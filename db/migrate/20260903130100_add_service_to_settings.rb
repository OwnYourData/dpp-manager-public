class AddServiceToSettings < ActiveRecord::Migration[8.1]
  def change
    change_table :settings, bulk: true do |t|
      # The DPP Service this operator writes to.
      t.string :service_base_url
      t.string :service_did          # from /.well-known/dpp-service
      t.string :service_audience     # what a bearer token's `aud` has to carry
      t.datetime :service_checked_at

      # The custodian, optional: without it passports stay in the service's own
      # database. base_url and collection_id are both public values — what is
      # secret in this arrangement is nothing, which is the point of the
      # delegation model.
      t.string :custodian_base_url
      t.string :custodian_collection_id

      t.datetime :setup_completed_at
    end
  end
end
