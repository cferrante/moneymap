class Invitation < ApplicationRecord
  EXPIRES_IN = 7.days

  belongs_to :invited_by, class_name: "User", inverse_of: :sent_invitations

  # Deterministic so the app can still look invitations up by email (duplicate
  # checks, matching an existing user). Normalized first, so lookups ignore case.
  encrypts :email_address, deterministic: true
  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # Signed, not stored: the token carries the id and a signature, so a database
  # leak doesn't leak working links. accepted_at is baked into the signature, so
  # setting it invalidates every token issued for this invitation (single use).
  generates_token_for :acceptance, expires_in: EXPIRES_IN do
    accepted_at
  end

  scope :pending, -> { where(accepted_at: nil).where(expires_at: Time.current..) }

  before_validation :set_expires_at, on: :create

  validates :email_address, presence: true, length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :email_not_registered, :no_other_pending_invitation, on: :create

  # A token's own expiry counts from when it was generated, and an admin can
  # re-copy a link late in an invitation's life, so the stored expires_at is
  # checked too and always wins.
  def self.find_pending_by_token(token)
    invitation = find_by_token_for(:acceptance, token)
    invitation if invitation&.pending?
  end

  def status
    if accepted_at?
      :accepted
    elsif expires_at.past?
      :expired
    else
      :pending
    end
  end

  def pending?
    status == :pending
  end

  private
    def set_expires_at
      self.expires_at ||= EXPIRES_IN.from_now
    end

    def email_not_registered
      errors.add(:email_address, "already has an account") if User.exists?(email_address: email_address)
    end

    def no_other_pending_invitation
      errors.add(:email_address, "already has a pending invitation") if Invitation.pending.exists?(email_address: email_address)
    end
end
