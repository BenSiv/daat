-- Schema-as-code: loads entity type definitions (Luam table files, see
-- doc/schema.md) and generates/migrates the real typed SQL table each
-- one describes. This is the only place field-type -> SQL-type mapping
-- happens.

db = require("db")
sandbox = require("sandbox")
paths = require("paths")
lfs = require("lfs")

schema = {}

FIELD_TYPES = {"text", "number", "date", "select", "reference", "multi_select", "multi_reference", "sql_select", "polymorphic_reference", "multi_polymorphic_reference"}

-- Field types stored in a companion junction table (schema.
-- ensure_multi_field_table) instead of as a column on the entity's own
-- projected table (see doc/schema.md's "Multivalue fields" section).
-- Mirrors the singular select/reference split (a fixed-list value vs.
-- a real link to another entity type), not one generic "multivalue"
-- flag, since the junction table's second column differs (a literal
-- value vs. a real FK).
MULTI_FIELD_TYPES = {multi_select = true, multi_reference = true}

function is_multi_field_type(t)
    return MULTI_FIELD_TYPES[t] == true
end

-- A reference whose *target type itself varies per row* -- a sample's
-- "source" can be a plant or another sample, decided per row, not a
-- fixed entity_type the way a plain `reference` field declares one.
-- Real-world check before building this (2026-07-28): every genuine
-- case in this deployment's actual data has a small, enumerable set of
-- possible target types (2, never "any registered type"), so this
-- isn't a generic "reference of unknown shape" -- each field declares
-- its own closed `allowed_entity_types` list, validated the same
-- strictness as a plain `select` field's declared value list.
--
-- Stored in ONE shared table (entity_source, see schema.
-- ensure_entity_source_table) rather than a table per (entity_type,
-- field_name) the way multi_reference's own junction tables work --
-- schema.ensure_multi_field_table's per-type table can't represent
-- "this row's target type differs from that row's," since its FK is
-- fixed to one ref_type at table-creation time. polymorphic_reference
-- (one target) and multi_polymorphic_reference (several, e.g.
-- product.source can legitimately have more than one) mirror the
-- existing reference/multi_reference singular/plural split rather than
-- inventing a single type with a cardinality flag, matching this
-- codebase's own established convention (select/multi_select is the
-- same split).
POLYMORPHIC_FIELD_TYPES = {polymorphic_reference = true, multi_polymorphic_reference = true}

function is_polymorphic_field_type(t)
    return POLYMORPHIC_FIELD_TYPES[t] == true
end

function is_multivalue_polymorphic_field_type(t)
    return t == "multi_polymorphic_reference"
end

