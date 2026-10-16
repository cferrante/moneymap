class InvitationAcceptancesController < ApplicationController
  allow_unauthenticated_access
  # Accepts a password and creates an account, so it's throttled like sign-in
  # (config/initializers/rack_attack.rb adds a per-IP limit in front of this).
  # Unlike sign-in, it sends the invitee back to their invitation rather than to
  # the sign-in page: they have no account yet, and would otherwise lose the link.
  # Safe to build from params: it's this app's own route, and the token only fills
  # in a path segment.
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to invitation_acceptance_path(params[:token]), alert: "Too many attempts. Wait a few minutes and try again." }

  before_action :redirect_if_signed_in
  before_action :set_invitation

  def new
    @user = User.new(email_address: @invitation.email_address)
  end

  def create
    @user = AcceptInvitation.new(@invitation,
      password: params[:password], password_confirmation: params[:password_confirmation]).call

    if @user.persisted?
      start_new_session_for @user
      redirect_to root_path, notice: "Welcome to Moneymap!"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    # Avoids silently creating a second account while already signed in.
    def redirect_if_signed_in
      redirect_to root_path, notice: "You're already signed in." if authenticated?
    end

    # Every unusable link gets the same response, so a link-holder can't tell
    # expired from revoked from already used. A garbage token renders that page
    # even with the flag off (there's no inviter to check the flag for); that
    # reveals only that invitation URLs exist.
    def set_invitation
      @invitation = Invitation.find_pending_by_token(params[:token])

      if @invitation.nil?
        render :invalid, status: :not_found
      elsif !FeatureFlag.enabled?(:invitations, user: @invitation.invited_by)
        head :not_found
      end
    end
end
