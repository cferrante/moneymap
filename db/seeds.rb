# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# A couple of sample logins so dev/demo environments aren't empty.
[
  "demo@moneymap.test",
  "alex@moneymap.test"
].each do |email_address|
  User.find_or_create_by!(email_address: email_address) do |user|
    user.password = "moneymap-demo-password"
  end
end

# Demo data (accounts, categories, ~3 months of transactions) for the demo user only, so the
# hosted app has something to look at. Gated on "no accounts yet" rather than per-record
# find_or_create_by, since transactions have no natural unique key — safe to leave running on
# every boot (like the rest of this file) because it only ever fires once per user. Wrapped in a
# transaction so a mid-run failure can't leave partial data behind: either it all lands, or the
# guard is still false next boot and it retries cleanly. Categories use find_or_create_by! since
# some may already exist from manual testing before this seed data existed.
demo_user = User.find_by!(email_address: "demo@moneymap.test")

if demo_user.accounts.none?
  ActiveRecord::Base.transaction do
    checking = demo_user.accounts.create!(name: "Everyday Checking", kind: "checking", starting_balance_cents: 250_000)
    savings  = demo_user.accounts.create!(name: "Emergency Fund", kind: "savings", starting_balance_cents: 800_000)
    credit   = demo_user.accounts.create!(name: "Rewards Card", kind: "credit", starting_balance_cents: 0)

    category = ->(name, kind, color) do
      demo_user.categories.find_or_create_by!(name: name) { |c| c.kind = kind; c.color = color }
    end

    salary         = category.call("Salary", "income", "green")
    freelance      = category.call("Freelance", "income", "teal")
    rent           = category.call("Rent", "expense", "red")
    groceries      = category.call("Groceries", "expense", "orange")
    utilities      = category.call("Utilities", "expense", "yellow")
    dining         = category.call("Dining Out", "expense", "pink")
    transportation = category.call("Transportation", "expense", "blue")
    entertainment  = category.call("Entertainment", "expense", "purple")

    rng = Random.new(20260830) # fixed seed so demo data looks the same every time it's (re-)generated
    today = Date.current
    # Current month plus the two before it, capped at "today" so nothing is dated in the future.
    [ 2, 1, 0 ].map { |n| (today << n).beginning_of_month }.each do |month_start|
      month_end = [ month_start.end_of_month, today ].min

      demo_user.transactions.create!(account: checking, category: salary, txn_type: "income",
        amount_cents: 320_000, occurred_on: month_start, description: "Paycheck")

      payday_two = month_start + 14
      if payday_two <= month_end
        demo_user.transactions.create!(account: checking, category: salary, txn_type: "income",
          amount_cents: 320_000, occurred_on: payday_two, description: "Paycheck")
      end

      if rng.rand < 0.6
        demo_user.transactions.create!(account: checking, category: freelance, txn_type: "income",
          amount_cents: rng.rand(20_000..80_000), occurred_on: [ month_start + 8, month_end ].min,
          description: "Freelance invoice")
      end

      demo_user.transactions.create!(account: checking, category: rent, txn_type: "expense",
        amount_cents: 150_000, occurred_on: month_start, description: "Rent")

      utilities_day = month_start + 4
      if utilities_day <= month_end
        demo_user.transactions.create!(account: checking, category: utilities, txn_type: "expense",
          amount_cents: rng.rand(9_000..16_000), occurred_on: utilities_day, description: "Electric & water")
      end

      (month_start..month_end).step(7) do |day|
        demo_user.transactions.create!(account: checking, category: groceries, txn_type: "expense",
          amount_cents: rng.rand(5_500..11_000), occurred_on: day, description: "Groceries")
      end

      ((month_start + 2)..month_end).step(6) do |day|
        demo_user.transactions.create!(account: credit, category: dining, txn_type: "expense",
          amount_cents: rng.rand(1_800..6_500), occurred_on: day, description: "Dining out")
      end

      ((month_start + 3)..month_end).step(9) do |day|
        demo_user.transactions.create!(account: credit, category: transportation, txn_type: "expense",
          amount_cents: rng.rand(2_000..7_000), occurred_on: day, description: "Gas & rideshare")
      end

      ((month_start + 6)..month_end).step(13) do |day|
        demo_user.transactions.create!(account: credit, category: entertainment, txn_type: "expense",
          amount_cents: rng.rand(1_200..4_500), occurred_on: day, description: "Movie night")
      end

      transfer_day = [ month_start + 16, month_end ].min
      transfer_id = SecureRandom.uuid
      demo_user.transactions.create!(account: checking, txn_type: "transfer", transfer_id: transfer_id,
        amount_cents: -50_000, occurred_on: transfer_day, description: "Transfer to savings")
      demo_user.transactions.create!(account: savings, txn_type: "transfer", transfer_id: transfer_id,
        amount_cents: 50_000, occurred_on: transfer_day, description: "Transfer to savings")
    end
  end

  puts "Seeded demo data: #{demo_user.accounts.count} accounts, #{demo_user.categories.count} " \
       "categories, #{demo_user.transactions.count} transactions."
