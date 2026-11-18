-- Custom SQL-query views: a named, read-only SELECT query rendered as
-- a generic table, defined the same way schemas/extensions are (a
-- Luam table file, version-controlled alongside them). A view has
-- direct database access the same way an extension does, so it goes
-- through the same admin-approval registry -- approving records the
-- exact SQL text at approval time, and if the file is edited
-- afterward, the view is unapproved again until re-approved (same
-- escalation-detection principle as extension.capabilities_equal, just
-- keyed on the query text instead of a capabilities table).

db = require("database")
json = require("dkjson")
paths = require("paths")
lfs = require("lfs")
sandbox = require("sandbox")
schema = require("schema")

view = {}

-- Approvals live in system_approval (store.lua), kind 'view'.
function view.init_schema(db_path)
    require("store").ensure_system_tables(db_path)
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
    "outfile", "dumpfile", "load_file", "load_extension",
    "get_lock", "release_lock", "release_all_locks", "sleep", "benchmark",
}

FORBIDDEN_SQL_WORDS_SET = {}
for _, w in ipairs(FORBIDDEN_SQL_WORDS) do
    FORBIDDEN_SQL_WORDS_SET[w] = true
end

-- Lexical scanner over a single SQL query string. Produces a flat list of
-- `{kind, value, raw, depth}` tokens (`kind` in `"word"`, `"ident"`,
-- `"string"`, `"punct"`, `"number"`), stripping `--`, `#`, and standard
-- `/* ... */` comments while rejecting MySQL executable comments
-- (`/*! ... */`), unclosed literals/comments, and unbalanced parentheses.
-- Quoted identifiers (`"..."`, `` `...` ``, `[...]`) are unquoted into
-- `kind = "ident"` so table allowlists see the real identifier regardless
-- of quoting style.
function scan_sql_tokens(sql_text)
    if type(sql_text) != "string" then
        return nil, "query must be a string"
    end
    tokens = {}
    len = string.len(sql_text)
    i = 1
    depth = 0

    while i <= len do
        ch = string.sub(sql_text, i, i)
        ch2 = string.sub(sql_text, i, i + 1)

        if string.match(ch, "%s") != nil then
            i = i + 1
        elseif ch2 == "--" or ch == "#" then
            nl = string.find(sql_text, "\n", i + 1, true)
            if nl == nil then
                i = len + 1
            else
                i = nl + 1
            end
        elseif ch2 == "/*" then
            if string.sub(sql_text, i + 2, i + 2) == "!" then
                return nil, "executable SQL comments (/*! ... */) are not allowed"
            end
            close_pos = string.find(sql_text, "*/", i + 2, true)
            if close_pos == nil then
                return nil, "unclosed SQL block comment"
            end
            i = close_pos + 2
        elseif ch == "'" then
            j = i + 1
            parts = {}
            closed = false
            while j <= len do
                c = string.sub(sql_text, j, j)
                if c == "'" then
                    if j < len and string.sub(sql_text, j + 1, j + 1) == "'" then
                        table.insert(parts, "'")
                        j = j + 2
                    else
                        closed = true
                        j = j + 1
                        break
                    end
                else
                    table.insert(parts, c)
                    j = j + 1
                end
            end
            if not closed then
                return nil, "unclosed string literal"
            end
            inner = table.concat(parts)
            table.insert(tokens, {kind = "string", value = inner, raw = inner, depth = depth})
            i = j
        elseif ch == "\"" or ch == "`" then
            quote_ch = ch
            j = i + 1
            parts = {}
            closed = false
            while j <= len do
                c = string.sub(sql_text, j, j)
                if c == quote_ch then
                    if j < len and string.sub(sql_text, j + 1, j + 1) == quote_ch then
                        table.insert(parts, quote_ch)
                        j = j + 2
                    else
                        closed = true
                        j = j + 1
                        break
                    end
                else
                    table.insert(parts, c)
                    j = j + 1
                end
            end
            if not closed then
                return nil, "unclosed quoted identifier"
            end
            ident_raw = table.concat(parts)
            table.insert(tokens, {kind = "ident", value = string.lower(ident_raw), raw = ident_raw, depth = depth})
            i = j
        elseif ch == "[" then
            close_br = string.find(sql_text, "]", i + 1, true)
            if close_br == nil then
                return nil, "unclosed bracket identifier"
            end
            ident_raw = string.sub(sql_text, i + 1, close_br - 1)
            table.insert(tokens, {kind = "ident", value = string.lower(ident_raw), raw = ident_raw, depth = depth})
            i = close_br + 1
        elseif ch == "(" then
            table.insert(tokens, {kind = "punct", value = "(", raw = "(", depth = depth})
            depth = depth + 1
            i = i + 1
        elseif ch == ")" then
            depth = depth - 1
            if depth < 0 then
                return nil, "unbalanced parentheses"
            end
            table.insert(tokens, {kind = "punct", value = ")", raw = ")", depth = depth})
            i = i + 1
        elseif ch == "," or ch == ";" or ch == "." then
            table.insert(tokens, {kind = "punct", value = ch, raw = ch, depth = depth})
            i = i + 1
        else
            _, num_end, num_txt = string.find(sql_text, "^(%d+%.?%d*)", i)
            if num_txt != nil then
                table.insert(tokens, {kind = "number", value = num_txt, raw = num_txt, depth = depth})
                i = num_end + 1
            else
                _, word_end, word_txt = string.find(sql_text, "^([%a_][%w_$]*)", i)
                if word_txt != nil then
                    table.insert(tokens, {kind = "word", value = string.lower(word_txt), raw = word_txt, depth = depth})
                    i = word_end + 1
                else
                    i = i + 1
                end
            end
        end
    end

    if depth != 0 then
        return nil, "unbalanced parentheses"
    end
    return tokens, nil
