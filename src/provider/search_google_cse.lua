-- Google Programmable Search (Custom Search JSON API) backend for
-- search_provider.lua's own facade -- selected by default
-- (config.platform_config().search_provider == "google_cse") since
-- it's the only real backend today, but no longer hardcoded into the
-- calling code the way the old, single-file web_search.lua was.
--
-- Requires GOOGLE_SEARCH_API_KEY and GOOGLE_SEARCH_ENGINE_ID in the
-- environment (PassEnv'd the same way ANTHROPIC_API_KEY/
-- PLATFORM_MARIADB_PASSWORD already are -- see apache-platform.conf).
-- The engine id ("cx") comes from a Programmable Search Engine
-- configured to search the whole web, created separately at
-- programmablesearchengine.google.com -- no Terraform/gcloud path
-- creates that half, only the API key itself.

json = require("dkjson")
external_tool = require("external_tool")

search_google_cse = {}

SEARCH_API_URL = "https://www.googleapis.com/customsearch/v1"
RESULT_COUNT = 5

function search_credentials()
    key = os.getenv("GOOGLE_SEARCH_API_KEY")
    cx = os.getenv("GOOGLE_SEARCH_ENGINE_ID")
    if key == nil or key == "" then
        return nil, nil, "GOOGLE_SEARCH_API_KEY is not set"
    end
    if cx == nil or cx == "" then
        return nil, nil, "GOOGLE_SEARCH_ENGINE_ID is not set"
    end
    return key, cx
end

-- query -> (response_table, err). response_table is always shaped like
-- Google CSE's own real JSON body ({items = {{title=,link=,snippet=},
-- ...}}) -- already the canonical shape search_provider.format_results
-- expects, no translation needed. Mirrors agent_claude.lua's
-- claude_post shape: shell_quote every value (only the key/cx/query are
-- ever shell-interpolated, never response content), GET via
-- -G/--data-urlencode (CSE is GET-based, unlike the LLM providers'
-- POST-with-temp-file), io.popen, and the same four-stage error
-- handling every provider call here already uses (missing credentials
-- -> no response -> bad JSON -> API-level error).
function search_google_cse.search(query)
    key, cx, cred_err = search_credentials()
    if key == nil then
        return nil, cred_err
    end

    cmd = "curl -s -G " .. external_tool.shell_quote(SEARCH_API_URL) ..
        " --data-urlencode " .. external_tool.shell_quote("key=" .. key) ..
        " --data-urlencode " .. external_tool.shell_quote("cx=" .. cx) ..
        " --data-urlencode " .. external_tool.shell_quote("q=" .. query) ..
        " --data-urlencode " .. external_tool.shell_quote("num=" .. tostring(RESULT_COUNT))

    response_text, _ = external_tool.capture(cmd)

    if response_text == nil then
        return nil, "no response from Google Search API (curl/network failure)"
    end

    response, _, decode_err = json.decode(response_text)
    if response == nil then
        return nil, "invalid JSON response from Google Search API: " .. tostring(decode_err)
    end
    if response.error != nil then
        return nil, "Google Search API error: " .. tostring(response.error.message)
    end
    return response
end

return search_google_cse
