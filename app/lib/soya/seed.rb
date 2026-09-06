module Soya
  # Putting the bundled product types into a vault.
  #
  # Runs once, when a vault is created — not on every unlock. A type the
  # operator deleted is a decision, and an application that quietly puts it back
  # every morning is arguing with them. The product types page offers the same
  # thing as a button, which is the way back for a vault that already existed
  # before these structures shipped.
  module Seed
    Result = Struct.new(:installed, :failed, keyword_init: true)

    module_function

    def install!(locale = I18n.locale)
      installed = []
      failed    = []

      Bundled.manifest.each do |entry|
        name = entry["structure"].to_s
        repo = entry["repo"].to_s
        next if name.blank? || repo.blank?
        next if ProductType.unscoped.exists?(structure_name: name, repo_base_url: repo)

        type = ProductType.new(
          label:               label_for(entry, locale),
          structure_name:      name,
          repo_base_url:       repo,
          transformation_name: entry["transformation"].presence,
          reverse_transformation_name: entry["reverse_transformation"].presence
        )
        next failed << name unless type.save

        # The structure is read through the ordinary import, which asks the
        # repository first and falls back to the copy in the image. So an
        # installation with a network gets the current version, one without gets
        # a working one, and neither needs a second code path.
        result = Import.refresh(type)
        result.ok? ? installed << type : failed << name
      end

      Result.new(installed: installed, failed: failed)
    end

    # Is there anything left to install? What the button on the product types
    # page is shown for.
    def pending?
      Bundled.manifest.any? do |entry|
        entry["structure"].present? && entry["repo"].present? &&
          !ProductType.unscoped.exists?(structure_name: entry["structure"], repo_base_url: entry["repo"])
      end
    end

    def label_for(entry, locale)
      labels = entry["label"]
      return entry["structure"].to_s unless labels.is_a?(Hash)

      labels[locale.to_s].presence || labels[I18n.default_locale.to_s].presence ||
        labels.values.first.presence || entry["structure"].to_s
    end
  end
end
