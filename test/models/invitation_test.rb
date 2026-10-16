require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @admin = users(:one)
  end

  test "normalizes the email address" do
    invitation = invite(" New.Person@EXAMPLE.com ")

    assert_equal "new.person@example.com", invitation.email_address
  end

  test "rejects a malformed email address" do
    invitation = build("not-an-email")

    assert_not invitation.valid?
    assert_includes invitation.errors[:email_address], "is invalid"
  end

  test "rejects an email address longer than 254 characters" do
    invitation = build("#{"a" * 243}@example.com")

    assert_not invitation.valid?
    assert_includes invitation.errors[:email_address], "is too long (maximum is 254 characters)"
  end

  test "rejects an email address that already has an account" do
    invitation = build(users(:two).email_address.upcase)

    assert_not invitation.valid?
    assert_includes invitation.errors[:email_address], "already has an account"
  end

  test "rejects a second pending invitation for the same email address" do
    invite("new@example.com")
    duplicate = build("new@example.com")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email_address], "already has a pending invitation"
  end

  test "allows a new invitation once the earlier one has expired" do
    invite("new@example.com")

    travel Invitation::EXPIRES_IN + 1.minute do
      assert build("new@example.com").valid?
    end
  end

  test "expires seven days after creation" do
    freeze_time do
      assert_equal 7.days.from_now, invite("new@example.com").expires_at
    end
  end

  test "status is pending, then expired" do
    invitation = invite("new@example.com")
    assert_equal :pending, invitation.status

    travel Invitation::EXPIRES_IN + 1.minute do
      assert_equal :expired, invitation.status
    end
  end

  test "status is accepted once accepted_at is set" do
    invitation = invite("new@example.com")
    invitation.update!(accepted_at: Time.current)

    assert_equal :accepted, invitation.status
  end

  test "stores the email address encrypted but can still be queried by it" do
    invitation = invite("new@example.com")

    assert_not_equal "new@example.com", invitation.ciphertext_for(:email_address)
    assert_equal invitation, Invitation.find_by(email_address: "NEW@example.com")
  end

  test "finds a pending invitation by a fresh token" do
    invitation = invite("new@example.com")

    assert_equal invitation, Invitation.find_pending_by_token(token_for(invitation))
  end

  test "rejects a tampered token" do
    invitation = invite("new@example.com")

    assert_nil Invitation.find_pending_by_token(token_for(invitation).reverse)
    assert_nil Invitation.find_pending_by_token("garbage")
  end

  test "rejects a token once the invitation is accepted" do
    invitation = invite("new@example.com")
    token = token_for(invitation)
    invitation.update!(accepted_at: Time.current)

    assert_nil Invitation.find_pending_by_token(token)
  end

  # Bypasses find_pending_by_token's pending? check, so this proves the signature
  # itself stops verifying once accepted_at changes, not just the status check.
  test "accepting invalidates the token's signature" do
    invitation = invite("new@example.com")
    token = token_for(invitation)
    invitation.update!(accepted_at: Time.current)

    assert_nil Invitation.find_by_token_for(:acceptance, token)
  end

  test "rejects a token once the invitation is revoked" do
    invitation = invite("new@example.com")
    token = token_for(invitation)
    invitation.destroy!

    assert_nil Invitation.find_pending_by_token(token)
  end

  test "rejects a token once the invitation has expired" do
    invitation = invite("new@example.com")
    token = token_for(invitation)

    travel Invitation::EXPIRES_IN + 1.minute do
      assert_nil Invitation.find_pending_by_token(token)
    end
  end

  # A link re-copied late in an invitation's life gets a token that would outlive
  # the invitation; the stored expires_at must still win.
  test "rejects a recently generated token once the invitation has expired" do
    invitation = invite("new@example.com")

    travel 6.days
    token = token_for(invitation)
    travel 2.days

    assert_nil Invitation.find_pending_by_token(token)
  end

  test "is destroyed with the user who sent it" do
    invite("new@example.com")

    assert_difference -> { Invitation.count }, -1 do
      @admin.destroy!
    end
  end

  private
    def build(email_address)
      @admin.sent_invitations.new(email_address: email_address)
    end

    def invite(email_address)
      @admin.sent_invitations.create!(email_address: email_address)
    end

    def token_for(invitation)
      invitation.generate_token_for(:acceptance)
    end
end
