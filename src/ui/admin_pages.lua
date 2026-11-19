-- Authentication, account, home/system landing, and admin UI pages:
-- /login, /forgot-password, /reset-password, /verify-email, /account,
-- /admin-users, /admin-api-keys, /settings, /, /system, /admin-triggers.

const asset = require("asset")
const auth_lib = require("auth")
const config_lib = require("config")
const page_lib = require("page")
const ui_assets = require("ui.assets")
const ui_common = require("ui.common")

const html_escape = ui_common.html_escape

const ui_admin = {}

function render_login_card(title, sections, footer_html)
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    footer = ""
    if footer_html != nil then
        footer = "<p class=\"platform-login-footer\">" .. footer_html .. "</p>\n"
    end
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.error_banner_css(),
        asset.read("ui/login_card.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s">
    %s
    <div class="platform-login-card">
%s%s    </div>
</div>
""", html_escape(title), style_block, page_lib.render(sections), footer)
end

function ui_admin.render_login(error_message, nonce, show_forgot_link, notice)
    message = error_message
    message_css_class = nil
    if message == nil and notice != nil then
        message = notice
        message_css_class = "platform-login-notice"
    end
    footer_html = nil
    if show_forgot_link == true then
        footer_html = "<a href=\"/forgot-password\">Forgot password?</a>"
    end
    return render_login_card("Log in", {
        {
            type = "form",
            method = "POST",
            action = "/login",
            heading = "Log in",
            message = message,
            message_css_class = message_css_class,
            fields = {
                {type = "text", name = "login", label = "Login", autocomplete = "username", required = true},
                {type = "password", name = "password", label = "Password", autocomplete = "current-password", required = true},
            },
            submit_label = "Log in",
        },
    }, footer_html)
end

function ui_admin.render_forgot_password(error_message, sent)
    if sent == true then
        return render_login_card("Forgot password", {
            {
                type = "form",
                method = "GET",
                action = "/login",
                heading = "Check your email",
                message = "If that matches an account with an email address on file, we've sent it a link to reset the password. The link expires in 1 hour.",
                message_css_class = "platform-login-notice",
                fields = {},
                submit_label = "Back to log in",
            },
        }, nil)
    end
    return render_login_card("Forgot password", {
        {
            type = "form",
            method = "POST",
            action = "/forgot-password",
            heading = "Forgot password",
            message = error_message,
            fields = {
                {type = "text", name = "identifier", label = "Login or email", autocomplete = "username", required = true},
            },
            submit_label = "Send reset link",
        },
    }, "<a href=\"/login\">Back to log in</a>")
end

function default_value_text(value)
    if value == nil then
        return ""
    end
    return value
end

function ui_admin.render_reset_password(token, error_message, invalid, nonce)
    if invalid == true then
        return render_login_card("Reset password", {
            {
                type = "form",
                method = "GET",
                action = "/forgot-password",
                heading = "Reset password",
                message = "This reset link is invalid, has expired, or has already been used.",
                fields = {},
                submit_label = "Request a new link",
            },
        }, "<a href=\"/login\">Back to log in</a>")
    end
    card = render_login_card("Reset password", {
        {
            type = "form",
            method = "POST",
            action = "/reset-password",
            heading = "Choose a new password",
            message = error_message,
            fields = {
                {type = "hidden", name = "token", id = "reset-token", value = default_value_text(token)},
                {type = "password", name = "new_password", label = "New password", autocomplete = "new-password", required = true},
                {type = "password", name = "confirm_password", label = "Confirm new password", autocomplete = "new-password", required = true},
            },
            submit_label = "Set password",
        },
    }, "<span id=\"reset-missing\" hidden>This link is incomplete. Open it straight from the email, or <a href=\"/forgot-password\">request a new one</a>.</span>")
    return card .. ui_assets.inline_script(nonce, asset.read("ui/hash_token.js"))
end

function ui_admin.render_verify_email(token, error_message, invalid, nonce)
    if invalid == true then
        return render_login_card("Confirm email", {
            {
                type = "form",
                method = "GET",
                action = "/login",
                heading = "Confirm email",
                message = "This confirmation link is invalid, has expired, or has already been used. Ask an administrator to send a new one.",
                fields = {},
                submit_label = "Back to log in",
            },
        }, "")
    end
    card = render_login_card("Confirm email", {
        {
            type = "form",
            method = "POST",
            action = "/verify-email",
            heading = "Confirm your email",
            message = error_message,
            fields = {
                {type = "hidden", name = "token", id = "verify-token", value = default_value_text(token)},
                {type = "password", name = "password", label = "Your current password", autocomplete = "current-password", required = true},
            },
            submit_label = "Confirm email",
        },
    }, "<span id=\"verify-missing\" hidden>This link is incomplete. Open it straight from the email.</span>")
    return card .. ui_assets.inline_script(nonce, asset.read("ui/hash_token.js"))
end

function ui_admin.render_account(username, user, csrf_token, message, is_error)
    message_css_class = "platform-account-message"
    if is_error == true then
        message_css_class = "platform-account-message platform-account-message-error"
    end

    sections = {}
    if message != nil and message != "" then
        table.insert(sections, {type = "message", css_class = message_css_class, text = message})
    end
    table.insert(sections, {type = "subheading", text = "Change password"})
    table.insert(sections, {
        type = "form",
        method = "POST",
        action = "account",
        fields = {
            {type = "hidden", name = "csrf_token", value = csrf_token},
            {type = "password", name = "current_password", label = "Current password", autocomplete = "current-password", required = true},
            {type = "password", name = "new_password", label = "New password", autocomplete = "new-password", required = true},
        },
        submit_label = "Change password",
    })
    email_text = "No email on file -- ask an admin to add one if you want to be able to reset your password."
    if user != nil and user.email != nil and user.email != "" then
        if auth_lib.email_verified(user) then
            email_text = user.email .. " (verified) -- ask an admin to change it."
        else
            email_text = user.email .. " (not verified yet: use the setup link emailed to it) -- ask an admin to change it."
        end
    end
    table.insert(sections, {type = "subheading", text = "Email"})
    table.insert(sections, {type = "message", css_class = "platform-account-email", text = email_text})
    table.insert(sections, {type = "subheading", text = "Log out"})
    table.insert(sections, {
        type = "form",
        css_class = "platform-account-logout-form",
        method = "GET",
        action = "logout",
        fields = {},
        submit_class = "btn-secondary",
        submit_label = "Log out",
    })

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        asset.read("ui/account.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Account">
    %s
    <div class="platform-account-card">
        <h2>Account</h2>
        <p class="platform-account-username">Signed in as <strong>%s</strong></p>
%s    </div>
</div>
""", style_block, html_escape(username), page_lib.render(sections))
end

