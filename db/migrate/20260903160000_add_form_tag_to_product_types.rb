class AddFormTagToProductTypes < ActiveRecord::Migration[8.1]
  def change
    # Which of a structure's forms to use.
    #
    # Asking soya-web-cli for a form in a language is not enough: a structure
    # can carry several form overlays for the same language, told apart only by
    # their tag, and a request without one gets the *generated* form back — the
    # author's careful grouping silently ignored, with no error and no hint that
    # something was skipped.
    add_column :product_types, :form_tag, :string

    # What the structure reported it has: [{"language":"de","tag":"dpp"}, …].
    # Kept so the operator can be shown the choice when there is one, without a
    # second round trip to a repository that may no longer be reachable.
    add_column :product_types, :form_options, :text
  end
end
