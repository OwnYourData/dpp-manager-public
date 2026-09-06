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
  end
end
