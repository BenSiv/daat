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
-- Links are a derived index over document content, not user-authored
-- data in their own right -- recomputed wholesale (delete + reinsert)
-- on every save, the same resync pattern the source convention uses,
-- rather than a schema-driven entity type with its own ledger history.
-- The content that generates them already has full audit history via
-- the document entity itself; a link row's own history would just be
-- churn (every content edit potentially archiving/recreating several),
-- not a real audit trail of anyone's actions.

db = require("db")
schema = require("schema")
entity = require("entity")
json = require("dkjson")

document = {}

DOCUMENT_SCHEMA = {
    name = "document",
    fields = {
        {name = "parent_id", type = "reference", required = false, entity_type = "document"},
        {name = "title", type = "text", required = true, display = true},
        {name = "content", type = "text", required = false},
    },
}

DOCUMENT_LINK_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_link (
    from_document_id INTEGER NOT NULL,
    to_document_id INTEGER,
    -- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT
    -- column as part of a key without an explicit length; see
    -- ledger.lua's own SCHEMA comment for the full reasoning.
    link_text VARCHAR(255) NOT NULL,
    PRIMARY KEY (from_document_id, link_text)
);
"""

-- Distinguishes a real `[[title]]` link a user actually wrote from one
-- this codebase created itself (co-retrieval -> explicit link) -- see
-- document.sync_links' own DELETE below: without this column, saving
-- either document's content would wipe an auto-created link the next
-- time sync_links reruns.
function ensure_document_link_source_column(db_path)
    existing = db.get_columns(db_path, "document_link")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["source"] == nil then
        db.exec(db_path, "ALTER TABLE document_link ADD COLUMN source VARCHAR(32) NOT NULL DEFAULT 'authored';")
    end
end

-- A document's cached semantic-search embedding. Recomputed on every
-- create_page/update_page -- one embedding API call per save, not a
-- corpus reindex. Best-effort: document.reindex_embedding returns
-- nil/err rather than throwing on failure (an unconfigured provider, a
-- network hiccup, ...), and create_page/update_page ignore that return
-- value entirely -- a document save must never fail just because the
-- embedding call did. document.reindex_all_embeddings/the CLI's own
-- `reindex-embeddings` command exist for bulk backfill (a provider
-- outage, or documents saved before this cache existed). Search itself
-- only ever *reads* this cache; it never computes an embedding on the fly.
DOCUMENT_EMBEDDING_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding (
    document_id INTEGER PRIMARY KEY,
    model TEXT NOT NULL,
    vector_json TEXT NOT NULL,
    updated_at TEXT DEFAULT (%s)
);
"""

EMBEDDING_MODEL = "text-embedding-005"

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

function document.init_schema(db_path)
    schema.register(db_path, DOCUMENT_SCHEMA)
    db.exec(db_path, DOCUMENT_LINK_SCHEMA)
    db.exec(db_path, string.format(DOCUMENT_EMBEDDING_SCHEMA, db.now_expr(db_path)))
    ensure_document_knowledge_columns(db_path)
    ensure_document_knowledge_indexes(db_path)
    ensure_document_link_source_column(db_path)
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

-- Recomputes every outgoing link for `document_id` from `content`:
-- delete the old set, re-parse, re-resolve, reinsert. Idempotent, safe
-- to call on every save regardless of whether content actually changed.
-- Only wipes/resyncs *authored* links (parsed fresh from this save's
-- own [[...]] markup below) -- an auto-created co-retrieval link
-- (source='co-retrieval') isn't derived from this document's content
-- at all, so it would otherwise get deleted the next time either
-- document's content changes.
function document.sync_links(db_path, document_id, content)
    db.exec(db_path, string.format(
        "DELETE FROM document_link WHERE from_document_id = %d AND source = 'authored';", tonumber(document_id)
    ))
    if content == nil then
        return
    end
    seen = {}
    for raw_link in string.gmatch(content, "%[%[(.-)%]%]") do
        if seen[raw_link] == nil then
            seen[raw_link] = true
            subject, title = document.parse_link_ref(raw_link)
            to_id = document.resolve_link(db_path, subject, title)
            db.exec(db_path, string.format(
                "%s document_link (from_document_id, to_document_id, link_text) VALUES (%d, %s, %s);",
                db.insert_ignore(db_path), tonumber(document_id), db.literal(to_id), db.quote(raw_link)
            ))
        end
    end
