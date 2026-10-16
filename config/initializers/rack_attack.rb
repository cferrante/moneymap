# Rate-limits sensitive endpoints to slow down credential stuffing and
# password-reset abuse. Uses the app's existing Solid Cache store instead of
# adding Redis, consistent with the rest of the stack (see CLAUDE.md).
class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  safelist("allow-localhost") do |req|
    req.ip == "127.0.0.1" || req.ip == "::1"
  end

  # Throttle sign-in attempts by IP.
  throttle("logins/ip", limit: 10, period: 60) do |req|
    req.ip if req.path == "/session" && req.post?
  end

  # Throttle sign-in attempts by the email address being attempted, so a
  # distributed attack against one account is still slowed down.
  throttle("logins/email", limit: 5, period: 60) do |req|
    if req.path == "/session" && req.post?
      req.params["email_address"].to_s.downcase.strip.presence
    end
  end

  # Throttle password-reset requests by IP — this endpoint sends email and
  # is a common target for enumeration and abuse.
  throttle("password_resets/ip", limit: 5, period: 60) do |req|
    req.ip if req.path == "/passwords" && req.post?
  end

  # Throttle invitation acceptance by IP — it accepts a password and creates an
  # account. Deliberately looser than the controller's rate_limit (10 per 3
  # minutes): that one sends a struggling invitee back to their invitation, and
  # this must not preempt it with a bare 429. This one only stops floods.
  throttle("invitation_acceptances/ip", limit: 20, period: 60) do |req|
    req.ip if req.post? && req.path.start_with?("/invitations/")
  end
end

Rails.application.config.middleware.use Rack::Attack
