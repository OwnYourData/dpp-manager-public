# Handing a passport to a different custodian is two acts against two systems,
# like ending one is: the service moves the document, and this application moves
# the identifier that says where the document can be read. Either can fail while
# the other has already happened.
#
# So the intended new address is written down before the identifier follows it.
# While that column holds something, the passport is at its new custodian under
# an identifier that still names the old one — which is the one state a reader
# would notice, and the one the page has to offer to finish.
class AddCustodyMoveToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :pending_endpoint_base, :string
    add_column :passports, :custody_moved_at, :datetime
  end
end
