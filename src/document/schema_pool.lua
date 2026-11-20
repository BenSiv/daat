-- Document schema DDL, link/embedding/pool table initialization,
-- conserved knowledge-pool heat accounting, content-maturity scoring
-- helpers, and tree/page CRUD primitives.

const aspect_lib = require("document.aspect")
const db = require("database")
const entity = require("entity")
const hmac = require("hmac")
const passage_lib = require("document.passage")
const reference = require("document.reference")
const schema = require("schema")
const store_lib = require("store")
const tag = require("tag")
const tag_upkeep_lib = require("tag.upkeep")

const doc_pool = {}

const DOCUMENT_SCHEMA = {
    name = "document",
    fields = {
        {name = "parent_id", type = "reference", required = false, entity_type = "document"},
        {name = "title", type = "text", required = true, display = true},
        {name = "content", type = "text", required = false},
    },
}

doc_pool.DOCUMENT_SCHEMA = DOCUMENT_SCHEMA

const DOCUMENT_LINK_TABLE_SQL = """
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

const BASE_LINK_STRENGTH = 1.0
doc_pool.BASE_LINK_STRENGTH = BASE_LINK_STRENGTH

function doc_pool.link_hash(link_text)
    return hmac.sha256("document_link", link_text)
end

function doc_pool.link_sync_hash(content)
    if content == nil then
        content = ""
    end
    return hmac.sha256("document_link_sync", content)
end

function doc_pool.sql_null_to_nil(value)
    if value == nil or value == "" then
        return nil
    end
    return value
end

function create_document_link_table(db_path, table_name)
    db.exec(db_path, string.format(DOCUMENT_LINK_TABLE_SQL, table_name, db.autoincrement_keyword(db_path)))
end

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

const LINK_MIGRATION_BATCH = 200

function document_link_needs_migration(db_path)
    if db.table_exists(db_path, "document_link") == false then
        return db.table_exists(db_path, "document_link_new")
    end
    return column_set(db_path, "document_link")["link_hash"] != true
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
    values = {}
    for i, row in ipairs(rows) do
        strength = tonumber(row.raw_strength)
        if strength == nil then
            strength = BASE_LINK_STRENGTH
        end
        table.insert(values, string.format("(%d, %s, %s, %s, %.17g, %s, %s)",
            tonumber(row.from_document_id), db.literal(doc_pool.sql_null_to_nil(row.to_document_id)), db.quote(row.link_text),
            db.quote(doc_pool.link_hash(row.link_text)), strength,
            db.literal(doc_pool.sql_null_to_nil(row.archived_at)), db.literal(doc_pool.sql_null_to_nil(row.created_at))))
        if #values == LINK_MIGRATION_BATCH or i == #rows then
            db.exec(db_path, "INSERT INTO document_link_new (from_document_id, to_document_id, link_text, link_hash, raw_strength, archived_at, created_at) VALUES " ..
                table.concat(values, ", ") .. ";")
            values = {}
        end
    end
    ensure_document_link_indexes(db_path, "document_link_new")
    db.exec(db_path, "ALTER TABLE document_link RENAME TO document_link_legacy;")
    db.exec(db_path, "ALTER TABLE document_link_new RENAME TO document_link;")
end

function migrate_document_link_layout(db_path)
    if document_link_needs_migration(db_path) == false then
        return
    end
    function run_link_layout_migration()
        if document_link_needs_migration(db_path) == false then
            return
        end
        if db.table_exists(db_path, "document_link") == false then
            db.exec(db_path, "ALTER TABLE document_link_new RENAME TO document_link;")
            return
        end
        copy_document_links_to_new_layout(db_path)
    end
    db.with_lock(db_path, "daat_document_link_layout", 120, run_link_layout_migration)
end

const DOCUMENT_EMBEDDING_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding (
    document_id INTEGER PRIMARY KEY,
    model TEXT NOT NULL,
    vector_json TEXT NOT NULL,
    vector_packed BLOB,
    text_hash VARCHAR(64),
    body_chars INTEGER,
    updated_at TEXT DEFAULT (%s)
);
"""