--------------------------------------------------------------------------
-- Named, reusable dropdown value lists (see doc/schema.md's "Named
-- dropdown lists" section)
--------------------------------------------------------------------------
--
-- A select/multi_select field can either inline its own `values` list
-- (unchanged, existing behavior) or reference a shared, named list via
-- `dropdown = "<name>"` -- config-as-code files under dropdowns/*.lua,
-- the same convention schemas/*.lua already uses. Resolved into
-- entity_field.enum_values at schema.register time (see
-- resolve_field_values below), so entity.validate's own enum-checking
-- code needs no changes at all -- it already just decodes enum_values
-- as a plain list, agnostic of whether it came from an inline list or a
-- shared dropdown.
DROPDOWN_SCHEMA = """
-- VARCHAR(255), not TEXT -- same MariaDB/InnoDB key-length reasoning as
-- ledger.lua's own entity_type/entity_field (a bare TEXT/BLOB column
-- can't be part of a key without an explicit bounded length).
CREATE TABLE IF NOT EXISTS dropdown_list (
    name VARCHAR(255) PRIMARY KEY,
    created_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS dropdown_value (
    list_name VARCHAR(255) NOT NULL,
    value VARCHAR(255) NOT NULL,
    value_order INTEGER NOT NULL,
    PRIMARY KEY (list_name, value),
    FOREIGN KEY (list_name) REFERENCES dropdown_list(name)
);

-- Single-row table recording a cheap signature of the schemas/
-- dropdowns directories' content as of the last real schema.sync_all
-- pass -- see schema.content_signature's own comment for why this
-- exists at all.
CREATE TABLE IF NOT EXISTS schema_sync_state (
    id INTEGER PRIMARY KEY,
    content_signature TEXT
);
"""

function schema.init_schema(db_path)
    db.exec(db_path, string.format(DROPDOWN_SCHEMA, db.now_expr(db_path)))
end

-- Structural validation for a dropdowns/*.lua file -- same shape/rigor
-- as schema.validate for an entity schema file.
function schema.validate_dropdown(def)
    if type(def) != "table" then
        return "dropdown definition must be a table"
    end
    if type(def.name) != "string" or def.name == "" then
        return "dropdown must have a non-empty string 'name'"
    end
    if type(def.values) != "table" or #def.values == 0 then
        return "dropdown '" .. tostring(def.name) .. "' must have a non-empty 'values' list"
    end
    for i, v in ipairs(def.values) do
        if type(v) != "string" or v == "" then
            return string.format("dropdown '%s' value #%d: must be a non-empty string", def.name, i)
        end
    end
    return nil
end

function schema.load_dropdown_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil, "cannot open dropdown file: " .. path
    end
    source = io.read(file, "*all")
    io.close(file)

    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == nil or ok == false then
        return nil, "error loading dropdown " .. path .. ": " .. tostring(result)
    end
    def = result

    err = schema.validate_dropdown(def)
    if err != nil then
        return nil, err
    end
    return def
end

-- Upserts one dropdown's value list -- delete-then-reinsert (same
-- "recompute wholesale" pattern document.sync_links already uses for
-- document_link), so removing a value from the schema file actually
-- removes it here too, not just additive drift.
-- One multi-row INSERT for every value, not one INSERT per value --
-- the per-value form is the dominant cost in schema.sync_all's own
-- per-request overhead once a deployment has enough dropdowns/values.
-- schema.validate_dropdown already requires a non-empty `values` list,
-- so the #def.values == 0 guard here is just defensive, not a real
-- case for a well-formed file.
function schema.register_dropdown(db_path, def)
    db.exec(db_path, string.format(
        "%s dropdown_list (name) VALUES (%s);", db.insert_ignore(db_path), db.quote(def.name)
    ))
    db.exec(db_path, string.format("DELETE FROM dropdown_value WHERE list_name = %s;", db.quote(def.name)))
    if #def.values > 0 then
        value_tuples = {}
        for i, value in ipairs(def.values) do
            table.insert(value_tuples, string.format("(%s, %s, %d)", db.quote(def.name), db.quote(value), i))
        end
        db.exec(db_path, string.format(
            "%s dropdown_value (list_name, value, value_order) VALUES %s;",
            db.insert_ignore(db_path), table.concat(value_tuples, ", ")
        ))
    end
    return true
end

-- The current value list for a named dropdown, in declaration order --
-- empty (not an error) if the name doesn't exist, so a field.dropdown
-- typo fails the same way an empty inline `values = {}` list already
-- would (every submitted value rejected as "not in the declared list"),
-- not with a confusing crash.
function schema.dropdown_values(db_path, name)
    rows = db.query(db_path, string.format(
        "SELECT value FROM dropdown_value WHERE list_name = %s ORDER BY value_order ASC;", db.quote(name)
    ))
    if rows == nil then
        return {}
    end
    values = {}
    for _, row in ipairs(rows) do
        table.insert(values, row.value)
    end
    return values
end

function schema.is_dropdown_registered(db_path, name)
    rows = db.query(db_path, string.format("SELECT 1 FROM dropdown_list WHERE name = %s;", db.quote(name)))
    return rows != nil and #rows > 0
end

-- A select/multi_select field's resolved allowed-values list -- inline
-- `values` if given, otherwise the current contents of the named
-- `dropdown` it references. Called at schema.register time so
-- entity_field.enum_values always reflects the dropdown's *current*
-- values, the same way it already gets re-applied on every sync.
function resolve_field_values(db_path, field)
    if field.values != nil then
        return field.values
    end
    if field.dropdown != nil then
        return schema.dropdown_values(db_path, field.dropdown)
    end
    return {}
end

-- Every generated entity table's own columns (builtin_columns below,
-- plus "id" itself) -- a field sharing one of these names fails at
-- `schema add` time with a raw "duplicate column name" SQL error
-- instead of a clear message. Listed here, not derived from builtin_columns()
-- itself, since that function needs a live db_path (for
-- db.now_expr's backend-specific default) that schema.validate itself
-- is never given, and every name in it is a plain string literal
-- anyway.
RESERVED_FIELD_NAMES = {
    "id", "created_by", "created_at", "updated_by", "updated_at",
    "last_event_id", "external_id", "name", "archived_at",
}

function is_reserved_field_name(name)
    for _, reserved in ipairs(RESERVED_FIELD_NAMES) do
        if name == reserved then
            return true
        end
    end
    return false
end

-- "text" is LONGTEXT, not TEXT -- MariaDB's plain TEXT caps at 65,535
-- *bytes*, not characters, so multi-KB content routinely exceeds it
-- ("Data too long for column"); SQLite has no such cap regardless of
-- the declared type name. Safe to change unconditionally rather than
-- branch per backend: SQLite's type-affinity rules key off the
-- substring "TEXT" in the declared type name, so a LONGTEXT column
-- behaves identically to a plain TEXT one there (verified directly:
-- stores 500KB with no truncation, `pragma_table_info` reports the
-- type as declared).
SQL_TYPE = {
    text = "LONGTEXT",
    number = "REAL",
    date = "TEXT",
    select = "TEXT",
    reference = "INTEGER",
    -- A plain TEXT column like "text" -- the only difference
    -- is entity.validate's value check (must be a single plain SELECT,
    -- see view.is_select_only), not storage.
    sql_select = "TEXT",
}

function is_valid_field_type(t)
    for _, valid in ipairs(FIELD_TYPES) do
        if t == valid then
            return true
        end
    end
    return false
end

-- Loads a schema definition from a Luam table file, sandboxed (see
-- doc/schema.md: schema files are executable, not inert data, so they
-- run through the same environment extension code would).
function schema.load_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil, "cannot open schema file: " .. path
    end
    source = io.read(file, "*all")
    io.close(file)

    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == nil or ok == false then
        return nil, "error loading schema " .. path .. ": " .. tostring(result)
    end
    def = result

    err = schema.validate(def)
    if err != nil then
        return nil, err
    end
    return def
end

-- Structural validation only -- does the definition make sense on its
-- own terms. Whether it's consistent with what's already registered
-- (e.g. a reference to an unknown entity_type) is checked at register
-- time, since that needs the database.
function schema.validate(def)
    if type(def) != "table" then
        return "schema definition must be a table"
    end
    if type(def.name) != "string" or def.name == "" then
        return "schema must have a non-empty string 'name'"
    end
    if type(def.fields) != "table" then
        return "schema '" .. tostring(def.name) .. "' must have a 'fields' list"
    end
    -- Type-level (not per-field) opt-in flags: a schema can require
    -- entity.update/entity.archive be given a non-empty `reason`
    -- before either is allowed to proceed for this type. Optional,
    -- default false either way -- most schemas set neither. Checked
    -- via direct true/false comparison, not type(x) == "boolean" --
    -- this Luam dialect's type() reports a real boolean as "flag", not
    -- "boolean" (matches how every other boolean-ish field in this
    -- file -- required, display -- is already checked elsewhere: ==
    -- true/== false, never by type name).
    if def.require_reason_on_update != nil and def.require_reason_on_update != true and def.require_reason_on_update != false then
        return string.format("schema '%s': 'require_reason_on_update' must be true or false", def.name)
    end
    if def.require_reason_on_archive != nil and def.require_reason_on_archive != true and def.require_reason_on_archive != false then
        return string.format("schema '%s': 'require_reason_on_archive' must be true or false", def.name)
    end
    -- Another type-level opt-in flag, same shape as the two
    -- above -- a schema can require Admin capability to create/update/
    -- archive rows of this type (e.g. label_template, whose `sql_select`
    -- field is genuinely executable). Anyone can still read/view rows
    -- of the type; this only gates writes. Enforced in cgi.lua, not
    -- here (schema.lua has no notion of an HTTP session/capability).
    if def.admin_write_only != nil and def.admin_write_only != true and def.admin_write_only != false then
        return string.format("schema '%s': 'admin_write_only' must be true or false", def.name)
    end
    for i, field in ipairs(def.fields) do
        if type(field.name) != "string" or field.name == "" then
            return string.format("schema '%s' field #%d: missing 'name'", def.name, i)
        end
        if is_reserved_field_name(field.name) then
            return string.format("schema '%s' field '%s': collides with a builtin column of the same name -- choose a different field name", def.name, field.name)
        end
        if is_valid_field_type(field.type) == false then
            return string.format("schema '%s' field '%s': invalid type '%s'", def.name, field.name, tostring(field.type))
        end
        if (field.type == "select" or field.type == "multi_select") then
            if field.values == nil and field.dropdown == nil then
                return string.format("schema '%s' field '%s': type '%s' requires either a 'values' list or a 'dropdown' name", def.name, field.name, field.type)
            end
            if field.values != nil and type(field.values) != "table" then
                return string.format("schema '%s' field '%s': 'values' must be a list", def.name, field.name)
            end
            if field.dropdown != nil and (type(field.dropdown) != "string" or field.dropdown == "") then
                return string.format("schema '%s' field '%s': 'dropdown' must be a non-empty string", def.name, field.name)
            end
        end
        if field.type == "multi_reference" and field.entity_type != nil and type(field.entity_type) != "string" then
            return string.format("schema '%s' field '%s': 'entity_type' must be a string", def.name, field.name)
        end
        if is_polymorphic_field_type(field.type) then
            if type(field.allowed_entity_types) != "table" or #field.allowed_entity_types == 0 then
                return string.format("schema '%s' field '%s': type '%s' requires a non-empty 'allowed_entity_types' list", def.name, field.name, field.type)
            end
            for _, allowed_type in ipairs(field.allowed_entity_types) do
                if type(allowed_type) != "string" or allowed_type == "" then
                    return string.format("schema '%s' field '%s': 'allowed_entity_types' entries must be non-empty strings", def.name, field.name)
                end
            end
        end
        -- Optional bounds on a "number" field -- UI-hint only for now
        -- (wired into the registration table's <input type="number">
        -- min/max, see html.lua), not yet enforced server-side. A real
        -- bug found in production: without this, the registration
        -- table's number input had no min/max at all, so its native
        -- spinner arrows could be clicked past any sensible bound
        -- (e.g. past 5 for a 1-5 field) with no feedback. Server-side
        -- range enforcement, if a schema author needs it, is still a
        -- before-hook extension's job (see software's
        -- task-priority-range) -- consolidating that into a generic,
        -- schema-declared, DB-enforced constraint is a bigger change
        -- (entity_field would need new columns) not attempted here.
        if field.min != nil and type(field.min) != "number" then
            return string.format("schema '%s' field '%s': 'min' must be a number", def.name, field.name)
        end
        if field.max != nil and type(field.max) != "number" then
            return string.format("schema '%s' field '%s': 'max' must be a number", def.name, field.name)
        end
        if field.min != nil and field.max != nil and field.min > field.max then
            return string.format("schema '%s' field '%s': 'min' (%s) is greater than 'max' (%s)", def.name, field.name, tostring(field.min), tostring(field.max))
        end
    end
    return nil
end

-- Registers a validated schema definition: upserts entity_type/entity_field
-- rows, then creates or migrates the projected table.
-- entity_field predates the `display` flag (see schema.fields()'s own
-- header comment on entity_display_label in html.lua) -- ledger.lua's
-- CREATE TABLE IF NOT EXISTS never retrofits an existing table, so this
-- migrates it the same way sync_table() already migrates per-type
-- tables: additive, idempotent, safe to re-run on every sync.
function ensure_entity_field_display_column(db_path)
    existing = db.get_columns(db_path, "entity_field")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["display"] == nil then
        db.exec(db_path, "ALTER TABLE entity_field ADD COLUMN display INTEGER DEFAULT 0;")
    end
    -- entity_field predates polymorphic_reference/multi_polymorphic_
    -- reference -- same migration pattern as `display` just above.
    -- JSON-encoded list, same convention as enum_values, since a
    -- polymorphic field's allowed target types are a list, not the one
    -- fixed ref_entity_type a plain reference/multi_reference declares.
    if have["allowed_entity_types"] == nil then
        db.exec(db_path, "ALTER TABLE entity_field ADD COLUMN allowed_entity_types LONGTEXT;")
    end
end

-- entity_type predates the require_reason_on_update/require_reason_on_
-- archive flags and admin_write_only -- same reasoning/pattern as
-- ensure_entity_field_display_column just above.
function ensure_entity_type_reason_flag_columns(db_path)
    existing = db.get_columns(db_path, "entity_type")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["require_reason_on_update"] == nil then
        db.exec(db_path, "ALTER TABLE entity_type ADD COLUMN require_reason_on_update INTEGER DEFAULT 0;")
    end
    if have["require_reason_on_archive"] == nil then
        db.exec(db_path, "ALTER TABLE entity_type ADD COLUMN require_reason_on_archive INTEGER DEFAULT 0;")
    end
    if have["admin_write_only"] == nil then
        db.exec(db_path, "ALTER TABLE entity_type ADD COLUMN admin_write_only INTEGER DEFAULT 0;")
    end
end

function schema.register(db_path, def)
    ensure_entity_field_display_column(db_path)
    ensure_entity_type_reason_flag_columns(db_path)
    db.exec(db_path, string.format(
        "%s entity_type (name) VALUES (%s);", db.insert_ignore(db_path), db.quote(def.name)
    ))

    -- A separate UPDATE, not folded into the INSERT OR IGNORE above --
    -- that statement only ever fires once (first registration; IGNORE
    -- means a second run touches nothing), but these two flags are
    -- meant to track whatever the schema file currently says, re-applied
    -- on every sync the same way field definitions already are.
    require_reason_on_update_flag = 0
    if def.require_reason_on_update == true then
        require_reason_on_update_flag = 1
    end
    require_reason_on_archive_flag = 0
    if def.require_reason_on_archive == true then
        require_reason_on_archive_flag = 1
    end
    admin_write_only_flag = 0
    if def.admin_write_only == true then
        admin_write_only_flag = 1
    end
    db.exec(db_path, string.format(
        "UPDATE entity_type SET require_reason_on_update = %d, require_reason_on_archive = %d, admin_write_only = %d WHERE name = %s;",
        require_reason_on_update_flag, require_reason_on_archive_flag, admin_write_only_flag, db.quote(def.name)
    ))

    for i, field in ipairs(def.fields) do
        enum_json = nil
        if field.type == "select" or field.type == "multi_select" then
            json = require("dkjson")
            enum_json = json.encode(resolve_field_values(db_path, field))
        end
        allowed_types_json = nil
        if is_polymorphic_field_type(field.type) then
            json = require("dkjson")
            allowed_types_json = json.encode(field.allowed_entity_types)
        end
        required_flag = 0
        if field.required == true then
            required_flag = 1
        end
        display_flag = 0
        if field.display == true then
            display_flag = 1
        end
        db.exec(db_path, string.format(
            "%s entity_field (entity_type, name, type, required, enum_values, ref_entity_type, field_order, display, allowed_entity_types) VALUES (%s, %s, %s, %d, %s, %s, %d, %d, %s);",
            db.replace_into(db_path),
            db.quote(def.name), db.quote(field.name), db.quote(field.type),
            required_flag,
            db.literal(enum_json),
            db.literal(field.entity_type),
            i,
            display_flag,
            db.literal(allowed_types_json)
        ))
    end

    schema.sync_table(db_path, def)
    return true
end

-- Always-present bookkeeping columns, independent of anything a schema
-- file declares -- external_id lets an external importer (e.g.
-- import_data_rest.py) look up "does a row for this source record
-- already exist" and upsert instead of blindly re-creating it every
-- sync run (a real, confirmed-live duplication bug this fixed: entity
-- tables had no external-id concept at all, so every run re-inserted
-- every source row from scratch).
--
-- "name" is the same idea for a real display label: an external source
-- like Benchling already assigns every record a genuine name (e.g. a
-- container literally named "50L stainless steel bioreactor"), distinct
-- from any of its own schema fields. Confirmed live: an importer was
-- already fetching this value to use as a natural key for dedup
-- matching, then discarding it -- never persisting it anywhere. A
-- schema-author's own {display = true} field (schema.lua's
-- entity_field.display column) is a reasonable per-type fallback for
-- data that has no such external source, but shouldn't be the first
-- choice when a real name already exists.
-- A function of db_path, not a static table, since created_at/
-- updated_at's default-value expression is backend-specific
-- (db.now_expr) -- db_path isn't known at module-load time, only once
-- schema.sync_table is actually called.
function builtin_columns(db_path)
    now_expr = db.now_expr(db_path)
    return {
        {name = "created_by", sql_type = "TEXT"},
        {name = "created_at", sql_type = "TEXT DEFAULT (" .. now_expr .. ")"},
        {name = "updated_by", sql_type = "TEXT"},
        {name = "updated_at", sql_type = "TEXT DEFAULT (" .. now_expr .. ")"},
        {name = "last_event_id", sql_type = "INTEGER"},
        {name = "external_id", sql_type = "TEXT"},
        {name = "name", sql_type = "TEXT"},
        -- NULL means active; a real timestamp means archived. Never a
        -- boolean/plain flag -- recording *when* costs nothing extra and
        -- means "archived" doesn't need a second column to also answer
        -- "since when". Nothing ever hard-deletes a row; this plus the
        -- ledger's own 'archive' event (ledger.append_archive) are the only
        -- two places "this entity is no longer active" is recorded, and
        -- both are additive, not destructive.
        {name = "archived_at", sql_type = "TEXT"},
    }
end

--------------------------------------------------------------------------
-- Multivalue fields -- a companion junction table per (entity_type,
-- field_name) instead of a column on the entity's own table (see
-- doc/schema.md's "Multivalue fields" section). Mirrors document_link's
-- own shape (a real many-to-many table, composite PK, no surrogate id)
-- -- the pattern this codebase already uses for "this row connects to
-- several others."
--------------------------------------------------------------------------

function schema.multi_field_table_name(entity_type, field_name)
    return entity_type .. "_" .. field_name
end

-- The junction table's own second column name -- "<field>_id" for a
-- multi_reference (it holds a real FK to another entity), plain "value"
-- for a multi_select (a literal string, no FK target to name it after).
function multi_field_value_column(field)
    if field.type == "multi_reference" then
        return field.name .. "_id"
    end
    return "value"
end

-- Idempotent (CREATE TABLE IF NOT EXISTS) -- called both from
-- schema.sync_table (so a schema sync alone is enough to create it) and
-- lazily before every write, so a table created before this field
-- existed still picks it up without a separate migration step.
function schema.ensure_multi_field_table(db_path, entity_type, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    if db.table_exists(db_path, table_name) then
        return
    end
    parent_col = entity_type .. "_id"
    value_col = multi_field_value_column(field)
    if field.type == "multi_reference" then
        -- `field` arrives in two different shapes depending on caller:
        -- a raw schemas/*.lua field definition (schema.sync_table,
        -- `.entity_type`) or an entity_field DB row (schema.
        -- multi_fields_by_name -> entity.lua, `.ref_entity_type`).
        -- Checking both is not redundancy for its own sake -- treating
        -- this as one shape was a real bug (silently FK'd every
        -- multi_reference junction table back at its own parent type).
        ref_type = entity_type
        if field.ref_entity_type != nil and field.ref_entity_type != "" then
            ref_type = field.ref_entity_type
        elseif field.entity_type != nil and field.entity_type != "" then
            ref_type = field.entity_type
        end
        db.exec(db_path, string.format("""
            CREATE TABLE %s (
                %s INTEGER NOT NULL,
                %s INTEGER NOT NULL,
                PRIMARY KEY (%s, %s),
                FOREIGN KEY (%s) REFERENCES %s(id),
                FOREIGN KEY (%s) REFERENCES %s(id)
            );
        """, table_name, parent_col, value_col, parent_col, value_col,
             parent_col, entity_type, value_col, ref_type))
    else
        -- VARCHAR(255), not TEXT -- same MariaDB/InnoDB key-length
        -- reasoning as ledger.lua/document_link (a bare TEXT/BLOB
        -- column can't be part of a key without a bounded length).
        db.exec(db_path, string.format("""
            CREATE TABLE %s (
                %s INTEGER NOT NULL,
                %s VARCHAR(255) NOT NULL,
                PRIMARY KEY (%s, %s),
                FOREIGN KEY (%s) REFERENCES %s(id)
            );
        """, table_name, parent_col, value_col, parent_col, value_col, parent_col, entity_type))
    end
end

-- Accepts either a real Lua array (already-parsed JSON, or a
-- programmatic caller) or a comma-separated string (CLI convenience --
-- every other CLI field value already arrives as a plain string) and
-- normalizes both into a plain array of trimmed, non-empty items.
function schema.normalize_multi_value(value)
    if value == nil then
        return {}
    end
    if type(value) == "table" then
        return value
    end
    items = {}
    for item in string.gmatch(tostring(value), "[^,]+") do
        trimmed = (string.gsub(item, "^%s*(.-)%s*$", "%1"))
        if trimmed != "" then
            table.insert(items, trimmed)
        end
    end
    return items
end

-- Replaces the full current set for one entity's multivalue field --
-- delete-then-reinsert (same "recompute wholesale" pattern document.
-- sync_links already uses for document_link), not an incremental
-- add/remove -- simpler, and correct either way since the caller always
-- submits the complete intended set, not a delta.
function schema.write_multi_field(db_path, entity_type, entity_id, field, value)
    schema.ensure_multi_field_table(db_path, entity_type, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    parent_col = entity_type .. "_id"
    value_col = multi_field_value_column(field)
    db.exec(db_path, string.format(
        "DELETE FROM %s WHERE %s = %d;", table_name, parent_col, tonumber(entity_id)
    ))
    for _, item in ipairs(schema.normalize_multi_value(value)) do
        if field.type == "multi_reference" then
            db.exec(db_path, string.format(
                "%s %s (%s, %s) VALUES (%d, %d);",
                db.insert_ignore(db_path), table_name, parent_col, value_col, tonumber(entity_id), tonumber(item)
            ))
        else
            db.exec(db_path, string.format(
                "%s %s (%s, %s) VALUES (%d, %s);",
                db.insert_ignore(db_path), table_name, parent_col, value_col, tonumber(entity_id), db.quote(tostring(item))
            ))
        end
    end
end

-- The current set for one entity's multivalue field, as a plain array
-- (of ids for multi_reference, of strings for multi_select).
function schema.read_multi_field(db_path, entity_type, entity_id, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    if db.table_exists(db_path, table_name) == false then
        return {}
    end
    parent_col = entity_type .. "_id"
    value_col = multi_field_value_column(field)
    rows = db.query(db_path, string.format(
        "SELECT %s AS v FROM %s WHERE %s = %d;", value_col, table_name, parent_col, tonumber(entity_id)
    ))
    if rows == nil then
        return {}
    end
    values = {}
    for _, row in ipairs(rows) do
        table.insert(values, row.v)
    end
    return values
end

-- Every multivalue field on `entity_type`, keyed by field name -- the
-- lookup entity.create/update/get all need to tell a multivalue field
-- apart from a plain column.
function schema.multi_fields_by_name(db_path, entity_type)
    result = {}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if is_multi_field_type(field.type) then
            result[field.name] = field
        end
    end
    return result
end

-- Same lookup as multi_fields_by_name, for polymorphic_reference/
-- multi_polymorphic_reference fields.
function schema.polymorphic_fields_by_name(db_path, entity_type)
    result = {}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if is_polymorphic_field_type(field.type) then
            result[field.name] = field
        end
    end
    return result
end

--------------------------------------------------------------------------
-- Polymorphic references (a "source" that can be a plant or a sample,
-- decided per row) -- see is_polymorphic_field_type's own header
-- comment for why this needs a different storage shape than
-- multi_reference's per-(entity_type, field_name) junction table.
--------------------------------------------------------------------------

-- ONE shared table across every polymorphic field on every entity type
-- -- not a table per (entity_type, field_name) the way
-- ensure_multi_field_table creates, since to_type itself varies row by
-- row and can't be a fixed FK target. No FK constraints on from_id/
-- to_id (the target table varies), so referential integrity here is
-- enforced at the application layer (entity.validate), the same trust
-- boundary reference/multi_reference already put on entity.lua rather
-- than the database for their own existence checks.
function schema.ensure_entity_source_table(db_path)
    if db.table_exists(db_path, "entity_source") then
        return
    end
    db.exec(db_path, "CREATE TABLE entity_source (" ..
        "id INTEGER PRIMARY KEY " .. db.autoincrement_keyword(db_path) .. ", " ..
        "from_type VARCHAR(255) NOT NULL, " ..
        "from_id INTEGER NOT NULL, " ..
        "field_name VARCHAR(255) NOT NULL, " ..
        "to_type VARCHAR(255) NOT NULL, " ..
        "to_id INTEGER NOT NULL, " ..
        "created_at TEXT DEFAULT (" .. db.now_expr(db_path) .. ")" ..
        ");")
    db.exec(db_path, "CREATE INDEX idx_entity_source_from ON entity_source (from_type, from_id, field_name);")
end

-- A single polymorphic item, in whichever shape the caller handed it:
-- already a real {type=..., id=...} table (JSON API payloads, decoded
-- by dkjson before reaching here), or a CLI-friendly "type:id" string
-- (e.g. "sample:92785") -- the CLI's plain `field=value` args have no
-- native table shape, so this is the same "flexible input, one real
-- internal shape" split schema.normalize_multi_value already draws for
-- multi_reference's own comma-separated ids, just with a type prefix
-- since a bare id alone doesn't say which table it belongs to.
function parse_polymorphic_item(item)
    if type(item) == "table" then
        return item
    end
    s = tostring(item)
    colon_pos = string.find(s, ":")
    if colon_pos == nil then
        return nil
    end
    return {type = string.sub(s, 1, colon_pos - 1), id = tonumber(string.sub(s, colon_pos + 1))}
end

-- Normalizes a polymorphic field's raw input value (nil, a single
-- {type=,id=} table, a list of them, or a CLI "type:id[,type:id...]"
-- string) into a plain list of {type=, id=} tables -- schema.
-- normalize_multi_value's own counterpart for this field family.
function schema.normalize_polymorphic_value(value)
    if value == nil then
        return {}
    end
    if type(value) == "table" then
        if value.type != nil then
            return {value}
        end
        items = {}
        for _, item in ipairs(value) do
            parsed = parse_polymorphic_item(item)
            if parsed != nil then
                table.insert(items, parsed)
            end
        end
        return items
    end
    items = {}
    for raw in string.gmatch(tostring(value), "[^,]+") do
        trimmed = (string.gsub(raw, "^%s*(.-)%s*$", "%1"))
        if trimmed != "" then
            parsed = parse_polymorphic_item(trimmed)
            if parsed != nil then
                table.insert(items, parsed)
            end
        end
    end
    return items
end

-- Replaces the full current set for one entity's polymorphic field --
-- same delete-then-reinsert "recompute wholesale" pattern
-- write_multi_field already uses.
function schema.write_polymorphic_field(db_path, entity_type, entity_id, field, value)
    schema.ensure_entity_source_table(db_path)
    db.exec(db_path, string.format(
        "DELETE FROM entity_source WHERE from_type = %s AND from_id = %d AND field_name = %s;",
        db.quote(entity_type), tonumber(entity_id), db.quote(field.name)
    ))
    for _, item in ipairs(schema.normalize_polymorphic_value(value)) do
        db.exec(db_path, string.format(
            "INSERT INTO entity_source (from_type, from_id, field_name, to_type, to_id) VALUES (%s, %d, %s, %s, %d);",
            db.quote(entity_type), tonumber(entity_id), db.quote(field.name), db.quote(item.type), tonumber(item.id)
        ))
    end
end

-- The current set for one entity's polymorphic field, as a plain array
-- of {type=, id=} tables (schema.read_multi_field's own counterpart).
function schema.read_polymorphic_field(db_path, entity_type, entity_id, field)
    if db.table_exists(db_path, "entity_source") == false then
        return {}
    end
    rows = db.query(db_path, string.format(
        "SELECT to_type, to_id FROM entity_source WHERE from_type = %s AND from_id = %d AND field_name = %s;",
        db.quote(entity_type), tonumber(entity_id), db.quote(field.name)
    ))
    if rows == nil then
        return {}
    end
    values = {}
    for _, row in ipairs(rows) do
        table.insert(values, {type = row.to_type, id = tonumber(row.to_id)})
    end
    return values
end

-- Creates the projected table if it doesn't exist, or adds any columns
-- for fields/builtins that aren't present yet. Never drops or renames a
-- column -- that's a deliberately manual, reviewed operation, not an
-- automatic one. Multivalue fields never become a column
-- here at all -- schema.ensure_multi_field_table gives them their own
-- companion junction table instead.
function schema.sync_table(db_path, def)
    if db.table_exists(db_path, def.name) == false then
        columns = {"id INTEGER PRIMARY KEY " .. db.autoincrement_keyword(db_path)}
        for _, field in ipairs(def.fields) do
            if is_multi_field_type(field.type) == false and is_polymorphic_field_type(field.type) == false then
                table.insert(columns, db.quote_ident(field.name) .. " " .. SQL_TYPE[field.type])
            end
        end
        for _, builtin in ipairs(builtin_columns(db_path)) do
            table.insert(columns, db.quote_ident(builtin.name) .. " " .. builtin.sql_type)
        end
        db.exec(db_path, string.format(
            "CREATE TABLE %s (%s);", def.name, table.concat(columns, ", ")
        ))
        index_name = "idx_" .. def.name .. "_external_id"
        if db.index_exists(db_path, def.name, index_name) == false then
            db.exec(db_path, string.format(
                "CREATE INDEX %s ON %s (%s);",
                index_name, def.name, db.text_index_column(db_path, "external_id")
            ))
        end
        for _, field in ipairs(def.fields) do
            if is_multi_field_type(field.type) then
                schema.ensure_multi_field_table(db_path, def.name, field)
            elseif is_polymorphic_field_type(field.type) then
                schema.ensure_entity_source_table(db_path)
            end
        end
        return
    end

    existing = db.get_columns(db_path, def.name)
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    for _, field in ipairs(def.fields) do
        if is_multi_field_type(field.type) then
            schema.ensure_multi_field_table(db_path, def.name, field)
        elseif is_polymorphic_field_type(field.type) then
            schema.ensure_entity_source_table(db_path)
        elseif have[field.name] == nil then
            db.exec(db_path, string.format(
                "ALTER TABLE %s ADD COLUMN %s %s;", def.name, db.quote_ident(field.name), SQL_TYPE[field.type]
            ))
        end
    end
    for _, builtin in ipairs(builtin_columns(db_path)) do
        if have[builtin.name] == nil then
            db.exec(db_path, string.format(
                "ALTER TABLE %s ADD COLUMN %s %s;", def.name, db.quote_ident(builtin.name), builtin.sql_type
            ))
        end
    end
    index_name = "idx_" .. def.name .. "_external_id"
    if db.index_exists(db_path, def.name, index_name) == false then
        db.exec(db_path, string.format(
            "CREATE INDEX %s ON %s (%s);",
            index_name, def.name, db.text_index_column(db_path, "external_id")
        ))
    end
end

-- A cheap-to-compute stand-in for "have the schemas/dropdowns
-- directories changed at all since the last real sync" -- name +
-- mtime + size per .lua file (sorted, so file iteration order never
-- matters), concatenated. Re-running the sync (schema.sync_all's own
-- loops below) costs real, multi-second time once a deployment has
-- enough schema/dropdown files against a real remote database -- a
-- plain filesystem stat of every file is negligible by comparison, so
-- this lets sync_all skip the expensive work entirely on the
-- overwhelming majority of requests in steady-state traffic (nothing
-- changed since last time).
function schema.content_signature(root)
    config = require("config")
    parts = {}
    for _, dir in ipairs({config.dropdowns_dir(root), config.schemas_dir(root)}) do
        attr = lfs.attributes(dir)
        if attr != nil and attr.mode == "directory" then
            names = {}
            for file_name in lfs.dir(dir) do
                if string.match(file_name, "%.lua$") != nil then
                    table.insert(names, file_name)
                end
            end
            table.sort(names)
            for _, file_name in ipairs(names) do
                file_attr = lfs.attributes(paths.joinpath(dir, file_name))
                table.insert(parts, dir .. "/" .. file_name .. ":" ..
                    tostring(file_attr.modification) .. ":" .. tostring(file_attr.size))
            end
        end
    end
    return table.concat(parts, "|")
end

function schema.stored_sync_signature(db_path)
    rows = db.query(db_path, "SELECT content_signature FROM schema_sync_state WHERE id = 1;")
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].content_signature
end

function schema.store_sync_signature(db_path, signature)
    db.exec(db_path, string.format(
        "%s schema_sync_state (id, content_signature) VALUES (1, %s);",
        db.replace_into(db_path), db.quote(signature)
    ))
end

-- Scans the schemas directory, registers any schema files found,
-- and ensures all projected tables are synced/created.
-- Dropdowns first, always -- an entity schema field can reference a
-- named dropdown (`dropdown = "..."`), and schema.register resolves
-- that reference's *current* values immediately (into entity_field.
-- enum_values), so the dropdown must already be registered by the time
-- any schema file referencing it is processed. dropdowns/ missing
-- entirely is fine (no dropdowns defined yet) -- only schemas/ missing
-- is a real error, since every deployment has at least that directory.
--
-- Skipped entirely when content_signature matches what was
-- stored after the last real pass -- see that function's own comment.
function schema.sync_all(db_path, root)
    config = require("config")

    signature = schema.content_signature(root)
    if signature == schema.stored_sync_signature(db_path) then
        return true
    end

    dropdowns_dir = config.dropdowns_dir(root)
    attr = lfs.attributes(dropdowns_dir)
    if attr != nil and attr.mode == "directory" then
        for file_name in lfs.dir(dropdowns_dir) do
            if string.match(file_name, "%.lua$") != nil then
                full_path = paths.joinpath(dropdowns_dir, file_name)
                def, err = schema.load_dropdown_file(full_path)
                if def != nil then
                    schema.register_dropdown(db_path, def)
                end
            end
        end
    end

    schemas_dir = config.schemas_dir(root)
    attr = lfs.attributes(schemas_dir)
    if attr == nil or attr.mode != "directory" then
        return false, "schemas directory not found: " .. schemas_dir
    end
    for file_name in lfs.dir(schemas_dir) do
        if string.match(file_name, "%.lua$") != nil then
            full_path = paths.joinpath(schemas_dir, file_name)
            def, err = schema.load_file(full_path)
            if def != nil then
                schema.register(db_path, def)
            end
        end
    end
    schema.store_sync_signature(db_path, signature)
    return true
end

-- The schema layout as a plain Luam table: {name, fields = {{name, label,
-- type, required, values?, ref_entity_type?}, ...}}. Shared by
-- schema.show_json (JSON for the client-side registration table) and
-- the browse/detail HTML views (cgi.lua/html.lua) -- one source of
-- truth for "what does this entity type's layout look like", native
-- consumers don't need to decode JSON just to get a Luam table back.
-- Prefers labels from the version-controlled schema file if available,
-- falling back to the database description (e.g. for a schema whose
-- file was since removed but whose table/data still exists).
function schema.layout(db_path, name)
    config = require("config")
    schemas_dir = config.schemas_dir()
    path = paths.joinpath(schemas_dir, name .. ".lua")
    def = nil
    if paths.file_exists(path) then
        def = schema.load_file(path)
    end

    if def != nil then
        -- A field.dropdown = "<name>" reference has no `values` of its
        -- own in the raw file -- schema sync resolves the dropdown's
        -- current values into this field's own `entity_field.enum_values`
        -- column (see schema.sync_all), which is the only place they
        -- live for a dropdown-referencing field. This loop must check
        -- both the raw file's own `field.values` (a field that inlines
        -- its own literal list) AND the resolved dropdown values --
        -- checking only the former sends no `values` array at all for
        -- a dropdown-referencing select field, and the register page's
        -- own client-side JS (addRow(), html.lua) crashes on
        -- `field.values.forEach` the instant it reaches one, breaking
        -- the whole batch-entry table for any entity type with a
        -- dropdown-based select (e.g. cell_line's required
        -- `tissue_code`), not just that one field.
        dkjson = require("dkjson")
        db_fields_by_name = {}
        for _, f in ipairs(schema.fields(db_path, name)) do
            db_fields_by_name[f.name] = f
        end

        result = {
            name = def.name,
            fields = {}
        }
        for _, field in ipairs(def.fields) do
            required = (field.required == true)
            label = field.label
            if label == nil then
                label = string.gsub(string.gsub(field.name, "^%l", string.upper), "_", " ")
            end
            field_def = {
                name = field.name,
                label = label,
                type = field.type,
                required = required
            }
            if field.values != nil then
                field_def.values = field.values
            elseif field.dropdown != nil then
                db_field = db_fields_by_name[field.name]
                if db_field != nil and db_field.enum_values != nil and db_field.enum_values != "" then
                    field_def.values = dkjson.decode(db_field.enum_values)
                end
            end
            if field.entity_type != nil then
                field_def.ref_entity_type = field.entity_type
            end
            if field.allowed_entity_types != nil then
                field_def.allowed_entity_types = field.allowed_entity_types
            end
            if field.min != nil then
                field_def.min = field.min
            end
            if field.max != nil then
                field_def.max = field.max
            end
            table.insert(result.fields, field_def)
        end
        return result
    else
        dkjson = require("dkjson")
        if schema.is_registered(db_path, name) == false then
            return nil, "unknown entity type: " .. name
        end
        fields = schema.fields(db_path, name)
        result = {
            name = name,
            fields = {}
        }
        for _, f in ipairs(fields) do
            required = (tonumber(f.required) == 1)
            label = string.gsub(string.gsub(f.name, "^%l", string.upper), "_", " ")
            field_def = {
                name = f.name,
                label = label,
                type = f.type,
                required = required
            }
            if f.enum_values != nil and f.enum_values != "" then
                field_def.values = dkjson.decode(f.enum_values)
            end
            if f.ref_entity_type != nil and f.ref_entity_type != "" then
                field_def.ref_entity_type = f.ref_entity_type
            end
            if f.allowed_entity_types != nil and f.allowed_entity_types != "" then
                field_def.allowed_entity_types = dkjson.decode(f.allowed_entity_types)
            end
            table.insert(result.fields, field_def)
        end
        return result
    end
end

-- Renders the schema structure as a JSON string (see schema.layout).
function schema.show_json(db_path, name)
    layout, err = schema.layout(db_path, name)
    if layout == nil then
        return nil, err
    end
    dkjson = require("dkjson")
    return dkjson.encode(layout)
end

-- Whether `name` has the shape a real registered entity-type name could
-- ever have -- lowercase ASCII letters/digits/underscore, not starting
-- with a digit, matching how every real schema file names itself
-- (`schema.register`'s `def.name`, always written this way by hand).
--
-- Security finding, fixed 2026-07-17 (see platform's own TODO.md, M3):
-- `entity_type` flows unescaped into raw SQL as a table name
-- (`entity.lua`/`db.lua`, `"SELECT * FROM " .. entity_type`) and into a
-- file path for schema lookup (`schemas_dir .. "/" .. name .. ".lua"`)
-- wherever it comes from a request parameter (`params.type`). Every
-- call site happened to be safe only because it incidentally checked
-- the name resolves via schema.layout/schema.fields first -- not a
-- deliberate guard. This is that guard: a single charset check, applied
-- once, centrally, at every point in cgi.lua where `params.type`/
-- `params.ref_type`-shaped external input becomes an `entity_type`,
-- before it can reach any raw SQL or path-building call.
function schema.valid_name_syntax(name)
    return type(name) == "string" and string.match(name, "^[a-z_][a-z0-9_]*$") != nil
end

-- Whether `entity_type` has been registered at all. A registered type
-- can legitimately have zero custom fields (e.g. a schema whose only
-- data is its name plus the system-managed created/updated columns),
-- so callers must not use "schema.fields() returned nothing" as a
-- stand-in for "this type doesn't exist" -- that conflates the two.
function schema.is_registered(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT 1 FROM entity_type WHERE name = %s;",
        db.quote(entity_type)
    ))
    return rows != nil and #rows > 0
end

-- Plain Levenshtein edit distance -- only used below to guess an intended
-- entity type name, never on a performance-sensitive path, so no need for
-- anything fancier.
function levenshtein(a, b)
    la, lb = #a, #b
    if la == 0 then
        return lb
    end
    if lb == 0 then
        return la
    end
    prev = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        curr = {[0] = i}
        for j = 1, lb do
            cost = 1
            if string.sub(a, i, i) == string.sub(b, j, j) then
                cost = 0
            end
            curr[j] = math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = curr
    end
    return prev[lb]
end

-- Best-guess registered entity type for a name that turned out not to be
-- registered -- e.g. an agent (or API caller) passing the plural "samples"
-- when the real type is "sample". Returns nil when nothing registered is
-- close enough: a wrong-but-confident suggestion is worse than none for a
-- caller deciding whether to retry with it. Found live: an agent burned a
-- whole extra tool call listing every entity type just to self-correct
-- this exact plural guess, because the error it got back for "samples"
-- gave it nothing to go on.
function schema.suggest_type(db_path, entity_type)
    if type(entity_type) != "string" or entity_type == "" then
        return nil
    end
    name = string.lower(entity_type)
    best, best_dist = nil, nil
    for _, t in ipairs(schema.list(db_path)) do
        candidate = string.lower(t.name)
        dist = levenshtein(name, candidate)
        max_len = math.max(#name, #candidate)
        threshold = math.max(1, math.floor(max_len / 3))
        if dist <= threshold and (best_dist == nil or dist < best_dist) then
            best, best_dist = t.name, dist
        end
    end
    return best
end

-- Task #93's reason-for-change opt-in flags for one registered entity
-- type -- what entity.update/entity.archive check before requiring
-- (or not) a non-empty `reason` argument. Defaults both false for an
-- unregistered type rather than erroring -- callers already handle
-- "no such entity" separately.
function schema.reason_flags(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT require_reason_on_update, require_reason_on_archive FROM entity_type WHERE name = %s;",
        db.quote(entity_type)
    ))
    if rows == nil or rows[1] == nil then
        return {require_on_update = false, require_on_archive = false}
    end
    return {
        require_on_update = tonumber(rows[1].require_reason_on_update) == 1,
        require_on_archive = tonumber(rows[1].require_reason_on_archive) == 1,
    }
end

-- Whether writes (create/update/archive) to this entity type
-- require Admin capability -- checked in cgi.lua, which has the HTTP
-- session's capabilities in scope (schema.lua/entity.lua don't).
function schema.admin_write_only(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT admin_write_only FROM entity_type WHERE name = %s;", db.quote(entity_type)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    return tonumber(rows[1].admin_write_only) == 1
end

-- The registered field list for an entity type, in declaration order --
-- what entity.lua validates rows against.
function schema.fields(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT * FROM entity_field WHERE entity_type = %s ORDER BY field_order ASC;",
        db.quote(entity_type)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Every reference relationship between registered entity types --
-- {from_type, to_type, field_name}, one per reference-typed field, across
-- every registered schema. Backs the Data page's entity-relation diagram;
-- a pure introspection query (like schema.fields()), so it belongs here
-- rather than in html.lua/cgi.lua alongside the rendering.
function schema.relationships(db_path)
    types = schema.list(db_path)
    edges = {}
    for _, t in ipairs(types) do
        fields = schema.fields(db_path, t.name)
        for _, field in ipairs(fields) do
            if (field.type == "reference" or field.type == "multi_reference") and field.ref_entity_type != nil and field.ref_entity_type != "" then
                -- field_type lets a caller tell a plain
                -- `reference` (a real column on from_type -- reverse-
                -- queryable directly, see cgi.lua's related_records)
                -- apart from `multi_reference` (stored in a separate
                -- junction table instead, schema.ensure_multi_field_table
                -- -- not reverse-queryable the same way).
                table.insert(edges, {from_type = t.name, to_type = field.ref_entity_type, field_name = field.name, field_type = field.type})
            elseif is_polymorphic_field_type(field.type) and field.allowed_entity_types != nil then
                -- One edge per allowed target type -- a real lineage
                -- investigation (research.investigate/entity.relationships)
                -- needs to see e.g. "sample.source -> plant" AND
                -- "sample.source -> sample" both, not just one collapsed
                -- row hiding which types are actually possible. Found
                -- live: a chat query exploring "sample lineages" missed
                -- this kind of edge entirely before polymorphic fields
                -- existed at all, since there was nowhere for it to show
                -- up in this list -- don't repeat that gap now that
                -- there is one.
                json = require("dkjson")
                allowed_types = json.decode(field.allowed_entity_types)
                if allowed_types != nil then
                    for _, to_type in ipairs(allowed_types) do
                        table.insert(edges, {from_type = t.name, to_type = to_type, field_name = field.name, field_type = field.type})
                    end
                end
            end
        end
    end
    return edges
end

function schema.list(db_path)
    rows = db.query(db_path, "SELECT name FROM entity_type ORDER BY name ASC;")
    if rows == nil then
        return {}
    end
    return rows
end

-- CLI entry point: `daat schema <add|list|show|show-json|sync> [args]`
function schema.do_schema(cmd_args, db_path)
    action = cmd_args[1]

    if action == "add" then
        path = cmd_args[2]
        if path == nil then
            print("Usage: daat schema add <file>")
            return
        end
        def, err = schema.load_file(path)
        if def == nil then
            print("Error: " .. err)
            return
        end
        schema.register(db_path, def)
        print("Registered entity type '" .. def.name .. "'")
        return
    end

    if action == "list" then
        schema.sync_all(db_path)
        for _, row in ipairs(schema.list(db_path)) do
            print(row.name)
        end
        return
    end

    if action == "show-json" or (action == "show" and cmd_args[3] == "--json") then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat schema show-json <name>")
            return
        end
        schema.sync_all(db_path)
        json_str, err = schema.show_json(db_path, name)
        if json_str == nil then
            print("Error: " .. tostring(err))
            return
        end
        print(json_str)
        return
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat schema show <name>")
            return
        end
        schema.sync_all(db_path)
        for _, field in ipairs(schema.fields(db_path, name)) do
            required = "optional"
            if tonumber(field.required) == 1 then
                required = "required"
            end
            print(string.format("%-20s %-10s %s", field.name, field.type, required))
        end
        return
    end

    if action == "sync" then
        ok, err = schema.sync_all(db_path)
        if not ok then
            print("Error: " .. tostring(err))
        else
            print("Schema sync complete")
        end
        return
    end

    print("Usage: daat schema <add|list|show|show-json|sync> [args]")
end

-- Exposed purely so tst/unit/schema.lua can reach it across the
-- require() boundary -- see the matching comment in
-- agent_claude.lua.
schema.is_multi_field_type = is_multi_field_type

return schema
