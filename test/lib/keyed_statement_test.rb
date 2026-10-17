require "test_helper"

# A statement carrying key material that fails must not hand that material on.
# The sqlite3 gem quotes the SQL in its error message, and an error that reaches
# a controller is written to the log with its message and its causes.
class KeyedStatementTest < ActiveSupport::TestCase
  test "a failing statement with key material names none of it" do
    secret = "ab" * 48
    database = SQLite3::Database.new(":memory:")

    error = assert_raises(Vault::KeyedStatementError) do
      Vault.execute_keyed(database, "SELECT \"x'#{secret}'\" FROM no_such_table", "probe")
    end

    assert_match(/\Aprobe failed/, error.message)
    refute_includes error.message, secret
    assert_nil error.cause
  ensure
    database&.close
  end

  test "a statement that works is simply run" do
    database = SQLite3::Database.new(":memory:")

    assert_equal [ [ 1 ] ], Vault.execute_keyed(database, "SELECT 1", "probe")
  ensure
    database&.close
  end
end
