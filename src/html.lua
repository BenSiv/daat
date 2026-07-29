db = require("db")
schema = require("schema")
view = require("view")
config = require("config")
document = require("document")

html = {}

-- Entity field values and (in principle) entity_type ultimately come
-- from user-submitted data -- escape before ever interpolating into
-- HTML text/attributes.
function html.html_escape(s)
    s = tostring(s)
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    s = string.gsub(s, "\"", "&quot;")
    s = string.gsub(s, "'", "&#39;")
    return s
end

-- Two more escaping functions, deliberately distinct from html_escape
-- above: HTML tag content/attributes and inline-<script> content are
-- different injection contexts and need different escaping, the same
-- way Go's html/template picks an escaper per context rather than
-- applying one generic function everywhere. html_escape is correct for
-- values landing in HTML body text or an attribute; neither of the two
-- below is that context.
--
-- json_for_script: for an *already JSON-encoded* string (json.encode's
-- own output) that will be embedded inside an inline <script> body, e.g.
-- `const layout = ` .. json_for_script(json.encode(layout)) .. `;`. A
-- JSON encoder has no reason to escape "<" (not required by the JSON
-- spec), but a literal "</script>" sequence inside a JSON string value
-- terminates the surrounding <script> tag at the HTML-parser level --
-- before any JS engine even looks at the content -- letting whatever
-- follows execute as newly-opened markup. Confirmed as a real, working
-- injection, not theoretical: a schema field's own `label` containing
-- "</script><script>alert(1)</script>" did exactly this, unescaped,
-- reaching the live page. < parses back to a literal "<" in
-- JSON/JS, so this changes nothing about the decoded value.
function json_for_script(json_string)
    return (string.gsub(json_string, "<", "\\u003c"))
end

-- js_string_literal: for a plain (not-yet-JSON-encoded) Lua string
-- being embedded directly inside a JS string literal, e.g.
-- `const entityType = "` .. js_string_literal(entity_type) .. `";`.
-- Escapes backslash and double-quote (so the value can't break out of
-- the surrounding "..." literal) and "<" for the same script-tag-breakout
-- reason json_for_script exists.
function js_string_literal(s)
    s = tostring(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\r\n", "\\n")
    s = string.gsub(s, "\r", "\\n")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "<", "\\u003c")
    return s
end

-- The ".platform-container" shell (card look: padding/shadow/border/
-- rounded corners) was copy-pasted, identically byte-for-byte except
-- max_width, into every render_* function's own inline <style> block --
-- ten separate copies, confirmed by grepping the file directly. One
-- shared definition instead; each caller supplies just the max-width
-- its own page already used (1200/1100/900/800), so this is a pure
-- de-duplication, not a visual change anywhere.
function platform_container_css(max_width)
    if max_width == nil then
        max_width = 1200
    end
    return string.format("""
        .platform-container {
            font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            color: var(--platform-text, #334155);
            background: #ffffff;
            padding: 28px;
            border-radius: var(--platform-radius-lg, 16px);
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.05);
            margin: 20px auto;
            max-width: %dpx;
            border: 1px solid var(--platform-bg-2, #f1f5f9);
        }
""", max_width)
end

-- Shared .btn/.btn-primary/.btn-secondary/.btn-delete/.btn-danger rules --
-- previously three separate, hand-copied inline copies (render(),
-- render_browse(), render_sql()) that had quietly drifted apart:
-- render_sql()'s never picked up the shared .btn base at all (no
-- flex-centering, no shared transition/padding token), and its
-- .btn-secondary was a whole font-size step smaller (0.85rem vs the
-- others' inherited 0.9rem) -- confirmed via a real rendered-page diff,
-- not just reading the CSS. One copy now, used everywhere a button
-- appears. .btn-danger (button-audit follow-up) is for a genuinely
-- one-way negative action -- Archive, Deny -- as opposed to .btn-delete's
-- own narrower "remove this not-yet-saved row" icon-button use, or a
-- reversible toggle like Unarchive/Approve, which stay .btn-secondary/
-- .btn-primary.
function platform_button_css()
    return """
        .btn {
            padding: 10px 20px;
            border-radius: var(--platform-radius-sm, 8px);
            font-weight: 600;
            font-size: 0.9rem;
            cursor: pointer;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            border: none;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            text-decoration: none;
        }
        .btn-primary {
            background: var(--platform-accent, #4f46e5);
            color: #ffffff;
        }
        .btn-primary:hover { filter: brightness(1.08); }
        .btn-primary:active { transform: scale(0.98); }
        .btn-secondary {
            background: var(--platform-bg, #f8fafc);
            color: var(--platform-th-text, #475569);
            border: 1px solid var(--platform-border, #e2e8f0);
        }
        .btn-secondary:hover { background: var(--platform-bg-2, #f1f5f9); color: var(--platform-heading, #0f172a); }
        .btn-secondary:active { transform: scale(0.98); }
        .btn-secondary:disabled { opacity: 0.6; cursor: default; transform: none; }
        .btn-danger {
            background: var(--platform-bg, #f8fafc);
            color: #b91c1c;
            border: 1px solid #fecaca;
        }
        .btn-danger:hover { background: #fef2f2; color: #b91c1c; }
        .btn-danger:active { transform: scale(0.98); }
        .btn-delete {
            background: transparent;
            color: var(--platform-muted-2, #94a3b8);
            font-size: 1.25rem;
            cursor: pointer;
            transition: color 0.15s ease;
            border: none;
            padding: 4px;
        }
        .btn-delete:hover { color: #ef4444; }
"""
end

-- Generic hover-popover component, for "reveal detail on hover instead
-- of cramming it into the default view" -- the design principle behind
-- moving Data-index row counts and SQL-result entity previews off the
-- page by default (see render_index/render_sql). Reused as shared
-- blocks rather than duplicated per render_* function, matching how a
-- few other repeated style rules (.platform-container, .btn-primary,
-- etc.) already work in this file -- each render_* function embeds its
-- own self-contained <style>/<script>, there is no separate
-- shared-asset loading mechanism in platform today.
--
-- Two trigger shapes, same visual popover, split into CSS-only vs
-- CSS+JS so a page with only the cheap precomputed case (no JS/nonce
-- needed at all) doesn't have to carry the fetch machinery:
--   - A trigger with a `.platform-popover` child already containing real
--     markup (no `data-platform-popover-src`) just reveals it on hover --
--     pure CSS, for callers that can cheaply precompute the content
--     server-side. Only needs popover_css().
--   - `data-platform-popover-src="URL"` -- lazy-fetched (debounced,
--     cached per URL for the page's lifetime) JSON `{html: "..."}`
--     response, shown on hover. For cases where precomputing/embedding
--     every possible preview server-side would be wasteful (e.g. one
--     row per SQL result). Needs both popover_css() and popover_js().
function html.popover_css()
    return """
<style>
.platform-popover-trigger { position: relative; cursor: help; }
.platform-popover-trigger[data-platform-popover-src] { cursor: pointer; }
.platform-popover {
    position: absolute; z-index: 100; left: 0; top: 100%; margin-top: 6px;
    min-width: 180px; max-width: 320px; padding: 10px 12px;
    background: var(--platform-bg, #ffffff); border: 1px solid var(--platform-border, #e2e8f0);
    border-radius: var(--platform-radius-sm, 8px); box-shadow: 0 6px 20px rgba(0,0,0,0.12);
    font-size: 0.85rem; font-weight: 400; color: var(--platform-text, #334155);
    text-align: left; white-space: normal;
    opacity: 0; visibility: hidden; transform: translateY(-4px);
    transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1));
    pointer-events: none;
}
.platform-popover-trigger:hover .platform-popover,
.platform-popover-trigger:focus .platform-popover { opacity: 1; visibility: visible; transform: translateY(0); pointer-events: auto; }
.platform-popover-loading, .platform-popover-error { color: var(--platform-muted, #94a3b8); font-style: italic; }
</style>
"""
end

-- `nonce` must be Fossil's own per-request CSP nonce (see html.render's
-- own comment below) since this emits an inline <script>.
function html.popover_js(nonce)
    if nonce == nil then
        nonce = ""
    end
    return string.format("""
<script nonce="%s">
(function(){
    var cache = {};
    function loadInto(trigger, pop){
        var src = trigger.getAttribute('data-platform-popover-src');
        if(cache[src] != null){ pop.innerHTML = cache[src]; return; }
        pop.innerHTML = '<span class="platform-popover-loading">Loading...</span>';
        fetch(src).then(function(resp){ return resp.json(); }).then(function(data){
            var html = (data && data.html) ? data.html : 'No preview available.';
            cache[src] = html;
            pop.innerHTML = html;
        }).catch(function(){
            pop.innerHTML = '<span class="platform-popover-error">Preview failed to load.</span>';
        });
    }
    document.querySelectorAll('.platform-popover-trigger[data-platform-popover-src]').forEach(function(trigger){
        var pop = trigger.querySelector('.platform-popover');
        if(!pop) return;
        var timer = null;
        var loaded = false;
        trigger.addEventListener('mouseenter', function(){
            // task #111: .platform-popover's default CSS is `position:
            // absolute` relative to the trigger -- fine standalone, but
            // a long result table is wrapped in `.platform-table-wrapper
            // { overflow-x: auto }`, and per the CSS Overflow spec
            // setting only one axis forces the *other* axis to compute
            // as auto too (an explicit `overflow-y: visible` on the
            // wrapper would still get overridden back to auto by that
            // same rule -- confirmed, not a viable CSS-only fix), so
            // the wrapper clips/traps the popover instead of letting it
            // float free. Repositioned to `position: fixed` with real
            // viewport coordinates here escapes that clipping
            // entirely, since a fixed-position element is placed
            // relative to the viewport, not any scrolling ancestor.
            var rect = trigger.getBoundingClientRect();
            var popWidth = 320; // matches .platform-popover's max-width
            var left = Math.min(rect.left, window.innerWidth - popWidth - 12);
            left = Math.max(left, 8);
            pop.style.position = 'fixed';
            pop.style.left = left + 'px';
            pop.style.top = (rect.bottom + 6) + 'px';
            pop.style.margin = '0';
            timer = setTimeout(function(){
                if(!loaded){ loaded = true; loadInto(trigger, pop); }
            }, 200);
        });
        trigger.addEventListener('mouseleave', function(){
            if(timer) clearTimeout(timer);
        });
    });
})();
</script>
""", nonce)
end

-- The CSS custom-property names a theme may override, in a fixed
-- display order -- matches config.lua's own THEME_COLOR_KEYS exactly.
THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
}

-- Wraps a rendered page body in the outer HTML document (<!doctype>,
-- <head>, top nav) that nothing in this codebase supplies on its own --
-- every render_* function below returns a bare content fragment (the
-- "fossil-doc"/data-title convention, a leftover from once being
-- embedded inside a Fossil skin that supplied the real shell and read
-- data-title for its own <title>). Now that platform is served
-- standalone, something has to supply that shell -- this is it, called
-- once per request from cgi.lua rather than duplicated into every
-- render_* call site.
--
-- theme is config.load_theme(root)'s return value: {site_name=...,
-- colors={...}}. This is deliberately the *only* place branding enters
-- a page -- platform itself ships no colors or company name of its
-- own beyond the existing var(--platform-*, <fallback>) defaults already
-- used throughout this file, which are left completely untouched when
-- theme.colors is empty (the out-of-the-box, unconfigured case).
-- Plain, generic (not brand-specific) 20x20 line icons for the nav
-- rail -- reused as-is from this deployment's own earlier hand-built
-- icon set (house/document/book/database/checkmark/gear), which lived
-- fine as generic iconography rather than anything Celleste-specific.
ICON_HOME = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 11l9-8 9 8\"/><path d=\"M5 10v10a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10\"/></svg>"
ICON_NOTEBOOK = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 5a2 2 0 0 1 2-2h5v18H6a2 2 0 0 1-2-2V5z\"/><path d=\"M20 5a2 2 0 0 0-2-2h-5v18h5a2 2 0 0 0 2-2V5z\"/></svg>"
ICON_DATA = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><ellipse cx=\"12\" cy=\"5\" rx=\"8\" ry=\"3\"/><path d=\"M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5\"/><path d=\"M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6\"/></svg>"
ICON_TASKS = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M9 11l3 3L22 4\"/><path d=\"M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11\"/></svg>"
ICON_SYSTEM = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z\"/></svg>"
-- Chat bubble -- the floating widget's toggle button icon, not part of
-- the icon rail's own order (see html.render_chat_widget below).
ICON_CHAT_BUBBLE = "<svg width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z\"/></svg>"

-- The `:root { --platform-x: value; ... }` block a deployment's real
-- theme.lua colors compile down to -- shared by html.page_shell (the
-- normal full-page case) and by /sql?embed=1's iframe fragment (cgi.lua),
-- which skips page_shell entirely (see its own comment on why) but still
-- needs these variables defined somewhere in its own document, or every
-- var(--platform-*, fallback) in its styles silently resolves to the
-- generic fallback instead of the deployment's real palette -- confirmed
-- live: the embedded SQL widget on /data was rendering in the default
-- indigo/slate colors instead of Celleste's real brown/gold theme.
function html.theme_root_css(theme)
    root_vars = {}
    for _, key in ipairs(THEME_COLOR_KEYS) do
        value = theme.colors[key]
        if value != nil then
            css_name = string.gsub(key, "_", "-")
            table.insert(root_vars, "--platform-" .. css_name .. ": " .. value .. ";")
        end
    end
    if #root_vars == 0 then
        return ""
    end
    return ":root { " .. table.concat(root_vars, " ") .. " }"
end

