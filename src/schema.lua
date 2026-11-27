-- Loads sandboxed entity/dropdown definitions and syncs projected SQL tables. See doc/schema.md.

const db = require("database")
const sandbox = require("sandbox")
const paths = require("paths")
const lfs = require("lfs")
const config_lib = require("config")
const extension_lib = require("extension")
const store_lib = require("store")
const json_lib = require("dkjson")

const schema = {}

_fields_cache = {}
_registered_cache = {}
_multi_table_ready = {}
_entity_source_ready = {}

function schema_cache_key(db_path)
    return db.cache_key(db_path)
end

function invalidate_schema_cache(db_path)
    if db_path == nil then
        _fields_cache = {}
        _registered_cache = {}
        _multi_table_ready = {}
        _entity_source_ready = {}
        return
    end
    key = schema_cache_key(db_path)
    _fields_cache[key] = nil
    _registered_cache[key] = nil
    _multi_table_ready[key] = nil
    _entity_source_ready[key] = nil
end

schema.clear_cache = invalidate_schema_cache

function shallow_copy_list(items)
    out = {}
    for i, v in ipairs(items) do
        out[i] = v
    end
    return out
end

const FIELD_TYPES = {"text", "number", "date", "select", "reference", "multi_select", "multi_reference", "sql_select", "polymorphic_reference", "multi_polymorphic_reference"}

-- Stored in companion <entity_type>_<field> junction tables rather than scalar columns.
const MULTI_FIELD_TYPES = {multi_select = true, multi_reference = true}

function is_multi_field_type(t)
    return MULTI_FIELD_TYPES[t] == true
end

-- Target type varies per row; stored in shared entity_ref table. See doc/schema.md.
const POLYMORPHIC_FIELD_TYPES = {polymorphic_reference = true, multi_polymorphic_reference = true}

function is_polymorphic_field_type(t)
    return POLYMORPHIC_FIELD_TYPES[t] == true
end

const DROPDOWN_SCHEMA = """
CREATE TABLE IF NOT EXISTS entity_dropdown_value (
    list_name VARCHAR(255) NOT NULL,
    value VARCHAR(255) NOT NULL,
    value_order INTEGER NOT NULL,
    PRIMARY KEY (list_name, value)
);

"""

function schema.init_schema(db_path)
    invalidate_schema_cache(db_path)
    db.exec(db_path, DROPDOWN_SCHEMA)
end

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

function schema.register_dropdown(db_path, def)
    function write_dropdown_tx()
        db.exec(db_path, string.format("DELETE FROM entity_dropdown_value WHERE list_name = %s;", db.quote(def.name)))
        if #def.values > 0 then
            value_tuples = {}
            for i, value in ipairs(def.values) do
                table.insert(value_tuples, string.format("(%s, %s, %d)", db.quote(def.name), db.quote(value), i))
            end
            db.exec(db_path, string.format(
                "%s entity_dropdown_value (list_name, value, value_order) VALUES %s;",
                db.insert_ignore(db_path), table.concat(value_tuples, ", ")
            ))
        end
        return true
    end
    return db.transaction(db_path, write_dropdown_tx)
end

