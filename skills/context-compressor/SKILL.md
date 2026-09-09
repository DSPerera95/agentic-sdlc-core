---
name: context-compressor
description: >
  Compresses workflow state and implementation context to reduce token usage while preserving critical engineering information.
user-invocable: false
model: claude-haiku-4-5-20251001
---

This is a declared preference, not a guaranteed one: unlike the agents pinned to a model in their own frontmatter, this skill can't run isolated to make that pin reliable. Its entire job is compressing *this session's* actual accumulated context — isolating it would hand it an empty context with nothing to compress, which defeats the point. It runs inline, on whatever model this session is already on — the Haiku frontmatter field above may or may not take effect for that reason.

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