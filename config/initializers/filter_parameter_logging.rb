# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# The same list filters bound values in the SQL log (Active Record takes it over
# as filter_attributes). In production the log goes to the container's standard
# output, so anything that matches nothing here ends up in `docker logs`.
#
# What this application receives or stores that must never be logged:
#   passphrase           the vault passphrase: passphrase, passphrase_confirmation,
#                        current_passphrase, new_passphrase, new_passphrase_confirmation
#   _key                 the keys of an identity or a passport: document_key, revocation_key
#   revocation_log       the prepared revocation of an identity or a passport; whoever
#                        holds it can end that identifier
#   token                access rights as signed tokens, and the form's authenticity token
Rails.application.config.filter_parameters += [
  :passw, :passphrase, :email, :secret, :token, :_key, :revocation_log, :crypt, :salt, :certificate,
  :otp, :ssn, :cvv, :cvc
]
