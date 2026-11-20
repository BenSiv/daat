# Deployment Configuration Reference

Every non-secret operational setting for a `daat` deployment lives in `config.lua` at the deployment root (alongside `theme.lua`, `schemas/`, `dropdowns/`, `extensions/`, `views/`, and `templates/`).

Both `config.lua` and `theme.lua` are optional data-only Lua tables evaluated inside `sandbox.data_env()` (no filesystem, OS, or network access). Omit either file — or any field inside it — to use `daat`'s built-in defaults.

## Inspecting and Validating Configuration

Run these commands from the deployment directory (they work both before and after `daat init`):

```sh
daat config check           # validate syntax, section/field names, types, and feature groups
daat config show            # print every effective setting and whether it came from config.lua or default
daat config show --json     # machine-readable effective config and diagnostics
```

`daat config check` catches:
- Lua syntax errors or non-table return values in `config.lua` and `theme.lua`
- Unknown or typoed section/field names (with closest-match suggestions)
- Flat top-level keys that belong inside a section (e.g. `agent_provider` -> `agent.provider`)
- Type, range, enum, or Lua-pattern errors
- Incomplete feature groups (e.g. `database.backend = "mariadb"` without `user`/`database`, or partial `mail` settings)
- **Accidental secrets** (`*password*`, `*secret*`, `*api_key*`) placed in `config.lua` or `theme.lua`, naming the environment variable to set instead

---

## Environment Variables (Secrets & Runtime Paths)

Secrets never belong in `config.lua` or version control. Pass them as environment variables to the `daat` CGI/CLI process (when running under Apache `mod_cgid`, remember to list each variable in `PassEnv`):

| Variable | Used when | Purpose |
|---|---|---|
| `DOCUMENT_ROOT` | CGI requests | Deployment root directory (CLI commands default to `.`) |
| `DAAT_VENDOR_DIR` | Container/custom installs | Path to `daat`'s `vnd/` frontend assets (defaults to `./vnd`) |
| `DAAT_MARIADB_PASSWORD` | `database.backend = "mariadb"` | MariaDB password for `database.user` |
| `DAAT_SMTP_PASSWORD` | `mail.provider = "smtp"` | SMTP password for `mail.smtp_user` |
| `DAAT_GRAPH_CLIENT_SECRET` | `mail.provider = "graph"` | Microsoft Entra client secret for `mail.graph_client_id` |
| `ANTHROPIC_API_KEY` | `agent.provider = "claude"` | Anthropic API key |
| `OLLAMA_API_KEY` / `OPENAI_API_KEY` | `agent.provider = "ollama"` | Optional bearer token when pointing `agent.ollama_url` at an authenticated OpenAI-compatible `/v1` endpoint |
| `GOOGLE_SEARCH_API_KEY` | `search.provider = "google_cse"` | Google Custom Search JSON API key |
| `GOOGLE_SEARCH_ENGINE_ID` | `search.provider = "google_cse"` | Programmable Search Engine ID (`cx`) |

*(Vertex AI (`agent.provider = "vertex"`) authenticates via Google Cloud Application Default Credentials on the host/VM service account — no key file or env var required.)*

---

## `config.lua` Structure

`config.lua` returns a table with up to seven top-level sections:

```lua
return {
  database = {
    backend = "sqlite",
  },
  agent = {
    provider = "ollama",
    model = "qwen3:8b",
  },
  knowledge = {
    embedding_model = "nomic-embed-text",
  },
  search = {},
  mail = {},
  ui = {},
  extensions = {},
}
```

### 1. `database`

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `backend` | `"sqlite"` \| `"mariadb"` | `"sqlite"` | SQLite stores data in `.store/store.db` |
| `host` | `string` | `"127.0.0.1"` | MariaDB server host |
| `port` | `integer >= 1` | `3306` | MariaDB TCP port |
| `user` | `string` | `nil` | Required when `backend = "mariadb"` (password via `DAAT_MARIADB_PASSWORD`) |
| `database` | `string` | `nil` | Required when `backend = "mariadb"` |

