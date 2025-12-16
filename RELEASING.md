# Releasing ros-apartment

This document describes the release process for the `ros-apartment` gem.

## Overview

Releases are automated via GitHub Actions. Pushing to `main` triggers the `gem-publish.yml` workflow, which publishes to RubyGems using trusted publishing (no API key required).

## Prerequisites

- All changes merged to `development` branch
- CI passing on `development`
- Version number updated in `lib/apartment/version.rb`

## Release Steps

### 1. Bump the version

Update `lib/apartment/version.rb` on the `development` branch:

```ruby
module Apartment
  VERSION = 'X.Y.Z'
end
```

Follow [Semantic Versioning](https://semver.org/):
- **MAJOR** (X): Breaking changes
- **MINOR** (Y): New features, backwards compatible
- **PATCH** (Z): Bug fixes, backwards compatible

### 2. Create release PR

Create a PR from `development` to `main`:

```bash
gh pr create --base main --head development --title "Release vX.Y.Z"
```

Include a summary of changes in the PR description.

### 3. Merge the release PR

Once CI passes and the PR is approved, merge it. This triggers the publish workflow.

**Important**: The workflow creates the git tag automatically. Do not create the tag manually beforehand or the workflow will fail.

### 4. Verify the publish

Monitor the `gem-publish.yml` workflow run. It will:
1. Build the gem
2. Create and push the `vX.Y.Z` tag
3. Publish to RubyGems
4. Wait for RubyGems indexes to update

Verify at: https://rubygems.org/gems/ros-apartment

### 5. Create GitHub Release

After the workflow completes:

1. Go to https://github.com/rails-on-services/apartment/releases/new
2. Select the `vX.Y.Z` tag (created by the workflow)
3. Click "Generate release notes" for a starting point
4. Edit the release notes to highlight key changes
5. Publish the release

We use GitHub Releases as our changelog (no CHANGELOG.md file).

### 6. Sync branches

Merge `main` back into `development` to keep them in sync:

```bash
git checkout development
git pull origin development
git merge origin/main --no-edit
git push
```

## Workflow Details

The `gem-publish.yml` workflow uses:
- **Trusted publishing**: Configured via RubyGems.org OIDC, no API key needed
- **rubygems/release-gem@v1**: Official RubyGems action
- **rake release**: Builds gem, creates tag, pushes to RubyGems

## Troubleshooting

### Workflow fails with "tag already exists"

The tag was created manually before the workflow ran. Delete the tag and re-run:

```bash
git push origin :refs/tags/vX.Y.Z
```

Then re-trigger the workflow by pushing to main again (or re-run from GitHub Actions UI).

### Gem published but GitHub Release missing

The GitHub Release is created manually (step 5). The gem is already available on RubyGems; the release is just for documentation.

### RubyGems trusted publishing fails

Verify the GitHub environment `production` is configured correctly in repository settings, and that RubyGems.org has the trusted publisher configured for this repository.
