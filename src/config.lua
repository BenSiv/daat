-- Resolves the store location: a `.store/` directory (renamed once the
-- project itself has a name) holding the ledger database, alongside
-- `schemas/`/`extensions/`/`views/`/`templates/` directories.
--
-- Root resolution no longer walks up looking for a Fossil checkout
-- marker (`.fslckout`/`_FOSSIL_`) -- there is no Fossil checkout to
-- find. `DOCUMENT_ROOT` is a standard CGI env var most web servers set
-- natively (not Fossil-specific, even though Fossil's own /ext relay
-- also happened to set it), so it's kept as the CGI-mode signal; CLI
-- mode still just uses the current directory. No more "which of two
-- possibly-different root markers wins" -- there's exactly one root
-- now, matching the single-SQLite-file storage consolidation this
-- migration is also doing.

-- No `json = require("dkjson")` here, unlike most other modules in
-- this codebase -- config.load_theme below is only ever reached via
-- cgi.lua's own request handling, which already requires dkjson as
-- `json` before dispatching to any handler; adding a second top-level
-- require of the same module here (this file loads earlier in the
-- build's bundle order than dkjson.lua itself) was confirmed, via a
-- real failing test (tst/integration/entity.bats "ledger records full
-- history"), to leave `json` broken for unrelated code later in the
-- same process -- CLI invocations of `ledger history` decoded
-- field_changes to nil instead of a table. Removing the duplicate
-- require fixed it; config.lua has no JSON needs of its own that
-- aren't already covered by relying on the shared global.
paths = require("paths")

config = {}

STORE_DIR = ".store"
DB_FILE = "store.db"
SESSION_SECRET_FILE = "session_secret"
THEME_FILE = "theme.json"

-- The CSS custom-property names a theme.json may override -- matches
-- html.lua's own var(--platform-*, <fallback>) usage sites exactly, so a
-- deployment can only override colors/tokens the app already exposes
-- as a hook, never introduce a new one by typo.
THEME_COLOR_KEYS = {
    "accent", "accent_2", "bg", "bg_2", "border", "border_2",
    "heading", "input_text", "muted", "muted_2", "text", "th_text",
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
-- Read fresh on every call rather than cached: cheap (one os.getenv),
-- and CGI-per-request means each process only ever asks once anyway,
-- so there's no real cost to keeping this stateless like every other
-- config.* resolver here.
function config.db_backend()
    backend = os.getenv("PLATFORM_DB_BACKEND")
    if backend == "mariadb" then
        return "mariadb"
    end
    return "sqlite"
end

-- Connection descriptor for the mariadb backend, resolved from env
-- vars -- same convention as PLATFORM_VENDOR_DIR. host/port default to
-- MariaDB's own usual localhost/3306; user/database have no sensible
-- guess and are left nil if unset rather than silently defaulting to
-- something that would connect to the wrong place.
function config.mariadb_descriptor()
    port = tonumber(os.getenv("PLATFORM_MARIADB_PORT"))
    if port == nil then
        port = 3306
    end
    host = os.getenv("PLATFORM_MARIADB_HOST")
    if host == nil or host == "" then
        host = "127.0.0.1"
    end
    password = os.getenv("PLATFORM_MARIADB_PASSWORD")
    if password == nil then
        password = ""
    end
    return {
        host = host,
        port = port,
        user = os.getenv("PLATFORM_MARIADB_USER"),
        password = password,
        database = os.getenv("PLATFORM_MARIADB_DATABASE"),
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

-- task #84: named, reusable value lists a select/multi_select field can
-- reference (`dropdown = "work_process"`) instead of inlining its own
-- `values` list -- so several fields (or several entity types) can
-- share one list and a single edit updates every field referencing it.
function config.dropdowns_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "dropdowns")
end

-- task #73: one file per entity type, each a `view`-shaped SQL query
-- (see src/label.lua) plus a `zpl` template string. Lazily looked up by
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

-- "Initialized" means `platform init` has already created the schema --
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

-- Optional binary assets (favicon/logo) a deployment's theme.json can
-- reference -- same "generic hook, real files seeded by whoever wants
-- them" split as theme.json itself.
function config.theme_assets_dir(root)
    if root == nil then
        root = config.find_root()
    end
    return paths.joinpath(root, "theme-assets")
end

-- Vendored third-party assets platform itself ships (e.g. the Toast UI
-- Editor bundle) -- unlike theme_assets_dir, this is NOT
-- DOCUMENT_ROOT-relative: these files belong to the platform-wip
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

-- Deliberately generic here: platform itself ships no brand identity,
-- just a hook. A deployment that wants one drops an optional
-- theme.json at the store root (e.g. seeded by its own deploy tooling,
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

    -- Required here, not at module top level -- matches html.lua/
    -- schema.lua/agent.lua's own per-function require("dkjson") calls
    -- rather than ledger.lua/cgi.lua's top-level ones. A top-level
    -- `json = require("dkjson")` added here once broke an unrelated
    -- CLI code path (tst/integration/entity.bats "ledger records full
    -- history" started failing: field_changes decoded to nil) --
    -- this file loads earlier than dkjson.lua in the build's bundle
    -- order, and re-requiring it there evidently isn't safe the way
    -- it is inside a function called well after the whole bundle has
    -- finished loading.
    json = require("dkjson")
    parsed, _, err = json.decode(contents)
    if err != nil or type(parsed) != "table" then
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
    -- system prompt (task #70) -- e.g. domain vocabulary, house style,
    -- or reminders specific to this deployment's use case, without
    -- editing platform-wip's own source. A generic hook (any deployment
    -- can set it), same split as every other theme.json field here.
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

-- Writes theme.json back out -- the settings UI's save path (task
-- #89), symmetric to load_theme above rather than a one-off ad hoc
-- writer. `theme` is the same shape load_theme returns; only
-- non-empty/non-default values are actually written, so a field left
-- blank in the settings form round-trips back to "absent from
-- theme.json" (load_theme's own generic fallback) instead of being
-- persisted as an explicit empty string.
function config.save_theme(root, theme)
    json = require("dkjson")
    out = {}
    if theme.site_name != nil and theme.site_name != "" and theme.site_name != "Platform" then
        out.site_name = theme.site_name
    end
    if theme.has_logo == true then
        out.has_logo = true
    end
    if theme.hide_home_heading == true then
        out.hide_home_heading = true
    end
    if theme.system_prompt_extra != nil and theme.system_prompt_extra != "" then
        out.system_prompt_extra = theme.system_prompt_extra
    end
    out.colors = {}
    if theme.colors != nil then
        for _, key in ipairs(THEME_COLOR_KEYS) do
            value = theme.colors[key]
            if type(value) == "string" and value != "" then
                out.colors[key] = value
            end
        end
    end

    path = config.theme_path(root)
    file, err = io.open(path, "w")
    if file == nil then
        return nil, err
    end
    io.write(file, json.encode(out, {indent = true}))
    io.close(file)
    return true
end

return config
