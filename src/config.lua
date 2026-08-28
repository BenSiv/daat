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

-- Returns whatever db.lua's db_path parameter expects for the active
-- backend: a SQLite file path (a string) or a MariaDB connection
-- descriptor (a table) -- opaque to every caller either way, only
-- db.lua itself ever inspects the shape (see that file's own header
-- comment).
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
-- instead. Requires "database" (the same luam module db.lua itself
-- wraps) directly rather than requiring db.lua -- db.lua already
-- requires config for nothing today and never should (see its own
-- header comment on why dispatch is by db_path's shape, not a config
-- lookup), so this file must not create that cycle from the other
-- direction either.
function config.is_initialized(root)
    if config.db_backend() == "mariadb" then
        database = require("database")
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
-- Same generic-hook contract as load_theme below: absent or malformed
-- platform.lua, every field just falls back to its default rather
-- than erroring -- a deployment that wants none of this can skip the
-- file entirely. Memoized per-process (PLATFORM_CONFIG_CACHE) since a
-- single turn loop reads several of these fields across several calls
-- -- safe to cache because CGI/CLI both start a fresh Lua process per
-- request/invocation, so there's never a stale value left over from
-- an earlier one.
function config.platform_config()
    if PLATFORM_CONFIG_CACHE != nil then
        return PLATFORM_CONFIG_CACHE
    end

    conf = {
        agent_provider = "vertex",
        agent_model = "gemini-2.5-flash",
        search_provider = "google_cse",
        vertex_project = nil,
        vertex_region = nil,
        agent_max_turns = 10,
        agent_research_max_turns = 6,
        agent_background_max_turns = 20,
        agent_background_max_attempts = 3,
        agent_search_excerpt_length = 1200,
        agent_query_row_cap = 200,
        agent_compaction_threshold = 4000,
        platform_adhoc_row_cap = 1000,
        extension_max_job_attempts = 5,
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
    if type(parsed.agent_model) == "string" and parsed.agent_model != "" then
        conf.agent_model = parsed.agent_model
    end
    if type(parsed.search_provider) == "string" and parsed.search_provider != "" then
        conf.search_provider = parsed.search_provider
    end
    if type(parsed.vertex_project) == "string" and parsed.vertex_project != "" then
        conf.vertex_project = parsed.vertex_project
    end
    if type(parsed.vertex_region) == "string" and parsed.vertex_region != "" then
        conf.vertex_region = parsed.vertex_region
    end
    if type(parsed.agent_max_turns) == "number" then
        conf.agent_max_turns = parsed.agent_max_turns
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
    if type(parsed.platform_adhoc_row_cap) == "number" then
        conf.platform_adhoc_row_cap = parsed.platform_adhoc_row_cap
    end
    if type(parsed.extension_max_job_attempts) == "number" then
        conf.extension_max_job_attempts = parsed.extension_max_job_attempts
    end
    if type(parsed.chat_attachments_enabled) == "boolean" then
        conf.chat_attachments_enabled = parsed.chat_attachments_enabled
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

    PLATFORM_CONFIG_CACHE = conf
    return conf
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
