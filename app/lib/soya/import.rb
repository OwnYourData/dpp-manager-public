module Soya
  # Bringing a product type into the vault, and the one moment in the
  # application's life that needs a network.
  #
  # Order matters and is not obvious: the structure is stored *before* the forms
  # are generated, because generating a form means asking soya-web-cli, and
  # soya-web-cli answers by pulling the structure back out of this application.
  # A structure that is not stored yet cannot be pulled.
  #
  # A failed refresh leaves the previous copy in place. The operator keeps
  # working with the version they had rather than losing the type because a
  # repository was down.
  module Import
    Result = Struct.new(:ok, :error, :languages, keyword_init: true) do
      def ok? = ok
    end

    module_function

    def refresh(product_type)
      structure = fetch_structure(product_type.repo_base_url, product_type.structure_name)

      product_type.update!(
        jsonld:      structure.jsonld,
        yaml:        structure.yaml,
        dri:         structure.dri,
        fetched_at:  Time.current,
        fetch_error: nil
      )

      product_type.update!(forms: JSON.generate(generate_forms(product_type)))
      fetch_transformation(product_type)
      fetch_reverse_transformation(product_type)

      Event.record!(:product_type_fetched,
        label: product_type.label, structure: product_type.structure_name,
        repo: product_type.repo_base_url, dri: product_type.dri)

      Result.new(ok: true, languages: product_type.forms_by_language.keys)
    rescue Error => e
      # A failed refresh leaves the previous copy in place — but a first fetch
      # that failed has no previous copy, and the structure is stored before the
      # forms are generated. Without this a row that never got a form would say
      # "ready" and hand the operator an empty one.
      product_type.update_columns(
        fetch_error: e.message,
        fetched_at:  (product_type.forms_by_language.any? ? product_type.fetched_at : nil),
        updated_at:  Time.current
      )
      Event.record!(:product_type_fetch_failed,
        label: product_type.label, structure: product_type.structure_name, message: e.message)

      Result.new(ok: false, error: e.message)
    end

    # The repository first, the copy in the image second.
    #
    # That order is the whole design: "Fetch again" has to mean the repository,
    # or the button is a lie; and a first start without a network has to end
    # with a usable product type, or the promise this application makes about
    # working offline is only true from the second day on. A structure the image
    # does not carry raises as before — there is nothing to fall back to, and
    # pretending otherwise would leave a type that looks fetched and is empty.
    def fetch_structure(base, name)
      Repository.fetch(base, name)
    rescue Error => e
      Bundled.fetch(name) || raise(e)
    end

    # The transformation, if this type names one.
    #
    # Fetched in the same breath as the structure and cached the same way, so a
    # passport can be submitted without a repository being reachable. A failure
    # here does NOT fail the refresh: a type whose form works and whose
    # transformation is stale is still usable for everything up to submitting,
    # and the shortfall is recorded rather than thrown.
    def fetch_transformation(product_type)
      return unless product_type.transformation?

      structure = fetch_structure(product_type.repo_base_url, product_type.transformation_name)
      product_type.update_columns(transformation_jsonld: structure.jsonld,
                                  transformation_fetched_at: Time.current,
                                  updated_at: Time.current)
    rescue Error => e
      Event.record!(:product_type_fetch_failed,
        label: product_type.label, structure: product_type.transformation_name, message: e.message)
    end

    # The other direction: what turns a passport read from a service back into
    # answers for this form. Optional in the same way and for a stronger reason
    # — a type nobody ever reads foreign passports of does not need one, and a
    # missing one costs only that one screen.
    def fetch_reverse_transformation(product_type)
      return unless product_type.reverse_transformation?

      structure = fetch_structure(product_type.repo_base_url, product_type.reverse_transformation_name)
      product_type.update_columns(reverse_transformation_jsonld: structure.jsonld,
                                  reverse_transformation_fetched_at: Time.current,
                                  updated_at: Time.current)
    rescue Error => e
      Event.record!(:product_type_fetch_failed,
        label: product_type.label, structure: product_type.reverse_transformation_name, message: e.message)
    end

    # One form per language the application speaks. A structure whose form
    # overlays cover only one of them still yields a form for both: soya-web-cli
    # falls back to generating from base, annotation and validation when there
    # is no matching overlay, which is exactly the behaviour wanted here.
    #
    # A language that fails is left out rather than failing the whole refresh —
    # a German form missing is worth saying, but not worth discarding an English
    # one that works.
    def generate_forms(product_type)
      name = product_type.resolvable_name
      options = nil

      forms = ProductType::LANGUAGES.each_with_object({}) do |language, result|
        first = WebCli.form(name, language: language, tag: product_type.form_tag.presence)
        options ||= Array(first["options"])

        tag = product_type.form_tag.presence || sole_tag_for(options, language)
        # Asking again only when a tag was found on the first answer, because
        # the first answer is the generated form and the author's own is the
        # one they meant.
        result[language] = tag && product_type.form_tag.blank? ? WebCli.form(name, language: language, tag: tag) : first
      rescue Error
        next
      end

      raise Error, "no_form_generated" if forms.empty?

      product_type.update_columns(form_options: JSON.generate(options || []), updated_at: Time.current)
      forms
    end

    # A tag is used automatically only when the structure leaves no choice.
    # Two tagged forms for one language is a decision about which of the
    # author's forms this operator wants, and guessing it would be wrong half
    # the time and invisible either way — that one goes on the type's page.
    def sole_tag_for(options, language)
      tags = options
        .select { |option| option["language"].to_s == language && option["tag"].present? }
        .map { |option| option["tag"] }
        .uniq

      tags.first if tags.size == 1
    end
  end
end
