# frozen_string_literal: true

class StasisService
  BASE_URL = "https://stasis.hackclub.com"

  def self.fetch_projects(email)
    res = Faraday.get("#{BASE_URL}/api/integrations/projects/by-email") do |req|
      req.params["email"] = email
      req.headers["Authorization"] = "Bearer #{ENV.fetch('STASIS_API_KEY')}"
    end
    raise "Stasis #{res.status} for /api/integrations/projects/by-email: #{res.body.truncate(300)}" unless res.success?

    JSON.parse(res.body).fetch("projects", [])
  end
end
