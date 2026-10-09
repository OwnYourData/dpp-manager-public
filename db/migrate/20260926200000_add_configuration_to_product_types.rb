# frozen_string_literal: true

# What the law says about a kind of product, beside what its structure says.
#
# ESPR Art. 9(2) has the delegated act fix, per product group, the data carrier
# and where it goes (b, c), the granularity (d) and how long the passport has to
# stay available (i); Art. 9(1) decides whether a passport is required at all.
# None of that is in a SOyA structure, which describes the data and nothing
# else, so it is kept on the product type next to it.
#
# All optional: a product type added before this existed stays valid, and a
# group whose delegated act is not out yet can still be worked with.
#
# config_version counts changes to these fields, so a passport can record
# which configuration it was issued under (CFG-011).
class AddConfigurationToProductTypes < ActiveRecord::Migration[8.1]
  def change
    add_column :product_types, :legal_act, :string
    add_column :product_types, :legal_act_url, :string
    add_column :product_types, :legal_act_valid_from, :date
    add_column :product_types, :legal_act_valid_until, :date
    add_column :product_types, :dpp_required_from, :date
    add_column :product_types, :granularity, :string
    add_column :product_types, :carriers, :text
    add_column :product_types, :carrier_placement, :text
    add_column :product_types, :carrier_layout, :text
    add_column :product_types, :availability_years, :integer
    add_column :product_types, :config_version, :integer, null: false, default: 0
    add_column :product_types, :config_changed_at, :datetime
  end
end
