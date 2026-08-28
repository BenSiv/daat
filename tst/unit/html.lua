-- tst/unit/html.lua
-- Unit tests for src/html.lua's "daat canvas" (validate_canvas/
-- render_canvas): the typed-element-table -> trusted-HTML-renderer
-- pattern a UI plugin's page is built from, modeled on template.lua's
-- own section.type dispatch. No prior test coverage existed for
-- html.lua at all before this file.

html = require("html")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_validate_rejects_unknown_element_type()
    print("Testing validate_canvas rejects an unrecognized element type")
    err = html.validate_canvas({{type = "not_a_real_type"}})
    check(err != nil, "an invalid element type should be rejected")
end

function test_validate_rejects_non_list()
    print("Testing validate_canvas rejects a non-table argument")
    err = html.validate_canvas("not a table")
    check(err != nil, "a non-table canvas should be rejected")
end

function test_validate_heading_and_text_require_text()
    print("Testing validate_canvas rejects heading/text elements missing 'text'")
    check(html.validate_canvas({{type = "heading"}}) != nil, "heading with no text should be rejected")
    check(html.validate_canvas({{type = "heading", text = ""}}) != nil, "heading with empty text should be rejected")
    check(html.validate_canvas({{type = "text"}}) != nil, "text with no text should be rejected")
    check(html.validate_canvas({{type = "heading", text = "Objective"}}) == nil, "well-formed heading should be accepted")
    check(html.validate_canvas({{type = "text", text = "Describe the goal."}}) == nil, "well-formed text should be accepted")
end

function test_validate_table_requires_columns_and_rows()
    print("Testing validate_canvas rejects a table element missing columns/rows")
    check(html.validate_canvas({{type = "table", rows = {}}}) != nil, "table with no columns should be rejected")
    check(html.validate_canvas({{type = "table", columns = {}, rows = {}}}) != nil, "table with empty columns should be rejected")
    check(html.validate_canvas({{type = "table", columns = {"Name"}}}) != nil, "table with no rows list should be rejected")
    check(html.validate_canvas({{type = "table", columns = {"Name"}, rows = {}}}) == nil, "well-formed (empty) table should be accepted")
end

function test_validate_button_requires_label_and_action()
    print("Testing validate_canvas rejects a button element missing label/action")
    check(html.validate_canvas({{type = "button", action = "do_thing"}}) != nil, "button with no label should be rejected")
    check(html.validate_canvas({{type = "button", label = "Run"}}) != nil, "button with no action should be rejected")
    check(html.validate_canvas({{type = "button", label = "Run", action = "do_thing"}}) == nil, "well-formed button should be accepted")
end

function test_render_heading_and_text_escape_html()
    print("Testing render_canvas escapes heading/text content")
    rendered = html.render_canvas({
        {type = "heading", text = "<script>alert(1)</script>"},
        {type = "text", text = "plain text"},
    })
    check(string.find(rendered, "<script>alert(1)</script>", 1, true) == nil,
        "raw <script> from an element's text must never reach the output unescaped: " .. rendered)
    check(string.find(rendered, "&lt;script&gt;", 1, true) != nil,
        "the escaped form should be present instead: " .. rendered)
    check(string.find(rendered, "plain text", 1, true) != nil, "plain text element should render its own text")
end

function test_render_table_emits_columns_and_rows()
    print("Testing render_canvas renders a table element's columns and rows")
    rendered = html.render_canvas({
        {type = "table", columns = {"Name", "Count"}, rows = {{"widgets", 3}, {"gadgets", 5}}},
    })
    check(string.find(rendered, "<table", 1, true) != nil, "a table element should render a real <table>")
    check(string.find(rendered, "Name", 1, true) != nil, "column headers should appear")
    check(string.find(rendered, "widgets", 1, true) != nil, "row values should appear")
    check(string.find(rendered, "gadgets", 1, true) != nil, "every row should appear, not just the first")
end

function test_render_button_carries_action_and_args_as_data_attributes()
    print("Testing render_canvas renders a button's action/args as data attributes, not inline JS")
    rendered = html.render_canvas({
        {type = "button", label = "Run", action = "do_thing", args = {sample_id = 12}},
    })
    check(string.find(rendered, "data-action=\"do_thing\"", 1, true) != nil,
        "the action name should be carried as a data attribute: " .. rendered)
    check(string.find(rendered, "sample_id", 1, true) != nil, "args should be JSON-encoded into the data attribute: " .. rendered)
    check(string.find(rendered, "<script", 1, true) == nil, "a button must never emit inline <script> of its own: " .. rendered)
end

function test_render_mixed_elements_in_order()
    print("Testing render_canvas renders a mix of element types in order")
    rendered = html.render_canvas({
        {type = "heading", text = "Samples"},
        {type = "table", columns = {"Name"}, rows = {{"widgets"}}},
        {type = "button", label = "Refresh", action = "refresh"},
    })
    heading_pos = string.find(rendered, "Samples", 1, true)
    table_pos = string.find(rendered, "widgets", 1, true)
    button_pos = string.find(rendered, "Refresh", 1, true)
    check(heading_pos != nil and table_pos != nil and button_pos != nil, "all three elements should render: " .. rendered)
    check(heading_pos < table_pos and table_pos < button_pos, "elements should render in the order given: " .. rendered)
end

-- Run them
test_validate_rejects_unknown_element_type()
test_validate_rejects_non_list()
test_validate_heading_and_text_require_text()
test_validate_table_requires_columns_and_rows()
test_validate_button_requires_label_and_action()
test_render_heading_and_text_escape_html()
test_render_table_emits_columns_and_rows()
test_render_button_carries_action_and_args_as_data_attributes()
test_render_mixed_elements_in_order()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All html.lua canvas tests passed")
