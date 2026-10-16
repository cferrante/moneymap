require "test_helper"

class InvitationAcceptancesControllerTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"

  setup do
    @admin = users(:one)
    @admin.update!(admin: true)
    enable_feature_for :invitations, @admin
    @invitation = @admin.sent_invitations.create!(email_address: "new@example.com")
    @token = @invitation.generate_token_for(:acceptance)
  end

  test "new shows the invited email without letting it be changed" do
    get invitation_acceptance_path(@token)

    assert_response :success
    assert_includes response.body, "new@example.com"
    assert_select "input[name=email_address]", count: 0
    assert_select "input[type=password][name=password]"
  end

  test "create makes the account, signs the invitee in and consumes the invitation" do
    assert_difference -> { User.count }, 1 do
      post invitation_acceptance_path(@token), params: { password: PASSWORD, password_confirmation: PASSWORD }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?
    assert_equal :accepted, @invitation.reload.status
    assert User.find_by(email_address: "new@example.com").authenticate(PASSWORD)

    follow_redirect! # root forwards a signed-in user to their landing page
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Welcome to Moneymap!"
  end

  test "create with a too-short password re-renders with the error" do
    assert_no_difference -> { User.count } do
      post invitation_acceptance_path(@token), params: { password: "too-short", password_confirmation: "too-short" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Password is too short"
    assert @invitation.reload.pending?
  end

  # A link-holder must learn nothing about *why* a link doesn't work, so every
  # unusable case has to produce byte-for-byte the same response.
  test "every unusable link gets the same response" do
    responses = {}

    get invitation_acceptance_path("garbage")
    responses[:garbage] = [ response.status, response.body ]

    get invitation_acceptance_path(@token.reverse)
    responses[:tampered] = [ response.status, response.body ]

    revoked = @admin.sent_invitations.create!(email_address: "revoked@example.com")
    revoked_token = revoked.generate_token_for(:acceptance)
    revoked.destroy!
    get invitation_acceptance_path(revoked_token)
    responses[:revoked] = [ response.status, response.body ]

    accepted = @admin.sent_invitations.create!(email_address: "accepted@example.com")
    accepted_token = accepted.generate_token_for(:acceptance)
    accepted.update!(accepted_at: Time.current)
    get invitation_acceptance_path(accepted_token)
    responses[:accepted] = [ response.status, response.body ]

    travel Invitation::EXPIRES_IN + 1.minute do
      get invitation_acceptance_path(@token)
      responses[:expired] = [ response.status, response.body ]
    end

    assert_equal :not_found, Rack::Utils::SYMBOL_TO_STATUS_CODE.key(responses[:garbage].first)
    assert_includes responses[:garbage].last, "invalid or has expired"
    responses.each do |name, result|
      assert_equal responses[:garbage], result, "#{name} link responded differently from a garbage link"
    end
  end

  test "an email registered since the invite gets the generic invalid response" do
    User.create!(email_address: "new@example.com", password: PASSWORD)

    get invitation_acceptance_path(@token)

    assert_response :not_found
    assert_includes response.body, "invalid or has expired"
  end

  test "create with an unusable link creates nothing" do
    assert_no_difference -> { User.count } do
      post invitation_acceptance_path("garbage"), params: { password: PASSWORD, password_confirmation: PASSWORD }
    end

    assert_response :not_found
  end

  test "is not found when the flag is off for the inviter" do
    FeatureFlagAssignment.where(user: @admin).destroy_all

    get invitation_acceptance_path(@token)

    assert_response :not_found
    assert_not_includes response.body, "new@example.com"
  end

  test "a signed-in user is told they're already signed in" do
    sign_in_as users(:two)

    assert_no_difference -> { User.count } do
      get invitation_acceptance_path(@token)
    end

    assert_redirected_to root_path
    follow_redirect! # root forwards a signed-in user to their landing page
    follow_redirect!
    assert_includes response.body, "You&#39;re already signed in."
  end
end
