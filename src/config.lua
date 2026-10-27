-- Resolves the store location: a `.store/` directory holding the
-- ledger database, alongside `schemas/`/`extensions/`/`views/`/
-- `templates/` directories. `DOCUMENT_ROOT` (a standard CGI env var
-- most web servers set natively) is the CGI-mode signal for where that
-- root is; CLI mode just uses the current directory.

paths = require("paths")
sandbox = require("sandbox")

config = {}

STORE_DIR = ".store"
DB_FILE = "store.db"
SESSION_SECRET_FILE = "session_secret"
-- theme.lua/platform.lua, not .json -- one config format across the
-- whole platform (schemas/dropdowns/views/templates/extension
-- manifests are all the same sandboxed-Lua-table convention already;
-- see doc/schema.md). Loaded via sandbox.run(source, path,
-- sandbox.data_env()) exactly like those -- a data-only sandbox (no
-- io/os/require/loadstring/network, just pairs/ipairs/string/table/
-- math, see sandbox.lua's own header), not "arbitrary code execution":
-- the only thing a loaded file can do is construct and return a table,
-- which still goes through the same field-by-field validation below
-- either way.
THEME_FILE = "theme.lua"
PLATFORM_CONFIG_FILE = "platform.lua"
PLATFORM_CONFIG_CACHE = nil
-- platform.lua's table as written, for config.setting.
PLATFORM_SETTINGS_CACHE = {}

-- The CSS custom-property names a theme.lua may override -- matches
-- html.lua's own var(--platform-*, <fallback>) usage sites exactly, so a
-- deployment can only override colors/tokens the app already exposes
-- as a hook, never introduce a new one by typo.
-- tier_0..tier_3: the Knowledge Pool's ordinal tier ramp (Raw Intake ->
-- Atomic Record) -- one hue, monotone lightness, light->dark as
-- maturity rises. Validated against dataviz's ordinal-ramp checks
-- (monotone L, adjacent ΔL >= 0.06, light-end contrast >= 2:1 on the
-- default surface, single hue) -- see html.theme_root_css's own
-- fallback defaults for the values, and doc/knowledge-graph-explorer.md
-- for the second place this ramp is meant to be reused (node color).
THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
    "tier_0", "tier_1", "tier_2", "tier_3",
}

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

-- "sqlite" (default) or "mariadb" -- see doc/mariadb-migration.md.
-- Sourced from platform.lua (config.platform_config()) now, not a raw
-- env var directly -- see that function's own header for why.
function config.db_backend()
    return config.platform_config().db_backend
end

-- Connection descriptor for the mariadb backend. host/port/user/
-- database come from platform.lua -- real, version-controlled
-- deployment content, not secrets. The password is the one field here
-- that stays a plain env var (PLATFORM_MARIADB_PASSWORD, never written
-- to a file this repo tracks) -- see config.platform_config()'s header.
function config.mariadb_descriptor()
    conf = config.platform_config()
    password = os.getenv("PLATFORM_MARIADB_PASSWORD")
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

-- Returns whatever database.lua's db_path parameter expects for the
-- active backend: a SQLite file path (a string) or a MariaDB
-- connection descriptor (a table) -- opaque to every caller either
-- way, only database.lua itself ever inspects the shape (see that
-- file's own header comment).
function config.db_path(root)
    if config.db_backend() == "mariadb" then
        return config.mariadb_descriptor()
    end
    return paths.joinpath(config.store_dir(root), DB_FILE)
end

function config.schemas_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "schemas")
end

function config.extensions_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "extensions")
end

function config.views_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "views")
end

function config.templates_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "templates")
end

-- Named, reusable value lists a select/multi_select field can reference
-- (`dropdown = "work_process"`) instead of inlining its own `values`
-- list -- so several fields (or several entity types) can share one
-- list and a single edit updates every field referencing it.
function config.dropdowns_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "dropdowns")
end

-- One file per entity type, each a `view`-shaped SQL query (see
-- src/label.lua) plus a `zpl` template string. Lazily looked up by
-- entity_type on /detail and /label, not eagerly scanned at boot the
-- way dropdowns/schemas are -- nothing else references a label
-- template the way a schema field references a dropdown.
function config.label_templates_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "label_templates")
end

