# Rails needs a secret to sign the session cookie. This application does not
# need that secret to survive a restart, and deliberately does not keep one.
#
# The reasoning: the only thing the session holds is "this browser has an open
# vault". A restart closes the vault — the key lives in process memory and
# nowhere else — so a session that outlived the process would point at nothing.
# Generating a fresh secret at boot therefore invalidates exactly the cookies
# that have already become meaningless, and it saves the operator from managing
# a secret file next to their data file.
#
# SECRET_KEY_BASE is still honoured, for anyone who wants sessions to survive a
# container restart. It changes nothing about the encryption of the vault, which
# is derived from the passphrase alone.
Rails.application.config.secret_key_base =
  ENV["SECRET_KEY_BASE"].presence || SecureRandom.hex(64)