function ui_admin.render_admin_users(users, invite_mode, csrf_token, message, is_error, show_archived)
    message_css_class = "platform-admin-message"
    if is_error == true then
        message_css_class = "platform-admin-message platform-admin-message-error"
    end

    create_fields = {
        {type = "hidden", name = "csrf_token", value = csrf_token},
        {type = "text", name = "login", placeholder = "login", required = true},
        {type = "password", name = "password", placeholder = "password", required = true},
        {type = "text", name = "email", placeholder = "email (optional)", autocomplete = "off"},
        {type = "text", name = "cap", placeholder = "capabilities (e.g. i)", size = "10"},
    }
    create_label = "Create user"
    if invite_mode == true then
        create_fields = {
            {type = "hidden", name = "csrf_token", value = csrf_token},
            {type = "text", name = "login", placeholder = "login", required = true},
            {type = "text", name = "email", placeholder = "email", required = true, autocomplete = "off"},
            {type = "text", name = "cap", placeholder = "capabilities (e.g. i)", size = "10"},
        }
        create_label = "Create and email setup link"
    end

    sections = {}
    if message != nil and message != "" then
        table.insert(sections, {type = "message", css_class = message_css_class, text = message})
    end
    table.insert(sections, {
        type = "form",
        method = "POST",
        action = "admin-users-create",
        css_class = "platform-admin-create-form",
        fields = create_fields,
        submit_label = create_label,
    })

    rows = {}
    for _, u in ipairs(users) do
        is_archived = u.archived_at != nil and u.archived_at != ""
        status = "active"
        if is_archived then
            status = "archived"
        end
        if u.email != nil and u.email != "" and not auth_lib.email_verified(u) then
            status = status .. ", email unverified"
        end
        archive_action = "archive"
        archive_label = "Archive"
        archive_button_class = "btn-danger"
        if is_archived then
            archive_action = "unarchive"
            archive_label = "Unarchive"
            archive_button_class = "btn-secondary"
        end

        table.insert(rows, {
            {u.login},
            {
                {
                    type = "form", method = "POST", action = "admin-users-email", css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "login", value = u.login},
                        {type = "text", name = "email", value = u.email, placeholder = "email", size = "22", autocomplete = "off"},
                    },
                    submit_class = "btn-secondary", submit_label = "Set",
                },
            },
            {
                {
                    type = "form", method = "POST", action = "admin-users-capabilities", css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "login", value = u.login},
                        {type = "text", name = "cap", value = u.cap, size = "6"},
                    },
                    submit_class = "btn-secondary", submit_label = "Set",
                },
            },
            {status},
            {
                {
                    type = "form", method = "POST", action = "admin-users-password", css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "login", value = u.login},
                        {type = "password", name = "password", placeholder = "new password", required = true},
                    },
                    submit_class = "btn-secondary", submit_label = "Set",
                },
                {
                    type = "form", method = "POST", action = "admin-users-" .. archive_action, css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "login", value = u.login},
                    },
                    submit_class = archive_button_class, submit_label = archive_label,
                },
            },
        })
    end
    toggle_fields = {}
    toggle_label = "Hide archived users"
    if show_archived != true then
        toggle_fields = {{type = "hidden", name = "archived", value = "1"}}
        toggle_label = "Show archived users"
    end
    table.insert(sections, {
        type = "form", method = "GET", action = "admin-users", css_class = "platform-admin-inline-form",
        fields = toggle_fields, submit_class = "btn-secondary", submit_label = toggle_label,
    })
    table.insert(sections, {
        type = "table",
        css_class = "platform-admin-users",
        columns = {"Login", "Email", "Capabilities", "Status", "Actions"},
        rows = rows,
    })

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        ui_common.admin_message_css(),
        asset.read("ui/admin_users.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Manage users">
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
""", style_block, ui_common.render_page_header("Manage users", nil, nil), page_lib.render(sections))
end

function ui_admin.render_admin_api_keys(keys, csrf_token, message, is_error, new_raw_key)
    message_css_class = "platform-admin-message"
    if is_error == true then
        message_css_class = "platform-admin-message platform-admin-message-error"
    end

    sections = {}
    if message != nil and message != "" then
        table.insert(sections, {type = "message", css_class = message_css_class, text = message})
    end
    if new_raw_key != nil and new_raw_key != "" then
        table.insert(sections, {
            type = "secret_reveal",
            css_class = "platform-admin-message platform-admin-new-key",
            instruction = "Save this key now -- it cannot be shown again:",
            value = new_raw_key,
        })
    end
    table.insert(sections, {
        type = "form",
        method = "POST",
        action = "admin-api-keys-create",
        css_class = "platform-admin-create-form",
        fields = {
            {type = "hidden", name = "csrf_token", value = csrf_token},
            {type = "text", name = "label", placeholder = "label (e.g. nightly sync job)", required = true},
            {type = "text", name = "cap", placeholder = "capabilities (e.g. i)", size = "10"},
        },
        submit_label = "Create key",
    })

    rows = {}
    for _, k in ipairs(keys) do
        is_archived = k.archived_at != nil and k.archived_at != ""
        status = "active"
        if is_archived then
            status = "archived"
        end
        archive_action = "archive"
        archive_label = "Archive"
        archive_button_class = "btn-danger"
        if is_archived then
            archive_action = "unarchive"
            archive_label = "Unarchive"
            archive_button_class = "btn-secondary"
        end

        table.insert(rows, {
            {k.label},
            {
                {
                    type = "form", method = "POST", action = "admin-api-keys-capabilities", css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "label", value = k.label},
                        {type = "text", name = "cap", value = k.cap, size = "6"},
                    },
                    submit_class = "btn-secondary", submit_label = "Set",
                },
            },
            {status},
            {
                {
                    type = "form", method = "POST", action = "admin-api-keys-" .. archive_action, css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                        {type = "hidden", name = "label", value = k.label},
                    },
                    submit_class = archive_button_class, submit_label = archive_label,
                },
            },
        })
    end
    table.insert(sections, {
        type = "table",
        css_class = "platform-admin-users",
        columns = {"Label", "Capabilities", "Status", "Actions"},
        rows = rows,
    })

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        ui_common.admin_message_css(),
        asset.read("ui/admin_users.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Manage API keys">
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
""", style_block, ui_common.render_page_header("Manage API keys", nil, nil), page_lib.render(sections))
end

