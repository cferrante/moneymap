# Invite-only sign-up implementation plan

**Goal:** Let an admin create a single-use, expiring invitation link for an email address, and let
the invitee open it and set a password to create their account, per
`docs/superpowers/specs/2026-10-15-invite-only-sign-up-design.md`.

**Architecture:** One new model (`Invitation`) with a signed token from `generates_token_for`, one
service (`AcceptInvitation`), an admin controller (`Admin::InvitationsController`), a public
controller (`InvitationAcceptancesController`), one small Stimulus controller (copy-to-clipboard),
new `User` validations, and an `invitations` feature flag.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest, Hotwire. No new gems, no paid services.

## Global Constraints

- Follow existing patterns, don't invent new ones: `Admin::BaseController` + `AdminAuthorization`
  for admin pages, `gate_behind` for the flag, `allow_unauthenticated_access` +
  `start_new_session_for` for the public page, business logic in `app/services/` with one `#call`.
- `Current.user`, not `current_user` (no such method exists).
- Double-quoted strings (`bin/rubocop` enforces it). Run `bin/rubocop` after every task.
- Minitest only: `ActiveSupport::TestCase` for models/services, `ActionDispatch::IntegrationTest`
  for controllers. Use `users(:one)` / `users(:two)` fixtures; create everything else inline. Don't
  add fixture files.
- Flags are off in tests unless a test calls `enable_feature` / `enable_feature_for`.
- One commit per task, each leaving `bin/rails test` green. Commit messages: imperative, sentence
  case, explain *why* in the body.
- The test env uses `:null_store` for cache, so `rate_limit` and `rack-attack` never trigger in
  tests. Throttling is verified by reading the code and a manual check (Task 8), not by tests.

## Order and why

Tasks 1–2 are prerequisites that touch existing code (validations, encryption config). Task 3 is
the data model. Tasks 4–6 build the admin side, then the public side. Task 7 is docs; Task 8 is
verification. Each task is independently reviewable and leaves the app working.

---

### Task 1: `User` email and password validations

**Why first:** the invitee chooses a password, so the 15-character minimum must exist before any
outsider can set one. It also changes existing tests and seeds, which is easier to review alone.

**Files:**
- Modify: `app/models/user.rb`
- Modify: `app/controllers/passwords_controller.rb` (failure message)
- Modify: `db/seeds.rb:17` (demo password is 11 characters)
- Modify: `docs/environment-setup-runbook.md:384` (example uses `password123`)
- Modify tests: `test/models/user_test.rb`, `test/controllers/passwords_controller_test.rb`,
  `test/controllers/settings_controller_test.rb`

**Interfaces:**
- Produces: `User::PASSWORD_MIN_LENGTH` (15), used by views for `minlength`.

- [ ] **Step 1: Write failing model tests** in `test/models/user_test.rb`:
  - rejects a 14-character password; accepts a 15-character one
  - accepts an update that doesn't touch the password (e.g. `users(:one).update!(admin: true)`),
    proving `allow_nil` (fixture passwords are short and must keep working)
  - rejects a malformed email (`"not-an-email"`), an email over 254 characters, and a duplicate
    email differing only in case (`users(:one).email_address.upcase`) with a validation error,
    not `ActiveRecord::RecordNotUnique`
  - update the existing "seeds default categories" test to use a 15+ character password

  Run `bin/rails test test/models/user_test.rb`. Expected: new tests fail.

- [ ] **Step 2: Add the validations** to `app/models/user.rb`:

  ```ruby
  PASSWORD_MIN_LENGTH = 15

  validates :email_address, presence: true, length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: true
  validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, allow_nil: true
  ```

  `uniqueness` compares the normalized (downcased) value because `normalizes` runs first; the
  existing unique index stays as the race-condition backstop.

- [ ] **Step 3: Fix the password-reset failure message.** `PasswordsController#update` currently
  says "Passwords did not match." for *any* failure, which would be wrong for a too-short password.
  Change the alert to `@user.errors.full_messages.to_sentence`.

- [ ] **Step 4: Update the existing controller tests** that use short passwords:
  - `passwords_controller_test.rb` "update": use a 15+ character password; "update with non
    matching passwords": assert the new message ("Password confirmation doesn't match Password").
  - Add a passwords test: a 14-character reset is rejected and the digest doesn't change.
  - `settings_controller_test.rb`: replace `"newpassword"` with a 15+ character value; add a test
    that a too-short new password re-renders with 422.

