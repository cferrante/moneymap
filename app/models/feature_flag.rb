class FeatureFlag < ApplicationRecord
  # Add a key here before creating a FeatureFlag row with it. `budgets` and
  # `dashboard` were placeholders for the work in docs/repo-review-2026-08-29.md;
  # `reports` covers the third page that arrived with the same design handoff.
  # `invitations` gates invite-only sign-up (docs/superpowers/specs/2026-10-15-invite-only-sign-up-design.md).
  REGISTRY = %w[budgets dashboard invitations reports].freeze

  has_many :feature_flag_assignments, dependent: :destroy
  has_many :users, through: :feature_flag_assignments

  validates :key, presence: true, uniqueness: true, inclusion: { in: REGISTRY }

  def self.enabled?(key, user: nil)
    FeatureFlagCheck.new(key, user: user).call
  end
end
