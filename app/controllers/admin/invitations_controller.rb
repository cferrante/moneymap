module Admin
  class InvitationsController < Admin::BaseController
    gate_behind :invitations
    # Admin-only already limits who can invite; this caps the damage a hijacked
    # admin session could do.
    rate_limit to: 20, within: 1.hour, only: :create,
      with: -> { redirect_to admin_invitations_path, alert: "Too many invitations. Try again later." }

    def index
      @invitation = Invitation.new
      @invitations = all_invitations
    end

    def create
      @invitation = Current.user.sent_invitations.new(email_address: params.dig(:invitation, :email_address))

      if @invitation.save
        redirect_to admin_invitations_path,
          notice: "Invitation created for #{@invitation.email_address}. Copy its link below and send it to them."
      else
        @invitations = all_invitations
        render :index, status: :unprocessable_entity
      end
    end

    # Only pending invitations can be revoked; accepted ones are the record of who
    # invited whom.
    def destroy
      Invitation.pending.find(params[:id]).destroy
      redirect_to admin_invitations_path, notice: "Invitation revoked.", status: :see_other
    end

    private
      def all_invitations
        Invitation.includes(:invited_by).order(created_at: :desc)
      end
  end
end
