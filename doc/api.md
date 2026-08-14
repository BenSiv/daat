# External API (v1)

A JSON HTTP API for external, programmatic access to the platform's
entities -- scripts, other systems, and automations, as distinct from
the browser UI (which has its own separate, unversioned internal
routes and isn't a stable external contract). Every entity type
defined under `schemas/` is available through this API automatically,
the same way it's automatically available through `/register`/
`/browse`/`/detail` -- there is nothing to configure per type.

## Authentication

Requests authenticate with an API key, sent as a custom header:

```
X-Api-Key: <raw key>
```

`Authorization: Bearer <key>` is deliberately not used: Apache's
mod_cgid (the production front end -- see `doc/architecture.md`) does
not forward the `Authorization` header into a CGI script's environment
unless the vhost explicitly opts in (`CGIPassAuth On`), while any other
header, including a custom one, always passes through with no server
configuration required. `X-Api-Key` avoids depending on that vhost
setting existing (or surviving a future config change) at all.

A missing or invalid key returns `401`:

```json
{"error": "Invalid API key"}
```

There is no separate CSRF requirement for key-authenticated requests
-- CSRF protection exists to stop a browser session's ambient cookie
from being ridden by another site; a key sent in a header is
deliberately attached by the caller, so that risk doesn't apply.

### Managing keys

Keys are managed by an account with the `a` (admin) capability, either
in the web UI (`/admin-api-keys`) or via the CLI:

```
daat api-key create <label> [cap]
daat api-key list [--include-archived]
daat api-key capabilities <label> <cap_string>
daat api-key archive <label>
daat api-key unarchive <label>
```

`create` prints the raw key exactly once. It is stored only as a
bcrypt hash -- the same guarantee the platform gives account passwords
-- so there is no way to retrieve an existing key's value again; if
it's lost, archive it and create a new one.

### Capabilities

A key's `cap` string uses the same single-letter capabilities as a
user account:

| Letter | Grants |
|---|---|
| `i` | Baseline access -- required for every endpoint below. |
| `a` | Required in addition to `i` for any entity type whose schema marks it `admin_write_only` (writes only; reads are unaffected). |

A key with just `i` can read and write every entity type that isn't
`admin_write_only`; add `a` for full write access.

## Base path

All routes below are rooted at `/api/v1`. `<type>` is any registered
entity type's name (e.g. `chemical`, `culture_medium`).

### `GET /api/v1/<type>`

List rows, paginated.

Query params (all optional):
- `limit` -- default matches the browse page size.
- `offset` -- default `0`.
- `filter_field` / `filter_value` -- restrict to rows where this field
  equals this value; `filter_field` must name a real field on the
  type. The same mechanism `/browse`'s own filtered links use for
  reverse-reference lookups (e.g. "every ingredient of this recipe").

```json
{"rows": [{"id": 5, "name": "Glucose", ...}], "total": 42}
```

### `GET /api/v1/<type>/<id>`

Fetch a single row (archived or not -- archiving never deletes a row).
`404` with `{"error": "Not found"}` if it doesn't exist.

```json
{"row": {"id": 5, "name": "Glucose", ...}}
```

### `POST /api/v1/<type>`

Create. A JSON object body creates one row; a JSON array creates a
batch in one call.

Single:
```json
{"name": "Glucose", "amount": 10}
```
->
```json
{"success": true, "created_id": 6, "issues": []}
```

Batch:
```json
[{"name": "Glucose"}, {"name": "Sucrose"}]
```
->
```json
{"success": true, "created_ids": [7, 8], "issues": [...]}
```

`issues` lists any field-level validation problems (present even on
success, e.g. warnings); `success: false` means nothing was created.

### `PATCH /api/v1/<type>/<id>`

Update. Body is a JSON object of the fields to change (unset fields
are left alone).

```json
{"amount": 12}
```
->
```json
{"success": true, "updated_id": 6, "issues": []}
```

An optional `?reason=` query param is recorded on the change's ledger
entry, same as the UI's own edit form.

### `POST /api/v1/<type>/<id>/archive`

### `POST /api/v1/<type>/<id>/unarchive`

Archive/unarchive a row -- never a hard delete; every entity's history
stays intact and reachable via `GET`. Same optional `?reason=`.

```json
{"success": true, "archived_id": 6, "issues": []}
```

## Errors

Every failure is `{"error": "..."}` with a 4xx/5xx status
(`400` malformed request, `401` bad key, `403` insufficient capability,
`404` unknown type/row, `405` unsupported method on a matched path).
Write endpoints instead return `200` with `{"success": false, "issues": [...]}`
when the request was well-formed but validation rejected the values --
the same convention the internal UI-facing routes already use.

## Provenance

Every write made through a key is recorded on that entity's ledger
history with the key's label as the author (e.g. `api:nightly sync
job`), so it reads unambiguously as key-driven -- not a real user's
own edit -- in `/detail`'s history and anywhere else ledger entries
are shown.

## Out of scope (v1)

- Rate limiting / per-key quotas.
- Per-entity-type or per-field scoping beyond the `i`/`a` capability
  model above.
- A deprecation/versioning policy beyond "v1 exists today."
