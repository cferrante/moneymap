# Invite-only sign-up — design

**Date:** 2026-10-15
**Status:** approved, ready for implementation plan
**Branch:** `feat/invite-only-sign-up`

## Context

Moneymap has no way for a new person to get an account. Users exist only via `db/seeds.rb` (two
sample users in development, plus the `SEED_ADMIN_EMAIL` founder account in production).
`docs/production-launch-tbd.md` lists "decide the sign-up story (build it, or confirm invite-only
is intentional)" as the first open item before real users.

This spec chooses a third option between "open sign-up form" and "no sign-up": **an admin
generates a single-use, expiring invitation link for a specific email address; the invitee opens
it and sets a password to create their account.**

Why invite-only rather than an open registration form, at this stage:

- **No public account-creation endpoint.** Bots, spam accounts, and "this email is already taken"
  account enumeration largely don't apply, because there's no form a stranger can reach without a
  valid link.
- **Controlled membership on fragile infrastructure.** Production runs on free-tier Render
  Postgres (deleted every 30 days, no backups). Admin-only invites mean nobody ends up with data
  on it who wasn't deliberately let in and told the risk.
- **Lays the groundwork for email verification.** Once production can send email, delivering the
  invite link by email makes "clicked the link" equivalent to "owns this inbox" — sign-up and
  verification in one flow. That delivery is out of scope here (see below), but the design
  shouldn't preclude it.
- **$0.** No new services, gems, or paid plans.

## Decisions (from discussion)

- **Admins only can create invitations.** Reuses the existing `Admin::` namespace and
  `AdminAuthorization` concern (`User#admin`). Opening invitations to every user is deferred — easy
  to widen later, hard to take back once relied on. (session-settled: user-directed — chosen over
  "any logged-in user can invite": simpler, more control, avoids per-user abuse limits for now.)
- **Stored invitations, not a purely stateless link.** An `invitations` table lets an admin list
  pending invites, revoke one, and see which were accepted; a stateless signed URL (like the
  password-reset link) can't be listed or revoked, and single-use is awkward without a row to mark.
  (session-settled: user-approved — chosen over a stateless signed link.)
- **Link delivery is manual for now: the admin copies the link** and sends it however they choose.
  Production SMTP isn't configured (`config/environments/production.rb` has it commented out;
  password reset is already non-functional there), and wiring it up is a separate piece of work
  with its own setup (domain DNS, a provider account). Trade-off accepted: a copied link can be
  forwarded, so in this version accepting an invite does **not** prove inbox ownership.
- **Behind a feature flag, `invitations`, off by default.** Staging is paused, so merging to
  `main` deploys straight to production; the flag lets the work merge before it's switched on.
- **Branch name** `feat/invite-only-sign-up`.

## Behavior

### Admin: creating and managing invitations (`/admin/invitations`)

- Admin enters an email address. On success, the page shows the invitation link with a "copy"
  affordance and its expiry date.
- The email is normalized the same way `User#email_address` is (strip + downcase).
- Creating an invitation is **rejected** with a visible error when:
  - the email is not a valid address format;
  - a `User` with that email already exists ("already has an account");
  - a pending (unaccepted, unexpired) invitation for that email already exists — the admin should
    copy or revoke the existing one instead of creating a duplicate.
- The index lists invitations with status: **pending**, **expired**, or **accepted** (with
  date), plus who created each one.
- A pending invitation can be **revoked** (deleted). Its link stops working immediately.
- A pending invitation's link can be **copied again** later from the index (see "Token" below for
  why this is possible).
- Sidebar: an "Invitations" entry in the existing admin section, alongside "Feature flags", shown
  only when the flag is enabled for the current admin.

### Invitee: accepting (`/invitations/<token>`)

- Reachable while logged out (`allow_unauthenticated_access`).
- Shows the invited email address **read-only** — the invitee cannot change which email the account
  is created for — plus password and password-confirmation fields.
- On submit with a valid password: creates the `User`, marks the invitation accepted, starts a
  session via the existing `start_new_session_for`, and redirects to the app root. The new user
  gets default categories automatically (`after_create :seed_default_categories`).
- On invalid password: re-renders the form with errors (422), invitation remains pending.
- An **invalid, expired, revoked, or already-accepted** link shows one generic "This invitation
  link is invalid or has expired" message and no form. The message is deliberately identical across
  cases so a link-holder learns nothing about which case applies.
