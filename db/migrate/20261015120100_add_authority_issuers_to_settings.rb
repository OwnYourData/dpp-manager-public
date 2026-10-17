# frozen_string_literal: true

# Who the DPP Service takes grants for authorities from: its list of authority
# issuers, as /.well-known/dpp-service published it when it was last asked.
# Kept here so the page can show it without going to the network.
class AddAuthorityIssuersToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :service_authority_issuers, :text
    add_column :settings, :service_authority_issuers_at, :datetime
  end
end