const DOCUMENT_EMBEDDING_DUE_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding_due (
    document_id INTEGER PRIMARY KEY,
    queued_at VARCHAR(19) NOT NULL
);
"""

const DOCUMENT_LINK_SYNC_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_link_sync (
    document_id INTEGER PRIMARY KEY,
    content_hash VARCHAR(64) NOT NULL
);
"""

const ACTIVE_POOL_DOCUMENT_WHERE = "(archived_at IS NULL OR archived_at = '') AND merged_into IS NULL"

function doc_pool.ensure_document_pool_columns(db_path, existing_map)
    have = existing_map
    if have == nil then
        if not db.table_exists(db_path, "document") then
            return
        end
        have = {}
        for _, name in ipairs(db.get_columns(db_path, "document")) do
            have[name] = true
        end
    end
    if have["log_scale_at_write"] == nil then
        store_lib.ensure_column(db_path, "document", "log_scale_at_write", "REAL NOT NULL DEFAULT 0.0")
        if have["scale_at_write"] != nil then
            db.exec(db_path, "UPDATE document SET log_scale_at_write = LN(scale_at_write) WHERE scale_at_write IS NOT NULL AND scale_at_write > 0 AND scale_at_write != 1.0;")
        end
    end
    if have["pool_active"] == nil then
        store_lib.ensure_column(db_path, "document", "pool_active", "INTEGER NOT NULL DEFAULT 0")
        db.exec(db_path, "UPDATE document SET pool_active = 1 WHERE " .. ACTIVE_POOL_DOCUMENT_WHERE .. ";")
    end
end

function ensure_document_knowledge_columns(db_path)
    store_lib.ensure_columns(db_path, "document", {
        {"tier", "INTEGER DEFAULT 0"},
        {"heat", "REAL DEFAULT 1.0"},
        {"retrieval_count", "INTEGER DEFAULT 0"},
        {"last_retrieved_at", "TEXT"},
        {"source_type", "TEXT"},
        {"source_id", "INTEGER"},
        {"source_ref", "TEXT"},
        {"content_hash", "TEXT"},
        {"duplicate_of", "INTEGER"},
        {"merged_into", "INTEGER"},
        {"raw_heat", "REAL DEFAULT 1.0"},
        {"scale_at_write", "REAL DEFAULT 1.0"},
    })
    doc_pool.ensure_document_pool_columns(db_path, nil)
end

const KNOWLEDGE_POOL_SQL_COLUMNS = {
    {name = "tier", note = "0-3, knowledge-pool maturity tier"},
    {name = "retrieval_count", note = "direct search-hit count"},
    {name = "last_retrieved_at", note = "timestamp of last search hit"},
    {name = "source_type", note = "'curated' | 'chat_session' | 'distilled' | 'reasoning' (legacy) | NULL (NULL means either directly user-authored, or synced in from an external system)"},
    {name = "source_id", note = "meaning depends on source_type"},
    {name = "source_ref", note = "e.g. the chat session id, when source_type = 'chat_session'"},
    {name = "external_id", note = "set when this document was synced in from an external system (e.g. Benchling); NULL for anything authored directly here"},
    {name = "content_hash", note = "used for duplicate detection"},
    {name = "duplicate_of", note = "FK to document.id, set once this row is folded into a canonical duplicate"},
    {name = "merged_into", note = "same as duplicate_of -- rows with this set are excluded from search"},
    {name = "raw_heat", note = "conserved-pool raw heat -- do not average this column alone, see log_scale_at_write"},
    {name = "log_scale_at_write", note = "combine as raw_heat * EXP(knowledge_pool_state.log_pool_scale - log_scale_at_write) for the real effective_heat (portable across SQLite and MariaDB); legacy 'heat' is unused -- ignore it"},
    {name = "scale_at_write", note = "legacy linear scale column kept for rollback -- ignore it and read log_scale_at_write instead"},
    {name = "pool_active", note = "1 while this document participates in the active conserved heat pool (neither archived nor merged_into), else 0"},
}
const KNOWLEDGE_POOL_SQL_NOTE = "Related tables, hand-rolled rather than schema.register()'d so entity.list_types never mentions them: knowledge_pool_state (one row, id=1: pool_scale/log_pool_scale/document_count) and document_link (queryable via entity.query; entity.fields('document_link') lists its columns) -- a derived index of [[links]] in document content; why two documents are connected is in content, not here."