- [ ] **Step 5: Lengthen the demo password** in `db/seeds.rb:17` (e.g. `"moneymap-demo-password"`)
  and the example in `docs/environment-setup-runbook.md:384`. Note: `find_or_create_by!` only sets
  the password on creation, so your *existing* local demo users keep `password123` until you run
  `bin/rails db:reset`. That's expected.

- [ ] **Step 6: Add `minlength`** to the password fields in `passwords/edit.html.erb` and the
  settings form, using `User::PASSWORD_MIN_LENGTH`, so the browser hints at the rule early. The
  model validation remains the actual control.

- [ ] **Step 7: Verify and commit.** `bin/rails test` and `bin/rubocop` green.
  Commit: "Require 15-character passwords and validate user email addresses".

---

### Task 2: Active Record encryption keys for development and test

**Why:** `Invitation#email_address` will be encrypted, and this is the app's first `encrypts`.
There's no `config/master.key` in this fork, so keys can't go into credentials (see the spec's
"Encryption of `email_address`" section).

**Files:**
- Modify: `config/environments/development.rb`, `config/environments/test.rb`

- [ ] **Step 1: Generate two independent key sets.** Run `bin/rails db:encryption:init` twice. It
  only prints keys; it doesn't write anything.

- [ ] **Step 2: Add one set to each environment file**, with a comment explaining they're
  non-secret and why:

  ```ruby
  # Active Record encryption keys for local/test data only. Not secrets: they protect
  # throwaway data, and committing them lets CI run without a repository secret.
  # Production reads its own keys from credentials (active_record_encryption).
  config.active_record.encryption.primary_key = "..."
  config.active_record.encryption.deterministic_key = "..."
  config.active_record.encryption.key_derivation_salt = "..."
  ```

  In `test.rb` also set `config.active_record.encryption.encrypt_fixtures = true`.

- [ ] **Step 3: Verify** with `bin/rails runner 'p ActiveRecord::Encryption.config.primary_key.present?'`
  in development (expect `true`), and `bin/rails test` green.
  Commit: "Configure Active Record encryption keys for development and test".

---

### Task 3: `Invitation` model

**Files:**
- Create: `db/migrate/<timestamp>_create_invitations.rb`
- Create: `app/models/invitation.rb`
- Modify: `app/models/user.rb` (association)
- Create: `test/models/invitation_test.rb`

**Interfaces:**
- Produces: `Invitation#status` (`:pending` / `:expired` / `:accepted`), `#pending?`,
  `Invitation.pending` scope, `#generate_token_for(:acceptance)`,
  `Invitation.find_pending_by_token(token)` (returns `nil` for any unusable token),
  `User#sent_invitations`.

- [ ] **Step 1: Migration.** `bin/rails generate migration CreateInvitations`, then:

  ```ruby
  create_table :invitations do |t|
    t.string :email_address, null: false
    t.references :invited_by, null: false, foreign_key: { to_table: :users }
    t.datetime :expires_at, null: false
    t.datetime :accepted_at
    t.timestamps
  end
  add_index :invitations, :email_address
  ```

  `bin/rails db:migrate`. Confirm `db/schema.rb` and that `strong_migrations` raised nothing.

- [ ] **Step 2: Write failing model tests** covering:
  - email normalized (strip + downcase), format, and length validations
  - rejected when a `User` with that email exists
  - rejected when a *pending* invitation for that email exists; allowed when the earlier one is
    expired or accepted
  - `expires_at` defaults to 7 days from creation
  - `status` for pending, expired (use `travel 8.days`), and accepted
  - the email is stored encrypted: the raw column value (`Invitation.connection.select_value(...)`)
    differs from the plaintext, and `Invitation.where(email_address: ...)` still finds it
  - `find_pending_by_token` returns the invitation for a fresh token, and `nil` for: a tampered
    token, a token after `accepted_at` is set (single-use), a token after `destroy` (revoked), and
    a token after expiry

