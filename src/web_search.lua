-- Google Programmable Search (Custom Search JSON API) backend for the
-- internet_search.search agent tool (src/agent.lua's own AGENT_TOOLS
-- entry) -- the ordinary custom tool, gated by the same destructive-
-- action approval flow every other destructive tool goes through, that
-- agent_provider_claude.lua's own header comment already anticipated
-- ("A web-search capability, if added later, belongs in AGENT_TOOLS as
-- an ordinary custom tool ... going through that same approval gate --
-- not as one of Claude's server tools").
--
-- Not an agent_provider_* file -- that naming is for LLM providers
-- specifically (agent_provider.lua's own dynamic-loading facade,
-- selected via platform.lua's agent_provider field). There's exactly
-- one search backend today, so this is a plain module, not a
-- swappable-provider abstraction.
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

web_search = {}

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

-- Formats a decoded Google CSE response's `items` (title/link/snippet)
-- into a plain-text block for the model -- same shape document.search's
-- own dispatch branch uses (src/agent.lua), one result per entry, and
-- deliberately NOT JSON: putting the URL directly in each result's own
-- header, not buried inside a structured blob, makes citing the source
-- the path of least resistance rather than something the model has to
-- remember to dig out.
function web_search.format_results(response)
    items = nil
    if response != nil then
        items = response.items
    end
    if items == nil or #items == 0 then
        return "No results found."
    end
    lines = {}
    for _, item in ipairs(items) do
        header = tostring(item.title) .. " (" .. tostring(item.link) .. ")"
        snippet = item.snippet
        if snippet == nil then
            snippet = ""
        end
        table.insert(lines, header .. "\n" .. snippet)
    end
    return table.concat(lines, "\n\n")
end

-- query -> (response_table, err). response_table is always shaped like
-- Google CSE's own real JSON body ({items = {{title=,link=,snippet=},
-- ...}}), whether it came from a real call or the WEB_SEARCH_TEST_RESULTS
-- gate below, so web_search.format_results (and everything downstream)
-- never needs to know which one produced it. Mirrors
-- agent_provider_claude.lua's claude_post shape: shell_quote every
-- value (only the key/cx/query are ever shell-interpolated, never
-- response content), GET via -G/--data-urlencode (CSE is GET-based,
-- unlike the LLM providers' POST-with-temp-file), io.popen, and the
-- same four-stage error handling every provider call here already uses
-- (missing credentials -> no response -> bad JSON -> API-level error).
function web_search.search(query)
    -- Scripted via WEB_SEARCH_TEST_RESULTS (one JSON-encoded response
    -- body, same shape a real call would decode to) -- mirrors
    -- agent_provider_test.lua's AGENT_TEST_RESPONSES gate, but scoped to
    -- this one module rather than swapping the whole LLM provider.
    -- internet_search.search is the first tool needing its own external
    -- side effect faked in tests; document.search never needed this
    -- since it's already local/deterministic against the test store.
    test_raw = os.getenv("WEB_SEARCH_TEST_RESULTS")
    if test_raw != nil and test_raw != "" then
        response, _, decode_err = json.decode(test_raw)
        if response == nil then
            return nil, "invalid WEB_SEARCH_TEST_RESULTS: " .. tostring(decode_err)
        end
        return response
    end

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

return web_search
