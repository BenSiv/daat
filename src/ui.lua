asset = require("asset")
db = require("database")
schema = require("schema")
view = require("view")
config = require("config")
document = require("document")
html_lib = require("html")
ui_assets = require("ui.assets")

html = {}

-- label_print_button_html/label_print_js/related_records_html/
-- platform_chat_widget_css used before their own definitions below --
-- pre-declared, see ../../luam/doc/forward_references.md
label_print_button_html, label_print_js, related_records_html, platform_chat_widget_css = nil, nil, nil, nil

-- Context-aware HTML body/attribute, inline-<script> JSON, and JS
-- string-literal escaping primitives live in luam/lib/html.lua.
html.escape = html_lib.escape
html.html_escape = html_lib.html_escape
json_for_script = html_lib.json_for_script
js_string_literal = html_lib.js_string_literal

-- The ".platform-container" shell (card look: padding/shadow/border/
-- rounded corners) was copy-pasted, identically byte-for-byte except
-- max_width, into every render_* function's own inline <style> block --
-- ten separate copies, each supplying whatever max-width its own page
-- happened to have picked (1200/1400/1100/1000/900/800), with no
-- reason for most of the differences beyond drift. One shared,
-- parameterless definition instead: PLATFORM_CONTENT_MAX_WIDTH is a
-- single generous ceiling, not a per-page design width -- min(...,
-- 95vw) already means it only ever matters on unusually wide screens,
-- so every normal-to-large screen just fills ~95% of the viewport
-- instead of landing on whichever number a given page happened to
-- carry. (Two pages -- render_login/render_account -- still include
-- this CSS but never apply the .platform-container class at all; their
-- actual card is the separately-sized .platform-login-card/
-- .platform-account-card, so this rule is inert there either way.)
PLATFORM_CONTENT_MAX_WIDTH = 2400

-- The standard page gutter -- shared by the main content area's own
-- top margin and side gutters (platform_container_css) and the
-- floating chat widget's own right/bottom offset and stretch limits
-- (platform_chat_widget_css), so the two stay in lockstep by
-- construction instead of by coincidence (both happened to independently
-- land on 20px before this). Previously platform_container_css's own
-- side gutter came from `max-width: min(2400px, 95vw)` -- `vw` is
-- relative to the *whole* viewport, ignoring that .platform-container
-- actually sits inside .platform-main (viewport width minus the nav
-- rail), so the real rendered gutter shrank to a few px (or 0) on most
-- real screen widths, well below this constant's own value and nothing
-- like the chat widget's fixed 20px. calc(100% - 2*PLATFORM_GUTTER)
-- below is relative to .platform-container's actual containing block
-- instead, which fixes that.
PLATFORM_GUTTER = 20

-- The icon nav rail's own width -- shared with the chat widget's own
-- stretch-to-nav-edge limit (platform_chat_widget_css) the same way
-- PLATFORM_GUTTER is shared between the main content gutter and the
-- chat widget's offset. Before this, .platform-nav's width and the
-- chat panel's max-width calc each carried their own literal "72px"
-- that happened to agree only because a human kept them in sync by
-- hand -- structurally identical to the gutter/chat-offset drift this
-- same session already fixed once, just not yet caught here. One
-- number now, not two coincidentally-matching ones.
PLATFORM_NAV_WIDTH = 72

-- One shared context table for every layout CSS block below, rendered
-- via render.lua's named {{{ }}} placeholders instead of positional
-- string.format args -- the exact bug class PLATFORM_GUTTER/
-- PLATFORM_NAV_WIDTH's own comments describe (two literals that only
-- coincidentally agreed) had a second form: a shared value threaded
-- into a five-argument string.format call by *position*, one
-- transposition away from silently rendering the wrong number with no
-- error. gutter_x2 is precomputed here rather than written as two
-- separate {{{layout.gutter}}} subtractions in the template, so the
-- rendered CSS text stays byte-identical to what string.format
-- produced before this. Defined before every function below that
-- closes over it -- Luam's implicit-local scoping (like Lua's real
-- `local`) only takes effect from this point in the chunk onward, so
-- a function defined earlier that referenced this name would silently
-- resolve it as an unset global instead.
PLATFORM_LAYOUT = {
    gutter = PLATFORM_GUTTER,
    gutter_x2 = PLATFORM_GUTTER * 2,
    nav_width = PLATFORM_NAV_WIDTH,
    content_max_width = PLATFORM_CONTENT_MAX_WIDTH,
}

function platform_container_css()
    render_lib = require("render")
    return render_lib.render("""
        .platform-container {
            font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            color: var(--platform-text, #334155);
            background: #ffffff;
            padding: 28px;
            border-radius: var(--platform-radius-lg, 16px);
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.05);
            margin: {{{layout.gutter}}}px auto;
            max-width: min({{{layout.content_max_width}}}px, calc(100% - {{{layout.gutter_x2}}}px));
            border: 1px solid var(--platform-bg-2, #f1f5f9);
        }
""", {layout = PLATFORM_LAYOUT})
end

