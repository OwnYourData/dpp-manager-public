module Dpp
  # The passport as EN 18223:2026 sees it: the envelope of Table 1 plus the
  # element tree.
  #
  # Two halves with two different authors, and keeping them apart is the point.
  # The elements come from the transformation, which is a published SOyA
  # structure and can be read by anyone who wants to know how an answer became
  # an element. The envelope is built here, because every one of its fields is
  # something the transformation cannot know: the passport's own DID, the
  # operator's identity, the edition this application writes.
  #
  # Three attributes of Table 1 are deliberately absent. `dppStatus` and
  # `lastUpdated` belong to the service — it sets them, and sending them would
  # be a client asserting a state it does not control. `economicOperatorId` is
  # sent, but the service overwrites it with the DID that presented the token;
  # it is included anyway so the document is complete on its own, in the file
  # the operator keeps.
  module Document
    class Error < StandardError; end

    module_function

    def build(passport)
      {
        "digitalProductPassportId" => passport.dpp_id,
        "uniqueProductIdentifier"  => passport.unique_product_identifier,
        "granularity"              => passport.granularity,
        "dppSchemaVersion"         => Passport::SCHEMA_VERSION,
        "economicOperatorId"       => Identity.current&.did,
        "facilityId"               => passport.facility_id.presence,
        "elements"                 => elements(passport)
      }.compact
    end

    # What a correction sends: only what the operator can still change.
    #
    # RFC 7396, so what is absent is left alone — and that is the point. The
    # identifier and the granularity are inside the published DID and cannot
    # move; dppStatus, lastUpdated and the owner belong to the service. Sending
    # the whole document again would be this application asserting all of them.
    #
    # facilityId is sent even when it is empty, as an explicit null: in a merge
    # patch that is how a member is removed, and an operator who cleared the
    # field means it should go.
    def correction(passport)
      {
        "elements"   => elements(passport),
        "facilityId" => passport.facility_id.presence
      }
    end

    # The way back: a passport read from a service, turned into answers for a
    # product type's form.
    #
    # Through the type's reverse transformation, and through soya-web-cli for
    # the same reason the forward direction is — an application that read the
    # element tree itself would have a second, private opinion about what these
    # elements mean, and the two would drift.
    #
    # It is not lossless and does not pretend to be: what comes back is what
    # this type has a field for. Everything else stays in the document, which is
    # shown beside it.
    def answers_from(document, product_type)
      raise Error, :no_reverse_transformation unless product_type&.reverse_transformation?
      raise Error, :reverse_transformation_not_fetched unless product_type.reverse_transformation_fetched?

      result = Soya::WebCli.transform(product_type.reverse_transformation_resolvable_name, document)
      raise Error, :transformation_did_not_yield_answers unless result.is_a?(Hash)

      result
    rescue Soya::Error
      raise Error, :transformation_failed
    end

    # The element tree, from the type's transformation structure.
    #
    # It runs through soya-web-cli rather than through jq directly, even though
    # jq is in the image: the transformation is a SOyA overlay, and running it
    # any other way would mean this application had its own opinion about what
    # an OverlayTransformation means. The copy it pulls is the one in the vault,
    # so this works without a network.
    def elements(passport)
      type = passport.product_type
      raise Error, :no_transformation unless type&.transformation?
      raise Error, :transformation_not_fetched unless type.transformation_fetched?

      result = Soya::WebCli.transform(type.transformation_resolvable_name, passport.values)
      raise Error, :transformation_did_not_yield_elements unless result.is_a?(Array)

      result
    rescue Soya::Error
      raise Error, :transformation_failed
    end
  end
end
