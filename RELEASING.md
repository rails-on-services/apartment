# Releasing ros-apartment

This document describes the release process for the `ros-apartment` gem.

## Branch Strategy

Following the Rails convention:

| Branch | Purpose |
|--------|---------|
| `main` | Active development (PRs land here) |
| `4-0-stable` | v4 release branch (created when v4.0.0 ships) |
| `3-4-stable` | v3 maintenance releases |

Features go to `main`. When a release is ready, a stable branch is created (or updated) from `main`, the version is bumped there, and a tag triggers the publish workflow.

## Overview

Releases are automated via GitHub Actions. Pushing a `v*` tag triggers the `gem-publish.yml` workflow, which publishes to RubyGems using trusted publishing (no API key required).

## Prerequisites

- CI passing on the stable branch
- Version number updated in `lib/apartment/version.rb`

## Release Steps

### 1. Create or update the stable branch

For a new minor/major release, create the stable branch from `main`:

```bash
git checkout main
git pull origin main
git checkout -b 4-0-stable    # or 4-1-stable, etc.
```

For a patch release, work directly on the existing stable branch:

```bash
git checkout 4-0-stable
git pull origin 4-0-stable
git cherry-pick <commit>      # backport fixes from main
```

### 2. Bump the version

Update `lib/apartment/version.rb` on the stable branch:

```ruby
module Apartment
  VERSION = 'X.Y.Z'
end
```

Follow [Semantic Versioning](https://semver.org/):
- MAJOR (X): Breaking changes
- MINOR (Y): New features, backwards compatible
- PATCH (Z): Bug fixes, backwards compatible

Commit the version bump:

```bash
git add lib/apartment/version.rb
git commit -m "Bump version to X.Y.Z"
git push origin 4-0-stable
```

### 3. Tag and publish

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

The tag push triggers `gem-publish.yml`, which builds and publishes the gem. The `production` environment protection provides a safeguard against accidental publishes.

### 4. Verify the publish

Monitor the `gem-publish.yml` workflow run. Verify at: https://rubygems.org/gems/ros-apartment

### 5. Create GitHub Release

1. Go to https://github.com/rails-on-services/apartment/releases/new
2. Select the `vX.Y.Z` tag
3. Click "Generate release notes" for a starting point
4. Edit the release notes to highlight key changes
5. Publish the release

We use GitHub Releases as our changelog (no CHANGELOG.md file).

### 6. Backport the version bump

Cherry-pick the version bump commit back to `main` so the version file stays current:

```bash
git checkout main
git cherry-pick <version-bump-commit>
git push origin main
```

## v3 Maintenance Releases

The `3-4-stable` branch holds v3 maintenance code. The process is the same as above:

1. Cherry-pick or apply fixes to `3-4-stable`
2. Bump version (e.g., `3.4.2`)
3. Tag and push: `git tag v3.4.2 && git push origin v3.4.2`
4. Create a GitHub Release noting it as a maintenance release

Do not merge `3-4-stable` into `main`; they contain different major versions.

### Version coordination

- v4 uses `4.x.y` version numbers
- v3 maintenance uses `3.4.x` version numbers
- Both publish to the same `ros-apartment` gem on RubyGems
- RubyGems resolves via version constraints in user Gemfiles

### End of v3 support

When v3 maintenance ends, delete the `3-4-stable` branch and remove this section.

## Workflow Details

The `gem-publish.yml` workflow uses:
- Trusted publishing: Configured via RubyGems.org OIDC, no API key needed
- `rubygems/release-gem@v1`: Official RubyGems action
- Triggers on any `v*` tag push

## Troubleshooting

### Workflow fails with "tag already exists"

Delete the tag and re-push:

```bash
git push origin --delete vX.Y.Z
git tag -d vX.Y.Z
git tag vX.Y.Z
git push origin vX.Y.Z
```

### Gem published but GitHub Release missing

The GitHub Release is created manually (step 5). The gem is already available on RubyGems; the release is for documentation.

### RubyGems trusted publishing fails

Verify the GitHub environment `production` is configured correctly in repository settings, and that RubyGems.org has the trusted publisher configured for this repository.

## Branch Migration (from pre-v4 layout)

The repository previously used `development` as the primary branch and `main` as the release branch. The migration to the Rails-style layout:

1. Rename `main` → `3-4-stable` on GitHub
2. Rename `development` → `main` on GitHub
3. Set `main` as the default branch
4. Contributors update local clones:

```bash
git fetch --prune
git branch -m development main
git branch -u origin/main
```
