# The economic operator's own identity DID.
#
# Not a passport identifier and not the service's: this is who the operator *is*
# towards the DPP Service and towards a custodian. It signs the bearer tokens,
# it signs the delegations, and a custodian records it as the controller of the
# collection the passports go into.
#
# Exactly one for now. The table is not built around that assumption, because a
# second one shows up as soon as somebody manages two legal entities from one
# machine — but nothing in this version offers to create it.
class Identity < ApplicationRecord
  ORIGINS = %w[minted imported].freeze

  validates :did, presence: true, uniqueness: true,
                  format: { with: /\Adid:oyd:[1-9A-HJ-NP-Za-km-z]+(@.+)?\z/ }
  validates :document_key, presence: true
  validates :origin, inclusion: { in: ORIGINS }

  # The revocation key is the only way to end this identity cleanly. It is
  # optional on an imported identity, because somebody may hold it elsewhere —
  # but the application says so rather than pretending everything is in place.
  def revocable?
    revocation_key.present?
  end

  def keys_secured? = keys_secured_at.present?

  def minted? = origin == "minted"

  def self.current = first

  # Short enough to recognise in a list, long enough not to collide by accident.
  def short
    did.to_s.delete_prefix("did:oyd:")[0, 12]
  end
end
