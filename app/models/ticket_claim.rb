# == Schema Information
#
# Table name: ticket_claims
#
#  id         :bigint           not null, primary key
#  state      :string           default("pending"), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_ticket_claims_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class TicketClaim < ApplicationRecord
  STATES = %w[pending approved rejected].freeze

  belongs_to :user

  enum :state, { pending: "pending", approved: "approved", rejected: "rejected" }, validate: true

  validates :state, inclusion: { in: STATES }
  validates :user_id, uniqueness: true # One claim per user enforced at both DB and model level

  # Airtable: sync people who hold an event ticket (an approved claim) to a dedicated table.
  # Table id comes from ENV so it can be configured per environment; AirtableSyncJob skips
  # this class entirely when it is unset, so the URL is never built with a nil table id.
  def self.airtable_sync_table_id
    ENV["AIRTABLE_EVENT_TICKETS_TABLE_ID"]
  end

  def self.airtable_sync_scope(query)
    query.approved.includes(:user)
  end

  def self.airtable_sync_field_mappings
    {
      "User ID"     => :user_id,
      "Email"       => ->(c) { c.user.email },
      "Display Name" => ->(c) { c.user.display_name },
      "First Name"  => ->(c) { c.user.first_name },
      "Last Name"   => ->(c) { c.user.last_name },
      "Claimed At"  => ->(c) { c.created_at&.iso8601 }
    }
  end
end
