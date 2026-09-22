-- tst/unit/html.lua
-- Unit tests for src/html.lua. Originally just the "daat canvas"
-- (validate_canvas/render_canvas): the typed-element-table -> trusted-
-- HTML-renderer pattern a UI plugin's page is built from, modeled on
-- template.lua's own section.type dispatch. No prior test coverage
-- existed for html.lua at all before this file. Later extended with
-- apply_nav_hidden/apply_nav_order (brex 683042859).

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

-- apply_nav_hidden/apply_nav_order (brex 683042859): the platform.lua
-- nav_order/nav_hidden overlay applied on top of html.page_shell's own
-- capability-gated nav_items list. No prior coverage existed since
-- these are new -- exercised directly here rather than only through a
-- full page_shell render, same reasoning tst/unit/page.lua gives for
-- testing its own module directly.
function nav_items_fixture()
    return {
        {key = "home", href = "/", label = "Home"},
        {key = "documents", href = "documents", label = "Documents"},
        {key = "data", href = "data", label = "Data"},
        {key = "system", href = "system", label = "System"},
    }
end

function keys_of(items)
    keys = {}
    for _, item in ipairs(items) do
        table.insert(keys, item.key)
    end
    return keys
end

function test_apply_nav_hidden_removes_only_listed_keys()
    print("Testing apply_nav_hidden removes exactly the listed keys, keeps the rest")
    result = html.apply_nav_hidden(nav_items_fixture(), {"data"})
    check(#result == 3, "expected 3 remaining items, got " .. tostring(#result))
    keys = keys_of(result)
    check(keys[1] == "home" and keys[2] == "documents" and keys[3] == "system",
        "expected home/documents/system in original order, got " .. table.concat(keys, ","))
end

function test_apply_nav_hidden_nil_or_empty_is_a_no_op()
    print("Testing apply_nav_hidden with nil or an empty list changes nothing")
    original = nav_items_fixture()
    check(#html.apply_nav_hidden(original, nil) == 4, "nil hidden list should keep all items")
    check(#html.apply_nav_hidden(original, {}) == 4, "empty hidden list should keep all items")
end

function test_apply_nav_hidden_unrecognized_key_is_a_silent_no_op()
    print("Testing apply_nav_hidden ignores a key that doesn't match any real item")
    result = html.apply_nav_hidden(nav_items_fixture(), {"not_a_real_key"})
    check(#result == 4, "an unrecognized hidden key should drop nothing, got " .. tostring(#result))
end

function test_apply_nav_order_moves_named_keys_to_the_front()
    print("Testing apply_nav_order places listed keys first, in the given order")
    result = html.apply_nav_order(nav_items_fixture(), {"data", "home"})
    keys = keys_of(result)
    check(keys[1] == "data" and keys[2] == "home", "expected data,home first, got " .. table.concat(keys, ","))
    check(keys[3] == "documents" and keys[4] == "system",
        "unlisted items should keep their original relative order, appended after -- got " .. table.concat(keys, ","))
end

function test_apply_nav_order_nil_or_empty_is_a_no_op()
    print("Testing apply_nav_order with nil or an empty list changes nothing")
    original = nav_items_fixture()
    check(table.concat(keys_of(html.apply_nav_order(original, nil)), ",") == table.concat(keys_of(original), ","),
        "nil order should leave the list unchanged")
    check(table.concat(keys_of(html.apply_nav_order(original, {})), ",") == table.concat(keys_of(original), ","),
        "empty order should leave the list unchanged")
end

function test_apply_nav_order_unrecognized_key_is_a_silent_no_op()
    print("Testing apply_nav_order ignores a key that doesn't match any real item")
    result = html.apply_nav_order(nav_items_fixture(), {"not_a_real_key", "data"})
    keys = keys_of(result)
    check(#result == 4, "an unrecognized order key should not add or drop items, got " .. tostring(#result))
    check(keys[1] == "data", "the real key in the order list should still move to the front, got " .. table.concat(keys, ","))
end

function test_apply_nav_order_duplicate_key_is_only_placed_once()
    print("Testing apply_nav_order doesn't duplicate an item whose key is repeated in order")
    result = html.apply_nav_order(nav_items_fixture(), {"data", "data", "home"})
    check(#result == 4, "a repeated order key should not duplicate the item, got " .. tostring(#result))
end

-- word_diff_html/word_diff_runs (found live: the ledger history view
-- showed a field's full old/new text side by side even for a one-word
-- edit, making a real change in a long field like a document's content
-- unreadable). LCS word diff -- exercised directly, same reasoning as
-- apply_nav_hidden/apply_nav_order above.
function test_word_diff_runs_identical_text_is_all_same()
    print("Testing word_diff_runs treats identical text as a single 'same' run")
    runs = html.word_diff_runs("the quick fox", "the quick fox")
    check(#runs == 1 and runs[1].kind == "same", "identical text should produce one 'same' run")
end

function test_word_diff_runs_detects_a_single_word_change()
    print("Testing word_diff_runs isolates a single changed word, keeping the rest as 'same'")
    runs = html.word_diff_runs("the quick fox jumps", "the slow fox jumps")
    -- "the"/"fox jumps" must stay 'same'; "quick"/"slow" must show up as
    -- one 'removed' and one 'added' run each -- the relative order
    -- between those two middle runs is just an LCS tie-break artifact,
    -- not a correctness property, so this checks presence/content, not
    -- a specific sequence.
    check(#runs == 4, "expected 4 runs (same, [added/removed]x2, same), got " .. tostring(#runs))
    check(runs[1].kind == "same" and runs[1].words[1] == "the", "the leading 'the' should be a same run")
    check(runs[4].kind == "same" and runs[4].words[1] == "fox" and runs[4].words[2] == "jumps",
        "the trailing 'fox jumps' should be one same run")
    removed_words, added_words = {}, {}
    for k = 2, 3 do
        if runs[k].kind == "removed" then
            removed_words = runs[k].words
        elseif runs[k].kind == "added" then
            added_words = runs[k].words
        end
    end
    check(removed_words[1] == "quick", "expected a removed run carrying 'quick', got " .. tostring(removed_words[1]))
    check(added_words[1] == "slow", "expected an added run carrying 'slow', got " .. tostring(added_words[1]))
end

function test_word_diff_runs_pure_insertion_and_deletion()
    print("Testing word_diff_runs handles a pure insertion and a pure deletion")
    added_runs = html.word_diff_runs("a b", "a b c")
    check(added_runs[#added_runs].kind == "added" and added_runs[#added_runs].words[1] == "c",
        "appending a word should show up as a trailing 'added' run")
    removed_runs = html.word_diff_runs("a b c", "a b")
    check(removed_runs[#removed_runs].kind == "removed" and removed_runs[#removed_runs].words[1] == "c",
        "dropping a trailing word should show up as a trailing 'removed' run")
end

function test_word_diff_html_highlights_only_the_changed_word()
    print("Testing word_diff_html wraps only the changed words, leaving the rest plain")
    rendered = html.word_diff_html("the quick fox jumps", "the slow fox jumps")
    check(string.find(rendered, "<del", 1, true) != nil and string.find(rendered, "quick", 1, true) != nil,
        "the removed word should be wrapped in <del>: " .. rendered)
    check(string.find(rendered, "<ins", 1, true) != nil and string.find(rendered, "slow", 1, true) != nil,
        "the added word should be wrapped in <ins>: " .. rendered)
    check(string.find(rendered, "<del>the</del>", 1, true) == nil and string.find(rendered, "<ins>the</ins>", 1, true) == nil,
        "an unchanged word must not be wrapped: " .. rendered)
end

function test_word_diff_html_escapes_html_in_diffed_text()
    print("Testing word_diff_html HTML-escapes both old and new words")
    rendered = html.word_diff_html("<script>old", "<script>new")
    check(string.find(rendered, "<script>", 1, true) == nil,
        "a raw <script> tag from either side must never reach the output unescaped: " .. rendered)
    check(string.find(rendered, "&lt;script&gt;", 1, true) != nil, "the escaped form should be present instead: " .. rendered)
end

function test_word_diff_html_returns_nil_past_the_word_cap()
    print("Testing word_diff_html falls back to nil (caller shows plain old -> new) past DIFF_MAX_WORDS")
    huge_old = {}
    huge_new = {}
    for i = 1, 401 do
        table.insert(huge_old, "word" .. tostring(i))
        table.insert(huge_new, "word" .. tostring(i))
    end
    huge_new[1] = "different"
    check(html.word_diff_html(table.concat(huge_old, " "), table.concat(huge_new, " ")) == nil,
        "a diff over DIFF_MAX_WORDS words should return nil, not attempt the O(n*m) LCS")
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
test_apply_nav_hidden_removes_only_listed_keys()
test_apply_nav_hidden_nil_or_empty_is_a_no_op()
test_apply_nav_hidden_unrecognized_key_is_a_silent_no_op()
test_apply_nav_order_moves_named_keys_to_the_front()
test_apply_nav_order_nil_or_empty_is_a_no_op()
test_apply_nav_order_unrecognized_key_is_a_silent_no_op()
test_apply_nav_order_duplicate_key_is_only_placed_once()
test_word_diff_runs_identical_text_is_all_same()
test_word_diff_runs_detects_a_single_word_change()
test_word_diff_runs_pure_insertion_and_deletion()
test_word_diff_html_highlights_only_the_changed_word()
test_word_diff_html_escapes_html_in_diffed_text()
test_word_diff_html_returns_nil_past_the_word_cap()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All html.lua tests passed")
