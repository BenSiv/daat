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

FORM_FIELD_TYPES = {text = true, password = true, hidden = true, checkbox = true, file = true, textarea = true}

-- Validates one field list (a form's own top-level `fields`, or one of
-- its `groups[i].fields` -- see `form`'s own validation below for why
-- a form can have both). Split out so both call the exact same rules,
-- not two copies of them.
function validate_fields(fields, label)
    for j, field in ipairs(fields) do
        if FORM_FIELD_TYPES[field.type] == nil then
            return string.format("%s field #%d: invalid type '%s'", label, j, tostring(field.type))
        end
        if type(field.name) != "string" or field.name == "" then
            return string.format("%s field #%d: missing 'name'", label, j)
        end
        if field.type == "hidden" then
            if type(field.value) != "string" then
                return string.format("%s field #%d (hidden): missing 'value'", label, j)
            end
        elseif field.label != nil and (type(field.label) != "string" or field.label == "") then
            -- label is optional (an inline table-cell field renders
            -- with no visible <label>, see .platform-admin-inline-form
            -- callers) -- but if given at all, it has to be real text.
            return string.format("%s field #%d: 'label' must be a non-empty string if given", label, j)
        end
        if field.wrapper_class != nil and (type(field.wrapper_class) != "string" or field.wrapper_class == "") then
            return string.format("%s field #%d: 'wrapper_class' must be a non-empty string if given", label, j)
        end
        if field.css_class != nil and (type(field.css_class) != "string" or field.css_class == "") then
            return string.format("%s field #%d: 'css_class' must be a non-empty string if given", label, j)
        end
        if field.id != nil and (type(field.id) != "string" or field.id == "") then
            return string.format("%s field #%d: 'id' must be a non-empty string if given", label, j)
        end
    end
    return nil
