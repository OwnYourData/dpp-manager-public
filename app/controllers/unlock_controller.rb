# The way in. Everything else in the application sits behind this.
class UnlockController < ApplicationController
  skip_before_action :require_open_vault
  skip_before_action :enforce_idle_timeout

  layout "unlock"

  def show
    return redirect_to root_path if vault_open?

    @vault_exists = Vault::Store.exists?
    @interrupted  = session.dig(:resume, "action").present?
    @storage_problem = Vault::Store.storage_problem
  end

  # Creating and opening are the same button to the user — the application knows
  # which of the two it is by whether the file is there.
  def create
    if vault_open?
      redirect_to root_path
    elsif (problem = Vault::Store.storage_problem)
      storage_unusable(problem)
    elsif Vault::Store.exists?
      unlock
    else
      create_vault
    end
  rescue SQLite3::CantOpenException, SQLite3::ReadOnlyException, Errno::EACCES, Errno::EROFS
    # Between the check and the write the mount can still change under us.
    Vault::Store.close!
    storage_unusable(Vault::Store.storage_problem || [ :directory_not_writable,
                                                       { directory: Vault::Store.data_dir.to_s, uid: Process.euid } ])
  end

  # Locking on purpose forgets where unlocking would have led: whoever opens the
  # file next starts at the overview, not on the page somebody else left.
  def destroy
    Vault::Lifecycle.lock!(reason: "manual")
    reset_session
    redirect_to unlock_path, notice: t("vault.locked")
  end

  private

  def unlock
    if Vault::Lifecycle.unlock!(params[:passphrase].to_s)
      resume = session[:resume] || {}
      start_session
      resume_where_interrupted(resume)
    else
      @vault_exists = true
      @interrupted  = session.dig(:resume, "action").present?
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

  # Nothing on this page can work, and the message says why and where. 503,
  # because nothing is wrong with what was sent: the installation cannot store it.
  def storage_unusable(problem)
    @vault_exists = Vault::Store.exists?
    @interrupted  = session.dig(:resume, "action").present?
    @storage_problem = problem
    render :show, status: :service_unavailable
  end

  # Back to the page the lock interrupted. If it interrupted an action, the
  # page says so — the action was not carried out — and names the form it came
  # from, so the browser can put back what was typed into it.
  def resume_where_interrupted(resume)
    path = resume["path"].to_s
    path = root_path unless path.start_with?("/") && !path.start_with?("//")

    if resume["action"].present?
      flash[:alert] = t("vault.action_not_done_after_unlock")
      flash[:resume_action] = resume["action"]
    end
    redirect_to path
  end

  def start_session
    reset_session
    session[:last_seen_at] = Time.current.iso8601
  end
end