- [ ] **Step 3: Implement** `app/models/invitation.rb`:

  ```ruby
  class Invitation < ApplicationRecord
    EXPIRES_IN = 7.days

    belongs_to :invited_by, class_name: "User"

    encrypts :email_address, deterministic: true
    normalizes :email_address, with: ->(e) { e.strip.downcase }

    # Signed, not stored. Changing accepted_at invalidates every token issued for
    # this invitation, which is what makes the link single-use.
    generates_token_for :acceptance, expires_in: EXPIRES_IN do
      accepted_at
    end

    scope :pending, -> { where(accepted_at: nil).where(expires_at: Time.current..) }

    before_validation :set_expires_at, on: :create

    validates :email_address, presence: true, length: { maximum: 254 },
      format: { with: URI::MailTo::EMAIL_REGEXP }
    validate :email_not_registered, :no_other_pending_invitation, on: :create

    # The token's own expiry runs from when it was generated (an admin can re-copy a
    # link later), so expires_at is checked too, keeping the stored date authoritative.
    def self.find_pending_by_token(token)
      invitation = find_by_token_for(:acceptance, token)
      invitation if invitation&.pending?
    end

    def status
      if accepted_at? then :accepted
      elsif expires_at.past? then :expired
      else :pending
      end
    end

    def pending? = status == :pending

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
  ```

  In `User`: `has_many :sent_invitations, class_name: "Invitation", foreign_key: :invited_by_id,
  dependent: :destroy, inverse_of: :invited_by`.

- [ ] **Step 4: Verify and commit.** Model tests, full suite, rubocop green.
  Commit: "Add Invitation model with signed single-use acceptance tokens".

---

### Task 4: `invitations` feature flag

**Files:**
- Modify: `app/models/feature_flag.rb` (`REGISTRY`)
- Modify: `test/integration/feature_gating_test.rb` (only if its structure makes adding gates
  natural; otherwise gating is tested in Tasks 5–6)

- [ ] **Step 1:** Add `invitations` to `FeatureFlag::REGISTRY`. `db/seeds.rb` already enables every
  registry key in development only, so no seed change is needed. Run `bin/rails db:seed` and
  confirm it's on at `/admin/feature_flags`.
- [ ] **Step 2:** Full suite green. Commit: "Register the invitations feature flag".

---

### Task 5: Admin invitations page

**Files:**
- Modify: `config/routes.rb`: inside `namespace :admin`, `resources :invitations, only: %i[ index create destroy ]`
- Create: `app/controllers/admin/invitations_controller.rb`
- Create: `app/views/admin/invitations/index.html.erb`
- Create: `app/javascript/controllers/clipboard_controller.js`
- Modify: `app/views/shared/_sidebar.html.erb` (admin array)
- Create: `test/controllers/admin/invitations_controller_test.rb`

- [ ] **Step 1: Write failing integration tests:**
  - signed out → redirect to sign in; signed-in non-admin → 404; admin with flag off → 404
  - admin with flag on (`enable_feature_for :invitations, admin`): index lists invitations with
    status; create with a valid email adds an invitation owned by the admin and redirects with a
    notice; create with an invalid or already-registered email re-renders with 422 and the
    error; destroy removes a pending invitation; destroy of an accepted invitation is 404 (accepted
    ones are the record and aren't revocable)
  - the index shows a working acceptance URL for pending invitations only
  - sidebar shows "Invitations" for a flagged admin and hides it otherwise

- [ ] **Step 2: Controller:**

  ```ruby
  module Admin
    class InvitationsController < Admin::BaseController
      gate_behind :invitations
      rate_limit to: 20, within: 1.hour, only: :create,
        with: -> { redirect_to admin_invitations_path, alert: "Too many invitations. Try again later." }

      def index
        @invitation = Invitation.new
        @invitations = Invitation.includes(:invited_by).order(created_at: :desc)
      end

      def create
        @invitation = Current.user.sent_invitations.new(email_address: params.dig(:invitation, :email_address))

        if @invitation.save
          redirect_to admin_invitations_path, notice: "Invitation created for #{@invitation.email_address}. Copy its link below."
        else
          @invitations = Invitation.includes(:invited_by).order(created_at: :desc)
          render :index, status: :unprocessable_entity
        end
      end

      def destroy
        Invitation.pending.find(params[:id]).destroy
        redirect_to admin_invitations_path, notice: "Invitation revoked.", status: :see_other
      end
    end
  end
  ```

- [ ] **Step 3: View**, matching `admin/feature_flags/index.html.erb`'s look (`shared/page_header`,
  `panel_classes`, `eyebrow_classes`, the same grid-row style): a create form at the top (email +
  "Create invitation"), then one row per invitation with email, status pill, invited by, expiry or
  accepted date, and for **pending** rows only: a read-only field holding
  `invitation_acceptance_url(invitation.generate_token_for(:acceptance))`, a copy button, and a
  revoke button. Use `shared/_empty_state` when there are none.

