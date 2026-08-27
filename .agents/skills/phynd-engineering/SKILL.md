---
name: phynd-engineering
description: >-
  Phynd implementation and self-review workflow. Load before implementing,
  testing, auditing, or reviewing changes in the Phynd Cloud monorepo.
user-invocable: false
metadata:
  internal: true
---

# Phynd engineering

Load `phynd-governance` first.
Read the Phynd monorepo root `AGENTS.md` and the most specific app guidance before changing code.

Use the owning app's established language and build path.
Keep API routes independently deployable Lambdas with route-specific least-privilege IAM policies.
Use Python for appropriate classical ML, data analysis, offline evaluation, and repository scripts, not as a reason to introduce an LLM.

Run deterministic tests, linters, type checks, builds, static analyzers, and policy checks through their normal commands.
An LLM may draft or improve a checker, but no quality-verification command may call an LLM, need model credentials, or depend on network availability.
Treat an LLM-generated NASA Power of 10 checker or similar analyzer as untrusted code until an engineer reviews it and fixtures demonstrate both violations and compliant cases.

Before completion, self-review the full diff, route and IAM scope, deployment packaging, logs, failure behavior, tests, and validation commands.
Do not report a passing quality result based only on an LLM explanation or code review.
