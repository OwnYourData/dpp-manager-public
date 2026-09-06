# The way in. Everything else in the application sits behind this.
class UnlockController < ApplicationController
  skip_before_action :require_open_vault
  skip_before_action :enforce_idle_timeout

  layout "unlock"

  def show
    return redirect_to root_path if vault_open?

    @vault_exists = Vault::Store.exists?
  end

  # Creating and opening are the same button to the user — the application knows
  # which of the two it is by whether the file is there.
  def create
    if vault_open?
      redirect_to root_path
    elsif Vault::Store.exists?
      unlock
    else
      create_vault
    end
  end

  def destroy
    Vault::Lifecycle.lock!(reason: "manual")
    reset_session
    redirect_to unlock_path, notice: t("vault.locked")
  end

  private

  def unlock
    if Vault::Lifecycle.unlock!(params[:passphrase].to_s)
      start_session
      redirect_to root_path
    else
      @vault_exists = true
      flash.now[:alert] = t("vault.wrong_passphrase")
      render :show, status: :unprocessable_entity
    end
  end

  def create_vault
    passphrase = params[:passphrase].to_s
    confirm    = params[:passphrase_confirmation].to_s

    error = if passphrase.length < Vault::Passphrase::MINIMUM_LENGTH
      t("vault.passphrase_too_short", count: Vault::Passphrase::MINIMUM_LENGTH)
    elsif passphrase != confirm
      t("vault.passphrase_mismatch")
    end

    if error
      @vault_exists = false
      flash.now[:alert] = error
      return render :show, status: :unprocessable_entity
    end

    # Creating the vault also puts the bundled product types in it, which means
    # fetching two structures and generating four forms. It happens here rather
    # than later because the alternative is an empty Product types page on the
    # first morning; it is worth saying out loud because it is why this button
    # takes a moment.
    Vault::Lifecycle.create!(passphrase)
    start_session

    seeded = ProductType.fetched.pluck(:label)
    notice = [ t("vault.created"), (t("vault.seeded", labels: seeded.to_sentence) if seeded.any?) ].compact.join(" ")
    redirect_to root_path, notice: notice
  end

  def start_session
    reset_session
    session[:last_seen_at] = Time.current.iso8601
  end
end
