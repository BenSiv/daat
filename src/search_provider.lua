-- The seam a real web-search backend plugs into -- same shape as
-- agent_provider.lua's own facade (see that file's header), just for
-- internet_search.search (src/agent.lua's own AGENT_TOOLS entry)
-- instead of the chat LLM. Loaded dynamically by name
-- (config.platform_config().search_provider, default "google_cse")
-- rather than required directly, so swapping backends -- or substituting
-- the deterministic test provider -- is a config change, not a code
-- change (see doc/architecture.md's "Providers" section for why this
-- exists as a third tier alongside core and extensions).
--
-- search(query) -> (response, err). `response` is always shaped like
-- {items = {{title=, link=, snippet=}, ...}} regardless of which
-- backend produced it -- Google CSE's own real JSON body happens to
-- already be this shape, so src/provider/search_google_cse.lua needs
-- no translation step, but a future backend with a different wire
-- format would translate into this same canonical shape before
-- returning, the same way agent_provider.lua's own {content,
-- stopReason} is canonical across every LLM backend. format_results
-- lives here, at the facade, rather than per-backend, because it only
-- ever needs to understand this one canonical shape. Implementations
-- live under src/provider/ (search_google_cse.lua, search_test.lua) --
-- this facade file itself stays one level up, same split as
-- agent_provider.lua/src/provider/agent_*.lua.

config = require("config")

search_provider = {}

function search_provider.name()
    return config.platform_config().search_provider
end

function search_provider.load()
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

-- Formats a canonical {items=...} response's title/link/snippet into a
-- plain-text block for the model -- same shape document.search's own
-- dispatch branch uses (src/agent.lua), one result per entry, and
-- deliberately NOT JSON: putting the URL directly in each result's own
-- header, not buried inside a structured blob, makes citing the source
-- the path of least resistance rather than something the model has to
-- remember to dig out.
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
