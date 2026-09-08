---
name: repo-discovery
description: >
  Analyze the repository before planning or implementation. Identifies architecture, conventions, boundaries, dependencies, testing patterns, and implementation constraints.
user-invocable: true
---

Analyze the repository before implementation work begins.

Identify:
- architecture style
- folder structure
- framework usage
- naming conventions
- dependency injection patterns
- testing strategy
- API patterns
- database access patterns
- logging conventions
- observability patterns
- feature flag usage
- deployment structure

Prefer existing patterns over introducing new abstractions.

Highlight:
- reusable components
- architectural boundaries
- risky areas
- anti-patterns to avoid
- integration constraints

Output concise implementation-relevant findings only.

Do not:
- modify code
- refactor code
- generate implementation plans
- generate specs