end

-- Nil when sql_text is a single plain SELECT, else why not -- naming
-- the offending token, so the agent fixes the actual problem instead of
-- guessing (seen in prod: REPLACE() refused as "not a plain SELECT").
function view.select_only_problem(sql_text)
    if type(sql_text) != "string" then
        return "must start with SELECT (or WITH ... SELECT)"
    end
    -- Conservative backslash guard: SQLite and default-mode MySQL disagree
    -- on whether \' ends a literal, so when any backslash appears in the
    -- query text, inspect every word across the raw text before trusting
    -- literal boundaries.
    if string.find(sql_text, "\\", 1, true) != nil then
        raw_lower = string.lower(sql_text)
        for _, word in ipairs(FORBIDDEN_SQL_WORDS) do
            if string.find(raw_lower, "%f[%a]" .. word .. "%f[%A]") != nil then
                return "contains '" .. word .. "' outside a quoted string -- refused anywhere, even as a function name like REPLACE()"
            end
        end
    end

    tokens, scan_err = scan_sql_tokens(sql_text)
    if tokens == nil then
        return scan_err
    end
    if #tokens == 0 then
        return "must start with SELECT (or WITH ... SELECT)"
    end
    first = tokens[1]
    if first.kind != "word" or (first.value != "select" and first.value != "with") then
        return "must start with SELECT (or WITH ... SELECT)"
    end

    for idx, tok in ipairs(tokens) do
        if tok.kind == "punct" and tok.value == ";" and idx < #tokens then
            return "contains ';' -- send one statement, no semicolons"
        end
    end

    for _, tok in ipairs(tokens) do
        if tok.kind == "word" and FORBIDDEN_SQL_WORDS_SET[tok.value] == true then
            return "contains '" .. tok.value .. "' outside a quoted string -- refused anywhere, even as a function name like REPLACE()"
        end
    end
    return nil
end

function has_top_level_limit(sql_text)
    tokens, _ = scan_sql_tokens(sql_text)
    if tokens == nil then
        return false
    end
    for _, tok in ipairs(tokens) do
        if tok.kind == "word" and tok.value == "limit" and tok.depth == 0 then
            return true
        end
    end
    return false
end

function view.is_select_only(sql_text)
    return view.select_only_problem(sql_text) == nil
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

function view.load_file(path)
    source = paths.read_file(path)
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

