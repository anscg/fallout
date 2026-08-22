# frozen_string_literal: true

# Computes what changed in a project's repo since the last relevant review, for
# surfacing on re-ship review pages. Computed once per review (on creation) and
# cached in the review's repo_diff column, mirroring repo_tree — so it reflects
# the repo near submission and may lag slightly behind later pushes.
#
# Anchors on the prior review's stored commit SHA; falls back to the commit at
# the prior review's completion time when no SHA was stored (older reviews) or
# the stored SHA was force-pushed out of the repo.
module ReviewRepoDiffService
  module_function

  # Computes the summary for a review, resolving its own anchor. Returns the
  # summary hash, or nil when there's nothing to compare (first review,
  # non-GitHub repo, or GitHub unreachable).
  def for_review(review)
    compute(review.ship, anchor_review_for(review))
  end

  # The baseline is the most recent time the project was sent back for changes —
  # a returned or rejected review among this review type's anchor classes (RC diffs
  # against RC/DR/BR, DR/BR against DR/BR), excluding the current ship. Approvals
  # after that return do NOT reset it: the diff always shows what the student
  # changed since they were last asked to fix something. A project never returned/
  # rejected is a fresh cycle, not a re-ship, so there's no baseline → nil.
  def anchor_review_for(review)
    review.class.repo_diff_anchor_classes.filter_map do |klass|
      klass.joins(:ship)
        .where(ships: { project_id: review.ship.project_id })
        .where.not(ship_id: review.ship_id)
        .where(status: [ :returned, :rejected ])
        .where.not(completed_at: nil)
        .order(completed_at: :desc)
        .first
    end.max_by(&:completed_at)
  end

  def compute(ship, anchor_review)
    return nil unless anchor_review

    owner, repo = GithubService.parse_repo(ship.project.repo_link)
    return nil unless owner

    head = GithubService.head_commit_sha(owner, repo)
    return nil unless head

    basis = "sha"
    base = anchor_review.reviewed_commit_sha.presence
    result = base && GithubService.compare(owner, repo, base, head)

    if result.nil? # no stored SHA, or it was force-pushed away — fall back to the completion date
      basis = "date"
      base = GithubService.commit_sha_at(owner, repo, anchor_review.completed_at)
      result = base && GithubService.compare(owner, repo, base, head)
    end
    return nil unless result

    summarize(result, basis:, base:, head:, anchor_review:)
  end

  def summarize(result, basis:, base:, head:, anchor_review:)
    files = result[:files]
    {
      commits: result[:total_commits],
      added: files.count { |f| f[:status] == "added" },
      modified: files.count { |f| %w[modified changed].include?(f[:status]) },
      removed: files.count { |f| f[:status] == "removed" },
      renamed: files.count { |f| f[:status] == "renamed" },
      files: files,
      basis: basis, # "sha" = exact anchor; "date" = approximated from completion time
      since: anchor_review.completed_at&.iso8601,
      anchor_review_type: anchor_review.class.name.underscore,
      base_sha: base,
      head_sha: head
    }
  end
end
