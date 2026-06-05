# Apartment RuboCop Cops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two custom RuboCop cops in the gem — `Apartment/NoDirectCurrentWrite` (error, bans raw `Apartment::Current` writes) and `Apartment/PreferBlockSwitch` (warning, nudges `switch!` toward the block form) — so downstream apps can enforce the block-form tenant-switching discipline.

**Architecture:** Cops live under `lib/rubocop/cop/apartment/` and ship via the gem (`s.files` extended to include `config/`). A `lib/rubocop/apartment.rb` entry point requires both; `config/default.yml` carries their defaults. `lib/rubocop` is Zeitwerk-ignored (it would map to the wrong-cased `Rubocop` constant). The cops are generic (match the qualified `Apartment::Current` / `Apartment::Tenant` receiver only); both exemptions (`lib/apartment/`, `spec/`) live in apartment's own `.rubocop.yml`, not in cop logic.

**Tech Stack:** Ruby, RuboCop 1.86 + rubocop-ast (node-pattern matchers, `RuboCop::Cop::Base`), RSpec with `RuboCop::RSpec::ExpectOffense`. Cop specs need no database.

**Design spec:** `docs/designs/rubocop-cops.md`

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `lib/apartment.rb` | Modify | Add `loader.ignore("#{__dir__}/rubocop")` (Zeitwerk) |
| `lib/rubocop/cop/apartment/no_direct_current_write.rb` | Create | The error cop |
| `lib/rubocop/cop/apartment/prefer_block_switch.rb` | Create | The warning cop |
| `lib/rubocop/apartment.rb` | Create | Entry point: requires both cops |
| `config/default.yml` | Create | Cop defaults (Enabled/Severity/Description) |
| `ros-apartment.gemspec` | Modify | Ship `config/` in `s.files` |
| `.rubocop.yml` | Modify | Load the cops, inherit defaults, add internal Excludes |
| `README.md` | Modify | Downstream opt-in recipe |
| `spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb` | Create | Cop spec (standalone) |
| `spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb` | Create | Cop spec (standalone) |
| `spec/unit/rubocop/apartment_spec.rb` | Create | Entry-point + config smoke spec |

**Why cop specs are standalone (no `spec_helper`):** `.rspec` does not auto-require `spec_helper`, and `spec_helper.rb` does `require 'apartment'` (triggering Zeitwerk). Cop specs `require 'rubocop'` + the cop file directly, so they never load Apartment. The full suite (`spec/unit/`) still loads Apartment via other specs — which is why the Zeitwerk ignore (Task 1) must land before any `lib/rubocop` file exists.

---

## Task 1: Zeitwerk ignore for `lib/rubocop`

Add the ignore first, before any `lib/rubocop` file exists, so the full suite keeps loading Apartment cleanly once the cop files land.

**Files:**
- Modify: `lib/apartment.rb` (after the `cli` ignores, ~line 26)

- [ ] **Step 1: Add the ignore line**

In `lib/apartment.rb`, immediately after the line `loader.ignore("#{__dir__}/apartment/cli")`, add:

```ruby

# RuboCop cops live under lib/rubocop and load only via RuboCop's `require:`
# (config), never through Apartment's autoloader. Ignore avoids Zeitwerk mapping
# lib/rubocop to a `Rubocop` constant (wrong casing vs RuboCop) — same rationale
# as the cli.rb / cli ignores above.
loader.ignore("#{__dir__}/rubocop")
```

(`loader.ignore` of a not-yet-existing path is harmless; the directory arrives in Task 2.)

- [ ] **Step 2: Verify Apartment still loads and the suite is green**

Run: `bundle exec ruby -e "require 'apartment'; puts 'loaded ok'"`
Expected: `loaded ok` (no Zeitwerk error).

Run: `bundle exec rspec spec/unit/ 2>&1 | tail -3`
Expected: existing examples pass, 0 failures (pending allowed).

- [ ] **Step 3: Commit**

```bash
git add lib/apartment.rb
git commit -m "Zeitwerk-ignore lib/rubocop ahead of shipping custom cops

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Apartment/NoDirectCurrentWrite` cop (TDD)

**Files:**
- Create: `spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb`
- Create: `lib/rubocop/cop/apartment/no_direct_current_write.rb`

- [ ] **Step 1: Write the failing spec**