- If a logged-in user opens an invitation link, they are told they're already signed in rather
  than being shown the form (avoids silently creating a second account while authenticated).
- If a `User` with the invited email was created between invite and acceptance (e.g. via seeds),
  acceptance fails with the generic invalid-link message and creates nothing.

### Feature flag behavior

- `invitations` is added to `FeatureFlag::REGISTRY`.
- Admin invitation pages: gated with `gate_behind :invitations` (404 when off), so the flag can be
  granted per-admin for dogfooding, like the existing flags.
- Acceptance page: the invitee is logged out, so a per-user check against `Current.user` can't
  apply. Instead, acceptance is allowed when the flag is enabled **for the invitation's creator**
  (`FeatureFlag.enabled?(:invitations, user: invitation.invited_by)`). Effect: granting the flag to
  one admin makes the whole loop work end-to-end for that admin's invites, without enabling it
  globally. When off, the acceptance URL responds 404, same as other gated pages.
- `db/seeds.rb` enables it in development only, matching the existing three flags.

## Data model

```ruby
create_table :invitations do |t|
  t.string     :email_address, null: false     # encrypted, deterministic (see below)
  t.references :invited_by, null: false, foreign_key: { to_table: :users }
  t.datetime   :expires_at, null: false
  t.datetime   :accepted_at                     # null = not yet accepted
  t.timestamps
end
add_index :invitations, :email_address
```

- **Expiry:** 7 days from creation, stored explicitly in `expires_at` so the admin index can show
  it and so the rule is visible in data rather than only in token config.
- **Accepted invitations are kept, not deleted** — they're the record of who invited whom.
  Revoking deletes only pending ones.
- **`invited_by` user deletion:** `User has_many :sent_invitations, dependent: :destroy` —
  deleting an admin deletes their invitations. Acceptable at this scale; revisit if invitations
  ever need to outlive their creator.
- **"One pending invitation per email"** is enforced by a model validation, not a database
  constraint. A partial unique index can't express "unexpired", since expiry is time-relative. The
  race (two admins inviting the same address in the same instant) is harmless: acceptance creates
  at most one `User` because `users.email_address` is uniquely indexed.

### Encryption of `email_address`

Per CLAUDE.md's security conventions, the new PII column uses Active Record Encryption by default.
It's `deterministic: true` because the app must query by it (duplicate-pending check, matching an
existing `User`). Deterministic encryption reveals when two rows share an email but not the email
itself — the standard trade-off for a queryable encrypted column.

**Setup cost:** this is the first `encrypts` in the app (confirmed: no existing `encrypts` calls or
encryption config), so it needs encryption keys configured per environment.

This fork has no `config/master.key` (the committed `config/credentials.yml.enc` was encrypted by
the upstream repo's owner and is unreadable here), so keys can't simply be added to credentials.
Instead:

- **Development and test:** fixed, non-secret keys set directly in
  `config/environments/development.rb` and `config/environments/test.rb`. They protect only
  throwaway local/test data, so committing them is acceptable, and it lets GitHub CI run without a
  repository secret. Test also sets `encrypt_fixtures = true` so invitation fixtures are stored
  encrypted.
- **Production:** keys read from `Rails.application.credentials.active_record_encryption`, the
  Rails default. Whoever deploys must generate keys (`bin/rails db:encryption:init`) and add them
  to their own production credentials. Without them, invitation reads/writes raise; unrelated
  pages are unaffected, since Active Record only needs the keys when an encrypted attribute is
  touched. No production deployment from this fork exists today, so this is documented rather
  than done.
- **Not done:** regenerating `config/master.key` / `credentials.yml.enc`. That would discard the
  upstream owner's existing (unreadable) credentials in this fork for no benefit.

Noted inconsistency, not fixed here: `users.email_address` itself is plaintext. Encrypting it is a
larger change (existing data, the login lookup) and out of scope.

### Token

Uses Rails' `generates_token_for` on `Invitation` (the same mechanism behind
`User#password_reset_token`), rather than a random token stored in a column:

```ruby
generates_token_for :acceptance, expires_in: 7.days do
  accepted_at
end
```

- **Signed, not stored.** The token embeds the invitation id plus a signature derived from
  `secret_key_base`; nothing secret sits in the database, so a DB leak doesn't leak working links.
