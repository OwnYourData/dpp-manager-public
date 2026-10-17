require "securerandom"

module Did
  # An access grant: the operator's signed statement that a reader may read the
  # controlled part of the operator's passports in the class of readers with a
  # legitimate interest (the DPP Service's docs/AccessClasses.md §7).
  #
  # What this application grants, and nothing else:
  #
  #   roles   legitimateInterest only. Authorities are vouched for by issuers
  #           the service trusts; an operator cannot make anybody an authority.
  #   iss     the operator's identity, which owns the passports. The service
  #           takes a grant of an operator for that operator's passports only.
  #   dpps    the passports it covers, at most MAX_DPPS, or instead
  #   scope   "issuer": every passport of the operator, today's and later ones.
  #
  # Signed with the document key of the identity, like the bearer token and the
  # custody mandate, and serialised the same way as the mandate: sorted keys, no
  # insignificant whitespace, ASCII only.
  module AccessGrant
    TYP = "dpp-access-grant+jwt".freeze
    ROLE = "legitimateInterest".freeze

    # The service refuses anything longer; offered as the default as well.
    MAX_DAYS = 365
    MAX_DPPS = 1000

    class Error < StandardError; end

    Signed = Struct.new(:token, :claims, keyword_init: true) do
      def jti = claims["jti"]
      def not_before = Time.at(claims["nbf"]).utc
      def expires_at = Time.at(claims["exp"]).utc
    end

    module_function

    # +dpp_ids+ for the passports named, or +all+ for every passport of the
    # operator. +days+ between 1 and MAX_DAYS.
    def issue(identity, subject:, service_did:, dpp_ids: nil, all: false, purpose: nil,
              days: MAX_DAYS, now: Time.now.to_i)
      raise Error, "no_identity" if identity.nil?
      raise Error, "no_service_did" if service_did.to_s.strip.empty?

      subject = subject.to_s.strip
      raise Error, "subject_not_a_did" unless subject.match?(/\Adid:[a-z0-9]+:\S+\z/)
      raise Error, "subject_is_issuer" if Oyd.normalize(subject) == identity.did

      days = Integer(days, exception: false)
      raise Error, "days_out_of_range" if days.nil? || days < 1 || days > MAX_DAYS

      claims = {
        "iss"   => identity.did,
        "sub"   => subject,
        "aud"   => service_did.to_s.strip,
        "roles" => [ ROLE ],
        "iat"   => now,
        "nbf"   => now,
        "exp"   => now + (days * 86_400),
        "jti"   => "grant-#{SecureRandom.uuid}"
      }

      if all
        claims["scope"] = "issuer"
      else
        ids = Array(dpp_ids).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        raise Error, "no_passports" if ids.empty?
        raise Error, "too_many_passports" if ids.size > MAX_DPPS

        claims["dpps"] = ids
      end
      claims["purpose"] = purpose.to_s.strip if purpose.to_s.strip.present?

      Signed.new(token: sign(identity, claims), claims: claims)
    end

    def sign(identity, claims)
      header = { "alg" => "EdDSA", "typ" => TYP, "kid" => "#{identity.did}#key-doc" }
      signing_input = "#{Delegation.encode64(Delegation.canonical(header))}." \
                      "#{Delegation.encode64(Delegation.canonical(claims))}"

      key = Oyd.signing_key(identity.document_key)
      "#{signing_input}.#{Delegation.encode64(key.sign(signing_input))}"
    rescue Delegation::Error
      # The only refusal there: a claim that is not ASCII, which in practice is
      # the free-text purpose.
      raise Error, "not_ascii"
    end
  end
end
