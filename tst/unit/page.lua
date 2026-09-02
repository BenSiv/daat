-- tst/unit/page.lua
-- Unit tests for src/page.lua: the first-party-only typed-section
-- vocabulary (see doc/templating.md). No prior direct test coverage
-- existed for this module -- the five real pages built on it
-- (html.render_login/_account/_admin_users/_admin_api_keys/_settings)
-- are covered by tst/integration/*.bats, but only through each page's
-- own real happy/error paths, never page.validate's error branches
-- directly. This file exercises page.validate/page.render against the
-- vocabulary itself, independent of any one page.

page = require("page")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function contains(haystack, needle)
    return string.find(haystack, needle, 1, true) != nil
end

function test_validate_accepts_a_realistic_page()
    print("Testing validate accepts a realistic, well-formed page")
    sections = {
        {type = "message", css_class = "platform-error-banner", text = "Invalid login."},
        {
            type = "form", method = "POST", action = "/login", heading = "Log in",
            fields = {
                {type = "text", name = "login", label = "Login", autocomplete = "username", required = true},
                {type = "password", name = "password", label = "Password", required = true},
            },
            submit_label = "Log in",
        },
    }
    err = page.validate(sections)
    check(err == nil, "a realistic page should validate cleanly: " .. tostring(err))
end

function test_validate_rejects_unknown_section_type()
    print("Testing validate rejects an unrecognized section type")
    err = page.validate({{type = "not_a_real_type"}})
    check(err != nil, "an invalid section type should be rejected")
end

function test_validate_rejects_missing_required_section_fields()
    print("Testing validate rejects each section type's own missing required field")
    check(page.validate({{type = "subheading"}}) != nil, "subheading needs text")
    check(page.validate({{type = "message", css_class = "x"}}) != nil, "message needs text")
    check(page.validate({{type = "message", text = "x"}}) != nil, "message needs css_class")
    check(page.validate({{type = "secret_reveal", css_class = "x", instruction = "x"}}) != nil, "secret_reveal needs value")
    check(page.validate({{type = "form", action = "/x", fields = {}, submit_label = "Go"}}) != nil, "form needs method")
    check(page.validate({{type = "form", method = "POST", fields = {}, submit_label = "Go"}}) != nil, "form needs action")
    check(page.validate({{type = "form", method = "POST", action = "/x", submit_label = "Go"}}) != nil, "form needs fields")
    check(page.validate({{type = "form", method = "POST", action = "/x", fields = {}}}) != nil, "form needs submit_label")
    check(page.validate({{type = "table", rows = {}}}) != nil, "table needs a non-empty columns list")
    check(page.validate({{type = "table", columns = {"A"}}}) != nil, "table needs rows")
end

-- Regression lock for the consistency pass: form.heading/message/
-- css_class/submit_class and table.css_class were used at render time
-- but never checked at validate time until this session's fix -- an
-- empty string would have silently rendered a blank <h2></h2> instead
-- of being rejected. See doc/templating.md's "A consistency pass found
-- two real gaps" section.
function test_validate_rejects_empty_string_optional_form_and_table_fields()
    print("Testing validate rejects an empty-string (not nil) optional field on form/table")
    base_form = {method = "POST", action = "/x", fields = {}, submit_label = "Go"}

    with_heading = {type = "form", heading = ""}
    for k, v in pairs(base_form) do with_heading[k] = v end
    check(page.validate({with_heading}) != nil, "empty-string form.heading should be rejected")

    with_message = {type = "form", message = ""}
    for k, v in pairs(base_form) do with_message[k] = v end
    check(page.validate({with_message}) != nil, "empty-string form.message should be rejected")

    with_css_class = {type = "form", css_class = ""}
    for k, v in pairs(base_form) do with_css_class[k] = v end
    check(page.validate({with_css_class}) != nil, "empty-string form.css_class should be rejected")

    with_submit_class = {type = "form", submit_class = ""}
    for k, v in pairs(base_form) do with_submit_class[k] = v end
    check(page.validate({with_submit_class}) != nil, "empty-string form.submit_class should be rejected")

    check(
        page.validate({{type = "table", css_class = "", columns = {"A"}, rows = {}}}) != nil,
        "empty-string table.css_class should be rejected"
    )

    -- nil (simply omitted) must stay valid -- only "" is the mistake.
    check(page.validate({{type = "form", method = "POST", action = "/x", fields = {}, submit_label = "Go"}}) == nil,
        "omitting these optional fields entirely must still validate cleanly")
end

function test_validate_rejects_bad_form_fields()
    print("Testing validate rejects a form field's own mistakes")
    function form_with(fields)
        return {type = "form", method = "POST", action = "/x", fields = fields, submit_label = "Go"}
    end
    check(page.validate({form_with({{type = "not_a_type", name = "x"}})}) != nil, "unknown field type should be rejected")
    check(page.validate({form_with({{type = "text"}})}) != nil, "field missing name should be rejected")
    check(page.validate({form_with({{type = "hidden", name = "csrf_token"}})}) != nil, "hidden field missing value should be rejected")
    check(page.validate({form_with({{type = "text", name = "x", label = ""}})}) != nil, "empty-string label should be rejected")
    check(page.validate({form_with({{type = "text", name = "x"}})}) == nil, "omitted label should be fine (inline, no visible label)")
    check(page.validate({form_with({{type = "text", name = "x", wrapper_class = ""}})}) != nil, "empty-string wrapper_class should be rejected")
end

function test_validate_rejects_bad_groups()
    print("Testing validate rejects a form group's own mistakes")
    function form_with_group(group)
        return {type = "form", method = "POST", action = "/x", fields = {}, submit_label = "Go", groups = {group}}
    end
    check(page.validate({form_with_group({heading = "H", fields = {}})}) != nil, "group missing css_class should be rejected")
    check(page.validate({form_with_group({css_class = "c", fields = {}})}) != nil, "group missing heading should be rejected")
    check(page.validate({form_with_group({css_class = "c", heading = "H", intro = "", fields = {}})}) != nil, "empty-string intro should be rejected")
    check(page.validate({form_with_group({css_class = "c", heading = "H"})}) != nil, "group missing fields should be rejected")
    check(
        page.validate({form_with_group({css_class = "c", heading = "H", fields = {{type = "text"}}})}) != nil,
        "a group field's own mistake (missing name) should still be caught"
    )
    check(
        page.validate({form_with_group({css_class = "c", heading = "H", fields = {{type = "text", name = "x", label = "L"}}})}) == nil,
        "a well-formed group should validate cleanly"
    )
end

function test_validate_table_cells_only_nest_form_or_html_fragment()
    print("Testing validate restricts table cell items to a string, a 'form' section, or an 'html_fragment' item")
    good_table = {type = "table", columns = {"A"}, rows = {{{"plain text"}}}}
    check(page.validate({good_table}) == nil, "a plain string cell item should validate")

    form_item = {type = "form", method = "POST", action = "/x", fields = {}, submit_label = "Go"}
    with_form_cell = {type = "table", columns = {"A"}, rows = {{{form_item}}}}
    check(page.validate({with_form_cell}) == nil, "a nested form cell item should validate")

    fragment_item = {type = "html_fragment", html = "<a href=\"/x\">link</a>"}
    with_fragment_cell = {type = "table", columns = {"A"}, rows = {{{fragment_item}}}}
    check(page.validate({with_fragment_cell}) == nil, "a well-formed html_fragment cell item should validate")

    with_bad_fragment_cell = {type = "table", columns = {"A"}, rows = {{{{type = "html_fragment"}}}}}
    check(page.validate({with_bad_fragment_cell}) != nil, "an html_fragment item missing 'html' should be rejected")

    bad_item = {type = "message", css_class = "c", text = "t"}
    with_bad_cell = {type = "table", columns = {"A"}, rows = {{{bad_item}}}}
    check(page.validate({with_bad_cell}) != nil, "a non-form/non-html_fragment section nested in a cell should be rejected")

    with_number_cell = {type = "table", columns = {"A"}, rows = {{{42}}}}
    check(page.validate({with_number_cell}) != nil, "a cell item that's neither a string nor a table should be rejected")
end

-- Regression lock for the reason 'html_fragment' exists at all: a
-- table cell holding a pre-rendered link (the SQL console's reference
-- columns, render_reference_value) must appear as a real <a> tag, not
-- get HTML-escaped into visible "&lt;a href..." markup the way a plain
-- string item would.
function test_render_html_fragment_cell_item_is_not_escaped()
    print("Testing render inserts an html_fragment cell item's HTML verbatim, not escaped")
    sections = {{
        type = "table",
        columns = {"Sample"},
        rows = {{{{type = "html_fragment", html = "<a href=\"/detail?id=1\">#1</a>"}}}},
    }}
    err = page.validate(sections)
    check(err == nil, "sanity: this section should validate: " .. tostring(err))
    html = page.render(sections)
    check(contains(html, "<a href=\"/detail?id=1\">#1</a>"), "the html_fragment item's real anchor tag should appear unescaped")
    check(not contains(html, "&lt;a href"), "an html_fragment item must never be HTML-escaped")
end

function test_render_escapes_user_text()
    print("Testing render HTML-escapes text content by default")
    sections = {{type = "subheading", text = "<script>alert(1)</script>"}}
    err = page.validate(sections)
    check(err == nil, "sanity: this section should validate: " .. tostring(err))
    html = page.render(sections)
    check(not contains(html, "<script>alert(1)</script>"), "raw script tag must not appear unescaped")
    check(contains(html, "&lt;script&gt;"), "the heading text should be HTML-escaped")
end

-- Regression lock for the attr_fragment fix this session: nil and ""
-- are not the same "absent" -- only nil should omit an attribute.
function test_render_distinguishes_nil_from_empty_string_value()
    print("Testing render renders value=\"\" for an empty string, omits the attribute entirely for nil")
    sections = {{
        type = "form", method = "POST", action = "/x", submit_label = "Go",
        fields = {
            {type = "text", name = "empty_field", value = ""},
            {type = "text", name = "unset_field"},
        },
    }}
    err = page.validate(sections)
    check(err == nil, "sanity: this section should validate: " .. tostring(err))
    html = page.render(sections)
    check(contains(html, "name=\"empty_field\" value=\"\""), "a present-but-empty value must render as value=\"\"")
    check(not contains(html, "name=\"unset_field\" value"), "an absent (nil) value must not render a value attribute at all")
end

function test_render_checkbox_label_after_input()
    print("Testing render puts a checkbox's label after its input, not before")
    sections = {{
        type = "form", method = "POST", action = "/x", submit_label = "Go",
        fields = {{type = "checkbox", name = "opt_in", label = "Opt in", checked = true, value = "1"}},
    }}
    html = page.render(sections)
    input_pos = string.find(html, "<input type=\"checkbox\"", 1, true)
    label_pos = string.find(html, "<label for=\"opt_in\">", 1, true)
    check(input_pos != nil and label_pos != nil and input_pos < label_pos, "checkbox input must come before its label")
    check(contains(html, "checked"), "a checked checkbox should render the checked attribute")
end

function test_render_textarea_value_is_inner_content_not_attribute()
    print("Testing render puts a textarea's value as escaped inner content, not a value= attribute")
    sections = {{
        type = "form", method = "POST", action = "/x", submit_label = "Go",
        fields = {{type = "textarea", name = "notes", label = "Notes", value = "line one"}},
    }}
    html = page.render(sections)
    check(contains(html, "<textarea"), "should render a textarea element")
    check(contains(html, ">line one</textarea>"), "the value should appear as inner content before the closing tag")
    check(not contains(html, "value=\"line one\""), "a textarea's value must never appear as a value= attribute")
end

function test_render_table_with_nested_form_cell()
    print("Testing render produces a real table with a nested form inside one cell")
    sections = {{
        type = "table",
        columns = {"Login", "Actions"},
        rows = {{
            {"alice"},
            {{type = "form", method = "POST", action = "/archive", css_class = "inline", fields = {}, submit_label = "Archive"}},
        }},
    }}
    html = page.render(sections)
    check(contains(html, "<table"), "should render a table element")
    check(contains(html, "<td>alice</td>"), "the plain-string cell should render as escaped text in its own <td>")
    check(contains(html, "<form class=\"inline\""), "the nested form should render as a real <form> inside its cell")
end

function test_render_form_groups_produce_headed_sections()
    print("Testing render splits a form's groups into their own headed sections")
    sections = {{
        type = "form", method = "POST", action = "/settings-save", submit_label = "Save",
        fields = {{type = "hidden", name = "csrf_token", value = "tok"}},
        groups = {
            {css_class = "site-group", heading = "Site", fields = {{type = "text", name = "site_name", label = "Site name"}}},
            {css_class = "chat-group", heading = "Chat assistant", fields = {{type = "textarea", name = "extra", label = "Extra"}}},
        },
    }}
    html = page.render(sections)
    check(contains(html, "<h3>Site</h3>"), "the first group's heading should render")
    check(contains(html, "<h3>Chat assistant</h3>"), "the second group's heading should render")
    check(contains(html, "class=\"site-group\""), "each group's own css_class should render on its wrapper div")
    -- Exactly one real <form>, one real submit button -- HTML forms
    -- can't nest, which is the entire reason groups exist.
    form_count = 0
    search_from = 1
    while true do
        match_start = string.find(html, "<form", search_from, true)
        if match_start == nil then break end
        form_count = form_count + 1
        search_from = match_start + 1
    end
    check(form_count == 1, "groups must stay inside exactly one real <form>, got " .. tostring(form_count))
end

-- Run them
test_validate_accepts_a_realistic_page()
test_validate_rejects_unknown_section_type()
test_validate_rejects_missing_required_section_fields()
test_validate_rejects_empty_string_optional_form_and_table_fields()
test_validate_rejects_bad_form_fields()
test_validate_rejects_bad_groups()
test_validate_table_cells_only_nest_form_or_html_fragment()
test_render_html_fragment_cell_item_is_not_escaped()
test_render_escapes_user_text()
test_render_distinguishes_nil_from_empty_string_value()
test_render_checkbox_label_after_input()
test_render_textarea_value_is_inner_content_not_attribute()
test_render_table_with_nested_form_cell()
test_render_form_groups_produce_headed_sections()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All page.lua tests passed")
