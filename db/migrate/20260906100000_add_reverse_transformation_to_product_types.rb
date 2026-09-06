# Reading a passport somebody else wrote needs the transformation the other way
# round, and it is a different structure: `soya transform` takes the first
# overlay in a graph that carries an engine, so one structure cannot hold both
# directions.
#
# Three columns, mirroring the forward transformation's, rather than one JSON
# column holding both. A column per thing keeps the queries in ProductType.
# resolve_document simple, and that lookup is what soya-web-cli walks through on
# every pull.
class AddReverseTransformationToProductTypes < ActiveRecord::Migration[8.1]
  def change
    add_column :product_types, :reverse_transformation_name, :string
    add_column :product_types, :reverse_transformation_jsonld, :text
    add_column :product_types, :reverse_transformation_fetched_at, :datetime
  end
end