function config.session_secret_path(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(config.store_dir(root), SESSION_SECRET_FILE)
end

-- "Initialized" means `daat init` has already created the schema --
-- for sqlite that's a file-exists check; for mariadb there's no file to
-- check, so this looks for entity_event (ledger.lua's own core table,
-- always created first during init) existing in the target database
-- instead. Requires "database_adapter" (the raw per-backend bindings
-- one layer below "database") directly rather than requiring
-- "database" -- "database" already requires config for nothing today
-- and never should (see its own header comment on why dispatch is by
-- db_path's shape, not a config lookup), so this file must not create
-- that cycle from the other direction either.
function config.is_initialized(root)
    if config.db_backend() == "mariadb" then
        database = require("database_adapter")
        descriptor = config.mariadb_descriptor()
        ok, rows = pcall(database.mariadb_query, descriptor,
            "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'entity_event';")
        return ok == true and rows != nil
    end
    return paths.file_exists(config.db_path(root))
end

function config.theme_path(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, THEME_FILE)
end

-- Optional binary assets (favicon/logo) a deployment's theme.lua can
-- reference -- same "generic hook, real files seeded by whoever wants
-- them" split as theme.lua itself.
function config.theme_assets_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "theme-assets")
end

-- Vendored third-party assets platform itself ships (e.g. the Toast UI
-- Editor bundle) -- unlike theme_assets_dir, this is NOT
-- DOCUMENT_ROOT-relative: these files belong to the daat
-- checkout/build, not a deployment's own data. PLATFORM_VENDOR_DIR
-- lets a real deployment point at wherever it actually copied
-- vnd/ to (e.g. /app/vnd in the Celleste Docker image); unset
-- defaults to "./vnd", which matches running from a plain repo
-- checkout (CLI/dev usage, tests).
function config.vendor_assets_dir()
    dir = os.getenv("PLATFORM_VENDOR_DIR")
    if dir != nil and dir != "" then
        return dir
    end
    return "./vnd"
end

function config.platform_config_path(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, PLATFORM_CONFIG_FILE)
end

-- Every deployment-tunable setting that ISN'T a secret: which
-- agent_provider/agent_model to call, the chat agent's own turn/row/
-- retry budgets (doc/architecture.md's own table), and the MariaDB
-- connection's host/port/user/database. All of it is real,
-- version-controlled deployment content -- meant to be committed
-- (see lims/platform.lua, seeded into the image/store exactly like
-- theme.lua already is), not something only an operator's shell
-- environment happens to know. The one field in this whole area that
-- IS a secret, the MariaDB password, deliberately stays out of this
-- file and out of version control entirely -- see
-- config.mariadb_descriptor's own PLATFORM_MARIADB_PASSWORD env var
-- read.
--
-- nav_order/nav_hidden's own shared validation: a plain list of
-- non-empty strings, everything else dropped silently (matching this
-- whole function's own "malformed input falls back, never errors"
-- contract) -- an unrecognized key is html.lua's own concern to treat
-- as a no-op, not this function's; there's no fixed key vocabulary to
-- check against here since extension-contributed keys ("ext:<name>")
-- are only known at render time, per deployment.
function validate_nav_key_list(raw)
    keys = {}
    for _, value in ipairs(raw) do
        if type(value) == "string" and value != "" then
            table.insert(keys, value)
        end
    end
    return keys
end

-- Same generic-hook contract as load_theme below: absent or malformed
-- platform.lua, every field just falls back to its default rather
-- than erroring -- a deployment that wants none of this can skip the
-- file entirely. Memoized per-process (PLATFORM_CONFIG_CACHE) since a
-- single turn loop reads several of these fields across several calls
-- -- safe to cache because CGI/CLI both start a fresh Lua process per
-- request/invocation, so there's never a stale value left over from
-- an earlier one.
-- reference_aliases: a list of {pattern, replacement} string pairs;
-- anything else in it is dropped rather than failing every request.
function validate_reference_aliases(list)
    out = {}
    for _, pair in ipairs(list) do
        if type(pair) == "table" and type(pair[1]) == "string" and pair[1] != "" and type(pair[2]) == "string" then
            table.insert(out, {pair[1], pair[2]})
        end
    end
    return out
end

-- A list of Lua patterns; a non-string or a malformed pattern is dropped
-- rather than failing every embedding.
function validate_patterns(list)
    out = {}
    for _, pattern in ipairs(list) do
        if type(pattern) == "string" and pattern != "" then
            ok, _ = pcall(string.find, "", pattern)
            if ok then
                table.insert(out, pattern)
            end
        end
    end
    return out
end

function config.platform_config()
    if PLATFORM_CONFIG_CACHE != nil then
        return PLATFORM_CONFIG_CACHE
    end

    -- Which backend to call is the deployment's choice, so core names
    -- none: nil agent_provider/search_provider/mail_provider means that
    -- feature is off. A nil agent_model/embedding_model means the
    -- chosen provider's own default (agent_provider.model/
    -- embedding_model). A provider's own settings (a cloud project, a
    -- mail server) aren't listed here either: the provider reads them
    -- itself through config.setting.
    PLATFORM_SETTINGS_CACHE = {}
    conf = {
        agent_provider = nil,
        agent_model = nil,
        embedding_model = nil,
        search_provider = nil,
        agent_max_turns = 20,
        -- "detached": a chat turn runs in its own worker process, not
        -- the web request (agent.lua, "Detached turns"); "inline": in
        -- the request, as before.
        agent_turn_mode = "detached",
        -- A detached turn with no progress for this long is reported as
        -- stopped.
        agent_turn_stale_seconds = 180,
        -- A detached turn that spends its step budget goes on with a
        -- fresh one (and a progress note) up to this many more times,
        -- within this many minutes in all.
        agent_auto_continue_max = 3,
        agent_auto_continue_minutes = 10,
        agent_research_max_turns = 12,
        agent_background_max_turns = 20,
        agent_background_max_attempts = 3,
        agent_search_excerpt_length = 1200,
        agent_query_row_cap = 200,
        -- Compaction (doc/context-management-plan.md, Phase 3): the
        -- threshold is in real tokens, sized from the last call's
        -- recorded prompt_tokens; without one, from the fixed overhead
        -- (system prompt + tool definitions) plus history characters
        -- per token, both fitted on prod chat calls. Mid-turn: check
        -- before every step, not only when a turn starts.
        agent_compaction_threshold = 48000,
        agent_context_fixed_tokens = 3900,
        agent_chars_per_token = 2.8,
        agent_compaction_mid_turn = true,
        -- agent_model_call.prompt (the exact history sent on each model
        -- call) is operational audit data: cleared after this many days
        -- by `daat agent prune-prompts` (0: keep forever). Chat history
        -- itself (agent_message, transcript documents) is never pruned.
        prompt_retention_days = 90,
        -- Keep what's already known (doc/context-management-plan.md,
        -- Phase 1): schema lookups carried verbatim through compaction
        -- (within this many characters), and an exact repeat of a
        -- read-only call answered with a pointer to the earlier result.
        -- Result sizes (doc/context-management-plan.md, Phase 2): tool
        -- results were 77% of prod chat history. knowledge.list pages
        -- (was every pool document); entity.query stops at a size as well
        -- as a row count; entity.get shows the start of a long text field
        -- (and reads the rest on request); any other tool result over
        -- agent_tool_result_cap is cut when shown to the model, with the
        -- rest readable through result.read. document.search's "full"
        -- detail uses the longer excerpt.
        agent_knowledge_list_page = 50,
        agent_query_char_cap = 12000,
        agent_get_field_chars = 4000,
        agent_tool_result_cap = 24000,
        agent_search_excerpt_full_length = 4000,
        -- Passage retrieval (doc/passage-retrieval.md): search shows each
        -- shortlisted document's most relevant passages, chosen by
        -- meaning, to the agent and on /documents alike.
        -- On since the 2026-10-26 live scorecard: answers and checks
        -- unchanged, ~3% fewer tokens per passed run.
        search_passages = true,
        passage_max_chars = 1500,
        passage_min_chars = 200,
        passages_per_document = 2,
        passage_lexical_weight = 0.2,
        passage_max_embeds_per_search = 60,
        -- Passage embeddings are cached (document_passage_cache) and
        -- expire this many days after last use (0: never).
        passage_cache_days = 30,
        -- The co-retrieval link gate (doc/link-passage-gate.md): a pair
        -- whose most similar passages score below this isn't put to the
        -- model (0: off). Compares at most this many passages of each
        -- document, embedding at most this many new ones per pair.
        link_passage_gate = 0.72,
        link_gate_passages_per_document = 40,
        link_gate_max_embeds = 80,
        agent_pin_schema = true,
        agent_pinned_schema_chars = 6000,
        agent_dedupe_repeat_calls = true,
        platform_adhoc_row_cap = 1000,
        extension_max_job_attempts = 5,
        -- Tag upkeep (tag.lua): vectors are the cached embeddings cut to
        -- tag_dims (256 lost about a point against the full 768 in the
        -- 2026-10-04 check, at a third of the cost); a document also
        -- joins its second-nearest tag when that's within
        -- tag_second_within of the nearest (nil: one tag only).
        tag_dims = 256,
        tag_second_within = 0.02,
        -- A saved document is (re-)embedded once it has gone this many
        -- minutes without another edit (`daat document embed-pending`,
        -- on the deployment's job timer), so a document edited again
        -- and again -- a chat transcript after every turn -- costs one
        -- embedding, not one per save. 0 embeds on save.
        embedding_quiet_minutes = 5,
        -- Lua patterns: a content line any of them matches is left out of
        -- the text a document's embedding is made from (document.lua's
        -- embedding_text) -- a sync's own header, template boilerplate.
        -- Changing them changes text hashes: `daat repair embeddings`
        -- re-embeds what changed.
        embedding_skip = nil,
        -- Tag restructuring (tag_upkeep.lua): split, merge and label
        -- checks, each decided by the agent, after embed-pending embeds
        -- anything. Off until a deployment has reviewed `daat repair tags
        -- --restructure --dry-run --judge` on its own tags. A tag smaller
        -- than tag_split_min is never split.
        tag_restructure = false,
        -- A document whose embedded text has fewer characters than this
        -- besides its title (a folder page, a template, a file with no
        -- extractable text) has nothing to say what it's about: it isn't
        -- tagged, by placement or the cold start. Still searchable.
        tag_min_text = 200,
        tag_split_min = 40,
        -- How this deployment's people write its entity names, for
        -- references (reference.lua): {{lua_pattern, replacement}, ...}
        -- over lowercased text, e.g. {{"experiment%s*(%d)", "exp%1"}}
        -- when experiments are named ExpN but written "Experiment N".
        reference_aliases = nil,
        -- Off by default -- a deployment opts in once pdftotext/pandoc
        -- (see doc's own Dockerfile) are actually installed, rather
        -- than the platform deciding every deployment wants a chat
        -- file-upload surface and its two extra system dependencies.
        chat_attachments_enabled = false,
        db_backend = "sqlite",
        mariadb_host = "127.0.0.1",
        mariadb_port = 3306,
        mariadb_user = nil,
        mariadb_database = nil,
        -- nil (both) means "today's hardcoded rail, unchanged" -- see
        -- html.lua's own apply_nav_order/apply_nav_hidden (brex
        -- 683042859). Deliberately a reorder/hide overlay on the
        -- existing capability-gated built-in items, not a from-scratch
        -- nav vocabulary: an unrecognized key in either list is a
        -- silent no-op (never an error), and a key genuinely hidden by
        -- capability/deployment state today (no Setup/Admin cap, no
        -- prioritized_tasks view, an unapproved extension) stays hidden
        -- regardless of what's listed here -- this can only reorder or
        -- further hide what would already render, never grant it back.
        nav_order = nil,
        nav_hidden = nil,
        -- Outbound mail (mail_provider.lua) -- only used by the
        -- forgot-password flow today. nil mail_provider means no mail
        -- at all: /forgot-password 404s and /login shows no link to it
        -- (see config.password_reset_enabled). public_url is the
        -- deployment's own externally-reachable base URL, used to build
        -- the emailed reset link -- deliberately config, never derived
        -- from the request's Host header, which a caller controls and
        -- could otherwise point a real user's reset link at their own
        -- server. The backend's own settings (an SMTP server, a Graph
        -- app registration) are its own, read through config.setting.
        mail_provider = nil,
        mail_from = nil,
        public_url = nil,
    }

    path = config.platform_config_path()
    file = io.open(path, "r")
    if file == nil then
        PLATFORM_CONFIG_CACHE = conf
        return conf
    end
    contents = io.read(file, "*all")
    io.close(file)

    ok, parsed = sandbox.run(contents, path, sandbox.data_env())
    if ok == false or type(parsed) != "table" then
        PLATFORM_CONFIG_CACHE = conf
        return conf
    end

    if type(parsed.agent_provider) == "string" and parsed.agent_provider != "" then
        conf.agent_provider = parsed.agent_provider
    end
    PLATFORM_SETTINGS_CACHE = parsed
    if type(parsed.agent_model) == "string" and parsed.agent_model != "" then
        conf.agent_model = parsed.agent_model
    end
    if type(parsed.embedding_model) == "string" and parsed.embedding_model != "" then
        conf.embedding_model = parsed.embedding_model
    end
    if type(parsed.search_provider) == "string" and parsed.search_provider != "" then
        conf.search_provider = parsed.search_provider
    end
    if type(parsed.agent_max_turns) == "number" then
        conf.agent_max_turns = parsed.agent_max_turns
    end
    if parsed.agent_turn_mode == "detached" or parsed.agent_turn_mode == "inline" then
        conf.agent_turn_mode = parsed.agent_turn_mode
    end
    if type(parsed.agent_turn_stale_seconds) == "number" then
        conf.agent_turn_stale_seconds = parsed.agent_turn_stale_seconds
    end
    if type(parsed.agent_auto_continue_max) == "number" then
        conf.agent_auto_continue_max = parsed.agent_auto_continue_max
    end
    if type(parsed.agent_auto_continue_minutes) == "number" then
        conf.agent_auto_continue_minutes = parsed.agent_auto_continue_minutes
    end
    if type(parsed.agent_research_max_turns) == "number" then
        conf.agent_research_max_turns = parsed.agent_research_max_turns
    end
    if type(parsed.agent_background_max_turns) == "number" then
        conf.agent_background_max_turns = parsed.agent_background_max_turns
    end
    if type(parsed.agent_background_max_attempts) == "number" then
        conf.agent_background_max_attempts = parsed.agent_background_max_attempts
    end
    if type(parsed.agent_search_excerpt_length) == "number" then
        conf.agent_search_excerpt_length = parsed.agent_search_excerpt_length
    end
    if type(parsed.agent_query_row_cap) == "number" then
        conf.agent_query_row_cap = parsed.agent_query_row_cap
    end
    if type(parsed.agent_compaction_threshold) == "number" then
        conf.agent_compaction_threshold = parsed.agent_compaction_threshold
    end
    if type(parsed.agent_context_fixed_tokens) == "number" then
        conf.agent_context_fixed_tokens = parsed.agent_context_fixed_tokens
    end
    if type(parsed.agent_chars_per_token) == "number" and parsed.agent_chars_per_token > 0 then
        conf.agent_chars_per_token = parsed.agent_chars_per_token
    end
    if parsed.agent_compaction_mid_turn == true or parsed.agent_compaction_mid_turn == false then
        conf.agent_compaction_mid_turn = parsed.agent_compaction_mid_turn
    end
    if type(parsed.prompt_retention_days) == "number" then
        conf.prompt_retention_days = parsed.prompt_retention_days
    end
    if parsed.search_passages == true or parsed.search_passages == false then
        conf.search_passages = parsed.search_passages
    end
    if type(parsed.passage_lexical_weight) == "number" and parsed.passage_lexical_weight >= 0 then
        conf.passage_lexical_weight = parsed.passage_lexical_weight
    end
    if type(parsed.passage_cache_days) == "number" and parsed.passage_cache_days >= 0 then
        conf.passage_cache_days = parsed.passage_cache_days
    end
    if type(parsed.link_passage_gate) == "number" and parsed.link_passage_gate >= 0 then
        conf.link_passage_gate = parsed.link_passage_gate
    end
    for _, key in ipairs({"agent_knowledge_list_page", "agent_query_char_cap", "agent_get_field_chars", "agent_tool_result_cap", "agent_search_excerpt_full_length",
            "passage_max_chars", "passage_min_chars", "passages_per_document", "passage_max_embeds_per_search",
            "link_gate_passages_per_document", "link_gate_max_embeds"}) do
        if type(parsed[key]) == "number" and parsed[key] > 0 then
            conf[key] = parsed[key]
        end
    end
    if parsed.agent_pin_schema == true or parsed.agent_pin_schema == false then
        conf.agent_pin_schema = parsed.agent_pin_schema
    end
    if type(parsed.agent_pinned_schema_chars) == "number" and parsed.agent_pinned_schema_chars >= 0 then
        conf.agent_pinned_schema_chars = parsed.agent_pinned_schema_chars
    end
    if parsed.agent_dedupe_repeat_calls == true or parsed.agent_dedupe_repeat_calls == false then
        conf.agent_dedupe_repeat_calls = parsed.agent_dedupe_repeat_calls
    end
    if type(parsed.platform_adhoc_row_cap) == "number" then
        conf.platform_adhoc_row_cap = parsed.platform_adhoc_row_cap
    end
    if type(parsed.extension_max_job_attempts) == "number" then
        conf.extension_max_job_attempts = parsed.extension_max_job_attempts
    end
    -- true/false compared directly: Luam's type() calls them "flag", not
    -- "boolean" (schema.lua's same note).
    if parsed.chat_attachments_enabled == true or parsed.chat_attachments_enabled == false then
        conf.chat_attachments_enabled = parsed.chat_attachments_enabled
    end
    if type(parsed.embedding_quiet_minutes) == "number" and parsed.embedding_quiet_minutes >= 0 then
        conf.embedding_quiet_minutes = parsed.embedding_quiet_minutes
    end
    if type(parsed.embedding_skip) == "table" then
        conf.embedding_skip = validate_patterns(parsed.embedding_skip)
    end
    if parsed.tag_restructure == true or parsed.tag_restructure == false then
        conf.tag_restructure = parsed.tag_restructure
    end
    if type(parsed.tag_min_text) == "number" and parsed.tag_min_text >= 0 then
        conf.tag_min_text = parsed.tag_min_text
    end
    if type(parsed.tag_split_min) == "number" and parsed.tag_split_min >= 2 then
        conf.tag_split_min = parsed.tag_split_min
    end
    if type(parsed.tag_dims) == "number" and parsed.tag_dims >= 1 then
        conf.tag_dims = parsed.tag_dims
    end
    -- A number, or false for one tag per document.
    if type(parsed.tag_second_within) == "number" then
        conf.tag_second_within = parsed.tag_second_within
    elseif parsed.tag_second_within == false then
        conf.tag_second_within = nil
    end
    if type(parsed.reference_aliases) == "table" then
        conf.reference_aliases = validate_reference_aliases(parsed.reference_aliases)
    end
    if parsed.db_backend == "mariadb" then
        conf.db_backend = "mariadb"
    end
    if type(parsed.mariadb_host) == "string" and parsed.mariadb_host != "" then
        conf.mariadb_host = parsed.mariadb_host
    end
    if type(parsed.mariadb_port) == "number" then
        conf.mariadb_port = parsed.mariadb_port
    end
    if type(parsed.mariadb_user) == "string" and parsed.mariadb_user != "" then
        conf.mariadb_user = parsed.mariadb_user
    end
    if type(parsed.mariadb_database) == "string" and parsed.mariadb_database != "" then
        conf.mariadb_database = parsed.mariadb_database
    end
    if type(parsed.nav_order) == "table" then
        conf.nav_order = validate_nav_key_list(parsed.nav_order)
    end
    if type(parsed.nav_hidden) == "table" then
        conf.nav_hidden = validate_nav_key_list(parsed.nav_hidden)
    end
    for _, key in ipairs({"mail_provider", "mail_from", "public_url"}) do
        if type(parsed[key]) == "string" and parsed[key] != "" then
            conf[key] = parsed[key]
        end
    end

    PLATFORM_CONFIG_CACHE = conf
    return conf
end

-- A provider's own platform.lua setting (vertex_project, smtp_url,
-- ...), as written: core doesn't know these keys, so the provider that
-- reads one checks it. An empty string counts as unset.
function config.setting(key)
    config.platform_config()
    value = PLATFORM_SETTINGS_CACHE[key]
    if value == "" then
        return nil
    end
    return value
