require "application_system_test_case"

# The only test that runs the invitation flow in a real browser, so it's the one
# that exercises the clipboard Stimulus controller and the forms as a user sees them.
class InvitationsTest < ApplicationSystemTestCase
  include FeatureFlagTestHelper

  PASSWORD = "correct-horse-battery"

  setup do
    @admin = users(:one)
    @admin.update!(admin: true)
    enable_feature_for :invitations, @admin
  end

  test "an admin invites someone who then creates their account" do
    sign_in @admin
    click_on "Invitations"

    fill_in "Email address", with: "friend@example.com"
    click_on "Create invitation"
    assert_text "Invitation created for friend@example.com"

    grant_clipboard_access
    click_on "Copy"
    assert_text "Copied"
    link = page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")
    assert_equal find("input[aria-label='Invitation link for friend@example.com']").value, link

    # A separate browser session, so the invitee is signed out.
    using_session(:invitee) do
      visit link
      assert_text "You're invited to Moneymap"
      assert_text "friend@example.com"

      fill_in "Password", with: PASSWORD
      fill_in "Confirm password", with: PASSWORD
      click_on "Create account"
      assert_text "Welcome to Moneymap!"
    end

    visit current_path
    assert_text "Accepted"
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password"
      click_on "Sign in"
      assert_no_current_path new_session_path
    end

    # Headless Chrome refuses clipboard access by default; grant it for this
    # server's origin so the test can read back what the Copy button wrote.
    def grant_clipboard_access
      origin = URI.parse(current_url).then { |uri| "#{uri.scheme}://#{uri.host}:#{uri.port}" }
      page.driver.browser.execute_cdp("Browser.grantPermissions",
        origin: origin, permissions: %w[clipboardReadWrite clipboardSanitizedWrite])
    end
end
