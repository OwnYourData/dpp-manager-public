module DppService
  # The economic operator signs a passport the DPP Service holds in its own
  # database (its docs/Integrity.md section 10).
  #
  # What is signed is fetched, not built here: the passport exactly as a reader
  # without access rights receives it, in the full representation. The
  # service checks the signature against that and nothing else, and only the
  # service knows how it delivers the passport after the write it has just
  # made — its own attributes included, lastUpdated among them. So the
  # answer is read, signed with the document key of this application's
  # identity, and handed back.
  #
  # Between the read and the hand-in another write can come in. The service
  # then refuses with 400 and the sentence below, and the passport is read and
  # signed again — a few times, then the refusal is what is reported.
  #
  # Passports held by a custodian are not signed here: the custodian serves
  # them, and the DPP Service accepts a signature only for passports it holds
  # itself. The callers do not get that far for them.
  module OperatorSigning
    ATTEMPTS = 3

    # The part of the service's sentence that says the passport changed since
    # it was read; the full sentence goes on to say "fetch it again".
    CHANGED_MEANWHILE = "not the passport as it is delivered now".freeze

    # ok?       the service holds the signature now
    # state     what the service said last (X-DPP-Signature-State)
    # warnings  its warnings on acceptance: the signer is not the passport's
    #           economicOperatorId, so it counts as an authorised
    #           representative's signature
    # problems  its sentences when it refused, or why nothing was handed in
    Outcome = Struct.new(:ok, :state, :warnings, :problems, :attempts, keyword_init: true) do
      def ok? = ok
    end

    module_function

    def call(base_url:, dpp_id:, identity:, audience:)
      signing_key = Did::Oyd.signing_key(identity.document_key)
      kid = "#{identity.did}#key-doc"
      bearer = Did::Token.bearer(identity, audience: audience)
      answer = nil

      1.upto(ATTEMPTS) do |attempt|
        read = Client.read_for_signing(base_url: base_url, dpp_id: dpp_id)
        return refused(read, attempt) unless read.ok? && read.raw.present?

        compact = Did::CompactJws.sign(read.raw, signing_key, kid: kid)
        answer = Client.submit_signature(compact, base_url: base_url, dpp_id: dpp_id, token: bearer)
        if answer.ok?
          return Outcome.new(ok: true, state: answer.signature_state.presence || "signed",
                             warnings: Array(answer.warnings), problems: [], attempts: attempt)
        end
        return refused(answer, attempt) unless changed_meanwhile?(answer)
      end

      refused(answer, ATTEMPTS)
    end

    def changed_meanwhile?(result)
      result.http_status == 400 && Array(result.problems).any? { |text| text.to_s.include?(CHANGED_MEANWHILE) }
    end

    def refused(result, attempt)
      Outcome.new(ok: false, state: result.signature_state, warnings: [],
                  problems: Array(result.problems).presence || [ "HTTP #{result.http_status}" ], attempts: attempt)
    end
  end
end
