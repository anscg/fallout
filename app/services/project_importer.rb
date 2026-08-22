# frozen_string_literal: true

# Usage (production console):
#   ProjectImporter.run!                                              # live import
#   ProjectImporter.run!(dry_run: true)                               # preview only
#   ProjectImporter.run!(only_link: "https://blueprint.hackclub.com/projects/123")
#   ProjectImporter.run!(only_link: "https://stasis.hackclub.com/projects/abc123")
#
# Behaviour:
#   - Reads approved rows from the transfer Airtable table.
#   - Detects whether each link is a Blueprint or Stasis project and fetches
#     project data from the appropriate API.
#   - Finds the Fallout user by email, then merges journal entries into an
#     existing same-named project or creates a new one. Adds overridden hours
#     to the project's manual_seconds.
#   - Deduplication: entries whose timestamp (to the minute) already exists on
#     the project are skipped, so re-running is safe.
class ProjectImporter
  AIRTABLE_TABLE_ID = "tblOzctyz4JGHL24P"

  COL_EMAIL   = "Email"
  COL_BP_LINK = "Blueprint / Stasis Project Link"
  COL_STATUS  = "Status"
  COL_HOURS   = "OPTIONAL - Hours Override"

  def self.run!(dry_run: false, only_link: nil)
    puts "=== Project Import#{' (DRY RUN)' if dry_run} ==="

    rows     = fetch_airtable_rows
    approved = rows.select { |r| r.dig("fields", COL_STATUS)&.strip&.casecmp?("approved") }
    approved = approved.select { |r| r.dig("fields", COL_BP_LINK)&.strip == only_link } if only_link
    puts "Airtable: #{rows.size} rows total, #{approved.size} approved#{" (filtered to #{only_link})" if only_link}\n\n"

    stats         = Hash.new(0)
    no_user_links = []
    transferred   = Hash.new { |h, k| h[k] = [] }

    approved.each do |row|
      fields         = row["fields"]
      email          = fields[COL_EMAIL]&.strip
      link           = fields[COL_BP_LINK]&.strip
      hours_override = fields[COL_HOURS]&.to_f

      unless email.present? && link.present?
        puts "SKIP (missing email/link): row #{row['id']}"
        stats[:skipped] += 1
        next
      end

      source = detect_source(link)
      unless source
        puts "SKIP (unrecognized link format): #{link}"
        stats[:skipped] += 1
        next
      end

      project_id = extract_project_id(link)
      unless project_id
        puts "SKIP (can't parse project ID from): #{link}"
        stats[:skipped] += 1
        next
      end

      user = User.verified.find_by(email: email)
      unless user
        puts "SKIP (no Fallout user for): #{email}"
        no_user_links << link
        stats[:skipped] += 1
        next
      end

      begin
        raw_project = fetch_raw_project(source, email, project_id)

        unless raw_project&.fetch("name", nil).present?
          puts "SKIP (project #{project_id} not found in #{source} for #{email}): #{link}"
          stats[:skipped] += 1
          next
        end

        project_data = normalize_project(source, raw_project, project_id)

        project_name = import_project(user, project_data, source, hours_override, dry_run, stats)
        transferred[user] << project_name if project_name
      rescue => e
        puts "ERROR #{email} / #{source}##{project_id}: #{e.class} — #{e.message}"
        stats[:errors] += 1
      end
    end

    unless dry_run
      transferred.each do |user, names|
        MailDeliveryService.project_transfer(user, names)
        puts "  + transfer mail sent to #{user.email} (#{names.join(', ')})"
      end
    end

    puts "\n=== Done: created=#{stats[:created]} merged=#{stats[:merged]} " \
         "entries=#{stats[:entries_added]} skipped=#{stats[:skipped]} errors=#{stats[:errors]} ==="

    if no_user_links.any?
      puts "\nNo Fallout user found for these project links:"
      no_user_links.each { |link| puts "  #{link}" }
    end

    stats
  end

  private_class_method def self.detect_source(url)
    host = URI.parse(url).host
    return "Blueprint" if host == "blueprint.hackclub.com"
    return "Stasis"    if host == "stasis.hackclub.com"
    nil
  rescue URI::InvalidURIError
    nil
  end

  private_class_method def self.extract_project_id(url)
    URI.parse(url).path.match(/\/([^\/]+)\/?$/)&.[](1)
  rescue URI::InvalidURIError
    nil
  end

  private_class_method def self.fetch_raw_project(source, email, project_id)
    case source
    when "Blueprint"
      raw_projects = BlueprintService.fetch_projects(email)
      raw_projects.find { |p| p["id"].to_s == project_id.to_s }
    when "Stasis"
      raw_projects = StasisService.fetch_projects(email)
      raw_projects.find { |p| p["id"].to_s == project_id.to_s }
    end
  end

  private_class_method def self.normalize_project(source, raw, project_id)
    case source
    when "Blueprint"
      {
        id:              project_id,
        name:            raw["name"],
        description:     raw["description"],
        repo_link:       raw["repo_url"],
        demo_link:       raw["demo_url"],
        journal_entries: (raw["journal_entries"] || []).map do |e|
          { timestamp: e["date"], content: e["content"] }
        end
      }
    when "Stasis"
      {
        id:              project_id,
        name:            raw["name"],
        description:     raw["description"],
        repo_link:       raw["repoUrl"],
        demo_link:       nil,
        journal_entries: (raw["journalEntries"] || []).map do |e|
          { timestamp: e["createdAt"], content: e["content"] }
        end
      }
    end
  end

  private_class_method def self.import_project(user, project_data, source, hours_override, dry_run, stats)
    existing = user.projects.kept.find_by("LOWER(name) = ?", project_data[:name].downcase)

    if existing
      puts "  MERGE '#{project_data[:name]}' into project##{existing.id} (#{user.email})"
      project = existing
      stats[:merged] += 1
    else
      print "  No match for '#{project_data[:name]}' (#{user.email}). Project ID to merge into, or N to create new: "
      input = $stdin.gets&.strip

      if input.nil? || input.casecmp?("n")
        puts "  -> CREATE new project"
        stats[:created] += 1
        return if dry_run

        project = user.projects.create!(
          name:        project_data[:name],
          description: project_data[:description],
          repo_link:   valid_url?(project_data[:repo_link]) ? project_data[:repo_link] : nil,
          demo_link:   valid_url?(project_data[:demo_link]) ? project_data[:demo_link] : nil
        )
      else
        project = user.projects.kept.find_by(id: input.to_i)
        unless project
          puts "  SKIP (project ##{input} not found for #{user.email})"
          stats[:skipped] += 1
          return
        end
        puts "  -> MERGE into project##{project.id} '#{project.name}'"
        stats[:merged] += 1
      end
    end

    return if dry_run

    transfer_marker = "Project transferred from #{source}!"
    already_transferred = project.journal_entries.where("content LIKE ?", "Project transferred from %").exists?

    project_data[:journal_entries].each do |entry_data|
      next unless entry_data[:timestamp].present?

      ts = entry_data[:timestamp].to_time.utc

      if project.journal_entries.exists?(created_at: ts.beginning_of_minute..ts.end_of_minute)
        puts "    SKIP entry (already exists at #{ts})"
        next
      end

      content = entry_data[:content]
      next if content.blank?

      je = JournalEntry.create!(user: user, project: project, content: content)
      je.update_columns(created_at: ts, updated_at: ts)
      MeilisearchReindexJob.perform_later(je.class.name, je.id)

      stats[:entries_added] += 1
      puts "    + entry #{ts}"
    end

    if already_transferred
      puts "    SKIP transfer markers (already transferred — re-run)"
      return nil
    end

    if hours_override&.positive?
      secs = (hours_override * 3600).round
      project.increment!(:manual_seconds, secs)
      puts "    + #{hours_override}h added to manual time"
    end

    transfer_content = if hours_override&.positive?
      "#{transfer_marker} Duration Transferred: #{hours_override}h"
    else
      transfer_marker
    end
    JournalEntry.create!(user: user, project: project, content: transfer_content)
    puts "    + transfer journal entry added"

    project.name
  end

  private_class_method def self.fetch_airtable_rows
    base   = ENV.fetch("AIRTABLE_BASE_ID")
    key    = ENV.fetch("AIRTABLE_API_KEY")
    rows   = []
    offset = nil

    loop do
      params = { pageSize: 100 }
      params[:offset] = offset if offset

      res = Faraday.get("https://api.airtable.com/v0/#{base}/#{AIRTABLE_TABLE_ID}") do |req|
        req.headers["Authorization"] = "Bearer #{key}"
        req.params.merge!(params)
      end
      raise "Airtable #{res.status}: #{res.body.truncate(300)}" unless res.success?

      data = JSON.parse(res.body)
      rows.concat(data["records"] || [])
      offset = data["offset"]
      break unless offset
    end

    rows
  end

  private_class_method def self.valid_url?(url)
    url.present? && url.match?(/\Ahttps?:\/\/\S+\z/i)
  end
end
