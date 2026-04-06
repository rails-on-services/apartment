# Phase 8: Documentation & Upgrade Guide — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make v4 shippable by rewriting user-facing docs, providing an upgrade guide for external users, and updating maintainer docs for dual-release support.

**Architecture:** Seven deliverables, all documentation/markdown except one workflow YAML change. No application code changes. Tasks are ordered so later tasks can reference earlier files (e.g., upgrade guide links to README, README links to upgrade guide).

**Tech Stack:** Markdown, Ruby comments (install template), GitHub Actions YAML

**Spec:** `docs/designs/v4-phase8-documentation.md`

**Packaging note:** The gemspec (`ros-apartment.gemspec`) packages `README.md` + `lib/` only. Docs in `docs/` are GitHub-only and don't ship in the gem. The `docs/history/` files are for GitHub readers, not gem consumers.

**Changelog strategy:** v4 uses GitHub Releases as the changelog (no `CHANGELOG.md` at root). The v3 changelog is archived at `docs/history/CHANGELOG-v3.md`.

---

### Task 1: Create Feature Branch

**Files:**
- None (git operation only)

- [ ] **Step 1: Create and checkout feature branch**

```bash
git checkout -b phase-8-documentation development
```

- [ ] **Step 2: Verify clean state**

```bash
git status
```

Expected: `On branch phase-8-documentation`, nothing to commit.

---

### Task 2: Move Legacy Files to `docs/history/`

**Files:**
- Move: `legacy_CHANGELOG.md` → `docs/history/CHANGELOG-v3.md`
- Create: `docs/history/README-v3.md` (copy of current README.md with header)

**Pre-check:** The current README on `development` is still the v3-era doc (references `config.excluded_models`, `config.tenant_names`). If the README has already been partially migrated to v4, snapshot from the last v3 release tag instead: `git show v3.4.1:README.md > docs/history/README-v3.md`.

- [ ] **Step 1: Create `docs/history/` directory**

```bash
mkdir -p docs/history
```

- [ ] **Step 2: Move `legacy_CHANGELOG.md`**

```bash
git mv legacy_CHANGELOG.md docs/history/CHANGELOG-v3.md
```

- [ ] **Step 3: Add header to `docs/history/CHANGELOG-v3.md`**

Prepend to the top of the file (before existing content):

```markdown
> **Note:** This changelog covers Apartment v3.x and earlier. For v4+, see [GitHub Releases](https://github.com/rails-on-services/apartment/releases).

```

- [ ] **Step 4: Copy current README to `docs/history/README-v3.md`**

```bash
cp README.md docs/history/README-v3.md
```

- [ ] **Step 5: Add header to `docs/history/README-v3.md`**

Prepend to the top of the file (before the `# Apartment` heading):

```markdown
> **Note:** This documents Apartment v3.x. For v4, see [README.md](../../README.md).

```

- [ ] **Step 6: Commit**

```bash
git add docs/history/
git commit -m "Move legacy docs to docs/history/

Moves legacy_CHANGELOG.md to docs/history/CHANGELOG-v3.md and snapshots
the current v3 README as docs/history/README-v3.md. Both get headers
pointing readers to the current versions."
```

---

### Task 3: Rewrite `README.md` for v4

**Files:**
- Modify: `README.md` (full rewrite)

**Reference files to read before writing:**
- `lib/apartment/config.rb` — all config options and defaults
- `lib/apartment/tenant.rb` — public API methods
- `lib/apartment/concerns/model.rb` — pin_tenant API
- `lib/apartment/railtie.rb` — elevator auto-insertion
- `lib/apartment/elevators/` — available elevator classes
- `docs/designs/v4-phase8-documentation.md` — spec section 2 for structure

- [ ] **Step 1: Write the new README.md**

Replace the entire contents of `README.md` with the v4 rewrite. The structure must follow the spec (section 2) exactly. Key sections and their content:

**Header + badges**: Keep existing badge URLs. Update one-liner and code example:

```markdown
# Apartment

[![Gem Version](https://badge.fury.io/rb/ros-apartment.svg)](https://badge.fury.io/rb/ros-apartment)
[![CI](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml/badge.svg)](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/rails-on-services/apartment/graph/badge.svg?token=Q4I5QL78SA)](https://codecov.io/gh/rails-on-services/apartment)

*Database-level multitenancy for Rails and ActiveRecord*

Apartment isolates tenant data at the **database level** — using PostgreSQL schemas or separate databases — so that tenant data separation is enforced by the database engine, not application code.

```ruby
Apartment::Tenant.switch('acme') do
  User.all  # only returns users in the 'acme' schema/database