end

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
        if section.heading != nil and (type(section.heading) != "string" or section.heading == "") then
            return label .. " (form): 'heading' must be a non-empty string if given"
        end
        if section.message != nil and (type(section.message) != "string" or section.message == "") then
            return label .. " (form): 'message' must be a non-empty string if given"
        end
        if section.css_class != nil and (type(section.css_class) != "string" or section.css_class == "") then
            return label .. " (form): 'css_class' must be a non-empty string if given"
        end
        if section.submit_class != nil and (type(section.submit_class) != "string" or section.submit_class == "") then
            return label .. " (form): 'submit_class' must be a non-empty string if given"
        end
        if type(section.fields) != "table" then
            return label .. " (form): missing 'fields'"
        end
        fields_err = validate_fields(section.fields, label .. " (form)")
        if fields_err != nil then
            return fields_err
        end
        -- groups: fields visually grouped under their own heading
        -- inside this same <form> (settings' Site/Branding/Colors/Chat
        -- assistant sections) -- HTML forms can't nest, so this is how
        -- one real <form> with one real submit button still gets more
        -- than one flat field list. section.fields stays for anything
        -- that isn't part of a visible group (a form-wide hidden CSRF
        -- token); groups is only for fields with a heading to sit
        -- under. Both can be present on the same form at once.
        if section.groups != nil then
            if type(section.groups) != "table" then
                return label .. " (form): 'groups' must be a list if given"
            end
            for g, group in ipairs(section.groups) do
                group_label = string.format("%s (form) group #%d", label, g)
                if type(group.css_class) != "string" or group.css_class == "" then
                    return group_label .. ": missing 'css_class'"
                end
                if type(group.heading) != "string" or group.heading == "" then
                    return group_label .. ": missing 'heading'"
                end
                if group.intro != nil and (type(group.intro) != "string" or group.intro == "") then
                    return group_label .. ": 'intro' must be a non-empty string if given"
                end
                if group.fields_wrapper_class != nil and (type(group.fields_wrapper_class) != "string" or group.fields_wrapper_class == "") then
                    return group_label .. ": 'fields_wrapper_class' must be a non-empty string if given"
                end
                if type(group.fields) != "table" then
                    return group_label .. ": missing 'fields'"
                end
                group_fields_err = validate_fields(group.fields, group_label)
                if group_fields_err != nil then
                    return group_fields_err
                end
            end
        end
        if section.enctype != nil and (type(section.enctype) != "string" or section.enctype == "") then
            return label .. " (form): 'enctype' must be a non-empty string if given"
        end
        if type(section.submit_label) != "string" or section.submit_label == "" then
            return label .. " (form): missing 'submit_label'"
        end
    elseif section.type == "table" then
        if section.css_class != nil and (type(section.css_class) != "string" or section.css_class == "") then
            return label .. " (table): 'css_class' must be a non-empty string if given"
        end
        if section.wrapper_class != nil and (type(section.wrapper_class) != "string" or section.wrapper_class == "") then
            return label .. " (table): 'wrapper_class' must be a non-empty string if given"
        end
        if section.id != nil and (type(section.id) != "string" or section.id == "") then
            return label .. " (table): 'id' must be a non-empty string if given"
        end
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
                        -- Only 'form' or 'html_fragment' -- not any section type
                        -- generally -- since render_page_table only knows
                        -- how to render these two (see its own header
                        -- comment on why that's not generic dispatch). Keep
                        -- this in sync with render_page_table's own
                        -- capability rather than accepting something
                        -- validate allows but render would silently drop.
                        if item.type == "html_fragment" then
                            if type(item.html) != "string" then
                                return item_label .. " (html_fragment): missing 'html'"
                            end
                        elseif item.type == "form" then
                            item_err = validate_section(item, item_label)
                            if item_err != nil then
                                return item_err
                            end
                        else
                            return item_label .. ": a table cell can only nest a 'form' or 'html_fragment' item, not '" .. tostring(item.type) .. "'"
                        end
                    elseif type(item) != "string" then
                        return item_label .. ": must be a string, a 'form' section, or a 'html_fragment' item"
                    end
                end
            end
        end
    elseif section.type == "actions" then
        if type(section.buttons) != "table" or #section.buttons == 0 then
            return label .. " (actions): must have a non-empty 'buttons' list"
        end
        for b, button in ipairs(section.buttons) do
            button_label = string.format("%s (actions) button #%d", label, b)
            if type(button.label) != "string" or button.label == "" then
                return button_label .. ": missing 'label'"
            end
            if type(button.id) != "string" or button.id == "" then
                return button_label .. ": missing 'id'"
            end
            if type(button.css_class) != "string" or button.css_class == "" then
                return button_label .. ": missing 'css_class'"
            end
        end
        if section.style != nil and (type(section.style) != "string" or section.style == "") then
            return label .. " (actions): 'style' must be a non-empty string if given"
        end
    elseif section.type == "status_placeholder" then
        if type(section.id) != "string" or section.id == "" then
            return label .. " (status_placeholder): missing 'id'"
        end
        if type(section.css_class) != "string" or section.css_class == "" then
            return label .. " (status_placeholder): missing 'css_class'"
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
-- is nil -- shared by every optional string-valued <input> attribute
-- (value/placeholder/size/autocomplete/accept) instead of a separate
-- hand-written branch per attribute. Only nil omits it -- an empty
-- string is a real, different value (a color field with nothing typed
-- into it yet still needs value="", not the attribute vanishing
-- entirely) and renders as an empty attribute, not nothing.
function attr_fragment(name, value)
    if value == nil then
        return ""
    end
    return " " .. name .. "=\"" .. html_lib.html_escape(tostring(value)) .. "\""
end

-- The <label>+<input>/<textarea> pair for one field, everything except
-- the hidden type and the optional wrapper_class handled by
-- render_page_field itself below. label_line is "" (not a blank line)
-- when field.label is nil -- an inline, no-label field (an admin
-- table's compact per-row inputs, shown via placeholder instead) never
-- had a spare blank line where its label would have been, and neither
-- should this. Checkbox is the one type whose label comes AFTER its
-- input rather than before (matching a native checkbox's usual reading
-- order: the box, then what it means).
function render_page_field_inner(field)
    -- id defaults to field.name, but only when there's a real label to
    -- target it -- an unmatched id is dead weight, not a neutral
    -- default. field.id overrides that default outright, for the one
    -- other real reason a field needs a stable id with no label at
    -- all: client-side JS addressing it directly (the SQL console's
    -- own query box is found by a fixed id, not by name, to sync it
    -- from elsewhere in the page).
    id_attr = ""
    label_line = ""
    if field.id != nil then
        id_attr = attr_fragment("id", field.id)
    elseif field.label != nil then
        id_attr = attr_fragment("id", field.name)
    end
    if field.label != nil then
        label_line = render_lib.render(
            "        <label for=\"{{ name }}\">{{ label }}</label>\n",
            {name = field.name, label = field.label}
        )
    end

    -- A class on the input/textarea element itself -- distinct from
    -- wrapper_class, which wraps the whole label+input pair in an
    -- outer div. Some CSS targets the field element directly (the SQL
    -- console's own .platform-sql-input styles the <textarea> itself,
    -- no wrapper involved) rather than a container around it.
    class_attr = attr_fragment("class", field.css_class)

    if field.type == "checkbox" then
        checked_attr = ""
        if field.checked == true then
            checked_attr = " checked"
        end
        input_line = render_lib.render(
            "        <input type=\"checkbox\"{{{ id_attr }}}{{{ class_attr }}} name=\"{{ name }}\"{{{ value_attr }}}{{{ checked_attr }}}>\n",
            {name = field.name, id_attr = id_attr, class_attr = class_attr, value_attr = attr_fragment("value", field.value), checked_attr = checked_attr}
        )
        return input_line .. label_line
    end

    if field.type == "textarea" then
        value = field.value
        if value == nil then
            value = ""
        end
        input_line = render_lib.render(
            "        <textarea{{{ id_attr }}}{{{ class_attr }}} name=\"{{ name }}\"{{{ placeholder_attr }}}>{{ value }}</textarea>\n",
            {name = field.name, id_attr = id_attr, class_attr = class_attr, placeholder_attr = attr_fragment("placeholder", field.placeholder), value = value}
        )
        return label_line .. input_line
    end

    required_attr = ""
    if field.required == true then
        required_attr = " required"
    end

    extra_attrs = class_attr ..
        attr_fragment("value", field.value) ..
        attr_fragment("placeholder", field.placeholder) ..
        attr_fragment("size", field.size) ..
        attr_fragment("autocomplete", field.autocomplete) ..
        attr_fragment("accept", field.accept)

    input_line = render_lib.render(
        "        <input type=\"{{{ type }}}\"{{{ id_attr }}} name=\"{{ name }}\"{{{ extra_attrs }}}{{{ required_attr }}}>\n",
        {name = field.name, type = field.type, id_attr = id_attr, extra_attrs = extra_attrs, required_attr = required_attr}
    )
    return label_line .. input_line
end

function render_page_field(field)
    if field.type == "hidden" then
        return render_lib.render(
            "        <input type=\"hidden\" name=\"{{ name }}\" value=\"{{ value }}\">\n",
            {name = field.name, value = field.value}
        )
    end

    inner = render_page_field_inner(field)
    if field.wrapper_class == nil then
        return inner
    end
    return render_lib.render(
        "    <div class=\"{{{ wrapper_class }}}\">\n{{{ inner }}}    </div>\n",
        {wrapper_class = field.wrapper_class, inner = inner}
    )
end

-- One group of fields under its own heading, inside a form -- HTML
-- forms can't nest, so this is the shape a real page (settings'
-- Site/Branding/Colors/Chat assistant) uses instead: one real <form>,
-- several visually distinct field groups inside it.
function render_page_group(group)
    fields_html = {}
    for _, field in ipairs(group.fields) do
        table.insert(fields_html, render_page_field(field))
    end
    fields_joined = table.concat(fields_html)
    -- An optional extra wrapper around the WHOLE field list (not each
    -- field individually, that's a field's own wrapper_class) -- e.g.
    -- settings' Colors group needs one shared grid container around
    -- all of its color fields together, on top of each color field's
    -- own individual wrapper_class.
    if group.fields_wrapper_class != nil then
        fields_joined = render_lib.render(
            "    <div class=\"{{{ wrapper_class }}}\">\n{{{ fields }}}    </div>\n",
            {wrapper_class = group.fields_wrapper_class, fields = fields_joined}
        )
    end
    intro_inner = ""
    if group.intro != nil then
        intro_inner = render_lib.render(
            "<p style=\"margin-top:0;color:var(--platform-muted,#64748b);font-size:0.9rem;\">{{ intro }}</p>",
            {intro = group.intro}
        )
    end
    return render_lib.render("""
    <div class="{{{ css_class }}}">
        <h3>{{ heading }}</h3>
        {{{ intro_inner }}}
{{{ fields_html }}}    </div>
""", {
        css_class = group.css_class,
        heading = group.heading,
        intro_inner = intro_inner,
        fields_html = fields_joined,
    })
end

function render_page_form(section)
    fields_html = {}
    for _, field in ipairs(section.fields) do
        table.insert(fields_html, render_page_field(field))
    end

    groups_html = ""
    if section.groups != nil then
        group_parts = {}
        for _, group in ipairs(section.groups) do
            table.insert(group_parts, render_page_group(group))
        end
        groups_html = table.concat(group_parts)
    end

    heading_inner = ""
    if section.heading != nil then
        heading_inner = render_lib.render("<h2>{{ heading }}</h2>", {heading = section.heading})
    end

    message_inner = ""
    if section.message != nil and section.message != "" then
        message_inner = render_page_message("platform-error-banner", section.message)
    end

    css_class_attr = attr_fragment("class", section.css_class)

    enctype_attr = attr_fragment("enctype", section.enctype)

    submit_class = "btn-primary"
    if section.submit_class != nil then
        submit_class = section.submit_class
    end

    return render_lib.render("""
    <form{{{ css_class_attr }}} method="{{{ method }}}" action="{{{ action }}}"{{{ enctype_attr }}}>
        {{{ heading_inner }}}
        {{{ message_inner }}}
{{{ fields_html }}}{{{ groups_html }}}        <button type="submit" class="btn {{{ submit_class }}}">{{ submit_label }}</button>
    </form>
""", {
        css_class_attr = css_class_attr,
        method = section.method,
        action = section.action,
        enctype_attr = enctype_attr,
        heading_inner = heading_inner,
        message_inner = message_inner,
        fields_html = table.concat(fields_html),
        groups_html = groups_html,
        submit_class = submit_class,
        submit_label = section.submit_label,
    })
end

-- A table whose cells can hold plain text, a nested `form` (an admin
-- table's per-row action forms), or an `html_fragment` item --
-- {type="html_fragment", html = "..."}, a pre-rendered, already-safe
-- HTML fragment the caller built itself (html.html_escape/render.lib
-- directly), inserted as-is, never re-escaped. For the one real case
-- that needs it so far: the SQL console's reference-column cells are
-- real <a href="detail?...">popover-linked anchors
-- (render_reference_value), not plain text -- a plain string item
-- would have HTML-escaped the whole anchor tag into visible markup
-- instead of a real link. `form`/`html_fragment` dispatch
-- directly rather than through the generic render_page_section: that
-- function is defined further down this file and itself dispatches to
-- render_page_table for `table` sections, so calling it from here
-- would be real mutual recursion between two separately-named
-- functions -- unlike validate_section's own self-recursion (safe: a
-- function can always call itself by name, since the assignment
-- finishes before the body ever runs), two DIFFERENT functions each
-- calling the other hits the same forward-reference trap as
-- doc/templating.md's ordering gotcha, because whichever is defined
-- first still sees the other as an unset global at the time its own
-- body is compiled. Extend this (both here and validate_section's own
-- matching check) if a third nested kind is ever genuinely needed in a
-- cell -- not before.
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
                    if item.type == "html_fragment" then
                        table.insert(item_parts, item.html)
                    else
                        table.insert(item_parts, render_page_form(item))
                    end
                else
                    table.insert(item_parts, render_lib.render("{{ item }}", {item = item}))
                end
            end
            cells = cells .. "<td>" .. table.concat(item_parts) .. "</td>"
        end
        body_rows = body_rows .. "<tr>" .. cells .. "</tr>"
    end
    css_class_attr = attr_fragment("class", section.css_class)
    id_attr = attr_fragment("id", section.id)
    table_html = render_lib.render(
        "<table{{{ id_attr }}}{{{ css_class_attr }}}><thead><tr>{{{ header_cells }}}</tr></thead><tbody>{{{ body_rows }}}</tbody></table>",
        {id_attr = id_attr, css_class_attr = css_class_attr, header_cells = header_cells, body_rows = body_rows}
    )
    -- wrapper_class is a separate outer <div> around the whole table --
    -- distinct from css_class, which is a class on the <table> element
    -- itself (admin-users'/admin-api-keys' own tables need only that).
    -- The SQL console's results table needs both: a wrapping
    -- .platform-table-wrapper div (a shape shared/copy-pasted across
    -- nine other render_* functions, per platform_table_wrapper_css's
    -- own comment -- a genuinely recurring shape, not a one-off) around
    -- a <table> that itself carries its own id, not a class.
    if section.wrapper_class == nil then
        return "    " .. table_html .. "\n"
    end
    return render_lib.render(
        "    <div class=\"{{{ wrapper_class }}}\">{{{ table_html }}}</div>\n",
        {wrapper_class = section.wrapper_class, table_html = table_html}
    )
end

-- A group of plain, non-submit buttons -- JS-driven (register's own
-- Add Row/Submit Batch, edit's own Save changes), never inside a
-- <form> (that's what the `form` type's own submit button is for, a
-- different case entirely). `style` is a rare, deliberate exception to
-- page.lua's usual class-only styling convention: edit's own action
-- group needs a bit of extra top margin its neighbor (a fields list
-- with no bottom margin of its own) doesn't provide, while register's
-- neighbor (a table wrapper that already carries margin-bottom)
-- doesn't -- a real, per-instance layout difference between the two
-- real callers, not something worth inventing a new CSS class for one
-- inline value.
function render_page_actions(section)
    buttons_html = {}
    for _, button in ipairs(section.buttons) do
        table.insert(buttons_html, render_lib.render(
            "        <button type=\"button\"{{{ class_attr }}}{{{ id_attr }}}>{{ label }}</button>\n",
            {class_attr = attr_fragment("class", button.css_class), id_attr = attr_fragment("id", button.id), label = button.label}
        ))
    end
    return render_lib.render(
        "    <div class=\"platform-actions\"{{{ style_attr }}}>\n{{{ buttons }}}    </div>\n",
        {style_attr = attr_fragment("style", section.style), buttons = table.concat(buttons_html)}
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
    elseif section.type == "actions" then
        return render_page_actions(section)
    elseif section.type == "status_placeholder" then
        return render_lib.render(
            "    <div{{{ id_attr }}}{{{ class_attr }}}></div>\n",
            {id_attr = attr_fragment("id", section.id), class_attr = attr_fragment("class", section.css_class)}
        )
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
