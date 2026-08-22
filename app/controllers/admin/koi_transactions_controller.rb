class Admin::KoiTransactionsController < Admin::ApplicationController
  before_action :require_admin! # Only admins can adjust koi/gold balances

  def index
    # policy_scope runs on the critical path so verify_policy_scoped passes on the initial
    # (deferred) render; it's lazy, so no query fires until the deferred loader enumerates it.
    scope = policy_scope(transaction_model)

    render inertia: "admin/koi_transactions/index", props: {
      user_id_filter: params[:user_id].to_s,
      user_filter: prefill_user_payload,
      search: params[:search].to_s,
      reason_filter: params[:reason].to_s,
      reasons: transaction_model::REASONS,
      currency: current_currency,
      **deferred_index_props(scope)
    }
  end

  def new
    model = transaction_model
    @transaction = model.new
    @transaction.user_id = params[:user_id] if params[:user_id].present?
    authorize @transaction

    render inertia: "admin/koi_transactions/new", props: {
      prefill_user: prefill_user_payload,
      currency: current_currency
    }
  end

  def create
    model = transaction_model
    @transaction = model.new(transaction_params)
    @transaction.actor = current_user
    @transaction.reason = "admin_adjustment"
    authorize @transaction

    if @transaction.save
      redirect_to admin_koi_transactions_path(user_id: @transaction.user_id, currency: current_currency),
        notice: "#{current_currency.capitalize} adjustment saved."
    else
      redirect_back fallback_location: new_admin_koi_transaction_path(currency: current_currency),
        inertia: { errors: @transaction.errors.messages }
    end
  end

  # JSON autocomplete for the adjustment user picker — mirrors the projects_search pattern.
  def users_search
    skip_authorization # Admin-only via require_admin!; read-only lookup, no record to authorize
    skip_policy_scope

    query = params[:q].to_s.strip
    return render(json: { users: [] }) if query.blank?

    # verified-only hides trial users (STI: TrialUser has type set, verified users type IS NULL).
    users = User.verified.search(query).limit(8).to_a

    # Let admins paste a raw user id — surface that exact user at the top of the results.
    if query.match?(/\A\d+\z/)
      by_id = User.verified.find_by(id: query)
      users.unshift(by_id) if by_id && users.exclude?(by_id)
      users = users.first(8)
    end

    render json: { users: users.map { |u| serialize_user_option(u) } }
  end

  private

  # Memoized loader shared by the deferred index props so the heavy query runs once per
  # deferred request even though transactions/pagy/stats are separate Inertia props.
  def deferred_index_props(scope)
    memo = nil
    load = lambda do
      memo ||= begin
        filtered = apply_filters(scope)
        @pagy, transactions = pagy(filtered.includes(:user, :actor).order(created_at: :desc))
        # Count is the true total (matches the listing), but the koi/gold sums exclude amounts
        # received by admins (self-grants / testing) so the economy figures reflect real users.
        # 'admin' is a hardcoded role literal — no user input is interpolated.
        not_admin = "NOT (users.roles @> ARRAY['admin']::varchar[])"
        count, net, added = filtered.reorder(nil).joins(:user).pick(Arel.sql(
          "COUNT(*), " \
          "COALESCE(SUM(amount) FILTER (WHERE #{not_admin}), 0), " \
          "COALESCE(SUM(amount) FILTER (WHERE amount > 0 AND #{not_admin}), 0)"
        ))
        {
          transactions: transactions.map { |t| serialize_transaction(t) },
          pagy: pagy_props(@pagy),
          stats: { count: count, net: net, added: added, removed: added - net }
        }
      end
    end
    {
      transactions: InertiaRails.defer(group: "index") { load.call[:transactions] },
      pagy: InertiaRails.defer(group: "index") { load.call[:pagy] },
      stats: InertiaRails.defer(group: "index") { load.call[:stats] }
    }
  end

  def apply_filters(scope)
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(reason: params[:reason]) if transaction_model::REASONS.include?(params[:reason])

    if params[:search].present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip)}%"
      table = transaction_model.table_name
      scope = scope.joins(:user).where(
        "users.display_name ILIKE :q OR users.email ILIKE :q OR #{table}.description ILIKE :q", q: term
      )
    end

    scope
  end

  def current_currency
    params[:currency] == "gold" ? "gold" : "koi"
  end

  def transaction_model
    current_currency == "gold" ? GoldTransaction : KoiTransaction
  end

  def transaction_params
    if current_currency == "gold"
      params.expect(gold_transaction: [ :user_id, :amount, :description ])
    else
      params.expect(koi_transaction: [ :user_id, :amount, :description ])
    end
  end

  def serialize_transaction(txn)
    {
      id: txn.id,
      user: { id: txn.user.id, display_name: txn.user.display_name, avatar: txn.user.avatar, email: txn.user.email },
      actor: txn.actor ? { id: txn.actor.id, display_name: txn.actor.display_name } : nil,
      amount: txn.amount,
      reason: txn.reason,
      description: txn.description,
      created_at: txn.created_at.strftime("%b %d, %Y %H:%M")
    }
  end

  # Balances read live off the ledger (User#koi / #gold) so the picker shows the admin exactly
  # what they're adjusting before committing. email is admin-only (require_admin! on the whole
  # controller), so PII exposure here is permitted.
  def serialize_user_option(user)
    {
      id: user.id,
      display_name: user.display_name,
      avatar: user.avatar,
      email: user.email,
      koi: user.koi,
      gold: user.gold
    }
  end

  def prefill_user_payload
    return nil if params[:user_id].blank?

    user = User.find_by(id: params[:user_id])
    user && serialize_user_option(user)
  end
end
