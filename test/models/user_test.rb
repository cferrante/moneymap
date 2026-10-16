require "test_helper"

class UserTest < ActiveSupport::TestCase
  VALID_PASSWORD = "correct-horse-battery"

  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "seeds default categories after creation" do
    user = User.create!(email_address: "new-user@example.com", password: VALID_PASSWORD)
    assert_equal 8, user.categories.count
  end

  test "admin defaults to false" do
    assert_not users(:one).admin?
  end

  test "rejects a password shorter than the minimum" do
    user = User.new(email_address: "short@example.com", password: "a" * (User::PASSWORD_MIN_LENGTH - 1))

    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 15 characters)"
  end

  test "accepts a password at the minimum length" do
    user = User.new(email_address: "exact@example.com", password: "a" * User::PASSWORD_MIN_LENGTH)

    assert user.valid?
  end

  # Fixture passwords predate the minimum; records must stay updatable as long as
  # the password itself isn't being changed.
  test "allows updates that don't change the password" do
    assert users(:one).update(admin: true)
  end

  test "rejects a malformed email address" do
    user = User.new(email_address: "not-an-email", password: VALID_PASSWORD)

    assert_not user.valid?
    assert_includes user.errors[:email_address], "is invalid"
  end

  test "rejects an email address longer than 254 characters" do
    user = User.new(email_address: "#{"a" * 243}@example.com", password: VALID_PASSWORD)

    assert_not user.valid?
    assert_includes user.errors[:email_address], "is too long (maximum is 254 characters)"
  end

  test "rejects a duplicate email address regardless of case" do
    user = User.new(email_address: users(:one).email_address.upcase, password: VALID_PASSWORD)

    assert_not user.valid?
    assert_includes user.errors[:email_address], "has already been taken"
  end
end
