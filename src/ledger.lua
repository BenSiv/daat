-- The entity ledger: an append-only event log plus the registry tables
-- (entity_type/entity_field) that describe what kinds of entities exist.
-- See doc/architecture.md, "The entity ledger: event-sourced, not
-- file-versioned" -- this file is exactly that design, nothing more.
--
-- entity_event rows are never updated or deleted. An entity's identity
-- (entity_id) is the event_id of its own create event -- no separate
-- sequence needed, and it ties identity directly to the ledger rather
-- than to whatever the projected table's storage happens to assign.

db = require("db")
json = require("dkjson")

ledger = {}

ledger.SCHEMA = """
-- VARCHAR(255), not TEXT, on every column that's a primary or
-- composite key below -- MariaDB/InnoDB refuses a bare TEXT/BLOB
-- column in a key without an explicit bounded length ("BLOB/TEXT
-- column 'name' used in key specification without a key length"),
-- unlike SQLite, which has no such restriction. VARCHAR(n) behaves
-- identically to TEXT in SQLite (both get TEXT type affinity, the
-- length is purely decorative there), so this is safe for both
-- engines rather than needing a backend branch -- non-key TEXT
-- columns elsewhere in this file are untouched.
CREATE TABLE IF NOT EXISTS entity_type (
    name VARCHAR(255) PRIMARY KEY,
    created_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS entity_field (
    entity_type VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    type TEXT NOT NULL,
    required INTEGER DEFAULT 0,
    enum_values TEXT,
    ref_entity_type TEXT,
    field_order INTEGER NOT NULL,
    PRIMARY KEY (entity_type, name)
);

CREATE TABLE IF NOT EXISTS entity_event (
    event_id INTEGER PRIMARY KEY %s,
    entity_id INTEGER,
    entity_type TEXT NOT NULL,
    event_type TEXT NOT NULL,
    -- LONGTEXT, not TEXT -- this stores a JSON diff that includes the
    -- full old/new value of whatever changed, so any "text"-typed field
    -- (schema.lua's own SQL_TYPE.text, same reasoning) can make this
    -- exceed MariaDB's real TEXT cap (65,535 bytes) just as easily as
    -- the column it's recording a change to. Found live importing a
    -- literature corpus: real paper text routinely blew past it.
    field_changes LONGTEXT NOT NULL,
    author TEXT,
    created_at TEXT DEFAULT (%s),
    source_notebook_entry_id TEXT,
    source_row_id TEXT,
    reason TEXT
);
"""

-- CREATE TABLE IF NOT EXISTS never retrofits an existing table (task
-- #93) -- same reasoning/pattern as schema.lua's own
-- ensure_entity_field_display_column. A brand-new store gets `reason`
-- straight from ledger.SCHEMA above; an existing one needs this to
-- pick it up.
function ensure_entity_event_reason_column(db_path)
    existing = db.get_columns(db_path, "entity_event")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["reason"] == nil then
        db.exec(db_path, "ALTER TABLE entity_event ADD COLUMN reason TEXT;")
    end
end

function ledger.init_schema(db_path)
    db.exec(db_path, string.format(ledger.SCHEMA,
        db.now_expr(db_path), db.autoincrement_keyword(db_path), db.now_expr(db_path)
    ))
    ensure_entity_event_reason_column(db_path)
end

-- Appends a 'create' event and returns the new entity_id.
-- `values` is a plain {field_name = value} table.
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
    -- Fixed 2026-07-20 (task #77): this used to re-derive entity_id via
    -- SELECT MAX(event_id), on the (false, for a real concurrent CGI
    -- deployment) assumption that nothing else could insert between
    -- this connection's own insert and that read -- two simultaneous
    -- creates could both read the same MAX and collide on one entity_id
    -- while the other's row silently kept entity_id NULL forever.
    -- db.exec's second return value is last_insert_rowid(), read on the
    -- very same connection the insert itself just ran on -- inherently
    -- connection-scoped, so it can't see another connection's insert
    -- regardless of timing.
    _, entity_id = db.exec(db_path, statement)
    db.exec(db_path, string.format(
        "UPDATE entity_event SET entity_id = %d WHERE event_id = %d;", entity_id, entity_id
    ))
    return entity_id
end

-- Appends an 'update' event for an existing entity_id. `field_changes`
-- is a plain {field_name = {old = ..., new = ...}} table -- callers
-- compute the diff themselves, since only they know the entity's
-- current projected values. `reason` (task #93) is optional -- nil
-- for the common case, a schema can require entity.update supply one
-- via its own require_reason_on_update flag before ever reaching here.
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
    -- Same fix as append_create above (task #77): return the
    -- connection-scoped insert_id directly instead of a separate
    -- SELECT MAX(event_id) that another concurrent writer's own insert
    -- could race ahead of.
    _, event_id = db.exec(db_path, statement)
    return event_id
end

-- Appends an 'archive' event -- never a delete. Returns the new
-- event_id, same as append_update, so callers can stamp
-- last_event_id on the projected table consistently either way.
-- `reason` (task #93) is optional, same as append_update's own --
-- archiving is the stronger candidate for a schema to actually
-- require one (see entity.archive), but the ledger itself doesn't
-- enforce that; validation happens one layer up.
function ledger.append_archive(db_path, entity_type, entity_id, author, source, reason)
    event_id = ledger.append_update(db_path, entity_type, entity_id, {}, author, source, reason)
    db.exec(db_path, string.format(
        "UPDATE entity_event SET event_type = 'archive' WHERE event_id = %d;", event_id
    ))
    return event_id
end

-- Full event history for one entity, oldest first.
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

-- A multivalue field's old/new (task #84) decodes from JSON as a plain
-- Lua array, not a scalar -- tostring() on that gives an unreadable
-- "table: 0x..." pointer, so this renders it as a real bracketed list
-- instead. Scalars pass straight through unchanged.
function format_change_value(v)
    if type(v) == "table" then
        parts = {}
        for _, item in ipairs(v) do
            table.insert(parts, tostring(item))
        end
        return "[" .. table.concat(parts, ", ") .. "]"
    end
    return tostring(v)
end

-- CLI entry point: `platform ledger <show|history> <entity_id>`
function ledger.do_ledger(cmd_args, db_path)
    action = cmd_args[1]
    entity_id = tonumber(cmd_args[2])

    if action != "show" and action != "history" then
        print("Usage: platform ledger <show|history> <entity_id>")
        return
    end
    if entity_id == nil then
        print("Usage: platform ledger " .. action .. " <entity_id>")
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
