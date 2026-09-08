---
name: risk-classifier
description: >
  Determines implementation risk level and required workflow rigor for a feature, bug fix, migration, or architecture change.
user-invocable: false
---

Classify work into one of the following risk levels:

L1:
- isolated fixes
- text changes
- styling
- config changes

L2:
- standard features
- API additions
- integrations
- normal business logic

L3:
- authentication
- payments
- infrastructure changes
- schema migrations
- distributed systems
- security-sensitive changes

Provide:
- risk level
- reasons
- required safeguards
- required human reviews
- recommended testing strategy

Be conservative when uncertainty exists.