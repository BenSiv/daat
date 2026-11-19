-- Deployment paths, declarative configuration schema, validation, and
-- CLI inspection (`daat config <show|check>`).
--
-- A deployment's root holds `.store/` (SQLite file + session secret),
-- `schemas/`, `dropdowns/`, `extensions/`, `views/`, `templates/`, and
-- two optional sandboxed-Lua data files:
--   - `config.lua`: structured operational configuration organized into
--     seven sections (`database`, `agent`, `knowledge`, `search`, `mail`,
--     `ui`, `extensions`). Secrets never live in `config.lua`; they are
--     read from environment variables (`DAAT_MARIADB_PASSWORD`,
--     `DAAT_SMTP_PASSWORD`, `DAAT_GRAPH_CLIENT_SECRET`,
--     `ANTHROPIC_API_KEY`, `OLLAMA_API_KEY` / `OPENAI_API_KEY`,
--     `GOOGLE_SEARCH_API_KEY` / `GOOGLE_SEARCH_ENGINE_ID`).
--   - `theme.lua`: optional branding (`site_name`, `has_logo`,
--     `hide_home_heading`, `system_prompt_extra`, `colors`).

const db_lib = require("database")
const json = require("dkjson")
const paths = require("paths")
const sandbox = require("sandbox")

const config = {}

function config.valid_resource_name(name)
    return type(name) == "string" and string.match(name, "^[A-Za-z0-9_][A-Za-z0-9_%-]*$") != nil
end

const STORE_DIR = ".store"
const DB_FILE = "store.db"
const SESSION_SECRET_FILE = "session_secret"
const THEME_FILE = "theme.lua"
const CONFIG_FILE = "config.lua"

CONFIG_CACHE = nil
SETTINGS_CACHE = {}

const THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
    "tier_0", "tier_1", "tier_2", "tier_3",
}
config.THEME_COLOR_KEYS = THEME_COLOR_KEYS

const THEME_TOP_KEYS = {
    site_name = "string",
    has_logo = "boolean",
    hide_home_heading = "boolean",
    system_prompt_extra = "string",
    colors = "table",
}

const RETENTION_STRATEGIES = {
    full = {
        knowledge_days = "forever",
        tool_trace_days = "forever",
        model_input_days = "forever",
        metrics_days = "forever",
        transcript_documents = "whole",
    },
    standard = {
        knowledge_days = "forever",
        tool_trace_days = 90,
        model_input_days = 30,
        metrics_days = "forever",
        transcript_documents = "off",
    },
    lean = {
        knowledge_days = 30,
        tool_trace_days = 14,
        model_input_days = 0,
        metrics_days = "forever",
        transcript_documents = "off",
    },
}
config.RETENTION_STRATEGIES = RETENTION_STRATEGIES

const DEFAULT_MASKING = {
    chat = false,
    research = true,
    background = true,
}

const CONFIG_SECTIONS = {
    "database",
    "agent",
    "knowledge",
    "search",
    "mail",
    "ui",
    "extensions",
}
config.CONFIG_SECTIONS = CONFIG_SECTIONS

