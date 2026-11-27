-- Google Custom Search JSON API provider (GOOGLE_SEARCH_API_KEY + GOOGLE_SEARCH_ENGINE_ID).

const json = require("dkjson")
const external_tool = require("external_tool")

const search_google_cse = {}

const SEARCH_API_URL = "https://www.googleapis.com/customsearch/v1"
const RESULT_COUNT = 5

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
