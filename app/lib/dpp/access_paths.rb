require "date"

module Dpp
  # Which element paths of EN 18223 a passport of a product type can carry, and
  # which form fields end up at each of them.
  #
  # An access policy addresses element paths (ProductIdentification/SerialNumber);
  # the operator thinks in form fields (serialNumber). The only place that knows
  # how one becomes the other is the type's transformation, a jq programme in a
  # SOyA structure. A second, hand-kept table of the same mapping would be a
  # second opinion about the transformation and would drift from it.
  #
  # So the transformation is asked. Every field of the structure is filled with
  # a marker value of its own type — a string that names it, a number nobody
  # would type, a date of its own — the transformation runs once, and the
  # markers are looked for in the element tree that comes back. A boolean has
  # only two values and cannot carry a marker; each boolean field gets a run of
  # its own in which it is the only answer, and the element that comes back
  # holding `true` is its element.
  #
  # Three shapes need care:
  #
  # - A MultiValuedDataElement is one path. Its items belong to it and share its
  #   class at the service, so whatever is inside it counts for it.
  # - An element whose elementId is itself an answer (a hazardous substance
  #   named by the substance) has no path a policy could name in advance. What
  #   is found inside it counts for the collection around it.
  # - A list is filled with two items. When its items come back at different
  #   paths (Document1, Document2), the list counts for the path they share:
  #   a third item at the service must be covered as well.
  #
  # What the transformation computes rather than passes on cannot be traced.
  # Such an element is still listed, without fields; it starts as authority.
  #
  # Runs in soya-web-cli, like every transformation in this application.
  module AccessPaths
    class Error < StandardError; end

    # Marker numbers sit far above any value a form would hold and are unique
    # per field, so a number that comes back says which field it was.
    NUMBER_BASE = 7_300_000
    STRING_MARKER = /PROBE(\d+)X/
    DATE_BASE = Date.new(1901, 1, 1)

    Result = Struct.new(:rows, :source, keyword_init: true)

    module_function

    # The paths of +type+ as [{ "path" => ..., "fields" => [...] }], in the
    # order the transformation emits them, with the transformation's resolvable
    # name as source. Raises Error when the transformation cannot be asked.
    def for(type)
      raise Error, "no_transformation" unless type&.transformation?
      raise Error, "transformation_not_fetched" unless type.transformation_fetched?

      structure = type.structure
      raise Error, "structure_not_fetched" if structure.nil?

      name = type.transformation_resolvable_name
      rows = trace(structure) { |answers| elements_of(Soya::WebCli.transform(name, answers)) }
      Result.new(rows: rows, source: name)
    rescue Soya::Error
      raise Error, "transformation_failed"
    end

    # The tracing itself, with the transformation passed in as a block that
    # takes answers and returns the element array. Kept apart so it can be run
    # against jq directly.
    def trace(structure, &transform)
      fields = Fields.new(structure)
      probe = Probe.new(fields)

      collector = Collector.new
      collector.walk(transform.call(probe.answers), probe)

      fields.booleans.each do |field|
        collector.walk(transform.call({ field => true }), BooleanProbe.new(field))
      end

      collector.rows(lists: fields.lists)
    end

    def elements_of(result)
      elements = result.is_a?(Hash) ? result["elements"] : result
      raise Error, "transformation_did_not_yield_elements" unless elements.is_a?(Array)

      elements
    end

    # The fields of a structure's main base, read from its JSON-LD.
    class Fields
      XSD = "xsd:".freeze

      attr_reader :top, :booleans, :lists

      def initialize(structure)
        graph = Array(structure["@graph"])
        @classes = graph.select { |node| node["@type"] == "owl:Class" }.map { |node| node["@id"] }
        @properties = graph.select { |node| %w[owl:DatatypeProperty owl:ObjectProperty].include?(node["@type"]) }
        main = main_base
        @top = properties_of(main)
        @booleans = @top.select { |property| range(property) == "boolean" }.map { |property| property["@id"] }
        @lists = @top.select { |property| list?(property) }.map { |property| property["@id"] }
      end

      def properties_of(base)
        @properties.select { |property| Array(property["domain"]).include?(base) }
      end

      # "string", "integer", "boolean", ... for a datatype; the class name for an
      # object; for a list, the type of its items.
      def range(property)
        type = list?(property) ? Array(property["soya:containerElementTypes"]).first : property["range"]
        name = type.to_s.split("/").last.to_s
        name.start_with?(XSD) ? name.delete_prefix(XSD) : name
      end

      def list?(property)
        property["range"].to_s.end_with?("#List")
      end

      def class?(name) = @classes.include?(name)

      private

      # The base no other base refers to. In a structure with nested bases (a
      # battery with its substances) that is the one the form is for.
      def main_base
        referenced = @properties.map { |property| range(property) }
        @classes.find { |name| !referenced.include?(name) } || @classes.first
      end
    end

    # Answers with a marker in every field, and the way back from a marker to
    # its field.
    class Probe
      attr_reader :answers

      def initialize(fields)
        @fields = fields
        @owner = {}
        @dates = {}
        @answers = fields.top.each_with_object({}) do |property, answers|
          id = property["@id"]
          next if fields.booleans.include?(id)

          answers[id] = value_for(property, id, depth: 0)
        end
      end

      # The fields a value found in the element tree came from.
      def fields_in(value)
        case value
        when String
          found = value.scan(STRING_MARKER).flatten.filter_map { |n| @owner[n.to_i] }
          found << @dates[value] if @dates.key?(value)
          found
        when Numeric
          @owner.key?((value - NUMBER_BASE).floor) && value >= NUMBER_BASE ? [ @owner[(value - NUMBER_BASE).floor] ] : []
        else
          []
        end
      end

      private

      def value_for(property, owner, depth:)
        type = @fields.range(property)
        if @fields.list?(property)
          Array.new(2) { scalar_or_object(type, owner, depth) }
        else
          scalar_or_object(type, owner, depth)
        end
      end

      def scalar_or_object(type, owner, depth)
        return nested(type, owner, depth) if @fields.class?(type)

        n = mark(owner)
        case type
        when "integer", "int", "long", "nonNegativeInteger", "positiveInteger" then NUMBER_BASE + n
        when "decimal", "double", "float" then NUMBER_BASE + n + 0.5
        when "boolean" then true
        when "date"
          date = (DATE_BASE + n).iso8601
          @dates[date] = owner
          date
        else "PROBE#{n}X"
        end
      end

      # An item of a list of objects: every field of it carries a marker of the
      # list it belongs to. Deep enough for a list in a list, and no deeper.
      def nested(type, owner, depth)
        return {} if depth > 1

        @fields.properties_of(type).to_h do |property|
          [ property["@id"], value_for(property, owner, depth: depth + 1) ]
        end
      end

      def mark(owner)
        n = @owner.size + 1
        @owner[n] = owner
        n
      end
    end

    # The run for one boolean field: `true` anywhere is that field.
    class BooleanProbe
      def initialize(field) = @field = field

      def fields_in(value) = value == true ? [ @field ] : []
    end

    # Walks element trees and collects paths and the fields found at them.
    class Collector
      STRUCTURAL = %w[elements elementId objectType].freeze

      def initialize
        @paths = {}
      end

      def walk(elements, probe)
        Array(elements).each { |element| visit(element, [], false, probe) }
      end

      # [{ "path", "fields" }] in the order paths were first seen. A list whose
      # items came back at several paths counts for the path they share.
      #
      # Grouped by top-level element, in the order the groups first appeared:
      # a path only a later run found (a boolean) joins its collection rather
      # than trailing behind everything else.
      def rows(lists: [])
        lists.each { |field| gather(field) }
        groups = @paths.keys.map { |path| path.split("/").first }.uniq
        @paths.each_with_index
              .sort_by { |(path, _), index| [ groups.index(path.split("/").first), index ] }
              .map { |(path, fields), _| { "path" => path, "fields" => fields.uniq } }
      end

      private

      # +held+ is true below an element that is one path as a whole (a
      # MultiValuedDataElement) or below an elementId that is an answer: from
      # there down, everything counts for +stable+.
      def visit(element, stable, held, probe)
        return unless element.is_a?(Hash)

        id = element["elementId"].to_s
        id_fields = probe.fields_in(id)
        here = if held || id_fields.any? || id.empty?
          stable
        else
          stable + [ id ]
        end
        note(here, id_fields) if id_fields.any?
        held ||= id_fields.any?

        children = element["elements"]
        multi = element["objectType"] == "MultiValuedDataElement"

        if children.is_a?(Array) && !multi
          children.each { |child| visit(child, here, held, probe) }
          note(here, []) if held && here.any?
        else
          note(here, []) unless held && here.empty?
          collect(element, here, probe)
          Array(children).each { |child| collect_all(child, here, probe) } if multi
        end
      end

      # Every member that can hold an answer: the value, the address of a
      # related resource, its title and language.
      def collect(element, here, probe)
        element.each do |key, value|
          next if STRUCTURAL.include?(key)

          Array(value).each { |item| note(here, probe.fields_in(item)) }
        end
      end

      def collect_all(element, here, probe)
        return unless element.is_a?(Hash)

        note(here, probe.fields_in(element["elementId"].to_s))
        collect(element, here, probe)
        Array(element["elements"]).each { |child| collect_all(child, here, probe) }
      end

      def note(path_segments, fields)
        return if path_segments.empty?

        path = path_segments.join("/")
        @paths[path] ||= []
        @paths[path].concat(fields)
      end

      def gather(field)
        holding = @paths.select { |_path, fields| fields.include?(field) }.keys
        return if holding.size < 2

        shared = holding.map { |path| path.split("/") }.reduce { |a, b| common(a, b) }
        return if shared.empty?

        target = shared.join("/")
        position = @paths.keys.index(holding.first)
        holding.each do |path|
          next if path == target

          @paths[path].delete(field)
          @paths.delete(path) if @paths[path].empty?
        end
        rest = @paths.to_a
        rest.reject! { |path, _| path == target }
        rest.insert(position || rest.size, [ target, (@paths[target] || []) + [ field ] ])
        @paths = rest.to_h
      end

      def common(a, b)
        a.zip(b).take_while { |x, y| x == y }.map(&:first)
      end
    end
  end
end