-- Single source of truth for every `config.lua` setting.
-- `section` + `key` is the path in `config.lua`; `conf_key` is the field
-- populated on `config.load()` (and `setting_key` is exposed via
-- `config.setting(...)` for provider-specific fields).
const CONFIG_SCHEMA = {
    -- database
    {section = "database", key = "backend", conf_key = "db_backend", kind = "enum", enum = {"sqlite", "mariadb"}, default = "sqlite", desc = "Storage backend ('sqlite' or 'mariadb')"},
    {section = "database", key = "host", conf_key = "mariadb_host", kind = "string", default = "127.0.0.1", desc = "MariaDB server host"},
    {section = "database", key = "port", conf_key = "mariadb_port", kind = "integer", min = 1, default = 3306, desc = "MariaDB server TCP port"},
    {section = "database", key = "user", conf_key = "mariadb_user", kind = "string", default = nil, desc = "MariaDB login user (password via DAAT_MARIADB_PASSWORD)"},
    {section = "database", key = "database", conf_key = "mariadb_database", kind = "string", default = nil, desc = "MariaDB database/schema name"},

    -- agent
    {section = "agent", key = "provider", conf_key = "agent_provider", kind = "string", default = nil, desc = "LLM provider ('vertex', 'claude', 'ollama', or 'test')"},
    {section = "agent", key = "model", conf_key = "agent_model", kind = "string", default = nil, desc = "Chat/generation model override"},
    {section = "agent", key = "thinking", conf_key = "agent_thinking", kind = "enum", enum = {"off", "summary", "full"}, default = "summary", desc = "Reasoning capture level ('off', 'summary', 'full')"},
    {section = "agent", key = "turn_mode", conf_key = "agent_turn_mode", kind = "enum", enum = {"detached", "inline"}, default = "detached", desc = "Chat turn execution mode ('detached' worker or 'inline')"},
    {section = "agent", key = "turn_stale_seconds", conf_key = "agent_turn_stale_seconds", kind = "number", min = 1, default = 180, desc = "Seconds without heartbeat before a detached turn is marked stale"},
    {section = "agent", key = "auto_continue_max", conf_key = "agent_auto_continue_max", kind = "integer", min = 0, default = 3, desc = "Max automatic step-budget continuations for a detached turn"},
    {section = "agent", key = "auto_continue_minutes", conf_key = "agent_auto_continue_minutes", kind = "number", min = 0, default = 10, desc = "Total wall-clock minutes allowed across auto-continuations"},
    {section = "agent", key = "max_turns", conf_key = "agent_max_turns", kind = "integer", min = 1, default = 20, desc = "Max model steps per chat turn"},
    {section = "agent", key = "research_max_turns", conf_key = "agent_research_max_turns", kind = "integer", min = 1, default = 12, desc = "Max model steps per research sub-agent call"},
    {section = "agent", key = "background_max_turns", conf_key = "agent_background_max_turns", kind = "integer", min = 1, default = 20, desc = "Max model steps per background task"},
    {section = "agent", key = "background_max_attempts", conf_key = "agent_background_max_attempts", kind = "integer", min = 1, default = 3, desc = "Max retry attempts for a failed background task"},
    {section = "agent", key = "search_excerpt_length", conf_key = "agent_search_excerpt_length", kind = "integer", min = 1, default = 1200, desc = "Default excerpt character length for document.search"},
    {section = "agent", key = "search_excerpt_full_length", conf_key = "agent_search_excerpt_full_length", kind = "integer", gt = 0, default = 4000, desc = "Full-detail excerpt character length for document.search"},
    {section = "agent", key = "query_row_cap", conf_key = "agent_query_row_cap", kind = "integer", min = 1, default = 200, desc = "Max rows returned to the model by entity.query"},
    {section = "agent", key = "query_char_cap", conf_key = "agent_query_char_cap", kind = "integer", gt = 0, default = 12000, desc = "Max characters returned to the model by entity.query"},
    {section = "agent", key = "get_field_chars", conf_key = "agent_get_field_chars", kind = "integer", gt = 0, default = 4000, desc = "Preview character window for entity.get text fields"},
    {section = "agent", key = "tool_result_cap", conf_key = "agent_tool_result_cap", kind = "integer", gt = 0, default = 24000, desc = "Max characters shown inline per tool result before result.read paging"},
    {section = "agent", key = "knowledge_list_page", conf_key = "agent_knowledge_list_page", kind = "integer", gt = 0, default = 50, desc = "Page size for knowledge.list"},
    {section = "agent", key = "compaction_threshold", conf_key = "agent_compaction_threshold", kind = "integer", min = 1, default = 48000, desc = "Prompt token threshold triggering conversation compaction"},
    {section = "agent", key = "context_fixed_tokens", conf_key = "agent_context_fixed_tokens", kind = "integer", min = 0, default = 3900, desc = "Estimated fixed prompt token overhead before first model call"},
    {section = "agent", key = "chars_per_token", conf_key = "agent_chars_per_token", kind = "number", gt = 0, default = 2.8, desc = "Fallback character-per-token ratio before real token counts exist"},
    {section = "agent", key = "compaction_mid_turn", conf_key = "agent_compaction_mid_turn", kind = "boolean", default = true, desc = "Check compaction threshold before each step within a turn"},
    {section = "agent", key = "pin_schema", conf_key = "agent_pin_schema", kind = "boolean", default = true, desc = "Preserve schema discovery tool results verbatim across compaction"},
    {section = "agent", key = "pinned_schema_chars", conf_key = "agent_pinned_schema_chars", kind = "integer", min = 0, default = 6000, desc = "Character budget for pinned schema tool results"},
    {section = "agent", key = "dedupe_repeat_calls", conf_key = "agent_dedupe_repeat_calls", kind = "boolean", default = true, desc = "Replace identical repeat read-only tool calls with pointers"},
    {section = "agent", key = "masking", conf_key = "agent_masking", kind = "masking", default = nil, desc = "Observation masking boolean or {chat, research, background} table"},
    {section = "agent", key = "masking_keep_last", conf_key = "agent_masking_keep_last", kind = "integer", min = 0, default = 5, desc = "Number of most recent tool results exempted from masking"},
    {section = "agent", key = "masking_min_chars", conf_key = "agent_masking_min_chars", kind = "integer", min = 0, default = 300, desc = "Minimum tool-result length eligible for observation masking"},
    {section = "agent", key = "masking_batch_tokens", conf_key = "agent_masking_batch_tokens", kind = "integer", min = 0, default = 4000, desc = "Token step size before advancing the observation-masking boundary"},
    {section = "agent", key = "carry_user_requests", conf_key = "agent_carry_user_requests", kind = "boolean", default = false, desc = "Carry recent user requests across sessions for the same user"},
    {section = "agent", key = "carry_user_requests_limit", conf_key = "agent_carry_user_requests_limit", kind = "integer", min = 1, default = 5, desc = "Max prior-session user requests carried forward"},
    {section = "agent", key = "retention", conf_key = "agent_retention", kind = "enum", enum = {"full", "standard", "lean"}, default = "standard", desc = "Data retention strategy ('full', 'standard', 'lean')"},
    {section = "agent", key = "retention_override", conf_key = "agent_retention_override", kind = "retention_override", default = nil, desc = "Per-category retention overrides ({knowledge_days, tool_trace_days, model_input_days, metrics_days, transcript_documents})"},
    {section = "agent", key = "model_input_days", conf_key = "model_input_days", kind = "retention_days", default = nil, desc = "Direct override for stored prompt retention days (number >= 0 or 'forever')"},
    {section = "agent", key = "transcript_documents", conf_key = "agent_transcript_documents", kind = "enum", enum = {"off", "whole"}, default = nil, desc = "Keep full searchable chat transcript documents ('off' or 'whole')"},
    {section = "agent", key = "curate_quiet_minutes", conf_key = "agent_curate_quiet_minutes", kind = "number", min = 0, default = 60, desc = "Idle minutes before a chat session becomes eligible for curation"},
    {section = "agent", key = "chat_attachments_enabled", conf_key = "chat_attachments_enabled", kind = "boolean", default = false, desc = "Enable PDF/document uploads in chat (requires pdftotext/pandoc)"},
    {section = "agent", key = "vertex_project", setting_key = "vertex_project", kind = "string", default = nil, desc = "Google Cloud project ID for Vertex AI"},
    {section = "agent", key = "vertex_region", setting_key = "vertex_region", kind = "string", default = nil, desc = "Google Cloud region for Vertex AI (e.g. 'global')"},
    {section = "agent", key = "ollama_url", setting_key = "ollama_url", kind = "string", default = nil, desc = "Base /v1 URL for Ollama or OpenAI-compatible server"},
    {section = "agent", key = "ollama_reasoning_effort", setting_key = "ollama_reasoning_effort", kind = "boolean", default = nil, desc = "Send OpenAI reasoning_effort field on Ollama/v1 requests"},

    -- knowledge
    {section = "knowledge", key = "embedding_model", conf_key = "embedding_model", kind = "string", default = nil, desc = "Embedding model override (changing requires 'daat repair embeddings')"},
    {section = "knowledge", key = "embedding_quiet_minutes", conf_key = "embedding_quiet_minutes", kind = "number", min = 0, default = 5, desc = "Quiet minutes after save before embedding (0 embeds immediately)"},
    {section = "knowledge", key = "embedding_skip", conf_key = "embedding_skip", kind = "pattern_list", default = nil, desc = "Lua line patterns stripped from document text before embedding"},
    {section = "knowledge", key = "search_review_mode", conf_key = "search_review_mode", kind = "enum", enum = {"deferred", "inline"}, default = "deferred", desc = "Run retrieval heat/link review 'deferred' in worker or 'inline'"},
    {section = "knowledge", key = "search_passages", conf_key = "search_passages", kind = "boolean", default = true, desc = "Score and extract top matching passages within search hits"},
    {section = "knowledge", key = "passage_max_chars", conf_key = "passage_max_chars", kind = "integer", gt = 0, default = 1500, desc = "Maximum characters per split passage"},
    {section = "knowledge", key = "passage_min_chars", conf_key = "passage_min_chars", kind = "integer", gt = 0, default = 200, desc = "Minimum characters per passage before merging into neighbors"},
    {section = "knowledge", key = "passages_per_document", conf_key = "passages_per_document", kind = "integer", gt = 0, default = 2, desc = "Maximum passages shown per shortlisted document"},
    {section = "knowledge", key = "passage_lexical_weight", conf_key = "passage_lexical_weight", kind = "number", min = 0, default = 0.2, desc = "Lexical weight blended into semantic passage scoring"},
    {section = "knowledge", key = "passage_max_embeds_per_search", conf_key = "passage_max_embeds_per_search", kind = "integer", gt = 0, default = 60, desc = "Maximum uncached passages embedded during a single search"},
    {section = "knowledge", key = "passage_cache_days", conf_key = "passage_cache_days", kind = "number", min = 0, default = 30, desc = "Days unused passage embeddings remain cached (0 keeps forever)"},
    {section = "knowledge", key = "build_aspects", conf_key = "build_aspects", kind = "boolean", default = false, desc = "Build multi-aspect vectors for long documents during embedding"},
    {section = "knowledge", key = "search_aspects", conf_key = "search_aspects", kind = "boolean", default = false, desc = "Include multi-aspect document vectors in semantic search"},
    {section = "knowledge", key = "curate_aspects", conf_key = "curate_aspects", kind = "boolean", default = true, desc = "Curate repeatedly retrieved aspects of long sources into standalone notes"},
    {section = "knowledge", key = "aspect_min_chars", conf_key = "aspect_min_chars", kind = "integer", min = 0, default = 7000, desc = "Minimum document length before building aspect vectors"},
    {section = "knowledge", key = "aspect_max", conf_key = "aspect_max", kind = "integer", min = 1, default = 4, desc = "Maximum aspect clusters built per long document"},
    {section = "knowledge", key = "aspect_dims", conf_key = "aspect_dims", kind = "integer", min = 0, default = 0, desc = "Truncated aspect vector dimensions (0 keeps full dimensionality)"},
    {section = "knowledge", key = "aspect_vector", conf_key = "aspect_vector", kind = "enum", enum = {"medoid", "centroid"}, default = "centroid", desc = "Aspect cluster vector representation ('centroid' or 'medoid')"},
    {section = "knowledge", key = "link_passage_gate", conf_key = "link_passage_gate", kind = "number", min = 0, default = 0.72, desc = "Minimum passage cosine similarity before proposing co-retrieval links (0 disables)"},
    {section = "knowledge", key = "link_gate_passages_per_document", conf_key = "link_gate_passages_per_document", kind = "integer", gt = 0, default = 40, desc = "Max passages compared per document in the co-retrieval link gate"},
    {section = "knowledge", key = "link_gate_max_embeds", conf_key = "link_gate_max_embeds", kind = "integer", gt = 0, default = 80, desc = "Max new passage embeddings computed per co-retrieval pair"},
    {section = "knowledge", key = "tag_restructure", conf_key = "tag_restructure", kind = "boolean", default = false, desc = "Allow agent-judged tag splits, merges, and relabels after embedding"},
    {section = "knowledge", key = "tag_dims", conf_key = "tag_dims", kind = "integer", min = 1, default = 256, desc = "Embedding prefix dimensions used for tag centres"},
    {section = "knowledge", key = "tag_second_within", conf_key = "tag_second_within", kind = "number_or_false", default = 0.02, desc = "Cosine margin to also assign second-nearest tag (or false for single tag)"},
    {section = "knowledge", key = "tag_min_text", conf_key = "tag_min_text", kind = "integer", min = 0, default = 200, desc = "Minimum body characters required before auto-tagging a document"},
    {section = "knowledge", key = "tag_split_min", conf_key = "tag_split_min", kind = "integer", min = 2, default = 40, desc = "Minimum member count before a tag is eligible to split"},
    {section = "knowledge", key = "tag_build_max", conf_key = "tag_build_max", kind = "integer", min = 2, default = 60, desc = "Maximum tag count considered by 'daat tag build'"},
    {section = "knowledge", key = "tag_build_coarseness", conf_key = "tag_build_coarseness", kind = "number", min = 0, default = 0, desc = "Coarseness exponent biasing 'daat tag build' toward fewer tags"},
    {section = "knowledge", key = "reference_aliases", conf_key = "reference_aliases", kind = "alias_list", default = nil, desc = "List of {lua_pattern, replacement} pairs for entity-mention normalization"},
    {section = "knowledge", key = "duplicate_external_prefixes", conf_key = "duplicate_external_prefixes", kind = "string_list", default = nil, desc = "External ID prefixes eligible for duplicate folding"},

    -- search
    {section = "search", key = "provider", conf_key = "search_provider", kind = "string", default = nil, desc = "Web search provider ('google_cse' or 'test')"},

    -- mail
    {section = "mail", key = "provider", conf_key = "mail_provider", kind = "string", default = nil, desc = "Outbound mail provider ('smtp', 'graph', or 'test')"},
    {section = "mail", key = "from", conf_key = "mail_from", kind = "string", default = nil, desc = "Sender email address for password-reset emails"},
    {section = "mail", key = "public_url", conf_key = "public_url", kind = "string", default = nil, desc = "Externally reachable base URL for emailed links"},
    {section = "mail", key = "smtp_url", setting_key = "smtp_url", kind = "string", default = nil, desc = "SMTP server URL (e.g. 'smtp://smtp.office365.com:587')"},
    {section = "mail", key = "smtp_user", setting_key = "smtp_user", kind = "string", default = nil, desc = "SMTP username (password via DAAT_SMTP_PASSWORD)"},
    {section = "mail", key = "graph_tenant_id", setting_key = "graph_tenant_id", kind = "string", default = nil, desc = "Microsoft Entra tenant ID for Graph mail"},
    {section = "mail", key = "graph_client_id", setting_key = "graph_client_id", kind = "string", default = nil, desc = "Microsoft Entra app client ID (secret via DAAT_GRAPH_CLIENT_SECRET)"},

    -- ui
    {section = "ui", key = "nav_order", conf_key = "nav_order", kind = "string_list", default = nil, desc = "Ordered list of sidebar navigation item keys"},
    {section = "ui", key = "nav_hidden", conf_key = "nav_hidden", kind = "string_list", default = nil, desc = "Sidebar navigation item keys to hide"},
    {section = "ui", key = "adhoc_row_cap", conf_key = "adhoc_row_cap", kind = "integer", min = 1, default = 1000, desc = "Default row limit applied to ad-hoc /sql queries"},

    -- extensions
    {section = "extensions", key = "max_job_attempts", conf_key = "extension_max_job_attempts", kind = "integer", min = 1, default = 5, desc = "Max retry attempts for background after-hook extension jobs"},
}
config.CONFIG_SCHEMA = CONFIG_SCHEMA