end

-- Documents linked to/from `document_id` (both directions, deduped via
-- UNION, self never included since document_link never stores a
-- self-loop) -- the graph knowledge.lua's spreading-activation pass
-- reinforces when a document is actually retrieved, on top of the
-- retrieved document's own heat bump (see doc/architecture.md's
-- "Knowledge pool" section, "Spreading activation").
function document.linked_neighbors(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT to_document_id AS id FROM document_link WHERE from_document_id = %d AND to_document_id IS NOT NULL
        UNION
        SELECT from_document_id AS id FROM document_link WHERE to_document_id = %d;
    """, tonumber(document_id), tonumber(document_id)))
    if rows == nil then
        return {}
    end
    return rows
end

-- ACT-R's "spreading activation": a retrieved document reinforces its
-- own heat directly (document.reinforcement_delta), but relevance
-- doesn't stop at the exact document that matched a query -- its
-- linked neighbors (document.linked_neighbors) get a smaller
-- reinforcement too. Diluted by fan_count (the "fan effect" -- a
-- concept spreads its activation across every connection it has, so a
-- heavily-linked hub document gives each neighbor a proportionally
-- smaller nudge, never the full amount every time). Never exceeds the
-- direct hit's own delta even for a single neighbor (fan_count floors
-- at 1, and SPREADING_ACTIVATION_FACTOR is itself < 1) -- a linked
-- neighbor's relevance is always a weaker signal than actually being
-- retrieved.
SPREADING_ACTIVATION_FACTOR = 0.35

function document.spreading_delta(base_delta, fan_count)
    if fan_count == nil or fan_count < 1 then
        fan_count = 1
    end
    return (base_delta * SPREADING_ACTIVATION_FACTOR) / fan_count
end

-- entity.create/update + document.sync_links together -- the full
-- "save a document" sequence, shared by the web save route and the agent's
-- document tool so the two can never drift apart on what "saving a
-- document" actually entails.
function document.create_page(db_path, author, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    created_id, issues = entity.create(db_path, "document", values, author, source)
    if created_id == nil then
        return nil, issues
    end
    document.sync_links(db_path, created_id, content)
    document.reindex_embedding(db_path, created_id)
    return created_id, issues
end

function document.update_page(db_path, author, document_id, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    updated_id, issues = entity.update(db_path, "document", document_id, values, author, source)
    if updated_id == nil then
        return nil, issues
    end
    document.sync_links(db_path, updated_id, content)
    document.reindex_embedding(db_path, updated_id)
    return updated_id, issues
end

-- Documents linking TO `document_id` -- "linked from" for the detail view.
function document.backlinks(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT dl.from_document_id AS id, d.title AS title
        FROM document_link dl
        JOIN document d ON d.id = dl.from_document_id
        WHERE dl.to_document_id = %d AND (d.archived_at IS NULL OR d.archived_at = '');
    """, tonumber(document_id)))
    if rows == nil then
        return {}
    end
    return rows
end

--------------------------------------------------------------------------
-- Rendering: Markdown -> HTML via cmark, "[[...]]" -> inline links
--------------------------------------------------------------------------

