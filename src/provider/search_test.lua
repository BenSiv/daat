-- A deterministic, cost-free provider for tests -- not a mock bolted
-- onto agent.lua, just another named backend behind search_provider's
-- own dynamic-loading facade, selected the same way agent_provider's
-- own "test" backend is (platform.lua's search_provider field, default
-- "test" in every bats test's own platform.lua -- see
-- tst/integration/test_helper.bash's write_platform_config). Running
-- the real internet_search.search tool against the real Google Search
-- API on every test run would make the test suite slow, flaky
-- (network), and genuinely cost money on every invocation.
--
-- Scripted via WEB_SEARCH_TEST_RESULTS (one JSON-encoded response body,
-- shaped like search_provider.lua's own canonical {items=...}) -- env
-- var name kept as-is from the pre-provider-split web_search.lua, no
-- functional reason to rename it now that only the module has moved.

json = require("dkjson")

search_test = {}

function search_test.search(query)
    test_raw = os.getenv("WEB_SEARCH_TEST_RESULTS")
    if test_raw == nil or test_raw == "" then
        return nil, "no results scripted for the test search provider (set WEB_SEARCH_TEST_RESULTS)"
    end
    response, _, decode_err = json.decode(test_raw)
    if response == nil then
        return nil, "invalid WEB_SEARCH_TEST_RESULTS: " .. tostring(decode_err)
    end
    return response
end

return search_test
