---
name: phynd-design
description: >-
  Phynd design and architecture workflow. Load before designing a feature,
  service, Lambda route, data pipeline, or cross-app change.
user-invocable: false
metadata:
  internal: true
---

# Phynd design

Load `phynd-governance` first.
Treat design as an explicit decision about the smallest suitable technology, boundary, and operational contract.

Before proposing an LLM, define the traditional code, SQL, Python, statistics, or conventional ML baseline and explain why it is insufficient.
For structured inputs and numeric or categorical outputs, start with deterministic code or a task-specific statistical or ML design.
For language-centered behavior, define grounding, evaluation, human review, privacy, latency, cost, and fallback requirements.

For every API design, identify the owning route Lambda, its input and output contract, its data stores, and its least-privilege IAM policy.
For every cross-app design, name the boundaries and the reason a shared package or service is necessary.
For any static-analysis proposal, separate LLM-assisted rule synthesis from deterministic checker execution and CI verdicts.

Self-review the design before implementation by checking the baseline comparison, failure modes, rollback path, measurable acceptance criteria, deployment ownership, and security implications.
Record unresolved assumptions as explicit decisions for the captain rather than hiding them behind model confidence.
