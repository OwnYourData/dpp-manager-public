# An access grant this operator issued, as far as this machine knows it.
#
# The service decides what a grant is worth: it is the one that checks it on
# every read, and the operator of the service can revoke it without asking.
# What is here is the operator's record, brought in line with the service when
# the operator asks for it (sync_from!), never silently.
class AccessGrant < ApplicationRecord
  STATES = %w[valid expired revoked_by_me revoked_by_operator].freeze

  serialize :roles, coder: JSON, type: Array
  serialize :dpp_ids, coder: JSON, type: Array

  validates :jti, :issuer_did, :subject_did, :scope, :expires_at, :service_base_url, presence: true
  validates :jti, uniqueness: { scope: :service_base_url }
  validates :subject_label, length: { maximum: 120 }

  default_scope { order(created_at: :desc) }

  def self.record_issued!(signed, base_url:, label: nil)
    claims = signed.claims
    create!(jti: claims["jti"], issuer_did: claims["iss"], subject_did: claims["sub"],
            subject_label: label.to_s.strip.presence, roles: claims["roles"],
            scope: claims.key?("scope") ? "issuer" : "dpps", dpp_ids: claims["dpps"],
            purpose: claims["purpose"], not_before: signed.not_before, expires_at: signed.expires_at,
            token: signed.token, service_base_url: base_url, registered_at: Time.current,
            known_to_service: true)
  end

  # What the service said about its grants of this issuer (GET
  # /dpp/v1/access-grants): revocations are taken over, grants it knows and
  # this machine does not are added, grants it does not know are marked.
  # Returns { updated:, added:, unknown: }.
  def self.sync_from!(summaries, base_url:, issuer_did:)
    counts = { updated: 0, added: 0, unknown: 0 }
    now = Time.current
    seen = []

    Array(summaries).each do |summary|
      next unless summary.is_a?(Hash) && summary["jti"].present?

      seen << summary["jti"]
      grant = find_by(service_base_url: base_url, jti: summary["jti"])
      if grant.nil?
        create!(jti: summary["jti"], issuer_did: issuer_did, subject_did: summary["sub"],
                roles: summary["roles"], scope: summary["scope"].presence || "dpps", dpp_ids: summary["dpps"],
                purpose: summary["purpose"], not_before: at(summary["nbf"]), expires_at: at(summary["exp"]),
                service_base_url: base_url, revoked_at: at(summary["revokedAt"]),
                revoked_by: summary["revokedBy"], synced_at: now, known_to_service: true)
        counts[:added] += 1
      else
        grant.update!(revoked_at: at(summary["revokedAt"]) || (summary["revoked"] ? grant.revoked_at || now : nil),
                      revoked_by: summary["revokedBy"] || grant.revoked_by,
                      expires_at: at(summary["exp"]) || grant.expires_at,
                      synced_at: now, known_to_service: true)
        counts[:updated] += 1
      end
    end

    where(service_base_url: base_url).where.not(jti: seen).find_each do |grant|
      grant.update!(known_to_service: false, synced_at: now)
      counts[:unknown] += 1
    end
    counts
  end

  def self.at(seconds) = seconds.present? ? Time.at(seconds.to_i).utc : nil
  private_class_method :at

  def all_passports? = scope == "issuer"

  def revoked? = revoked_at.present?

  def expired?(now = Time.current) = expires_at < now

  def state(now = Time.current)
    if revoked?
      revoked_by.present? && revoked_by != issuer_did ? "revoked_by_operator" : "revoked_by_me"
    elsif expired?(now)
      "expired"
    else
      "valid"
    end
  end

  def revocable? = !revoked? && known_to_service?

  def record_revocation!(summary)
    update!(revoked_at: summary.is_a?(Hash) && summary["revokedAt"] ? Time.at(summary["revokedAt"].to_i).utc : Time.current,
            revoked_by: (summary["revokedBy"] if summary.is_a?(Hash)) || issuer_did, synced_at: Time.current)
  end
end
