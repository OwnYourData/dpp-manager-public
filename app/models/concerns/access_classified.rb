# The access classes of a product type: which element path of its passports
# is public, for readers with a legitimate interest, or for authorities, and
# the access policy the DPP Service gets from that.
#
# Off by default. A type whose policy is not switched on behaves exactly as
# before: its passports are public as a whole and nothing about access is sent.
#
# Three inputs, kept apart:
#
#   access_paths     what the transformation makes of the fields (traced, cached
#                    per version of the transformation)
#   suggestions      what the structure's author suggests, from an
#                    OverlayClassification
#   access_classes   what the operator decided, per path
#
# The operator's decision wins wherever there is one. A path without one —
# every path before the first save, a path a new transformation adds — shows
# the suggestion.
module AccessClassified
  extend ActiveSupport::Concern

  # The access_paths rows, traced again when the structure or the
  # transformation was fetched since. Raises Dpp::AccessPaths::Error when the
  # transformation cannot be asked.
  def access_rows
    source = access_paths_source
    cached = parsed(access_paths)
    return cached["rows"] if cached.is_a?(Hash) && cached["source"] == source

    rows = Dpp::AccessPaths.for(self).rows
    update_columns(access_paths: JSON.generate("source" => source, "rows" => rows))
    rows
  end

  # What the traced paths depend on: the fields come from the structure, the
  # paths from the transformation.
  def access_paths_source
    "#{transformation_resolvable_name} #{fetched_at.to_i}"
  end

  def access_classes_hash
    value = parsed(access_classes)
    value.is_a?(Hash) ? value : {}
  end

  # What the structure's OverlayClassification says, by field: the strictest
  # class of the vocabulary it names for the field. Other classifications
  # ("pii") are ignored.
  def access_class_suggestions
    graph = Array(structure&.dig("@graph"))
    graph.each_with_object({}) do |node, found|
      next unless node.is_a?(Hash) && node.key?("classification")

      field = node["@id"].to_s.split("/").last
      Array(node["classification"]).each do |value|
        cls = Dpp::AccessPolicy.notation(value)
        found[field] = Dpp::AccessPolicy.stricter(found[field], cls) if cls
      end
    end
  rescue JSON::ParserError
    {}
  end

  def suggests_access_classes? = access_class_suggestions.any?

  # The class of every path: the operator's, or the suggestion.
  def effective_access_classes(rows = access_rows)
    suggested = Dpp::AccessPolicy.suggested(rows, access_class_suggestions)
    decided = access_classes_hash
    rows.to_h { |row| [ row["path"], decided[row["path"]] || suggested[row["path"]] ] }
  end

  # Stores the operator's classes for the paths of +rows+ and whether the policy
  # is on. A changed set of rules while it is on is a new version; switching it
  # on for the first time is version 1. Returns true when the version changed.
  def store_access_classes!(classes, enabled:, rows: access_rows)
    known = rows.map { |row| row["path"] }
    chosen = classes.to_h.slice(*known).select { |_path, cls| Dpp::AccessPolicy::CLASSES.include?(cls) }
    merged = effective_access_classes(rows).merge(chosen)

    self.access_classes = JSON.generate(merged)
    self.access_policy_enabled = enabled

    bumped = false
    if enabled
      digest = Dpp::AccessPolicy.digest(merged)
      if digest != access_policy_digest || access_policy_version.to_i.zero?
        self.access_policy_version = access_policy_version.to_i + 1
        self.access_policy_digest = digest
        bumped = true
      end
    end

    save!
    bumped
  end

  # Moves to the next version without a change of rules: the id of the current
  # one is taken at the service by different content (a vault restored from an
  # older backup, two installations with the same identity).
  def skip_access_policy_version!
    update!(access_policy_version: access_policy_version.to_i + 1)
  end

  def access_policy_id(did = Identity.current&.did)
    return nil if did.blank? || access_policy_version.to_i.zero?

    Dpp::AccessPolicy.id_for(did, structure_name, access_policy_version)
  end

  def access_policy_document(did = Identity.current&.did)
    id = access_policy_id(did)
    return nil if id.nil?

    Dpp::AccessPolicy.build(id: id, title: label, classes: access_classes_hash)
  end

  def record_access_policy_registered!(id, base_url)
    update!(access_policy_registered_id: id, access_policy_registered_to: base_url,
            access_policy_registered_at: Time.current)
  end

  def access_policy_registered_at?(base_url, did = Identity.current&.did)
    access_policy_registered_id.present? && access_policy_registered_id == access_policy_id(did) &&
      access_policy_registered_to == base_url
  end

  # Passports already classified by one of this type's policies. Once there is
  # one, the policy cannot be switched off: the service never takes a policy off
  # a passport, and new passports without one would be inconsistent with it.
  def classified_passports
    Passport.where(product_type_id: id).where.not(access_policy_id: [ nil, "" ])
  end

  private

  def parsed(text)
    text.present? ? JSON.parse(text) : nil
  rescue JSON::ParserError
    nil
  end
end
