class User < ApplicationRecord
  # NIST SP 800-63B rev. 4's floor when the password is the only factor (no 2FA here).
  # No composition rules, per the same guidance.
  PASSWORD_MIN_LENGTH = 15

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :transactions, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :budgets, dependent: :destroy
  has_many :sent_invitations, class_name: "Invitation", foreign_key: :invited_by_id,
    inverse_of: :invited_by, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # has_secure_password only checks presence, confirmation and bcrypt's 72-byte max.
  # Uniqueness compares the normalized value; the unique index remains the backstop.
  validates :email_address, presence: true, length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: true
  # allow_nil: only enforced when a password is being set, so existing records and
  # unrelated updates aren't affected.
  validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, allow_nil: true

  after_create :seed_default_categories

  private
    def seed_default_categories
      SeedDefaultCategories.new(self).call
    end
end
