# External & UI REST API (v1)

A unified JSON HTTP API rooted at `/api/v1` providing 100% parity with every operation surfaced in Daat's browser UI. Both external integrations (`X-Api-Key`) and the browser UI (`session` cookie + `X-CSRF-Token`) call the same `/api/v1` endpoints and enforce identical capabilities and validation rules.

## UI/API parity invariant

Every feature or operation surfaced in Daat's browser UI **must** ship with an equivalent JSON endpoint under `/api/v1/*`:

1. **One surface, no browser-only shims.** Browser JavaScript (`src/ui/*.js`) calls `/api/v1/*` directly (`session` cookie + `X-CSRF-Token`). Never introduce unversioned `/api/*` endpoints or HTML form-POST-only mutations without a `/api/v1/*` counterpart (the sole exceptions are browser session bootstrap routes: `/login`, `/logout`, `/forgot-password`, `/reset-password`, and `/verify-email`, plus binary `/attachments/*` uploads/downloads).
2. **Same capabilities, validation, and provenance.** Session callers and `X-Api-Key` callers share the exact same route handler, single-letter capability check (`i`, `s`, `a`), `entity` / hook validation, and ledger recording (`<login>` vs. `api:<label>`).
3. **Definition of done for any new UI feature.** Register the route under `/api/v1/*` (`src/web/api_v1_routes.lua` + domain `src/web/*_routes.lua`), wire the UI to call it, document the endpoint in this file, and add integration tests in `tst/integration/api_v1.bats`.

## Authentication & CSRF

### External callers (`X-Api-Key`)

```
X-Api-Key: <raw key>
```

`Authorization: Bearer <key>` is deliberately not used: Apache's `mod_cgid` does not forward `Authorization` into a CGI script's environment unless `CGIPassAuth On` is configured, whereas custom headers (`X-Api-Key`) always pass through.

- Missing header (and no `session` cookie) redirects to `/login` (`302`), matching browser routes.
- Invalid or archived `X-Api-Key` returns `401` JSON: `{"error": "Invalid API key"}`.
- No CSRF token is required for key-authenticated requests.

### Browser UI callers (`session` + `X-CSRF-Token`)

Browser JavaScript authenticates with the `HttpOnly` `session` cookie and sends `X-CSRF-Token: <csrf cookie>` on all non-`GET`/`HEAD` requests. Missing or mismatched CSRF returns `403` JSON: `{"error": "CSRF check failed"}`.

### Managing keys

Keys are managed by an account or API key with `a` (admin) capability via the web UI (`/admin-api-keys`), the REST API (`/api/v1/admin/api-keys`), or the CLI:

```
daat api-key create <label> [cap]
daat api-key list [--include-archived]
daat api-key capabilities <label> <cap_string>
daat api-key archive <label>
daat api-key unarchive <label>
```

`create` returns the raw key once; only its bcrypt hash is stored.

### Capabilities

Every endpoint enforces the exact same single-letter capabilities (`cap`) for both user sessions and API keys:

| Letter | Grants |
|---|---|
| `i` | Baseline access -- required for every `/api/v1/*` endpoint. |
| `s` | Setup / SQL access -- grants `/api/v1/sql` (read-only ad-hoc `SELECT` queries). |
| `a` | Admin access -- grants writes to `admin_write_only` entity schemas, `/api/v1/sql`, foreign read-only chat inspection, and all `/api/v1/admin/*` endpoints. |

---

## Endpoints

### Account (`/api/v1/account`)

- `GET /api/v1/account` -- inspect caller identity (`{author, capabilities, via_api_key, login, email, email_verified}`).
- `POST /api/v1/account/password` -- change the authenticated session user's password (`{current_password, new_password}`). Re-issues a fresh `session` cookie (`400` if called with `X-Api-Key`).

### Schemas (`/api/v1/schemas`)

- `GET /api/v1/schemas` -- list all registered entity types with active row counts (`schemas`) and foreign-key edges (`relationships`).
- `GET /api/v1/schemas/<type>` -- inspect one type's layout, field definitions, dropdown values, `admin_write_only`, `reason_flags`, and `has_label_template`.

### Entities, Ledger, Related & Labels (`/api/v1/entities`)

