-- Custom SQL-query views: a named, read-only SELECT query rendered as
-- a generic table, defined the same way schemas/extensions are (a
-- Luam table file, version-controlled alongside them). A view has
-- direct database access the same way an extension does, so it goes
-- through the same admin-approval registry -- approving records the
-- exact SQL text at approval time, and if the file is edited
-- afterward, the view is unapproved again until re-approved (same
-- escalation-detection principle as extension.capabilities_equal, just
-- keyed on the query text instead of a capabilities table).

db = require("db")
json = require("dkjson")
paths = require("paths")
lfs = require("lfs")
sandbox = require("sandbox")
schema = require("schema")
file_util = require("file_util")

view = {}

view.SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS view_approval (
    name VARCHAR(255) PRIMARY KEY,
    sql_text TEXT NOT NULL,
    approved_by TEXT,
    approved_at TEXT DEFAULT (%s)
);
"""

function view.init_schema(db_path)
    return db.exec(db_path, string.format(view.SCHEMA, db.now_expr(db_path)))
end

function view.names(views_dir)
    names = {}
    attr = lfs.attributes(views_dir)
    if attr == nil or attr.mode != "directory" then
        return names
    end
    for dir_name in lfs.dir(views_dir) do
        if dir_name != "." and dir_name != ".." then
            if string.match(dir_name, "%.lua$") != nil then
                name = string.gsub(dir_name, "%.lua$", "")
                table.insert(names, name)
            end
        end
    end
    return names
end

-- Rejects anything but a single, plain SELECT statement: no stacked
-- statements (a ";" anywhere but optionally trailing), and no
-- DDL/DML/pragma/attach keywords, matched on word boundaries (not bare
-- substring search -- platform's own tables have columns like
-- updated_at/updated_by, which a naive substring check for "update"
-- would wrongly reject).
FORBIDDEN_SQL_WORDS = {
    "insert", "update", "delete", "drop", "alter", "attach", "detach",
    "pragma", "create", "replace", "vacuum", "reindex", "trigger", "exec",
}

function view.is_select_only(sql_text)
    trimmed = string.gsub(sql_text, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    lowered = string.lower(trimmed)
    -- A CTE ("WITH x AS (...) SELECT ...") is still a single read-only
    -- statement -- allowed on the same footing as a plain SELECT, not a
    -- looser check: the trailing FORBIDDEN_SQL_WORDS/no-semicolon checks
    -- below still apply to the whole text either way.
    if string.find(lowered, "^select") == nil and string.find(lowered, "^with%f[%A]") == nil then
        return false
    end

    body = trimmed
    if string.sub(trimmed, -1) == ";" then
        body = string.sub(trimmed, 1, -2)
    end
    if string.find(body, ";") != nil then
        return false
    end

    for _, word in ipairs(FORBIDDEN_SQL_WORDS) do
        if string.find(lowered, "%f[%a]" .. word .. "%f[%A]") != nil then
            return false
        end
    end
    return true
end

-- A view may declare at most one runtime parameter (e.g. scoping a
-- lookup to one experiment's samples), bound through sqlite's own
-- prepared-statement API (view.run below) -- never string-interpolated
-- into the SQL text, so there's no injection surface from the value
-- itself regardless of type. `type` controls the coercion applied
-- before binding, not any kind of SQL-text validation.
PARAM_TYPES = {"integer", "number", "text"}

function is_valid_param_type(t)
    for _, valid in ipairs(PARAM_TYPES) do
        if t == valid then
            return true
        end
    end
    return false
end

function view.validate(def)
    if type(def.name) != "string" or def.name == "" then
        return "view must have a non-empty string 'name'"
    end
    if type(def.sql) != "string" or def.sql == "" then
        return "view '" .. tostring(def.name) .. "' must have a non-empty string 'sql'"
    end
    if view.is_select_only(def.sql) == false then
        return "view '" .. tostring(def.name) .. "': sql must be a single, plain SELECT statement (no ';', no DDL/DML/pragma)"
    end
    -- An optional MariaDB-specific variant, for the rare view whose SQL
    -- genuinely can't be written as one expression valid on both
    -- backends (e.g. SQLite's julianday() vs. MariaDB's DATEDIFF() --
    -- see doc/mariadb-migration.md). Absent for every other view; only
    -- needed when a portable expression doesn't exist at all, not as a
    -- general escape hatch.
    if def.sql_mariadb != nil then
        if type(def.sql_mariadb) != "string" or def.sql_mariadb == "" then
            return "view '" .. tostring(def.name) .. "': sql_mariadb must be a non-empty string if present"
        end
        if view.is_select_only(def.sql_mariadb) == false then
            return "view '" .. tostring(def.name) .. "': sql_mariadb must be a single, plain SELECT statement (no ';', no DDL/DML/pragma)"
        end
    end
    if type(def.columns) != "table" or #def.columns == 0 then
        return "view '" .. tostring(def.name) .. "' must have a non-empty 'columns' list"
    end
    for i, col in ipairs(def.columns) do
        if type(col.name) != "string" or col.name == "" then
            return string.format("view '%s' column #%d: missing 'name'", def.name, i)
        end
    end
    if def.param != nil then
        if type(def.param.name) != "string" or def.param.name == "" then
            return "view '" .. tostring(def.name) .. "': param must have a non-empty string 'name'"
        end
        -- "id" and "name" collide with Fossil's own /ext dispatch
        -- parameters -- a query param with either of these names never
        -- reaches platform at all, so reject them here rather than let
        -- an author discover it as a mysterious 404 later.
        if def.param.name == "id" or def.param.name == "name" then
            return "view '" .. tostring(def.name) .. "': param name can't be 'id' or 'name' -- both collide with Fossil's own /ext dispatch (see doc/deployment.md)"
        end
        if is_valid_param_type(def.param.type) == false then
            return "view '" .. tostring(def.name) .. "': param 'type' must be one of integer/number/text"
        end
    end
    -- Optional: which single entity type this view is primarily about,
    -- if any (a view can join across types, so there isn't always one --
    -- see html.render_view's own comment). Purely a rendering hint for
    -- the "+ Register new" link; not cross-checked against schema.list()
    -- here since view.load/validate has no db_path to check against --
    -- a typo'd name just means a broken register link, not a security
    -- concern (the /register route validates the type itself).
    if def.entity_type != nil and (type(def.entity_type) != "string" or def.entity_type == "") then
        return "view '" .. tostring(def.name) .. "': entity_type must be a non-empty string if present"
    end
    return nil
end

function view.load(views_dir, name)
    path = paths.joinpath(views_dir, name .. ".lua")
    source = file_util.read(path)
    if source == nil then
        return nil, "cannot open view: " .. path
    end
    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == false or type(result) != "table" then
        return nil, "error loading view " .. path .. ": " .. tostring(result)
    end
    err = view.validate(result)
    if err != nil then
        return nil, err
    end
    return result
end

function view.all(views_dir)
    result = {}
    for _, name in ipairs(view.names(views_dir)) do
        def, err = view.load(views_dir, name)
        table.insert(result, {name = name, def = def, err = err})
    end
    return result
end

-- The SQL text that actually runs for this backend -- def.sql_mariadb
-- when running under MariaDB and present, def.sql otherwise. The one
-- place `def.sql` gets read directly for execution is replaced by this
-- everywhere below.
function view.effective_sql(db_path, def)
    if db.is_mariadb(db_path) and def.sql_mariadb != nil then
        return def.sql_mariadb
    end
    return def.sql
end

-- What gets recorded/compared for approval -- both variants combined
-- into one string when sql_mariadb is present, so editing *either* one
-- (not just whichever currently runs on this deployment's own backend)
-- invalidates approval. A dev iterating against SQLite locally should
-- still be forced to re-approve after touching the MariaDB-only half
-- of a view they can't even exercise locally.
function view.approval_identity(def)
    if def.sql_mariadb == nil then
        return def.sql
    end
    return def.sql .. "\n--- sql_mariadb ---\n" .. def.sql_mariadb
end

function view.approved_sql(db_path, name)
    view.init_schema(db_path)
    rows = db.query(db_path, "SELECT sql_text FROM view_approval WHERE name = " .. db.quote(name) .. ";")
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1].sql_text
end

function view.is_approved(db_path, def)
    approved = view.approved_sql(db_path, def.name)
    if approved == nil then
        return false
    end
    return approved == view.approval_identity(def)
end

function view.approve(db_path, def, approved_by)
    view.init_schema(db_path)
    db.exec(db_path, string.format(
        "%s view_approval (name, sql_text, approved_by, approved_at) VALUES (%s, %s, %s, %s);",
        db.replace_into(db_path),
        db.quote(def.name), db.quote(view.approval_identity(def)), db.literal(approved_by), db.now_expr(db_path)
    ))
end

function view.revoke(db_path, name)
    view.init_schema(db_path)
    db.exec(db_path, "DELETE FROM view_approval WHERE name = " .. db.quote(name) .. ";")
end

-- Runs an approved view's query. `param_value` is required iff the
-- view declares `param` (ignored otherwise). Returns (rows, err) --
-- rows is a list of {column_name = value} tables either way.
function view.run(db_path, def, param_value)
    param_type = nil
    if def.param != nil then
        param_type = def.param.type
    end
    return view.run_sql(db_path, view.effective_sql(db_path, def), param_type, param_value)
end

-- Runs a validated, parameterized SELECT: `sql_text` must contain
-- exactly one literal '?' placeholder if `param_type` is non-nil.
-- Returns (rows, err) -- rows is a list of {column_name = value}
-- tables. Shared by view.run (named/approved views) and label.lua's
-- label.render -- one dual-backend-safe implementation, not two.
--
-- SQLite: real bind-parameter execution via sqlite3's own prepared-
-- statement API -- never string-interpolated into the SQL text (db.
-- exec/db.query's own %s substitution is fine for identifiers/
-- literals platform itself builds, but a runtime-supplied value needs
-- the real thing). sqlite3 isn't shared as a global across modules in
-- Luam (each require() gets its own reference; see src/db.lua for the
-- same require), so it's pulled in locally here rather than assumed
-- available.
--
-- MariaDB: no equivalent path exists -- luam's own mariadb binding
-- (lib/mariadb/lmariadb.c) deliberately does NOT expose a
-- prepared-statement/cursor object at all (see its own header comment).
-- Falls back to safely-encoded substitution instead: param_type is
-- restricted to integer/number/text (view.validate already enforces
-- this on param.type), so the substituted value is either a
-- tonumber()-coerced literal (a number can never carry an injection
-- payload, regardless of quoting) or db.quote()'d text (the same
-- escaping helper trusted everywhere else in this codebase) --
-- genuinely safe for these specific types, just not a real prepared
-- statement.
function view.run_sql(db_path, sql_text, param_type, param_value)
    if view.is_select_only(sql_text) == false then
        return nil, "refusing to run: not a plain SELECT"
    end

    if param_type == nil then
        rows = db.query(db_path, sql_text)
        if rows == nil then
            return {}
        end
        return rows
    end

    bind_value = param_value
    if param_type == "integer" or param_type == "number" then
        bind_value = tonumber(param_value)
        if bind_value == nil then
            return nil, "parameter must be a number"
        end
    elseif param_value == nil or param_value == "" then
        return nil, "missing required parameter"
    end

    placeholder_count = 0
    for _ in string.gmatch(sql_text, "%?") do
        placeholder_count = placeholder_count + 1
    end
    if placeholder_count != 1 then
        return nil, "sql doesn't have exactly one '?' placeholder"
    end

    if db.is_mariadb(db_path) then
        literal = tostring(bind_value)
        if param_type == "text" then
            literal = db.quote(bind_value)
        end
        -- Plain (non-pattern) find + string.sub, not gsub -- gsub's
        -- replacement argument treats a literal '%' specially (a
        -- backreference escape), which real substituted text (e.g. a
        -- lab_name containing '%') could easily contain.
        pos = string.find(sql_text, "?", 1, true)
        substituted = string.sub(sql_text, 1, pos - 1) .. literal .. string.sub(sql_text, pos + 1)
        rows = db.query(db_path, substituted)
        if rows == nil then
            return {}
        end
        return rows
    end

    sqlite3 = require("sqlite3")
    conn = sqlite3.open(db_path)
    if conn == nil then
        return nil, "cannot open database"
    end

    vm, err = sqlite3.prepare(conn, sql_text)
    if vm == nil then
        sqlite3.close(conn)
        return nil, "invalid sql: " .. tostring(err)
    end
    if sqlite3.stmt.bind_parameter_count(vm) != 1 then
        sqlite3.stmt.finalize(vm)
        sqlite3.close(conn)
        return nil, "sql doesn't have exactly one '?' placeholder"
    end

    bind_rc = sqlite3.stmt.bind(vm, 1, bind_value)
    if bind_rc != 0 then
        sqlite3.stmt.finalize(vm)
        sqlite3.close(conn)
        return nil, "failed to bind parameter"
    end

    rows = {}
    for row in sqlite3.stmt.nrows(vm) do
        table.insert(rows, row)
    end
    sqlite3.stmt.finalize(vm)
    sqlite3.close(conn)
    return rows
end

-- Ad-hoc, unsaved SELECT execution against the entity store -- for
-- one-off exploration, not embeddable/shareable content, so unlike a
-- named view there's nothing to approve (the caller enforcing Setup/
-- Admin capability -- see cgi.lua's /sql route -- already *is* the
-- approval: nobody untrusted can reach this). Still SELECT-only via
-- the same is_select_only guard, and returns column names separately
-- from db.query's rows (which are unordered Lua tables keyed by
-- column name) so results render with real, ordered headers even for
-- an empty result set.
-- Best-effort single-table guess for "which table is this query
-- primarily about" -- used for the "id" self-reference special case in
-- cgi.lua (the queried table's own id column). Still just the first
-- `FROM <table>` match, alias discarded (a result column is looked up
-- by its own name, not by qualified alias.column, so the alias itself
-- is never needed). See guess_tables below for the full table list a
-- query reads from, joins included.
function view.guess_from_table(sql_text)
    table_name = string.match(sql_text, "[Ff][Rr][Oo][Mm]%s+([A-Za-z_][A-Za-z0-9_]*)")
    return table_name
end

-- Best-effort guess of every table a query reads from: the primary
-- FROM table plus any JOINed tables -- INNER/LEFT/RIGHT/OUTER/CROSS
-- JOIN all end in the literal word "JOIN" immediately before the table
-- name, so one case-insensitive match covers every join variant.
-- Still string-matching, not a real SQL parser: comma-joins ("FROM a,
-- b"), subqueries, and CTEs aren't covered, and each table's alias (if
-- any) is discarded -- reference_columns below only needs the real
-- table name to look up entity_field metadata, since a query's result
-- columns are keyed by their own (possibly aliased-away) name, not by
-- qualified alias.column.
function view.guess_tables(sql_text)
    tables = {}
    seen = {}
    from_table = view.guess_from_table(sql_text)
    if from_table != nil then
        table.insert(tables, from_table)
        seen[from_table] = true
    end
    for joined in string.gmatch(sql_text, "[Jj][Oo][Ii][Nn]%s+([A-Za-z_][A-Za-z0-9_]*)") do
        if seen[joined] == nil then
            table.insert(tables, joined)
            seen[joined] = true
        end
    end
    return tables
end

-- {column_name -> ref_entity_type} for a set of tables' reference-type
-- fields, via the same entity_field metadata schema.layout() already
-- exposes (see html.lua's display_field_value) -- used here directly by
-- table name since an ad-hoc query has no schema.layout() call of its
-- own. Accepts either a single table name (back-compat for callers that
-- only ever guessed one table) or a list (see guess_tables) -- merged in
-- list order, first table wins a column-name collision, so a query's
-- primary FROM table takes precedence over a joined table that happens
-- to reuse the same column name.
function view.reference_columns(db_path, table_names)
    columns = {}
    if table_names == nil then
        return columns
    end
    if type(table_names) == "string" then
        table_names = {table_names}
    end
    for _, table_name in ipairs(table_names) do
        rows = db.query(db_path, string.format(
            "SELECT name, ref_entity_type FROM entity_field WHERE entity_type = %s AND type = 'reference';",
            db.quote(table_name)
        ))
        if rows != nil then
            for _, row in ipairs(rows) do
                if columns[row.name] == nil then
                    columns[row.name] = row.ref_entity_type
                end
            end
        end
    end
    return columns
end

-- Uses db.query (not sqlite3.open directly) so this dispatches
-- correctly to either backend and returns (rows, column_names) either
-- way -- both vendored query functions (luam's sqlite_query/
-- mariadb_query) throw via error() on invalid SQL rather than returning
-- nil+err, so this is pcalled to convert a typo'd ad-hoc query into
-- this page's own inline error message instead of a generic 500.
-- A query with no LIMIT of its own gets one added automatically -- an
-- unbounded admin power-query against a real production table has no
-- reason to ever render thousands of full rows at once. Same
-- word-boundary convention is_select_only's own FORBIDDEN_SQL_WORDS
-- check uses, so "LIMIT" inside a string literal or column alias isn't
-- mistaken for a real clause keyword -- and isn't mistaken the other
-- way either (a query that only *mentions* limit without one is still
-- capped).
-- Fetches one extra row past the cap, not to display it, just to tell
-- "exactly N rows" apart from "N rows, and more exist" for the UI's
-- own truncation notice -- a second COUNT(*) query would double the
-- real cost this exists to avoid.
--
-- How much a deployment's own admin/agent-facing row caps below should
-- actually be depends on things this code doesn't know -- how much data
-- a given deployment holds, how big a table a human reasonably wants to
-- browse at once, how much context budget the configured AGENT_MODEL
-- has -- so neither is a bare hardcoded literal; each is read fresh
-- from config.platform_config() per call (not resolved once at load).

function view.run_adhoc(db_path, sql_text)
    if view.is_select_only(sql_text) == false then
        return nil, nil, "refusing to run: not a plain SELECT"
    end

    config = require("config")
    row_cap = config.platform_config().platform_adhoc_row_cap
    query_text = sql_text
    body = string.gsub(sql_text, "%s+$", "")
    if string.sub(body, -1) == ";" then
        body = string.sub(body, 1, -2)
    end
    has_own_limit = string.find(string.lower(body), "%f[%a]limit%f[%A]") != nil
    capped = false
    if has_own_limit == false then
        query_text = body .. string.format(" LIMIT %d;", row_cap + 1)
        capped = true
    end

    ok, rows, column_names = pcall(db.query, db_path, query_text)
    if ok == false then
        return nil, nil, "invalid sql: " .. tostring(rows)
    end
    if rows == nil then
        rows = {}
    end
    if column_names == nil then
        column_names = {}
    end
    truncated = false
    if capped == true and #rows > row_cap then
        truncated = true
        capped_rows = {}
        for i = 1, row_cap do
            table.insert(capped_rows, rows[i])
        end
        rows = capped_rows
    end
    return column_names, rows, nil, truncated
end

--------------------------------------------------------------------------
-- Read-only SQL for the chat agent -- entity.list's own single-table
-- exact-match filter can't express joins/aggregates/grouping, which
-- real questions genuinely need (see agent.lua's entity.query tool)
--------------------------------------------------------------------------
--
-- A materially stricter boundary than the admin-only /sql console
-- (view.run_adhoc above) needs, even though both start from the same
-- is_select_only check: a human typing SQL into an admin-gated console
-- is one trust level, an LLM composing SQL from a conversation
-- (prompt injection can steer what gets generated in a way a human's
-- own intent never is) is a different, lower one. entity.list/
-- entity.get structurally can never reach a non-entity table at all
-- (they only ever go through the schema-registered entity
-- abstraction) -- this tool has to enforce that same boundary itself,
-- by checking every table the query actually references against the
-- registered entity type list, rejecting anything else (auth_user's
-- password hashes, api_key secrets, agent_message/agent_pending_action,
-- schema_sync_state, or any other internal table entity.list/get
-- could never expose either).

-- Collects every identifier immediately following `keyword` (word-
-- boundary matched, same convention as FORBIDDEN_SQL_WORDS -- so a
-- column literally named e.g. "from_date" is never mistaken for a
-- FROM clause), including old-style comma-joined table lists
-- ("FROM a, b" -- not just "FROM a JOIN b"). Scans the whole query
-- text, not just its top level, so a table referenced only inside a
-- subquery is still caught. A WITH-clause alias (see cte_names below)
-- is excluded from the allowlist check by the caller -- otherwise a
-- CTE's own name would be checked against the schema registry and
-- rejected as an unregistered "table", even though it's a local alias
-- the query defines itself, not a real table.
function extract_after_keyword(lowered_sql, keyword, names)
    start = 1
    while true do
        s, e = string.find(lowered_sql, "%f[%a]" .. keyword .. "%f[%A]%s+", start)
        if s == nil then
            return
        end
        rest = string.sub(lowered_sql, e + 1)
        ident = string.match(rest, "^([%a_][%w_]*)")
        if ident != nil then
            table.insert(names, ident)
            pos = e + string.len(ident)
            while true do
                tail = string.sub(lowered_sql, pos + 1)
                comma_ident = string.match(tail, "^%s*,%s*([%a_][%w_]*)")
                if comma_ident == nil then
                    break
                end
                table.insert(names, comma_ident)
                _, comma_end = string.find(tail, "^%s*,%s*[%a_][%w_]*")
                pos = pos + comma_end
            end
        end
        start = e + 1
    end
end

function referenced_table_names(sql_text)
    lowered = string.lower(sql_text)
    names = {}
    extract_after_keyword(lowered, "from", names)
    extract_after_keyword(lowered, "join", names)
    return names
end

-- Names a WITH-clause defines ("WITH a AS (...), b AS (...) SELECT ...").
-- Still string-matching, not a real parser (same accepted rigor level
-- as guess_tables/referenced_table_names above): "<ident> AS (" is a
-- specific enough shape that it only matches a CTE definition, never a
-- column alias (which can't take a parenthesized value) or a derived-
-- table alias (there the "(" comes before "AS", not after).
function cte_names(sql_text)
    names = {}
    lowered = string.lower(sql_text)
    if string.find(lowered, "^%s*with%f[%A]") == nil then
        return names
    end
    for ident in string.gmatch(lowered, "([%a_][%w_]*)%s+as%s*%(") do
        table.insert(names, ident)
    end
    return names
end

-- A separate, smaller default cap than platform_adhoc_row_cap -- that
-- one is sized for a human reading an HTML table in a browser; this
-- result goes straight into the model's own prompt/context, where 1000
-- rows would be wasteful at best and a real token-cost problem at
-- worst (and the right number here depends on the configured
-- AGENT_MODEL's own context budget, not just this code).
function view.run_agent_query(db_path, sql_text)
    if view.is_select_only(sql_text) == false then
        return nil, nil, "refusing to run: not a plain SELECT"
    end

    config = require("config")
    row_cap = config.platform_config().agent_query_row_cap
    referenced = referenced_table_names(sql_text)
    if #referenced == 0 then
        return nil, nil, "refusing to run: no FROM/JOIN table found"
    end

    allowed = {}
    for _, t in ipairs(schema.list(db_path)) do
        allowed[t.name] = true
    end
    for _, name in ipairs(cte_names(sql_text)) do
        allowed[name] = true
    end
    for _, name in ipairs(referenced) do
        if allowed[name] == nil then
            message = "refusing to run: '" .. name .. "' is not a registered entity type -- only registered entity tables can be queried this way"
            suggestion = schema.suggest_type(db_path, name)
            if suggestion != nil then
                message = message .. " (did you mean '" .. suggestion .. "'?)"
            end
            return nil, nil, message
        end
    end

    query_text = sql_text
    body = string.gsub(sql_text, "%s+$", "")
    if string.sub(body, -1) == ";" then
        body = string.sub(body, 1, -2)
    end
    has_own_limit = string.find(string.lower(body), "%f[%a]limit%f[%A]") != nil
    capped = false
    if has_own_limit == false then
        query_text = body .. string.format(" LIMIT %d;", row_cap + 1)
        capped = true
    end

    ok, rows, column_names = pcall(db.query, db_path, query_text)
    if ok == false then
        return nil, nil, "invalid sql: " .. tostring(rows)
    end
    if rows == nil then
        rows = {}
    end
    if column_names == nil then
        column_names = {}
    end
    truncated = false
    total_count = nil
    if capped == true and #rows > row_cap then
        truncated = true
        capped_rows = {}
        for i = 1, row_cap do
            table.insert(capped_rows, rows[i])
        end
        rows = capped_rows
        -- One extra query, only paid when we already know the cap was hit:
        -- tells the caller (and the model reading the tool result) the
        -- real match count instead of just "more than the cap", which
        -- otherwise makes it impossible to tell a 201-row result apart
        -- from a 90,000-row one.
        count_ok, count_rows = pcall(db.query, db_path, "SELECT COUNT(*) AS n FROM (" .. body .. ") AS _agent_query_count;")
        if count_ok == true and count_rows != nil and count_rows[1] != nil then
            total_count = tonumber(count_rows[1].n)
        end
    end
    return column_names, rows, nil, truncated, total_count
end

-- CLI entry point: `daat view <list|show|approve|revoke> [args]`
function view.do_view(cmd_args, db_path)
    config = require("config")
    views_dir = config.views_dir()
    action = cmd_args[1]

    if action == "list" then
        for _, entry in ipairs(view.all(views_dir)) do
            if entry.def == nil then
                print(string.format("%-20s ERROR: %s", entry.name, entry.err))
            else
                status = "not approved"
                if view.is_approved(db_path, entry.def) then
                    status = "approved"
                end
                sql_note = entry.def.sql
                if entry.def.sql_mariadb != nil then
                    sql_note = sql_note .. " (+ sql_mariadb variant)"
                end
                print(string.format("%-20s %-14s %s", entry.name, status, sql_note))
            end
        end
        return
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat view show <name>")
            return
        end
        def, err = view.load(views_dir, name)
        if def == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("name: " .. def.name)
        print("sql:  " .. def.sql)
        if def.sql_mariadb != nil then
            print("sql_mariadb: " .. def.sql_mariadb)
        end
        if view.is_approved(db_path, def) then
            print("status: approved")
        elseif view.approved_sql(db_path, name) == nil then
            print("status: not approved")
        else
            print("status: NOT APPROVED -- sql changed since last approval, re-approval required")
        end
        return
    end

    if action == "approve" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat view approve <name>")
            return
        end
        def, err = view.load(views_dir, name)
        if def == nil then
            print("Error: " .. tostring(err))
            return
        end
        view.approve(db_path, def, os.getenv("USER"))
        print("Approved '" .. name .. "'")
        return
    end

    if action == "revoke" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat view revoke <name>")
            return
        end
        view.revoke(db_path, name)
        print("Revoked '" .. name .. "'")
        return
    end

    print("Usage: daat view <list|show|approve|revoke> [args]")
end

return view
