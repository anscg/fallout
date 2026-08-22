class Admin::ShipsController < Admin::ApplicationController
  before_action :set_ship, only: %i[show]

  def index
    # policy_scope runs on the critical path so verify_policy_scoped passes on the initial
    # (deferred) render; it's lazy, so no query fires until the deferred loader enumerates it.
    scope = policy_scope(Ship)
    render inertia: deferred_index_props(scope)
  end

  def show
    authorize @ship

    render inertia: {
      ship: serialize_ship_detail(@ship)
    }
  end

  private

  # Memoized loader shared by the deferred index props so the heavy query runs once per
  # deferred request even though ships/pagy are separate Inertia props.
  def deferred_index_props(scope)
    memo = nil
    load = lambda do
      memo ||= begin
        @pagy, @ships = pagy(scope.includes(:project, :reviewer, project: :user).order(created_at: :desc))
        { ships: @ships.map { |s| serialize_ship_row(s) }, pagy: pagy_props(@pagy) }
      end
    end
    {
      ships: InertiaRails.defer(group: "index") { load.call[:ships] },
      pagy: InertiaRails.defer(group: "index") { load.call[:pagy] }
    }
  end

  def set_ship
    @ship = Ship.includes(:time_audit_review, :requirements_check_review, :design_review, :build_review, project: :user).find(params[:id])
  end

  def serialize_ship_row(ship)
    {
      id: ship.id,
      project_name: ship.project.name,
      user_display_name: ship.project.user.display_name,
      status: ship.status,
      reviewer_display_name: ship.reviewer&.display_name,
      created_at: ship.created_at.strftime("%b %d, %Y")
    }
  end

  def serialize_ship_detail(ship)
    public_hrs = ship.approved_public_seconds ? (ship.approved_public_seconds / 3600.0).round(1) : nil
    internal_hrs = internal_hours_display(ship)
    {
      id: ship.id,
      status: ship.status,
      approved_public_hours: public_hrs,
      approved_internal_hours: internal_hrs,
      feedback: ship.feedback,
      justification: ship.justification,
      frozen_demo_link: ship.frozen_demo_link,
      frozen_repo_link: ship.frozen_repo_link,
      project_name: ship.project.name,
      user_display_name: ship.project.user.display_name,
      review_statuses: review_statuses_payload(ship),
      created_at: ship.created_at.strftime("%B %d, %Y")
    }
  end

  # nil when nothing has been approved or adjusted yet, so the UI shows blank
  # instead of "0.0h" for ships still in flight.
  def internal_hours_display(ship)
    seconds = ship.approved_internal_seconds
    return nil if seconds.zero?
    (seconds / 3600.0).round(1)
  end
end
