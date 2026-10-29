require "yaml"
require "json"

module Soya
  # The structures that ship inside the image.
  #
  # Two jobs, and they are different enough to say apart.
  #
  # The first is the one the operator notices: a fresh installation already has
  # a working product type, with its form and its transformation, without
  # anybody typing a repository address. That is Seed.
  #
  # The second is quieter. A bundled structure is also the fallback when the
  # repository cannot be reached, which is what makes the promise "this works
  # without a network" true on the very first start as well as later. The
  # network is still asked first — "Fetch again" has to mean what it says — and
  # the copy in here is only used when the answer does not come.
  #
  # The .jsonld files are what the repository serves, with the shared context
  # already resolved into them (see Repository.inline_context), so nothing in
  # them points outside the image. They are refreshed with `rake soya:bundle`
  # after the YAML beside them has been pushed.
  module Bundled
    module_function

    def dir = Rails.root.join("soya")

    def manifest
      raw = YAML.safe_load_file(dir.join("bundled.yml"))
      raw.is_a?(Array) ? raw : []
    rescue Errno::ENOENT, Psych::SyntaxError
      []
    end

    # Every structure name the image carries, both transformations included.
    def names
      manifest.flat_map { |entry|
        [ entry["structure"], entry["transformation"], entry["reverse_transformation"] ]
      }.compact
    end

    def include?(name) = names.include?(name.to_s)

    # The bundled structure under this name, in the shape Repository.fetch
    # returns — so a caller cannot tell the two apart, which is the point.
    #
    # Returns nil rather than raising when there is none: the caller is a rescue
    # path, and "no bundled copy" is a normal answer there.
    def fetch(name)
      return nil unless include?(name)

      jsonld = dir.join("#{name}.jsonld")
      return nil unless jsonld.exist?

      Repository::Structure.new(
        name:   name.to_s,
        jsonld: JSON.generate(JSON.parse(jsonld.read)),
        yaml:   read_optional("#{name}.yaml"),
        dri:    nil
      )
    rescue JSON::ParserError
      nil
    end

    # The author's YAML is what soya-form fetches while it renders. A structure
    # bundled without one is not broken, so this must not raise.
    def read_optional(filename)
      path = dir.join(filename)
      path.exist? ? path.read : nil
    end

    # What `rake soya:bundle` does: the JSON-LD of every bundled structure,
    # fetched from its repository and written beside the YAML. Returns the
    # problems found, an empty list when there are none.
    #
    # It also checks that the repository serves each structure's YAML, and the
    # same YAML as the file beside it. A structure pushed with
    # `soya init | soya push` has JSON-LD only, and an installation that
    # fetches it again gets a form that does not render; `soya init-push`
    # stores the YAML as well. Transformations have no form and are not
    # checked for one.
    def refresh!(out: $stdout)
      manifest.flat_map do |entry|
        repo = entry["repo"].to_s

        [ entry["structure"], entry["transformation"], entry["reverse_transformation"] ].compact.filter_map do |name|
          structure = Repository.fetch(repo, name)
          path = dir.join("#{name}.jsonld")
          path.write("#{JSON.pretty_generate(JSON.parse(structure.jsonld))}\n")
          out.puts "#{name}: #{path.size} bytes from #{repo}"

          yaml_problem(name, structure.yaml) if name == entry["structure"]
        rescue Error => e
          "#{name}: #{e.message}"
        end
      end
    end

    def yaml_problem(name, served)
      if served.blank?
        return "#{name}: the repository serves no YAML; push it again with `soya init-push`"
      end

      local = read_optional("#{name}.yaml")
      return nil if local.nil? || normalize(local) == normalize(served)

      "#{name}: the repository serves a different YAML than soya/#{name}.yaml"
    end

    def normalize(text) = text.gsub(/\r\n?/, "\n").rstrip
  end
end