Create `spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rubocop'
require 'rubocop/rspec/support'
require_relative '../../../../../lib/rubocop/cop/apartment/no_direct_current_write'

RSpec.describe(RuboCop::Cop::Apartment::NoDirectCurrentWrite, :config) do
  it 'flags a qualified Apartment::Current.tenant write' do
    expect_offense(<<~RUBY)
      Apartment::Current.tenant = 'acme'
                         ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags a qualified Apartment::Current.previous_tenant write' do
    expect_offense(<<~RUBY)
      Apartment::Current.previous_tenant = nil
                         ^^^^^^^^^^^^^^^ Do not write `Apartment::Current.previous_tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags a cbase (::Apartment) write' do
    expect_offense(<<~RUBY)
      ::Apartment::Current.tenant = 'acme'
                           ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'ignores the block-form switch' do
    expect_no_offenses("Apartment::Tenant.switch('acme') { :work }")
  end

  it 'ignores a read of Apartment::Current.tenant' do
    expect_no_offenses('x = Apartment::Current.tenant')
  end

  it 'ignores an unrelated Current constant' do
    expect_no_offenses("Foo::Current.tenant = 'x'")
    expect_no_offenses("Current.tenant = 'x'")
  end

  it 'respects an inline disable' do
    expect_no_offenses(<<~RUBY)
      Apartment::Current.tenant = 'x' # rubocop:disable Apartment/NoDirectCurrentWrite
    RUBY
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb`
Expected: FAIL with `LoadError` / `cannot load such file -- .../no_direct_current_write` (the cop file does not exist yet).

- [ ] **Step 3: Implement the cop**

Create `lib/rubocop/cop/apartment/no_direct_current_write.rb`:

```ruby
# frozen_string_literal: true

module RuboCop
  module Cop
    module Apartment
      # Bans direct assignment to Apartment::Current attributes. Application code
      # must change tenant context through the block-form switch, which guarantees
      # restore via ensure.
      #
      # @example
      #   # bad
      #   Apartment::Current.tenant = 'acme'
      #
      #   # good
      #   Apartment::Tenant.switch('acme') { ... }
      class NoDirectCurrentWrite < Base
        MSG = 'Do not write `Apartment::Current.%<attr>s` directly; use the ' \
              'block-form `Apartment::Tenant.switch(tenant) { ... }`.'

        # @!method current_attr_write?(node)
        def_node_matcher :current_attr_write?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Current) {:tenant= :previous_tenant=} _)
        PATTERN

        def on_send(node)
          return unless current_attr_write?(node)

          attr = node.method_name.to_s.delete_suffix('=')
          # Highlight the attribute selector (`tenant` / `previous_tenant`), not the
          # whole assignment — stable range, independent of the RHS and any cbase.
          add_offense(node.loc.selector, message: format(MSG, attr: attr))
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb`
Expected: PASS (7 examples). If a caret line mismatches, RuboCop prints the expected vs actual range/message — align the `^` count to the flagged expression and the annotation to `MSG` exactly.

- [ ] **Step 5: Commit**

```bash
git add lib/rubocop/cop/apartment/no_direct_current_write.rb spec/unit/rubocop/cop/apartment/no_direct_current_write_spec.rb
git commit -m "Add Apartment/NoDirectCurrentWrite cop (bans raw Apartment::Current writes)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `Apartment/PreferBlockSwitch` cop (TDD)

**Files:**
- Create: `spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb`
- Create: `lib/rubocop/cop/apartment/prefer_block_switch.rb`

- [ ] **Step 1: Write the failing spec**

Create `spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rubocop'
require 'rubocop/rspec/support'
require_relative '../../../../../lib/rubocop/cop/apartment/prefer_block_switch'

RSpec.describe(RuboCop::Cop::Apartment::PreferBlockSwitch, :config) do
  it 'flags Apartment::Tenant.switch!' do
    expect_offense(<<~RUBY)
      Apartment::Tenant.switch!('acme')
                        ^^^^^^^ Use the block-form `Apartment::Tenant.switch(tenant) { ... }` instead of `switch!`.
    RUBY
  end

  it 'flags a cbase (::Apartment) switch!' do
    expect_offense(<<~RUBY)
      ::Apartment::Tenant.switch!('acme')
                          ^^^^^^^ Use the block-form `Apartment::Tenant.switch(tenant) { ... }` instead of `switch!`.
    RUBY
  end

  it 'ignores the block-form switch' do
    expect_no_offenses("Apartment::Tenant.switch('acme') { :work }")
  end

  it 'ignores reset' do
    expect_no_offenses('Apartment::Tenant.reset')
  end

  it 'ignores switch! on an unrelated receiver' do
    expect_no_offenses("Foo::Tenant.switch!('x')")
  end

  it 'respects an inline disable' do
    expect_no_offenses(<<~RUBY)
      Apartment::Tenant.switch!('x') # rubocop:disable Apartment/PreferBlockSwitch
    RUBY
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb`
Expected: FAIL with `LoadError` (cop file missing).

- [ ] **Step 3: Implement the cop**

Create `lib/rubocop/cop/apartment/prefer_block_switch.rb`:

