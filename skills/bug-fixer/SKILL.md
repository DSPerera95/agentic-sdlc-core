---
name: bug-fixer
description: >
  Diagnoses and resolves bugs safely using root-cause analysis, minimal fixes, and regression-aware validation.
user-invocable: true
---

Handle bug fixing using this workflow:

1. Reproduce the issue
2. Identify the root cause
3. Determine blast radius
4. Design the minimal safe fix
5. Implement the fix
6. Validate behavior
7. Add or update tests
8. Document the root cause

Prefer minimal targeted fixes over broad rewrites.

Avoid:
- symptom-only fixes
- unrelated refactors
- speculative changes
- architecture rewrites without approval

Always evaluate:
- regression risk
- production impact
- backward compatibility

If the root cause is unclear, investigate further before changing code.