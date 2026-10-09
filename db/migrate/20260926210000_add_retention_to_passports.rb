# frozen_string_literal: true

# When the product was placed on the market, how long its passport has to stay
# available, and the configuration it was issued under.
#
# placed_on_market_on is the start of the availability period (ESPR Art.
# 9(2)(i)); without it the period runs from the submission. retain_until is
# worked out once, at submission, from that start and the product type's
# availability in years, and it is sent to the service, which refuses to
# delete the passport before that day.
#
# configuration_snapshot is the product type's legal configuration and the
# version of its structure at the moment of submission (CFG-011): the product
# type can change afterwards, the passport keeps what it was issued under.
class AddRetentionToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :placed_on_market_on, :date
    add_column :passports, :retain_until, :date
    add_column :passports, :configuration_snapshot, :text
  end
end
