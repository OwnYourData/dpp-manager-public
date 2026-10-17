# frozen_string_literal: true

# Who may read which field of a passport of this type.
#
# access_paths is what the type's transformation makes of its fields: the
# element paths of EN 18223 a passport of this type can carry, each with the
# fields that end up there (Dpp::AccessPaths). access_classes is the operator's
# answer for each of those paths: public, legitimateInterest or authority.
#
# Nothing of it reaches a passport until access_policy_enabled is set. From
# then on the classes go to the DPP Service as an access policy, under an id
# that carries access_policy_version; a changed set of classes is a new version
# and a new id, because the service keeps every policy it was given unchanged.
# access_policy_digest tells a changed set from an unchanged one.
#
# The registered_* columns record which service last confirmed which id, so the
# page can say whether the current version is known there.
class AddAccessClassesToProductTypes < ActiveRecord::Migration[8.1]
  def change
    change_table :product_types, bulk: true do |t|
      t.boolean  :access_policy_enabled, null: false, default: false
      t.text     :access_paths
      t.text     :access_classes
      t.integer  :access_policy_version, null: false, default: 0
      t.string   :access_policy_digest
      t.string   :access_policy_registered_id
      t.string   :access_policy_registered_to
      t.datetime :access_policy_registered_at
    end
  end
end