### 2. `agent`

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `provider` | `"vertex"` \| `"claude"` \| `"ollama"` \| `"test"` | `nil` | Unset disables the chat assistant and embeddings |
| `model` | `string` | provider default | Overrides the provider's default chat/generation model |
| `thinking` | `"off"` \| `"summary"` \| `"full"` | `"summary"` | Model reasoning capture level |
| `turn_mode` | `"detached"` \| `"inline"` | `"detached"` | `"detached"` runs turns in a background worker process |
| `retention` | `"full"` \| `"standard"` \| `"lean"` | `"standard"` | Retention policy across `daat store prune` (`doc/agent-data.md`) |
| `retention_override` | `table` | `nil` | Override `knowledge_days`, `tool_trace_days`, `model_input_days`, `metrics_days`, `transcript_documents` |
| `model_input_days` | `number >= 0` \| `"forever"` | from `retention` | Direct override for stored raw prompt retention (`0` omits storing prompts) |
| `transcript_documents` | `"off"` \| `"whole"` | from `retention` | Whether to maintain a full searchable transcript Document per chat |
| `curate_quiet_minutes` | `number >= 0` | `60` | Idle minutes before `daat knowledge curate-pending` curates a chat |
| `chat_attachments_enabled` | `boolean` | `false` | Enables PDF/document uploads in chat (requires `pdftotext`/`pandoc` on `PATH`) |
| `vertex_project` | `string` | `nil` | GCP project ID when `provider = "vertex"` |
| `vertex_region` | `string` | `"global"` | GCP Vertex region when `provider = "vertex"` |
| `ollama_url` | `string` | `"http://127.0.0.1:11434/v1"` | Base `/v1` URL for Ollama or any OpenAI-compatible server |
| `ollama_reasoning_effort` | `boolean` | `false` | Send OpenAI `reasoning_effort` field on `/v1` requests |

**Advanced `agent` loop & context tuning:**
`max_turns` (`20`), `research_max_turns` (`12`), `background_max_turns` (`20`), `background_max_attempts` (`3`), `turn_stale_seconds` (`180`), `auto_continue_max` (`3`), `auto_continue_minutes` (`10`), `search_excerpt_length` (`1200`), `search_excerpt_full_length` (`4000`), `query_row_cap` (`200`), `query_char_cap` (`12000`), `get_field_chars` (`4000`), `tool_result_cap` (`24000`), `knowledge_list_page` (`50`), `compaction_threshold` (`48000`), `context_fixed_tokens` (`3900`), `chars_per_token` (`2.8`), `compaction_mid_turn` (`true`), `pin_schema` (`true`), `pinned_schema_chars` (`6000`), `dedupe_repeat_calls` (`true`), `masking` (`{chat=false, research=true, background=true}`), `masking_keep_last` (`5`), `masking_min_chars` (`300`), `masking_batch_tokens` (`4000`), `carry_user_requests` (`false`), `carry_user_requests_limit` (`5`).

### 3. `knowledge`

| Key | Type / Values | Default | Post-change action / Notes |
|---|---|---|---|
| `embedding_model` | `string` | provider default | Run `daat repair embeddings` (then `daat repair tags`) after changing |
| `embedding_quiet_minutes` | `number >= 0` | `5` | Quiet window before `daat document embed-pending` embeds an edited Document (`0` embeds on save) |
| `embedding_skip` | `string[]` (Lua patterns) | `nil` | Lines matching any pattern are stripped from embedded text; run `daat repair embeddings` after changing |
| `search_review_mode` | `"deferred"` \| `"inline"` | `"deferred"` | `"deferred"` offloads retrieval heat/link reviews to `daat knowledge review-pending` |
| `search_passages` | `boolean` | `true` | Score and show the best-matching passages inside shortlisted Documents |
| `build_aspects` | `boolean` | `false` | Build multi-aspect vectors for long Documents; backfill existing ones with `daat repair aspects` |
| `search_aspects` | `boolean` | `false` | Match multi-aspect vectors during semantic search |
| `curate_aspects` | `boolean` | `true` | Curate repeatedly retrieved aspects of long Documents into standalone notes |
| `tag_restructure` | `boolean` | `false` | Allow agent-judged tag splits/merges/relabels after `embed-pending` |
| `reference_aliases` | `{{pattern, replacement}, ...}` | `nil` | Normalize entity mentions (e.g. `{{"experiment%s*(%d)", "exp%1"}}`); run `daat repair references` after changing |
| `duplicate_external_prefixes` | `string[]` | `nil` | External-ID prefixes eligible for `daat repair duplicates` |

