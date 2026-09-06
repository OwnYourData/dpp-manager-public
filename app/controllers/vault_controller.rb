# Everything that is about the file itself rather than about its contents:
# changing the passphrase and taking a backup copy.
class VaultController < ApplicationController
  def show
    @backups = existing_backups
  end

  def change_passphrase
    current = params[:current_passphrase].to_s
    fresh   = params[:new_passphrase].to_s
    confirm = params[:new_passphrase_confirmation].to_s

    if fresh.length < Vault::Passphrase::MINIMUM_LENGTH
      return fail_with(t("vault.passphrase_too_short", count: Vault::Passphrase::MINIMUM_LENGTH))
    end
    return fail_with(t("vault.passphrase_mismatch")) if fresh != confirm

    begin
      Vault::Store.change_passphrase!(current, fresh)
    rescue Vault::LockedError
      return fail_with(t("vault.wrong_current_passphrase"))
    end

    Event.record!(:passphrase_changed, kdf_profile: Vault::Session.profile)
    redirect_to vault_path, notice: t("vault.passphrase_changed")
  end

  def backup
    name = "dpp-#{Time.current.utc.strftime('%Y%m%d-%H%M%S')}.db"
    path = Vault::Store.data_dir.join(name)

    Vault::Store.backup!(path)
    Event.record!(:backup_created, filename: name)
    redirect_to vault_path, notice: t("vault.backup_created", filename: name)
  rescue StandardError => e
    fail_with(t("vault.backup_failed", message: e.message))
  end

  private

  def fail_with(message)
    @backups = existing_backups
    flash.now[:alert] = message
    render :show, status: :unprocessable_entity
  end

  def existing_backups
    Dir.glob(Vault::Store.data_dir.join("dpp-*.db")).sort.reverse.map do |file|
      { name: File.basename(file), size: File.size(file), modified_at: File.mtime(file) }
    end
  end
end
