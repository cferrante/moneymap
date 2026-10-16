# Creates the invitee's account and consumes the invitation together: both
# happen or neither does.
class AcceptInvitation
  INVALID = "This invitation is no longer valid.".freeze

  def initialize(invitation, password:, password_confirmation:)
    @invitation = invitation
    @user = User.new(email_address: invitation.email_address, password: password,
      password_confirmation: password_confirmation)
  end

  # Returns the user: persisted on success, unsaved with errors otherwise.
  def call
    Invitation.transaction do
      # Row lock: a second submit waits here, then re-reads the invitation and
      # finds it accepted, so one link can't create two accounts.
      @invitation.lock!

      if !@invitation.pending?
        @user.errors.add(:base, INVALID)
      elsif @user.save
        @invitation.update!(accepted_at: Time.current)
      end
    end

    @user
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique
    # RecordNotFound: an admin revoked the invitation after it was loaded, so
    # lock! couldn't find the row. RecordNotUnique: someone registered this email
    # between the validation and the insert. Either way the link is no longer usable.
    @user.errors.add(:base, INVALID)
    @user
  end
end
