# The two secrets of one passport's DID.
#
# The same shape as the identity's keys and for the same reason: whoever holds
# the document key can rewrite what the passport's DID points at, and whoever
# holds the revocation key can end it. Neither exists anywhere but here — the
# registrar never sees them and cannot hand them out a second time.
#
# Why a passport has keys at all, when the operator's identity is what signs the
# submission: the DID is the product's, not the operator's. If the passport ever
# has to move to another custodian, or be retired at end of life, that is done by
# updating or revoking this DID, and only these two keys can do it.
class PassportKey < ApplicationRecord
  belongs_to :passport

  validates :document_key, presence: true

  def secured? = keys_secured_at.present?

  def revocable? = revocation_key.present?
end