- `GET /api/v1/entities?query=<q>` -- cross-type entity search (`[{entity_type, id, label, subtitle}, ...]`).
- `GET /api/v1/entities/<type>` -- paginated row list (`?limit=&offset=&filter_field=&filter_value=&since_event=`) -> `{"rows": [...], "total": 42, "max_event_id": 108}`. Passing `since_event=<n>` returns all rows of `<type>` (including archived rows) with `last_event_id > <n>` ordered by `last_event_id ASC, id ASC` for incremental sync polling.
- `POST /api/v1/entities/<type>` -- create single row (`{...}` -> `{"success": true, "created_id": 6, "issues": []}`) or batch (`[{...}, ...]` -> `{"success": true, "created_ids": [7, 8], "issues": []}`). Optional `?entry=` records notebook provenance.
- `POST /api/v1/entities/<type>/validate` -- dry-run validation on a single object or batch array -> `{"valid": true, "issues": []}`.
- `GET /api/v1/entities/<type>/autocomplete?query=<q>` -- active reference-picker candidates (`[{"id": 1, "name": "..."}, ...]`).
- `GET /api/v1/entities/<type>/<id>` -- fetch single row (active or archived) -> `{"row": {...}}`.
- `PATCH /api/v1/entities/<type>/<id>` -- partial field update (`?reason=&entry=`) -> `{"success": true, "updated_id": 6, "issues": []}`.
- `POST /api/v1/entities/<type>/<id>/archive` -- soft-archive row (`?reason=&entry=`) -> `{"success": true, "archived_id": 6, "issues": []}`.
- `POST /api/v1/entities/<type>/<id>/unarchive` -- restore archived row (`?reason=&entry=`) -> `{"success": true, "unarchived_id": 6, "issues": []}`.
- `GET /api/v1/entities/<type>/<id>/history` -- append-only ledger events for `<id>` -> `{"events": [...]}`.
- `GET /api/v1/entities/<type>/<id>/related` -- incoming reverse-reference groups and preview rows -> `{"related": [...]}`.
- `GET /api/v1/entities/<type>/<id>/preview` -- summary title, top fields, and popover HTML -> `{"title": "...", "fields": [...], "html": "..."}`.
- `GET /api/v1/entities/<type>/<id>/label` -- rendered ZPL barcode label -> `{"zpl": "^XA...^XZ"}`.

### Saved Views & Ad-Hoc SQL (`/api/v1/views`, `/api/v1/sql`)

- `GET /api/v1/views` -- list saved SQL views (`{views: [{name, label, description, param, columns, approved}, ...]}`).
- `GET /api/v1/views/<name>` -- execute an approved view (passing `?<param.name>=<val>` if parameterized) -> `{"view": {...}, "param_value": ..., "rows": [...]}`.
- `GET /api/v1/sql?q=<SELECT...>` or `POST /api/v1/sql` (`{"q": "SELECT ..."}`) -- execute a read-only `SELECT` query (requires `s` or `a` capability) -> `{"sql": "...", "columns": [...], "rows": [...], "ref_columns": {...}, "truncated": false}`.

### Documents, Templates & Knowledge Pool (`/api/v1/documents`, `/api/v1/templates`, `/api/v1/knowledge`)

Raw document and tag table CRUD uses `/api/v1/entities/document` (and `tag`, `document_tag`, `tag_relation`, `tag_evidence`). Higher-level document and pool operations live under:

- `GET /api/v1/documents/tree` -- lightweight active page tree (`id`, `title`, `parent_id`, `created_at`, `external_id`) -> `{"documents": [...]}`.
- `GET /api/v1/documents/search?q=<query>&limit=10` -- hybrid lexical + semantic + heat-reinforced search with snippets and retrieval logging under `author` (`api:<label>` or `<login>`) -> `{"results": [...]}`.
- `GET /api/v1/documents/link-search?query=<q>&exclude_id=<id>` -- canonical `[[title]]` / `[[folder/title]]` link suggestions.
- `POST /api/v1/documents/render` (`{"content": "..."}`) -- render Markdown, `plot` gnuplot fences, `[[links]]`, and inline `{{view:...}}` embeds to HTML -> `{"html": "..."}`.
- `GET /api/v1/documents/connection-draft?connect_a=<id>&connect_b=<id>` -- prefill draft explaining the link between two documents -> `{"draft": {title, parent_id, content}}`.
- `GET /api/v1/documents/<id>` -- full page model (`{document, rendered_html, breadcrumbs, children, links, related}`).
- `GET /api/v1/templates` -- list document templates (`{"templates": [...]}`).
- `GET /api/v1/templates/<name>` -- load and render a template (`{template, default_path, content}`).
- `GET /api/v1/knowledge/stats` -- Knowledge Pool tier counts, scale, retrieval totals, and chat session counts.
- `GET /api/v1/knowledge/documents` -- pool documents (`?tier=0..3` or `?reviewed=1`) -> `{"documents": [...]}`.
- `GET /api/v1/knowledge/graph` -- knowledge graph nodes (with tags/groups/heat/tier) and weighted link edges -> `{"nodes": [...], "edges": [...]}`.
- `GET /api/v1/knowledge/retrievals?limit=500` -- recent retrieval runs -> `{"retrievals": [...]}`.

