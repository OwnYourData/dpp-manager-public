require "test_helper"

class EventTest < ActiveSupport::TestCase
  setup { reset_vault!; Vault::Lifecycle.create!(TEST_PASSPHRASE) }
  teardown { Vault::Store.close! }

  test "the chain starts at the genesis digest and links every entry" do
    first  = Event.record!(:backup_created, filename: "one.db")
    second = Event.record!(:backup_created, filename: "two.db")

    assert_equal Event::GENESIS, Event.unscoped.order(:id).first.prev_digest
    assert_equal first.digest, second.prev_digest
    assert_nil Event.verify_chain
  end

  test "an edited entry breaks the chain and is reported by id" do
    Event.record!(:backup_created, filename: "one.db")
    tampered = Event.record!(:backup_created, filename: "two.db")
    Event.record!(:backup_created, filename: "three.db")

    # Straight past the model, the way someone with a SQL prompt would do it.
    Event.connection.execute(
      "UPDATE events SET detail = '{\"filename\":\"rewritten.db\"}' WHERE id = #{tampered.id}"
    )

    assert_equal tampered.id, Event.verify_chain
  end

  test "a removed entry breaks the chain at the entry that followed it" do
    Event.record!(:backup_created, filename: "one.db")
    removed = Event.record!(:backup_created, filename: "two.db")
    following = Event.record!(:backup_created, filename: "three.db")

    Event.connection.execute("DELETE FROM events WHERE id = #{removed.id}")

    assert_equal following.id, Event.verify_chain
  end

  test "an unknown kind is refused rather than silently recorded" do
    assert_raises(ArgumentError) { Event.record!(:something_invented) }
  end

  test "creating the vault is itself the first entry" do
    assert_equal "vault_created", Event.unscoped.order(:id).first.kind
  end

  test "failed unlock attempts are counted and entered on the next success" do
    Vault::Store.close!

    refute Vault::Lifecycle.unlock!("wrong one")
    refute Vault::Lifecycle.unlock!("wrong again")
    assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE)

    failure = Event.where(kind: "vault_open_failed").last
    assert_equal 2, failure.detail_hash["attempts"]
    assert_nil Event.verify_chain
  end
end
