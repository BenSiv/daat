db = require("db")
config = require("config")
schema = require("schema")
entity = require("entity")
ledger = require("ledger")
view = require("view")
template = require("template")
html = require("html")
json = require("dkjson")
paths = require("paths")
auth = require("auth")
document = require("document")
knowledge = require("knowledge")
agent = require("agent")
multipart = require("multipart")
label = require("label")

cgi = {}

-- Duplicated from config.lua/html.lua (both already keep their own
-- copy for the same reason) -- Luam's per-module isolation means a
-- bare top-level global in one file isn't visible from another, only
-- what a module explicitly returns on its own table.
THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
}

-- The baseline capability every gated route (other than /login,
-- /logout, and the login form's own POST) requires. Real session/login
-- machinery lives in auth.lua -- see cgi.handle_request's session
-- verification block below.
REQUIRED_CAPABILITY = "i"

-- Rows per /browse page. A flat, fixed page size rather than a
-- user-configurable one -- simple, and every entity type here is a
-- plain projected SQL table so COUNT/LIMIT/OFFSET are cheap regardless
-- of size.
BROWSE_PAGE_SIZE = 100

function cgi.has_capability(capabilities, letter)
    if capabilities == nil or capabilities == "" then
        return false
    end
    return string.find(capabilities, letter, 1, true) != nil
end

-- Luam's and/or require boolean operands, so plain "value or default"
-- nil-coalescing (fine in stock Lua) errors here whenever value is a
-- truthy non-boolean (e.g. any real env var/query value) -- exactly the
-- normal-success case, not just an edge case.
function default_value(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

-- The current state of one chat session as a JSON-safe table -- shared
-- by every /api/chat-widget-* route (start/send/approve/deny/history)
-- below, all of which end by returning "here's the state now" so the
-- floating widget (see html.page_shell) never has to separately poll.
function chat_widget_state(db_path, session_id)
    -- false: the widget is a human-facing view -- tool calls/raw tool
    -- results are filtered out (see agent.all_messages' own comment);
    -- the complete record is untouched in agent_message and in the
    -- synced session document.
    messages = agent.all_messages(db_path, session_id, false)
    -- Rendered server-side so the widget's own JS can trust and embed
    -- this directly (see html.page_shell's render()), rather than
    -- re-escaping already-rendered HTML or re-implementing Markdown
    -- rendering in JS.
    for _, msg in ipairs(messages) do
        if html.CHAT_MARKDOWN_ROLES[msg.role] == true then
            msg.content = document.render_markdown(msg.content)
        end
    end
    pending = agent.latest_pending(db_path, session_id)
    pending_out = nil
    if pending != nil then
        args, _, _ = json.decode(pending.args_json)
        if args == nil then
            args = {}
        end
        pending_out = {id = pending.id, tool = pending.tool, method = pending.method, args = args}
    end
    -- The most recent SQL the model constructed this session -- whether
    -- via an actual entity.query tool call, or written out as plain
    -- final-answer text (e.g. "write me a query" answered as a fenced
    -- code block instead of a real tool call) -- for the /sql console's
    -- client-side prefill (see html.lua's chat widget JS); nil if
    -- neither has happened yet. This is the one deliberate, narrow
    -- exception to the "widget only sees human-facing content" rule
    -- just above: real SQL text, not a generic exposure of every tool
    -- call's raw arguments.
    last_query_sql = agent.last_console_query_sql(db_path, session_id)
    return {session_id = session_id, messages = messages, pending = pending_out, last_query_sql = last_query_sql}
end

-- Collapses entity.create/update's issues list into one human-readable
-- string, for a plain-form page (document-edit) that has nowhere to
-- show per-field errors the way the JS-driven registration table does.
function issues_to_message(issues)
    if issues == nil or #issues == 0 then
        return "Could not save."
    end
    parts = {}
    for _, issue in ipairs(issues) do
        if issue.severity == "error" then
            table.insert(parts, tostring(issue.message))
        end
    end
    if #parts == 0 then
        return "Could not save."
    end
    return table.concat(parts, "; ")
end

function parse_query(query_str)
    params = {}
    if query_str == nil then return params end
    for k, v in string.gmatch(query_str, "([^&=]+)=([^&=]*)") do
        -- simple url decoding for basic params
        decoded_v = string.gsub(string.gsub(v, "+", " "), "%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
        params[k] = decoded_v
    end
    return params
end

-- Filters/reorders a schema layout's fields to a comma-separated
-- allowlist, e.g. "?columns=lab_name,volume_ul" -- lets one embedded
-- registration table show only a curated subset of a schema's fields,
-- in a chosen order.
function filter_layout_columns(layout, columns_param)
    if columns_param == nil or columns_param == "" then
        return layout
    end
    by_name = {}
    for _, field in ipairs(layout.fields) do
        by_name[field.name] = field
    end
    filtered_fields = {}
    for wanted_name in string.gmatch(columns_param, "[^,]+") do
        field = by_name[wanted_name]
        if field != nil then
            table.insert(filtered_fields, field)
        end
    end
    if #filtered_fields == 0 then
        return layout
    end
    return {name = layout.name, fields = filtered_fields}
end

-- A `?lock_<field_name>=<value>` query param fixes that
-- field's value across every row of the batch-entry table (e.g.
-- `?lock_mixture=5` when adding several ingredients for one mixture)
-- -- generic, not specific to any one schema/field. Only single-value
-- fields (not multi_select/multi_reference) are supported; nothing
-- currently needs a locked *list*. For a `reference` field, resolves a
-- real display label (the same one entity links render elsewhere)
-- instead of showing the user a bare id.
function collect_locked_fields(db_path, layout, params)
    locked = {}
    for key, value in pairs(params) do
        if string.sub(key, 1, 5) == "lock_" then
            field_name = string.sub(key, 6)
            for _, field in ipairs(layout.fields) do
                if field.name == field_name and field.type != "multi_select" and field.type != "multi_reference" then
                    -- NOT named `label` -- that bare global is the
                    -- required `label` module (src/label.lua);
                    -- reassigning it here would silently break
                    -- any later `label.xxx` call in this same request.
                    display_label = value
                    if field.type == "reference" and field.ref_entity_type != nil then
                        resolved = html.entity_display_label(db_path, field.ref_entity_type, tonumber(value))
                        if resolved != nil then
                            display_label = resolved
                        end
                    end
                    locked[field_name] = {value = value, label = display_label}
                end
            end
        end
    end
    return locked
end

-- How many preview rows (mixture -> its own ingredients,
-- etc.) render inline on /detail before pointing at the full,
-- paginated /browse view instead.
RELATED_RECORDS_PREVIEW_LIMIT = 10

-- Every real, plain `reference` field elsewhere that points back at
-- this entity_type -- e.g. ingredient.mixture -> mixture -- with a
-- short preview of the actual rows. Fully generic: computed from
-- schema.relationships(), not specific to any one pair of types.
-- multi_reference edges are skipped -- those live in a companion
-- junction table, not a plain column on the referencing
-- type's own table, so entity.list_by_field's WHERE <field> = <id>
-- wouldn't apply to them the same way.
function related_records(db_path, entity_type, entity_id)
    result = {}
    for _, edge in ipairs(schema.relationships(db_path)) do
        if edge.to_type == entity_type and edge.field_type == "reference" then
            total = entity.count_by_field(db_path, edge.from_type, edge.field_name, entity_id)
            rows = entity.list_by_field(db_path, edge.from_type, edge.field_name, entity_id, RELATED_RECORDS_PREVIEW_LIMIT)
            table.insert(result, {from_type = edge.from_type, field_name = edge.field_name, total = total, rows = rows})
        end
    end
    return result
end

-- The `entry` query param is the embedding notebook entry's identifier,
-- whatever the client sent. Optional.
function source_from_params(params)
    source = {}
    if params.entry != nil and params.entry != "" then
        source.notebook_entry_id = params.entry
    end
    return source
end

-- `extra_headers` is an optional list of raw "Name: value" header
-- lines (used for Set-Cookie, which can't be folded into a single
-- header the way Content-Type/Content-Length are).
function print_response(status, content_type, body, extra_headers)
    io.write("Status: " .. status .. "\r\n")
    io.write("Content-Type: " .. content_type .. "\r\n")
    if extra_headers != nil then
        for _, header_line in ipairs(extra_headers) do
            io.write(header_line .. "\r\n")
        end
    end
    io.write("Content-Length: " .. string.len(body) .. "\r\n")
    io.write("\r\n")
    io.write(body)
end

-- Parses the raw "k1=v1; k2=v2" HTTP_COOKIE env var into a table.
function parse_cookies(cookie_header)
    cookies = {}
    if cookie_header == nil then
        return cookies
    end
    for pair in string.gmatch(cookie_header, "([^;]+)") do
        key, value = string.match(pair, "%s*([^=]+)=(.*)")
        if key != nil then
            cookies[key] = value
        end
    end
    return cookies
end

-- Builds one Set-Cookie header line. `max_age_seconds == nil` means a
-- session cookie (cleared on browser close, not just on expiry) --
-- used for CSRF, which is meant to live only as long as the login
-- session cookie it accompanies is being actively used, not persist as
-- its own independent lifetime. Marks Secure automatically whenever
-- the request itself arrived over HTTPS (HTTPS env var, the same
-- signal most CGI-hosting web servers set) rather than hardcoding it,
-- since a hardcoded Secure would silently break local plain-HTTP
-- testing/dev.
function set_cookie_header(name, value, max_age_seconds, http_only)
    parts = {name .. "=" .. value, "Path=/", "SameSite=Lax"}
    if max_age_seconds != nil then
        table.insert(parts, "Max-Age=" .. tostring(max_age_seconds))
    end
    if http_only == true then
        table.insert(parts, "HttpOnly")
    end
    https = os.getenv("HTTPS")
    if https != nil and https != "" then
        table.insert(parts, "Secure")
    end
    return "Set-Cookie: " .. table.concat(parts, "; ")
end

function clear_cookie_header(name)
    return "Set-Cookie: " .. name .. "=; Path=/; Max-Age=0"
end

-- Double-submit CSRF check for authenticated, state-changing POST
-- routes. The token travels as a custom request header (arrives as
-- HTTP_X_CSRF_TOKEN via the standard CGI header<->env-var mapping),
-- set client-side by JS reading its own non-HttpOnly csrf cookie --
-- see html.lua's getCsrfToken() helper -- or, for a plain HTML <form>
-- POST that can't attach a custom header at all (e.g. the /admin/users
-- pages below), a hidden form field instead. `form_token` is only read
-- if the header is absent.
function require_csrf(cookies, form_token)
    submitted = os.getenv("HTTP_X_CSRF_TOKEN")
    if submitted == nil or submitted == "" then
        submitted = form_token
    end
    return auth.verify_csrf(cookies.csrf, submitted)
end

-- A schema can declare admin_write_only = true (checked the
-- same way any other entity type could -- schema.admin_write_only
-- isn't special-cased to a specific type name here). Applied at every
-- entity-write route (create/update/archive/unarchive), not just
-- label_template's own -- any current or future type that sets the
-- flag gets the same gate for free.
function require_write_capability(db_path, capabilities, entity_type)
    if schema.admin_write_only(db_path, entity_type) == false then
        return true
    end
    return cgi.has_capability(capabilities, "a")
end

function handle_autocomplete(db_path, params)
    ref_type = params.type
    query_str = default_value(params.query, "")
    if ref_type == nil or ref_type == "" then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
    end
    if not schema.valid_name_syntax(ref_type) then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end

    if not db.table_exists(db_path, ref_type) then
        return print_response("200 OK", "application/json", "[]")
    end

    cols = db.get_columns(db_path, ref_type)
    if #cols == 0 then
        return print_response("200 OK", "application/json", "[]")
    end

    search_cols = {}
    for _, col in ipairs(cols) do
        if col == "id" or col == "name" or col == "title" or col == "label" or col == "lot_number" then
            table.insert(search_cols, col)
        end
    end
    if #search_cols == 0 then
        table.insert(search_cols, cols[1])
    end

    where = {}
    for _, col in ipairs(search_cols) do
        table.insert(where, col .. " LIKE " .. db.quote("%" .. query_str .. "%"))
    end

    has_name = false
    for _, col in ipairs(cols) do
        if col == "name" then has_name = true end
    end

    q = nil
    if has_name then
        q = "SELECT id, name FROM " .. ref_type
    else
        text_col = "id"
        for _, col in ipairs(cols) do
            if col != "id" and col != "created_at" and col != "created_by" and col != "updated_at" and col != "updated_by" and col != "last_event_id" then
                text_col = col
                break
            end
        end
        q = "SELECT id, " .. text_col .. " AS name FROM " .. ref_type
    end

    if #where > 0 then
        q = q .. " WHERE " .. table.concat(where, " OR ")
    end
    q = q .. " LIMIT 15;"

    rows = db.query(db_path, q)
    result = default_value(rows, {})
    return print_response("200 OK", "application/json", json.encode(result))
end

-- Backs the entity-reference hover preview (render_reference_value's
-- data popover-src, html.lua) -- a few key fields of the referenced
-- row, fetched lazily on hover rather than shown by default on every
-- reference column.
function handle_preview(db_path, params)
    entity_type = params.type
    entity_id = tonumber(params.entity_id)
    if entity_type == nil or entity_type == "" or entity_id == nil then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
    end
    if not schema.valid_name_syntax(entity_type) then
        return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
    end
    if not db.table_exists(db_path, entity_type) then
        return print_response("200 OK", "application/json", json.encode({html = "Unknown entity type."}))
    end

    rows = db.query(db_path, "SELECT * FROM " .. entity_type .. " WHERE id = " .. db.quote(entity_id) .. ";")
    if rows == nil or rows[1] == nil then
        return print_response("200 OK", "application/json", json.encode({html = "Not found."}))
    end
    -- Same raw-row override entity.list/entity.get need (see entity.lua's
    -- apply_computed_field_overrides) -- without it this preview would
    -- silently show a stale leftover column's old value instead of a
    -- polymorphic_reference field's real current link (structured as a
    -- Lua array here, not a string -- see the "table: 0x..." bug fixed
    -- just below via html.display_field_value).
    entity.apply_computed_field_overrides(db_path, entity_type, rows)
    row = rows[1]

    title = html.own_row_label(db_path, entity_type, row)
    if title == nil then
        title = entity_type .. " #" .. tostring(entity_id)
    end

    entity_layout, layout_err = schema.layout(db_path, entity_type)
    fields = {}
    if entity_layout != nil then
        fields = entity_layout.fields
    end

    field_lines = ""
    shown = 0
    for _, field in ipairs(fields) do
        if shown < 5 then
            value = row[field.name]
            -- A multi_reference/(multi_)polymorphic_reference field's
            -- value is a plain Lua array (see entity.apply_computed_
            -- field_overrides above), not a scalar -- tostring(value)
            -- on one of those is "table: 0x...", not "".
            -- html.display_field_value (same dispatcher /browse and
            -- /detail already use) renders every field type correctly
            -- and already HTML-escapes/links as needed, so it isn't
            -- re-escaped here the way a bare tostring() would need.
            is_empty = value == nil
            if type(value) == "table" then
                is_empty = #value == 0
            elseif tostring(value) == "" then
                is_empty = true
            end
            if is_empty == false then
                field_lines = field_lines .. "<div><strong>" .. html.html_escape(field.label) .. ":</strong> " ..
                    html.display_field_value(db_path, field, value) .. "</div>"
                shown = shown + 1
            end
        end
    end
    if field_lines == "" then
        field_lines = "<div style=\"color:#94a3b8;\">No fields to show.</div>"
    end

    preview_html = "<strong>" .. html.html_escape(title) .. "</strong>" ..
        "<hr style=\"margin:6px 0;border:none;border-top:1px solid #e2e8f0;\">" ..
        field_lines
    return print_response("200 OK", "application/json", json.encode({html = preview_html}))
end

-- `/login`: GET renders the form, POST verifies credentials (via
-- auth.login, which checks bcrypt + archived_at) and issues the two
-- cookies a session needs -- the HttpOnly signed session cookie and a
-- readable-by-JS CSRF token -- before redirecting to "/". Deliberately
-- not gated behind the session-verification block below (it runs
-- before that block in handle_request) since an unauthenticated caller
-- reaching /login is the expected case, not an error. Rendered through
-- the real page_shell (not a bare content fragment), so the login page
-- still picks up the deployment's theme.lua colors/site name and
-- favicon like every other page. show_sql_nav/show_admin_nav are
-- always false here (nobody is authenticated yet, so no capabilities
-- apply); has_tasks_view is still real, not hardcoded -- cheap to
-- check directly, same as every other route.
function handle_login(root, db_path, method, nonce, theme)
    has_tasks_view = view.load(config.views_dir(root), "prioritized_tasks") != nil

    if method == "POST" then
        body = io.read("*all")
        form = parse_query(body)
        cap, login_err = auth.login(db_path, form.login, form.password)
        if cap == nil then
            body_html = html.render_login("Invalid login or password.", nonce)
            return print_response("401 Unauthorized", "text/html",
                html.page_shell("Log in", "login", body_html, nonce, false, false, has_tasks_view, theme, nil))
        end

        session_cookie, cookie_err = auth.issue_session_cookie(root, form.login)
        if session_cookie == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(cookie_err) .. "</h3>")
        end
        csrf_token, csrf_err = auth.generate_csrf_token()
        if csrf_token == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(csrf_err) .. "</h3>")
        end

        return print_response("302 Found", "text/plain", "", {
            "Location: /",
            set_cookie_header("session", session_cookie, SESSION_TTL_SECONDS, true),
            set_cookie_header("csrf", csrf_token, nil, false)
        })
    end

    body_html = html.render_login(nil, nonce)
    return print_response("200 OK", "text/html",
        html.page_shell("Log in", "login", body_html, nonce, false, false, has_tasks_view, theme, nil))
end

function cgi.handle_request()
    path_info = default_value(os.getenv("PATH_INFO"), "/register")
    query_string = default_value(os.getenv("QUERY_STRING"), "")
    method = default_value(os.getenv("REQUEST_METHOD"), "GET")
    params = parse_query(query_string)
    cookies = parse_cookies(os.getenv("HTTP_COOKIE"))

    root = config.find_root()
    db_path = config.db_path(root)
    theme = config.load_theme(root)

    -- Auto-initialize or sync database schemas on request. Directory
    -- creation is naturally tied to "does this deployment look
    -- bootstrapped yet" (only needed once), but every schema/table init
    -- call below is idempotent (CREATE TABLE IF NOT EXISTS, INSERT OR
    -- IGNORE) and runs unconditionally every request instead, matching
    -- schema.sync_all's own already-established pattern just below --
    -- otherwise a store initialized before some built-in schema existed
    -- would never pick it up (a real, if latent, gap this closes for
    -- auth/document both, not just newly-added ones going forward).
    if not config.is_initialized(root) then
        paths.create_dir_if_not_exists(config.store_dir(root))
        paths.create_dir_if_not_exists(config.schemas_dir(root))
        paths.create_dir_if_not_exists(config.extensions_dir(root))
        paths.create_dir_if_not_exists(config.views_dir(root))
        paths.create_dir_if_not_exists(config.templates_dir(root))
        paths.create_dir_if_not_exists(config.dropdowns_dir(root))
    end
    ledger.init_schema(db_path)
    schema.init_schema(db_path)
    auth.init_schema(db_path)
    document.init_schema(db_path)
    knowledge.init_schema(db_path)
    agent.init_schema(db_path)
    secret_ok, secret_err = auth.ensure_session_secret(root)
    if secret_ok == nil then
        return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(secret_err) .. "</h3>")
    end
    schema.sync_all(db_path, root)

    nonce = auth.generate_nonce()

    -- No auth required -- browsers request the favicon (and page_shell
    -- requests the sidebar logo) on every page load, including /login,
    -- before any session exists. `name` is checked against a fixed
    -- allowlist, not used to build the path directly, so this can't be
    -- turned into a path-traversal read of arbitrary files on disk.
    if path_info == "/theme-asset" then
        allowed_names = {["favicon.png"] = true, ["logo.png"] = true, ["logo-full.png"] = true}
        if allowed_names[params.name] != true then
            return print_response("404 Not Found", "text/plain", "")
        end
        asset_path = paths.joinpath(config.theme_assets_dir(root), params.name)
        asset_file = io.open(asset_path, "rb")
        if asset_file == nil then
            return print_response("404 Not Found", "text/plain", "")
        end
        asset_bytes = io.read(asset_file, "*all")
        io.close(asset_file)
        return print_response("200 OK", "image/png", asset_bytes, {"Cache-Control: public, max-age=86400"})
    end

    -- Vendored third-party assets (e.g. the Toast UI Editor bundle) --
    -- allowlisted by exact name + content-type, same "never path-build
    -- from user input" reasoning as /theme-asset above, just a
    -- platform-owned vnd/ directory rather than a deployment's own
    -- DOCUMENT_ROOT-relative theme-assets/.
    if path_info == "/vendor" then
        allowed_vendor_assets = {
            ["toastui-editor-all.min.js"] = {path = "toastui/toastui-editor-all.min.js", content_type = "application/javascript"},
            ["toastui-editor.min.css"] = {path = "toastui/toastui-editor.min.css", content_type = "text/css"},
            ["BrowserPrint-3.0.216.min.js"] = {path = "browserprint/BrowserPrint-3.0.216.min.js", content_type = "application/javascript"},
        }
        asset = allowed_vendor_assets[params.name]
        if asset == nil then
            return print_response("404 Not Found", "text/plain", "")
        end
        asset_path = paths.joinpath(config.vendor_assets_dir(), asset.path)
        asset_file = io.open(asset_path, "rb")
        if asset_file == nil then
            return print_response("404 Not Found", "text/plain", "")
        end
        asset_bytes = io.read(asset_file, "*all")
        io.close(asset_file)
        return print_response("200 OK", asset.content_type, asset_bytes, {"Cache-Control: public, max-age=86400"})
    end

    if path_info == "/login" then
        return handle_login(root, db_path, method, nonce, theme)
    end

    -- API-key auth for external/programmatic clients, as an
    -- alternative to the session cookie below. A custom X-Api-Key
    -- header, not "Authorization: Bearer" -- Apache's mod_cgid (the
    -- real production front end, per doc/architecture.md) does NOT
    -- forward the Authorization header into a CGI script's environment
    -- unless the vhost explicitly sets "CGIPassAuth On" (it assumes
    -- Apache's own auth modules consume that header otherwise); any
    -- other header passes through as HTTP_* with no server config
    -- needed at all, so X-Api-Key avoids that deployment trap entirely.
    capabilities = nil
    author = nil
    via_api_key = false
    api_key_header = os.getenv("HTTP_X_API_KEY")
    if api_key_header != nil and api_key_header != "" then
        key_row = auth.verify_api_key(db_path, api_key_header)
        if key_row == nil then
            return print_response("401 Unauthorized", "application/json", json.encode({error = "Invalid API key"}))
        end
        capabilities = key_row.cap
        author = "api:" .. key_row.label
        via_api_key = true
    end

    -- Real session verification, replacing the old Phase 0
    -- AUTH_USER/AUTH_CAPABILITIES/AUTH_NONCE env-var stub. Capabilities
    -- are looked up fresh from the user table on every request rather
    -- than trusted from the cookie itself -- see auth.lua's own header
    -- comment for why.
    if not via_api_key then
        user = nil
        session_login = auth.verify_session_cookie(root, cookies.session)
        if session_login != nil then
            candidate = auth.get_user(db_path, session_login)
            if candidate != nil and (candidate.archived_at == nil or candidate.archived_at == "") then
                user = candidate
            end
        end

        if user == nil then
            return print_response("302 Found", "text/plain", "", {"Location: /login"})
        end

        capabilities = user.cap
        author = user.login
    end
    show_sql_nav = cgi.has_capability(capabilities, "s") or cgi.has_capability(capabilities, "a")
    show_admin_nav = cgi.has_capability(capabilities, "a")
    -- Nav-rail "Tasks" icon and Home's matching quick-link are only
    -- real links when this deployment actually seeded a
    -- "prioritized_tasks" view -- a fresh/generic install has no
    -- views/ at all, and would otherwise 404 on a raw internal path.
    has_tasks_view = view.load(config.views_dir(root), "prioritized_tasks") != nil

    if path_info == "/logout" then
        return print_response("302 Found", "text/plain", "", {
            "Location: /login",
            clear_cookie_header("session"),
            clear_cookie_header("csrf")
        })
    end

    if not cgi.has_capability(capabilities, REQUIRED_CAPABILITY) then
        if via_api_key then
            return print_response("403 Forbidden", "application/json", json.encode({error = "Insufficient capability"}))
        end
        return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires baseline capability</h3>")
    end

    -- Single account page (task: replace the nav's separate "Change
    -- password"/"Log out" links with one entry point, the username
    -- itself) -- hosts self-service password change (baseline "i"
    -- capability only, every logged-in account, not just Admin, always
    -- targeting the requesting session's own `author`, never a
    -- form-supplied login the way /admin-users-password's admin-only
    -- form does -- requires the current password to verify (auth.login's
    -- own bcrypt check) before setting a new one) and log out (a plain
    -- link to the existing /logout route, not handled here).
    if path_info == "/account" then
        if method == "POST" then
            form = parse_query(io.read("*all"))
            if not require_csrf(cookies, form.csrf_token) then
                body = html.render_account(author, default_value(cookies.csrf, ""), "CSRF check failed.", true)
                return print_response("403 Forbidden", "text/html",
                    html.page_shell("Account", "", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
            end
            if auth.login(db_path, author, default_value(form.current_password, "")) == nil then
                body = html.render_account(author, default_value(cookies.csrf, ""), "Current password is incorrect.", true)
                return print_response("200 OK", "text/html",
                    html.page_shell("Account", "", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
            end
            ok, err = auth.set_password(db_path, author, form.new_password)
            if ok == nil then
                body = html.render_account(author, default_value(cookies.csrf, ""), tostring(err), true)
                return print_response("200 OK", "text/html",
                    html.page_shell("Account", "", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
            end
            body = html.render_account(author, default_value(cookies.csrf, ""), "Password changed.", false)
            return print_response("200 OK", "text/html",
                html.page_shell("Account", "", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end
        body = html.render_account(author, default_value(cookies.csrf, ""), nil, false)
        return print_response("200 OK", "text/html",
            html.page_shell("Account", "", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/register" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        layout = filter_layout_columns(layout, params.columns)
        layout_json = json.encode(layout)

        locked_fields = collect_locked_fields(db_path, layout, params)
        body = html.render(entity_type, layout_json, nonce, locked_fields)
        page_context = {page_type = "entity_register", entity_type = entity_type, title = entity_type .. " · Register"}
        return print_response("200 OK", "text/html",
            html.page_shell(entity_type .. " · Register", "data", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    if path_info == "/browse" then
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        -- Optional generic filter, e.g.
        -- ?filter_field=mixture&filter_value=5 for "this mixture's
        -- ingredients" -- reuses /browse's own existing pagination
        -- rather than a bespoke list inside /detail. filter_field must
        -- name a real field on this type (same reasoning `columns` is
        -- checked against layout.fields in filter_layout_columns).
        filter_field = nil
        if params.filter_field != nil and params.filter_field != "" and params.filter_value != nil then
            for _, field in ipairs(layout.fields) do
                if field.name == params.filter_field then
                    filter_field = params.filter_field
                end
            end
        end

        page = tonumber(params.page)
        if page == nil or page < 1 then
            page = 1
        end
        offset = (page - 1) * BROWSE_PAGE_SIZE
        total = nil
        rows = nil
        if filter_field != nil then
            total = entity.count_by_field(db_path, entity_type, filter_field, params.filter_value)
            rows = entity.list_by_field(db_path, entity_type, filter_field, params.filter_value, BROWSE_PAGE_SIZE, offset)
        else
            total = entity.count(db_path, entity_type)
            rows = entity.list(db_path, entity_type, BROWSE_PAGE_SIZE, offset)
        end
        body = html.render_browse(db_path, entity_type, layout, rows, page, BROWSE_PAGE_SIZE, total, nonce, filter_field, params.filter_value)
        page_context = {page_type = "entity_browse", entity_type = entity_type, title = entity_type .. " · Browse"}
        return print_response("200 OK", "text/html",
            html.page_shell(entity_type .. " · Browse", "data", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    -- A simple, mostly-static landing page -- basic information and
    -- quick links, deliberately not an activity dashboard (working
    -- lists, a calendar, recent-entries feed) yet. Taking inspiration
    -- from Benchling's own Home concept without copying its actual
    -- design; this is a real v1 (a start), not the end state.
    if path_info == "/" or path_info == "" then
        body = html.render_home(theme, show_sql_nav, show_admin_nav, has_tasks_view)
        return print_response("200 OK", "text/html",
            html.page_shell(theme.site_name, "home", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- What "/" used to render, in full, before Home became its own
    -- separate landing page above -- the entity-type overview and the
    -- relation diagram. Used to also embed an ad hoc SQL widget here
    -- (Setup/Admin only); removed after a persistent styling problem
    -- that wasn't worth continuing to chase (real callers just use
    -- /sql directly, linked from /system).
    if path_info == "/data" then
        entity_types = schema.list(db_path)
        for _, row in ipairs(entity_types) do
            row.count = entity.count(db_path, row.name)
        end
        table.sort(entity_types, function(a, b)
            if a.count != b.count then
                return a.count > b.count
            end
            return a.name < b.name
        end)
        edges = schema.relationships(db_path)
        body = html.render_index(db_path, entity_types, edges, nonce)
        return print_response("200 OK", "text/html",
            html.page_shell("Data", "data", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- Landing page for admin/setup-only tooling (SQL console, user
    -- admin, templates) -- a single "System" destination rather than
    -- three separate top-level tabs, matching the old platform
    -- deployment's own "System" concept.
    if path_info == "/system" then
        if show_sql_nav == false and show_admin_nav == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        body = html.render_system(show_sql_nav, show_admin_nav)
        return print_response("200 OK", "text/html",
            html.page_shell("System", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/knowledge" then
        if show_sql_nav == false and show_admin_nav == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        stats = knowledge.stats(db_path)
        body = html.render_knowledge_pool(stats)
        return print_response("200 OK", "text/html",
            html.page_shell("Knowledge Pool", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- Backing view for /knowledge's stat cards -- reuses
    -- knowledge.list_documents (already existed for the CLI's `platform
    -- knowledge list`) rather than /browse: "document" has no
    -- schemas/document.lua file, and tier/retrieval_count/heat are
    -- migration-added columns, not part of DOCUMENT_SCHEMA.fields, so
    -- /browse's filter_field validation (must match a registered field)
    -- can never accept "tier" as a filter.
    if path_info == "/knowledge-documents" then
        if show_sql_nav == false and show_admin_nav == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        tier = tonumber(params.tier)
        rows = knowledge.list_documents(db_path, tier)
        body = html.render_knowledge_documents(rows, tier)
        return print_response("200 OK", "text/html",
            html.page_shell("Knowledge Pool", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- Backing view for /knowledge's "N reviewed notes" stat.
    if path_info == "/knowledge-reviewed" then
        if show_sql_nav == false and show_admin_nav == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        rows = knowledge.reviewed_documents(db_path)
        body = html.render_knowledge_documents(rows, nil, "Reviewed notes")
        return print_response("200 OK", "text/html",
            html.page_shell("Knowledge Pool", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- Backing view for /knowledge's "N retrieval runs" stat -- replaces
    -- the old inline "Recent Retrievals" preview panel (capped at 10)
    -- with a real full listing, same reasoning as /knowledge-documents:
    -- one obvious place to drill into the number, not a second,
    -- truncated copy on the landing page itself.
    if path_info == "/knowledge-retrievals" then
        if show_sql_nav == false and show_admin_nav == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        rows = knowledge.recent_retrievals(db_path, 500)
        body = html.render_knowledge_retrievals(rows)
        return print_response("200 OK", "text/html",
            html.page_shell("Knowledge Pool", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/detail" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' or 'entity_id' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        row = entity.get(db_path, entity_type, entity_id)
        if row == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such " .. html.html_escape(entity_type) .. " #" .. tostring(entity_id) .. "</h3>")
        end

        history = ledger.history(db_path, entity_id)
        has_label_template = label.has_template(db_path, entity_type)
        related = related_records(db_path, entity_type, entity_id)
        body = html.render_detail(db_path, entity_type, layout, row, history, nonce, has_label_template, related)
        page_context = {page_type = "entity_detail", entity_type = entity_type, entity_id = entity_id,
                         title = entity_type .. " #" .. tostring(entity_id)}
        return print_response("200 OK", "text/html",
            html.page_shell(entity_type .. " #" .. tostring(entity_id), "data", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    -- Single-row edit form for any entity type -- /register only ever
    -- creates. GET-only rendering here, same as /register: the write
    -- capability check happens at submit time via /api/update (below),
    -- not here, matching /register's own existing precedent of not
    -- gating the form's mere display.
    if path_info == "/entity-edit" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'type' or 'entity_id' parameter</h3>")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Invalid 'type' parameter</h3>")
        end

        layout, err = schema.layout(db_path, entity_type)
        if layout == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        layout_json = json.encode(layout)

        row = entity.get(db_path, entity_type, entity_id)
        if row == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such " .. html.html_escape(entity_type) .. " #" .. tostring(entity_id) .. "</h3>")
        end
        row_json = json.encode(row)

        body = html.render_entity_edit(entity_type, layout_json, row_json, entity_id, nonce)
        page_context = {page_type = "entity_edit", entity_type = entity_type, entity_id = entity_id,
                         title = "Edit " .. entity_type .. " #" .. tostring(entity_id)}
        return print_response("200 OK", "text/html",
            html.page_shell("Edit " .. entity_type .. " #" .. tostring(entity_id), "data", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    -- Same visibility as /detail (viewing/printing a label isn't a
    -- data mutation -- only creating/editing the template
    -- itself needs Admin, enforced on the label_template entity's own
    -- write routes above). Plain text, not HTML -- the client JS fetches
    -- this as a raw string and hands it straight to the printer, never
    -- renders it.
    if path_info == "/label" then
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "text/plain", "Missing 'type' or 'entity_id' parameter")
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "text/plain", "Invalid 'type' parameter")
        end

        zpl, err = label.render(db_path, entity_type, entity_id)
        if zpl == nil then
            return print_response("404 Not Found", "text/plain", tostring(err))
        end
        return print_response("200 OK", "text/plain", zpl)
    end

    if path_info == "/view" then
        view_name = params.view_name
        if view_name == nil or view_name == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'view_name' parameter</h3>")
        end

        views_dir = config.views_dir(root)
        view_def, err = view.load(views_dir, view_name)
        if view_def == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        if view.is_approved(db_path, view_def) == false then
            return print_response("403 Forbidden", "text/html", "<h3>Error: view '" .. html.html_escape(view_name) .. "' is not approved</h3>")
        end

        param_value = nil
        if view_def.param != nil then
            param_value = params[view_def.param.name]
        end

        rows, err = view.run(db_path, view_def, param_value)
        if rows == nil then
            return print_response("500 Internal Server Error", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end
        body = html.render_view(view_def, rows, param_value)
        page_context = {page_type = "view", view_name = view_name, title = view_name}
        -- The Tasks nav-rail icon links here with view_name=
        -- prioritized_tasks specifically (html.lua's own nav_items) --
        -- without this check every /view page, including this one,
        -- would highlight "Data" as the active rail icon regardless of
        -- which view is actually being shown.
        active_section = "data"
        if view_name == "prioritized_tasks" then
            active_section = "tasks"
        end
        return print_response("200 OK", "text/html",
            html.page_shell(view_name, active_section, body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    -- Documents (src/document.lua): a real parent_id tree, not a
    -- name-is-identity wiki page. `can_create`/`can_edit` are always
    -- true here -- the baseline "i" capability check above already
    -- gates every route in this file, and (matching /api/submit and
    -- /api/update, which also only require "i") creating/editing a
    -- document doesn't need anything beyond that today. Threaded
    -- through as an explicit parameter, not hardcoded in html.lua,
    -- so a future capability tier (e.g. a read-only viewer role) has
    -- somewhere to plug in without changing html.lua at all.
    if path_info == "/documents" then
        rows = document.all_active(db_path)
        body = html.render_document_tree(rows, true, nonce)
        return print_response("200 OK", "text/html",
            html.page_shell("Pages", "documents", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/document" then
        entity_id = tonumber(params.entity_id)
        if entity_id == nil then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'entity_id' parameter</h3>")
        end
        doc = entity.get(db_path, "document", entity_id)
        if doc == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: no such document #" .. tostring(entity_id) .. "</h3>")
        end
        rendered_html = document.render_html(db_path, doc.content)
        rendered_html = html.expand_inline_views(db_path, rendered_html)
        breadcrumbs = document.breadcrumbs(db_path, entity_id)
        children = document.children(db_path, entity_id)
        backlinks = document.backlinks(db_path, entity_id)
        body = html.render_document(doc, rendered_html, breadcrumbs, children, backlinks, true)
        page_context = {page_type = "document", entity_type = "document", entity_id = doc.id, title = doc.title}
        return print_response("200 OK", "text/html",
            html.page_shell(doc.title, "documents", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    if path_info == "/document-edit" then
        doc = nil
        entity_id = tonumber(params.entity_id)
        if entity_id != nil then
            doc = entity.get(db_path, "document", entity_id)
            if doc == nil then
                return print_response("404 Not Found", "text/html", "<h3>Error: no such document #" .. tostring(entity_id) .. "</h3>")
            end
        end

        -- task: "create new document from template" -- prefills a brand new
        -- (still unsaved) document's title/content from one of template.lua's
        -- reusable Entry templates, same rendered content the read-only
        -- /template page already shows, just landed in the real editor
        -- instead of a copy-paste-it-yourself textarea. Only applies to a
        -- genuinely new document (doc == nil) -- ?from_template on an existing
        -- document's edit URL would silently clobber real content otherwise.
        prefill = nil
        if doc == nil and params.from_template != nil and params.from_template != "" then
            templates_dir = config.templates_dir(root)
            template_def, template_err = template.load(templates_dir, params.from_template)
            if template_def == nil then
                return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(template_err) .. "</h3>")
            end
            default_path = template_def.default_path
            if default_path == nil then
                default_path = template_def.label
            end
            prefill = {title = default_path, content = template.render(template_def)}
        end

        parent_id = nil
        if doc != nil then
            parent_id = doc.parent_id
        end
        parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
        body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""), nil, nonce, prefill)
        page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
        return print_response("200 OK", "text/html",
            html.page_shell("Edit document", "documents", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    if path_info == "/document-save" and method == "POST" then
        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: CSRF check failed</h3>")
        end

        entity_id = tonumber(form.entity_id)
        parent_id = nil
        if form.parent_id != nil and form.parent_id != "" then
            parent_id = tonumber(form.parent_id)
        end

        if entity_id != nil and document.would_create_cycle(db_path, entity_id, parent_id) then
            doc = entity.get(db_path, "document", entity_id)
            parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""),
                "Can't move a document underneath its own sub-document.", nonce)
            page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
            return print_response("200 OK", "text/html",
                html.page_shell("Edit document", "documents", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
        end

        saved_id = nil
        issues = nil
        if entity_id != nil then
            saved_id, issues = document.update_page(db_path, author, entity_id, form.title, parent_id, form.content,
                source_from_params(params))
        else
            saved_id, issues = document.create_page(db_path, author, form.title, parent_id, form.content,
                source_from_params(params))
        end

        if saved_id == nil then
            doc = nil
            if entity_id != nil then
                doc = entity.get(db_path, "document", entity_id)
            end
            parent_options_html = html.document_parent_options(document.all_active(db_path), parent_id, entity_id)
            body = html.render_document_edit(doc, parent_options_html, default_value(cookies.csrf, ""),
                issues_to_message(issues), nonce)
            page_context = {page_type = "document_edit", entity_type = "document", entity_id = entity_id, title = "Edit document"}
            return print_response("200 OK", "text/html",
                html.page_shell("Edit document", "documents", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
        end

        return print_response("302 Found", "text/plain", "", {"Location: document?entity_id=" .. tostring(saved_id)})
    end

    if path_info == "/sql" then
        -- Setup or Admin only -- this runs arbitrary (SELECT-only)
        -- SQL an authenticated user typed themselves, so gating it
        -- behind the baseline "i" capability every other route uses
        -- would be far too permissive.
        if cgi.has_capability(capabilities, "s") == false and cgi.has_capability(capabilities, "a") == false then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end

        sql_text = params.q
        column_names = nil
        rows = nil
        sql_err = nil
        ref_columns = {}
        truncated = false
        if sql_text == nil then
            sql_text = "SELECT * FROM sample LIMIT 20;"
        elseif sql_text != "" then
            column_names, rows, sql_err, truncated = view.run_adhoc(db_path, sql_text)
            from_table = view.guess_from_table(sql_text)
            ref_columns = view.reference_columns(db_path, view.guess_tables(sql_text))
            if from_table != nil and schema.is_registered(db_path, from_table) then
                ref_columns["id"] = from_table
            end
        end
        body = html.render_sql(db_path, sql_text, column_names, rows, sql_err, ref_columns, nonce, params.embed == "1", theme, truncated)
        -- ?embed=1 is the home page's own SQL widget iframe (see
        -- render_index) -- it's already inside a page shell, so
        -- nesting a second full <html>/<nav> shell inside a 520px
        -- iframe would just show a broken, redundant page-within-a-
        -- page. Only skip the shell for that specific embed, not
        -- direct /sql visits, which still get the real nav.
        if params.embed == "1" then
            return print_response("200 OK", "text/html", body)
        end
        -- query_ran: true exactly when this page load itself came from
        -- running a query (?q= present) -- lets the chat widget's own
        -- syncSqlConsole (html.lua) tell "the user just ran this and is
        -- looking at its results" apart from "a fresh /sql visit, safe
        -- to prefill from the agent's last query" (see that function's
        -- own comment for the bug this fixes).
        return print_response("200 OK", "text/html",
            html.page_shell("SQL", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author,
                {page_type = "sql", title = "SQL", query_ran = (params.q != nil)}))
    end

    if path_info == "/admin-users" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        users = auth.list_users(db_path, true)
        body = html.render_admin_users(users, default_value(cookies.csrf, ""), nil, false)
        return print_response("200 OK", "text/html",
            html.page_shell("Users", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    -- Flat, single-segment names (not "/admin/users/create" etc) --
    -- deliberately, not just for consistency with every other route
    -- here: every relative link/form-action this app renders resolves
    -- against the CURRENT page's own directory, and this whole family
    -- of routes needs to link to each other and back to /admin-users.
    -- A flat namespace makes that trivial (every route is a sibling of
    -- every other); a nested one requires "../"-style relative math
    -- that's easy to get wrong -- exactly the bug class just fixed
    -- elsewhere in this file's own links.
    is_admin_user_action = path_info == "/admin-users-create" or
        path_info == "/admin-users-capabilities" or
        path_info == "/admin-users-password" or
        path_info == "/admin-users-archive" or
        path_info == "/admin-users-unarchive"
    if is_admin_user_action and method == "POST" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            users = auth.list_users(db_path, true)
            body = html.render_admin_users(users, default_value(cookies.csrf, ""), "CSRF check failed.", true)
            return print_response("403 Forbidden", "text/html",
                html.page_shell("Users", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end

        ok = nil
        err = nil

        if path_info == "/admin-users-create" then
            ok, err = auth.create_user(db_path, form.login, form.password, form.cap)
        elseif path_info == "/admin-users-capabilities" then
            ok, err = auth.set_capabilities(db_path, form.login, form.cap)
        elseif path_info == "/admin-users-password" then
            ok, err = auth.set_password(db_path, form.login, form.password)
        elseif path_info == "/admin-users-archive" then
            ok, err = auth.archive_user(db_path, form.login)
        elseif path_info == "/admin-users-unarchive" then
            ok, err = auth.unarchive_user(db_path, form.login)
        end

        if ok == nil then
            users = auth.list_users(db_path, true)
            body = html.render_admin_users(users, default_value(cookies.csrf, ""), tostring(err), true)
            return print_response("200 OK", "text/html",
                html.page_shell("Users", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end
        return print_response("302 Found", "text/plain", "", {"Location: admin-users"})
    end

    -- Admin UI for the api_key table, mirroring /admin-users above
    -- exactly, with one difference -- a successful create renders
    -- the list directly (not a redirect) so the one-time raw key can be
    -- shown; a redirect would lose it, since it's never stored anywhere
    -- to retrieve on a later request.
    if path_info == "/admin-api-keys" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        keys = auth.list_api_keys(db_path, true)
        body = html.render_admin_api_keys(keys, default_value(cookies.csrf, ""), nil, false, nil)
        return print_response("200 OK", "text/html",
            html.page_shell("API keys", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    is_admin_api_key_action = path_info == "/admin-api-keys-create" or
        path_info == "/admin-api-keys-capabilities" or
        path_info == "/admin-api-keys-archive" or
        path_info == "/admin-api-keys-unarchive"
    if is_admin_api_key_action and method == "POST" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        form = parse_query(io.read("*all"))
        if not require_csrf(cookies, form.csrf_token) then
            keys = auth.list_api_keys(db_path, true)
            body = html.render_admin_api_keys(keys, default_value(cookies.csrf, ""), "CSRF check failed.", true, nil)
            return print_response("403 Forbidden", "text/html",
                html.page_shell("API keys", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end

        if path_info == "/admin-api-keys-create" then
            raw_key, err = auth.create_api_key(db_path, form.label, form.cap)
            keys = auth.list_api_keys(db_path, true)
            if raw_key == nil then
                body = html.render_admin_api_keys(keys, default_value(cookies.csrf, ""), tostring(err), true, nil)
                return print_response("200 OK", "text/html",
                    html.page_shell("API keys", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
            end
            body = html.render_admin_api_keys(keys, default_value(cookies.csrf, ""), nil, false, raw_key)
            return print_response("200 OK", "text/html",
                html.page_shell("API keys", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end

        ok = nil
        err = nil

        if path_info == "/admin-api-keys-capabilities" then
            ok, err = auth.set_api_key_capabilities(db_path, form.label, form.cap)
        elseif path_info == "/admin-api-keys-archive" then
            ok, err = auth.archive_api_key(db_path, form.label)
        elseif path_info == "/admin-api-keys-unarchive" then
            ok, err = auth.unarchive_api_key(db_path, form.label)
        end

        if ok == nil then
            keys = auth.list_api_keys(db_path, true)
            body = html.render_admin_api_keys(keys, default_value(cookies.csrf, ""), tostring(err), true, nil)
            return print_response("200 OK", "text/html",
                html.page_shell("API keys", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end
        return print_response("302 Found", "text/plain", "", {"Location: admin-api-keys"})
    end

    if path_info == "/settings" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        body = html.render_settings(theme, default_value(cookies.csrf, ""), nil, false)
        return print_response("200 OK", "text/html",
            html.page_shell("Settings", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/settings-save" and method == "POST" then
        if not cgi.has_capability(capabilities, "a") then
            return print_response("403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        -- multipart, not parse_query -- the form's own enctype, needed
        -- for the logo/favicon file fields to arrive at all.
        raw_body = io.read("*all")
        form = multipart.parse(os.getenv("CONTENT_TYPE"), raw_body)

        if not require_csrf(cookies, form.csrf_token) then
            body = html.render_settings(theme, default_value(cookies.csrf, ""), "CSRF check failed.", true)
            return print_response("403 Forbidden", "text/html",
                html.page_shell("Settings", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end

        -- Colors get embedded straight into a <style> block by
        -- html.theme_root_css (not HTML-escaped -- it isn't HTML
        -- content), so this is the one place that has to actually
        -- validate them rather than trust an Admin-only form the way
        -- everything else here does: a value breaking out of <style>
        -- would be stored injection against every visitor, not just
        -- whoever filled in this form. Allowlist covers real CSS color
        -- syntax (#hex, rgb()/rgba()/hsl()/hsla(), named colors) and
        -- structurally excludes every HTML/CSS-breakout character.
        new_colors = {}
        color_error = nil
        for _, key in ipairs(THEME_COLOR_KEYS) do
            value = form["color_" .. key]
            if value != nil and value != "" then
                if string.match(value, "^[%w%s#%.,%%()-]+$") == nil then
                    color_error = "Invalid color value for '" .. key .. "' -- only letters, digits, and #.,%()- are allowed."
                end
                new_colors[key] = value
            end
        end

        -- Uploaded files are written under fixed destination names
        -- (logo.png/logo-full.png/favicon.png) -- never the
        -- client-supplied filename -- same "never path-build from user
        -- input" reasoning as /theme-asset's own allowlist. Checked
        -- against the real PNG magic bytes first, since accept=
        -- "image/png" on the <input> is only ever a client-side hint.
        upload_specs = {
            {field = "logo_file", filename = "logo.png", is_logo = true},
            {field = "logo_full_file", filename = "logo-full.png", is_logo = true},
            {field = "favicon_file", filename = "favicon.png", is_logo = false},
        }
        upload_error = nil
        for _, spec in ipairs(upload_specs) do
            uploaded = form[spec.field]
            if type(uploaded) == "table" and uploaded.data != nil and uploaded.data != "" then
                if string.sub(uploaded.data, 1, 8) != "\137PNG\r\n\026\n" then
                    upload_error = "'" .. spec.filename .. "' must be a real PNG file."
                end
            end
        end

        if color_error != nil or upload_error != nil then
            current = config.load_theme(root)
            body = html.render_settings(current, default_value(cookies.csrf, ""), default_value(color_error, upload_error), true)
            return print_response("200 OK", "text/html",
                html.page_shell("Settings", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end

        new_theme = config.load_theme(root)
        new_theme.site_name = default_value(form.site_name, "Platform")
        new_theme.hide_home_heading = (form.hide_home_heading == "1")
        new_theme.system_prompt_extra = nil
        if form.system_prompt_extra != nil and form.system_prompt_extra != "" then
            new_theme.system_prompt_extra = form.system_prompt_extra
        end
        new_theme.colors = new_colors

        for _, spec in ipairs(upload_specs) do
            uploaded = form[spec.field]
            if type(uploaded) == "table" and uploaded.data != nil and uploaded.data != "" then
                paths.create_dir_if_not_exists(config.theme_assets_dir(root))
                dest_file, dest_err = io.open(paths.joinpath(config.theme_assets_dir(root), spec.filename), "wb")
                if dest_file == nil then
                    body = html.render_settings(new_theme, default_value(cookies.csrf, ""), tostring(dest_err), true)
                    return print_response("500 Internal Server Error", "text/html",
                        html.page_shell("Settings", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
                end
                io.write(dest_file, uploaded.data)
                io.close(dest_file)
                if spec.is_logo then
                    new_theme.has_logo = true
                end
            end
        end

        ok, err = config.save_theme(root, new_theme)
        if ok == nil then
            body = html.render_settings(new_theme, default_value(cookies.csrf, ""), tostring(err), true)
            return print_response("500 Internal Server Error", "text/html",
                html.page_shell("Settings", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
        end
        return print_response("302 Found", "text/plain", "", {"Location: settings"})
    end

    -- Read-only chat-history browser (see doc/architecture.md's "Chat"
    -- section) -- /api/chat-widget-* below is the only way to mutate a
    -- chat session; this route only lists sessions and validates
    -- ownership of the one selected via ?session_id=, so the widget's
    -- own init script (html.lua) can be handed it via page_context.
    -- open_chat_session_id and pop open onto it. Never fetches messages/
    -- pending itself -- the page never displays a transcript, only the
    -- widget does (via its own /api/chat-widget-history).
    if path_info == "/chat" then
        session_id = params.session_id
        sessions = agent.list_sessions(db_path, author)
        current_session_id = nil
        if session_id != nil and session_id != "" then
            session = agent.get_session(db_path, session_id, author)
            if session == nil then
                return print_response("404 Not Found", "text/html", "<h3>Error: no such chat session</h3>")
            end
            current_session_id = session_id
        end
        body = html.render_chat(sessions, current_session_id, nonce)
        page_context = {page_type = "chat", open_chat_session_id = current_session_id}
        return print_response("200 OK", "text/html",
            html.page_shell("Chat", "chat", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author, page_context))
    end

    -- JSON counterparts of the old full-page chat routes, for the
    -- floating chat widget (html.page_shell) -- same underlying
    -- agent.* calls, fetch()-friendly responses instead
    -- of a 302 redirect back to a full page render. `chat_widget_state`
    -- (above) is the one place "here's the session now" gets built, so
    -- all four stay in sync with each other and with /chat itself.
    if path_info == "/api/chat-widget-start" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        new_session_id, create_err = agent.create_session(db_path, author, body_data.title)
        if new_session_id == nil then
            return print_response("500 Internal Server Error", "application/json", json.encode({error = tostring(create_err)}))
        end
        return print_response("200 OK", "application/json", json.encode(chat_widget_state(db_path, new_session_id)))
    end

    if path_info == "/api/chat-widget-send" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        session = agent.get_session(db_path, body_data.session_id, author)
        if session == nil then
            return print_response("404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        model = config.platform_config().agent_model
        agent.run_turn(db_path, body_data.session_id, author, nil, model, body_data.message)
        return print_response("200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id)))
    end

    if path_info == "/api/chat-widget-approve" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        model = config.platform_config().agent_model
        agent.approve_pending(db_path, tonumber(body_data.pending_id), author, nil, model)
        return print_response("200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id)))
    end

    -- The user-feedback half of knowledge_chat_eval. Ownership-
    -- checked the same way every other chat-widget route already is
    -- (agent.get_session requires session.login == author) -- without
    -- this, any authenticated user could record feedback against any
    -- message_id just by guessing/incrementing it.
    if path_info == "/api/chat-widget-feedback" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        message_id = tonumber(body_data.message_id)
        session_id = agent.message_session_id(db_path, message_id)
        if session_id == nil or agent.get_session(db_path, session_id, author) == nil then
            return print_response("404 Not Found", "application/json", json.encode({error = "no such message"}))
        end
        ok = knowledge.record_chat_feedback(db_path, message_id, body_data.feedback)
        return print_response("200 OK", "application/json", json.encode({ok = ok}))
    end

    if path_info == "/api/chat-widget-deny" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        model = config.platform_config().agent_model
        agent.deny_pending(db_path, tonumber(body_data.pending_id), author, nil, model)
        return print_response("200 OK", "application/json", json.encode(chat_widget_state(db_path, body_data.session_id)))
    end

    -- GET, not POST -- just reads back state, no CSRF needed (matches
    -- every other read-only /api/* route in this file). Used to
    -- rehydrate the floating widget's panel after a full page
    -- navigation, since its own session_id lives in localStorage
    -- (see html.page_shell's script), not anything server-rendered.
    if path_info == "/api/chat-widget-history" then
        session = agent.get_session(db_path, params.session_id, author)
        if session == nil then
            return print_response("404 Not Found", "application/json", json.encode({error = "no such chat session"}))
        end
        return print_response("200 OK", "application/json", json.encode(chat_widget_state(db_path, params.session_id)))
    end

    if path_info == "/templates" then
        templates_dir = config.templates_dir(root)
        body = html.render_templates_list(template.all(templates_dir))
        return print_response("200 OK", "text/html",
            html.page_shell("Templates", "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/template" then
        template_name = params.template_name
        if template_name == nil or template_name == "" then
            return print_response("400 Bad Request", "text/html", "<h3>Error: Missing 'template_name' parameter</h3>")
        end

        templates_dir = config.templates_dir(root)
        template_def, err = template.load(templates_dir, template_name)
        if template_def == nil then
            return print_response("404 Not Found", "text/html", "<h3>Error: " .. tostring(err) .. "</h3>")
        end

        rendered = template.render(template_def)
        body = html.render_template(template_def, rendered, nonce)
        return print_response("200 OK", "text/html",
            html.page_shell(template_name, "system", body, nonce, show_sql_nav, show_admin_nav, has_tasks_view, theme, author))
    end

    if path_info == "/api/autocomplete" then
        return handle_autocomplete(db_path, params)
    end

    -- /data's own entity search box (task: /documents already has a
    -- fuzzy title search, /data had nothing at all -- Ben's own explicit
    -- ask). Server-side, not a client-side index like documents' own --
    -- see entity.search_across_types' own header comment for why.
    if path_info == "/api/entity-search" then
        query_str = default_value(params.query, "")
        results = entity.search_across_types(db_path, query_str, 5, 20)
        return print_response("200 OK", "application/json", json.encode(results))
    end

    if path_info == "/api/preview" then
        return handle_preview(db_path, params)
    end

    if path_info == "/api/document-preview" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        input = io.read("*all")
        body_data, _, err = json.decode(input)
        if body_data == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        rendered = document.render_html(db_path, body_data.content)
        rendered = html.expand_inline_views(db_path, rendered)
        return print_response("200 OK", "application/json", json.encode({html = rendered}))
    end

    if path_info == "/api/validate" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end
        batch_issues = entity.validate_batch(db_path, entity_type, rows_values)
        return print_response("200 OK", "application/json", json.encode(batch_issues))
    end

    if path_info == "/api/submit" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        if entity_type == nil or entity_type == "" then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not require_write_capability(db_path, capabilities, entity_type) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        created_ids, batch_issues = entity.create_batch(db_path, entity_type, rows_values, author, source_from_params(params))
        response = {
            issues = batch_issues
        }
        if created_ids != nil then
            response.created_ids = created_ids
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/update" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not require_write_capability(db_path, capabilities, entity_type) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end
        input = io.read("*all")
        values, _, err = json.decode(input)
        if values == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
        end

        -- Optional -- a plain query/form param, not nested
        -- in the JSON body, so this doesn't change /api/update's own
        -- existing request-body contract (that body IS the values
        -- object directly, not a {values=..., reason=...} wrapper).
        updated_id, issues = entity.update(db_path, entity_type, entity_id, values, author, source_from_params(params), params.reason)
        response = {
            issues = issues
        }
        if updated_id != nil then
            response.updated_id = updated_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/archive" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not require_write_capability(db_path, capabilities, entity_type) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end

        archived_id, issues = entity.archive(db_path, entity_type, entity_id, author, source_from_params(params), params.reason)
        response = {issues = issues}
        if archived_id != nil then
            response.archived_id = archived_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    if path_info == "/api/unarchive" and method == "POST" then
        if not require_csrf(cookies) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        entity_type = params.type
        entity_id = tonumber(params.entity_id)
        if entity_type == nil or entity_type == "" or entity_id == nil then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Missing type or entity_id"}))
        end
        if not schema.valid_name_syntax(entity_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not require_write_capability(db_path, capabilities, entity_type) then
            return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
        end

        unarchived_id, issues = entity.unarchive(db_path, entity_type, entity_id, author, source_from_params(params))
        response = {issues = issues}
        if unarchived_id != nil then
            response.unarchived_id = unarchived_id
            response.success = true
        else
            response.success = false
        end
        return print_response("200 OK", "application/json", json.encode(response))
    end

    -- Versioned, external-facing API -- see doc/api.md for the full
    -- contract (response shapes, CSRF-skip reasoning for key-authed
    -- requests). Deliberately separate from the unversioned /api/*
    -- routes above, which are the browser UI's own internal contract,
    -- not meant for outside consumers.
    v1_type, v1_id, v1_action = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)/(%d+)/([a-z_]+)$")
    if v1_type == nil then
        v1_type, v1_id = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)/(%d+)$")
    end
    if v1_type == nil then
        v1_type = string.match(path_info, "^/api/v1/([a-z_][a-z0-9_]*)$")
    end

    if v1_type != nil then
        if not schema.valid_name_syntax(v1_type) then
            return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid type"}))
        end
        if not schema.is_registered(db_path, v1_type) then
            return print_response("404 Not Found", "application/json", json.encode({error = "Unknown type: " .. v1_type}))
        end

        v1_entity_id = tonumber(v1_id)
        v1_source = source_from_params(params)
        if via_api_key then
            v1_source = {api_key = author}
        end

        -- GET /api/v1/<type> -- list, optionally filtered (reuses
        -- entity.list_by_field/count_by_field as-is).
        if v1_id == nil and method == "GET" then
            layout = schema.layout(db_path, v1_type)
            v1_filter_field = nil
            if params.filter_field != nil and params.filter_field != "" and params.filter_value != nil and layout != nil then
                for _, field in ipairs(layout.fields) do
                    if field.name == params.filter_field then
                        v1_filter_field = params.filter_field
                    end
                end
            end
            v1_limit = tonumber(params.limit)
            if v1_limit == nil then
                v1_limit = BROWSE_PAGE_SIZE
            end
            v1_offset = tonumber(params.offset)
            if v1_offset == nil then
                v1_offset = 0
            end
            v1_total = nil
            v1_rows = nil
            if v1_filter_field != nil then
                v1_total = entity.count_by_field(db_path, v1_type, v1_filter_field, params.filter_value)
                v1_rows = entity.list_by_field(db_path, v1_type, v1_filter_field, params.filter_value, v1_limit, v1_offset)
            else
                v1_total = entity.count(db_path, v1_type)
                v1_rows = entity.list(db_path, v1_type, v1_limit, v1_offset)
            end
            return print_response("200 OK", "application/json", json.encode({rows = v1_rows, total = v1_total}))
        end

        -- POST /api/v1/<type> -- create. A JSON array body creates a
        -- batch (entity.create_batch, matching /api/submit's own
        -- convention); a single JSON object creates one row -- the
        -- natural shape for an external client posting to a collection.
        if v1_id == nil and method == "POST" then
            if not via_api_key and not require_csrf(cookies) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
            end
            if not require_write_capability(db_path, capabilities, v1_type) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
            end
            input = io.read("*all")
            decoded, _, err = json.decode(input)
            if decoded == nil then
                return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
            end

            if decoded[1] != nil then
                created_ids, batch_issues = entity.create_batch(db_path, v1_type, decoded, author, v1_source)
                response = {issues = batch_issues}
                if created_ids != nil then
                    response.created_ids = created_ids
                    response.success = true
                else
                    response.success = false
                end
                return print_response("200 OK", "application/json", json.encode(response))
            end

            created_id, issues = entity.create(db_path, v1_type, decoded, author, v1_source)
            response = {issues = issues}
            if created_id != nil then
                response.created_id = created_id
                response.success = true
            else
                response.success = false
            end
            return print_response("200 OK", "application/json", json.encode(response))
        end

        -- GET /api/v1/<type>/<id> -- get one
        if v1_entity_id != nil and v1_action == nil and method == "GET" then
            row = entity.get(db_path, v1_type, v1_entity_id)
            if row == nil then
                return print_response("404 Not Found", "application/json", json.encode({error = "Not found"}))
            end
            return print_response("200 OK", "application/json", json.encode({row = row}))
        end

        -- PATCH /api/v1/<type>/<id> -- update
        if v1_entity_id != nil and v1_action == nil and method == "PATCH" then
            if not via_api_key and not require_csrf(cookies) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
            end
            if not require_write_capability(db_path, capabilities, v1_type) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
            end
            input = io.read("*all")
            values, _, err = json.decode(input)
            if values == nil then
                return print_response("400 Bad Request", "application/json", json.encode({error = "Invalid JSON: " .. tostring(err)}))
            end
            updated_id, issues = entity.update(db_path, v1_type, v1_entity_id, values, author, v1_source, params.reason)
            response = {issues = issues}
            if updated_id != nil then
                response.updated_id = updated_id
                response.success = true
            else
                response.success = false
            end
            return print_response("200 OK", "application/json", json.encode(response))
        end

        -- POST /api/v1/<type>/<id>/archive
        if v1_entity_id != nil and v1_action == "archive" and method == "POST" then
            if not via_api_key and not require_csrf(cookies) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
            end
            if not require_write_capability(db_path, capabilities, v1_type) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
            end
            archived_id, issues = entity.archive(db_path, v1_type, v1_entity_id, author, v1_source, params.reason)
            response = {issues = issues}
            if archived_id != nil then
                response.archived_id = archived_id
                response.success = true
            else
                response.success = false
            end
            return print_response("200 OK", "application/json", json.encode(response))
        end

        -- POST /api/v1/<type>/<id>/unarchive
        if v1_entity_id != nil and v1_action == "unarchive" and method == "POST" then
            if not via_api_key and not require_csrf(cookies) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
            end
            if not require_write_capability(db_path, capabilities, v1_type) then
                return print_response("403 Forbidden", "application/json", json.encode({error = "Admin capability required to write this entity type"}))
            end
            unarchived_id, issues = entity.unarchive(db_path, v1_type, v1_entity_id, author, v1_source)
            response = {issues = issues}
            if unarchived_id != nil then
                response.unarchived_id = unarchived_id
                response.success = true
            else
                response.success = false
            end
            return print_response("200 OK", "application/json", json.encode(response))
        end

        return print_response("405 Method Not Allowed", "application/json", json.encode({error = "Method not allowed"}))
    end

    return print_response("404 Not Found", "text/plain", "Not Found")
end

return cgi
