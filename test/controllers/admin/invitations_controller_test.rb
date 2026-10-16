require "test_helper"

class Admin::InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @admin.update!(admin: true)
    @non_admin = users(:two)
  end

  test "index redirects to sign in when signed out" do
    get admin_invitations_path
    assert_redirected_to new_session_path
  end

  test "index is not found for a signed-in non-admin" do
    enable_feature :invitations
    sign_in_as @non_admin

    get admin_invitations_path

    assert_response :not_found
  end

  test "index is not found for an admin when the flag is off" do
    sign_in_as @admin

    get admin_invitations_path

    assert_response :not_found
  end

  test "index lists invitations with their status" do
    enable_feature_for :invitations, @admin
    pending = @admin.sent_invitations.create!(email_address: "pending@example.com")
    accepted = @admin.sent_invitations.create!(email_address: "accepted@example.com")
    accepted.update!(accepted_at: Time.current)
    sign_in_as @admin

    get admin_invitations_path

    assert_response :success
    assert_includes response.body, pending.email_address
    assert_includes response.body, accepted.email_address
    assert_includes response.body, "Pending"
    assert_includes response.body, "Accepted"
  end

  test "index shows an empty state when there are no invitations" do
    enable_feature_for :invitations, @admin
    sign_in_as @admin

    get admin_invitations_path

    assert_includes response.body, "No invitations yet"
  end

  test "index shows a working acceptance link for pending invitations only" do
    enable_feature_for :invitations, @admin
    pending = @admin.sent_invitations.create!(email_address: "pending@example.com")
    accepted = @admin.sent_invitations.create!(email_address: "accepted@example.com")
    accepted.update!(accepted_at: Time.current)
    sign_in_as @admin

    get admin_invitations_path

    links = css_select("input[data-clipboard-target=source]").map { |input| input["value"] }
    assert_equal 1, links.size
    token = links.first.split("/invitations/").last
    assert_equal pending, Invitation.find_pending_by_token(token)
  end

  test "create adds an invitation sent by the current admin" do
    enable_feature_for :invitations, @admin
    sign_in_as @admin

    assert_difference -> { @admin.sent_invitations.count }, 1 do
      post admin_invitations_path, params: { invitation: { email_address: "New@Example.com" } }
    end

    assert_redirected_to admin_invitations_path
    follow_redirect!
    assert_includes response.body, "Invitation created for new@example.com"
  end

  test "create with an invalid email re-renders with the error" do
    enable_feature_for :invitations, @admin
    sign_in_as @admin

    assert_no_difference -> { Invitation.count } do
      post admin_invitations_path, params: { invitation: { email_address: "not-an-email" } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Email address is invalid"
  end

  test "create for an email that already has an account re-renders with the error" do
    enable_feature_for :invitations, @admin
    sign_in_as @admin

    assert_no_difference -> { Invitation.count } do
      post admin_invitations_path, params: { invitation: { email_address: @non_admin.email_address } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Email address already has an account"
  end

  test "create is not found for a signed-in non-admin" do
    enable_feature :invitations
    sign_in_as @non_admin

    assert_no_difference -> { Invitation.count } do
      post admin_invitations_path, params: { invitation: { email_address: "new@example.com" } }
    end

    assert_response :not_found
  end

  test "destroy revokes a pending invitation" do
    enable_feature_for :invitations, @admin
    invitation = @admin.sent_invitations.create!(email_address: "pending@example.com")
    sign_in_as @admin

    assert_difference -> { Invitation.count }, -1 do
      delete admin_invitation_path(invitation)
    end

    assert_redirected_to admin_invitations_path
  end

  # The admin loaded the page while it was pending; it expired before they clicked.
  test "destroy revokes an invitation that has expired since the page loaded" do
    enable_feature_for :invitations, @admin
    invitation = @admin.sent_invitations.create!(email_address: "expiring@example.com")
    sign_in_as @admin

    travel Invitation::EXPIRES_IN + 1.minute do
      assert_difference -> { Invitation.count }, -1 do
        delete admin_invitation_path(invitation)
      end

      assert_redirected_to admin_invitations_path
    end
  end

  # Accepted invitations are the record of who invited whom, so they can't be revoked.
  test "destroy is not found for an accepted invitation" do
    enable_feature_for :invitations, @admin
    invitation = @admin.sent_invitations.create!(email_address: "accepted@example.com")
    invitation.update!(accepted_at: Time.current)
    sign_in_as @admin

    assert_no_difference -> { Invitation.count } do
      delete admin_invitation_path(invitation)
    end

    assert_response :not_found
  end
end