end
```
```

**When to Use Apartment**: Keep the existing comparison table verbatim (it's good).

**About ros-apartment**: Keep existing text, add mention of v4.

**Installation**: Update requirements to Ruby 3.3+, Rails 7.2+, PG 14+/MySQL 8.4+/SQLite3. Keep Gemfile + generator commands.

**Quick Start**: Show the v4 configure block with `tenant_strategy`, `tenants_provider`, `default_tenant`. State the invariant: "Tenant context is block-scoped; prefer `Tenant.switch { ... }` in app code." Show `create`/`switch`/`drop` examples. Show `Apartment::Model` + `pin_tenant` for global models.

```ruby
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Customer.pluck(:subdomain) }
  config.default_tenant = 'public'
end
```

```ruby
# Global models — pinned to the default tenant
class Company < ApplicationRecord
  include Apartment::Model
  pin_tenant
end
```

**Configuration Reference**: Subsections for Required Options, Pool Settings, Elevator, Migrations, RBAC, PostgreSQL, MySQL. Use the config options from `lib/apartment/config.rb`. For PostgreSQL, keep the shared extensions rake example from the current README.

**Elevators**: Keep current elevator list and examples. Note that Railtie auto-inserts middleware — no manual `config.middleware.use` needed. Update elevator configuration to use `config.elevator = :subdomain` style. Keep custom elevator example but update base class if needed.

**Pinned Models (Global Tables)**: New section. Show `include Apartment::Model` + `pin_tenant`. Explain why (declarative, Zeitwerk-safe, composable with `connected_to`). Note `has_many :through` requirement (no HABTM). Note `connected_to(role: :reading)` compatibility. Cross-reference Known Limitations for the `connects_to` separate database edge case.

**Callbacks**: Keep current content (same API).

**Migrations**: Keep content, ensure rake task names are `apartment:create`, `apartment:drop`, `apartment:migrate`, `apartment:seed`, `apartment:rollback`. Keep parallel migrations section.

**Known Limitations**: `connects_to` with separate databases section per spec.

**Background Workers**: Keep content, update examples to block-based `switch`.

**Rails Console**: Keep current content.

**Troubleshooting**: Keep relevant items, remove v3-only items. Keep `APARTMENT_DISABLE_INIT` and `tenant_presence_check` tips.

**Upgrading from v3**: One-paragraph pointer to `docs/upgrading-to-v4.md`.

**Contributing**: Keep, verify test commands match current reality.

**License**: Keep.

Content NOT included (per spec):
- `config.excluded_models` (upgrade guide only)
- `config.tenant_names` (removed)
- `config.use_schemas` / `config.use_sql` (removed)
- `switch!` as recommended pattern (mention exists for console, discourage in app code)
- Multi-server setup (not ported to v4)

- [ ] **Step 2: Review the README for internal consistency**

Read through the written README. Check:
- All config option names match `lib/apartment/config.rb`
- All method names match `lib/apartment/tenant.rb`
- All elevator class names match `lib/apartment/elevators/`
- No v3 API references leaked in
- Cross-references (to upgrade guide, to Known Limitations) are correct

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Rewrite README for v4 API

Restructured around v4 mental model: tenant_strategy, tenants_provider,
Apartment::Model + pin_tenant, pool-per-tenant, Railtie auto-wiring.
Removed v3-only config (excluded_models, tenant_names, use_schemas).
Added Pinned Models and Known Limitations sections. v3 README preserved
in docs/history/README-v3.md."
```

---

### Task 4: Write Upgrade Guide

**Files:**
- Create: `docs/upgrading-to-v4.md`

**Reference files to read before writing:**
- `docs/designs/v4-phase8-documentation.md` — spec section 3 for structure
- PR #327's upgrade doc: `git show pr-327:docs/4.0-Upgrade.md` — port useful content, correct inaccuracies
- `lib/apartment/config.rb` — verify config option names
- `lib/apartment/tenant.rb` — verify API method names

- [ ] **Step 1: Write `docs/upgrading-to-v4.md`**

Follow the spec structure exactly. Full content for each section:

**Requirements**: Ruby 3.3+, Rails 7.2+, PostgreSQL 14+, MySQL 8.4+, SQLite3.

**What Changed and Why**: 3-4 sentences. Pool-per-tenant replaces thread-local switching. Fiber-safe via `CurrentAttributes`. Config is immutable after boot. Declarative model pinning replaces config-list approach.

**Breaking Changes**: Five subsections (Configuration, Tenant API, Models, Middleware, Connection Model) per spec. Use before/after code examples for each change. Key accuracy points:
- `Apartment::Tenant.current` is unchanged (same in v3 and v4) — do NOT list as breaking
- `excluded_models` is deprecated (still works in v4, removed in v5) — not "removed"
- `process_excluded_models` is deprecated — not "removed"

Example before/after for Configuration:

```ruby
# v3
Apartment.configure do |config|
  config.excluded_models = %w[User Company]
  config.tenant_names = -> { Customer.pluck(:subdomain) }
  config.use_schemas = true
end

# v4
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Customer.pluck(:subdomain) }
  config.default_tenant = 'public'
