class ApplicationController < ActionController::Base
  before_action :secure_session_cookie
  before_action :enforce_idle_timeout
  before_action :require_open_vault
  before_action :set_locale

  helper_method :help_mode?, :settings, :vault_open?, :vault_held_elsewhere?

  private

  # DPP_SECURE_COOKIES: behind HTTPS the session cookie is sent over HTTPS only.
  # It is the cookie that holds the vault (Vault::Session), so it should never
  # travel in the clear because somebody typed http:// once.
  def secure_session_cookie
    request.session_options[:secure] = true if Deployment.secure_cookies?
  end

  # Open for this request: the vault is open, and this session is the one that
  # opened it (Vault::Session). Any other session sees it as locked.
  def vault_open?
    Vault::Store.open? && Vault::Session.held_by?(session[:vault_holder])
  end

  # Open, but in another session. The unlock screen says so, because typing the
  # passphrase here takes it over.
  def vault_held_elsewhere?
    Vault::Store.open? && !vault_open?
  end

  # A request that finds the vault closed is not carried out. What the person
  # was doing is remembered — which page, and which action if it was one — so
  # that unlocking leads back there and says that the action did not happen.
  # The values of the form are not: they stay in the browser that typed them
  # (resume_controller.js), which is the only place they were ever meant to be.
  #
  # A session whose vault was taken over by another session is told so once,
  # on its next request; after that it is simply a session without a vault.
  def require_open_vault
    return if vault_open?

    taken_over = session[:vault_holder].present? && Vault::Store.open?
    session.delete(:vault_holder) if taken_over

    remember_interrupted_request!
    message = [ (t("vault.taken_over") if taken_over),
                (t("vault.action_not_done") if interrupted_action) ].compact.join(" ")
    redirect_to unlock_path, alert: message.presence
  end

  # The vault closes itself after a while unattended. What that costs is a
  # re-typed passphrase; what it buys is that a laptop left open in an office
  # does not leave the passports readable.
  #
  # The clock is the holder's — only its requests move it — but it is kept in
  # the process, not in the holder's cookie, and checked on every request from
  # any session. A holder who walks away therefore does not leave the key in
  # memory until they come back: the next request from anywhere closes it.
  def enforce_idle_timeout
    return unless close_vault_left_idle

    # Somebody else's vault ran out; for this session nothing changes, and
    # require_open_vault sends it to the unlock screen as it would anyway.
    return unless @closed_for_holder

    reset_session
    remember_interrupted_request!
    message = interrupted_action ? t("vault.locked_after_idle_action") : t("vault.locked_after_idle")
    redirect_to unlock_path, alert: message
  end

  # Closes the vault if its holder has been away longer than the limit, and
  # says whether it did. Otherwise a request of the holder counts as activity —
  # except a link Turbo fetches ahead because the pointer rests on it, which is
  # not somebody using the application.
  def close_vault_left_idle
    return false unless Vault::Store.open?

    holder = vault_open?
    if Vault::Session.idle_longer_than?(settings.idle_timeout_minutes.minutes)
      detail = { not_carried_out: (interrupted_action if holder) }.compact
      Vault::Lifecycle.lock!(reason: "idle", **detail)
      @closed_for_holder = holder
      return true
    end

    Vault::Session.touch! if holder && !prefetch?
    false
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
