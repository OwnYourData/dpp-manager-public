class ApplicationController < ActionController::Base
  before_action :require_open_vault
  before_action :enforce_idle_timeout
  before_action :set_locale

  helper_method :help_mode?, :settings, :vault_open?

  private

  def vault_open?
    Vault::Store.open?
  end

  # A request that finds the vault closed is not carried out. What the person
  # was doing is remembered — which page, and which action if it was one — so
  # that unlocking leads back there and says that the action did not happen.
  # The values of the form are not: they stay in the browser that typed them
  # (resume_controller.js), which is the only place they were ever meant to be.
  def require_open_vault
    return if vault_open?

    remember_interrupted_request!
    redirect_to unlock_path, alert: (t("vault.action_not_done") if interrupted_action)
  end

  # The vault closes itself after a while unattended. What that costs is a
  # re-typed passphrase; what it buys is that a laptop left open in an office
  # does not leave the passports readable.
  def enforce_idle_timeout
    return unless vault_open?

    limit = settings.idle_timeout_minutes.minutes
    last  = session[:last_seen_at]&.to_time

    if last && Time.current - last > limit
      Vault::Lifecycle.lock!(reason: "idle", **{ not_carried_out: interrupted_action }.compact)
      reset_session
      remember_interrupted_request!
      message = interrupted_action ? t("vault.locked_after_idle_action") : t("vault.locked_after_idle")
      return redirect_to unlock_path, alert: message
    end

    # A link Turbo fetches ahead because the pointer rests on it is not somebody
    # using the application, so it does not keep the vault open.
    session[:last_seen_at] = Time.current.iso8601 unless prefetch?
  end

  # "POST /setup/custodian" — what a request that writes was going to do, for
  # the log and for the way back. nil for a request that only reads.
  def interrupted_action
    return nil if request.get? || request.head?

    "#{request.request_method} #{request.path}"
  end

  # Where unlocking should lead. A page that was asked for is that page; an
  # action is the page it was sent from, which is where its form is. Only paths
  # of this application, never another host and never the unlock page itself.
  def remember_interrupted_request!
    return if prefetch?

    target = request.get? || request.head? ? request.fullpath : referer_path
    session[:resume] = { "path" => (local_path(target) || root_path),
                         "action" => (request.path if interrupted_action) }.compact
  end

  def referer_path
    uri = URI.parse(request.referer.to_s)
    return nil unless uri.host.nil? || uri.host == request.host

    [ uri.path, uri.query ].compact.join("?")
  rescue URI::InvalidURIError
    nil
  end

  def local_path(path)
    path = path.to_s
    return nil unless path.start_with?("/") && !path.start_with?("//")
    return nil if path == unlock_path || path.start_with?("#{unlock_path}?")

    path
  end

  def prefetch?
    request.headers["X-Sec-Purpose"].to_s.include?("prefetch") || request.headers["Purpose"] == "prefetch"
  end

  def settings
    @settings ||= Setting.current
  end

  # While the vault is closed there is nowhere to store a preference, so the
  # choice on the unlock screen rides in the session cookie. Once it is open,
  # the setting inside the vault wins — that is the one the user actually set.
  def set_locale
    if vault_open?
      I18n.locale = settings.locale
    else
      session[:locale] = params[:locale] if Setting::LOCALES.include?(params[:locale])
      I18n.locale = session[:locale] || I18n.default_locale
    end
  end

  def help_mode?
    vault_open? && settings.help_mode
  end
end
