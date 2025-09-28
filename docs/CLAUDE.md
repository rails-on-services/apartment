# docs/CLAUDE.md - Apartment Documentation Context

This directory contains documentation for the Apartment gem's refactored architecture.

## Documentation Structure

### Core Documentation

- **`refactor-guide.md`** - Complete architectural overview and design decisions
- **`migration-guide.md`** - Guide for upgrading from legacy Apartment versions
- **`performance-benchmarks.md`** - Performance testing results and scaling guidance

### API Documentation

- **`api-reference.md`** - Complete public API documentation
- **`configuration-guide.md`** - Detailed configuration options and examples
- **`database-strategies.md`** - Multi-database support documentation

### Integration Guides

- **`rails-integration.md`** - Rails-specific setup and patterns
- **`middleware-guide.md`** - Rack/Rails middleware integration
- **`background-jobs.md`** - Sidekiq/ActiveJob tenant switching patterns

## Documentation Standards

### Content Principles

1. **Accuracy First**: All examples must work in current implementation
2. **Production Ready**: Focus on real-world usage patterns
3. **Database Agnostic**: Show examples for PostgreSQL, MySQL, SQLite
4. **Performance Aware**: Include scaling and performance considerations

### Writing Style

- **Clear Examples**: Show both basic and advanced usage
- **Error Scenarios**: Document common mistakes and solutions
- **Performance Notes**: Include memory and speed implications
- **Migration Paths**: Provide upgrade guidance from legacy versions

### Code Examples Format

Always include working, tested examples:

```ruby
# ✅ GOOD - Shows complete working example
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Tenant.active.pluck(:name) }
  config.default_tenant = "public"
end

# Usage
Apartment::Tenant.switch("acme") do
  User.count # Queries acme.users table
end
```

## Key Documentation Topics

### Architecture Documentation

**Connection Pool Design:**
- Immutable tenant-per-connection architecture
- Zero switching overhead benefits
- Thread safety implementation
- Memory efficiency patterns

**Database Strategy Support:**
- PostgreSQL schema isolation (primary)
- MySQL database-per-tenant
- SQLite in-memory testing
- Custom configuration strategies

### Performance Documentation

**Proven Scalability:**
- 50+ concurrent tenants tested
- 100+ rapid switches without memory leaks
- 20+ concurrent threads with perfect isolation
- Sub-millisecond switching for cached pools

**Benchmarking Results:**
- Memory usage patterns
- Connection pool growth behavior
- Thread contention analysis
- Database-specific performance characteristics

### Migration Documentation

**Legacy Apartment Migration:**
- Configuration format changes
- API method updates
- Threading model changes
- Performance improvements

**Database Strategy Migration:**
- Schema-based to database-based
- Single-DB to multi-DB strategies
- Custom configuration setups

## Documentation Maintenance

### Keeping Documentation Current

1. **Code Examples**: Verify all examples work with current implementation
2. **Performance Data**: Update benchmarks when architecture changes
3. **API Changes**: Document any public API modifications
4. **Database Support**: Update when new database strategies are added

### Documentation Testing

Run examples from documentation:

```bash
# Test configuration examples
ruby -e "$(cat docs/examples/basic-config.rb)"

# Test API examples
bundle exec rails runner "$(cat docs/examples/api-usage.rb)"
```

### Version Compatibility

Document which versions support which features:

- **Rails 7.1+**: All features supported
- **Rails 8.0+**: Enhanced performance
- **Ruby 3.2+**: Required minimum version
- **Ruby 3.3+**: Recommended for best performance

## Contributing to Documentation

### Adding New Documentation

1. **Identify Gap**: What's missing or unclear?
2. **Write Examples**: Create working, tested examples
3. **Test Thoroughly**: Verify examples work across databases
4. **Review for Clarity**: Ensure technical accuracy

### Documentation Review Process

1. **Technical Accuracy**: All code examples must work
2. **Completeness**: Cover edge cases and error scenarios
3. **Clarity**: Non-technical stakeholders should understand concepts
4. **Performance**: Include scaling and memory considerations

### Style Guidelines

**Code Blocks:**
- Always include language specification
- Show complete, working examples
- Include expected output when relevant
- Use realistic variable names

**Performance Notes:**
- Include actual benchmark data
- Show scaling implications
- Document memory usage patterns
- Provide optimization guidance

**Error Handling:**
- Show common error scenarios
- Provide troubleshooting steps
- Include debugging techniques
- Document error recovery patterns

## Documentation Tools

### Generating API Documentation

```bash
# Generate YARD documentation
bundle exec yard doc

# Generate markdown API docs
bundle exec yard -f markdown -o docs/api
```

### Testing Documentation Examples

```bash
# Extract and test code examples
bundle exec ruby scripts/test-docs-examples.rb

# Verify documentation links
bundle exec ruby scripts/check-doc-links.rb
```

### Documentation Linting

```bash
# Check markdown formatting
bundle exec markdownlint docs/

# Spell check documentation
bundle exec cspell "docs/**/*.md"
```

## Documentation Roadmap

### Immediate Priorities

1. **API Reference**: Complete public API documentation
2. **Migration Guide**: Detailed upgrade instructions
3. **Performance Guide**: Scaling and optimization best practices

### Future Documentation

1. **Video Tutorials**: Visual guides for complex concepts
2. **Interactive Examples**: Runnable code examples
3. **Case Studies**: Real-world implementation examples
4. **Troubleshooting**: Comprehensive debugging guide

### Integration Documentation

1. **Framework Guides**: Rails, Sinatra, Hanami integration
2. **Background Job Patterns**: Sidekiq, Resque, DelayedJob
3. **Database Guides**: PostgreSQL, MySQL, SQLite optimization
4. **Deployment Guides**: Docker, Kubernetes, cloud platforms

## Performance Documentation Standards

### Benchmark Documentation

Include specific performance data:

```markdown
## Performance Benchmarks (Rails 8.0, Ruby 3.3.6)

### Tenant Switching Performance
- **Cached Pool Access**: < 1ms (99th percentile)
- **New Pool Creation**: < 10ms (95th percentile)
- **100 Rapid Switches**: < 50ms total

### Memory Usage
- **Base Memory**: 50MB (empty Rails app)
- **Per Tenant Pool**: ~2MB additional
- **50 Active Tenants**: ~150MB total
```

### Scaling Guidelines

Provide clear capacity planning:

```markdown
## Recommended Limits

### PostgreSQL Schema Strategy
- **Recommended**: Up to 100 active tenants
- **Maximum Tested**: 200 concurrent tenants
- **Memory per Tenant**: ~2MB

### MySQL Database Strategy
- **Recommended**: Up to 50 active tenants
- **Maximum Tested**: 100 concurrent tenants
- **Memory per Tenant**: ~5MB
```