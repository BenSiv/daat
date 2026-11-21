-- System overview, user/API-key administration, theme settings,
-- extension canvas/triggers, and their /api/v1 counterparts
-- (/api/v1/extensions*, /api/v1/admin/*).

const config = require("config")
const paths = require("paths")
const auth = require("auth")
const entity = require("entity")
const extension = require("extension")
const mail_provider = require("mail_provider")
const multipart = require("multipart")
const schema = require("schema")
const status_lib = require("status")
const ui = require("ui")
const view = require("view")
const web_ctx = require("web.context")

const admin_routes = {}

const ALLOWED_THEME_ASSETS = {
    ["logo.png"] = {is_logo = true},
    ["logo-full.png"] = {is_logo = true},
    ["favicon.png"] = {is_logo = false},
}

function validate_theme_colors(colors_table)
    validated = {}
    if type(colors_table) != "table" then
        return validated, nil
    end
    allowed_key = {}
    for _, key in ipairs(config.THEME_COLOR_KEYS) do
        allowed_key[key] = true
    end
    for k, v in pairs(colors_table) do
        if allowed_key[k] != true then
            return nil, "Unknown color key '" .. tostring(k) .. "'."
        end
        if v != nil and tostring(v) != "" then
            val_str = tostring(v)
            if string.match(val_str, "^[%w%s#%.,%%()-]+$") == nil then
                return nil, "Invalid color value for '" .. k .. "' -- only letters, digits, and #.,%()- are allowed."
            end
            validated[k] = val_str
        end
    end
    return validated, nil
end

function write_png_theme_asset(root, filename, data_bytes)
    if data_bytes == nil or string.sub(data_bytes, 1, 8) != "\x89PNG\r\n\x1A\n" then
        return nil, "'" .. filename .. "' must be a real PNG file."
    end
    paths.create_dir_if_not_exists(config.theme_assets_dir(root))
    dest_file, dest_err = io.open(paths.joinpath(config.theme_assets_dir(root), filename), "wb")
    if dest_file == nil then
        return nil, tostring(dest_err)
    end
    io.write(dest_file, data_bytes)
    io.close(dest_file)
    return true, nil
end

function create_or_invite_user(root, db_path, site_name, login, password, email_in, cap)
    email = web_ctx.default_value(email_in, "")
    if config.password_reset_enabled() then
        return auth.invite_user(root, db_path, login, email, cap, site_name)
    end
    if email != "" and not mail_provider.valid_address(string.lower(email)) then
        return nil, "invalid email address: " .. email
    end
    if email != "" and auth.get_user_by_email(db_path, email) != nil then
        return nil, "email already used by another account"
    end
    ok, err = auth.create_user(db_path, login, password, cap)
    if ok != nil and email != "" then
        ok, err = auth.set_email(db_path, login, email)
    end
    return ok, err
end

function update_user_email_with_setup(root, db_path, site_name, login, email_in)
    email = web_ctx.default_value(email_in, "")
    ok, err = auth.set_email(db_path, login, email)
    email_user = auth.get_user(db_path, login)
    if ok != nil and config.password_reset_enabled() and email_user != nil
            and email_user.email != nil and email_user.email != "" and not auth.email_verified(email_user) then
        ok, err = auth.send_setup_link(root, db_path, login, site_name)
        if ok == nil then
            err = "email saved, but the setup link could not be sent: " .. tostring(err)
        end
    end
    return ok, err
end

function run_manual_trigger(root, db_path, author, trigger_ext_name, trigger_name)
    ext_dir = config.extensions_dir(root)
    manifest, _ = extension.load_manifest(ext_dir, trigger_ext_name)
    trigger_spec = nil
    if manifest != nil and manifest.capabilities != nil and manifest.capabilities.manual_triggers != nil then
        for _, candidate in ipairs(manifest.capabilities.manual_triggers) do
            if candidate.name == trigger_name then
                trigger_spec = candidate
            end
        end
    end
    if trigger_spec == nil or extension.is_approved(db_path, manifest) == false then
        return "404 Not Found", {error = "unknown trigger"}
    end

    hooks, _ = extension.load_hooks(ext_dir, trigger_ext_name, manifest)
    trigger_fn = nil
    if hooks != nil and type(hooks.manual_triggers) == "table" then
        trigger_fn = hooks.manual_triggers[trigger_name]
    end
    if type(trigger_fn) != "function" then
        return "404 Not Found", {error = "unknown trigger"}
    end

    ctx = entity.build_ctx(db_path, manifest)
    trigger_ok, trigger_result = extension.call_bounded(trigger_fn, ctx, {triggered_by = author})
    if trigger_ok == false then
        return "500 Internal Server Error", {error = tostring(trigger_result)}
    end
    message = "Triggered."
    if type(trigger_result) == "table" and type(trigger_result.message) == "string" then
        message = trigger_result.message
    end
    return "200 OK", {success = true, message = message}
end

function admin_routes.handle(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    root = req.root
    params = req.params
    author = req.author
    csrf_val = web_ctx.default_value(req.cookies.csrf, "")
    is_admin = web_ctx.has_capability(req.capabilities, "a")

    if path_info == "/system" then
        if req.show_sql_nav == false and req.show_admin_nav == false then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Setup or Admin capability</h3>")
        end
        body = ui.render_system(req.show_sql_nav, req.show_admin_nav)
        return web_ctx.render_page(req, "System", "system", body)
    end

    if path_info == "/system-status" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        rep = status_lib.collect(db_path, root)
        body = ui.render_system_status(rep, csrf_val, params.msg, false)
        return web_ctx.render_page(req, "Status & Approvals", "system", body)
    end

    is_status_action = path_info == "/system-status-schema-sync" or
        path_info == "/system-status-view-approve" or
        path_info == "/system-status-view-revoke" or
        path_info == "/system-status-extension-approve" or
        path_info == "/system-status-extension-revoke"
    if is_status_action and method == "POST" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        form = web_ctx.parse_query(web_ctx.read_body())
        if not web_ctx.require_csrf(req, form.csrf_token) then
            rep = status_lib.collect(db_path, root)
            body = ui.render_system_status(rep, csrf_val, "CSRF check failed.", true)
            return web_ctx.render_page(req, "Status & Approvals", "system", body, nil, "403 Forbidden")
        end

        action_err = nil
        if path_info == "/system-status-schema-sync" then
            _, sync_err = schema.sync_all(db_path, root)
            if sync_err != nil then
                action_err = tostring(sync_err)
            end
        elseif path_info == "/system-status-view-approve" then
            target_name = web_ctx.default_value(form.name, "")
            if not config.valid_resource_name(target_name) then
                action_err = "Invalid view name."
            else
                def, load_err = view.load(db_path, target_name, root)
                if def == nil then
                    action_err = tostring(load_err)
                else
                    view.approve(db_path, def, author)
                end
            end
        elseif path_info == "/system-status-view-revoke" then
            target_name = web_ctx.default_value(form.name, "")
            if not config.valid_resource_name(target_name) then
                action_err = "Invalid view name."
            else
                view.revoke(db_path, target_name)
            end
        elseif path_info == "/system-status-extension-approve" then
            target_name = web_ctx.default_value(form.name, "")
            if not config.valid_resource_name(target_name) then
                action_err = "Invalid extension name."
            else
                manifest, load_err = extension.load_manifest(config.extensions_dir(root), target_name)
                if manifest == nil then
                    action_err = tostring(load_err)
                else
                    extension.approve(db_path, manifest, author)
                end
            end
        elseif path_info == "/system-status-extension-revoke" then
            target_name = web_ctx.default_value(form.name, "")
            if not config.valid_resource_name(target_name) then
                action_err = "Invalid extension name."
            else
                extension.revoke(db_path, target_name)
            end
        end

        if action_err != nil then
            rep = status_lib.collect(db_path, root)
            body = ui.render_system_status(rep, csrf_val, action_err, true)
            return web_ctx.render_page(req, "Status & Approvals", "system", body)
        end
        return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: system-status"})
    end

    if path_info == "/admin-triggers" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        ext_dir = config.extensions_dir(root)
        body = ui.render_admin_triggers(extension.approved_with_manual_triggers(db_path, ext_dir), req.nonce)
        return web_ctx.render_page(req, "Manual Triggers", "system", body)
    end

    if path_info == "/admin-users" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        show_archived = params.archived == "1"
        users = auth.list_users(db_path, show_archived)
        body = ui.render_admin_users(users, config.password_reset_enabled(), csrf_val, nil, false, show_archived)
        return web_ctx.render_page(req, "Users", "system", body)
    end

    is_admin_user_action = path_info == "/admin-users-create" or
        path_info == "/admin-users-capabilities" or
        path_info == "/admin-users-password" or
        path_info == "/admin-users-email" or
        path_info == "/admin-users-archive" or
        path_info == "/admin-users-unarchive"
    if is_admin_user_action and method == "POST" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        form = web_ctx.parse_query(web_ctx.read_body())
        if not web_ctx.require_csrf(req, form.csrf_token) then
            users = auth.list_users(db_path, true)
            body = ui.render_admin_users(users, config.password_reset_enabled(), csrf_val, "CSRF check failed.", true, true)
            return web_ctx.render_page(req, "Users", "system", body, nil, "403 Forbidden")
        end

        ok = nil
        err = nil
        self_cookie_headers = nil

        if path_info == "/admin-users-create" then
            ok, err = create_or_invite_user(root, db_path, req.theme.site_name, form.login, form.password, form.email, form.cap)
        elseif path_info == "/admin-users-email" then
            ok, err = update_user_email_with_setup(root, db_path, req.theme.site_name, form.login, form.email)
        elseif path_info == "/admin-users-capabilities" then
            ok, err = auth.set_capabilities(db_path, form.login, form.cap)
        elseif path_info == "/admin-users-password" then
            ok, err = auth.set_password(db_path, form.login, form.password)
            if ok != nil and form.login == author then
                self_cookie_headers = web_ctx.fresh_session_cookie_headers(root, db_path, author)
            end
        elseif path_info == "/admin-users-archive" then
            ok, err = auth.archive_user(db_path, form.login)
        elseif path_info == "/admin-users-unarchive" then
            ok, err = auth.unarchive_user(db_path, form.login)
        end

        if ok == nil then
            users = auth.list_users(db_path, true)
            body = ui.render_admin_users(users, config.password_reset_enabled(), csrf_val, tostring(err), true, true)
            return web_ctx.render_page(req, "Users", "system", body)
        end
        redirect_headers = {"Location: admin-users"}
        if self_cookie_headers != nil then
            for _, header_line in ipairs(self_cookie_headers) do
                table.insert(redirect_headers, header_line)
            end
        end
        return web_ctx.respond(req, "302 Found", "text/plain", "", redirect_headers)
    end

    if path_info == "/admin-api-keys" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        keys = auth.list_api_keys(db_path, true)
        body = ui.render_admin_api_keys(keys, csrf_val, nil, false, nil)
        return web_ctx.render_page(req, "API keys", "system", body)
    end

    is_admin_api_key_action = path_info == "/admin-api-keys-create" or
        path_info == "/admin-api-keys-capabilities" or
        path_info == "/admin-api-keys-archive" or
        path_info == "/admin-api-keys-unarchive"
    if is_admin_api_key_action and method == "POST" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        form = web_ctx.parse_query(web_ctx.read_body())
        if not web_ctx.require_csrf(req, form.csrf_token) then
            keys = auth.list_api_keys(db_path, true)
            body = ui.render_admin_api_keys(keys, csrf_val, "CSRF check failed.", true, nil)
            return web_ctx.render_page(req, "API keys", "system", body, nil, "403 Forbidden")
        end

        if path_info == "/admin-api-keys-create" then
            raw_key, err = auth.create_api_key(db_path, form.label, form.cap)
            keys = auth.list_api_keys(db_path, true)
            if raw_key == nil then
                body = ui.render_admin_api_keys(keys, csrf_val, tostring(err), true, nil)
                return web_ctx.render_page(req, "API keys", "system", body)
            end
            body = ui.render_admin_api_keys(keys, csrf_val, nil, false, raw_key)
            return web_ctx.render_page(req, "API keys", "system", body)
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
            body = ui.render_admin_api_keys(keys, csrf_val, tostring(err), true, nil)
            return web_ctx.render_page(req, "API keys", "system", body)
        end
        return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: admin-api-keys"})
    end

    if path_info == "/settings" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end
        body = ui.render_settings(req.theme, csrf_val, nil, false)
        return web_ctx.render_page(req, "Settings", "system", body)
    end

    if path_info == "/settings-save" and method == "POST" then
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "text/html", "<h3>Forbidden: requires Admin capability</h3>")
        end

        raw_body = web_ctx.read_body()
        form = multipart.parse(os.getenv("CONTENT_TYPE"), raw_body)

        if not web_ctx.require_csrf(req, form.csrf_token) then
            body = ui.render_settings(req.theme, csrf_val, "CSRF check failed.", true)
            return web_ctx.render_page(req, "Settings", "system", body, nil, "403 Forbidden")
        end

        raw_colors = {}
        for _, key in ipairs(config.THEME_COLOR_KEYS) do
            raw_colors[key] = form["color_" .. key]
        end
        new_colors, color_error = validate_theme_colors(raw_colors)

        upload_specs = {
            {field = "logo_file", filename = "logo.png", is_logo = true},
            {field = "logo_full_file", filename = "logo-full.png", is_logo = true},
            {field = "favicon_file", filename = "favicon.png", is_logo = false},
        }
        upload_error = nil
        for _, spec in ipairs(upload_specs) do
            uploaded = form[spec.field]
            if type(uploaded) == "table" and uploaded.data != nil and uploaded.data != "" then
                if string.sub(uploaded.data, 1, 8) != "\x89PNG\r\n\x1A\n" then
                    upload_error = "'" .. spec.filename .. "' must be a real PNG file."
                end
            end
        end

        if color_error != nil or upload_error != nil then
            current = config.load_theme(root)
            body = ui.render_settings(current, csrf_val, web_ctx.default_value(color_error, upload_error), true)
            return web_ctx.render_page(req, "Settings", "system", body)
        end

        new_theme = config.load_theme(root)
        new_theme.site_name = web_ctx.default_value(form.site_name, "Daat")
        new_theme.hide_home_heading = (form.hide_home_heading == "1")
        new_theme.system_prompt_extra = nil
        if form.system_prompt_extra != nil and form.system_prompt_extra != "" then
            new_theme.system_prompt_extra = form.system_prompt_extra
        end
        new_theme.colors = new_colors

        for _, spec in ipairs(upload_specs) do
            uploaded = form[spec.field]
            if type(uploaded) == "table" and uploaded.data != nil and uploaded.data != "" then
                wrote, write_err = write_png_theme_asset(root, spec.filename, uploaded.data)
                if wrote == nil then
                    body = ui.render_settings(new_theme, csrf_val, write_err, true)
                    return web_ctx.render_page(req, "Settings", "system", body, nil, "500 Internal Server Error")
                end
                if spec.is_logo then
                    new_theme.has_logo = true
                end
            end
        end

        ok, err = config.save_theme(root, new_theme)
        if ok == nil then
            body = ui.render_settings(new_theme, csrf_val, tostring(err), true)
            return web_ctx.render_page(req, "Settings", "system", body, nil, "500 Internal Server Error")
        end
        return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: settings"})
    end

    return false
end

function handle_api_v1_extensions(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    root = req.root

    if path_info == "/api/v1/extensions" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        exts = extension.approved_with_ui(db_path, config.extensions_dir(root))
        return web_ctx.respond_json(req, "200 OK", {extensions = web_ctx.as_json_array(exts)})
    end

    ext_name_raw, ext_sub = string.match(path_info, "^/api/v1/extensions/([^/]+)/([a-z]+)$")
    if ext_name_raw == nil then
        ext_name_raw = string.match(path_info, "^/api/v1/extensions/([^/]+)$")
    end
    if ext_name_raw == nil then
        return false
    end
    ext_name = web_ctx.percent_decode(ext_name_raw)

    ext_dir = config.extensions_dir(root)
    manifest, _ = extension.load_manifest(ext_dir, ext_name)
    plugin_ok = manifest != nil and manifest.capabilities != nil
        and manifest.capabilities.ui != nil and extension.is_approved(db_path, manifest)

    if ext_sub == nil then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        if plugin_ok == false then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown extension"})
        end
        hooks, _ = extension.load_hooks(ext_dir, ext_name, manifest)
        if hooks == nil or type(hooks.render) != "function" then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown extension"})
        end
        ctx = entity.build_ctx(db_path, manifest)
        render_ok, render_result = extension.call_bounded(hooks.render, ctx, req.params)
        if render_ok == false then
            return web_ctx.respond_json(req, "500 Internal Server Error", {error = tostring(render_result)})
        end
        elements = nil
        if type(render_result) == "table" then
            elements = render_result.elements
        end
        if elements == nil then
            elements = {}
        end
        validate_err = ui.validate_canvas(elements)
        if validate_err != nil then
            return web_ctx.respond_json(req, "500 Internal Server Error", {error = "invalid canvas: " .. validate_err})
        end
        return web_ctx.respond_json(req, "200 OK", {
            name = ext_name,
            label = manifest.capabilities.ui.label,
            elements = web_ctx.as_json_array(elements),
            html = ui.render_canvas(elements),
        })
    end

    if ext_sub == "actions" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        if plugin_ok == false then
            return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown extension"})
        end
        if type(body_data.action) != "string" or body_data.action == "" then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid request"})
        end
        hooks, _ = extension.load_hooks(ext_dir, ext_name, manifest)
        action_fn = nil
        if hooks != nil and type(hooks.actions) == "table" then
            action_fn = hooks.actions[body_data.action]
        end
        if type(action_fn) != "function" then
            return web_ctx.respond_json(req, "404 Not Found", {error = "unknown action"})
        end
        action_args = body_data.args
        if action_args == nil then
            action_args = {}
        end
        ctx = entity.build_ctx(db_path, manifest)
        action_ok, action_result = extension.call_bounded(action_fn, ctx, action_args)
        if action_ok == false then
            return web_ctx.respond_json(req, "500 Internal Server Error", {error = tostring(action_result)})
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
            return web_ctx.respond_json(req, "500 Internal Server Error", {error = "invalid canvas: " .. validate_err})
        end
        return web_ctx.respond_json(req, "200 OK", {
            elements = web_ctx.as_json_array(elements),
            html = ui.render_canvas(elements),
        })
    end

    return false
end

function theme_settings_payload(theme)
    colors = theme.colors
    if colors == nil or next(colors) == nil then
        colors = setmetatable({}, {__jsontype = "object"})
    end
    return {
        site_name = theme.site_name,
        hide_home_heading = (theme.hide_home_heading == true),
        system_prompt_extra = theme.system_prompt_extra,
        colors = colors,
        has_logo = (theme.has_logo == true),
    }
end

function admin_routes.handle_api_v1(req)
    path_info = req.path_info
    method = req.method
    db_path = req.db_path
    root = req.root
    params = req.params
    author = req.author

    if path_info == "/api/v1/extensions" or string.sub(path_info, 1, 19) == "/api/v1/extensions/" then
        return handle_api_v1_extensions(req)
    end

    if string.sub(path_info, 1, 14) != "/api/v1/admin/" then
        return false
    end

    if not web_ctx.has_capability(req.capabilities, "a") then
        if method != "GET" and method != "HEAD" then
            web_ctx.read_body()
        end
        return web_ctx.require_admin_json(req)
    end

    if path_info == "/api/v1/admin/status" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        return web_ctx.respond_json(req, "200 OK", status_lib.collect(db_path, root))
    end

    if path_info == "/api/v1/admin/schemas/sync" then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        _, sync_err = schema.sync_all(db_path, root)
        if sync_err != nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(sync_err)})
        end
        return web_ctx.respond_json(req, "200 OK", {success = true})
    end

    view_target, view_act = string.match(path_info, "^/api/v1/admin/views/([^/]+)/([a-z]+)$")
    if view_target != nil and (view_act == "approve" or view_act == "revoke") then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        view_name = web_ctx.percent_decode(view_target)
        if not config.valid_resource_name(view_name) then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid view name."})
        end
        if view_act == "approve" then
            def, load_err = view.load(db_path, view_name, root)
            if def == nil then
                return web_ctx.respond_json(req, "404 Not Found", {error = tostring(load_err)})
            end
            view.approve(db_path, def, author)
        else
            view.revoke(db_path, view_name)
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, name = view_name})
    end

    ext_target, ext_act = string.match(path_info, "^/api/v1/admin/extensions/([^/]+)/([a-z]+)$")
    if ext_target != nil and (ext_act == "approve" or ext_act == "revoke") then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        ext_name = web_ctx.percent_decode(ext_target)
        if not config.valid_resource_name(ext_name) then
            return web_ctx.respond_json(req, "400 Bad Request", {error = "Invalid extension name."})
        end
        if ext_act == "approve" then
            manifest, load_err = extension.load_manifest(config.extensions_dir(root), ext_name)
            if manifest == nil then
                return web_ctx.respond_json(req, "404 Not Found", {error = tostring(load_err)})
            end
            extension.approve(db_path, manifest, author)
        else
            extension.revoke(db_path, ext_name)
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, name = ext_name})
    end

    if path_info == "/api/v1/admin/triggers" then
        if method != "GET" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        items = extension.approved_with_manual_triggers(db_path, config.extensions_dir(root))
        return web_ctx.respond_json(req, "200 OK", {extensions = web_ctx.as_json_array(items)})
    end

    trig_ext_raw, trig_name_raw = string.match(path_info, "^/api/v1/admin/triggers/([^/]+)/([^/]+)$")
    if trig_ext_raw != nil then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        status_str, payload = run_manual_trigger(root, db_path, author,
            web_ctx.percent_decode(trig_ext_raw), web_ctx.percent_decode(trig_name_raw))
        return web_ctx.respond_json(req, status_str, payload)
    end

    if path_info == "/api/v1/admin/users" then
        if method == "GET" then
            show_archived = (params.archived == "1")
            users = auth.list_users(db_path, show_archived)
            return web_ctx.respond_json(req, "200 OK", {users = web_ctx.as_json_array(users)})
        end
        if method == "POST" then
            body_data, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            ok, err = create_or_invite_user(root, db_path, req.theme.site_name,
                body_data.login, body_data.password, body_data.email, body_data.cap)
            if ok == nil then
                return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
            end
            return web_ctx.respond_json(req, "200 OK", {
                success = true,
                login = body_data.login,
                invited = config.password_reset_enabled(),
            })
        end
        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    user_login_raw, user_act = string.match(path_info, "^/api/v1/admin/users/([^/]+)/([a-z]+)$")
    if user_login_raw != nil and (user_act == "archive" or user_act == "unarchive") then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        target_login = web_ctx.percent_decode(user_login_raw)
        if auth.get_user(db_path, target_login) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such user: " .. target_login})
        end
        ok = nil
        err = nil
        if user_act == "archive" then
            ok, err = auth.archive_user(db_path, target_login)
        else
            ok, err = auth.unarchive_user(db_path, target_login)
        end
        if ok == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, login = target_login})
    end

    user_patch_raw = string.match(path_info, "^/api/v1/admin/users/([^/]+)$")
    if user_patch_raw != nil then
        if method != "PATCH" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        target_login = web_ctx.percent_decode(user_patch_raw)
        if auth.get_user(db_path, target_login) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such user: " .. target_login})
        end
        self_cookie_headers = nil
        if body_data.email != nil then
            ok, err = update_user_email_with_setup(root, db_path, req.theme.site_name, target_login, body_data.email)
            if ok == nil then
                return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
            end
        end
        if body_data.cap != nil then
            ok, err = auth.set_capabilities(db_path, target_login, body_data.cap)
            if ok == nil then
                return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
            end
        end
        if body_data.password != nil then
            ok, err = auth.set_password(db_path, target_login, body_data.password)
            if ok == nil then
                return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
            end
            if req.via_api_key == false and target_login == author then
                self_cookie_headers = web_ctx.fresh_session_cookie_headers(root, db_path, author)
            end
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, login = target_login}, self_cookie_headers)
    end

    if path_info == "/api/v1/admin/api-keys" then
        if method == "GET" then
            include_archived = (params.archived != "0")
            keys = auth.list_api_keys(db_path, include_archived)
            return web_ctx.respond_json(req, "200 OK", {api_keys = web_ctx.as_json_array(keys)})
        end
        if method == "POST" then
            body_data, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            raw_key, err = auth.create_api_key(db_path, body_data.label, body_data.cap)
            if raw_key == nil then
                return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
            end
            return web_ctx.respond_json(req, "200 OK", {
                success = true,
                label = body_data.label,
                cap = web_ctx.default_value(body_data.cap, ""),
                raw_key = raw_key,
            })
        end
        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    key_label_arch_raw = string.match(path_info, "^/api/v1/admin/api%-keys/(.+)/archive$")
    key_act = nil
    if key_label_arch_raw != nil then
        key_act = "archive"
    else
        key_label_arch_raw = string.match(path_info, "^/api/v1/admin/api%-keys/(.+)/unarchive$")
        if key_label_arch_raw != nil then
            key_act = "unarchive"
        end
    end
    if key_act != nil then
        if method != "POST" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        _, ok_body = web_ctx.read_write_json(req, true)
        if not ok_body then
            return true
        end
        target_label = web_ctx.percent_decode(key_label_arch_raw)
        if auth.get_api_key(db_path, target_label) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such api key: " .. target_label})
        end
        ok = nil
        err = nil
        if key_act == "archive" then
            ok, err = auth.archive_api_key(db_path, target_label)
        else
            ok, err = auth.unarchive_api_key(db_path, target_label)
        end
        if ok == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, label = target_label})
    end

    key_patch_raw = string.match(path_info, "^/api/v1/admin/api%-keys/(.+)$")
    if key_patch_raw != nil then
        if method != "PATCH" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        body_data, ok_body = web_ctx.read_write_json(req, false)
        if not ok_body then
            return true
        end
        target_label = web_ctx.percent_decode(key_patch_raw)
        if auth.get_api_key(db_path, target_label) == nil then
            return web_ctx.respond_json(req, "404 Not Found", {error = "no such api key: " .. target_label})
        end
        ok, err = auth.set_api_key_capabilities(db_path, target_label, body_data.cap)
        if ok == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = tostring(err)})
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, label = target_label})
    end

    if path_info == "/api/v1/admin/settings" then
        if method == "GET" then
            return web_ctx.respond_json(req, "200 OK", theme_settings_payload(config.load_theme(root)))
        end
        if method == "PATCH" then
            body_data, ok_body = web_ctx.read_write_json(req, false)
            if not ok_body then
                return true
            end
            current = config.load_theme(root)
            if body_data.site_name != nil then
                current.site_name = tostring(body_data.site_name)
            end
            if body_data.hide_home_heading != nil then
                current.hide_home_heading = (body_data.hide_home_heading == true)
            end
            if body_data.system_prompt_extra != nil then
                if body_data.system_prompt_extra == "" or body_data.system_prompt_extra == false then
                    current.system_prompt_extra = nil
                else
                    current.system_prompt_extra = tostring(body_data.system_prompt_extra)
                end
            end
            if body_data.colors != nil then
                new_colors, color_err = validate_theme_colors(body_data.colors)
                if color_err != nil then
                    return web_ctx.respond_json(req, "400 Bad Request", {error = color_err})
                end
                current.colors = new_colors
            end
            ok, err = config.save_theme(root, current)
            if ok == nil then
                return web_ctx.respond_json(req, "500 Internal Server Error", {error = tostring(err)})
            end
            return web_ctx.respond_json(req, "200 OK", {
                success = true,
                settings = theme_settings_payload(config.load_theme(root)),
            })
        end
        web_ctx.read_body()
        return web_ctx.method_not_allowed(req)
    end

    asset_name_raw = string.match(path_info, "^/api/v1/admin/settings/assets/([^/]+)$")
    if asset_name_raw != nil then
        asset_name = web_ctx.percent_decode(asset_name_raw)
        spec = ALLOWED_THEME_ASSETS[asset_name]
        if spec == nil then
            web_ctx.read_body()
            return web_ctx.respond_json(req, "404 Not Found", {error = "Unknown theme asset: " .. asset_name})
        end
        if method != "PUT" then
            web_ctx.read_body()
            return web_ctx.method_not_allowed(req)
        end
        raw_bytes = web_ctx.read_body()
        if not web_ctx.require_write_auth(req) then
            return true
        end
        wrote, write_err = write_png_theme_asset(root, asset_name, raw_bytes)
        if wrote == nil then
            return web_ctx.respond_json(req, "400 Bad Request", {error = write_err})
        end
        if spec.is_logo then
            current = config.load_theme(root)
            current.has_logo = true
            config.save_theme(root, current)
        end
        return web_ctx.respond_json(req, "200 OK", {success = true, name = asset_name})
    end

    return false
end

return admin_routes
