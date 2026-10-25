require "base64"
require "json"

module Did
  # A JWS in the compact serialization (RFC 7515) with an EdDSA signature
  # (Ed25519, RFC 8037): the form in which the economic operator signs a
  # passport for the DPP Service (its docs/Integrity.md section 10).
  #
  # The same format as app/lib/compact_jws.rb in the DPP Service, which checks
  # these signatures: the protected header is exactly { "alg": "EdDSA",
  # "kid": kid }, and the payload is the bytes that were read, base64url-encoded
  # as they are. Nothing is serialised again in between, because the service
  # compares the payload with the passport it delivers, and the bytes it
  # delivered are what that passport is.
  module CompactJws
    ALGORITHM = "EdDSA".freeze

    module_function

    # +signing_key+ is an Ed25519::SigningKey.
    def sign(payload_bytes, signing_key, kid:)
      head = encode(JSON.generate({ "alg" => ALGORITHM, "kid" => kid }))
      body = encode(payload_bytes.to_s.b)
      "#{head}.#{body}.#{encode(signing_key.sign("#{head}.#{body}"))}"
    end

    def encode(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
  end
end
