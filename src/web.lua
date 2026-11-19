-- HTTP/CGI front controller: builds a self-contained request context
-- (`req`), ensures built-in and deployment schemas, enforces session or
-- API-key authentication, and dispatches across `src/web/*_routes.lua`.

const db = require("database")
const config = require("config")
const schema = require("schema")
const entity = require("entity")
const ledger = require("ledger")
const view = require("view")
const ui = require("ui")
const json = require("dkjson")
const paths = require("paths")
const lfs = require("lfs")
const store = require("store")
const auth = require("auth")
const document = require("document")
const knowledge = require("knowledge")
const agent = require("agent")
const extension = require("extension")

const web_ctx = require("web.context")
const auth_routes = require("web.auth_routes")
const entity_routes = require("web.entity_routes")
const knowledge_routes = require("web.knowledge_routes")
const admin_routes = require("web.admin_routes")
const chat_routes = require("web.chat_routes")
const api_v1_routes = require("web.api_v1_routes")

const web = {}
web.has_capability = web_ctx.has_capability

const ROUTE_MODULES = {
    auth_routes,
    entity_routes,
    knowledge_routes,
    admin_routes,
    chat_routes,
    api_v1_routes,
}

function builtin_schema_signature()
    parts = {"v=" .. tostring(store.latest_schema_version())}
    exe_attr = lfs.attributes("/proc/self/exe")
    if exe_attr != nil then
        table.insert(parts, "exe=" .. tostring(exe_attr.modification) .. ":" .. tostring(exe_attr.size) .. ":" .. tostring(exe_attr.ino))
    end
    if debug != nil and type(debug.getinfo) == "function" then
        info = debug.getinfo(builtin_schema_signature, "S")
        if info != nil and type(info.source) == "string" and string.sub(info.source, 1, 1) == "@" then
            src_file_path = string.sub(info.source, 2)
            src_dir = paths.dirname(src_file_path)
            dir_attr = lfs.attributes(src_dir)
            if dir_attr != nil and dir_attr.mode == "directory" then
                src_files = {}
                for f in lfs.dir(src_dir) do
                    if string.match(f, "%.lua$") != nil then
                        table.insert(src_files, f)
                    end
                end
                table.sort(src_files)
                for _, f in ipairs(src_files) do
                    fa = lfs.attributes(paths.joinpath(src_dir, f))
                    if fa != nil then
                        table.insert(parts, f .. ":" .. tostring(fa.modification) .. ":" .. tostring(fa.size))
                    end
                end
            end
        end
    end
    return table.concat(parts, "|")
end

function builtin_schemas_up_to_date(db_path, expected_sig)
    ok_sig, stored_sig = pcall(store.get_text, db_path, "web.builtin_schema_signature")
    if ok_sig == true and stored_sig == expected_sig then
        ok_probe, _ = pcall(db.query, db_path, "SELECT link_hash FROM document_link LIMIT 0;")
        if ok_probe == true then
            return true
        end
    end
    return false
end

function ensure_builtin_schemas(db_path)
    expected_sig = builtin_schema_signature()
    if builtin_schemas_up_to_date(db_path, expected_sig) then
        return
    end
    function run_locked_builtin_schemas()
        if builtin_schemas_up_to_date(db_path, expected_sig) then
            return
        end
        store.ensure_system_tables(db_path)
        ledger.init_schema(db_path)
        schema.init_schema(db_path)
        auth.init_schema(db_path)
        document.init_schema(db_path)
        knowledge.init_schema(db_path)
        agent.init_schema(db_path)
        store.set_text(db_path, "web.builtin_schema_signature", expected_sig)
    end
    db.with_lock(db_path, "daat_builtin_schema", 120, run_locked_builtin_schemas)
end

