class ApplicationController < ActionController::Base
  before_action :require_open_vault
  before_action :enforce_idle_timeout
  before_action :set_locale

  helper_method :help_mode?, :settings, :vault_open?

  private

  def vault_open?
    Vault::Store.open?
  end

  def require_open_vault
    return if vault_open?

    redirect_to unlock_path
  end

  # The vault closes itself after a while unattended. What that costs is a
  # re-typed passphrase; what it buys is that a laptop left open in an office
  # does not leave the passports readable.
  def enforce_idle_timeout
    return unless vault_open?

    limit = settings.idle_timeout_minutes.minutes
    last  = session[:last_seen_at]&.to_time

    if last && Time.current - last > limit
      Vault::Lifecycle.lock!(reason: "idle")
      reset_session
      return redirect_to unlock_path, alert: t("vault.locked_after_idle")
    end

    session[:last_seen_at] = Time.current.iso8601
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
