# Database schema revision: proposal

Proposal, 2026-10-23. Goal: a schema that is clean, logical and compact, with nothing piling up unused and nothing readable that shouldn't be. Based on prod (Cloud SQL `platform`, 75 tables) mapped in `~/lims/docs/database-schema.dbml`, and on how each built-in table is read and written in `src/`.

Scope: the **42 built-in tables** daat owns (37 core tables plus 5 entity types daat registers itself). The 32 user-defined tables (from `~/lims/schemas`) and the one extension table (`task`) are the deployment's design; observations on them are at the end.

## Status (2026-10-25)

Built on `feature/schema-revision`, as store migrations 1-6 (`src/store.lua`), with these changes to the plan below:
- **Done:** B (`agent_model_call`), C (`system_state`, without `knowledge_pool_state`), F (`knowledge_retrieval_hit`), G (`system_approval`), I (`entity_dropdown_value`), the domain renames, prompt retention (`prompt_retention_days`, `daat agent prune-prompts`), and K (the deploy pipeline's Step 9b, in `~/software`).
- **Not done, on purpose: D, E and H.** Each would merge tables written by different modules. With one shared row per document or tag, every write becomes a dialect-specific partial upsert, and every delete becomes "null out my columns". That's harder to keep correct than one small table per owner. Instead, `knowledge_tier_review` is renamed to `document_tier_judgment`. `document_embedding`, `document_embedding_due`, `document_link_sync`, `tag_centre`, `tag_upkeep`, `knowledge_link_review` and `tag_judgment` stay as they are.
- **Retrieval-hit retention dropped:** old hits feed the co-retrieval link logic (pairs of documents returned by the same search), so deleting them would change link decisions. With the review folded in they're small.

Result: **42 built-in tables → 36**: `tag_relation` kept, `knowledge_pool_state` kept, D/E/H not merged.



- **Why so many tables look unconnected.** Many links in daat are generic pairs, `(entity_type, entity_id)` or `login` / `session_id` stored as text, which no diagram can draw as a foreign key. `entity_event`, `entity_source`, `document_reference`, `reference_name` and `extension_job` all point at entities this way. So part of the clutter is a drawing limit, not real islands.
- **The real clutter is small tables for one piece of state each:**
  - **Four single-row state tables:** `knowledge_pool_state`, `schema_sync_state`, `tag_evidence_state` and `tag_upkeep_state`, each holding one row.
  - **Six one-to-one side tables,** each keyed by `document_id` or `tag_id` and holding one derived value: `document_embedding`, `document_embedding_due`, `document_link_sync` and `knowledge_tier_review` for documents; `tag_centre` and `tag_upkeep` for tags.
  - **Pairs that record the same thing at the same grain:** `knowledge_context` and `knowledge_chat_eval` (one row per chat reply each), `knowledge_retrieval_document` and `knowledge_review` (one row per retrieved document each), and `extension_approval` and `view_approval` (an admin approving one named thing).
- **One registered but unused table:** `tag_relation`, with 0 rows. It's part of the tag ontology design, but no code reads or writes it yet.
- **Checked, not a problem:** the chat agent's `entity.query` can only read registered entity tables, their multi-value tables, and `entity_source`, `document_link` and `entity_event` (`view.queryable_tables`), which is what any user already sees on detail pages. `knowledge_context`, `knowledge_chat_eval` and `agent_session` are on a separate list of tables whose *columns* the agent may describe for the `/sql` console; `entity.query` refuses them.
- **Data that only grows:** `knowledge_context.prompt` stores the whole history again on every step (about 25 MB after 7 weeks with 6 users, mostly a copy of `agent_message`), and `knowledge_review` adds a row for every document every search returns. Nothing reads either beyond counts.
- **A leftover:** `/data/.store/store.db` on the prod server is a SQLite store from first setup (2026-09-01), never written since. The deployment runs on MySQL only.

## Principles for the target

1. **One table per concept, one place per fact.** Derived state about a document lives in one document side table, not four.
2. **Settings and checkpoints that are a single value** live in one key/value table, not a table each.
3. **Logs either earn their keep or expire.** Every log has a reader and a retention rule.
4. **Nothing the chat agent can query holds another user's content** (true today; keep it that way when tables merge or move).
5. **Names say the domain:** `user` / `api_key` / `password_reset` (accounts), `agent_*` (chat), `entity_*` (registry and ledger), `document_*`, `tag_*`, `knowledge_*` (the pool), `system_*`.

## Proposed changes

Ordered by value and risk. Each is its own migration, so each can ship and be checked separately.

| # | Change | Tables before → after | Risk |
|---|---|---|---|
| B | **`knowledge_context` is the one record per model call:** keep the Phase 0 `step_kind` / `step`; fold `knowledge_chat_eval` into it as columns (`reply_kind`, `quality_status`, `reasoning_status`, `user_feedback`, `feedback_at`); clear `prompt` after the deployment's retention period, keeping the token rows. Chat history itself (`agent_message`, and the transcript documents in the knowledge pool) is not affected and is kept forever | 2 → 1 | Low–medium. The feedback route and evaluation queries move to the merged table |
| C | **`system_state` key/value table** for checkpoint values: schema signature, tag evidence fingerprint, tag upkeep's merge cosine. `knowledge_pool_state` stays its own table: it's the pool's live totals, updated in one atomic statement on the hot path (scale and document count together), which key/value rows can't do as cleanly | 3 → 1 | Low |
| D | **`document_index`:** one row per document for everything derived from its content: embedding (vector, model, text hash, body size), when it's due for embedding, the hash its links were last synced from, its last tier judgment | 4 → 1 | Medium. Embedding search reads the vector here, so test search ranking before and after |
| E | **`tag_index`:** merge `tag_centre` and `tag_upkeep`, both one row per tag of derived state | 2 → 1 | Low |
| F | **`knowledge_retrieval_document` carries its review:** fold `knowledge_review`'s four rule-based statuses into it (same grain), and apply the same retention as other logs | 2 → 1 | Low |
| G | **One `approval` table:** `kind` ('extension' / 'view'), `name`, the approved content (capabilities JSON or exact SQL text), `approved_by`, `approved_at` | 2 → 1 | Low. Approval checks keep comparing exact content |
| H | **One `model_judgment` table** for memoized model verdicts: `knowledge_link_review` (document pairs) and `tag_judgment` (tag pairs and groups), with `kind`, the subjects, an input hash, `verdict`, `reason`, `evaluated_at` | 2 → 1 | Low–medium |
| I | **Dropdowns:** drop `dropdown_list`, which holds only names; `dropdown_value.list_name` is the list | 2 → 1 | Low |
| J | **`tag_relation`:** kept. It is part of the ontology project integration (`doc/tag-ontology.md`); nothing writes it yet | 1 → 1 | — |
| K | **Prod leftover:** remove `/data/.store/store.db`, as a cleanup stage in the deployment pipeline (see below) | — | Low |

**Result:** 42 built-in tables → **31**. The groups become:
- **Accounts:** `user`, `api_key`, `password_reset`
- **Chat:** `agent_session`, `agent_message`, `agent_pending_action`, `agent_background_task`, `knowledge_context`
- **Entities:** `entity_type`, `entity_field`, `entity_event`, `entity_source`, `dropdown_value`
- **Documents:** `document`, `document_index`, `document_link`, `document_reference`, `document_tag`
- **Tags:** `tag`, `tag_index`, `tag_evidence`, `tag_relation`
- **Knowledge pool:** `knowledge_pool_state`, `knowledge_retrieval`, `knowledge_retrieval_document`, `model_judgment`, plus `reference_name` and `reference_prefix`
- **System:** `system_state`, `approval`, `extension_job`

Deliberately **not** merged:
- **`entity_source`, `document_link` and `document_reference`:** all three are edges, but they mean different things (a structured field value; a `[[link]]` with a strength; a name mentioned in text), and each is queried on its own.
- **`agent_pending_action` and `agent_background_task`:** each is a queue with its own life cycle.
- **`entity_event`:** the ledger, append-only by design.

### Target shape of the new and changed tables (DBML)

```dbml
Table knowledge_context {   // one row per model call (B)
  id int [pk]
  session_id varchar(255) [not null]
  message_id int             // the agent_message it produced, if any
  step_kind varchar(32)      // chat, research, background, compaction, wrapup, self_check
  step int
  model_id text
  prompt longtext            // cleared after the retention period
  reasoning_document_id int
  prompt_tokens int
  completion_tokens int
  total_tokens int
  reply_kind varchar(32)     // from knowledge_chat_eval, on reply rows
  quality_status varchar(32)
  reasoning_status varchar(32)
  user_feedback varchar(16)
  feedback_at text
  created_at text
}

Table system_state {        // checkpoint values (C), and the store's schema version
  name varchar(64) [pk]      // e.g. 'schema.sync_signature', 'store.schema_version'
  text_value longtext
  number_value double
  updated_at text
}

Table document_index {      // derived from a document's content (D)
  document_id int [pk]
  embedding_model text
  embedding_packed longblob
  embedded_text_hash varchar(64)
  body_chars int
  embed_due_at text          // set on save, cleared once embedded
  links_synced_hash varchar(64)
  tier_judged_hash varchar(64)
  judged_tier int
  tier_judged_at text
}

Table tag_index {           // derived per tag (E)
  tag_id int [pk]
  members int
  centroid_json longtext
  built_spread double
  fit_members int
  updated_at text
}

Table approval {            // (G)
  kind varchar(16) [pk]      // 'extension' | 'view'
  name varchar(255) [pk]
  approved_content longtext  // capabilities JSON or exact SQL text
  approved_by text
  approved_at text
}

Table model_judgment {      // memoized model verdicts (H)
  id int [pk]
  kind varchar(32)           // 'document_link', 'tag_merge', 'tag_split', 'tag_label', ...
  subject_a int
  subject_b int
  input_hash varchar(64)     // re-judge when the inputs change
  verdict varchar(32)
  reason text
  evaluated_at text
}
```

## How to migrate

- **One migration per change,** in daat's existing style: idempotent, run on every startup, tolerant of the concurrent-first-request race (as `add_column_if_missing` and the `document_link` rebuild already are).
- **Copy, then swap, under MySQL's named lock** (`GET_LOCK`), as the `document_link` layout migration does. Copy into the new table, switch the code to read it, and rename the old table to `*_legacy` for one release before dropping it. Nothing is lost if a step fails.
- **Before and after each change:** run `daat agent context-report` and the agent scorecard, plus that area's bats tests; for D, also a search-ranking comparison.
- **Retention (B and F):** a small `daat repair prune-logs` on the jobs timer. It clears `knowledge_context.prompt` and deletes old retrieval-review detail beyond the retention period, and it never touches token counts, chat history, the ledger or anything a person wrote.
  - The periods are deployment settings in `platform.lua`, not constants in daat: `prompt_retention_days` (default 90) and `retrieval_review_retention_days` (default 90). `nil` means keep forever.
  - The same rule applies to every new threshold this work adds (masking window, caps, excerpt lengths): a `platform.lua` setting with a default, never a hard-coded value.
- **Leftover SQLite store (K):** the prod server's `store.db` predates the switch to MySQL. daat never opens a SQLite file when `db_backend = "mariadb"`. A cleanup stage in the server startup script (`software/infra/gcp/lims/.../startup-platform.sh.tpl`) removes it, and any later stray copy, on every boot when the backend is MySQL. The script's comments that still describe `store.db` as live data get corrected in the same change.

Suggested order: **B** (merged with Phase 0, so `knowledge_context` changes once); then **C, E, G, I** (small, low risk, one branch); then **D** and **F, H** (more code touched); **J** and **K** whenever you decide.

## Decisions for Ben

Decided 2026-10-23:
1. **Retention:** prompt text and retrieval-review detail are operational, so 90 days, as configurable deployment settings. Chat history is kept forever.
2. **`tag_relation`:** kept, for the ontology integration.
3. **Leftover SQLite file:** removed, as a deployment-pipeline cleanup stage.

Open:
4. **Table names:** see the proposal below.

## Naming proposal (for review)

One prefix per domain, so a table's name says what it belongs to. Entity types (`document`, `tag`, `document_tag`, `tag_evidence`, `tag_relation`) keep their names: those are part of the UI, URLs and the agent's vocabulary. The deployment's tables aren't touched.

| Domain | Today | Proposed | Why |
|---|---|---|---|
| Accounts | `user` | `auth_user` | `user` is a reserved word in MySQL (every query has to backtick it), and the prefix groups it with the other account tables |
| | `api_key` | `auth_api_key` | domain prefix |
| | `password_reset` | `auth_email_link` | it holds reset, setup and verify links, not only resets |
| Chat | `agent_session`, `agent_message`, `agent_pending_action`, `agent_background_task` | unchanged | already prefixed |
| | `knowledge_context` (+ `knowledge_chat_eval`) | `agent_model_call` | it records the agent's model calls, not knowledge-pool content |
| Entities | `entity_type`, `entity_field`, `entity_event` | unchanged | already clear |
| | `entity_source` | `entity_ref` | it holds every polymorphic and multi-polymorphic reference value, not only "source" fields |
| | `dropdown_value` | `entity_dropdown_value` | dropdowns are part of the entity schema |
| | `reference_name`, `reference_prefix` | `entity_name_index`, `entity_name_prefix` | they index entity names for recognising them in text; removes the clash with the deployment's `reference` type |
| Documents | `document_index` (new), `document_link` | unchanged | |
| | `document_reference` | `document_mention` | entity names mentioned in a document's text; again avoids "reference" |
| Tags | `tag_index` (new) | unchanged | |
| Knowledge pool | `knowledge_retrieval` | unchanged | |
| | `knowledge_retrieval_document` (+ `knowledge_review`) | `knowledge_retrieval_hit` | one row per document a search returned |
| | `model_judgment` (new) | `knowledge_judgment` | cached model verdicts on documents and tags |
| System | `system_state` (new) | unchanged | |
| | `approval` (new) | `system_approval` | admin approvals of extensions and views |
| | `extension_job` | `system_job` | the job queue that extension hooks run through |

**What a rename costs.** Inside daat, each is a migration (rename under the named lock) plus updating the SQL that names the table. Outside daat, only four scripts in `~/software` query these tables directly:
- `pedia/daat/retier_documents.py` (`knowledge_tier_review`)
- `pedia/daat/convert_co_retrieval_links.py` and `pedia/daat/clean_document_titles.py` (`document_link`)
- `benchling/sync/db_source.py` (`entity_source`)

Admin-approved views and the `/sql` console's saved queries would need the new names too; lims' own views only use entity tables. Renames can ride along with the structural changes above, one table at a time, so nothing is renamed twice.

## The user-defined and extension tables (observations only)

These are the deployment's own design, from `~/lims/schemas` and `extensions/task`:
- **Empty in prod:** `cell_supply_request` (and its `delivered_samples` junction), `free_text_label`, `media_calculator`, `temperature_reading`. `label_template` has 1 row and `task` has 1. Worth asking whether each is still wanted.
- **No reference to or from any other type:** `bioreactor_parameters`, `temperature_reading`, `media_calculator`, `free_text_label`, `label_template`. That's fine for standalone lookups, worth checking for the others.
- **Naming clash:** the deployment's `reference` type (literature) and daat's `reference_name` / `reference_prefix` (recognising entity names in text) are unrelated but read as one feature. Renaming the core pair to `entity_name_index` / `entity_name_prefix` would remove the confusion.