function ui_admin.render_settings(theme, csrf_token, message, is_error)
    message_css_class = "platform-admin-message"
    if is_error == true then
        message_css_class = "platform-admin-message platform-admin-message-error"
    end

    system_prompt_extra_value = ""
    if theme.system_prompt_extra != nil then
        system_prompt_extra_value = theme.system_prompt_extra
    end

    color_fields = {}
    for _, key in ipairs(config_lib.THEME_COLOR_KEYS) do
        value = ""
        if theme.colors != nil and theme.colors[key] != nil then
            value = theme.colors[key]
        end
        table.insert(color_fields, {
            type = "text", name = "color_" .. key, label = string.gsub(key, "_", " "),
            value = value, placeholder = "e.g. #4f46e5", size = "12", wrapper_class = "platform-settings-color",
        })
    end

    logo_status = "No logo uploaded -- the sidebar shows the default icon and \"Daat\" as plain text."
    if theme.has_logo == true then
        logo_status = "A logo is set. Uploading a new file below replaces it; there is no separate \"remove\" action today -- redeploy tooling or a direct theme-assets/ edit still handles removal."
    end

    sections = {}
    if message != nil and message != "" then
        table.insert(sections, {type = "message", css_class = message_css_class, text = message})
    end
    table.insert(sections, {
        type = "form",
        method = "POST",
        action = "settings-save",
        enctype = "multipart/form-data",
        fields = {
            {type = "hidden", name = "csrf_token", value = csrf_token},
        },
        groups = {
            {
                css_class = "platform-settings-section",
                heading = "Site",
                fields = {
                    {type = "text", name = "site_name", label = "Site name", value = theme.site_name, placeholder = "Daat"},
                    {
                        type = "checkbox", name = "hide_home_heading",
                        label = "Hide the site name heading on Home (use when the logo already reads as a wordmark)",
                        value = "1", checked = (theme.hide_home_heading == true), wrapper_class = "platform-settings-checkbox",
                    },
                },
            },
            {
                css_class = "platform-settings-section",
                heading = "Branding",
                intro = logo_status,
                fields = {
                    {type = "file", name = "logo_file", label = "Sidebar mark (square, theme-assets/logo.png)", accept = "image/png"},
                    {type = "file", name = "logo_full_file", label = "Full wordmark shown on Home (theme-assets/logo-full.png)", accept = "image/png"},
                    {type = "file", name = "favicon_file", label = "Favicon (theme-assets/favicon.png)", accept = "image/png"},
                },
            },
            {
                css_class = "platform-settings-section",
                heading = "Colors",
                intro = "Leave any field blank to use the default indigo/slate palette for that color.",
                fields_wrapper_class = "platform-settings-colors",
                fields = color_fields,
            },
            {
                css_class = "platform-settings-section",
                heading = "Chat assistant",
                fields = {
                    {
                        type = "textarea", name = "system_prompt_extra", label = "Extra system prompt instructions",
                        value = system_prompt_extra_value,
                        placeholder = "e.g. This deployment tracks bioreactor runs -- always ask for the run ID before creating a sample.",
                    },
                },
            },
        },
        submit_label = "Save settings",
    })

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        ui_common.admin_message_css(),
        asset.read("ui/settings.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Settings">
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
""", style_block, ui_common.render_page_header("Settings", nil, nil), page_lib.render(sections))
end

function ui_admin.render_home(theme, show_sql, show_admin, has_tasks_view, nav_extensions)
    site_name = "Daat"
    has_logo = false
    hide_home_heading = false
    if theme != nil then
        site_name = theme.site_name
        has_logo = theme.has_logo == true
        hide_home_heading = theme.hide_home_heading == true
    end

    logo_html = ""
    if has_logo then
        logo_html = string.format(
            "<img class=\"platform-home-logo\" src=\"theme-asset?name=logo-full.png\" alt=\"%s\">",
            html_escape(site_name)
        )
    end

    heading_html = ""
    if not (hide_home_heading and has_logo) then
        heading_html = "<h2>" .. html_escape(site_name) .. "</h2>"
    end

    system_link = ""
    if show_sql or show_admin then
        system_link = ui_common.render_sitemap_item("system", "System", "Admin, SQL console, and templates.")
    end

    knowledge_link = ui_common.render_sitemap_item("knowledge", "Knowledge Pool", "Tiered notes, retrieval activity, and chat sessions.")

    tasks_link = ""
    if has_tasks_view == true then
        tasks_link = ui_common.render_sitemap_item("view?view_name=prioritized_tasks", "Tasks", "Open tasks, ranked by priority.")
    end

    extension_tiles = ""
    if nav_extensions != nil then
        for _, entry in ipairs(nav_extensions) do
            ext_ui = entry.manifest.capabilities.ui
            description = ext_ui.description
            if description == nil or description == "" then
                description = "Open the " .. ext_ui.label .. " extension."
            end
            extension_tiles = extension_tiles .. ui_common.render_sitemap_item("ext/" .. entry.name, ext_ui.label, description)
        end
    end

    home_header = "<div class=\"platform-header\"><div>" .. logo_html .. heading_html ..
        "<p>Welcome back. Use the sidebar to get around, or jump in below.</p></div></div>"
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.sitemap_css(),
        ui_common.page_header_css(),
        asset.read("ui/home.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Home">
    %s
    <div class="platform-container">
        %s
        <ul class="platform-sitemap">
            %s
            %s
            %s
            %s
            %s
            %s
            %s
        </ul>
    </div>
</div>
""", style_block, home_header,
     ui_common.render_sitemap_item("document-edit", "New Document", "Write a new document from scratch."),
     ui_common.render_sitemap_item("documents", "Documents", "Browse all documents, organized as a tree."),
     ui_common.render_sitemap_item("data", "Data", "Registered entity types, row counts, and relations."),
     knowledge_link, tasks_link, system_link, extension_tiles)
