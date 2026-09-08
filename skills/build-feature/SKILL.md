---
name: build-feature
description: >
  Lightweight, single-pass build workflow for small, low-risk (L1) changes: config tweaks, copy/text changes, isolated one-file fixes. No formal spec or plan file — one scope confirmation, then implement and validate. Invoked automatically by feature-orchestrator when /risk-classifier returns L1. Use directly only when the user explicitly asks for a quick or small change and wants to skip the formal spec/plan process.
user-invocable: true
---

# Fast path for low-risk work

This is the L1 branch of /feature-orchestrator. Do not use this for anything /risk-classifier would tag L2 or L3 — route those through the standard /feature-orchestrator workflow instead.

## Phase 1 — Confirm scope

State in one or two sentences what you understand the change to be and which file(s) it touches.

STOP. Ask: "Confirm this is the full scope? (yes / more context needed)"
Do not proceed until the user confirms.

## Phase 2 — Implement

Invoke /implementer, scoped to the confirmed file(s) only. Follow the project's existing conventions. If the project defines a decision log or change record in its own config (e.g. CLAUDE.md), follow that — this skill does not assume any specific file path or documentation structure.

## Phase 3 — Validate

Invoke /validator.

If issues exist:
- invoke /bug-fixer
- invoke /validator again

## Phase 4 — Summary

Report what changed. No per-step STOP gate here — L1 changes don't require confirmation at every phase, only the scope confirmation in Phase 1.

## Guardrails

- If mid-task the change turns out to touch more files than the confirmed scope, or looks architecturally significant, stop and re-route through /risk-classifier rather than continuing down the fast path on a misclassified change.
- Never skip the Phase 1 scope confirmation.
- Never introduce project-specific file paths or template references into this skill — if a project needs those, they belong in that project's own config, not here.