-- Build lookup indexes once at load time.
const SCHEMA_BY_SECTION = {}
const SECTION_SET = {}
const FLAT_KEY_HINTS = {}
for _, sec in ipairs(CONFIG_SECTIONS) do
    SCHEMA_BY_SECTION[sec] = {}
    SECTION_SET[sec] = true
end
for _, spec in ipairs(CONFIG_SCHEMA) do
    SCHEMA_BY_SECTION[spec.section][spec.key] = spec
    if spec.conf_key != nil then
        FLAT_KEY_HINTS[spec.conf_key] = spec.section .. "." .. spec.key
    end
    if spec.setting_key != nil then
        FLAT_KEY_HINTS[spec.setting_key] = spec.section .. "." .. spec.key
    end
    if FLAT_KEY_HINTS[spec.key] == nil then
        FLAT_KEY_HINTS[spec.key] = spec.section .. "." .. spec.key
    end
end

function edit_distance(a, b)
    la = string.len(a)
    lb = string.len(b)
    prev = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        curr = {[0] = i}
        ca = string.byte(a, i)
        for j = 1, lb do
            cost = 1
            if ca == string.byte(b, j) then
                cost = 0
            end
            ins = curr[j - 1] + 1
            del = prev[j] + 1
            sub = prev[j - 1] + cost
            curr[j] = math.min(ins, math.min(del, sub))
        end
        prev = curr
    end
    return prev[lb]