end

function ui_admin.render_system(show_sql, show_admin)
    items = ""
    if show_sql then
        items = items .. ui_common.render_sitemap_item("sql", "SQL console", "Run ad hoc, read-only queries.")
    end
    if show_admin then
        items = items .. ui_common.render_sitemap_item("system-status", "Status & Approvals", "Deployment health, runtime checks, and view/extension approvals.")
        items = items .. ui_common.render_sitemap_item("admin-users", "Users", "Manage accounts and capabilities.")
        items = items .. ui_common.render_sitemap_item("admin-api-keys", "API keys", "Manage external-integration API keys.")
        items = items .. ui_common.render_sitemap_item("settings", "Settings", "Site name, branding, colors, and chat prompt.")
        items = items .. ui_common.render_sitemap_item("admin-triggers", "Manual Triggers", "Run admin-triggered extension actions on demand.")
    end
    items = items .. ui_common.render_sitemap_item("templates", "Templates", "Reusable entry templates for new documents.")

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.sitemap_css(),
        ui_common.page_header_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="System">
    %s
    <div class="platform-container">
        %s
        <ul class="platform-sitemap">
%s
        </ul>
    </div>
</div>
""", style_block, ui_common.render_page_header("System", nil, nil), items)
end

function status_text(cond, t_str, f_str)
    if cond == true then
        return t_str
    end
    return f_str
end

function status_default(val, fallback)
    if val == nil or val == "" then
        return fallback
    end
    return tostring(val)
end

function ui_admin.render_system_status(report, csrf_token, message, is_error)
    sections = {}
    if message != nil and message != "" then
        msg_class = "platform-admin-message"
        if is_error == true then
            msg_class = "platform-admin-message platform-admin-message-error"
        end
        table.insert(sections, {type = "message", css_class = msg_class, text = message})
    end

    for _, iss in ipairs(report.issues) do
        table.insert(sections, {
            type = "message",
            css_class = "platform-admin-message platform-admin-message-error",
            text = "Error: " .. iss,
        })
    end
    for _, warn in ipairs(report.warnings) do
        table.insert(sections, {
            type = "message",
            css_class = "platform-admin-message",
            text = "Warning: " .. warn,
        })
    end

    -- 1. Store, Providers & Queues summary table
    table.insert(sections, {type = "subheading", text = "Deployment Health"})
    health_rows = {
        {{"Database backend"}, {report.store.backend .. " (" .. report.store.target .. ")"}, {status_text(report.store.connected, "connected", "disconnected")}},
        {{"Database auth"}, {report.store.credential_status}, {status_text(report.config.ok, "config ok", "config errors")}},
        {
            {"Agent provider"},
            {report.providers.agent.provider .. " (model: " .. status_default(report.providers.agent.model, "-") ..
                ", embedding: " .. status_default(report.providers.agent.embedding_model, "-") .. ")"},
            {report.providers.agent.credential_status},
        },
        {{"Search provider"}, {report.providers.search.provider}, {report.providers.search.credential_status}},
        {
            {"Mail provider"},
            {report.providers.mail.provider .. " (password reset: " .. status_text(report.providers.mail.password_reset_enabled, "enabled", "disabled") .. ")"},
            {report.providers.mail.credential_status},
        },
    }
    for _, b in ipairs(report.binaries) do
        bin_state = "not installed (optional)"
        if b.available == true then
            bin_state = "found"
        elseif b.required == true then
            bin_state = "MISSING (required)"
        end
        table.insert(health_rows, {{"Binary: " .. b.name}, {b.purpose}, {bin_state}})
    end
    if report.queues != nil then
        table.insert(health_rows, {
            {"Pending queues"},
            {string.format("embeddings=%d, reviews=%d, extensions=%d, background=%d, curations=%d",
                report.queues.embeddings_due,
                report.queues.retrievals_unreviewed,
                report.queues.extension_jobs_pending,
                report.queues.agent_background_pending,
                report.queues.conversations_due_curation)},
            {"ready"},
        })
    end
    table.insert(sections, {
        type = "table",
        css_class = "platform-admin-users",
        columns = {"Check", "Details", "Status"},
        rows = health_rows,
    })

    -- 2. Schemas sync status
    if report.schemas != nil then
        table.insert(sections, {type = "subheading", text = "Schemas"})
        sync_state = status_text(report.schemas.in_sync, "in sync", "unapplied changes on disk")
        schema_action_cell = {"Up to date"}
        if report.schemas.in_sync != true then
            schema_action_cell = {
                {
                    type = "form", method = "POST", action = "system-status-schema-sync", css_class = "platform-admin-inline-form",
                    fields = {
                        {type = "hidden", name = "csrf_token", value = csrf_token},
                    },
                    submit_class = "btn-secondary", submit_label = "Sync schemas",
                },
            }
        end
        table.insert(sections, {
            type = "table",
            css_class = "platform-admin-users",
            columns = {"Registered types", "Files on disk", "Status", "Action"},
            rows = {
                {
                    {tostring(report.schemas.registered_count)},
                    {tostring(report.schemas.disk_count)},
                    {sync_state},
                    schema_action_cell,
                },
            },
        })
    end

    -- 3. Views approvals
    table.insert(sections, {type = "subheading", text = "Saved Views Approval"})
    if #report.views == 0 then
        table.insert(sections, {type = "message", css_class = "platform-admin-message", text = "No view definitions found on disk."})
    else
        view_rows = {}
        for _, vw in ipairs(report.views) do
            action_cell = {"Invalid file"}
            if vw.status == "approved" then
                action_cell = {
                    {
                        type = "form", method = "POST", action = "system-status-view-revoke", css_class = "platform-admin-inline-form",
                        fields = {
                            {type = "hidden", name = "csrf_token", value = csrf_token},
                            {type = "hidden", name = "name", value = vw.name},
                        },
                        submit_class = "btn-danger", submit_label = "Revoke",
                    },
                }
            elseif vw.status == "unapproved" or vw.status == "drifted" then
                btn_label = "Approve"
                if vw.status == "drifted" then
                    btn_label = "Re-approve SQL"
                end
                action_cell = {
                    {
                        type = "form", method = "POST", action = "system-status-view-approve", css_class = "platform-admin-inline-form",
                        fields = {
                            {type = "hidden", name = "csrf_token", value = csrf_token},
                            {type = "hidden", name = "name", value = vw.name},
                        },
                        submit_class = "btn-secondary", submit_label = btn_label,
                    },
                }
            end
            sql_display = vw.sql
            if vw.status == "invalid" then
                sql_display = status_default(vw.error, "invalid view")
            end
            table.insert(view_rows, {
                {vw.name},
                {sql_display},
                {vw.status},
                action_cell,
            })
        end
        table.insert(sections, {
            type = "table",
            css_class = "platform-admin-users",
            columns = {"View", "SQL", "Approval", "Action"},
            rows = view_rows,
        })
    end

    -- 4. Extensions approvals
    table.insert(sections, {type = "subheading", text = "Extensions Approval"})
    if #report.extensions == 0 then
        table.insert(sections, {type = "message", css_class = "platform-admin-message", text = "No extensions found on disk."})
    else
        ext_rows = {}
        for _, ex in ipairs(report.extensions) do
            ext_action = {"Invalid manifest"}
            if ex.status == "approved" then
                ext_action = {
                    {
                        type = "form", method = "POST", action = "system-status-extension-revoke", css_class = "platform-admin-inline-form",
                        fields = {
                            {type = "hidden", name = "csrf_token", value = csrf_token},
                            {type = "hidden", name = "name", value = ex.name},
                        },
                        submit_class = "btn-danger", submit_label = "Revoke",
                    },
                }
            elseif ex.status == "unapproved" or ex.status == "drifted" then
                btn_label = "Approve"
                if ex.status == "drifted" then
                    btn_label = "Re-approve capabilities"
                end
                ext_action = {
                    {
                        type = "form", method = "POST", action = "system-status-extension-approve", css_class = "platform-admin-inline-form",
                        fields = {
                            {type = "hidden", name = "csrf_token", value = csrf_token},
                            {type = "hidden", name = "name", value = ex.name},
                        },
                        submit_class = "btn-secondary", submit_label = btn_label,
                    },
                }
            end
            caps_display = ex.capabilities_summary
            if ex.status == "invalid" then
                caps_display = status_default(ex.error, "invalid manifest")
            end
            ev_text = "-"
            if type(ex.events) == "table" and #ex.events > 0 then
                ev_text = table.concat(ex.events, ", ")
            end
            table.insert(ext_rows, {
                {ex.name},
                {ev_text},
                {caps_display},
                {ex.status},
                ext_action,
            })
        end
        table.insert(sections, {
            type = "table",
            css_class = "platform-admin-users",
            columns = {"Extension", "Events", "Requested Capabilities", "Approval", "Action"},
            rows = ext_rows,
        })
    end

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.page_header_css(),
        ui_common.admin_message_css(),
        asset.read("ui/admin_users.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Status &amp; Approvals">
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
""", style_block, ui_common.render_page_header("Status & Approvals", nil, nil), page_lib.render(sections))
end

