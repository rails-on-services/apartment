# Repository Guidelines for AI Agents

This repo uses `CLAUDE.md` files as authoritative contributor guides for all AI assistants.

## Reading Order

1. **Read `/CLAUDE.md` (root) first** - project-wide architecture, patterns, design decisions
2. **Read directory-specific `CLAUDE.md`** - check the directory you're modifying and its parents
3. **Nested files override root** on conflicts (per AGENTS.md spec)

Nested `CLAUDE.md` files exist in `lib/apartment/`, `lib/apartment/adapters/`, `lib/apartment/elevators/`, `lib/apartment/tasks/`, and `spec/`.

## Key Principle

Check `CLAUDE.md` before copying patterns from existing code - it documents preferred patterns, design rationale, and known pitfalls.

## Adding Documentation

Update the appropriate `CLAUDE.md` rather than this file. This file exists only as a pointer.
