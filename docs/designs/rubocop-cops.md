# Apartment RuboCop cops

**Status:** Designed, pending implementation
**Scope:** Two shippable custom cops + packaging, config, docs, specs
**Related:** [[tenant-aware-caching]] (the block-form discipline these cops enforce), `lib/apartment/tenant.rb`

## TL;DR

Ship two custom RuboCop cops in the gem so downstream apps can enforce the
block-form tenant-switching discipline. `Apartment/NoDirectCurrentWrite` (error)
bans assigning `Apartment::Current.tenant` / `.previous_tenant` directly;
`Apartment/PreferBlockSwitch` (warning) nudges `Apartment::Tenant.switch!` toward
the block form `switch(tenant) { … }`. Neither is a deprecation or an API change —
the goal is to make the anti-patterns visible (and, for direct writes, blocking) at
lint time. Apartment's own suite exempts `lib/apartment/` (the legitimate writers)
and `spec/`.

## Motivation

The block form `Apartment::Tenant.switch(tenant) { … }` is the only context change
with a guaranteed `ensure` restore — every correctness argument in the gem leans on
it. Two ways to subvert it remain reachable:

- **Raw `Apartment::Current.tenant = "x"`** — bypasses the primitive entirely; no
  restore, no guard. There is no legitimate reason for application code to do this.
- **`Apartment::Tenant.switch!("x")`** — sets context with no block and no restore;
  documented as "discouraged" but nothing enforces it.

Linting is the right altitude: a documented "always use the block form" discipline
is exactly the kind of rule a cop encodes, and shipping the cops lets every
consumer opt in rather than re-deriving the rule. This is deliberately *not* a
runtime deprecation of `switch!` (still used by `reset` and in tests) — only a
lint-time nudge, plus a hard stop on raw `Current` writes.

## Design

### Packaging — shipped in the gem

```
lib/rubocop/apartment.rb                               # entry point: requires both cops
lib/rubocop/cop/apartment/no_direct_current_write.rb   # RuboCop::Cop::Apartment::NoDirectCurrentWrite
lib/rubocop/cop/apartment/prefer_block_switch.rb       # RuboCop::Cop::Apartment::PreferBlockSwitch
config/default.yml                                     # cop defaults (Enabled/Severity/Description)
spec/unit/rubocop/cop/apartment/
  no_direct_current_write_spec.rb
  prefer_block_switch_spec.rb
```

- **Ship via gemspec**: `s.files` currently globs `git ls-files -- lib`; `config/`
  is outside `lib/`, so add `config/default.yml` (and `config/**/*.yml`) to
  `s.files`. The `lib/rubocop/**` files ship automatically.
- **Zeitwerk ignore**: `lib/apartment.rb` builds the loader with
  `Zeitwerk::Loader.for_gem`, rooted at `lib/`. Add
  `loader.ignore("#{__dir__}/rubocop")` so Zeitwerk does not try to autoload the
  cops as `Rubocop::…` (wrong casing vs `RuboCop`). Same rationale and pattern as
  the existing `cli.rb` / `cli` ignores. The cops load only via RuboCop's
  `require:`, never through Apartment's autoloader.

### The two cops

Both match the **qualified** receiver only (`Apartment::Current`,
`Apartment::Tenant`, with or without leading `::`). Downstream app code always
qualifies; matching the qualified form avoids false positives on unrelated
`Current` / `Tenant` constants. Apartment's own bare `Current.tenant =` / `switch!`
live in `lib/apartment/`, which is exempted by config (below).

#### `Apartment/NoDirectCurrentWrite` (error, no autocorrect)

Flags assignment to `Apartment::Current.tenant=` and
`Apartment::Current.previous_tenant=`.

```ruby
# bad — flagged
Apartment::Current.tenant = "acme"
Apartment::Current.previous_tenant = nil

# good
Apartment::Tenant.switch("acme") { … }   # routed work
Apartment::Tenant.with_default_tenant { … }   # pinned/global work
```

Message: `"Don't assign Apartment::Current.%<attr>s directly; change tenant
context with the block form Apartment::Tenant.switch(tenant) { … } (or
with_default_tenant for global work)."`

No autocorrect: the fix wraps surrounding code in a block, which a cop cannot
synthesize safely.

#### `Apartment/PreferBlockSwitch` (warning, no autocorrect)

Flags `Apartment::Tenant.switch!(…)`. Does **not** flag `reset` (the sanctioned
unguarded path) or the block-form `switch`.

```ruby
# warned
Apartment::Tenant.switch!("acme")

# good
Apartment::Tenant.switch("acme") { … }
```

