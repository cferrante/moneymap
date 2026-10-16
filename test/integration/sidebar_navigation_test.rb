require "test_helper"

# The sidebar renders on every authenticated page, so its contents are covered
# here rather than in any one controller's test.
class SidebarNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    FeatureFlag::REGISTRY.each { |key| enable_feature(key) }
  end

  test "links every section and the account actions" do
    sign_in_as @user

    get dashboard_path

    assert_response :success
    [ dashboard_path, transactions_path, budgets_path, reports_path,
      accounts_path, categories_path, edit_settings_path ].each do |path|
      assert_select "aside a[href=?]", path, { count: 1 }, "expected the sidebar to link #{path}"
    end
    assert_select "aside form[action=?][method=post]", session_path # log out
  end

  test "marks the section the current page belongs to" do
    sign_in_as @user

    get budgets_path

    assert_select "aside a[href=?][aria-current=page]", budgets_path
    assert_select "aside a[href=?][aria-current=page]", dashboard_path, count: 0
  end

  test "keeps a section marked on its nested pages" do
    sign_in_as @user

    get new_budget_path

    assert_select "aside a[href=?][aria-current=page]", budgets_path
  end

  test "hides the admin group from a non-admin" do
    sign_in_as @user

    get dashboard_path

    assert_not @user.admin?
    assert_select "aside a[href=?]", admin_feature_flags_path, count: 0
    assert_not_includes response.body, "Feature flags"
  end

  test "shows the admin group to an admin" do
    @user.update!(admin: true)
    sign_in_as @user

    get dashboard_path

    assert_select "aside a[href=?]", admin_feature_flags_path, count: 1
    assert_includes response.body, "Feature flags"
  end

  test "shows invitations to an admin when its flag is on" do
    @user.update!(admin: true)
    sign_in_as @user

    get dashboard_path

    assert_select "aside a[href=?]", admin_invitations_path, count: 1
  end

  test "hides invitations from an admin when its flag is off" do
    @user.update!(admin: true)
    FeatureFlag.find_by!(key: "invitations").update!(globally_enabled: false)
    sign_in_as @user

    get dashboard_path

    assert_select "aside a[href=?]", admin_invitations_path, count: 0
    assert_select "aside a[href=?]", admin_feature_flags_path, count: 1
  end

  test "is absent while signed out" do
    get root_path

    assert_response :success
    assert_select "aside", count: 0
  end
end