end

-- The forgot-password flow needs all three: something to send with,
-- an address to send from, and a real base URL to put in the link.
-- Missing any one, the whole flow stays off rather than half-working
-- (e.g. sending a link with no host in it).
function config.password_reset_enabled()
    conf = config.platform_config()
    return conf.mail_provider != nil and conf.mail_from != nil and conf.public_url != nil
end

-- Deliberately generic here: platform itself ships no brand identity,
-- just a hook. A deployment that wants one drops an optional
-- theme.lua at the store root (e.g. seeded by its own deploy tooling,
-- outside this repo) -- absent or malformed, every value below falls
-- back to nil, which leaves html.lua's existing var(--platform-*,
-- <fallback>) defaults (its current indigo/slate palette) untouched.
-- site_name similarly defaults to a generic label, never a company name.
function config.load_theme(root)
    theme = {site_name = "Platform", colors = {}, has_logo = false, hide_home_heading = false, system_prompt_extra = nil}
    path = config.theme_path(root)
    file = io.open(path, "r")
    if file == nil then
        return theme
    end
    contents = io.read(file, "*all")
    io.close(file)

    ok, parsed = sandbox.run(contents, path, sandbox.data_env())
    if ok == false or type(parsed) != "table" then
        return theme
    end

    if type(parsed.site_name) == "string" and parsed.site_name != "" then
        theme.site_name = parsed.site_name
    end
    if parsed.has_logo == true then
        theme.has_logo = true
    end
    -- For a deployment whose logo image already contains the company
    -- name (a wordmark, not just a mark) -- repeating it as a second,
    -- redundant text heading on Home reads as a mistake, not a
    -- feature. A generic hook, not a Celleste-specific behavior baked
    -- into html.lua: any deployment can opt into it, none are forced to.
    if parsed.hide_home_heading == true then
        theme.hide_home_heading = true
    end
    -- Deployment-specific instructions appended to the chat agent's own
    -- system prompt -- e.g. domain vocabulary, house style, or
    -- reminders specific to this deployment's use case, without editing
    -- daat's own source. A generic hook (any deployment can set
    -- it), same split as every other theme.lua field here.
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

