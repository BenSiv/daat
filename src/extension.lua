-- Extension manifest loading, the admin-approval registry, and the
-- after-hook job queue. See doc/extensibility.md for the extension
-- layout/capability model this implements.
--
-- Deliberately does not require "entity" (avoids a require cycle --
-- entity.lua requires this module to build ctx.create_entity/
-- update_entity bindings). extension.invoke() takes an already-built ctx
-- rather than building one itself.

db = require("db")
json = require("dkjson")
paths = require("paths")
lfs = require("lfs")
sandbox = require("sandbox")
file_util = require("file_util")
config = require("config")

extension = {}

-- How many retries make sense before giving up on a job plausibly
-- depends on how flaky a given deployment's own extensions/network are
-- -- not a bare hardcoded literal; read fresh from
-- config.platform_config() per call rather than resolved once at load.

extension.SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS extension_approval (
    name VARCHAR(255) PRIMARY KEY,
    capabilities_json TEXT NOT NULL,
    approved_by TEXT,
    approved_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS extension_job (
    job_id INTEGER PRIMARY KEY %s,
    extension_name TEXT NOT NULL,
    event_name TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id INTEGER NOT NULL,
    new_values_json TEXT,
    old_values_json TEXT,
    -- VARCHAR(32), not TEXT -- real MySQL 8.0 (unlike MariaDB, which
    -- allows this as an extension) rejects a literal DEFAULT value on
    -- a BLOB/TEXT/GEOMETRY/JSON column outright ("can't have a default
    -- value"). Found running tst/integration/mariadb_backend.bats
    -- against a real Cloud SQL for MySQL instance, not anticipated
    -- when the earlier MariaDB-only dialect work was verified.
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);
"""

function extension_schema_sql(db_path)
    return string.format(extension.SCHEMA,
        db.now_expr(db_path), db.autoincrement_keyword(db_path),
        db.now_expr(db_path), db.now_expr(db_path)
    )
end

function extension.init_schema(db_path)
    return db.exec(db_path, extension_schema_sql(db_path))
end

-- Names of extension directories under ext_dir that have both a
-- manifest.lua and a main.lua. A directory missing either is ignored,
-- not an error -- an in-progress scaffold can sit there harmlessly.
function extension.names(ext_dir)
    names = {}
    attr = lfs.attributes(ext_dir)
    if attr == nil or attr.mode != "directory" then
        return names
    end
    for dir_name in lfs.dir(ext_dir) do
        if dir_name != "." and dir_name != ".." then
            manifest_path = paths.joinpath(ext_dir, dir_name, "manifest.lua")
            main_path = paths.joinpath(ext_dir, dir_name, "main.lua")
            if paths.file_exists(manifest_path) and paths.file_exists(main_path) then
                table.insert(names, dir_name)
            end
        end
    end
    return names
end

-- Every top-level AGENT_TOOLS group name (src/agent.lua) -- an
-- extension's own name can never collide with one of these, since
-- capabilities.tools entries dispatch under tool_name = manifest.name.
RESERVED_TOOL_NAMES = {
    document = true, entity = true, plot = true, template = true,
    knowledge = true, view = true, research = true, clarify = true,
    background = true, internet_search = true,
}

-- Structural validation only -- does the manifest make sense on its own
-- terms (mirrors schema.validate's role for schema files).
function extension.validate_manifest(manifest)
    if type(manifest.name) != "string" or manifest.name == "" then
        return "manifest must have a non-empty string 'name'"
    end
    if type(manifest.events) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "' must have an 'events' list"
    end
    if type(manifest.entity_types) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "' must have an 'entity_types' list"
    end
    if manifest.capabilities != nil and type(manifest.capabilities) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "': 'capabilities' must be a table"
    end
    -- capabilities.ui's mere presence opts an extension into a page at
    -- /ext/<name> (see doc/plugin-system-research.md) -- no separate
    -- 'path' field; the route is always derived from the extension's
    -- own name, which sidesteps path-format/collision validation
    -- entirely rather than needing it.
    if manifest.capabilities != nil and manifest.capabilities.ui != nil then
        ui = manifest.capabilities.ui
        if type(ui) != "table" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must be a table"
        end
        if type(ui.label) != "string" or ui.label == "" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must have a non-empty string 'label'"
        end
        if type(ui.icon) != "string" or ui.icon == "" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must have a non-empty string 'icon'"
        end
    end
    -- capabilities.tools' entries are dispatched under tool_name =
    -- manifest.name (see agent.execute_tool's extension fallback) --
    -- reusing the plain tool_name.method_name convention every built-in
    -- AGENT_TOOLS entry already uses, with no separate namespace. That
    -- only works if an extension's own name can never collide with one
    -- of those built-in top-level groups, so it's rejected here, once,
    -- rather than needing a remapping table at dispatch time.
    if manifest.capabilities != nil and manifest.capabilities.tools != nil then
        if RESERVED_TOOL_NAMES[manifest.name] == true then
            return "manifest '" .. tostring(manifest.name) .. "': extension name collides with a built-in tool group"
        end
        if type(manifest.capabilities.tools) != "table" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools must be a list"
        end
        for _, tool in ipairs(manifest.capabilities.tools) do
            if type(tool) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entries must be tables"
            end
            if type(tool.name) != "string" or tool.name == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry must have a non-empty string 'name'"
            end
            if type(tool.description) != "string" or tool.description == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry '" .. tool.name .. "' must have a non-empty string 'description'"
            end
            if type(tool.parameters) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry '" .. tool.name .. "' must have a 'parameters' table"
            end
        end
    end
    return nil
end

-- Loads a manifest from extensions/<name>/manifest.lua, sandboxed the
-- same data-only way a schema file is (see doc/schema.md).
function extension.load_manifest(ext_dir, name)
    manifest_path = paths.joinpath(ext_dir, name, "manifest.lua")
    source = file_util.read(manifest_path)
    if source == nil then
        return nil, "cannot open manifest: " .. manifest_path
    end
    ok, result = sandbox.run(source, manifest_path, sandbox.data_env())
    if ok == false or type(result) != "table" then
        return nil, "error loading manifest " .. manifest_path .. ": " .. tostring(result)
    end
    err = extension.validate_manifest(result)
    if err != nil then
        return nil, err
    end
    return result
end

function extension.load_main_source(ext_dir, name)
    main_path = paths.joinpath(ext_dir, name, "main.lua")
    source = file_util.read(main_path)
    if source == nil then
        return nil, "cannot open main.lua: " .. main_path
    end
    return source
end

-- Every extension directory found, each with its loaded manifest (or an
-- error) -- one bad extension's manifest error never hides the others.
function extension.all(ext_dir)
    result = {}
    for _, name in ipairs(extension.names(ext_dir)) do
        manifest, err = extension.load_manifest(ext_dir, name)
        table.insert(result, {name = name, manifest = manifest, err = err})
    end
    return result
end

-- Approved extensions that also declare capabilities.ui -- the one
-- list both the nav rail (html.page_shell) and the /ext/<name> route
-- dispatcher (cgi.lua) need; a bad manifest or an unapproved/no-ui
-- extension is silently excluded here rather than surfaced as an
-- error, same spirit as extension.matching's own filtering.
function extension.approved_with_ui(db_path, ext_dir)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and entry.manifest.capabilities != nil
           and entry.manifest.capabilities.ui != nil
           and extension.is_approved(db_path, entry.manifest) then
            table.insert(result, {name = entry.name, manifest = entry.manifest})
        end
    end
    return result
end

-- Approved extensions that also declare capabilities.tools -- the one
-- list the agent-tools registry/dispatch (agent.lua) needs, same
-- exclusion spirit as approved_with_ui: a bad manifest or an
-- unapproved/tool-less extension is silently excluded, not surfaced as
-- an error.
function extension.approved_with_tools(db_path, ext_dir)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and entry.manifest.capabilities != nil
           and entry.manifest.capabilities.tools != nil
           and #entry.manifest.capabilities.tools > 0
           and extension.is_approved(db_path, entry.manifest) then
            table.insert(result, {name = entry.name, manifest = entry.manifest})
        end
    end
    return result
end

function extension.matches_event(manifest, event_name)
    if manifest.events == nil then
        return false
    end
    for _, ev in ipairs(manifest.events) do
        if ev == event_name then
            return true
        end
    end
    return false
end

function extension.matches_entity_type(manifest, entity_type)
    if manifest.entity_types == nil then
        return false
    end
    for _, et in ipairs(manifest.entity_types) do
        if et == entity_type then
            return true
        end
    end
    return false
end

-- Extensions (name + manifest) declaring interest in this event + entity
-- type. Extensions with a bad manifest are silently excluded here (they
-- already surface via extension.all()/`daat extension list`).
function extension.matching(ext_dir, event_name, entity_type)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and extension.matches_event(entry.manifest, event_name)
           and extension.matches_entity_type(entry.manifest, entity_type) then
            table.insert(result, entry)
        end
    end
    return result
end

-- ---- Capability comparison (order-independent set equality) ----

function string_set(list)
    set = {}
    if list == nil then
        return set
    end
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

function string_sets_equal(a, b)
    set_a = string_set(a)
    set_b = string_set(b)
    for k, _ in pairs(set_a) do
        if set_b[k] == nil then
            return false
        end
    end
    for k, _ in pairs(set_b) do
        if set_a[k] == nil then
            return false
        end
    end
    return true
end

-- Same-shape comparison for capabilities.ui -- its mere presence is a
-- real capability grant (a page at /ext/<name>, visible to every
-- user), so editing label/icon -- not just adding/removing the whole
-- block -- has to invalidate approval the same way any other
-- capabilities change does.
function ui_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    return a.label == b.label and a.icon == b.icon
end

-- Order-independent structural equality -- needed because
-- extension.approve stores capabilities as a JSON round-trip
-- (extension.approved_capabilities decodes it back), and dkjson's own
-- encode has no canonical key ordering: two Lua tables built from the
-- exact same JSON can iterate their hash parts in different orders, so
-- comparing json.encode(a) == json.encode(b) string-for-string is
-- unreliable (this broke every capabilities.tools comparison the
-- first time it was tried -- see tst/integration/extension.bats'
-- tool-demo cases).
function deep_equal(a, b)
    if type(a) != type(b) then
        return false
    end
    if type(a) != "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if deep_equal(v, b[k]) == false then
            return false
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function tool_spec_equal(a, b)
    return a.name == b.name and a.description == b.description
        and a.destructive == b.destructive
        and deep_equal(a.parameters, b.parameters)
end

-- Same-shape comparison for capabilities.tools -- like capabilities.ui,
-- its presence is a real grant (a new tool the chat agent can call), so
-- editing a declared tool's description/parameters/destructive flag --
-- not just adding/removing one -- has to invalidate approval too.
function tools_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    if #a != #b then
        return false
    end
    for i, tool in ipairs(a) do
        if tool_spec_equal(tool, b[i]) == false then
            return false
        end
    end
    return true
end

function extension.capabilities_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    if string_sets_equal(a.read, b.read) == false then
        return false
    end
    if string_sets_equal(a.write, b.write) == false then
        return false
    end
    a_net = a.net
    if a_net == nil then a_net = "none" end
    b_net = b.net
    if b_net == nil then b_net = "none" end
    if a_net != b_net then
        return false
    end
    if ui_equal(a.ui, b.ui) == false then
        return false
    end
    return tools_equal(a.tools, b.tools)
end

-- ---- Admin-approval registry ----
--
-- Approving records the EXACT capabilities table present at approval
-- time. A manifest edited afterward to request more is treated as
-- unapproved again (extension.is_approved compares current vs. stored),
-- not silently granted the escalation -- see doc/extensibility.md,
-- "What extensions cannot do".

function extension.approved_capabilities(db_path, name)
    extension.init_schema(db_path)
    rows = db.query(db_path, "SELECT capabilities_json FROM extension_approval WHERE name = " .. db.quote(name) .. ";")
    if rows == nil or #rows == 0 then
        return nil
    end
    return json.decode(rows[1].capabilities_json)
end

function extension.is_approved(db_path, manifest)
    approved = extension.approved_capabilities(db_path, manifest.name)
    if approved == nil then
        return false
    end
    return extension.capabilities_equal(approved, manifest.capabilities)
end

function extension.approve(db_path, manifest, approved_by)
    extension.init_schema(db_path)
    caps = manifest.capabilities
    if caps == nil then caps = {} end
    caps_json = json.encode(caps)
    db.exec(db_path, string.format(
        "%s extension_approval (name, capabilities_json, approved_by, approved_at) VALUES (%s, %s, %s, %s);",
        db.replace_into(db_path),
        db.quote(manifest.name), db.quote(caps_json), db.literal(approved_by), db.now_expr(db_path)
    ))
end

function extension.revoke(db_path, name)
    extension.init_schema(db_path)
    db.exec(db_path, "DELETE FROM extension_approval WHERE name = " .. db.quote(name) .. ";")
end

-- ---- Sandboxed invocation ----
--
-- Loads an extension's main.lua inside the capability-scoped sandbox
-- its manifest describes, and returns its hooks table (return
-- {on_before = ..., on_after = ...}, the same convention manifest.lua
-- already uses -- never a bare top-level `function on_before() end`
-- read back out of env afterward: a bare function statement is
-- implicit-local (see doc/why-luam.md), so it would compile to a real
-- local invisible to this file no matter what env the chunk ran under;
-- setfenv only ever redirects a *global* read/write, and a local was
-- never one).
--
-- Shared by extension.invoke (entity hooks) and the UI-route/action
-- dispatch (cgi.lua) -- both need "load this extension's code, get its
-- hooks table" and nothing else; what they call on that table differs
-- per call site. Returns (nil, nil) -- not an error -- when main.lua
-- doesn't return a hooks table at all, so a manifest can declare
-- interest in an event/route without every extension needing to
-- implement every hook it might see. Returns (nil, err) only for a
-- genuine load/run failure.
function extension.load_hooks(ext_dir, name, manifest)
    main_src, err = extension.load_main_source(ext_dir, name)
    if main_src == nil then
        return nil, err
    end
    env = sandbox.extension_env(manifest.capabilities)
    main_path = paths.joinpath(ext_dir, name, "main.lua")
    load_ok, hooks = sandbox.run(main_src, main_path, env)
    if load_ok == false then
        return nil, "error running extension main.lua: " .. tostring(hooks)
    end
    if type(hooks) != "table" then
        return nil, nil
    end
    return hooks, nil
end

-- Calls hook_name (e.g. "on_before"/"on_after") from an extension's
-- hooks table. `ctx` is built by the caller (entity.lua owns
-- ctx.query/create_entity/update_entity, since it owns entity CRUD).
-- Returns (true, nil) if main.lua doesn't define hook_name at all, or
-- has no hooks table at all -- see extension.load_hooks' own comment.
function extension.invoke(ext_dir, name, manifest, hook_name, new_values, old_values, ctx)
    hooks, err = extension.load_hooks(ext_dir, name, manifest)
    if hooks == nil then
        if err != nil then
            return false, err
        end
        return true, nil
    end
    hook_fn = hooks[hook_name]
    if type(hook_fn) != "function" then
        return true, nil
    end
    return pcall(hook_fn, new_values, old_values, ctx)
end

-- ---- After-hook job queue ----

-- Enqueues one job per matching, approved extension. Unapproved
-- extensions are silently skipped here (not an error) -- approval is an
-- opt-in gate, not a misconfiguration.
function extension.enqueue_after_hooks(db_path, ext_dir, event_name, entity_type, entity_id, new_values, old_values)
    extension.init_schema(db_path)
    for _, entry in ipairs(extension.matching(ext_dir, event_name, entity_type)) do
        if extension.is_approved(db_path, entry.manifest) then
            new_json = nil
            if new_values != nil then
                new_json = json.encode(new_values)
            end
            old_json = nil
            if old_values != nil then
                old_json = json.encode(old_values)
            end
            db.exec(db_path, string.format(
                "INSERT INTO extension_job (extension_name, event_name, entity_type, entity_id, new_values_json, old_values_json) VALUES (%s, %s, %s, %d, %s, %s);",
                db.quote(entry.name), db.quote(event_name), db.quote(entity_type), entity_id,
                db.literal(new_json), db.literal(old_json)
            ))
        end
    end
end

function extension.pending_jobs(db_path, limit)
    extension.init_schema(db_path)
    if limit == nil then limit = 50 end
    rows = db.query(db_path, string.format(
        "SELECT * FROM extension_job WHERE status = 'pending' AND attempts < %d ORDER BY job_id ASC LIMIT %d;",
        config.platform_config().extension_max_job_attempts, limit
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function extension.mark_job_done(db_path, job)
    db.exec(db_path, string.format(
        "UPDATE extension_job SET status = 'done', updated_at = %s WHERE job_id = %d;",
        db.now_expr(db_path), tonumber(job.job_id)
    ))
end

-- A job keeps status='pending' (so it's retried) until it has failed
-- extension_max_job_attempts times, at which point it moves to 'failed'
-- and is no longer picked up -- one broken extension's job retries
-- forever inside its own row, never blocking or affecting any other job.
function extension.mark_job_failed(db_path, job, message)
    attempts = tonumber(job.attempts) + 1
    status = "pending"
    if attempts >= config.platform_config().extension_max_job_attempts then
        status = "failed"
    end
    db.exec(db_path, string.format(
        "UPDATE extension_job SET status = %s, attempts = %d, last_error = %s, updated_at = %s WHERE job_id = %d;",
        db.quote(status), attempts, db.quote(message), db.now_expr(db_path), tonumber(job.job_id)
    ))
end

return extension