### Agent Chat (`/api/v1/chat`)

- `GET /api/v1/chat/sessions` -- list caller's chat sessions (`{"sessions": [...]}`).
- `POST /api/v1/chat/sessions` (`{"title": "..."}`) -- start a new session and return its state.
- `GET /api/v1/chat/sessions/<session_id>` -- fetch session state (`{session_id, owner, read_only, running, messages, pending, last_query_sql}`; markdown-role messages carry both raw `content` and rendered `content_html`). Admins (`a`) can inspect other users' sessions read-only.
- `POST /api/v1/chat/sessions/<session_id>/messages` (`{"message": "..."}`) -- send a user message and run/start the agent turn (`409` if a turn is already running).
- `POST /api/v1/chat/sessions/<session_id>/stop` -- request cancellation of an active turn -> `{"ok": true}`.
- `POST /api/v1/chat/sessions/<session_id>/approve` (`{"pending_id": 12}`) -- approve a pending write/tool call and resume the turn.
- `POST /api/v1/chat/sessions/<session_id>/deny` (`{"pending_id": 12, "reason": "..."}`) -- deny a pending write/tool call and resume the turn.
- `POST /api/v1/chat/messages/<message_id>/feedback` (`{"feedback": "up"|"down"}`) -- record reply feedback -> `{"ok": true}`.
- `POST /api/v1/chat/attachments/extract` -- multipart `file` upload (when `agent.chat_attachments_enabled = true`) -> `{"filename": "...", "text": "..."}`.

### Extensions (`/api/v1/extensions`)

- `GET /api/v1/extensions` -- list approved UI extensions (`{"extensions": [{name, label}, ...]}`).
- `GET /api/v1/extensions/<name>` -- evaluate `hooks.render(ctx, params)` -> `{"name": "...", "label": "...", "elements": [...], "html": "..."}`.
- `POST /api/v1/extensions/<name>/actions` (`{"action": "...", "args": {...}}`) -- invoke `hooks.actions[action]` -> `{"elements": [...], "html": "..."}`.

### System Administration & Settings (`/api/v1/admin`, requires `a`)

- `GET /api/v1/admin/status` -- full deployment health, provider auth, queues, and approval status report.
- `POST /api/v1/admin/schemas/sync` -- sync declarative schemas and dropdowns from disk.
- `POST /api/v1/admin/views/<name>/approve` and `POST /api/v1/admin/views/<name>/revoke` -- approve or revoke a saved SQL view.
- `POST /api/v1/admin/extensions/<name>/approve` and `POST /api/v1/admin/extensions/<name>/revoke` -- approve or revoke an extension manifest.
- `GET /api/v1/admin/triggers` -- list approved manual triggers.
- `POST /api/v1/admin/triggers/<ext>/<trigger>` -- invoke a manual trigger (`{"success": true, "message": "..."}`).
- `GET /api/v1/admin/users` (`?archived=1`), `POST /api/v1/admin/users` (`{login, password?, email?, cap?}`), `PATCH /api/v1/admin/users/<login>` (`{email?, cap?, password?}`), `POST /api/v1/admin/users/<login>/archive`, `POST /api/v1/admin/users/<login>/unarchive`.
- `GET /api/v1/admin/api-keys` (`?archived=0|1` -> `{"api_keys": [...]}`), `POST /api/v1/admin/api-keys` (`{label, cap?}` -> returns `raw_key` once), `PATCH /api/v1/admin/api-keys/<label>` (`{cap}`), `POST /api/v1/admin/api-keys/<label>/archive`, `POST /api/v1/admin/api-keys/<label>/unarchive`.
- `GET /api/v1/admin/settings` and `PATCH /api/v1/admin/settings` (`{site_name?, hide_home_heading?, system_prompt_extra?, colors?}`) -- inspect or update theme/deployment settings.
- `PUT /api/v1/admin/settings/assets/<name>` -- upload raw `image/png` bytes for `logo.png`, `logo-full.png`, or `favicon.png`.

---

## Errors & Provenance

- Protocol/auth/routing errors return `{"error": "..."}` with an HTTP 4xx/5xx status (`400` malformed request, `401` invalid key, `403` insufficient capability or bad CSRF, `404` unknown endpoint/type/row, `405` unsupported method, `409` concurrent chat turn).
- Entity field/hook validation failures on write endpoints return `200 OK` with `{"success": false, "issues": [...]}` so callers can inspect structured per-field/per-row validation issues uniformly.
- Writes authenticated via `X-Api-Key` record `api:<key label>` as the ledger author; session-authenticated writes record `<login>`.
