---
name: phynd-governance
description: >-
  Phynd product architecture and technology-selection governance for work in the
  Phynd Cloud monorepo. Load before planning, designing, implementing, or
  reviewing Phynd product changes.
user-invocable: false
metadata:
  internal: true
---

# Phynd governance

Load this skill before any work in the Phynd Cloud monorepo at https://github.com/phynd-games/phynd-cloud.
The monorepo is the canonical place to build and evolve the Phynd product line.
Read its root `AGENTS.md` and the most specific app-level guidance before making a plan or dispatching work.

## Product boundaries

Keep each change inside its owning app or package boundary unless the accepted design requires a cross-cutting change.
Use Rust for Lambda workloads where the owning app specifies Rust.
Treat every API route as an independently deployed Lambda with its own least-privilege AWS IAM policy.
Do not combine routes into a shared Lambda or broaden an IAM policy without explicit architecture approval and a security review.
The Flagship TV application is Solid JavaScript.
The mobile application is Expo with React Native.

## Agent execution

Use Sandcastle from Matt Pocock for isolated agent execution when available.
Use the configured model-and-harness dispatch profiles rather than selecting a tool by habit.
The current Phynd defaults are Pi with Luna xhigh for routine work, Claude Code with Fable high for feature design and architecture, and Sol high or Claude Code with Fable xhigh for ambiguous or high-risk implementation.
Choose a combination that preserves the required local tool access and complies with every applicable provider and service term.
Never work around usage limits, authentication boundaries, sandbox controls, or provider safety restrictions.

## Tool-selection rule

Do not use an LLM where traditional code, a database query, statistics, or conventional machine learning can solve the problem adequately.
Treat an LLM as a language interface or reasoning aid, not as a default replacement for deterministic software or task-specific models.

Use traditional code for deterministic and auditable work such as routing, validation, authorization, parsing, serialization, state transitions, retries, scheduling, cryptography, billing calculations, and data transformation.
Use SQL or a database index for filtering, joining, aggregation, lookup, and pagination over structured data.
Use statistics or conventional machine learning for structured prediction such as forecasting, ranking, recommendation, fraud detection, anomaly detection, churn prediction, regression, and classification.
Use Python and its established scientific ecosystem for classical ML, data analysis, feature engineering, offline evaluation, notebooks, batch jobs, and developer scripts when Python is the most suitable tool.
Prefer a deterministic Python, Rust, or shell script for repeatable repository checks, data transforms, build steps, migrations, and operational automation.
Use a specialized computer-vision, speech, embedding, or ranking model when that model matches the data and output better than a general language model.
Use an LLM when the input or output is genuinely language-centered, such as drafting, summarization, translation, conversational interaction, semantic extraction from unstructured documents, or code assistance.
An LLM may explain, orchestrate, or provide a reviewed first pass around a traditional system, but it must not replace the deterministic or task-specific component without evidence.
Python does not make a workload an LLM workload: a Python script that computes metrics, trains a classifier, runs a simulation, or checks source code remains conventional software and must be evaluated as such.

Before proposing an LLM for a non-language workload, document the simpler baseline, the measurable benefit the LLM is expected to provide, and the tradeoffs in accuracy, latency, cost, interpretability, privacy, and operational reliability.
For high-impact behavior, require an offline evaluation against the traditional baseline, a rollback or fallback path, and human review where the output can affect users, access, money, or safety.
Do not accept an LLM-generated traditional ML design merely because the generated code is plausible; validate the problem formulation, features, labels, metrics, and deployment behavior with domain expertise.

## LLM-assisted static analysis

An LLM may help discover a rule, translate a known policy into a checker, write a first implementation, or repair syntax in a static-analysis script.
The checker that runs in local development or CI must be deterministic, versioned, testable, and runnable without an LLM, network access, or model credentials.
Do not invoke an LLM as part of a quality gate, lint command, security scan, compliance check, release check, or test verdict.
The LLM proposes or generates the checker; conventional execution produces the verdict.

Suitable implementations include CodeQL queries, Semgrep rules, compiler plugins, AST visitors, Python or Rust repository analyzers, dependency-policy scripts, and NASA Power of 10 compliance checks.
For example, an LLM may draft a Python AST checker for NASA Power of 10 violations, but the committed script must be reviewed by an engineer, covered by positive and negative fixtures, and run deterministically in CI without asking an LLM whether a violation exists.
Generated checkers must be validated against known buggy and known compliant examples, with false-positive and false-negative behavior recorded before they become a blocking gate.
Security-sensitive or safety-related checkers require domain review and an explicit escalation path when the checker is uncertain.

## Self-review gate

Before declaring Phynd design or engineering work complete, perform a self-review against the actual diff and run the repository's applicable deterministic checks.
Confirm that the change is in the correct monorepo boundary, uses the owning app's language and runtime, preserves per-route Lambda and IAM isolation, and does not introduce an LLM where code, SQL, Python, statistics, or conventional ML is sufficient.
Confirm that any LLM-assisted checker is committed as ordinary executable tooling with fixtures and that its quality verdict does not call an LLM or require network access.
Confirm that tests cover both expected behavior and relevant failure or safety paths, and record unresolved uncertainty rather than treating a plausible LLM output as evidence.
For design work, self-review the baseline comparison, measurable acceptance criteria, operational rollback, data governance, and cost and latency assumptions before implementation begins.
For implementation work, self-review the changed files, generated artifacts, IAM policy scope, deployment packaging, logs, and the exact commands that produce the validation result.

This separation preserves the scalability benefits of LLM-assisted checker synthesis while keeping quality decisions reproducible, auditable, offline-capable, and independent of model availability.

## Rationale and references

Traditional machine learning is generally better suited to structured labels and numeric predictions because it is cheaper, faster, more interpretable, and easier to evaluate for those tasks.
LLMs are specialized deep-learning systems for language and can produce plausible but incorrect output, so generated facts and numeric claims require validation.
A compound design may combine both, with a task-specific model producing a decision and an LLM explaining or presenting it.

These principles are informed by:

- [Neural Concept: ML vs LLM](https://www.neuralconcept.com/post/ml-vs-llm-key-differences-applications-engineering-impact)
- [Databricks: LLM vs AI](https://www.databricks.com/blog/llm-vs-ai)
- [Concept to Cloud: When not to use LLMs](https://concepttocloud.com/podcast/ai-briefing/when-not-to-use-llms-choosing-the-right-ai-tool-for-your-data-pipeline/)
- [QLPro: LLM-assisted CodeQL vulnerability rule synthesis](https://arxiv.org/html/2506.23644v1)
- [KNighter: LLM-synthesized static checkers](https://arxiv.org/html/2503.09002v3)