-- Rewrites every "[[...]]" occurrence into a plain CommonMark link
-- (resolved) or an unlinked, clearly-marked placeholder (dangling) --
-- ordinary Markdown either way, so cmark itself needs no special
-- handling for this project's own link syntax.
function document.inline_links_to_markdown(db_path, content)
    return (string.gsub(content, "%[%[(.-)%]%]", function(raw_link)
        subject, title = document.parse_link_ref(raw_link)
        target_id = document.resolve_link(db_path, subject, title)
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
    tmp_path = os.tmpname()
    file = io.open(tmp_path, "w")
    if file == nil then
        return ""
    end
    io.write(file, content)
    io.close(file)

    handle = io.popen("cmark-gfm -e table -e strikethrough -e autolink " .. shell_quote(tmp_path), "r")
    html = ""
    if handle != nil then
        html = io.read(handle, "*all")
        io.close(handle)
    end
    os.remove(tmp_path)
    if html == nil then
        html = ""
    end
    return html
end

function shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- The full pipeline: resolve "[[...]]" refs into plain Markdown links
-- first, then hand the whole thing to cmark once.
function document.render_html(db_path, content)
    if content == nil or content == "" then
        return ""
    end
    return document.render_markdown(document.inline_links_to_markdown(db_path, content))
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

-- A flat 0.15 plus the retrieved document's own tier weight, added to
-- heat on every retrieval hit. No decay -- heat is monotonic; see
-- document.effective_heat for the read-time decayed view.
function document.reinforcement_delta(tier)
    tier_weight = TIER_WEIGHT[tier]
    if tier_weight == nil then
        tier_weight = 0.0
    end
    return 0.15 + tier_weight
end

-- Heat decay: computed lazily wherever heat is actually used for a
-- decision (review's own promotion/demotion check, search's own
-- ranking) rather than a scheduled job rewriting every row -- matches
-- this codebase's "compute at request time" convention throughout (no
-- in-app background scheduler exists at all). The stored `heat` column
-- is left untouched -- it's the raw, monotonic reinforcement total;
-- effective_heat is the read-time view of it.
--
-- How fast "relevance heat" should decay plausibly tracks a
-- deployment's own real usage cadence (touched hourly vs. weekly) --
-- not a bare hardcoded literal; read fresh from
-- config.platform_config() per call rather than resolved once at load.

-- Days between `timestamp_str` (this codebase's "YYYY-MM-DD HH:MM:SS"
-- convention, whatever db.now_expr's own DEFAULT produced) and now.
-- nil (not 0) for anything unparseable -- callers treat that as "no
-- decay information, use heat as-is" rather than "decay as if just
-- retrieved," which would be the wrong direction to fail in.
function document.days_since(timestamp_str)
    if timestamp_str == nil or timestamp_str == "" then
        return nil
    end
    year, month, day, hour, min, sec = string.match(timestamp_str, "(%d+)-(%d+)-(%d+)[ T](%d+):(%d+):(%d+)")
    if year == nil then
        return nil
    end
    then_time = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })
    return (os.time() - then_time) / 86400
end

