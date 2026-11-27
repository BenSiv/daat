-- Deterministic test search provider returning JSON from WEB_SEARCH_TEST_RESULTS.

const json = require("dkjson")

const search_test = {}

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
