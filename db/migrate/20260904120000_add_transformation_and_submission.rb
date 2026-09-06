class AddTransformationAndSubmission < ActiveRecord::Migration[8.1]
  def change
    # Which SOyA structure turns this type's form answers into the element model
    # of EN 18223. A second structure, not an overlay of the first: `soya
    # transform` takes the first overlay in the graph that carries an `engine`
    # field, so a structure can hold exactly one transformation and the form
    # structure's overlays are already spoken for.
    #
    # It is fetched and cached exactly like the form structure, and for the same
    # reason: submitting a passport must not depend on a repository being up.
    add_column :product_types, :transformation_name, :string
    add_column :product_types, :transformation_jsonld, :text
    add_column :product_types, :transformation_fetched_at, :datetime

    # The submission. `submitted_to` is the base URL the passport was actually
    # handed to — kept beside the endpoint the DID names, because those two
    # agreeing is the condition the service checks and disagreeing is the
    # failure that cannot be repaired.
    add_column :passports, :submitted_at, :datetime
    add_column :passports, :submitted_to, :string

    # What the service answered with: the stored document as it accepted it.
    # Kept so the operator can see what was sent and what came back without the
    # service having to be reachable.
    add_column :passports, :service_document, :text
  end
end
