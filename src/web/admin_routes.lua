-- System overview, user/API-key administration, theme settings, and
-- manual extension triggers (/system, /admin-*, /settings*).

const config = require("config")
const paths = require("paths")
const auth = require("auth")
const entity = require("entity")
const extension = require("extension")
const mail_provider = require("mail_provider")
const multipart = require("multipart")
const json = require("dkjson")
const schema = require("schema")
const status_lib = require("status")
const ui = require("ui")
const view = require("view")
const web_ctx = require("web.context")

const admin_routes = {}

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
        form = web_ctx.parse_query(io.read("*all"))
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

    if string.sub(path_info, 1, 16) == "/admin-triggers/" then
        trigger_ext_name, trigger_name = string.match(path_info, "^/admin%-triggers/([^/]+)/([^/]+)$")
        if trigger_ext_name == nil or method != "POST" then
            return web_ctx.respond(req, "404 Not Found", "text/plain", "Not Found")
        end
        if not is_admin then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "Admin capability required"}))
        end
        if not web_ctx.require_csrf(req) then
            return web_ctx.respond(req, "403 Forbidden", "application/json", json.encode({error = "CSRF check failed"}))
        end

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
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "unknown trigger"}))
        end

        hooks, _ = extension.load_hooks(ext_dir, trigger_ext_name, manifest)
        trigger_fn = nil
        if hooks != nil and type(hooks.manual_triggers) == "table" then
            trigger_fn = hooks.manual_triggers[trigger_name]
        end
        if type(trigger_fn) != "function" then
            return web_ctx.respond(req, "404 Not Found", "application/json", json.encode({error = "unknown trigger"}))
        end

        ctx = entity.build_ctx(db_path, manifest)
        trigger_ok, trigger_result = extension.call_bounded(trigger_fn, ctx, {triggered_by = author})
        if trigger_ok == false then
            return web_ctx.respond(req, "500 Internal Server Error", "application/json", json.encode({error = tostring(trigger_result)}))
        end
        message = "Triggered."
        if type(trigger_result) == "table" and type(trigger_result.message) == "string" then
            message = trigger_result.message
        end
        return web_ctx.respond(req, "200 OK", "application/json", json.encode({success = true, message = message}))
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

        form = web_ctx.parse_query(io.read("*all"))
        if not web_ctx.require_csrf(req, form.csrf_token) then
            users = auth.list_users(db_path, true)
            body = ui.render_admin_users(users, config.password_reset_enabled(), csrf_val, "CSRF check failed.", true, true)
            return web_ctx.render_page(req, "Users", "system", body, nil, "403 Forbidden")
        end

        ok = nil
        err = nil
        self_cookie_headers = nil

        if path_info == "/admin-users-create" and config.password_reset_enabled() then
            ok, err = auth.invite_user(root, db_path, form.login, web_ctx.default_value(form.email, ""), form.cap, req.theme.site_name)
        elseif path_info == "/admin-users-create" then
            email = web_ctx.default_value(form.email, "")
            if email != "" and not mail_provider.valid_address(string.lower(email)) then
                ok, err = nil, "invalid email address: " .. email
            elseif email != "" and auth.get_user_by_email(db_path, email) != nil then
                ok, err = nil, "email already used by another account"
            else
                ok, err = auth.create_user(db_path, form.login, form.password, form.cap)
                if ok != nil and email != "" then
                    ok, err = auth.set_email(db_path, form.login, email)
                end
            end
        elseif path_info == "/admin-users-email" then
            ok, err = auth.set_email(db_path, form.login, web_ctx.default_value(form.email, ""))
            email_user = auth.get_user(db_path, form.login)
            if ok != nil and config.password_reset_enabled() and email_user != nil
                    and email_user.email != nil and email_user.email != "" and not auth.email_verified(email_user) then
                ok, err = auth.send_setup_link(root, db_path, form.login, req.theme.site_name)
                if ok == nil then
                    err = "email saved, but the setup link could not be sent: " .. tostring(err)
                end
            end
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

        form = web_ctx.parse_query(io.read("*all"))
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

        raw_body = io.read("*all")
        form = multipart.parse(os.getenv("CONTENT_TYPE"), raw_body)

        if not web_ctx.require_csrf(req, form.csrf_token) then
            body = ui.render_settings(req.theme, csrf_val, "CSRF check failed.", true)
            return web_ctx.render_page(req, "Settings", "system", body, nil, "403 Forbidden")
        end

        new_colors = {}
        color_error = nil
        for _, key in ipairs(config.THEME_COLOR_KEYS) do
            value = form["color_" .. key]
            if value != nil and value != "" then
                if string.match(value, "^[%w%s#%.,%%()-]+$") == nil then
                    color_error = "Invalid color value for '" .. key .. "' -- only letters, digits, and #.,%()- are allowed."
                end
                new_colors[key] = value
            end
        end

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
                paths.create_dir_if_not_exists(config.theme_assets_dir(root))
                dest_file, dest_err = io.open(paths.joinpath(config.theme_assets_dir(root), spec.filename), "wb")
                if dest_file == nil then
                    body = ui.render_settings(new_theme, csrf_val, tostring(dest_err), true)
                    return web_ctx.render_page(req, "Settings", "system", body, nil, "500 Internal Server Error")
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
            body = ui.render_settings(new_theme, csrf_val, tostring(err), true)
            return web_ctx.render_page(req, "Settings", "system", body, nil, "500 Internal Server Error")
        end
        return web_ctx.respond(req, "302 Found", "text/plain", "", {"Location: settings"})
    end

    return false
end

return admin_routes
