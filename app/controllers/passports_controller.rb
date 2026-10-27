# Filling in a passport.
#
# The form itself is not rendered here: it is soya-form, in a frame, driven by
# the structure the operator imported. What this controller does is choose the
# type, hold the answers, and check them — the checking through soya-web-cli,
# because a validation this application wrote itself would be a second opinion
# about a structure that already has one.
class PassportsController < ApplicationController
  # Enough to act on, not so many that the message becomes a wall.
  SHOWN_PROBLEMS = 8

  helper_method :mint_endpoint_base, :storage_base, :identifier_suggestion, :unserved_identifier_host

  before_action :find_passport,
                only: %i[edit update destroy mint keys secure_keys export_keys
                         submit correct attest retire renew_delegation check_delegation
                         move_custody finish_move apply_access_policy access_policy sign]
  before_action :require_product_type, only: %i[new create]
  before_action :refresh_carrier_hosts, only: :new

  def index
    @passports = Passport.includes(:product_type).all
    @product_types = ProductType.fetched
    @awaiting_signature = Identity.current ? Passport.awaiting_signature.count : 0
  end

  def new
    # The granularity the product type prescribes is the starting point; the
    # identifier's path still has the last word as it is typed.
    @passport = Passport.new(product_type: @product_type, granularity: @product_type.granularity)
  end

  def create
    @passport = Passport.new(permitted.merge(product_type: @product_type))
    save_and_redirect(@passport, t("passports.created"))
  end

  def edit
    @product_type = @passport.product_type
  end

  def update
    @product_type = @passport.product_type
    @passport.assign_attributes(permitted)
    save_and_redirect(@passport, t("passports.saved"))
  end

  def destroy
    # A minted passport is not only here any more: its DID is published in the
    # registry, and deleting the row takes its keys with it — after which nobody
    # can ever revoke that identifier. Ending it properly comes first; once the
    # identifier is revoked the keys are spent and the row is only a record.
    if @passport.minted? && !@passport.revoked?
      return redirect_to(edit_passport_path(@passport), alert: t("passports.remove.minted"))
    end

    label = @passport.label
    @passport.destroy
    redirect_to passports_path, notice: t("passports.removed", label: label)
  end

  # --- the passport's own DID -------------------------------------------------

  # Minting is the first step that leaves this machine: the document and its log
  # are published to the registry and the identifier is from then on real.
  #
  # Two things are decided here and cannot be decided again. The product
  # identifier goes into the endpoint, so the envelope has to be finished first;
  # and the endpoint's host is compared by the DPP Service against where the
  # passport is submitted, so where this passport will live has to be settled
  # before it has a name.
  def mint
    return redirect_to(edit_passport_path(@passport), alert: t("passports.mint.already")) if @passport.minted?

    unless @passport.envelope_complete?
      return redirect_to(edit_passport_path(@passport), alert: t("passports.mint.envelope_first"))
    end

    base = mint_endpoint_base
    return redirect_to(edit_passport_path(@passport), alert: t("passports.mint.no_endpoint")) if base.blank?

    @passport.mint!(endpoint_base: base,
                    collection_id: (settings.custodian_collection_id if settings.custodian_configured?))
    Event.record!(:passport_minted, passport: @passport.label, did: @passport.dpp_id,
                                    product_id: @passport.unique_product_identifier, endpoint_base: base)
    redirect_to keys_passport_path(@passport)
  rescue Did::Oyd::Error, ActiveRecord::RecordInvalid => e
    Event.record!(:passport_mint_failed, passport: @passport.label, message: e.message)
    redirect_to edit_passport_path(@passport), alert: t("passports.mint.failed", message: e.message)
  end

  # The one screen the two keys appear on. After they are confirmed it shows the
  # DID and says where they went instead.
  def keys
    return redirect_to(edit_passport_path(@passport), alert: t("passports.mint.not_minted")) unless @passport.minted?

    @key = @passport.passport_key
    @export_path = export_filename
  end

  def secure_keys
    if @passport.passport_key.nil? || @passport.keys_secured?
      return redirect_to(edit_passport_path(@passport))
    end

    unless params[:confirmed] == "1"
      return redirect_to(keys_passport_path(@passport), alert: t("passports.keys.must_confirm"))
    end

    @passport.passport_key.update!(keys_secured_at: Time.current)
    Event.record!(:passport_keys_secured, passport: @passport.label, did: @passport.dpp_id)
    redirect_to edit_passport_path(@passport), notice: t("passports.keys.secured")
  end

  # Written next to the vault, not into the browser's Downloads folder — the
  # same reasoning as for the identity's keys, and the same warning inside the
  # file: this is plain text, because that is what a key backup is.
  def export_keys
    key = @passport.passport_key
    return redirect_to(passports_path, alert: t("passports.mint.not_minted")) if key.nil?

    path = Vault::Store.data_dir.join(export_filename)
    if path.exist?
      return redirect_to(keys_passport_path(@passport), alert: t("identity.export.exists", filename: export_filename))
    end

    path.write(JSON.pretty_generate(
      "WARNING" => "These keys are not encrypted. Whoever holds them controls this passport's identifier.",
      "did" => @passport.dpp_id,
      "uniqueProductIdentifier" => @passport.unique_product_identifier,
      "serviceEndpoint" => @passport.service_endpoint,
      "documentKey" => key.document_key,
      "revocationKey" => key.revocation_key,
      "revocationLog" => (JSON.parse(key.revocation_log) rescue key.revocation_log),
      "exportedAt" => Time.current.utc.iso8601
    ))
    path.chmod(0o600)

    Event.record!(:passport_keys_exported, passport: @passport.label, did: @passport.dpp_id,
                                           filename: export_filename)
    redirect_to keys_passport_path(@passport), notice: t("identity.export.written", filename: export_filename)
  end

  # --- handing the passport to the service ------------------------------------

  # CreateDPP. The last step, and the one after which the passport is somebody
  # else's to serve.
  #
  # Everything that can be refused is refused here rather than at the service,
  # because the two failures that matter are unrepairable: a DID whose endpoint
  # names a different host than the service being handed it, and a submission
  # made twice under one identifier.
  def submit
    return submit_refused(t("passports.submit.already")) if @passport.submitted?
    return submit_refused(t("passports.mint.not_minted")) unless @passport.minted?
    return submit_refused(t("passports.submit.no_service")) unless settings.service_configured?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base = settings.service_base_url

    if @passport.custodial? && settings.custodian_base_url.blank?
      return submit_refused(t("passports.custody.no_custodian"))
    end

    # Where this passport will be kept is not the same question as where the
    # submission is sent. A custodial passport is handed to the service, which
    # then writes it into the custodian named in the mandate — and the service
    # compares the DID's endpoint against the custodian, not against itself.
    unless @passport.endpoint_agrees_with?(storage_base)
      return submit_refused(t("passports.submit.endpoint_mismatch",
                              endpoint: @passport.endpoint_host, service: storage_base))
    end

    return if refused_for_problems?(:submit)

    # Before anything is signed: a policy the service does not take is a
    # passport that must not go out public instead.
    policy_id = ensure_access_policy(base)
    return if performed?

    mandate = @passport.custodial? ? sign_mandate : nil
    return if performed?

    document     = Dpp::Document.build(@passport)
    retain_until = @passport.retention_deadline
    result       = DppService::Client.create(document,
                                             base_url: base,
                                             token: Did::Token.bearer(Identity.current,
                                                                      audience: settings.service_audience),
                                             storage: custody_header(mandate),
                                             retain_until: retain_until,
                                             **access_policy_header(policy_id))

    unless result.ok?
      Event.record!(:passport_submit_failed, passport: @passport.label, did: @passport.dpp_id,
                                             status: result.http_status, problems: result.problems)
      return service_refused(result)
    end

    @passport.record_submission!(result.document, base_url: base, retain_until: retain_until)
    @passport.record_access_policy!(result.access_policy, policy_id) if policy_id

    if mandate
      @passport.record_delegation!(mandate)
      Event.record!(:passport_delegated, passport: @passport.label, did: @passport.dpp_id,
                                         custodian: storage_base, collection: @passport.custodian_collection_id,
                                         jti: mandate.jti, expires_at: mandate.expires_at.iso8601)
    end

    attested = attest_payload(result.commitment)

    Event.record!(:passport_submitted, passport: @passport.label, did: @passport.dpp_id, service: base,
                                       **sent_despite_problems)
    signed = sign_after_write(result, base)
    notice = mandate ? t("passports.custody.submitted", custodian: storage_base) : t("passports.submit.done")
    notice = [ notice, access_policy_note(result.access_policy, policy_id) ].compact.join(" ")
    notice = "#{notice} #{t('passports.attest.waiting')}" if attested == false
    notice = [ notice, signature_note(signed) ].compact.join(" ")
    redirect_to edit_passport_path(@passport), notice: notice
  rescue Did::Oyd::Error => e
    submit_refused(t("passports.submit.token_failed", message: e.message))
  rescue Dpp::Document::Error => e
    submit_refused(t("passports.submit.document_failed", reason: reason_for(e)))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # Sending a correction to a passport the service already holds.
  #
  # A separate action from submitting, and deliberately so: the operator has to
  # say that the change should leave this machine. Saving a corrected answer is
  # a local act — they may be halfway through — and an application that pushed
  # every keystroke to a public record would be making a decision that is theirs.
  def correct
    return submit_refused(t("passports.correct.not_submitted")) unless @passport.submitted?
    return submit_refused(t("passports.custody.expired_first")) if mandate_stale?
    return submit_refused(t("passports.correct.nothing_to_send")) unless @passport.differs_from_service?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base = @passport.submitted_to.presence || settings.service_base_url
    return submit_refused(t("passports.submit.no_service")) if base.blank?
    return if refused_for_problems?(:correct)

    # A correction carries the type's current policy along: the passport is
    # classified by the version in force when it was last written.
    policy_id = ensure_access_policy(base)
    return if performed?

    patch  = Dpp::Document.correction(@passport)
    result = DppService::Client.update(patch,
                                       base_url: base, dpp_id: @passport.dpp_id,
                                       token: Did::Token.bearer(Identity.current,
                                                                audience: settings.service_audience),
                                       **access_policy_header(policy_id))

    unless result.ok?
      Event.record!(:passport_update_failed, passport: @passport.label, did: @passport.dpp_id,
                                             status: result.http_status, problems: result.problems)
      return service_refused(result)
    end

    @passport.record_correction!(result.document)
    @passport.record_access_policy!(result.access_policy, policy_id) if policy_id
    attested = attest_payload(result.commitment)

    Event.record!(:passport_updated, passport: @passport.label, did: @passport.dpp_id, service: base,
                                     **sent_despite_problems)
    signed = sign_after_write(result, base)
    notice = [ t("passports.correct.done"), access_policy_note(result.access_policy, policy_id) ].compact.join(" ")
    notice = "#{notice} #{t('passports.attest.waiting')}" if attested == false
    notice = [ notice, signature_note(signed) ].compact.join(" ")
    redirect_to edit_passport_path(@passport), notice: notice
  rescue Did::Oyd::Error => e
    submit_refused(t("passports.submit.token_failed", message: e.message))
  rescue Dpp::Document::Error => e
    submit_refused(t("passports.submit.document_failed", reason: reason_for(e)))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # --- the access policy ------------------------------------------------------

  # Classifying a passport the service already holds by the type's current
  # policy: UpdateDPP with an empty merge patch and the policy's id, so nothing
  # of the document changes but who may read which part of it.
  #
  # Not part of a correction, and not a correction itself: the answers here may
  # be half-edited, and sending a new policy must not send them along. The
  # public part changes with the classification, so the payload is attested
  # again as after any write.
  def apply_access_policy
    type = @passport.product_type
    return submit_refused(t("passports.access_policy.not_submitted")) unless @passport.submitted?
    return submit_refused(t("passports.retired.not_served")) if @passport.retired?
    return submit_refused(t("passports.access_policy.off")) unless type&.access_policy_enabled?
    return submit_refused(t("passports.custody.expired_first")) if mandate_stale?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base = @passport.submitted_to.presence || settings.service_base_url
    return submit_refused(t("passports.submit.no_service")) if base.blank?

    policy_id = ensure_access_policy(base)
    return if performed?

    result = DppService::Client.update({}, base_url: base, dpp_id: @passport.dpp_id,
                                           token: Did::Token.bearer(Identity.current,
                                                                    audience: settings.service_audience),
                                           access_policy: policy_id)

    unless result.ok?
      Event.record!(:passport_access_policy_failed, passport: @passport.label, did: @passport.dpp_id,
                                                    policy: policy_id, status: result.http_status,
                                                    problems: result.problems)
      return service_refused(result)
    end

    @passport.record_access_policy!(result.access_policy, policy_id)
    @passport.update!(service_document: JSON.generate(result.document)) if result.document.present?
    attested = attest_payload(result.commitment)

    Event.record!(:passport_access_policy_applied, passport: @passport.label, did: @passport.dpp_id,
                                                   policy: policy_id, service: base)
    signed = sign_after_write(result, base)
    notice = [ t("passports.access_policy.applied"), access_policy_note(result.access_policy, policy_id) ].join(" ")
    notice = "#{notice} #{t('passports.attest.waiting')}" if attested == false
    notice = [ notice, signature_note(signed) ].compact.join(" ")
    redirect_to edit_passport_path(@passport), notice: notice
  rescue Did::Oyd::Error => e
    submit_refused(t("passports.submit.token_failed", message: e.message))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # The lists behind the counts: which attributes of the passport no rule
  # reaches, and which rules reach nothing. Asked of the service, which is the
  # only one that sees the passport as it stands there.
  def access_policy
    unless @passport.submitted? && @passport.access_policy_id.present?
      return redirect_to(edit_passport_path(@passport), alert: t("passports.access_policy.none"))
    end
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base = @passport.submitted_to.presence || settings.service_base_url
    result = DppService::Client.read_access_policy(base_url: base, dpp_id: @passport.dpp_id,
                                                   token: Did::Token.bearer(Identity.current,
                                                                            audience: settings.service_audience))
    unless result.ok?
      return redirect_to(edit_passport_path(@passport),
                         alert: t("passports.submit.refused", status: result.http_status,
                                                              problems: result.problems.join(" · ")))
    end

    @details = result.document || {}
  rescue Did::Oyd::Error => e
    redirect_to edit_passport_path(@passport), alert: t("passports.submit.token_failed", message: e.message)
  rescue DppService::Client::Error => e
    redirect_to edit_passport_path(@passport), alert: t("passports.submit.unreachable", message: reason_for(e))
  end

  # --- the mandate the custodian holds ----------------------------------------

  # A fresh mandate for a passport somebody else is holding.
  #
  # A mandate has a lifetime and a passport does not, so this is an ordinary
  # act rather than an exception: ninety days after it was signed, the one the
  # service holds stops being redeemable while the passport goes on being
  # updated and, eventually, ended. Only the operator can sign the next one.
  #
  # The service takes a token with the fresh mandate before it replaces the one
  # in place, so a mandate that turns out not to work leaves the working one
  # alone. This end records what was signed only once the service confirms it,
  # for the same reason.
  def renew_delegation
    return submit_refused(t("passports.custody.not_custodial")) unless @passport.custodial?
    return submit_refused(t("passports.custody.not_submitted")) unless @passport.submitted?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    mandate = sign_mandate
    return if performed?

    base   = @passport.submitted_to.presence || settings.service_base_url
    result = DppService::Client.renew_delegation(
      base_url: base, dpp_id: @passport.dpp_id, storage: custody_header(mandate),
      token: Did::Token.bearer(Identity.current, audience: settings.service_audience)
    )

    unless result.ok?
      Event.record!(:passport_delegation_failed, passport: @passport.label, did: @passport.dpp_id,
                                                 status: result.http_status, problems: result.problems)
      return redirect_to(edit_passport_path(@passport),
                         alert: t("passports.submit.refused", status: result.http_status,
                                                              problems: result.problems.join(" · ")))
    end

    @passport.record_delegation!(mandate)
    Event.record!(:passport_delegation_renewed, passport: @passport.label, did: @passport.dpp_id,
                                                jti: mandate.jti, expires_at: mandate.expires_at.iso8601)
    redirect_to edit_passport_path(@passport),
      notice: t("passports.custody.renewed", date: l(mandate.expires_at.in_time_zone, format: :short))
  rescue Did::Oyd::Error, Did::Delegation::Error => e
    submit_refused(t("passports.custody.sign_failed", message: e.message))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # Handing this passport to a different custodian.
  #
  # The exit, and the reason the whole mandate construction is worth its cost:
  # the operator can take their passports elsewhere without asking anybody's
  # permission, because the authority the current custodian holds is one signed
  # sentence about one passport, and a new sentence can be written at any time.
  #
  # Two acts, in this order. The service moves the document first, while the
  # identifier still names the old custodian — who goes on serving, so at no
  # moment is the passport unreadable. Then the identifier follows. The reverse
  # order would point the world at a host that does not have the passport yet.
  def move_custody
    return submit_refused(t("passports.custody.not_custodial")) unless @passport.custodial?
    return submit_refused(t("passports.custody.not_submitted")) unless @passport.submitted?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?
    return submit_refused(t("passports.custody.finish_first")) if @passport.move_unfinished?

    destination = new_custodian or return
    mandate = sign_mandate(audience: destination[:base_url], collection: destination[:collection_id])
    return if performed?

    base   = @passport.submitted_to.presence || settings.service_base_url
    result = DppService::Client.move_custody(
      base_url: base, dpp_id: @passport.dpp_id, storage: {
        base_url: destination[:base_url], collection_id: destination[:collection_id],
        delegation: mandate.token
      },
      release_previous: params[:release_previous] == "1",
      token: Did::Token.bearer(Identity.current, audience: settings.service_audience)
    )

    unless result.ok?
      Event.record!(:passport_custody_move_failed, passport: @passport.label, did: @passport.dpp_id,
                                                   status: result.http_status, problems: result.problems)
      return service_refused(result, resume: move_custody_passport_path(@passport),
                                     custodian: destination[:base_url], collection: destination[:collection_id])
    end

    @passport.record_custody_move!(base_url: destination[:base_url],
                                   collection_id: destination[:collection_id], signed: mandate)
    Event.record!(:passport_custody_moved, passport: @passport.label, did: @passport.dpp_id,
                                           custodian: destination[:base_url],
                                           collection: destination[:collection_id],
                                           released_previous: params[:release_previous] == "1")

    point_identifier_at_new_custodian
  rescue Did::Oyd::Error, Did::Delegation::Error => e
    submit_refused(t("passports.custody.sign_failed", message: e.message))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # The second half on its own, for when the first attempt got the document
  # moved and the identifier not. Nobody else can do this: the keys are here.
  def finish_move
    return submit_refused(t("passports.custody.nothing_to_finish")) unless @passport.move_unfinished?

    point_identifier_at_new_custodian
  end

  # What the service says it holds, next to what was signed here.
  #
  # Both records are the operator's own — they signed the mandate and they own
  # the passport — but they are kept in two places and can drift: a restore from
  # an older backup on either side is enough. The drift is otherwise silent, and
  # silent is the worst way for a mandate to be wrong.
  def check_delegation
    return submit_refused(t("passports.custody.not_custodial")) unless @passport.custodial?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base   = @passport.submitted_to.presence || settings.service_base_url
    result = DppService::Client.read_delegation(
      base_url: base, dpp_id: @passport.dpp_id,
      token: Did::Token.bearer(Identity.current, audience: settings.service_audience)
    )

    unless result.ok?
      # A service that has no such route answers a bare 404 with no Result
      # object in it, which is a different thing from "this passport is not held
      # by a custodian" — and it is not the operator's problem: nothing is wrong
      # with the mandate, there is simply nobody to ask.
      if result.http_status == 404 && result.problems == [ "HTTP 404" ]
        return redirect_to(edit_passport_path(@passport),
                           alert: t("passports.custody.check_unsupported", service: base))
      end

      return redirect_to(edit_passport_path(@passport),
                         alert: t("passports.submit.refused", status: result.http_status,
                                                              problems: result.problems.join(" · ")))
    end

    Event.record!(:passport_delegation_checked, passport: @passport.label, did: @passport.dpp_id,
                                                jti: result.document&.dig("jti"))
    redirect_to edit_passport_path(@passport), notice: comparison(result.document)
  rescue Did::Oyd::Error => e
    submit_refused(t("passports.submit.token_failed", message: e.message))
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
  end

  # --- ending a passport ------------------------------------------------------

  # The end of the product's life, in the order the two failures make necessary.
  #
  # First the service stops serving it — it archives the final state, so the
  # history survives. Then the identifier is revoked with the keys kept here,
  # which the service cannot do: it holds no key for a DID it did not mint.
  #
  # That order and not the other way round. A revoked identifier while the
  # service still serves the passport means the world can read a document whose
  # identifier no longer resolves, and no reader can tell whether that is a
  # retired product or a forgery. The reverse — no longer served, identifier
  # still live — is merely unfinished, and this page offers to finish it.
  def retire
    return submit_refused(t("passports.retire.not_minted")) unless @passport.minted?
    return submit_refused(t("passports.retire.already")) if @passport.revoked?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?
    return submit_refused(t("passports.custody.expired_first")) if mandate_stale? && !@passport.retired?
    # The service refuses it anyway (ESPR Art. 9(2)(i)); said here first, in words.
    if @passport.retained_on? && !@passport.retired?
      return submit_refused(t("passports.retire.retained", date: l(@passport.retain_until)))
    end

    withdraw_from_service or return
    revoke_identifier
  end

  # Attesting after the fact.
  #
  # Normally this happens as part of submitting: the service reports the hash and
  # the entry is written in the same request. This is the way back for a passport
  # that was left waiting — the registry was unreachable, or the passport was
  # submitted before the service reported a hash at all. It exists because the
  # service cannot do it instead: only the document key in this vault can sign
  # that entry.
  def attest
    return submit_refused(t("passports.attest.nothing")) if @passport.payload_hash.blank?

    if @passport.payload_attested?
      return redirect_to(edit_passport_path(@passport), notice: t("passports.attest.already"))
    end

    if write_payload_attestation
      redirect_to edit_passport_path(@passport), notice: t("passports.attest.done")
    else
      redirect_to edit_passport_path(@passport),
                  alert: t("passports.attest.failed", message: @attestation_message)
    end
  end

  # --- the signature of the economic operator -------------------------------
  #
  # A passport the DPP Service keeps in its own database is signed by the
  # economic operator after every write: the service delivers it, and the
  # signature says who stands behind what it delivers (dpp-service
  # docs/Integrity.md section 10). This application does it on its own after
  # submitting, correcting and classifying; the action here is for a passport
  # whose signature did not go through then, or that was never signed.
  #
  # A custodian serves its passports itself, and the DPP Service takes no
  # signature for them; the page says so instead of offering one.
  def sign
    return submit_refused(t("passports.signature.not_submitted")) unless @passport.submitted?
    return submit_refused(t("passports.retired.not_served")) if @passport.retired?
    return submit_refused(t("passports.signature.custodial")) if @passport.custodial?
    return submit_refused(t("passports.submit.no_identity")) if Identity.current.nil?

    base = @passport.submitted_to.presence || settings.service_base_url
    return submit_refused(t("passports.submit.no_service")) if base.blank?

    outcome = sign_passport(@passport, base)
    if outcome.ok?
      redirect_to edit_passport_path(@passport), notice: signature_note(outcome)
    else
      redirect_to edit_passport_path(@passport), alert: signature_note(outcome)
    end
  end

  # Every passport that should carry the signature and does not, signed in one
  # go: passports that were never signed, and those whose signature failed.
  # One after the other, each with its own answer.
  def sign_all
    return redirect_to(passports_path, alert: t("passports.submit.no_identity")) if Identity.current.nil?

    candidates = Passport.awaiting_signature.to_a
    return redirect_to(passports_path, notice: t("passports.signature.all_none")) if candidates.empty?

    failed = candidates.reject do |passport|
      sign_passport(passport, passport.submitted_to.presence || settings.service_base_url).ok?
    end

    notice = t("passports.signature.all_done", signed: candidates.size - failed.size, count: candidates.size)
    return redirect_to(passports_path, notice: notice) if failed.empty?

    redirect_to passports_path, notice: notice,
                                alert: t("passports.signature.all_failed", labels: failed.map(&:label).join(", "))
  end

  private

  # Returns true when the passport is no longer at the service — including the
  # case where it never was, and the one where a previous attempt already got
  # this far.
  def withdraw_from_service
    return true if @passport.retired?

    # Minted but never handed to anyone: there is nothing to withdraw, and the
    # only thing left of this passport out in the world is its identifier. The
    # row still records that the passport was ended, because it was.
    unless @passport.submitted?
      @passport.record_retirement!
      return true
    end

    base = @passport.submitted_to.presence || settings.service_base_url
    result = DppService::Client.delete(base_url: base, dpp_id: @passport.dpp_id,
                                       token: Did::Token.bearer(Identity.current,
                                                                audience: settings.service_audience))

    unless result.ok?
      Event.record!(:passport_retire_failed, passport: @passport.label, did: @passport.dpp_id,
                                             status: result.http_status, problems: result.problems)
      redirect_to edit_passport_path(@passport),
        alert: t("passports.submit.refused", status: result.http_status, problems: result.problems.join(" · "))
      return false
    end

    @passport.record_retirement!
    Event.record!(:passport_retired, passport: @passport.label, did: @passport.dpp_id, service: base)
    true
  rescue Did::Oyd::Error => e
    submit_refused(t("passports.submit.token_failed", message: e.message))
    false
  rescue DppService::Client::Error => e
    submit_refused(t("passports.submit.unreachable", message: reason_for(e)))
    false
  end

  # The second half, and the one nobody else can do. A failure here leaves the
  # passport withdrawn but its identifier still live, which the page says and
  # offers to finish — the keys are still in the vault, so it can be finished.
  def revoke_identifier
    key = @passport.passport_key
    return retire_incomplete(t("passports.retire.no_keys")) if key.nil? || key.revocation_key.blank?

    Did::Oyd.revoke(@passport.dpp_id, document_key: key.document_key, revocation_key: key.revocation_key)
    @passport.record_revocation!
    Event.record!(:passport_revoked, passport: @passport.label, did: @passport.dpp_id)

    redirect_to edit_passport_path(@passport), notice: t("passports.retire.done")
  rescue Did::Oyd::Error, StandardError => e
    retire_incomplete(t("passports.retire.revoke_failed", message: e.message))
  end

  def retire_incomplete(message)
    Event.record!(:passport_revoke_failed, passport: @passport.label, did: @passport.dpp_id, message: message)
    redirect_to edit_passport_path(@passport), alert: message
  end

  # Move the passport's own identifier to the custodian that now holds it.
  #
  # The half nobody else can do, and the one that has to be finishable: a
  # failure here leaves the document at the new custodian under an identifier
  # that still names the old one, which is the only state in this sequence a
  # reader would notice.
  # --- attesting the payload (EN 18246:2026, variant B) ------------------------
  #
  # The service computes the hash of the payload the custodian delivers and
  # reports it in a header, but it holds no document key and cannot sign the log
  # entry that commits to it. This is where that entry is written, with the two
  # secrets that never leave this machine — which is the whole of the argument
  # that the custodian cannot change a passport unnoticed.
  #
  # Best effort on purpose. The passport is already with the service; a registry
  # that cannot be reached must not turn a successful submission into a failure.
  # What is left behind is a passport that says it is waiting.
  #
  # Returns nil when there was nothing to attest, true when the entry is
  # published, false when it was tried and did not work.
  def attest_payload(commitment)
    return nil if commitment.nil? || commitment.payload_hash.blank?

    @passport.record_payload_expected!(commitment.payload_hash)

    # Already attested — by this machine on an earlier attempt, or by a service
    # that holds the document key itself. Either way the document commits to this
    # payload, and saying "waiting" about it would be wrong.
    if commitment.committed?
      @passport.record_payload_committed! unless @passport.payload_attested?
      return nil
    end
    return nil unless commitment.pending?

    write_payload_attestation
  end

  def write_payload_attestation
    key = @passport.passport_key
    return attestation_failed(t("passports.attest.no_keys")) if key.nil? || key.document_key.blank?

    written = Did::Oyd.commit_payload(@passport.dpp_id,
                                     payload_hash:   @passport.payload_hash,
                                     document_key:   key.document_key,
                                     revocation_key: key.revocation_key)
    @passport.record_payload_committed!(written && written[:revocation_log])
    Event.record!(:passport_payload_attested, passport: @passport.label, did: @passport.dpp_id,
                                              payload_hash: @passport.payload_hash)
    true
  rescue Did::Oyd::Error, ActiveRecord::RecordInvalid => e
    attestation_failed(e.message)
  end

  def attestation_failed(message)
    @attestation_message = message
    Event.record!(:passport_payload_attestation_failed, passport: @passport.label,
                                                        did: @passport.dpp_id, message: message)
    false
  end

  def point_identifier_at_new_custodian
    # A move within one custodian — another collection at the same pod — leaves
    # the endpoint exactly as it was. Writing it again would publish a new
    # document to the registry that says the same thing, and every registry
    # write is one more thing that can fail.
    if @passport.pending_endpoint_base == @passport.endpoint_base
      @passport.record_endpoint_moved!
      return redirect_to(edit_passport_path(@passport),
                         notice: t("passports.custody.moved", custodian: @passport.endpoint_base))
    end

    key = @passport.passport_key
    return move_incomplete(t("passports.custody.no_keys")) if key.nil? || key.document_key.blank?

    moved = Did::Oyd.move_endpoint(@passport.dpp_id,
                                   product_id:     @passport.unique_product_identifier,
                                   endpoint_base:  @passport.pending_endpoint_base,
                                   document_key:   key.document_key,
                                   revocation_key: key.revocation_key)

    @passport.record_endpoint_moved!(moved[:revocation_log])
    Event.record!(:passport_endpoint_moved, passport: @passport.label, did: @passport.dpp_id,
                                            endpoint_base: @passport.endpoint_base)
    redirect_to edit_passport_path(@passport),
      notice: t("passports.custody.moved", custodian: @passport.endpoint_base)
  rescue Did::Oyd::Error, ActiveRecord::RecordInvalid => e
    move_incomplete(t("passports.custody.endpoint_failed", message: e.message))
  end

  def move_incomplete(message)
    Event.record!(:passport_endpoint_move_failed, passport: @passport.label, did: @passport.dpp_id,
                                                  message: message)
    redirect_to edit_passport_path(@passport), alert: message
  end

  # Where the passport is to go. Normalised the way every other address in this
  # application is, and refused rather than guessed at when it is not usable.
  def new_custodian
    base = DppService::Directory.normalize_base(params[:custodian_base_url])
    collection = params[:custodian_collection_id].to_s.strip

    return submit_refused(t("setup.custodian.invalid_url")) && nil if base.nil?
    return submit_refused(t("setup.custodian.collection_required")) && nil if collection.blank?

    if base == storage_base.to_s && collection == @passport.custodian_collection_id.to_s
      return submit_refused(t("passports.custody.already_there")) && nil
    end

    { base_url: base, collection_id: collection }
  end

  # The mandate, signed here and now. Returns nil after redirecting when
  # something it needs is missing — the caller checks `performed?`, because
  # every one of these is a sentence the operator has to act on rather than an
  # error to pass through.
  #
  # The custodian is an argument rather than read from the settings: a handover
  # signs a mandate for somewhere the settings do not name yet, and a mandate
  # that quietly named the old place would be redeemable and useless.
  def sign_mandate(audience: storage_base, collection: custody_collection)
    if settings.service_did.blank?
      submit_refused(t("passports.custody.no_service_did", service: settings.service_base_url))
      return nil
    end

    Did::Delegation.issue(
      Identity.current,
      audience:    audience,
      collection:  collection,
      product_id:  @passport.unique_product_identifier,
      service_did: settings.service_did
    )
  rescue Did::Delegation::Error => e
    submit_refused(t("passports.custody.sign_failed", message: e.message))
    nil
  end

  # A custodian is holding this passport under a mandate that has run out, so
  # the service can no longer write there. It would find that out at the pod and
  # answer with an OAuth code; saying it here means the operator is told what to
  # do instead of what happened.
  def mandate_stale?
    @passport.custodial? && @passport.delegated? && @passport.delegation_expired?
  end

  def custody_header(mandate)
    return nil if mandate.nil?

    { base_url: storage_base, collection_id: custody_collection, delegation: mandate.token }
  end

  # Where this passport is to be kept: the custodian for a custodial one, the
  # service itself otherwise.
  #
  # From the settings rather than from the passport's own endpoint, and that is
  # the whole point of the comparison it feeds: the endpoint was frozen into the
  # DID at minting, and if the custodian has been changed since, the passport
  # must be refused rather than quietly handed to somewhere its own identifier
  # does not name. Comparing the endpoint with itself would always agree.
  def storage_base
    return settings.service_base_url unless @passport.custodial?

    # Once a handover has been recorded, the custodian is the one the service
    # moved the passport to — the settings still name whichever one this
    # installation creates new passports at, and that is a different question.
    @passport.pending_endpoint_base.presence ||
      (@passport.submitted? ? @passport.endpoint_base.presence : nil) ||
      settings.custodian_base_url
  end

  # The place in the custodian's store. The passport's own record once it has
  # been submitted — that is what the service holds a mandate for. Before then
  # the settings still win, so a collection corrected after minting is picked up
  # rather than frozen into a passport that was never handed over.
  def custody_collection
    return @passport.custodian_collection_id if @passport.submitted?

    settings.custodian_collection_id.presence || @passport.custodian_collection_id
  end

  # What the service holds, said in a sentence rather than shown as a record.
  # The jti is the whole comparison: it is unique per mandate and it is the
  # handle a mandate is revoked by.
  def comparison(document)
    claims = document.is_a?(Hash) ? document : {}
    expires = Time.at(claims["exp"].to_i).utc if claims["exp"].present?

    if @passport.delegation_matches?(claims)
      t("passports.custody.in_step", date: expires ? l(expires.in_time_zone, format: :short) : "—")
    elsif claims["jti"].present?
      t("passports.custody.differs", jti: claims["jti"],
                                     date: expires ? l(expires.in_time_zone, format: :short) : "—")
    else
      t("passports.custody.service_holds_nothing")
    end
  end

  # The id of the type's policy, registered with +base+, or nil when the type
  # has none switched on. When the service does not take it, the write is
  # refused here with the service's own sentence and nil comes back with the
  # response already rendered.
  def ensure_access_policy(base)
    DppService::AccessPolicyRegistration.ensure!(@passport.product_type, base_url: base,
                                                                        audience: settings.service_audience)
  rescue DppService::AccessPolicyRegistration::Error => e
    reason = e.problems.any? ? e.problems.join(" · ") : t("passports.access_policy.reasons.#{e.message}")
    submit_refused(t("passports.access_policy.not_registered", reason: reason))
    nil
  end

  # Only when there is a policy: a passport without one is written exactly as
  # before, and a client stub that knows nothing about policies still fits.
  def access_policy_header(policy_id)
    policy_id ? { access_policy: policy_id } : {}
  end

  # One sentence about how the policy fits the passport, from the counts the
  # service reported.
  def access_policy_note(report, policy_id)
    return nil if policy_id.nil?
    return t("passports.access_policy.sent") if report.nil?

    t("passports.access_policy.report", unclassified: report.unclassified.to_i, unused: report.unused_rules.to_i)
  end

  # A refusal of the service, back on the passport's page. The one only the
  # custodian can resolve -- no reader of the service entered for the
  # collection -- is said in the operator's language, with the reader to pass
  # on (shared/reader_missing); every other one as the service put it. The
  # reader is the one the refusal names, or else the one the service publishes
  # for that custodian. +custodian+ and +collection+ are where the write was to
  # go. +resume+ names the form whose values the browser puts back
  # (ResumeController), so a refused handover does not cost the operator what
  # they typed.
  def service_refused(result, resume: nil, custodian: storage_base, collection: custody_collection)
    flash[:resume_action] = resume if resume
    missing = DppService::Client.reader_missing(result, custodian: custodian, collection: collection)
    if missing
      missing.reader_did ||= DppService::Directory.reader_for(@passport.submitted_to.presence ||
                                                                settings.service_base_url, missing.custodian)
      flash[:reader_missing] = missing.to_h.transform_keys(&:to_s) if missing.reader_did
      alert = missing.reader_did ? "passports.reader_missing.alert" : "passports.reader_missing.alert_without_reader"
      return redirect_to(edit_passport_path(@passport),
                         alert: t(alert, custodian: missing.custodian, collection: missing.collection))
    end

    redirect_to(edit_passport_path(@passport),
                alert: t("passports.submit.refused", status: result.http_status,
                                                     problems: result.problems.join(" · ")))
  end

  def submit_refused(message)
    Event.record!(:passport_submit_failed, passport: @passport.label, did: @passport.dpp_id, problems: [ message ])
    redirect_to edit_passport_path(@passport), alert: message
  end

  # After a write: what the service now says about the signature, and the
  # signature itself where the service keeps the passport. A service that
  # reports no state knows no signature of the economic operator, and is not
  # asked for one.
  #
  # Best effort, like the attestation: the write is done, and a signature that
  # cannot be handed in must not turn it into a failure. The passport then
  # says that it waits, and offers to sign again.
  def sign_after_write(result, base)
    return nil if @passport.custodial? || result.signature_state.blank?

    @passport.record_signature_state!(result.signature_state)
    sign_passport(@passport, base)
  end

  def sign_passport(passport, base)
    outcome = DppService::OperatorSigning.call(base_url: base, dpp_id: passport.dpp_id,
                                               identity: Identity.current,
                                               audience: settings.service_audience)
    record_signature(passport, outcome)
  rescue DppService::Client::Error => e
    record_signature(passport, DppService::OperatorSigning::Outcome.new(ok: false, warnings: [],
                                                                        problems: [ reason_for(e) ]))
  rescue Did::Oyd::Error => e
    record_signature(passport, DppService::OperatorSigning::Outcome.new(ok: false, warnings: [],
                                                                        problems: [ e.message ]))
  end

  def record_signature(passport, outcome)
    passport.record_signature!(outcome)
    if outcome.ok?
      Event.record!(:passport_signed, passport: passport.label, did: passport.dpp_id, state: outcome.state,
                                      warnings: outcome.warnings)
    else
      Event.record!(:passport_signature_failed, passport: passport.label, did: passport.dpp_id,
                                                problems: outcome.problems)
    end
    outcome
  end

  # The sentence for the flash; nil when nothing was signed or tried.
  def signature_note(outcome)
    return nil if outcome.nil?
    return t("passports.signature.failed", problems: outcome.problems.join(" · ")) unless outcome.ok?
    return t("passports.signature.done_representative") if outcome.warnings.any?

    t("passports.signature.done")
  end

  # Both libraries raise with a symbol naming the cause, so each one has a
  # sentence rather than an English fragment appearing inside a German page.
  def reason_for(error)
    t("passports.submit.reasons.#{error.message}", default: error.message.to_s)
  end

  # Where the passport will be readable, and therefore what goes into its DID.
  #
  # The same choice the DPP Service makes for a passport it mints itself: a
  # custodian if one is configured, the service's own database otherwise. Only
  # the host is ever compared, but the whole base URL is what is stored, so the
  # operator can see what they committed to.
  def mint_endpoint_base
    settings.custodian_configured? ? settings.custodian_base_url : settings.service_base_url
  end

  def export_filename
    "passport-#{@passport.short_dpp_id}-keys.json"
  end

  def find_passport
    @passport = Passport.find(params[:id])
  end

  def require_product_type
    @product_type = ProductType.fetched.find_by(id: params[:product_type_id])
    return if @product_type

    redirect_to passports_path, alert: t("passports.choose_type_first")
  end

  # Where a save lands. "Save" comes back to the passport, "Save and close" goes
  # to the list.
  #
  # The plain save stays because everything after the form is on this same page:
  # the identifier is created here, submitted here, handed to a custodian here.
  # A save that always left meant walking back in for each of those, and a
  # passport is filled in over several sittings.
  #
  # Still a redirect and not a render: the form is a POST or PATCH, and Turbo
  # does not display a page rendered in answer to one.
  def save_and_redirect(passport, message)
    passport.values = answers

    if passport.save
      result = validation_result(passport)
      flash[:problems] = shown_problems(result)
      flash[:problem_count] = problem_count(result)
      redirect_to(params[:and_close].present? ? passports_path : edit_passport_path(passport),
                  notice: [ message, validation_note(result) ].compact.join(" "))
    else
      render(passport.persisted? ? :edit : :new, status: :unprocessable_entity)
    end
  end

  # The one moment the structure's rules have to hold is the moment the passport
  # leaves this machine. Everything before that is a draft.
  #
  # Refused rather than blocked: the operator is told what is wrong and can send
  # it anyway with a second, deliberate click. A hard stop would be the wrong
  # trade -- the SOyA structure can itself be wrong or out of date, and then an
  # application that cannot be overruled holds up a passport that has to go out.
  # What is sent despite known problems is recorded with them, so the log says
  # afterwards that it was a decision and which one.
  #
  # :unchecked does not block. "We could not look" is not "we looked and found
  # something", and a soya-web-cli that does not answer must not stop a
  # submission.
  def refused_for_problems?(action)
    return false if ActiveModel::Type::Boolean.new.cast(params[:despite_problems])

    result = validation_result(@passport)
    return false unless result.is_a?(Soya::Validation::Result) && !result.valid?

    Event.record!(action == :submit ? :passport_submit_failed : :passport_update_failed,
                  passport: @passport.label, did: @passport.dpp_id, problems: result.problems)
    redirect_to edit_passport_path(@passport, despite: action),
                alert: t("passports.validation.blocked", count: result.problems.size),
                flash: { problems: shown_problems(result), problem_count: problem_count(result) }
    true
  end

  # What is recorded alongside a submission that was sent anyway.
  def sent_despite_problems
    ActiveModel::Type::Boolean.new.cast(params[:despite_problems]) ? { despite_problems: true } : {}
  end

  # A draft is saved whether or not it validates. The alternative — refusing to
  # store what somebody has half typed — loses work to protect a rule that only
  # has to hold when the passport is submitted, which is a later milestone.
  # So the answer is recorded and the shortfall is said out loud.
  #
  # :unchecked rather than nil when soya-web-cli did not answer, because "we did
  # not look" and "we looked and found nothing" are different things and only
  # one of them is worth telling somebody about.
  def validation_result(passport)
    Soya::Validation.check(passport)
  rescue Soya::Error
    :unchecked
  end

  def validation_note(result)
    return t("passports.not_checked") if result == :unchecked
    return nil if result.nil? || result.valid?

    t("passports.not_valid_yet", count: result.problems.size)
  end

  # The shortfall, named rather than counted. A number tells the operator that
  # something is wrong and nothing about what, which leaves them to hunt through
  # a form of twenty fields.
  #
  # Capped, because SHACL can report a great many things about one bad answer
  # and a flash message is not a report. What is cut off is said.
  def shown_problems(result)
    return nil unless result.is_a?(Soya::Validation::Result) && result.problems.any?

    shown = result.problems.first(SHOWN_PROBLEMS)
    over  = result.problems.size - shown.size
    over.positive? ? shown + [ t("passports.more_problems", count: over) ] : shown
  end

  # How many points there are, not how many lines the list has: a cut list ends
  # in a line that says what was cut, and counting that line as a point made the
  # summary say "9" over eight points and four more.
  def problem_count(result)
    result.problems.size if result.is_a?(Soya::Validation::Result) && result.problems.any?
  end

  # The form's answers arrive as one JSON string, put there by the page from
  # what soya-form sent it. Parsed here rather than trusted: it is a value that
  # travelled through the browser, and a broken one must not take down the save.
  def answers
    parsed = JSON.parse(params[:answers].to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def permitted
    values = params.require(:passport).permit(:label, :unique_product_identifier, :granularity, :facility_id,
                                              :placed_on_market_on)
    # The suggestion left as it was is not an identifier anybody chose, and a
    # draft is not refused for it.
    values[:unique_product_identifier] = "" if suggestion_untouched?(values[:unique_product_identifier])
    values
  end

  # --- the carrier host ---------------------------------------------------------

  # A passport the service keeps in its own database is reached by scanning
  # the product only if its identifier is on a host the service answers on
  # (its carrierHosts). With a custodian nothing here applies: the custodian
  # answers for its passports itself.

  # Starting a passport is when the identifier is chosen, so that is when the
  # list is brought up to date. Every other page uses it as it was last fetched.
  def refresh_carrier_hosts
    return if settings.service_base_url.blank? || !settings.carrier_hosts_due?

    settings.record_carrier_hosts!(DppService::Directory.carrier_hosts(settings.service_base_url))
  end

  # What the identifier of a new passport starts with: the first host the
  # service answers on, and the start of a GS1 Digital Link. nil with a
  # custodian, once the identifier is fixed, or when the service names no host.
  def identifier_suggestion
    host = settings.carrier_hosts.first
    return nil if host.nil? || @passport.minted? || !stays_with_service?

    "https://#{host}/01/"
  end

  # The host of this passport's identifier when the passport stays with the
  # service and the service does not answer on that host. nil when there is
  # nothing to warn about: a custodian, an identifier that is not one yet, a
  # host the service answers on, or a service that names no host.
  def unserved_identifier_host
    hosts = settings.carrier_hosts
    return nil if hosts.empty? || !stays_with_service?

    identifier = @passport.identifier
    return nil unless identifier.valid?

    identifier.host unless hosts.include?(identifier.host)
  end

  # Decided at minting (Passport#custodial?); until then by whether this
  # installation hands its passports to a custodian.
  def stays_with_service?
    @passport.minted? ? !@passport.custodial? : !settings.custodian_configured?
  end

  def suggestion_untouched?(value)
    value = value.to_s.strip
    value.present? && settings.carrier_hosts.any? { |host| [ "https://#{host}/01/", "https://#{host}/01" ].include?(value) }
  end
end
