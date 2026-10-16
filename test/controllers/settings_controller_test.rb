require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  NEW_PASSWORD = "correct-horse-battery"

  setup do
    @user = users(:one)
    sign_in_as @user
  end

  test "edit renders the form" do
    get edit_settings_path

    assert_response :success
    assert_includes response.body, @user.email_address
  end

  test "update with the correct current password changes the password" do
    patch settings_path, params: { current_password: "password", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }

    assert_redirected_to edit_settings_path
    assert @user.reload.authenticate(NEW_PASSWORD)
  end

  test "update with an incorrect current password re-renders the form" do
    patch settings_path, params: { current_password: "wrong", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password")
  end

  test "update with mismatched confirmation re-renders the form" do
    patch settings_path, params: { current_password: "password", password: NEW_PASSWORD, password_confirmation: "different-horse-battery" }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password")
  end

  test "update with a too-short new password re-renders the form" do
    patch settings_path, params: { current_password: "password", password: "too-short", password_confirmation: "too-short" }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password")
  end
end