function schema.dropdown_values(db_path, name)
    rows = db.query(db_path, string.format(
        "SELECT value FROM entity_dropdown_value WHERE list_name = %s ORDER BY value_order ASC;", db.quote(name)
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

function resolve_field_values(db_path, field)
    if field.values != nil then
        return field.values
    end
    if field.dropdown != nil then
        return schema.dropdown_values(db_path, field.dropdown)
    end
    return {}
end

-- Builtin columns present on every projected entity table (cannot be reused as field names).
const RESERVED_FIELD_NAMES = {
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

-- SQL keywords reserved unquoted in SQLite or MariaDB; checked on entity-type names only
-- (columns are quoted via db.quote_ident). See doc/mariadb-migration.md.
const RESERVED_SQL_WORDS = {
    "accessible", "add", "all", "alter", "analyze", "and", "as", "asc",
    "asensitive", "autoincrement", "before", "between", "bigint", "binary",
    "blob", "both", "by", "call", "cascade", "case", "change", "char",
    "character", "check", "collate", "column", "commit", "condition",
    "constraint", "continue", "convert", "create", "cross", "current_date",
    "current_role", "current_time", "current_timestamp", "current_user",
    "cursor", "databases", "day_hour", "day_microsecond", "day_minute",
    "day_second", "dec", "decimal", "declare", "default", "deferrable",
    "delayed", "delete", "delete_domain_id", "desc", "describe",
    "deterministic", "distinct", "distinctrow", "div", "do_domain_ids",
    "double", "drop", "each", "else", "elseif", "enclosed", "escape",
    "escaped", "except", "exists", "exit", "explain", "false", "fetch",
    "float", "float4", "float8", "for", "force", "foreign", "from",
    "fulltext", "grant", "group", "having", "high_priority",
    "hour_microsecond", "hour_minute", "hour_second", "if", "ignore",
    "ignore_domain_ids", "in", "index", "infile", "inner", "inout",
    "insensitive", "insert", "int", "int1", "int2", "int3", "int4", "int8",
    "integer", "intersect", "interval", "into", "is", "isnull", "iterate",
    "join", "key", "keys", "kill", "leading", "leave", "left", "like",
    "limit", "linear", "lines", "load", "localtime", "localtimestamp",
    "lock", "long", "longblob", "longtext", "loop", "low_priority",
    "master_ssl_verify_server_cert", "match", "maxvalue", "mediumblob",
    "mediumint", "mediumtext", "middleint", "minute_microsecond",
    "minute_second", "mod", "modifies", "natural", "no_write_to_binlog",
    "not", "nothing", "notnull", "null", "numeric", "offset", "on",
    "optimize", "optionally", "or", "order", "out", "outer", "outfile",
    "over", "page_checksum", "partition", "portion", "precision", "primary",
    "procedure", "purge", "range", "read", "read_write", "reads", "real",
    "recursive", "references", "regexp", "release", "rename", "repeat",
    "replace", "require", "resignal", "restrict", "return", "returning",
    "revoke", "right", "rlike", "row_number", "rows", "schemas",
    "second_microsecond", "select", "sensitive", "separator", "set", "show",
    "signal", "smallint", "spatial", "specific", "sql", "sql_big_result",
    "sql_calc_found_rows", "sql_small_result", "sqlexception", "sqlstate",
    "sqlwarning", "ssl", "starting", "stats_auto_recalc", "stats_persistent",
    "stats_sample_pages", "straight_join", "table", "terminated", "then",
    "tinyblob", "tinyint", "tinytext", "to", "trailing", "transaction",
    "trigger", "true", "undo", "union", "unique", "unlock", "unsigned",
    "update", "usage", "use", "using", "utc_date", "utc_time",
    "utc_timestamp", "value", "values", "varbinary", "varchar",
    "varcharacter", "varying", "when", "where", "while", "with", "write",
    "xor", "year_month", "zerofill",
}

const RESERVED_SQL_WORDS_SET = {}
for _, w in ipairs(RESERVED_SQL_WORDS) do
    RESERVED_SQL_WORDS_SET[w] = true
end

function is_reserved_sql_word(name)
    return type(name) == "string" and RESERVED_SQL_WORDS_SET[string.lower(name)] == true
end

-- Internal platform tables that user entity schemas must never shadow.
const RESERVED_PLATFORM_TABLES = {
    "agent_background_task", "agent_message", "agent_model_call",
    "agent_pending_action", "agent_session", "auth_api_key",
    "auth_email_link", "auth_user", "document_aspect", "document_embedding",
    "document_embedding_due", "document_link", "document_link_sync",
    "document_mention", "document_passage_cache", "document_tier_judgment",
    "entity_dropdown_value", "entity_event", "entity_field",
    "entity_name_index", "entity_name_prefix", "entity_ref", "entity_type",
    "knowledge_aspect_curation", "knowledge_conversation_curation",
    "knowledge_curation", "knowledge_distillation", "knowledge_link_review",
    "knowledge_pool_state", "knowledge_reference", "knowledge_retrieval",
    "knowledge_retrieval_hit", "knowledge_tag_definition", "sqlite_master",
    "sqlite_schema", "sqlite_sequence", "system_approval", "system_job",
    "system_state", "tag_centre", "tag_judgment", "tag_upkeep",
}

const RESERVED_PLATFORM_TABLES_SET = {}
for _, t in ipairs(RESERVED_PLATFORM_TABLES) do
    RESERVED_PLATFORM_TABLES_SET[t] = true
end

function is_reserved_table_name(name)
    return type(name) == "string" and RESERVED_PLATFORM_TABLES_SET[string.lower(name)] == true
end

function schema.valid_name_syntax(name)
    return type(name) == "string" and string.match(name, "^[a-z_][a-z0-9_]*$") != nil
end

-- LONGTEXT avoids MariaDB's 64 KB TEXT cap while keeping SQLite TEXT affinity. See doc/mariadb-migration.md.
const SQL_TYPE = {
    text = "LONGTEXT",
    number = "REAL",
    date = "TEXT",
    select = "TEXT",
    reference = "INTEGER",
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

-- Offline structural check; cross-entity checks run at register/entity.validate time.
function schema.validate(def)
    if type(def) != "table" then
        return "schema definition must be a table"
    end
    if type(def.name) != "string" or def.name == "" then
        return "schema must have a non-empty string 'name'"
    end
    if schema.valid_name_syntax(def.name) == false then
        return string.format("schema '%s': name must match ^[a-z_][a-z0-9_]*$ (lowercase letters, digits, and underscores, not starting with a digit)", def.name)
    end
    if is_reserved_sql_word(def.name) then
        return string.format("schema '%s': '%s' is a reserved SQL word -- choose a different entity type name", def.name, def.name)
    end
    if is_reserved_table_name(def.name) then
        return string.format("schema '%s': collides with an internal platform table of the same name -- choose a different entity type name", def.name)
    end
    if type(def.fields) != "table" then
        return "schema '" .. tostring(def.name) .. "' must have a 'fields' list"
    end
    if def.require_reason_on_update != nil and def.require_reason_on_update != true and def.require_reason_on_update != false then
        return string.format("schema '%s': 'require_reason_on_update' must be true or false", def.name)
    end
    if def.require_reason_on_archive != nil and def.require_reason_on_archive != true and def.require_reason_on_archive != false then
        return string.format("schema '%s': 'require_reason_on_archive' must be true or false", def.name)
    end
    if def.admin_write_only != nil and def.admin_write_only != true and def.admin_write_only != false then
        return string.format("schema '%s': 'admin_write_only' must be true or false", def.name)
    end
    seen_fields = {}
    for i, field in ipairs(def.fields) do
        if type(field.name) != "string" or field.name == "" then
            return string.format("schema '%s' field #%d: missing 'name'", def.name, i)
        end
        if schema.valid_name_syntax(field.name) == false then
            return string.format("schema '%s' field '%s': name must match ^[a-z_][a-z0-9_]*$ (lowercase letters, digits, and underscores, not starting with a digit)", def.name, field.name)
        end
        if is_reserved_field_name(field.name) then
            return string.format("schema '%s' field '%s': collides with a builtin column of the same name -- choose a different field name", def.name, field.name)
        end
        if seen_fields[field.name] == true then
            return string.format("schema '%s' field '%s': duplicate field name", def.name, field.name)
        end
        seen_fields[field.name] = true
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
        -- Indexed by document.reference; restricted to text/select so stored values round-trip verbatim.
        if field.identifier != nil and field.identifier != true and field.identifier != false then
            return string.format("schema '%s' field '%s': 'identifier' must be true or false", def.name, field.name)
        end
        if field.identifier == true and field.type != "text" and field.type != "select" then
            return string.format("schema '%s' field '%s': type '%s' can't be an identifier, only text and select can",
                def.name, field.name, field.type)
        end
        -- UI input bounds hint only; server-side range checks belong in before-hook extensions.
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

function ensure_entity_field_display_column(db_path)
    store_lib.ensure_columns(db_path, "entity_field", {
        {"display", "INTEGER DEFAULT 0"},
        {"allowed_entity_types", "LONGTEXT"},
        {"identifier", "INTEGER DEFAULT 0"},
    })
end

function ensure_entity_type_reason_flag_columns(db_path)
    store_lib.ensure_columns(db_path, "entity_type", {
        {"require_reason_on_update", "INTEGER DEFAULT 0"},
        {"require_reason_on_archive", "INTEGER DEFAULT 0"},
        {"admin_write_only", "INTEGER DEFAULT 0"},
    })
end

function schema.register(db_path, def)
    ensure_entity_field_display_column(db_path)
    ensure_entity_type_reason_flag_columns(db_path)

    -- Sync DDL outside db.transaction: MariaDB implicitly commits open transactions on DDL.
    -- See doc/mariadb-migration.md.
    schema.sync_table(db_path, def)

    function write_schema_metadata_tx()
        db.exec(db_path, string.format(
            "%s entity_type (name) VALUES (%s);", db.insert_ignore(db_path), db.quote(def.name)
        ))

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
                enum_json = json_lib.encode(resolve_field_values(db_path, field))
            end
            allowed_types_json = nil
            if is_polymorphic_field_type(field.type) then
                allowed_types_json = json_lib.encode(field.allowed_entity_types)
            end
            required_flag = 0
            if field.required == true then
                required_flag = 1
            end
            display_flag = 0
            if field.display == true then
                display_flag = 1
            end
            identifier_flag = 0
            if field.identifier == true then
                identifier_flag = 1
            end
            db.exec(db_path, string.format(
                "%s entity_field (entity_type, name, type, required, enum_values, ref_entity_type, field_order, display, allowed_entity_types, identifier) VALUES (%s, %s, %s, %d, %s, %s, %d, %d, %s, %d);",
                db.replace_into(db_path),
                db.quote(def.name), db.quote(field.name), db.quote(field.type),
                required_flag,
                db.literal(enum_json),
                db.literal(field.entity_type),
                i,
                display_flag,
                db.literal(allowed_types_json),
                identifier_flag
            ))
        end

        -- Retire removed entity_field metadata without dropping projected table columns or data.
        current_names = {}
        for _, field in ipairs(def.fields) do
            table.insert(current_names, db.quote(field.name))
        end
        retired_sql = string.format("DELETE FROM entity_field WHERE entity_type = %s", db.quote(def.name))
        if #current_names > 0 then
            retired_sql = retired_sql .. " AND name NOT IN (" .. table.concat(current_names, ", ") .. ")"
        end
        db.exec(db_path, retired_sql .. ";")
        return true
    end

    db.transaction(db_path, write_schema_metadata_tx)
    invalidate_schema_cache(db_path)
    return true
end

-- System columns added to every projected entity table; archived_at != NULL marks soft-archived rows.
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
        {name = "archived_at", sql_type = "TEXT"},
    }
end

function schema.multi_field_table_name(entity_type, field_name)
    return entity_type .. "_" .. field_name
end

function multi_field_value_column(field)
    if field.type == "multi_reference" then
        return field.name .. "_id"
    end
    return "value"
end

function schema.ensure_multi_field_table(db_path, entity_type, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    parent_col = entity_type .. "_id"
    value_col = multi_field_value_column(field)
    cache_key = schema_cache_key(db_path)
    bucket = _multi_table_ready[cache_key]
    if bucket != nil and bucket[table_name] == value_col then
        return
    end
    if db.table_exists(db_path, table_name) then
        has_value_col = false
        for _, col in ipairs(db.get_columns(db_path, table_name)) do
            if col == value_col then
                has_value_col = true
            end
        end
        if has_value_col then
            if bucket == nil then
                bucket = {}
                _multi_table_ready[cache_key] = bucket
            end
            bucket[table_name] = value_col
            return
        end
        existing_rows = db.query(db_path, string.format("SELECT 1 AS x FROM %s LIMIT 1;", db.quote_ident(table_name)))
        if existing_rows != nil and #existing_rows > 0 then
            error(string.format(
                "cannot change multivalue field '%s.%s' column to '%s' while companion table '%s' contains data",
                entity_type, field.name, value_col, table_name
            ))
        end
        db.exec(db_path, string.format("DROP TABLE %s;", db.quote_ident(table_name)))
    end
    ddl_sql = nil
    quoted_table = db.quote_ident(table_name)
    quoted_parent = db.quote_ident(parent_col)
    quoted_value = db.quote_ident(value_col)
    quoted_entity = db.quote_ident(entity_type)
    if field.type == "multi_reference" then
        -- Accepts both raw schema defs (.entity_type) and entity_field DB rows (.ref_entity_type).
        ref_type = entity_type
        if field.ref_entity_type != nil and field.ref_entity_type != "" then
            ref_type = field.ref_entity_type
        elseif field.entity_type != nil and field.entity_type != "" then
            ref_type = field.entity_type
        end
        ddl_sql = string.format("""
            CREATE TABLE IF NOT EXISTS %s (
                %s INTEGER NOT NULL,
                %s INTEGER NOT NULL,
                PRIMARY KEY (%s, %s),
                FOREIGN KEY (%s) REFERENCES %s (`id`),
                FOREIGN KEY (%s) REFERENCES %s (`id`)
            );
        """, quoted_table, quoted_parent, quoted_value, quoted_parent, quoted_value,
             quoted_parent, quoted_entity, quoted_value, db.quote_ident(ref_type))
    else
        ddl_sql = string.format("""
            CREATE TABLE IF NOT EXISTS %s (
                %s INTEGER NOT NULL,
                %s VARCHAR(255) NOT NULL,
                PRIMARY KEY (%s, %s),
                FOREIGN KEY (%s) REFERENCES %s (`id`)
            );
        """, quoted_table, quoted_parent, quoted_value, quoted_parent, quoted_value, quoted_parent, quoted_entity)
    end
    ok_ddl, ddl_err = pcall(db.exec, db_path, ddl_sql)
    if ok_ddl == false and db.table_exists(db_path, table_name) == false then
        error(ddl_err)
    end
    if bucket == nil then
        bucket = {}
        _multi_table_ready[cache_key] = bucket
    end
    bucket[table_name] = value_col
end

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

function schema.write_multi_field(db_path, entity_type, entity_id, field, value)
    schema.ensure_multi_field_table(db_path, entity_type, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    quoted_table = db.quote_ident(table_name)
    quoted_parent = db.quote_ident(entity_type .. "_id")
    quoted_value = db.quote_ident(multi_field_value_column(field))
    db.exec(db_path, string.format(
        "DELETE FROM %s WHERE %s = %d;", quoted_table, quoted_parent, tonumber(entity_id)
    ))
    for _, item in ipairs(schema.normalize_multi_value(value)) do
        if field.type == "multi_reference" then
            db.exec(db_path, string.format(
                "%s %s (%s, %s) VALUES (%d, %d);",
                db.insert_ignore(db_path), quoted_table, quoted_parent, quoted_value, tonumber(entity_id), tonumber(item)
            ))
        else
            db.exec(db_path, string.format(
                "%s %s (%s, %s) VALUES (%d, %s);",
                db.insert_ignore(db_path), quoted_table, quoted_parent, quoted_value, tonumber(entity_id), db.quote(tostring(item))
            ))
        end
    end
end

function schema.read_multi_field(db_path, entity_type, entity_id, field)
    table_name = schema.multi_field_table_name(entity_type, field.name)
    if db.table_exists(db_path, table_name) == false then
        return {}
    end
    parent_col = entity_type .. "_id"
    value_col = multi_field_value_column(field)
    rows = db.query(db_path, string.format(
        "SELECT %s AS v FROM %s WHERE %s = %d;",
        db.quote_ident(value_col), db.quote_ident(table_name), db.quote_ident(parent_col), tonumber(entity_id)
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

function schema.multi_fields_by_name(db_path, entity_type)
    result = {}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if is_multi_field_type(field.type) then
            result[field.name] = field
        end
    end
    return result
end

function schema.polymorphic_fields_by_name(db_path, entity_type)
    result = {}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if is_polymorphic_field_type(field.type) then
            result[field.name] = field
        end
    end
    return result
end

-- Shared polymorphic reference table (target table varies per row, so referential
-- integrity is enforced in entity.validate rather than SQL FKs).
function schema.ensure_entity_source_table(db_path)
    cache_key = schema_cache_key(db_path)
    if _entity_source_ready[cache_key] == true then
        return
    end
    if db.table_exists(db_path, "entity_ref") then
        if db.index_exists(db_path, "entity_ref", "idx_entity_source_from") == false then
            ok_idx, idx_err = pcall(db.exec, db_path, "CREATE INDEX idx_entity_source_from ON entity_ref (from_type, from_id, field_name);")
            if ok_idx == false and db.index_exists(db_path, "entity_ref", "idx_entity_source_from") == false then
                error(idx_err)
            end
        end
        _entity_source_ready[cache_key] = true
        return
    end
    ok_tbl, tbl_err = pcall(db.exec, db_path, "CREATE TABLE IF NOT EXISTS entity_ref (" ..
        "id INTEGER PRIMARY KEY " .. db.autoincrement_keyword(db_path) .. ", " ..
        "from_type VARCHAR(255) NOT NULL, " ..
        "from_id INTEGER NOT NULL, " ..
        "field_name VARCHAR(255) NOT NULL, " ..
        "to_type VARCHAR(255) NOT NULL, " ..
        "to_id INTEGER NOT NULL, " ..
        "created_at TEXT DEFAULT (" .. db.now_expr(db_path) .. ")" ..
        ");")
    if ok_tbl == false and db.table_exists(db_path, "entity_ref") == false then
        error(tbl_err)
    end
    if db.index_exists(db_path, "entity_ref", "idx_entity_source_from") == false then
        ok_idx, idx_err = pcall(db.exec, db_path, "CREATE INDEX idx_entity_source_from ON entity_ref (from_type, from_id, field_name);")
        if ok_idx == false and db.index_exists(db_path, "entity_ref", "idx_entity_source_from") == false then
            error(idx_err)
        end
    end
    _entity_source_ready[cache_key] = true
end

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

-- Normalizes {type, id} tables or CLI "type:id,..." strings into a list of {type, id} tables.
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

function schema.write_polymorphic_field(db_path, entity_type, entity_id, field, value)
    schema.ensure_entity_source_table(db_path)
    db.exec(db_path, string.format(
        "DELETE FROM entity_ref WHERE from_type = %s AND from_id = %d AND field_name = %s;",
        db.quote(entity_type), tonumber(entity_id), db.quote(field.name)
    ))
    for _, item in ipairs(schema.normalize_polymorphic_value(value)) do
        db.exec(db_path, string.format(
            "INSERT INTO entity_ref (from_type, from_id, field_name, to_type, to_id) VALUES (%s, %d, %s, %s, %d);",
            db.quote(entity_type), tonumber(entity_id), db.quote(field.name), db.quote(item.type), tonumber(item.id)
        ))
    end
end

function schema.read_polymorphic_field(db_path, entity_type, entity_id, field)
    if db.table_exists(db_path, "entity_ref") == false then
        return {}
    end
    rows = db.query(db_path, string.format(
        "SELECT to_type, to_id FROM entity_ref WHERE from_type = %s AND from_id = %d AND field_name = %s;",
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

-- Concurrent workers may race on additive DDL; ignore DDL errors if the target now exists.
function add_unless_present(db_path, sql, present)
    ok, err = pcall(db.exec, db_path, sql)
    if ok == false and not present() then
        error(err)
    end
end

function ensure_external_id_index(db_path, table_name)
    index_name = "idx_" .. table_name .. "_external_id"
    if db.index_exists(db_path, table_name, index_name) == false then
        add_unless_present(db_path, string.format(
            "CREATE INDEX %s ON %s (%s);", db.quote_ident(index_name), db.quote_ident(table_name), db.text_index_column(db_path, "external_id")
        ), function() return db.index_exists(db_path, table_name, index_name) end)
    end
end

function add_column_unless_present(db_path, table_name, column_name, sql_type)
    add_unless_present(db_path, string.format(
        "ALTER TABLE %s ADD COLUMN %s %s;", db.quote_ident(table_name), db.quote_ident(column_name), sql_type
    ), function()
        for _, name in ipairs(db.get_columns(db_path, table_name)) do
            if name == column_name then
                return true
            end
        end
        return false
    end)
end

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
            "CREATE TABLE IF NOT EXISTS %s (%s);", db.quote_ident(def.name), table.concat(columns, ", ")
        ))
        ensure_external_id_index(db_path, def.name)
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
            add_column_unless_present(db_path, def.name, field.name, SQL_TYPE[field.type])
        end
    end
    for _, builtin in ipairs(builtin_columns(db_path)) do
        if have[builtin.name] == nil then
            add_column_unless_present(db_path, def.name, builtin.name, builtin.sql_type)
        end
    end
    ensure_external_id_index(db_path, def.name)
end

-- Stat signature across dropdowns/, schemas/, and approved extension schemas so
-- steady-state requests skip schema.sync_all when nothing on disk or in approvals changed.
function schema.content_signature(db_path, root)
    paths_to_stat = {}
    for _, dir in ipairs({config_lib.dropdowns_dir(root), config_lib.schemas_dir(root)}) do
        attr = lfs.attributes(dir)
        if attr != nil and attr.mode == "directory" then
            for file_name in lfs.dir(dir) do
                if string.match(file_name, "%.lua$") != nil then
                    table.insert(paths_to_stat, paths.joinpath(dir, file_name))
                end
            end
        end
    end
    for _, owned in ipairs(extension_lib.owned_definitions(db_path, config_lib.extensions_dir(root), "schemas")) do
        table.insert(paths_to_stat, owned.path)
    end
    table.sort(paths_to_stat)
    parts = {}
    for _, path in ipairs(paths_to_stat) do
        file_attr = lfs.attributes(path)
        if file_attr == nil then
            table.insert(parts, path .. ":missing")
        else
            table.insert(parts, path .. ":" .. tostring(file_attr.modification) .. ":" .. tostring(file_attr.size))
        end
    end
    return table.concat(parts, "|")
end

function schema.definition_files(db_path, root)
    return extension_lib.definition_files(db_path, config_lib.schemas_dir(root), config_lib.extensions_dir(root), "schemas", true)
end

function schema.definition_path(db_path, name, root)
    path = paths.joinpath(config_lib.schemas_dir(root), name .. ".lua")
    if paths.file_exists(path) then
        return path
    end
    files = schema.definition_files(db_path, root)
    if files == nil then
        return nil
    end
    for _, f in ipairs(files) do
        if f.name == name and f.extension != nil then
            return f.path
        end
    end
    return nil
end

function schema.stored_sync_signature(db_path)
    return store_lib.get_text(db_path, "schema.sync_signature")
end

function schema.store_sync_signature(db_path, signature)
    store_lib.set_text(db_path, "schema.sync_signature", signature)
end

-- Registers dropdowns before schemas so dropdown-backed enum_values resolve on first pass.
function schema.sync_all(db_path, root)
    config = config_lib

    signature = schema.content_signature(db_path, root)
    if signature == schema.stored_sync_signature(db_path) then
        return true
    end

    function run_locked_sync()
        fresh_sig = schema.content_signature(db_path, root)
        if fresh_sig == schema.stored_sync_signature(db_path) then
            invalidate_schema_cache(db_path)
            return true
        end

        dropdown_defs = {}
        dropdowns_dir = config.dropdowns_dir(root)
        attr = lfs.attributes(dropdowns_dir)
        if attr != nil and attr.mode == "directory" then
            dropdown_files = {}
            for file_name in lfs.dir(dropdowns_dir) do
                if string.match(file_name, "%.lua$") != nil then
                    table.insert(dropdown_files, file_name)
                end
            end
            table.sort(dropdown_files)
            for _, file_name in ipairs(dropdown_files) do
                full_path = paths.joinpath(dropdowns_dir, file_name)
                def, err = schema.load_dropdown_file(full_path)
                if def == nil then
                    return false, "failed to load dropdown " .. full_path .. ": " .. tostring(err)
                end
                table.insert(dropdown_defs, def)
            end
        end

        files, files_err = schema.definition_files(db_path, root)
        if files == nil then
            return false, files_err
        end

        defs = {}
        for _, f in ipairs(files) do
            def, load_err = schema.load_file(f.path)
            if def == nil then
                return false, "failed to load " .. f.path .. ": " .. tostring(load_err)
            end
            if f.extension != nil and def.name != f.name then
                return false, "extension '" .. f.extension .. "' declares schema '" .. f.name ..
                    "' but " .. f.path .. " defines '" .. tostring(def.name) .. "'"
            end
            table.insert(defs, def)
        end

        if #dropdown_defs > 0 then
            function write_all_dropdowns_tx()
                for _, ddef in ipairs(dropdown_defs) do
                    schema.register_dropdown(db_path, ddef)
                end
                return true
            end
            db.transaction(db_path, write_all_dropdowns_tx)
        end

        last_error = nil
        while #defs > 0 do
            still_pending = {}
            registered_this_pass = 0
            for _, def in ipairs(defs) do
                ok, register_err = pcall(schema.register, db_path, def)
                if ok == true then
                    registered_this_pass = registered_this_pass + 1
                else
                    table.insert(still_pending, def)
                    last_error = register_err
                end
            end
            if registered_this_pass == 0 then
                return false, "schema sync stalled, no progress in a pass -- last error: " .. tostring(last_error)
            end
            defs = still_pending
        end

        schema.store_sync_signature(db_path, fresh_sig)
        invalidate_schema_cache(db_path)
        return true
    end

    return db.with_lock(db_path, "daat_schema_sync", 120, run_locked_sync)
end

-- Merges file labels/bounds with entity_field.enum_values (for dropdown-backed selects);
-- falls back to entity_field metadata when the schema file was removed.
function schema.layout(db_path, name)
    path = schema.definition_path(db_path, name)
    def = nil
    if path != nil then
        def = schema.load_file(path)
    end

    if def != nil then
        dkjson = json_lib
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
        dkjson = json_lib
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

function schema.show_json(db_path, name)
    layout, err = schema.layout(db_path, name)
    if layout == nil then
        return nil, err
    end
    return json_lib.encode(layout)
end

schema.valid_resource_name = config_lib.valid_resource_name

-- Checks entity_type directly (a registered schema may have zero custom fields).
function schema.is_registered(db_path, entity_type)
    cache_key = schema_cache_key(db_path)
    reg_bucket = _registered_cache[cache_key]
    if reg_bucket != nil and reg_bucket[entity_type] == true then
        return true
    end
    rows = db.query(db_path, string.format(
        "SELECT 1 FROM entity_type WHERE name = %s;",
        db.quote(entity_type)
    ))
    found = rows != nil and #rows > 0
    if found then
        if reg_bucket == nil then
            reg_bucket = {}
            _registered_cache[cache_key] = reg_bucket
        end
        reg_bucket[entity_type] = true
    end
    return found
end

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

schema.levenshtein = levenshtein

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

function schema.admin_write_only(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT admin_write_only FROM entity_type WHERE name = %s;", db.quote(entity_type)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    return tonumber(rows[1].admin_write_only) == 1
end

function schema.fields(db_path, entity_type)
    cache_key = schema_cache_key(db_path)
    fields_bucket = _fields_cache[cache_key]
    if fields_bucket != nil and fields_bucket[entity_type] != nil then
        return shallow_copy_list(fields_bucket[entity_type])
    end
    rows = db.query(db_path, string.format(
        "SELECT * FROM entity_field WHERE entity_type = %s ORDER BY field_order ASC;",
        db.quote(entity_type)
    ))
    if rows == nil then
        rows = {}
    end
    if #rows > 0 or schema.is_registered(db_path, entity_type) then
        if fields_bucket == nil then
            fields_bucket = {}
            _fields_cache[cache_key] = fields_bucket
        end
        fields_bucket[entity_type] = rows
    end
    return shallow_copy_list(rows)
end

function schema.preload_all_fields(db_path, entity_types)
    types = entity_types
    if types == nil then
        types = schema.list(db_path)
    end
    cache_key = schema_cache_key(db_path)
    fields_bucket = _fields_cache[cache_key]
    if fields_bucket == nil then
        fields_bucket = {}
        _fields_cache[cache_key] = fields_bucket
    end
    reg_bucket = _registered_cache[cache_key]
    if reg_bucket == nil then
        reg_bucket = {}
        _registered_cache[cache_key] = reg_bucket
    end
    grouped = {}
    missing = false
    for _, t in ipairs(types) do
        name = t
        if type(t) == "table" then
            name = t.name
        end
        if name != nil and name != "" then
            grouped[name] = {}
            reg_bucket[name] = true
            if fields_bucket[name] == nil then
                missing = true
            end
        end
    end
    if missing == false then
        return
    end
    all_rows = db.query(db_path, "SELECT * FROM entity_field ORDER BY entity_type ASC, field_order ASC;")
    if all_rows != nil then
        for _, row in ipairs(all_rows) do
            et = row.entity_type
            if grouped[et] == nil then
                grouped[et] = {}
            end
            table.insert(grouped[et], row)
        end
    end
    for et, list in pairs(grouped) do
        fields_bucket[et] = list
    end
end

function schema.relationships(db_path, entity_types)
    types = entity_types
    if types == nil then
        types = schema.list(db_path)
    end
    schema.preload_all_fields(db_path, types)
    edges = {}
    for _, t in ipairs(types) do
        fields = schema.fields(db_path, t.name)
        for _, field in ipairs(fields) do
            if (field.type == "reference" or field.type == "multi_reference") and field.ref_entity_type != nil and field.ref_entity_type != "" then
                table.insert(edges, {from_type = t.name, to_type = field.ref_entity_type, field_name = field.name, field_type = field.type})
            elseif is_polymorphic_field_type(field.type) and field.allowed_entity_types != nil then
                allowed_types = json_lib.decode(field.allowed_entity_types)
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

function schema.do_schema(cmd_args, db_path)
    action = cmd_args[1]

    if action == "add" then
        path = cmd_args[2]
        if path == nil then
            print("Usage: daat schema add <file>")
            return 1
        end
        def, err = schema.load_file(path)
        if def == nil then
            print("Error: " .. err)
            return 1
        end
        schema.register(db_path, def)
        print("Registered entity type '" .. def.name .. "'")
        return 0
    end

    if action == "list" then
        schema.sync_all(db_path)
        for _, row in ipairs(schema.list(db_path)) do
            print(row.name)
        end
        return 0
    end

    if action == "show-json" or (action == "show" and cmd_args[3] == "--json") then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat schema show-json <name>")
            return 1
        end
        schema.sync_all(db_path)
        json_str, err = schema.show_json(db_path, name)
        if json_str == nil then
            print("Error: " .. tostring(err))
            return 1
        end
        print(json_str)
        return 0
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat schema show <name>")
            return 1
        end
        schema.sync_all(db_path)
        for _, field in ipairs(schema.fields(db_path, name)) do
            required = "optional"
            if tonumber(field.required) == 1 then
                required = "required"
            end
            print(string.format("%-20s %-10s %s", field.name, field.type, required))
        end
        return 0
    end

    if action == "sync" then
        ok, err = schema.sync_all(db_path)
        if not ok then
            print("Error: " .. tostring(err))
            return 1
        end
        print("Schema sync complete")
        return 0
    end

    print("Usage: daat schema <add|list|show|show-json|sync> [args]")
    return 1
end

schema.is_multi_field_type = is_multi_field_type
schema.is_polymorphic_field_type = is_polymorphic_field_type
schema.is_reserved_field_name = is_reserved_field_name
schema.is_reserved_sql_word = is_reserved_sql_word
schema.is_reserved_table_name = is_reserved_table_name

return schema
