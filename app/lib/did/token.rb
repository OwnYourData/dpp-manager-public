require "securerandom"

module Did
  # The bearer token the DPP Service wants on every write.
  #
  # There is no registration and no client secret anywhere in this: the operator
  # issues the token themselves and signs it with the document key of their own
  # DID. The service resolves that DID, takes the public key out of the document
  # and checks the signature. Revoking the DID therefore ends every token it ever
  # signed, without a revocation list existing anywhere.
  #
  # The contract is narrow and every part of it has been got wrong before:
  #
  #   alg  EdDSA          — and jwt needs jwt/eddsa loaded, or it does not know it
  #   kid  <did>#key-doc
  #   iss  == sub == the DID, WITHOUT the "@<repository>" suffix: the service
  #                    normalises its own identifiers but resolves iss verbatim
  #   aud  the service's public base URL
  #   exp  at most 900 seconds out (DID_AUTH_MAX_LIFETIME)
  #
  # Signed with the DOCUMENT key — slot 0 of the DID's key field, not slot 1.
  module Token
    # The service refuses anything longer. Staying well under it costs nothing:
    # a token is minted per request, not per session.
    MAX_LIFETIME = 900
    DEFAULT_LIFETIME = 300

    module_function

    def issue(identity, audience:, lifetime: DEFAULT_LIFETIME)
      require "jwt"
      require "jwt/eddsa"

      raise ArgumentError, "audience is required" if audience.blank?

      seconds = [ lifetime.to_i, MAX_LIFETIME ].min
      now = Time.now.to_i
      did = identity.did

      JWT.encode(
        { "iss" => did, "sub" => did, "aud" => audience.to_s,
          "iat" => now, "exp" => now + seconds, "jti" => SecureRandom.hex(8) },
        Oyd.signing_key(identity.document_key),
        "EdDSA",
        { "kid" => "#{did}#key-doc" }
      )
    end

    # Sign a token and verify it against the key the VDR publishes for this DID.
    #
    # This is what the setup wizard offers as "check my keys": it exercises the
    # whole chain the service will walk — key material, encoding, resolution —
    # without writing anything anywhere and without needing the service to be
    # reachable at all.
    def self_test(identity, audience: "https://example.invalid")
      require "jwt"
      require "jwt/eddsa"

      token = issue(identity, audience: audience, lifetime: 60)
      public_key = Oyd.public_key(identity.did)
      verify_key = ::Ed25519::VerifyKey.new(public_key)

      JWT.decode(token, verify_key, true,
                 algorithm: "EdDSA", aud: audience, verify_aud: true,
                 iss: identity.did, verify_iss: true,
                 required_claims: %w[iss sub aud exp])
      true
    end
  end
end
