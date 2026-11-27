# 002. Three-Tier Trust Boundary & Config-Selected Provider Facades

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

`daat` integrates with external network services for LLM generation/tool-calling/embeddings, web search, and transactional account email, while also supporting deployment-authored Extensions (`extensions/<name>/`). Treating external integrations as hardcoded single-vendor modules (`web_search.lua`'s original Google Custom Search implementation) coupled core callers directly to one vendor's wire dialect and made offline testing impossible without invasive mocks. Meanwhile, live LLM and mail APIs churn continuously (Vertex AI's 2026-10-20 `gemini-2.5-flash` deprecation, Gemini 3's mandatory `thoughtSignature` and forbidden `functionCall.id` on Vertex `generateContent`, Claude/OpenAI tool-name character limits `#21`, and Exchange Online retiring Basic SMTP auth), and `./bld/test.sh` must test the exact compiled production binary with zero live credentials or network access.

## Decision

1. **Three explicit trust tiers ([architecture.md](../architecture.md)):**
   - **Core (`src/*.lua`):** Ships in `bin/daat`, full platform access, not swappable, no runtime approval gate.
   - **Providers (`src/*_provider.lua` + `src/provider/*`):** Ships in `bin/daat`, full platform access, no runtime approval gate, dynamically `require`d by name from `config.lua` (`agent.provider`, `search.provider`, `mail.provider`; unset means the capability is disabled).
   - **Extensions (`extensions/<name>/`):** Deployment-authored, sandboxed (`sandbox.extension_env`), capability-checked (`entity.build_ctx`), and Admin-approval-gated ([004](004-sandboxed-content-and-hash-keyed-approvals.md)).
2. **Provider facade from v1 (`src/agent_provider.lua`, `src/search_provider.lua`, `src/mail_provider.lua`):** Every external integration is introduced behind a top-level `src/<kind>_provider.lua` facade even when only one real backend exists. Core code names no vendor and no model: each facade owns the neutral canonical contract (JSON Schema tool parameters and canonical `{content, stopReason}` blocks in [agent-protocol.md](../agent-protocol.md); `{items = {{title, link, snippet}}}` in `search_provider.lua`; strict bare `addr-spec` validation and CR/LF-stripped RFC 5322 MIME construction in `mail_provider.lua`), while vendor-specific wire translation and `config.setting(...)` keys stay isolated inside `src/provider/<kind>_<name>.lua`.
3. **Bundled deterministic `*_test.lua` stubs (`bld/package.lua`):** `always_include = {"provider"}` compiles `agent_test.lua`, `search_test.lua`, and `mail_test.lua` directly into `bin/daat` alongside `agent_{vertex,claude,ollama}`, `search_google_cse`, and `mail_{smtp,graph}`. Integration and scorecard suites set `provider = "test"` in `config.lua` and script responses via `AGENT_TEST_RESPONSES`, exercising the identical static binary shipped to production.

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Every new external integration carries one thin facade file and a `config.lua` field upfront. Because `*_test.lua` modules are compiled into `bin/daat`, setting `provider = "test"` in a production `config.lua` would serve canned stub responses without crashing (`daat status` / `daat config show` surface active providers). A neutral wire facade isolates vendor churn in one file but does not make untested LLMs zero-friction drop-ins at scale — differences in multi-step tool use and thinking budgets still require live scorecard verification.
- **Not in scope:** Running first-party `src/provider/*` modules inside `sandbox.lua` or `system_approval`; declaring vendor server-executed tools (`web_search`, `code_execution`) that execute upstream of `agent.lua`'s human approval gate; building a separate test-only binary.
- **Revisit trigger:** If external contributors need drop-in custom LLM or mail adapters without recompiling `bin/daat`, or if accidental `provider = "test"` configuration occurs in deployment (warranting a startup refusal when `mail.public_url` is set unless overridden).

## Verification

- `./bld/test.sh` (`tst/unit/agent_{vertex,claude,ollama}.lua`, `tst/integration/*.bats`)
- `./bin/daat config check` & `./bin/daat status`
- Canonical contract & per-vendor wire rules: [agent-protocol.md](../agent-protocol.md)