end

function closest_match(target, candidates)
    best = nil
    best_dist = 4
    lower_target = string.lower(tostring(target))
    for _, cand in ipairs(candidates) do
        d = edit_distance(lower_target, string.lower(cand))
        if d < best_dist then
            best_dist = d
            best = cand
        end
    end
    return best
end

function secret_env_hint(key_path)
    lower = string.lower(key_path)
    if string.find(lower, "mariadb", 1, true) != nil or string.find(lower, "database%.", 1, false) != nil or string.find(lower, "db_", 1, true) != nil then
        return "DAAT_MARIADB_PASSWORD"
    end
    if string.find(lower, "smtp", 1, true) != nil or string.find(lower, "mail%.", 1, false) != nil then
        return "DAAT_SMTP_PASSWORD"
    end
    if string.find(lower, "graph", 1, true) != nil then
        return "DAAT_GRAPH_CLIENT_SECRET"
    end
    if string.find(lower, "anthropic", 1, true) != nil or string.find(lower, "claude", 1, true) != nil then
        return "ANTHROPIC_API_KEY"
    end
    if string.find(lower, "ollama", 1, true) != nil or string.find(lower, "openai", 1, true) != nil then
        return "OLLAMA_API_KEY or OPENAI_API_KEY"
    end
    if string.find(lower, "google", 1, true) != nil or string.find(lower, "search", 1, true) != nil then
        return "GOOGLE_SEARCH_API_KEY"
    end
    return "an environment variable"
end

function is_secret_key_name(key)
    lower = string.lower(tostring(key))
    if string.find(lower, "password", 1, true) != nil then return true end
    if string.find(lower, "passwd", 1, true) != nil then return true end
    if string.find(lower, "secret", 1, true) != nil then return true end
    if string.find(lower, "api_key", 1, true) != nil then return true end
    if string.find(lower, "apikey", 1, true) != nil then return true end
    if string.find(lower, "private_key", 1, true) != nil then return true end
    return false
end

function scan_for_secret_keys(tbl, prefix, file_label, errors)
    if type(tbl) != "table" then
        return
    end
    keys = {}
    for k, _ in pairs(tbl) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        path_label = k
        if prefix != "" then
            path_label = prefix .. "." .. k
        end
        if is_secret_key_name(k) then
            table.insert(errors, string.format(
                "%s: '%s' looks like a secret -- never put secrets in %s; set %s in the environment instead",
                file_label, path_label, file_label, secret_env_hint(path_label)
            ))
        elseif type(tbl[k]) == "table" then
            scan_for_secret_keys(tbl[k], path_label, file_label, errors)
        end
    end
end

function config.reset_cache()
    CONFIG_CACHE = nil
    SETTINGS_CACHE = {}
end

function config.find_root()
    root = os.getenv("DOCUMENT_ROOT")
    if root != nil and root != "" then
        return string.gsub(root, "\\", "/")
    end
    return "."
end

function config.store_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, STORE_DIR)
end

function config.db_backend(root)
    return config.load(root).db_backend
end

function config.mariadb_descriptor(root)
    conf = config.load(root)
    password = os.getenv("DAAT_MARIADB_PASSWORD")
    if password == nil then
        password = ""
    end
    return {
        host = conf.mariadb_host,
        port = conf.mariadb_port,
        user = conf.mariadb_user,
        password = password,
        database = conf.mariadb_database,
    }
end

function config.db_path(root)
    if config.db_backend(root) == "mariadb" then
        return config.mariadb_descriptor(root)
    end
    return paths.joinpath(config.store_dir(root), DB_FILE)
end

function config.schemas_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "schemas")
end

function config.extensions_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "extensions")
end

function config.views_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "views")
end

function config.templates_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "templates")
end

function config.dropdowns_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "dropdowns")
end