function handle_static_asset(req)
    if req.path_info == "/theme-asset" then
        allowed_names = {["favicon.png"] = true, ["logo.png"] = true, ["logo-full.png"] = true}
        if allowed_names[req.params.name] != true then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "")
        end
        asset_path = paths.joinpath(config.theme_assets_dir(req.root), req.params.name)
        asset_file = io.open(asset_path, "rb")
        if asset_file == nil then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "")
        end
        asset_bytes = io.read(asset_file, "*all")
        io.close(asset_file)
        return web_ctx.respond(req, "200 OK", "image/png", asset_bytes, {"Cache-Control: public, max-age=86400"})
    end

    if req.path_info == "/vendor" then
        allowed_vendor_assets = {
            ["toastui-editor-all.min.js"] = {path = "toastui/toastui-editor-all.min.js", content_type = "application/javascript"},
            ["toastui-editor.min.css"] = {path = "toastui/toastui-editor.min.css", content_type = "text/css"},
            ["BrowserPrint-3.0.216.min.js"] = {path = "browserprint/BrowserPrint-3.0.216.min.js", content_type = "application/javascript"},
        }
        asset_spec = allowed_vendor_assets[req.params.name]
        if asset_spec == nil then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "")
        end
        asset_path = paths.joinpath(config.vendor_assets_dir(), asset_spec.path)
        asset_file = io.open(asset_path, "rb")
        if asset_file == nil then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "")
        end
        asset_bytes = io.read(asset_file, "*all")
        io.close(asset_file)
        return web_ctx.respond(req, "200 OK", asset_spec.content_type, asset_bytes, {"Cache-Control: public, max-age=86400"})
    end

    return false
end

function handle_extension_ui(req)
    if string.sub(req.path_info, 1, 5) != "/ext/" then
        return false
    end

    ext_name = string.match(req.path_info, "^/ext/([^/]+)$")
    is_action_path = false
    if ext_name == nil then
        ext_name = string.match(req.path_info, "^/ext/([^/]+)/action$")
        is_action_path = true
    end
    if ext_name == nil then
        return web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
    end

    ext_dir = config.extensions_dir(req.root)
    manifest, _ = extension.load_manifest(ext_dir, ext_name)
    plugin_ok = manifest != nil and manifest.capabilities != nil
        and manifest.capabilities.ui != nil and extension.is_approved(req.db_path, manifest)
    if plugin_ok == false then
        return web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
    end

    if is_action_path == false and req.method == "GET" then
        page_context = {page_type = "extension", title = manifest.capabilities.ui.label}
        hooks, _ = extension.load_hooks(ext_dir, ext_name, manifest)
        if hooks == nil or type(hooks.render) != "function" then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
        end
        ctx = entity.build_ctx(req.db_path, manifest)
        render_ok, render_result = extension.call_bounded(hooks.render, ctx, req.params)
        elements = nil
        if render_ok == true and type(render_result) == "table" then
            elements = render_result.elements
        end
        if elements == nil then
            elements = {}
        end
        validate_err = ui.validate_canvas(elements)
        if render_ok == false or validate_err != nil then
            error_message = validate_err
            if render_ok == false then
                error_message = tostring(render_result)
            end
            body = "<div class=\"fossil-doc\"><div class=\"platform-error-banner\">Plugin error: " ..
                ui.html_escape(error_message) .. "</div></div>"
            return web_ctx.render_page(req, manifest.capabilities.ui.label, "ext:" .. ext_name, body,
                page_context, "500 Internal Server Error")
        end
        body = ui.render_plugin_page(manifest.capabilities.ui.label, elements, req.nonce)
        return web_ctx.render_page(req, manifest.capabilities.ui.label, "ext:" .. ext_name, body, page_context)
    end

    if is_action_path == true and req.method == "POST" then
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end
        body_data, _, _ = json.decode(io.read("*all"))
        if body_data == nil or type(body_data.action) != "string" then
            return web_ctx.respond(req, "400 Bad Request", "application/json", json.encode({error = "Invalid request"}))
        end
        hooks, _ = extension.load_hooks(ext_dir, ext_name, manifest)
        action_fn = nil
        if hooks != nil and type(hooks.actions) == "table" then
            action_fn = hooks.actions[body_data.action]
        end
        if type(action_fn) != "function" then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "unknown action"}))
        end
        action_args = body_data.args
        if action_args == nil then
            action_args = {}
        end
        ctx = entity.build_ctx(req.db_path, manifest)
        action_ok, action_result = extension.call_bounded(action_fn, ctx, action_args)
        if action_ok == false then
            return web_ctx.respond(req, "500 Internal Server Error", "application/json", json.encode({error = tostring(action_result)}))
        end
        elements = nil
        if type(action_result) == "table" then
            elements = action_result.elements
        end
        if elements == nil then
            elements = {}
        end
        validate_err = ui.validate_canvas(elements)
        if validate_err != nil then
            return web_ctx.respond(req, "500 Internal Server Error", "application/json", json.encode({error = "invalid canvas: " .. validate_err}))
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({html = ui.render_canvas(elements)}))
    end

    return web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
