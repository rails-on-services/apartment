---
name: manage-worktree
description: >
  Create, move, or remove a git worktree.
  Use when the user asks to create a worktree, start a new branch in a worktree,
  move a branch to a worktree, work on something in parallel, remove/delete a worktree,
  or says "/manage-worktree <name>". Handles stashing, branch management, setup, and cleanup.
argument-hint: [branch-name]
allowed-tools: Bash(git worktree *), Bash(bin/dev/setup-worktree *), Bash(bin/dev/remove-worktree *), Bash(git branch *), Bash(git stash *), Bash(git checkout *), Bash(git switch *)
---

# Manage Worktree

## Path Resolution

**Always resolve the worktree base from the main repo** — relative paths like `../apartment-worktrees/`
break when invoked from inside an existing worktree.

```bash
MAIN_REPO=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
WORKTREE_BASE="$(dirname "$MAIN_REPO")/apartment-worktrees"
```

Use `$WORKTREE_BASE/<name>` for all worktree paths in the steps below.

## Conventions

- Path: `$WORKTREE_BASE/<name>` (sibling to main repo)
- Branch: `<dev-prefix>/<name>` (e.g., `man/v4-foundation`, `jb/fix-auth`)
- Base: current branch (confirm if it's a feature branch rather than `development`)
- **Always** run `bin/dev/setup-worktree` after `git worktree add`
- Remove with: `bin/dev/remove-worktree <name> --delete-branch`

## Mode Detection

Determine the mode from the argument and user intent:

1. **Remove mode** — if the user says "remove", "delete", "clean up", or "tear down" a worktree
2. **Move mode** — if `$ARGUMENTS` matches an existing local branch (`git branch --list "$ARGUMENTS"`), or the user says "move this branch to a worktree"
3. **Create mode** — otherwise (new branch + worktree)

## Create Mode (new branch)

1. **Detect developer prefix** from remote branches:
   ```bash
   git branch -r | sed 's|^ *origin/||' | grep -E '^[a-z]{2,4}/' | cut -d/ -f1 | sort | uniq -c | sort -rn
   ```
   Known prefixes: `man`. Exclude automated prefixes (`seer/`, `fix/`, `feat/`, `docs/`). Ask if unclear.

2. **Stash** uncommitted changes (if dirty): `git stash push -u -m "pre-worktree: $ARGUMENTS"`

3. **Get base branch**: `git branch --show-current`

4. **Create worktree**:
   ```bash
   mkdir -p "$WORKTREE_BASE"
   git worktree add "$WORKTREE_BASE/$ARGUMENTS" -b <prefix>/$ARGUMENTS <base-branch>
   ```

5. **Run setup** (copies `.claude`, `.bundle`, `.vscode`, sets Peacock color):
   ```bash
   bin/dev/setup-worktree "$WORKTREE_BASE/$ARGUMENTS"
   ```

6. **Pop stash** in the **original** worktree (not the new one) if stashed in step 2.

7. **Report**: worktree path, branch name, base branch, any issues.

## Move Mode (existing branch → worktree)

Moves the current or specified branch out of the main repo into a dedicated worktree.
The main repo switches back to a base branch (`development` by default).

1. **Identify the branch to move**: `$ARGUMENTS` or `git branch --show-current`

2. **Derive worktree name** from the branch name (strip the dev prefix):
   - `man/v4-foundation` → worktree name: `v4-foundation`
   - Already unprefixed → use as-is

3. **Stash** uncommitted changes (if dirty): `git stash push -u -m "pre-worktree-move: <branch>"`

4. **Determine return branch**: default is `development`.

5. **Switch main repo** to the return branch: `git switch <return-branch>`

6. **Create worktree** with the existing branch (no `-b`):
   ```bash
   mkdir -p "$WORKTREE_BASE"
   git worktree add "$WORKTREE_BASE/<worktree-name>" <branch>
   ```

7. **Run setup**:
   ```bash
   bin/dev/setup-worktree "$WORKTREE_BASE/<worktree-name>"
   ```

8. **Pop stash** in the **new worktree** (that's where the work continues):
   ```bash
   cd "$WORKTREE_BASE/<worktree-name>" && git stash pop
   ```

9. **Report**: worktree path, branch name, return branch in main repo, any issues.

## Remove Mode (delete worktree)

1. **Resolve worktree name** from `$ARGUMENTS`

2. **Verify it exists**:
   ```bash
   ls "$WORKTREE_BASE/<name>" 2>/dev/null
   ```

3. **Run removal**:
   ```bash
   bin/dev/remove-worktree <name> --delete-branch --confirm
   ```
   Omit `--confirm` if the user hasn't explicitly confirmed.

4. **Report**: confirm removal, branch deletion, any issues.
