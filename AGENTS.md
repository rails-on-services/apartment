# Repository Guidelines for AI Agents

This repo uses `CLAUDE.md` files as authoritative contributor guides for all AI assistants.

## Reading Order

1. **Read `/CLAUDE.md` (root) first** - project-wide architecture, patterns, design decisions
2. **Read directory-specific `CLAUDE.md`** - check the directory you're modifying and its parents
3. **Nested files override root** on conflicts (per AGENTS.md spec)

Nested `CLAUDE.md` files exist in `lib/apartment/`, `lib/apartment/adapters/`, `lib/apartment/elevators/`, `lib/apartment/tasks/`, and `spec/`.

## Key Principle

Check `CLAUDE.md` before copying patterns from existing code - it documents preferred patterns, design rationale, and known pitfalls.

## Author preferences (code style)

Prefer **SOLID** and explicit APIs over **metaprogramming** unless there is a concrete reason to break SOLID. Metaprogramming can be concise but is easy to misuse because it is powerful (e.g. reaching into classes via `instance_variable_*`). When behavior must live on models, prefer a concern or public class methods with clear names, and keep ivar details private to that layer.

## Adding Documentation

Update the appropriate `CLAUDE.md` rather than this file. This file exists only as a pointer.