```ruby
# frozen_string_literal: true

module RuboCop
  module Cop
    module Apartment
      # Nudges callers away from Apartment::Tenant.switch! toward the block-form
      # switch, which restores context via ensure. reset is intentionally not
      # flagged (it is the sanctioned unguarded path back to the default tenant).
      #
      # @example
      #   # bad
      #   Apartment::Tenant.switch!('acme')
      #
      #   # good
      #   Apartment::Tenant.switch('acme') { ... }
      class PreferBlockSwitch < Base
        MSG = 'Use the block-form `Apartment::Tenant.switch(tenant) { ... }` ' \
              'instead of `switch!`.'

        # @!method tenant_bang_switch?(node)
        def_node_matcher :tenant_bang_switch?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Tenant) :switch! ...)
        PATTERN

        def on_send(node)
          return unless tenant_bang_switch?(node)

          # Highlight the `switch!` selector — stable range regardless of receiver
          # prefix or arguments.
          add_offense(node.loc.selector)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/rubocop/cop/apartment/prefer_block_switch.rb spec/unit/rubocop/cop/apartment/prefer_block_switch_spec.rb
git commit -m "Add Apartment/PreferBlockSwitch cop (warning: prefer block-form switch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Entry point + `config/default.yml` (TDD smoke)

**Files:**
- Create: `spec/unit/rubocop/apartment_spec.rb`
- Create: `lib/rubocop/apartment.rb`
- Create: `config/default.yml`

- [ ] **Step 1: Write the failing smoke spec**

Create `spec/unit/rubocop/apartment_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rubocop'
require_relative '../../../lib/rubocop/apartment'

RSpec.describe('rubocop/apartment') do
  it 'registers both Apartment cops' do
    names = RuboCop::Cop::Registry.global.cops.map(&:cop_name)
    expect(names).to(include('Apartment/NoDirectCurrentWrite', 'Apartment/PreferBlockSwitch'))
  end

  it 'config/default.yml sets the documented severities' do
    config = RuboCop::ConfigLoader.load_file('config/default.yml')
    expect(config['Apartment/NoDirectCurrentWrite']['Severity']).to(eq('error'))
    expect(config['Apartment/PreferBlockSwitch']['Severity']).to(eq('warning'))
    expect(config['Apartment/NoDirectCurrentWrite']['Enabled']).to(be(true))
    expect(config['Apartment/PreferBlockSwitch']['Enabled']).to(be(true))
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/unit/rubocop/apartment_spec.rb`
Expected: FAIL with `LoadError` on `../../../lib/rubocop/apartment` (entry point missing).

- [ ] **Step 3: Create the entry point**

Create `lib/rubocop/apartment.rb`:

```ruby
# frozen_string_literal: true

require_relative 'cop/apartment/no_direct_current_write'
require_relative 'cop/apartment/prefer_block_switch'
```

- [ ] **Step 4: Create the config**

Create `config/default.yml`:

```yaml
Apartment/NoDirectCurrentWrite:
  Description: 'Use the block-form switch instead of writing Apartment::Current directly.'
  Enabled: true
  Severity: error

Apartment/PreferBlockSwitch:
  Description: 'Prefer the block-form Apartment::Tenant.switch over switch!.'
  Enabled: true
  Severity: warning
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/unit/rubocop/apartment_spec.rb`
Expected: PASS (2 examples). Run from the repo root so `config/default.yml` resolves.

- [ ] **Step 6: Commit**

```bash
git add lib/rubocop/apartment.rb config/default.yml spec/unit/rubocop/apartment_spec.rb
git commit -m "Add rubocop/apartment entry point and config/default.yml

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Ship `config/` in the gem + wire the repo's own RuboCop

**Files:**
- Modify: `ros-apartment.gemspec:16`
- Modify: `.rubocop.yml`

- [ ] **Step 1: Ship `config/` in the gemspec**

In `ros-apartment.gemspec`, replace line 16:

```ruby
  s.files = %w[ros-apartment.gemspec README.md] + `git ls-files -- lib`.split("\n")
```

with:

```ruby
  s.files = %w[ros-apartment.gemspec README.md] + `git ls-files -- lib config`.split("\n")
```

- [ ] **Step 2: Verify the config ships**

Run: `ruby -e "require 'rubygems'; puts Gem::Specification.load('ros-apartment.gemspec').files.grep(%r{config/})"`
Expected output includes: `config/default.yml`
(`config/default.yml` is tracked as of Task 4, so `git ls-files -- config` lists it.)

- [ ] **Step 3: Wire the cops into the repo's own `.rubocop.yml`**

In `.rubocop.yml`, add a `require:` block immediately after the existing `plugins:` block (after the `- rubocop-rspec` line), then the inherit + excludes. Insert:

