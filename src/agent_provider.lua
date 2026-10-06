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
-- An implementation also names its own defaults, default_model and
-- (with embeddings) default_embedding_model, so a model name never
-- appears in core: platform.lua's agent_model/embedding_model choose
-- one, and when unset the provider's own default applies.
-- Loaded dynamically by name (config.platform_config().agent_provider,
-- no default: a deployment names its backend, e.g. "vertex" for
-- src/provider/agent_vertex.lua) rather than required directly, so swapping providers -- or,
-- just as importantly, swapping in the deterministic test provider for
-- repeatable, cost-free test runs -- is a config change, not a code
-- change. Implementations live under src/provider/ (agent_claude.lua,
-- agent_vertex.lua, agent_test.lua) -- this facade file itself stays
-- one level up, since it's the seam every implementation plugs into,
-- not an implementation itself (see doc/architecture.md's "Providers"
-- section).

config = require("config")

agent_provider = {}

-- Same default-resolution as agent_provider.load() itself, split out
-- so a caller that just wants the *name* (knowledge_chat_eval recording,
-- e.g.) doesn't need to load/require the actual provider module to get
-- it.
function agent_provider.name()
    return config.platform_config().agent_provider
end

function agent_provider.load()
    if agent_provider.name() == nil then
        return nil, "no agent_provider is set in platform.lua"
    end
    ok, mod = pcall(require, "provider.agent_" .. agent_provider.name())
    if ok == false or mod == nil then
        return nil, "could not load agent provider '" .. agent_provider.name() .. "': " .. tostring(mod)
    end
    return mod
end

-- The chat/generation model: platform.lua's agent_model, else the
-- provider's default. nil when no provider loads.
function agent_provider.model()
    configured = config.platform_config().agent_model
    if configured != nil then
        return configured
    end
    provider = agent_provider.load()
    if provider == nil then
        return nil
    end
    return provider.default_model
end

-- The embedding model, the same way: platform.lua's embedding_model,
-- else the provider's default. Stored with every vector
-- (document_embedding.model), so a change of model is visible there.
function agent_provider.embedding_model()
    configured = config.platform_config().embedding_model
    if configured != nil then
        return configured
    end
    provider = agent_provider.load()
    if provider == nil then
        return nil
    end
    return provider.default_embedding_model
end

-- A nil model in any call below means agent_provider.model() (or
-- embedding_model()), so callers needn't resolve it themselves.
function agent_provider.generate(model, system_prompt, prompt)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    if model == nil then
        model = agent_provider.model()
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
    if model == nil then
        model = agent_provider.model()
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
    if model == nil then
        model = agent_provider.embedding_model()
    end
    return provider.embeddings(model, text)
end

return agent_provider
