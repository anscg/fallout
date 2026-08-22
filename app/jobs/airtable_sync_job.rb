class AirtableSyncJob < ApplicationJob
  queue_as :background

  CLASSES_TO_SYNC = %w[User Project ShopOrder Ship TimeAuditReview RequirementsCheckReview DesignReview BuildReview].freeze

  def perform
    return unless ENV["AIRTABLE_API_KEY"].present?

    classes = CLASSES_TO_SYNC.dup
    # Only sync event-ticket holders when the destination table is configured.
    classes << "TicketClaim" if ENV["AIRTABLE_EVENT_TICKETS_TABLE_ID"].present?

    classes.each do |classname|
      AirtableSyncClassJob.perform_later(classname)
    end
  end
end