-- page_context: what the chat widget/agent is told about "where the
-- user currently is" (see render_chat_widget's script and
-- agent.default_system_prompt). Callers that know more than the bare
-- nav section (a document's own id, an entity's type+id, a view's
-- name) should pass their own richer table; nil falls back to just
-- {page_type = active, title = title} -- still real signal (which nav
-- section, what the page is titled), just not entity-specific.
--
-- current_user is merged in here unconditionally (every caller gets
-- it for free, not just the ones that already pass a rich context) --
-- found missing live: the model had no way to know who it was talking
-- to, so it left owner/assignee-style fields blank instead of
-- defaulting to the current user the way a human filling out the same
-- form naturally would.
function html.page_shell(title, active, body, nonce, show_sql, show_admin, has_tasks_view, theme, author, page_context)
    if theme == nil then
        theme = {site_name = "Platform", colors = {}}
    end
    if page_context == nil then
        page_context = {page_type = active, title = title}
    end
    if author != nil then
        page_context.current_user = author
    end
    json = require("dkjson")
    page_context_json = json_for_script(json.encode(page_context))

    root_css = html.theme_root_css(theme)

    -- Icon-rail order: Home, Documents, Data, Tasks, (System if Setup/
    -- Admin). No separate New Document icon -- the document tree's own
    -- "+ New document" button already covers that entry point. Chat has
    -- no rail icon of its own either; it's the floating widget below.
    --
    -- No real nav items at all when nobody's authenticated (author ==
    -- nil, e.g. /login) -- every one of them just bounces back to
    -- /login anyway (found live: the nav rail was fully visible and
    -- clickable on the login page itself after task #89's /login fix
    -- started wrapping it in this same page_shell).
    nav_items = {}
    if author != nil then
        nav_items = {
            {key = "home", href = "/", label = "Home", icon = ICON_HOME},
            {key = "documents", href = "documents", label = "Documents", icon = ICON_NOTEBOOK},
            {key = "data", href = "data", label = "Data", icon = ICON_DATA},
        }
        -- Only a real rail icon when a deployment actually seeded a
        -- "prioritized_tasks" view -- see the matching comment in
        -- render_home (task #101).
        if has_tasks_view == true then
            table.insert(nav_items, {key = "tasks", href = "view?view_name=prioritized_tasks", label = "Tasks", icon = ICON_TASKS})
        end
        if show_sql or show_admin then
            table.insert(nav_items, {key = "system", href = "system", label = "System", icon = ICON_SYSTEM})
        end
    end

    -- Only rendered when the deployment's own theme.lua sets
    -- has_logo = true (a real logo.png is seeded at theme-assets/) --
    -- generic/unconfigured deployments get no logo slot at all rather
    -- than a broken-image icon.
    brand_html = ""
    if theme.has_logo == true then
        brand_html = string.format(
            '<a class="platform-nav-brand" href="/" title="%s"><img src="theme-asset?name=logo.png" alt="%s"></a>',
            html.html_escape(theme.site_name), html.html_escape(theme.site_name)
        )
    end

    nav_links = {}
    for _, item in ipairs(nav_items) do
        link_class = "platform-nav-link"
        if item.key == active then
            link_class = link_class .. " platform-nav-link-active"
        end
        table.insert(nav_links, string.format(
            '<a class="%s" href="%s" title="%s">%s<span class="platform-nav-label">%s</span></a>',
            link_class, item.href, html.html_escape(item.label), item.icon, html.html_escape(item.label)
        ))
    end

    user_box = ""
    if author != nil then
        user_box = string.format("""
<div class="platform-nav-user">
    <div class="platform-nav-user-name">%s</div>
    <a href="logout">Log out</a>
</div>
""", html.html_escape(author))
    end

    -- No chat widget for an unauthenticated page either -- same
    -- reasoning as nav_items above. The backend already rejects an
    -- unauthenticated /chat-start or /chat-message before it ever
    -- reaches the agent/Vertex AI call (cgi.handle_request's own
    -- session check runs first, confirmed live), so this isn't a
    -- billing/security gap by itself -- but showing a chat box nobody
    -- can actually use is confusing UX, and only ever produces a
    -- confusing "error" in the widget (a 302 redirect response its own
    -- JS isn't expecting), not a real conversation.
    chat_widget_html = ""
    if author != nil then
        chat_widget_html = html.render_chat_widget(nonce)
    end

    return string.format("""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<link rel="icon" type="image/png" href="theme-asset?name=favicon.png">
<script nonce="%s">window.PLATFORM_PAGE_CONTEXT = %s;</script>
<style>
%s
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%%; }
body {
    display: flex;
    font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--platform-bg-2, #f1f5f9);
}
.platform-nav {
    width: 72px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 2px;
    padding: 12px 8px;
    background: var(--platform-bg, #ffffff);
    border-right: 1px solid var(--platform-border, #e2e8f0);
    min-height: 100vh;
}
.platform-nav-link {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 12px;
    border-radius: var(--platform-radius-sm, 8px);
    color: var(--platform-th-text, #475569);
    text-decoration: none;
    transition: var(--platform-transition, all 0.15s ease);
}
.platform-nav-link:hover { background: var(--platform-bg-2, #f1f5f9); color: var(--platform-heading, #0f172a); }
.platform-nav-link-active { background: var(--platform-accent, #4f46e5); color: #ffffff; }
.platform-nav-spacer { flex: 1; }
.platform-nav-label {
    position: absolute;
    left: calc(100%% + 8px);
    top: 50%%;
    transform: translateY(-50%%);
    padding: 6px 10px;
    white-space: nowrap;
    background: var(--platform-heading, #1e293b);
    color: #ffffff;
    border-radius: var(--platform-radius-sm, 8px);
    font-size: 0.8rem;
    font-weight: 600;
    opacity: 0;
    visibility: hidden;
    pointer-events: none;
    z-index: 20;
    transition: var(--platform-transition, all 0.15s ease);
}
.platform-nav-link:hover .platform-nav-label, .platform-nav-link:focus .platform-nav-label { opacity: 1; visibility: visible; }
.platform-nav-user {
    padding: 10px 6px;
    border-top: 1px solid var(--platform-border, #e2e8f0);
    text-align: center;
}
.platform-nav-user-name {
    font-size: 0.7rem;
    font-weight: 600;
    color: var(--platform-muted, #64748b);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-bottom: 4px;
}
.platform-nav-user a { font-size: 0.75rem; color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
.platform-nav-user a:hover { text-decoration: underline; }
.platform-nav-brand { display: block; padding: 4px; margin-bottom: 8px; text-align: center; }
.platform-nav-brand img { width: 100%%; max-width: 40px; height: auto; display: block; margin: 0 auto; }
.platform-main { flex: 1; min-width: 0; }
%s
</style>
</head>
<body>
<nav class="platform-nav">
%s
%s
<div class="platform-nav-spacer"></div>
%s
</nav>
<div class="platform-main">
%s
</div>
%s
</body>
</html>
""", html.html_escape(title), nonce, page_context_json, root_css, platform_chat_widget_css(), brand_html, table.concat(nav_links, ""), user_box, body,
     chat_widget_html)
end

-- `nonce` must be Fossil's own per-request CSP nonce (the FOSSIL_NONCE
-- CGI env var Fossil already injects, see doc/architecture.md) --
-- Fossil's page wrapper sets a strict `script-src 'self' 'nonce-...'`
-- CSP, so an inline <script> without the matching nonce is silently
-- blocked by the browser: the page loads, but no JS in it ever runs.
function html.render(entity_type, layout_json, nonce, locked_fields)
    escaped_type = html.html_escape(entity_type)
    if locked_fields == nil then
        locked_fields = {}
    end
    json = require("dkjson")
    locked_fields_json = json.encode(locked_fields)
    return string.format("""
<div class="fossil-doc" data-title="Register %s">
    <style>
%s
        .platform-header {
            margin-bottom: 24px;
            border-bottom: 1px solid var(--platform-bg-2, #f1f5f9);
            padding-bottom: 16px;
        }
        .platform-header h2 {
            margin: 0 0 6px 0;
            font-size: 1.6rem;
            font-weight: 700;
            color: var(--platform-heading, #0f172a);
            letter-spacing: -0.02em;
        }
        .platform-header p {
            color: var(--platform-muted, #64748b);
            margin: 0;
            font-size: 0.95rem;
        }
        .platform-header span.req-dot {
            color: #ef4444;
            font-weight: bold;
        }
        .platform-table-wrapper {
            overflow-x: auto;
            margin-bottom: 24px;
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
            box-shadow: inset 0 2px 4px 0 rgba(0,0,0,0.02);
            background: var(--platform-bg, #f8fafc);
        }
        #registration-table {
            width: 100%%;
            border-collapse: separate;
            border-spacing: 0;
            min-width: 700px;
        }
        #registration-table th, #registration-table td {
            padding: 14px 16px;
            text-align: left;
            border-bottom: 1px solid var(--platform-border, #e2e8f0);
        }
        #registration-table th {
            background: var(--platform-bg-2, #f1f5f9);
            font-weight: 600;
            font-size: 0.8rem;
            color: var(--platform-th-text, #475569);
            text-transform: uppercase;
            letter-spacing: 0.06em;
            border-top: 1px solid var(--platform-border, #e2e8f0);
        }
        #registration-table th:first-child { border-top-left-radius: 10px; }
        #registration-table th:last-child  { border-top-right-radius: 10px; }
        #registration-table td { background: #ffffff; }
        #registration-table tr:last-child td { border-bottom: none; }
        #registration-table tr:last-child td:first-child { border-bottom-left-radius: 10px; }
        #registration-table tr:last-child td:last-child  { border-bottom-right-radius: 10px; }
        #registration-table th.required::after {
            content: " *";
            color: #ef4444;
        }
        .cell-input-wrapper { position: relative; }
        .cell-locked-value {
            display: inline-block;
            padding: 9px 12px;
            font-size: 0.9rem;
            color: var(--platform-muted, #64748b);
            font-style: italic;
        }
        .cell-input {
            width: 100%%;
            padding: 9px 12px;
            border: 1px solid var(--platform-border-2, #cbd5e1);
            border-radius: var(--platform-radius-sm, 8px);
            font-size: 0.9rem;
            background: #ffffff;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            box-sizing: border-box;
            color: var(--platform-input-text, #1e293b);
        }
        .cell-input:focus {
            border-color: var(--platform-accent-2, #6366f1);
            outline: none;
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.12);
            background: #fff;
        }
        .cell-input.error {
            border-color: #f87171;
            background-color: #fef2f2;
            box-shadow: 0 0 0 3px rgba(239, 68, 68, 0.08);
        }
        .error-badge {
            color: #ef4444;
            font-size: 0.75rem;
            margin-top: 4px;
            display: block;
            font-weight: 500;
        }
        .autocomplete-results {
            position: absolute;
            top: 100%%;
            left: 0;
            right: 0;
            background: #ffffff;
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-sm, 8px);
            max-height: 220px;
            overflow-y: auto;
            z-index: 1000;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            margin-top: 6px;
            padding: 4px 0;
        }
        .autocomplete-item {
            padding: 9px 14px;
            cursor: pointer;
            font-size: 0.85rem;
            transition: all 0.15s ease;
            color: var(--platform-text, #334155);
        }
        .autocomplete-item:hover { background: var(--platform-bg-2, #f1f5f9); color: var(--platform-heading, #0f172a); }
        .platform-actions {
            display: flex;
            gap: 14px;
            justify-content: flex-start;
            align-items: center;
        }
        %s
        .status-msg {
            margin-top: 24px;
            padding: 14px 20px;
            border-radius: var(--platform-radius-sm, 8px);
            font-size: 0.95rem;
            display: none;
            font-weight: 500;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.02);
        }
        .status-msg.success {
            display: block;
            background: #f0fdf4;
            color: #166534;
            border: 1px solid #bbf7d0;
            animation: fadeIn 0.25s ease;
        }
        .status-msg.error {
            display: block;
            background: #fef2f2;
            color: #991b1b;
            border: 1px solid #fecaca;
            animation: fadeIn 0.25s ease;
        }
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(4px); }
            to   { opacity: 1; transform: translateY(0); }
        }
    </style>

    <div class="platform-container">
        <div class="platform-header">
            <h2>Register %s</h2>
            <p>Fill out the sheet. Fields marked with <span class="req-dot">*</span> are required.</p>
            <p><a href="browse?type=%s">Browse existing %s entities &rarr;</a></p>
        </div>

        <div class="platform-table-wrapper">
            <table id="registration-table">
                <thead>
                    <tr id="table-headers">
                        <!-- headers dynamically injected -->
                    </tr>
                </thead>
                <tbody id="table-body">
                    <!-- rows dynamically injected -->
                </tbody>
            </table>
        </div>

        <div class="platform-actions">
            <button type="button" class="btn btn-secondary" id="btn-add-row">+ Add Row</button>
            <button type="button" class="btn btn-primary"   id="btn-submit-batch">Submit Batch</button>
        </div>

        <div id="status-message" class="status-msg"></div>
    </div>

    <script nonce="%s">
        const layout = %s;
        const entityType = "%s";
        const lockedFields = %s;
        const baseUrl = window.location.pathname.replace(/\/register\/?$/, "");
        let rowCounter = 0;

        // Reads the non-HttpOnly csrf cookie (set at /login) for the
        // double-submit CSRF check -- see cgi.lua's require_csrf.
        function getCsrfToken() {
            const match = document.cookie.match(/(?:^|;\s*)csrf=([^;]*)/);
            return match ? match[1] : "";
        }

        // Which document this registration table is embedded in, for
        // ledger provenance (source_notebook_entry_id).
        // An explicit ?entry= on this iframe's own src overrides
        // auto-detection via document.referrer (the parent page's URL,
        // set by the browser for a same-origin iframe navigation) --
        // useful when referrer policies strip it, or to label it by
        // something other than a raw URL.
        const urlParams = new URLSearchParams(window.location.search);
        let notebookEntry = urlParams.get("entry");
        if (!notebookEntry && document.referrer) {
            notebookEntry = document.referrer;
        }

        function initTable() {
            const headerRow = document.getElementById("table-headers");
            headerRow.innerHTML = "";

            layout.fields.forEach(field => {
                const th = document.createElement("th");
                th.innerText = field.label;
                if (field.required) { th.classList.add("required"); }
                headerRow.appendChild(th);
            });

            const deleteTh = document.createElement("th");
            deleteTh.style.width = "40px";
            headerRow.appendChild(deleteTh);

            addRow();
        }

        function addRow() {
            rowCounter++;
            const tbody = document.getElementById("table-body");
            const tr = document.createElement("tr");
            tr.id = `row-${rowCounter}`;

            layout.fields.forEach(field => {
                const td = document.createElement("td");
                const wrapper = document.createElement("div");
                wrapper.classList.add("cell-input-wrapper");

                // task #112: a locked field (?lock_<name>=<value>) shows
                // a fixed, read-only display -- e.g. which mixture these
                // ingredients belong to -- plus a same-named hidden
                // input so submitBatch()'s existing
                // querySelector(`[name="..."]`) collection picks up the
                // value with no changes needed there at all.
                const locked = lockedFields[field.name];
                if (locked !== undefined) {
                    const display = document.createElement("span");
                    display.className = "cell-locked-value";
                    display.innerText = locked.label;
                    wrapper.appendChild(display);
                    const hidden = document.createElement("input");
                    hidden.type = "hidden";
                    hidden.name = field.name;
                    hidden.value = locked.value;
                    wrapper.appendChild(hidden);
                    td.appendChild(wrapper);
                    tr.appendChild(td);
                    return;
                }

                let input;
                if (field.type === "select") {
                    input = document.createElement("select");
                    input.classList.add("cell-input");
                    const optEmpty = document.createElement("option");
                    optEmpty.value = "";
                    optEmpty.innerText = "";
                    input.appendChild(optEmpty);
                    field.values.forEach(val => {
                        const opt = document.createElement("option");
                        opt.value = val;
                        opt.innerText = val;
                        input.appendChild(opt);
                    });
                } else if (field.type === "multi_select") {
                    // task #84: a native multi-select listbox -- no new
                    // widget needed, the browser's own ctrl/cmd-click
                    // multi-selection is enough for a fixed value list.
                    input = document.createElement("select");
                    input.classList.add("cell-input");
                    input.multiple = true;
                    field.values.forEach(val => {
                        const opt = document.createElement("option");
                        opt.value = val;
                        opt.innerText = val;
                        input.appendChild(opt);
                    });
                } else if (field.type === "polymorphic_reference" || field.type === "multi_polymorphic_reference") {
                    // The target type itself varies per row (a sample's
                    // source can be a plant or another sample) -- a type
                    // picker alongside the usual search-by-name input,
                    // not a fixed ref_entity_type the way reference/
                    // multi_reference already have one. Submits as
                    // "type:id" (or "type:id, type:id" for the multi
                    // variant) -- schema.normalize_polymorphic_value
                    // parses that same convention from the CLI too.
                    const typeSelect = document.createElement("select");
                    typeSelect.classList.add("cell-input", "cell-source-type");
                    (field.allowed_entity_types || []).forEach(t => {
                        const opt = document.createElement("option");
                        opt.value = t;
                        opt.innerText = t;
                        typeSelect.appendChild(opt);
                    });
                    wrapper.appendChild(typeSelect);

                    input = document.createElement("input");
                    input.classList.add("cell-input");
                    input.type = "text";
                    input.setAttribute("autocomplete", "off");
                    input.placeholder = field.type === "multi_polymorphic_reference" ?
                        "Search ID or name, pick several..." : "Search ID or name...";
                    setupPolymorphicAutocomplete(input, typeSelect, field.type === "multi_polymorphic_reference");
                } else {
                    input = document.createElement("input");
                    input.classList.add("cell-input");
                    if (field.type === "number") {
                        input.type = "number";
                        input.step = "any";
                        // Real bug found in production: with no min/max
                        // set, the native spinner arrows let a value
                        // cycle past any sensible bound (e.g. past 5 on
                        // a 1-5 field) with zero feedback. Both optional
                        // -- a schema author declares them per-field
                        // (see schema.md), platform itself has no opinion
                        // on what range makes sense for a given field.
                        if (field.min !== undefined && field.min !== null) { input.min = field.min; }
                        if (field.max !== undefined && field.max !== null) { input.max = field.max; }
                    } else if (field.type === "date") {
                        input.type = "date";
                    } else {
                        input.type = "text";
                    }
                    if (field.type === "reference") {
                        input.setAttribute("autocomplete", "off");
                        input.placeholder = "Search ID or name...";
                        setupAutocomplete(input, field.ref_entity_type, false);
                    } else if (field.type === "multi_reference") {
                        // task #84: same autocomplete search as a
                        // singular reference field -- picking a
                        // suggestion appends to a comma-separated list
                        // instead of replacing the input's value.
                        input.setAttribute("autocomplete", "off");
                        input.placeholder = "Search ID or name, pick several...";
                        setupAutocomplete(input, field.ref_entity_type, true);
                    }
                }

                input.name = field.name;
                input.addEventListener("input",  () => clearCellError(input));
                input.addEventListener("change", () => clearCellError(input));
                wrapper.appendChild(input);
                td.appendChild(wrapper);
                tr.appendChild(td);
            });

            const deleteTd = document.createElement("td");
            const deleteBtn = document.createElement("button");
            deleteBtn.type = "button";
            deleteBtn.classList.add("btn-delete");
            deleteBtn.innerHTML = "&times;";
            deleteBtn.onclick = () => {
                const rows = tbody.getElementsByTagName("tr");
                if (rows.length > 1) {
                    tr.remove();
                } else {
                    alert("Cannot delete the only row.");
                }
            };
            deleteTd.appendChild(deleteBtn);
            tr.appendChild(deleteTd);
            tbody.appendChild(tr);
        }

        function clearCellError(input) {
            input.classList.remove("error");
            const parent = input.parentElement;
            const existingBadge = parent.querySelector(".error-badge");
            if (existingBadge) { existingBadge.remove(); }
        }

        function highlightError(rowIndex, fieldName, message) {
            const tbody = document.getElementById("table-body");
            const tr = tbody.getElementsByTagName("tr")[rowIndex];
            if (!tr) return;
            const input = tr.querySelector(`[name="${fieldName}"]`);
            if (!input) return;
            input.classList.add("error");
            const parent = input.parentElement;
            let badge = parent.querySelector(".error-badge");
            if (!badge) {
                badge = document.createElement("span");
                badge.classList.add("error-badge");
                parent.appendChild(badge);
            }
            badge.innerText = message;
        }

        function clearAllErrors() {
            document.querySelectorAll(".cell-input").forEach(input => clearCellError(input));
            const msg = document.getElementById("status-message");
            msg.className = "status-msg";
            msg.innerText = "";
            msg.style.display = "none";
        }

        // `multi` (task #84): for a multi_reference field, a picked
        // suggestion appends to a comma-separated list in the input
        // (skipping an id already present) instead of replacing the
        // whole value the way a singular reference field's picker does.
        // The search itself is identical either way -- same endpoint,
        // same debounce, same results dropdown.
        function setupAutocomplete(input, refType, multi) {
            const wrapper = input.parentElement;
            let resultsContainer = null;
            let debounceTimer;

            input.addEventListener("input", () => {
                clearTimeout(debounceTimer);
                const raw = input.value;
                const query = (multi ? raw.split(",").pop() : raw).trim();
                if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
                if (query.length === 0) return;

                debounceTimer = setTimeout(() => {
                    fetch(`${baseUrl}/api/autocomplete?type=${refType}&query=${encodeURIComponent(query)}`)
                        .then(res => res.json())
                        .then(data => {
                            if (resultsContainer) resultsContainer.remove();
                            if (data.length === 0) return;
                            resultsContainer = document.createElement("div");
                            resultsContainer.classList.add("autocomplete-results");
                            data.forEach(item => {
                                const div = document.createElement("div");
                                div.classList.add("autocomplete-item");
                                div.innerText = `[#${item.id}] ${item.name}`;
                                div.onclick = () => {
                                    if (multi) {
                                        const existing = input.value.split(",").map(s => s.trim()).filter(s => s.length > 0);
                                        existing.pop();
                                        if (!existing.includes(String(item.id))) { existing.push(String(item.id)); }
                                        input.value = existing.join(", ") + ", ";
                                    } else {
                                        input.value = item.id;
                                    }
                                    clearCellError(input);
                                    resultsContainer.remove();
                                    resultsContainer = null;
                                };
                                resultsContainer.appendChild(div);
                            });
                            wrapper.appendChild(resultsContainer);
                        })
                        .catch(err => console.error("Autocomplete fetch error", err));
                }, 200);
            });

            document.addEventListener("click", (e) => {
                if (e.target !== input && resultsContainer && !resultsContainer.contains(e.target)) {
                    resultsContainer.remove();
                    resultsContainer = null;
                }
            });
        }

        // Same search/pick UX as setupAutocomplete, but the target type
        // comes from typeSelect's own current value at query/pick time
        // (re-read live, not captured once) instead of one fixed
        // refType -- a polymorphic field's target type is chosen by the
        // user, not declared by the schema. Inserts "type:id", not a
        // bare id, so the submitted value round-trips through
        // schema.normalize_polymorphic_value the same way a hand-typed
        // one would.
        function setupPolymorphicAutocomplete(input, typeSelect, multi) {
            const wrapper = input.parentElement;
            let resultsContainer = null;
            let debounceTimer;

            input.addEventListener("input", () => {
                clearTimeout(debounceTimer);
                const raw = input.value;
                const query = (multi ? raw.split(",").pop() : raw).trim();
                if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
                if (query.length === 0) return;

                debounceTimer = setTimeout(() => {
                    const refType = typeSelect.value;
                    fetch(`${baseUrl}/api/autocomplete?type=${refType}&query=${encodeURIComponent(query)}`)
                        .then(res => res.json())
                        .then(data => {
                            if (resultsContainer) resultsContainer.remove();
                            if (data.length === 0) return;
                            resultsContainer = document.createElement("div");
                            resultsContainer.classList.add("autocomplete-results");
                            data.forEach(item => {
                                const div = document.createElement("div");
                                div.classList.add("autocomplete-item");
                                div.innerText = `[${refType} #${item.id}] ${item.name}`;
                                div.onclick = () => {
                                    const entry = `${refType}:${item.id}`;
                                    if (multi) {
                                        const existing = input.value.split(",").map(s => s.trim()).filter(s => s.length > 0);
                                        existing.pop();
                                        if (!existing.includes(entry)) { existing.push(entry); }
                                        input.value = existing.join(", ") + ", ";
                                    } else {
                                        input.value = entry;
                                    }
                                    clearCellError(input);
                                    resultsContainer.remove();
                                    resultsContainer = null;
                                };
                                resultsContainer.appendChild(div);
                            });
                            wrapper.appendChild(resultsContainer);
                        })
                        .catch(err => console.error("Autocomplete fetch error", err));
                }, 200);
            });

            document.addEventListener("click", (e) => {
                if (e.target !== input && resultsContainer && !resultsContainer.contains(e.target)) {
                    resultsContainer.remove();
                    resultsContainer = null;
                }
            });
        }

        function submitBatch() {
            clearAllErrors();
            const tbody = document.getElementById("table-body");
            const trs = tbody.getElementsByTagName("tr");
            const payload = [];

            for (let i = 0; i < trs.length; i++) {
                const tr = trs[i];
                const rowData = {};
                layout.fields.forEach(field => {
                    const el = tr.querySelector(`[name="${field.name}"]`);
                    if (el) {
                        let val = el.value;
                        if (field.type === "number" && val !== "") { val = parseFloat(val); }
                        // task #84: both multivalue types send a real
                        // JSON array in the payload, not a joined string
                        // -- /api/submit's body is already JSON, so
                        // there's no wire-format reason to flatten one.
                        if (field.type === "multi_select") {
                            val = Array.from(el.selectedOptions).map(o => o.value);
                        } else if (field.type === "multi_reference" || field.type === "multi_polymorphic_reference") {
                            val = val.split(",").map(s => s.trim()).filter(s => s.length > 0);
                        }
                        rowData[field.name] = val;
                    }
                });
                payload.push(rowData);
            }

            const msg = document.getElementById("status-message");
            msg.className = "status-msg";
            msg.innerText = "Validating and submitting...";
            msg.style.display = "block";

            const entryParam = notebookEntry ? `&entry=${encodeURIComponent(notebookEntry)}` : "";
            fetch(`${baseUrl}/api/submit?type=${entityType}${entryParam}`, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-CSRF-Token": getCsrfToken() },
                body: JSON.stringify(payload)
            })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    msg.className = "status-msg success";
                    msg.innerText = `Successfully registered ${data.created_ids.length} entities (IDs: ${data.created_ids.join(", ")}).`;
                    tbody.innerHTML = "";
                    rowCounter = 0;
                    addRow();
                } else {
                    msg.className = "status-msg error";
                    msg.innerText = "Submission failed. Please check highlighted errors in the form.";
                    if (data.issues && data.issues.length > 0) {
                        data.issues.forEach(issue => {
                            highlightError(issue.row_index - 1, issue.field, issue.message);
                        });
                    }
                }
            })
            .catch(err => {
                console.error("Submit error", err);
                msg.className = "status-msg error";
                msg.innerText = "An unexpected error occurred during submission.";
            });
        }

        window.onload = initTable;
        document.getElementById("btn-add-row").addEventListener("click", addRow);
        document.getElementById("btn-submit-batch").addEventListener("click", submitBatch);
    </script>
</div>
""", escaped_type, platform_container_css(1200), platform_button_css(), escaped_type, escaped_type, escaped_type, nonce, json_for_script(layout_json), js_string_literal(entity_type), json_for_script(locked_fields_json))
end

-- Single-row edit form for an existing entity -- the generic-entity
-- counterpart to render_document_edit (documents already had their own
-- edit page; every other entity type had none at all, only /register's
-- create-only sheet and /detail's read-only view). Deliberately a
-- separate function from html.render rather than a "mode" flag on it:
-- that function's whole design (add/delete rows, batch submit) is
-- for bulk entry, and bolting a single prefilled, non-deletable row
-- onto it would tangle two different concerns. Reuses the same
-- per-field-type input rendering (select/multi_select/number/date/
-- reference/multi_reference with autocomplete) since that logic is
-- exactly what's needed here too, just for one row instead of many,
-- submitting to /api/update (already exists, task #93) instead of
-- /api/submit.
function html.render_entity_edit(entity_type, layout_json, row_json, entity_id, nonce)
    escaped_type = html.html_escape(entity_type)
    return string.format("""
<div class="fossil-doc" data-title="Edit %s #%s">
    <style>
%s
%s
        .platform-header { margin-bottom: 24px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; font-size: 0.9rem; }
        .platform-header a:hover { text-decoration: underline; }
        .platform-edit-fields { display: flex; flex-direction: column; gap: 14px; max-width: 640px; }
        .platform-edit-field label { display: block; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--platform-muted, #64748b); font-weight: 600; margin-bottom: 6px; }
        .platform-edit-field label .req-dot { color: #ef4444; font-weight: bold; }
        .platform-edit-field { position: relative; }
        .cell-input {
            width: 100%%; padding: 9px 12px; border: 1px solid var(--platform-border-2, #cbd5e1);
            border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem; background: #ffffff;
            box-sizing: border-box; color: var(--platform-input-text, #1e293b);
        }
        .cell-input.error { border-color: #f87171; background-color: #fef2f2; }
        .error-badge { color: #ef4444; font-size: 0.75rem; margin-top: 4px; display: block; font-weight: 500; }
        .autocomplete-results {
            position: absolute; top: 100%%; left: 0; right: 0; background: #ffffff;
            border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px);
            max-height: 220px; overflow-y: auto; z-index: 1000;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05); margin-top: 6px;
        }
        .autocomplete-results div { padding: 8px 12px; cursor: pointer; font-size: 0.88rem; }
        .autocomplete-results div:hover { background: var(--platform-bg-2, #f1f5f9); }
        .status-msg { display: none; padding: 12px 16px; border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem; margin-top: 16px; max-width: 640px; }
        .status-msg.success { display: block; background: #f0fdf4; color: #166534; border: 1px solid #bbf7d0; }
        .status-msg.error { display: block; background: #fef2f2; color: #991b1b; border: 1px solid #fecaca; }
    </style>

    <div class="platform-container">
        <div class="platform-header">
            <h2>Edit %s #%s</h2>
            <a href="detail?type=%s&entity_id=%s">&larr; Back to detail</a>
        </div>

        <div class="platform-edit-fields" id="edit-fields"><!-- fields injected --></div>

        <div class="platform-actions" style="margin-top: 20px;">
            <button type="button" class="btn btn-primary" id="btn-save">Save changes</button>
        </div>

        <div id="status-message" class="status-msg"></div>
    </div>

    <script nonce="%s">
        const layout = %s;
        const row = %s;
        const entityType = "%s";
        const entityId = %s;
        const baseUrl = window.location.pathname.replace(/\/entity-edit\/?$/, "");

        function getCsrfToken() {
            const match = document.cookie.match(/(?:^|;\s*)csrf=([^;]*)/);
            return match ? match[1] : "";
        }

        function clearCellError(input) {
            input.classList.remove("error");
            const parent = input.parentElement;
            const existingBadge = parent.querySelector(".error-badge");
            if (existingBadge) { existingBadge.remove(); }
        }

        function highlightError(fieldName, message) {
            const input = document.querySelector(`[name="${fieldName}"]`);
            if (!input) return;
            input.classList.add("error");
            const parent = input.parentElement;
            let badge = parent.querySelector(".error-badge");
            if (!badge) {
                badge = document.createElement("span");
                badge.classList.add("error-badge");
                parent.appendChild(badge);
            }
            badge.innerText = message;
        }

        function setupAutocomplete(input, refType, multi) {
            const wrapper = input.parentElement;
            let resultsContainer = null;
            let debounceTimer;
            input.addEventListener("input", () => {
                clearTimeout(debounceTimer);
                const raw = input.value;
                const query = (multi ? raw.split(",").pop() : raw).trim();
                if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
                if (query.length === 0) return;
                debounceTimer = setTimeout(() => {
                    fetch(`${baseUrl}/api/autocomplete?type=${refType}&query=${encodeURIComponent(query)}`)
                        .then(res => res.json())
                        .then(data => {
                            if (resultsContainer) { resultsContainer.remove(); }
                            if (!data || data.length === 0) return;
                            resultsContainer = document.createElement("div");
                            resultsContainer.className = "autocomplete-results";
                            data.forEach(item => {
                                const opt = document.createElement("div");
                                opt.innerText = item.label;
                                opt.addEventListener("mousedown", (e) => {
                                    e.preventDefault();
                                    if (multi) {
                                        const parts = raw.split(",").map(s => s.trim()).filter(s => s.length > 0);
                                        parts.pop();
                                        if (!parts.includes(String(item.id))) { parts.push(String(item.id)); }
                                        input.value = parts.join(", ") + ", ";
                                    } else {
                                        input.value = item.id;
                                    }
                                    resultsContainer.remove();
                                    resultsContainer = null;
                                    input.focus();
                                });
                                resultsContainer.appendChild(opt);
                            });
                            wrapper.appendChild(resultsContainer);
                        });
                }, 200);
            });
            document.addEventListener("click", (e) => {
                if (e.target !== input && resultsContainer && !resultsContainer.contains(e.target)) {
                    resultsContainer.remove();
                    resultsContainer = null;
                }
            });
        }

        // Same search/pick UX as setupAutocomplete, but the target type
        // comes from typeSelect's own current value at query/pick time
        // instead of one fixed refType -- see the /register batch
        // table's own copy of this function for the full reasoning.
        function setupPolymorphicAutocomplete(input, typeSelect, multi) {
            const wrapper = input.parentElement;
            let resultsContainer = null;
            let debounceTimer;
            input.addEventListener("input", () => {
                clearTimeout(debounceTimer);
                const raw = input.value;
                const query = (multi ? raw.split(",").pop() : raw).trim();
                if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
                if (query.length === 0) return;
                debounceTimer = setTimeout(() => {
                    const refType = typeSelect.value;
                    fetch(`${baseUrl}/api/autocomplete?type=${refType}&query=${encodeURIComponent(query)}`)
                        .then(res => res.json())
                        .then(data => {
                            if (resultsContainer) { resultsContainer.remove(); }
                            if (!data || data.length === 0) return;
                            resultsContainer = document.createElement("div");
                            resultsContainer.className = "autocomplete-results";
                            data.forEach(item => {
                                const opt = document.createElement("div");
                                opt.innerText = item.label;
                                opt.addEventListener("mousedown", (e) => {
                                    e.preventDefault();
                                    const entry = `${refType}:${item.id}`;
                                    if (multi) {
                                        const parts = raw.split(",").map(s => s.trim()).filter(s => s.length > 0);
                                        parts.pop();
                                        if (!parts.includes(entry)) { parts.push(entry); }
                                        input.value = parts.join(", ") + ", ";
                                    } else {
                                        input.value = entry;
                                    }
                                    resultsContainer.remove();
                                    resultsContainer = null;
                                    input.focus();
                                });
                                resultsContainer.appendChild(opt);
                            });
                            wrapper.appendChild(resultsContainer);
                        });
                }, 200);
            });
            document.addEventListener("click", (e) => {
                if (e.target !== input && resultsContainer && !resultsContainer.contains(e.target)) {
                    resultsContainer.remove();
                    resultsContainer = null;
                }
            });
        }

        function buildFields() {
            const container = document.getElementById("edit-fields");
            layout.fields.forEach(field => {
                const wrapper = document.createElement("div");
                wrapper.classList.add("platform-edit-field");
                const label = document.createElement("label");
                label.innerHTML = field.label + (field.required ? ' <span class="req-dot">*</span>' : '');
                wrapper.appendChild(label);

                const current = row[field.name];
                let input;
                if (field.type === "select") {
                    input = document.createElement("select");
                    input.classList.add("cell-input");
                    const optEmpty = document.createElement("option");
                    optEmpty.value = ""; optEmpty.innerText = "";
                    input.appendChild(optEmpty);
                    field.values.forEach(val => {
                        const opt = document.createElement("option");
                        opt.value = val; opt.innerText = val;
                        if (current === val) { opt.selected = true; }
                        input.appendChild(opt);
                    });
                } else if (field.type === "multi_select") {
                    input = document.createElement("select");
                    input.classList.add("cell-input");
                    input.multiple = true;
                    const currentList = Array.isArray(current) ? current : [];
                    field.values.forEach(val => {
                        const opt = document.createElement("option");
                        opt.value = val; opt.innerText = val;
                        if (currentList.includes(val)) { opt.selected = true; }
                        input.appendChild(opt);
                    });
                } else if (field.type === "polymorphic_reference" || field.type === "multi_polymorphic_reference") {
                    // Same type-picker + search widget as the /register
                    // batch table's own addRow() -- see that function's
                    // own comment for why a fixed ref_entity_type won't
                    // do here. current is entity.get's own list of
                    // {type=, id=} tables (0 or 1 entries for the
                    // singular variant) -- pre-filled as "type:id" text,
                    // the same convention new entries get typed/picked
                    // in as.
                    const typeSelect = document.createElement("select");
                    typeSelect.classList.add("cell-input", "cell-source-type");
                    (field.allowed_entity_types || []).forEach(t => {
                        const opt = document.createElement("option");
                        opt.value = t; opt.innerText = t;
                        typeSelect.appendChild(opt);
                    });
                    wrapper.appendChild(typeSelect);

                    input = document.createElement("input");
                    input.classList.add("cell-input");
                    input.type = "text";
                    input.setAttribute("autocomplete", "off");
                    input.placeholder = field.type === "multi_polymorphic_reference" ?
                        "Search ID or name, pick several..." : "Search ID or name...";
                    const currentList = Array.isArray(current) ? current : [];
                    if (currentList.length > 0) {
                        input.value = currentList.map(v => `${v.type}:${v.id}`).join(", ") + ", ";
                    }
                    setupPolymorphicAutocomplete(input, typeSelect, field.type === "multi_polymorphic_reference");
                } else {
                    input = document.createElement("input");
                    input.classList.add("cell-input");
                    if (field.type === "number") {
                        input.type = "number"; input.step = "any";
                        if (field.min !== undefined && field.min !== null) { input.min = field.min; }
                        if (field.max !== undefined && field.max !== null) { input.max = field.max; }
                        if (current !== undefined && current !== null) { input.value = current; }
                    } else if (field.type === "date") {
                        input.type = "date";
                        if (current) { input.value = current; }
                    } else if (field.type === "multi_reference") {
                        input.type = "text";
                        input.setAttribute("autocomplete", "off");
                        input.placeholder = "Search ID or name, pick several...";
                        const currentList = Array.isArray(current) ? current : [];
                        if (currentList.length > 0) { input.value = currentList.join(", ") + ", "; }
                        setupAutocomplete(input, field.ref_entity_type, true);
                    } else {
                        input.type = "text";
                        if (current !== undefined && current !== null) { input.value = current; }
                        if (field.type === "reference") {
                            input.setAttribute("autocomplete", "off");
                            input.placeholder = "Search ID or name...";
                            setupAutocomplete(input, field.ref_entity_type, false);
                        }
                    }
                }
                input.name = field.name;
                input.addEventListener("input",  () => clearCellError(input));
                input.addEventListener("change", () => clearCellError(input));
                wrapper.appendChild(input);
                container.appendChild(wrapper);
            });

            const reasonWrapper = document.createElement("div");
            reasonWrapper.classList.add("platform-edit-field");
            const reasonLabel = document.createElement("label");
            reasonLabel.innerText = "Reason for this change (optional unless required)";
            reasonWrapper.appendChild(reasonLabel);
            const reasonInput = document.createElement("input");
            reasonInput.type = "text";
            reasonInput.classList.add("cell-input");
            reasonInput.id = "platform-edit-reason";
            reasonInput.placeholder = "Why is this changing?";
            reasonWrapper.appendChild(reasonInput);
            container.appendChild(reasonWrapper);
        }

        function submitEdit() {
            document.querySelectorAll(".cell-input").forEach(clearCellError);
            const payload = {};
            layout.fields.forEach(field => {
                const el = document.querySelector(`[name="${field.name}"]`);
                if (!el) return;
                let val = el.value;
                if (field.type === "number" && val !== "") { val = parseFloat(val); }
                if (field.type === "multi_select") {
                    val = Array.from(el.selectedOptions).map(o => o.value);
                } else if (field.type === "multi_reference" || field.type === "multi_polymorphic_reference") {
                    val = val.split(",").map(s => s.trim()).filter(s => s.length > 0);
                }
                payload[field.name] = val;
            });

            const msg = document.getElementById("status-message");
            msg.className = "status-msg";
            msg.innerText = "Saving...";
            msg.style.display = "block";

            const reasonEl = document.getElementById("platform-edit-reason");
            const reasonParam = reasonEl.value ? `&reason=${encodeURIComponent(reasonEl.value)}` : "";
            fetch(`${baseUrl}/api/update?type=${entityType}&entity_id=${entityId}${reasonParam}`, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-CSRF-Token": getCsrfToken() },
                body: JSON.stringify(payload)
            })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    window.location.href = `${baseUrl}/detail?type=${entityType}&entity_id=${entityId}`;
                } else {
                    msg.className = "status-msg error";
                    msg.innerText = "Save failed. Please check highlighted errors below.";
                    if (data.issues && data.issues.length > 0) {
                        data.issues.forEach(issue => {
                            if (issue.field) { highlightError(issue.field, issue.message); }
                            else { msg.innerText = issue.message; }
                        });
                    }
                }
            })
            .catch(err => {
                console.error("Save error", err);
                msg.className = "status-msg error";
                msg.innerText = "An unexpected error occurred while saving.";
            });
        }

        buildFields();
        document.getElementById("btn-save").addEventListener("click", submitEdit);
    </script>
</div>
""", escaped_type, tostring(entity_id), platform_container_css(1200), platform_button_css(),
     escaped_type, tostring(entity_id), escaped_type, tostring(entity_id),
     nonce, json_for_script(layout_json), json_for_script(row_json), js_string_literal(entity_type), tostring(entity_id))
end

-- A multivalue field's value (task #84) is a plain Lua array, not a
-- scalar -- both a row's own current value (entity.get attaches it) and
-- a ledger history change's old/new (json-decoded from field_changes).
-- html.html_escape on a raw table would misbehave, so this renders an
-- empty array as the same "&mdash;" a nil/empty scalar gets, and a
-- non-empty one as a comma-joined, individually-escaped list.
function display_value(value)
    if type(value) == "table" then
        if #value == 0 then
            return "&mdash;"
        end
        parts = {}
        for _, item in ipairs(value) do
            if type(item) == "table" and item.type != nil then
                -- A polymorphic-reference item ({type=, id=}) -- same
                -- "table: 0x..." address problem plain tostring(item)
                -- has for entity.lua's format_cli_value/ledger.lua's
                -- format_change_value. Plain text here, not a real
                -- link, matching how a reference/multi_reference
                -- field's own id already just shows as plain unlinked
                -- text in this same ledger-history-diff view today.
                table.insert(parts, html.html_escape(tostring(item.type) .. ":" .. tostring(item.id)))
            else
                table.insert(parts, html.html_escape(tostring(item)))
            end
        end
        return table.concat(parts, ", ")
    end
    if value == nil or tostring(value) == "" then
        return "&mdash;"
    end
    return html.html_escape(value)
end

-- Reference-type field values are a raw entity id -- platform has no
-- general "display name" concept for entities (confirmed directly:
-- entity tables carry no "name" column at all, only whatever fields
-- each schema declares; /browse and /detail already only ever show
-- "#<id>" for the row's own identity too), so this can't resolve to a
-- human-readable name -- it renders the id as a real, styled link to
-- the referenced entity's own detail page instead of a disconnected
-- bare number, matching how the row's own id already links out in
-- render_browse below. The link is relative ("detail...", no leading
-- slash) so it resolves correctly regardless of where this app is
-- mounted -- every route lives at the same top-level directory, so a
-- plain relative reference from any of them reaches any other.
-- Two sources for a human-readable label, tried in priority order:
--   1. The builtin "name" column (schema.lua's BUILTIN_COLUMNS) -- a
--      real name assigned by an external source like Benchling (e.g. a
--      container literally named "50L stainless steel bioreactor").
--      Confirmed live: an importer already fetched this value but only
--      used it transiently for dedup matching, never persisting it --
--      fixed separately, but this is the whole reason the column exists.
--   2. A schema author's own {display = true} field (entity_field.display),
--      for entity types with no such external source at all. A
--      heuristic like "first text field" was considered and rejected: a
--      real schema's first text-type field is often not the one a human
--      would pick (e.g. plant's is "genetic_group", not species/variety).
-- Returns nil (caller falls back to "#id") when neither source has a
-- non-empty value for this row.
--
-- A bare number from source 2 (e.g. "343" for an experiment) reads as
-- ambiguous -- could be mistaken for the id itself -- while a text value
-- is already self-explanatory. Only number-typed display fields get the
-- entity type name prefixed ("experiment 343"); text/select fields, and
-- anything from the builtin name column, are used exactly as they are.
function format_display_label(entity_type, field, raw_value)
    if field.type == "number" then
        return entity_type .. " " .. tostring(raw_value)
    end
    return tostring(raw_value)
end

function html.entity_display_label(db_path, entity_type, entity_id)
    rows = db.query(db_path, string.format(
        "SELECT name FROM %s WHERE id = %s;", entity_type, db.quote(entity_id)
    ))
    if rows != nil and rows[1] != nil and rows[1].name != nil and tostring(rows[1].name) != "" then
        return tostring(rows[1].name)
    end

    fields = schema.fields(db_path, entity_type)
    if fields == nil then
        return nil
    end
    display_field = nil
    for _, f in ipairs(fields) do
        if tonumber(f.display) == 1 then
            display_field = f
            break
        end
    end
    if display_field == nil then
        return nil
    end
    rows = db.query(db_path, string.format(
        "SELECT %s AS label FROM %s WHERE id = %s;",
        display_field.name, entity_type, db.quote(entity_id)
    ))
    if rows == nil or rows[1] == nil or rows[1].label == nil or tostring(rows[1].label) == "" then
        return nil
    end
    return format_display_label(entity_type, display_field, rows[1].label)
end

-- Same two-source priority as entity_display_label, but for a row this
-- page already has fully loaded -- no second query needed for either
-- source, just reading row.name and (if empty) a schema.fields() lookup.
function html.own_row_label(db_path, entity_type, row)
    if row.name != nil and tostring(row.name) != "" then
        return tostring(row.name)
    end

    fields = schema.fields(db_path, entity_type)
    if fields == nil then
        return nil
    end
    for _, f in ipairs(fields) do
        if tonumber(f.display) == 1 then
            value = row[f.name]
            if value != nil and tostring(value) != "" then
                return format_display_label(entity_type, f, value)
            end
            return nil
        end
    end
    return nil
end

function render_reference_value(db_path, ref_entity_type, value)
    if value == nil or tostring(value) == "" then
        return "&mdash;"
    end
    escaped_type = html.html_escape(ref_entity_type)
    escaped_id = html.html_escape(tostring(value))
    link_text = "#" .. escaped_id
    label = html.entity_display_label(db_path, ref_entity_type, value)
    if label != nil then
        link_text = html.html_escape(label)
    end
    -- Hover reveals a preview of the referenced row (fetched lazily via
    -- /api/preview, see cgi.lua) rather than making every reference
    -- column a guessing game of "click through and come back" -- the
    -- same popover mechanism (html.popover_css()/popover_js()) used for
    -- Data-index row counts, here in its lazy-fetch form since
    -- precomputing every row's preview server-side would be wasteful.
    preview_src = "api/preview?type=" .. escaped_type .. "&entity_id=" .. escaped_id
    return "<a href=\"detail?type=" .. escaped_type .. "&entity_id=" .. escaped_id ..
        "\" class=\"platform-entity-ref platform-popover-trigger\" data-platform-popover-src=\"" .. preview_src ..
        "\" tabindex=\"0\">" .. link_text .. "<span class=\"platform-popover\"></span></a>"
end

-- Every linked entity in a multi_reference field's value, each rendered
-- exactly like a real singular reference field (same popover-preview
-- link) and comma-joined -- not a plain id list, since these are just
-- as much real links to another row as a singular reference field's
-- value is.
function render_multi_reference_value(db_path, ref_entity_type, values)
    if values == nil or #values == 0 then
        return "&mdash;"
    end
    parts = {}
    for _, v in ipairs(values) do
        table.insert(parts, render_reference_value(db_path, ref_entity_type, v))
    end
    return table.concat(parts, ", ")
end

-- A polymorphic field's value (entity.get/schema.read_polymorphic_field
-- always return a plain list of {type=, id=} tables, whether the field
-- is the singular polymorphic_reference or the plural
-- multi_polymorphic_reference variant -- 0 or 1 items either way for
-- the singular case) -- each item already carries its own real target
-- type, so render_reference_value (a real link + hover preview,
-- exactly like a plain reference field gets) just needs calling once
-- per item with that item's own type, not one fixed type for the
-- whole field the way multi_reference's own renderer assumes.
function render_polymorphic_reference_value(db_path, values)
    if values == nil or #values == 0 then
        return "&mdash;"
    end
    parts = {}
    for _, v in ipairs(values) do
        table.insert(parts, render_reference_value(db_path, v.type, v.id))
    end
    return table.concat(parts, ", ")
end

-- Picks the right renderer for a field's value, given its schema.layout()
-- metadata (type + ref_entity_type, when type=="reference"/"multi_reference").
-- Namespaced under html. (not a bare global like most of this file's own
-- render_* helpers) specifically so cgi.lua's handle_preview can call it
-- too -- a bare global declared here isn't reachable from another
-- required file's own scope even though the build bundles everything
-- into one binary (see entity.apply_computed_field_overrides' own
-- comment for the same gotcha, hit twice this session).
function html.display_field_value(db_path, field, value)
    if field.type == "reference" and field.ref_entity_type != nil then
        return render_reference_value(db_path, field.ref_entity_type, value)
    end
    if field.type == "multi_reference" then
        ref_type = field.ref_entity_type
        if ref_type == nil then
            return display_value(value)
        end
        return render_multi_reference_value(db_path, ref_type, value)
    end
    if field.type == "polymorphic_reference" or field.type == "multi_polymorphic_reference" then
        return render_polymorphic_reference_value(db_path, value)
    end
    return display_value(value)
end

-- Browse view: a read-only table of every entity of a type, linking to
-- each one's detail page. Pure server-rendered HTML -- no JS, so none
-- of the CSP/nonce concerns the registration table's client-side JS
-- has (see html.render's header comment for why that one needs one).
function html.render_browse(db_path, entity_type, layout, rows, page, page_size, total, nonce, filter_field, filter_value)
    if nonce == nil then
        nonce = ""
    end
    escaped_type = html.html_escape(entity_type)

    -- task #112: preserves an active ?filter_field=&filter_value=
    -- across Prev/Next -- otherwise paging past page 1 on a filtered
    -- view (e.g. "this mixture's ingredients") would silently drop
    -- back to the unfiltered list.
    filter_query_suffix = ""
    if filter_field != nil then
        filter_query_suffix = "&filter_field=" .. html.html_escape(filter_field) .. "&filter_value=" .. html.html_escape(tostring(filter_value))
    end

    header_cells = "<th>ID</th>"
    for _, field in ipairs(layout.fields) do
        header_cells = header_cells .. "<th>" .. html.html_escape(field.label) .. "</th>"
    end

    body_rows = ""
    for _, row in ipairs(rows) do
        own_label = html.own_row_label(db_path, entity_type, row)
        id_link_text = "#" .. tostring(row.id)
        if own_label != nil then
            id_link_text = html.html_escape(own_label)
        end
        cells = "<td><a href=\"detail?type=" .. escaped_type .. "&entity_id=" .. tostring(row.id) ..
            "\">" .. id_link_text .. "</a></td>"
        for _, field in ipairs(layout.fields) do
            cells = cells .. "<td>" .. html.display_field_value(db_path, field, row[field.name]) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end

    table_or_empty = "<div class=\"platform-table-wrapper\"><table id=\"browse-table\"><thead><tr>" ..
        header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
    if #rows == 0 then
        table_or_empty = "<p class=\"platform-empty\">No " .. escaped_type .. " entities registered yet.</p>"
    end

    pager = ""
    if total > page_size then
        last_page = math.ceil(total / page_size)
        range_start = ((page - 1) * page_size) + 1
        range_end = range_start + #rows - 1
        pager = "<div class=\"platform-pager\">"
        pager = pager .. "<span>Showing " .. tostring(range_start) .. "-" .. tostring(range_end) ..
            " of " .. tostring(total) .. "</span>"
        pager = pager .. "<span class=\"platform-pager-links\">"
        if page > 1 then
            pager = pager .. "<a href=\"browse?type=" .. escaped_type .. "&page=" .. tostring(page - 1) .. filter_query_suffix .. "\">&laquo; Prev</a>"
        end
        pager = pager .. "<span>Page " .. tostring(page) .. " of " .. tostring(last_page) .. "</span>"
        if page < last_page then
            pager = pager .. "<a href=\"browse?type=" .. escaped_type .. "&page=" .. tostring(page + 1) .. filter_query_suffix .. "\">Next &raquo;</a>"
        end
        pager = pager .. "</span></div>"
    end

    return string.format("""
<div class="fossil-doc" data-title="Browse %s">
    <style>
%s
        .platform-header {
            margin-bottom: 24px;
            border-bottom: 1px solid var(--platform-bg-2, #f1f5f9);
            padding-bottom: 16px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-header a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-header a:hover { text-decoration: underline; }
        %s
        .platform-table-wrapper {
            overflow-x: auto;
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
            background: var(--platform-bg, #f8fafc);
        }
        #browse-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        #browse-table th, #browse-table td {
            padding: 12px 16px;
            text-align: left;
            border-bottom: 1px solid var(--platform-border, #e2e8f0);
            font-size: 0.9rem;
        }
        #browse-table th {
            background: var(--platform-bg-2, #f1f5f9);
            font-weight: 600;
            font-size: 0.78rem;
            color: var(--platform-th-text, #475569);
            text-transform: uppercase;
            letter-spacing: 0.06em;
        }
        #browse-table td { background: #ffffff; }
        #browse-table a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        #browse-table a:hover { text-decoration: underline; }
        .platform-empty {
            padding: 32px;
            text-align: center;
            color: var(--platform-muted, #64748b);
            background: var(--platform-bg, #f8fafc);
            border: 1px dashed var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
        .platform-pager {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-top: 16px;
            font-size: 0.85rem;
            color: var(--platform-muted, #64748b);
        }
        .platform-pager-links { display: flex; gap: 14px; align-items: center; }
        .platform-pager-links a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-pager-links a:hover { text-decoration: underline; }
        .platform-entity-ref { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-entity-ref::after { content: " \2197"; font-size: 0.85em; }
        .platform-entity-ref:hover { text-decoration: underline; }
    </style>
    %s
    <div class="platform-container">
        <div class="platform-header">
            <div>
                <h2>Browse %s</h2>
                <p>%d registered</p>
            </div>
            <a class="btn btn-primary" href="register?type=%s">+ New %s</a>
        </div>
        %s
        %s
    </div>
</div>
%s
""", escaped_type, platform_container_css(1200), platform_button_css(), html.popover_css(), escaped_type, total, escaped_type, escaped_type, table_or_empty, pager, html.popover_js(nonce))
end

-- Real bug found while extracting platform_container_css above, unrelated
-- to that refactor: the args list here previously started with
-- `html.popover_css()` where the FIRST %s in the template
-- (`data-title="Browse %s"`) actually is -- meaning every /browse page's
-- data-title (which Fossil's own doc.c reads to set the real page
-- title, confirmed directly in fossil-scm's source) rendered as raw CSS
-- text instead of "Browse <type>". The visible <h2> heading used a
-- *different*, correctly-positioned escaped_type and was always fine --
-- an easy thing to miss since the page looked completely normal, only
-- the browser tab title was ever wrong. Fixed above by reordering the
-- args to match where each %s actually is.

-- Detail view: current field values plus the full ledger history for
-- one entity. Also pure server-rendered HTML, no JS.
function html.render_detail(db_path, entity_type, layout, row, history, nonce, has_label_template, related)
    if nonce == nil then
        nonce = ""
    end
    escaped_type = html.html_escape(entity_type)
    id_str = tostring(row.id)
    own_label = html.own_row_label(db_path, entity_type, row)
    title_id_part = "#" .. id_str
    if own_label != nil then
        title_id_part = html.html_escape(own_label) .. " (#" .. id_str .. ")"
    end

    edit_link = "<a class=\"btn btn-secondary\" href=\"entity-edit?type=" .. escaped_type .. "&entity_id=" .. id_str .. "\">Edit</a>"

    print_label_html = ""
    print_label_js_block = ""
    if has_label_template == true then
        print_label_html = label_print_button_html()
        print_label_js_block = string.format("<script src=\"vendor?name=BrowserPrint-3.0.216.min.js\" nonce=\"%s\"></script>", nonce) ..
            label_print_js(nonce, entity_type, id_str)
    end

    fields_html = ""
    for _, field in ipairs(layout.fields) do
        fields_html = fields_html .. "<div class=\"detail-row\"><span class=\"detail-label\">" ..
            html.html_escape(field.label) .. "</span><span class=\"detail-value\">" ..
            html.display_field_value(db_path, field, row[field.name]) .. "</span></div>"
    end

    related_html = related_records_html(db_path, related, row.id)

    history_rows = ""
    for _, event in ipairs(history) do
        changes = ""
        if event.reason != nil and event.reason != "" then
            changes = changes .. "<div class=\"change-item change-reason\"><em>Reason: " ..
                html.html_escape(event.reason) .. "</em></div>"
        end
        for field_name, change in pairs(event.field_changes) do
            changes = changes .. "<div class=\"change-item\"><strong>" .. html.html_escape(field_name) ..
                "</strong>: " .. display_value(change.old) .. " &rarr; " .. display_value(change.new) .. "</div>"
        end
        history_rows = history_rows .. "<tr><td>#" .. tostring(event.event_id) .. "</td><td>" ..
            html.html_escape(event.event_type) .. "</td><td>" .. display_value(event.author) .. "</td><td>" ..
            html.html_escape(event.created_at) .. "</td><td>" .. changes .. "</td></tr>"
    end

    return string.format("""
<div class="fossil-doc" data-title="%s %s">
    <style>
%s
        .platform-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; font-size: 0.9rem; }
        .platform-header a:hover { text-decoration: underline; }
        .platform-header-actions { display: flex; align-items: center; gap: 12px; }
        .platform-subheading { font-size: 1.05rem; color: var(--platform-heading, #0f172a); margin: 28px 0 14px 0; }
        .platform-detail-fields {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
            gap: 16px 24px;
            padding: 20px;
            background: var(--platform-bg, #f8fafc);
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
        .detail-row { display: flex; flex-direction: column; gap: 4px; }
        .detail-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--platform-muted, #64748b); font-weight: 600; }
        .detail-value { font-size: 0.95rem; color: var(--platform-heading, #0f172a); word-break: break-word; }
        .platform-table-wrapper { overflow-x: auto; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        #history-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 700px; }
        #history-table th, #history-table td {
            padding: 12px 16px;
            text-align: left;
            border-bottom: 1px solid var(--platform-border, #e2e8f0);
            font-size: 0.85rem;
            vertical-align: top;
        }
        #history-table th {
            background: var(--platform-bg-2, #f1f5f9);
            font-weight: 600;
            font-size: 0.75rem;
            color: var(--platform-th-text, #475569);
            text-transform: uppercase;
            letter-spacing: 0.06em;
        }
        #history-table td { background: #ffffff; }
        .change-item { margin-bottom: 4px; }
        .change-item:last-child { margin-bottom: 0; }
        .platform-entity-ref { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-entity-ref::after { content: " \2197"; font-size: 0.85em; }
        .platform-entity-ref:hover { text-decoration: underline; }
        .platform-print-label { display: inline-flex; align-items: center; gap: 8px; margin-left: 16px; }
        .platform-print-label select { padding: 6px 10px; border-radius: var(--platform-radius-sm, 8px); border: 1px solid var(--platform-border, #e2e8f0); }
        #platform-print-label-status { font-size: 0.85rem; color: var(--platform-muted, #64748b); }
        #platform-print-label-status.platform-admin-message-error { color: #991b1b; }
        .platform-related { display: flex; flex-direction: column; gap: 16px; }
        .platform-related-group {
            padding: 16px 20px;
            background: var(--platform-bg, #f8fafc);
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
        .platform-related-group h4 { margin: 0 0 10px 0; font-size: 0.95rem; color: var(--platform-heading, #0f172a); }
        .platform-related-group ul { margin: 0 0 10px 0; padding-left: 20px; }
        .platform-related-group li { font-size: 0.9rem; margin-bottom: 4px; }
        .platform-related-actions { display: flex; gap: 16px; font-size: 0.85rem; }
        .platform-related-empty { color: var(--platform-muted, #64748b); font-style: italic; font-size: 0.9rem; margin: 0 0 10px 0; }
    </style>
    %s
    <div class="platform-container">
        <div class="platform-header">
            <div>
                <h2>%s %s</h2>
                <a href="browse?type=%s">&larr; Back to browse</a>
            </div>
            <div class="platform-header-actions">
                %s
                %s
            </div>
        </div>

        <div class="platform-detail-fields">
            %s
        </div>

        %s

        <h3 class="platform-subheading">Ledger history</h3>
        <div class="platform-table-wrapper">
            <table id="history-table">
                <thead><tr><th>Event</th><th>Type</th><th>Author</th><th>When</th><th>Changes</th></tr></thead>
                <tbody>%s</tbody>
            </table>
        </div>
    </div>
</div>
%s
%s
""", escaped_type, title_id_part, platform_container_css(1200), html.popover_css(), escaped_type, title_id_part, escaped_type, edit_link, print_label_html, fields_html, related_html, history_rows, html.popover_js(nonce), print_label_js_block)
end

-- task #112: "Related records" -- every real, plain `reference` field
-- elsewhere that points back at this row (e.g. ingredient.mixture ->
-- this mixture), computed generically by cgi.lua's related_records
-- (schema.relationships(), not specific to any one pair of types).
-- `related` is a list of {from_type, field_name, total, rows} (rows
-- already capped to cgi.lua's RELATED_RECORDS_PREVIEW_LIMIT); empty
-- list means this entity_type has no reverse references at all, not
-- rendered.
function related_records_html(db_path, related, entity_id)
    if related == nil or #related == 0 then
        return ""
    end
    groups_html = ""
    for _, group in ipairs(related) do
        escaped_from = html.html_escape(group.from_type)
        escaped_field = html.html_escape(group.field_name)
        rows_html = ""
        for _, r in ipairs(group.rows) do
            own_label = html.own_row_label(db_path, group.from_type, r)
            link_text = "#" .. tostring(r.id)
            if own_label != nil then
                link_text = html.html_escape(own_label) .. " (#" .. tostring(r.id) .. ")"
            end
            rows_html = rows_html .. "<li><a href=\"detail?type=" .. escaped_from .. "&entity_id=" .. tostring(r.id) .. "\">" .. link_text .. "</a></li>"
        end
        if rows_html == "" then
            rows_html = "<p class=\"platform-related-empty\">None yet.</p>"
        else
            rows_html = "<ul>" .. rows_html .. "</ul>"
        end

        view_all = ""
        if group.total > #group.rows then
            view_all = "<a href=\"browse?type=" .. escaped_from .. "&filter_field=" .. escaped_field ..
                "&filter_value=" .. tostring(entity_id) .. "\">View all " .. tostring(group.total) .. "</a>"
        end
        add_link = "<a href=\"register?type=" .. escaped_from .. "&lock_" .. escaped_field .. "=" .. tostring(entity_id) ..
            "\">+ Add " .. escaped_from .. "</a>"

        groups_html = groups_html .. "<div class=\"platform-related-group\"><h4>" .. escaped_from .. " (" ..
            tostring(group.total) .. ")</h4>" .. rows_html .. "<div class=\"platform-related-actions\">" ..
            add_link .. view_all .. "</div></div>"
    end
    return "<h3 class=\"platform-subheading\">Related records</h3><div class=\"platform-related\">" .. groups_html .. "</div>"
end

-- task #73: markup for the print-label control, only ever emitted when
-- a label_template row exists for this entity_type (has_label_template,
-- computed by cgi.lua's /detail route -- see label.has_template).
function label_print_button_html()
    return """
<div class="platform-print-label">
    <select id="platform-label-printer"></select>
    <button type="button" id="platform-print-label-btn" class="btn btn-secondary">Print Label</button>
    <span id="platform-print-label-status"></span>
</div>
"""
end

-- Discovers local Zebra printers via the vendored Browser Print SDK
-- (loaded separately, see render_detail) and sends this entity's
-- rendered ZPL (fetched from /label, task #73) to whichever one is
-- selected. `nonce` must be Fossil's own per-request CSP nonce (see
-- html.popover_js's own comment) since this emits an inline <script>.
function label_print_js(nonce, entity_type, entity_id)
    return string.format("""
<script nonce="%s">
(function(){
    var select = document.getElementById('platform-label-printer');
    var btn = document.getElementById('platform-print-label-btn');
    var status = document.getElementById('platform-print-label-status');
    var devices = [];

    function showStatus(msg, isError){
        status.textContent = msg;
        status.className = isError ? 'platform-admin-message-error' : '';
    }

    if(typeof BrowserPrint === 'undefined'){
        showStatus('Zebra Browser Print not detected -- install it from zebra.com/us/en/support-downloads/software/printer-setup-utilities/browser-print.html and reload this page.', true);
        btn.disabled = true;
        return;
    }

    BrowserPrint.getLocalDevices(function(deviceList){
        devices = deviceList || [];
        select.innerHTML = '';
        if(devices.length === 0){
            showStatus('No local Zebra printers found.', true);
            btn.disabled = true;
            return;
        }
        devices.forEach(function(d, i){
            var opt = document.createElement('option');
            opt.value = i;
            opt.textContent = d.name;
            select.appendChild(opt);
        });
    }, function(){
        showStatus('Could not reach Zebra Browser Print -- is the app running?', true);
        btn.disabled = true;
    }, 'printer');

    btn.addEventListener('click', function(){
        var device = devices[parseInt(select.value, 10)];
        if(!device){ showStatus('No printer selected.', true); return; }
        showStatus('Printing...', false);
        fetch('label?type=%s&entity_id=%s').then(function(resp){
            if(!resp.ok){ throw new Error('label render failed'); }
            return resp.text();
        }).then(function(zpl){
            device.send(zpl, function(){
                showStatus('Sent to ' + device.name + '.', false);
            }, function(err){
                showStatus('Print failed: ' + err, true);
            });
        }).catch(function(){
            showStatus('Could not fetch label content.', true);
        });
    });
})();
</script>
""", nonce, entity_type, entity_id)
end

-- Generic view: any approved custom SQL view rendered as a table.
-- Unlike browse/detail, columns come from the view's own declared
-- `columns` list (name/label), not a schema -- a view can join/select
-- across entity types, so there's no single schema to draw from.
-- Just the <table>/empty-state markup for a view's result rows -- no
-- title/subtitle/page chrome. Shared by render_view (the standalone
-- /view page) and html.expand_inline_views (a view embedded inline in
-- document content) so cell-rendering logic (including display_value)
-- lives in exactly one place. Uses a class, not an id, since a single
-- document can embed more than one view -- an id would collide.
function html.render_view_table(view_def, rows)
    header_cells = ""
    for _, col in ipairs(view_def.columns) do
        label = col.label
        if label == nil then
            label = col.name
        end
        header_cells = header_cells .. "<th>" .. html.html_escape(label) .. "</th>"
    end

    body_rows = ""
    for _, row in ipairs(rows) do
        cells = ""
        for _, col in ipairs(view_def.columns) do
            cells = cells .. "<td>" .. display_value(row[col.name]) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end

    if #rows == 0 then
        return "<p class=\"platform-empty\">No rows.</p>"
    end
    return "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
        header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
end

function html.render_view(view_def, rows, param_value)
    title = view_def.title
    if title == nil then
        title = view_def.name
    end
    escaped_title = html.html_escape(title)

    subtitle = tostring(#rows) .. " rows"
    if view_def.param != nil then
        subtitle = subtitle .. " -- filtered by " .. html.html_escape(view_def.param.name) ..
            " = " .. html.html_escape(tostring(param_value))
    end

    table_or_empty = html.render_view_table(view_def, rows)

    -- A view has no schema of its own to register against (it can join
    -- across entity types, see the function comment above) -- but a
    -- view whose author declares a single `entity_type` it's primarily
    -- about (e.g. a prioritized/filtered list over one real entity type)
    -- can still offer the same "+ Register new" entry point
    -- render_browse already has, instead of leaving read-only views as a
    -- dead end with no way to add the row they're meant to be tracking.
    register_link = ""
    if view_def.entity_type != nil then
        escaped_entity_type = html.html_escape(view_def.entity_type)
        register_link = string.format(
            "<a class=\"btn btn-primary\" href=\"register?type=%s\">+ New %s</a>",
            escaped_entity_type, escaped_entity_type
        )
    end

    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
        .platform-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-table-wrapper { overflow-x: auto; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        .platform-view-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        .platform-view-table th, .platform-view-table td { padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.9rem; }
        .platform-view-table th {
            background: var(--platform-bg-2, #f1f5f9);
            font-weight: 600;
            font-size: 0.78rem;
            color: var(--platform-th-text, #475569);
            text-transform: uppercase;
            letter-spacing: 0.06em;
        }
        .platform-view-table td { background: #ffffff; }
        .platform-empty {
            padding: 32px;
            text-align: center;
            color: var(--platform-muted, #64748b);
            background: var(--platform-bg, #f8fafc);
            border: 1px dashed var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <div>
                <h2>%s</h2>
                <p>%s</p>
            </div>
            %s
        </div>
        %s
    </div>
</div>
""", escaped_title, platform_container_css(1200), escaped_title, subtitle, register_link, table_or_empty)
end

-- Expands `{{view:view_name:123}}` markers in already-rendered document
-- HTML into a real, live inline table -- a document embeds an existing
-- parameterized view (e.g. "samples for this experiment") instead of
-- just linking out to /view. Deliberately a THIRD, unrelated `{{ }}`
-- convention in this codebase (render.lua's `{{ expr }}` templating,
-- label.lua's `{{column_name}}` ZPL substitution are the other two) --
-- no collision risk, neither of those patterns has a colon in it and
-- neither ever runs on document content.
--
-- Runs as a post-processing pass over document.render_html's *output*,
-- not injected into the markdown pre-processing chain -- `{{view:...}}`
-- has no CommonMark meaning, so cmark-gfm already passes it through as
-- inert literal text, fully intact, by the time this runs.
--
-- Numeric-only param value (every real view.param.type in this
-- codebase is "integer") -- a malformed marker (e.g. a non-numeric
-- value) just fails to match and passes through unexpanded, rather
-- than reaching view.run and depending on its own error path.
--
-- An unapproved view renders nothing at all, not a placeholder message
-- -- a document may be read by more roles than whoever manages view
-- approvals, and even naming the view in a "not approved" message
-- would leak its existence/state, exactly what the approval gate
-- exists to prevent. A genuine error (missing view file, query
-- failure) gets the same terse empty-state markup render_view itself
-- uses -- an authoring mistake worth surfacing, not a trust boundary.
function html.expand_inline_views(db_path, content)
    return (string.gsub(content, "{{view:([%w_]+):(%d+)}}", function(view_name, param_value)
        view_def, err = view.load(config.views_dir(), view_name)
        if view_def == nil then
            return "{{view:" .. view_name .. ":" .. param_value .. "}}"
        end
        if view.is_approved(db_path, view_def) == false then
            return ""
        end
        rows, run_err = view.run(db_path, view_def, tonumber(param_value))
        if rows == nil then
            return "<p class=\"platform-empty\">Error running view '" .. html.html_escape(view_name) .. "'.</p>"
        end
        return html.render_view_table(view_def, rows)
    end))
end

-- ERD box geometry (task #86) -- fixed width rather than measured text,
-- since computing real SVG text metrics server-side isn't available;
-- 200px comfortably fits "some_field_name : multi_reference", the
-- longest realistic name:type pair in this codebase's own schemas.
DIAGRAM_BOX_WIDTH = 200
DIAGRAM_HEADER_HEIGHT = 26
DIAGRAM_ROW_HEIGHT = 18
DIAGRAM_COLUMN_GAP = 70
DIAGRAM_ROW_GAP = 34
DIAGRAM_PADDING = 40

-- One row per real field (schema.fields()) plus a synthetic leading
-- `id` row -- every entity has one, but it's a builtin column, never
-- itself an entity_field row, so it has to be added here to match how
-- a real ERD always shows the primary key.
function diagram_box_rows(db_path, entity_type)
    rows = {{name = "id", type_label = "integer", is_pk = true, required = true}}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        table.insert(rows, {
            name = field.name, type_label = field.type, is_pk = false,
            required = (tonumber(field.required) == 1)
        })
    end
    return rows
end

-- A specific row's vertical center, box-relative.
function diagram_row_center_y(box, row_index)
    return box.y + DIAGRAM_HEADER_HEIGHT + (row_index - 1) * DIAGRAM_ROW_HEIGHT + (DIAGRAM_ROW_HEIGHT / 2)
end

-- Renders `entity_types`/`edges` (schema.relationships()'s output) as an
-- inline SVG ERD, dbdiagram.io-inspired: each entity type is a box
-- listing its real fields (name : type, PK/required marked), and each
-- reference/multi_reference edge connects the *specific* referencing
-- field's row to the target type's `id` row, labeled with cardinality
-- (`1`/`*`) -- not bare type-to-type lines. Layout is a simple packed
-- grid (shortest-column-first, like a masonry layout), not a physics
-- simulation: box heights vary with field count, so a uniform circle/
-- grid would waste space or crowd; this stays a deterministic, single-
-- pass computation, same "server computes positions, client only does
-- hover/click" split the previous circular layout already used.
function html.render_relation_diagram(db_path, entity_types, edges)
    n = #entity_types
    if n == 0 then
        return "<p class=\"platform-empty\">No entity types registered yet.</p>"
    end

    index_by_name = {}
    for i, row in ipairs(entity_types) do
        index_by_name[row.name] = i
    end

    -- Precompute every box's real rows + height up front (needed both
    -- for layout packing below and for locating a specific field's row
    -- when drawing edges).
    boxes = {}
    for i, row in ipairs(entity_types) do
        box_rows = diagram_box_rows(db_path, row.name)
        row_index_by_field = {}
        for j, box_row in ipairs(box_rows) do
            row_index_by_field[box_row.name] = j
        end
        boxes[i] = {
            name = row.name, rows = box_rows, row_index_by_field = row_index_by_field,
            width = DIAGRAM_BOX_WIDTH,
            height = DIAGRAM_HEADER_HEIGHT + (#box_rows * DIAGRAM_ROW_HEIGHT)
        }
    end

    -- Shortest-column-first packing: each box goes into whichever
    -- column currently has the smallest accumulated height, keeping
    -- the overall layout roughly square without a real force-directed
    -- solver.
    columns = math.ceil(math.sqrt(n))
    column_height = {}
    for c = 1, columns do
        column_height[c] = DIAGRAM_PADDING
    end
    max_height = DIAGRAM_PADDING
    for i = 1, n do
        target_col = 1
        for c = 2, columns do
            if column_height[c] < column_height[target_col] then
                target_col = c
            end
        end
        boxes[i].x = DIAGRAM_PADDING + (target_col - 1) * (DIAGRAM_BOX_WIDTH + DIAGRAM_COLUMN_GAP)
        boxes[i].y = column_height[target_col]
        column_height[target_col] = column_height[target_col] + boxes[i].height + DIAGRAM_ROW_GAP
        if column_height[target_col] > max_height then
            max_height = column_height[target_col]
        end
    end
    total_width = DIAGRAM_PADDING * 2 + columns * DIAGRAM_BOX_WIDTH + (columns - 1) * DIAGRAM_COLUMN_GAP
    total_height = max_height + DIAGRAM_PADDING

    edges_svg = ""
    for _, edge in ipairs(edges) do
        from_i = index_by_name[edge.from_type]
        to_i = index_by_name[edge.to_type]
        if from_i != nil and to_i != nil and from_i != to_i then
            from_box = boxes[from_i]
            to_box = boxes[to_i]
            from_row_index = from_box.row_index_by_field[edge.field_name]
            if from_row_index != nil then
                to_row_index = to_box.row_index_by_field["id"]
                from_y = diagram_row_center_y(from_box, from_row_index)
                to_y = diagram_row_center_y(to_box, to_row_index)
                -- Pre-declared, not just assigned inside the branches
                -- below -- Luam requires a variable's first assignment
                -- to happen before an if/else block if it's referenced
                -- after it (same rule hit earlier in cgi.lua's /browse
                -- route).
                from_x = nil
                to_x = nil
                -- Connect whichever sides actually face each other --
                -- otherwise a target box positioned to the *left* of
                -- its source would draw a line crossing clean through
                -- both boxes instead of approaching from the near side.
                if to_box.x >= from_box.x then
                    from_x = from_box.x + from_box.width
                    to_x = to_box.x
                else
                    from_x = from_box.x
                    to_x = to_box.x + to_box.width
                end
                to_label = "1"
                from_label = "*"
                if edge.field_type == "multi_reference" then
                    from_label = "*"
                    to_label = "*"
                end
                label_dx = 14
                if to_x < from_x then
                    label_dx = -14
                end
                edges_svg = edges_svg .. string.format(
                    "<g class=\"platform-diagram-edge\" data-from=\"%s\" data-to=\"%s\">" ..
                    "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\"></line>" ..
                    "<text class=\"platform-diagram-card\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                    "<text class=\"platform-diagram-card\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                    "</g>",
                    html.html_escape(edge.from_type), html.html_escape(edge.to_type),
                    from_x, from_y, to_x, to_y,
                    from_x + label_dx, from_y - 4, from_label,
                    to_x - label_dx, to_y - 4, to_label
                )
            end
        end
    end

    boxes_svg = ""
    for i, row in ipairs(entity_types) do
        box = boxes[i]
        escaped_name = html.html_escape(row.name)
        rows_svg = ""
        for j, box_row in ipairs(box.rows) do
            row_y = box.y + DIAGRAM_HEADER_HEIGHT + (j - 1) * DIAGRAM_ROW_HEIGHT
            name_class = "platform-diagram-row-name"
            if box_row.is_pk then
                name_class = name_class .. " platform-diagram-row-pk"
            elseif box_row.required then
                name_class = name_class .. " platform-diagram-row-required"
            end
            rows_svg = rows_svg .. string.format(
                "<text class=\"%s\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                "<text class=\"platform-diagram-row-type\" x=\"%.1f\" y=\"%.1f\">%s</text>",
                name_class, box.x + 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html.html_escape(box_row.name),
                box.x + box.width - 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html.html_escape(box_row.type_label)
            )
        end
        boxes_svg = boxes_svg .. string.format(
            "<g class=\"platform-diagram-node\" data-entity-type=\"%s\" tabindex=\"0\">" ..
            "<rect class=\"platform-diagram-box\" x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\"></rect>" ..
            "<rect class=\"platform-diagram-box-header\" x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%d\"></rect>" ..
            "<text class=\"platform-diagram-box-title\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
            "%s" ..
            "</g>",
            escaped_name, box.x, box.y, box.width, box.height,
            box.x, box.y, box.width, DIAGRAM_HEADER_HEIGHT,
            box.x + box.width / 2, box.y + DIAGRAM_HEADER_HEIGHT - 8, escaped_name,
            rows_svg
        )
    end

    return string.format("""
<div class="platform-diagram-hint">Hover an entity to see its relations; click its header to browse it.</div>
<div class="platform-diagram-scroll">
<svg id="platform-diagram-svg" viewBox="0 0 %d %d" width="%d" height="%d">
    %s
    %s
</svg>
</div>
""", total_width, total_height, total_width, total_height, edges_svg, boxes_svg)
end

function html.relation_diagram_css()
    return """
        .platform-diagram-hint { color: var(--platform-muted, #64748b); font-size: 0.85rem; margin-bottom: 10px; }
        .platform-diagram-scroll { overflow: auto; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        .platform-diagram-edge line { stroke: var(--platform-border, #cbd5e1); stroke-width: 1.5; transition: stroke 0.15s ease, opacity 0.15s ease; }
        .platform-diagram-edge.platform-diagram-edge-active line { stroke: var(--platform-accent, #4f46e5); stroke-width: 2.5; }
        .platform-diagram-edge.platform-diagram-edge-dim { opacity: 0.15; }
        .platform-diagram-card { font-size: 11px; font-weight: 700; fill: var(--platform-muted, #64748b); }
        .platform-diagram-edge.platform-diagram-edge-active .platform-diagram-card { fill: var(--platform-accent, #4f46e5); }
        .platform-diagram-box { fill: var(--platform-bg, #ffffff); stroke: var(--platform-border, #cbd5e1); stroke-width: 1.5; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-diagram-box-header { fill: var(--platform-accent, #4f46e5); }
        .platform-diagram-box-title { font-size: 12px; font-weight: 700; text-anchor: middle; fill: #ffffff; text-transform: capitalize; }
        .platform-diagram-row-name { font-size: 11px; fill: var(--platform-text, #334155); }
        .platform-diagram-row-name.platform-diagram-row-pk { font-weight: 700; text-decoration: underline; fill: var(--platform-heading, #0f172a); }
        .platform-diagram-row-name.platform-diagram-row-required { font-weight: 700; }
        .platform-diagram-row-type { font-size: 10px; fill: var(--platform-muted, #94a3b8); text-anchor: end; }
        .platform-diagram-node { cursor: pointer; }
        .platform-diagram-node:hover .platform-diagram-box, .platform-diagram-node:focus .platform-diagram-box { stroke: var(--platform-accent, #4f46e5); stroke-width: 2.5; }
        .platform-diagram-node.platform-diagram-node-dim { opacity: 0.25; }
"""
end

-- `nonce` must be Fossil's own per-request CSP nonce, same requirement
-- as html.popover_js.
function html.diagram_js(nonce)
    if nonce == nil then
        nonce = ""
    end
    return string.format("""
<script nonce="%s">
(function(){
    var toggle = document.getElementById('platform-view-toggle');
    var listView = document.getElementById('platform-view-list');
    var diagramView = document.getElementById('platform-view-diagram');
    if(toggle && listView && diagramView){
        toggle.querySelectorAll('button').forEach(function(btn){
            btn.addEventListener('click', function(){
                var view = btn.getAttribute('data-view');
                listView.style.display = (view === 'list') ? '' : 'none';
                diagramView.style.display = (view === 'diagram') ? '' : 'none';
                toggle.querySelectorAll('button').forEach(function(b){
                    b.classList.toggle('platform-view-active', b === btn);
                });
            });
        });
    }

    var hideEmpty = document.getElementById('platform-hide-empty');
    if(hideEmpty && listView){
        hideEmpty.addEventListener('change', function(){
            listView.querySelectorAll('li[data-count]').forEach(function(li){
                var isEmpty = li.getAttribute('data-count') === '0';
                li.style.display = (hideEmpty.checked && isEmpty) ? 'none' : '';
            });
        });
    }

    var svg = document.getElementById('platform-diagram-svg');
    if(!svg) return;
    var nodes = svg.querySelectorAll('.platform-diagram-node');
    var edges = svg.querySelectorAll('.platform-diagram-edge');
    function related(a, b){
        var isRelated = false;
        edges.forEach(function(edge){
            var from = edge.getAttribute('data-from'), to = edge.getAttribute('data-to');
            if((from === a && to === b) || (from === b && to === a)){ isRelated = true; }
        });
        return isRelated;
    }
    nodes.forEach(function(node){
        var type = node.getAttribute('data-entity-type');
        function highlight(){
            edges.forEach(function(edge){
                if(edge.getAttribute('data-from') === type || edge.getAttribute('data-to') === type){
                    edge.classList.add('platform-diagram-edge-active');
                }else{
                    edge.classList.add('platform-diagram-edge-dim');
                }
            });
            nodes.forEach(function(other){
                var otherType = other.getAttribute('data-entity-type');
                if(otherType != type && !related(type, otherType)){
                    other.classList.add('platform-diagram-node-dim');
                }
            });
        }
        function clear(){
            edges.forEach(function(edge){ edge.classList.remove('platform-diagram-edge-active', 'platform-diagram-edge-dim'); });
            nodes.forEach(function(other){ other.classList.remove('platform-diagram-node-dim'); });
        }
        node.addEventListener('mouseenter', highlight);
        node.addEventListener('focus', highlight);
        node.addEventListener('mouseleave', clear);
        node.addEventListener('blur', clear);
        node.addEventListener('click', function(){
            window.location.href = 'browse?type=' + encodeURIComponent(type);
        });
        node.addEventListener('keydown', function(e){
            if(e.key === 'Enter' || e.key === ' '){
                e.preventDefault();
                window.location.href = 'browse?type=' + encodeURIComponent(type);
            }
        });
    });
})();
</script>
""", nonce)
end

-- platform's own landing page: every registered entity type, linking to
-- its browse view, plus a toggle to an interactive entity-relation
-- diagram (html.render_relation_diagram) built from the same reference
-- fields entity.lua/schema.lua already track -- same page/URL, just a
-- second view of the same data, per the "toggle next to the list"
-- design call rather than a separate route. This is the page a
-- deployment's Fossil "mainmenu" entry (see doc/deployment.md) should
-- point at, so there's a real entry point into platform beyond knowing a
-- /browse?type=... URL by hand.
-- Unauthenticated -- no popover/autocomplete JS needed, so unlike
-- every other render_* page here, no nonce-gated <script> at all.
function html.render_login(error_message, nonce)
    -- render.lua demo: autoescapes error_message by construction rather
    -- than relying on remembering to call html.html_escape here.
    render_lib = require("render")

    error_html = ""
    if error_message != nil and error_message != "" then
        error_html = render_lib.render(
            "<div class=\"platform-login-error\">{{ error_message }}</div>",
            {error_message = error_message}
        )
    end

    return string.format("""
<div class="fossil-doc" data-title="Log in">
    <style>
%s
%s
        .platform-login-card { max-width: 360px; margin: 60px auto; padding: 28px; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-login-card h2 { margin: 0 0 18px 0; font-size: 1.4rem; font-weight: 700; color: var(--platform-heading, #0f172a); }
        .platform-login-card label { display: block; margin-bottom: 4px; font-size: 0.88rem; color: var(--platform-muted, #64748b); }
        .platform-login-card input[type=text], .platform-login-card input[type=password] {
            width: 100%%; box-sizing: border-box; padding: 8px 10px; margin-bottom: 14px;
            border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); font-size: 0.95rem;
        }
        .platform-login-error { color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-item, 10px); padding: 10px 12px; margin-bottom: 14px; font-size: 0.88rem; }
        .platform-login-card .btn { width: 100%%; }
    </style>
    <form class="platform-login-card" method="POST" action="/login">
        <h2>Log in</h2>
        %s
        <label for="login">Login</label>
        <input type="text" id="login" name="login" autocomplete="username" required>
        <label for="password">Password</label>
        <input type="password" id="password" name="password" autocomplete="current-password" required>
        <button type="submit" class="btn btn-primary">Log in</button>
    </form>
</div>
""", platform_container_css(800), platform_button_css(), error_html)
end

-- Minimal admin-only user management page -- Admin ("a") capability
-- only, gated in cgi.lua, not exposed via the normal nav. Each row
-- gets its own small forms (capabilities, password, archive/unarchive)
-- rather than one big multi-field form, so a mistake in one row's
-- inputs can't clobber another's. `csrf_token` is echoed as a hidden
-- field in every form here -- a plain HTML <form> POST (unlike the
-- JS fetch() calls elsewhere in this app) has no way to attach a
-- custom request header, so the double-submit token has to travel as
-- form data instead (see cgi.lua's require_csrf).
function html.render_admin_users(users, csrf_token, message, is_error)
    escaped_csrf = html.html_escape(csrf_token)

    message_html = ""
    if message != nil and message != "" then
        css_class = "platform-admin-message"
        if is_error == true then
            css_class = "platform-admin-message platform-admin-message-error"
        end
        message_html = "<div class=\"" .. css_class .. "\">" .. html.html_escape(message) .. "</div>"
    end

    rows_html = ""
    for _, u in ipairs(users) do
        escaped_login = html.html_escape(u.login)
        status = "active"
        if u.archived_at != nil and u.archived_at != "" then
            status = "archived"
        end
        archive_action = "archive"
        archive_label = "Archive"
        archive_button_class = "btn-danger"
        if status == "archived" then
            archive_action = "unarchive"
            archive_label = "Unarchive"
            archive_button_class = "btn-secondary"
        end

        rows_html = rows_html .. string.format("""
        <tr>
            <td>%s</td>
            <td>
                <form method="POST" action="admin-users-capabilities" class="platform-admin-inline-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="hidden" name="login" value="%s">
                    <input type="text" name="cap" value="%s" size="6">
                    <button type="submit" class="btn btn-secondary">Set</button>
                </form>
            </td>
            <td>%s</td>
            <td>
                <form method="POST" action="admin-users-password" class="platform-admin-inline-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="hidden" name="login" value="%s">
                    <input type="password" name="password" placeholder="new password" required>
                    <button type="submit" class="btn btn-secondary">Set</button>
                </form>
                <form method="POST" action="admin-users-%s" class="platform-admin-inline-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="hidden" name="login" value="%s">
                    <button type="submit" class="btn %s">%s</button>
                </form>
            </td>
        </tr>
""", escaped_login, escaped_csrf, escaped_login, html.html_escape(u.cap), status,
     escaped_csrf, escaped_login, archive_action, escaped_csrf, escaped_login, archive_button_class, archive_label)
    end

    return string.format("""
<div class="fossil-doc" data-title="Manage users">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-admin-message { padding: 10px 12px; margin-bottom: 16px; border-radius: var(--platform-radius-item, 10px); background: #f0fdf4; border: 1px solid #bbf7d0; color: #166534; font-size: 0.9rem; }
        .platform-admin-message-error { background: #fef2f2; border-color: #fecaca; color: #991b1b; }
        .platform-admin-create-form { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 24px; padding: 16px; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-admin-create-form input[type=text], .platform-admin-create-form input[type=password] {
            padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem;
        }
        table.platform-admin-users { width: 100%%; border-collapse: collapse; }
        table.platform-admin-users th, table.platform-admin-users td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.9rem; vertical-align: middle; }
        .platform-admin-inline-form { display: inline-flex; gap: 6px; align-items: center; margin-right: 8px; }
        .platform-admin-inline-form input[type=text], .platform-admin-inline-form input[type=password] {
            padding: 6px 8px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.85rem;
        }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Manage users</h2>
        </div>
        %s
        <form method="POST" action="admin-users-create" class="platform-admin-create-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="text" name="login" placeholder="login" required>
            <input type="password" name="password" placeholder="password" required>
            <input type="text" name="cap" placeholder="capabilities (e.g. i)" size="10">
            <button type="submit" class="btn btn-primary">Create user</button>
        </form>
        <table class="platform-admin-users">
            <thead><tr><th>Login</th><th>Capabilities</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
%s
            </tbody>
        </table>
    </div>
</div>
""", platform_container_css(1000), platform_button_css(), message_html, escaped_csrf, rows_html)
end

-- Admin UI for task #114's api_key table, mirroring render_admin_users
-- exactly. `new_raw_key` is only ever set immediately after a
-- successful create -- the raw key is never stored, so this is the one
-- and only time it can be shown; it's rendered in its own prominent,
-- one-time banner rather than folded into `message`.
function html.render_admin_api_keys(keys, csrf_token, message, is_error, new_raw_key)
    escaped_csrf = html.html_escape(csrf_token)

    message_html = ""
    if message != nil and message != "" then
        css_class = "platform-admin-message"
        if is_error == true then
            css_class = "platform-admin-message platform-admin-message-error"
        end
        message_html = "<div class=\"" .. css_class .. "\">" .. html.html_escape(message) .. "</div>"
    end

    new_key_html = ""
    if new_raw_key != nil and new_raw_key != "" then
        new_key_html = string.format("""
        <div class="platform-admin-message platform-admin-new-key">
            <strong>Save this key now -- it cannot be shown again:</strong>
            <code>%s</code>
        </div>
""", html.html_escape(new_raw_key))
    end

    rows_html = ""
    for _, k in ipairs(keys) do
        escaped_label = html.html_escape(k.label)
        status = "active"
        if k.archived_at != nil and k.archived_at != "" then
            status = "archived"
        end
        archive_action = "archive"
        archive_label = "Archive"
        archive_button_class = "btn-danger"
        if status == "archived" then
            archive_action = "unarchive"
            archive_label = "Unarchive"
            archive_button_class = "btn-secondary"
        end

        rows_html = rows_html .. string.format("""
        <tr>
            <td>%s</td>
            <td>
                <form method="POST" action="admin-api-keys-capabilities" class="platform-admin-inline-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="hidden" name="label" value="%s">
                    <input type="text" name="cap" value="%s" size="6">
                    <button type="submit" class="btn btn-secondary">Set</button>
                </form>
            </td>
            <td>%s</td>
            <td>
                <form method="POST" action="admin-api-keys-%s" class="platform-admin-inline-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="hidden" name="label" value="%s">
                    <button type="submit" class="btn %s">%s</button>
                </form>
            </td>
        </tr>
""", escaped_label, escaped_csrf, escaped_label, html.html_escape(k.cap), status,
     archive_action, escaped_csrf, escaped_label, archive_button_class, archive_label)
    end

    return string.format("""
<div class="fossil-doc" data-title="Manage API keys">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-admin-message { padding: 10px 12px; margin-bottom: 16px; border-radius: var(--platform-radius-item, 10px); background: #f0fdf4; border: 1px solid #bbf7d0; color: #166534; font-size: 0.9rem; }
        .platform-admin-message-error { background: #fef2f2; border-color: #fecaca; color: #991b1b; }
        .platform-admin-new-key code { display: inline-block; margin-left: 8px; padding: 2px 8px; background: #fff; border: 1px solid #bbf7d0; border-radius: 6px; font-size: 0.9rem; }
        .platform-admin-create-form { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 24px; padding: 16px; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-admin-create-form input[type=text] {
            padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem;
        }
        table.platform-admin-users { width: 100%%; border-collapse: collapse; }
        table.platform-admin-users th, table.platform-admin-users td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.9rem; vertical-align: middle; }
        .platform-admin-inline-form { display: inline-flex; gap: 6px; align-items: center; margin-right: 8px; }
        .platform-admin-inline-form input[type=text] {
            padding: 6px 8px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.85rem;
        }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Manage API keys</h2>
        </div>
        %s
        %s
        <form method="POST" action="admin-api-keys-create" class="platform-admin-create-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="text" name="label" placeholder="label (e.g. nightly sync job)" required>
            <input type="text" name="cap" placeholder="capabilities (e.g. i)" size="10">
            <button type="submit" class="btn btn-primary">Create key</button>
        </form>
        <table class="platform-admin-users">
            <thead><tr><th>Label</th><th>Capabilities</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
%s
            </tbody>
        </table>
    </div>
</div>
""", platform_container_css(1000), platform_button_css(), message_html, new_key_html, escaped_csrf, rows_html)
end

-- Settings (task #89): a real UI for theme.lua's own fields, instead
-- of hand-editing the file and redeploying. Covers every field
-- config.load_theme/save_theme round-trip -- site_name, the color
-- overrides, hide_home_heading, system_prompt_extra, and logo/favicon
-- uploads. Deliberately NOT env-var-driven config (DB backend, agent
-- provider/model, Vertex project/region): those are process-bootstrap
-- values read once at CGI-process start, not something safe to change
-- from inside a running request.
function html.render_settings(theme, csrf_token, message, is_error)
    escaped_csrf = html.html_escape(csrf_token)

    message_html = ""
    if message != nil and message != "" then
        css_class = "platform-admin-message"
        if is_error == true then
            css_class = "platform-admin-message platform-admin-message-error"
        end
        message_html = "<div class=\"" .. css_class .. "\">" .. html.html_escape(message) .. "</div>"
    end

    hide_heading_checked = ""
    if theme.hide_home_heading == true then
        hide_heading_checked = " checked"
    end

    system_prompt_extra_value = ""
    if theme.system_prompt_extra != nil then
        system_prompt_extra_value = theme.system_prompt_extra
    end

    color_rows = ""
    for _, key in ipairs(THEME_COLOR_KEYS) do
        value = ""
        if theme.colors != nil and theme.colors[key] != nil then
            value = theme.colors[key]
        end
        label = string.gsub(key, "_", " ")
        color_rows = color_rows .. string.format("""
            <div class="platform-settings-color">
                <label for="color_%s">%s</label>
                <input type="text" id="color_%s" name="color_%s" value="%s" placeholder="e.g. #4f46e5" size="12">
            </div>
""", key, html.html_escape(label), key, key, html.html_escape(value))
    end

    logo_status = "No logo uploaded -- the sidebar shows the default icon and \"Platform\" as plain text."
    if theme.has_logo == true then
        logo_status = "A logo is set. Uploading a new file below replaces it; there is no separate \"remove\" action today -- redeploy tooling or a direct theme-assets/ edit still handles removal."
    end

    return string.format("""
<div class="fossil-doc" data-title="Settings">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-admin-message { padding: 10px 12px; margin-bottom: 16px; border-radius: var(--platform-radius-item, 10px); background: #f0fdf4; border: 1px solid #bbf7d0; color: #166534; font-size: 0.9rem; }
        .platform-admin-message-error { background: #fef2f2; border-color: #fecaca; color: #991b1b; }
        .platform-settings-section { margin-bottom: 28px; padding: 16px; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-settings-section h3 { margin: 0 0 12px 0; font-size: 1.05rem; }
        .platform-settings-section label { display: block; font-size: 0.85rem; color: var(--platform-muted, #64748b); margin-bottom: 4px; }
        .platform-settings-section input[type=text], .platform-settings-section textarea, .platform-settings-section input[type=file] {
            width: 100%%; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem; margin-bottom: 14px;
        }
        .platform-settings-section textarea { min-height: 90px; font-family: inherit; }
        .platform-settings-checkbox { display: flex; align-items: center; gap: 8px; margin-bottom: 14px; }
        .platform-settings-checkbox label { margin-bottom: 0; }
        .platform-settings-colors { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 10px 16px; }
        .platform-settings-color label { text-transform: capitalize; }
        .platform-settings-color input { margin-bottom: 0; }
    </style>
    <div class="platform-container">
        <div class="platform-header"><h2>Settings</h2></div>
        %s
        <form method="POST" action="settings-save" enctype="multipart/form-data">
            <input type="hidden" name="csrf_token" value="%s">

            <div class="platform-settings-section">
                <h3>Site</h3>
                <label for="site_name">Site name</label>
                <input type="text" id="site_name" name="site_name" value="%s" placeholder="Platform">

                <div class="platform-settings-checkbox">
                    <input type="checkbox" id="hide_home_heading" name="hide_home_heading" value="1"%s>
                    <label for="hide_home_heading">Hide the site name heading on Home (use when the logo already reads as a wordmark)</label>
                </div>
            </div>

            <div class="platform-settings-section">
                <h3>Branding</h3>
                <p style="margin-top:0;color:var(--platform-muted,#64748b);font-size:0.9rem;">%s</p>
                <label for="logo_file">Sidebar mark (square, theme-assets/logo.png)</label>
                <input type="file" id="logo_file" name="logo_file" accept="image/png">
                <label for="logo_full_file">Full wordmark shown on Home (theme-assets/logo-full.png)</label>
                <input type="file" id="logo_full_file" name="logo_full_file" accept="image/png">
                <label for="favicon_file">Favicon (theme-assets/favicon.png)</label>
                <input type="file" id="favicon_file" name="favicon_file" accept="image/png">
            </div>

            <div class="platform-settings-section">
                <h3>Colors</h3>
                <p style="margin-top:0;color:var(--platform-muted,#64748b);font-size:0.9rem;">Leave any field blank to use the default indigo/slate palette for that color.</p>
                <div class="platform-settings-colors">
%s
                </div>
            </div>

            <div class="platform-settings-section">
                <h3>Chat assistant</h3>
                <label for="system_prompt_extra">Extra system prompt instructions</label>
                <textarea id="system_prompt_extra" name="system_prompt_extra" placeholder="e.g. This deployment tracks bioreactor runs -- always ask for the run ID before creating a sample.">%s</textarea>
            </div>

            <button type="submit" class="btn btn-primary">Save settings</button>
        </form>
    </div>
</div>
""", platform_container_css(900), platform_button_css(), message_html, escaped_csrf,
     html.html_escape(theme.site_name), hide_heading_checked, html.html_escape(logo_status),
     color_rows, html.html_escape(system_prompt_extra_value))
end

-- v1 landing page: basic information and quick links, deliberately
-- not an activity dashboard (working lists, a calendar, recent-entries
-- feed) yet -- a real starting point, not the end state. `theme` is
-- config.load_theme(root)'s return value, purely for site_name; no
-- other Celleste-specific content belongs here (see theme.lua's own
-- split from platform-wip).
function html.render_home(theme, show_sql, show_admin, has_tasks_view)
    site_name = "Platform"
    has_logo = false
    hide_home_heading = false
    if theme != nil then
        site_name = theme.site_name
        has_logo = theme.has_logo == true
        hide_home_heading = theme.hide_home_heading == true
    end

    -- Full wordmark, distinct from the sidebar's small square mark
    -- (theme-assets/logo.png) -- same has_logo gate, so a generic/
    -- unconfigured deployment gets neither rather than a broken image.
    logo_html = ""
    if has_logo then
        logo_html = string.format(
            '<img class="platform-home-logo" src="theme-asset?name=logo-full.png" alt="%s">',
            html.html_escape(site_name)
        )
    end

    -- hide_home_heading is for a deployment whose logo already reads as
    -- a wordmark (the name is IN the image) -- a plain text <h2> repeating
    -- the same name right underneath is redundant, not a platform-wide
    -- default. Ignored (heading always shows) when there's no logo to
    -- stand in for it -- a page with neither would just look empty.
    heading_html = ""
    if not (hide_home_heading and has_logo) then
        heading_html = "<h2>" .. html.html_escape(site_name) .. "</h2>"
    end

    system_link = ""
    if show_sql or show_admin then
        system_link = "<li><a href=\"system\">System</a><p>Admin, SQL console, and templates.</p></li>"
    end

    -- Only a real link when a deployment actually seeded a
    -- "prioritized_tasks" view -- a fresh/generic install has no
    -- views/ at all, so this used to be a nav item that 404'd on
    -- "cannot open view: ./views/prioritized_tasks.lua" (task #101).
    tasks_link = ""
    if has_tasks_view == true then
        tasks_link = "<li><a href=\"view?view_name=prioritized_tasks\">Tasks</a><p>Open tasks, ranked by priority.</p></li>"
    end

    return string.format("""
<div class="fossil-doc" data-title="Home">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-home-logo { display: block; max-width: 240px; height: auto; margin-bottom: 16px; }
        .platform-sitemap { list-style: none !important; margin: 16px 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
        .platform-sitemap li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 16px 18px; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-sitemap li:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-sitemap a { font-weight: 700; color: var(--platform-accent, #4f46e5); text-decoration: none; font-size: 1.05rem; }
        .platform-sitemap a:hover { text-decoration: underline; }
        .platform-sitemap p { margin: 6px 0 0 0; color: var(--platform-muted, #64748b); font-size: 0.9rem; }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            %s
            %s
            <p>Welcome back. Use the sidebar to get around, or jump in below.</p>
        </div>
        <ul class="platform-sitemap">
            <li><a href="document-edit">New Document</a><p>Write a new document from scratch.</p></li>
            <li><a href="documents">Documents</a><p>Browse all documents, organized as a tree.</p></li>
            <li><a href="data">Data</a><p>Registered entity types, row counts, and relations.</p></li>
            %s
            %s
        </ul>
    </div>
</div>
""", platform_container_css(1200), logo_html, heading_html, tasks_link, system_link)
end

-- Landing page for Setup/Admin-only tooling -- a single destination
-- rather than SQL/Users/Templates each getting their own top-level nav
-- icon, matching this deployment's earlier "System" concept. Callers
-- (cgi.lua) already gate the route itself on show_sql/show_admin
-- before rendering this; the links below still only show what the
-- caller says is allowed via its own show_sql/show_admin parameters.
function html.render_system(show_sql, show_admin)
    items = "<li><a href=\"knowledge\">Knowledge Pool</a><p>Tiered notes, retrieval activity, and chat sessions.</p></li>"
    if show_sql then
        items = items .. "<li><a href=\"sql\">SQL console</a><p>Run ad hoc, read-only queries.</p></li>"
    end
    if show_admin then
        items = items .. "<li><a href=\"admin-users\">Users</a><p>Manage accounts and capabilities.</p></li>"
        items = items .. "<li><a href=\"admin-api-keys\">API keys</a><p>Manage external-integration API keys.</p></li>"
        items = items .. "<li><a href=\"settings\">Settings</a><p>Site name, branding, colors, and chat prompt.</p></li>"
    end
    items = items .. "<li><a href=\"templates\">Templates</a><p>Reusable entry templates for new documents.</p></li>"

    return string.format("""
<div class="fossil-doc" data-title="System">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-sitemap { list-style: none !important; margin: 16px 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
        .platform-sitemap li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 16px 18px; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-sitemap li:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-sitemap a { font-weight: 700; color: var(--platform-accent, #4f46e5); text-decoration: none; font-size: 1.05rem; }
        .platform-sitemap a:hover { text-decoration: underline; }
        .platform-sitemap p { margin: 6px 0 0 0; color: var(--platform-muted, #64748b); font-size: 0.9rem; }
    </style>
    <div class="platform-container">
        <div class="platform-header"><h2>System</h2></div>
        <ul class="platform-sitemap">
%s
        </ul>
    </div>
</div>
""", platform_container_css(1200), items)
end

-- Content-maturity ladder (see document.promotion_target_tier's own
-- comment for the real mechanism): a document only advances once it's
-- actually been revised, and the tier it lands in depends on the shape
-- that revision produced -- not on how often it's been retrieved.
KNOWLEDGE_TIER_LABELS = {
    [0] = "Tier 0: Raw Intake",
    [1] = "Tier 1: Curated Draft",
    [2] = "Tier 2: Developed Reference",
    [3] = "Tier 3: Atomic Record",
}

-- Plain-language criterion for each tier, shown under its label on
-- /knowledge -- closes the "no explanation exists anywhere" gap: the
-- names alone don't communicate that promotion depends on real editing,
-- not just retrieval count.
KNOWLEDGE_TIER_CAPTIONS = {
    [0] = "Captured, not yet worked on.",
    [1] = "Lightly edited -- summarized or cleaned up.",
    [2] = "Fully developed -- multi-section, covers a nuanced subject.",
    [3] = "Short, single-subject, distilled to one idea.",
}

-- Landing page for src/knowledge.lua's tiering/retrieval-logging
-- system (see that module's own header) -- linked from System, not
-- given its own sidebar icon; chat session browsing lives at /chat,
-- linked from here rather than a dedicated nav-rail entry.
function html.render_knowledge_pool(stats, recent_retrievals)
    tier_tiles = ""
    for tier = 0, 3 do
        tier_tiles = tier_tiles .. string.format(
            '<div class="platform-knowledge-tier"><strong>%s</strong><span class="dimmed">%d note(s)</span>' ..
            '<p class="platform-knowledge-tier-caption">%s</p></div>',
            html.html_escape(KNOWLEDGE_TIER_LABELS[tier]), stats.tier_counts[tier],
            html.html_escape(KNOWLEDGE_TIER_CAPTIONS[tier])
        )
    end

    retrieval_rows = ""
    for _, r in ipairs(recent_retrievals) do
        retrieval_rows = retrieval_rows .. string.format(
            '<div class="platform-knowledge-retrieval"><strong>#%s</strong> %s <span class="dimmed">[%s, %s hit(s)]</span></div>',
            tostring(r.id), html.html_escape(r.query_text), html.html_escape(r.created_at), tostring(r.hit_count)
        )
    end
    if retrieval_rows == "" then
        retrieval_rows = '<p class="dimmed">No retrievals yet.</p>'
    end

    return string.format("""
<div class="fossil-doc" data-title="Knowledge Pool">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-knowledge-stats { display: grid; grid-template-columns: repeat(4, minmax(10em, 1fr)); gap: 14px; margin-bottom: 20px; }
        .platform-knowledge-stats div { border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; background: var(--platform-bg, #f8fafc); }
        .platform-knowledge-stats strong { display: block; font-size: 1.4rem; color: var(--platform-heading, #0f172a); }
        .platform-knowledge-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 20px; }
        .platform-knowledge-tiers { display: grid; grid-template-columns: repeat(2, minmax(14em, 1fr)); gap: 12px; }
        .platform-knowledge-tier { border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 12px 14px; background: var(--platform-bg, #f8fafc); }
        .platform-knowledge-tier strong { display: block; margin-bottom: 4px; }
        .platform-knowledge-tier-caption { margin: 6px 0 0 0; font-size: 0.82rem; color: var(--platform-muted, #64748b); }
        .platform-knowledge-panel { border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; background: var(--platform-bg, #f8fafc); margin-bottom: 14px; }
        .platform-knowledge-panel h4 { margin: 0 0 10px 0; font-size: 0.95rem; color: var(--platform-muted, #64748b); }
        .platform-knowledge-retrieval { margin: 6px 0; font-size: 0.9rem; }
        .dimmed { color: var(--platform-muted, #64748b); font-size: 0.85rem; }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Knowledge Pool</h2>
            <p>Notes promote through processing tiers as they're retrieved and reinforced; every retrieval is logged.</p>
        </div>
        <div class="platform-knowledge-stats">
            <div><strong>%d</strong><span class="dimmed">pool records</span></div>
            <div><strong>%d</strong><span class="dimmed">retrieval runs</span></div>
            <div><strong>%d</strong><span class="dimmed">reviewed notes</span></div>
            <div><strong>%d</strong><span class="dimmed">chat sessions</span></div>
        </div>
        <div class="platform-knowledge-grid">
            <div>
                <div class="platform-knowledge-panel">
                    <h4>Processing Tiers</h4>
                    <div class="platform-knowledge-tiers">
%s
                    </div>
                </div>
            </div>
            <div>
                <div class="platform-knowledge-panel">
                    <h4>Recent Retrievals</h4>
%s
                </div>
                <div class="platform-knowledge-panel">
                    <a href="chat">Browse chat sessions &rarr;</a>
                </div>
            </div>
        </div>
    </div>
</div>
""", platform_container_css(1200), stats.note_count, stats.retrieval_count, stats.reviewed_note_count,
     stats.session_count, tier_tiles, retrieval_rows)
end

function html.render_index(db_path, entity_types, edges, nonce)
    items = ""
    for _, row in ipairs(entity_types) do
        escaped_name = html.html_escape(row.name)
        -- Row count used to be an always-visible inline badge; moved to
        -- a hover popover (html.popover_css()) so the default view only
        -- shows what's needed to decide "do I click into this."
        trigger_class = ""
        count_popover = ""
        if row.count != nil then
            count_label = tostring(row.count) .. " rows"
            if row.count == 1 then
                count_label = "1 row"
            end
            trigger_class = "platform-popover-trigger"
            count_popover = "<span class=\"platform-popover\">" .. count_label .. "</span>"
        end
        row_count = 0
        if row.count != nil then
            row_count = row.count
        end
        items = items .. "<li data-count=\"" .. tostring(row_count) .. "\"><a href=\"browse?type=" .. escaped_name .. "\" class=\"" .. trigger_class .. "\" tabindex=\"0\">" .. escaped_name ..
            count_popover .. "</a></li>"
    end

    list_or_empty = "<ul class=\"platform-index-list\">" .. items .. "</ul>"
    if #entity_types == 0 then
        list_or_empty = "<p class=\"platform-empty\">No entity types registered yet.</p>"
    end

    diagram_html = html.render_relation_diagram(db_path, entity_types, edges)

    return string.format("""
<div class="fossil-doc" data-title="Overview">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-view-toggle { display: flex; gap: 6px; flex-shrink: 0; }
        .platform-view-toggle button { padding: 6px 14px; border-radius: var(--platform-radius-sm, 8px); border: 1px solid var(--platform-border, #e2e8f0); background: var(--platform-bg, #f8fafc); color: var(--platform-text, #334155); font-weight: 600; font-size: 0.85rem; cursor: pointer; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-view-toggle button.platform-view-active { background: var(--platform-accent, #4f46e5); border-color: var(--platform-accent, #4f46e5); color: #ffffff; }
        .platform-hide-empty-toggle { display: flex; align-items: center; gap: 6px; font-size: 0.85rem; color: var(--platform-muted, #64748b); cursor: pointer; user-select: none; margin-right: 8px; }
        .platform-hide-empty-toggle input { cursor: pointer; }
        .platform-entity-search { position: relative; margin-bottom: 16px; max-width: 420px; }
        .platform-entity-search input {
            width: 100%%; padding: 9px 12px; border: 1px solid var(--platform-border-2, #cbd5e1);
            border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem; box-sizing: border-box;
        }
        .platform-entity-search-results {
            display: none; position: absolute; top: 100%%; left: 0; right: 0; margin-top: 6px;
            background: #ffffff; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px);
            max-height: 320px; overflow-y: auto; z-index: 1000;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
        }
        .platform-entity-search-results.platform-entity-search-open { display: block; }
        .platform-entity-search-results a { display: flex; justify-content: space-between; gap: 10px; padding: 8px 12px; font-size: 0.88rem; text-decoration: none; color: var(--platform-text, #334155); }
        .platform-entity-search-results a:hover { background: var(--platform-bg-2, #f1f5f9); }
        .platform-entity-search-results a span.platform-entity-search-type { color: var(--platform-muted, #64748b); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; }
        .platform-entity-search-empty { padding: 10px 12px; color: var(--platform-muted, #64748b); font-size: 0.88rem; }
        .platform-index-list { list-style: none !important; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
        .platform-index-list li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); display: flex; align-items: center; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-index-list li:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-index-list li::marker { content: ""; }
        .platform-index-list a { flex: 1; display: block; padding: 12px 16px; color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; text-transform: capitalize; }
        .platform-index-list a:hover { background: var(--platform-bg-2, #f1f5f9); border-radius: var(--platform-radius-item, 10px) 0 0 var(--platform-radius-item, 10px); }
%s
        .platform-empty {
            padding: 32px;
            text-align: center;
            color: var(--platform-muted, #64748b);
            background: var(--platform-bg, #f8fafc);
            border: 1px dashed var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
    </style>
    %s
    <div class="platform-container">
        <div class="platform-header">
            <div>
                <h2>Entity types</h2>
                <p>%d registered</p>
            </div>
            <div class="platform-view-toggle" id="platform-view-toggle">
                <label class="platform-hide-empty-toggle"><input type="checkbox" id="platform-hide-empty"> Hide empty types</label>
                <button type="button" data-view="list" class="platform-view-active">List</button>
                <button type="button" data-view="diagram">Diagram</button>
            </div>
        </div>
        <div class="platform-entity-search">
            <input type="text" id="platform-entity-search-input" placeholder="Search entities by name..." autocomplete="off">
            <div class="platform-entity-search-results" id="platform-entity-search-results"></div>
        </div>
        <div id="platform-view-list">%s</div>
        <div id="platform-view-diagram" style="display:none;">%s</div>
    </div>
    <script nonce="%s">
    (function(){
        var input = document.getElementById('platform-entity-search-input');
        var results = document.getElementById('platform-entity-search-results');
        var debounceTimer;

        function escapeHtml(s) {
            return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        }

        function render(items) {
            if (items.length === 0) {
                results.innerHTML = '<div class="platform-entity-search-empty">No matching entities.</div>';
            } else {
                results.innerHTML = items.map(function(item){
                    return '<a href="detail?type=' + encodeURIComponent(item.entity_type) + '&entity_id=' + item.id + '">' +
                        escapeHtml(item.label) + '<span class="platform-entity-search-type">' + escapeHtml(item.entity_type) + '</span></a>';
                }).join('');
            }
            results.classList.add('platform-entity-search-open');
        }

        input.addEventListener('input', function(){
            clearTimeout(debounceTimer);
            var query = input.value.trim();
            if (!query) { results.classList.remove('platform-entity-search-open'); results.innerHTML = ''; return; }
            debounceTimer = setTimeout(function(){
                fetch('api/entity-search?query=' + encodeURIComponent(query))
                    .then(function(res){ return res.json(); })
                    .then(render);
            }, 200);
        });
        document.addEventListener('click', function(e){
            if (e.target !== input && !results.contains(e.target)) {
                results.classList.remove('platform-entity-search-open');
            }
        });
        input.addEventListener('keydown', function(e){
            if (e.key === 'Escape') { results.classList.remove('platform-entity-search-open'); }
        });
    })();
    </script>
</div>
%s
""", platform_container_css(800), html.relation_diagram_css(), html.popover_css(), #entity_types,
     list_or_empty, diagram_html, nonce, html.diagram_js(nonce))
end

-- Every entry template found (whether it loaded cleanly or not), each
-- linking to /template?name=... where the actual snippet is rendered.
function html.render_templates_list(entries)
    items = ""
    for _, entry in ipairs(entries) do
        escaped_name = html.html_escape(entry.name)
        if entry.def == nil then
            items = items .. "<li class=\"platform-template-error\">" .. escaped_name ..
                " -- ERROR: " .. html.html_escape(entry.err) .. "</li>"
        else
            label = entry.def.label
            if label == nil then
                label = entry.name
            end
            description = entry.def.description
            if description == nil then
                description = ""
            end
            escaped_label = html.html_escape(label)
            escaped_desc = html.html_escape(description)
            items = items .. "<li><a href=\"template?template_name=" .. escaped_name .. "\">" ..
                escaped_label .. "</a><p>" .. escaped_desc .. "</p>" ..
                "<p><a href=\"document-edit?from_template=" .. escaped_name .. "\">+ New document from this&rarr;</a></p></li>"
        end
    end

    list_or_empty = "<ul class=\"platform-index-list\">" .. items .. "</ul>"
    if #entries == 0 then
        list_or_empty = "<p class=\"platform-empty\">No entry templates yet.</p>"
    end

    return string.format("""
<div class="fossil-doc" data-title="Entry templates">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-index-list { list-style: none !important; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
        .platform-index-list li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; }
        .platform-index-list li::marker { content: ""; }
        .platform-index-list a { font-weight: 700; color: var(--platform-accent, #4f46e5); text-decoration: none; }
        .platform-index-list a:hover { text-decoration: underline; }
        .platform-index-list p { margin: 6px 0 0 0; color: var(--platform-muted, #64748b); font-size: 0.88rem; }
        .platform-template-error { color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; }
        .platform-empty {
            padding: 32px;
            text-align: center;
            color: var(--platform-muted, #64748b);
            background: var(--platform-bg, #f8fafc);
            border: 1px dashed var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
        }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Entry templates</h2>
            <p>Pick a template to see its rendered Markdown.</p>
        </div>
        %s
    </div>
</div>
""", platform_container_css(800), list_or_empty)
end

-- The rendered Markdown snippet for one template, in a read-only
-- textarea for easy select-all-and-copy -- no JS needed (a "Copy"
-- button would need one, and this is simple enough not to bother).
function html.render_template(def, rendered_markdown, nonce)
    if nonce == nil then
        nonce = ""
    end
    label = def.label
    if label == nil then
        label = def.name
    end
    description = def.description
    if description == nil then
        description = ""
    end
    escaped_label = html.html_escape(label)
    escaped_desc = html.html_escape(description)
    escaped_body = html.html_escape(rendered_markdown)
    escaped_name = html.html_escape(def.name)

    return string.format("""
<div class="fossil-doc" data-title="Template: %s">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-header a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-header a:hover { text-decoration: underline; }
        .platform-snippet {
            width: 100%%;
            min-height: 360px;
            box-sizing: border-box;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.88rem;
            padding: 16px;
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px);
            background: var(--platform-bg, #f8fafc);
            color: var(--platform-input-text, #1e293b);
        }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <div>
                <h2>%s</h2>
                <p>%s</p>
                <p><a href="templates">&larr; All templates</a></p>
            </div>
            <a class="btn btn-primary" href="document-edit?from_template=%s">+ New document from template</a>
        </div>
        <p>Or select-all and copy the rendered snippet below.</p>
        <textarea class="platform-snippet" id="platform-template-content" readonly>%s</textarea>
    </div>
</div>
""", escaped_label, platform_container_css(900), platform_button_css(), escaped_label, escaped_desc, escaped_name, escaped_body)
end

-- Ad-hoc SQL console (Setup/Admin only -- see cgi.lua's /sql route):
-- a plain GET form (no JS needed, unlike register's autocomplete) so
-- the query is a normal, bookmarkable/shareable URL. `column_names`/
-- `rows` are nil until a query has been run; `err` is set instead if
-- it failed (not select-only, invalid sql, etc.).
function html.render_sql(db_path, sql_text, column_names, rows, err, ref_columns, nonce, embed, theme, truncated)
    if ref_columns == nil then
        ref_columns = {}
    end
    if nonce == nil then
        nonce = ""
    end
    -- ?embed=1 renders this page for use inside a same-origin iframe
    -- (previously used by /data's own SQL widget, removed after a
    -- persistent styling problem -- see cgi.lua's own comment on
    -- /data). Kept as a general capability: the .platform-container
    -- "card" look (padding/shadow/border/radius) is right for a
    -- standalone page, but reads as a window nested inside a window
    -- once sitting inside an iframe's own bordered box. cgi.lua knows
    -- server-side that this is the embedded case (its own ?embed=1),
    -- so this flattens the card directly rather than needing a
    -- client-side "am I in an iframe"
    -- detection script the way a skin with no such server-side signal
    -- would have to.
    embed_css = ""
    if embed == true then
        embed_css = ".platform-container { padding: 0; margin: 0; max-width: none; box-shadow: none; border: none; border-radius: 0; }"
        -- The embedded case skips html.page_shell entirely (see above),
        -- so it never otherwise gets the :root { --platform-x: ...; }
        -- block a real theme compiles to -- without it, every
        -- var(--platform-*, fallback) below silently resolves to the
        -- generic fallback color instead of the deployment's real
        -- palette. Confirmed live: the embedded widget on /data was
        -- rendering in the default indigo/slate, not Celleste's brown/gold.
        if theme != nil then
            embed_css = html.theme_root_css(theme) .. " " .. embed_css
        end
    end
    sql_text_or_empty = sql_text
    if sql_text_or_empty == nil then
        sql_text_or_empty = ""
    end
    escaped_sql = html.html_escape(sql_text_or_empty)

    result_html = ""
    if err != nil then
        result_html = "<div class=\"platform-sql-error\">Error: " .. html.html_escape(err) .. "</div>"
    elseif rows != nil then
        header_parts = {}
        for _, name in ipairs(column_names) do
            table.insert(header_parts, "<th>" .. html.html_escape(name) .. "</th>")
        end
        header_cells = table.concat(header_parts)
        -- Real bug found live: repeated ".." string concatenation in
        -- this loop is O(n^2) in Lua (each ".." copies the whole
        -- accumulated string so far) -- fine for a handful of rows, but
        -- a genuinely unbounded query (/sql has no LIMIT/pagination at
        -- all, unlike /browse's own BROWSE_PAGE_SIZE cap) against a
        -- real production table confirmed this taking 54 real seconds
        -- for ~3800 rows of full document content. table.insert +
        -- table.concat is O(n).
        body_row_parts = {}
        for _, row in ipairs(rows) do
            cell_parts = {}
            for _, name in ipairs(column_names) do
                ref_type = ref_columns[name]
                if ref_type != nil then
                    table.insert(cell_parts, "<td>" .. render_reference_value(db_path, ref_type, row[name]) .. "</td>")
                else
                    table.insert(cell_parts, "<td>" .. display_value(row[name]) .. "</td>")
                end
            end
            table.insert(body_row_parts, "<tr>" .. table.concat(cell_parts) .. "</tr>")
        end
        body_rows = table.concat(body_row_parts)
        if #rows == 0 then
            result_html = "<p class=\"platform-empty\">No rows.</p>"
        else
            count_message = tostring(#rows) .. " rows"
            if truncated == true then
                count_message = "Showing first " .. tostring(#rows) .. " rows -- more may exist. Add your own LIMIT to see a different range."
            end
            result_html = "<div class=\"platform-table-wrapper\"><table id=\"sql-table\"><thead><tr>" ..
                header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>" ..
                "<p class=\"platform-sql-count\">" .. count_message .. "</p>"
        end
    elseif sql_text_or_empty == "" then
        -- Submitted with a genuinely empty box -- distinct from the
        -- pre-run, example-prefilled first-load case below, which
        -- needs no message at all (nothing has failed or been skipped).
        result_html = "<p class=\"platform-empty\">Enter a SQL query above, then click Run.</p>"
    end

    return string.format("""
<div class="fossil-doc" data-title="Query">
    <style>
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-sql-input {
            width: 100%%;
            /* max-width explicit, not left to inherit: Fossil's own base
            ** CSS (src/default.css) has a bare "textarea { max-width:
            ** 95%% }" rule that otherwise wins over nothing here -- a
            ** real, confirmed-live gap (measured 1045px vs the intended
            ** 1100px). This class selector's higher specificity
            ** overrides it. */
            max-width: 100%%;
            min-height: 140px;
            box-sizing: border-box;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.9rem;
            padding: 14px;
            border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-item, 10px);
            background: var(--platform-bg, #f8fafc);
            color: var(--platform-input-text, #1e293b);
            margin-bottom: 12px;
        }
        %s
        .platform-sql-error {
            margin-top: 20px;
            padding: 14px 18px;
            border-radius: var(--platform-radius-item, 10px);
            background: #fef2f2;
            border: 1px solid #fecaca;
            color: #991b1b;
        }
        .platform-sql-count { color: var(--platform-muted, #64748b); font-size: 0.85rem; margin-top: 8px; }
        .platform-table-wrapper { overflow-x: auto; margin-top: 20px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        #sql-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        #sql-table th, #sql-table td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.85rem; }
        #sql-table th { background: var(--platform-bg-2, #f1f5f9); font-weight: 600; font-size: 0.75rem; color: var(--platform-th-text, #475569); text-transform: uppercase; letter-spacing: 0.06em; }
        #sql-table td { background: #ffffff; }
        .platform-empty { margin-top: 20px; padding: 24px; text-align: center; color: var(--platform-muted, #64748b); background: var(--platform-bg, #f8fafc); border: 1px dashed var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-entity-ref { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-entity-ref::after { content: " \2197"; font-size: 0.85em; }
        .platform-entity-ref:hover { text-decoration: underline; }
        %s
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Query</h2>
            <p>Read-only (SELECT only) queries against the entity store. Setup/Admin only.</p>
        </div>
        <form method="get" action="sql">
            <textarea class="platform-sql-input" id="platform-sql-query" name="q" placeholder="SELECT * FROM sample LIMIT 20;">%s</textarea>
            <button class="btn btn-primary" type="submit">Run</button>
        </form>
        %s
    </div>
</div>
%s
""", platform_container_css(1100), platform_button_css(), html.popover_css() .. embed_css, escaped_sql, result_html, html.popover_js(nonce))
end

--------------------------------------------------------------------------
-- Documents (the notebook/wiki-style entity type, src/document.lua)
--------------------------------------------------------------------------

-- Groups a flat {id, title, parent_id} list by parent, keyed "root" for
-- top-level rows -- one query from document.all_active(), built into a
-- nested tree here rather than one query per level.
function build_document_tree_index(rows)
    by_parent = {}
    for _, row in ipairs(rows) do
        key = "root"
        if row.parent_id != nil and row.parent_id != "" then
            key = tostring(tonumber(row.parent_id))
        end
        if by_parent[key] == nil then
            by_parent[key] = {}
        end
        table.insert(by_parent[key], row)
    end
    return by_parent
end

-- Renders one tree level as collapsible <details>/<summary> nodes --
-- pure CSS/HTML (no JS, no CSP-nonce plumbing needed, see html.lua's
-- own render() comment on why an inline <script> would need one).
-- Previously always fully expanded, every level, in one shot -- fine
-- for a handful of pages, unusable once real content brought hundreds
-- of folders (confirmed against real production data: 376 folder
-- nodes). depth 0 (top level) starts open so the overall shape is
-- visible immediately; everything nested starts closed, since a
-- fully-expanded deep tree is exactly the problem being fixed here.
-- The link and the disclosure triangle are deliberately separate
-- click targets -- summary normally toggles on any click inside it,
-- but browsers let a nested <a>'s own click take over instead, so the
-- title text still navigates rather than only expanding.
function render_document_tree_level(by_parent, key, depth)
    children = by_parent[key]
    if children == nil then
        return ""
    end
    items = ""
    for _, row in ipairs(children) do
        child_key = tostring(tonumber(row.id))
        nested = render_document_tree_level(by_parent, child_key, depth + 1)
        link = "<a href=\"document?entity_id=" .. tostring(row.id) .. "\">" .. html.html_escape(row.title) .. "</a>"
        if nested == "" then
            items = items .. "<li class=\"platform-tree-leaf\">" .. link .. "</li>"
        else
            -- Collapsed by default at every depth, including the top
            -- level (task: Ben's own explicit ask, prompted by the tree
            -- getting long after a real bulk import). Was "open" at
            -- depth 0 only; the user navigates inward as needed instead.
            items = items .. "<li><details><summary>" .. link .. "</summary><ul>" ..
                nested .. "</ul></details></li>"
        end
    end
    return items
end

-- <option> tags for the parent-document <select> in render_document_edit.
-- Excludes `exclude_id` (a document can't be its own parent) -- doesn't
-- also exclude its descendants (which would need a full descendant
-- walk to build); choosing one of those is instead caught at save time
-- by document.would_create_cycle, with a real error message rather than
-- the option silently not being offered.
--
-- Duplicate titles are real and already fairly common (task: found
-- live, 293 titles with duplicates in production, mostly "Experiment
-- N" documents resynced from Benchling more than once) -- picking a parent
-- by title alone is ambiguous whenever that happens, and the person
-- doing it has no way to tell the options apart. Never shown as a bare
-- internal id (meaningless to a human, and the whole point of this
-- fix is *not* making someone handle ids) -- instead, whichever of
-- {parent folder, creation date, Benchling's own external_id} actually
-- differs between the duplicates. All three can coincide (two entries
-- synced in the same batch, same parent, same second) -- external_id
-- is the one property still guaranteed to differ in that case, since
-- it names a real, distinct source record.
function html.document_parent_options(rows, selected_id, exclude_id)
    title_counts = {}
    by_id = {}
    for _, row in ipairs(rows) do
        current_count = title_counts[row.title]
        if current_count == nil then
            current_count = 0
        end
        title_counts[row.title] = current_count + 1
        by_id[tostring(tonumber(row.id))] = row
    end

    options = ""
    for _, row in ipairs(rows) do
        if exclude_id == nil or tonumber(row.id) != tonumber(exclude_id) then
            selected_attr = ""
            if selected_id != nil and tonumber(row.id) == tonumber(selected_id) then
                selected_attr = " selected"
            end
            label = html.html_escape(row.title)
            if title_counts[row.title] > 1 then
                bits = {}
                if row.parent_id != nil then
                    parent_row = by_id[tostring(tonumber(row.parent_id))]
                    if parent_row != nil then
                        table.insert(bits, "under " .. parent_row.title)
                    end
                end
                if row.created_at != nil and row.created_at != "" then
                    table.insert(bits, string.sub(row.created_at, 1, 10))
                end
                if row.external_id != nil and row.external_id != "" then
                    table.insert(bits, row.external_id)
                end
                if #bits > 0 then
                    label = label .. " (" .. html.html_escape(table.concat(bits, ", ")) .. ")"
                end
            end
            options = options .. "<option value=\"" .. tostring(row.id) .. "\"" .. selected_attr .. ">" ..
                label .. "</option>"
        end
    end
    return options
end

-- `can_create` is a plain boolean (the "+ New document" link's own gate) --
-- html.lua never checks capabilities itself, same convention
-- render_system's show_sql/show_admin params already use; cgi.lua
-- decides and passes the answer in.
-- Flat {id, title} pairs for the fuzzy-search box's client-side
-- matching -- the same `rows` the tree itself is built from
-- (document.all_active), just the two fields the search actually
-- needs, not the full row (content, timestamps, etc).
function document_search_index_json(rows)
    json = require("dkjson")
    index = {}
    for _, row in ipairs(rows) do
        table.insert(index, {id = tonumber(row.id), title = row.title})
    end
    return json_for_script(json.encode(index))
end

function html.render_document_tree(rows, can_create, nonce)
    by_parent = build_document_tree_index(rows)
    tree_items = render_document_tree_level(by_parent, "root", 0)
    tree_html = "<ul class=\"platform-document-tree\">" .. tree_items .. "</ul>"
    if tree_items == "" then
        tree_html = "<p class=\"platform-empty\">No documents yet.</p>"
    end

    new_page_link = ""
    if can_create == true then
        new_page_link = "<a class=\"btn btn-primary\" href=\"document-edit\">+ New document</a> " ..
            "<a class=\"btn btn-secondary\" href=\"templates\">From template&hellip;</a>"
    end

    return string.format("""
<div class="fossil-doc" data-title="Documents">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-document-search { position: relative; margin-bottom: 16px; }
        .platform-document-search input {
            width: 100%%; padding: 10px 12px; box-sizing: border-box;
            border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.92rem;
        }
        .platform-document-search-results {
            position: absolute; left: 0; right: 0; top: calc(100%% + 4px); z-index: 30;
            background: var(--platform-bg, #ffffff); border: 1px solid var(--platform-border, #e2e8f0);
            border-radius: var(--platform-radius-md, 12px); box-shadow: 0 6px 20px rgba(0,0,0,0.12);
            max-height: 320px; overflow-y: auto; display: none;
        }
        .platform-document-search-results.platform-document-search-open { display: block; }
        .platform-document-search-results a {
            display: block; padding: 8px 12px; color: var(--platform-text, #334155); text-decoration: none; font-size: 0.9rem;
        }
        .platform-document-search-results a:hover, .platform-document-search-results a.platform-search-active { background: var(--platform-bg-2, #f1f5f9); }
        .platform-document-search-empty { padding: 10px 12px; color: var(--platform-muted, #64748b); font-size: 0.88rem; }
        .platform-document-tree, .platform-document-tree ul { list-style: none !important; margin: 0; padding-left: 20px; }
        .platform-document-tree { padding-left: 0; }
        .platform-document-tree li { margin: 4px 0; }
        .platform-document-tree a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-document-tree a:hover { text-decoration: underline; }
        .platform-document-tree details > summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: 4px; padding: 2px 0; }
        .platform-document-tree details > summary::-webkit-details-marker { display: none; }
        .platform-document-tree details > summary::before {
            content: "▸"; display: inline-block; color: var(--platform-muted, #94a3b8);
            font-size: 0.75rem; width: 12px; transition: transform 0.15s ease;
        }
        .platform-document-tree details[open] > summary::before { transform: rotate(90deg); }
        .platform-tree-leaf { padding: 2px 0 2px 16px; }
    </style>
    <div class="platform-container">
        <div class="platform-header">
            <h2>Documents</h2>
            %s
        </div>
        <div class="platform-document-search">
            <input type="text" id="platform-document-search-input" placeholder="Fuzzy search document titles..." autocomplete="off">
            <div class="platform-document-search-results" id="platform-document-search-results"></div>
        </div>
        %s
    </div>
    <script nonce="%s">
    (function(){
        var index = %s;
        var input = document.getElementById('platform-document-search-input');
        var results = document.getElementById('platform-document-search-results');

        // Simple ordered-subsequence fuzzy match: every character of
        // the query must appear in the title, in order (not
        // necessarily contiguous) -- consecutive matches score higher,
        // so "exp277" ranks "Experiment 277" above a title that merely
        // contains the same letters scattered further apart.
        function fuzzyScore(query, title) {
            var qi = 0, score = 0, lastMatch = -2;
            var q = query.toLowerCase(), t = title.toLowerCase();
            for (var ti = 0; ti < t.length && qi < q.length; ti++) {
                if (t[ti] === q[qi]) {
                    score += (ti === lastMatch + 1) ? 3 : 1;
                    lastMatch = ti;
                    qi++;
                }
            }
            return (qi === q.length) ? score : -1;
        }

        function renderResults(query) {
            if (!query) { results.classList.remove('platform-document-search-open'); results.innerHTML = ''; return; }
            var scored = [];
            index.forEach(function(item){
                var score = fuzzyScore(query, item.title);
                if (score >= 0) scored.push({item: item, score: score});
            });
            scored.sort(function(a, b){ return b.score - a.score; });
            scored = scored.slice(0, 15);
            if (scored.length === 0) {
                results.innerHTML = '<div class="platform-document-search-empty">No matching documents.</div>';
            } else {
                results.innerHTML = scored.map(function(s){
                    var title = s.item.title.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                    return '<a href="document?entity_id=' + s.item.id + '">' + title + '</a>';
                }).join('');
            }
            results.classList.add('platform-document-search-open');
        }

        input.addEventListener('input', function(){ renderResults(input.value); });
        input.addEventListener('focus', function(){ if (input.value) renderResults(input.value); });
        document.addEventListener('click', function(e){
            if (e.target !== input && !results.contains(e.target)) {
                results.classList.remove('platform-document-search-open');
            }
        });
        input.addEventListener('keydown', function(e){
            if (e.key === 'Enter') {
                var first = results.querySelector('a');
                if (first) { window.location.href = first.getAttribute('href'); }
            } else if (e.key === 'Escape') {
                results.classList.remove('platform-document-search-open');
            }
        });
    })();
    </script>
</div>
""", platform_container_css(900), platform_button_css(), new_page_link, tree_html,
     nonce, document_search_index_json(rows))
end

-- `can_edit` is likewise a plain boolean, decided by cgi.lua.
-- `rendered_html` (document.render_html's own output) is embedded
-- unescaped -- deliberately: it's already-rendered HTML from cmark's
-- default (non---unsafe) mode, which strips raw HTML/script tags out of
-- the *source* Markdown before this ever runs, so what comes back here
-- is already safe to place directly in the page, not user input that
-- still needs escaping.
function html.render_document(doc, rendered_html, breadcrumbs, children, backlinks, can_edit)
    breadcrumb_html = ""
    for i, crumb in ipairs(breadcrumbs) do
        if i > 1 then
            breadcrumb_html = breadcrumb_html .. " / "
        end
        if i == #breadcrumbs then
            breadcrumb_html = breadcrumb_html .. html.html_escape(crumb.title)
        else
            breadcrumb_html = breadcrumb_html .. "<a href=\"document?entity_id=" .. tostring(crumb.id) .. "\">" ..
                html.html_escape(crumb.title) .. "</a>"
        end
    end

    children_html = ""
    for _, child in ipairs(children) do
        children_html = children_html .. "<li><a href=\"document?entity_id=" .. tostring(child.id) .. "\">" ..
            html.html_escape(child.title) .. "</a></li>"
    end
    children_block = ""
    if children_html != "" then
        children_block = "<div class=\"platform-document-children\"><h4>Sub-documents</h4><ul>" .. children_html .. "</ul></div>"
    end

    backlinks_html = ""
    for _, link in ipairs(backlinks) do
        backlinks_html = backlinks_html .. "<li><a href=\"document?entity_id=" .. tostring(link.id) .. "\">" ..
            html.html_escape(link.title) .. "</a></li>"
    end
    backlinks_block = ""
    if backlinks_html != "" then
        backlinks_block = "<div class=\"platform-document-backlinks\"><h4>Linked from</h4><ul>" .. backlinks_html .. "</ul></div>"
    end

    edit_link = ""
    if can_edit == true then
        edit_link = "<a class=\"btn btn-secondary\" href=\"document-edit?entity_id=" .. tostring(doc.id) .. "\">Edit</a>"
    end

    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
%s
        .platform-document-breadcrumbs { margin-bottom: 12px; font-size: 0.88rem; color: var(--platform-muted, #64748b); }
        .platform-document-breadcrumbs a { color: var(--platform-accent, #4f46e5); text-decoration: none; }
        .platform-document-breadcrumbs a:hover { text-decoration: underline; }
        .platform-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-document-content { line-height: 1.6; }
        .platform-document-content h1, .platform-document-content h2, .platform-document-content h3 { margin-top: 1.2em; }
        .platform-document-children, .platform-document-backlinks { margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--platform-border, #e2e8f0); }
        .platform-document-children h4, .platform-document-backlinks h4 { margin: 0 0 8px 0; font-size: 0.95rem; color: var(--platform-muted, #64748b); }
    </style>
    <div class="platform-container">
        <div class="platform-document-breadcrumbs">%s <a href="documents">(all documents)</a></div>
        <div class="platform-header">
            <h2>%s</h2>
            %s
        </div>
        <div class="platform-document-content">
%s
        </div>
        %s
        %s
    </div>
</div>
""", html.html_escape(doc.title), platform_container_css(900), platform_button_css(),
     breadcrumb_html, html.html_escape(doc.title), edit_link, rendered_html, children_block, backlinks_block)
end

-- `doc` is nil for "create a new document", or the current row for
-- editing an existing one. `parent_options_html` is pre-rendered
-- <option> tags (cgi.lua builds these from document.all_active, since
-- it needs entity.get to know which one -- if any -- is currently
-- selected). `prefill` (only used when doc == nil, i.e. a genuinely
-- new, unsaved document): {title=, content=} to seed the form with,
-- e.g. from a template.lua template's own rendered content (cgi.lua's
-- /document-edit?from_template=<name>). Nothing is created yet --
-- still a plain new-document form the user reviews/edits before Save,
-- same as if they'd typed it by hand.
function html.render_document_edit(doc, parent_options_html, csrf_token, error_message, nonce, prefill)
    is_edit = doc != nil
    heading = "New document"
    entity_id_value = ""
    title_value = ""
    content_value_raw = ""
    if is_edit then
        heading = "Edit: " .. html.html_escape(doc.title)
        entity_id_value = tostring(doc.id)
        title_value = html.html_escape(doc.title)
        if doc.content != nil then
            content_value_raw = doc.content
        end
    elseif prefill != nil then
        if prefill.title != nil then
            title_value = html.html_escape(prefill.title)
        end
        if prefill.content != nil then
            content_value_raw = prefill.content
        end
    end

    error_html = ""
    if error_message != nil and error_message != "" then
        error_html = "<div class=\"platform-login-error\">" .. html.html_escape(error_message) .. "</div>"
    end

    return string.format("""
<div class="fossil-doc" data-title="%s">
    <link rel="stylesheet" href="vendor?name=toastui-editor.min.css">
    <style>
%s
%s
        .platform-login-error { color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-item, 10px); padding: 10px 12px; margin-bottom: 14px; font-size: 0.88rem; }
        .platform-document-edit-fields { display: flex; gap: 12px; margin-bottom: 14px; flex-wrap: wrap; }
        .platform-document-edit-fields input[type=text], .platform-document-edit-fields select {
            padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); font-size: 0.9rem;
        }
        .platform-wikilink {
            color: var(--platform-accent, #4f46e5); background: var(--platform-bg-2, #f1f5f9);
            border-radius: 4px; padding: 0 4px; font-weight: 600;
        }
    </style>
    <div class="platform-container">
        <div class="platform-header"><h2>%s</h2></div>
        %s
        <form method="POST" action="document-save" id="platform-document-edit-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="hidden" name="entity_id" value="%s">
            <input type="hidden" name="content" id="platform-document-content-hidden">
            <div class="platform-document-edit-fields">
                <input type="text" name="title" value="%s" placeholder="Title" required>
                <select name="parent_id">
                    <option value="">(top level)</option>
                    %s
                </select>
                <button type="submit" class="btn btn-primary">Save</button>
            </div>
            <div id="platform-toastui-editor"></div>
        </form>
    </div>
    <script src="vendor?name=toastui-editor-all.min.js" nonce="%s"></script>
    <script nonce="%s">
    (function(){
        // Starts in 'markdown' mode -- the familiar plain-text +
        // toolbar experience -- with 'wysiwyg' (syntax hidden, edit
        // the rendered view directly) one click away via the
        // editor's own built-in mode tab, not a separate feature to
        // build. getMarkdown() on submit keeps document-save's
        // contract (a plain markdown `content` field) unchanged --
        // schema.lua/document.lua/cmark downstream never know the
        // editor changed.
        var editor = new toastui.Editor({
            el: document.querySelector('#platform-toastui-editor'),
            height: '460px',
            initialEditType: 'markdown',
            previewStyle: 'vertical',
            initialValue: "%s",
            placeholder: 'Write in Markdown. Link to other documents with [[title]] or [[folder/title]].',
            // WYSIWYG mode has no built-in notion of this project's own
            // "[[title]]" link syntax -- without a widget rule it shows
            // as inert literal text. This only styles it as recognized
            // syntax while editing; resolved-vs-dangling status is still
            // computed server-side (document.render_html), same as
            // before -- getMarkdown() on submit is untouched either way.
            widgetRules: [{
                rule: /\[\[([^\]]+)\]\]/,
                toDOM: function(text) {
                    var matched = text.match(/\[\[([^\]]+)\]\]/);
                    var span = document.createElement('span');
                    span.className = 'platform-wikilink';
                    span.textContent = '[[' + matched[1] + ']]';
                    return span;
                }
            }]
        });
        var form = document.getElementById('platform-document-edit-form');
        var hiddenContent = document.getElementById('platform-document-content-hidden');
        form.addEventListener('submit', function(){
            hiddenContent.value = editor.getMarkdown();
        });
    })();
    </script>
</div>
""", heading, platform_container_css(1200), platform_button_css(), heading, error_html,
     html.html_escape(csrf_token), entity_id_value, title_value, parent_options_html,
     nonce, nonce, js_string_literal(content_value_raw))
end

--------------------------------------------------------------------------
-- Chat/agent (src/agent.lua)
--------------------------------------------------------------------------

CHAT_ROLE_LABELS = {
    user = "You",
    assistant = "Assistant",
    tool_result = "Tool result",
    compaction_summary = "Compacted summary",
    self_check = "Self-check",
}

-- Every message renders, including ones marked out-of-context by
-- compaction (dimmed, not hidden) -- transparency about what the model
-- can/can't currently see, matching this system's own "nothing is ever
-- hidden, only marked" stance elsewhere (archived_at, in_context).
-- Shared `.platform-chat-*` thread rules -- used by both html.render_chat
-- and the inline "Edit with AI" panel on a document page (see
-- html.render_document_ai_panel below), same de-duplication reasoning
-- as platform_container_css/platform_button_css above.
function platform_chat_thread_css()
    return """
        .platform-chat-messages { max-height: 55vh; overflow-y: auto; margin-bottom: 16px; padding: 12px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        .platform-chat-msg { margin-bottom: 10px; padding: 8px 10px; border-radius: var(--platform-radius-sm, 8px); background: #fff; border: 1px solid var(--platform-border, #e2e8f0); }
        .platform-chat-user { background: #eef2ff; }
        .platform-chat-tool_result { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; }
        .platform-chat-compaction_summary { font-style: italic; color: var(--platform-muted, #64748b); }
        .platform-chat-self_check { font-style: italic; color: var(--platform-muted, #64748b); border-left: 3px solid #fbbf24; }
        .platform-chat-out-of-context { opacity: 0.45; }
        .platform-chat-input-form { display: flex; gap: 8px; }
        .platform-chat-input-form input[type=text] { flex: 1; padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); }
        .platform-chat-pending { padding: 14px; border: 1px solid #fde68a; background: #fffbeb; border-radius: var(--platform-radius-md, 12px); }
        .platform-chat-pending-form { display: inline-block; margin-right: 8px; margin-top: 8px; }
"""
end

-- Roles whose content is real model output (often Markdown -- headings,
-- bold, lists) rather than plain human-typed text -- found live: a
-- real reply came back with **bold** section headers and the chat page
-- just showed the literal asterisks, since everything was plain
-- html-escaped text before this. Rendered through the exact same
-- cmark-gfm pipeline document pages already use (document.render_markdown),
-- not a separate one -- its own non-`--unsafe` mode already strips raw
-- HTML/scripts, so this is exactly as safe to embed unescaped as any
-- other rendered-Markdown HTML this codebase already trusts.
-- A field on the `html` table, not a bare global -- cgi.lua's own
-- chat_widget_state (a different required module, its own separate
-- environment in this runtime) needs this same set too, and only
-- values actually returned by require() (table fields like this one,
-- not bare globals) cross that boundary. Confirmed live: a bare global
-- here crashed cgi.lua outright ("attempt to index global
-- 'CHAT_MARKDOWN_ROLES' (a nil value)") the moment a route that isn't
-- html.lua's own tried to read it.
html.CHAT_MARKDOWN_ROLES = {assistant = true, self_check = true, compaction_summary = true}

function render_chat_message(msg)
    label = CHAT_ROLE_LABELS[msg.role]
    if label == nil then
        label = msg.role
    end
    css_class = "platform-chat-msg platform-chat-" .. msg.role
    if tonumber(msg.in_context) == 0 then
        css_class = css_class .. " platform-chat-out-of-context"
    end
    body = html.html_escape(msg.content)
    if html.CHAT_MARKDOWN_ROLES[msg.role] == true then
        body = document.render_markdown(msg.content)
    end
    return "<div class=\"" .. css_class .. "\"><strong>" .. html.html_escape(label) .. ":</strong> " ..
        body .. "</div>"
end

function render_chat_sessions_list(sessions, current_session_id)
    items = ""
    for _, s in ipairs(sessions) do
        css_class = ""
        if current_session_id != nil and s.id == current_session_id then
            css_class = " class=\"platform-chat-session-active\""
        end
        label = s.title
        if label == nil or label == "" then
            label = "Untitled chat"
        end
        started_at = ""
        if s.created_at != nil then
            started_at = "<span class=\"platform-chat-session-started\">" .. html.html_escape(s.created_at) .. "</span>"
        end
        items = items .. "<li" .. css_class .. "><a href=\"chat?session_id=" .. s.id .. "\">" ..
            html.html_escape(label) .. "</a>" .. started_at .. "</li>"
    end
    if items == "" then
        return "<p class=\"platform-empty\">No chats yet.</p>"
    end
    return "<ul class=\"platform-chat-sessions\">" .. items .. "</ul>"
end

-- `pending`, if not nil, blocks the plain message input and shows an
-- approve/deny prompt instead -- a destructive tool call has to be
-- resolved before the conversation can continue.
function render_chat_pending(pending, csrf_token)
    json = require("dkjson")
    args, _, _ = json.decode(pending.args_json)
    if args == nil then
        args = {}
    end
    args_lines = ""
    for k, v in pairs(args) do
        args_lines = args_lines .. "<div>" .. html.html_escape(tostring(k)) .. " = " .. html.html_escape(tostring(v)) .. "</div>"
    end

    return string.format("""
    <div class="platform-chat-pending">
        <p><strong>The assistant wants to run:</strong> %s.%s</p>
        %s
        <form method="POST" action="chat-approve" class="platform-chat-pending-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="hidden" name="pending_id" value="%s">
            <input type="hidden" name="session_id" value="%s">
            <button type="submit" class="btn btn-primary">Approve</button>
        </form>
        <form method="POST" action="chat-deny" class="platform-chat-pending-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="hidden" name="pending_id" value="%s">
            <input type="hidden" name="session_id" value="%s">
            <button type="submit" class="btn btn-danger">Deny</button>
        </form>
    </div>
""", html.html_escape(pending.tool), html.html_escape(pending.method), args_lines,
     html.html_escape(csrf_token), tostring(pending.id), html.html_escape(pending.session_id),
     html.html_escape(csrf_token), tostring(pending.id), html.html_escape(pending.session_id))
end

function html.render_chat(sessions, session, messages, pending, csrf_token, nonce)
    current_session_id = nil
    if session != nil then
        current_session_id = session.id
    end
    sessions_html = render_chat_sessions_list(sessions, current_session_id)

    main_html = "<p class=\"platform-empty\">Start a new chat, or pick one from the list.</p>"
    if session != nil then
        messages_html = ""
        for _, msg in ipairs(messages) do
            messages_html = messages_html .. render_chat_message(msg)
        end
        if messages_html == "" then
            messages_html = "<p class=\"platform-empty\">No messages yet -- say something below.</p>"
        end

        input_html = ""
        if pending != nil then
            input_html = render_chat_pending(pending, csrf_token)
        else
            input_html = string.format("""
        <form method="POST" action="chat-message" class="platform-chat-input-form">
            <input type="hidden" name="csrf_token" value="%s">
            <input type="hidden" name="session_id" value="%s">
            <input type="text" name="message" placeholder="Ask something, or ask the assistant to search or create a document..." required autofocus>
            <button type="submit" class="btn btn-primary">Send</button>
        </form>
""", html.html_escape(csrf_token), html.html_escape(session.id))
        end

        main_html = "<div class=\"platform-chat-messages\">" .. messages_html .. "</div>" .. input_html
    end

    return string.format("""
<div class="fossil-doc" data-title="Chat">
    <style>
%s
%s
        .platform-header { margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-chat-layout { display: grid; grid-template-columns: 220px 1fr; gap: 20px; }
        .platform-chat-sessions { list-style: none !important; margin: 0; padding: 0; }
        .platform-chat-sessions li { margin: 4px 0; display: flex; flex-direction: column; }
        .platform-chat-sessions a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-chat-session-active a { text-decoration: underline; }
        .platform-chat-session-started { font-size: 0.75rem; color: var(--platform-muted, #64748b); }
        .platform-chat-new-form { display: flex; gap: 6px; margin-bottom: 16px; }
        .platform-chat-new-form input[type=text] { flex: 1; padding: 6px 8px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); }
        .platform-chat-messages { max-height: 55vh; overflow-y: auto; margin-bottom: 16px; padding: 12px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        .platform-chat-msg { margin-bottom: 10px; padding: 8px 10px; border-radius: var(--platform-radius-sm, 8px); background: #fff; border: 1px solid var(--platform-border, #e2e8f0); }
        .platform-chat-user { background: #eef2ff; }
        .platform-chat-tool_result { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; }
        .platform-chat-compaction_summary { font-style: italic; color: var(--platform-muted, #64748b); }
        .platform-chat-self_check { font-style: italic; color: var(--platform-muted, #64748b); border-left: 3px solid #fbbf24; }
        .platform-chat-out-of-context { opacity: 0.45; }
        .platform-chat-input-form { display: flex; gap: 8px; }
        .platform-chat-input-form input[type=text] { flex: 1; padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px); }
        .platform-chat-pending { padding: 14px; border: 1px solid #fde68a; background: #fffbeb; border-radius: var(--platform-radius-md, 12px); }
        .platform-chat-pending-form { display: inline-block; margin-right: 8px; margin-top: 8px; }
    </style>
    <div class="platform-container">
        <div class="platform-header"><h2>Chat</h2></div>
        <div class="platform-chat-layout">
            <div>
                <form method="POST" action="chat-start" class="platform-chat-new-form">
                    <input type="hidden" name="csrf_token" value="%s">
                    <input type="text" name="title" placeholder="New chat title">
                    <button type="submit" class="btn btn-secondary">+ New chat</button>
                </form>
                %s
            </div>
            <div>
                %s
            </div>
        </div>
    </div>
</div>
""", platform_container_css(1200), platform_button_css(), html.html_escape(csrf_token), sessions_html, main_html)
end

--------------------------------------------------------------------------
-- Floating chat widget -- rendered on every authenticated page (see
-- html.page_shell), talking to /api/chat-widget-* (cgi.lua) rather
-- than the full-page /chat/chat-start/chat-message/chat-approve/
-- chat-deny routes render_chat above uses. Its own session_id lives in
-- the browser's localStorage (not server-rendered state), so it
-- survives a normal, full-page navigation between one platform page
-- and the next the same way it would if this were a true SPA.
function platform_chat_widget_css()
    return """
.platform-chat-widget { position: fixed; right: 20px; bottom: 20px; z-index: 1000; font-family: inherit; }
.platform-chat-widget-toggle {
    width: 56px; height: 56px; border-radius: 50%;
    background: var(--platform-accent, #4f46e5); color: #ffffff; border: none;
    box-shadow: 0 4px 14px rgba(0,0,0,0.2); cursor: pointer;
    display: flex; align-items: center; justify-content: center;
    transition: var(--platform-transition, all 0.15s ease);
}
.platform-chat-widget-toggle:hover { filter: brightness(1.08); }
.platform-chat-widget-panel {
    position: absolute; right: 0; bottom: 64px; width: 320px; height: 440px;
    min-width: 280px; min-height: 320px; max-width: 90vw; max-height: 80vh;
    background: var(--platform-bg, #ffffff); border: 1px solid var(--platform-border, #e2e8f0);
    border-radius: var(--platform-radius-md, 12px); box-shadow: 0 10px 30px rgba(0,0,0,0.2);
    display: none; flex-direction: column; overflow: hidden;
}
.platform-chat-widget.platform-chat-widget-open .platform-chat-widget-panel { display: flex; }
/* Native CSS `resize: both` always draws its drag handle at the
   element's own bottom-right corner -- wrong here, since this panel
   is anchored bottom-right (right:0; bottom:64px) and grows up and to
   the left, which puts the free/grabbable corner at the TOP-left, not
   the bottom-right (which sits jammed against the toggle button and
   screen edge). `resize` has no way to relocate its handle to another
   corner, so this is a small custom drag handle + JS instead. */
.platform-chat-widget-resize-handle {
    position: absolute; top: 0; left: 0; width: 16px; height: 16px;
    cursor: nwse-resize; z-index: 1;
}
.platform-chat-widget-resize-handle::before {
    content: ""; position: absolute; top: 5px; left: 5px; width: 7px; height: 7px;
    border-top: 2px solid var(--platform-border-2, #cbd5e1);
    border-left: 2px solid var(--platform-border-2, #cbd5e1);
}
.platform-chat-widget-header {
    padding: 12px 14px; border-bottom: 1px solid var(--platform-border, #e2e8f0);
    font-weight: 700; color: var(--platform-heading, #0f172a); font-size: 0.95rem;
    display: flex; align-items: center; justify-content: space-between;
}
.platform-chat-widget-new {
    background: none; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-sm, 8px);
    color: var(--platform-accent, #4f46e5); font-size: 0.75rem; font-weight: 600; padding: 3px 8px; cursor: pointer;
}
.platform-chat-widget-new:hover { background: var(--platform-bg-2, #f1f5f9); }
.platform-chat-widget-messages { flex: 1; overflow-y: auto; padding: 10px; }
.platform-chat-widget-messages .platform-chat-msg { font-size: 0.85rem; }
.platform-chat-widget-input {
    display: flex; gap: 6px; padding: 10px; border-top: 1px solid var(--platform-border, #e2e8f0);
}
.platform-chat-widget-input input[type=text] {
    flex: 1; padding: 8px 10px; border: 1px solid var(--platform-border, #e2e8f0);
    border-radius: var(--platform-radius-sm, 8px); font-size: 0.85rem;
}
.platform-chat-widget-empty { padding: 20px; text-align: center; color: var(--platform-muted, #64748b); font-size: 0.85rem; }
.platform-chat-widget-thinking { padding: 8px 10px; color: var(--platform-muted, #64748b); font-size: 0.85rem; font-style: italic; }
.platform-chat-widget-error { padding: 8px 10px; color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-sm, 8px); font-size: 0.85rem; margin: 4px 0; }
.platform-chat-feedback { display: flex; gap: 4px; margin: 2px 0 8px 0; }
.platform-chat-feedback button {
    background: none; border: 1px solid transparent; border-radius: var(--platform-radius-sm, 8px);
    font-size: 0.85rem; padding: 1px 5px; cursor: pointer; line-height: 1.4; opacity: 0.6;
}
.platform-chat-feedback button:hover { opacity: 1; border-color: var(--platform-border, #e2e8f0); background: var(--platform-bg-2, #f1f5f9); }
.platform-chat-feedback button.platform-feedback-pressed { opacity: 1; border-color: var(--platform-border, #e2e8f0); background: var(--platform-bg-2, #f1f5f9); }
.platform-chat-feedback button:disabled { cursor: default; }
.platform-chat-feedback-error { color: #991b1b; font-size: 0.85rem; }
"""
end

function html.render_chat_widget(nonce)
    return string.format("""
<div class="platform-chat-widget" id="platform-chat-widget">
    <div class="platform-chat-widget-panel">
        <div class="platform-chat-widget-resize-handle" id="platform-chat-widget-resize-handle"></div>
        <div class="platform-chat-widget-header">Chat<button type="button" class="platform-chat-widget-new" id="platform-chat-widget-new" title="Start a new chat">+ New chat</button></div>
        <div class="platform-chat-widget-messages" id="platform-chat-widget-messages">
            <p class="platform-chat-widget-empty">Ask something, or ask the assistant to search or create a document...</p>
        </div>
        <form class="platform-chat-widget-input" id="platform-chat-widget-form">
            <input type="text" id="platform-chat-widget-text" placeholder="Message" required autofocus>
            <button type="submit" class="btn btn-primary">Send</button>
        </form>
    </div>
    <button type="button" class="platform-chat-widget-toggle" id="platform-chat-widget-toggle" aria-label="Chat">%s</button>
</div>
<script nonce="%s">
(function(){
    var STORAGE_KEY = 'platform_chat_widget_session';
    var root = document.getElementById('platform-chat-widget');
    var toggle = document.getElementById('platform-chat-widget-toggle');
    var messagesEl = document.getElementById('platform-chat-widget-messages');
    var form = document.getElementById('platform-chat-widget-form');
    var input = document.getElementById('platform-chat-widget-text');

    function getCsrfToken() {
        var match = document.cookie.match(/(?:^|;\\s*)csrf=([^;]*)/);
        return match ? match[1] : "";
    }

    // Builds a short, readable description from whatever page_shell
    // (see its own header comment) put in window.PLATFORM_PAGE_CONTEXT
    // for the current page -- every page sets at least page_type/title
    // now, entity pages/documents/views add entity_type+entity_id or
    // view_name on top.
    function describeCurrentPage() {
        var ctx = window.PLATFORM_PAGE_CONTEXT;
        if (!ctx) { return null; }
        var parts = [ctx.page_type || 'unknown'];
        if (ctx.title) { parts.push('"' + ctx.title + '"'); }
        if (ctx.entity_type && ctx.entity_id != null) {
            parts.push('(' + ctx.entity_type + ' id=' + ctx.entity_id + ')');
        } else if (ctx.view_name) {
            parts.push('(view=' + ctx.view_name + ')');
        }
        return parts.join(' ');
    }

    var ROLE_LABELS = {user: 'You', assistant: 'Assistant', tool_result: 'Tool result', compaction_summary: 'Compacted summary', self_check: 'Self-check'};
    // Same roles as html.lua's own CHAT_MARKDOWN_ROLES -- the server
    // (chat_widget_state, cgi.lua) already rendered these through
    // cmark-gfm before this JSON ever reached the browser, so this JS
    // trusts and embeds that HTML directly rather than re-escaping it
    // (which would just show the literal tags) or re-implementing
    // Markdown rendering client-side.
    var MARKDOWN_ROLES = {assistant: true, self_check: true, compaction_summary: true};
    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
    function render(state) {
        if (!state || !state.messages || state.messages.length === 0) {
            messagesEl.innerHTML = '<p class="platform-chat-widget-empty">Ask something, or ask the assistant to search or create a document...</p>';
        } else {
            var html = '';
            state.messages.forEach(function(msg){
                var label = ROLE_LABELS[msg.role] || msg.role;
                var body = MARKDOWN_ROLES[msg.role] ? msg.content : escapeHtml(msg.content);
                html += '<div class="platform-chat-msg platform-chat-' + msg.role + '"><strong>' + escapeHtml(label) + ':</strong> ' + body + '</div>';
                // task #87: feedback only makes sense on a real answer --
                // not on the user's own message, a tool result, or a
                // compaction summary the user never actually sees as a
                // "reply".
                if (msg.role === 'assistant') {
                    html += '<div class="platform-chat-feedback" data-feedback-for="' + msg.id + '">' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="up" title="Helpful">👍</button>' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="down" title="Not helpful">👎</button>' +
                        '</div>';
                }
            });
            messagesEl.innerHTML = html;
        }
        if (state && state.pending) {
            var argsLines = '';
            for (var k in state.pending.args) { argsLines += '<div>' + escapeHtml(k) + ' = ' + escapeHtml(state.pending.args[k]) + '</div>'; }
            messagesEl.innerHTML += '<div class="platform-chat-pending"><p><strong>Run:</strong> ' + escapeHtml(state.pending.tool) + '.' + escapeHtml(state.pending.method) + '</p>' + argsLines +
                '<button type="button" class="btn btn-primary" data-approve="' + state.pending.id + '">Approve</button> ' +
                '<button type="button" class="btn btn-danger" data-deny="' + state.pending.id + '">Deny</button></div>';
            form.style.display = 'none';
        } else {
            form.style.display = 'flex';
        }
        messagesEl.scrollTop = messagesEl.scrollHeight;
        syncSqlConsole(state);
    }

    // Prefills the /sql console's own query textarea from the agent's
    // most recent entity.query call this session (chat_widget_state,
    // cgi.lua) -- only on this specific page (page_type "sql", set by
    // page_shell), and only once per new value, so re-renders after an
    // unrelated turn (or the initial page-load fetch) don't keep
    // clobbering text the user is actively editing by hand. Writes the
    // query text only -- running it is still a deliberate click on
    // /sql's own Run button, through its own real capability check and
    // row cap, not something this widget ever does itself.
    var lastAppliedQuerySql = null;
    function syncSqlConsole(state) {
        if (!window.PLATFORM_PAGE_CONTEXT || window.PLATFORM_PAGE_CONTEXT.page_type !== 'sql') { return; }
        if (!state || !state.last_query_sql) { return; }
        if (state.last_query_sql === lastAppliedQuerySql) { return; }
        lastAppliedQuerySql = state.last_query_sql;
        var queryBox = document.getElementById('platform-sql-query');
        if (queryBox) { queryBox.value = state.last_query_sql; }
    }

    function post(url, body) {
        return fetch(url, {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken()},
            body: JSON.stringify(body)
        }).then(function(res){ return res.json(); });
    }

    function ensureSession() {
        var sessionId = localStorage.getItem(STORAGE_KEY);
        if (sessionId) return Promise.resolve(sessionId);
        return post('api/chat-widget-start', {}).then(function(state){
            localStorage.setItem(STORAGE_KEY, state.session_id);
            return state.session_id;
        });
    }

    var OPEN_KEY = 'platform_chat_widget_open';
    var SIZE_KEY = 'platform_chat_widget_size';
    var panel = root.querySelector('.platform-chat-widget-panel');

    // A full page load (not a SPA route change) re-renders this whole
    // widget from scratch every navigation, so "is the panel open"
    // needs its own persisted flag -- same reasoning as the session id
    // itself, just for UI state instead of conversation state.
    if (localStorage.getItem(OPEN_KEY) === '1') {
        root.classList.add('platform-chat-widget-open');
    }
    var savedSize = localStorage.getItem(SIZE_KEY);
    if (savedSize) {
        var parts = savedSize.split('x');
        if (parts.length === 2) {
            panel.style.width = parts[0] + 'px';
            panel.style.height = parts[1] + 'px';
        }
    }
    if (window.ResizeObserver) {
        new ResizeObserver(function(){
            // ResizeObserver fires once immediately on observe(), even
            // while the panel is display:none (offsetWidth/Height 0) --
            // guard against that firing clobbering a real saved size.
            if (panel.offsetWidth === 0 || panel.offsetHeight === 0) return;
            localStorage.setItem(SIZE_KEY, Math.round(panel.offsetWidth) + 'x' + Math.round(panel.offsetHeight));
        }).observe(panel);
    }

    var resizeHandle = document.getElementById('platform-chat-widget-resize-handle');
    resizeHandle.addEventListener('mousedown', function(e){
        e.preventDefault();
        var startX = e.clientX, startY = e.clientY;
        var startWidth = panel.offsetWidth, startHeight = panel.offsetHeight;
        function onMove(moveEvent) {
            // The handle sits at the panel's top-left corner, the
            // corner that's free to move (bottom-right is pinned via
            // the panel's own right:0; bottom:64px anchoring) -- so
            // dragging up-left (negative delta) grows the panel,
            // dragging down-right shrinks it. CSS min/max-width/height
            // on the panel itself still clamp the result.
            panel.style.width = (startWidth - (moveEvent.clientX - startX)) + 'px';
            panel.style.height = (startHeight - (moveEvent.clientY - startY)) + 'px';
        }
        function onUp() {
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onUp);
        }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
    });

    toggle.addEventListener('click', function(){
        var isOpen = root.classList.toggle('platform-chat-widget-open');
        localStorage.setItem(OPEN_KEY, isOpen ? '1' : '0');
    });

    document.getElementById('platform-chat-widget-new').addEventListener('click', function(){
        localStorage.removeItem(STORAGE_KEY);
        render(null);
    });

    function showThinking() {
        var el = document.createElement('div');
        el.className = 'platform-chat-widget-thinking';
        el.textContent = 'Thinking...';
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
        return el;
    }

    // A rejected fetch (network drop, a request landing mid-server-
    // restart, CORS, whatever) previously vanished completely -- the
    // thinking indicator was removed and nothing else happened, so a
    // real failure looked identical to "nothing was typed" (confirmed
    // live: reported as "showed thinking, then nothing, my message
    // wasn't even in the chat"). This is a different gap than
    // agent.execute_tool's own errors (agent.lua, server-persisted,
    // shows as a real transcript row) -- a fetch that never reaches
    // the server has nothing for the server to persist, so this has
    // to be a client-side-only message instead.
    function showFetchError() {
        var el = document.createElement('div');
        el.className = 'platform-chat-widget-error';
        el.textContent = 'Something went wrong sending that -- please try again.';
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    form.addEventListener('submit', function(e){
        e.preventDefault();
        var typedText = input.value;
        if (!typedText) return;
        input.value = '';
        var text = typedText;
        // Read lazily, at send time, not at widget-init time -- whatever
        // page.PLATFORM_PAGE_CONTEXT is *right now* is what the agent
        // should be told, every message, not just the first -- if the
        // widget's conversation carries over as the user browses to a
        // different page, the agent should track that, not still think
        // it's on wherever the chat happened to start.
        var pageDescription = describeCurrentPage();
        if (pageDescription) {
            text = '[Current page: ' + pageDescription + ']\n\n' + text;
        }
        if (window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.current_user) {
            text = '[Current user: ' + window.PLATFORM_PAGE_CONTEXT.current_user + ']\n' + text;
        }
        var thinkingEl = showThinking();
        ensureSession().then(function(sessionId){
            return post('api/chat-widget-send', {session_id: sessionId, message: text});
        }).then(function(state){ thinkingEl.remove(); render(state); })
          .catch(function(){ thinkingEl.remove(); showFetchError(); input.value = typedText; });
    });

    messagesEl.addEventListener('click', function(e){
        var sessionId = localStorage.getItem(STORAGE_KEY);
        if (e.target.hasAttribute('data-approve')) {
            var thinkingEl = showThinking();
            post('api/chat-widget-approve', {pending_id: e.target.getAttribute('data-approve'), session_id: sessionId})
                .then(function(state){ thinkingEl.remove(); render(state); })
                .catch(function(){ thinkingEl.remove(); showFetchError(); });
        } else if (e.target.hasAttribute('data-deny')) {
            post('api/chat-widget-deny', {pending_id: e.target.getAttribute('data-deny'), session_id: sessionId}).then(render);
        } else if (e.target.hasAttribute('data-feedback')) {
            var messageId = e.target.getAttribute('data-feedback-message');
            var feedback = e.target.getAttribute('data-feedback');
            var container = e.target.closest('.platform-chat-feedback');
            // task #115: mark the clicked button as pressed and disable
            // both immediately, before the request even resolves --
            // previously nothing happened visually until (and unless)
            // the async call both succeeded and resolved, which read as
            // "the button does nothing" even when it was working.
            if (container) {
                container.querySelectorAll('button').forEach(function(b){ b.disabled = true; });
                e.target.classList.add('platform-feedback-pressed');
            }
            function showFeedbackError() {
                if (container) { container.innerHTML = '<span class="platform-chat-feedback-error">Couldn\'t record feedback.</span>'; }
            }
            post('api/chat-widget-feedback', {message_id: messageId, feedback: feedback}).then(function(result){
                if (!container) return;
                if (result && result.ok) {
                    container.innerHTML = feedback === 'up' ? 'Thanks for the feedback 👍' : 'Thanks for the feedback 👎';
                } else {
                    showFeedbackError();
                }
            }).catch(showFeedbackError);
        }
    });

    var existingSessionId = localStorage.getItem(STORAGE_KEY);
    if (existingSessionId) {
        fetch('api/chat-widget-history?session_id=' + encodeURIComponent(existingSessionId))
            .then(function(res){ if (!res.ok) { throw new Error('no session'); } return res.json(); })
            .then(render)
            .catch(function(){ localStorage.removeItem(STORAGE_KEY); });
    }
})();
</script>
""", ICON_CHAT_BUBBLE, nonce)
end

return html
