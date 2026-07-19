require "test_helper"

class AdminAuditLogTest < ActiveSupport::TestCase
  test "persisted audit rows are immutable" do
    log = AdminAuditLog.create!(actor_designer: designers(:one), action: "test_action")

    assert_predicate log, :readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { log.update!(action: "changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy! }
  end

  test "audit survives actor deletion without becoming writable" do
    actor = Designer.create!(
      email_address: "former-admin@example.com", password: "password", display_name: "Former Admin"
    )
    log = AdminAuditLog.create!(actor_designer: actor, action: "test_action")

    actor.destroy!

    assert_nil log.reload.actor_designer
    assert_predicate log, :readonly?
  end
end