-- Every view definition file this deployment loads: views/*.lua plus
-- the ones approved extensions own (see extension.definition_files).
function view.definition_files(db_path, root)
    config = require("config")
    extension = require("extension")
    return extension.definition_files(db_path, config.views_dir(root), config.extensions_dir(root), "views", false)
end

-- An extension-owned view must define the name it declared, since
-- that's the name its extension was approved for (and the name view
-- approval is recorded under).
function load_definition_file(f)
    def, err = view.load_file(f.path)
    if def != nil and f.extension != nil and def.name != f.name then
        return nil, "extension '" .. f.extension .. "' declares view '" .. f.name ..
            "' but " .. f.path .. " defines '" .. tostring(def.name) .. "'"
    end
    return def, err
end

-- views/<name>.lua first, without touching extensions at all -- the
-- nav rail checks for prioritized_tasks on every request.
function view.load(db_path, name, root)
    if not schema.valid_resource_name(name) then
        return nil, "invalid view name: " .. tostring(name)
    end
    config = require("config")
    path = paths.joinpath(config.views_dir(root), name .. ".lua")
    if paths.file_exists(path) then
        return view.load_file(path)
    end
    files = view.definition_files(db_path, root)
    if files != nil then
        for _, f in ipairs(files) do
            if f.name == name and f.extension != nil then
                return load_definition_file(f)
            end
        end
    end
    return nil, "cannot open view: " .. path
end

function view.all(db_path, root)
    files, files_err = view.definition_files(db_path, root)
    if files == nil then
        return {{name = "(views)", def = nil, err = files_err}}
    end
    result = {}
    for _, f in ipairs(files) do
        def, err = load_definition_file(f)
        table.insert(result, {name = f.name, def = def, err = err})
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
    return require("store").approved_content(db_path, "view", name)
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
    require("store").approve(db_path, "view", def.name, view.approval_identity(def), approved_by)
end

function view.revoke(db_path, name)
    view.init_schema(db_path)
    require("store").revoke(db_path, "view", name)
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
-- Luam (each require() gets its own reference; see luam/lib/database.lua
-- for the same require), so it's pulled in locally here rather than
-- assumed available.
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
-- Executes a view's SELECT across SQLite and MariaDB, delegating
-- single-parameter binding to `db.query_params` (`luam/lib/database.lua`)
-- so this file never imports `sqlite3` or `database_adapter` directly.
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

    return db.query_params(db_path, sql_text, {{type = param_type, value = param_value}})
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
    problem = view.select_only_problem(sql_text)
    if problem != nil then
        return nil, nil, "refusing to run: not a plain SELECT -- " .. problem
    end

    config = require("config")
    row_cap = config.platform_config().platform_adhoc_row_cap
    query_text = sql_text
    body = string.gsub(sql_text, "%s+$", "")
    if string.sub(body, -1) == ";" then
        body = string.sub(body, 1, -2)
    end
    has_own_limit = has_top_level_limit(body)
    capped = false
    if has_own_limit == false then
        query_text = body .. string.format(" LIMIT %d;", row_cap + 1)
        capped = true
    end

    ok, rows, column_names = pcall(db.query, db_path, query_text)
    if ok == false then
        return nil, nil, "invalid sql (" .. view.sql_error_hint(tostring(rows)) .. "): " .. tostring(rows)
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
-- password hashes, auth_api_key secrets, agent_message/agent_pending_action,
-- system_state, or any other internal table entity.list/get
-- could never expose either).

-- The single source of truth for "this is a real, hand-rolled table the
-- model is allowed to know exists and name" -- deliberately narrow, not
-- "every hand-rolled table" (agent_message/agent_pending_action/
-- agent_background_task, system_state, auth_user/auth_api_key with real
-- secrets, ...). Whether a table belongs here is a real per-table
-- security judgment call, not a mechanical copy-paste -- the comment
-- above run_agent_query names agent_message/agent_pending_action
-- specifically as tables that must stay opaque to the model.
--
-- That judgment call is made exactly once, here -- agent_tools.lua's own
-- HAND_ROLLED_ENTITY_FIELDS (the per-table entity.fields column-listing
-- functions) validates its own keys against this table at load time
-- (errors loudly, not silently, on a mismatch) rather than hand-
-- maintaining a second, independently-drifting copy of the same
-- decision. A table can be named here without also being in
-- HAND_ROLLED_ENTITY_FIELDS (not every real table gets its own
-- individual entity.fields listing -- document_link/knowledge_pool_state
-- are only ever named in prose, via document.knowledge_pool_sql_columns_text)
-- but never the other way around.
HAND_ROLLED_DOCUMENTED_TABLES = {
    document_link = true,
    entity_event = true,
    knowledge_pool_state = true,
    agent_session = true,
    document_embedding = true,
    knowledge_retrieval = true,
    knowledge_retrieval_hit = true,
    agent_model_call = true,
}
-- Attached to the module table too (not just left as the bare global
-- run_agent_query itself uses below) -- a require()'d module's own
-- top-level locals/globals aren't visible to the file that required it,
-- only what it explicitly returns, and agent_tools.lua's own load-time
-- consistency check needs real cross-file access to this table.
view.HAND_ROLLED_DOCUMENTED_TABLES = HAND_ROLLED_DOCUMENTED_TABLES

-- Words that terminate a FROM/JOIN table-reference item or cannot be a
-- bare table alias.
SQL_CLAUSE_WORDS = {
    ["as"] = true, where = true, on = true, using = true, join = true, straight_join = true,
    left = true, right = true, inner = true, outer = true, cross = true, full = true,
    natural = true, group = true, order = true, limit = true, offset = true,
    union = true, intersect = true, except = true, having = true, window = true,
    indexed = true, ["not"] = true, use = true, force = true, ignore = true,
}

FROM_CLAUSE_TERMINATORS = {
    where = true, on = true, using = true, join = true, straight_join = true,
    left = true, right = true, inner = true, outer = true, cross = true, full = true,
    natural = true, group = true, order = true, limit = true, offset = true,
    union = true, intersect = true, except = true, having = true, window = true,
}

function is_ident_token(tok)
    return tok != nil and (tok.kind == "word" or tok.kind == "ident")
end

-- Shared token-level extractor for every FROM / JOIN / STRAIGHT_JOIN
-- clause across the query (including inside subqueries and CTE bodies).
-- Handles bare and quoted identifiers (`"tbl"`, `` `tbl` ``, `[tbl]`),
-- schema-qualified names (`db.tbl`), comments, subqueries followed by
-- comma-joins (`FROM (SELECT ...) s, other_tbl`), and aliased comma-joins
-- (`FROM a x, b y`). Returns `{entries = {{lower=, raw=, alias=}, ...}}`.
function scan_table_references(sql_text)
    tokens, _ = scan_sql_tokens(sql_text)
    if tokens == nil then
        return {}
    end
    entries = {}
    n = #tokens
    i = 1
    while i <= n do
        tok = tokens[i]
        if tok.kind == "word" and (tok.value == "from" or tok.value == "join" or tok.value == "straight_join") then
            clause_depth = tok.depth
            is_from = (tok.value == "from")
            k = i + 1
            while k <= n do
                cur = tokens[k]
                if cur.depth < clause_depth then
                    break
                end
                if cur.kind == "word" and cur.value == "lateral" and cur.depth == clause_depth then
                    k = k + 1
                    cur = tokens[k]
                end
                if cur == nil then
                    break
                end

                if cur.kind == "punct" and cur.value == "(" and cur.depth == clause_depth then
                    -- Derived subquery or parenthesized join; its inner FROM/JOIN
                    -- clauses are visited by the outer `i` scan, so advance past
                    -- the matching `)` at `clause_depth` to see any trailing `, tbl`.
                    k = k + 1
                    while k <= n do
                        t2 = tokens[k]
                        if t2.kind == "punct" and t2.value == ")" and t2.depth == clause_depth then
                            k = k + 1
                            break
                        end
                        k = k + 1
                    end
                elseif is_ident_token(cur) and cur.depth == clause_depth then
                    t_lower = cur.value
                    t_raw = cur.raw
                    k = k + 1
                    -- Schema-qualified `schema.table` stays qualified so e.g.
                    -- `main.auth_user` or `doc.auth_user` cannot match an
                    -- unqualified registered table name.
                    if k + 1 <= n and tokens[k].kind == "punct" and tokens[k].value == "."
                            and tokens[k].depth == clause_depth and is_ident_token(tokens[k + 1]) then
                        t_lower = t_lower .. "." .. tokens[k + 1].value
                        t_raw = t_raw .. "." .. tokens[k + 1].raw
                        k = k + 2
                    end
                    alias_lower = nil
                    if k <= n and tokens[k].depth == clause_depth then
                        if tokens[k].kind == "word" and tokens[k].value == "as" and k + 1 <= n and is_ident_token(tokens[k + 1]) then
                            alias_lower = tokens[k + 1].value
                            k = k + 2
                        elseif is_ident_token(tokens[k]) and (tokens[k].kind == "ident" or SQL_CLAUSE_WORDS[tokens[k].value] != true) then
                            alias_lower = tokens[k].value
                            k = k + 1
                        end
                    end
                    table.insert(entries, {lower = t_lower, raw = t_raw, alias = alias_lower, keyword = tok.value})
                else
                    break
                end

                if not is_from then
                    break
                end

                -- Scan forward at `clause_depth` to either `,` (next comma-joined
                -- table in this FROM clause) or the end of the FROM clause.
                found_comma = false
                while k <= n do
                    tk = tokens[k]
                    if tk.depth < clause_depth then
                        break
                    end
                    if tk.depth == clause_depth then
                        if tk.kind == "punct" and tk.value == "," then
                            found_comma = true
                            k = k + 1
                            break
                        end
                        if tk.kind == "punct" and tk.value == ";" then
                            break
                        end
                        if tk.kind == "word" and FROM_CLAUSE_TERMINATORS[tk.value] == true then
                            break
                        end
                    end
                    k = k + 1
                end
                if not found_comma then
                    break
                end
            end
        end
        i = i + 1
    end
    return entries
end

function referenced_table_names(sql_text)
    names = {}
    for _, entry in ipairs(scan_table_references(sql_text)) do
        table.insert(names, entry.lower)
    end
    return names
end

-- Names a leading WITH-clause defines at depth 0:
--   WITH [RECURSIVE] a [(c1, c2)] AS (...), b AS (...) SELECT ...
-- Token-scoped to depth 0 in the leading WITH header so `<ident> AS (`
-- inside a string literal or comment can never whitelist a table name.
function cte_names(sql_text)
    names = {}
    tokens, _ = scan_sql_tokens(sql_text)
    if tokens == nil or #tokens == 0 then
        return names
    end
    if tokens[1].kind != "word" or tokens[1].value != "with" then
        return names
    end
    k = 2
    if k <= #tokens and tokens[k].kind == "word" and tokens[k].value == "recursive" then
        k = k + 1
    end
    while k <= #tokens do
        cte_tok = tokens[k]
        if not is_ident_token(cte_tok) or cte_tok.depth != 0 then
            break
        end
        cte_name = cte_tok.value
        k = k + 1
        -- Optional CTE column list: `WITH totals(day, n) AS (...)`
        if k <= #tokens and tokens[k].kind == "punct" and tokens[k].value == "(" and tokens[k].depth == 0 then
            k = k + 1
            while k <= #tokens do
                if tokens[k].kind == "punct" and tokens[k].value == ")" and tokens[k].depth == 0 then
                    k = k + 1
                    break
                end
                k = k + 1
            end
        end
        if k + 1 > #tokens or tokens[k].kind != "word" or tokens[k].value != "as" or tokens[k].depth != 0 then
            break
        end
        k = k + 1
        if tokens[k].kind != "punct" or tokens[k].value != "(" or tokens[k].depth != 0 then
            break
        end
        table.insert(names, cte_name)
        -- Advance past the CTE body's closing `)` at depth 0
        k = k + 1
        while k <= #tokens do
            if tokens[k].kind == "punct" and tokens[k].value == ")" and tokens[k].depth == 0 then
                k = k + 1
                break
            end
            k = k + 1
        end
        if k <= #tokens and tokens[k].kind == "punct" and tokens[k].value == "," and tokens[k].depth == 0 then
            k = k + 1
        else
            break
        end
    end
    return names
end

-- view.query_aliases(sql_text) -> {name = table}: every table a FROM or
-- JOIN clause names, under its own name and under its alias
-- ("FROM experiment e", "JOIN project AS p", "FROM a x, b y"), all
-- lowercased. For telling the model, when a query fails on a column,
-- which table that column's prefix stands for (#8).
function view.query_aliases(sql_text)
    aliases = {}
    for _, entry in ipairs(scan_table_references(tostring(sql_text))) do
        aliases[entry.lower] = entry.lower
        if entry.alias != nil then
            aliases[entry.alias] = entry.lower
        end
    end
    return aliases
end

-- Registered entity tables plus the storage tables that hold their
-- own multi-valued/polymorphic field values -- entity data the model can
-- already read one row at a time via entity.get, just not joinable in
-- SQL without these. Seen in prod: "Unknown column 'cm.usage'" (a
-- multi_select lives in its junction table) and sample lineage walked
-- ~25 entity.get calls deep because entity_ref was refused. None of
-- these hold anything beyond entity ids/types/values.
--
-- document_link and entity_event follow the same rule from the other
-- side: the agent sees what a user sees. Every document page shows its
-- links, every detail page shows its ledger history -- the agent could
-- read neither across rows (document.links is one document at a time,
-- entity.get returns current values only).
function view.queryable_tables(db_path)
    allowed = {entity_ref = true, document_link = true, entity_event = true}
    for _, t in ipairs(schema.list(db_path)) do
        allowed[t.name] = true
        for _, f in ipairs(schema.fields(db_path, t.name)) do
            if f.type == "multi_select" or f.type == "multi_reference" then
                allowed[schema.multi_field_table_name(t.name, f.name)] = true
            end
        end
    end
    return allowed
end

-- Every registered entity table carries archived_at (see
-- schema.lua's RESERVED_FIELD_NAMES), and archived rows stay in the
-- table -- so a query that never mentions archived_at silently counts
-- them as live. Seen in prod: a nightly archive-and-recreate sync
-- turned a 5-ingredient recipe into 143 rows. Rewriting the model's
-- SQL to filter them would have to understand its aliases/joins/CTEs;
-- a note naming the affected tables is structural enough to reliably
-- surface the problem, and leaves the choice (sometimes archived rows
-- ARE wanted) with the query's author.
function archived_rows_note(db_path, sql_text, referenced)
    if string.find(string.lower(sql_text), "archived_at", 1, true) != nil then
        return nil
    end
    registered = {}
    for _, t in ipairs(schema.list(db_path)) do
        registered[t.name] = true
    end
    affected = {}
    seen = {}
    for _, name in ipairs(referenced) do
        if registered[name] == true and seen[name] == nil then
            seen[name] = true
            ok, count_rows = pcall(db.query, db_path, "SELECT COUNT(*) AS n FROM " .. name .. " WHERE archived_at IS NOT NULL;")
            if ok == true and count_rows != nil and count_rows[1] != nil then
                n = tonumber(count_rows[1].n)
                if n != nil and n > 0 then
                    table.insert(affected, name .. " (" .. tostring(n) .. " archived rows)")
                end
            end
        end
    end
    if #affected == 0 then
        return nil
    end
    return "Note: this query doesn't filter archived rows, and these tables have some: " .. table.concat(affected, ", ") ..
        ". Archived rows are deleted/superseded records -- unless you specifically want them, re-run with `<table>.archived_at IS NULL` for each."
end

-- A separate, smaller default cap than platform_adhoc_row_cap -- that
-- one is sized for a human reading an HTML table in a browser; this
-- result goes straight into the model's own prompt/context, where 1000
-- rows would be wasteful at best and a real token-cost problem at
-- worst (and the right number here depends on the configured
-- AGENT_MODEL's own context budget, not just this code).
function view.run_agent_query(db_path, sql_text)
    problem = view.select_only_problem(sql_text)
    if problem != nil then
        return nil, nil, "refusing to run: not a plain SELECT -- " .. problem
    end

    config = require("config")
    row_cap = config.platform_config().agent_query_row_cap
    referenced = referenced_table_names(sql_text)
    if #referenced == 0 then
        return nil, nil, "refusing to run: no FROM/JOIN table found"
    end

    allowed = view.queryable_tables(db_path)
    for _, name in ipairs(cte_names(sql_text)) do
        allowed[name] = true
    end
    for _, name in ipairs(referenced) do
        if allowed[name] == nil then
            if HAND_ROLLED_DOCUMENTED_TABLES[name] == true then
                -- A real table, not a typo -- just intentionally excluded
                -- from this tool (system/derived event logs, never
                -- schema.register()'d; see doc/architecture.md's own
                -- "Hand-rolled tables" list). Distinguished from the
                -- generic "unregistered type" message below so the
                -- caller (the model, per its own system-prompt
                -- instruction to self-verify SQL via this tool before
                -- presenting it) doesn't mistake this refusal for a
                -- broken query and "fix" it into something else --
                -- it's still valid SQL for the admin /sql console,
                -- which has no such restriction.
                return nil, nil, "refusing to run: '" .. name .. "' is a real table, but intentionally excluded from entity.query (a hand-rolled system/derived log, not a registered entity type) -- this isn't a typo or a broken query, just not self-verifiable through this tool; it's still valid SQL for the admin /sql console"
            end
            message = "refusing to run: '" .. name .. "' is not a registered entity type -- only registered entity tables can be queried this way"
            -- SQL written before daat's schema revision (in chat history
            -- or a compaction summary) can still use an old table name.
            renamed = require("store").RENAMED_TABLES[name]
            if renamed != nil then
                message = message .. " ('" .. name .. "' was renamed to '" .. renamed .. "')"
            end
            if name == "sqlite_master" or name == "information_schema" or name == "sqlite_schema" then
                message = message .. " (to inspect the schema, call entity.list_types/entity.fields/entity.relationships instead; queries run in " .. view.sql_dialect_name() .. ")"
            end
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
    has_own_limit = has_top_level_limit(body)
    capped = false
    if has_own_limit == false then
        query_text = body .. string.format(" LIMIT %d;", row_cap + 1)
        capped = true
    end

    ok, rows, column_names = pcall(db.query, db_path, query_text)
    if ok == false then
        return nil, nil, "invalid sql (" .. view.sql_error_hint(tostring(rows)) .. "): " .. tostring(rows)
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
    return column_names, rows, nil, truncated, total_count, archived_rows_note(db_path, sql_text, referenced)
end

-- The SQL dialect entity.query actually runs, named for the model so it
-- doesn't guess (seen in prod: sqlite_master/julianday tried ~15 times
-- against MariaDB).
function view.sql_dialect_name()
    config = require("config")
    if config.db_backend() == "mariadb" then
        return "MariaDB/MySQL dialect: use DATEDIFF/TIMESTAMPDIFF, LN, window functions; ONLY_FULL_GROUP_BY applies; no sqlite_master/julianday"
    end
    return "SQLite dialect: use julianday()/strftime(), no DATEDIFF; no LN/EXP/POWER (use calc.evaluate on the returned values)"
end

-- What to tell the model about a failed query. A missing table or
-- column is a guessed name, not a dialect problem: naming the dialect
-- there sent the agent after date functions instead of the schema
-- (found by the agent scorecard, doc/agent-eval.md). Everything else
-- keeps the dialect note, since a wrong function or syntax is the
-- common other cause.
SCHEMA_ERROR_PATTERNS = {"no such column", "no such table", "unknown column", "unknown table", "doesn't exist"}

function view.sql_error_hint(err_text)
    lowered = string.lower(tostring(err_text))
    for _, pattern in ipairs(SCHEMA_ERROR_PATTERNS) do
        if string.find(lowered, pattern, 1, true) != nil then
            return "a table or column name doesn't exist: call entity.fields/entity.relationships for the real names; " ..
                "a multi-value field is its own table <type>_<field> with columns <type>_id and <field>_id"
        end
    end
    return view.sql_dialect_name()
end

-- CLI entry point: `daat view <list|show|approve|revoke> [args]`
function view.do_view(cmd_args, db_path)
    action = cmd_args[1]

    if action == "list" then
        for _, entry in ipairs(view.all(db_path)) do
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
        def, err = view.load(db_path, name)
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
        def, err = view.load(db_path, name)
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