- [ ] **Step 4: Stimulus `clipboard` controller** (a first Stimulus controller with a target,
  good for learning):

  ```js
  import { Controller } from "@hotwired/stimulus"

  // Copies an invitation link so the admin can paste it into whatever channel
  // they use to send it (the app doesn't email invitations yet).
  export default class extends Controller {
    static targets = ["source", "label"]

    async copy() {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.labelTarget.textContent = "Copied"
    }
  }
  ```

  `controllers/index.js` already eager-loads controllers by filename, so check that rather than
  pinning anything in `config/importmap.rb`.

- [ ] **Step 5: Sidebar.** Add
  `{ label: "Invitations", path: admin_invitations_path, icon: "mail-plus", controllers: %w[ admin/invitations ], feature: :invitations }`
  to the `admin` array and apply the same `.select { feature nil or enabled }` filter `nav` uses.
  (`mail-plus` exists under `app/assets/svg/icons/lucide/outline/`.)

- [ ] **Step 6: Verify and commit.** Tests, rubocop green; open `/admin/invitations` locally,
  create one, copy the link. Commit: "Add admin page to create, copy and revoke invitations".

---

### Task 6: Accepting an invitation

**Files:**
- Modify: `config/routes.rb`:
  ```ruby
  get  "invitations/:token", to: "invitation_acceptances#new", as: :invitation_acceptance
  post "invitations/:token", to: "invitation_acceptances#create"
  ```
- Create: `app/services/accept_invitation.rb`, `test/services/accept_invitation_test.rb`
- Create: `app/controllers/invitation_acceptances_controller.rb`
- Create: `app/views/invitation_acceptances/new.html.erb`, `invalid.html.erb`
- Modify: `config/initializers/rack_attack.rb`
- Create: `test/controllers/invitation_acceptances_controller_test.rb`

- [ ] **Step 1: Failing service tests** (`AcceptInvitation`):
  - valid password → returns a persisted `User` with the invitation's email; invitation's
    `accepted_at` is set; default categories were seeded
  - too-short or mismatched password → returns an unsaved `User` with errors; invitation still
    pending; no user created
  - invitation no longer pending (accepted in the meantime) → no user created, base error

- [ ] **Step 2: Service.** Accepting creates a user *and* consumes the invitation, which must happen
  together or not at all, so it's a transaction with a row lock (two quick submits can't both
  succeed):

  ```ruby
  class AcceptInvitation
    def initialize(invitation, password:, password_confirmation:)
      @invitation = invitation
      @user = User.new(email_address: invitation.email_address, password: password,
        password_confirmation: password_confirmation)
    end

    # Returns the user: persisted on success, unsaved with errors otherwise.
    def call
      Invitation.transaction do
        @invitation.lock!

        if !@invitation.pending?
          @user.errors.add(:base, "This invitation is no longer valid.")
        elsif @user.save
          @invitation.update!(accepted_at: Time.current)
        end
      end

      @user
    rescue ActiveRecord::RecordNotUnique
      @user.errors.add(:base, "This invitation is no longer valid.")
      @user
    end
  end
  ```

- [ ] **Step 3: Failing controller tests:**
  - GET with a valid token (flag on for the inviter) → 200, shows the email read-only and no
    editable email field
  - POST valid → user created, signed in (`Current`/cookie set; follow redirect to root works),
    invitation accepted
  - POST too-short password → 422, errors shown, nothing created
  - invalid token, tampered token, revoked, expired, and already-accepted → **identical** response
    (same status and same body text) for every case; assert that explicitly by comparing them
  - a `User` with the invited email created after the invite → generic invalid response
  - flag off for the inviter → 404 even with a valid token
  - signed-in user opening a valid link → redirected with "You're already signed in", nothing
    created

- [ ] **Step 4: Controller:**

  ```ruby
  class InvitationAcceptancesController < ApplicationController
    allow_unauthenticated_access
    rate_limit to: 10, within: 3.minutes, only: :create,
      with: -> { redirect_to new_session_path, alert: "Try again later." }

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
      def redirect_if_signed_in
        redirect_to root_path, notice: "You're already signed in." if authenticated?
      end

      # Every unusable link gets the same response so a link-holder can't tell
      # expired from revoked from used.
      def set_invitation
        @invitation = Invitation.find_pending_by_token(params[:token])

        if @invitation.nil? || User.exists?(email_address: @invitation.email_address)
          render :invalid, status: :not_found
        elsif !FeatureFlag.enabled?(:invitations, user: @invitation.invited_by)
          head :not_found
        end
      end
  end
  ```

  Known nuance, accepted: a garbage token renders the friendly "invalid" page even when the flag is
  off, because there's no inviter to check the flag against. It reveals only that invitation URLs
  exist, nothing about any invitation.

