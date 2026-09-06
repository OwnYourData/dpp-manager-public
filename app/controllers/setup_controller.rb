# The setup wizard: the DPP Service, the operator's identity, and optionally a
# custodian.
#
# The step is derived from what is actually configured rather than kept in the
# session. So a wizard interrupted by a lock, a restart or a closed browser
# picks up where it stopped, and there is no way to end up on a screen whose
# prerequisites are missing.
class SetupController < ApplicationController
  STEPS = %i[service identity keys custodian done].freeze

  def show
    @step = requested_step || current_step
    @identity = Identity.current
    render @step.to_s
  end

  # --- step 1: the DPP Service ----------------------------------------------

  def configure_service
    base = DppService::Directory.normalize_base(params[:service_base_url])
    return fail_with(:service, t("setup.service.invalid_url")) if base.nil?

    result = DppService::Directory.probe(base)
    unless result.reachable?
      return fail_with(:service, t("setup.service.errors.#{result.message}",
                                   default: t("setup.service.errors.unreachable")))
    end

    settings.update!(service_base_url: base, service_did: result.did,
                     service_audience: result.audience, service_checked_at: Time.current)
    Event.record!(:service_configured, base_url: base, did: result.did)
    redirect_to setup_path
  end

  # --- step 2: the identity --------------------------------------------------

  def mint_identity
    return redirect_to(setup_path) if Identity.current

    minted = Did::Oyd.mint
    identity = Identity.create!(did: minted[:did], origin: "minted",
                                label: params[:label].presence,
                                document_key: minted[:document_key],
                                revocation_key: minted[:revocation_key],
                                revocation_log: minted[:revocation_log])
    Event.record!(:identity_minted, did: identity.did)
    redirect_to setup_path(step: "keys")
  rescue Did::Oyd::Error => e
    fail_with(:identity, t("setup.identity.mint_failed", message: e.message))
  end

  def import_identity
    return redirect_to(setup_path) if Identity.current

    did = Did::Oyd.normalize(params[:did].to_s.strip)
    document_key = params[:document_key].to_s.strip
    revocation_key = params[:revocation_key].to_s.strip

    return fail_with(:identity, t("setup.identity.import_incomplete")) if did.blank? || document_key.blank?

    begin
      unless Did::Oyd.key_matches?(did, document_key)
        return fail_with(:identity, t("setup.identity.key_mismatch"))
      end
    rescue Did::Oyd::Error => e
      return fail_with(:identity, t("setup.identity.does_not_resolve", message: e.message))
    rescue StandardError
      return fail_with(:identity, t("setup.identity.key_unreadable"))
    end

    identity = Identity.new(did: did, origin: "imported", label: params[:label].presence,
                            document_key: document_key,
                            revocation_key: revocation_key.presence,
                            # Imported keys are by definition already somewhere
                            # else — that is where they were imported from.
                            keys_secured_at: Time.current)
    return fail_with(:identity, identity.errors.full_messages.to_sentence) unless identity.save

    Event.record!(:identity_imported, did: identity.did, revocable: identity.revocable?)
    redirect_to setup_path
  end

  # --- step 3: the keys ------------------------------------------------------

  def secure_keys
    identity = Identity.current
    return redirect_to(setup_path) if identity.nil? || identity.keys_secured?

    unless params[:confirmed] == "1"
      return fail_with(:keys, t("setup.keys.must_confirm"))
    end

    identity.update!(keys_secured_at: Time.current)
    Event.record!(:identity_keys_secured, did: identity.did)
    redirect_to setup_path
  end

  # --- step 4: the custodian -------------------------------------------------

  def configure_custodian
    if params[:skip] == "1"
      settings.update!(custodian_base_url: nil, custodian_collection_id: nil)
      return redirect_to(settings_path, notice: t("setup.custodian.cleared")) if settings.setup_complete?

      return complete!
    end

    # The named custodian's address comes from here rather than from the form:
    # somebody who picked it off the list did not type an address, and a typo in
    # a field they never looked at would be frozen into every identifier they
    # mint afterwards.
    chosen = params[:custodian_choice] == "known" ? Setting::KNOWN_CUSTODIAN[:base_url] : params[:custodian_base_url]
    base = DppService::Directory.normalize_base(chosen)
    collection = params[:custodian_collection_id].to_s.strip

    return fail_with(:custodian, t("setup.custodian.invalid_url")) if base.nil?
    return fail_with(:custodian, t("setup.custodian.collection_required")) if collection.blank?

    # The base URL ends up inside every passport DID's serviceEndpoint, where it
    # competes for the 50 characters the registry allows on a data carrier. Too
    # long here means unprintable identifiers later, and by then the DID is
    # minted and the endpoint frozen.
    if base.length > 35
      return fail_with(:custodian, t("setup.custodian.too_long", count: base.length))
    end

    settings.update!(custodian_base_url: base, custodian_collection_id: collection)
    Event.record!(:custodian_configured, base_url: base, collection_id: collection)

    # Changing this later is an ordinary edit, not the end of the setup: it
    # belongs back where it was opened from, with a sentence saying what it does
    # and does not affect.
    return redirect_to(settings_path, notice: t("setup.custodian.changed")) if settings.setup_complete?

    complete!
  end

  private

  def complete!
    settings.update!(setup_completed_at: Time.current) unless settings.setup_complete?
    Event.record!(:setup_completed)
    redirect_to root_path, notice: t("setup.done.finished")
  end

  def current_step
    return :service  unless settings.service_configured?
    return :identity unless Identity.current
    return :keys     unless Identity.current.keys_secured?
    return :custodian unless settings.setup_complete?

    :done
  end

  def requested_step
    step = params[:step]&.to_sym
    return nil unless STEPS.include?(step)
    # Only backwards, or to where we already are. Skipping ahead would land on a
    # screen whose prerequisites do not exist yet.
    return nil if STEPS.index(step) > STEPS.index(current_step)

    step
  end

  def fail_with(step, message)
    @step = step
    @identity = Identity.current
    flash.now[:alert] = message
    render step.to_s, status: :unprocessable_entity
  end
end