-- Exponential half-life decay: unchanged the instant a document is
-- retrieved, half its value after HEAT_DECAY_HALF_LIFE_DAYS of disuse,
-- a quarter after twice that, and so on -- never negative, never
-- demanding an exact "when did decay start" origin point the way a
-- linear decay would.
function document.effective_heat(heat, last_retrieved_at)
    days = document.days_since(last_retrieved_at)
    if days == nil or days <= 0 then
        return heat
    end
    config = require("config")
    half_life = config.platform_config().platform_heat_decay_half_life_days
    return heat * (0.5 ^ (days / half_life))
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
-- Scores every active document directly in Lua rather than a real
-- search index (see doc/architecture.md's "Documents" section for why
-- -- no FTS5 support in this project's SQLite binding) -- revisit only
-- if a real deployment's document count makes an O(n)-per-search scan
-- actually show up.

-- Computes and caches one document's embedding -- best-effort, called
-- from create_page/update_page on every save, as well as explicitly
-- via the CLI/document.reindex_all_embeddings for bulk backfill (see
-- DOCUMENT_EMBEDDING_SCHEMA's own comment).
function document.reindex_embedding(db_path, document_id)
    agent_provider = require("agent_provider")
    json = require("dkjson")

    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    text = doc.title
    if doc.content != nil and doc.content != "" then
        text = text .. "\n" .. doc.content
    end

    vector, err = agent_provider.embeddings(EMBEDDING_MODEL, text)
    if vector == nil then
        return nil, err
    end

    db.exec(db_path, string.format(
        "%s document_embedding (document_id, model, vector_json, updated_at) VALUES (%d, %s, %s, %s);",
        db.replace_into(db_path),
        tonumber(document_id), db.quote(EMBEDDING_MODEL), db.quote(json.encode(vector)), db.now_expr(db_path)
    ))
    return true
end

function document.reindex_all_embeddings(db_path)
    reindexed = 0
    failed = 0
    for _, row in ipairs(document.all_active(db_path)) do
        ok, err = document.reindex_embedding(db_path, row.id)
        if ok == true then
            reindexed = reindexed + 1
        else
            failed = failed + 1
        end
    end
    return reindexed, failed
end

function escape_pattern(text)
    return (string.gsub(text, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

function count_matches(text, term)
    if text == nil or term == nil or term == "" then
        return 0
    end
    text = string.lower(text)
    term = string.lower(term)
    pattern = escape_pattern(term)
    count = 0
    for _ in string.gmatch(text, pattern) do
        count = count + 1
    end
    return count
end

function cosine_similarity(v1, v2)
    if v1 == nil or v2 == nil or #v1 == 0 or #v2 == 0 or #v1 != #v2 then
        return 0.0
    end
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for i = 1, #v1 do
        dot = dot + v1[i] * v2[i]
        norm_a = norm_a + v1[i] * v1[i]
        norm_b = norm_b + v2[i] * v2[i]
    end
    if norm_a == 0.0 or norm_b == 0.0 then
        return 0.0
    end
    return dot / (math.sqrt(norm_a) * math.sqrt(norm_b))
end

function query_terms(query_text)
    terms = {}
    if query_text == nil then
        return terms
    end
    for term in string.gmatch(string.lower(query_text), "%S+") do
        table.insert(terms, term)
    end
    return terms
end

-- Blended lexical + optional semantic relevance for one document
-- against a parsed query. A document with score 0 and similarity at or
-- below 0.45 is excluded outright (the relevance floor) rather than
-- ranked last -- an irrelevant result showing up at the bottom of a
-- results list is still a wrong result.
function document.search_score(row, terms, query_text, query_vector)
    title = row.title
    if title == nil then
        title = ""
    end
    content = row.content
    if content == nil then
        content = ""
    end

    score = 0
    for _, term in ipairs(terms) do
        score = score + (count_matches(title, term) * 4)
        score = score + count_matches(content, term)
    end

    if query_text != nil and query_text != "" then
        lower_query = string.lower(query_text)
        if string.find(string.lower(title), escape_pattern(lower_query)) != nil then
            score = score + 6
        elseif string.find(string.lower(title .. " " .. content), escape_pattern(lower_query)) != nil then
            score = score + 3
        end
    end

    similarity = 0.0
    if query_vector != nil and row.embedding_vector != nil then
        similarity = cosine_similarity(query_vector, row.embedding_vector)
    end

    if score <= 0 and similarity <= 0.45 then
        return 0
    end

    final_score = score
    if similarity > 0 then
        final_score = final_score + (similarity * 8.0)
    end

    -- Tier/heat reinforcement, folded in only after the relevance floor
    -- above -- a heavily-reinforced document that's actually irrelevant
    -- to this query is still excluded outright, never ranked highly
    -- just because it's "hot".
    tier_weight = document.tier_weight(row.tier)
    heat = tonumber(row.heat)
    if heat == nil then
        heat = 1.0
    end
    effective_heat = document.effective_heat(heat, row.last_retrieved_at)
    final_score = final_score + (tier_weight * 10.0) + effective_heat

    return final_score
end

-- Searches active documents by blended lexical+embedding relevance,
-- including tier/heat reinforcement. `use_semantic` (default true)
-- computes the *query's* own embedding fresh each call (one cheap,
-- real-time API call) -- but a document only contributes semantic
-- score if it was already indexed via document.reindex_embedding/_all;
-- nothing here computes a document's own embedding on the fly.
-- Documents already folded into a canonical duplicate (merged_into
-- set) are excluded outright -- they'd otherwise compete with their
-- own canonical for the same result slot.
function document.search(db_path, query_text, limit, use_semantic)
    if limit == nil then
        limit = 20
    end
    if use_semantic == nil then
        use_semantic = true
    end

    terms = query_terms(query_text)

    query_vector = nil
    if use_semantic == true and query_text != nil and query_text != "" then
        agent_provider = require("agent_provider")
        vector, _ = agent_provider.embeddings(EMBEDDING_MODEL, query_text)
        query_vector = vector
    end

    -- Chat sessions are saved as their own searchable documents
    -- (source_type = 'chat_session', knowledge.sync_session_document)
    -- but excluded here from ordinary content search -- a transcript
    -- full of tool-call noise would otherwise pollute results for
    -- unrelated real-content queries. Still reachable directly
    -- (entity.get/detail), just not surfaced by document.search's
    -- relevance ranking.
    rows = db.query(db_path, """
        SELECT d.id, d.title, d.content, d.tier, d.heat, d.retrieval_count, d.last_retrieved_at,
               d.source_type, d.source_id, d.content_hash, d.created_at, d.external_id, e.vector_json
        FROM document d
        LEFT JOIN document_embedding e ON e.document_id = d.id
        WHERE (d.archived_at IS NULL OR d.archived_at = '')
          AND (d.merged_into IS NULL OR d.merged_into = '')
          AND (d.source_type IS NULL OR d.source_type != 'chat_session');
    """)
    if rows == nil then
        return {}
    end

    json = require("dkjson")
    scored = {}
    for _, row in ipairs(rows) do
        if row.vector_json != nil then
            decoded, _, _ = json.decode(row.vector_json)
            row.embedding_vector = decoded
        end
        row_score = document.search_score(row, terms, query_text, query_vector)
        if row_score > 0 then
            table.insert(scored, {
                id = row.id, title = row.title, content = row.content, score = row_score,
                tier = row.tier, heat = row.heat, retrieval_count = row.retrieval_count,
                last_retrieved_at = row.last_retrieved_at, source_type = row.source_type,
                source_id = row.source_id, content_hash = row.content_hash,
                created_at = row.created_at, external_id = row.external_id,
            })
        end
    end

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)

    results = {}
    for i = 1, math.min(limit, #scored) do
        table.insert(results, scored[i])
    end
    return results
end

-- CLI entry point: `platform document <create-json|reindex-embeddings [entity_id]>`
-- -- `reindex-embeddings` is for bulk backfill (documents saved before
-- this cache existed, or after a provider outage silently dropped some
-- best-effort saves).
function document.do_document(cmd_args, db_path)
    action = cmd_args[1]

    -- Bulk document import (e.g. meeting notes, a literature corpus) --
    -- deliberately NOT the generic `entity create-json` action: that
    -- goes through entity.create_batch -> entity.create directly, which
    -- skips document.create_page's own side effects (document.sync_links
    -- for backlinks, document.reindex_embedding for semantic search) --
    -- a plain entity-create bulk import would leave every new document
    -- unfindable by embedding similarity and invisible to backlinks
    -- until a full document reindex-embeddings run, silently. Also
    -- deliberately NOT all-or-nothing the way create_batch's own
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

    if action == "reindex-embeddings" then
        entity_id = tonumber(cmd_args[2])
        if entity_id != nil then
            ok, err = document.reindex_embedding(db_path, entity_id)
            if ok == nil then
                print("Error: " .. tostring(err))
                return
            end
            print("Reindexed embedding for document #" .. tostring(entity_id))
            return
        end
        reindexed, failed = document.reindex_all_embeddings(db_path)
        print(string.format("Reindexed %d document(s), %d failed", reindexed, failed))
        return
    end

    print("Usage: platform document <create-json|reindex-embeddings [entity_id]>")
end

return document
