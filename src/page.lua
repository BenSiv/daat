-- Trusted first-party page-section validator and HTML renderer.
-- Distinct from ui.render_canvas and template.lua; see doc/decisions/006-trusted-page-sections-vs-extension-canvas.md.

const html_lib = require("html")
const render_lib = require("render")

const page = {}

const FORM_FIELD_TYPES = {text = true, password = true, hidden = true, checkbox = true, file = true, textarea = true}

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
        if section.message_css_class != nil and (type(section.message_css_class) != "string" or section.message_css_class == "") then
            return label .. " (form): 'message_css_class' must be a non-empty string if given"
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
                        -- Keep in sync with render_page_table's supported nested cell types.
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
            if button.data != nil and type(button.data) != "table" then
                return button_label .. ": 'data' must be a table if given"
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

-- Validates trusted section literals; callers error() on non-nil return (see doc/templating.md).
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

function render_page_message(css_class, text)
    return render_lib.render(
        "<div class=\"{{{ css_class }}}\">{{ text }}</div>",
        {css_class = css_class, text = text}
    )
end

function render_page_secret_reveal(css_class, instruction, value)
    return render_lib.render(
        "<div class=\"{{{ css_class }}}\"><strong>{{ instruction }}</strong> <code>{{ value }}</code></div>",
        {css_class = css_class, instruction = instruction, value = value}
    )
end

-- Omit only when value is nil; "" renders an explicit empty attribute.
function attr_fragment(name, value)
    if value == nil then
        return ""
    end
    return " " .. name .. "=\"" .. html_lib.html_escape(tostring(value)) .. "\""
end

function render_page_field_inner(field)
    -- Emit id=field.name only when paired with a <label> unless field.id overrides it.
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
            "        <input type=\"hidden\" name=\"{{ name }}\"{{{ id_attr }}} value=\"{{ value }}\">\n",
            {name = field.name, id_attr = attr_fragment("id", field.id), value = field.value}
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

function render_page_group(group)
    fields_html = {}
    for _, field in ipairs(group.fields) do
        table.insert(fields_html, render_page_field(field))
    end
    fields_joined = table.concat(fields_html)
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

function default_message_css_class(css_class)
    if css_class == nil then
        return "platform-error-banner"
    end
    return css_class
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
        message_inner = render_page_message(default_message_css_class(section.message_css_class), section.message)
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

-- html_fragment inserts pre-escaped HTML verbatim; calls render_page_form directly to avoid mutual-recursion forward-ref trap (see doc/templating.md).
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
    if section.wrapper_class == nil then
        return "    " .. table_html .. "\n"
    end
    return render_lib.render(
        "    <div class=\"{{{ wrapper_class }}}\">{{{ table_html }}}</div>\n",
        {wrapper_class = section.wrapper_class, table_html = table_html}
    )
end

-- Escapes button.data into data-* attributes so extension trigger names never enter inline JS.
function render_page_actions(section)
    buttons_html = {}
    for _, button in ipairs(section.buttons) do
        data_attrs = ""
        if button.data != nil then
            for key, value in pairs(button.data) do
                data_attrs = data_attrs .. attr_fragment("data-" .. key, value)
            end
        end
        table.insert(buttons_html, render_lib.render(
            "        <button type=\"button\"{{{ class_attr }}}{{{ id_attr }}}{{{ data_attrs }}}>{{ label }}</button>\n",
            {class_attr = attr_fragment("class", button.css_class), id_attr = attr_fragment("id", button.id), data_attrs = data_attrs, label = button.label}
        ))
    end
    return render_lib.render(
        "    <div class=\"platform-actions\"{{{ style_attr }}}>\n{{{ buttons }}}    </div>\n",
        {style_attr = attr_fragment("style", section.style), buttons = table.concat(buttons_html)}
    )
end

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

function page.render(sections)
    parts = {}
    for _, section in ipairs(sections) do
        table.insert(parts, render_page_section(section))
    end
    return table.concat(parts)
end

return page
