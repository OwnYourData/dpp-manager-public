module Soya
  # Checking a passport's answers against its structure.
  #
  # Two steps, and the first one is not optional: soya-web-cli validates JSON-LD,
  # not flat JSON, and answering it with a plain object gets "Input data is not
  # valid JSON-LD!" — which reads like a bug in the data and is really a missing
  # step. So the answers go through acquire first, which is what turns them into
  # the shape the SHACL shapes are written against.
  #
  # The other half of this file is about the report that comes back. It is
  # rdf-validate-shacl's, passed through soya-js unchanged, and it is written for
  # a machine: the message is a list of RDF literal terms rather than a sentence,
  # the field is an IRI hidden among the entry's other values, and a violated
  # sh:in names the blank node holding the list rather than what is in it. Handed
  # to an operator as it stands it reads as a stack trace. Everything below turns
  # one entry into one sentence that names the field they were looking at.
  module Validation
    Result = Struct.new(:valid, :problems, keyword_init: true) do
      def valid? = valid
    end

    # What rdf-validate-shacl puts where a message should be when the message
    # was a blank node: its generated name, "df_17_85".
    BLANK_NODE = /\A(?:_:)?df_\d+_\d+\z/

    module_function

    def check(passport)
      type = passport.product_type
      return nil unless type&.fetched?

      document = WebCli.acquire(type.resolvable_name, passport.values)
      report   = WebCli.validate(type.resolvable_name, document)

      # The product type's own configuration is checked with it, so that a
      # passport that contradicts it is held back by the same second click.
      configured = passport.configuration_problems
      Result.new(valid: report["isValid"] == true && configured.empty?,
                 problems: problems_in(report, type) + configured)
    end

    # SHACL results and the class check are two different failures with the same
    # consequence, so they are counted together. A structure whose target class
    # is absent from the data reports the second and no violations at all, and
    # calling that "valid" would be the worst kind of wrong answer.
    def problems_in(report, type = nil)
      fields = type ? form_fields(type) : {}

      Array(report["results"]).map { |entry| describe(entry, fields) } +
        Array(report["classChecks"]).map { |check| class_check_text(check) }
    end

    def describe(entry, fields)
      key   = field_key(entry, fields)
      field = fields.dig(key, :label) if key
      text  = message_for(entry, fields[key])

      field.present? ? "#{field}: #{text}" : text
    end

    # The message is an RDF literal term, or a list of them — an object with a
    # "value", a "datatype" and a "language", not a string. Printing it gives the
    # Ruby rendering of that hash, which is what an operator saw before this
    # existed.
    def message_for(entry, field)
      texts = Array.wrap(entry["message"] || entry["resultMessage"])
                   .map { |message| message.is_a?(Hash) ? message["value"].to_s : message.to_s }
                   .reject(&:blank?)

      text = texts.join("; ")
      return I18n.t("passports.problem.unnamed") if text.blank?

      # A structure that words its own message in more than one language
      # (sh:message with a de and an en literal) reaches the report as the name
      # of the blank node holding them -- "df_17_85" -- and not as either
      # sentence. The sentences are in the structure, so they are taken from
      # there, in the language the operator is reading.
      if BLANK_NODE.match?(text)
        own = field && field[:message]
        return own.presence || I18n.t("passports.problem.unnamed")
      end

      # "Value is not in Blank node df_6_121" is the library naming the node that
      # holds an sh:in list. The list itself is right there in the form's schema,
      # so say what is allowed instead of what the node is called.
      allowed = field && field[:allowed]
      return I18n.t("passports.problem.one_of", values: allowed.join(", ")) if text.include?("Blank node") && allowed.present?

      count_text(text) || text
    end

    # The library's words for sh:minCount and sh:maxCount. "Less than 1 values"
    # is how an empty mandatory field is reported, and it is the most common
    # thing an operator will see here.
    def count_text(text)
      case text
      when /\ALess than 1 values?\z/     then I18n.t("passports.problem.required")
      when /\ALess than (\d+) values?\z/ then I18n.t("passports.problem.at_least", count: Regexp.last_match(1).to_i)
      when /\AMore than (\d+) values?\z/ then I18n.t("passports.problem.at_most", count: Regexp.last_match(1).to_i)
      end
    end

    # The structure's own messages, by field, in one language. They sit on the
    # property shapes of the validation overlay as sh:message -- a plain string,
    # a map of language to text, or a list of language-tagged literals, depending
    # on how the structure was written and expanded.
    def messages_in(structure, language)
      graph = structure.is_a?(Hash) ? Array(structure["@graph"]) : []

      graph.each_with_object({}) do |node, found|
        next unless node.is_a?(Hash)

        Array(node["sh:property"]).each do |shape|
          next unless shape.is_a?(Hash) && shape["sh:path"].is_a?(String)

          text = localized(shape["sh:message"], language)
          found[shape["sh:path"].split(/[\/#:]/).last] = text if text.present?
        end
      end
    rescue StandardError
      {}
    end

    def localized(message, language)
      wanted = [ language.to_s, I18n.default_locale.to_s ]

      case message
      when String then message
      when Hash
        return message["@value"].to_s if message.key?("@value")

        wanted.map { |lang| message[lang] }.find(&:present?) || message.values.first.to_s
      when Array
        tagged = message.select { |entry| entry.is_a?(Hash) }
        pick = wanted.map { |lang| tagged.find { |entry| entry["@language"].to_s == lang } }.compact.first
        (pick || tagged.first)&.dig("@value").to_s.presence || message.find { |entry| entry.is_a?(String) }
      end
    end

    def class_check_text(check)
      name = check.is_a?(Hash) ? (check["name"] || check["message"]) : check
      I18n.t("passports.problem.missing_class", name: name.to_s.split("/").last.presence || name)
    end

    # Which field an entry is about.
    #
    # soya-js builds each result as `{ id: focusNode, message, ...path }`, so the
    # property IRI arrives under whichever keys the RDF term happened to carry —
    # and can overwrite `id` on the way. Rather than depend on that, every string
    # in the entry is considered and the first one whose last segment is a field
    # of this form wins. A segment that is not a field of the form cannot be the
    # answer, which is what makes guessing safe here.
    def field_key(entry, fields)
      iris_in(entry).map { |iri| iri.split(/[\/#]/).last }.find { |segment| fields.key?(segment) }
    end

    def iris_in(value)
      case value
      when String then value.start_with?("http") ? [ value ] : []
      when Hash   then value.values.flat_map { |inner| iris_in(inner) }
      when Array  then value.flat_map { |inner| iris_in(inner) }
      else []
      end
    end

    # The fields of the form the operator is actually looking at: their labels in
    # the current language, and the values a closed list allows.
    def form_fields(type)
      form       = type.form_for(I18n.locale) || {}
      properties = form.dig("schema", "properties") || {}
      ui_labels  = labels_in(form["ui"])
      messages   = type.respond_to?(:structure) ? messages_in(type.structure, I18n.locale) : {}

      properties.each_with_object({}) do |(key, property), result|
        result[key] = {
          label:   ui_labels[key].presence || property["title"].presence || key,
          allowed: allowed_values(property),
          message: messages[key]
        }
      end
    end

    # JSON Forms keeps the label on the control, not in the schema, and the
    # control names its field with a JSON pointer — "#/properties/colourTemperature".
    def labels_in(node, found = {})
      case node
      when Hash
        scope = node["scope"].to_s
        found[scope.split("/").last] = node["label"] if scope.present? && node["label"].present?
        node.each_value { |inner| labels_in(inner, found) }
      when Array
        node.each { |inner| labels_in(inner, found) }
      end

      found
    end

    def allowed_values(property)
      return Array(property["enum"]).map(&:to_s) if property["enum"].present?

      Array(property["oneOf"]).filter_map { |option|
        option["title"].presence || option["const"]&.to_s
      }
    end
  end
end
