-- Shared request context, security headers, page shell wrapper, and
-- generic helpers for web route modules (`src/web/*.lua`).
--
-- Replaces module-global response_nonce / response_csrf_header with an
-- explicit per-request `req` table so concurrent or persistent-worker
-- requests never share mutable state.

const cgi_lib = require("cgi")
const auth = require("auth")
const json = require("dkjson")
const lfs = require("lfs")
const schema = require("schema")
const entity = require("entity")
const ui = require("ui")

const web_ctx = {}

const REQUIRED_CAPABILITY = "i"
const BROWSE_PAGE_SIZE = 100
const RELATED_RECORDS_PREVIEW_LIMIT = 10
const DOCUMENT_OWN_REFERENCING_TYPES = {document = true, document_tag = true}

web_ctx.REQUIRED_CAPABILITY = REQUIRED_CAPABILITY
web_ctx.BROWSE_PAGE_SIZE = BROWSE_PAGE_SIZE
web_ctx.parse_query = cgi_lib.parse_query
web_ctx.parse_cookies = cgi_lib.parse_cookies
web_ctx.set_cookie_header = cgi_lib.set_cookie_header
web_ctx.clear_cookie_header = cgi_lib.clear_cookie_header

function web_ctx.has_capability(capabilities, letter)
    if capabilities == nil or capabilities == "" then
        return false
    end
    return string.find(capabilities, letter, 1, true) != nil
end

