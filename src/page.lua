-- First-party-only page-section vocabulary: daat's OWN trusted pages
-- built as a typed table of sections instead of ad hoc string
-- concatenation, dispatched to a renderer -- the same "typed-table ->
-- trusted renderer" shape template.lua and html.lua's own extension
-- canvas already use.
--
-- Deliberately NOT the same mechanism as html.lua's canvas
-- (html.validate_canvas/html.render_canvas). That one exists to be a
-- narrow, deliberately-limited TRUST BOUNDARY: a plugin's page is
-- restricted to a closed vocabulary specifically so untrusted,
-- deployment-authored extension code can never emit arbitrary
-- HTML/JS. This module has no such boundary to protect -- every
-- caller is daat's own first-party code building its own pages -- so
-- its vocabulary can and should grow to cover what daat's real pages
-- actually need, without that growth ever widening what an extension
-- is allowed to do. Sharing one vocabulary between the two would mean
-- either crippling core pages down to the canvas's narrow set, or
-- growing the canvas to match core's needs and handing extensions
-- that same expanded surface -- both wrong for different reasons, see
-- doc/templating.md.
--
-- Vocabulary grows only when a real page needs a new section type,
-- same discipline template.lua's own four types and the canvas's own
-- four element types were grown under -- not speculatively.

render_lib = require("render")

page = {}

FORM_FIELD_TYPES = {text = true, password = true}

-- Checks each section's `type` against the known vocabulary and that
-- type's required fields. Not a trust boundary (every caller is
-- first-party code, not an attacker) -- this is a fast, clear error
-- for a programmer mistake (a typo'd type, a missing field) instead of
-- a silently blank or malformed page, the same role template.validate
-- plays for template sections.
function page.validate(sections)
    if type(sections) != "table" then
        return "page must be a list of sections"
    end
    for i, section in ipairs(sections) do
        if section.type == "form" then
            if type(section.method) != "string" or section.method == "" then
                return string.format("page section #%d (form): missing 'method'", i)
            end
            if type(section.action) != "string" or section.action == "" then
                return string.format("page section #%d (form): missing 'action'", i)
            end
            if type(section.fields) != "table" then
                return string.format("page section #%d (form): missing 'fields'", i)
            end
            for j, field in ipairs(section.fields) do
                if FORM_FIELD_TYPES[field.type] == nil then
                    return string.format("page section #%d (form) field #%d: invalid type '%s'", i, j, tostring(field.type))
                end
                if type(field.name) != "string" or field.name == "" then
                    return string.format("page section #%d (form) field #%d: missing 'name'", i, j)
                end
                if type(field.label) != "string" or field.label == "" then
                    return string.format("page section #%d (form) field #%d: missing 'label'", i, j)
                end
            end
            if type(section.submit_label) != "string" or section.submit_label == "" then
                return string.format("page section #%d (form): missing 'submit_label'", i)
            end
        else
            return string.format("page section #%d: invalid type '%s'", i, tostring(section.type))
        end
    end
    return nil
end

function render_page_form(section)
    fields_html = {}
    for _, field in ipairs(section.fields) do
        required_attr = ""
        if field.required == true then
            required_attr = " required"
        end
        autocomplete_attr = ""
        if field.autocomplete != nil and field.autocomplete != "" then
            autocomplete_attr = " autocomplete=\"" .. field.autocomplete .. "\""
        end
        table.insert(fields_html, render_lib.render(
            "        <label for=\"{{ name }}\">{{ label }}</label>\n" ..
            "        <input type=\"{{{ type }}}\" id=\"{{ name }}\" name=\"{{ name }}\"{{{ autocomplete_attr }}}{{{ required_attr }}}>\n",
        {
            name = field.name,
            label = field.label,
            type = field.type,
            autocomplete_attr = autocomplete_attr,
            required_attr = required_attr,
        }))
    end

    heading_inner = ""
    if section.heading != nil then
        heading_inner = render_lib.render("<h2>{{ heading }}</h2>", {heading = section.heading})
    end

    message_inner = ""
    if section.message != nil and section.message != "" then
        message_inner = render_lib.render(
            "<div class=\"platform-error-banner\">{{ message }}</div>",
            {message = section.message}
        )
    end

    css_class_attr = ""
    if section.css_class != nil then
        css_class_attr = " class=\"" .. section.css_class .. "\""
    end

    return render_lib.render("""
    <form{{{ css_class_attr }}} method="{{{ method }}}" action="{{{ action }}}">
        {{{ heading_inner }}}
        {{{ message_inner }}}
{{{ fields_html }}}        <button type="submit" class="btn btn-primary">{{ submit_label }}</button>
    </form>
""", {
        css_class_attr = css_class_attr,
        method = section.method,
        action = section.action,
        heading_inner = heading_inner,
        message_inner = message_inner,
        fields_html = table.concat(fields_html),
        submit_label = section.submit_label,
    })
end

-- Turns a validated section list into real HTML. Caller is expected to
-- have already checked page.validate.
function page.render(sections)
    parts = {}
    for _, section in ipairs(sections) do
        if section.type == "form" then
            table.insert(parts, render_page_form(section))
        end
    end
    return table.concat(parts)
end

return page
