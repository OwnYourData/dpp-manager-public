# The Vault is the single encrypted file that holds everything this application
# knows: settings, identities, product types, passports, keys and the event log.
#
# One file, because the economic operator has to be able to carry their work to
# another machine by copying it. Encrypted as a whole rather than field by
# field, because the passport list has to stay sortable and filterable in SQL —
# per-column encryption would move that work into Ruby and lose it.
#
# See docs/Decisions.md for why the pieces are shaped the way they are.
module Vault
  # Raised when the file cannot be opened with the passphrase given. Deliberately
  # one error for "wrong passphrase" and "not our file": telling them apart is
  # information an attacker gets for free otherwise, and the user's next step is
  # the same either way.
  class LockedError < StandardError; end

  # Raised when the caller asks for something that needs an open vault.
  class NotOpenError < StandardError; end

  # Raised when a vault already exists and creation was attempted anyway.
  class AlreadyExistsError < StandardError; end

  # Raised when a statement that carries key material fails. Its message names
  # the statement and nothing of it.
  class KeyedStatementError < StandardError; end

  # Runs a statement that carries key material — PRAGMA key, ATTACH … KEY —
  # directly on the SQLite connection, past Active Record. Active Record would
  # print the statement in its query log, and a failing statement comes back
  # from the sqlite3 gem as an error whose message quotes the SQL, on its way
  # into the log. So the error is replaced, and the original is not kept as its
  # cause either, because the error page and the log print causes too.
  def self.execute_keyed(raw_connection, sql, statement)
    raw_connection.execute(sql)
  rescue StandardError => e
    raise KeyedStatementError, "#{statement} failed (#{e.class.name})", cause: nil
  end
end
