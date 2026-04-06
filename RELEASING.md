# Releasing ros-apartment

This document describes the release process for the `ros-apartment` gem.

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Active development (PRs land here) |
| `4-0-alpha` | v4 pre-releases (alpha, beta, rc) |
| `3-4-stable` | v3 maintenance releases |
| `4-0-stable` | v4 stable releases (created when v4.0.0 GA ships) |

Features go to `main`. When a release is ready, push to the appropriate release branch. `rake release` (via the `gem-publish.yml` workflow) creates the tag and publishes to RubyGems.

## Who Can Release

Only the primary maintainer pushes to release branches. Release branches are listed explicitly in `gem-publish.yml`; branches not in the list cannot trigger publishes. The `production` GitHub environment provides an additional approval gate.

## Overview

Releases are automated via GitHub Actions. Pushing to a release branch triggers `gem-publish.yml`, which runs `rake release` to create a git tag and publish to RubyGems using trusted publishing (no API key required).

## Release Steps

### 1. Prepare the release branch

For a new release track, create the branch from `main`:

```bash
git checkout main
git pull origin main
git checkout -b 4-0-alpha    # or 4-0-stable, etc.
```

For a subsequent release, work on the existing branch:

```bash
git checkout 4-0-alpha
git pull origin 4-0-alpha
git cherry-pick <commit>      # backport fixes from main if needed
```

### 2. Bump the version

Update `lib/apartment/version.rb` on the release branch:

```ruby
module Apartment
  VERSION = 'X.Y.Z'           # or 'X.Y.Z.alpha2', 'X.Y.Z.beta1', etc.
end
```

Follow [Semantic Versioning](https://semver.org/):
- MAJOR (X): Breaking changes
- MINOR (Y): New features, backwards compatible
- PATCH (Z): Bug fixes, backwards compatible

Pre-release suffixes: `.alpha1`, `.beta1`, `.rc1`

### 3. Push to publish

Commit the version bump and push:

```bash
git add lib/apartment/version.rb
git commit -m "Bump version to X.Y.Z"
git push origin 4-0-alpha
```

The push triggers `gem-publish.yml`. `rake release` creates the `vX.Y.Z` tag and publishes the gem. No manual tag creation needed.

### 4. Verify the publish

Monitor the workflow run. Verify at: https://rubygems.org/gems/ros-apartment

### 5. Create GitHub Release

1. Go to https://github.com/rails-on-services/apartment/releases/new
2. Select the `vX.Y.Z` tag (created by `rake release`)
3. Click "Generate release notes" for a starting point
4. Edit the release notes to highlight key changes
5. For pre-releases, check the "Set as a pre-release" checkbox
6. Publish the release

We use GitHub Releases as our changelog (no CHANGELOG.md file).

### 6. Backport the version bump

Cherry-pick the version bump back to `main` so the version file stays current:

```bash
git checkout main
git cherry-pick <version-bump-commit>
git push origin main
```

## v3 Maintenance Releases

Same process on the `3-4-stable` branch:

1. Cherry-pick or apply fixes to `3-4-stable`
2. Bump version (e.g., `3.4.2`)
3. Push to `3-4-stable`; `rake release` tags and publishes
4. Create a GitHub Release noting it as a maintenance release

Do not merge `3-4-stable` into `main`; they contain different major versions.

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

The version in `version.rb` matches a tag that was already pushed. Either bump to a new version or delete the existing tag:

```bash
git push origin --delete vX.Y.Z
git tag -d vX.Y.Z
```

Then push to the release branch again.

### Gem published but GitHub Release missing

The GitHub Release is created manually (step 5). The gem is already available on RubyGems; the release is for documentation.

### RubyGems trusted publishing fails

Verify the GitHub environment `production` is configured correctly in repository settings, and that RubyGems.org has the trusted publisher configured for this repository.

## Branch Migration History

The repository previously used `development` as the primary branch and `main` as the release branch. In Phase 8 (April 2026), the layout was changed to the Rails convention:

1. `main` renamed to `3-4-stable`
2. `development` renamed to `main`
3. `main` set as the default branch
