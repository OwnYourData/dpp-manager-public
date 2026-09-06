# The identity after setup: showing it, exporting the keys, checking that they
# still work, and ending it.
class IdentitiesController < ApplicationController
  before_action :find_identity

  def show
    @export_path = export_filename
  end

  # Writes both keys into the mounted data directory, next to the vault.
  #
  # Not a browser download: the operator's browser Downloads folder is the wrong
  # place for the one secret that cannot be replaced, and on this machine the
  # data directory is a folder they already treat as theirs. It is still plain
  # text — that is what a key backup is — so the file says so in its own first
  # field.
  def export_keys
    path = Vault::Store.data_dir.join(export_filename)
    return fail_with(t("identity.export.exists", filename: export_filename)) if path.exist?

    path.write(JSON.pretty_generate(
      "WARNING" => "These keys are not encrypted. Whoever holds them is this identity.",
      "did" => @identity.did,
      "documentKey" => @identity.document_key,
      "revocationKey" => @identity.revocation_key,
      "revocationLog" => (JSON.parse(@identity.revocation_log) rescue @identity.revocation_log),
      "exportedAt" => Time.current.utc.iso8601
    ))
    path.chmod(0o600)

    Event.record!(:identity_keys_exported, did: @identity.did, filename: export_filename)
    redirect_to after_export_path, notice: t("identity.export.written", filename: export_filename)
  end

  # Signs a token and verifies it against the key the registry publishes. Proves
  # the whole chain the DPP Service will walk, without writing anything anywhere.
  def check_keys
    if Did::Token.self_test(@identity)
      redirect_to identity_path, notice: t("identity.check.ok")
    else
      fail_with(t("identity.check.failed"))
    end
  rescue Did::Oyd::Error => e
    fail_with(t("identity.check.unreachable", message: e.message))
  rescue StandardError => e
    fail_with(t("identity.check.failed_with", message: e.message))
  end

  private

  def find_identity
    @identity = Identity.current
    redirect_to setup_path if @identity.nil?
  end

  def export_filename
    "identity-#{@identity.short}-keys.json"
  end

  # Writing the key file is offered in two places, and the operator has to end
  # up back where they pressed it. During setup that matters more than
  # elsewhere: the keys are on screen exactly once, and being dropped onto
  # another page would take them away before they have been confirmed.
  def after_export_path
    @identity.keys_secured? ? identity_path : setup_path(step: "keys")
  end

  def fail_with(message)
    return redirect_to(setup_path(step: "keys"), alert: message) unless @identity.keys_secured?

    @export_path = export_filename
    flash.now[:alert] = message
    render :show, status: :unprocessable_entity
  end
end
