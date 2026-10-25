module DppService
  # Making sure the DPP Service knows the current version of a product type's
  # access policy, before a passport names it.
  #
  # Asked before every write that names the policy, not only once: the service
  # answers a policy it already holds with 200 and changes nothing, so asking
  # again costs one request and saves the passport from a 400 when the service
  # was reset, or when the operator moved to another one since.
  #
  # A 409 means the id of the current version is taken at that service by a
  # policy with different rules — a vault restored from an older backup, or a
  # second installation under the same identity. The rules here are the ones
  # that count, so they go up as the next version, a few times at most.
  module AccessPolicyRegistration
    class Error < StandardError
      attr_reader :problems

      def initialize(message, problems: [])
        @problems = problems
        super(message)
      end
    end

    ATTEMPTS = 3

    module_function

    # The id the passport names, or nil for a type whose policy is off.
    # Raises Error with the service's sentences when it cannot be registered,
    # and Client::Error when the service cannot be reached.
    def ensure!(product_type, base_url:, audience:, identity: Identity.current)
      return nil unless product_type.access_policy_enabled?
      raise Error, "no_identity" if identity.nil?

      ATTEMPTS.times do
        document = product_type.access_policy_document(identity.did)
        raise Error, "no_policy" if document.nil?

        result = Client.register_access_policy(document, base_url: base_url,
                                                         token: Did::Token.bearer(identity, audience: audience))
        if result.ok?
          newly = !product_type.access_policy_registered_at?(base_url, identity.did)
          product_type.record_access_policy_registered!(document["id"], base_url)
          if newly
            Event.record!(:access_policy_registered, product_type: product_type.label, policy: document["id"],
                                                     service: base_url, status: result.http_status)
          end
          return document["id"]
        end

        if result.http_status == 409
          product_type.skip_access_policy_version!
          next
        end

        raise Error.new("refused", problems: result.problems)
      end

      raise Error, "conflict"
    end
  end
end