end

# Monthly budget targets for the demo user, covering the same three months the
# transactions above span, so the Budgets page has a spread of on-track / watch /
# over-budget cards rather than being empty. Gated on "no budgets yet" for the
# same reason as the block above.
if demo_user.budgets.none?
  targets = {
    "Rent" => 150_000,
    "Groceries" => 38_000,
    "Dining Out" => 25_000,
    "Transportation" => 22_000,
    "Utilities" => 17_500,
    "Entertainment" => 9_000
  }

  ActiveRecord::Base.transaction do
    months = [ 2, 1, 0 ].map { |n| (Date.current << n).beginning_of_month }

    targets.each do |category_name, target_cents|
      category = demo_user.categories.find_by(name: category_name)
      next if category.nil?

      months.each do |month|
        demo_user.budgets.create!(category: category, month: month, target_cents: target_cents)
      end
    end
  end

  puts "Seeded #{demo_user.budgets.count} budgets."
end

# Feature flags for the dashboard/budgets/reports pages, enabled in DEVELOPMENT
# ONLY. This deliberately does not run in production: seeds execute on every
# container boot there, so enabling flags here would make the gate decorative and
# ship the pages to everyone the moment they deploy. Toggle them for real at
# /admin/feature_flags (takes effect immediately, no deploy).
if Rails.env.development?
  FeatureFlag::REGISTRY.each do |key|
    FeatureFlag.find_or_create_by!(key: key).update!(globally_enabled: true)
  end

  puts "Enabled #{FeatureFlag.count} feature flags (development only)."
end

# Personal login, opt-in via env vars set in the Render dashboard (there's no self-serve
# sign-up yet, and SSH/console access isn't available on the free plan) — also the only way to
# reach the admin flag UI in production, since that same lack of console access rules out
# `User.find_by(...).update!(admin: true)` there. Only sets the password on creation, so
# re-running this after changing SEED_ADMIN_PASSWORD won't silently reset an already-created
# account; the admin grant, though, is checked and (re-)applied on every boot, so promoting this
# user doesn't require recreating the record.
#
# Seeds run on every production boot under `set -e` (bin/docker-entrypoint), so a new account
# that fails validation (e.g. a SEED_ADMIN_PASSWORD under User::PASSWORD_MIN_LENGTH) must not
# raise: that would stop the container from ever starting. It's skipped with a warning in the
# deploy log instead, and the app boots without the admin login.
if ENV["SEED_ADMIN_EMAIL"].present? && ENV["SEED_ADMIN_PASSWORD"].present?
  admin_user = User.find_or_initialize_by(email_address: ENV["SEED_ADMIN_EMAIL"])
  admin_user.password = ENV["SEED_ADMIN_PASSWORD"] if admin_user.new_record?

  if admin_user.new_record? && admin_user.invalid?
    warn "Skipping the SEED_ADMIN account: #{admin_user.errors.full_messages.to_sentence}. " \
      "Fix SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD and redeploy."
  else
    admin_user.save! if admin_user.new_record?
    admin_user.update!(admin: true) unless admin_user.admin?
  end
end

puts "Seeded #{User.count} user(s)."
