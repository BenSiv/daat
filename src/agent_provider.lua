-- The seam a real LLM backend plugs into:
--   generate(model, system_prompt, prompt) -> (text, err) -- a single
--     plain-text call, no tools/history (compaction summaries,
--     knowledge distillation/link-evaluation).
--   converse(model, system_prompt, messages, tools) -> (response, err)
--     -- the real chat-agent turn loop: `messages` is a list of
--     {role, content} turns, `tools` a list of function declarations
--     (agent.tool_declarations()), `response` a structured
--     {content: [...blocks...], stopReason, errorMessage} reply --
--     real native tool-calling, not a hand-rolled text tag protocol.
--   embeddings(model, text) -> (vector, err), optional.
-- Loaded dynamically by name (AGENT_PROVIDER env var, default "pi" --
-- the pi-ai bridge, real multi-provider structured tool-calling)
-- rather than required directly, so swapping providers -- or, just as
-- importantly, swapping in the deterministic test provider for
-- repeatable, cost-free test runs -- is a config change, not a code
-- change.

agent_provider = {}

-- Same default-resolution as agent_provider.load() itself, split out
-- so a caller that just wants the *name* (task #87's knowledge_chat_eval
-- recording, e.g.) doesn't need to load/require the actual provider
-- module to get it.
function agent_provider.name()
    name = os.getenv("AGENT_PROVIDER")
    if name == nil or name == "" then
        name = "pi"
    end
    return name
end

function agent_provider.load()
    ok, mod = pcall(require, "agent_provider_" .. agent_provider.name())
    if ok == false or mod == nil then
        return nil, "could not load agent provider '" .. agent_provider.name() .. "': " .. tostring(mod)
    end
    return mod
end

function agent_provider.generate(model, system_prompt, prompt)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    return provider.generate(model, system_prompt, prompt)
end

function agent_provider.converse(model, system_prompt, messages, tools)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    if provider.converse == nil then
        return nil, "provider '" .. agent_provider.name() .. "' has no converse (structured tool-calling) support"
    end
    return provider.converse(model, system_prompt, messages, tools)
end

function agent_provider.embeddings(model, text)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    if provider.embeddings == nil then
        return nil, "provider has no embeddings support"
    end
    return provider.embeddings(model, text)
end

return agent_provider
