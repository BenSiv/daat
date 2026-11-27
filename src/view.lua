-- Read-only SQL views, ad-hoc /sql execution, and table-allowlisted agent queries.
-- See doc/decisions/004-sandboxed-content-and-hash-keyed-approvals.md.

const db = require("database")
const json = require("dkjson")
const paths = require("paths")
const lfs = require("lfs")
const sandbox = require("sandbox")
const schema = require("schema")
const store_lib = require("store")
const config_lib = require("config")
const extension_lib = require("extension")

const view = {}

function view.init_schema(db_path)
    store_lib.ensure_system_tables(db_path)
end

-- Matched on token/word boundaries so column names like updated_at are not rejected.
const FORBIDDEN_SQL_WORDS = {
    "insert", "update", "delete", "drop", "alter", "attach", "detach",
    "pragma", "create", "replace", "vacuum", "reindex", "trigger", "exec",
    "outfile", "dumpfile", "load_file", "load_extension",
    "get_lock", "release_lock", "release_all_locks", "sleep", "benchmark",
}

const FORBIDDEN_SQL_WORDS_SET = {}
for _, w in ipairs(FORBIDDEN_SQL_WORDS) do
    FORBIDDEN_SQL_WORDS_SET[w] = true
end

-- Tokenizes SQL while stripping comments, rejecting MySQL /*! ... */ comments, and
-- unquoting identifiers so table allowlists see real names.
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

function view.select_only_problem(sql_text)
    if type(sql_text) != "string" then
        return "must start with SELECT (or WITH ... SELECT)"
    end
    -- SQLite and MySQL disagree on \' escaping; scan raw words whenever a backslash is present.
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

const PARAM_TYPES = {"integer", "number", "text"}

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
        -- 'id' and 'name' collide with CGI/Fossil /ext dispatch query parameters.
        if def.param.name == "id" or def.param.name == "name" then
            return "view '" .. tostring(def.name) .. "': param name can't be 'id' or 'name' -- both collide with Fossil's own /ext dispatch (see doc/deployment.md)"
        end
        if is_valid_param_type(def.param.type) == false then
            return "view '" .. tostring(def.name) .. "': param 'type' must be one of integer/number/text"
        end
    end
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

function view.definition_files(db_path, root)
    return extension_lib.definition_files(db_path, config_lib.views_dir(root), config_lib.extensions_dir(root), "views", false)
end

function load_definition_file(f)
    def, err = view.load_file(f.path)
    if def != nil and f.extension != nil and def.name != f.name then
        return nil, "extension '" .. f.extension .. "' declares view '" .. f.name ..
            "' but " .. f.path .. " defines '" .. tostring(def.name) .. "'"
    end
    return def, err
end

function view.load(db_path, name, root)
    if not schema.valid_resource_name(name) then
        return nil, "invalid view name: " .. tostring(name)
    end
    config = config_lib
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

function view.effective_sql(db_path, def)
    if db.is_mariadb(db_path) and def.sql_mariadb != nil then
        return def.sql_mariadb
    end
    return def.sql
end

-- Includes both SQLite and MariaDB SQL variants so editing either invalidates approval.
function view.approval_identity(def)
    if def.sql_mariadb == nil then
        return def.sql
    end
    return def.sql .. "\n--- sql_mariadb ---\n" .. def.sql_mariadb
end

function view.approved_sql(db_path, name)
    view.init_schema(db_path)
    return store_lib.approved_content(db_path, "view", name)
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
    store_lib.approve(db_path, "view", def.name, view.approval_identity(def), approved_by)
end

function view.revoke(db_path, name)
    view.init_schema(db_path)
    store_lib.revoke(db_path, "view", name)
end

function view.run(db_path, def, param_value)
    param_type = nil
    if def.param != nil then
        param_type = def.param.type
    end
    return view.run_sql(db_path, view.effective_sql(db_path, def), param_type, param_value)
end

-- Single-statement SELECT runner; binds optional '?' parameter via db.query_params.
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

-- Heuristic FROM/JOIN table extraction for UI reference-column linking on ad-hoc /sql results.
function view.guess_from_table(sql_text)
    table_name = string.match(sql_text, "[Ff][Rr][Oo][Mm]%s+[`\"]?([A-Za-z_][A-Za-z0-9_]*)[`\"]?")
    return table_name
end

function view.guess_tables(sql_text)
    tables = {}
    seen = {}
    from_table = view.guess_from_table(sql_text)
    if from_table != nil then
        table.insert(tables, from_table)
        seen[from_table] = true
    end
    for joined in string.gmatch(sql_text, "[Jj][Oo][Ii][Nn]%s+[`\"]?([A-Za-z_][A-Za-z0-9_]*)[`\"]?") do
        if seen[joined] == nil then
            table.insert(tables, joined)
            seen[joined] = true
        end
    end
    return tables