end

function web.handle_request()
    path_info = web_ctx.default_value(os.getenv("PATH_INFO"), "/register")
    query_string = web_ctx.default_value(os.getenv("QUERY_STRING"), "")
    method = web_ctx.default_value(os.getenv("REQUEST_METHOD"), "GET")
    root = config.find_root()

    req = {
        root = root,
        db_path = nil,
        path_info = path_info,
        method = method,
        params = web_ctx.parse_query(query_string),
        cookies = web_ctx.parse_cookies(os.getenv("HTTP_COOKIE")),
        nonce = auth.generate_nonce(),
        csrf_header = nil,
        theme = nil,
        capabilities = nil,
        author = nil,
        via_api_key = false,
        show_sql_nav = false,
        show_admin_nav = false,
        has_tasks_view = false,
        nav_extensions = nil,
    }

    if handle_static_asset(req) then
        return
    end

    req.db_path = config.db_path(root)
    req.theme = config.load_theme(root)

    was_initialized = config.is_initialized(root)
    if not was_initialized then
        paths.create_dir_if_not_exists(config.store_dir(root))
        paths.create_dir_if_not_exists(config.schemas_dir(root))
        paths.create_dir_if_not_exists(config.extensions_dir(root))
        paths.create_dir_if_not_exists(config.views_dir(root))
        paths.create_dir_if_not_exists(config.templates_dir(root))
        paths.create_dir_if_not_exists(config.dropdowns_dir(root))
    end
    store.migrate(req.db_path)
    if not was_initialized then
        store.set_text(req.db_path, "web.builtin_schema_signature", nil)
    end
    ensure_builtin_schemas(req.db_path)
    secret_ok, secret_err = auth.ensure_session_secret(root)
    if secret_ok == nil then
        web_ctx.error_html(req, "500 Internal Server Error", secret_err)
        return
    end
    schema.sync_all(req.db_path, root)

    if auth_routes.handle_public(req) then
        return
    end

    api_key_header = os.getenv("HTTP_X_API_KEY")
    if api_key_header != nil and api_key_header != "" then
        key_row = auth.verify_api_key(req.db_path, api_key_header)
        if key_row == nil then
            web_ctx.respond(req, "401 Unauthorized", "application/json", json.encode({error = "Invalid API key"}))
            return
        end
        req.capabilities = key_row.cap
        req.author = "api:" .. key_row.label
        req.via_api_key = true
    else
        user = auth.verify_session_cookie(root, req.db_path, req.cookies.session)
        if user == nil then
            web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: /login"})
            return
        end
        req.capabilities = user.cap
        req.author = user.login
    end

    if path_info == "/logout" then
        web_ctx.respond(req, "302 Found", "text/plain", "", {
            "Location: /login",
            web_ctx.clear_cookie_header("session"),
            web_ctx.clear_cookie_header("csrf"),
        })
        return
    end

    if not req.via_api_key and method == "GET" and (req.cookies.csrf == nil or req.cookies.csrf == "") then
        csrf_token = auth.generate_csrf_token()
        if csrf_token != nil then
            req.cookies.csrf = csrf_token
            req.csrf_header = web_ctx.set_cookie_header("csrf", csrf_token, auth.SESSION_TTL_SECONDS, false)
        end
    end

    if not web.has_capability(req.capabilities, web_ctx.REQUIRED_CAPABILITY) then
        if req.via_api_key then
            web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Insufficient capability"}))
        else
            web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires baseline capability</h3>")
        end
        return
    end

    req.show_sql_nav = web.has_capability(req.capabilities, "s") or web.has_capability(req.capabilities, "a")
    req.show_admin_nav = web.has_capability(req.capabilities, "a")
    req.has_tasks_view = view.load(req.db_path, "prioritized_tasks", root) != nil
    req.nav_extensions = extension.approved_with_ui(req.db_path, config.extensions_dir(root))

    if path_info == "/" or path_info == "" then
        body = ui.render_home(req.theme, req.show_sql_nav, req.show_admin_nav, req.has_tasks_view, req.nav_extensions)
        web_ctx.render_page(req, req.theme.site_name, "home", body)
        return
    end

    for _, route_mod in ipairs(ROUTE_MODULES) do
        if route_mod.handle(req) == true then
            return
        end
    end

    if handle_extension_ui(req) then
        return
    end

    web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
end

return web
