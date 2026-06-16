# `config.reap_in_test` — Implementation Plan (PR 2)

**Goal:** Add a declarative `config.reap_in_test` so adopters can control the reaper's `Rails.env.test?` auto-stop, removing the need for app-side boot guards.

**Architecture:** New boolean config (default `false` = today's behavior). `Railtie.deactivate_pool_reaper_in_test_env!` gains one guard: skip the stop when `reap_in_test` is `true`. No behavior change at the default.

**Design spec:** `docs/designs/v4-pool-adopter-ergonomics.md` (component A).

**Branch:** `feat/reap-in-test` off `main`.

---

### Task 1: `config.reap_in_test` — default + validation

**Files:** `lib/apartment/config.rb`, `spec/unit/config_spec.rb`

- Add `:reap_in_test` to the `attr_accessor` list; `@reap_in_test = false` in `initialize`.
- In `validate!`, with the other booleans:

```ruby
unless [true, false].include?(@reap_in_test)
  raise(ConfigurationError, "reap_in_test must be true or false, got: #{@reap_in_test.inspect}")
end
```

- Specs (`config_spec.rb`):

```ruby
it { expect(config.reap_in_test).to(be(false)) }   # in the defaults block

it 'raises when reap_in_test is not a boolean' do
  config.tenant_strategy = :schema
  config.tenants_provider = -> { [] }
  config.reap_in_test = 'yes'
  expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /reap_in_test/))
end

it 'accepts reap_in_test = true' do
  config.tenant_strategy = :schema
  config.tenants_provider = -> { [] }
  config.reap_in_test = true
  expect { config.validate! }.not_to(raise_error)
end
```

TDD + commit.

---

### Task 2: Railtie guard

**Files:** `lib/apartment/railtie.rb`, `spec/unit/railtie_spec.rb`

- Add the guard (config may be nil when the method is unit-tested in isolation, so use `&.`):

```ruby
def self.deactivate_pool_reaper_in_test_env!
  return unless Rails.env.test?
  return if Apartment.config&.reap_in_test
  return unless Apartment.pool_reaper

  Apartment.pool_reaper.stop
  Apartment::Instrumentation.instrument(:reaper_stopped, reason: :test_env)
end
```

- Update the method's doc comment to note that `config.reap_in_test = true` keeps the reaper running in test (so a deployment that runs under `RAILS_ENV=test` semantics doesn't silently disable reaping — no boot guard needed).

- Specs (`railtie_spec.rb`, in the existing `.deactivate_pool_reaper_in_test_env!` describe):

```ruby
it 'leaves the reaper running when config.reap_in_test is true' do
  reaper = instance_double(Apartment::PoolReaper, stop: nil)
  allow(Apartment).to(receive(:pool_reaper).and_return(reaper))
  allow(Apartment).to(receive(:config).and_return(instance_double(Apartment::Config, reap_in_test: true)))
  allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('test')))

  Apartment::Railtie.deactivate_pool_reaper_in_test_env!

  expect(reaper).not_to(have_received(:stop))
end

it 'stops the reaper when config.reap_in_test is false (default)' do
  reaper = instance_double(Apartment::PoolReaper, stop: nil)
  allow(Apartment).to(receive(:pool_reaper).and_return(reaper))
  allow(Apartment).to(receive(:config).and_return(instance_double(Apartment::Config, reap_in_test: false)))
  allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('test')))

  Apartment::Railtie.deactivate_pool_reaper_in_test_env!

  expect(reaper).to(have_received(:stop))
end
```

TDD + commit. The existing deactivate specs (which don't stub `config`) must still pass — `&.` makes a nil config fall through to the stop.

---

### Task 3: Docs

**Files:** `README.md`, `docs/upgrading-to-v4.md`

- README "Pool Settings": add

  > `reap_in_test`: keep the background reaper running under `Rails.env.test?` (default `false` — the railtie stops it in test, since fixture transactions make eviction a liability). Set `true` if a deployed process can run under test-env semantics and must keep reaping, instead of guarding `RAILS_ENV` at boot.

- `docs/upgrading-to-v4.md` pool-config table: add the `reap_in_test` row (default `false`).

Commit.

---

### Task 4: Verify

- `bundle exec rspec spec/unit/config_spec.rb spec/unit/railtie_spec.rb` — green
- `bundle exec rspec spec/unit/` — green, no regressions (existing deactivate specs still pass)
- `bundle exec rubocop lib/apartment/config.rb lib/apartment/railtie.rb spec/unit/config_spec.rb spec/unit/railtie_spec.rb` — clean
- `bundle exec appraisal rails-7.2-sqlite3 rspec spec/unit/config_spec.rb` and `rails-8.1-sqlite3` — green

Then: adversarial panel review (standard for this series) → address findings → PR `feat/reap-in-test` → `main`.
