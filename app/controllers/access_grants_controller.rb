# Who may read the controlled part of this operator's passports.
#
# The operator grants readers with a legitimate interest — a repair shop, a
# recycler — access to some or all of their passports, for at most a year. The
# grant is signed here with the identity's document key and registered with
# the DPP Service, which checks it on every read. Grants for authorities are not
# the operator's to give: issuers the service trusts vouch for those, and the
# page only says who they are.
#
# Opening the page asks nobody anything. What the service holds is fetched when
# the operator asks for it ("Compare with the service"), because the service
# can revoke a grant on its own and the answer may differ from what is here.
class AccessGrantsController < ApplicationController
  before_action :find_grant, only: :revoke

  def index
    @grants = AccessGrant.all
    @passports = grantable_passports
    @issuers = settings.authority_issuers
  end

  def create
    return grant_refused(t("access_grants.no_service")) unless settings.service_configured?
    return grant_refused(t("access_grants.reasons.no_identity")) if Identity.current.nil?
    return grant_refused(t("access_grants.reasons.no_service_did")) if settings.service_did.blank?

    all = params[:scope] == "issuer"
    chosen = Array(params[:dpp_ids]).map(&:to_s) & grantable_passports.map(&:dpp_id)
    warning = unresolvable_reader_warning(params[:subject_did].to_s.strip)

    signed = Did::AccessGrant.issue(Identity.current, subject: params[:subject_did], service_did: settings.service_did,
                                                      dpp_ids: chosen, all: all, purpose: params[:purpose],
                                                      days: params[:days].presence || Did::AccessGrant::MAX_DAYS)
    base = settings.service_base_url
    result = DppService::Client.register_access_grant(signed.token, base_url: base, token: bearer)

    unless result.ok?
      return grant_refused(t("access_grants.refused", status: result.http_status,
                                                      problems: result.problems.join(" · ")))
    end

    grant = AccessGrant.record_issued!(signed, base_url: base, label: params[:subject_label])
    Event.record!(:access_grant_issued, jti: grant.jti, reader: grant.subject_did, scope: grant.scope,
                                        passports: Array(grant.dpp_ids).size, until: grant.expires_at.iso8601,
                                        service: base)
    redirect_to access_grants_path, notice: [ t("access_grants.issued", reader: grant.subject_did), warning ].compact.join(" ")
  rescue Did::AccessGrant::Error => e
    grant_refused(t("access_grants.reasons.#{e.message}"))
  rescue Did::Oyd::Error => e
    grant_refused(t("passports.submit.token_failed", message: e.message))
  rescue DppService::Client::Error => e
    grant_refused(t("passports.submit.unreachable", message: e.message))
  end

  # What the service holds: its grants of this issuer and its list of
  # authority issuers.
  def sync
    return grant_refused(t("access_grants.no_service")) unless settings.service_configured?
    return grant_refused(t("access_grants.reasons.no_identity")) if Identity.current.nil?

    base = settings.service_base_url
    result = DppService::Client.list_access_grants(base_url: base, token: bearer)
    unless result.ok?
      return grant_refused(t("access_grants.refused", status: result.http_status,
                                                      problems: result.problems.join(" · ")))
    end

    counts = AccessGrant.sync_from!(result.list, base_url: base, issuer_did: Identity.current.did)
    issuers_note = record_authority_issuers(base)
    redirect_to access_grants_path,
                notice: [ t("access_grants.synced", **counts), issuers_note ].compact.join(" ")
  rescue Did::Oyd::Error => e
    grant_refused(t("passports.submit.token_failed", message: e.message))
  rescue DppService::Client::Error => e
    grant_refused(t("passports.submit.unreachable", message: e.message))
  end

  def revoke
    return grant_refused(t("access_grants.not_revocable")) unless @grant.revocable?
    return grant_refused(t("access_grants.other_service", service: @grant.service_base_url)) \
      unless @grant.service_base_url == settings.service_base_url
    return grant_refused(t("access_grants.reasons.no_identity")) if Identity.current.nil?

    result = DppService::Client.revoke_access_grant(@grant.jti, base_url: @grant.service_base_url, token: bearer)

    if result.http_status == 404
      @grant.update!(known_to_service: false)
      return grant_refused(t("access_grants.unknown_to_service"))
    end
    unless result.ok?
      return grant_refused(t("access_grants.refused", status: result.http_status,
                                                      problems: result.problems.join(" · ")))
    end

    @grant.record_revocation!(result.document)
    Event.record!(:access_grant_revoked, jti: @grant.jti, reader: @grant.subject_did, by: @grant.revoked_by,
                                         service: @grant.service_base_url)
    redirect_to access_grants_path, notice: t("access_grants.revoked", reader: @grant.subject_did)
  rescue Did::Oyd::Error => e
    grant_refused(t("passports.submit.token_failed", message: e.message))
  rescue DppService::Client::Error => e
    grant_refused(t("passports.submit.unreachable", message: e.message))
  end

  private

  def find_grant
    @grant = AccessGrant.find(params[:id])
  end

  def bearer
    Did::Token.bearer(Identity.current, audience: settings.service_audience)
  end

  # The passports a grant of this operator can name at the configured service:
  # submitted there, not ended. The service takes a grant only for passports it
  # holds for this operator.
  def grantable_passports
    return [] unless settings.service_configured?

    Passport.where(submitted_to: settings.service_base_url, retired_at: nil).where.not(dpp_id: [ nil, "" ])
            .where.not(submitted_at: nil).to_a
  end

  # A reader DID that does not resolve is most likely mistyped, but it may be a
  # method this machine cannot resolve or a registry that is down. Said, not
  # refused.
  def unresolvable_reader_warning(did)
    return nil unless did.start_with?("did:oyd:")

    Did::Oyd.public_key(did)
    nil
  rescue Did::Oyd::Error, StandardError
    t("access_grants.reader_unresolved", reader: did)
  end

  def record_authority_issuers(base)
    settings.record_authority_issuers!(DppService::Directory.authority_issuers(base))
    nil
  rescue DppService::Directory::Error
    t("access_grants.issuers_unavailable")
  end

  def grant_refused(message)
    redirect_to access_grants_path, alert: message
  end
end
