class AddCorrectionToPassports < ActiveRecord::Migration[8.1]
  def change
    # A fingerprint of what was sent, over the parts the operator controls: the
    # answers and the facility. It is what lets the page say "this differs from
    # the copy at the service" without rebuilding the document — which would
    # mean running the transformation on every page view.
    #
    # A stored fingerprint rather than a "changed" flag, because a flag has to be
    # set and cleared by somebody and can therefore be wrong. This cannot: it is
    # either the fingerprint of what the service holds or it is not.
    add_column :passports, :submitted_digest, :string

    # When the service last accepted a correction. Kept apart from submitted_at,
    # which stays the moment the passport first became somebody else's to serve.
    add_column :passports, :corrected_at, :datetime
  end
end
