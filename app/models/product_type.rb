# A kind of passport, described by a SOyA structure.
#
# The row is two things at once. Before it is fetched it is an address: a
# repository and a name in it, typed by the operator. After it is fetched it is
# also the structure itself — JSON-LD, the author's YAML, and a JSON Forms form
# per language. From then on nothing outside the vault is needed to render or
# validate, which is the whole reason the copies are kept rather than fetched
# each time.
class ProductType < ApplicationRecord
  include AccessClassified

  LANGUAGES = %w[en de].freeze

  # --- what the law says about this kind of product (ESPR Art. 9) -----------
  #
  # The data carriers a delegated act may prescribe (Art. 9(2)(b)) and where
  # the carrier may sit (Art. 9(2)(c), Art. 10(1)(b)).
  CARRIERS   = %w[qr datamatrix nfc rfid].freeze
  PLACEMENTS = %w[product packaging documentation].freeze

  # The fields that make up the configuration. A change to any of them is a new
  # configuration version; the structure's own fields are versioned by their
  # fetch time instead.
  CONFIGURATION = %i[legal_act legal_act_url legal_act_valid_from legal_act_valid_until
                     dpp_required_from granularity carriers carrier_placement carrier_layout
                     availability_years].freeze

  serialize :carriers, coder: JSON, type: Array
  serialize :carrier_placement, coder: JSON, type: Array

  # A structure name is a path segment in the repository, and it ends up in a
  # URL that soya-web-cli builds. Keeping it to this alphabet means it never
  # needs escaping and can never walk out of the repository's namespace.
  NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/

  validates :label, presence: true, length: { maximum: 120 }
  validates :structure_name, presence: true, format: { with: NAME }
  validates :repo_base_url, presence: true
  validates :structure_name, uniqueness: { scope: :repo_base_url }
  validates :transformation_name, format: { with: NAME }, allow_blank: true
  validates :reverse_transformation_name, format: { with: NAME }, allow_blank: true
  validate  :repo_base_url_is_http
  validate  :transformation_is_a_different_structure

  validates :legal_act, length: { maximum: 200 }
  validates :carrier_layout, length: { maximum: 2000 }
  validates :granularity, inclusion: { in: Dpp::ProductIdentifier::GRANULARITIES }, allow_blank: true
  validates :availability_years, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 },
                                 allow_nil: true
  validate  :legal_act_url_is_http
  validate  :legal_act_period_is_ordered
  validate  :carriers_are_known

  before_save :count_configuration_change

  # Through the same normaliser both SOyA clients use, so a host typed without
  # a scheme is stored the way it will be requested. An address that cannot be
  # made into one is kept as typed, so the validation below can say so rather
  # than the field silently emptying itself.
  normalizes :repo_base_url, with: ->(value) { Soya.normalize_base(value) || value.to_s.strip }
  normalizes :structure_name, with: ->(value) { value.to_s.strip }
  normalizes :transformation_name, with: ->(value) { value.to_s.strip }
  normalizes :reverse_transformation_name, with: ->(value) { value.to_s.strip }
  normalizes :label, with: ->(value) { value.to_s.strip }
  normalizes :legal_act, :legal_act_url, :carrier_layout, :granularity, with: ->(value) { value.to_s.strip.presence }
  # Check boxes send an empty string beside what was ticked.
  normalizes :carriers, :carrier_placement, with: ->(value) { Array(value).map(&:to_s).compact_blank.uniq }

  default_scope { order(label: :asc) }

  scope :fetched, -> { where.not(fetched_at: nil) }

  def fetched? = fetched_at.present?

  # Whether anything of the legal configuration has been filled in at all.
  def configured? = CONFIGURATION.any? { |field| self[field].present? }

  # Whether a passport is required for this kind of product on a given day
  # (Art. 9(1)): only once the date is set and reached. Unset means nobody has
  # determined it yet, which is not the same as "not required".
  def dpp_required_on?(date = Date.current)
    dpp_required_from.present? && date >= dpp_required_from
  end

  # Whether the legal act is in force on a given day. An open end is in force.
  def legal_act_in_force_on?(date = Date.current)
    return false if legal_act.blank?
    return false if legal_act_valid_from.present? && date < legal_act_valid_from

    legal_act_valid_until.blank? || date <= legal_act_valid_until
  end

  def structure = jsonld.present? ? JSON.parse(jsonld) : nil

  def forms_by_language
    forms.present? ? JSON.parse(forms) : {}
  rescue JSON::ParserError
    {}
  end

  # The form for a language, falling back to the other one. A structure whose
  # form overlays cover only English still has to produce a usable form for a
  # German-speaking operator — an untranslated label beats an empty page.
  def form_for(language)
    all = forms_by_language
    all[language.to_s] || all[I18n.default_locale.to_s] || all.values.first
  end

  # The labels the form shows for its fields, by field name.
  #
  # Out of the UI schema and not out of the JSON Schema: JSON Forms puts the
  # label on the control rather than on the property, so anything built from the
  # schema alone shows `manufacturerName` where the form says "Manufacturer".
  def field_labels(language = I18n.locale)
    form = form_for(language)
    return {} if form.nil?

    labels = {}
    collect_labels(form["ui"], labels)
    labels
  end

  def source_url = "#{repo_base_url}/#{structure_name}"

  def form_options_list
    form_options.present? ? Array(JSON.parse(form_options)) : []
  rescue JSON::ParserError
    []
  end

  # The tags the structure offers for a language. More than one means the author
  # made several forms and somebody has to say which.
  def form_tags_for(language)
    form_options_list
      .select { |option| option["language"].to_s == language.to_s && option["tag"].present? }
      .map { |option| option["tag"] }.uniq
  end

  # The tag actually in force for a language: what the operator set, or the
  # structure's single offer for that language.
  #
  # It matters beyond the import, because soya-form does not use the form this
  # application stored — it fetches the author's YAML and picks an overlay
  # itself, filtering by tag and language. Without the tag it takes the first
  # that matches the language, which for a structure with several is a coin toss.
  def effective_form_tag(language = I18n.locale)
    return form_tag if form_tag.present?

    tags = form_tags_for(language)
    tags.first if tags.size == 1
  end

  def ambiguous_form_choice?
    form_tag.blank? && LANGUAGES.any? { |language| form_tags_for(language).size > 1 }
  end

  # The name soya-web-cli is asked for, which is not quite the structure's name.
  #
  # soya-js keeps a pulled structure in memory for thirty minutes. Refreshing a
  # type inside that window would otherwise generate the form from the copy it
  # already had, and the operator would see their correction ignored with no
  # indication why. Appending the moment of the fetch makes each version its own
  # cache entry; the local repository strips it again.
  #
  # It carries the row's id as well, because two repositories may publish a
  # structure under the same name and the local repository has to answer with
  # the right one — the name alone does not identify it.
  def resolvable_name
    fetched? ? "#{structure_name}~#{id}~#{fetched_at.to_i}" : structure_name
  end

  # The other direction, for the local repository: find the row a name asked for
  # by soya-web-cli belongs to. The name is checked against the row rather than
  # ignored, so a request that pairs one type's id with another's name is
  # refused instead of quietly answered.
  def self.resolve(resolvable)
    type, kind = resolve_document(resolvable)
    type if kind == :structure
  end

  # The same lookup, but for any of the three structures a type carries: the one
  # the form is generated from, the one that transforms its answers into the
  # element model, and the one that reads an element model back. All three are
  # pulled by soya-web-cli through this application, under names that differ
  # only in which of the row's name columns they match.
  #
  # Returns [type, :structure | :transformation | :reverse_transformation], or nil.
  def self.resolve_document(resolvable)
    name, id, = resolvable.to_s.split("~")
    return nil if name.blank?

    row = if id.present?
      unscoped.find_by(id: id)
    else
      unscoped.where(structure_name: name)
              .or(unscoped.where(transformation_name: name))
              .or(unscoped.where(reverse_transformation_name: name))
              .order(fetched_at: :desc).first
    end
    return nil if row.nil?

    return [ row, :structure ]      if row.structure_name == name
    return [ row, :transformation ] if row.transformation_name.present? && row.transformation_name == name
    if row.reverse_transformation_name.present? && row.reverse_transformation_name == name
      return [ row, :reverse_transformation ]
    end

    nil
  end

  def transformation? = transformation_name.present?

  def transformation_fetched? = transformation_fetched_at.present?

  # Same cache-busting shape as resolvable_name, and for the same reason: a
  # refreshed transformation must not be shadowed by soya-js's thirty-minute
  # copy of the previous one.
  def transformation_resolvable_name
    return nil unless transformation?

    transformation_fetched? ? "#{transformation_name}~#{id}~#{transformation_fetched_at.to_i}" : transformation_name
  end

  def reverse_transformation? = reverse_transformation_name.present?

  def reverse_transformation_fetched? = reverse_transformation_fetched_at.present?

  # Whether a passport written against this type can be read back into its form.
  # Both halves have to be here: a name without a fetched copy is an intention.
  def readable? = reverse_transformation? && reverse_transformation_fetched?

  def reverse_transformation_resolvable_name
    return nil unless reverse_transformation?

    if reverse_transformation_fetched?
      "#{reverse_transformation_name}~#{id}~#{reverse_transformation_fetched_at.to_i}"
    else
      reverse_transformation_name
    end
  end

  # What the repository answered with, condensed for the list: the classes the
  # structure defines and the overlays it carries. Read from the cached copy,
  # so it costs nothing and works offline.
  def summary
    doc = structure
    return nil if doc.nil?

    graph = doc["@graph"] || []
    {
      bases: graph.count { |node| node_type?(node, "Base") },
      overlays: graph.filter_map { |node| overlay_kind(node) }.tally
    }
  rescue StandardError
    nil
  end

  private

  # A new row that is configured starts at version 1; an unconfigured one stays
  # at 0, which reads as "no configuration" rather than as a first version.
  def count_configuration_change
    changed_fields = CONFIGURATION.map(&:to_s) & changed
    return if changed_fields.empty?
    return if new_record? && !configured?

    self.config_version    = config_version.to_i + 1
    self.config_changed_at = Time.current
  end

  def legal_act_url_is_http
    return if legal_act_url.blank?

    uri = URI.parse(legal_act_url)
    errors.add(:legal_act_url, :invalid) unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:legal_act_url, :invalid)
  end

  def legal_act_period_is_ordered
    return if legal_act_valid_from.blank? || legal_act_valid_until.blank?
    return if legal_act_valid_until >= legal_act_valid_from

    errors.add(:legal_act_valid_until, :greater_than_or_equal_to, count: I18n.l(legal_act_valid_from))
  end

  def carriers_are_known
    errors.add(:carriers, :inclusion) if (Array(carriers) - CARRIERS).any?
    errors.add(:carrier_placement, :inclusion) if (Array(carrier_placement) - PLACEMENTS).any?
  end

  def collect_labels(node, labels)
    case node
    when Array
      node.each { |child| collect_labels(child, labels) }
    when Hash
      scope = node["scope"].to_s
      if scope.start_with?("#/properties/") && node["label"].present?
        labels[scope.delete_prefix("#/properties/")] = node["label"]
      end
      collect_labels(node["elements"], labels) if node["elements"]
    end
  end

  def node_type?(node, suffix)
    Array(node["@type"]).any? { |type| type.to_s.split(/[:#\/]/).last == suffix }
  end

  def overlay_kind(node)
    Array(node["@type"]).filter_map { |type|
      name = type.to_s.split(/[:#\/]/).last
      name.delete_prefix("Overlay") if name.start_with?("Overlay") && name != "Overlay"
    }.first
  end

  # All three names resolve through the same local repository, so a row that
  # used one string twice would make one of them unreachable — and the one that
  # lost would be whichever the lookup happened to check first.
  def transformation_is_a_different_structure
    errors.add(:transformation_name, :taken) if transformation_name.present? && transformation_name == structure_name

    return if reverse_transformation_name.blank?

    if reverse_transformation_name == structure_name || reverse_transformation_name == transformation_name
      errors.add(:reverse_transformation_name, :taken)
    end
  end

  def repo_base_url_is_http
    uri = URI.parse(repo_base_url.to_s)
    return if uri.is_a?(URI::HTTP) && uri.host.present?

    errors.add(:repo_base_url, :invalid)
  rescue URI::InvalidURIError
    errors.add(:repo_base_url, :invalid)
  end
end
