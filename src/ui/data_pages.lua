-- Structured data UI pages and helpers: entity display labels, word-level
-- ledger diffs, /browse, /detail, /view, inline {{view:...}} expansion,
-- SVG relation diagram, /data index, and /sql console.

const asset = require("asset")
const db = require("database")
const page_lib = require("page")
const render_lib = require("render")
const schema_lib = require("schema")
const ui_assets = require("ui.assets")
const ui_common = require("ui.common")
const view_lib = require("view")

const html_escape = ui_common.html_escape

const ui_data = {}

const DIFF_MAX_WORDS = 400
const DIAGRAM_BOX_WIDTH = 200
const DIAGRAM_HEADER_HEIGHT = 26
const DIAGRAM_ROW_HEIGHT = 18
const DIAGRAM_COLUMN_GAP = 70
const DIAGRAM_ROW_GAP = 34
const DIAGRAM_PADDING = 40

function ui_data.display_value(value)
    if type(value) == "table" then
        if #value == 0 then
            return "&mdash;"
        end
        parts = {}
        for _, item in ipairs(value) do
            if type(item) == "table" and item.type != nil then
                table.insert(parts, html_escape(tostring(item.type) .. ":" .. tostring(item.id)))
            else
                table.insert(parts, html_escape(tostring(item)))
            end
        end
        return table.concat(parts, ", ")
    end
    if value == nil or tostring(value) == "" then
        return "&mdash;"
    end
    return html_escape(value)
end

function split_words(text)
    words = {}
    for w in string.gmatch(tostring(text), "%S+") do
        table.insert(words, w)
    end
    return words
end

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

function ui_data.word_diff_runs(old_text, new_text)
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

function ui_data.word_diff_html(old_value, new_value)
    old_text = tostring(old_value)
    new_text = tostring(new_value)
    if old_text == new_text then
        return html_escape(old_text)
    end
    a = split_words(old_text)
    b = split_words(new_text)
    if #a > DIFF_MAX_WORDS or #b > DIFF_MAX_WORDS then
        return nil
    end
    parts = {}
    for _, run in ipairs(ui_data.word_diff_runs(old_text, new_text)) do
        escaped = html_escape(table.concat(run.words, " "))
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

function format_display_label(entity_type, field, raw_value)
    if field.type == "number" then
        return entity_type .. " " .. tostring(raw_value)
    end
    return tostring(raw_value)
end

_display_label_cache = nil

function compute_entity_display_label(db_path, entity_type, entity_id)
    quoted_type = db.quote_ident(entity_type)
    rows = db.query(db_path, string.format(
        "SELECT name FROM %s WHERE id = %s;", quoted_type, db.quote(entity_id)
    ))
    if rows != nil and rows[1] != nil and rows[1].name != nil and tostring(rows[1].name) != "" then
        return tostring(rows[1].name)
    end

    fields = schema_lib.fields(db_path, entity_type)
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
        db.quote_ident(display_field.name), quoted_type, db.quote(entity_id)
    ))
    if rows == nil or rows[1] == nil or rows[1].label == nil or tostring(rows[1].label) == "" then
        return nil
    end
    return format_display_label(entity_type, display_field, rows[1].label)
end

function ui_data.entity_display_label(db_path, entity_type, entity_id)
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

function ui_data.own_row_label(db_path, entity_type, row)
    if row.name != nil and tostring(row.name) != "" then
        return tostring(row.name)
    end

    fields = schema_lib.fields(db_path, entity_type)
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
    escaped_type = html_escape(ref_entity_type)
    escaped_id = html_escape(tostring(value))
    link_text = "#" .. escaped_id
    label = ui_data.entity_display_label(db_path, ref_entity_type, value)
    if label != nil then
        link_text = html_escape(label)
    end
    preview_src = "api/v1/entities/" .. escaped_type .. "/" .. escaped_id .. "/preview"
    return "<a href=\"detail?type=" .. escaped_type .. "&entity_id=" .. escaped_id ..
        "\" class=\"platform-entity-ref platform-popover-trigger\" data-platform-popover-src=\"" .. preview_src ..
        "\" tabindex=\"0\">" .. link_text .. "<span class=\"platform-popover\"></span></a>"