-- A theme.lua field value is about to become part of a real Lua source
-- file that sandbox.run will later execute -- unlike dkjson.encode
-- (which handled this automatically), writing a string literal by hand
-- means backslashes/quotes/newlines in an admin-supplied value (site_name,
-- system_prompt_extra) must be escaped correctly, or they'd either break
-- the file's own syntax or (worse) let a crafted value close the string
-- early and inject extra table fields. Order matters: backslashes must
-- be escaped first, before quotes/newlines, so the backslashes this
-- function itself inserts are never re-escaped by a later step.
function lua_string_literal(s)
    escaped = string.gsub(s, "\\", "\\\\")
    escaped = string.gsub(escaped, "\"", "\\\"")
    escaped = string.gsub(escaped, "\n", "\\n")
    escaped = string.gsub(escaped, "\r", "\\r")
    return "\"" .. escaped .. "\""
end

-- Writes theme.lua back out -- the settings UI's save path, symmetric
-- to load_theme above rather than a one-off ad hoc writer. `theme` is
-- the same shape load_theme returns; only non-empty/non-default values
-- are actually written, so a field left blank in the settings form
-- round-trips back to "absent from theme.lua" (load_theme's own
-- generic fallback) instead of being persisted as an explicit empty
-- string.
function config.save_theme(root, theme)
    lines = {"return {"}
    if theme.site_name != nil and theme.site_name != "" and theme.site_name != "Platform" then
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

return config
