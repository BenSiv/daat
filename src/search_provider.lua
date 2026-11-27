-- Web-search provider facade returning canonical {items = {{title, link, snippet}}} results.
-- Dynamically loads provider.search_<name>; see doc/decisions/002-provider-facade-tier.md.

const config = require("config")

const search_provider = {}

function search_provider.name()
    return config.load().search_provider
end

function search_provider.load()
    if search_provider.name() == nil then
        return nil, "no search.provider is set in config.lua"
    end
    ok, mod = pcall(require, "provider.search_" .. search_provider.name())
    if ok == false or mod == nil then
        return nil, "could not load search provider '" .. search_provider.name() .. "': " .. tostring(mod)
    end
    return mod
end

function search_provider.search(query)
    provider, err = search_provider.load()
    if provider == nil then
        return nil, err
    end
    return provider.search(query)
end

-- Plain-text "title (url)\nsnippet" blocks for direct citation by the agent.
function search_provider.format_results(response)
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

return search_provider
