# AI Tools Setup Guide

Plugins, skills, and MCP servers for AI-assisted development with the Apartment Ruby gem.

## Plugin > Skill > MCP

When a capability is available through multiple mechanisms, prefer: **Plugin** (auto-updating) > **Skill** (`.claude/skills/`) > **MCP server** (`.mcp.json`).

### Capabilities Covered by Plugins

These have official plugins; do not add MCP servers for them:

| Capability | Claude Code Plugin | Cursor Plugin |
|---|---|---|
| Library docs | `context7@claude-plugins-official` | [upstash](https://cursor.com/marketplace/upstash) |
| Web scraping/search | `firecrawl@claude-plugins-official` | [firecrawl](https://cursor.com/marketplace/firecrawl) |
| Error tracking | `sentry@claude-plugins-official` | [sentry](https://cursor.com/marketplace/sentry) |
| Code review | `code-review@claude-plugins-official` | — |
| Git commits | `commit-commands@claude-plugins-official` | — |
| PR review | `pr-review-toolkit@claude-plugins-official` | — |
| GitHub | `github@claude-plugins-official` | — |
| Workflows | `superpowers@claude-plugins-official` | — |
| Ruby LSP | `ruby-lsp@claude-plugins-official` | — |
| Repomix (codebase pack/MCP) | `repomix-mcp@repomix` + `repomix-commands@repomix` + `repomix-explorer@repomix` (user scope) | — (use MCP server) |
| code-graph (call/dep graph) | `code-graph-mcp@code-graph-mcp` (user scope) | — (use MCP server) |

## Project MCP Servers

This repo's `.mcp.json` carries team-shared MCP servers (currently `rails-mcp-server` if present). Per-developer opt-in via `.claude/settings.local.json` `enabledMcpjsonServers`.

For Cursor: `.cursor/mcp.json` mirrors `.mcp.json` for team-shared servers.

## Code Intelligence (Cross-Project)

Three personal dev tools that work across multiple projects. Configure at user scope (Claude Code plugins, global `~/.cursor/mcp.json`) — not in this project's MCP configs.

### Serena (semantic code search & symbolic edits)

LSP-backed symbolic tools for the AI: `find_symbol`, `replace_symbol_body`, `find_referencing_symbols`, `get_symbols_overview`. Prefer over Read/Grep/Edit when working on Ruby code.

**Install:**

```bash
uv tool install -p 3.13 serena-agent@latest --prerelease=allow
serena setup claude-code  # registers Serena as an MCP server with Claude Code
```

**Cursor** (`~/.cursor/mcp.json`):

```json
"serena": {
  "command": "serena",
  "args": ["start-mcp-server", "--context=ide", "--project-from-cwd"]
}
```

`--context=ide` is the right context for Cursor; `--context=claude-code` is for Claude Code.

**Project files (`.serena/`)** — when populated, commit `.serena/.gitignore`, `.serena/project.yml`, and `.serena/memories/` (verify `project.yml` has no absolute paths). Serena's bundled `.serena/.gitignore` keeps `cache/` and `project.local.yml` out of git.

### code-graph-mcp (call graph, impact analysis)

Tracks the codebase as a graph; supports `impact_analysis` before signature changes, `get_call_graph`, `find_dead_code`, `find_similar_code`, `dependency_graph`, `semantic_code_search`.

**Claude Code:**

```
/plugin marketplace add sdsrss/code-graph-mcp
/plugin install code-graph-mcp
/reload-plugins
```

**Cursor** (`~/.cursor/mcp.json`):

```json
"code-graph": {
  "command": "npx",
  "args": ["-y", "@sdsrs/code-graph"]
}
```

The plugin/MCP creates a `.code-graph/` index — gitignored.

### Repomix (bulk codebase packing)

Packs the codebase (or a remote repo) into a single XML/markdown blob.

**Claude Code:**

```
/plugin marketplace add yamadashy/repomix
/plugin install repomix-mcp@repomix
/plugin install repomix-commands@repomix
/plugin install repomix-explorer@repomix
```

**Cursor** (`~/.cursor/mcp.json`):

```json
"repomix": {
  "command": "npx",
  "args": ["-y", "repomix@latest", "--mcp"]
}
```

Output (`repomix-output.*`) is gitignored.

### Choosing between Serena, code-graph-mcp, and Repomix

The decision rule and apartment-specific triggers live in [`.claude/rules/tool-layer-apartment.md`](../.claude/rules/tool-layer-apartment.md), auto-loaded into AI sessions in this repo. Short version: Serena for symbols, code-graph for blast radius, Repomix for bounded holistic reads.

## Cursor Setup

### Plugins (Preferred)

- **[Upstash (Context7)](https://cursor.com/marketplace/upstash)** — Library documentation lookup
- **[Firecrawl](https://cursor.com/marketplace/firecrawl)** — Web scraping and search
- **[Sentry](https://cursor.com/marketplace/sentry)** — Error tracking and debugging

### Project MCP Servers

`.cursor/mcp.json` carries team-shared MCP servers (matches `.mcp.json`).

### Global MCP Servers

Personal dev tools at `~/.cursor/mcp.json`:

- **`serena`** — `serena start-mcp-server --context=ide --project-from-cwd`
- **`repomix`** — `npx -y repomix@latest --mcp`
- **`code-graph`** — `npx -y @sdsrs/code-graph`

## Verification

```bash
claude mcp list           # Claude Code MCP servers
ls .claude/rules/         # auto-loaded rules
```

In Claude Code:
```
> Use serena to find_symbol Apartment::Tenant
> Use code-graph to get_call_graph for Apartment::Adapters::PostgresqlSchemaAdapter
```