function ui_admin.render_admin_triggers(triggers, nonce)
    if #triggers == 0 then
        sections = {
            {type = "message", css_class = "status-msg", text = "No approved extension currently declares a manual trigger."},
        }
        validate_err = page_lib.validate(sections)
        if validate_err != nil then
            error(validate_err)
        end
        style_block = ui_common.inline_styles({
            ui_common.container_css(),
            ui_common.page_header_css(),
        })
        return string.format("""
<div class="fossil-doc" data-title="Manual Triggers">
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
""", style_block, ui_common.render_page_header("Manual Triggers", nil, nil), page_lib.render(sections))
    end

    buttons = {}
    for _, entry in ipairs(triggers) do
        for _, trigger in ipairs(entry.manifest.capabilities.manual_triggers) do
            table.insert(buttons, {
                label = trigger.label,
                id = "btn-trigger-" .. entry.name .. "-" .. trigger.name,
                css_class = "btn btn-secondary",
                data = {ext = entry.name, trigger = trigger.name},
            })
        end
    end

    sections = {
        {type = "actions", buttons = buttons},
        {type = "status_placeholder", id = "status-message", css_class = "status-msg"},
    }
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    actions_html = page_lib.render(sections)

    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.page_header_css(),
        ui_common.button_css(),
        asset.read("ui/home.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Manual Triggers">
    %s
    <div class="platform-container">
        %s
%s    </div>

%s</div>
""", style_block, ui_common.render_page_header("Manual Triggers", nil, nil), actions_html,
     ui_assets.inline_script(nonce, asset.read("ui/admin_triggers.js")))
end

return ui_admin
