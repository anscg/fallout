desc "Cancel pending reviews stranded on terminal (approved/returned/rejected) ships — submitting them would attempt a forbidden ship status transition and 500"
task cancel_orphaned_pending_reviews: :environment do
  terminal = Ship.statuses.values_at("approved", "returned", "rejected")

  Reviewable::REVIEW_MODELS.each do |name|
    model = name.constantize
    scope = model.pending.joins(:ship).where(ships: { status: terminal })
    candidates = scope.count
    puts "#{name}: #{candidates} orphaned pending reviews"
    next if candidates.zero?

    cancelled = 0
    scope.find_each do |review|
      # skip_ship_recompute: the ship is already terminal — recomputing would try a
      # blocked transition out of the terminal state and raise (the original bug).
      review.skip_ship_recompute = true
      review.update!(status: :cancelled)
      cancelled += 1
      puts "  Cancelled #{name}##{review.id} (ship ##{review.ship_id}, ship status #{review.ship.status})"
    rescue StandardError => e
      puts "  Error #{name}##{review.id}: #{e.class}: #{e.message}"
    end

    puts "#{name}: cancelled #{cancelled}"
  end
end
