-- The document/notebook entity type: a real parent_id tree, not a
-- name-is-identity convention. Unlike a schema a deployment authors
-- itself (schemas/*.lua), "document" is a built-in type this module
-- registers directly via schema.register -- its own extra behavior
-- here (link parsing, backlinks, breadcrumbs, rendering) is tightly
-- coupled to its exact field shape, so keeping the schema and that
-- behavior in the same trusted, first-party module (not a deployment-
-- editable file) guarantees they can never drift apart.
--
-- Cross-document linking adopts the "[[title]]" / "[[subject/title]]"
-- inline-link convention -- parsed the same way (regex over the raw
-- content, split on the first "/"), but NOT ported as-is: the source
-- convention strips a matched link out of the displayed content
-- entirely once parsed (fine for a personal note's tag-like link
-- list, wrong here, since a document's prose needs the link to stay
-- visible and readable in place). Links here are left in the content
-- and rendered as an inline Markdown link over the same text instead.
--
-- Link resolution deliberately doesn't walk a full multi-level path --
-- "title" alone matches by title (first match wins if more than one
-- document shares a title); "subject/title" additionally requires the
-- resolved document's immediate parent to be titled "subject". A full
-- path-chain resolver would be more precise but is more machinery than
-- inline prose links need; this one-level disambiguator covers the
-- realistic case (two same-titled documents in different folders) without
-- it.
--
-- Links are a derived index over document content, not data in their
-- own right -- rebuildable from content alone at any time (`daat repair
-- links`), rather than a schema-driven entity type with its own ledger
-- history. Content is the only place knowledge lives: *why* two
-- documents are connected is the sentence around the link, or a
-- document that links both and says why -- written the same way by a
-- person or the agent (see doc/document-link-flow.md). The content that
-- generates links already has full audit history via the document
-- entity itself; a link row's own history would just be churn.

db = require("database")
schema = require("schema")
entity = require("entity")
tag = require("tag")
reference = require("reference")
json = require("dkjson")
external_tool = require("external_tool")
gnuplot = require("gnuplot")
hmac = require("hmac")
config = require("config")

document = {}

-- shell_quote/strip_spaces used before their own definitions below --
-- pre-declared, see ../../luam/doc/forward_references.md
shell_quote, strip_spaces = nil, nil

DOCUMENT_SCHEMA = {
    name = "document",
    fields = {
        {name = "parent_id", type = "reference", required = false, entity_type = "document"},
        {name = "title", type = "text", required = true, display = true},
        {name = "content", type = "text", required = false},
    },
}

-- Derived subject tags (doc/structure-layers.md): computed outside daat
-- by a clustering job that writes these through the API, with manual
-- overrides that a recompute never touches. Ordinary entity types, so
-- they're browsable, editable and ledgered like any other.
--   tag.source: "computed" (the job's) or "manual" (a person's).
--   document_tag.decision: "computed" (the job replaces it freely),
--   "pinned" (a person put the document in the tag; never removed by
--   the job) or "excluded" (a person took it out; never re-added, and
--   treated as absent everywhere).
TAG_SCHEMA = {
    name = "tag",
    fields = {
        -- "label", not "name": every entity table already has a
        -- bookkeeping `name` column (schema.sync_table).
        {name = "label", type = "text", required = true, display = true},
        -- The tag's definition (doc/tag-ontology.md): what it covers and
        -- how it differs from the tags beside it.
        {name = "description", type = "text", required = false},
        {name = "terms", type = "text", required = false},
        {name = "source", type = "select", required = true, values = {"computed", "manual"}},
        {name = "computed_at", type = "text", required = false},
        -- Optional broader tag this one sits under (one level: broad >
        -- specific). Documents carry the specific tag; the broad one
        -- follows from it, e.g. for the graph's colour-by.
        {name = "parent", type = "reference", required = false, entity_type = "tag"},
    },
}

DOCUMENT_TAG_SCHEMA = {
    name = "document_tag",
    fields = {
        {name = "document", type = "reference", required = true, entity_type = "document"},
        {name = "tag", type = "reference", required = true, entity_type = "tag"},
        {name = "score", type = "number", required = false},
        {name = "decision", type = "select", required = true, values = {"computed", "pinned", "excluded"}},
        -- "text": the membership is a #tag in the document's content
        -- (tag.sync_text_tags), kept while the text has it.
        {name = "via", type = "select", required = false, values = {"text"}},
    },
}

-- "See also" between two tags (doc/tag-ontology.md). Broader is not a
-- relation here: it's tag.parent, the one place a tag's broader tag is
-- kept. A pair is stored once, tag_a the smaller id.
--   decision: "computed" (proposed from evidence or by the agent;
--   replaced freely), "pinned" (a person asserted it; never removed) or
--   "excluded" (a person rejected it; never proposed again) -- the same
--   words as document_tag.decision.
--   reason: why the two are related, in words; evidence: what it was
--   derived from (JSON), so it can be checked.
TAG_RELATION_SCHEMA = {
    name = "tag_relation",
    fields = {
        {name = "tag_a", type = "reference", required = true, entity_type = "tag"},
        {name = "tag_b", type = "reference", required = true, entity_type = "tag"},
        {name = "decision", type = "select", required = true, values = {"computed", "pinned", "excluded"}},
        {name = "score", type = "number", required = false},
        {name = "reason", type = "text", required = false},
        {name = "evidence", type = "text", required = false},
    },
}

-- Edges between documents, lifted onto their tags: one row per pair,
-- kind and producer, holding raw totals only (lift is computed on read,
-- so a row changes only when its underlying edges do). Like a
-- document's content, the rows can carry deployment-specific meaning:
-- `kind` is an open string ("link", "connection", or whatever an
-- extension produces), and core never branches on its value.
--   direction: "directed" (tag_a -> tag_b) or "undirected" (tag_a the
--   smaller id; tag_a = tag_b is evidence inside one tag).
--   weight: the pair's total; support: how many distinct underlying
--   things (documents, entities) it rests on.
--   producer: "core", or the extension that wrote the row.
TAG_EVIDENCE_SCHEMA = {
    name = "tag_evidence",
    fields = {
        {name = "tag_a", type = "reference", required = true, entity_type = "tag"},
        {name = "tag_b", type = "reference", required = true, entity_type = "tag"},
        {name = "kind", type = "text", required = true},
        {name = "direction", type = "select", required = true, values = {"directed", "undirected"}},
        {name = "weight", type = "number", required = true},
        {name = "support", type = "number", required = false},
        {name = "producer", type = "text", required = true},
    },
}

-- One row per distinct [[link]] text in a document's content. Keyed by
-- its own id rather than by link_text: link text is whatever a title
-- is, and no key length can promise to hold that (a real paper title
-- overflowed the old VARCHAR(255) key). Uniqueness per (document, link
-- text) goes through link_hash instead. raw_strength/archived_at/
-- created_at are usage metadata about the edge, the way heat is about a
-- document -- not knowledge, which lives only in content.
DOCUMENT_LINK_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS %s (
    id INTEGER PRIMARY KEY %s,
    from_document_id INTEGER NOT NULL,
    to_document_id INTEGER,
    link_text TEXT NOT NULL,
    link_hash CHAR(64) NOT NULL,
    raw_strength REAL NOT NULL DEFAULT 1.0,
    archived_at TEXT DEFAULT NULL,
    created_at TEXT DEFAULT NULL
);
"""

-- Usage-driven edge strength (see doc/link-strength-redesign.md) --
-- reinforced when a directly linked pair keeps being retrieved
-- together (knowledge.maybe_link_co_retrieved), read as a share of a
-- retrieved document's total outgoing strength by spread_activation.
-- Every new row starts here.
BASE_LINK_STRENGTH = 1.0

function document.link_hash(link_text)
    return hmac.sha256("document_link", link_text)
end

function create_document_link_table(db_path, table_name)
    db.exec(db_path, string.format(DOCUMENT_LINK_TABLE_SQL, table_name, db.autoincrement_keyword(db_path)))
end

-- Guarded execs, not CREATE INDEX IF NOT EXISTS -- real MySQL has no
-- such syntax (see knowledge.lua's ensure_knowledge_indexes). Every
-- request runs this, so concurrent first requests can all see an index
-- missing and race to create it -- found rehearsing the layout
-- migration against real MySQL: the losers failed with "Duplicate key
-- name". A failed CREATE is only an error if the index still doesn't
-- exist afterwards. The migration also creates them itself, under its
-- lock, before the table is ever visible under its real name.
function ensure_document_link_indexes(db_path, table_name)
    if table_name == nil then
        table_name = "document_link"
    end
    indexes = {
        {name = "document_link_from_hash_idx",
         sql = "CREATE UNIQUE INDEX document_link_from_hash_idx ON %s(from_document_id, link_hash);"},
        {name = "document_link_to_idx",
         sql = "CREATE INDEX document_link_to_idx ON %s(to_document_id);"},
    }
    for _, idx in ipairs(indexes) do
        if db.index_exists(db_path, table_name, idx.name) == false then
            ok, err = pcall(db.exec, db_path, string.format(idx.sql, table_name))
            if ok == false and db.index_exists(db_path, table_name, idx.name) == false then
                error(err)
            end
        end
    end
end

function column_set(db_path, table_name)
    have = {}
    for _, name in ipairs(db.get_columns(db_path, table_name)) do
        have[name] = true
    end
    return have
end

-- Defined below migrate_document_link_layout, called from it -- see
-- ../../luam/doc/forward_references.md.
copy_document_links_to_new_layout, sql_null_to_nil = nil, nil

LINK_MIGRATION_BATCH = 200

-- Every store before this layout keyed document_link by
-- (from_document_id, link_text) -- and also held links no content
-- backed: rows the co-retrieval judgment created directly (source =
-- 'co-retrieval'), plus per-link notes. Rebuilt once into the layout
-- above. Rows content backs, and archived ones (whose raw_strength a
-- retyped link gets back), are copied; co-retrieval-only rows aren't --
-- no document holds them, so a content-derived index can't -- and stay
-- behind in document_link_legacy for the deployment to turn into real
-- content (a connection document per pair) and then drop. Notes aren't
-- copied either: the sentence around a link is read from content now.
--
-- Runs from every request's schema init (cgi.handle_request), so on
-- MySQL it takes a named lock and re-checks under it: the first
-- requests after a deploy would otherwise run it concurrently, and DDL
-- isn't transactional. Copies into document_link_new before swapping
-- names, so a failure part-way leaves the old table untouched and the
-- next request starts over (document_link_needs_migration also covers
-- a failure between the two renames).
-- Either half-done state this migration can be in: the old layout
-- still in place, or the one window copy_document_links_to_new_layout
-- can't make atomic -- the first rename done, the second not
-- (document_link missing, a fully copied document_link_new present).
function document_link_needs_migration(db_path)
    if db.table_exists(db_path, "document_link") == false then
        return db.table_exists(db_path, "document_link_new")
    end
    return column_set(db_path, "document_link")["link_hash"] != true
end

function migrate_document_link_layout(db_path)
    if document_link_needs_migration(db_path) == false then
        return
    end
    locked = db.is_mariadb(db_path)
    if locked then
        db.query(db_path, "SELECT GET_LOCK('daat_document_link_layout', 120) AS got;")
    end
    ok, err = pcall(function()
        if document_link_needs_migration(db_path) == false then
            return
        end
        if db.table_exists(db_path, "document_link") == false then
            db.exec(db_path, "ALTER TABLE document_link_new RENAME TO document_link;")
            return
        end
        copy_document_links_to_new_layout(db_path)
    end)
    if locked then
        db.query(db_path, "SELECT RELEASE_LOCK('daat_document_link_layout') AS released;")
    end
    if ok == false then
        error(err)
    end
end

function copy_document_links_to_new_layout(db_path)
    db.exec(db_path, "DROP TABLE IF EXISTS document_link_new;")
    create_document_link_table(db_path, "document_link_new")
    have = column_set(db_path, "document_link")
    strength_expr = "1.0"
    if have["raw_strength"] == true then
        strength_expr = "raw_strength"
    end
    archived_expr = "NULL"
    if have["archived_at"] == true then
        archived_expr = "archived_at"
    end
    created_expr = "NULL"
    if have["created_at"] == true then
        created_expr = "created_at"
    end
    where = ""
    if have["source"] == true then
        where = " WHERE source != 'co-retrieval'"
    end
    rows = db.query(db_path, string.format(
        "SELECT from_document_id, to_document_id, link_text, %s AS raw_strength, %s AS archived_at, %s AS created_at FROM document_link%s;",
        strength_expr, archived_expr, created_expr, where
    ))
    if rows == nil then
        rows = {}
    end
    -- Multi-row INSERTs, LINK_MIGRATION_BATCH rows at a time -- every
    -- request waits on this, and one statement per row is thousands of
    -- round trips against a remote MySQL.
    values = {}
    for i, row in ipairs(rows) do
        strength = tonumber(row.raw_strength)
        if strength == nil then
            strength = BASE_LINK_STRENGTH
        end
        table.insert(values, string.format("(%d, %s, %s, %s, %.17g, %s, %s)",
            tonumber(row.from_document_id), db.literal(sql_null_to_nil(row.to_document_id)), db.quote(row.link_text),
            db.quote(document.link_hash(row.link_text)), strength,
            db.literal(sql_null_to_nil(row.archived_at)), db.literal(sql_null_to_nil(row.created_at))))
        if #values == LINK_MIGRATION_BATCH or i == #rows then
            db.exec(db_path, "INSERT INTO document_link_new (from_document_id, to_document_id, link_text, link_hash, raw_strength, archived_at, created_at) VALUES " ..
                table.concat(values, ", ") .. ";")
            values = {}
        end
    end
    -- Indexes before the swap, so the table is complete the moment it's
    -- visible as document_link. Index names carry over a rename; the
    -- legacy table never had these names, so SQLite's database-wide
    -- index namespace doesn't collide either.
    ensure_document_link_indexes(db_path, "document_link_new")
    db.exec(db_path, "ALTER TABLE document_link RENAME TO document_link_legacy;")
    db.exec(db_path, "ALTER TABLE document_link_new RENAME TO document_link;")
end

-- db.query renders a SQL NULL as "", never Lua nil.
function sql_null_to_nil(value)
    if value == nil or value == "" then
        return nil
    end
    return value
end


-- A document's cached semantic-search embedding. A save doesn't call
-- the provider: it queues the document in document_embedding_due, and
-- `daat document embed-pending` (document.embed_pending, on the
-- deployment's job timer) embeds it once it has gone
-- embedding_quiet_minutes without another edit -- so a document saved
-- again and again (a chat transcript, after every turn) costs one
-- embedding, not one per save. text_hash is the hash of the exact text
-- embedded, so a queued document whose text came back unchanged isn't
-- re-embedded. Best-effort: a failed call leaves the document queued for
-- the next run, and a save never fails because of it.
-- document.reindex_all_embeddings/`daat repair embeddings` exist for
-- recovery (a provider outage, a change of model). Search itself only
-- ever *reads* this cache; it never computes an embedding on the fly.
-- `model` is the embedding model that made the vector
-- (agent_provider.embedding_model -- platform.lua's embedding_model, else
-- the provider's default); search compares only vectors from the current
-- one, so after a change of model `daat repair embeddings` re-embeds.
DOCUMENT_EMBEDDING_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding (
    document_id INTEGER PRIMARY KEY,
    model TEXT NOT NULL,
    vector_json TEXT NOT NULL,
    updated_at TEXT DEFAULT (%s)
);
"""

-- Documents saved since their embedding was made, with when they were
-- last saved (UTC, "YYYY-MM-DD HH:MM:SS", written by Lua so the quiet-
-- period comparison means the same on SQLite and MariaDB).
DOCUMENT_EMBEDDING_DUE_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding_due (
    document_id INTEGER PRIMARY KEY,
    queued_at VARCHAR(19) NOT NULL
);
"""

-- Knowledge Pool scoring columns live directly on `document` (see
-- doc/architecture.md's "Knowledge pool" section for why) -- these are
-- system/derived bookkeeping a user never edits directly, so they're
-- added via migration rather than DOCUMENT_SCHEMA.fields (which would
-- wrongly expose them as user-editable/required form fields) -- same
-- pattern as ledger.lua's ensure_entity_event_reason_column.
function ensure_document_knowledge_columns(db_path)
    existing = db.get_columns(db_path, "document")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["tier"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN tier INTEGER DEFAULT 0;")
    end
    if have["heat"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN heat REAL DEFAULT 1.0;")
    end
    if have["retrieval_count"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN retrieval_count INTEGER DEFAULT 0;")
    end
    if have["last_retrieved_at"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN last_retrieved_at TEXT;")
    end
    if have["source_type"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN source_type TEXT;")
    end
    if have["source_id"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN source_id INTEGER;")
    end
    if have["source_ref"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN source_ref TEXT;")
    end
    if have["content_hash"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN content_hash TEXT;")
    end
    if have["duplicate_of"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN duplicate_of INTEGER;")
    end
    if have["merged_into"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN merged_into INTEGER;")
    end
    -- The conserved heat-pool model (see doc/heat-decay-redesign.md).
    -- ADD COLUMN ... DEFAULT 1.0 backfills every existing row to
    -- BASE_HEAT, which is exactly the "reset" migration decision from
    -- that document -- no separate UPDATE needed.
    if have["raw_heat"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN raw_heat REAL DEFAULT 1.0;")
    end
    if have["scale_at_write"] == nil then
        db.exec(db_path, "ALTER TABLE document ADD COLUMN scale_at_write REAL DEFAULT 1.0;")
    end
end

-- Ground truth for the chat agent when it's asked to write ad-hoc SQL
-- touching heat/tier/retrieval/source: since these columns are
-- deliberately absent from DOCUMENT_SCHEMA.fields (see
-- ensure_document_knowledge_columns above), entity.fields('document')
-- used to return only parent_id/title/content -- the model had no real
-- column names to ground a query in, and would invent a fictional table
-- instead of naming the real one (confirmed live: it asked for "heat" by
-- inventing "knowledge_entries"/"record_type", which don't exist).
-- agent.lua's entity.fields dispatch appends this after the normal
-- editable-field listing -- read-only documentation, never a
-- schema.fields()/DOCUMENT_SCHEMA source, so it can't leak into the edit
-- form the way adding these to DOCUMENT_SCHEMA.fields would.
KNOWLEDGE_POOL_SQL_COLUMNS = {
    {name = "tier", note = "0-3, knowledge-pool maturity tier"},
    {name = "retrieval_count", note = "direct search-hit count"},
    {name = "last_retrieved_at", note = "timestamp of last search hit"},
    {name = "source_type", note = "'chat_session' | 'reasoning' | 'distilled' | NULL (NULL means either directly user-authored, or synced in from an external system)"},
    {name = "source_id", note = "meaning depends on source_type"},
    {name = "source_ref", note = "e.g. the chat session id, when source_type = 'chat_session'"},
    {name = "external_id", note = "set when this document was synced in from an external system (e.g. Benchling); NULL for anything authored directly here"},
    {name = "content_hash", note = "used for duplicate detection"},
    {name = "duplicate_of", note = "FK to document.id, set once this row is folded into a canonical duplicate"},
    {name = "merged_into", note = "same as duplicate_of -- rows with this set are excluded from search"},
    {name = "raw_heat", note = "conserved-pool raw heat -- do not average this column alone, see scale_at_write"},
    {name = "scale_at_write", note = "combine as raw_heat * (EXP(knowledge_pool_state.log_pool_scale) / scale_at_write) for the real effective_heat; the separate 'heat' column is legacy and never updated -- ignore it"},
}
KNOWLEDGE_POOL_SQL_NOTE = "Related tables, hand-rolled rather than schema.register()'d so entity.list_types never mentions them: knowledge_pool_state (one row, id=1: pool_scale/log_pool_scale/document_count) and document_link (queryable via entity.query; entity.fields('document_link') lists its columns) -- a derived index of [[links]] in document content; why two documents are connected is in content, not here."

-- entity.fields('document_link'): it's queryable (view.queryable_tables),
-- so its columns get the same real-columns answer as document_embedding.
DOCUMENT_LINK_SQL_COLUMNS = {
    {name = "id", note = "primary key"},
    {name = "from_document_id", note = "FK to document.id -- the document whose content holds the [[link]]"},
    {name = "to_document_id", note = "FK to document.id -- the linked document; NULL while the link points at a page not created yet"},
    {name = "link_text", note = "the text inside [[...]] in from_document_id's content"},
    {name = "link_hash", note = "hash of link_text, for matching"},
    {name = "raw_strength", note = "usage-driven edge strength, starts at 1.0 and grows when the pair is retrieved together"},
    {name = "archived_at", note = "set when the link left the content -- filter archived_at IS NULL for current links"},
    {name = "created_at", note = "NULL for links predating the column"},
}

function document.link_sql_columns_text()
    lines = {}
    for _, col in ipairs(DOCUMENT_LINK_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n") .. "\nWhy two documents are connected is in content, not here: document.links returns the sentence around each link."
end

function document.knowledge_pool_sql_columns_text()
    lines = {}
    for _, col in ipairs(KNOWLEDGE_POOL_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n") .. "\n" .. KNOWLEDGE_POOL_SQL_NOTE
end

-- Same treatment as KNOWLEDGE_POOL_SQL_COLUMNS above, for a genuinely
-- separate table rather than document's own extra columns -- so
-- entity.fields('document_embedding') answers with real columns instead
-- of agent.lua falling through to the generic "unknown entity type"
-- message.
DOCUMENT_EMBEDDING_SQL_COLUMNS = {
    {name = "document_id", note = "primary key, FK to document.id"},
    {name = "model", note = "which embedding model produced this vector"},
    {name = "vector_json", note = "the cached embedding vector, JSON-encoded"},
    {name = "vector_packed", note = "the same vector L2-normalised, as little-endian float32 bytes (what search reads)"},
    {name = "text_hash", note = "hash of the exact text embedded (NULL: made before this column, assumed current)"},
    {name = "updated_at", note = "timestamp of the last reindex"},
}

-- vector_packed (see document.pack_vector) and text_hash postdate the
-- table, so they're retrofitted here rather than in
-- DOCUMENT_EMBEDDING_SCHEMA -- one path for new and existing installs
-- alike.
function ensure_document_embedding_columns(db_path)
    have = {}
    for _, name in ipairs(db.get_columns(db_path, "document_embedding")) do
        have[name] = true
    end
    if have["vector_packed"] == nil then
        db.exec(db_path, "ALTER TABLE document_embedding ADD COLUMN vector_packed BLOB;")
    end
    if have["text_hash"] == nil then
        db.exec(db_path, "ALTER TABLE document_embedding ADD COLUMN text_hash VARCHAR(64);")
    end
end

function document.embedding_sql_columns_text()
    lines = {}
    for _, col in ipairs(DOCUMENT_EMBEDDING_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n")
end

-- Real MySQL has no "CREATE INDEX IF NOT EXISTS" (a syntax error, not a
-- no-op, unlike MariaDB) -- same reasoning as knowledge.lua's own
-- ensure_knowledge_indexes (now folded in here).
function ensure_document_knowledge_indexes(db_path)
    indexes = {
        {name = "document_tier_idx", table = "document",
         sql = "CREATE INDEX document_tier_idx ON document(tier, heat DESC, retrieval_count DESC);"},
        {name = "document_hash_idx", table = "document",
         sql = string.format("CREATE INDEX document_hash_idx ON document(%s);",
             db.text_index_column(db_path, "content_hash"))},
    }
    for _, idx in ipairs(indexes) do
        if db.index_exists(db_path, idx.table, idx.name) == false then
            db.exec(db_path, idx.sql)
        end
    end
end

-- The conserved heat-pool model (see doc/heat-decay-redesign.md). One
-- shared row: `pool_scale` is the lazy multiplier every document's
-- raw_heat is read against (see document.pool_effective_heat below);
-- `document_count` is the active (non-archived, non-merged) count,
-- maintained incrementally so no reinforcement event ever needs a
-- COUNT(*) scan. `pool_scale` itself is kept only for rollback (Phase
-- 4) -- no longer written or read; `log_pool_scale` is authoritative.
-- See "The representation change" in doc/heat-decay-redesign.md for why
-- only this shared value needs log-space (each row's own
-- scale_at_write stays linear, unaffected).
KNOWLEDGE_POOL_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_pool_state (
    id INTEGER PRIMARY KEY,
    pool_scale REAL NOT NULL DEFAULT 1.0,
    log_pool_scale REAL NOT NULL DEFAULT 0.0,
    document_count INTEGER NOT NULL DEFAULT 0
);
"""

-- Declared here, not down by the rest of the pool functions below,
-- since Luam requires a top-level value to be declared before any
-- function referencing it -- even one elsewhere in the same file (a
-- stricter static-scoping check than vanilla Lua does; see
-- document.register_pool_document just below, which needs this).
BASE_HEAT = 1.0

-- Retrofits `log_pool_scale` onto an existing knowledge_pool_state
-- table (KNOWLEDGE_POOL_STATE_SCHEMA's CREATE TABLE IF NOT EXISTS only
-- covers a brand-new table). For an install that already has real
-- traffic -- a `pool_scale` drifted away from its 1.0 default -- seeds
-- log_pool_scale = ln(pool_scale) from that existing value, a genuine
-- one-time migration, not a blind reset to 0.0 (see "Migration" in
-- doc/heat-decay-redesign.md, Phase 4). A no-op every call after the
-- first, and for a fresh install where the column already came from
-- the CREATE TABLE itself.
function ensure_knowledge_pool_state_log_scale_column(db_path)
    existing = db.get_columns(db_path, "knowledge_pool_state")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["log_pool_scale"] != nil then
        return
    end
    db.exec(db_path, "ALTER TABLE knowledge_pool_state ADD COLUMN log_pool_scale REAL NOT NULL DEFAULT 0.0;")
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    if rows != nil and rows[1] != nil then
        db.exec(db_path, string.format(
            "UPDATE knowledge_pool_state SET log_pool_scale = %.17g WHERE id = 1;",
            math.log(tonumber(rows[1].pool_scale))
        ))
    end
end

-- Seeds the single state row exactly once, from a one-time COUNT(*) --
-- the only place this design scans the whole pool (see "Migration of
-- existing values" in doc/heat-decay-redesign.md). A no-op every call
-- after the first.
function document.ensure_pool_state(db_path)
    db.exec(db_path, KNOWLEDGE_POOL_STATE_SCHEMA)
    ensure_knowledge_pool_state_log_scale_column(db_path)
    rows = db.query(db_path, "SELECT id FROM knowledge_pool_state WHERE id = 1;")
    if rows != nil and rows[1] != nil then
        return
    end
    count_rows = db.query(db_path,
        "SELECT COUNT(*) AS n FROM document WHERE (archived_at IS NULL OR archived_at = '') AND merged_into IS NULL;")
    count = 0
    if count_rows != nil and count_rows[1] != nil then
        count = tonumber(count_rows[1].n)
    end
    db.exec(db_path, string.format(
        "%s knowledge_pool_state (id, pool_scale, log_pool_scale, document_count) VALUES (1, 1.0, 0.0, %d);",
        db.insert_ignore(db_path), count
    ))
end

-- Backfill for document_count drift -- the manual correction for
-- whatever entity.create's own on_entity_created hook can't reach (a
-- raw SQL insert, a restored backup, a bulk load run before this hook
-- existed) -- `daat repair pool-count`, the same class of command as
-- `daat repair links`/`embeddings`.
-- Recomputes document_count from a real COUNT(*) over active documents
-- -- the same one-time scan ensure_pool_state's own initial seed uses
-- -- and overwrites the stored value with it. Doesn't (can't) recover
-- any individual document's own raw_heat/scale_at_write for whatever
-- window it went unregistered; realigns the aggregate invariant
-- (`total = document_count * BASE_HEAT`) for every reinforcement from
-- this point on, which is what the conservation guarantee actually
-- depends on going forward.
function document.resync_pool_count(db_path)
    document.ensure_pool_state(db_path)
    count_rows = db.query(db_path,
        "SELECT COUNT(*) AS n FROM document WHERE (archived_at IS NULL OR archived_at = '') AND merged_into IS NULL;")
    count = 0
    if count_rows != nil and count_rows[1] != nil then
        count = tonumber(count_rows[1].n)
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_pool_state SET document_count = %d WHERE id = 1;", count
    ))
    return count
end

-- Registers a document with the pool -- either genuinely new, or
-- rejoining after an unarchive (see document.on_entity_unarchived
-- below). Grows the total by exactly BASE_HEAT (see "Document
-- creation" in doc/heat-decay-redesign.md) and pins the row's
-- raw_heat/scale_at_write so it reads back as exactly BASE_HEAT right
-- away, regardless of how far the shared multiplier has already
-- drifted from 1.0 by this point. raw_heat is set explicitly rather
-- than relied on from the column's own DEFAULT, since a rejoining row
-- already has some stale value sitting in it from before it was
-- archived -- its old heat was already returned to the pool at
-- archive time (return_pool_heat), so reusing it here would double it.
function document.register_pool_document(db_path, document_id)
    document.ensure_pool_state(db_path)
    state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    if state_rows == nil or state_rows[1] == nil then
        return
    end
    pool_scale = math.exp(tonumber(state_rows[1].log_pool_scale))
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = %.17g, scale_at_write = %.17g WHERE id = %d;",
        BASE_HEAT, pool_scale, tonumber(document_id)
    ))
    db.exec(db_path, "UPDATE knowledge_pool_state SET document_count = document_count + 1 WHERE id = 1;")
end

function document.init_schema(db_path)
    schema.register(db_path, DOCUMENT_SCHEMA)
    schema.register(db_path, TAG_SCHEMA)
    schema.register(db_path, DOCUMENT_TAG_SCHEMA)
    schema.register(db_path, TAG_RELATION_SCHEMA)
    schema.register(db_path, TAG_EVIDENCE_SCHEMA)
    migrate_document_link_layout(db_path)
    create_document_link_table(db_path, "document_link")
    ensure_document_link_indexes(db_path)
    db.exec(db_path, string.format(DOCUMENT_EMBEDDING_SCHEMA, db.now_expr(db_path)))
    ensure_document_embedding_columns(db_path)
    db.exec(db_path, DOCUMENT_EMBEDDING_DUE_SCHEMA)
    tag.init_schema(db_path)
    require("tag_upkeep").init_schema(db_path)
    reference.init_schema(db_path)
    ensure_document_knowledge_columns(db_path)
    ensure_document_knowledge_indexes(db_path)
    document.ensure_pool_state(db_path)
end

-- The single top-level folder every system/agent-derived document
-- (reasoning notes, distilled notes) lives under. Visible and
-- browsable like any other folder, never containing a user's own
-- authored documents. Created lazily on first use, not at init time;
-- idempotent -- a second call reuses the existing folder.
KNOWLEDGE_POOL_FOLDER_TITLE = "Knowledge Pool"

function document.ensure_knowledge_pool_folder(db_path)
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE parent_id IS NULL AND title = %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC LIMIT 1;",
        db.quote(KNOWLEDGE_POOL_FOLDER_TITLE)
    ))
    if rows != nil and rows[1] != nil then
        return tonumber(rows[1].id)
    end
    folder_id, _ = document.create_page(db_path, "system", KNOWLEDGE_POOL_FOLDER_TITLE, nil, nil, nil)
    return folder_id
end

--------------------------------------------------------------------------
-- Tree structure
--------------------------------------------------------------------------

function document.children(db_path, parent_id)
    where = "parent_id IS NULL"
    if parent_id != nil then
        where = "parent_id = " .. tostring(tonumber(parent_id))
    end
    rows = db.query(db_path, string.format(
        "SELECT id, title FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '') ORDER BY title ASC;",
        where
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Every active document's id/title/parent_id, for building the full
-- tree view in one query rather than one query per level. created_at/
-- external_id ride along here rather than a second query (used by
-- html.document_parent_options to disambiguate duplicate titles) --
-- cheap, and every existing caller already ignores columns it doesn't use.
function document.all_active(db_path)
    rows = db.query(db_path,
        "SELECT id, title, parent_id, created_at, external_id FROM document WHERE archived_at IS NULL OR archived_at = '' ORDER BY title ASC;")
    if rows == nil then
        return {}
    end
    return rows
end

-- Root-to-self list of {id, title}, for breadcrumbs. `path` is
-- deliberately not cached on the row -- it's fully derived from
-- parent_id (the actual source of identity), recomputed on read, so it
-- can never go stale the way a cached copy could.
function document.breadcrumbs(db_path, document_id)
    crumbs = {}
    current_id = tonumber(document_id)
    guard = 0
    while current_id != nil and guard < 100 do
        guard = guard + 1
        row = entity.get(db_path, "document", current_id)
        if row == nil then
            break
        end
        table.insert(crumbs, 1, {id = row.id, title = row.title})
        current_id = tonumber(row.parent_id)
    end
    return crumbs
end

-- True if setting `document_id`'s parent to `new_parent_id` would make
-- it its own ancestor (moving a document underneath its own descendant).
-- Checked explicitly at save time rather than only guarded against by
-- breadcrumbs' own iteration cap -- a real error message beats a
-- silently-truncated breadcrumb trail.
function document.would_create_cycle(db_path, document_id, new_parent_id)
    if new_parent_id == nil or new_parent_id == "" then
        return false
    end
    target_id = tonumber(new_parent_id)
    self_id = tonumber(document_id)
    if target_id == self_id then
        return true
    end
    current_id = target_id
    guard = 0
    while current_id != nil and guard < 100 do
        guard = guard + 1
        if current_id == self_id then
            return true
        end
        row = entity.get(db_path, "document", current_id)
        if row == nil then
            return false
        end
        current_id = tonumber(row.parent_id)
    end
    return false
end

--------------------------------------------------------------------------
-- Link parsing, resolution, backlinks
--------------------------------------------------------------------------

-- "subject/title" -> subject, title; "title" alone -> nil, title.
-- Only the fallback reading of a link -- see document.resolve_link_text.
function document.parse_link_ref(raw_link)
    trimmed = string.gsub(raw_link, "^%s*(.-)%s*$", "%1")
    slash_pos = string.find(trimmed, "/", 1, true)
    if slash_pos != nil then
        return string.sub(trimmed, 1, slash_pos - 1), string.sub(trimmed, slash_pos + 1)
    end
    return nil, trimmed
end

-- Resolves a parsed link ref to a document id, or nil if unresolved
-- (a "dangling" link -- the target hasn't been created yet, or was
-- archived/renamed away).
function document.resolve_link(db_path, subject, title)
    rows = db.query(db_path, string.format(
        "SELECT id, parent_id FROM document WHERE title = %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC;",
        db.quote(title)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    if subject == nil then
        return rows[1].id
    end
    for _, row in ipairs(rows) do
        if row.parent_id != nil then
            parent = entity.get(db_path, "document", tonumber(row.parent_id))
            if parent != nil and parent.title == subject then
                return row.id
            end
        end
    end
    return nil
end

-- Resolves the text inside a [[...]] to a document id, or nil. The
-- whole text is tried as a title first, so a title that itself
-- contains "/" (CRISPR/Cas9, PI3K/AKT, 11/08/2026) links as written;
-- only when no document has that exact title is it read as
-- "subject/title" (split on the first "/"). An exact title always wins.
function document.resolve_link_text(db_path, raw_link)
    trimmed = string.gsub(raw_link, "^%s*(.-)%s*$", "%1")
    target_id = document.resolve_link(db_path, nil, trimmed)
    if target_id != nil then
        return target_id
    end
    subject, title = document.parse_link_ref(trimmed)
    if subject == nil then
        return nil
    end
    return document.resolve_link(db_path, subject, title)
end

-- The one link grammar, shared by indexing (sync_links) and rendering
-- (inline_links_to_markdown) so the two can never disagree: [[...]] on
-- a single line, with no brackets inside. An unclosed [[ therefore
-- matches nothing -- plain text on the page, never an index row --
-- instead of swallowing everything up to the next ]].
LINK_PATTERN = "%[%[([^%[%]\n]+)%]%]"

-- How a document is written as a link, or nil if it can't be: the
-- grammar has no escaping, so a title containing a bracket or a newline
-- can't be linked at all. A "/" is fine -- resolve_link_text tries the
-- whole text as a title before reading it as "subject/title". A
-- title shared with another document gets its parent folder's title in
-- front ("[[folder/title]]", resolve_link's one-level disambiguator),
-- and nil if even that doesn't pick this document out. Used wherever
-- something writes a link to a known document on someone's behalf --
-- the "Explain connection" prefill, the agent's connection documents.
function document.link_ref(db_path, document_id)
    doc = entity.get(db_path, "document", tonumber(document_id))
    if doc == nil or doc.title == nil or string.find(doc.title, "[%[%]\n]") != nil then
        return nil
    end
    if tonumber(document.resolve_link_text(db_path, doc.title)) == tonumber(document_id) then
        return "[[" .. doc.title .. "]]"
    end
    if doc.parent_id == nil or doc.parent_id == "" then
        return nil
    end
    parent = entity.get(db_path, "document", tonumber(doc.parent_id))
    if parent == nil or string.find(parent.title, "[/%[%]\n]") != nil then
        return nil
    end
    if tonumber(document.resolve_link_text(db_path, parent.title .. "/" .. doc.title)) == tonumber(document_id) then
        return "[[" .. parent.title .. "/" .. doc.title .. "]]"
    end
    return nil
end

-- Bytes, not characters -- document.clip_text backs off to a UTF-8
-- boundary rather than splitting a multi-byte character.
CONTEXT_MAX_LENGTH = 500

-- Trims, and caps at CONTEXT_MAX_LENGTH; nil for blank text.
function document.clip_text(text)
    if text == nil then
        return nil
    end
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil
    end
    if #text <= CONTEXT_MAX_LENGTH then
        return text
    end
    cut = CONTEXT_MAX_LENGTH
    -- 0x80-0xBF is a UTF-8 continuation byte -- never cut right before one.
    while cut > 1 and string.byte(text, cut + 1) != nil and string.byte(text, cut + 1) >= 0x80 and string.byte(text, cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return string.sub(text, 1, cut) .. "..."
end

-- The author's own words around a [[link]] -- why the two documents are
-- connected, read straight from content whenever it's shown (never
-- stored). The sentence containing the link's first occurrence, with
-- list/heading/quote/table markup stripped and every [[x]] flattened to
-- x. A link standing alone (a bare bullet in a list of links) has no
-- sentence worth quoting, so it falls back to the nearest heading above
-- it, which is usually what groups the list ("## Related meetings").
-- nil when neither says anything.
function document.link_context(content, raw_link)
    if content == nil then
        return nil
    end
    marker = "[[" .. raw_link .. "]]"
    start_pos = string.find(content, marker, 1, true)
    if start_pos == nil then
        return nil
    end

    line_start = start_pos
    while line_start > 1 and string.sub(content, line_start - 1, line_start - 1) != "\n" do
        line_start = line_start - 1
    end
    line_end = string.find(content, "\n", start_pos, true)
    if line_end == nil then
        line_end = #content
    else
        line_end = line_end - 1
    end
    line = string.sub(content, line_start, line_end)
    offset = start_pos - line_start + 1

    -- Sentence boundary = terminal punctuation followed by whitespace,
    -- so "v1.2" or "e.g.x" don't split mid-sentence.
    sentence_start = 1
    search_from = 1
    while true do
        boundary_start, boundary_end = string.find(line, "[%.!?]%s", search_from)
        if boundary_start == nil or boundary_start >= offset then
            break
        end
        sentence_start = boundary_end + 1
        search_from = boundary_end + 1
    end
    sentence_end = #line
    boundary_start = string.find(line, "[%.!?]%s", offset + #marker)
    if boundary_start != nil then
        sentence_end = boundary_start
    end
    sentence = document.clean_link_context(string.sub(line, sentence_start, sentence_end))

    -- Anything left once every [[link]] and all punctuation/space is
    -- removed? Byte count, not %a -- %a is ASCII-only and would treat
    -- a non-Latin sentence as empty.
    residue = ""
    if sentence != nil then
        residue = string.gsub(string.gsub(sentence, LINK_PATTERN, ""), "[%s%p]", "")
    end
    if #residue >= 3 then
        return document.clip_text((string.gsub(sentence, LINK_PATTERN, "%1")))
    end

    heading = nil
    for heading_line in string.gmatch(string.sub(content, 1, line_start - 1), "[^\n]+") do
        heading_text = string.match(heading_line, "^%s*#+%s+(.-)%s*$")
        if heading_text != nil and heading_text != "" then
            heading = heading_text
        end
    end
    if heading == nil then
        return nil
    end
    return document.clip_text("Listed under \"" .. string.gsub(heading, LINK_PATTERN, "%1") .. "\"")
end

-- Strips the line-level Markdown a sentence pulled from mid-document
-- may still carry -- list bullets/numbers, heading hashes, blockquote
-- markers, table pipes -- and collapses whitespace.
function document.clean_link_context(text)
    text = string.gsub(text, "^%s*>%s*", "")
    text = string.gsub(text, "^%s*#+%s+", "")
    text = string.gsub(text, "^%s*[-*+]%s+%[[ xX]%]%s+", "")
    text = string.gsub(text, "^%s*[-*+]%s+", "")
    text = string.gsub(text, "^%s*%d+[.)]%s+", "")
    text = string.gsub(text, "|", " ")
    text = string.gsub(text, "%s+", " ")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil
    end
    return text
end

-- Records that `from_id`'s content holds [[link_text]]. A new link text
-- inserts at BASE_LINK_STRENGTH; one this document already had (active
-- or archived) is unarchived and has its to_document_id healed if it
-- was dangling and now resolves -- a retyped link comes back at its old
-- strength, never reset.
function document.upsert_link(db_path, from_id, to_id, link_text)
    link_hash = document.link_hash(link_text)
    rows = db.query(db_path, string.format(
        "SELECT id, to_document_id FROM document_link WHERE from_document_id = %d AND link_hash = %s;",
        tonumber(from_id), db.quote(link_hash)
    ))
    if rows == nil or #rows == 0 then
        db.exec(db_path, string.format(
            "INSERT INTO document_link (from_document_id, to_document_id, link_text, link_hash, created_at) VALUES (%d, %s, %s, %s, %s);",
            tonumber(from_id), db.literal(to_id), db.quote(link_text), db.quote(link_hash), db.now_expr(db_path)
        ))
        return
    end
    healed_to_id = sql_null_to_nil(rows[1].to_document_id)
    if healed_to_id == nil then
        healed_to_id = to_id
    end
    db.exec(db_path, string.format(
        "UPDATE document_link SET archived_at = NULL, to_document_id = %s WHERE id = %d;",
        db.literal(healed_to_id), tonumber(rows[1].id)
    ))
end

-- Makes `document_id`'s rows match its content: every [[link]] in it
-- goes through document.upsert_link; every active row whose link text
-- no longer appears is archived, not deleted, so raw_strength survives
-- the link being retyped later.
function document.sync_links(db_path, document_id, content)
    if content == nil then
        content = ""
    end
    seen = {}
    ordered = {}
    for raw_link in string.gmatch(content, LINK_PATTERN) do
        if seen[raw_link] == nil then
            seen[raw_link] = true
            table.insert(ordered, raw_link)
        end
    end

    existing = db.query(db_path, string.format(
        "SELECT id, link_text FROM document_link WHERE from_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        tonumber(document_id)
    ))
    if existing == nil then
        existing = {}
    end
    for _, row in ipairs(existing) do
        if seen[row.link_text] == nil then
            db.exec(db_path, string.format(
                "UPDATE document_link SET archived_at = %s WHERE id = %d;", db.now_expr(db_path), tonumber(row.id)
            ))
        end
    end

    for _, raw_link in ipairs(ordered) do
        document.upsert_link(db_path, document_id, document.resolve_link_text(db_path, raw_link), raw_link)
    end
end

-- Documents linked to/from `document_id` (both directions, self never
-- included since document_link never stores a self-loop) -- the graph
-- knowledge.lua's spreading-activation pass reinforces when a document
-- is actually retrieved, on top of the retrieved document's own heat
-- bump (see doc/architecture.md's "Knowledge pool" section, "Spreading
-- activation", and doc/link-strength-redesign.md for raw_strength).
--
-- GROUP BY id, SUM(raw_strength) rather than a bare UNION (dedup on
-- the whole row) -- with only an id column, UNION's row-level dedup
-- already collapsed a neighbor connected by two distinct document_link
-- rows (e.g. a link each way) down to one; adding
-- raw_strength as a second column would silently break that once two
-- such rows carry different strengths, since UNION would then see them
-- as two different rows instead of duplicates. Aggregating explicitly
-- keeps one row per neighbor id either way, with the rare double-link
-- case's strengths summed into one total instead of ambiguously
-- picking one.
function document.linked_neighbors(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT id, SUM(raw_strength) AS raw_strength FROM (
            SELECT to_document_id AS id, raw_strength FROM document_link WHERE from_document_id = %d AND to_document_id IS NOT NULL AND (archived_at IS NULL OR archived_at = '')
            UNION ALL
            SELECT from_document_id AS id, raw_strength FROM document_link WHERE to_document_id = %d AND (archived_at IS NULL OR archived_at = '')
        ) AS neighbor_links
        GROUP BY id;
    """, tonumber(document_id), tonumber(document_id)))
    if rows == nil then
        return {}
    end
    return rows
end

-- Backs /knowledge-graph-data (doc/knowledge-graph-explorer.md, Phase
-- 2): every document_link edge whose two endpoints are both active
-- documents, as flat (from, to, strength) rows for the graph explorer
-- to draw directly -- unlike linked_neighbors, this isn't scoped to
-- one document's own local neighbor set, so there's no SUM-by-id
-- aggregation here; a pair connected by two distinct document_link
-- rows (a link each way, or two spellings of the same target) comes
-- back as two edges, drawn as two lines, rather than merged into
-- one -- a Phase 4 open question (doc/knowledge-graph-explorer.md), not
-- resolved here.
function document.graph_edges(db_path)
    rows = db.query(db_path, """
        SELECT dl.from_document_id AS from_id, dl.to_document_id AS to_id, dl.raw_strength AS strength
        FROM document_link dl
        JOIN document d1 ON d1.id = dl.from_document_id
        JOIN document d2 ON d2.id = dl.to_document_id
        WHERE dl.to_document_id IS NOT NULL
          AND (dl.archived_at IS NULL OR dl.archived_at = '')
          AND (d1.archived_at IS NULL OR d1.archived_at = '') AND d1.merged_into IS NULL
          AND (d2.archived_at IS NULL OR d2.archived_at = '') AND d2.merged_into IS NULL;
    """)
    if rows == nil then
        return {}
    end
    edges = {}
    for _, row in ipairs(rows) do
        table.insert(edges, {from = tonumber(row.from_id), to = tonumber(row.to_id), strength = tonumber(row.strength)})
    end
    return edges
end

-- ACT-R's "spreading activation": a retrieved document reinforces its
-- own heat directly (document.reinforcement_delta), but relevance
-- doesn't stop at the exact document that matched a query -- its
-- linked neighbors (document.linked_neighbors) get a smaller
-- reinforcement too. Diluted by each neighbor's own share of this
-- document's total outgoing link strength (see doc/link-strength-
-- redesign.md) -- the "fan effect": a heavily-linked hub document
-- spreads its activation across every connection it has, so a neighbor
-- reached through a strong, frequently-co-retrieved edge gets a bigger
-- share than one reached through a rarely-reinforced edge, rather than
-- every neighbor getting an identical flat cut. Never exceeds the
-- direct hit's own delta even for a single neighbor (a single edge's
-- share of the total is at most 1, and SPREADING_ACTIVATION_FACTOR is
-- itself < 1) -- a linked neighbor's relevance is always a weaker
-- signal than actually being retrieved.
--
-- Backward-compatible degenerate case: with every edge still at
-- BASE_LINK_STRENGTH (1.0, unreinforced), total_strength = fan_count *
-- 1.0, so edge_strength / total_strength = 1 / fan_count -- identical
-- to the flat per-neighbor split this replaces. Behavior only diverges
-- once real, repeated co-retrieval differentiates one edge's strength
-- from its siblings'.
SPREADING_ACTIVATION_FACTOR = 0.35

function document.weighted_spreading_delta(base_delta, edge_strength, total_strength)
    if total_strength == nil or total_strength <= 0 then
        return 0
    end
    return (base_delta * SPREADING_ACTIVATION_FACTOR) * (tonumber(edge_strength) / total_strength)
end

-- Saving a document is just entity.create/update now: pool
-- registration, link sync and embedding all run from entity's own
-- document hooks (document.on_entity_created/on_entity_updated), so
-- every write path -- this one, the generic API/CLI, the agent's entity
-- tools -- gets them exactly once. Kept as the web save route's and the
-- agent document tool's shared entry point.
function document.create_page(db_path, author, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    return entity.create(db_path, "document", values, author, source)
end

function document.update_page(db_path, author, document_id, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    return entity.update(db_path, "document", document_id, values, author, source)
end

-- Every active link touching `document_id`, both directions, with the
-- other document's id/title and why they're connected -- the detail
-- view's "Connections" list and the agent's document.links. `direction`
-- is "out" (this document's content links to it) or "in" (its content
-- links here). `context` is the sentence around the link in whichever
-- document holds it (document.link_context), read from content now --
-- so a document written to explain a connection shows its explanation
-- here with nothing special about it. Outgoing dangling links (no
-- target yet) are left out -- the content already renders them as "not
-- created yet".
function document.links(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT 'out' AS direction, d.id AS id, d.title AS title, dl.link_text AS link_text,
               dl.raw_strength AS raw_strength, dl.created_at AS created_at, src.content AS holder_content
        FROM document_link dl
        JOIN document d ON d.id = dl.to_document_id
        JOIN document src ON src.id = dl.from_document_id
        WHERE dl.from_document_id = %d AND (dl.archived_at IS NULL OR dl.archived_at = '') AND (d.archived_at IS NULL OR d.archived_at = '')
        UNION ALL
        SELECT 'in' AS direction, d.id AS id, d.title AS title, dl.link_text AS link_text,
               dl.raw_strength AS raw_strength, dl.created_at AS created_at, d.content AS holder_content
        FROM document_link dl
        JOIN document d ON d.id = dl.from_document_id
        WHERE dl.to_document_id = %d AND (dl.archived_at IS NULL OR dl.archived_at = '') AND (d.archived_at IS NULL OR d.archived_at = '')
        ORDER BY title;
    """, tonumber(document_id), tonumber(document_id)))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.context = document.link_context(row.holder_content, row.link_text)
        row.holder_content = nil
    end
    return rows
end

-- A document explaining why two others are connected is an ordinary
-- document, whoever writes it -- a person via the Connections list's
-- "Explain connection" action, or the agent when two documents keep
-- being retrieved together (knowledge.evaluate_co_retrieval_pair). This
-- is the shared starting shape both use: title "A <-> B", content one
-- sentence linking both, so document.link_context shows the reason on
-- each side's Connections list. Filed under the Knowledge Pool folder,
-- where other notes about the pool live. nil if either document can't
-- be written as a link (document.link_ref).
CONNECTION_TITLE_SEPARATOR = " ↔ "

-- Whether a title has a connection document's shape; tag.lua counts such
-- a document as one edge between the two it links, not as two links.
function document.is_connection_title(title)
    if title == nil then
        return false
    end
    return string.find(title, CONNECTION_TITLE_SEPARATOR, 1, true) != nil
end

function document.connection_draft(db_path, document_a_id, document_b_id, reason)
    ref_a = document.link_ref(db_path, document_a_id)
    ref_b = document.link_ref(db_path, document_b_id)
    if ref_a == nil or ref_b == nil then
        return nil
    end
    doc_a = entity.get(db_path, "document", tonumber(document_a_id))
    doc_b = entity.get(db_path, "document", tonumber(document_b_id))
    if reason == nil then
        reason = ""
    end
    return {
        title = doc_a.title .. CONNECTION_TITLE_SEPARATOR .. doc_b.title,
        content = ref_a .. " and " .. ref_b .. ": " .. reason,
        parent_id = document.ensure_knowledge_pool_folder(db_path),
    }
end


--------------------------------------------------------------------------
-- Rendering: Markdown -> HTML via cmark, "[[...]]" -> inline links
--------------------------------------------------------------------------

-- Rewrites every "[[...]]" occurrence into a plain CommonMark link
-- (resolved) or an unlinked, clearly-marked placeholder (dangling) --
-- ordinary Markdown either way, so cmark itself needs no special
-- handling for this project's own link syntax.
function document.inline_links_to_markdown(db_path, content)
    return (string.gsub(content, LINK_PATTERN, function(raw_link)
        target_id = document.resolve_link_text(db_path, raw_link)
        if target_id != nil then
            return "[" .. raw_link .. "](document?entity_id=" .. tostring(target_id) .. ")"
        end
        return "*" .. raw_link .. "* _(not created yet)_"
    end))
end

-- Shells out to cmark-gfm (CommonMark + GitHub's table/strikethrough/
-- autolink extensions, not vendored/hand-rolled) rather than writing a
-- Markdown parser -- same reasoning as bcrypt/hmac: prefer a small,
-- battle-tested existing implementation. Content goes through a temp
-- file, not shell-interpolated directly -- the only shell-interpolated
-- value is a path this process generated itself, never anything from
-- the document's own content. Requires `cmark-gfm` on PATH at runtime
-- (not statically linked into this binary the way bcrypt/hmac are --
-- a real external dependency, not bundled).
--
-- `cmark-gfm`, not plain `cmark` (the bare CommonMark reference
-- implementation): table syntax is a GFM *extension*, not core
-- CommonMark, and plain `cmark` has no `-e`/extension flag to add it.
-- `cmark-gfm` is a strict superset (same default output for everything
-- else already relied on) that adds table/strikethrough/autolink
-- support when explicitly enabled via `-e`.
--
-- Extensions deliberately NOT enabled: `--unsafe` (raw HTML rendering)
-- and its own `tagfilter` extension (which only filters *within*
-- `--unsafe` mode) -- cmark-gfm's default (non-unsafe) mode still
-- strips raw HTML blocks/inline HTML from the input, exactly the
-- safety property wanted here: document content is user-authored and
-- shown to other users, so it must never be able to inject a raw
-- <script> or event handler.
function document.render_markdown(content)
    if content == nil or content == "" then
        return ""
    end
    html, _ = external_tool.with_temp_file(content, "w", function(tmp_path)
        return external_tool.capture("cmark-gfm -e table -e strikethrough -e autolink " .. external_tool.shell_quote(tmp_path))
    end)
    if html == nil then
        html = ""
    end
    return document.render_plot_fences(html)
end

-- Max chars returned to the chat agent for one attachment -- roughly
-- the same order of magnitude as agent.estimate_tokens' chars/4 budget
-- heuristic (agent.lua) already used for compaction decisions. A whole
-- large PDF dumped into one turn's context is exactly the kind of thing
-- that budget is meant to guard against.
ATTACHMENT_TEXT_MAX_CHARS = 20000

-- Chat-widget file attachments (`/api/chat-widget-attach`, cgi.lua) --
-- "documents for context," not vision/images and not a real platform
-- Document: the extracted text is folded into that one turn's outgoing
-- message client-side and never persisted as its own row anywhere.
-- Only PDF/.docx for now (the two most common cases) rather than a
-- general office-format converter -- anything else is a clear,
-- immediate error instead of a best-effort partial extraction.
--
-- Unlike render_markdown's silent "" on failure, this returns an
-- explicit nil, err -- an attachment failure has to be visible to the
-- user, not swallowed into an empty-context turn. Gated by
-- config.platform_config().chat_attachments_enabled at the route level
-- (cgi.lua) -- this function itself just extracts text; it doesn't
-- know or care whether the feature is turned on for this deployment.
function document.extract_attachment_text(filename, data)
    if filename == nil then
        return nil, "No filename given."
    end
    extension_match = string.match(filename, "%.([^.]+)$")
    extension = ""
    if extension_match != nil then
        extension = string.lower(extension_match)
    end
    if extension != "pdf" and extension != "docx" then
        return nil, "Unsupported file type -- only PDF and .docx are supported right now."
    end

    binary = "pandoc"
    if extension == "pdf" then
        binary = "pdftotext"
    end
    if external_tool.available(binary) == false then
        return nil, binary .. " is not installed on this deployment."
    end

    text, _ = external_tool.with_temp_file(data, "wb", function(tmp_path)
        -- -f docx is required, not optional: os.tmpname() produces an
        -- extensionless path, and pandoc otherwise guesses input
        -- format from the filename -- with no extension to go on it
        -- silently falls back to "markdown" and tries to parse the raw
        -- docx (zip) binary as text, producing garbage instead of an
        -- error (confirmed directly: without -f docx this returns
        -- literal "PK..." noise).
        if extension == "pdf" then
            return external_tool.capture("pdftotext " .. external_tool.shell_quote(tmp_path) .. " - 2>/dev/null")
        end
        return external_tool.capture("pandoc -f docx -t plain " .. external_tool.shell_quote(tmp_path) .. " 2>/dev/null")
    end)

    if text == nil then
        return nil, "Could not extract text from this file."
    end
    if string.len(text) > ATTACHMENT_TEXT_MAX_CHARS then
        text = string.sub(text, 1, ATTACHMENT_TEXT_MAX_CHARS) ..
            "\n\n[...truncated, showing the first " .. tostring(ATTACHMENT_TEXT_MAX_CHARS) .. " characters...]"
    end
    return text
end

--------------------------------------------------------------------------
-- Plotting: ```plot``` fences -> gnuplot SVG
--------------------------------------------------------------------------
--
-- Deliberately NOT letting the agent/document author write raw gnuplot
-- script: gnuplot's own language can shell out (`system(...)`, `load`),
-- so free-form text reaching a real gnuplot process would be a real RCE
-- surface. Instead a ```plot``` fence holds a small, constrained JSON
-- data spec; document.plot_spec_to_gnuplot_cfg is the only thing that
-- turns it into a gnuplot.create(cfg) table, and every string that ends
-- up embedded in a generated `set title "..."`/`t "..."` command is run
-- through document.gnuplot_safe_string first, since gnuplot.lua's own
-- generate_code interpolates title/xlabel/ylabel/series-title strings
-- into double-quoted gnuplot commands with no escaping of its own --
-- an unescaped `"` in one of those strings would let a spec break out
-- of the string literal and inject arbitrary gnuplot commands.

-- Reverses cmark-gfm's HTML entity escaping of fenced code block
-- content. Order matters: the four specific entities first, `&amp;`
-- last -- reversing that order would turn a literal "&amp;lt;" (an
-- escaped ampersand followed by literal text "lt;") into "<" instead
-- of leaving it as the literal text "&lt;" it actually represents.
function document.html_unescape(s)
    if s == nil then
        return ""
    end
    s = string.gsub(s, "&lt;", "<")
    s = string.gsub(s, "&gt;", ">")
    s = string.gsub(s, "&quot;", "\"")
    s = string.gsub(s, "&#39;", "'")
    s = string.gsub(s, "&amp;", "&")
    return s
end

-- Strips the characters that would let a title/label string break out
-- of gnuplot.lua's own unescaped `"..."` command interpolation (a bare
-- `"` ends the string literal early; a `\` can start an escape gnuplot
-- itself interprets). Chart labels have no legitimate need for either.
function document.gnuplot_safe_string(s)
    if s == nil then
        return ""
    end
    s = tostring(s)
    s = string.gsub(s, "[\"\\]", "")
    s = string.gsub(s, "[\r\n]", " ")
    return s
end

PLOT_TYPE_TO_WITH = {line = "linespoints", scatter = "points", bar = "boxes"}

-- Pure translation from the fence's JSON spec into the table shape
-- gnuplot.create expects -- no file I/O, no shelling out, so it's
-- unit-testable on its own. Returns (cfg, nil) on success or
-- (nil, error_message) if the spec is malformed.
function document.plot_spec_to_gnuplot_cfg(spec)
    if spec == nil or type(spec) != "table" then
        return nil, "plot spec must be a JSON object"
    end
    if spec.series == nil or type(spec.series) != "table" or #spec.series == 0 then
        return nil, "plot spec needs a non-empty \"series\" array"
    end

    default_with = PLOT_TYPE_TO_WITH[spec.type]
    if default_with == nil then
        default_with = "linespoints"
    end

    data = {}
    for i, series in ipairs(spec.series) do
        if series.x == nil or type(series.x) != "table" or series.y == nil or type(series.y) != "table" then
            return nil, "series " .. tostring(i) .. " needs \"x\" and \"y\" arrays"
        end
        if #series.x != #series.y then
            return nil, "series " .. tostring(i) .. "'s \"x\" and \"y\" arrays must be the same length"
        end
        for j = 1, #series.x do
            if type(series.x[j]) != "number" or type(series.y[j]) != "number" then
                return nil, "series " .. tostring(i) .. "'s \"x\"/\"y\" values must all be numbers"
            end
        end

        series_with = default_with
        if series.with != nil then
            series_with = document.gnuplot_safe_string(series.with)
        end
        series_title = "series " .. tostring(i)
        if series.name != nil then
            series_title = document.gnuplot_safe_string(series.name)
        end
        table.insert(data, {{series.x, series.y}, with = series_with, title = series_title})
    end

    cfg = {type = "svg", width = 640, height = 400, grid = true, data = data}
    if spec.title != nil then
        cfg.title = document.gnuplot_safe_string(spec.title)
    end
    if spec.xlabel != nil then
        cfg.xlabel = document.gnuplot_safe_string(spec.xlabel)
    end
    if spec.ylabel != nil then
        cfg.ylabel = document.gnuplot_safe_string(spec.ylabel)
    end

    return cfg, nil
end

-- Renders one JSON spec (already HTML-unescaped, already JSON-decoded)
-- into a `<div class="platform-plot">` holding raw SVG markup, or a
-- visible error message on any failure. Never lets an exception here
-- crash the surrounding page.
function document.render_plot(spec_text)
    spec, _, decode_err = json.decode(spec_text)
    if spec == nil then
        return '<div class="platform-plot platform-plot-error">Could not render plot: invalid JSON.</div>'
    end

    cfg, cfg_err = document.plot_spec_to_gnuplot_cfg(spec)
    if cfg == nil then
        return '<div class="platform-plot platform-plot-error">Could not render plot: ' .. tostring(cfg_err) .. '.</div>'
    end

    plot = gnuplot.create(cfg)
    out_path = os.tmpname()
    ok, gnuplot_output, script_path = gnuplot.savefig(plot, out_path)
    if script_path != nil then
        os.remove(script_path)
    end
    if ok != true then
        os.remove(out_path)
        return '<div class="platform-plot platform-plot-error">Could not render plot: gnuplot failed.</div>'
    end

    file = io.open(out_path, "r")
    if file == nil then
        os.remove(out_path)
        return '<div class="platform-plot platform-plot-error">Could not render plot: no output produced.</div>'
    end
    svg = io.read(file, "*all")
    io.close(file)
    os.remove(out_path)
    if svg == nil or string.find(svg, "<svg", 1, true) == nil then
        return '<div class="platform-plot platform-plot-error">Could not render plot: no output produced.</div>'
    end

    return '<div class="platform-plot">' .. svg .. '</div>'
end

-- Post-processes cmark-gfm's rendered HTML, replacing every
-- `<pre><code class="language-plot">...</code></pre>` block (the exact
-- shape cmark-gfm emits for a fenced ```plot``` block) with a rendered
-- plot. Run over cmark's OUTPUT, never over the raw Markdown -- so this
-- only ever sees content cmark itself already decided was a code fence,
-- with cmark's own HTML-escaping already applied.
function document.render_plot_fences(html)
    return (string.gsub(html, '<pre><code class="language%-plot">(.-)</code></pre>', function(escaped_json)
        return document.render_plot(document.html_unescape(escaped_json))
    end))
end

-- The full pipeline: #tags into links to their tags (before "[[...]]",
-- whose text they mustn't touch), "[[...]]" refs into plain Markdown
-- links, then cmark once; a tag's link is then marked as a chip.
function document.render_html(db_path, content)
    if content == nil or content == "" then
        return ""
    end
    html = document.render_markdown(document.inline_links_to_markdown(db_path, tag.inline_text_tags(db_path, content)))
    html, _ = string.gsub(html, '<a href="detail%?type=tag&amp;entity_id=', '<a class="platform-tag-chip" href="detail?type=tag&amp;entity_id=')
    return html
end

--------------------------------------------------------------------------
-- Knowledge-pool scoring: tier/heat/dedup pure functions
--------------------------------------------------------------------------
--
-- Kept here, not in knowledge.lua, because tier/heat/content_hash are
-- columns on `document` itself -- these are the pure, DB-free
-- heuristics document.search_score/knowledge.lua's review pass both
-- need, kept alongside the data they score. knowledge.lua depends
-- on document.lua, never the reverse, so anything document.search
-- itself needs has to live here.

TIER_WEIGHT = {[0] = 0.0, [1] = 0.10, [2] = 0.20, [3] = 0.35}

-- Accessor (not the bare TIER_WEIGHT table) for cross-file use --
-- knowledge.lua reads this rather than TIER_WEIGHT directly, since a
-- bare global table isn't a reliable way to share data across this
-- codebase's per-module-isolated files (module-table fields are).
function document.tier_weight(tier)
    weight = TIER_WEIGHT[tonumber(tier)]
    if weight == nil then
        return 0.0
    end
    return weight
end

-- A fast, deterministic (not cryptographic -- dedup fingerprinting has
-- no adversarial threat model here) djb2-style hash, since no SHA1/MD5
-- binding is available in this Lua fork's stdlib. Kept within 2^32 so
-- the running total stays exactly representable in a Lua 5.1 double.
function document.content_hash(body)
    body = tostring(body)
    hash = 5381
    for i = 1, string.len(body) do
        hash = (hash * 33 + string.byte(body, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

-- A flat 0.15 plus the retrieved document's own tier weight -- the
-- amount a retrieval hit reinforces a document by, fed into
-- document.reinforce_pool_heat below (see doc/heat-decay-redesign.md).
function document.reinforcement_delta(tier)
    tier_weight = TIER_WEIGHT[tier]
    if tier_weight == nil then
        tier_weight = 0.0
    end
    return 0.15 + tier_weight
end

--------------------------------------------------------------------------
-- Conserved heat pool (see doc/heat-decay-redesign.md)
--------------------------------------------------------------------------
--
-- The only heat/relevance model as of the Phase 3 cutover -- the old
-- wall-clock decay (document.effective_heat/days_since,
-- platform_heat_decay_half_life_days) is gone; document.search_score
-- and knowledge.due_for_review both read pool_effective_heat below.
-- Plain archival and merge (duplicate_of/merged_into) both return a
-- departing document's heat to the pool -- see on_entity_archived/
-- on_entity_unarchived below for archival's dispatch (entity.archive/
-- unarchive are generic, so those are called from each call site, not
-- from inside entity.lua itself). BASE_HEAT itself is declared earlier,
-- alongside KNOWLEDGE_POOL_STATE_SCHEMA -- Luam requires a top-level
-- value like this to be declared before any function referencing it,
-- even elsewhere in the same file (a stricter static-scoping check
-- than vanilla Lua does).

-- Accessor for cross-file use, same reasoning as document.tier_weight
-- above (a bare global isn't reliably shared across this codebase's
-- per-module-isolated files).
function document.base_heat()
    return BASE_HEAT
end

-- The read-time view of a document's true current heat: however much
-- proportional shrink every *other* reinforcement/departure event has
-- applied to the shared pool_scale since this document's own row was
-- last written, captured in one multiplication. See "Avoiding an O(N)
-- write per retrieval" in doc/heat-decay-redesign.md for the derivation.
function document.pool_effective_heat(raw_heat, scale_at_write, pool_scale)
    raw_heat = tonumber(raw_heat)
    scale_at_write = tonumber(scale_at_write)
    pool_scale = tonumber(pool_scale)
    if raw_heat == nil or scale_at_write == nil or scale_at_write == 0 or pool_scale == nil then
        return BASE_HEAT
    end
    return raw_heat * (pool_scale / scale_at_write)
end

-- Reinforces `document_id` by `delta`, funded by a proportional shrink
-- of every *other* active document rather than manufacturing new heat.
-- O(1): touches only this document's row and the single shared state
-- row, never a scan across the rest of the pool.
--
-- Same-row concurrency: the final UPDATE below writes `raw_heat` as a
-- pure expression over the row's own *live* raw_heat/scale_at_write
-- (read by the UPDATE itself, at lock time), never as a value computed
-- once in Lua and written back absolute. Two concurrent reinforcements
-- of the same document_id therefore serialize on that row exactly like
-- any other `col = col + 1` update elsewhere in this codebase -- the
-- second one to commit sees the first one's already-applied delta and
-- adds its own on top, so neither delta is ever silently lost. The
-- shared pool_scale update further below has the identical shape for
-- the same reason (see "Concurrency" in doc/heat-decay-redesign.md).
--
-- What this does NOT make perfectly exact: `pool_scale` (the
-- multiplicative correction applied to the row's stale raw_heat before
-- adding delta) is still a snapshot read moments earlier, so under two
-- truly concurrent reinforcements of the same document, the second one
-- to commit may correct against a pool_scale that's a step behind the
-- first one's own contribution. That's a small, bounded, self-correcting
-- approximation (the next event against this row corrects it further),
-- the same tolerance already accepted for the shared row -- not a lost
-- reinforcement, which is the failure mode this fixes.
function document.reinforce_pool_heat(db_path, document_id, delta)
    document.ensure_pool_state(db_path)
    delta = tonumber(delta)
    if delta == nil then
        return nil
    end

    state_rows = db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
    if state_rows == nil or state_rows[1] == nil then
        return nil
    end
    log_pool_scale = tonumber(state_rows[1].log_pool_scale)
    document_count = tonumber(state_rows[1].document_count)
    pool_scale = math.exp(log_pool_scale)

    doc_rows = db.query(db_path, string.format(
        "SELECT raw_heat, scale_at_write FROM document WHERE id = %d;", tonumber(document_id)
    ))
    if doc_rows == nil or doc_rows[1] == nil then
        return nil
    end
    x_eff = document.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].scale_at_write, pool_scale)

    total = document_count * BASE_HEAT
    denominator = total - x_eff

    -- Exponential redistribution (doc/heat-decay-redesign.md, Phase 4):
    -- f = exp(-delta/denominator) stays in (0, 1) for ANY delta >= 0,
    -- by construction -- unlike the old f = 1 - delta/denominator,
    -- there is no delta that drives this negative or past zero, so no
    -- floor/clamp is needed. `extracted` (not the raw `delta`) is what
    -- X actually receives -- exact conservation falls out of the same
    -- substitution that makes f safe, not a separate clamp on both
    -- sides of the transfer.
    log_f = 0.0
    extracted = 0.0
    if denominator > 0 then
        log_f = -(delta / denominator)
        extracted = denominator * (1 - math.exp(log_f))
    end
    -- denominator <= 0: degenerate pool (one document, or a badly
    -- drifted total) -- nothing left to redistribute from. log_f/
    -- extracted stay 0: no shrink applied, X gets nothing extra
    -- either, matching "a single-document pool must hold x_eff
    -- exactly at BASE_HEAT forever."

    new_log_pool_scale = log_pool_scale + log_f
    new_pool_scale = math.exp(new_log_pool_scale)

    db.exec(db_path, string.format(
        "UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g WHERE id = 1;", log_f
    ))

    -- raw_heat is written as an expression over the row's own live
    -- columns (read by this UPDATE at lock time), not as a value
    -- computed once above and written back absolute -- see the
    -- function comment above for why that's what actually closes the
    -- same-row concurrency gap. Pure arithmetic (*, /, +) only -- the
    -- log-space value was already linearized above, so this needs no
    -- EXP()/LN() SQL function from either SQLite or MariaDB.
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = (raw_heat * (%.17g / scale_at_write)) + %.17g, scale_at_write = %.17g WHERE id = %d;",
        pool_scale, extracted, new_pool_scale, tonumber(document_id)
    ))

    -- Best-effort return value for callers/logging -- reflects this
    -- call's own read, which is exactly right in the common
    -- uncontended case, but nothing in this codebase reads it for a
    -- decision that depends on it being exact under a genuine race.
    return x_eff + extracted
end

-- The reverse of reinforce_pool_heat, for a document leaving the pool
-- (the merge/duplicate path, and plain archival via
-- on_entity_archived below). Returns the departing document's current
-- heat to the survivors, proportionally, and decrements document_count
-- -- both computed from the pre-departure state, per "Order matters
-- here" in doc/heat-decay-redesign.md.
function document.return_pool_heat(db_path, document_id)
    document.ensure_pool_state(db_path)

    state_rows = db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
    if state_rows == nil or state_rows[1] == nil then
        return
    end
    log_pool_scale = tonumber(state_rows[1].log_pool_scale)
    document_count = tonumber(state_rows[1].document_count)
    pool_scale = math.exp(log_pool_scale)

    doc_rows = db.query(db_path, string.format(
        "SELECT raw_heat, scale_at_write FROM document WHERE id = %d;", tonumber(document_id)
    ))
    if doc_rows == nil or doc_rows[1] == nil then
        return
    end
    x_eff = document.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].scale_at_write, pool_scale)

    total = document_count * BASE_HEAT
    denominator = total - x_eff
    if document_count <= 1 or denominator <= 0 then
        -- Last document leaving, or a degenerate pool -- nothing left
        -- to redistribute onto. Just shrink the count.
        db.exec(db_path, "UPDATE knowledge_pool_state SET document_count = document_count - 1 WHERE id = 1;")
        return
    end

    -- This f (a departing document returning its heat to survivors,
    -- the reverse of reinforce_pool_heat above) is always strictly
    -- positive for document_count >= 2 -- guarded just above -- so
    -- math.log(f) is always safe here; it's the growth-side analogue
    -- of the shrink-side bug Phase 4 fixed, and doesn't share that bug
    -- (see doc/heat-decay-redesign.md, Phase 4).
    f = 1 + ((x_eff - BASE_HEAT) / denominator)
    db.exec(db_path, string.format(
        "UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g, document_count = document_count - 1 WHERE id = 1;",
        math.log(f)
    ))
end

-- Plain archival returns heat to the pool / re-registers on unarchive,
-- the same as the merge path above. entity.archive/unarchive are
-- generic (any entity_type), so these are type-checking dispatchers,
-- called from each call site right after a *successful* archive/
-- unarchive -- never from inside entity.lua itself, which must never
-- require document.lua (document.lua already requires entity.lua; the
-- reverse would be circular).
-- Called from entity.create's own single choke point (see the comment
-- there), for every entity_type, not just "document" -- filters here
-- the same way on_entity_archived/on_entity_unarchived do, so
-- entity.create itself never needs to know this hook is document-
-- specific. Covers every creation path uniformly (CLI create/create-
-- json, the v1 API, the agent's generic entity.create tool, extension
-- manifests, and document.create_page's own direct entity.create call)
-- -- document.create_page no longer calls register_pool_document
-- itself, since this hook now does it for that path too, exactly once.
--
-- Also where every new document's links and embedding get computed --
-- not document.create_page, so the generic entity paths get them too
-- instead of leaving the document invisible to backlinks/semantic search
-- until a `daat repair`. Embedding stays best-effort: a failed provider
-- call never fails the create.
--
-- A new document can also be the target a dangling [[link]] elsewhere
-- has been waiting for (document.resolve_dangling_links).
function document.on_entity_created(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_created(db_path, entity_id)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.register_pool_document(db_path, entity_id)
    doc = entity.get(db_path, "document", entity_id)
    if doc != nil then
        document.sync_links(db_path, entity_id, doc.content)
        reference.sync_document(db_path, entity_id, doc.title, doc.content)
        tag.sync_text_tags(db_path, entity_id, doc.content, doc.created_by)
    end
    document.resolve_dangling_links(db_path)
    document.queue_embedding(db_path, entity_id)
end

-- Points every active dangling link (to_document_id NULL -- its target
-- didn't exist when the link was written) at its target, if one now
-- resolves. Run whenever a document appears or is renamed, so a link
-- to a page created later heals on its own instead of waiting for the
-- linking document's own next save or a `daat repair links` -- the case
-- a bulk import hits every time a page links forward to one imported
-- after it. Re-resolves through document.resolve_link rather than
-- matching titles here, so "subject/title" disambiguation stays in one
-- place. Dangling rows are rare (a handful per deployment), so scanning
-- all of them per create is cheap.
function document.resolve_dangling_links(db_path)
    rows = db.query(db_path,
        "SELECT id, link_text FROM document_link WHERE to_document_id IS NULL AND (archived_at IS NULL OR archived_at = '');")
    if rows == nil then
        return
    end
    for _, row in ipairs(rows) do
        to_id = document.resolve_link_text(db_path, row.link_text)
        if to_id != nil then
            db.exec(db_path, string.format(
                "UPDATE document_link SET to_document_id = %d WHERE id = %d AND to_document_id IS NULL;",
                tonumber(to_id), tonumber(row.id)
            ))
        end
    end
end

-- entity.update's counterpart: re-syncs links on a content change,
-- re-embeds on a content or title change, and retries dangling links on
-- a rename or move (a new title, or a new parent for "subject/title",
-- can be what one was waiting for). `field_changes` is keyed by field
-- name.
function document.on_entity_updated(db_path, entity_type, entity_id, field_changes)
    if entity_type == "document_tag" then
        tag.on_membership_updated(db_path, entity_id, field_changes)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    if field_changes.content != nil or field_changes.title != nil then
        doc = entity.get(db_path, "document", entity_id)
        if doc != nil then
            reference.sync_document(db_path, entity_id, doc.title, doc.content)
        end
    end
    if field_changes.content != nil then
        doc = entity.get(db_path, "document", entity_id)
        if doc != nil then
            document.sync_links(db_path, entity_id, doc.content)
            tag.sync_text_tags(db_path, entity_id, doc.content, doc.updated_by, field_changes.content.old)
        end
    end
    if field_changes.title != nil or field_changes.parent_id != nil then
        document.resolve_dangling_links(db_path)
    end
    if field_changes.content != nil or field_changes.title != nil then
        document.queue_embedding(db_path, entity_id)
    end
end

function document.on_entity_archived(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_archived(db_path, entity_id, true)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.return_pool_heat(db_path, entity_id)
    -- Before drop_derived: it reads the vector it takes out of the centres.
    tag.on_document_archived(db_path, entity_id, true)
    document.drop_derived(db_path, entity_id)
end

function document.on_entity_unarchived(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_archived(db_path, entity_id, false)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.register_pool_document(db_path, entity_id)
    doc = entity.get(db_path, "document", entity_id)
    if doc != nil then
        document.sync_links(db_path, entity_id, doc.content)
        reference.sync_document(db_path, entity_id, doc.title, doc.content)
    end
    document.resolve_dangling_links(db_path)
    -- Its vector went with the archive (drop_derived); re-embedding puts
    -- it back into its tags' centres (document.refresh_embedding). One
    -- archived before drop_derived existed still has its row, though
    -- its vector already left the centres -- cleared so the refresh
    -- doesn't take it out a second time.
    db.exec(db_path, string.format("DELETE FROM document_embedding WHERE document_id = %d;", tonumber(entity_id)))
    document.queue_embedding(db_path, entity_id)
end

-- What an archived document leaves behind: rows derived from it, all
-- rebuilt on unarchive (document.on_entity_unarchived). Its outgoing
-- links are archived rather than deleted, so their raw_strength comes
-- back with them.
function document.drop_derived(db_path, document_id)
    document_id = tonumber(document_id)
    db.exec(db_path, string.format("DELETE FROM document_embedding WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_embedding_due WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_reference WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format(
        "UPDATE document_link SET archived_at = %s WHERE from_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        db.now_expr(db_path), document_id))
end

-- Tier is decided by content-processing maturity, not retrieval
-- frequency -- retrieval_count/effective_heat only decide whether a
-- document is *due for review* at all (knowledge.due_for_review); once
-- due, the tier depends on whether it's actually been worked on
-- (`revised`) and what shape that work produced (`content_shape`), not
-- how often it's been looked up (see doc/architecture.md's "Knowledge
-- pool" section). Bidirectional: recomputed from scratch against the
-- CURRENT body every review, so a document edited back down to a
-- smaller/thinner shape genuinely drops back down. Duplicates never move.
function document.promotion_target_tier(tier, is_duplicate, revised, content_shape)
    if is_duplicate == true then
        return tier
    end
    if revised != true then
        return 0
    end
    if content_shape == "developed" then
        return 2
    end
    if content_shape == "atomic" then
        return 3
    end
    return 1
end

-- Naive whitespace-token count -- same "plain ASCII pattern matching,
-- no external tokenizer" style as content_hash/atomicity_status.
function document.word_count(body)
    body = tostring(body)
    count = 0
    for _ in string.gmatch(body, "%S+") do
        count = count + 1
    end
    return count
end

-- Four content shapes, replacing the old three-way atomicity_status:
-- "developed" (multi-section/long -- the SAME heading/paragraph
-- thresholds the old "needs-split" used, but now a *positive* Tier-2
-- signal: a fully-written-up, wiki-page-like article, not a problem to
-- flag), "atomic" (short, single-subject, definition-card-shaped --
-- Tier 3 territory), "thin" (too little content to be a genuine card
-- yet, regardless of revision), or "simple" (short-to-medium, not yet
-- multi-section -- Tier 1 territory). The 120-word ceiling for "atomic"
-- is sized like a glossary/flashcard definition plus one clarifying
-- sentence; the 6-word floor excludes bare fragments ("see below") from
-- being mistaken for a real one-line definition.
function document.content_shape(body)
    body = tostring(body)
    heading_count = 0
    for _ in string.gmatch(body, "\n#[^\n]*") do
        heading_count = heading_count + 1
    end
    if string.match(body, "^#") != nil then
        heading_count = heading_count + 1
    end

    paragraph_count = 0
    for para in string.gmatch(body .. "\n\n", "(.-)\n\n") do
        if string.match(para, "%S") != nil then
            paragraph_count = paragraph_count + 1
        end
    end

    words = document.word_count(body)

    if heading_count > 1 or paragraph_count > 6 then
        return "developed"
    end
    if heading_count <= 1 and paragraph_count <= 2 and words >= 6 and words <= 120 then
        return "atomic"
    end
    if words < 6 then
        return "thin"
    end
    return "simple"
end

-- Ledger query, not a new column: `entity_event` already records every
-- genuine create/update for every entity type, and review_retrieval's
-- own tier/title housekeeping writes go through raw `db.exec`, never
-- `entity.update` -- so this only ever reflects a real human/agent edit
-- made through document.update_page, never the review pipeline's own
-- writes.
function document.was_revised(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM entity_event WHERE entity_type = 'document' AND entity_id = %d AND event_type = 'update';",
        tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    return tonumber(rows[1].n) > 0
end

-- A document created by knowledge.distill (source_type == "distilled")
-- is, by construction, a deliberate rewrite -- that's strictly stronger
-- evidence of "processed" than one incidental ledger edit, so it
-- satisfies the revised gate without waiting for a second, separate
-- edit after creation. It must still independently pass
-- content_shape == "atomic" though -- provenance proves intent, not
-- that the actual output came out short and single-subject; a
-- rambling "distillation" doesn't get to skip the content check just
-- because of where it came from.
function document.processing_maturity(db_path, document_id, body, source_type)
    revised = (source_type == "distilled") or document.was_revised(db_path, document_id)
    return {revised = revised, content_shape = document.content_shape(body), word_count = document.word_count(body)}
end

function document.connectivity_status(peer_count)
    return "linked-" .. tostring(peer_count)
end

GENERIC_TITLES = {["note"] = true, ["untitled note"] = true, ["manual note"] = true, [""] = true, ["untitled"] = true}

function document.title_is_generic(title)
    if title == nil then
        return true
    end
    return GENERIC_TITLES[string.lower(strip_spaces(title))] == true
end

function strip_spaces(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- First non-heading line of body (heading lines are skipped entirely,
-- not stripped-and-used -- "# Heading\n\nFirst real line" guesses
-- "First real line", not "Heading"), with leading bullet/quote
-- decoration stripped, truncated to ~72 chars on a word boundary when
-- one exists past position 24 (short enough truncations just get a
-- hard cut rather than a barely-shorter one).
function document.guess_title_from_body(body)
    if body == nil then
        return "Untitled note"
    end
    for line in string.gmatch(body, "[^\n]+") do
        if string.match(line, "^%s*#") == nil then
            candidate = strip_spaces(string.gsub(line, "^[>%-%*%s]+", ""))
            if candidate != "" then
                if string.len(candidate) <= 72 then
                    return candidate
                end
                cut = string.find(string.sub(candidate, 1, 72), " [^ ]*$")
                if cut != nil and cut > 24 then
                    return string.sub(candidate, 1, cut - 1)
                end
                return string.sub(candidate, 1, 72)
            end
        end
    end
    return "Untitled note"
end

--------------------------------------------------------------------------
-- Semantic search
--------------------------------------------------------------------------
--
-- No real search index (see doc/architecture.md's "Documents" section
-- for why -- no FTS5 support in this project's SQLite binding), but no
-- full-content scan in Lua either: the O(n)-per-search scan did show up
-- once a SharePoint sync brought ~8,000 documents (30-120 s per search).
-- Lexical counting runs in SQL, and embeddings are read packed (see
-- document.pack_vector).

-- Binary as a hex literal (X'...'), which both backends read as raw
-- bytes -- never through db.quote, whose string escaping is for text.
function hex_literal(bytes)
    return "X'" .. string.gsub(bytes, ".", function(c) return string.format("%02x", string.byte(c)) end) .. "'"
end

-- The text a document's embedding was made from before the rules below
-- -- what a row with no text_hash (made before it existed) was made from.
function legacy_embedding_text(doc)
    text = doc.title
    if doc.content != nil and doc.content != "" then
        text = text .. "\n" .. doc.content
    end
    return text
end

-- A chat transcript's conversation: what the people and the agent said,
-- without tool calls or raw tool results (agent.all_messages(..., false),
-- the live chat view's own rendering). nil when it isn't a transcript.
function transcript_conversation(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT source_type, source_ref FROM document WHERE id = %d;", tonumber(document_id)))
    if rows == nil or rows[1] == nil or rows[1].source_type != "chat_session" or sql_null_to_nil(rows[1].source_ref) == nil then
        return nil
    end
    agent = require("agent")
    parts = {}
    for _, msg in ipairs(agent.all_messages(db_path, rows[1].source_ref, false)) do
        if (msg.role == "user" or msg.role == "assistant") and msg.content != nil and msg.content != "" then
            label = "User"
            if msg.role == "assistant" then
                label = "Assistant"
            end
            table.insert(parts, label .. ": " .. msg.content)
        end
    end
    return table.concat(parts, "\n\n")
end

-- The text a document's embedding is made from: what the document is
-- about, not where it came from. Its title and content, less every line
-- one of platform.lua's embedding_skip patterns matches (a sync's own
-- header, a template's boilerplate) -- a SharePoint path and author in
-- every synced file drew documents together by folder, not subject
-- (2026-10-07). A chat transcript is embedded from its conversation
-- alone (transcript_conversation).
function embedding_text(db_path, doc)
    body = transcript_conversation(db_path, doc.id)
    if body == nil then
        body = doc.content
    end
    if body == nil then
        body = ""
    end
    patterns = config.platform_config().embedding_skip
    if patterns != nil and #patterns > 0 then
        kept = {}
        for line in string.gmatch(body .. "\n", "(.-)\n") do
            skip = false
            for _, pattern in ipairs(patterns) do
                if string.find(line, pattern) != nil then
                    skip = true
                    break
                end
            end
            if skip == false then
                table.insert(kept, line)
            end
        end
        body = table.concat(kept, "\n")
    end
    body = string.gsub(body, "^%s+", "")
    if body == "" then
        return doc.title
    end
    return doc.title .. "\n" .. body
end

function document.embedding_text(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil
    end
    return embedding_text(db_path, doc)
end

-- Computes and caches one document's embedding -- best-effort (see
-- DOCUMENT_EMBEDDING_SCHEMA's own comment). With if_changed, a document
-- whose stored vector was made from the same text by the same model is
-- left alone. -> true (embedded), false (unchanged), or nil, err.
function document.reindex_embedding(db_path, document_id, if_changed)
    agent_provider = require("agent_provider")
    json = require("dkjson")

    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    text = embedding_text(db_path, doc)

    model = agent_provider.embedding_model()
    if model == nil then
        return nil, "no embedding model: no agent_provider, or it has no embeddings"
    end
    text_hash = hmac.sha256("document_embedding", text)
    if if_changed == true then
        rows = db.query(db_path, string.format(
            "SELECT model, text_hash FROM document_embedding WHERE document_id = %d;", tonumber(document_id)))
        if rows != nil and rows[1] != nil and rows[1].model == model and rows[1].text_hash == text_hash then
            return false
        end
    end
    vector, err = agent_provider.embeddings(model, text)
    if vector == nil then
        return nil, err
    end

    packed = document.pack_vector(vector)
    packed_literal = "NULL"
    if packed != nil then
        packed_literal = hex_literal(packed)
    end
    db.exec(db_path, string.format(
        "%s document_embedding (document_id, model, vector_json, vector_packed, text_hash, updated_at) VALUES (%d, %s, %s, %s, %s, %s);",
        db.replace_into(db_path),
        tonumber(document_id), db.quote(model), db.quote(json.encode(vector)), packed_literal, db.quote(text_hash), db.now_expr(db_path)
    ))
    return true
end

-- Re-embeds a document if its text changed, then swaps the new vector
-- into its tags' centres and places it by nearest tag (tag.lua) -- the
-- tag upkeep a save used to do, now done once the vector exists.
-- -> as document.reindex_embedding.
function document.refresh_embedding(db_path, document_id)
    old_vector = tag.document_vector(db_path, document_id)
    embedded, err = document.reindex_embedding(db_path, document_id, true)
    if embedded == true then
        tag.on_document_vector_changed(db_path, document_id, old_vector)
        tag.place_document(db_path, document_id)
    end
    return embedded, err
end

function utc_timestamp(seconds)
    return os.date("!%Y-%m-%d %H:%M:%S", seconds)
end

-- Called by every save of a document's title or content: the embedding
-- waits for the quiet period (DOCUMENT_EMBEDDING_SCHEMA's comment). A
-- later save moves queued_at forward, so the wait restarts.
function document.queue_embedding(db_path, document_id)
    if config.platform_config().embedding_quiet_minutes == 0 then
        document.refresh_embedding(db_path, document_id)
        return
    end
    db.exec(db_path, string.format(
        "%s document_embedding_due (document_id, queued_at) VALUES (%d, %s);",
        db.replace_into(db_path), tonumber(document_id), db.quote(utc_timestamp(os.time()))))
end

-- `daat document embed-pending`: embeds every queued document that has
-- gone embedding_quiet_minutes without a save. A document archived
-- since it was queued is dropped from the queue; one whose call failed
-- stays for the next run. -> {embedded, unchanged, failed, dropped,
-- waiting}.
function document.embed_pending(db_path)
    quiet_minutes = config.platform_config().embedding_quiet_minutes
    cutoff = utc_timestamp(os.time() - quiet_minutes * 60)
    rows = db.query(db_path, string.format("""
        SELECT q.document_id, q.queued_at, d.id AS live_id FROM document_embedding_due q
        LEFT JOIN document d ON d.id = q.document_id AND (d.archived_at IS NULL OR d.archived_at = '')
        WHERE q.queued_at <= %s ORDER BY q.queued_at;""", db.quote(cutoff)))
    if rows == nil then
        rows = {}
    end
    counts = {embedded = 0, unchanged = 0, failed = 0, dropped = 0, waiting = 0}
    for _, row in ipairs(rows) do
        document_id = tonumber(row.document_id)
        outcome = "dropped"
        if sql_null_to_nil(row.live_id) != nil then
            -- pcalled: a raised SQL error on one document mustn't stop
            -- the rest of the queue.
            ok, embedded = pcall(document.refresh_embedding, db_path, document_id)
            if ok == true and embedded == true then
                outcome = "embedded"
            elseif ok == true and embedded == false then
                outcome = "unchanged"
            else
                outcome = "failed"
            end
        end
        counts[outcome] = counts[outcome] + 1
        if outcome != "failed" then
            -- Only if not saved again meanwhile (queued_at unchanged).
            db.exec(db_path, string.format(
                "DELETE FROM document_embedding_due WHERE document_id = %d AND queued_at = %s;",
                document_id, db.quote(row.queued_at)))
        end
    end
    waiting = db.query(db_path, "SELECT COUNT(*) AS n FROM document_embedding_due;")
    if waiting != nil and waiting[1] != nil then
        counts.waiting = tonumber(waiting[1].n) - counts.failed
    end
    -- New vectors moved the tags' centres: the tags themselves may now
    -- want a split, merge or new label (tag_upkeep.lua). pcalled: a
    -- failure there mustn't undo the embedding work reported above.
    counts.upkeep = {}
    if counts.embedded > 0 and config.platform_config().tag_restructure == true then
        ok, report = pcall(require("tag_upkeep").run, db_path, {judge = true, apply = true})
        if ok then
            counts.upkeep = report
        else
            counts.upkeep = {"tag upkeep failed: " .. tostring(report)}
        end
    end
    return counts
end

-- Rebuilds vector_packed from vector_json -- no provider calls, just a
-- re-encoding of what's stored (rows saved before vector_packed existed
-- are searched via a slower JSON fallback until this runs). Returns the
-- number of rows packed.
function document.repack_all_embeddings(db_path)
    json = require("dkjson")
    rows = db.query(db_path, "SELECT document_id, vector_json FROM document_embedding WHERE vector_packed IS NULL;")
    packed_count = 0
    if rows == nil then
        return 0
    end
    for _, row in ipairs(rows) do
        decoded, _, _ = json.decode(row.vector_json)
        packed = document.pack_vector(decoded)
        if packed != nil then
            db.exec(db_path, string.format("UPDATE document_embedding SET vector_packed = %s WHERE document_id = %d;",
                hex_literal(packed), tonumber(row.document_id)))
            packed_count = packed_count + 1
        end
    end
    return packed_count
end

-- The document.sync_links equivalent of reindex_embedding above --
-- `daat repair links`, for documents whose content reached the table
-- without going through entity.create/update (a raw SQL insert, a
-- restored backup) and so never had their links registered.
function document.resync_links(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    document.sync_links(db_path, document_id, doc.content)
    return true
end

function document.resync_all_links(db_path)
    resynced = 0
    for _, row in ipairs(document.all_active(db_path)) do
        document.resync_links(db_path, row.id)
        resynced = resynced + 1
    end
    return resynced
end

-- Every active document whose embedding is missing, from another model
-- than the current one, or made from other text; with `all`, every
-- active document. A row from before text_hash existed (NULL) was made
-- from legacy_embedding_text: when today's rules give the same text it's
-- current, and only its hash is filled in (no provider call).
-- -> reindexed, failed, unchanged.
function document.reindex_all_embeddings(db_path, all)
    agent_provider = require("agent_provider")
    model = agent_provider.embedding_model()
    stored = {}
    rows = db.query(db_path, "SELECT document_id, model, text_hash FROM document_embedding;")
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        stored[tonumber(row.document_id)] = row
    end
    reindexed = 0
    failed = 0
    unchanged = 0
    for _, doc in ipairs(document.all_active(db_path)) do
        row = stored[tonumber(doc.id)]
        legacy_current = false
        if all != true and row != nil and row.model == model and sql_null_to_nil(row.text_hash) == nil then
            current = entity.get(db_path, "document", doc.id)
            if current != nil then
                text = embedding_text(db_path, current)
                if text == legacy_embedding_text(current) then
                    db.exec(db_path, string.format("UPDATE document_embedding SET text_hash = %s WHERE document_id = %d;",
                        db.quote(hmac.sha256("document_embedding", text)), tonumber(doc.id)))
                    legacy_current = true
                end
            end
        end
        if legacy_current then
            unchanged = unchanged + 1
        else
            if_changed = all != true and row != nil and row.model == model
            ok, err = document.reindex_embedding(db_path, doc.id, if_changed)
            if ok == true then
                reindexed = reindexed + 1
            elseif ok == false then
                unchanged = unchanged + 1
            else
                failed = failed + 1
            end
        end
    end
    return reindexed, failed, unchanged
end

function escape_pattern(text)
    return (string.gsub(text, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- Function words dropped from a search query before lexical scoring.
-- Found live: the agent writes queries like "passage OR subculture OR
-- degradation" -- every "or" then matched as a substring of nearly every
-- document ("for", "work", "procedure"), thousands of times in a long
-- PDF, and buried the real hits under whichever documents were longest.
SEARCH_STOPWORDS = {}
for _, word in ipairs({
    "a", "an", "and", "or", "not", "the", "of", "in", "on", "at", "to", "for", "from", "by", "with",
    "into", "about", "as", "is", "are", "was", "were", "be", "been", "it", "its", "this", "that",
    "these", "those", "what", "which", "who", "how", "when", "where", "why", "do", "does", "did",
    "we", "our", "you", "your", "any", "all", "there", "their", "than", "then", "vs",
}) do
    SEARCH_STOPWORDS[word] = true
end

SEARCH_MAX_TERMS = 8

-- Lowercased query words, edge punctuation stripped (quotes, brackets,
-- a trailing comma or '?', the '*' a model sometimes sends as "match
-- anything") but inner punctuation kept, since identifiers like
-- "rt-qpcr" or "c.cot.m-1d" are exactly what people search for here.
-- Stopwords, one-character fragments and repeats are dropped.
function document.query_terms(query_text)
    terms = {}
    if query_text == nil then
        return terms
    end
    seen = {}
    for word in string.gmatch(string.lower(query_text), "%S+") do
        word = string.gsub(word, "^[%p]+", "")
        word = string.gsub(word, "[%p]+$", "")
        if string.len(word) > 1 and SEARCH_STOPWORDS[word] == nil and seen[word] == nil and #terms < SEARCH_MAX_TERMS then
            seen[word] = true
            table.insert(terms, word)
        end
    end
    return terms
end

-- A LIKE pattern matching `term` anywhere, with LIKE's own wildcards
-- escaped -- paired with ESCAPE '!' at the call site, which both
-- backends accept (MySQL's default escape is a backslash, SQLite has
-- none, so neither default works for both).
function like_anywhere(term)
    escaped = string.gsub(term, "([!%%_])", "!%1")
    return db.quote("%" .. escaped .. "%")
end

-- SQL expression for how many times `term` (already lowercase) occurs
-- in `column`: the length lost by deleting every occurrence, divided by
-- the term's own length. Plain LENGTH/LOWER/REPLACE, so it means the
-- same on SQLite and MySQL (byte vs. character LENGTH doesn't matter --
-- all three LENGTHs use the same unit).
function occurrence_count_sql(column, term)
    lowered = "LOWER(COALESCE(" .. column .. ", ''))"
    quoted = db.quote(term)
    return string.format("((LENGTH(%s) - LENGTH(REPLACE(%s, %s, ''))) / LENGTH(%s))", lowered, lowered, quoted, quoted)
end

-- A document is searchable unless archived or folded into a canonical
-- duplicate (it would compete with its own canonical for the same
-- slot). Never by kind: a chat transcript, a distilled note and a
-- synced file are all knowledge on the same level, ranked by relevance
-- and usage (heat, tier) alone.
SEARCHABLE_DOCUMENT_WHERE = """
(d.archived_at IS NULL OR d.archived_at = '')
AND (d.merged_into IS NULL OR d.merged_into = '')
"""

SEARCH_RESULT_COLUMNS = """
d.id, d.title, d.tier, d.retrieval_count, d.raw_heat, d.scale_at_write,
d.source_type, d.source_id, d.content_hash, d.created_at, d.external_id
"""

-- How many candidates each ranking (lexical, semantic) contributes to
-- the fused list -- well past any `limit` a caller asks for, so fusion
-- has real overlap to work with.
SEARCH_CANDIDATES_PER_RANKING = 50
-- Reciprocal-rank-fusion constant (the standard 60): flattens the gap
-- between neighbouring ranks so neither ranking's #1 dominates alone.
SEARCH_RRF_K = 60
-- Cosine similarity at or below which an embedding match is not a
-- match at all -- an irrelevant document at the bottom of a results
-- list is still a wrong result.
SEARCH_SIMILARITY_FLOOR = 0.45
-- BM25's usual constants: term-frequency saturation and how strongly a
-- long document's counts are discounted for its length.
BM25_K1 = 1.2
BM25_B = 0.75
-- A query term in the title counts as this many content-weight hits'
-- worth of evidence, on top of the content score.
SEARCH_TITLE_WEIGHT = 2.0

-- How many documents get exact per-term counts (stage 2 below) after
-- the cheap presence pass narrows the field.
SEARCH_COUNTED_CANDIDATES = 200

-- Lexical ranking, computed in SQL in two stages, and never by reading
-- content into Lua. Found live: the previous version selected every
-- active document's full content and embedding (~290 MB in production)
-- into Lua on every call and counted substrings there, taking 30-120 s
-- per search; that, not the model, was most of what users saw as the
-- agent "sleeping".
--
-- Stage 1 asks only *whether* each term occurs (LIKE, which both
-- backends evaluate case-insensitively and which stops at the first
-- match) and ranks by the rarity-weighted share of terms present.
-- Stage 2 counts occurrences (LOWER + REPLACE over the whole text --
-- the expensive part, so only for the top SEARCH_COUNTED_CANDIDATES)
-- and ranks those by BM25 over content (saturating term frequency,
-- document length normalisation, rarer terms weighted higher) plus a
-- title bonus, so a 500-page PDF that mentions a common word 2,000
-- times no longer outranks a short note about exactly the thing asked
-- for.
function lexical_ranking(db_path, terms, query_text)
    if #terms == 0 then
        return {}
    end
    presence_columns = {}
    matches_any = {}
    for i, term in ipairs(terms) do
        content_like = "d.content LIKE " .. like_anywhere(term) .. " ESCAPE '!'"
        title_like = "d.title LIKE " .. like_anywhere(term) .. " ESCAPE '!'"
        table.insert(presence_columns, string.format("CASE WHEN %s THEN 1 ELSE 0 END AS p%d", content_like, i))
        table.insert(matches_any, title_like)
        table.insert(matches_any, content_like)
    end
    candidates = db.query(db_path, string.format("""
        SELECT %s, %s
        FROM document d
        WHERE %s AND (%s);
    """, SEARCH_RESULT_COLUMNS, table.concat(presence_columns, ", "), SEARCHABLE_DOCUMENT_WHERE, table.concat(matches_any, " OR ")))
    if candidates == nil or #candidates == 0 then
        return {}
    end

    total_rows = db.query(db_path, "SELECT COUNT(*) AS n FROM document d WHERE " .. SEARCHABLE_DOCUMENT_WHERE .. ";")
    total = tonumber(total_rows[1].n)
    document_frequency = {}
    for i = 1, #terms do
        document_frequency[i] = 0
    end
    for _, row in ipairs(candidates) do
        row.title_lower = ""
        if row.title != nil then
            row.title_lower = string.lower(row.title)
        end
        row.in_title = {}
        for i, term in ipairs(terms) do
            row.in_title[i] = string.find(row.title_lower, term, 1, true) != nil
            if tonumber(row["p" .. tostring(i)]) == 1 or row.in_title[i] == true then
                document_frequency[i] = document_frequency[i] + 1
            end
        end
    end
    idf = {}
    for i = 1, #terms do
        idf[i] = math.log(1 + (total - document_frequency[i] + 0.5) / (document_frequency[i] + 0.5))
    end
    lower_query = ""
    if query_text != nil then
        lower_query = string.lower(query_text)
    end

    -- Stage 1: presence only.
    for _, row in ipairs(candidates) do
        presence = 0
        for i = 1, #terms do
            if tonumber(row["p" .. tostring(i)]) == 1 then
                presence = presence + idf[i]
            end
            if row.in_title[i] == true then
                presence = presence + idf[i] * SEARCH_TITLE_WEIGHT
            end
        end
        row.lexical_score = presence
    end
    table.sort(candidates, function(a, b) return a.lexical_score > b.lexical_score end)
    counted = {}
    for i = 1, math.min(#candidates, SEARCH_COUNTED_CANDIDATES) do
        table.insert(counted, candidates[i])
    end

    -- Stage 2: occurrence counts for the survivors.
    count_columns = {}
    for i, term in ipairs(terms) do
        table.insert(count_columns, occurrence_count_sql("d.content", term) .. " AS c" .. tostring(i))
    end
    ids = {}
    by_id = {}
    for _, row in ipairs(counted) do
        table.insert(ids, tostring(tonumber(row.id)))
        by_id[tonumber(row.id)] = row
    end
    count_rows = db.query(db_path, string.format("SELECT d.id, LENGTH(COALESCE(d.content, '')) AS content_length, %s FROM document d WHERE d.id IN (%s);",
        table.concat(count_columns, ", "), table.concat(ids, ", ")))
    length_sum = 0
    if count_rows != nil then
        for _, count_row in ipairs(count_rows) do
            row = by_id[tonumber(count_row.id)]
            row.content_length = tonumber(count_row.content_length)
            for i = 1, #terms do
                row["c" .. tostring(i)] = tonumber(count_row["c" .. tostring(i)])
            end
        end
    end
    for _, row in ipairs(counted) do
        if row.content_length == nil then
            row.content_length = 0
        end
        length_sum = length_sum + row.content_length
    end
    -- Average over the counted candidates rather than the whole pool:
    -- one less full-table pass, and only the ratio between documents
    -- matters.
    average_length = math.max(length_sum / #counted, 1)

    for _, row in ipairs(counted) do
        score = 0
        length_norm = BM25_K1 * (1 - BM25_B + BM25_B * row.content_length / average_length)
        for i = 1, #terms do
            count = row["c" .. tostring(i)]
            if count != nil and count > 0 then
                score = score + idf[i] * (count * (BM25_K1 + 1)) / (count + length_norm)
            end
            if row.in_title[i] == true then
                score = score + idf[i] * SEARCH_TITLE_WEIGHT
            end
        end
        -- The whole multi-word query appearing verbatim in the title is
        -- the strongest single signal a lexical match can give.
        if #terms > 1 and lower_query != "" and string.find(row.title_lower, lower_query, 1, true) != nil then
            score = score * 1.5
        end
        row.lexical_score = score
    end
    table.sort(counted, function(a, b) return a.lexical_score > b.lexical_score end)
    return counted
end

-- Embedding vectors are stored twice: vector_json (the record of what
-- the provider returned, read by tag.lua and visible to entity.query)
-- and vector_packed, the same vector L2-normalised and packed as
-- little-endian float32 -- what search actually reads. ~4x smaller on
-- the wire than the JSON, decoded by one string.unpack instead of a JSON
-- parse (JSON decoding alone was ~9 s per search over ~8,000 documents),
-- and pre-normalised so similarity is a plain dot product.
function document.pack_vector(vector)
    if vector == nil or #vector == 0 then
        return nil
    end
    norm = 0.0
    for _, x in ipairs(vector) do
        norm = norm + x * x
    end
    if norm == 0.0 then
        return nil
    end
    norm = math.sqrt(norm)
    normalized = {}
    for i, x in ipairs(vector) do
        normalized[i] = x / norm
    end
    return string.pack("<" .. string.rep("f", #normalized), table.unpack(normalized))
end

function document.unpack_vector(packed)
    if packed == nil or packed == "" or string.len(packed) % 4 != 0 then
        return nil
    end
    values = {string.unpack("<" .. string.rep("f", string.len(packed) / 4), packed)}
    table.remove(values) -- string.unpack's trailing "next position"
    return values
end

function dot_product(v1, v2)
    if v1 == nil or v2 == nil or #v1 != #v2 then
        return 0.0
    end
    total = 0.0
    for i = 1, #v1 do
        total = total + v1[i] * v2[i]
    end
    return total
end

-- Semantic ranking: every searchable document's embedding against the
-- query's, keeping those above the similarity floor. Reads only
-- vector_packed; a row not yet packed (saved before the column existed,
-- until `daat repair embeddings-packed` runs) falls back to its JSON.
function semantic_ranking(db_path, query_vector, model)
    query_packed = document.pack_vector(query_vector)
    if query_packed == nil then
        return {}
    end
    query_unit = document.unpack_vector(query_packed)
    json = require("dkjson")
    rows = db.query(db_path, string.format("""
        SELECT e.document_id, e.vector_packed,
               CASE WHEN e.vector_packed IS NULL THEN e.vector_json END AS vector_json
        FROM document_embedding e
        JOIN document d ON d.id = e.document_id
        WHERE e.model = %s AND %s;
    """, db.quote(model), SEARCHABLE_DOCUMENT_WHERE))
    if rows == nil then
        return {}
    end
    ranked = {}
    for _, row in ipairs(rows) do
        unit = document.unpack_vector(row.vector_packed)
        if unit == nil and row.vector_json != nil then
            decoded, _, _ = json.decode(row.vector_json)
            unit = document.unpack_vector(document.pack_vector(decoded))
        end
        similarity = dot_product(query_unit, unit)
        if similarity > SEARCH_SIMILARITY_FLOOR then
            table.insert(ranked, {id = tonumber(row.document_id), similarity = similarity})
        end
    end
    table.sort(ranked, function(a, b) return a.similarity > b.similarity end)
    return ranked
end

-- Searches active documents by lexical and embedding relevance, fused by
-- reciprocal rank (a document near the top of both rankings beats one
-- at the top of only one; no score-scale tuning between the two), with
-- tier/heat reinforcement applied last as a bounded multiplier.
--
-- Found live: reinforcement used to be *added* -- tier_weight * 10 plus
-- effective heat, which reaches ~12 for the most-retrieved documents
-- against a relevance score of a few points -- so the same handful of
-- "hot" documents (a computational-neuroscience proceedings, a maths
-- software proceedings) came back for almost any query, which retrieved
-- them again and made them hotter. As a multiplier capped at +50%,
-- reinforcement still breaks near-ties between relevant documents but
-- can't carry an irrelevant one.
--
-- `use_semantic` (default true) computes the *query's* own embedding
-- fresh each call (one cheap API call); a document only contributes a
-- semantic match if it was already indexed (document.reindex_embedding).
-- Returns at most `limit` rows, each with its full content (for the
-- caller's excerpt and knowledge.lua's content_hash) and `score`.
function document.search(db_path, query_text, limit, use_semantic)
    if limit == nil then
        limit = 20
    end
    if use_semantic == nil then
        use_semantic = true
    end

    terms = document.query_terms(query_text)
    lexical = lexical_ranking(db_path, terms, query_text)

    semantic = {}
    if use_semantic == true and query_text != nil and query_text != "" then
        agent_provider = require("agent_provider")
        model = agent_provider.embedding_model()
        if model != nil then
            query_vector, _ = agent_provider.embeddings(model, query_text)
            if query_vector != nil then
                semantic = semantic_ranking(db_path, query_vector, model)
            end
        end
    end

    fused = {}
    by_id = {}
    rankings = {}
    for rank = 1, math.min(#lexical, SEARCH_CANDIDATES_PER_RANKING) do
        table.insert(rankings, {id = tonumber(lexical[rank].id), rank = rank, row = lexical[rank]})
    end
    for rank = 1, math.min(#semantic, SEARCH_CANDIDATES_PER_RANKING) do
        table.insert(rankings, {id = semantic[rank].id, rank = rank})
    end
    for _, ranked in ipairs(rankings) do
        entry = by_id[ranked.id]
        if entry == nil then
            entry = {id = ranked.id, fused = 0.0}
            by_id[ranked.id] = entry
            table.insert(fused, entry)
        end
        entry.fused = entry.fused + 1.0 / (SEARCH_RRF_K + ranked.rank)
        if ranked.row != nil then
            entry.row = ranked.row
        end
    end
    if #fused == 0 then
        return {}
    end

    -- Semantic-only candidates still need their metadata row.
    missing = {}
    for _, entry in ipairs(fused) do
        if entry.row == nil then
            table.insert(missing, tostring(entry.id))
        end
    end
    if #missing > 0 then
        meta_rows = db.query(db_path, string.format("SELECT %s FROM document d WHERE d.id IN (%s);",
            SEARCH_RESULT_COLUMNS, table.concat(missing, ", ")))
        if meta_rows != nil then
            for _, row in ipairs(meta_rows) do
                entry = by_id[tonumber(row.id)]
                if entry != nil then
                    entry.row = row
                end
            end
        end
    end

    -- Phase 3 cutover (see doc/heat-decay-redesign.md): one shared
    -- pool_scale read, reused for every row's effective_heat.
    document.ensure_pool_state(db_path)
    pool_state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = 1.0
    if pool_state_rows != nil and pool_state_rows[1] != nil then
        pool_scale = math.exp(tonumber(pool_state_rows[1].log_pool_scale))
    end

    scored = {}
    for _, entry in ipairs(fused) do
        row = entry.row
        if row != nil then
            effective_heat = document.pool_effective_heat(row.raw_heat, row.scale_at_write, pool_scale)
            heat_boost = 0.1 * math.log(math.max(effective_heat, 0.01) / BASE_HEAT)
            heat_boost = math.max(-0.1, math.min(heat_boost, 0.15))
            reinforcement = 1.0 + document.tier_weight(row.tier) + heat_boost
            table.insert(scored, {
                id = row.id, title = row.title, score = entry.fused * reinforcement,
                tier = row.tier, retrieval_count = row.retrieval_count,
                source_type = row.source_type,
                source_id = row.source_id, content_hash = row.content_hash,
                created_at = row.created_at, external_id = row.external_id,
            })
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)

    results = {}
    for i = 1, math.min(limit, #scored) do
        table.insert(results, scored[i])
    end
    if #results == 0 then
        return results
    end

    -- Content only for what's actually returned.
    ids = {}
    for _, r in ipairs(results) do
        table.insert(ids, tostring(tonumber(r.id)))
    end
    content_rows = db.query(db_path, string.format("SELECT id, content FROM document WHERE id IN (%s);", table.concat(ids, ", ")))
    content_by_id = {}
    if content_rows != nil then
        for _, row in ipairs(content_rows) do
            content_by_id[tonumber(row.id)] = row.content
        end
    end
    for _, r in ipairs(results) do
        r.content = content_by_id[tonumber(r.id)]
    end
    return results
end

-- The passage of `content` most worth showing for a search: the window
-- of `max_length` characters holding the most distinct query terms
-- (then the most hits), widened back to a line or word start. Found
-- live: excerpts used to be the first N characters, which for synced
-- files is a metadata preamble (source path, author, "synced daily"
-- notice) and a cover page -- the model saw the same boilerplate for
-- every hit and searched again. With no term in the content (a
-- semantic-only match), a leading blockquote preamble closed by a
-- horizontal rule is skipped instead.
function document.search_snippet(content, query_text, max_length)
    if content == nil or content == "" then
        return ""
    end
    lower = string.lower(content)
    snippet_terms = document.query_terms(query_text)
    hits = {}
    for i, term in ipairs(snippet_terms) do
        position = 1
        while #hits < 2000 do
            found = string.find(lower, term, position, true)
            if found == nil then
                break
            end
            table.insert(hits, {at = found, term = i})
            position = found + string.len(term)
        end
    end
    start = 1
    if #hits > 0 then
        table.sort(hits, function(a, b) return a.at < b.at end)
        best_distinct = 0
        best_count = 0
        left = 1
        in_window = {}
        for i = 1, #snippet_terms do
            in_window[i] = 0
        end
        distinct = 0
        for right = 1, #hits do
            in_window[hits[right].term] = in_window[hits[right].term] + 1
            if in_window[hits[right].term] == 1 then
                distinct = distinct + 1
            end
            while hits[right].at - hits[left].at > max_length / 2 do
                in_window[hits[left].term] = in_window[hits[left].term] - 1
                if in_window[hits[left].term] == 0 then
                    distinct = distinct - 1
                end
                left = left + 1
            end
            count = right - left + 1
            if distinct > best_distinct or (distinct == best_distinct and count > best_count) then
                best_distinct = distinct
                best_count = count
                start = hits[left].at
            end
        end
        -- A little lead-in, from the start of that line if it's close.
        lead_start = math.max(1, start - 150)
        line_start = nil
        search_from = lead_start
        while true do
            newline = string.find(content, "\n", search_from, true)
            if newline == nil or newline >= start then
                break
            end
            line_start = newline + 1
            search_from = newline + 1
        end
        if line_start != nil then
            start = line_start
        else
            start = lead_start
        end
    else
        -- Walk the leading quoted (and blank) lines; only if a "---"
        -- rule closes them is it a preamble worth skipping.
        position = 1
        while string.sub(content, position, position) == ">" or string.sub(content, position, position) == "\n" do
            line_end = string.find(content, "\n", position, true)
            if line_end == nil then
                break
            end
            position = line_end + 1
        end
        rule_end = string.match(content, "^%-%-%-+\n+()", position)
        if position > 1 and rule_end != nil then
            start = rule_end
        end
    end
    while start > 1 and string.find(string.sub(content, start - 1, start - 1), "%w") != nil do
        start = start - 1
    end
    body = string.sub(content, start)
    prefix = ""
    if start > 1 then
        prefix = "..."
    end
    if string.len(body) <= max_length then
        return prefix .. body
    end
    truncated = string.sub(body, 1, max_length)
    trimmed = string.match(truncated, "^(.*)%s%S*$")
    if trimmed != nil and string.len(trimmed) > max_length - 40 then
        truncated = trimmed
    end
    return prefix .. truncated .. "..."
end

-- CLI entry point: `daat document create-json`. The link/embedding/
-- pool-count backfills that used to live here are `daat repair` now
-- (src/repair.lua).
-- `daat repair knowledge`: rows derived from documents (or tags) that
-- are no longer active -- leftovers from before document.drop_derived
-- ran on archive, or from a raw SQL write. Only rows rebuilt from active
-- documents anyway: never the knowledge_* history, memberships or the
-- ledger. Embeddings from another model than the current one are only
-- counted: deleting them would just leave search without vectors until
-- `daat repair embeddings` re-embeds. -> {{label, action, count}, ...}
ACTIVE_DOCUMENT_IDS = "SELECT id FROM document WHERE archived_at IS NULL OR archived_at = ''"
ACTIVE_TAG_IDS = "SELECT id FROM tag WHERE archived_at IS NULL OR archived_at = ''"

function document.prune_derived(db_path, dry_run)
    checks = {
        {label = "embeddings of archived or missing documents", action = "deleted",
         tbl = "document_embedding", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "queued embeddings of archived or missing documents", action = "deleted",
         tbl = "document_embedding_due", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "references from archived or missing documents", action = "deleted",
         tbl = "document_reference", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "live links from archived or missing documents", action = "archived",
         tbl = "document_link", where = "(archived_at IS NULL OR archived_at = '') AND from_document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "centres of archived or missing tags", action = "deleted",
         tbl = "tag_centre", where = "tag_id NOT IN (" .. ACTIVE_TAG_IDS .. ")"},
    }
    results = {}
    for _, check in ipairs(checks) do
        rows = db.query(db_path, string.format("SELECT COUNT(*) AS n FROM %s WHERE %s;", check.tbl, check.where))
        count = 0
        if rows != nil and rows[1] != nil then
            count = tonumber(rows[1].n)
        end
        if count > 0 and dry_run != true then
            if check.action == "archived" then
                db.exec(db_path, string.format("UPDATE %s SET archived_at = %s WHERE %s;", check.tbl, db.now_expr(db_path), check.where))
            else
                db.exec(db_path, string.format("DELETE FROM %s WHERE %s;", check.tbl, check.where))
            end
        end
        table.insert(results, {label = check.label, action = check.action, count = count})
    end

    agent_provider = require("agent_provider")
    model = agent_provider.embedding_model()
    if model != nil then
        rows = db.query(db_path, string.format("SELECT COUNT(*) AS n FROM document_embedding WHERE model != %s;", db.quote(model)))
        if rows != nil and rows[1] != nil then
            table.insert(results, {label = "embeddings from another model than " .. model .. " (run `daat repair embeddings`)",
                action = "left", count = tonumber(rows[1].n)})
        end
    end
    return results
end

function document.do_document(cmd_args, db_path)
    action = cmd_args[1]

    -- What a document's embedding is made from, after embedding_skip
    -- and the transcript rule -- to check a pattern against real text.
    if action == "embedding-text" then
        text = document.embedding_text(db_path, tonumber(cmd_args[2]))
        if text == nil then
            print("Usage: daat document embedding-text <document_id>")
            return
        end
        print(text)
        return
    end

    if action == "embed-pending" then
        counts = document.embed_pending(db_path)
        print(string.format("Embedded %d, unchanged %d, failed %d, dropped %d (archived); %d still waiting",
            counts.embedded, counts.unchanged, counts.failed, counts.dropped, counts.waiting))
        for _, line in ipairs(counts.upkeep) do
            print("tag upkeep: " .. line)
        end
        return
    end

    -- Bulk document import (e.g. meeting notes, a literature corpus).
    -- Links and embeddings come from entity.create's own document hook
    -- either way, same as `entity create-json`; what differs is that
    -- this is deliberately NOT all-or-nothing the way create_batch's own
    -- validate-everything-first gate is: a real, heterogeneous batch
    -- (hundreds of files of unpredictable quality) shouldn't have one
    -- bad row block every other row -- each is created independently,
    -- successes and failures both reported.
    if action == "create-json" then
        input = io.read("*all")
        rows_values, _, decode_err = json.decode(input)
        if rows_values == nil then
            print(json.encode({error = "Invalid JSON input: " .. tostring(decode_err)}))
            return
        end
        author = os.getenv("USER")
        created_ids = {}
        failed = {}
        for i, values in ipairs(rows_values) do
            -- pcalled: db.exec/db.query raise a hard Lua error() on a
            -- genuine SQL failure (e.g. "Data too long for column")
            -- rather than returning nil+issues -- without this, one
            -- such row would crash the whole create-json process,
            -- losing every other row already queued in the same
            -- invocation, not just the bad one.
            ok, id_or_err, issues = pcall(document.create_page, db_path, author, values.title, values.parent_id, values.content, nil)
            if ok == false then
                table.insert(failed, {row_index = i, title = values.title, issues = tostring(id_or_err)})
            elseif id_or_err != nil then
                table.insert(created_ids, id_or_err)
            else
                table.insert(failed, {row_index = i, title = values.title, issues = issues})
            end
        end
        print(json.encode({created_ids = created_ids, failed = failed}))
        return
    end

    print("Usage: daat document <create-json|embed-pending|embedding-text>")
end

return document