function web_ctx.default_value(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

function web_ctx.issues_to_message(issues)
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

function web_ctx.filter_layout_columns(layout, columns_param)
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

function web_ctx.collect_locked_fields(db_path, layout, params)
    locked = {}
    for key, value in pairs(params) do
        if string.sub(key, 1, 5) == "lock_" then
            field_name = string.sub(key, 6)
            for _, field in ipairs(layout.fields) do
                if field.name == field_name and field.type != "multi_select" and field.type != "multi_reference" then
                    display_label = value
                    if field.type == "reference" and field.ref_entity_type != nil then
                        resolved = ui.entity_display_label(db_path, field.ref_entity_type, tonumber(value))
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

function web_ctx.related_records(db_path, entity_type, entity_id)
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

function web_ctx.document_related_records(db_path, document_id)
    result = {}
    for _, group in ipairs(web_ctx.related_records(db_path, "document", document_id)) do
        if DOCUMENT_OWN_REFERENCING_TYPES[group.from_type] == nil then
            table.insert(result, group)
        end
    end
    return result
end

function web_ctx.source_from_params(params)
    source = {}
    if params.entry != nil and params.entry != "" then
        source.notebook_entry_id = params.entry
    end
    return source
end

function security_header_lines(nonce)
    script_src = "'self'"
    if nonce != nil then
        script_src = script_src .. " 'nonce-" .. nonce .. "'"
    end
    csp = table.concat({
        "default-src 'self'",
        "script-src " .. script_src,
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob: https:",
        "font-src 'self' data:",
        "connect-src 'self' http://127.0.0.1:9100 https://127.0.0.1:9101",
        "frame-src 'self'",
        "frame-ancestors 'self'",
        "form-action 'self'",
        "base-uri 'self'",
        "object-src 'none'",
    }, "; ")
    lines = {
        "Content-Security-Policy: " .. csp,
        "X-Frame-Options: SAMEORIGIN",
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: same-origin",
    }
    if cgi_lib.is_https() then
        table.insert(lines, "Strict-Transport-Security: max-age=31536000")
    end
    return lines
end

function header_name(header_line)
    name = string.match(header_line, "^([^:]+):")
    if name == nil then
        return ""
    end
    return string.lower(name)
end

-- Sends a CGI response using `req`'s nonce and pending CSRF Set-Cookie
-- header, returning `true` so route dispatchers can `return web_ctx.respond(...)`.
function web_ctx.respond(req, status, content_type, body, extra_headers)
    headers = {}
    overridden = {}
    if extra_headers != nil then
        for _, header_line in ipairs(extra_headers) do
            overridden[header_name(header_line)] = true
        end
    end
    for _, header_line in ipairs(security_header_lines(req.nonce)) do
        if overridden[header_name(header_line)] != true then
            table.insert(headers, header_line)
        end
    end
    if extra_headers != nil then
        for _, header_line in ipairs(extra_headers) do
            table.insert(headers, header_line)
        end
    end
    if req.csrf_header != nil then
        table.insert(headers, req.csrf_header)
    end
    cgi_lib.respond({
        status = status,
        content_type = content_type,
        headers = headers,
        body = body,
    })
    return true
end

function web_ctx.error_html(req, status, message)
    return web_ctx.respond(req, status, "text/html", "<h3>Error: " .. ui.html_escape(tostring(message)) .. "</h3>")
end

-- Wraps `body_html` in `ui.page_shell` using `req`'s authenticated nav state.
function web_ctx.render_page(req, title, active_section, body_html, page_context, status, extra_headers)
    if status == nil then
        status = "200 OK"
    end
    full_html = ui.page_shell(
        title, active_section, body_html, req.nonce,
        req.show_sql_nav, req.show_admin_nav, req.has_tasks_view,
        req.nav_extensions, req.theme, req.author, page_context
    )
    return web_ctx.respond(req, status, "text/html", full_html, extra_headers)
end

-- Wraps unauthenticated public pages (/login, /forgot-password, etc.).
function web_ctx.render_public_page(req, title, body_html, has_tasks_view, status, extra_headers)
    if status == nil then
        status = "200 OK"
    end
    full_html = ui.page_shell(
        title, "login", body_html, req.nonce,
        false, false, has_tasks_view, nil, req.theme, nil
    )
    return web_ctx.respond(req, status, "text/html", full_html, extra_headers)
end

function web_ctx.fresh_session_cookie_headers(root, db_path, login)
    session_cookie = auth.issue_session_cookie(root, db_path, login)
    if session_cookie == nil then
        return nil
    end
    return {cgi_lib.set_cookie_header("session", session_cookie, auth.SESSION_TTL_SECONDS, true)}
end

function web_ctx.require_csrf(req, form_token)
    submitted = os.getenv("HTTP_X_CSRF_TOKEN")
    if submitted == nil or submitted == "" then
        submitted = form_token
    end
    return auth.verify_csrf(req.cookies.csrf, submitted)
end

function web_ctx.require_write_capability(req, entity_type)
    if schema.admin_write_only(req.db_path, entity_type) == false then
        return true
    end
    return web_ctx.has_capability(req.capabilities, "a")
end

function web_ctx.as_json_array(list)
    if list == nil or #list == 0 then
        return setmetatable({}, {__jsontype = "array"})
    end
    return list
end

function web_ctx.percent_decode(str)
    if str == nil then
        return ""
    end
    return (string.gsub(str, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

function web_ctx.respond_json(req, status, payload, extra_headers)
    return web_ctx.respond(req, status, "application/json", json.encode(payload), extra_headers)
end

function web_ctx.method_not_allowed(req)
    return web_ctx.respond_json(req, "405 Method Not Allowed", {error = "Method not allowed"})
end

function web_ctx.require_write_auth(req, form_token)
    if req.via_api_key == true then
        return true
    end
    if web_ctx.require_csrf(req, form_token) then
        return true
    end
    web_ctx.respond_json(req, "403 Forbidden", {error = "CSRF check failed"})
    return false
end

function web_ctx.require_admin_json(req)
    if web_ctx.has_capability(req.capabilities, "a") then
        return true
    end
    web_ctx.respond_json(req, "403 Forbidden", {error = "Admin capability required"})
    return false
end

function web_ctx.read_body()
    content_len = tonumber(os.getenv("CONTENT_LENGTH"))
    if content_len != nil then
        if content_len <= 0 then
            return ""
        end
        return web_ctx.default_value(io.read(content_len), "")
    end
    stdin_mode = lfs.attributes("/proc/self/fd/0", "mode")
    if stdin_mode == "char device" then
        return ""
    end
    return web_ctx.default_value(io.read("*all"), "")
end

function web_ctx.read_json_body(req, allow_empty)
    raw = web_ctx.read_body()
    if (raw == nil or raw == "") and allow_empty == true then
        return {}, true
    end
    decoded, _, err = json.decode(raw)
    if decoded == nil or type(decoded) != "table" then
        msg = tostring(err)
        if decoded != nil then
            msg = "expected JSON object or array"
        end
        web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid JSON: " .. msg})
        return nil, false
    end
    return decoded, true
end

function web_ctx.read_write_json(req, allow_empty)
    raw = web_ctx.read_body()
    if not web_ctx.require_write_auth(req) then
        return nil, false
    end
    if (raw == nil or raw == "") and allow_empty == true then
        return {}, true
    end
    decoded, _, err = json.decode(raw)
    if decoded == nil or type(decoded) != "table" then
        msg = tostring(err)
        if decoded != nil then
            msg = "expected JSON object or array"
        end
        web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid JSON: " .. msg})
        return nil, false
    end
    return decoded, true
end

function web_ctx.request_source(req)
    if req.via_api_key == true then
        return {api_key = req.author}
    end
    return web_ctx.source_from_params(req.params)
end

return web_ctx