**Advanced `knowledge` tuning:**
`passage_max_chars` (`1500`), `passage_min_chars` (`200`), `passages_per_document` (`2`), `passage_lexical_weight` (`0.2`), `passage_max_embeds_per_search` (`60`), `passage_cache_days` (`30`), `aspect_min_chars` (`7000`), `aspect_max` (`4`), `aspect_dims` (`0`), `aspect_vector` (`"centroid"` \| `"medoid"`), `link_passage_gate` (`0.72`), `link_gate_passages_per_document` (`40`), `link_gate_max_embeds` (`80`), `tag_dims` (`256`), `tag_second_within` (`0.02` or `false`), `tag_min_text` (`200`), `tag_split_min` (`40`), `tag_build_max` (`60`), `tag_build_coarseness` (`0`).

### 4. `search`

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `provider` | `"google_cse"` \| `"test"` | `nil` | Enables the agent's `internet_search.search` tool (`GOOGLE_SEARCH_API_KEY` + `GOOGLE_SEARCH_ENGINE_ID`) |

### 5. `mail`

All three of `provider`, `from`, and `public_url` must be set to enable `/forgot-password`:

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `provider` | `"smtp"` \| `"graph"` \| `"test"` | `nil` | Outbound email backend |
| `from` | `string` | `nil` | Sender email address |
| `public_url` | `string` | `nil` | Canonical external URL used to construct password-reset links |
| `smtp_url` | `string` | `nil` | Required for `"smtp"` (e.g. `"smtp://smtp.office365.com:587"`) |
| `smtp_user` | `string` | `nil` | Optional SMTP auth username (password via `DAAT_SMTP_PASSWORD`) |
| `graph_tenant_id` | `string` | `nil` | Microsoft Entra tenant ID for `"graph"` |
| `graph_client_id` | `string` | `nil` | Microsoft Entra client ID for `"graph"` (secret via `DAAT_GRAPH_CLIENT_SECRET`) |

### 6. `ui`

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `nav_order` | `string[]` | `nil` | Reorders sidebar items (`"home"`, `"documents"`, `"data"`, `"tasks"`, `"system"`, `"ext:<name>"`) |
| `nav_hidden` | `string[]` | `nil` | Hides listed sidebar items (never grants items hidden by permissions) |
| `adhoc_row_cap` | `integer >= 1` | `1000` | Default row cap added to `/sql` queries without an explicit `LIMIT` |

### 7. `extensions`

| Key | Type / Values | Default | Notes |
|---|---|---|---|
| `max_job_attempts` | `integer >= 1` | `5` | Max retries for queued `after_*` extension jobs |

---

## Branding & Theme (`theme.lua` and `theme-assets/`)

`theme.lua` can be edited through **System -> Settings** (`/settings`) or committed as code:

```lua
return {
  site_name = "Daat",
  has_logo = false,
  hide_home_heading = false,
  system_prompt_extra = "",
  colors = {
    accent = "#4f46e5",
    accent_2 = "#6366f1",
    bg = "#f8fafc",
    bg_2 = "#f1f5f9",
    border = "#e2e8f0",
    border_2 = "#cbd5e1",
    heading = "#0f172a",
    input_text = "#0f172a",
    muted = "#64748b",
    muted_2 = "#94a3b8",
    text = "#334155",
    th_text = "#475569",
    -- Optional Knowledge Pool ordinal tier ramp (Raw Intake -> Atomic Record):
    -- tier_0, tier_1, tier_2, tier_3
  },
}
```

Optional PNG brand assets live in `theme-assets/`:
- `theme-assets/logo.png` — square sidebar mark (enabled when `has_logo = true`)
- `theme-assets/logo-full.png` — full wordmark displayed on Home
- `theme-assets/favicon.png` — browser tab icon
