# Architecture Decision Records (`doc/decisions/`)

Concise records of "one-way door" architectural choices, module boundaries, and deliberate tradeoffs in `daat`. Check these before proposing structural refactors, widening trust boundaries, or reintroducing retired patterns.

## Index

- [001 — CGI-per-Request Process Isolation & Connection Lifecycle](001-cgi-per-request-lifecycle.md)
- [002 — Three-Tier Trust Boundary & Config-Selected Provider Facades](002-provider-facade-tier.md)
- [003 — Append-Only Entity Ledger, Projected Relational Storage & Soft-Archive](003-append-only-ledger-and-soft-archive.md)
- [004 — Unified Lua Sandboxing, Content-Keyed Approvals & Split Hook Execution](004-sandboxed-content-and-hash-keyed-approvals.md)
- [005 — Rule-Based Agent Control, Persisted Approval Gates & Detached Execution Queues](005-agent-approval-gate-and-detached-queues.md)
- [006 — Separate Vocabularies for Trusted Pages, Extension Canvas & Document Templates](006-trusted-page-sections-vs-extension-canvas.md)
- [007 — Unified Knowledge Pool, Conserved Heat & Usage-Driven Curation Ladder](007-usage-driven-knowledge-pool-and-curation-ladder.md)

## Authoring Rules

1. Number sequentially (`NNN-short-slug.md`) and index here and in [architecture.md](../architecture.md) using relative Markdown links so `repo_docs_sync.py` rewrites them cleanly into `daat` wikilinks.
2. Check [glossary.md](../glossary.md) before naming domain concepts (*Document*, *Entity* / *Entity type*, *Extension* vs *Hook*, *Knowledge Pool* tiers, *Baseline* / *Setup* / *Admin*).
3. Cite measured numbers, concrete failure modes, **Accepted cost**, **Not in scope**, and an explicit **Revisit trigger** — keeping source code comments strictly to terse current-state contracts ([review-checklist.md](../review-checklist.md)).