- **Single-use for free.** The block's value (`accepted_at`) is baked into the signature; once it
  changes from `nil` to a timestamp, every previously issued token for that invitation fails
  verification.
- **Revocation** is deleting the row — the token's id no longer resolves.
- **Re-copyable.** Because nothing is stored, the index can generate a fresh valid link for a
  pending invitation at any time. Older copies of the link also remain valid until expiry or
  acceptance; acceptable, since they all grant the same thing.
- Lookup: `Invitation.find_by_token_for(:acceptance, token)` — returns `nil` for tampered,
  expired, revoked, or accepted.
- The model also checks `expires_at` directly, so the stored expiry and the token's `expires_in`
  can't disagree silently.

## Validations added to `User`

Required now that an outsider can choose a password. Neither exists today.

- **`email_address`:** presence, format (`URI::MailTo::EMAIL_REGEXP`), max length 254,
  uniqueness (case-insensitive is already guaranteed by the `normalizes` call). The DB unique index
  stays as the backstop; this adds a friendly error instead of a raised `RecordNotUnique`.
- **`password`:** minimum length 15 (see resolved question 1), `allow_nil: true` so existing records and
  non-password updates aren't affected. Maximum stays bcrypt's 72-byte limit, already enforced by
  `has_secure_password`.
- Existing users with shorter passwords keep working; the rule applies when a password is set or
  changed (sign-up, password reset, settings).

## Abuse protection

Following `config/initializers/rack_attack.rb` and the existing controllers:

- **Acceptance (`POST`)**: Rails `rate_limit` in the controller (10 per 3 minutes, matching
  `SessionsController`) **plus** a `rack-attack` IP throttle (5 per minute), since it accepts a
  password and creates an account.
- **Invitation creation (admin)**: Rails `rate_limit` (e.g. 20 per hour). Admin-only already limits
  exposure; this caps damage from a compromised admin session. No rack-attack rule needed for an
  authenticated-admin endpoint.
- Token guessing isn't a practical attack — tokens are signed — but the acceptance throttle covers
  brute-force attempts anyway.

## Testing

- **Model:** `User` validations (email format/length/uniqueness, password length, `allow_nil`
  behavior on non-password updates); `Invitation` validations (format, existing-user rejection,
  duplicate-pending rejection), status (pending/expired/accepted), token lookup for valid,
  tampered, expired, revoked, and accepted cases.
- **Integration:** admin create/list/revoke; non-admin gets 404; flag-off gets 404 on both sides;
  acceptance happy path (user created, invitation accepted, session started, categories seeded);
  invalid password re-renders 422; each invalid-link case shows the identical generic message;
  signed-in user opening a link; reusing an accepted link fails.
- Tests use `enable_feature` / `enable_feature_for` per `test/test_helpers/feature_flag_test_helper.rb`.
- `bin/ci` green, plus a manual click-through in development (staging is paused, so local is the
  only pre-production check).

## Out of scope

- Sending invitations by email (needs production SMTP — separate work).
- Email verification for existing users (the earlier `is_email_verified` idea; becomes relevant
  once email delivery exists).
- Open, self-serve registration.
- Non-admin users sending invitations.
- Encrypting `users.email_address`.
- Granting `admin` to invited users (still only via seeds/console).

## Docs to update with the implementation

- `CLAUDE.md` — project state (sign-up path now exists, invite-only), feature-flag registry list.
- `docs/production-launch-tbd.md` — narrow the "no self-serve sign-up" item to reflect
  invite-only; note the new `encrypts` credentials dependency.

## Resolved review questions

1. **Minimum password length: 15**, no composition rules (no "must contain a symbol").
   (session-settled: user-approved — chosen over a shorter floor such as OWASP ASVS's 8: NIST SP
   800-63B rev. 4 asks for at least 15 when the password is the only factor, which it is here with
   no 2FA.) Consequence: the development seed password `"password123"` (11 characters,
   `db/seeds.rb:17`) must be lengthened, and production's `SEED_ADMIN_PASSWORD` must meet the rule
   if the seed ever creates that account again (it only sets the password on creation).
2. **Keep the feature flag.** (session-settled: user-approved — chosen over shipping without a
   flag on the grounds that admin-only creation already limits access: the flag is cheap and lets
   the work merge to `main` before it's finished, consistent with how in-progress work ships here.)
