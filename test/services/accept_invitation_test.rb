require "test_helper"

class AcceptInvitationTest < ActiveSupport::TestCase
  PASSWORD = "correct-horse-battery"

  setup do
    @invitation = users(:one).sent_invitations.create!(email_address: "new@example.com")
  end

  test "creates a user with the invited email and marks the invitation accepted" do
    user = nil

    assert_difference -> { User.count }, 1 do
      user = accept(PASSWORD, PASSWORD)
    end

    assert user.persisted?
    assert_equal "new@example.com", user.email_address
    assert user.authenticate(PASSWORD)
    assert_equal :accepted, @invitation.reload.status
  end

  test "seeds the new user's default categories" do
    assert_equal 8, accept(PASSWORD, PASSWORD).categories.count
  end

  test "returns an unsaved user with errors for a too-short password" do
    user = nil

    assert_no_difference -> { User.count } do
      user = accept("too-short", "too-short")
    end

    assert_not user.persisted?
    assert user.errors[:password].any?
    assert @invitation.reload.pending?
  end

  test "returns an unsaved user with errors when the confirmation doesn't match" do
    user = accept(PASSWORD, "different-horse-battery")

    assert_not user.persisted?
    assert user.errors[:password_confirmation].any?
    assert @invitation.reload.pending?
  end

  # Covers a second submit racing the first: the row lock re-reads the invitation,
  # so the loser sees it already accepted.
  test "creates nothing when the invitation is no longer pending" do
    Invitation.find(@invitation.id).update!(accepted_at: Time.current)
    user = nil

    assert_no_difference -> { User.count } do
      user = accept(PASSWORD, PASSWORD)
    end

    assert_not user.persisted?
    assert_includes user.errors[:base], "This invitation is no longer valid."
  end

  # The controller loaded the invitation, then an admin revoked (deleted) it
  # before the service locked the row.
  test "creates nothing when the invitation was revoked after being loaded" do
    Invitation.where(id: @invitation.id).delete_all
    user = nil

    assert_no_difference -> { User.count } do
      user = accept(PASSWORD, PASSWORD)
    end

    assert_not user.persisted?
    assert_includes user.errors[:base], "This invitation is no longer valid."
  end

  test "creates nothing when an account with the email was created since the invite" do
    User.create!(email_address: "new@example.com", password: PASSWORD)
    user = nil

    assert_no_difference -> { User.count } do
      user = accept(PASSWORD, PASSWORD)
    end

    assert_not user.persisted?
    assert @invitation.reload.pending?
  end

  private
    def accept(password, confirmation)
      AcceptInvitation.new(@invitation, password: password, password_confirmation: confirmation).call
    end
end