function config.session_secret_path(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(config.store_dir(root), SESSION_SECRET_FILE)
end

function config.is_initialized(root)
    if config.db_backend(root) == "mariadb" then
        descriptor = config.mariadb_descriptor(root)
        ok_init, exists_init = pcall(db_lib.table_exists, descriptor, "entity_event")
        return ok_init == true and exists_init == true
    end
    return paths.file_exists(config.db_path(root))
end

function config.theme_path(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, THEME_FILE)
end

function config.theme_assets_dir(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, "theme-assets")
end

function config.vendor_assets_dir()
    dir = os.getenv("DAAT_VENDOR_DIR")
    if dir != nil and dir != "" then
        return dir
    end
    return "./vnd"
end

function config.config_path(root)
    if root == nil then root = config.find_root() end
    return paths.joinpath(root, CONFIG_FILE)
end

function valid_retention_days(value)
    if value == "forever" then
        return "forever"
    end
    if type(value) == "number" and value >= 0 then
        return value
    end
    return nil
end

-- Accepts either structured agent section keys (`retention`,
-- `retention_override`, `model_input_days`, `transcript_documents`) or
-- unit-test tables passing `agent_retention` / `agent_retention_override`.
function config.resolve_retention(parsed)
    strategy = "standard"
    if type(parsed) == "table" then
        raw_strat = parsed.retention
        if raw_strat == nil then
            raw_strat = parsed.agent_retention
        end
        if RETENTION_STRATEGIES[raw_strat] != nil then
            strategy = raw_strat
        end
    end
    base = RETENTION_STRATEGIES[strategy]
    policy = {
        strategy = strategy,
        knowledge_days = base.knowledge_days,
        tool_trace_days = base.tool_trace_days,
        model_input_days = base.model_input_days,
        metrics_days = base.metrics_days,
        transcript_documents = base.transcript_documents,
    }
    if type(parsed) != "table" then
        return policy
    end
    mi_days = valid_retention_days(parsed.model_input_days)
    if mi_days != nil then
        policy.model_input_days = mi_days
    end
    raw_td = parsed.transcript_documents
    if raw_td == nil then
        raw_td = parsed.agent_transcript_documents
    end
    if raw_td == "off" or raw_td == "whole" then
        policy.transcript_documents = raw_td
    end
    overrides = parsed.retention_override
    if overrides == nil then
        overrides = parsed.agent_retention_override
    end
    if type(overrides) == "table" then
        for _, key in ipairs({"knowledge_days", "tool_trace_days", "model_input_days", "metrics_days"}) do
            ov = valid_retention_days(overrides[key])
            if ov != nil then
                policy[key] = ov
            end
        end
        if overrides.transcript_documents == "off" or overrides.transcript_documents == "whole" then
            policy.transcript_documents = overrides.transcript_documents
        end
    end
    return policy
end

function apply_retention(conf, policy)
    conf.agent_retention = policy.strategy
    conf.retention = policy
    conf.knowledge_days = policy.knowledge_days
    conf.tool_trace_days = policy.tool_trace_days
    conf.model_input_days = policy.model_input_days
    conf.metrics_days = policy.metrics_days
    conf.agent_transcript_documents = policy.transcript_documents
end

function config.resolve_masking(raw)
    resolved = {
        chat = DEFAULT_MASKING.chat,
        research = DEFAULT_MASKING.research,
        background = DEFAULT_MASKING.background,
    }
    if raw == true or raw == false then
        resolved.chat = raw
        resolved.research = raw
        resolved.background = raw
        return resolved
    end
    if type(raw) == "table" then
        for _, loop_kind in ipairs({"chat", "research", "background"}) do
            if raw[loop_kind] == true or raw[loop_kind] == false then
                resolved[loop_kind] = raw[loop_kind]
            end
        end
    end
    return resolved
end

function build_default_conf()
    conf = {}
    for _, spec in ipairs(CONFIG_SCHEMA) do
        if spec.conf_key != nil and spec.default != nil then
            conf[spec.conf_key] = spec.default
        end
    end
    conf.agent_masking = config.resolve_masking(nil)
    apply_retention(conf, config.resolve_retention(nil))
    return conf
end

function enum_contains(list, val)
    for _, item in ipairs(list) do
        if item == val then
            return true
        end
    end
    return false
end

function validate_field_value(spec, raw, path_label, errors, warnings)
    kind = spec.kind
    if kind == "string" then
        if type(raw) != "string" or raw == "" then
            table.insert(errors, string.format("config.lua: '%s' must be a non-empty string (got %s)", path_label, type(raw)))
            return nil, false
        end
        return raw, true
    end
    if kind == "enum" then
        if type(raw) != "string" or not enum_contains(spec.enum, raw) then
            table.insert(errors, string.format("config.lua: '%s' must be one of {%s} (got %s)",
                path_label, table.concat(spec.enum, ", "), tostring(raw)))
            return nil, false
        end
        return raw, true
    end
    if kind == "boolean" then
        if raw != true and raw != false then
            table.insert(errors, string.format("config.lua: '%s' must be true or false (got %s)", path_label, type(raw)))
            return nil, false
        end
        return raw, true
    end
    if kind == "number" or kind == "integer" then
        if type(raw) != "number" then
            table.insert(errors, string.format("config.lua: '%s' must be a number (got %s)", path_label, type(raw)))
            return nil, false
        end
        if spec.gt != nil and not (raw > spec.gt) then
            table.insert(errors, string.format("config.lua: '%s' must be > %s (got %s)", path_label, tostring(spec.gt), tostring(raw)))
            return nil, false
        end
        if spec.min != nil and raw < spec.min then
            table.insert(errors, string.format("config.lua: '%s' must be >= %s (got %s)", path_label, tostring(spec.min), tostring(raw)))
            return nil, false
        end
        if kind == "integer" then
            return math.floor(raw), true
        end
        return raw, true
    end
    if kind == "number_or_false" then
        if raw == false then
            return nil, true
        end
        if type(raw) == "number" then
            return raw, true
        end
        table.insert(errors, string.format("config.lua: '%s' must be a number or false (got %s)", path_label, type(raw)))
        return nil, false
    end
    if kind == "string_list" then
        if type(raw) != "table" then
            table.insert(errors, string.format("config.lua: '%s' must be a list of strings (got %s)", path_label, type(raw)))
            return nil, false
        end
        out = {}
        for idx, item in ipairs(raw) do
            if type(item) == "string" and item != "" then
                table.insert(out, item)
            else
                table.insert(warnings, string.format("config.lua: '%s[%d]' ignored (expected non-empty string, got %s)", path_label, idx, type(item)))
            end
        end
        if spec.key == "duplicate_external_prefixes" and #out == 0 then
            return nil, true
        end
        return out, true
    end
    if kind == "pattern_list" then
        if type(raw) != "table" then
            table.insert(errors, string.format("config.lua: '%s' must be a list of Lua patterns (got %s)", path_label, type(raw)))
            return nil, false
        end
        out = {}
        for idx, pattern in ipairs(raw) do
            if type(pattern) == "string" and pattern != "" then
                ok_pat, pat_err = pcall(string.find, "", pattern)
                if ok_pat then
                    table.insert(out, pattern)
                else
                    table.insert(warnings, string.format("config.lua: '%s[%d]' invalid Lua pattern '%s' (%s)", path_label, idx, pattern, tostring(pat_err)))
                end
            else
                table.insert(warnings, string.format("config.lua: '%s[%d]' ignored (expected pattern string, got %s)", path_label, idx, type(pattern)))
            end
        end
        return out, true
    end
    if kind == "alias_list" then
        if type(raw) != "table" then
            table.insert(errors, string.format("config.lua: '%s' must be a list of {pattern, replacement} pairs (got %s)", path_label, type(raw)))
            return nil, false
        end
        out = {}
        for idx, pair in ipairs(raw) do
            if type(pair) == "table" and type(pair[1]) == "string" and pair[1] != "" and type(pair[2]) == "string" then
                ok_pat, pat_err = pcall(string.find, "", pair[1])
                if ok_pat then
                    table.insert(out, {pair[1], pair[2]})
                else
                    table.insert(warnings, string.format("config.lua: '%s[%d]' invalid Lua pattern '%s' (%s)", path_label, idx, pair[1], tostring(pat_err)))
                end
            else
                table.insert(warnings, string.format("config.lua: '%s[%d]' ignored (expected {pattern, replacement})", path_label, idx))
            end
        end
        return out, true
    end
    if kind == "masking" then
        if raw != true and raw != false and type(raw) != "table" then
            table.insert(errors, string.format("config.lua: '%s' must be a boolean or {chat, research, background} table (got %s)", path_label, type(raw)))
            return nil, false
        end
        if type(raw) == "table" then
            allowed_mask = {chat = true, research = true, background = true}
            for k, v in pairs(raw) do
                if allowed_mask[k] == nil then
                    table.insert(errors, string.format("config.lua: unknown key '%s.%s' (allowed: chat, research, background)", path_label, tostring(k)))
                elseif v != true and v != false then
                    table.insert(errors, string.format("config.lua: '%s.%s' must be true or false", path_label, tostring(k)))
                end
            end
        end
        return config.resolve_masking(raw), true
    end
    if kind == "retention_days" then
        days = valid_retention_days(raw)
        if days == nil then
            table.insert(errors, string.format("config.lua: '%s' must be a number >= 0 or 'forever' (got %s)", path_label, tostring(raw)))
            return nil, false
        end
        return days, true
    end
    if kind == "retention_override" then
        if type(raw) != "table" then
            table.insert(errors, string.format("config.lua: '%s' must be a table (got %s)", path_label, type(raw)))
            return nil, false
        end
        allowed_ov = {
            knowledge_days = true,
            tool_trace_days = true,
            model_input_days = true,
            metrics_days = true,
            transcript_documents = true,
        }
        for k, v in pairs(raw) do
            if allowed_ov[k] == nil then
                table.insert(errors, string.format("config.lua: unknown key '%s.%s'", path_label, tostring(k)))
            elseif k == "transcript_documents" then
                if v != "off" and v != "whole" then
                    table.insert(errors, string.format("config.lua: '%s.transcript_documents' must be 'off' or 'whole'", path_label))
                end
            elseif valid_retention_days(v) == nil then
                table.insert(errors, string.format("config.lua: '%s.%s' must be a number >= 0 or 'forever'", path_label, tostring(k)))
            end
        end
        return raw, true
    end
    return raw, true
end

function validate_theme_file(root, errors, warnings)
    theme_path = config.theme_path(root)
    file = io.open(theme_path, "r")
    if file == nil then
        return false
    end
    contents = io.read(file, "*all")
    io.close(file)

    ok, parsed = sandbox.run(contents, theme_path, sandbox.data_env())
    if ok == false then
        table.insert(errors, "theme.lua: syntax/evaluation error: " .. tostring(parsed))
        return true
    end
    if parsed == nil then
        return true
    end
    if type(parsed) != "table" then
        table.insert(errors, "theme.lua: must return a table (got " .. type(parsed) .. ")")
        return true
    end

    scan_for_secret_keys(parsed, "", "theme.lua", errors)

    top_candidates = {"site_name", "has_logo", "hide_home_heading", "system_prompt_extra", "colors"}
    for k, v in pairs(parsed) do
        expected = THEME_TOP_KEYS[k]
        if expected == nil then
            hint = closest_match(tostring(k), top_candidates)
            suffix = ""
            if hint != nil then
                suffix = " (did you mean '" .. hint .. "'?)"
            end
            table.insert(errors, "theme.lua: unknown key '" .. tostring(k) .. "'" .. suffix)
        elseif expected == "boolean" and v != true and v != false then
            table.insert(errors, "theme.lua: '" .. tostring(k) .. "' must be true or false (got " .. type(v) .. ")")
        elseif expected == "string" and type(v) != "string" then
            table.insert(errors, "theme.lua: '" .. tostring(k) .. "' must be a string (got " .. type(v) .. ")")
        elseif expected == "table" and type(v) != "table" then
            table.insert(errors, "theme.lua: '" .. tostring(k) .. "' must be a table (got " .. type(v) .. ")")
        end
    end

    if type(parsed.colors) == "table" then
        valid_color = {}
        for _, ck in ipairs(THEME_COLOR_KEYS) do
            valid_color[ck] = true
        end
        for ck, cv in pairs(parsed.colors) do
            if valid_color[ck] == nil then
                hint = closest_match(tostring(ck), THEME_COLOR_KEYS)
                suffix = ""
                if hint != nil then
                    suffix = " (did you mean '" .. hint .. "'?)"
                end
                table.insert(errors, "theme.lua: unknown color key 'colors." .. tostring(ck) .. "'" .. suffix)
            elseif type(cv) != "string" then
                table.insert(errors, "theme.lua: 'colors." .. tostring(ck) .. "' must be a CSS color string")
            elseif cv != "" and string.match(cv, "^#[0-9a-fA-F]+$") == nil and string.match(cv, "^rgba?%([0-9,%s%.%%]+%)$") == nil and string.match(cv, "^hsla?%([0-9,%s%.%%deg]+%)$") == nil then
                table.insert(warnings, "theme.lua: 'colors." .. tostring(ck) .. "' ('" .. cv .. "') does not look like a hex/rgb/hsl color")
            end
        end
    end

    return true
end

-- Validates `config.lua` and `theme.lua` at `root` and resolves the
-- effective configuration, per-field sources ("config.lua" or "default"),
-- and provider settings.
function config.validate(root)
    if root == nil then
        root = config.find_root()
    end
    errors = {}
    warnings = {}
    conf = build_default_conf()
    settings = {}
    sources = {}
    for _, spec in ipairs(CONFIG_SCHEMA) do
        sources[spec.section .. "." .. spec.key] = "default"
    end

    cfg_path = config.config_path(root)
    cfg_exists = false
    file = io.open(cfg_path, "r")
    if file != nil then
        cfg_exists = true
        contents = io.read(file, "*all")
        io.close(file)

        ok, parsed = sandbox.run(contents, cfg_path, sandbox.data_env())
        if ok == false then
            table.insert(errors, "config.lua: syntax/evaluation error: " .. tostring(parsed))
        elseif parsed != nil and type(parsed) != "table" then
            table.insert(errors, "config.lua: must return a table (got " .. type(parsed) .. ")")
        elseif type(parsed) == "table" then
            scan_for_secret_keys(parsed, "", "config.lua", errors)

            top_keys = {}
            for k, _ in pairs(parsed) do
                table.insert(top_keys, tostring(k))
            end
            table.sort(top_keys)
            for _, k in ipairs(top_keys) do
                if not is_secret_key_name(k) then
                    if SECTION_SET[k] == nil then
                        if FLAT_KEY_HINTS[k] != nil then
                            table.insert(errors, string.format(
                                "config.lua: flat top-level key '%s' is not supported; move it under '%s'",
                                k, FLAT_KEY_HINTS[k]
                            ))
                        else
                            hint = closest_match(k, CONFIG_SECTIONS)
                            suffix = ""
                            if hint != nil then
                                suffix = " (did you mean section '" .. hint .. "'?)"
                            end
                            table.insert(errors, "config.lua: unknown top-level section '" .. k .. "'" .. suffix)
                        end
                    elseif type(parsed[k]) != "table" then
                        table.insert(errors, string.format("config.lua: section '%s' must be a table (got %s)", k, type(parsed[k])))
                    end
                end
            end

            for _, sec in ipairs(CONFIG_SECTIONS) do
                sec_tbl = parsed[sec]
                if type(sec_tbl) == "table" then
                    sec_schema = SCHEMA_BY_SECTION[sec]
                    sec_candidates = {}
                    for sk, _ in pairs(sec_schema) do
                        table.insert(sec_candidates, sk)
                    end
                    table.sort(sec_candidates)

                    written_keys = {}
                    for wk, _ in pairs(sec_tbl) do
                        table.insert(written_keys, tostring(wk))
                    end
                    table.sort(written_keys)
                    for _, wk in ipairs(written_keys) do
                        if not is_secret_key_name(wk) and sec_schema[wk] == nil then
                            hint = closest_match(wk, sec_candidates)
                            suffix = ""
                            if hint != nil then
                                suffix = " (did you mean '" .. sec .. "." .. hint .. "'?)"
                            elseif FLAT_KEY_HINTS[wk] != nil then
                                suffix = " (belongs at '" .. FLAT_KEY_HINTS[wk] .. "')"
                            end
                            table.insert(errors, string.format("config.lua: unknown key '%s.%s'%s", sec, wk, suffix))
                        end
                    end

                    for _, spec in ipairs(CONFIG_SCHEMA) do
                        if spec.section == sec and sec_tbl[spec.key] != nil then
                            path_label = sec .. "." .. spec.key
                            val, valid = validate_field_value(spec, sec_tbl[spec.key], path_label, errors, warnings)
                            if valid then
                                sources[path_label] = "config.lua"
                                if spec.conf_key != nil and spec.key != "retention" and spec.key != "retention_override" and spec.key != "model_input_days" and spec.key != "transcript_documents" then
                                    conf[spec.conf_key] = val
                                end
                                if spec.setting_key != nil then
                                    settings[spec.setting_key] = val
                                end
                            end
                        end
                    end
                end
            end

            if type(parsed.agent) == "table" then
                valid_agent_retention = {}
                if RETENTION_STRATEGIES[parsed.agent.retention] != nil then
                    valid_agent_retention.retention = parsed.agent.retention
                end
                if type(parsed.agent.retention_override) == "table" then
                    valid_agent_retention.retention_override = parsed.agent.retention_override
                end
                if valid_retention_days(parsed.agent.model_input_days) != nil then
                    valid_agent_retention.model_input_days = parsed.agent.model_input_days
                end
                if parsed.agent.transcript_documents == "off" or parsed.agent.transcript_documents == "whole" then
                    valid_agent_retention.transcript_documents = parsed.agent.transcript_documents
                end
                apply_retention(conf, config.resolve_retention(valid_agent_retention))
            end

            -- Cross-field completeness checks.
            if conf.db_backend == "mariadb" then
                if conf.mariadb_user == nil or conf.mariadb_database == nil then
                    table.insert(errors, "config.lua: database.backend is 'mariadb' but database.user or database.database is missing")
                end
            end
            if conf.mail_provider != nil and (conf.mail_from == nil or conf.public_url == nil) then
                table.insert(warnings, "config.lua: mail.provider is set, but mail.from or mail.public_url is missing (password reset remains disabled until all three are set)")
            elseif conf.mail_provider == nil and conf.mail_from != nil then
                table.insert(warnings, "config.lua: mail.from is set without mail.provider (outbound mail remains disabled)")
            end
            if conf.agent_provider == "vertex" and settings.vertex_project == nil then
                table.insert(warnings, "config.lua: agent.provider is 'vertex' but agent.vertex_project is not set")
            end
            if conf.mail_provider == "smtp" and settings.smtp_url == nil then
                table.insert(warnings, "config.lua: mail.provider is 'smtp' but mail.smtp_url is not set")
            end
            if conf.mail_provider == "graph" and (settings.graph_tenant_id == nil or settings.graph_client_id == nil) then
                table.insert(warnings, "config.lua: mail.provider is 'graph' but mail.graph_tenant_id or mail.graph_client_id is not set")
            end
        end
    end

    theme_exists = validate_theme_file(root, errors, warnings)

    return {
        ok = (#errors == 0),
        config_exists = cfg_exists,
        config_path = cfg_path,
        theme_exists = theme_exists,
        theme_path = config.theme_path(root),
        errors = errors,
        warnings = warnings,
        resolved = conf,
        settings = settings,
        sources = sources,
    }
end

function config.load(root)
    if root == nil and CONFIG_CACHE != nil then
        return CONFIG_CACHE
    end

    report = config.validate(root)
    for _, err_msg in ipairs(report.errors) do
        if string.find(err_msg, "syntax/evaluation error", 1, true) != nil or string.find(err_msg, "looks like a secret", 1, true) != nil then
            io.write(io.stderr, "Warning: " .. err_msg .. "\n")
        end
    end

    if root == nil then
        SETTINGS_CACHE = report.settings
        CONFIG_CACHE = report.resolved
    end
    return report.resolved
end

function config.setting(key)
    config.load()
    value = SETTINGS_CACHE[key]
    if value == "" then
        return nil
    end
    return value
end

function config.password_reset_enabled(root)
    conf = config.load(root)
    return conf.mail_provider != nil and conf.mail_from != nil and conf.public_url != nil
end

function config.load_theme(root)
    theme = {site_name = "Daat", colors = {}, has_logo = false, hide_home_heading = false, system_prompt_extra = nil}
    path = config.theme_path(root)
    file = io.open(path, "r")
    if file == nil then
        return theme
    end
    contents = io.read(file, "*all")
    io.close(file)

    ok, parsed = sandbox.run(contents, path, sandbox.data_env())
    if ok == false then
        io.write(io.stderr, "Warning: theme.lua: syntax/evaluation error: " .. tostring(parsed) .. "\n")
        return theme
    end
    if type(parsed) != "table" then
        return theme
    end

    if type(parsed.site_name) == "string" and parsed.site_name != "" then
        theme.site_name = parsed.site_name
    end
    if parsed.has_logo == true then
        theme.has_logo = true
    end
    if parsed.hide_home_heading == true then
        theme.hide_home_heading = true
    end
    if type(parsed.system_prompt_extra) == "string" and parsed.system_prompt_extra != "" then
        theme.system_prompt_extra = parsed.system_prompt_extra
    end
    if type(parsed.colors) == "table" then
        for _, key in ipairs(THEME_COLOR_KEYS) do
            value = parsed.colors[key]
            if type(value) == "string" and value != "" then
                theme.colors[key] = value
            end
        end
    end
    return theme
end

function lua_string_literal(s)
    escaped = string.gsub(s, "\\", "\\\\")
    escaped = string.gsub(escaped, "\"", "\\\"")
    escaped = string.gsub(escaped, "\n", "\\n")
    escaped = string.gsub(escaped, "\r", "\\r")
    return "\"" .. escaped .. "\""
end

function config.save_theme(root, theme)
    lines = {"return {"}
    if theme.site_name != nil and theme.site_name != "" and theme.site_name != "Daat" then
        table.insert(lines, "    site_name = " .. lua_string_literal(theme.site_name) .. ",")
    end
    if theme.has_logo == true then
        table.insert(lines, "    has_logo = true,")
    end
    if theme.hide_home_heading == true then
        table.insert(lines, "    hide_home_heading = true,")
    end
    if theme.system_prompt_extra != nil and theme.system_prompt_extra != "" then
        table.insert(lines, "    system_prompt_extra = " .. lua_string_literal(theme.system_prompt_extra) .. ",")
    end

    color_lines = {}
    if theme.colors != nil then
        for _, key in ipairs(THEME_COLOR_KEYS) do
            value = theme.colors[key]
            if type(value) == "string" and value != "" then
                table.insert(color_lines, "        " .. key .. " = " .. lua_string_literal(value) .. ",")
            end
        end
    end
    table.insert(lines, "    colors = {")
    for _, color_line in ipairs(color_lines) do
        table.insert(lines, color_line)
    end
    table.insert(lines, "    },")
    table.insert(lines, "}")

    path = config.theme_path(root)
    file, err = io.open(path, "w")
    if file == nil then
        return nil, err
    end
    io.write(file, table.concat(lines, "\n") .. "\n")
    io.close(file)
    return true
end

function resolved_value_for_spec(report, spec)
    if spec.setting_key != nil then
        return report.settings[spec.setting_key]
    end
    if spec.key == "retention_override" then
        return report.resolved.retention
    end
    return report.resolved[spec.conf_key]
end

function format_display_value(val)
    if val == nil then
        return "nil"
    end
    if type(val) == "string" then
        return lua_string_literal(val)
    end
    if val == true or val == false or type(val) == "number" then
        return tostring(val)
    end
    if type(val) == "table" then
        return json.encode(val)
    end
    return tostring(val)
end

function has_flag(cmd_args, flag)
    for _, a in ipairs(cmd_args) do
        if a == flag then
            return true
        end
    end
    return false
end

function config.do_config(cmd_args, root)
    if root == nil then
        root = "."
    end
    sub = cmd_args[1]
    as_json = has_flag(cmd_args, "--json")

    if sub == "check" then
        report = config.validate(root)
        if as_json then
            print(json.encode({
                ok = report.ok,
                config_exists = report.config_exists,
                theme_exists = report.theme_exists,
                errors = report.errors,
                warnings = report.warnings,
            }))
        else
            cfg_state = "absent (using defaults)"
            if report.config_exists then
                cfg_state = "present"
            end
            theme_state = "absent (using defaults)"
            if report.theme_exists then
                theme_state = "present"
            end
            print("config.lua: " .. cfg_state)
            print("theme.lua:  " .. theme_state)
            for _, w in ipairs(report.warnings) do
                print("WARNING: " .. w)
            end
            for _, e in ipairs(report.errors) do
                print("ERROR:   " .. e)
            end
            if report.ok then
                print(string.format("OK (%d warning(s))", #report.warnings))
            else
                print(string.format("FAILED (%d error(s), %d warning(s))", #report.errors, #report.warnings))
            end
        end
        if report.ok then
            return 0
        end
        return 1
    end

    if sub == "show" then
        report = config.validate(root)
        theme = config.load_theme(root)
        if as_json then
            sections_out = {}
            for _, sec in ipairs(CONFIG_SECTIONS) do
                sections_out[sec] = {}
            end
            for _, spec in ipairs(CONFIG_SCHEMA) do
                path_label = spec.section .. "." .. spec.key
                sections_out[spec.section][spec.key] = {
                    value = resolved_value_for_spec(report, spec),
                    source = report.sources[path_label],
                    description = spec.desc,
                }
            end
            print(json.encode({
                ok = report.ok,
                config_exists = report.config_exists,
                theme_exists = report.theme_exists,
                sections = sections_out,
                theme = {
                    site_name = theme.site_name,
                    has_logo = theme.has_logo,
                    hide_home_heading = theme.hide_home_heading,
                    has_system_prompt_extra = (theme.system_prompt_extra != nil and theme.system_prompt_extra != ""),
                    colors = theme.colors,
                },
                errors = report.errors,
                warnings = report.warnings,
            }))
            return 0
        end

        for _, sec in ipairs(CONFIG_SECTIONS) do
            print("[" .. sec .. "]")
            for _, spec in ipairs(CONFIG_SCHEMA) do
                if spec.section == sec then
                    path_label = sec .. "." .. spec.key
                    val_str = format_display_value(resolved_value_for_spec(report, spec))
                    src_tag = report.sources[path_label]
                    print(string.format("  %-32s = %-28s (%s)", spec.key, val_str, src_tag))
                end
            end
            print("")
        end
        print("[theme]")
        print(string.format("  %-32s = %s", "site_name", format_display_value(theme.site_name)))
        print(string.format("  %-32s = %s", "has_logo", tostring(theme.has_logo)))
        print(string.format("  %-32s = %s", "hide_home_heading", tostring(theme.hide_home_heading)))
        for _, w in ipairs(report.warnings) do
            print("WARNING: " .. w)
        end
        for _, e in ipairs(report.errors) do
            print("ERROR:   " .. e)
        end
        return 0
    end

    print("Usage: daat config <show|check> [--json]")
    if sub == "-h" or sub == "--help" then
        return 0
    end
    return 1
end

return config
