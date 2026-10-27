# frozen_string_literal: true

# The hosts the DPP Service answers printed product identifiers on, as
# /.well-known/dpp-service published them when it was last asked, and when
# that was. Kept here so that a passport page can say whether its identifier
# leads anywhere without going to the network.
class AddCarrierHostsToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :service_carrier_hosts, :text
    add_column :settings, :service_carrier_hosts_at, :datetime
  end
end
