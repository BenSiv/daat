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

html_lib = require("html")
render_lib = require("render")

page = {}

FORM_FIELD_TYPES = {text = true, password = true, hidden = true}

-- Validates one section, returning an error string prefixed with
-- `label` (e.g. "page section #3" at the top level, or a nested
-- "page section #2 (table) row #1 cell #2 item #1" for a section
-- embedded in a table cell -- see the `table` type below) or nil.
-- Split out from page.validate so table cells can validate their own
-- nested sections through the exact same rules, not a second copy of
-- them.
function validate_section(section, label)
    if section.type == "subheading" then
        if type(section.text) != "string" or section.text == "" then
            return label .. " (subheading): missing 'text'"
        end
    elseif section.type == "message" then
        if type(section.css_class) != "string" or section.css_class == "" then
            return label .. " (message): missing 'css_class'"
        end
        if type(section.text) != "string" or section.text == "" then
            return label .. " (message): missing 'text'"
        end
    elseif section.type == "secret_reveal" then
        if type(section.css_class) != "string" or section.css_class == "" then
            return label .. " (secret_reveal): missing 'css_class'"
        end
        if type(section.instruction) != "string" or section.instruction == "" then
            return label .. " (secret_reveal): missing 'instruction'"
        end
        if type(section.value) != "string" or section.value == "" then
            return label .. " (secret_reveal): missing 'value'"
        end
    elseif section.type == "form" then
        if type(section.method) != "string" or section.method == "" then
            return label .. " (form): missing 'method'"
        end
        if type(section.action) != "string" or section.action == "" then
            return label .. " (form): missing 'action'"
        end
        if type(section.fields) != "table" then
            return label .. " (form): missing 'fields'"
        end
        for j, field in ipairs(section.fields) do
            if FORM_FIELD_TYPES[field.type] == nil then
                return string.format("%s (form) field #%d: invalid type '%s'", label, j, tostring(field.type))
            end
            if type(field.name) != "string" or field.name == "" then
                return string.format("%s (form) field #%d: missing 'name'", label, j)
            end
            if field.type == "hidden" then
                if type(field.value) != "string" then
                    return string.format("%s (form) field #%d (hidden): missing 'value'", label, j)
                end
            elseif field.label != nil and (type(field.label) != "string" or field.label == "") then
                -- label is optional (an inline table-cell field renders
                -- with no visible <label>, see .platform-admin-inline-form
                -- callers) -- but if given at all, it has to be real text.
                return string.format("%s (form) field #%d: 'label' must be a non-empty string if given", label, j)
            end
        end
        if type(section.submit_label) != "string" or section.submit_label == "" then
            return label .. " (form): missing 'submit_label'"
        end
    elseif section.type == "table" then
        if type(section.columns) != "table" or #section.columns == 0 then
            return label .. " (table): must have a non-empty 'columns' list"
        end
        if type(section.rows) != "table" then
            return label .. " (table): missing 'rows'"
        end
        for r, row in ipairs(section.rows) do
            if type(row) != "table" then
                return string.format("%s (table) row #%d: must be a list of cells", label, r)
            end
            for c, cell in ipairs(row) do
                if type(cell) != "table" then
                    return string.format("%s (table) row #%d cell #%d: must be a list of items", label, r, c)
                end
                for k, item in ipairs(cell) do
                    item_label = string.format("%s (table) row #%d cell #%d item #%d", label, r, c, k)
                    if type(item) == "table" then
                        -- Only 'form' -- not any section type generally --
                        -- since render_page_table only knows how to render
                        -- a nested form (see its own header comment on why
                        -- that's not generic dispatch). Keep this in sync
                        -- with render_page_table's own capability rather
                        -- than accepting something validate allows but
                        -- render would silently drop.
                        if item.type != "form" then
                            return item_label .. ": a table cell can only nest a 'form' section, not '" .. tostring(item.type) .. "'"
                        end
                        item_err = validate_section(item, item_label)
                        if item_err != nil then
                            return item_err
                        end
                    elseif type(item) != "string" then
                        return item_label .. ": must be a string or a 'form' section"
                    end
                end
            end
        end
    else
        return label .. ": invalid type '" .. tostring(section.type) .. "'"
    end
    return nil
end

-- Checks each section's `type` against the known vocabulary and that
-- type's required fields. Not a trust boundary (every caller is
-- first-party code, not an attacker) -- this is a fast, clear error
-- for a programmer mistake (a typo'd type, a missing field) instead of
-- a silently blank or malformed page, the same role template.validate
-- plays for template sections. Unlike template.validate/
-- html.validate_canvas, though, a failure here is never a real,
-- expected error path -- section lists are always hardcoded literals
-- daat's own code just built two lines above the validate call, never
-- external/untrusted data -- so callers are expected to `error()` on a
-- non-nil return, not thread nil+err onward the way those two do (see
-- doc/templating.md).
function page.validate(sections)
    if type(sections) != "table" then
        return "page must be a list of sections"
    end
    for i, section in ipairs(sections) do
        err = validate_section(section, "page section #" .. tostring(i))
        if err != nil then
            return err
        end
    end
    return nil
end

-- Shared by the standalone `message` section type and `form`'s own
-- inline `message` field -- one styled banner shape, the CSS class
-- always supplied by the caller rather than hardcoded here, since
-- different pages currently style this differently (login's shared
-- .platform-error-banner, account's own .platform-account-message/
-- -error, the admin pages' own .platform-admin-message/-error) and
-- unifying those CSS classes is a separate decision from this
-- migration, not bundled into it.
function render_page_message(css_class, text)
    return render_lib.render(
        "<div class=\"{{{ css_class }}}\">{{ text }}</div>",
        {css_class = css_class, text = text}
    )
end

-- A one-time "here's a secret value, it will never be shown again"
-- banner (an API key's raw value right after creation) -- a real,
-- different shape from render_page_message's plain single string: bold
-- instruction text plus the value itself in a distinct <code> run, not
-- one escaped sentence.
function render_page_secret_reveal(css_class, instruction, value)
    return render_lib.render(
        "<div class=\"{{{ css_class }}}\"><strong>{{ instruction }}</strong> <code>{{ value }}</code></div>",
        {css_class = css_class, instruction = instruction, value = value}
    )
end

-- One optional HTML attribute, escaped, omitted entirely when `value`
-- is absent -- shared by every optional string-valued <input>
-- attribute (value/placeholder/size/autocomplete) instead of a
-- separate hand-written branch per attribute.
function attr_fragment(name, value)
    if value == nil or value == "" then
        return ""
    end
    return " " .. name .. "=\"" .. html_lib.html_escape(tostring(value)) .. "\""
end

function render_page_field(field)
    if field.type == "hidden" then
        return render_lib.render(
            "        <input type=\"hidden\" name=\"{{ name }}\" value=\"{{ value }}\">\n",
            {name = field.name, value = field.value}
        )
    end

    required_attr = ""
    if field.required == true then
        required_attr = " required"
    end

    -- id only when there's a real label for it to target -- an
    -- inline, no-label field (an admin table's compact per-row inputs,
    -- shown via placeholder instead) never had one before this
    -- vocabulary existed, and an unmatched id is dead weight, not a
    -- neutral default.
    label_inner = ""
    id_attr = ""
    if field.label != nil then
        label_inner = render_lib.render(
            "        <label for=\"{{ name }}\">{{ label }}</label>\n",
            {name = field.name, label = field.label}
        )
        id_attr = attr_fragment("id", field.name)
    end

    extra_attrs = attr_fragment("value", field.value) ..
        attr_fragment("placeholder", field.placeholder) ..
        attr_fragment("size", field.size) ..
        attr_fragment("autocomplete", field.autocomplete)

    return label_inner .. render_lib.render(
        "        <input type=\"{{{ type }}}\"{{{ id_attr }}} name=\"{{ name }}\"{{{ extra_attrs }}}{{{ required_attr }}}>\n",
        {
            name = field.name,
            type = field.type,
            id_attr = id_attr,
            extra_attrs = extra_attrs,
            required_attr = required_attr,
        }
    )
end

function render_page_form(section)
    fields_html = {}
    for _, field in ipairs(section.fields) do
        table.insert(fields_html, render_page_field(field))
    end

    heading_inner = ""
    if section.heading != nil then
        heading_inner = render_lib.render("<h2>{{ heading }}</h2>", {heading = section.heading})
    end

    message_inner = ""
    if section.message != nil and section.message != "" then
        message_inner = render_page_message("platform-error-banner", section.message)
    end

    css_class_attr = ""
    if section.css_class != nil then
        css_class_attr = " class=\"" .. section.css_class .. "\""
    end

    submit_class = "btn-primary"
    if section.submit_class != nil then
        submit_class = section.submit_class
    end

    return render_lib.render("""
    <form{{{ css_class_attr }}} method="{{{ method }}}" action="{{{ action }}}">
        {{{ heading_inner }}}
        {{{ message_inner }}}
{{{ fields_html }}}        <button type="submit" class="btn {{{ submit_class }}}">{{ submit_label }}</button>
    </form>
""", {
        css_class_attr = css_class_attr,
        method = section.method,
        action = section.action,
        heading_inner = heading_inner,
        message_inner = message_inner,
        fields_html = table.concat(fields_html),
        submit_class = submit_class,
        submit_label = section.submit_label,
    })
end

-- A table whose cells can hold plain text or a nested `form` (in
-- practice, so far, the only section type a real page has ever needed
-- inside a cell -- an admin table's per-row action forms). Each item
-- dispatches to render_page_form directly rather than through the
-- generic render_page_section: that function is defined further down
-- this file and itself dispatches to render_page_table for `table`
-- sections, so calling it from here would be real mutual recursion
-- between two separately-named functions -- unlike validate_section's
-- own self-recursion (safe: a function can always call itself by name,
-- since the assignment finishes before the body ever runs), two
-- DIFFERENT functions each calling the other hits the same
-- forward-reference trap as doc/templating.md's ordering gotcha,
-- because whichever one is defined first still sees the other as an
-- unset global at the time its own body is compiled. Extend this if a
-- second nested type is ever genuinely needed in a cell -- not before.
function render_page_table(section)
    header_cells = ""
    for _, col in ipairs(section.columns) do
        header_cells = header_cells .. render_lib.render("<th>{{ col }}</th>", {col = col})
    end
    body_rows = ""
    for _, row in ipairs(section.rows) do
        cells = ""
        for _, cell in ipairs(row) do
            item_parts = {}
            for _, item in ipairs(cell) do
                if type(item) == "table" then
                    table.insert(item_parts, render_page_form(item))
                else
                    table.insert(item_parts, render_lib.render("{{ item }}", {item = item}))
                end
            end
            cells = cells .. "<td>" .. table.concat(item_parts) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end
    css_class_attr = ""
    if section.css_class != nil then
        css_class_attr = " class=\"" .. section.css_class .. "\""
    end
    return render_lib.render(
        "    <table{{{ css_class_attr }}}><thead><tr>{{{ header_cells }}}</tr></thead><tbody>{{{ body_rows }}}</tbody></table>\n",
        {css_class_attr = css_class_attr, header_cells = header_cells, body_rows = body_rows}
    )
end

-- Renders one section to HTML. Split out from page.render for the
-- same reason validate_section is split from page.validate: a table
-- cell's nested section renders through this exact function too, not
-- a second copy of the dispatch.
function render_page_section(section)
    if section.type == "subheading" then
        return render_lib.render("    <h3>{{ text }}</h3>\n", {text = section.text})
    elseif section.type == "message" then
        return "    " .. render_page_message(section.css_class, section.text) .. "\n"
    elseif section.type == "secret_reveal" then
        return "    " .. render_page_secret_reveal(section.css_class, section.instruction, section.value) .. "\n"
    elseif section.type == "form" then
        return render_page_form(section)
    elseif section.type == "table" then
        return render_page_table(section)
    end
    return ""
end

-- Turns a validated section list into real HTML. Caller is expected to
-- have already checked page.validate.
function page.render(sections)
    parts = {}
    for _, section in ipairs(sections) do
        table.insert(parts, render_page_section(section))
    end
    return table.concat(parts)
end

return page
