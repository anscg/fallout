class ProjectFundingTopupPolicy < ApplicationPolicy
  # Ledger rows are read through Admin::ProjectGrants::OrdersController#index via
  # policy_scope. Write access is for manual adjustments (direction=in or out)
  # recorded by admins to reconcile real-world HCB activity outside the automated
  # settle flow. Money movement gate: hcb role only.
  def new? = hcb?
  def create? = hcb?
  # Read-only unissued-funds report. Same hcb gate as the adjustments form: it surfaces
  # the per-user delta figures that drive money movement, not just order metadata.
  def unissued_funds? = hcb?
  # Converts owed funding into koi/gold. Ledger-only (no HCB call — the money is
  # already back at the org), but it writes the money ledger and mints currency.
  def refund_to_currency? = hcb?
  # Pushes owed funding onto the user's card via the settle service. Real money moves.
  def issue_funds? = hcb?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user&.admin?

      scope.all
    end
  end

  private

  def hcb?
    user&.hcb?
  end
end