end

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

-- Fetches row_cap + 1 rows when uncapped to detect truncation without a second COUNT(*).
function view.run_adhoc(db_path, sql_text)
    problem = view.select_only_problem(sql_text)
    if problem != nil then
        return nil, nil, "refusing to run: not a plain SELECT -- " .. problem
    end

    config = config_lib
    row_cap = config.load().adhoc_row_cap
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

-- Non-entity internal tables documented to the agent (cross-checked by agent_tools.lua);
-- auth/session/pending-action tables must never appear here.
const HAND_ROLLED_DOCUMENTED_TABLES = {
    document_link = true,
    entity_event = true,
    knowledge_pool_state = true,
    agent_session = true,
    document_embedding = true,
    knowledge_retrieval = true,
    knowledge_retrieval_hit = true,
    agent_model_call = true,
}
view.HAND_ROLLED_DOCUMENTED_TABLES = HAND_ROLLED_DOCUMENTED_TABLES

const SQL_CLAUSE_WORDS = {
    ["as"] = true, where = true, on = true, using = true, join = true, straight_join = true,
    left = true, right = true, inner = true, outer = true, cross = true, full = true,
    natural = true, group = true, order = true, limit = true, offset = true,
    union = true, intersect = true, except = true, having = true, window = true,
    indexed = true, ["not"] = true, use = true, force = true, ignore = true,
}

const FROM_CLAUSE_TERMINATORS = {
    where = true, on = true, using = true, join = true, straight_join = true,
    left = true, right = true, inner = true, outer = true, cross = true, full = true,
    natural = true, group = true, order = true, limit = true, offset = true,
    union = true, intersect = true, except = true, having = true, window = true,
}

function is_ident_token(tok)
    return tok != nil and (tok.kind == "word" or tok.kind == "ident")
end

-- Extracts {lower, raw, alias, keyword} for every FROM/JOIN table reference across
-- subqueries, CTE bodies, quoted/qualified names, and comma-joins.
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
                    -- Keep schema.table qualified so e.g. main.auth_user never matches an unqualified entry.
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

-- Leading depth-0 CTE names defined by WITH [RECURSIVE] <name> [(cols)] AS (...).
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

-- Tables allowed in agent entity.query: registered entity types, their multivalue/polymorphic
-- junction tables, document_link, and entity_event.
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

-- Warns the agent when a query omits archived_at on entity tables containing archived rows.
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
            ok, count_rows = pcall(db.query, db_path, "SELECT COUNT(*) AS n FROM " .. db.quote_ident(name) .. " WHERE archived_at IS NOT NULL;")
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

function view.run_agent_query(db_path, sql_text)
    problem = view.select_only_problem(sql_text)
    if problem != nil then
        return nil, nil, "refusing to run: not a plain SELECT -- " .. problem
    end

    config = config_lib
    row_cap = config.load().agent_query_row_cap
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
                return nil, nil, "refusing to run: '" .. name .. "' is a real table, but intentionally excluded from entity.query (a hand-rolled system/derived log, not a registered entity type) -- this isn't a typo or a broken query, just not self-verifiable through this tool; it's still valid SQL for the admin /sql console"
            end
            message = "refusing to run: '" .. name .. "' is not a registered entity type -- only registered entity tables can be queried this way"
            renamed = store_lib.RENAMED_TABLES[name]
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
        count_ok, count_rows = pcall(db.query, db_path, "SELECT COUNT(*) AS n FROM (" .. body .. ") AS _agent_query_count;")
        if count_ok == true and count_rows != nil and count_rows[1] != nil then
            total_count = tonumber(count_rows[1].n)
        end
    end
    return column_names, rows, nil, truncated, total_count, archived_rows_note(db_path, sql_text, referenced)
end

function view.sql_dialect_name()
    config = config_lib
    if config.db_backend() == "mariadb" then
        return "MariaDB/MySQL dialect: use DATEDIFF/TIMESTAMPDIFF, LN, window functions; ONLY_FULL_GROUP_BY applies; no sqlite_master/julianday"
    end
    return "SQLite dialect: use julianday()/strftime(), no DATEDIFF; no LN/EXP/POWER (use calc.evaluate on the returned values)"
end

-- Route missing table/column errors to schema discovery tools rather than SQL dialect hints.
const SCHEMA_ERROR_PATTERNS = {"no such column", "no such table", "unknown column", "unknown table", "doesn't exist"}

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
