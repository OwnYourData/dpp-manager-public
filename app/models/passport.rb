# One passport: a product type, a name, the answers to the form, and the part of
# the EN 18223 envelope the operator supplies.
#
# Nothing here has been minted or submitted yet, so a row can still be deleted
# without consequence anywhere else. That stops being true the moment it gets a
# passport DID and a place at a custodian.
class Passport < ApplicationRecord
  STATUSES = %w[draft minted submitted retired].freeze

  # The edition this application writes. A constant and not a setting: it names
  # the semantic model the elements were built against, and the transformation
  # would have to change with it.
  SCHEMA_VERSION = "EN 18223:2026".freeze

  belongs_to :product_type
  has_one :passport_key, dependent: :destroy

  validates :label, presence: true, length: { maximum: 200 }
  validates :status, inclusion: { in: STATUSES }
  validates :granularity, inclusion: { in: Dpp::ProductIdentifier::GRANULARITIES }, allow_blank: true
  validate  :identifier_is_carrier_borne
  validate  :granularity_agrees_with_the_path
  validate  :placing_on_market_fixed_once_submitted
  validate  :envelope_is_frozen_after_minting

  normalizes :label, with: ->(value) { value.to_s.strip }
  normalizes :unique_product_identifier, with: ->(value) { value.to_s.strip }
  normalizes :facility_id, with: ->(value) { value.to_s.strip }

  default_scope { order(updated_at: :desc) }

  def values
    data.present? ? JSON.parse(data) : {}
  rescue JSON::ParserError
    {}
  end

  def values=(hash)
    self.data = JSON.generate(hash.presence || {})
  end

  def identifier = Dpp::ProductIdentifier.new(unique_product_identifier)

  # Everything the envelope needs is present. Not a validation: a draft is
  # allowed to be incomplete, and this is the question "could this be submitted",
  # asked at the moment somebody wants to.
  def envelope_complete?
    unique_product_identifier.present? && granularity.present? && identifier.valid?
  end

  def minted? = dpp_id.present?

  # --- availability (ESPR Art. 9(2)(i)) ---------------------------------------

  # The last day the passport has to stay available, worked out from the start
  # of the period and the years the product type prescribes. nil when the type
  # prescribes none. The period starts when the product was placed on the
  # market; without that date, on the day of submission.
  def retention_deadline(submitted_on = Date.current)
    years = product_type&.availability_years
    return nil if years.blank?

    (placed_on_market_on || submitted_on).advance(years: years)
  end

  # Whether the passport may not be ended yet. The last day is inside the
  # period, as it is at the service, which refuses the deletion on that day too.
  def retained_on?(date = Date.current) = retain_until.present? && date <= retain_until

  def configuration_snapshot_hash
    configuration_snapshot.present? ? JSON.parse(configuration_snapshot) : {}
  rescue JSON::ParserError
    {}
  end

  # What the product type's configuration says about this passport, worded like
  # the structure's own problems so both land in the same list.
  #
  # A problem and not a validation, as decided for the structure's rules: the
  # configuration can itself be out of date, and the operator has to be able to
  # send the passport anyway with a deliberate second click.
  def configuration_problems
    type = product_type
    return [] if type.nil? || type.granularity.blank? || granularity.blank?
    return [] if granularity == type.granularity

    [ "#{I18n.t('passports.envelope.granularity')}: " \
      "#{I18n.t('passports.problem.granularity_config',
                expected: I18n.t("passports.granularities.#{type.granularity}"))}" ]
  end

  # Mint this passport's own DID and keep its keys.
  #
  # One transaction, because a DID whose keys were not written down is a DID
  # nobody can ever update or revoke — the registrar has already published the
  # document by the time this returns, so if the row cannot be saved the right
  # outcome is a rolled-back passport and a raised error, not a half-minted one.
  #
  # The endpoint base is an argument rather than read from the settings here: it
  # is a decision with no way back, and the caller is the one that has to have
  # made it deliberately.
  # The collection is recorded here because minting is where the choice between
  # "the service's own database" and "a custodian" is made and frozen: the
  # endpoint inside the DID names the host that will hold this passport, and the
  # service refuses a submission whose DID points anywhere else.
  def mint!(endpoint_base:, collection_id: nil)
    raise Did::Oyd::Error, "this passport already has a DID" if minted?
    raise Did::Oyd::Error, "the envelope is not complete" unless envelope_complete?

    minted = Did::Oyd.mint_passport(unique_product_identifier, endpoint_base: endpoint_base)

    transaction do
      update!(dpp_id: minted[:did], minted_at: Time.current,
              endpoint_base: endpoint_base, status: "minted",
              custodian_collection_id: collection_id.presence)
      create_passport_key!(document_key:   minted[:document_key],
                           revocation_key: minted[:revocation_key],
                           revocation_log: minted[:revocation_log])
    end

    self
  end

  # Where this passport's DID says it can be read. Rebuilt rather than stored,
  # so it cannot drift from what the DID actually carries.
  def service_endpoint
    return nil unless minted? && endpoint_base.present?

    Did::Oyd.service_endpoint(unique_product_identifier, endpoint_base)
  end

  def keys_secured? = passport_key&.secured? || false

  # --- custody ----------------------------------------------------------------

  # Is this passport meant to live at a custodian rather than in the service's
  # own database? Decided at minting, because the DID's endpoint says where it
  # will be readable and cannot be changed afterwards.
  def custodial? = custodian_collection_id.present?

  def delegated? = delegation_jti.present?

  def delegation_expired?
    delegation_expires_at.present? && delegation_expires_at <= Time.current
  end

  # Running out, with enough left to do something about it. A mandate is renewed
  # with one signature, but only by the operator — so the application has to ask
  # before it is too late rather than report afterwards.
  def delegation_expiring_soon?
    delegation_expires_at.present? && !delegation_expired? &&
      delegation_expires_at <= Time.current + Did::Delegation::RENEW_WITHIN
  end

  # The passport is at its new custodian, but its identifier still says the old
  # one. A reader who resolves the DID is sent to a host that either serves a
  # stale copy or nothing at all, and neither of them says so — which is why
  # this state is named rather than merely temporary.
  def move_unfinished? = pending_endpoint_base.present?

  def record_custody_move!(base_url:, collection_id:, signed:)
    update!(pending_endpoint_base: base_url, custodian_collection_id: collection_id,
            custody_moved_at: Time.current,
            delegation_jti: signed.jti, delegation_signed_at: Time.current,
            delegation_expires_at: signed.expires_at, delegation_act: Array(signed.act).join(","))
  end

  # The identifier has caught up with the document. From here the passport is
  # readable at its new custodian by resolving the DID, which is what the world
  # does with it.
  def record_endpoint_moved!(revocation_log = nil)
    transaction do
      update!(endpoint_base: pending_endpoint_base, pending_endpoint_base: nil)
      passport_key&.update!(revocation_log: revocation_log) if revocation_log.present?
    end
  end

  # The service has told us which hash it expects to see attested. Recording it
  # clears the attestation: a changed payload means whatever was signed before is
  # about an older version.
  def record_payload_expected!(payload_hash)
    return if payload_hash.blank? || payload_hash == self.payload_hash

    update!(payload_hash: payload_hash, payload_committed_at: nil)
  end

  # The log entry is published. The revocation record belongs to the new document
  # and replaces the stored one, or the passport can no longer be retired.
  def record_payload_committed!(revocation_log = nil)
    transaction do
      update!(payload_committed_at: Time.current)
      passport_key&.update!(revocation_log: revocation_log) if revocation_log.present?
    end
  end

  def payload_attested? = payload_hash.present? && payload_committed_at.present?

  def payload_awaiting_attestation? = payload_hash.present? && payload_committed_at.nil?

  def record_delegation!(signed)
    update!(delegation_jti: signed.jti,
            delegation_signed_at: Time.current,
            delegation_expires_at: signed.expires_at,
            delegation_act: Array(signed.act).join(","))
  end

  # Does what the service says it holds agree with what was signed here? The
  # jti alone answers it: it is unique per mandate and it is the handle the
  # custodian revokes by, so two records naming the same one are the same
  # mandate.
  def delegation_matches?(claims)
    claims.is_a?(Hash) && claims["jti"].present? && claims["jti"] == delegation_jti
  end

  def submitted? = submitted_at.present?

  def retired? = retired_at.present?

  def revoked? = revoked_at.present?

  # Ending a passport is two acts against two systems. Either can fail while the
  # other has already happened, so the application has to be able to say which
  # half is done — and to offer the missing half rather than starting again.
  def half_retired? = retired? && !revoked?

  def record_retirement!
    update!(status: "retired", retired_at: Time.current)
  end

  def record_revocation!
    update!(revoked_at: Time.current)
  end

  # The host the passport's DID says it can be read at. The DPP Service compares
  # exactly this with the host it is being handed to, and refuses a mismatch —
  # unrepairably, because it holds no key for a DID it did not mint.
  def endpoint_host
    URI.parse(endpoint_base.to_s).host
  rescue URI::InvalidURIError
    nil
  end

  def endpoint_agrees_with?(base_url)
    host = begin
      URI.parse(base_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    host.present? && host == endpoint_host
  end

  def record_submission!(document, base_url:, retain_until: nil)
    update!(status: "submitted", submitted_at: Time.current, submitted_to: base_url,
            submitted_digest: input_digest,
            service_document: document.present? ? JSON.generate(document) : nil,
            retain_until: retain_until,
            configuration_snapshot: JSON.generate(snapshot_of_configuration))
  end

  # What the product type said when this passport was issued (CFG-011): its
  # legal configuration with the version number, and which copy of the SOyA
  # structure and transformation the passport was built from.
  def snapshot_of_configuration
    type = product_type
    fields = ProductType::CONFIGURATION.index_with { |field| type[field] }
    fields.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value }
          .merge("config_version" => type.config_version,
                 "structure" => { "name" => type.structure_name, "repo" => type.repo_base_url,
                                  "fetched_at" => type.fetched_at&.utc&.iso8601,
                                  "transformation" => type.transformation_name,
                                  "transformation_fetched_at" => type.transformation_fetched_at&.utc&.iso8601 })
          .stringify_keys
  end

  # --- access policy --------------------------------------------------------

  # What the service confirmed after a write that named a policy. The report
  # comes from the answer header; without one (an older service) the id that
  # was sent is all there is to record.
  def record_access_policy!(report, sent_id)
    id = report&.id.presence || sent_id
    return if id.blank?

    update!(access_policy_id: id,
            access_policy_report: report ? JSON.generate(report.to_h.merge("at" => Time.current.utc.iso8601)) : nil)
  end

  def access_policy_report_hash
    access_policy_report.present? ? JSON.parse(access_policy_report) : {}
  rescue JSON::ParserError
    {}
  end

  # The type's policy has moved on since this passport was classified, or the
  # type has one and this passport, already with the service, has none yet.
  def access_policy_behind?(current_id)
    submitted? && !retired? && current_id.present? && access_policy_id != current_id
  end

  # --- signature of the economic operator -----------------------------------

  # The passports that should carry the signature and, as far as is known
  # here, do not: with the DPP Service in its own database, not ended.
  scope :awaiting_signature, lambda {
    where.not(submitted_at: nil).where(retired_at: nil, custodian_collection_id: [ nil, "" ])
         .where("signature_state IS NULL OR signature_state <> ?", "signed")
  }

  # Only a passport the DPP Service keeps in its own database can carry it. A
  # custodian serves its passports itself, and the service takes no signature
  # for them.
  def signable? = submitted? && !retired? && !custodial?

  def signed? = signature_state == "signed"

  # What the service said after a write: the signature it held is gone, and
  # with it the warning that came with it.
  def record_signature_state!(state)
    return if state.blank?

    update!(signature_state: state, signature_warning: (signature_warning if state == "signed"),
            signature_recorded_at: Time.current)
  end

  # The outcome of handing in a signature (DppService::OperatorSigning).
  def record_signature!(outcome)
    if outcome.ok?
      update!(signature_state: outcome.state, signature_warning: outcome.warnings.join(" ").presence,
              signature_problem: nil, signature_recorded_at: Time.current)
    else
      update!(signature_state: outcome.state.presence || signature_state,
              signature_problem: outcome.problems.join(" · ").presence, signature_recorded_at: Time.current)
    end
  end

  def record_correction!(document)
    update!(corrected_at: Time.current, submitted_digest: input_digest,
            service_document: document.present? ? JSON.generate(document) : nil)
  end

  # A fingerprint of everything the operator can still change after submitting:
  # the answers and the facility. The identifier and the granularity are inside
  # the published DID and are frozen, so they are not part of it.
  #
  # Over sorted keys, because two hashes that say the same thing in a different
  # order are the same passport, and a fingerprint that disagreed would offer to
  # correct something that has not changed.
  def input_digest
    Digest::SHA256.hexdigest(JSON.generate([ values.sort.to_h, facility_id.to_s ]))
  end

  # Does this row say something different from the copy at the service?
  #
  # The question the page asks before offering to send a correction. A passport
  # that was submitted before this column existed has no fingerprint, and the
  # honest answer there is "cannot tell" — which reads as "nothing to send"
  # rather than as an invented difference.
  def differs_from_service?
    submitted? && submitted_digest.present? && submitted_digest != input_digest
  end

  def submitted_document
    service_document.present? ? JSON.parse(service_document) : nil
  rescue JSON::ParserError
    nil
  end

  # Short enough to recognise in a list, long enough not to collide by accident.
  def short_dpp_id
    dpp_id.to_s.delete_prefix("did:oyd:")[0, 12]
  end

  # The answers, seen through the form's own schema: only fields the structure
  # knows, in the order the schema lists them, with the empty ones dropped.
  #
  # A summary built from the raw hash would show whatever a stale form left
  # behind, and in the order a JSON object happens to have — which is how a
  # field that was removed from the structure keeps appearing in the list for
  # months.
  def summary(language = I18n.locale, limit: 4)
    form = product_type.form_for(language)
    properties = form&.dig("schema", "properties") || {}
    given = values

    properties.keys.filter_map { |key|
      value = given[key]
      next if value.nil? || value == "" || value == []

      [ key, Array(value).join(", ") ]
    }.first(limit)
  end

  private

  # Only when something was typed: an empty identifier is an unfinished draft,
  # not a wrong one.
  def identifier_is_carrier_borne
    return if unique_product_identifier.blank?

    problem = identifier.problem
    return if problem.nil?

    errors.add(:unique_product_identifier,
      I18n.t("passports.identifier.#{problem}"))
  end

  # The rule that is invisible until it fails. A Digital Link path expresses the
  # granularity, and the service refuses a declaration that contradicts it — so
  # the contradiction is shown here, next to the two fields that disagree,
  # rather than arriving later as a rejected submission.
  # The period the service holds the passport for was fixed from this date at
  # submission, so changing it afterwards would change nothing but the record.
  def placing_on_market_fixed_once_submitted
    return unless will_save_change_to_placed_on_market_on? && submitted_at.present? && !will_save_change_to_submitted_at?

    errors.add(:placed_on_market_on, I18n.t("passports.envelope.placed_on_market_fixed"))
  end

  def granularity_agrees_with_the_path
    return if granularity.blank? || unique_product_identifier.blank?

    from_path = identifier.granularity
    return if from_path.nil? || from_path == granularity

    errors.add(:granularity, I18n.t("passports.identifier.granularity_contradicts", from_path: from_path))
  end

  # After minting, the identifier is no longer only a field on this row: it sits
  # inside the DID's serviceEndpoint, which the registrar has published and the
  # data carrier will point at. Editing it here would leave a passport whose own
  # DID resolves to a different product, and the DPP Service — which compares
  # them — would refuse the submission with a message about a host, several
  # steps away from the field that was changed.
  #
  # The granularity is frozen with it because the service derives it from that
  # same path, and the two are only ever right together.
  def envelope_is_frozen_after_minting
    return unless minted? && persisted?

    %i[unique_product_identifier granularity].each do |field|
      next unless will_save_change_to_attribute?(field.to_s)

      errors.add(field, I18n.t("passports.mint.frozen"))
    end
  end
end