end

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

function ui_data.display_field_value(db_path, field, value)
    if field.type == "reference" and field.ref_entity_type != nil then
        return render_reference_value(db_path, field.ref_entity_type, value)
    end
    if field.type == "multi_reference" then
        ref_type = field.ref_entity_type
        if ref_type == nil then
            return ui_data.display_value(value)
        end
        return render_multi_reference_value(db_path, ref_type, value)
    end
    if field.type == "polymorphic_reference" or field.type == "multi_polymorphic_reference" then
        return render_polymorphic_reference_value(db_path, value)
    end
    return ui_data.display_value(value)
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
        if schema_lib.valid_name_syntax(ref_type) and schema_lib.is_registered(db_path, ref_type) and db.table_exists(db_path, ref_type) then
            display_field = nil
            fields = schema_lib.fields(db_path, ref_type)
            if fields != nil then
                for _, f in ipairs(fields) do
                    if tonumber(f.display) == 1 and schema_lib.is_multi_field_type(f.type) == false and schema_lib.is_polymorphic_field_type(f.type) == false then
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
                    select_cols, db.quote_ident(ref_type), table.concat(quoted_ids, ", ")
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

function ui_data.render_browse(db_path, entity_type, layout, rows, page, page_size, total, nonce, filter_field, filter_value)
    if nonce == nil then
        nonce = ""
    end
    escaped_type = html_escape(entity_type)

    filter_query_suffix = ""
    if filter_field != nil then
        filter_query_suffix = "&filter_field=" .. html_escape(filter_field) .. "&filter_value=" .. html_escape(tostring(filter_value))
    end

    header_parts = {"<th>ID</th>"}
    for _, field in ipairs(layout.fields) do
        table.insert(header_parts, "<th>" .. html_escape(field.label) .. "</th>")
    end
    header_cells = table.concat(header_parts)

    prev_cache = _display_label_cache
    _display_label_cache = prefetch_browse_display_labels(db_path, layout, rows)
    ok_rows, body_rows_or_err = pcall(function()
        row_parts = {}
        for _, row in ipairs(rows) do
            own_label = ui_data.own_row_label(db_path, entity_type, row)
            id_link_text = "#" .. tostring(row.id)
            if own_label != nil then
                id_link_text = html_escape(own_label)
            end
            cell_parts = {
                "<td><a href=\"detail?type=" .. escaped_type .. "&entity_id=" .. tostring(row.id) ..
                "\">" .. id_link_text .. "</a></td>"
            }
            for _, field in ipairs(layout.fields) do
                table.insert(cell_parts, "<td>" .. ui_data.display_field_value(db_path, field, row[field.name]) .. "</td>")
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

    browse_header = ui_common.render_page_header("Browse " .. escaped_type, "<p>" .. tostring(total) .. " registered</p>",
        "<a class=\"btn btn-primary\" href=\"register?type=" .. escaped_type .. "\">+ New " .. escaped_type .. "</a>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.page_header_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        asset.read("ui/browse.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="Browse %s">
    %s
    %s
    <div class="platform-container">
        %s
        %s
        %s
    </div>
</div>
%s
""", escaped_type, style_block, ui_common.popover_css(), browse_header, table_or_empty, pager, ui_common.popover_js(nonce))
end

function ui_data.related_records_html(db_path, related, entity_id)
    if related == nil or #related == 0 then
        return ""
    end
    groups_html = ""
    for _, group in ipairs(related) do
        escaped_from = html_escape(group.from_type)
        escaped_field = html_escape(group.field_name)
        rows_html = ""
        for _, r in ipairs(group.rows) do
            own_label = ui_data.own_row_label(db_path, group.from_type, r)
            link_text = "#" .. tostring(r.id)
            if own_label != nil then
                link_text = html_escape(own_label) .. " (#" .. tostring(r.id) .. ")"
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

function label_print_button_html(entity_type, entity_id)
    return string.format("""
<div class="platform-print-label">
    <select id="platform-label-printer"></select>
    <button type="button" id="platform-print-label-btn" class="btn btn-secondary" data-entity-type="%s" data-entity-id="%s">Print Label</button>
    <span id="platform-print-label-status"></span>
</div>
""", html_escape(entity_type), html_escape(tostring(entity_id)))
end

function label_print_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/label_print.js"))
end

function ui_data.render_detail(db_path, entity_type, layout, row, history, nonce, has_label_template, related)
    if nonce == nil then
        nonce = ""
    end
    escaped_type = html_escape(entity_type)
    id_str = tostring(row.id)
    own_label = ui_data.own_row_label(db_path, entity_type, row)
    title_id_part = "#" .. id_str
    if own_label != nil then
        title_id_part = html_escape(own_label) .. " (#" .. id_str .. ")"
    end

    view_document_link = ""
    if entity_type == "document" then
        view_document_link = "<a class=\"btn btn-secondary\" href=\"document?entity_id=" .. id_str .. "\">View document</a>"
    end
    edit_link = "<a class=\"btn btn-secondary\" href=\"entity-edit?type=" .. escaped_type .. "&entity_id=" .. id_str .. "\">Edit</a>"

    print_label_html = ""
    print_label_js_block = ""
    if has_label_template == true then
        print_label_html = label_print_button_html(entity_type, id_str)
        print_label_js_block = string.format("<script src=\"vendor?name=BrowserPrint-3.0.216.min.js\" nonce=\"%s\"></script>", html_escape(nonce)) ..
            label_print_js(nonce)
    end

    fields_html = ""
    for _, field in ipairs(layout.fields) do
        fields_html = fields_html .. "<div class=\"detail-row\"><span class=\"detail-label\">" ..
            html_escape(field.label) .. "</span><span class=\"detail-value\">" ..
            ui_data.display_field_value(db_path, field, row[field.name]) .. "</span></div>"
    end

    related_html = ui_data.related_records_html(db_path, related, row.id)

    history_rows = ""
    for _, event in ipairs(history) do
        changes = ""
        if event.reason != nil and event.reason != "" then
            changes = changes .. "<div class=\"change-item change-reason\"><em>Reason: " ..
                html_escape(event.reason) .. "</em></div>"
        end
        for field_name, change in pairs(event.field_changes) do
            diff_body = nil
            if type(change.old) != "table" and type(change.new) != "table" then
                diff_body = ui_data.word_diff_html(change.old, change.new)
            end
            if diff_body != nil then
                changes = changes .. "<div class=\"change-item\"><strong>" .. html_escape(field_name) ..
                    "</strong>: <span class=\"diff-view\">" .. diff_body .. "</span></div>"
            else
                changes = changes .. "<div class=\"change-item\"><strong>" .. html_escape(field_name) ..
                    "</strong>: " .. ui_data.display_value(change.old) .. " &rarr; " .. ui_data.display_value(change.new) .. "</div>"
            end
        end
        history_rows = history_rows .. "<tr><td>#" .. tostring(event.event_id) .. "</td><td>" ..
            html_escape(event.event_type) .. "</td><td>" .. ui_data.display_value(event.author) .. "</td><td>" ..
            html_escape(event.created_at) .. "</td><td>" .. changes .. "</td></tr>"
    end

    detail_header = ui_common.render_page_header(escaped_type .. " " .. title_id_part,
        "<a class=\"btn btn-secondary\" href=\"browse?type=" .. escaped_type .. "\">&larr; Back to browse</a>",
        "<div class=\"platform-header-actions\">" .. view_document_link .. edit_link .. print_label_html .. "</div>")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        ui_common.page_header_css(),
        ui_common.related_css(),
        asset.read("ui/detail.css"),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s %s">
    %s
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
""", escaped_type, title_id_part, style_block, ui_common.popover_css(), detail_header, fields_html, related_html, history_rows, ui_common.popover_js(nonce), print_label_js_block)
end

function ui_data.render_view_table(view_def, rows)
    header_parts = {}
    for _, col in ipairs(view_def.columns) do
        label = col.label
        if label == nil then
            label = col.name
        end
        table.insert(header_parts, "<th>" .. html_escape(label) .. "</th>")
    end
    header_cells = table.concat(header_parts)

    if #rows == 0 then
        return "<p class=\"platform-empty\">No rows.</p>"
    end

    row_parts = {}
    for _, row in ipairs(rows) do
        cell_parts = {}
        for _, col in ipairs(view_def.columns) do
            table.insert(cell_parts, "<td>" .. ui_data.display_value(row[col.name]) .. "</td>")
        end
        table.insert(row_parts, "<tr>" .. table.concat(cell_parts) .. "</tr>")
    end
    body_rows = table.concat(row_parts)

    return "<div class=\"platform-table-wrapper\"><table class=\"platform-view-table\"><thead><tr>" ..
        header_cells .. "</tr></thead><tbody>" .. body_rows .. "</tbody></table></div>"
end

function ui_data.render_view(view_def, rows, param_value)
    title = view_def.title
    if title == nil then
        title = view_def.name
    end
    escaped_title = html_escape(title)

    subtitle = tostring(#rows) .. " rows"
    if view_def.param != nil then
        subtitle = subtitle .. " -- filtered by " .. html_escape(view_def.param.name) ..
            " = " .. html_escape(tostring(param_value))
    end

    table_or_empty = ui_data.render_view_table(view_def, rows)

    register_link = ""
    if view_def.entity_type != nil then
        escaped_entity_type = html_escape(view_def.entity_type)
        register_link = string.format(
            "<a class=\"btn btn-primary\" href=\"register?type=%s\">+ New %s</a>",
            escaped_entity_type, escaped_entity_type
        )
    end

    view_header = ui_common.render_page_header(escaped_title, "<p>" .. subtitle .. "</p>", register_link)
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        ui_common.page_header_css(),
        ui_common.view_table_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="%s">
    %s
    <div class="platform-container">
        %s
        %s
    </div>
</div>
""", escaped_title, style_block, view_header, table_or_empty)
end

function ui_data.expand_inline_views(db_path, content)
    return (string.gsub(content, "{{view:([%w_]+):(%d+)}}", function(view_name, param_value)
        view_def, err = view_lib.load(db_path, view_name)
        if view_def == nil then
            return "{{view:" .. view_name .. ":" .. param_value .. "}}"
        end
        if view_lib.is_approved(db_path, view_def) == false then
            return ""
        end
        rows, run_err = view_lib.run(db_path, view_def, tonumber(param_value))
        if rows == nil then
            return "<p class=\"platform-empty\">Error running view '" .. html_escape(view_name) .. "'.</p>"
        end
        return ui_data.render_view_table(view_def, rows)
    end))
end

function diagram_box_rows(db_path, entity_type)
    rows = {{name = "id", type_label = "integer", is_pk = true, required = true}}
    for _, field in ipairs(schema_lib.fields(db_path, entity_type)) do
        table.insert(rows, {
            name = field.name, type_label = field.type, is_pk = false,
            required = (tonumber(field.required) == 1)
        })
    end
    return rows
end

function diagram_row_center_y(box, row_index)
    return box.y + DIAGRAM_HEADER_HEIGHT + (row_index - 1) * DIAGRAM_ROW_HEIGHT + (DIAGRAM_ROW_HEIGHT / 2)
end

function ui_data.render_relation_diagram(db_path, entity_types, edges)
    n = #entity_types
    if n == 0 then
        return "<p class=\"platform-empty\">No entity types registered yet.</p>"
    end

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
                from_x = nil
                to_x = nil
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
                    html_escape(edge.from_type), html_escape(edge.to_type),
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
        escaped_name = html_escape(row.name)
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
                name_class, box.x + 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html_escape(box_row.name),
                box.x + box.width - 8, row_y + DIAGRAM_ROW_HEIGHT - 5, html_escape(box_row.type_label)
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

function ui_data.relation_diagram_css()
    return asset.read("ui/diagram.css")
end

function ui_data.diagram_js(nonce)
    return ui_assets.inline_script(nonce, asset.read("ui/diagram.js"))
end

function ui_data.render_index(db_path, entity_types, edges, nonce)
    items_parts = {}
    for _, row in ipairs(entity_types) do
        escaped_name = html_escape(row.name)
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

    diagram_html = ui_data.render_relation_diagram(db_path, entity_types, edges)

    index_header = ui_common.render_page_header("Entity types", "<p>" .. tostring(#entity_types) .. " registered</p>", """
            <div class="platform-view-toggle" id="platform-view-toggle">
                <label class="platform-hide-empty-toggle"><input type="checkbox" id="platform-hide-empty"> Hide empty types</label>
                <button type="button" data-view="list" class="platform-view-active">List</button>
                <button type="button" data-view="diagram">Diagram</button>
            </div>
""")
    style_block = ui_common.inline_styles({
        ui_common.container_css(),
        ui_common.page_header_css(),
        asset.read("ui/data_index.css"),
        ui_data.relation_diagram_css(),
        ui_common.table_wrapper_css(),
    })
    return string.format("""
<div class="fossil-doc" data-title="Overview">
    %s
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
%s</div>
%s
""", style_block, ui_common.popover_css(), index_header, list_or_empty, diagram_html,
     ui_assets.inline_script(nonce, asset.read("ui/data_index.js")),
     ui_data.diagram_js(nonce))
end

function ui_data.render_sql(db_path, sql_text, column_names, rows, err, ref_columns, nonce, embed, theme, truncated)
    if ref_columns == nil then
        ref_columns = {}
    end
    if nonce == nil then
        nonce = ""
    end
    embed_css = ""
    if embed == true then
        embed_css = ".platform-container { padding: 0; margin: 0; max-width: none; box-shadow: none; border: none; border-radius: 0; }"
        if theme != nil then
            embed_css = ui_common.theme_root_css(theme) .. " " .. embed_css
        end
    end
    sql_text_or_empty = sql_text
    if sql_text_or_empty == nil then
        sql_text_or_empty = ""
    end

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

    extra_html = ""
    if err != nil then
        table.insert(sections, {type = "message", css_class = "platform-sql-error", text = "Error: " .. err})
    elseif rows != nil then
        page_rows = {}
        for _, row in ipairs(rows) do
            cells = {}
            for _, name in ipairs(column_names) do
                ref_type = ref_columns[name]
                cell_html = ui_data.display_value(row[name])
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
        extra_html = render_lib.render("<p class=\"platform-empty\">Enter a SQL query above, then click Run.</p>", {})
    end

    validate_err = page_lib.validate(sections)
    if validate_err != nil then
        error(validate_err)
    end
    result_html = page_lib.render(sections) .. extra_html

    sql_header = ui_common.render_page_header("Query", "<p>Read-only (SELECT only) queries against the entity store. Setup/Admin only.</p>", nil)
    style_parts = {
        ui_common.container_css(),
        ui_common.page_header_css(),
        ui_common.button_css(),
        ui_common.table_wrapper_css(),
        asset.read("ui/sql.css"),
    }
    if embed_css != "" then
        table.insert(style_parts, embed_css)
    end
    style_block = ui_common.inline_styles(style_parts)
    return string.format("""
<div class="fossil-doc" data-title="Query">
    %s
    %s
    <div class="platform-container">
        %s
%s    </div>
</div>
%s
""", style_block, ui_common.popover_css(), sql_header, result_html, ui_common.popover_js(nonce))
end

return ui_data
