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

extension = {}

DEFAULT_MAX_JOB_ATTEMPTS = 5

-- How many retries make sense before giving up on a job plausibly
-- depends on how flaky a given deployment's own extensions/network are
-- -- not a bare hardcoded literal; real env var override, read fresh
-- per call rather than resolved once at load.
function extension_env_number(name, fallback)
    value = tonumber(os.getenv(name))
    if value == nil then
        return fallback
    end
    return value
end

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

function read_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil
    end
    source = io.read(file, "*all")
    io.close(file)
    return source
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
    return nil
end

-- Loads a manifest from extensions/<name>/manifest.lua, sandboxed the
-- same data-only way a schema file is (see doc/schema.md).
function extension.load_manifest(ext_dir, name)
    manifest_path = paths.joinpath(ext_dir, name, "manifest.lua")
    source = read_file(manifest_path)
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
    source = read_file(main_path)
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
-- already surface via extension.all()/`platform extension list`).
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
    return a_net == b_net
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
-- Loads and calls hook_name (e.g. "on_before"/"on_after") from an
-- extension's main.lua, inside the capability-scoped sandbox its
-- manifest describes. `ctx` is built by the caller (entity.lua owns
-- ctx.query/create_entity/update_entity, since it owns entity CRUD).
-- Returns (true, nil) if main.lua doesn't define hook_name at all --
-- a manifest can declare interest in an event without every extension
-- needing to implement every hook it might see.
function extension.invoke(ext_dir, name, manifest, hook_name, new_values, old_values, ctx)
    main_src, err = extension.load_main_source(ext_dir, name)
    if main_src == nil then
        return false, err
    end
    env = sandbox.extension_env(manifest.capabilities)
    env[hook_name] = nil
    main_path = paths.joinpath(ext_dir, name, "main.lua")
    load_ok, load_err = sandbox.run(main_src, main_path, env)
    if load_ok == false then
        return false, "error running extension main.lua: " .. tostring(load_err)
    end
    hook_fn = env[hook_name]
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
        extension_env_number("EXTENSION_MAX_JOB_ATTEMPTS", DEFAULT_MAX_JOB_ATTEMPTS), limit
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
-- EXTENSION_MAX_JOB_ATTEMPTS times, at which point it moves to 'failed'
-- and is no longer picked up -- one broken extension's job retries
-- forever inside its own row, never blocking or affecting any other job.
function extension.mark_job_failed(db_path, job, message)
    attempts = tonumber(job.attempts) + 1
    status = "pending"
    if attempts >= extension_env_number("EXTENSION_MAX_JOB_ATTEMPTS", DEFAULT_MAX_JOB_ATTEMPTS) then
        status = "failed"
    end
    db.exec(db_path, string.format(
        "UPDATE extension_job SET status = %s, attempts = %d, last_error = %s, updated_at = %s WHERE job_id = %d;",
        db.quote(status), attempts, db.quote(message), db.now_expr(db_path), tonumber(job.job_id)
    ))
end

return extension
