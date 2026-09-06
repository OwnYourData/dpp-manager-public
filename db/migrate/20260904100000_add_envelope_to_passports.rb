class AddEnvelopeToPassports < ActiveRecord::Migration[8.1]
  def change
    # The attributes of EN 18223:2026 Table 1 that the operator supplies. The
    # rest of the envelope is not stored because it is not theirs to choose:
    # dppStatus and lastUpdated belong to the service, economicOperatorId is the
    # identity, and dppSchemaVersion is a constant of the edition this
    # application writes.
    #
    # The identifier is the string on the data carrier. EN 18219:2026 3.1.25
    # makes it one value that identifies the product *and* links to the
    # passport — there is no second carrier token, which is why this is a URL
    # and not a serial number.
    add_column :passports, :unique_product_identifier, :string

    # model, batch or item. For a GS1 Digital Link the path already says which,
    # and the service refuses a declaration that contradicts it; for an
    # identification link the path is opaque and the declaration is all there is.
    add_column :passports, :granularity, :string

    # Optional in Table 1, and it is a product identifier of a place: the GS1
    # Digital Link of the facility, not a name.
    add_column :passports, :facility_id, :string
  end
end