end
# In each global model:
# include Apartment::Model
# pin_tenant
```

**Migration Steps**: Seven steps per spec. Each step has concrete find/replace patterns or before/after code. Step 3 accuracy: `switch!(t) ... ensure reset` → `switch(t) { ... }` and `switch_to(t) ... ensure reset!` → `switch(t) { ... }`. Note that `Apartment::Tenant.current` is unchanged.

**connects_to Compatibility**: Expanded version of README's Known Limitations. Common case works (ApplicationRecord with roles). Edge case: model with `connects_to` to separate database needs `pin_tenant`. `connected_to(role: :reading)` works correctly with pinned models.

**Troubleshooting**: Port from PR #327 with corrections:
- "No connection defined for tenant" → check `tenants_provider` returns valid names
- Connection pool sizing → `tenant_pool_size`, `max_total_connections`
- Thread safety → always use block-scoped `switch`
- Do NOT include: emoji headers, inflated benchmarks, inaccurate API claims from PR #327

- [ ] **Step 2: Cross-check against PR #327 for missed useful content**

```bash
git show pr-327:docs/4.0-Upgrade.md 2>/dev/null || echo "pr-327 branch not available locally"
```

If the branch is not available locally, fetch it or reference the PR on GitHub:
`https://github.com/rails-on-services/apartment/pull/327/files`

Scan for any useful troubleshooting items or migration steps not already covered. Add if relevant.

- [ ] **Step 3: Verify all method and config names against source**

Grep for every config option and method name mentioned in the upgrade guide to confirm they exist in the codebase:

```bash
grep -n 'tenants_provider\|tenant_strategy\|excluded_models\|pin_tenant\|process_pinned_models' lib/apartment/config.rb lib/apartment/tenant.rb lib/apartment/concerns/model.rb
```

- [ ] **Step 4: Commit**

```bash
git add docs/upgrading-to-v4.md
git commit -m "Add v4 upgrade guide for external users

Self-sufficient guide covering breaking changes, step-by-step migration,
connects_to compatibility, and troubleshooting. Ported useful content
from PR #327 with corrected requirements and API references."
```

---

### Task 5: Update Install Template

**Files:**
- Modify: `lib/generators/apartment/install/templates/apartment.rb:19-21`

- [ ] **Step 1: Update the excluded_models comment block**

In `lib/generators/apartment/install/templates/apartment.rb`, replace:

```ruby
  # Models that live in the shared/default schema (not per-tenant).
  # config.excluded_models = %w[Account]
```

With:

```ruby
  # Models that live in the shared/default schema (not per-tenant).
  # The recommended approach is to declare this in the model itself:
  #
  #   class Account < ApplicationRecord
  #     include Apartment::Model
  #     pin_tenant
  #   end
  #
  # Legacy alternative (deprecated in v4, removed in v5):
  # config.excluded_models = %w[Account]
```

- [ ] **Step 2: Verify the template still parses as valid Ruby**

```bash
ruby -c lib/generators/apartment/install/templates/apartment.rb
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/generators/apartment/install/templates/apartment.rb
git commit -m "Update install template to recommend pin_tenant

Adds commented example showing Apartment::Model + pin_tenant as the
recommended v4 approach. Keeps excluded_models as deprecated fallback."
```

---

### Task 6: Update `RELEASING.md` for Dual Release

**Files:**
- Modify: `RELEASING.md`

- [ ] **Step 1: Add dual release section**

After the existing "Troubleshooting" section (end of file, line 107), append:

```markdown

## Dual Release (v4 + v3 maintenance)

While v3 is still supported, maintenance releases (bug fixes, security patches) are cut from the `v3-stable` branch.

### v4 releases

Same as current process: `development` → `main` → publish.

### v3 maintenance releases

The `gem-publish.yml` workflow triggers on push to `main` and on `v3.*` tags (see below). For v3 releases:

1. Create or checkout the `v3-stable` branch (branched from the last v3 release tag)
2. Cherry-pick or apply fixes
3. Bump version in `lib/apartment/version.rb` (e.g., `3.4.2`)
4. Push `v3-stable` to origin
5. Tag and push: `git tag v3.4.2 && git push origin v3.4.2`
   - The tag push triggers `gem-publish.yml`, which checks out the tagged commit
   - Do **not** merge `v3-stable` into `main` — `main` contains v4 code
6. Create a GitHub Release from the `v3.4.2` tag, noting it as a maintenance release

GitHub Actions `*` matches any character sequence including dots, so the `v3.*` pattern matches tags like `v3.4.2`. Only maintainers should push v3 tags; the `production` environment protection on the workflow provides an additional safeguard.

### Version coordination

- v4 uses `4.x.y` version numbers
- v3 maintenance uses `3.4.x` version numbers
- Both publish to the same `ros-apartment` gem on RubyGems
- RubyGems resolves via version constraints in user Gemfiles

### End of v3 support

When v3 maintenance ends, delete the `v3-stable` branch and remove this section.
```

- [ ] **Step 2: Commit**

```bash
git add RELEASING.md
git commit -m "Add dual-release process for v3 maintenance

Documents v3-stable branch workflow: cherry-pick fixes, tag from branch,
publish via tag trigger. v3-stable never merges into main."
```

---

### Task 7: Add Tag Trigger to `gem-publish.yml`

**Files:**
- Modify: `.github/workflows/gem-publish.yml:3-5`

- [ ] **Step 1: Add tags trigger**

In `.github/workflows/gem-publish.yml`, replace:

```yaml
on:
  push:
    branches: [ 'main' ]
```

With:

```yaml
on:
  push:
    branches: [ 'main' ]
    tags: [ 'v3.*' ]
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/gem-publish.yml
git commit -m "Add v3 tag trigger to gem-publish workflow

Allows v3 maintenance releases to be published by pushing a v3.* tag
from the v3-stable branch, without merging into main."
```

---

### Task 8: Update CLAUDE.md Files

**Files:**
- Modify: `CLAUDE.md` (root)
- Modify: `lib/apartment/CLAUDE.md`
- Modify: `spec/CLAUDE.md`

- [ ] **Step 1: Update root `CLAUDE.md` — Core Concepts**

In `CLAUDE.md`, in the "Core Concepts" section (around line 74), replace:

```markdown
- **Excluded models**: Shared tables (User, Company) pinned to default tenant. Use `has_many :through`, not HABTM.
```

With:

```markdown
- **Pinned models**: Global tables declared with `Apartment::Model` + `pin_tenant`. Bypasses tenant routing. Use `has_many :through`, not HABTM. Replaces `excluded_models` (deprecated in v4).
```

- [ ] **Step 2: Update root `CLAUDE.md` — Testing spec count**

First, get the current count:

```bash
bundle exec rspec spec/unit/ --dry-run 2>&1 | grep "examples"
```

In the "Testing" section (around line 89), replace the count in:

```markdown
bundle exec rspec spec/unit/                    # v4 unit tests (231 specs)
```

With the actual count from the dry-run (576 as of this writing, but use the live value).

- [ ] **Step 3: Update root `CLAUDE.md` — Gotchas**

After the last gotcha bullet (the `v4 Railtie` bullet, around line 111), add:

```markdown
- **`connects_to` edge case**: Models (or abstract base classes) that use `connects_to` to point at a separate database need `pin_tenant` to prevent Apartment from creating tenant pools for them. The common pattern of `ApplicationRecord` using `connects_to` with multiple roles (writing/reading) on the same database works correctly without any special handling.
```

- [ ] **Step 4: Update `lib/apartment/CLAUDE.md` — Directory structure**

In `lib/apartment/CLAUDE.md`, in the directory structure tree (after the `configs/` entry, around line 18), add:

```
├── concerns/              # ActiveRecord concerns for tenant-aware models
│   └── model.rb               # Apartment::Model concern: pin_tenant, apartment_pinned?
```

- [ ] **Step 5: Update `lib/apartment/CLAUDE.md` — File description**

After the "### Concrete Adapters (Phase 2.2)" section (around line 71), add a new section:

```markdown
### concerns/model.rb — Model Pinning Concern

`Apartment::Model` provides `pin_tenant` (class method) to declare a model as pinned to the default tenant. Registered models bypass the `ConnectionHandling` patch. Zeitwerk-safe: works whether called before or after `activate!`. `apartment_pinned?` checks the class and its superclass chain.
```

- [ ] **Step 6: Update `spec/CLAUDE.md` — Unit test file listing**

In `spec/CLAUDE.md`, in the "Adapter Tests (spec/unit/)" section's file listing (after the sqlite3 adapter spec entry, around line 40), add:

```markdown
- `concerns/model_spec.rb` - Apartment::Model concern (pin_tenant, apartment_pinned?, inheritance)
- `patches/connection_handling_spec.rb` - ConnectionHandling patch (tenant pool routing, pinned model bypass, role keying)
```

- [ ] **Step 7: Update `spec/CLAUDE.md` — Spec count in header**

In `spec/CLAUDE.md`, in the opening note (line 1), replace `375+` with the live unit spec count from `bundle exec rspec spec/unit/ --dry-run`.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md lib/apartment/CLAUDE.md spec/CLAUDE.md
git commit -m "Update CLAUDE.md files for Phase 7.1 additions

Adds concerns/model.rb docs, updates spec counts (576 unit specs),
replaces excluded_models with pin_tenant in Core Concepts, adds
connects_to gotcha, notes new spec files."
```

---

### Task 9: Run Rubocop and Final Verification

**Files:**
- None (verification only)

- [ ] **Step 1: Run rubocop on changed Ruby files**

```bash
bundle exec rubocop lib/generators/apartment/install/templates/apartment.rb
```

Expected: no offenses. (The YAML workflow change is not linted by RuboCop; rely on CI's workflow validation or `actionlint` if available.)

- [ ] **Step 1a: Run generator specs to confirm template change is compatible**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/generator/ --format progress
```

Expected: all pass. The existing specs check for `tenant_strategy`, `tenants_provider`, and absence of v3 references — our comment-only change should not affect them.

- [ ] **Step 2: Verify all markdown links resolve**

Check that cross-references between docs work:

```bash
# Verify files referenced in README exist
test -f docs/upgrading-to-v4.md && echo "upgrade guide: OK" || echo "MISSING"
test -f docs/history/README-v3.md && echo "legacy readme: OK" || echo "MISSING"
test -f docs/history/CHANGELOG-v3.md && echo "legacy changelog: OK" || echo "MISSING"

# Verify files referenced in CLAUDE.md exist
test -f lib/apartment/concerns/model.rb && echo "model concern: OK" || echo "MISSING"
test -f spec/unit/concerns/model_spec.rb && echo "model spec: OK" || echo "MISSING"
test -f spec/unit/patches/connection_handling_spec.rb && echo "connection handling spec: OK" || echo "MISSING"
```

Expected: all OK.

- [ ] **Step 3: Verify unit tests still pass**

```bash
bundle exec rspec spec/unit/ --format progress
```

Expected: all pass, 0 failures (documentation changes should not affect tests).

---

### Task 10: Push and Create PR

**Files:**
- None (git operations only)

- [ ] **Step 1: Push feature branch**

```bash
git push -u origin phase-8-documentation
```

- [ ] **Step 2: Create pull request**

```bash
gh pr create --base development --title "Phase 8: Documentation & Upgrade Guide" --body "$(cat <<'EOF'
## Summary

- Moves legacy docs to `docs/history/` (README-v3.md, CHANGELOG-v3.md)
- Rewrites README.md for v4 API (tenant_strategy, tenants_provider, pin_tenant, pool-per-tenant)
- Adds `docs/upgrading-to-v4.md` — self-sufficient upgrade guide for external users
- Updates install template to recommend `Apartment::Model` + `pin_tenant`
- Adds dual-release process to RELEASING.md (v4 from main, v3 from tags)
- Adds `v3.*` tag trigger to gem-publish workflow
- Updates all CLAUDE.md files (root, lib/apartment/, spec/)

## Design spec

`docs/designs/v4-phase8-documentation.md`

## Test plan

- [ ] Rubocop passes on changed files
- [ ] All markdown cross-references resolve to existing files
- [ ] Unit tests pass (576 specs, no database required)
- [ ] Install template is valid Ruby (`ruby -c`)
- [ ] Review README Quick Start examples against actual v4 config API
- [ ] Review upgrade guide breaking changes against actual v4 behavior

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Record PR URL**

Note the PR URL for the user.