const DOCUMENT_LINK_SQL_COLUMNS = {
    {name = "id", note = "primary key"},
    {name = "from_document_id", note = "FK to document.id -- the document whose content holds the [[link]]"},
    {name = "to_document_id", note = "FK to document.id -- the linked document; NULL while the link points at a page not created yet"},
    {name = "link_text", note = "the text inside [[...]] in from_document_id's content"},
    {name = "link_hash", note = "hash of link_text, for matching"},
    {name = "raw_strength", note = "usage-driven edge strength, starts at 1.0 and grows when the pair is retrieved together"},
    {name = "archived_at", note = "set when the link left the content -- filter archived_at IS NULL for current links"},
    {name = "created_at", note = "NULL for links predating the column"},
}

function doc_pool.link_sql_columns_text()
    lines = {}
    for _, col in ipairs(DOCUMENT_LINK_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n") .. "\nWhy two documents are connected is in content, not here: document.links returns the sentence around each link."
end

function doc_pool.knowledge_pool_sql_columns_text()
    lines = {}
    for _, col in ipairs(KNOWLEDGE_POOL_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n") .. "\n" .. KNOWLEDGE_POOL_SQL_NOTE
end

const DOCUMENT_EMBEDDING_SQL_COLUMNS = {
    {name = "document_id", note = "primary key, FK to document.id"},
    {name = "model", note = "which embedding model produced this vector"},
    {name = "vector_json", note = "the cached embedding vector, JSON-encoded"},
    {name = "vector_packed", note = "the same vector L2-normalised, as little-endian float32 bytes (what search reads)"},
    {name = "text_hash", note = "hash of the exact text embedded (NULL: made before this column, assumed current)"},
    {name = "body_chars", note = "length of that text besides the title (NULL: not known yet; `daat repair embeddings` fills it)"},
    {name = "updated_at", note = "timestamp of the last reindex"},
}

function ensure_document_embedding_columns(db_path)
    store_lib.ensure_columns(db_path, "document_embedding", {
        {"vector_packed", "BLOB"},
        {"text_hash", "VARCHAR(64)"},
        {"body_chars", "INTEGER"},
    })
end

function doc_pool.embedding_sql_columns_text()
    lines = {}
    for _, col in ipairs(DOCUMENT_EMBEDDING_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n")
end

function ensure_document_knowledge_indexes(db_path)
    store_lib.ensure_index(db_path, "document", "document_tier_idx",
        "CREATE INDEX document_tier_idx ON document(tier, heat DESC, retrieval_count DESC);")
    store_lib.ensure_index(db_path, "document", "document_hash_idx",
        string.format("CREATE INDEX document_hash_idx ON document(%s);",
            db.text_index_column(db_path, "content_hash")))
end

const KNOWLEDGE_POOL_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_pool_state (
    id INTEGER PRIMARY KEY,
    pool_scale REAL NOT NULL DEFAULT 1.0,
    log_pool_scale REAL NOT NULL DEFAULT 0.0,
    document_count INTEGER NOT NULL DEFAULT 0
);
"""

const BASE_HEAT = 1.0
const TIER_WEIGHT = {[0] = 0.0, [1] = 0.10, [2] = 0.20, [3] = 0.35}

function ensure_knowledge_pool_state_log_scale_column(db_path)
    if store_lib.has_column(db_path, "knowledge_pool_state", "log_pool_scale") then
        return
    end
    store_lib.ensure_column(db_path, "knowledge_pool_state", "log_pool_scale", "REAL NOT NULL DEFAULT 0.0")
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    if rows != nil and rows[1] != nil and tonumber(rows[1].pool_scale) != nil and tonumber(rows[1].pool_scale) > 0 then
        db.exec(db_path, string.format(
            "UPDATE knowledge_pool_state SET log_pool_scale = %.17g WHERE id = 1;",
            math.log(tonumber(rows[1].pool_scale))
        ))
    end
end

const _pool_state_ready = {}

function doc_pool.ensure_pool_state(db_path)
    cache_key = db.cache_key(db_path)
    if _pool_state_ready[cache_key] == true then
        return
    end
    ok_fast, fast_rows = pcall(db.query, db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    ok_cols, _ = pcall(db.query, db_path, "SELECT log_scale_at_write, pool_active FROM document LIMIT 1;")
    if ok_fast == true and fast_rows != nil and fast_rows[1] != nil and ok_cols == true then
        _pool_state_ready[cache_key] = true
        return
    end
    doc_pool.ensure_document_pool_columns(db_path, nil)
    db.exec(db_path, KNOWLEDGE_POOL_STATE_SCHEMA)
    ensure_knowledge_pool_state_log_scale_column(db_path)
    rows = db.query(db_path, "SELECT id FROM knowledge_pool_state WHERE id = 1;")
    if rows != nil and rows[1] != nil then
        _pool_state_ready[cache_key] = true
        return
    end
    db.exec(db_path, "UPDATE document SET pool_active = CASE WHEN " .. ACTIVE_POOL_DOCUMENT_WHERE .. " THEN 1 ELSE 0 END;")
    count_rows = db.query(db_path, "SELECT COUNT(*) AS n FROM document WHERE pool_active = 1;")
    count = 0
    if count_rows != nil and count_rows[1] != nil then
        count = tonumber(count_rows[1].n)
    end
    db.exec(db_path, string.format(
        "%s knowledge_pool_state (id, pool_scale, log_pool_scale, document_count) VALUES (1, 1.0, 0.0, %d);",
        db.insert_ignore(db_path), count
    ))
    _pool_state_ready[cache_key] = true
end

function lock_pool_document_row(db_path, document_id)
    if db.is_mariadb(db_path) then
        return db.query(db_path, string.format(
            "SELECT raw_heat, log_scale_at_write, pool_active FROM document WHERE id = %d FOR UPDATE;",
            tonumber(document_id)
        ))
    end
    return db.query(db_path, string.format(
        "SELECT raw_heat, log_scale_at_write, pool_active FROM document WHERE id = %d;",
        tonumber(document_id)
    ))
end

function lock_pool_state_row(db_path)
    if db.is_mariadb(db_path) then
        return db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1 FOR UPDATE;")
    end
    return db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
end

function doc_pool.resync_pool_count(db_path)
    doc_pool.ensure_pool_state(db_path)
    function run_resync_tx()
        lock_pool_state_row(db_path)
        db.exec(db_path, "UPDATE document SET pool_active = CASE WHEN " .. ACTIVE_POOL_DOCUMENT_WHERE .. " THEN 1 ELSE 0 END;")
        count_rows = db.query(db_path, "SELECT COUNT(*) AS n FROM document WHERE pool_active = 1;")
        count = 0
        if count_rows != nil and count_rows[1] != nil then
            count = tonumber(count_rows[1].n)
        end
        db.exec(db_path, string.format(
            "UPDATE knowledge_pool_state SET document_count = %d WHERE id = 1;", count
        ))
        return count
    end
    return db.transaction(db_path, run_resync_tx)
end

function doc_pool.register_pool_document(db_path, document_id)
    doc_pool.ensure_pool_state(db_path)
    function run_register_pool_tx()
        lock_pool_document_row(db_path, document_id)
        state_rows = lock_pool_state_row(db_path)
        if state_rows == nil or state_rows[1] == nil then
            return
        end
        log_pool_scale = tonumber(state_rows[1].log_pool_scale)
        _, _, changed = db.exec(db_path, string.format(
            "UPDATE document SET raw_heat = %.17g, log_scale_at_write = %.17g, pool_active = 1 " ..
            "WHERE id = %d AND pool_active = 0 AND %s;",
            BASE_HEAT, log_pool_scale, tonumber(document_id), ACTIVE_POOL_DOCUMENT_WHERE
        ))
        if changed != nil and changed > 0 then
            db.exec(db_path, "UPDATE knowledge_pool_state SET document_count = document_count + 1 WHERE id = 1;")
        end
    end
    db.transaction(db_path, run_register_pool_tx)
end

function doc_pool.init_schema(db_path)
    schema.register(db_path, DOCUMENT_SCHEMA)
    tag.register_schemas(db_path)
    migrate_document_link_layout(db_path)
    create_document_link_table(db_path, "document_link")
    ensure_document_link_indexes(db_path)
    db.exec(db_path, string.format(DOCUMENT_EMBEDDING_SCHEMA, db.now_expr(db_path)))
    ensure_document_embedding_columns(db_path)
    db.exec(db_path, DOCUMENT_EMBEDDING_DUE_SCHEMA)
    db.exec(db_path, DOCUMENT_LINK_SYNC_SCHEMA)
    tag.init_schema(db_path)
    tag_upkeep_lib.init_schema(db_path)
    passage_lib.init_schema(db_path)
    aspect_lib.init_schema(db_path)
    reference.init_schema(db_path)
    ensure_document_knowledge_columns(db_path)
    ensure_document_knowledge_indexes(db_path)
    doc_pool.ensure_pool_state(db_path)
end

function doc_pool.create_page(db_path, author, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    return entity.create(db_path, "document", values, author, source)
end

function doc_pool.update_page(db_path, author, document_id, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    return entity.update(db_path, "document", document_id, values, author, source)
end

const KNOWLEDGE_POOL_FOLDER_TITLE = "Knowledge Pool"

function find_knowledge_pool_folder(db_path)
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE parent_id IS NULL AND title = %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC LIMIT 1;",
        db.quote(KNOWLEDGE_POOL_FOLDER_TITLE)
    ))
    if rows != nil and rows[1] != nil then
        return tonumber(rows[1].id)
    end
    return nil
end

function doc_pool.ensure_knowledge_pool_folder(db_path)
    existing_id = find_knowledge_pool_folder(db_path)
    if existing_id != nil then
        return existing_id
    end
    function create_pool_folder_locked()
        locked_id = find_knowledge_pool_folder(db_path)
        if locked_id != nil then
            return locked_id
        end
        folder_id, _ = doc_pool.create_page(db_path, "system", KNOWLEDGE_POOL_FOLDER_TITLE, nil, nil, nil)
        return folder_id
    end
    return db.with_lock(db_path, "daat_pool_folder", 30, create_pool_folder_locked)
end

function doc_pool.children(db_path, parent_id)
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

function doc_pool.all_active(db_path)
    rows = db.query(db_path,
        "SELECT id, title, parent_id, created_at, external_id FROM document WHERE archived_at IS NULL OR archived_at = '' ORDER BY title ASC;")
    if rows == nil then
        return {}
    end
    return rows
end

function doc_pool.breadcrumbs(db_path, document_id)
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

function doc_pool.would_create_cycle(db_path, document_id, new_parent_id)
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

function doc_pool.tier_weight(tier)
    weight = TIER_WEIGHT[tonumber(tier)]
    if weight == nil then
        return 0.0
    end
    return weight
end

function legacy_djb2_content_hash(body)
    body = tostring(body)
    hash = 5381
    for i = 1, string.len(body) do
        hash = (hash * 33 + string.byte(body, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

function doc_pool.content_hash(body)
    return hmac.sha256("document_content", tostring(body))
end

function doc_pool.content_hash_matches(stored_hash, body)
    if stored_hash == nil or stored_hash == "" then
        return false
    end
    if string.len(stored_hash) == 8 then
        return stored_hash == legacy_djb2_content_hash(body)
    end
    return stored_hash == doc_pool.content_hash(body)
end

function doc_pool.reinforcement_delta(tier)
    tier_weight = TIER_WEIGHT[tier]
    if tier_weight == nil then
        tier_weight = 0.0
    end
    return 0.15 + tier_weight
end

function doc_pool.base_heat()
    return BASE_HEAT
end

function doc_pool.pool_effective_heat(raw_heat, log_scale_at_write, log_pool_scale)
    raw_heat = tonumber(raw_heat)
    log_scale_at_write = tonumber(log_scale_at_write)
    log_pool_scale = tonumber(log_pool_scale)
    if raw_heat == nil or log_scale_at_write == nil or log_pool_scale == nil then
        return BASE_HEAT
    end
    return raw_heat * math.exp(log_pool_scale - log_scale_at_write)
end

function doc_pool.reinforce_pool_heat(db_path, document_id, delta)
    doc_pool.ensure_pool_state(db_path)
    delta = tonumber(delta)
    if delta == nil then
        return nil
    end

    function run_reinforce_pool_tx()
        doc_rows = lock_pool_document_row(db_path, document_id)
        if doc_rows == nil or doc_rows[1] == nil then
            return nil
        end
        if tonumber(doc_rows[1].pool_active) != 1 then
            return nil
        end

        state_rows = lock_pool_state_row(db_path)
        if state_rows == nil or state_rows[1] == nil then
            return nil
        end
        log_pool_scale = tonumber(state_rows[1].log_pool_scale)
        document_count = tonumber(state_rows[1].document_count)

        x_eff = doc_pool.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].log_scale_at_write, log_pool_scale)

        total = document_count * BASE_HEAT
        denominator = total - x_eff

        log_f = 0.0
        extracted = 0.0
        if denominator > 0 then
            log_f = -(delta / denominator)
            extracted = denominator * (1 - math.exp(log_f))
        end

        new_log_pool_scale = log_pool_scale + log_f

        db.exec(db_path, string.format(
            "UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g WHERE id = 1;", log_f
        ))

        db.exec(db_path, string.format(
            "UPDATE document SET raw_heat = (raw_heat * EXP(%.17g - log_scale_at_write)) + %.17g, log_scale_at_write = %.17g WHERE id = %d AND pool_active = 1;",
            log_pool_scale, extracted, new_log_pool_scale, tonumber(document_id)
        ))

        return x_eff + extracted
    end

    return db.transaction(db_path, run_reinforce_pool_tx)
end

function doc_pool.return_pool_heat(db_path, document_id)
    doc_pool.ensure_pool_state(db_path)

    function run_return_pool_tx()
        doc_rows = lock_pool_document_row(db_path, document_id)
        if doc_rows == nil or doc_rows[1] == nil then
            return
        end
        state_rows = lock_pool_state_row(db_path)
        if state_rows == nil or state_rows[1] == nil then
            return
        end

        _, _, changed = db.exec(db_path, string.format(
            "UPDATE document SET pool_active = 0 WHERE id = %d AND pool_active = 1;", tonumber(document_id)
        ))
        if changed == nil or changed == 0 then
            return
        end

        log_pool_scale = tonumber(state_rows[1].log_pool_scale)
        document_count = tonumber(state_rows[1].document_count)
        x_eff = doc_pool.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].log_scale_at_write, log_pool_scale)

        total = document_count * BASE_HEAT
        denominator = total - x_eff
        if document_count <= 1 or denominator <= 0 then
            db.exec(db_path, "UPDATE knowledge_pool_state SET document_count = document_count - 1 WHERE id = 1;")
            return
        end

        f = 1 + ((x_eff - BASE_HEAT) / denominator)
        db.exec(db_path, string.format(
            "UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g, document_count = document_count - 1 WHERE id = 1;",
            math.log(f)
        ))
    end

    db.transaction(db_path, run_return_pool_tx)
end

function doc_pool.promotion_target_tier(tier, is_duplicate, revised, content_shape)
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

function doc_pool.word_count(body)
    body = tostring(body)
    count = 0
    for _ in string.gmatch(body, "%S+") do
        count = count + 1
    end
    return count
end

function doc_pool.content_shape(body)
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

    words = doc_pool.word_count(body)

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

function doc_pool.was_revised(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM entity_event WHERE entity_type = 'document' AND entity_id = %d AND event_type = 'update';",
        tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    return tonumber(rows[1].n) > 0
end

function doc_pool.connectivity_status(peer_count)
    return "linked-" .. tostring(peer_count)
end

function strip_spaces(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

const GENERIC_TITLES = {["note"] = true, ["untitled note"] = true, ["manual note"] = true, [""] = true, ["untitled"] = true}

function doc_pool.title_is_generic(title)
    if title == nil then
        return true
    end
    return GENERIC_TITLES[string.lower(strip_spaces(title))] == true
end

function doc_pool.guess_title_from_body(body)
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

return doc_pool
