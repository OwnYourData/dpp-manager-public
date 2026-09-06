# What this installation knows about the mandate under which somebody else
# holds a passport.
#
# The service keeps its own copy of the assertion, so none of this is needed to
# make the custody work. It is needed to notice when the two have drifted: a
# mandate has a lifetime and a passport does not, and the operator is the only
# one who can sign a fresh one. A record of what was signed and when it runs out
# is what turns that from a surprise into a reminder.
#
# The assertion itself is deliberately not stored. It is redeemable only by the
# service named in it, so keeping it would buy nothing, and a second copy of a
# signed statement is a second thing that can be leaked or go stale.
class AddCustodyToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :custodian_collection_id, :string
    add_column :passports, :delegation_jti, :string
    add_column :passports, :delegation_signed_at, :datetime
    add_column :passports, :delegation_expires_at, :datetime
    add_column :passports, :delegation_act, :string
  end
end
