---
name: context-compressor
description: >
  Compresses workflow state and implementation context to reduce token usage while preserving critical engineering information.
user-invocable: false
---

Compress context while preserving:
- current workflow phase
- approved decisions
- architecture constraints
- completed work
- remaining work
- blockers
- risks
- unresolved questions

Remove:
- repetition
- conversational filler
- obsolete discussions
- discarded approaches

Prefer:
- bullet summaries
- implementation-focused compression
- deterministic state tracking

Preserve only information required for workflow continuity.