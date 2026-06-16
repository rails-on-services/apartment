# Releasing ros-apartment

This document describes the release process for the `ros-apartment` gem.

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Active development (PRs land here) |
| `4-0-alpha` | v4 pre-releases (alpha, beta, rc) |
| `3-4-stable` | v3 maintenance releases |
| `4-0-stable` | v4 stable releases (created when v4.0.0 GA ships) |

Features go to `main`. To publish, the release content has to land on a release branch — for the v4 line, by **merging `main` into `4-0-alpha`** (see Release Steps); for a maintenance branch on a different major version, by cherry-picking (see v3 Maintenance). The resulting push triggers `gem-publish.yml`, whose `rake release` step creates the tag and publishes to RubyGems.

## Who Can Release

Only the primary maintainer pushes to release branches. Release branches are listed explicitly in `gem-publish.yml`; branches not in the list cannot trigger publishes. The `production` GitHub environment provides an additional approval gate.

## Overview

Releases are automated via GitHub Actions. While `main` is the v4 development line, `4-0-alpha` is a **publish gate that tracks `main`**: merging `main` into it triggers `gem-publish.yml`, which runs `rake release` to create a git tag and publish to RubyGems using trusted publishing (no API key required). Maintenance branches on a different major version (`3-4-stable`) are curated with cherry-picks instead, because they cannot track `main`.

## Release Steps (v4 pre-releases — `4-0-alpha`)

While `main` is the v4 development line, `4-0-alpha` simply tracks it: an alpha/beta/rc is "current `main`, published." You release by bumping the version on `main`, then merging `main` into `4-0-alpha`. No cherry-picking, no backport.

### 1. Bump the version on `main`

Update `lib/apartment/version.rb` on `main` — either in the feature PR that completes the release, or a standalone bump PR — and merge it:

```ruby
module Apartment
  VERSION = '4.0.0.alpha4'    # SemVer + optional pre-release suffix
end
```

Follow [Semantic Versioning](https://semver.org/): MAJOR = breaking, MINOR = new features (compatible), PATCH = fixes (compatible). Pre-release suffixes: `.alpha1`, `.beta1`, `.rc1`.

### 2. Open the release PR: `main` → `4-0-alpha`

```bash
gh pr create --base 4-0-alpha --head main --title "Release v4.0.0.alpha4"
```

**Merging this PR is the publish.** The merge pushes `main`'s commits onto `4-0-alpha`, which triggers `gem-publish.yml`; `rake release` creates the `v4.0.0.alpha4` tag and pushes the gem to RubyGems. Don't merge until you mean to ship — a published version number can be yanked but not reused.

> **⚠️ Always pick "Create a merge commit" — never squash or rebase this PR.** `4-0-alpha` is a publish gate that *tracks* `main`; a squash collapses `main`'s commits into one new parallel commit on `4-0-alpha`, so the branches diverge in history even though their content matches. That (a) breaks GitHub's release-notes generator, which walks per-commit/per-PR, and (b) leaves the next release's `main` → `4-0-alpha` diff re-listing everything already shipped. GitHub offers all three merge methods on this PR (the squash-only ruleset is scoped to `main`, not the release branches), so the choice is manual discipline. If a release PR is squashed by mistake, realign with `git push origin origin/main:refs/heads/4-0-alpha --force-with-lease` once the content is identical (this re-triggers `gem-publish.yml`, which no-op-fails on the already-published tag).

### 3. Verify the publish

Watch the workflow run (Actions → "Publish to RubyGems"), then confirm the version is live:

```bash
gem list -r --prerelease ros-apartment    # prereleases are hidden without --prerelease
```

or the versions page: https://rubygems.org/gems/ros-apartment/versions

### 4. Create the GitHub Release

1. https://github.com/rails-on-services/apartment/releases/new
2. Select the `v4.0.0.alpha4` tag (created by `rake release`)
3. "Generate release notes", then edit to highlight key changes
4. For pre-releases, check "Set as a pre-release"
5. Publish

GitHub Releases are our changelog (no `CHANGELOG.md` file).

**No backport step** — the version bump originated on `main`, so `main` already carries it and `4-0-alpha` received it through the merge. The two branches agree by construction.

### Why merge `main` instead of cherry-picking?

While `main` *is* the v4 line, an alpha should be exactly "what's on `main`", so merging keeps them in lock-step with zero per-release curation. The trade-off: an alpha ships everything on `main` — keep not-yet-releasable work behind a flag or unmerged until it's ready. (A maintenance branch on a different major version can't merge `main` and uses cherry-pick instead — see v3 Maintenance. A future `4-0-stable` GA branch will likely also curate rather than track `main` wholesale.)

### Why a branch and not a tag?

`gem-publish.yml` triggers on a push to a release branch, never on `main` or on a tag. That's deliberate: `rake release` creates the version tag *itself*, so triggering on tag pushes would make the workflow re-trigger on its own tag. The release branch is the publish gate.

## v3 Maintenance Releases (`3-4-stable`)

`3-4-stable` carries a different major version than `main`, so it **cannot** track `main` by merge — you curate it with cherry-picks:

1. Cherry-pick (or apply) the fixes onto `3-4-stable`
2. Bump the version on `3-4-stable` (e.g., `3.4.5`)
3. Push `3-4-stable`; `rake release` tags and publishes
4. Create a GitHub Release noting it as a maintenance release

Do not merge `3-4-stable` into `main` (or `main` into it); they contain different major versions.

### Version coordination

- v4 uses `4.x.y` version numbers (with optional pre-release suffixes)
- v3 maintenance uses `3.4.x` version numbers
- Both publish to the same `ros-apartment` gem on RubyGems
- RubyGems resolves via version constraints in user Gemfiles

### End of v3 support

When v3 maintenance ends, delete the `3-4-stable` branch, remove it from `gem-publish.yml`, and remove this section.

## Adding a New Release Branch

To enable publishing from a new branch (e.g., `4-0-stable` for GA releases):

1. Add the branch name to `gem-publish.yml`'s `on.push.branches` list
2. Commit and push the workflow change to `main`
3. Cherry-pick the workflow change to all active release branches

## Workflow Details

The `gem-publish.yml` workflow uses:
- Trusted publishing: Configured via RubyGems.org OIDC, no API key needed
- `rubygems/release-gem@v1`: Official RubyGems action
- `rake release`: Creates the git tag, builds the gem, publishes to RubyGems
- Triggers only on explicit release branches (not tags, not `main`)

## Troubleshooting

### Workflow fails with "tag already exists"

The version in `version.rb` matches a tag that was already pushed. Either bump to a new version on `main` or delete the existing tag:

```bash
git push origin --delete vX.Y.Z
git tag -d vX.Y.Z
```

Then re-run the publish (re-merge the release PR, or push the release branch again).

### Gem published but GitHub Release missing

The GitHub Release is created manually (Release Steps, step 4). The gem is already available on RubyGems; the release is for documentation.

### RubyGems trusted publishing fails

Verify the GitHub environment `production` is configured correctly in repository settings, and that RubyGems.org has the trusted publisher configured for this repository.

## Branch Migration History

The repository previously used `development` as the primary branch and `main` as the release branch. In Phase 8 (April 2026), the layout was changed to the Rails convention:

1. `main` renamed to `3-4-stable`
2. `development` renamed to `main`
3. `main` set as the default branch