-- Extracted out of html.page_shell's own giant template literal so
-- PLATFORM_NAV_WIDTH can reach the one CSS rule that needs it
-- (.platform-nav's own width) without renumbering that literal's
-- existing, already-long positional string.format argument list --
-- same "small format() island, threaded in as one more %s" technique
-- platform_chat_widget_css uses internally.
function platform_nav_css()
    render_lib = require("render")
    return render_lib.render("""
.platform-nav {
    width: {{{layout.nav_width}}}px;
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
""", {layout = PLATFORM_LAYOUT}) .. """
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
    left: calc(100% + 8px);
    top: 50%;
    transform: translateY(-50%);
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
.platform-nav-user a { display: block; font-size: 0.75rem; color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
.platform-nav-user a:hover { text-decoration: underline; }
.platform-nav-brand { display: block; padding: 4px; margin-bottom: 8px; text-align: center; }
.platform-nav-brand img { width: 100%; max-width: 40px; height: auto; display: block; margin: 0 auto; }
"""
end

-- .platform-table-wrapper (the scroll/border/background shell around a
-- data table) and .platform-empty (its "no rows" placeholder) were
-- hand-copied into nine different render_* functions' own <style>
-- blocks, byte-identical apart from one unexplained margin-top variant
-- -- the same drift shape platform_container_css's old max_width
-- parameter had. One shared copy instead; a page that needs only one
-- of the two rules (e.g. render_detail has no empty-state, render_index/
-- render_templates_list have no table) just leaves the other unused,
-- same as this codebase already tolerates elsewhere (e.g. render_login/
-- render_account include platform_container_css() without ever
-- applying .platform-container at all). Two pages need a genuinely
-- different look on top of this base -- html.render's editable
-- registration grid, and html.render_sql's results table sitting below
-- a query editor -- both call this for the shared base, then layer
-- their own small override rule after it rather than re-declaring the
-- whole thing.
function platform_table_wrapper_css()
    return """
        .platform-table-wrapper { overflow-x: auto; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); background: var(--platform-bg, #f8fafc); }
        .platform-empty { padding: 32px; text-align: center; color: var(--platform-muted, #64748b); background: var(--platform-bg, #f8fafc); border: 1px dashed var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
"""
end

-- .cell-input/.error-badge/.autocomplete-results/.status-msg: html.render
-- (the registration batch table) and html.render_entity_edit (the
-- single-row edit form) each hand-copied their own version of these,
-- and had drifted for real, not just cosmetically -- render_entity_edit
-- never picked up the focus ring, the error box-shadow, or the
-- status-msg fade-in animation render() has. Worse: render()'s own
-- ".autocomplete-item" selector is dead CSS that has never matched
-- anything -- PlatformJS.setupAutocomplete (this file's own shared
-- suggestion-dropdown JS) builds each option as a bare <div> with no
-- class at all, so only render_entity_edit's ".autocomplete-results
-- div" selector was ever real; /register's own autocomplete dropdown
-- has been rendering completely unstyled (no padding, no hover
-- highlight) the whole time. One shared, correct copy now. Callers
-- needing a narrower layout (render_entity_edit's own max-width: 640px
-- on .status-msg, matching its single-column form) layer that as a
-- small override after this, same as platform_table_wrapper_css's own
-- per-page overrides.
function platform_cell_editor_css()
    return """
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
        .autocomplete-results div {
            padding: 9px 14px;
            cursor: pointer;
            font-size: 0.85rem;
            transition: all 0.15s ease;
            color: var(--platform-text, #334155);
        }
        .autocomplete-results div:hover { background: var(--platform-bg-2, #f1f5f9); color: var(--platform-heading, #0f172a); }
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
"""
end

-- Shared .btn/.btn-primary/.btn-secondary/.btn-delete/.btn-danger rules --
-- previously three separate, hand-copied inline copies (render(),
-- render_browse(), render_sql()) that had quietly drifted apart:
-- render_sql()'s never picked up the shared .btn base at all (no
-- flex-centering, no shared transition/padding token), and its
-- .btn-secondary was a whole font-size step smaller (0.85rem vs the
-- others' inherited 0.9rem). One copy now, used everywhere a button
-- appears. .btn-danger is for a genuinely one-way negative action --
-- Archive, Deny -- as opposed to .btn-delete's own narrower "remove
-- this not-yet-saved row" icon-button use, or a reversible toggle like
-- Unarchive/Approve, which stay .btn-secondary/.btn-primary.
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
            /* !important on both of these: a generic "a { color:
               var(--platform-accent) }"/"a:hover { text-decoration:
               underline }" rule scoped to some surrounding wrapper
               (.platform-header a and friends, hand-copied across ~18
               render_* functions) has higher specificity than a bare
               .btn-* class, so a <a class="btn btn-primary"> sitting
               inside one can silently lose its own white text to the
               wrapper's accent-color rule -- on an amber accent theme,
               that makes the button's text exactly match its own
               background: invisible, not just low-contrast. Centralized
               here (the one shared place every .btn already comes from)
               instead of chasing down every current and future
               wrapper-link rule with its own :not(.btn) exception. */
            text-decoration: none !important;
        }
        .btn:hover { text-decoration: none !important; }
        .btn-primary {
            background: var(--platform-accent, #4f46e5);
            color: #ffffff !important;
        }
        .btn-primary:hover { filter: brightness(1.08); }
        .btn-primary:active { transform: scale(0.98); }
        .btn-secondary {
            background: var(--platform-bg, #f8fafc);
            color: var(--platform-th-text, #475569) !important;
            border: 1px solid var(--platform-border, #e2e8f0);
        }
        .btn-secondary:hover { background: var(--platform-bg-2, #f1f5f9); color: var(--platform-heading, #0f172a) !important; }
        .btn-secondary:active { transform: scale(0.98); }
        .btn-secondary:disabled { opacity: 0.6; cursor: default; transform: none; }
        .btn-danger {
            background: var(--platform-bg, #f8fafc);
            color: #b91c1c !important;
            border: 1px solid #fecaca;
        }
        .btn-danger:hover { background: #fef2f2; color: #b91c1c !important; }
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

-- Shared "sitemap" card-grid CSS -- was hand-copied identically across
-- render_home/render_system. The whole card is now the hit target, not
-- just the title text -- same mechanism html.render_index's own
-- .platform-index-list already uses for /data's entity-type cards (put
-- everything inside the one <a>, then stretch that <a> to fill its
-- parent via display:block, rather than a sibling <a>+<p> where only
-- the <a> was ever clickable).
function platform_sitemap_css()
    return """
        .platform-sitemap { list-style: none !important; margin: 16px 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
        .platform-sitemap li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); overflow: hidden; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-sitemap li:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-sitemap a { display: block; padding: 16px 18px; text-decoration: none !important; }
        .platform-sitemap a strong { display: block; font-weight: 700; color: var(--platform-accent, #4f46e5); font-size: 1.05rem; }
        .platform-sitemap a:hover strong { text-decoration: underline; }
        .platform-sitemap p { margin: 6px 0 0 0; color: var(--platform-muted, #64748b); font-size: 0.9rem; }
"""
end

-- One sitemap card, whole-card clickable (see platform_sitemap_css).
function render_sitemap_item(href, title, description)
    return "<li><a href=\"" .. href .. "\"><strong>" .. html.html_escape(title) .. "</strong><p>" ..
        html.html_escape(description) .. "</p></a></li>"
end

-- "Related records" styling (related_records_html's markup) -- shared
-- by the generic /detail page and a document's own page.
function platform_related_css()
    return """
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
"""
end

-- Shared page-header CSS -- was hand-copied, with real drift, across
-- ~19 separate render_* functions in this file: margin-bottom 20px vs
-- 24px depending which function you looked at, some missing the flex/
-- space-between layout entirely, render_document missing the h2's own
-- bottom margin. Centralized here the same way platform_button_css/
-- platform_sitemap_css/html.popover_css already centralize their own
-- components -- see render_page_header for the matching markup helper.
function platform_page_header_css()
    return """
        .platform-header { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 16px; margin-bottom: 20px; border-bottom: 1px solid var(--platform-bg-2, #f1f5f9); padding-bottom: 16px; }
        .platform-header h2 { margin: 0 0 6px 0; font-size: 1.6rem; font-weight: 700; color: var(--platform-heading, #0f172a); letter-spacing: -0.02em; }
        .platform-header p { color: var(--platform-muted, #64748b); margin: 0; font-size: 0.95rem; }
        .platform-header p a { color: var(--platform-accent, #4f46e5); }
        .platform-header > div:first-child { min-width: 0; }
"""
end

-- Wraps every document.render_plot output (document content and chat
-- alike, since both bottom out in document.render_markdown). overflow-x
-- rather than a fixed max-width -- a plot is a fixed-size SVG (gnuplot's
-- own width/height), and the narrowest surface this renders into is the
-- ~280px-wide chat panel, so a plot wider than its container scrolls in
-- its own box instead of the page/panel scrolling sideways.
function html.plot_css()
    return """
        .platform-plot { overflow-x: auto; margin: 12px 0; }
        .platform-plot svg { display: block; }
        .platform-plot-error { color: var(--platform-muted, #64748b); font-size: 0.88rem; font-style: italic; }
"""
end

-- One page header: a title, optional extra markup under it (a
-- subtitle <p>, a back-link, more than one paragraph -- caller's own
-- raw HTML, or nil/"" for none), and an optional right-aligned action
-- (a .btn link, a toggle control, or nil/"" for none). `title` is
-- placed unescaped, same trust level render_* functions already give
-- their own title interpolations (an entity_type/document title that
-- reaches here has already been through html.html_escape by the
-- caller, or is a literal like "Settings").
function render_page_header(title, extra, action)
    if extra == nil then
        extra = ""
    end
    if action == nil then
        action = ""
    end
    return "<div class=\"platform-header\"><div><h2>" .. title .. "</h2>" .. extra .. "</div>" .. action .. "</div>"
end

-- The post-action status banner ("User created", "Wrong password", ...)
-- shown at the top of render_admin_users/render_admin_api_keys/
-- render_settings -- both this Lua and its .platform-admin-message*
-- CSS (platform_admin_message_css() below) were hand-copied
-- identically into all three. One shared pair instead.
function render_admin_message(message, is_error)
    if message == nil or message == "" then
        return ""
    end
    css_class = "platform-admin-message"
    if is_error == true then
        css_class = "platform-admin-message platform-admin-message-error"
    end
    return "<div class=\"" .. css_class .. "\">" .. html.html_escape(message) .. "</div>"
end

function platform_admin_message_css()
    return """
        .platform-admin-message { padding: 10px 12px; margin-bottom: 16px; border-radius: var(--platform-radius-item, 10px); background: #f0fdf4; border: 1px solid #bbf7d0; color: #166534; font-size: 0.9rem; }
        .platform-admin-message-error { background: #fef2f2; border-color: #fecaca; color: #991b1b; }
"""
end

-- A plain inline error banner -- render_login's own ".platform-login-
-- error" rule, reused verbatim under that login-specific name by
-- render_document_edit for an unrelated save error. Same rule, generic
-- name instead of a borrowed one.
function platform_error_banner_css()
    return """
        .platform-error-banner { color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-item, 10px); padding: 10px 12px; margin-bottom: 14px; font-size: 0.88rem; }
"""
end

-- "daat canvas" -- a plugin's page is a plain Lua table of predefined
-- elements (heading/text/table/button), never raw HTML/JS from the
-- plugin (see doc/plugin-system-research.md). Modeled directly on
-- template.lua's own section.type dispatch (validate/render pairs,
-- one function per type) -- the same "typed-table -> trusted renderer"
-- shape, just aimed at live HTML instead of a Markdown snippet.
-- Vocabulary is deliberately small; grow it only when a real plugin
-- needs a new element type, the same way template.lua's own vocabulary
-- grew by four types over real demand, not speculatively.
function platform_canvas_css()
    return asset.read("ui/canvas.css")
end

-- Checks each element's `type` against the known vocabulary and that
-- type's required fields -- the same role template.validate plays for
-- template sections. Returns an error string, or nil if every element
-- is well-formed.
function html.validate_canvas(elements)
    if type(elements) != "table" then
        return "canvas must be a list of elements"
    end
    for i, element in ipairs(elements) do
        if element.type == "heading" or element.type == "text" then
            if type(element.text) != "string" or element.text == "" then
                return string.format("canvas element #%d (%s): missing 'text'", i, element.type)
            end
        elseif element.type == "table" then
            if type(element.columns) != "table" or #element.columns == 0 then
                return string.format("canvas element #%d (table): must have a non-empty 'columns' list", i)
            end
            if type(element.rows) != "table" then
                return string.format("canvas element #%d (table): must have a 'rows' list", i)
            end
        elseif element.type == "button" then
            if type(element.label) != "string" or element.label == "" then
                return string.format("canvas element #%d (button): missing 'label'", i)
            end
            if type(element.action) != "string" or element.action == "" then
                return string.format("canvas element #%d (button): missing 'action'", i)
            end
        elseif element.type == "input" then
            if type(element.name) != "string" or element.name == "" then
                return string.format("canvas element #%d (input): missing 'name'", i)
            end
        else
            return string.format("canvas element #%d: invalid type '%s'", i, tostring(element.type))
        end
    end
    return nil
end

function render_canvas_table(element)
    header_cells = ""
    for _, col in ipairs(element.columns) do
        header_cells = header_cells .. "<th>" .. html.html_escape(tostring(col)) .. "</th>"
    end
    body_rows = ""
    for _, row in ipairs(element.rows) do
        cells = ""
        for _, value in ipairs(row) do
            cells = cells .. "<td>" .. html.html_escape(tostring(value)) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end
    return "<div class=\"platform-canvas-element platform-table-wrapper\"><table class=\"platform-canvas-table\"><thead><tr>" ..
        header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
end

function render_canvas_button(element)
    json = require("dkjson")
    args = element.args
    if args == nil then
        args = {}
    end
    -- html.html_escape, not json_for_script -- this JSON lands inside
    -- an HTML attribute value (data-args="..."), not a <script> body,
    -- so it needs ordinary attribute escaping (quotes/angle brackets),
    -- not json_for_script's own </script>-breakout escaping.
    return string.format(
        "<div class=\"platform-canvas-element\"><button type=\"button\" class=\"btn btn-primary platform-canvas-action\" data-action=\"%s\" data-args=\"%s\">%s</button></div>",
        html.html_escape(element.action), html.html_escape(json.encode(args)), html.html_escape(element.label)
    )
end

-- `name` rides in a data-input-name attribute rather than the input's
-- own `name` (no <form> wraps this -- canvas.js reads it directly, no
-- native form submission involved). `label`/`placeholder` both
-- optional -- an omitted one just renders as an empty/absent string,
-- same convention as button's own optional `args`.
function render_canvas_input(element)
    label_html = ""
    if element.label != nil and element.label != "" then
        label_html = "<label class=\"platform-canvas-input-label\">" .. html.html_escape(element.label) .. "</label>"
    end
    placeholder = ""
    if element.placeholder != nil then
        placeholder = element.placeholder
    end
    return string.format(
        "<div class=\"platform-canvas-element platform-canvas-input-wrapper\">%s<input type=\"text\" class=\"platform-canvas-input\" data-input-name=\"%s\" placeholder=\"%s\"></div>",
        label_html, html.html_escape(element.name), html.html_escape(placeholder)
    )
end

-- Turns a validated element list into real HTML -- the only place that
-- happens; a plugin never supplies markup itself, only these typed
-- tables (see this function's own header comment above
-- platform_canvas_css). Caller is expected to have already checked
-- html.validate_canvas -- an invalid element here just renders nothing
-- for that one entry rather than crashing the whole page.
function html.render_canvas(elements)
    parts = {}
    for _, element in ipairs(elements) do
        if element.type == "heading" then
            table.insert(parts, "<h3 class=\"platform-canvas-element platform-canvas-heading\">" .. html.html_escape(element.text) .. "</h3>")
        elseif element.type == "text" then
            table.insert(parts, "<p class=\"platform-canvas-element platform-canvas-text\">" .. html.html_escape(element.text) .. "</p>")
        elseif element.type == "table" then
            table.insert(parts, render_canvas_table(element))
        elseif element.type == "button" then
            table.insert(parts, render_canvas_button(element))
        elseif element.type == "input" then
            table.insert(parts, render_canvas_input(element))
        end
    end
    return table.concat(parts)
end

-- The small click-delegation script every plugin page needs: a button
-- (.platform-canvas-action, rendered by render_canvas_button above)
-- posts its declared action+args to this exact page's own /action
-- sub-path (cgi.lua's POST /ext/<name>/action) and swaps the response's
-- re-rendered canvas HTML straight in -- the plugin never gets a live
-- event loop or client-side code of its own, only "this named,
-- capability-checked action happened, here's the new canvas."
--
-- Live .platform-canvas-input values are collected at click time and
-- merged into that same args object (input values win over a
-- same-named static arg, since they're the current, user-supplied
-- ones) -- one flat args table either way, so an action handler never
-- needs to know whether a given key came from the button's own
-- declared args or from a box the user just typed into. Enter inside
-- an input clicks the container's first action button -- there's no
-- explicit input-to-button association beyond that (this vocabulary
-- grows when a real plugin needs more structure, not speculatively;
-- today's only caller is one search box + one search button).
function html.canvas_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/canvas.js"))
end

-- A plugin's whole page: the canvas its render() hook returned, wrapped
-- in the same .platform-container shell every other page uses. Only
-- cgi.lua's own GET /ext/<name> route calls this -- the extension
-- itself never sees or supplies any of this markup.
function html.render_plugin_page(label, elements, nonce)
    escaped_label = html.html_escape(label)
    page_header = render_page_header(escaped_label, nil, nil)
    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
%s
%s
    </style>
    <div class="platform-container">
        %s
        <div class="platform-canvas-container">%s</div>
    </div>
</div>
%s
""", escaped_label, platform_container_css(), platform_button_css(), platform_canvas_css(),
     page_header, html.render_canvas(elements), html.canvas_js(nonce))
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
    return ui_assets.inline_style(asset.read("ui/popover.css"))
end

-- `nonce` must be Fossil's own per-request CSP nonce (see html.render's
-- own comment below) since this emits an inline <script>.
function html.popover_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/popover.js"))
end

-- Shared client-side helpers -- CSRF-token reading, JSON fetch/post,
-- HTML-escaping, debounce, outside-click-close, and cell-error display --
-- previously hand-copied (in some cases 3x, byte-near-identical) across
-- html.render/html.render_entity_edit/html.render_index/
-- html.render_document_tree/html.render_chat_widget. A per-field-type
-- input builder (PlatformJS.buildFieldInput, the biggest single
-- duplication in the file) and the shared autocomplete implementation
-- join this same namespace in a later migration step, once these smaller
-- primitives they depend on (postJSON, debounce, onOutsideClick,
-- clearCellError/highlightError) are already proven out.
-- Emitted once per page from html.page_shell (same treatment as
-- platform_button_css()/html.popover_css() for CSS: define the shared
-- component once, guard it, let every caller reuse it instead of
-- re-deriving it) -- safe to emit unconditionally on every page since it
-- only defines a namespace object with zero top-level side effects (no
-- DOM queries, no listeners registered at load time), exactly like
-- page_shell's own PLATFORM_PAGE_CONTEXT script tag it sits beside.
function platform_common_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/common.js"))
end

-- The CSS custom-property names a theme may override, in a fixed
-- display order -- matches config.lua's own THEME_COLOR_KEYS exactly.
THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
    "tier_0", "tier_1", "tier_2", "tier_3",
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
ICON_KNOWLEDGE = "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z\"/><path d=\"M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z\"/></svg>"
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
-- generic fallback instead of the deployment's real palette.
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
-- user currently is" (see doc/architecture.md's "Chat" section,
-- render_chat_widget's script, and agent_tools.default_system_prompt).
-- Callers that know more than the bare nav section (a document's own
-- id, an entity's type+id, a view's name) should pass their own richer
-- table; nil falls back to just {page_type = active, title = title} --
-- still real signal (which nav section, what the page is titled), just
-- not entity-specific.
--
-- current_user is merged in here unconditionally (every caller gets it
-- for free, not just the ones that already pass a rich context) -- so
-- the model always knows who it's talking to and can default owner/
-- assignee-style fields to the current user, the way a human filling
-- out the same form naturally would.
-- Deployment-level nav rail reorder/hide (brex 683042859,
-- platform.lua's own nav_order/nav_hidden -- see config.lua's own
-- validate_nav_key_list). Deliberately an overlay applied AFTER
-- nav_items is already built from capability/deployment-state checks
-- below, never a replacement for them: this can only reorder or
-- further hide what would already render for this user, never grant
-- back something their own capabilities/deployment state already
-- excluded (no Setup/Admin cap, no prioritized_tasks view, an
-- unapproved extension). An unrecognized key in either list (a typo,
-- an extension that's since been removed) is a silent no-op, matching
-- every other malformed-config-falls-back-quietly convention this
-- config system already follows.
function apply_nav_hidden(nav_items, hidden_keys)
    if hidden_keys == nil or #hidden_keys == 0 then
        return nav_items
    end
    hidden_set = {}
    for _, key in ipairs(hidden_keys) do
        hidden_set[key] = true
    end
    result = {}
    for _, item in ipairs(nav_items) do
        if hidden_set[item.key] == nil then
            table.insert(result, item)
        end
    end
    return result
end

-- order lists keys in the desired position; any real nav item whose
-- key isn't mentioned keeps its original relative order, appended
-- after every explicitly-ordered one -- so a deployment only needs to
-- name the items it actually wants moved, not repeat the full list
-- (and can never accidentally drop one it forgot to mention).
function apply_nav_order(nav_items, order_keys)
    if order_keys == nil or #order_keys == 0 then
        return nav_items
    end
    by_key = {}
    for _, item in ipairs(nav_items) do
        by_key[item.key] = item
    end
    result = {}
    placed = {}
    for _, key in ipairs(order_keys) do
        item = by_key[key]
        if item != nil and placed[key] == nil then
            table.insert(result, item)
            placed[key] = true
        end
    end
    for _, item in ipairs(nav_items) do
        if placed[item.key] == nil then
            table.insert(result, item)
        end
    end
    return result
end

function html.page_shell(title, active, body, nonce, show_sql, show_admin, has_tasks_view, nav_extensions, theme, author, page_context)
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

    -- Icon-rail order: Home, Documents, Data, Knowledge Pool, Tasks,
    -- (System if Setup/Admin). No separate New Document icon -- the
    -- document tree's own "+ New document" button already covers that
    -- entry point. Chat has no rail icon of its own either; it's the
    -- floating widget below.
    --
    -- Knowledge Pool is a plain baseline-capability rail item, not
    -- gated on show_sql/show_admin -- it's read-only browsing (stats,
    -- documents, graph, retrievals), nothing about it is an admin
    -- action, so it no longer lives behind /system (brex 492390825).
    --
    -- No real nav items at all when nobody's authenticated (author ==
    -- nil, e.g. /login) -- every one of them just bounces back to
    -- /login anyway, so a fully visible, clickable nav rail on the
    -- login page itself would just be confusing.
    nav_items = {}
    if author != nil then
        nav_items = {
            {key = "home", href = "/", label = "Home", icon = ICON_HOME},
            {key = "documents", href = "documents", label = "Documents", icon = ICON_NOTEBOOK},
            {key = "data", href = "data", label = "Data", icon = ICON_DATA},
            {key = "knowledge", href = "knowledge", label = "Knowledge Pool", icon = ICON_KNOWLEDGE},
        }
        -- Only a real rail icon when a deployment actually seeded a
        -- "prioritized_tasks" view -- see the matching comment in
        -- render_home.
        if has_tasks_view == true then
            table.insert(nav_items, {key = "tasks", href = "view?view_name=prioritized_tasks", label = "Tasks", icon = ICON_TASKS})
        end
        if show_sql or show_admin then
            table.insert(nav_items, {key = "system", href = "system", label = "System", icon = ICON_SYSTEM})
        end
        -- One rail entry per approved, UI-capable extension
        -- (extension.approved_with_ui, computed once by the caller) --
        -- see doc/plugin-system-research.md. icon is manifest-supplied
        -- (a plain emoji, not trusted SVG like ICON_HOME/etc. above),
        -- so it's html_escape'd here before landing in the same `icon`
        -- field the render loop below inserts unescaped.
        if nav_extensions != nil then
            for _, entry in ipairs(nav_extensions) do
                ui = entry.manifest.capabilities.ui
                table.insert(nav_items, {
                    key = "ext:" .. entry.name, href = "ext/" .. entry.name,
                    label = ui.label, icon = html.html_escape(ui.icon),
                })
            end
        end
        nav_config = config.platform_config()
        nav_items = apply_nav_hidden(nav_items, nav_config.nav_hidden)
        nav_items = apply_nav_order(nav_items, nav_config.nav_order)
    end

    -- Only rendered when the deployment's own theme.lua sets
    -- has_logo = true (a real logo.png is seeded at theme-assets/) --
    -- generic/unconfigured deployments get no logo slot at all rather
    -- than a broken-image icon.
    brand_html = ""
    if theme.has_logo == true then
        brand_html = string.format(
            "<a class=\"platform-nav-brand\" href=\"/\" title=\"%s\"><img src=\"theme-asset?name=logo.png\" alt=\"%s\"></a>",
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
            "<a class=\"%s\" href=\"%s\" title=\"%s\">%s<span class=\"platform-nav-label\">%s</span></a>",
            link_class, item.href, html.html_escape(item.label), item.icon, html.html_escape(item.label)
        ))
    end

    -- Single clickable entry point -- the username itself links to
    -- /account, which hosts both password-change and log-out. Keeps
    -- the sidebar minimal rather than growing it with more per-feature
    -- links.
    user_box = ""
    if author != nil then
        user_box = string.format("""
<div class="platform-nav-user">
    <a class="platform-nav-user-name" href="account">%s</a>
</div>
""", html.html_escape(author))
    end

    -- No chat widget for an unauthenticated page either -- same
    -- reasoning as nav_items above. The backend already rejects an
    -- unauthenticated /api/chat-widget-start or /api/chat-widget-send
    -- before it ever reaches the agent/Vertex AI call (cgi.handle_request's
    -- own session check runs first), so this isn't a billing/security
    -- gap by itself -- but showing a chat box nobody can actually use
    -- is confusing UX, and only ever produces a confusing JSON error
    -- response its own JS isn't expecting, not a real conversation.
    chat_widget_html = ""
    if author != nil then
        chat_widget_html = html.render_chat_widget(nonce, config.platform_config().chat_attachments_enabled == true)
    end

    return string.format("""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Every relative href/src in this app (nav links, theme-asset,
     vendor, etc.) is written assuming it resolves against the site
     root -- true by construction for every route that existed before
     capabilities.ui extensions (all single-segment: /documents, /data,
     /chat, ...), so it never needed stating explicitly. /ext/<name>
     (and its .../action sibling) is the first real nested path
     (confirmed live: the sidebar logo and every nav link 404'd on that
     page, each silently resolving one level too deep, e.g.
     /ext/theme-asset instead of /theme-asset) -- pin the base
     explicitly rather than rewrite every existing relative reference,
     since a root base changes nothing for the already-root-relative
     pages and fixes any current or future nested one. -->
<base href="/">
<title>%s</title>
<link rel="icon" type="image/png" href="theme-asset?name=favicon.png">
<script nonce="%s">window.PLATFORM_PAGE_CONTEXT = %s;</script>
%s
<style>
%s
* { box-sizing: border-box; }
/* min-height, not height -- height:100%% pins body's own box (and its
   background paint) to exactly one viewport tall; a page whose content
   is taller than that overflows the box while its background stops
   dead at the one-screen mark, which is exactly what showed up as
   "background/sidebar end partway down a long page." min-height lets
   the box grow to the real content height while still guaranteeing a
   full screen on short pages, so .platform-nav's own min-height:100vh
   below (a floor, not a cap) still reaches the bottom of the viewport
   there too. */
html, body { margin: 0; min-height: 100vh; }
body {
    display: flex;
    font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--platform-bg-2, #f1f5f9);
}
%s
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
""", html.html_escape(title), nonce, page_context_json, platform_common_js(nonce), root_css, platform_nav_css(), platform_chat_widget_css(), brand_html, table.concat(nav_links, ""), user_box, body,
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
    register_header = render_page_header("Register " .. escaped_type,
        "<p>Fill out the sheet. Fields marked with <span class=\"req-dot\">*</span> are required.</p>",
        "<a class=\"btn btn-secondary\" href=\"browse?type=" .. escaped_type .. "\">Browse " .. escaped_type .. "</a>")

    -- The action buttons and status placeholder are the only pieces of
    -- this page's static shell that recur elsewhere verbatim (render_
    -- entity_edit's own single-row edit page has the exact same two
    -- shapes) -- everything else here (the always-JS-populated table
    -- shell, the CSS block, the templated inline <script>) stays direct
    -- string composition, same as before: see doc/templating.md's
    -- scope-boundary note on why those don't fit page.lua's vocabulary.
    page_lib = require("page")
    sections = {
        {
            type = "actions",
            buttons = {
                {label = "+ Add Row", id = "btn-add-row", css_class = "btn btn-secondary"},
                {label = "Submit Batch", id = "btn-submit-batch", css_class = "btn btn-primary"},
            },
        },
        {type = "status_placeholder", id = "status-message", css_class = "status-msg"},
    }
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    actions_html = page_lib.render(sections)
    return string.format("""
<div class="fossil-doc" data-title="Register %s">
    <style>
%s
%s
        .platform-header span.req-dot {
            color: #ef4444;
            font-weight: bold;
        }
        %s
        /* The registration grid is editable cells, not a plain
           read-only table -- the inset shadow and bottom margin are
           deliberate on top of the shared base, not drift. */
        .platform-table-wrapper { margin-bottom: 24px; box-shadow: inset 0 2px 4px 0 rgba(0,0,0,0.02); }
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
        .platform-actions {
            display: flex;
            gap: 14px;
            justify-content: flex-start;
            align-items: center;
        }
        %s
    </style>

    <div class="platform-container">
        %s

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

        %s
    </div>

    <script nonce="%s">
        const layout = %s;
        const entityType = "%s";
        const lockedFields = %s;
        const baseUrl = window.location.pathname.replace(/\\/register\\/?$/, "");
        let rowCounter = 0;

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

                // A locked field (?lock_<name>=<value>) shows a fixed,
                // read-only display -- e.g. which mixture these
                // ingredients belong to -- plus a same-named hidden
                // input so submitBatch()'s existing
                // querySelector(`[name="..."]`) collection picks up the
                // value with no changes needed there at all.
                const locked = lockedFields[field.name];
                PlatformJS.buildFieldInput(field, wrapper, { locked: locked, baseUrl: baseUrl });
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

        // Row/field lookup stays bespoke here (register's inputs share
        // one bare `name` per <tr>, so a lookup needs the row too) --
        // only the "mark this input errored" mechanics are shared.
        function highlightError(rowIndex, fieldName, message) {
            const tbody = document.getElementById("table-body");
            const tr = tbody.getElementsByTagName("tr")[rowIndex];
            if (!tr) return;
            const input = tr.querySelector(`[name="${fieldName}"]`);
            if (!input) return;
            PlatformJS.highlightError(input, message);
        }

        function clearAllErrors() {
            PlatformJS.clearAllErrors(document, document.getElementById("status-message"));
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
                        // Both multivalue types send a real JSON array
                        // in the payload, not a joined string -- /api/
                        // submit's body is already JSON, so there's no
                        // wire-format reason to flatten one.
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
            PlatformJS.postJSON(`${baseUrl}/api/submit?type=${entityType}${entryParam}`, payload)
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
""", escaped_type, platform_container_css(), platform_page_header_css(), platform_table_wrapper_css(), platform_button_css() .. platform_cell_editor_css(), register_header, actions_html, nonce, json_for_script(layout_json), js_string_literal(entity_type), json_for_script(locked_fields_json))
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
-- submitting to /api/update instead of /api/submit.
function html.render_entity_edit(entity_type, layout_json, row_json, entity_id, nonce)
    escaped_type = html.html_escape(entity_type)
    escaped_entity_id = tostring(entity_id)
    edit_header = render_page_header("Edit " .. escaped_type .. " #" .. escaped_entity_id,
        "<a class=\"btn btn-secondary\" href=\"detail?type=" .. escaped_type .. "&entity_id=" .. escaped_entity_id .. "\">&larr; Back to detail</a>", nil)

    -- Same two shapes html.render's own registration grid already
    -- built these types for (see doc/templating.md) -- reused verbatim
    -- here, no new vocabulary needed. This page's own `style` is the
    -- real reason `actions.style` exists at all: this fields list
    -- carries no bottom margin of its own (unlike register's neighbor,
    -- a table wrapper that already does), so its action group needs
    -- the extra top margin explicitly.
    page_lib = require("page")
    sections = {
        {
            type = "actions",
            buttons = {{label = "Save changes", id = "btn-save", css_class = "btn btn-primary"}},
            style = "margin-top: 20px;",
        },
        {type = "status_placeholder", id = "status-message", css_class = "status-msg"},
    }
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    actions_html = page_lib.render(sections)
    return string.format("""
<div class="fossil-doc" data-title="Edit %s #%s">
    <style>
%s
%s
%s
        .platform-edit-fields { display: flex; flex-direction: column; gap: 14px; max-width: 640px; }
        .platform-edit-field label { display: block; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--platform-muted, #64748b); font-weight: 600; margin-bottom: 6px; }
        .platform-edit-field label .req-dot { color: #ef4444; font-weight: bold; }
        .platform-edit-field { position: relative; }
        /* This form is a single narrow column (.platform-edit-fields'
           own max-width: 640px above) -- keep the shared status-msg
           the same width rather than letting it stretch full-width. */
        .status-msg { max-width: 640px; }
    </style>

    <div class="platform-container">
        %s

        <div class="platform-edit-fields" id="edit-fields"><!-- fields injected --></div>

        %s
    </div>

    <script nonce="%s">
        const layout = %s;
        const row = %s;
        const entityType = "%s";
        const entityId = %s;
        const baseUrl = window.location.pathname.replace(/\\/entity-edit\\/?$/, "");

        // Field lookup stays bespoke here (document-global, not
        // row-scoped like register's) -- only the "mark this input
        // errored" mechanics are shared.
        function highlightError(fieldName, message) {
            const input = document.querySelector(`[name="${fieldName}"]`);
            if (!input) return;
            PlatformJS.highlightError(input, message);
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
                PlatformJS.buildFieldInput(field, wrapper, { value: current, baseUrl: baseUrl });
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
            document.querySelectorAll(".cell-input").forEach(PlatformJS.clearCellError);
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
            PlatformJS.postJSON(`${baseUrl}/api/update?type=${entityType}&entity_id=${entityId}${reasonParam}`, payload)
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
""", escaped_type, escaped_entity_id, platform_container_css(), platform_button_css(), platform_page_header_css() .. platform_cell_editor_css(),
     edit_header, actions_html,
     nonce, json_for_script(layout_json), json_for_script(row_json), js_string_literal(entity_type), tostring(entity_id))
end

-- A multivalue field's value is a plain Lua array, not a
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

-- Word-level diff between an old/new field value, for the ledger
-- history view -- a document's `content` field can be thousands of
-- words; showing the full old and new blobs side by side (display_value's
-- old -> new above) for a one-word edit makes the real change all but
-- impossible to spot. Classic LCS word diff: common words render
-- plain, removed words struck through, added words highlighted -- the
-- same red/green tokens .platform-chat-error/.platform-admin-message
-- already use elsewhere in this file, not a new palette (see the CSS
-- above).
--
-- Guarded by DIFF_MAX_WORDS: the LCS table below is O(#a * #b) in word
-- count, and a full multi-thousand-word field (a real, common size in
-- this deployment's own document pool -- whole journal-article bodies)
-- would make that a genuinely expensive request. Past the cap,
-- word_diff_html returns nil so the caller falls back to the old plain
-- old -> new rendering rather than either hanging the request or
-- silently truncating a real diff.
DIFF_MAX_WORDS = 400

function split_words(text)
    words = {}
    for w in string.gmatch(tostring(text), "%S+") do
        table.insert(words, w)
    end
    return words
end

-- Standard dynamic-programming LCS length table over two word arrays --
-- lengths[i][j] is the LCS length of a[1..i] and b[1..j].
function word_lcs_lengths(a, b)
    lengths = {}
    for i = 0, #a do
        lengths[i] = {}
        for j = 0, #b do
            lengths[i][j] = 0
        end
    end
    for i = 1, #a do
        for j = 1, #b do
            if a[i] == b[j] then
                lengths[i][j] = lengths[i - 1][j - 1] + 1
            elseif lengths[i - 1][j] >= lengths[i][j - 1] then
                lengths[i][j] = lengths[i - 1][j]
            else
                lengths[i][j] = lengths[i][j - 1]
            end
        end
    end
    return lengths
end

-- Backtracks the LCS table into a sequence of {kind, words} runs, in
-- original order -- kind is one of "same"/"removed"/"added", with
-- adjacent same-kind words already grouped into one run so a caller
-- doesn't have to.
function word_diff_runs(old_text, new_text)
    a = split_words(old_text)
    b = split_words(new_text)
    lengths = word_lcs_lengths(a, b)

    reversed = {}
    i, j = #a, #b
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            table.insert(reversed, {kind = "same", word = a[i]})
            i = i - 1
            j = j - 1
        elseif lengths[i - 1][j] >= lengths[i][j - 1] then
            table.insert(reversed, {kind = "removed", word = a[i]})
            i = i - 1
        else
            table.insert(reversed, {kind = "added", word = b[j]})
            j = j - 1
        end
    end
    while i > 0 do
        table.insert(reversed, {kind = "removed", word = a[i]})
        i = i - 1
    end
    while j > 0 do
        table.insert(reversed, {kind = "added", word = b[j]})
        j = j - 1
    end

    runs = {}
    for k = #reversed, 1, -1 do
        entry = reversed[k]
        last = runs[#runs]
        if last != nil and last.kind == entry.kind then
            table.insert(last.words, entry.word)
        else
            table.insert(runs, {kind = entry.kind, words = {entry.word}})
        end
    end
    return runs
end

-- Rendered HTML for a word diff, or nil when either side is too large
-- to diff cheaply (see DIFF_MAX_WORDS above) -- the caller falls back
-- to display_value's plain old -> new rendering in that case.
function word_diff_html(old_value, new_value)
    old_text = tostring(old_value)
    new_text = tostring(new_value)
    if old_text == new_text then
        return html.html_escape(old_text)
    end
    a = split_words(old_text)
    b = split_words(new_text)
    if #a > DIFF_MAX_WORDS or #b > DIFF_MAX_WORDS then
        return nil
    end
    parts = {}
    for _, run in ipairs(word_diff_runs(old_text, new_text)) do
        escaped = html.html_escape(table.concat(run.words, " "))
        if run.kind == "removed" then
            table.insert(parts, "<del class=\"diff-removed\">" .. escaped .. "</del>")
        elseif run.kind == "added" then
            table.insert(parts, "<ins class=\"diff-added\">" .. escaped .. "</ins>")
        else
            table.insert(parts, escaped)
        end
    end
    return table.concat(parts, " ")
end

-- Reference-type field values are a raw entity id -- not every entity
-- type has a human-readable label for it (see the two sources below),
-- so this always renders the id as a real, styled link to the
-- referenced entity's own detail page instead of a disconnected bare
-- number, matching how the row's own id already links out in
-- render_browse below. The link is relative ("detail...", no leading
-- slash) so it resolves correctly regardless of where this app is
-- mounted -- every route lives at the same top-level directory, so a
-- plain relative reference from any of them reaches any other.
-- Two sources for a human-readable label, tried in priority order:
--   1. The builtin "name" column (schema.lua's BUILTIN_COLUMNS) -- a
--      real name assigned by an external source like Benchling (e.g. a
--      container literally named "50L stainless steel bioreactor").
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

_display_label_cache = nil

function compute_entity_display_label(db_path, entity_type, entity_id)
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

function html.entity_display_label(db_path, entity_type, entity_id)
    if _display_label_cache != nil then
        ckey = tostring(entity_type) .. ":" .. tostring(entity_id)
        cached = _display_label_cache[ckey]
        if cached == false then
            return nil
        elseif cached != nil then
            return cached
        end
        computed = compute_entity_display_label(db_path, entity_type, entity_id)
        if computed == nil then
            _display_label_cache[ckey] = false
        else
            _display_label_cache[ckey] = computed
        end
        return computed
    end
    return compute_entity_display_label(db_path, entity_type, entity_id)
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

function prefetch_browse_display_labels(db_path, layout, rows)
    cache = {}
    if rows == nil or #rows == 0 or layout == nil or layout.fields == nil then
        return cache
    end
    ids_by_type = {}
    function add_ref(ref_type, ref_id)
        if ref_type == nil or ref_type == "" or ref_id == nil then
            return
        end
        s_id = tostring(ref_id)
        if s_id == "" then
            return
        end
        if ids_by_type[ref_type] == nil then
            ids_by_type[ref_type] = {}
        end
        ids_by_type[ref_type][s_id] = true
    end

    for _, field in ipairs(layout.fields) do
        ftype = field.type
        if ftype == "reference" and field.ref_entity_type != nil then
            for _, row in ipairs(rows) do
                add_ref(field.ref_entity_type, row[field.name])
            end
        elseif ftype == "multi_reference" and field.ref_entity_type != nil then
            for _, row in ipairs(rows) do
                vals = row[field.name]
                if type(vals) == "table" then
                    for _, v in ipairs(vals) do
                        add_ref(field.ref_entity_type, v)
                    end
                end
            end
        elseif ftype == "polymorphic_reference" or ftype == "multi_polymorphic_reference" then
            for _, row in ipairs(rows) do
                vals = row[field.name]
                if type(vals) == "table" then
                    for _, v in ipairs(vals) do
                        if type(v) == "table" then
                            add_ref(v.type, v.id)
                        end
                    end
                end
            end
        end
    end

    for ref_type, id_set in pairs(ids_by_type) do
        if schema.valid_name_syntax(ref_type) and schema.is_registered(db_path, ref_type) and db.table_exists(db_path, ref_type) then
            display_field = nil
            fields = schema.fields(db_path, ref_type)
            if fields != nil then
                for _, f in ipairs(fields) do
                    if tonumber(f.display) == 1 and schema.is_multi_field_type(f.type) == false and schema.is_polymorphic_field_type(f.type) == false then
                        display_field = f
                        break
                    end
                end
            end

            quoted_ids = {}
            for s_id, _ in pairs(id_set) do
                cache[ref_type .. ":" .. s_id] = false
                table.insert(quoted_ids, db.quote(s_id))
            end

            if #quoted_ids > 0 then
                select_cols = "id, name"
                if display_field != nil then
                    select_cols = "id, name, " .. db.quote_ident(display_field.name) .. " AS display_val"
                end
                q_rows = db.query(db_path, string.format(
                    "SELECT %s FROM %s WHERE id IN (%s);",
                    select_cols, ref_type, table.concat(quoted_ids, ", ")
                ))
                if q_rows != nil then
                    for _, qr in ipairs(q_rows) do
                        ckey = ref_type .. ":" .. tostring(qr.id)
                        if qr.name != nil and tostring(qr.name) != "" then
                            cache[ckey] = tostring(qr.name)
                        elseif display_field != nil and qr.display_val != nil and tostring(qr.display_val) != "" then
                            cache[ckey] = format_display_label(ref_type, display_field, qr.display_val)
                        end
                    end
                end
            end
        end
    end

    return cache
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

    -- Preserves an active ?filter_field=&filter_value= across Prev/Next
    -- -- otherwise paging past page 1 on a filtered view (e.g. "this
    -- mixture's ingredients") would silently drop back to the
    -- unfiltered list.
    filter_query_suffix = ""
    if filter_field != nil then
        filter_query_suffix = "&filter_field=" .. html.html_escape(filter_field) .. "&filter_value=" .. html.html_escape(tostring(filter_value))
    end

    header_parts = {"<th>ID</th>"}
    for _, field in ipairs(layout.fields) do
        table.insert(header_parts, "<th>" .. html.html_escape(field.label) .. "</th>")
    end
    header_cells = table.concat(header_parts)

    prev_cache = _display_label_cache
    _display_label_cache = prefetch_browse_display_labels(db_path, layout, rows)
    ok_rows, body_rows_or_err = pcall(function()
        row_parts = {}
        for _, row in ipairs(rows) do
            own_label = html.own_row_label(db_path, entity_type, row)
            id_link_text = "#" .. tostring(row.id)
            if own_label != nil then
                id_link_text = html.html_escape(own_label)
            end
            cell_parts = {
                "<td><a href=\"detail?type=" .. escaped_type .. "&entity_id=" .. tostring(row.id) ..
                "\">" .. id_link_text .. "</a></td>"
            }
            for _, field in ipairs(layout.fields) do
                table.insert(cell_parts, "<td>" .. html.display_field_value(db_path, field, row[field.name]) .. "</td>")
            end
            table.insert(row_parts, "<tr>" .. table.concat(cell_parts) .. "</tr>")
        end
        return table.concat(row_parts)
    end)
    _display_label_cache = prev_cache
    if not ok_rows then
        error(body_rows_or_err, 0)
    end
    body_rows = body_rows_or_err

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

    browse_header = render_page_header("Browse " .. escaped_type, "<p>" .. tostring(total) .. " registered</p>",
        "<a class=\"btn btn-primary\" href=\"register?type=" .. escaped_type .. "\">+ New " .. escaped_type .. "</a>")
    return string.format("""
<div class="fossil-doc" data-title="Browse %s">
    <style>
%s
%s
        %s
        %s
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
    </style>
    %s
    <div class="platform-container">
        %s
        %s
        %s
    </div>
</div>
%s
""", escaped_type, platform_container_css(), platform_page_header_css(), platform_button_css(), platform_table_wrapper_css(), html.popover_css(), browse_header, table_or_empty, pager, html.popover_js(nonce))
end

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
            -- A word-level diff only makes sense for two plain scalars
            -- (see word_diff_html's own comment for why, and its size
            -- cap) -- a multivalue field's old/new is a real Lua array
            -- (display_value's own header comment), so that still falls
            -- back to the plain old -> new rendering below.
            diff_body = nil
            if type(change.old) != "table" and type(change.new) != "table" then
                diff_body = word_diff_html(change.old, change.new)
            end
            if diff_body != nil then
                changes = changes .. "<div class=\"change-item\"><strong>" .. html.html_escape(field_name) ..
                    "</strong>: <span class=\"diff-view\">" .. diff_body .. "</span></div>"
            else
                changes = changes .. "<div class=\"change-item\"><strong>" .. html.html_escape(field_name) ..
                    "</strong>: " .. display_value(change.old) .. " &rarr; " .. display_value(change.new) .. "</div>"
            end
        end
        history_rows = history_rows .. "<tr><td>#" .. tostring(event.event_id) .. "</td><td>" ..
            html.html_escape(event.event_type) .. "</td><td>" .. display_value(event.author) .. "</td><td>" ..
            html.html_escape(event.created_at) .. "</td><td>" .. changes .. "</td></tr>"
    end

    detail_header = render_page_header(escaped_type .. " " .. title_id_part,
        "<a class=\"btn btn-secondary\" href=\"browse?type=" .. escaped_type .. "\">&larr; Back to browse</a>",
        "<div class=\"platform-header-actions\">" .. edit_link .. print_label_html .. "</div>")
    return string.format("""
<div class="fossil-doc" data-title="%s %s">
    <style>
%s
%s
%s
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
        .diff-view { word-break: break-word; }
        /* Same red/green tokens as .platform-chat-error and
           .platform-admin-message elsewhere in this file -- not a new
           palette, just this codebase's existing danger/success colors
           applied to a diff. */
        .diff-removed { color: #991b1b; background: #fef2f2; text-decoration: line-through; padding: 0 2px; border-radius: 3px; }
        .diff-added { color: #166534; background: #f0fdf4; text-decoration: none; padding: 0 2px; border-radius: 3px; }
        .platform-print-label { display: inline-flex; align-items: center; gap: 8px; margin-left: 16px; }
        .platform-print-label select { padding: 6px 10px; border-radius: var(--platform-radius-sm, 8px); border: 1px solid var(--platform-border, #e2e8f0); }
        #platform-print-label-status { font-size: 0.85rem; color: var(--platform-muted, #64748b); }
        #platform-print-label-status.platform-admin-message-error { color: #991b1b; }
    </style>
    %s
    <div class="platform-container">
        %s

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
""", escaped_type, title_id_part, platform_container_css(), platform_button_css() .. platform_table_wrapper_css(), platform_page_header_css() .. platform_related_css(), html.popover_css(), detail_header, fields_html, related_html, history_rows, html.popover_js(nonce), print_label_js_block)
end

-- "Related records" -- every real, plain `reference` field
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
            rows_html = rows_html .. "<li><a class=\"btn btn-secondary\" href=\"detail?type=" .. escaped_from .. "&entity_id=" .. tostring(r.id) .. "\">" .. link_text .. "</a></li>"
        end
        if rows_html == "" then
            rows_html = "<p class=\"platform-related-empty\">None yet.</p>"
        else
            rows_html = "<ul>" .. rows_html .. "</ul>"
        end

        view_all = ""
        if group.total > #group.rows then
            view_all = "<a class=\"btn btn-secondary\" href=\"browse?type=" .. escaped_from .. "&filter_field=" .. escaped_field ..
                "&filter_value=" .. tostring(entity_id) .. "\">View all " .. tostring(group.total) .. "</a>"
        end
        add_link = "<a class=\"btn btn-primary\" href=\"register?type=" .. escaped_from .. "&lock_" .. escaped_field .. "=" .. tostring(entity_id) ..
            "\">+ Add " .. escaped_from .. "</a>"

        groups_html = groups_html .. "<div class=\"platform-related-group\"><h4>" .. escaped_from .. " (" ..
            tostring(group.total) .. ")</h4>" .. rows_html .. "<div class=\"platform-related-actions\">" ..
            add_link .. view_all .. "</div></div>"
    end
    return "<h3 class=\"platform-subheading\">Related records</h3><div class=\"platform-related\">" .. groups_html .. "</div>"
end

-- Markup for the print-label control, only ever emitted when a
-- label_template row exists for this entity_type (has_label_template,
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
-- rendered ZPL (fetched from /label) to whichever one is selected.
-- `nonce` must be Fossil's own per-request CSP nonce (see
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
        fetch("label?type=%s&entity_id=%s").then(function(resp){
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
""", nonce, js_string_literal(entity_type), js_string_literal(tostring(entity_id)))
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
    header_parts = {}
    for _, col in ipairs(view_def.columns) do
        label = col.label
        if label == nil then
            label = col.name
        end
        table.insert(header_parts, "<th>" .. html.html_escape(label) .. "</th>")
    end
    header_cells = table.concat(header_parts)

    if #rows == 0 then
        return "<p class=\"platform-empty\">No rows.</p>"
    end

    row_parts = {}
    for _, row in ipairs(rows) do
        cell_parts = {}
        for _, col in ipairs(view_def.columns) do
            table.insert(cell_parts, "<td>" .. display_value(row[col.name]) .. "</td>")
        end
        table.insert(row_parts, "<tr>" .. table.concat(cell_parts) .. "</tr>")
    end
    body_rows = table.concat(row_parts)

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

    view_header = render_page_header(escaped_title, "<p>" .. subtitle .. "</p>", register_link)
    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
%s
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
    </style>
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", escaped_title, platform_container_css() .. platform_table_wrapper_css(), platform_page_header_css(), view_header, table_or_empty)
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
        view_def, err = view.load(db_path, view_name)
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

-- ERD box geometry -- fixed width rather than measured text,
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

    -- Pack diagram boxes in deterministic alphabetical order rather than
    -- `entity_types`'s row-count order so a count change on one table never
    -- reshuffles base coordinates across the diagram.
    diagram_types = {}
    for i, row in ipairs(entity_types) do
        diagram_types[i] = row
    end
    table.sort(diagram_types, function(a, b)
        return a.name < b.name
    end)

    index_by_name = {}
    for i, row in ipairs(diagram_types) do
        index_by_name[row.name] = i
    end

    -- Precompute every box's real rows + height up front (needed both
    -- for layout packing below and for locating a specific field's row
    -- when drawing edges).
    boxes = {}
    for i, row in ipairs(diagram_types) do
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

    edges_parts = {}
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
                table.insert(edges_parts, string.format(
                    "<g class=\"platform-diagram-edge\" data-from=\"%s\" data-to=\"%s\">" ..
                    "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\"></line>" ..
                    "<text class=\"platform-diagram-card\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                    "<text class=\"platform-diagram-card\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                    "</g>",
                    html.html_escape(edge.from_type), html.html_escape(edge.to_type),
                    from_x, from_y, to_x, to_y,
                    from_x + label_dx, from_y - 4, from_label,
                    to_x - label_dx, to_y - 4, to_label
                ))
            end
        end
    end
    edges_svg = table.concat(edges_parts)

    boxes_parts = {}
    for i, row in ipairs(diagram_types) do
        box = boxes[i]
        escaped_name = html.html_escape(row.name)
        rows_parts = {}
        for j, box_row in ipairs(box.rows) do
            row_y = box.y + DIAGRAM_HEADER_HEIGHT + (j - 1) * DIAGRAM_ROW_HEIGHT
            name_class = "platform-diagram-row-name"
            if box_row.is_pk then
                name_class = name_class .. " platform-diagram-row-pk"
            elseif box_row.required then
                name_class = name_class .. " platform-diagram-row-required"
            end
            table.insert(rows_parts, string.format(
                "<text class=\"%s\" x=\"%.1f\" y=\"%.1f\">%s</text>" ..
                "<text class=\"platform-diagram-row-type\" x=\"%.1f\" y=\"%.1f\">%s</text>",
                name_class, box.x + 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html.html_escape(box_row.name),
                box.x + box.width - 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html.html_escape(box_row.type_label)
            ))
        end
        rows_svg = table.concat(rows_parts)
        table.insert(boxes_parts, string.format(
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
        ))
    end
    boxes_svg = table.concat(boxes_parts)

    return string.format("""
<div class="platform-diagram-hint">
    Hover an entity to see its relations; click its header to browse it; drag a box or the background to rearrange/pan, scroll to zoom.
    <button type="button" class="platform-diagram-auto-arrange" id="platform-diagram-auto-arrange">Auto-arrange</button>
    <button type="button" class="platform-diagram-auto-arrange" id="platform-diagram-reset-view">Reset view</button>
</div>
<div class="platform-diagram-scroll">
<svg id="platform-diagram-svg" viewBox="0 0 %d %d" data-natural-view="0 0 %d %d" preserveAspectRatio="xMidYMid meet">
    %s
    %s
</svg>
</div>
""", total_width, total_height, total_width, total_height, edges_svg, boxes_svg)
end

function html.relation_diagram_css()
    return asset.read("ui/diagram.css")
end

-- `nonce` must be Fossil's own per-request CSP nonce, same requirement
-- as html.popover_js.
function html.diagram_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/diagram.js"))
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
-- Shared by /login, /forgot-password and /reset-password -- the three
-- pages an unauthenticated visitor can reach, all one centered card.
-- `footer_html` is an already-safe fragment (a link back to /login or
-- on to /forgot-password) rendered under the card's form.
function render_login_card(title, sections, footer_html)
    page_lib = require("page")
    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    footer = ""
    if footer_html != nil then
        footer = "<p class=\"platform-login-footer\">" .. footer_html .. "</p>\n"
    end

    return string.format("""
<div class="fossil-doc" data-title="%s">
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
        .platform-login-card .btn { width: 100%%; }
        .platform-login-notice { color: #166534; background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: var(--platform-radius-item, 10px); padding: 10px 12px; margin-bottom: 14px; font-size: 0.88rem; }
        .platform-login-card form { margin: 0; }
        .platform-login-footer { margin: 16px 0 0 0; text-align: center; font-size: 0.88rem; }
        .platform-login-footer a { color: var(--platform-accent, #4f46e5); }
    </style>
    <div class="platform-login-card">
%s%s    </div>
</div>
""", html.html_escape(title), platform_container_css(), platform_button_css() .. platform_error_banner_css(), page_lib.render(sections), footer)
end

-- `notice` is a non-error message (e.g. "password updated") shown in
-- place of `error_message` when there's no error. `show_forgot_link`
-- is config.password_reset_enabled() -- no link to a flow this
-- deployment can't actually send mail for.
function html.render_login(error_message, nonce, show_forgot_link, notice)
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

-- /forgot-password: one field, login or email. After a POST, `sent` is
-- true and the form is replaced by the same neutral confirmation
-- whether or not an account matched -- see auth.request_password_reset.
function html.render_forgot_password(error_message, sent)
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

-- /reset-password#token=...: the emailed token rides in the URL
-- fragment (see auth.request_password_reset), which the server never
-- sees -- so the GET page can't check it, and this page's one script
-- copies it into the form's hidden field (and strips it from the
-- address bar) for the POST to check instead. `token` is only set when
-- re-rendering after a POST (e.g. mismatched passwords); `invalid` is
-- set when a POSTed token didn't check out.
function html.render_reset_password(token, error_message, invalid, nonce)
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
    return card .. string.format("""
<script nonce="%s">
(function() {
    var field = document.getElementById('reset-token');
    var match = /(?:^#|&)token=([0-9a-f]+)/.exec(window.location.hash);
    if (match) {
        field.value = match[1];
        history.replaceState(null, '', window.location.pathname);
    }
    if (!field.value) {
        field.form.hidden = true;
        document.getElementById('reset-missing').hidden = false;
    }
})();
</script>
""", nonce)
end

-- /verify-email#token=...: confirms a new address for an account that
-- already has a password (auth.send_setup_link's "verify" link). Same
-- fragment handling as render_reset_password; the form asks for the
-- account's current password, because the link alone only proves the
-- mailbox, not that its reader owns the account.
function html.render_verify_email(token, error_message, invalid, nonce)
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
    return card .. string.format("""
<script nonce="%s">
(function() {
    var field = document.getElementById('verify-token');
    var match = /(?:^#|&)token=([0-9a-f]+)/.exec(window.location.hash);
    if (match) {
        field.value = match[1];
        history.replaceState(null, '', window.location.pathname);
    }
    if (!field.value) {
        field.form.hidden = true;
        document.getElementById('verify-missing').hidden = false;
    }
})();
</script>
""", nonce)
end

-- Self-service password change -- every capability level (baseline "i"
-- included) can reach this via the "Change password" link in the nav
-- user box. Deliberately narrow: cgi.lua's route always targets the
-- requesting session's own login (never an arbitrary login field the
-- way /admin-users-password's admin-only form does) and requires the
-- current password to verify before setting a new one. No broader
-- account-settings page, no other fields -- just this.
-- The single destination for the nav's username link -- hosts both
-- self-service password change and log out, so no new sidebar links
-- are ever needed for account-level actions.
-- `email` is the account's current address (nil if none) -- used by
-- the forgot-password flow, so changing it needs the current password
-- the same way changing the password itself does.
function html.render_account(username, user, csrf_token, message, is_error)
    page_lib = require("page")

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
    -- Read-only: an admin sets the email (see cgi.lua's /account).
    email_text = "No email on file -- ask an admin to add one if you want to be able to reset your password."
    if user != nil and user.email != nil and user.email != "" then
        auth_lib = require("auth")
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

    return string.format("""
<div class="fossil-doc" data-title="Account">
    <style>
%s
%s
        .platform-account-card { max-width: 360px; margin: 60px auto; padding: 28px; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-md, 12px); }
        .platform-account-card h2 { margin: 0 0 4px 0; font-size: 1.4rem; font-weight: 700; color: var(--platform-heading, #0f172a); }
        .platform-account-card h3 { margin: 24px 0 12px 0; font-size: 1rem; font-weight: 700; color: var(--platform-heading, #0f172a); }
        .platform-account-username { margin: 0 0 18px 0; font-size: 0.88rem; color: var(--platform-muted, #64748b); }
        .platform-account-card label { display: block; margin-bottom: 4px; font-size: 0.88rem; color: var(--platform-muted, #64748b); }
        .platform-account-card input[type=password], .platform-account-card input[type=text] {
            width: 100%%; box-sizing: border-box; padding: 8px 10px; margin-bottom: 14px;
            border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); font-size: 0.95rem;
        }
        .platform-account-message { color: #166534; background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: var(--platform-radius-item, 10px); padding: 10px 12px; margin-bottom: 14px; font-size: 0.88rem; }
        .platform-account-message-error { color: #991b1b; background: #fef2f2; border-color: #fecaca; }
        .platform-account-card .btn { width: 100%%; }
        .platform-account-logout-form { margin: 0; }
    </style>
    <div class="platform-account-card">
        <h2>Account</h2>
        <p class="platform-account-username">Signed in as <strong>%s</strong></p>
%s    </div>
</div>
""", platform_container_css(), platform_button_css(), html.html_escape(username), page_lib.render(sections))
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
-- invite_mode: mail is configured, so accounts are created with an
-- email and get a setup link (auth.invite_user), not a typed password.
-- show_archived: `users` includes archived accounts; the toggle below
-- links to the other view (?archived=1), so unarchive stays reachable.
function html.render_admin_users(users, invite_mode, csrf_token, message, is_error, show_archived)
    page_lib = require("page")

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
        auth_lib = require("auth")
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

    return string.format("""
<div class="fossil-doc" data-title="Manage users">
    <style>
%s
%s
%s
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
        %s
%s    </div>
</div>
""", platform_container_css(), platform_button_css(), platform_page_header_css() .. platform_admin_message_css(), render_page_header("Manage users", nil, nil), page_lib.render(sections))
end

-- Admin UI for the auth_api_key table, mirroring render_admin_users
-- exactly. `new_raw_key` is only ever set immediately after a
-- successful create -- the raw key is never stored, so this is the one
-- and only time it can be shown; it's rendered in its own prominent,
-- one-time banner rather than folded into `message`.
function html.render_admin_api_keys(keys, csrf_token, message, is_error, new_raw_key)
    page_lib = require("page")

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
        status = "active"
        if k.archived_at != nil and k.archived_at != "" then
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
        columns = {"Label", "Capabilities", "Status", "Actions"},
        rows = rows,
    })

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end

    return string.format("""
<div class="fossil-doc" data-title="Manage API keys">
    <style>
%s
%s
%s
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
        %s
%s    </div>
</div>
""", platform_container_css(), platform_button_css(), platform_page_header_css() .. platform_admin_message_css(), render_page_header("Manage API keys", nil, nil), page_lib.render(sections))
end

-- Settings: a real UI for theme.lua's own fields, instead
-- of hand-editing the file and redeploying. Covers every field
-- config.load_theme/save_theme round-trip -- site_name, the color
-- overrides, hide_home_heading, system_prompt_extra, and logo/favicon
-- uploads. Deliberately NOT env-var-driven config (DB backend, agent
-- provider/model, Vertex project/region): those are process-bootstrap
-- values read once at CGI-process start, not something safe to change
-- from inside a running request.
function html.render_settings(theme, csrf_token, message, is_error)
    page_lib = require("page")

    message_css_class = "platform-admin-message"
    if is_error == true then
        message_css_class = "platform-admin-message platform-admin-message-error"
    end

    system_prompt_extra_value = ""
    if theme.system_prompt_extra != nil then
        system_prompt_extra_value = theme.system_prompt_extra
    end

    color_fields = {}
    for _, key in ipairs(THEME_COLOR_KEYS) do
        value = ""
        if theme.colors != nil and theme.colors[key] != nil then
            value = theme.colors[key]
        end
        table.insert(color_fields, {
            type = "text", name = "color_" .. key, label = string.gsub(key, "_", " "),
            value = value, placeholder = "e.g. #4f46e5", size = "12", wrapper_class = "platform-settings-color",
        })
    end

    logo_status = "No logo uploaded -- the sidebar shows the default icon and \"Platform\" as plain text."
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
                    {type = "text", name = "site_name", label = "Site name", value = theme.site_name, placeholder = "Platform"},
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

    return string.format("""
<div class="fossil-doc" data-title="Settings">
    <style>
%s
%s
%s
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
        %s
%s    </div>
</div>
""", platform_container_css(), platform_button_css(), platform_page_header_css() .. platform_admin_message_css(), render_page_header("Settings", nil, nil), page_lib.render(sections))
end

-- v1 landing page: basic information and quick links, deliberately
-- not an activity dashboard (working lists, a calendar, recent-entries
-- feed) yet -- a real starting point, not the end state. `theme` is
-- config.load_theme(root)'s return value, purely for site_name; no
-- other Celleste-specific content belongs here (see theme.lua's own
-- split from daat).
function html.render_home(theme, show_sql, show_admin, has_tasks_view, nav_extensions)
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
            "<img class=\"platform-home-logo\" src=\"theme-asset?name=logo-full.png\" alt=\"%s\">",
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
        system_link = render_sitemap_item("system", "System", "Admin, SQL console, and templates.")
    end

    -- Unconditional -- every logged-in user has baseline capability,
    -- and the Knowledge Pool is read-only browsing, not an admin tool
    -- (brex 492390825), so it no longer needs a show_sql/show_admin
    -- guard the way system_link above does.
    knowledge_link = render_sitemap_item("knowledge", "Knowledge Pool", "Tiered notes, retrieval activity, and chat sessions.")

    -- Only a real link when a deployment actually seeded a
    -- "prioritized_tasks" view -- a fresh/generic install has no
    -- views/ at all, and without this guard it would be a nav item
    -- that 404'd on "cannot open view: ./views/prioritized_tasks.lua".
    tasks_link = ""
    if has_tasks_view == true then
        tasks_link = render_sitemap_item("view?view_name=prioritized_tasks", "Tasks", "Open tasks, ranked by priority.")
    end

    -- One tile per approved capabilities.ui extension -- the same
    -- nav_extensions data the sidebar rail already renders from
    -- (extension.approved_with_ui), just a second, independent listing
    -- of it. Deliberately not filtered by nav_hidden: a deployment
    -- hiding an extension from the sidebar (platform.lua's own
    -- nav_hidden) doesn't mean hiding it altogether -- "home page
    -- link instead of a permanent nav entry" is exactly what a plain,
    -- occasionally-used lookup page (e.g. experiment_view, brex
    -- 462301011) wants, and nav_hidden already exists as its own
    -- independent, generic toggle for the sidebar specifically.
    extension_tiles = ""
    if nav_extensions != nil then
        for _, entry in ipairs(nav_extensions) do
            ui = entry.manifest.capabilities.ui
            description = ui.description
            if description == nil or description == "" then
                description = "Open the " .. ui.label .. " extension."
            end
            extension_tiles = extension_tiles .. render_sitemap_item("ext/" .. entry.name, ui.label, description)
        end
    end

    -- Not built via render_page_header's usual title slot: logo_html is
    -- a real <img>, a sibling block before the <h2>, not text belonging
    -- inside the heading itself (nesting it into <h2> would put an
    -- image inside a heading element and change how its own margin
    -- interacts with the h2's, both wrong). Still reuses the shared
    -- platform_page_header_css() below -- only the markup differs from
    -- the single-title-string case render_page_header covers.
    home_header = "<div class=\"platform-header\"><div>" .. logo_html .. heading_html ..
        "<p>Welcome back. Use the sidebar to get around, or jump in below.</p></div></div>"
    return string.format("""
<div class="fossil-doc" data-title="Home">
    <style>
%s
%s
%s
        .platform-home-logo { display: block; max-width: 240px; height: auto; margin-bottom: 16px; }
    </style>
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
""", platform_container_css(), platform_sitemap_css(), platform_page_header_css(), home_header,
     render_sitemap_item("document-edit", "New Document", "Write a new document from scratch."),
     render_sitemap_item("documents", "Documents", "Browse all documents, organized as a tree."),
     render_sitemap_item("data", "Data", "Registered entity types, row counts, and relations."),
     knowledge_link, tasks_link, system_link, extension_tiles)
end

-- Landing page for Setup/Admin-only tooling -- a single destination
-- rather than SQL/Users each getting their own top-level nav icon,
-- matching this deployment's earlier "System" concept. Callers
-- (cgi.lua) already gate the route itself on show_sql/show_admin
-- before rendering this; the links below still only show what the
-- caller says is allowed via its own show_sql/show_admin parameters.
-- Knowledge Pool used to be a card here too, but it's baseline-
-- accessible now with its own top-level nav icon (brex 492390825), so
-- it no longer belongs on an admin/setup landing page.
function html.render_system(show_sql, show_admin)
    items = ""
    if show_sql then
        items = items .. render_sitemap_item("sql", "SQL console", "Run ad hoc, read-only queries.")
    end
    if show_admin then
        items = items .. render_sitemap_item("admin-users", "Users", "Manage accounts and capabilities.")
        items = items .. render_sitemap_item("admin-api-keys", "API keys", "Manage external-integration API keys.")
        items = items .. render_sitemap_item("settings", "Settings", "Site name, branding, colors, and chat prompt.")
        items = items .. render_sitemap_item("admin-triggers", "Manual Triggers", "Run admin-triggered extension actions on demand.")
    end
    items = items .. render_sitemap_item("templates", "Templates", "Reusable entry templates for new documents.")

    return string.format("""
<div class="fossil-doc" data-title="System">
    <style>
%s
%s
%s
    </style>
    <div class="platform-container">
        %s
        <ul class="platform-sitemap">
%s
        </ul>
    </div>
</div>
""", platform_container_css(), platform_sitemap_css(), platform_page_header_css(), render_page_header("System", nil, nil), items)
end

-- Admin listing of every approved extension's capabilities.manual_triggers
-- (brex 925561615's own blocker) -- one button per declared trigger,
-- POSTing to /admin-triggers/<ext>/<trigger> (cgi.lua) and showing the
-- result in a single shared status placeholder. Built from page.lua's
-- existing actions/status_placeholder section types, the same pattern
-- html.render/html.render_entity_edit already use for their own
-- Save/Submit buttons -- not the canvas/plugin system, since a manual
-- trigger has no canvas page of its own to (re-)render, just a
-- success/failure message.
--
-- `triggers` is extension.approved_with_manual_triggers's own return
-- shape: a list of {name = <extension dir name>, manifest = <table>}.
function html.render_admin_triggers(triggers, nonce)
    page_lib = require("page")

    if #triggers == 0 then
        sections = {
            {type = "message", css_class = "status-msg", text = "No approved extension currently declares a manual trigger."},
        }
        validate_err = page_lib.validate(sections)
        if validate_err != nil then
            error(validate_err)
        end
        return string.format("""
<div class="fossil-doc" data-title="Manual Triggers">
    <style>
%s
%s
    </style>
    <div class="platform-container">
        %s
%s    </div>
</div>
""", platform_container_css(), platform_page_header_css(), render_page_header("Manual Triggers", nil, nil), page_lib.render(sections))
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

    return string.format("""
<div class="fossil-doc" data-title="Manual Triggers">
    <style>
%s
%s
%s
        .platform-actions { display: flex; flex-wrap: wrap; gap: 14px; }
    </style>
    <div class="platform-container">
        %s
%s    </div>

    <script nonce="%s">
(function(){
    var container = document.querySelector('.platform-actions');
    var status = document.getElementById('status-message');
    if (!container || !status) { return; }
    container.addEventListener('click', function(e){
        var btn = e.target.closest('button[data-ext]');
        if (!btn) { return; }
        var ext = btn.getAttribute('data-ext');
        var trigger = btn.getAttribute('data-trigger');
        btn.disabled = true;
        status.className = "status-msg";
        status.innerText = "Running...";
        PlatformJS.postJSON('/admin-triggers/' + encodeURIComponent(ext) + '/' + encodeURIComponent(trigger), {})
            .then(function(result){
                btn.disabled = false;
                if (result && result.success) {
                    status.className = "status-msg success";
                    status.innerText = result.message || "Done.";
                } else {
                    status.className = "status-msg error";
                    status.innerText = (result && result.error) || "Trigger failed.";
                }
            })
            .catch(function(){
                btn.disabled = false;
                status.className = "status-msg error";
                status.innerText = "An unexpected error occurred.";
            });
    });
})();
    </script>
</div>
""", platform_container_css(), platform_page_header_css(), platform_button_css(),
     render_page_header("Manual Triggers", nil, nil), actions_html, nonce)
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

-- One hue, monotone lightness, light->dark as maturity rises (an
-- ordinal ramp, not a categorical one -- tier order is meaningful, so
-- color should read as a sequence, not four arbitrary identities).
-- Validated against dataviz's ordinal-ramp checks (monotone L, adjacent
-- delta-L >= 0.06, light-end contrast >= 2:1 against the default
-- #fcfcfb-ish surface, single hue) -- these are the *fallback* values a
-- deployment's theme.lua can override per-key (config.THEME_COLOR_KEYS'
-- tier_0..tier_3), the same override convention every other themed
-- color here already follows. Reused as-is for node color in the
-- knowledge-graph explorer (doc/knowledge-graph-explorer.md) once that
-- ships, so a document's tier reads the same way on both pages.
KNOWLEDGE_TIER_COLORS = {
    [0] = "#b0abf0",
    [1] = "#8880ec",
    [2] = "#5c52e0",
    [3] = "#332ba8",
}

-- Landing page for src/knowledge.lua's tiering/retrieval-logging
-- system (see that module's own header) -- linked from System, not
-- given its own sidebar icon. Every stat/tier tile is a link to its
-- own backing table (html.render_knowledge_documents/-retrievals) --
-- deliberately the ONLY navigation on this page (no inline retrieval
-- preview, no second link to /chat) so there's one obvious way to
-- drill into each number, not several redundant ones.
function html.render_knowledge_pool(stats)
    tier_tiles = ""
    for tier = 0, 3 do
        tier_tiles = tier_tiles .. string.format(
            "<a class=\"platform-knowledge-tier\" href=\"knowledge-documents?tier=%d\" style=\"border-left: 4px solid var(--platform-tier-%d, %s);\"><strong>%s</strong><span class=\"dimmed\">%d note(s)</span>" ..
            "<p class=\"platform-knowledge-tier-caption\">%s</p></a>",
            tier, tier, KNOWLEDGE_TIER_COLORS[tier], html.html_escape(KNOWLEDGE_TIER_LABELS[tier]), stats.tier_counts[tier],
            html.html_escape(KNOWLEDGE_TIER_CAPTIONS[tier])
        )
    end

    return string.format("""
<div class="fossil-doc" data-title="Knowledge Pool">
    <style>
%s
%s
%s
        .platform-knowledge-stats { display: grid; grid-template-columns: repeat(4, minmax(10em, 1fr)); gap: 14px; margin-bottom: 20px; }
        .platform-knowledge-stats div, .platform-knowledge-stats a { border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; background: var(--platform-bg, #f8fafc); }
        .platform-knowledge-stats a { display: block; text-decoration: none !important; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-knowledge-stats a:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-knowledge-stats strong { display: block; font-size: 1.4rem; color: var(--platform-heading, #0f172a); }
        .platform-knowledge-tiers { display: grid; grid-template-columns: repeat(2, minmax(14em, 1fr)); gap: 12px; }
        .platform-knowledge-tier { display: block; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 12px 14px; background: var(--platform-bg, #f8fafc); text-decoration: none !important; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-knowledge-tier:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-knowledge-tier strong { display: block; margin-bottom: 4px; color: var(--platform-heading, #0f172a); }
        .platform-knowledge-tier-caption { margin: 6px 0 0 0; font-size: 0.82rem; color: var(--platform-muted, #64748b); }
        .platform-knowledge-panel { border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; background: var(--platform-bg, #f8fafc); }
        .platform-knowledge-panel h4 { margin: 0 0 10px 0; font-size: 0.95rem; color: var(--platform-muted, #64748b); }
        .dimmed { color: var(--platform-muted, #64748b); font-size: 0.85rem; }
    </style>
    <div class="platform-container">
        %s
        <div class="platform-knowledge-stats">
            <a href="knowledge-documents"><strong>%d</strong><span class="dimmed">pool records</span></a>
            <a href="knowledge-retrievals"><strong>%d</strong><span class="dimmed">retrieval runs</span></a>
            <a href="knowledge-reviewed"><strong>%d</strong><span class="dimmed">reviewed notes</span></a>
            <a href="chat"><strong>%d</strong><span class="dimmed">chat sessions</span></a>
        </div>
        <div class="platform-knowledge-panel">
            <h4>Processing Tiers</h4>
            <div class="platform-knowledge-tiers">
%s
            </div>
        </div>
        <p style="margin-top: 14px;"><a class="btn btn-secondary" href="knowledge-graph">Explore the knowledge graph &rarr;</a></p>
    </div>
</div>
""", platform_container_css(), platform_button_css(), platform_page_header_css(),
     render_page_header("Knowledge Pool", "<p>Notes promote through processing tiers as they're retrieved and reinforced; every retrieval is logged.</p>", nil),
     stats.note_count, stats.retrieval_count, stats.reviewed_note_count,
     stats.session_count, tier_tiles)
end

-- Obsidian-style graph view of the document_link graph (doc/knowledge-
-- graph-explorer.md, Phase 2): fetches /knowledge-graph-data client-
-- side and lays it out with a small, hand-rolled force simulation --
-- no charting/graph-layout dependency, consistent with why-luam.md's
-- "Minimal dependencies" stance and this problem's actual scale (a
-- single deployment's own document pool, not a general-purpose graph
-- product). Static for now: the simulation runs once on load and
-- settles, no drag/pan/zoom/click-to-navigate yet (Phase 3). Node
-- radius = heat, edge width/opacity = strength, node color = tier via
-- the same --platform-tier-N custom properties /knowledge's own tier
-- tiles use (KNOWLEDGE_TIER_COLORS) -- a document's tier reads the
-- same way on both pages.
function html.render_knowledge_graph(nonce)
    knowledge_graph = require("ui.knowledge_graph")
    kg_header = render_page_header("Knowledge Graph",
        "<p>Documents sized by heat, connections weighted by link strength -- see <a href=\"knowledge\">Knowledge Pool</a> for the tier/heat breakdown this visualizes.</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    base_css = platform_container_css() .. "\n" .. platform_button_css() .. "\n" .. platform_page_header_css()
    return knowledge_graph.render(KNOWLEDGE_TIER_LABELS, KNOWLEDGE_TIER_COLORS, kg_header, base_css, nonce)
end

-- Backing table for /knowledge's "N pool records" stat and each tier
-- tile (see cgi.lua's /knowledge-documents route for why this is its
-- own small view rather than /browse: "document" has no filterable
-- "tier" field to reuse /browse's ?filter_field= mechanism against).
-- `tier` is nil for the unfiltered "all pool records" link, 0-3 for a
-- single tier tile.
function html.render_knowledge_documents(rows, tier, title_override)
    title = "Pool records"
    if tier != nil then
        title = KNOWLEDGE_TIER_LABELS[tier]
        if title == nil then
            title = "Pool records"
        end
    end
    if title_override != nil then
        title = title_override
    end

    body_rows = ""
    for _, row in ipairs(rows) do
        tier_label = KNOWLEDGE_TIER_LABELS[tonumber(row.tier)]
        if tier_label == nil then
            tier_label = tostring(row.tier)
        end
        body_rows = body_rows .. string.format(
            "<tr><td><a href=\"document?entity_id=%s\">%s</a></td><td>%s</td><td>%s</td>" ..
            "<td>%s</td><td>%s</td></tr>",
            tostring(row.id), html.html_escape(row.title), html.html_escape(tier_label),
            tostring(row.retrieval_count), string.format("%.2f", row.effective_heat), display_value(row.source_type)
        )
    end

    table_or_empty = "<p class=\"platform-empty\">No documents.</p>"
    if #rows > 0 then
        table_or_empty = "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
            "<th>Title</th><th>Tier</th><th>Retrievals</th><th>Effective heat</th><th>Source</th>" ..
            "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
    end

    escaped_title = html.html_escape(title)
    kd_header = render_page_header(escaped_title, "<p>" .. tostring(#rows) .. " document(s)</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
%s
%s
        .platform-view-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        .platform-view-table th, .platform-view-table td { padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.9rem; }
        .platform-view-table th { background: var(--platform-bg-2, #f1f5f9); font-weight: 600; font-size: 0.78rem; color: var(--platform-th-text, #475569); text-transform: uppercase; letter-spacing: 0.06em; }
        .platform-view-table td { background: #ffffff; }
    </style>
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", escaped_title, platform_container_css(), platform_button_css() .. platform_table_wrapper_css(), platform_page_header_css(), kd_header, table_or_empty)
end

-- Backing table for /knowledge's "N retrieval runs" stat -- reuses
-- knowledge.recent_retrievals (already existed for the CLI/the old
-- inline "Recent Retrievals" preview), just without a small cap.
function html.render_knowledge_retrievals(rows)
    body_rows = ""
    for _, r in ipairs(rows) do
        body_rows = body_rows .. string.format(
            "<tr><td>#%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
            tostring(r.id), html.html_escape(r.query_text), html.html_escape(r.created_at), tostring(r.hit_count)
        )
    end

    table_or_empty = "<p class=\"platform-empty\">No retrievals yet.</p>"
    if #rows > 0 then
        table_or_empty = "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
            "<th>ID</th><th>Query</th><th>When</th><th>Hits</th>" ..
            "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
    end

    header = render_page_header("Retrieval runs", "<p>" .. tostring(#rows) .. " run(s)</p>",
        "<a class=\"btn btn-secondary\" href=\"knowledge\">&larr; Back to Knowledge Pool</a>")
    return string.format("""
<div class="fossil-doc" data-title="Retrieval runs">
    <style>
%s
%s
%s
        .platform-view-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        .platform-view-table th, .platform-view-table td { padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.9rem; }
        .platform-view-table th { background: var(--platform-bg-2, #f1f5f9); font-weight: 600; font-size: 0.78rem; color: var(--platform-th-text, #475569); text-transform: uppercase; letter-spacing: 0.06em; }
        .platform-view-table td { background: #ffffff; }
    </style>
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", platform_container_css(), platform_button_css() .. platform_table_wrapper_css(), platform_page_header_css(), header, table_or_empty)
end

function html.render_index(db_path, entity_types, edges, nonce)
    items_parts = {}
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
        table.insert(items_parts, "<li data-count=\"" .. tostring(row_count) .. "\"><a href=\"browse?type=" .. escaped_name .. "\" class=\"" .. trigger_class .. "\" tabindex=\"0\">" .. escaped_name ..
            count_popover .. "</a></li>")
    end
    items = table.concat(items_parts)

    list_or_empty = "<ul class=\"platform-index-list\">" .. items .. "</ul>"
    if #entity_types == 0 then
        list_or_empty = "<p class=\"platform-empty\">No entity types registered yet.</p>"
    end

    diagram_html = html.render_relation_diagram(db_path, entity_types, edges)

    index_header = render_page_header("Entity types", "<p>" .. tostring(#entity_types) .. " registered</p>", """
            <div class="platform-view-toggle" id="platform-view-toggle">
                <label class="platform-hide-empty-toggle"><input type="checkbox" id="platform-hide-empty"> Hide empty types</label>
                <button type="button" data-view="list" class="platform-view-active">List</button>
                <button type="button" data-view="diagram">Diagram</button>
            </div>
""")
    return string.format("""
<div class="fossil-doc" data-title="Overview">
    <style>
%s
%s
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
        .platform-entity-search-results a span.platform-entity-search-sub { color: var(--platform-muted, #64748b); font-weight: 400; margin-left: 6px; }
        .platform-entity-search-results a span.platform-entity-search-type { color: var(--platform-muted, #64748b); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; flex-shrink: 0; }
        .platform-entity-search-empty { padding: 10px 12px; color: var(--platform-muted, #64748b); font-size: 0.88rem; }
        .platform-index-list { list-style: none !important; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
        .platform-index-list li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); display: flex; align-items: center; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-index-list li:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-index-list li::marker { content: ""; }
        .platform-index-list a { flex: 1; display: block; padding: 12px 16px; color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; text-transform: capitalize; }
        .platform-index-list a:hover { background: var(--platform-bg-2, #f1f5f9); border-radius: var(--platform-radius-item, 10px) 0 0 var(--platform-radius-item, 10px); }
%s
    </style>
    %s
    <div class="platform-container">
        %s
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

        function render(items) {
            if (items.length === 0) {
                results.innerHTML = '<div class="platform-entity-search-empty">No matching entities.</div>';
            } else {
                results.innerHTML = items.map(function(item){
                    var sub = item.subtitle ? '<span class="platform-entity-search-sub">&middot; ' + PlatformJS.escapeHtml(item.subtitle) + '</span>' : '';
                    return '<a href="detail?type=' + encodeURIComponent(item.entity_type) + '&entity_id=' + item.id + '"><span>' +
                        PlatformJS.escapeHtml(item.label) + sub + '</span><span class="platform-entity-search-type">' + PlatformJS.escapeHtml(item.entity_type) + '</span></a>';
                }).join('');
            }
            results.classList.add('platform-entity-search-open');
        }

        var doSearch = PlatformJS.debounce(function(query){
            PlatformJS.fetchJSON('api/entity-search?query=' + encodeURIComponent(query)).then(render);
        }, 200);
        input.addEventListener('input', function(){
            var query = input.value.trim();
            if (!query) { results.classList.remove('platform-entity-search-open'); results.innerHTML = ''; return; }
            doSearch(query);
        });
        PlatformJS.onOutsideClick(input, function(){ return results; }, function(){
            results.classList.remove('platform-entity-search-open');
        });
        input.addEventListener('keydown', function(e){
            if (e.key === 'Escape') { results.classList.remove('platform-entity-search-open'); }
        });
    })();
    </script>
</div>
%s
""", platform_container_css(), platform_page_header_css(), html.relation_diagram_css() .. platform_table_wrapper_css(), html.popover_css(),
     index_header, list_or_empty, diagram_html, nonce, html.diagram_js(nonce))
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
                "<p><a class=\"btn btn-primary\" href=\"document-edit?from_template=" .. escaped_name .. "\">+ New document</a></p></li>"
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
%s
%s
        .platform-index-list { list-style: none !important; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
        .platform-index-list li { list-style: none !important; background: var(--platform-bg, #f8fafc); border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; }
        .platform-index-list li::marker { content: ""; }
        .platform-index-list a { font-weight: 700; color: var(--platform-accent, #4f46e5); text-decoration: none; }
        .platform-index-list a:hover { text-decoration: underline; }
        .platform-index-list p { margin: 6px 0 0 0; color: var(--platform-muted, #64748b); font-size: 0.88rem; }
        .platform-template-error { color: #991b1b; background: #fef2f2; border: 1px solid #fecaca; border-radius: var(--platform-radius-item, 10px); padding: 14px 16px; }
    </style>
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", platform_container_css(), platform_button_css() .. platform_table_wrapper_css(), platform_page_header_css(),
     render_page_header("Entry templates", "<p>Pick a template to see its rendered Markdown.</p>", nil), list_or_empty)
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

    template_header = render_page_header(escaped_label,
        "<p>" .. escaped_desc .. "</p><p><a class=\"btn btn-secondary\" href=\"templates\">&larr; All templates</a></p>",
        "<a class=\"btn btn-primary\" href=\"document-edit?from_template=" .. escaped_name .. "\">+ New document from template</a>")
    return string.format("""
<div class="fossil-doc" data-title="Template: %s">
    <style>
%s
%s
%s
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
        %s
        <p>Or select-all and copy the rendered snippet below.</p>
        <textarea class="platform-snippet" id="platform-template-content" readonly>%s</textarea>
    </div>
</div>
""", escaped_label, platform_container_css(), platform_button_css(), platform_page_header_css(), template_header, escaped_body)
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
        -- palette.
        if theme != nil then
            embed_css = html.theme_root_css(theme) .. " " .. embed_css
        end
    end
    sql_text_or_empty = sql_text
    if sql_text_or_empty == nil then
        sql_text_or_empty = ""
    end

    page_lib = require("page")
    render_lib = require("render")
    sections = {
        {
            type = "form",
            method = "get",
            action = "sql",
            fields = {
                {type = "textarea", name = "q", id = "platform-sql-query", value = sql_text_or_empty, placeholder = "SELECT * FROM sample LIMIT 20;", css_class = "platform-sql-input"},
            },
            submit_label = "Run",
        },
    }

    -- Three `<p class="platform-empty">`-shaped one-off messages (no
    -- rows, a genuinely empty submitted query, the real row count)
    -- stay as direct render.lib composition rather than page.lua
    -- sections -- that type only ever renders a <div>, and growing it
    -- with a tag override would be for this one page's benefit alone.
    -- The error state and the real results table both do fit the
    -- existing vocabulary exactly (message, table+html_fragment), so
    -- those go through page.lua like everything else.
    extra_html = ""
    if err != nil then
        table.insert(sections, {type = "message", css_class = "platform-sql-error", text = "Error: " .. err})
    elseif rows != nil then
        -- Every cell here is already-safe, pre-rendered HTML --
        -- display_value/render_reference_value both call
        -- html.html_escape (or build a real popover-linked <a>)
        -- internally -- never a raw value a plain string table-cell
        -- item's own auto-escaping should touch a second time.
        page_rows = {}
        for _, row in ipairs(rows) do
            cells = {}
            for _, name in ipairs(column_names) do
                ref_type = ref_columns[name]
                cell_html = display_value(row[name])
                if ref_type != nil then
                    cell_html = render_reference_value(db_path, ref_type, row[name])
                end
                table.insert(cells, {{type = "html_fragment", html = cell_html}})
            end
            table.insert(page_rows, cells)
        end

        if #rows == 0 then
            extra_html = render_lib.render("<p class=\"platform-empty\">No rows.</p>", {})
        else
            table.insert(sections, {
                type = "table",
                id = "sql-table",
                wrapper_class = "platform-table-wrapper",
                columns = column_names,
                rows = page_rows,
            })
            count_message = tostring(#rows) .. " rows"
            if truncated == true then
                count_message = "Showing first " .. tostring(#rows) .. " rows -- more may exist. Add your own LIMIT to see a different range."
            end
            extra_html = render_lib.render("<p class=\"platform-sql-count\">{{ text }}</p>", {text = count_message})
        end
    elseif sql_text_or_empty == "" then
        -- Submitted with a genuinely empty box -- distinct from the
        -- pre-run, example-prefilled first-load case below, which
        -- needs no message at all (nothing has failed or been skipped).
        extra_html = render_lib.render("<p class=\"platform-empty\">Enter a SQL query above, then click Run.</p>", {})
    end

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    result_html = page_lib.render(sections) .. extra_html

    sql_header = render_page_header("Query", "<p>Read-only (SELECT only) queries against the entity store. Setup/Admin only.</p>", nil)
    return string.format("""
<div class="fossil-doc" data-title="Query">
    <style>
%s
%s
        .platform-sql-input {
            width: 100%%;
            /* max-width explicit, not left to inherit: Fossil's own base
            ** CSS (src/default.css) has a bare "textarea { max-width:
            ** 95%% }" rule that otherwise wins over nothing here
            ** (measured 1045px vs the intended 1100px). This class
            ** selector's higher specificity overrides it. */
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
        %s
        /* Extra spacing below the query editor above -- the shared
           base rule (platform_table_wrapper_css()) has no opinion on
           that, since most of its other callers put a table first,
           not after an editor. */
        .platform-table-wrapper, .platform-empty { margin-top: 20px; }
        #sql-table { width: 100%%; border-collapse: separate; border-spacing: 0; min-width: 600px; }
        #sql-table th, #sql-table td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--platform-border, #e2e8f0); font-size: 0.85rem; }
        #sql-table th { background: var(--platform-bg-2, #f1f5f9); font-weight: 600; font-size: 0.75rem; color: var(--platform-th-text, #475569); text-transform: uppercase; letter-spacing: 0.06em; }
        #sql-table td { background: #ffffff; }
        %s
    </style>
    <div class="platform-container">
        %s
%s    </div>
</div>
%s
""", platform_container_css(), platform_page_header_css(), platform_button_css(), platform_table_wrapper_css(), html.popover_css() .. embed_css, sql_header, result_html, html.popover_js(nonce))
end

--------------------------------------------------------------------------
-- Documents (the notebook/wiki-style entity type, src/document.lua)
--------------------------------------------------------------------------

-- <option> tags for the parent-document <select> in render_document_edit.
-- Excludes `exclude_id` (a document can't be its own parent) -- doesn't
-- also exclude its descendants (which would need a full descendant
-- walk to build); choosing one of those is instead caught at save time
-- by document.would_create_cycle, with a real error message rather than
-- the option silently not being offered.
--
-- Duplicate titles are real and already fairly common (293 titles with
-- duplicates in production, mostly "Experiment N" documents resynced
-- from Benchling more than once) -- picking a parent
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
-- `query` / `results` (optional): a content search to show above the
-- tree (ui/document_tree.lua).
function html.render_document_tree(rows, can_create, nonce, query, results)
    document_tree = require("ui.document_tree")
    new_page_link = ""
    if can_create == true then
        new_page_link = "<a class=\"btn btn-primary\" href=\"document-edit\">+ New document</a> " ..
            "<a class=\"btn btn-secondary\" href=\"templates\">From template&hellip;</a>"
    end
    doc_tree_header = render_page_header("Documents", nil, new_page_link)
    base_css = platform_container_css() .. "\n" .. platform_button_css() .. "\n" .. platform_page_header_css()
    return document_tree.render(rows, doc_tree_header, base_css, nonce, query, results)
end

-- `can_edit` is likewise a plain boolean, decided by cgi.lua.
-- `rendered_html` (document.render_html's own output) is embedded
-- unescaped -- deliberately: it's already-rendered HTML from cmark's
-- default (non---unsafe) mode, which strips raw HTML/script tags out of
-- the *source* Markdown before this ever runs, so what comes back here
-- is already safe to place directly in the page, not user input that
-- still needs escaping.
-- One row of the document view's "Connections" list: the other
-- document, which way the link points, and why they're connected -- the
-- sentence around the link in whichever document's content holds it
-- (document.links' `context`), or a muted placeholder when there's none.
-- "Explain connection" opens a new document linking both
-- (document.connection_draft) -- the same thing the agent writes, so a
-- connection is explained one way, by anyone, in content.
function render_document_connection(link, doc_id, can_edit)
    arrow = "&larr;"
    arrow_title = "links here"
    if link.direction == "out" then
        arrow = "&rarr;"
        arrow_title = "this document links to it"
    end
    context_html = "<span class=\"platform-connection-context platform-connection-context-empty\">Nothing in the text says why yet.</span>"
    if link.context != nil and link.context != "" then
        context_html = "<span class=\"platform-connection-context\">" .. html.html_escape(link.context) .. "</span>"
    end
    explain_html = ""
    if can_edit == true then
        explain_html = " <a class=\"platform-connection-explain\" href=\"document-edit?connect_a=" .. tostring(doc_id) ..
            "&amp;connect_b=" .. tostring(link.id) .. "\">Explain connection</a>"
    end
    return "<li><span class=\"platform-connection-arrow\" title=\"" .. arrow_title .. "\">" .. arrow .. "</span> " ..
        "<a href=\"document?entity_id=" .. tostring(link.id) .. "\">" .. html.html_escape(link.title) .. "</a>" ..
        "<div class=\"platform-connection-detail\">" .. context_html .. explain_html .. "</div></li>"
end

-- `related` is cgi.lua's related_records for this document, already
-- narrowed to the types that aren't the document's own structure (see
-- document_related_records there); empty renders nothing.
function html.render_document(db_path, doc, rendered_html, breadcrumbs, children, links, can_edit, related)
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
        -- A plain file-tree-style list, not a row of buttons.
        children_html = children_html .. "<li><a href=\"document?entity_id=" .. tostring(child.id) .. "\">" ..
            html.html_escape(child.title) .. "</a></li>"
    end
    children_block = ""
    if children_html != "" then
        children_block = "<div class=\"platform-document-children\"><h4>Sub-documents</h4><ul>" .. children_html .. "</ul></div>"
    end

    connections_html = ""
    for _, link in ipairs(links) do
        connections_html = connections_html .. render_document_connection(link, doc.id, can_edit)
    end
    connections_block = ""
    if connections_html != "" then
        connections_block = "<div class=\"platform-document-connections\"><h4>Connections</h4><ul>" .. connections_html .. "</ul></div>"
    end

    edit_link = ""
    if can_edit == true then
        edit_link = "<a class=\"btn btn-secondary\" href=\"document-edit?entity_id=" .. tostring(doc.id) .. "\">Edit</a>"
    end
    -- The generic /detail page (ledger history/diff, same as every
    -- other entity type) has no other link into it from the document
    -- view itself -- document is its own dedicated route (/document,
    -- not /detail?type=document), found live: a real user on this page
    -- had no way to reach it at all.
    history_link = "<a class=\"btn btn-secondary\" href=\"detail?type=document&entity_id=" .. tostring(doc.id) .. "\">History</a>"

    related_block = ""
    related_html = related_records_html(db_path, related, doc.id)
    if related_html != "" then
        related_block = "<div class=\"platform-document-related\">" .. related_html .. "</div>"
    end

    escaped_doc_title = html.html_escape(doc.title)
    doc_header = render_page_header(escaped_doc_title, nil, "<div class=\"platform-header-actions\">" .. history_link .. edit_link .. "</div>")
    return string.format("""
<div class="fossil-doc" data-title="%s">
    <style>
%s
%s
        .platform-document-breadcrumbs { margin-bottom: 12px; font-size: 0.88rem; color: var(--platform-muted, #64748b); }
        .platform-document-breadcrumbs a { color: var(--platform-accent, #4f46e5); text-decoration: none; }
        .platform-document-breadcrumbs a:hover { text-decoration: underline; }
        %s
        .platform-document-content { line-height: 1.6; }
        .platform-document-content h1, .platform-document-content h2, .platform-document-content h3 { margin-top: 1.2em; }
        .platform-document-content a { color: var(--platform-accent, #4f46e5); text-decoration: none; }
        .platform-document-content a:hover { text-decoration: underline; }
        .platform-document-content a.platform-tag-chip { display: inline-block; padding: 0 8px; border-radius: 999px; background: var(--platform-bg-2, #f1f5f9); font-size: 0.85em; line-height: 1.6; }
        .platform-document-content a.platform-tag-chip:hover { text-decoration: none; filter: brightness(0.96); }
        %s
        .platform-document-children, .platform-document-connections, .platform-document-related { margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--platform-border, #e2e8f0); }
        .platform-document-related .platform-subheading { font-size: 0.95rem; color: var(--platform-muted, #64748b); margin: 0 0 8px 0; }
        .platform-document-children h4, .platform-document-connections h4 { margin: 0 0 8px 0; font-size: 0.95rem; color: var(--platform-muted, #64748b); }
        .platform-document-children ul { list-style: none; padding: 0; margin: 0; }
        .platform-document-children li { padding: 2px 0 2px 16px; }
        .platform-document-children a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 600; }
        .platform-document-children a:hover { text-decoration: underline; }
        .platform-document-connections ul { list-style: none; padding: 0; margin: 0; }
        .platform-document-connections li { padding: 8px 0; border-bottom: 1px solid var(--platform-border, #e2e8f0); }
        .platform-document-connections li:last-child { border-bottom: none; }
        .platform-document-connections a { color: var(--platform-accent, #4f46e5); text-decoration: none; font-weight: 500; }
        .platform-document-connections a:hover { text-decoration: underline; }
        .platform-connection-arrow { color: var(--platform-muted, #64748b); }
        .platform-connection-detail { margin: 2px 0 0 1.4em; font-size: 0.9rem; }
        .platform-connection-context-empty { color: var(--platform-muted, #64748b); font-style: italic; }
        .platform-document-connections a.platform-connection-explain { font-weight: 400; font-size: 0.85rem; margin-left: 6px; white-space: nowrap; }
    </style>
    <div class="platform-container">
        <div class="platform-document-breadcrumbs">%s <a href="documents">(all documents)</a></div>
        %s
        <div class="platform-document-content">
%s
        </div>
        %s
        %s
        %s
    </div>
</div>
""", escaped_doc_title, platform_container_css(), platform_button_css(),
     platform_page_header_css() .. platform_related_css(), html.plot_css(), breadcrumb_html, doc_header, rendered_html, children_block, connections_block, related_block)
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
    document_edit = require("ui.document_edit")
    fields = document_edit.resolve_initial_fields(doc, prefill)
    doc_edit_header = render_page_header(html.html_escape(fields.heading_text), nil, nil)
    base_css = platform_container_css() .. "\n" .. platform_button_css() .. "\n" ..
        platform_page_header_css() .. platform_error_banner_css()
    return document_edit.render(fields, parent_options_html, csrf_token, error_message, doc_edit_header, base_css, nonce)
end

--------------------------------------------------------------------------
-- Chat/agent (src/agent.lua)
--------------------------------------------------------------------------

-- Roles whose content is real model output (often Markdown -- headings,
-- bold, lists) rather than plain human-typed text -- without this, a
-- reply with **bold** section headers would show the literal asterisks
-- to the user, since everything else here is plain html-escaped text.
-- Rendered through the exact same cmark-gfm pipeline document pages
-- already use (document.render_markdown), not a separate one -- its
-- own non-`--unsafe` mode already strips raw HTML/scripts, so this is
-- exactly as safe to embed unescaped as any other rendered-Markdown
-- HTML this codebase already trusts.
-- A field on the `html` table, not a bare global -- cgi.lua's own
-- chat_widget_state (a different required module, its own separate
-- environment in this runtime) needs this same set too, and only
-- values actually returned by require() (table fields like this one,
-- not bare globals) cross that boundary. A bare global here crashes
-- cgi.lua outright ("attempt to index global 'CHAT_MARKDOWN_ROLES' (a
-- nil value)") the moment a route that isn't html.lua's own tries to
-- read it.
html.CHAT_MARKDOWN_ROLES = {assistant = true, self_check = true, compaction_summary = true, progress = true}

-- Full-width, one-row-per-session list -- clicking a session hands it
-- off to the floating widget (see html.render_chat's own comment) and
-- pops the widget open right onto that conversation, so this list's
-- only job is picking which one, not previewing it (see doc/
-- architecture.md's "Chat" section).
function render_chat_sessions_list(sessions, current_session_id)
    items = ""
    for _, s in ipairs(sessions) do
        css_class = "platform-chat-session-row"
        if current_session_id != nil and s.id == current_session_id then
            css_class = css_class .. " platform-chat-session-active"
        end
        label = s.title
        if label == nil or label == "" then
            label = "Untitled chat"
        end
        started_at = ""
        if s.created_at != nil then
            started_at = "<span class=\"platform-chat-session-started\">" .. html.html_escape(s.created_at) .. "</span>"
        end
        items = items .. "<li><a class=\"" .. css_class .. "\" href=\"chat?session_id=" .. s.id .. "\">" ..
            "<span class=\"platform-chat-session-title\">" .. html.html_escape(label) .. "</span>" ..
            started_at .. "</a></li>"
    end
    if items == "" then
        return "<p class=\"platform-empty\">No chats yet.</p>"
    end
    return "<ul class=\"platform-chat-sessions\">" .. items .. "</ul>"
end

-- Read-only, full-width chat-history browser (see doc/architecture.md's
-- "Chat" section -- only the floating widget, html.render_chat_widget,
-- ever actually shows a transcript or sends/approves/denies anything).
-- This page's only job is picking a session: clicking one hands its id
-- to the widget (cgi.lua's /chat route sets page_context.
-- open_chat_session_id) and pops the widget open right onto it, so
-- there's exactly one place a conversation is ever previewed or
-- continued, never two.
function html.render_chat(sessions, current_session_id, nonce)
    sessions_html = render_chat_sessions_list(sessions, current_session_id)

    return string.format("""
<div class="fossil-doc" data-title="Chat">
    <style>
%s
%s
        .platform-chat-sessions { list-style: none !important; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
        .platform-chat-session-row { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 14px 18px; border: 1px solid var(--platform-border, #e2e8f0); border-radius: var(--platform-radius-item, 10px); background: var(--platform-bg, #f8fafc); text-decoration: none !important; transition: var(--platform-transition, all 0.2s cubic-bezier(0.4, 0, 0.2, 1)); }
        .platform-chat-session-row:hover { border-color: var(--platform-accent, #4f46e5); box-shadow: 0 4px 12px rgba(0,0,0,0.06); }
        .platform-chat-session-title { color: var(--platform-heading, #0f172a); font-weight: 600; }
        .platform-chat-session-active { border-color: var(--platform-accent, #4f46e5); }
        .platform-chat-session-active .platform-chat-session-title { color: var(--platform-accent, #4f46e5); }
        .platform-chat-session-started { font-size: 0.8rem; color: var(--platform-muted, #64748b); flex-shrink: 0; }
    </style>
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", platform_container_css(), platform_page_header_css(),
     render_page_header("Chat", "<p>Pick a conversation to continue it in the chat widget.</p>", nil),
     sessions_html)
end

--------------------------------------------------------------------------
-- Floating chat widget -- rendered on every authenticated page (see
-- html.page_shell), the only surviving way to actually chat (render_chat
-- above is a read-only history browser). Talks to /api/chat-widget-*
-- (cgi.lua). Its own session_id lives in the browser's localStorage (not
-- server-rendered state), so it survives a normal, full-page navigation
-- between one platform page and the next the same way it would if this
-- were a true SPA -- except when a page hands it a specific session to
-- resume via page_context.open_chat_session_id (see below), which wins
-- over whatever was already cached.
function platform_chat_widget_css()
    chat_widget = require("ui.chat_widget")
    return chat_widget.css(PLATFORM_LAYOUT)
end

function html.render_chat_widget(nonce, attachments_enabled)
    chat_widget = require("ui.chat_widget")
    return chat_widget.render(nonce, attachments_enabled, ICON_CHAT_BUBBLE)
end

-- Exposed purely so tst/unit/html.lua can reach them across the
-- require() boundary -- see the matching comment in agent_vertex.lua.
html.apply_nav_hidden = apply_nav_hidden
html.apply_nav_order = apply_nav_order
html.word_diff_runs = word_diff_runs
html.word_diff_html = word_diff_html

return html
