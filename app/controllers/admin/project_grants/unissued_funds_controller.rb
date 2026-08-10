class Admin::ProjectGrants::UnissuedFundsController < Admin::ApplicationController
  before_action :require_admin! # Money surface — non-admin staff never reach it

  # Users we owe funding to with no way to deliver it: delta > 0 (fulfilled orders
  # exceed what's actually been transferred) and no order sitting in the queue that
  # could trigger a settle. Their entitlement only moves when they place a new order,
  # at which point the next card is topped up by more than they asked for.
  #
  # Two ways out, one button each: pay it onto their card (#issue_funds, real money)
  # or convert it back into koi/gold (#refund_to_currency, ledger-only).
  AWAITING_FULFILMENT_STATES = %w[pending on_hold].freeze

  # Cap the payload; the list should be short by nature. `truncated` tells the UI to
  # say so rather than silently implying it's the whole set.
  ROW_LIMIT = 250

  # Sentinel on the koi/gold ledger entries this controller writes. Summing prior
  # refunds is how the gold cap stays honest across repeated partial refunds — without
  # it, refunding $10 twice could hand back more gold than the user ever spent.
  CURRENCY_REFUND_PREFIX = "[Grant refund]"

  def index
    # Read-only, but it exposes the same per-user money figures as the adjustments
    # form, so it sits behind the same hcb gate rather than plain admin.
    authorize ProjectFundingTopup, :unissued_funds?

    # Satisfies verify_policy_scoped and keeps every aggregate below inside the same
    # scope the topups ledger uses.
    topups = policy_scope(ProjectFundingTopup).kept

    expected_by_user = ProjectGrantOrder.kept.where(state: "fulfilled").group(:user_id).sum(:frozen_usd_cents)
    # Mirrors ProjectFundingTopupService#funding_transferred_usd_cents — the same sum
    # the settle service uses for delta, so this page agrees with what a future order
    # would actually send.
    funding_by_user = topups.where(status: "completed", counts_toward_funding: true).group(:user_id).sum(
      Arel.sql("CASE direction WHEN 'out' THEN -amount_cents ELSE amount_cents END")
    )

    owed = expected_by_user.filter_map do |user_id, expected|
      delta = expected - (funding_by_user[user_id] || 0)
      [ user_id, delta ] if delta.positive?
    end.to_h

    # An order awaiting fulfilment already provides a path — fulfilling it settles the
    # whole delta, so those users aren't stuck and don't belong on this page.
    unless owed.empty?
      awaiting = ProjectGrantOrder.kept.where(state: AWAITING_FULFILMENT_STATES, user_id: owed.keys)
        .distinct.pluck(:user_id)
      owed = owed.except(*awaiting)
    end

    ranked = owed.sort_by { |_user_id, delta| -delta }
    truncated = ranked.size > ROW_LIMIT
    page_ids = ranked.first(ROW_LIMIT).map(&:first)

    setting = HcbGrantSetting.current
    render inertia: "admin/project_grants/unissued_funds/index", props: {
      rows: serialize_rows(page_ids, owed, expected_by_user, funding_by_user, topups),
      stats: {
        user_count: ranked.size,
        total_owed_cents: ranked.sum { |(_user_id, delta)| delta }
      },
      truncated: truncated,
      row_limit: ROW_LIMIT,
      # Drives the live koi/gold split in the refund dialog. The server recomputes the
      # authoritative split on submit — this is for display only.
      rates: {
        koi_to_cents_numerator: setting.koi_to_cents_numerator,
        koi_to_cents_denominator: setting.koi_to_cents_denominator
      }
    }
  end

  # POST /admin/project_grants/unissued_funds/:id/refund_to_currency
  # Converts owed funding back into koi/gold. No HCB call: a positive delta means the
  # dollars are already sitting at the org, so this is purely two ledger writes — an
  # `in`/counts:true row cancelling the entitlement, and the currency credits.
  def refund_to_currency
    authorize ProjectFundingTopup, :refund_to_currency?

    user = User.find(params[:id])
    amount_cents = (params[:amount_dollars].to_f * 100).round
    error = nil
    credited = nil

    ActiveRecord::Base.transaction do
      # Same key the settle service and donation matcher use, so a refund can't
      # interleave with a topup that's changing the same delta.
      lock_key = "pft:#{user.id}"
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext(#{ActiveRecord::Base.connection.quote(lock_key)}))"
      )

      owed_cents = ProjectFundingTopupService.delta_cents(user)
      # Re-derived inside the lock, so a double-submit finds the delta already spent
      # and fails instead of refunding twice. No idempotency token needed.
      error = refund_blocker(user, amount_cents, owed_cents)

      if error.nil?
        units = HcbGrantSetting.current.refund_units_for_usd_cents(amount_cents)
        if units.zero?
          error = "$#{'%.2f' % (amount_cents / 100.0)} converts to 0 koi at the current rate — refund a larger amount."
        else
          credited = credit_currency!(user, amount_cents, units)
        end
      end

      raise ActiveRecord::Rollback if error
    end

    if error
      redirect_to admin_project_grants_unissued_funds_path, alert: error
    else
      redirect_to admin_project_grants_unissued_funds_path,
        notice: "Refunded $#{'%.2f' % (amount_cents / 100.0)} to #{user.display_name} as " \
                "#{credited[:gold]} gold and #{credited[:koi]} koi."
    end
  end

  # POST /admin/project_grants/unissued_funds/:id/issue_funds
  # Pushes the owed balance onto the user's card through the normal settle service —
  # same path an order fulfilment takes, minus the order. Every existing guard applies
  # (pending-topup reconciliation, ratchet cap, dangling-card window).
  def issue_funds
    authorize ProjectFundingTopup, :issue_funds?

    user = User.find(params[:id])
    owed_cents = ProjectFundingTopupService.delta_cents(user)

    if owed_cents <= 0
      redirect_to admin_project_grants_unissued_funds_path,
        alert: "#{user.display_name} is no longer owed anything — nothing to issue."
      return
    end

    # settle! raises ReconciliationRequired on a pending row; refusing up front gives a
    # readable message instead of a failed background job.
    if user.project_funding_topups.kept.where(status: "pending").exists?
      redirect_to admin_project_grants_unissued_funds_path,
        alert: "#{user.display_name} has a pending topup — reconcile it before issuing."
      return
    end

    ProjectFundingTopupJob.perform_later(user.id)
    redirect_to admin_project_grants_unissued_funds_path,
      notice: "Queued $#{'%.2f' % (owed_cents / 100.0)} to #{user.display_name}'s card. " \
              "The ledger updates once HCB confirms."
  end

  private

  # Returns a message if the refund must not proceed, nil if it's safe. Ordered
  # cheapest-first; every branch is a reason real money would be double-counted.
  def refund_blocker(user, amount_cents, owed_cents)
    if amount_cents <= 0
      "Enter an amount greater than $0."
    elsif owed_cents <= 0
      "#{user.display_name} is no longer owed anything — the balance may have been settled already."
    elsif amount_cents > owed_cents
      "Refund exceeds the $#{'%.2f' % (owed_cents / 100.0)} owed to #{user.display_name}."
    elsif user.project_funding_topups.kept.where(status: "pending").exists?
      # The pending row may or may not have reached HCB. Crediting koi now risks paying
      # the user twice if it later completes.
      "#{user.display_name} has a pending topup — reconcile it before refunding."
    elsif user.hcb_grant_cards.none?
      # ProjectFundingTopup requires a card FK, so there's nowhere to book the
      # entitlement cancellation. Mirrors the adjustments form's refusal.
      "#{user.display_name} has no HCB grant card on record to book the adjustment against."
    end
  end

  # Books the entitlement cancellation and the currency credits as one unit. Gold is
  # returned first, capped at what the user actually spent in gold and never exceeding
  # it across repeated refunds; the remainder comes back as koi.
  def credit_currency!(user, amount_cents, units)
    gold = [ units, refundable_gold_for(user) ].min
    koi = units - gold
    setting = HcbGrantSetting.current
    rate_note = "#{setting.koi_to_cents_denominator} units = $#{'%.2f' % (setting.koi_to_cents_numerator / 100.0)}"
    description = "#{CURRENCY_REFUND_PREFIX} $#{'%.2f' % (amount_cents / 100.0)} of unissued project funding " \
                  "returned as #{gold} gold + #{koi} koi (#{rate_note})"

    ProjectFundingTopup.create!(
      user: user,
      hcb_grant_card: user.hcb_grant_cards.active.first || user.hcb_grant_cards.order(created_at: :desc).first,
      direction: "in",
      amount_cents: amount_cents,
      # Terminal on create — this reflects a decision, not an outbox write. `in` with
      # counts_toward_funding pushes the entitlement back DOWN, which is the whole
      # point: the dollars left as currency, so they must stop being spendable funding.
      status: "completed",
      completed_at: Time.current,
      counts_toward_funding: true,
      note: "[Refund to koi/gold by #{current_user.display_name}] #{description}"
    )

    if gold.positive?
      GoldTransaction.create!(user: user, actor: current_user, amount: gold,
                              reason: "admin_adjustment", description: description)
    end
    if koi.positive?
      KoiTransaction.create!(user: user, actor: current_user, amount: koi,
                             reason: "admin_adjustment", description: description)
    end

    { gold: gold, koi: koi }
  end

  # Gold the user can still get back: what they spent on fulfilled orders, minus gold
  # already returned through this flow.
  def refundable_gold_for(user)
    spent = user.project_grant_orders.kept.where(state: "fulfilled").sum(:frozen_gold_amount)
    already_refunded = user.gold_transactions.where(reason: "admin_adjustment")
      .where("amount > 0").where("description LIKE ?", "#{CURRENCY_REFUND_PREFIX}%").sum(:amount)
    [ spent - already_refunded, 0 ].max
  end

  def serialize_rows(user_ids, owed, expected_by_user, funding_by_user, topups)
    return [] if user_ids.empty?

    users = User.where(id: user_ids).index_by(&:id)
    pending_topup_user_ids = topups.where(status: "pending", user_id: user_ids).distinct.pluck(:user_id).to_set
    causes = cause_lookup(user_ids, topups, pending_topup_user_ids)
    active_card_user_ids = HcbGrantCard.active.where(user_id: user_ids).pluck(:user_id).to_set
    any_card_user_ids = HcbGrantCard.where(user_id: user_ids).distinct.pluck(:user_id).to_set
    # When the delta appeared — the newest `out` row is what pushed transferred below
    # expected, so it dates the debt.
    owed_since = topups.where(status: "completed", direction: "out", user_id: user_ids)
      .group(:user_id).maximum(:created_at)
    last_order_at = ProjectGrantOrder.kept.where(state: "fulfilled", user_id: user_ids)
      .group(:user_id).maximum(:created_at)
    gold_refundable = refundable_gold_by_user(user_ids)

    user_ids.filter_map do |user_id|
      user = users[user_id]
      next unless user

      {
        user: { id: user.id, display_name: user.display_name, email: user.email, avatar: user.avatar },
        owed_cents: owed[user_id],
        expected_cents: expected_by_user[user_id] || 0,
        transferred_cents: funding_by_user[user_id] || 0,
        has_active_card: active_card_user_ids.include?(user_id),
        # Both actions need somewhere to book the ledger row; no card at all blocks the refund.
        has_card: any_card_user_ids.include?(user_id),
        # Blocks both buttons — we can't tell whether the pending money reached HCB.
        has_pending_topup: pending_topup_user_ids.include?(user_id),
        gold_refundable: gold_refundable[user_id] || 0,
        cause: causes[user_id] || "unknown",
        owed_since: owed_since[user_id]&.iso8601,
        last_fulfilled_order_at: last_order_at[user_id]&.iso8601
      }
    end
  end

  # Bulk version of refundable_gold_for for the index payload.
  def refundable_gold_by_user(user_ids)
    spent = ProjectGrantOrder.kept.where(state: "fulfilled", user_id: user_ids)
      .group(:user_id).sum(:frozen_gold_amount)
    refunded = GoldTransaction.where(user_id: user_ids, reason: "admin_adjustment")
      .where("amount > 0").where("description LIKE ?", "#{CURRENCY_REFUND_PREFIX}%")
      .group(:user_id).sum(:amount)

    spent.each_with_object({}) do |(user_id, gold), memo|
      memo[user_id] = [ gold - (refunded[user_id] || 0), 0 ].max
    end
  end

  # Why each user is owed, most-actionable first. A stuck or failed topup means the
  # money never left despite a fulfilled order (reconciliation work); a closure refund
  # or manual out means it came back and is simply waiting on a new order.
  def cause_lookup(user_ids, topups, pending_topup_user_ids)
    completed_out = topups.where(status: "completed", direction: "out", user_id: user_ids)

    by_cause = {
      "manual_out" => completed_out.where(counts_toward_funding: true)
        .where("note LIKE ?", "[Manual adjustment%").distinct.pluck(:user_id),
      "card_closed" => completed_out
        .where("note LIKE ?", "#{HcbGrantCardSyncJob::CLOSURE_REFUND_NOTE_PREFIX}%").distinct.pluck(:user_id),
      "failed_topup" => topups.where(status: "failed", user_id: user_ids).distinct.pluck(:user_id),
      "pending_topup" => pending_topup_user_ids.to_a
    }

    # Later keys overwrite earlier ones, so the hash order above is the priority order.
    by_cause.each_with_object({}) do |(cause, ids), lookup|
      ids.each { |id| lookup[id] = cause }
    end
  end
end
