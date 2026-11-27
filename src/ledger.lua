-- Append-only entity event log and entity_type/entity_field registries.
-- entity_id equals the event_id of its create event. See doc/decisions/003-append-only-ledger-and-soft-archive.md.

const db = require("database")
const json = require("dkjson")
const store_lib = require("store")

const ledger = {}

ledger.SCHEMA = """
CREATE TABLE IF NOT EXISTS entity_type (
    name VARCHAR(255) PRIMARY KEY,
    created_at TEXT DEFAULT (%s),
    require_reason_on_update INTEGER DEFAULT 0,
    require_reason_on_archive INTEGER DEFAULT 0,
    admin_write_only INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS entity_field (
    entity_type VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    type TEXT NOT NULL,
    required INTEGER DEFAULT 0,
    enum_values TEXT,
    ref_entity_type TEXT,
    field_order INTEGER NOT NULL,
    display INTEGER DEFAULT 0,
    allowed_entity_types LONGTEXT,
    identifier INTEGER DEFAULT 0,
    PRIMARY KEY (entity_type, name)
);

CREATE TABLE IF NOT EXISTS entity_event (
    event_id INTEGER PRIMARY KEY %s,
    entity_id INTEGER,
    entity_type TEXT NOT NULL,
    event_type TEXT NOT NULL,
    field_changes LONGTEXT NOT NULL,
    author TEXT,
    created_at TEXT DEFAULT (%s),
    source_notebook_entry_id TEXT,
    source_row_id TEXT,
    reason TEXT
);
"""

function ensure_entity_event_reason_column(db_path)
    store_lib.ensure_column(db_path, "entity_event", "reason", "TEXT")
end

function ledger.init_schema(db_path)
    db.exec(db_path, string.format(ledger.SCHEMA,
        db.now_expr(db_path), db.autoincrement_keyword(db_path), db.now_expr(db_path)
    ))
    ensure_entity_event_reason_column(db_path)
    store_lib.ensure_index(db_path, "entity_event", "entity_event_entity_id_idx",
        "CREATE INDEX entity_event_entity_id_idx ON entity_event(entity_id, event_id);")
end

function ledger.append_create(db_path, entity_type, values, author, source)
    if source == nil then
        source = {}
    end
    field_changes = {}
    for name, value in pairs(values) do
        field_changes[name] = {old = nil, new = value}
    end

    statement = string.format(
        "INSERT INTO entity_event (entity_id, entity_type, event_type, field_changes, author, source_notebook_entry_id, source_row_id) VALUES (NULL, %s, 'create', %s, %s, %s, %s);",
        db.quote(entity_type),
        db.quote(json.encode(field_changes)),
        db.literal(author),
        db.literal(source.notebook_entry_id),
        db.literal(source.row_id)
    )
    -- Connection-scoped last_insert_rowid inside db.transaction prevents concurrent ID races
    -- or observable entity_id = NULL rows. See doc/mariadb-migration.md.
    function write_create_event()
        _, new_entity_id = db.exec(db_path, statement)
        db.exec(db_path, string.format(
            "UPDATE entity_event SET entity_id = %d WHERE event_id = %d;", new_entity_id, new_entity_id
        ))
        return new_entity_id
    end
    return db.transaction(db_path, write_create_event)
end

function ledger.append_update(db_path, entity_type, entity_id, field_changes, author, source, reason)
    if source == nil then
        source = {}
    end
    statement = string.format(
        "INSERT INTO entity_event (entity_id, entity_type, event_type, field_changes, author, source_notebook_entry_id, source_row_id, reason) VALUES (%d, %s, 'update', %s, %s, %s, %s, %s);",
        entity_id,
        db.quote(entity_type),
        db.quote(json.encode(field_changes)),
        db.literal(author),
        db.literal(source.notebook_entry_id),
        db.literal(source.row_id),
        db.literal(reason)
    )
    _, event_id = db.exec(db_path, statement)
    return event_id
end

function ledger.append_archive(db_path, entity_type, entity_id, author, source, reason)
    event_id = ledger.append_update(db_path, entity_type, entity_id, {}, author, source, reason)
    db.exec(db_path, string.format(
        "UPDATE entity_event SET event_type = 'archive' WHERE event_id = %d;", event_id
    ))
    return event_id
end

const ENTITY_EVENT_SQL_COLUMNS = {
    {name = "event_id", note = "primary key, in write order"},
    {name = "entity_id", note = "the entity's id -- ids come from one sequence shared by every entity type, so also filter entity_type"},
    {name = "entity_type", note = "registered entity type name (e.g. document)"},
    {name = "event_type", note = "create, update or archive"},
    {name = "field_changes", note = "JSON object {field: {old, new}} (create rows have only new) -- old/new hold full values, so a document's content can be long; select it only for the rows you need"},
    {name = "author", note = "login of who made the change"},
    {name = "created_at", note = "timestamp of the change"},
    {name = "source_notebook_entry_id", note = "external source (e.g. a Benchling entry) a synced write came from, else NULL"},
    {name = "source_row_id", note = "row within that source, else NULL"},
    {name = "reason", note = "free-text reason given for the change, may be NULL"},
}

function ledger.event_sql_columns_text()
    lines = {}
    for _, col in ipairs(ENTITY_EVENT_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n")
end

function ledger.history(db_path, entity_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM entity_event WHERE entity_id = %d ORDER BY event_id ASC;", entity_id
    ))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.field_changes = json.decode(row.field_changes)
    end
    return rows
end

function format_change_value(v)
    if type(v) == "table" then
        parts = {}
        for _, item in ipairs(v) do
            if type(item) == "table" and item.type != nil then
                table.insert(parts, tostring(item.type) .. ":" .. tostring(item.id))
            else
                table.insert(parts, tostring(item))
            end
        end
        return "[" .. table.concat(parts, ", ") .. "]"
    end
    return tostring(v)
end

function ledger.do_ledger(cmd_args, db_path)
    action = cmd_args[1]
    entity_id = tonumber(cmd_args[2])

    if action != "show" and action != "history" then
        print("Usage: daat ledger <show|history> <entity_id>")
        return
    end
    if entity_id == nil then
        print("Usage: daat ledger " .. action .. " <entity_id>")
        return
    end

    events = ledger.history(db_path, entity_id)
    if #events == 0 then
        print("No events for entity #" .. tostring(entity_id))
        return
    end

    for _, event in ipairs(events) do
        print(string.format("event #%d  %s  %s  by %s  at %s",
            event.event_id, event.event_type, event.entity_type,
            tostring(event.author), event.created_at))
        if event.reason != nil and event.reason != "" then
            print("    reason: " .. event.reason)
        end
        for field, change in pairs(event.field_changes) do
            print(string.format("    %s: %s -> %s", field, format_change_value(change.old), format_change_value(change.new)))
        end
    end
end

return ledger
