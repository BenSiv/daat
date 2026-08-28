-- tst/unit/search_provider.lua
-- Unit tests for src/search_provider.lua's format_results (pure, no I/O) --
-- exercises citation formatting against canned Google CSE-shaped
-- response tables, matching this repo's existing tst/unit/ style
-- (require the module, check(), run inline, exit 1 on failure). The
-- real search() call (search_google_cse.lua's curl call,
-- search_test.lua's WEB_SEARCH_TEST_RESULTS gate) is covered
-- by tst/integration/search_provider.bats instead, since exercising
-- either is naturally a process-level concern.

search_provider = require("search_provider")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_format_results_puts_url_in_every_result_header()
    print("Testing format_results puts each result's URL right in its own header, not buried in a blob")
    response = {
        items = {
            {title = "Example Domain", link = "https://example.com/", snippet = "This domain is for use in examples."},
            {title = "Another Page", link = "https://example.org/page", snippet = "Some other snippet text."},
        },
    }
    out = search_provider.format_results(response)
    check(string.find(out, "Example Domain (https://example.com/)", 1, true) != nil,
        "expected first result's title+URL header, got:\n" .. tostring(out))
    check(string.find(out, "This domain is for use in examples.", 1, true) != nil,
        "expected first result's snippet present")
    check(string.find(out, "Another Page (https://example.org/page)", 1, true) != nil,
        "expected second result's title+URL header")
end

function test_format_results_blank_line_separates_results()
    print("Testing format_results joins multiple results with a blank line")
    response = {
        items = {
            {title = "A", link = "https://a.example/", snippet = "snippet a"},
            {title = "B", link = "https://b.example/", snippet = "snippet b"},
        },
    }
    out = search_provider.format_results(response)
    check(string.find(out, "snippet a\n\nB (https://b.example/)", 1, true) != nil,
        "expected a blank line between the first result's snippet and the second result's header, got:\n" .. tostring(out))
end

function test_format_results_handles_missing_snippet()
    print("Testing format_results doesn't error when a result has no snippet")
    response = {items = {{title = "No Snippet", link = "https://example.net/"}}}
    ok = pcall(search_provider.format_results, response)
    check(ok == true, "a result with no snippet field should not error")
end

function test_format_results_empty_items()
    print("Testing format_results reports no results found for an empty items list")
    out = search_provider.format_results({items = {}})
    check(out == "No results found.", "expected the no-results message, got: " .. tostring(out))
end

function test_format_results_nil_items()
    print("Testing format_results reports no results found when items is entirely absent (a real CSE zero-result response)")
    out = search_provider.format_results({})
    check(out == "No results found.", "expected the no-results message, got: " .. tostring(out))
end

function test_format_results_nil_response()
    print("Testing format_results doesn't error on a nil response")
    ok, out = pcall(search_provider.format_results, nil)
    check(ok == true, "a nil response should not error")
    check(out == "No results found.", "expected the no-results message for a nil response, got: " .. tostring(out))
end

test_format_results_puts_url_in_every_result_header()
test_format_results_blank_line_separates_results()
test_format_results_handles_missing_snippet()
test_format_results_empty_items()
test_format_results_nil_items()
test_format_results_nil_response()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All search_provider.lua tests passed")
