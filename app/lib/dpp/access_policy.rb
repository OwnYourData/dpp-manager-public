require "digest"
require "json"

module Dpp
  # Who may read which attribute of a passport of one product type.
  #
  # The vocabulary is the DPP Service's (https://w3id.org/soya/dpp-access/v1):
  # three access classes, each one reading everything the one before it reads.
  #
  #   public               anyone, without a token
  #   legitimateInterest   readers the economic operator grants it to
  #   authority            authorities, granted by issuers the service trusts
  #
  # The policy is a document of its own, never part of the passport. It is
  # registered with the service once per version and named by its id in every
  # passport of the type. A registered policy never changes at the service, so a
  # changed set of classes is a new version under a new id.
  #
  # Rules address element paths, not form fields: the policy speaks about the
  # passport the service holds, and the passport only has elements. Which form
  # field ends up at which path is worked out by Dpp::AccessPaths.
  module AccessPolicy
    SCHEME = "https://w3id.org/soya/dpp-access/v1".freeze

    # Ordered from the most open to the most closed.
    CLASSES = %w[public legitimateInterest authority].freeze

    # What a path no field could be traced to starts as. A value withheld by
    # mistake can be released later; one published by mistake cannot be
    # withdrawn.
    UNTRACED = "authority".freeze

    # What a traced field starts as when its structure suggests nothing: what a
    # passport without a policy shows today.
    UNSUGGESTED = "public".freeze

    module_function

    # The notation of a class given as notation or as IRI; nil for anything that
    # is not a class of this vocabulary. A classification overlay can carry
    # classes of other schemes too ("pii"), and those are not ours to read.
    def notation(value)
      text = value.to_s.strip
      text = text.delete_prefix("#{SCHEME}#") if text.start_with?("#{SCHEME}#")
      CLASSES.include?(text) ? text : nil
    end

    def stricter(a, b)
      return b if a.nil?
      return a if b.nil?

      CLASSES.index(a) >= CLASSES.index(b) ? a : b
    end

    # The class each path starts with before the operator has said anything.
    #
    # A path that carries no field gets UNTRACED. A path that carries fields gets
    # the strictest class the structure suggests for any of them, or UNSUGGESTED
    # when it suggests none.
    def suggested(rows, suggestions)
      rows.to_h do |row|
        fields = Array(row["fields"])
        cls = if fields.empty?
          UNTRACED
        else
          fields.map { |field| suggestions[field] || UNSUGGESTED }.reduce { |a, b| stricter(a, b) }
        end
        [ row["path"], cls ]
      end
    end

    # The id of one version of the policy of a product type.
    #
    # Under the operator's DID: an absolute URI that nobody else issues, and that
    # says whose policy it is when it shows up in a header or a log. The service
    # keeps the policies of different operators apart anyway.
    def id_for(did, structure_name, version)
      "#{did}/access-policies/#{structure_name}/#{version}"
    end

    # The policy document of access-policy.schema.json: one rule per path, in
    # path order, as notations. No default, so whatever no rule reaches — an
    # element a later transformation adds, a field that could not be traced — is
    # authority at the service.
    def build(id:, title:, classes:)
      {
        "id"     => id,
        "title"  => title.to_s.presence,
        "scheme" => SCHEME,
        "rules"  => rules(classes)
      }.compact
    end

    def rules(classes)
      classes.to_h.sort.map { |path, cls| { "path" => path, "accessClass" => cls } }
    end

    # Changes when, and only when, the rules change.
    def digest(classes)
      Digest::SHA256.hexdigest(JSON.generate(rules(classes)))
    end
  end
end