Message: `"Prefer the block form Apartment::Tenant.switch(tenant) { … }; switch!
sets context with no guaranteed restore."`

Warning severity: visible in editors and review, does not fail CI. The intended
"soft but effective" nudge, not a gate.

### Config & enforcement boundaries

`config/default.yml` ships the defaults so a consumer gets turnkey behavior:

```yaml
Apartment/NoDirectCurrentWrite:
  Description: 'Use the block form switch instead of writing Apartment::Current directly.'
  Enabled: true
  Severity: error

Apartment/PreferBlockSwitch:
  Description: 'Prefer the block form Apartment::Tenant.switch over switch!.'
  Enabled: true
  Severity: warning
```

**The shipped cops are generic** — they carry no knowledge of apartment's directory
layout and flag the qualified bad forms wherever they appear. *Both* exemptions are
expressed in **apartment's own `.rubocop.yml`**, not in cop logic: the gem's
legitimate writers live in `lib/apartment/`, and its test scaffolding in `spec/`.

```yaml
require:
  - rubocop/apartment
inherit_from:
  - config/default.yml            # apartment's own relative path to its shipped defaults
Apartment/NoDirectCurrentWrite:
  Exclude:
    - lib/apartment/**/*          # the sanctioned primitives (switch/switch!/with_default_tenant/reset)
    - spec/**/*                   # scaffolding + Current self-tests
Apartment/PreferBlockSwitch:
  Exclude:
    - lib/apartment/**/*          # reset legitimately calls switch!
    - spec/**/*                   # switch! self-tests live here
```

Keeping the `lib/apartment/` exemption in config (not cop logic) means the shipped
cop never false-exempts a downstream app that happens to have a `lib/apartment/`
path of its own.

**Net internal effect today:** ~0 violations (the only `lib` writers are in
`lib/apartment/`, excluded; specs excluded). The value is the shipped tool plus a
preventative guard against future non-core `lib` code.

**Downstream opt-in** (e.g. an application):

```yaml
require: rubocop/apartment
inherit_gem:
  ros-apartment: config/default.yml
```

### Testing

Cop specs use RuboCop's `expect_offense` / `expect_no_offenses` RSpec matchers
(available via the `rubocop` test support, already a dev dependency). Each cop:

- flags the qualified bad form (with the correct highlight range and message);
- ignores the block form and, for `PreferBlockSwitch`, ignores `reset`;
- ignores unrelated `Current` / `Tenant` constants (e.g. a non-Apartment
  `Current.tenant = …`);
- respects `# rubocop:disable Apartment/<Cop>`.

Plus one smoke spec asserting `config/default.yml` loads and registers both cops
under the `Apartment` department with the expected severities.

The cop specs live under `spec/unit/rubocop/` and run in the normal unit suite
(`bundle exec rspec spec/unit/`); they require no database.

### Docs

A short **"RuboCop cops"** section in `README.md`: the downstream `require` +
`inherit_gem` recipe, a one-line statement of what each cop enforces and why, and a
pointer to this design doc. No design-grade prose in the README — just the opt-in
recipe.

## Alternatives considered

- **Internal-only cop (outside `lib/`).** Simpler — no Zeitwerk ignore, no gemspec
  change, no downstream docs — but the cop couldn't be reused by consumers, who
  would re-implement it. Rejected: the primary value is downstream enforcement.
- **Ship only the write ban; defer `PreferBlockSwitch`.** Considered, since the
  `switch!` nudge is softer and was less settled. Folded in because it shares all
  the cop infrastructure and is the "soft but effective" mechanism the maintainer
  wanted; warning severity keeps it from gating CI.
- **Police `spec/` too.** Would force ~60 `Current.tenant =` setups to block-form
  and flag ~70 `switch!` calls; some specs irreducibly test `Current`/`switch!`
  directly and would need inline disables. Rejected as scope creep (a large
  mechanical refactor unrelated to the cop), and consistent with the repo already
  excluding `spec/` from Metrics cops. A future PR may convert non-`Current` specs.
- **Hand-configured downstream (no shipped `config/default.yml`).** Avoids the
  gemspec change but makes consumers write `Enabled`/`Severity` by hand. Rejected:
  shipping the config is the conventional rubocop-extension experience for one
  gemspec line.
- **Runtime deprecation of `switch!`.** Explicitly out of scope — `switch!` is
  still used by `reset` and is not being removed. The cop is lint-time only.

## Scope guardrails

Branch off `main`. No spec refactor. No `switch!` deprecation or API change. No
autocorrect on either cop.
