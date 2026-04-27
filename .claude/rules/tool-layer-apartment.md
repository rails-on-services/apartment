# Tool Layer Selection (apartment)

When working in this codebase, the three tools below sit at different layers of the same code question; they don't compete.

## Layer table

| Tool | Role | Optimizes | Failure it fixes |
|---|---|---|---|
| **Serena** | Scalpel: symbol resolution (LSP) | Token-cheap, surgical lookups and edits | Wrong rename, missed references |
| **code-graph-mcp** | Map: structural relationships (call/dep graph) | Token-cheap, returns graph nodes | Unknown blast radius |
| **Repomix** | Print job: bulk packaging | Loads code so the model reads end-to-end | Token thrash, fragmented reasoning |

Serena and code-graph are *retrieval* (specific questions, precise answers). Repomix is *packaging* (code loaded so the model reads rather than queries). Repomix doesn't replace the others; it feeds them.

## Apartment-specific triggers

- "What calls `Apartment::Tenant.switch!`?" → Serena `find_referencing_symbols`
- "If I rename `Apartment::Adapters::AbstractAdapter#switch`, what breaks downstream?" → code-graph `impact_analysis`
- "Pack `lib/apartment/adapters/` and tell me where the abstraction leaks PostgreSQL specifics" → Repomix
- "What's the call chain from `Apartment::Tenant.create` to the DB schema creation?" → code-graph `get_call_graph`
- "Find dead methods in the elevators namespace" → code-graph `find_dead_code`
- "What's the body of `Apartment::Reloader#call`?" → Serena `find_symbol` with `include_body=true`
- "Review `lib/apartment/active_record/` for invariants we depend on" → Repomix
- "Find similar implementations of `connection_switch!`" → code-graph `find_similar_code`

## When NOT to use Repomix

- Single-symbol questions (Serena beats a directory dump in one call)
- Impact analysis (code-graph shows dependency structure; Repomix shows source)
- Iterative refactor with edits between queries (Serena and code-graph stay fresh; Repomix needs a repack)
- Scope larger than the context budget (the full gem at once is fine; a downstream Rails app's view of apartment usage is not)

## Typical week allocation (rough)

For a gem-development week:

- **~50% Serena** — most questions are symbol-level (the gem is small)
- **~25% code-graph-mcp** — impact analysis when changing public APIs
- **~15% Repomix** — invariants review, doc generation, upstream-PR-prep packaging
- **~5% rspec / minitest output** — iterative test-driven changes (not an MCP tool, but it dominates the loop)
- **~5% GitHub MCP plugin** — upstream PR archaeology, fork-vs-upstream diff investigations

This is a fork of `rails-on-services/apartment`; when investigating "why did we diverge from upstream here?", reach for the GitHub MCP plugin to inspect upstream PRs and our fork's history side by side.
