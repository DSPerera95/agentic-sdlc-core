---
name: spec-writer
description: >
  Generates a production-quality feature specification document that acts as the implementation contract for the feature.
user-invocable: false
---

Generate a concise but complete feature specification.

The spec must include:
- overview
- functional requirements
- non-functional requirements (if applicable)
- architecture overview
- API changes
- database changes
- validation rules
- edge cases
- error handling
- security considerations
- observability requirements
- acceptance criteria
- out-of-scope items
- decision log

Eliminate ambiguity wherever possible.

Document assumptions clearly.

Prefer implementation-oriented language.

Do not:
- generate code
- skip edge cases
- invent architecture not discussed with the user