```yaml
require:
  - ./lib/rubocop/apartment

inherit_from:
  - config/default.yml

Apartment/NoDirectCurrentWrite:
  Exclude:
    - lib/apartment/**/*
    - spec/**/*

Apartment/PreferBlockSwitch:
  Exclude:
    - lib/apartment/**/*
    - spec/**/*
```

(`require: ./lib/rubocop/apartment` uses a repo-relative path because the gem's `lib` is not on RuboCop's load path when linting in-repo. Downstream apps use `require: rubocop/apartment` — the installed gem's `lib` is on the load path. This distinction goes in the README, Task 6.)

- [ ] **Step 4: Run RuboCop on the repo — expect clean**

Run: `bundle exec rubocop 2>&1 | tail -5`
Expected: `no offenses detected` (the new cop files pass; the two Apartment cops find 0 violations because `lib/apartment/**/*` and `spec/**/*` are excluded and no other `lib` file writes `Apartment::Current` or calls `switch!`).

If the cop files themselves trip a style cop, autocorrect with `bundle exec rubocop -A lib/rubocop/` and re-inspect the diff (logic unchanged).

- [ ] **Step 5: Confirm the cops are actually loaded (not silently inert)**

Run: `bundle exec rubocop --show-cops Apartment/NoDirectCurrentWrite Apartment/PreferBlockSwitch 2>&1 | grep -E "Apartment/|Enabled|Severity"`
Expected: both cops listed, `Enabled: true`, severities `error` / `warning`.

- [ ] **Step 6: Commit**

```bash
git add ros-apartment.gemspec .rubocop.yml
git commit -m "Ship config/ in gemspec; enable Apartment cops in the repo's own RuboCop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: README docs + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find a placement anchor**

Run: `grep -n "^## " README.md`
Insert the new section before the last top-level section (e.g. a `## License` / `## Contributing` if present; otherwise append at end).

- [ ] **Step 2: Add the RuboCop section**

Insert this section:

```markdown
## RuboCop cops

Apartment ships two optional RuboCop cops that enforce the block-form
tenant-switching discipline. Enable them in your application's `.rubocop.yml`:

```yaml
require: rubocop/apartment
inherit_gem:
  ros-apartment: config/default.yml
```

- **`Apartment/NoDirectCurrentWrite`** (error) — bans assigning
  `Apartment::Current.tenant` / `.previous_tenant` directly. Change tenant context
  with `Apartment::Tenant.switch(tenant) { ... }` (or `with_default_tenant` for
  global work), which guarantees a restore via `ensure`.
- **`Apartment/PreferBlockSwitch`** (warning) — nudges `Apartment::Tenant.switch!`
  toward the block form. `reset` is not flagged.

Both match the qualified `Apartment::` receiver only. Scope them to your
application code with the standard `Exclude:` keys if needed. See
`docs/designs/rubocop-cops.md` for the rationale.
```
```

(Note: the closing ```` ``` ```` of the inner YAML fence is part of the section content — keep both fence levels when pasting.)

- [ ] **Step 3: Commit the docs**

```bash
git add README.md
git commit -m "Docs: README section for the Apartment RuboCop cops

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Final full verification**

Run: `bundle exec rspec spec/unit/ 2>&1 | tail -3`
Expected: all examples pass, 0 failures (the 15 new cop examples included).

Run: `bundle exec rubocop 2>&1 | tail -3`
Expected: `no offenses detected`.

Run: `git log --oneline main..HEAD`
Expected: the design commit plus six task commits. Branch `apartment-rubocop-cops` ready for a PR against `main`.

---

## Notes for the implementer

- **Caret precision in cop specs:** `expect_offense` requires the `^` run to underline the flagged expression exactly and the trailing text to equal the cop's message verbatim. If a spec fails on a range/message mismatch, RuboCop prints expected-vs-actual — align to it; the cop code is the source of truth for the message.
- **Both cops highlight `node.loc.selector`**, not the whole node — the caret range is the attribute/method token (`tenant`, `previous_tenant`, `switch!`), stable regardless of the RHS value or a `::` (cbase) prefix. `NoDirectCurrentWrite` passes an interpolated `message:` (the attr name varies); `PreferBlockSwitch` omits `message:` so `Base` uses the static `MSG` constant.
- **Run specs from the repo root** so `config/default.yml` (a relative path in the smoke spec) resolves.
- **Do not** add the `lib/apartment/` exemption to cop logic — it belongs only in this repo's `.rubocop.yml` (Task 5), so the shipped cop stays generic for downstream apps.
- **Do not** convert spec-suite `Current.tenant =` / `switch!` sites — `spec/**/*` is excluded by design (out of scope).