- [ ] **Step 5: Views**, matching `passwords/edit.html.erb` (DaisyUI `card`, signed-out shell):
  `new` shows "You're invited to Moneymap", the email as text (not an input), password +
  confirmation with `autocomplete="new-password"`, `minlength` from `User::PASSWORD_MIN_LENGTH`,
  `maxlength: 72`, a hint "At least 15 characters", and the user's errors. `invalid` shows "This
  invitation link is invalid or has expired. Ask the person who invited you for a new one." and a
  link to sign in.

- [ ] **Step 6: Rack::Attack throttle** next to the existing ones:

  ```ruby
  # Throttle invitation acceptance by IP — it accepts a password and creates an account.
  throttle("invitation_acceptances/ip", limit: 5, period: 60) do |req|
    req.ip if req.post? && req.path.start_with?("/invitations/")
  end
  ```

- [ ] **Step 7: Verify and commit.** Tests, rubocop green.
  Commit: "Let invitees accept an invitation and create their account".

---

### Task 7: Docs

- [ ] `CLAUDE.md`: Project state (an invite-only sign-up path now exists); the feature-flag
  paragraph (registry now has four keys, including `invitations`, gated by inviter for
  acceptance); the encryption-keys note (dev/test keys in environment files; production needs
  `active_record_encryption` in credentials); `Admin::` namespace now also has invitations.
- [ ] `docs/production-launch-tbd.md`: narrow "No self-serve sign-up exists" to "invite-only
  sign-up exists; open sign-up and emailed invitations don't"; add the production encryption-keys
  requirement; note the 15-character password minimum closes the weak-password gap.
- [ ] Commit: "Document invite-only sign-up".

---

### Task 8: Verification before the PR

- [ ] `bin/ci` green.
- [ ] `bin/rails test:system` green (not part of `bin/ci`, but GitHub CI runs it).
- [ ] Manual click-through in development (`bin/dev`), signed in as your `.env` admin:
  1. `/admin/invitations` → create an invitation for a made-up address → copy the link.
  2. Open the link in a private/incognito window → set a 14-character password (rejected) → set a
     15+ character one → you land in the app as the new user with default categories.
  3. Open the same link again → generic invalid page.
  4. Create another invitation → revoke it → its link shows the generic invalid page.
  5. Turn the flag off for yourself at `/admin/feature_flags` → the Invitations sidebar entry
     disappears and `/admin/invitations` is 404.
  6. Rate limit spot check: submit the acceptance form with a bad password 11 times within three
     minutes → the 11th redirects to sign-in with "Try again later." This exercises Rails'
     `rate_limit` only (development uses `:memory_store`, so it works locally); Rack::Attack
     safelists localhost, so its throttle can't be seen in local testing.
- [ ] Open the PR against **`cferrante/moneymap` `main`** (`gh pr create`; the default repo is
  already set to the fork) with a plain-language description. Confirm GitHub CI passes before
  merging.

## Deviations from the plan (recorded during implementation)

- **Task 5 added the two public acceptance routes** (`GET`/`POST /invitations/:token`), planned for
  Task 6. The admin page builds each pending invitation's link with `invitation_acceptance_url`,
  so it couldn't render without them. Between Tasks 5 and 6 a copied link pointed at a controller
  that didn't exist yet; that was harmless behind the flag. The controller and views still landed
  in Task 6.
- **Task 8 added a browser-driven system test** (`test/system/invitations_test.rb`), not in the
  original plan. Verification found that nothing automated exercised the clipboard Stimulus
  controller, because integration tests don't run JavaScript. The test drives headless Chrome
  through the full loop (create, copy, accept in a signed-out session, see "Accepted"), and grants
  clipboard permission over the Chrome DevTools Protocol so it can read back what Copy wrote. It
  runs in GitHub CI's `system-test` job; `bin/ci` doesn't include system tests.

## Explicitly not in this plan

Emailing invitations, open sign-up, non-admin inviters, email verification for existing users,
encrypting `users.email_address`, and any production deployment. See the spec's "Out of scope".
