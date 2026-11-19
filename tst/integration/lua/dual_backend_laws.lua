-- tst/integration/lua/dual_backend_laws.lua
-- Law L6: Dual-Backend Observational Equivalence (SQLite vs. MariaDB).
--
-- Generates seeded command traces via `laws` and executes each step in lockstep
-- against an isolated SQLite store and an isolated MariaDB database. After
-- every step, asserts:
--   1. `verify.check_all` (Laws L1-L4) passes on BOTH SQLite and MariaDB.
--   2. Ledger event sequences, projected entity rows (including multi-value
--      and polymorphic junctions), knowledge-pool effective heats and counts,
--      active document links, and entity_name_index agree observationally
--      between the two backends.

laws = require("laws")
lfs = require("lfs")
db = require("database")
store = require("store")
ledger = require("ledger")
schema = require("schema")
extension = require("extension")
auth = require("auth")
entity = require("entity")
document = require("document")
knowledge = require("knowledge")
reference = require("document.reference")
tag = require("tag")
duplicate = require("document.duplicate")
verify = require("verify")

ORIGIN_CWD = lfs.currentdir()
package.path = ORIGIN_CWD .. "/src/?.lua;" .. ORIGIN_CWD .. "/tst/lib/?.lua;" .. package.path

HOST = arg[1]
PORT = tonumber(arg[2])
USER = arg[3]
DB_PREFIX = arg[4]
PASSWORD = os.getenv("DAAT_MARIADB_PASSWORD")
if PASSWORD == nil then
    PASSWORD = ""
end

ADMIN_DB = {
    host = HOST,
    port = PORT,
    user = USER,
    password = PASSWORD,
    database = "information_schema",
}

PROJECT_SCHEMA = {
    name = "project",
    fields = {
        {name = "code", type = "text", required = true, identifier = true},
        {name = "title", type = "text", required = true, display = true},
    },
}

SAMPLE_SCHEMA = {
    name = "sample",
    fields = {
        {name = "batch_code", type = "text", required = true, identifier = true},
        {name = "mass", type = "number", required = true},
        {name = "phase", type = "select", required = true, values = {"seed", "growth", "harvest"}},
        {name = "project", type = "reference", required = false, entity_type = "project"},
        {name = "flags", type = "multi_select", required = false, values = {"sterile", "frozen", "priority"}},
        {name = "related_projects", type = "multi_reference", required = false, entity_type = "project"},
        {name = "lineage", type = "multi_polymorphic_reference", required = false, allowed_entity_types = {"project", "sample"}},
    },
}

function init_target(target)
    store.migrate(target)
    ledger.init_schema(target)
    schema.init_schema(target)
    extension.init_schema(target)
    auth.init_schema(target)
    document.init_schema(target)
    knowledge.init_schema(target)
    reference.init_schema(target)
    tag.init_schema(target)
    schema.register(target, PROJECT_SCHEMA)
    schema.register(target, SAMPLE_SCHEMA)
end

TRIAL_COUNTER = 0

function create_dual_stores()
    TRIAL_COUNTER = TRIAL_COUNTER + 1
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    lfs.mkdir(dir .. "/.store")
    lfs.mkdir(dir .. "/extensions")
    pf = io.open(dir .. "/config.lua", "w")
    io.write(pf, """return {agent_provider = "test", search_provider = "test", embedding_quiet_minutes = 0, tag_min_text = 0}""")
    io.close(pf)
    lfs.chdir(dir)

    sqlite_db = dir .. "/.store/store.db"
    mdb_name = DB_PREFIX .. "_l6_" .. tostring(TRIAL_COUNTER)
    db.exec(ADMIN_DB, "DROP DATABASE IF EXISTS " .. mdb_name .. ";")
    db.exec(ADMIN_DB, "CREATE DATABASE " .. mdb_name .. ";")
    mariadb_db = {
        host = HOST,
        port = PORT,
        user = USER,
        password = PASSWORD,
        database = mdb_name,
    }

    db.sqlite_keep_open(true)
    init_target(sqlite_db)
    init_target(mariadb_db)
    return {
        dir = dir,
        sqlite_db = sqlite_db,
        mariadb_db = mariadb_db,
        mdb_name = mdb_name,
    }
end

function destroy_dual_stores(pair)
    db.sqlite_keep_open(false)
    lfs.chdir(ORIGIN_CWD)
    if pair != nil then
        if pair.mdb_name != nil then
            pcall(db.exec, ADMIN_DB, "DROP DATABASE IF EXISTS " .. pair.mdb_name .. ";")
        end
        if pair.dir != nil then
            os.execute("rm -rf '" .. pair.dir .. "'")
        end
    end
end

function qrows(target, sql)
    rows = db.query(target, sql)
    if rows == nil then
        return {}
    end
    return rows
end

function is_blank(v)
    return v == nil or tostring(v) == ""
end

function sorted_set_str(items)
    if type(items) != "table" then
        return ""
    end
    vals = {}
    for _, it in ipairs(items) do
        if type(it) == "table" and it.type != nil then
            table.insert(vals, tostring(it.type) .. ":" .. tostring(tonumber(it.id)))
        else
            table.insert(vals, tostring(it))
        end
    end
    table.sort(vals)
    return table.concat(vals, ",")
end

function compare_rows_by_id(a, b)
    return tonumber(a.id) < tonumber(b.id)
end

function compare_dual_state(s_db, m_db)
    -- 1. All 4 formal store laws hold on both backends independently
    s_ver = verify.check_all(s_db)
    if not s_ver.ok then
        v = s_ver.violations[1]
        return false, "SQLite verify failed: " .. v.law .. "/" .. v.code .. ": " .. v.message
    end
    m_ver = verify.check_all(m_db)
    if not m_ver.ok then
        v = m_ver.violations[1]
        return false, "MariaDB verify failed: " .. v.law .. "/" .. v.code .. ": " .. v.message
    end

    -- 2. Ledger event structural sequence equivalence
    s_ev = qrows(s_db, "SELECT event_id, entity_id, entity_type, event_type FROM entity_event ORDER BY event_id ASC;")
    m_ev = qrows(m_db, "SELECT event_id, entity_id, entity_type, event_type FROM entity_event ORDER BY event_id ASC;")
    if #s_ev != #m_ev then
        return false, string.format("entity_event count mismatch: sqlite=%d vs mariadb=%d", #s_ev, #m_ev)
    end
    for i = 1, #s_ev do
        se = s_ev[i]
        me = m_ev[i]
        if tonumber(se.event_id) != tonumber(me.event_id)
                or tonumber(se.entity_id) != tonumber(me.entity_id)
                or tostring(se.entity_type) != tostring(me.entity_type)
                or tostring(se.event_type) != tostring(me.event_type) then
            return false, string.format("entity_event row %d diverged between SQLite and MariaDB", i)
        end
    end

    -- 3. Projected entity rows equivalence (project, sample, document)
    for _, et in ipairs({"project", "sample", "document"}) do
        s_rows = entity.list(s_db, et, nil, nil, true)
        m_rows = entity.list(m_db, et, nil, nil, true)
        table.sort(s_rows, compare_rows_by_id)
        table.sort(m_rows, compare_rows_by_id)
        if #s_rows != #m_rows then
            return false, string.format("%s row count mismatch: sqlite=%d vs mariadb=%d", et, #s_rows, #m_rows)
        end
        fields = schema.fields(s_db, et)
        for i = 1, #s_rows do
            sr = s_rows[i]
            mr = m_rows[i]
            if tonumber(sr.id) != tonumber(mr.id) then
                return false, string.format("%s id mismatch at index %d", et, i)
            end
            if tonumber(sr.last_event_id) != tonumber(mr.last_event_id) then
                return false, string.format("%s #%s last_event_id mismatch", et, tostring(sr.id))
            end
            if is_blank(sr.archived_at) != is_blank(mr.archived_at) then
                return false, string.format("%s #%s archived state mismatch", et, tostring(sr.id))
            end
            for _, f in ipairs(fields) do
                fn = f.name
                if schema.is_multi_field_type(f.type) or schema.is_polymorphic_field_type(f.type) then
                    if sorted_set_str(sr[fn]) != sorted_set_str(mr[fn]) then
                        return false, string.format("%s #%s junction field '%s' mismatch", et, tostring(sr.id), fn)
                    end
                elseif f.type == "number" or f.type == "reference" then
                    sv = tonumber(sr[fn])
                    mv = tonumber(mr[fn])
                    if (sv == nil) != (mv == nil) then
                        return false, string.format("%s #%s numeric field '%s' nullability mismatch", et, tostring(sr.id), fn)
                    elseif sv != nil and math.abs(sv - mv) > 1e-9 then
                        return false, string.format("%s #%s numeric field '%s' value mismatch", et, tostring(sr.id), fn)
                    end
                else
                    s_txt = ""
                    if not is_blank(sr[fn]) then s_txt = tostring(sr[fn]) end
                    m_txt = ""
                    if not is_blank(mr[fn]) then m_txt = tostring(mr[fn]) end
                    if s_txt != m_txt then
                        return false, string.format("%s #%s text field '%s' mismatch ('%s' vs '%s')", et, tostring(sr.id), fn, s_txt, m_txt)
                    end
                end
            end
        end
    end

    -- 4. Knowledge pool state & per-document effective heat equivalence
    s_ps = qrows(s_db, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
    m_ps = qrows(m_db, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
    if #s_ps != #m_ps then
        return false, "knowledge_pool_state row presence mismatch"
    end
    if #s_ps == 1 then
        if tonumber(s_ps[1].document_count) != tonumber(m_ps[1].document_count) then
            return false, string.format("document_count mismatch: sqlite=%s vs mariadb=%s",
                tostring(s_ps[1].document_count), tostring(m_ps[1].document_count))
        end
        sL = tonumber(s_ps[1].log_pool_scale)
        mL = tonumber(m_ps[1].log_pool_scale)
        if math.abs(sL - mL) > 1e-9 then
            return false, string.format("log_pool_scale diverged: sqlite=%.12f vs mariadb=%.12f", sL, mL)
        end
        s_docs = qrows(s_db, "SELECT id, raw_heat, log_scale_at_write, pool_active FROM document ORDER BY id ASC;")
        m_docs = qrows(m_db, "SELECT id, raw_heat, log_scale_at_write, pool_active FROM document ORDER BY id ASC;")
        for i = 1, #s_docs do
            if tonumber(s_docs[i].pool_active) != tonumber(m_docs[i].pool_active) then
                return false, "pool_active mismatch on document #" .. tostring(s_docs[i].id)
            end
            if tonumber(s_docs[i].pool_active) == 1 then
                s_eff = document.pool_effective_heat(s_docs[i].raw_heat, s_docs[i].log_scale_at_write, sL)
                m_eff = document.pool_effective_heat(m_docs[i].raw_heat, m_docs[i].log_scale_at_write, mL)
                if math.abs(s_eff - m_eff) > 1e-9 then
                    return false, string.format("effective_heat diverged on document #%s: %.12f vs %.12f",
                        tostring(s_docs[i].id), s_eff, m_eff)
                end
            end
        end
    end

    -- 5. Derived indexes equivalence: active document_link + entity_name_index
    s_links = qrows(s_db, "SELECT from_document_id, COALESCE(to_document_id, -1) AS tid, link_text, raw_strength FROM document_link WHERE archived_at IS NULL OR archived_at = '' ORDER BY from_document_id ASC, link_text ASC;")
    m_links = qrows(m_db, "SELECT from_document_id, COALESCE(to_document_id, -1) AS tid, link_text, raw_strength FROM document_link WHERE archived_at IS NULL OR archived_at = '' ORDER BY from_document_id ASC, link_text ASC;")
    if #s_links != #m_links then
        return false, "active document_link count mismatch"
    end
    for i = 1, #s_links do
        if tonumber(s_links[i].from_document_id) != tonumber(m_links[i].from_document_id)
                or tonumber(s_links[i].tid) != tonumber(m_links[i].tid)
                or tostring(s_links[i].link_text) != tostring(m_links[i].link_text)
                or math.abs(tonumber(s_links[i].raw_strength) - tonumber(m_links[i].raw_strength)) > 1e-9 then
            return false, "active document_link row " .. tostring(i) .. " diverged"
        end
    end

    s_names = qrows(s_db, "SELECT entity_type, entity_id, name_key, distinctive FROM entity_name_index ORDER BY entity_type ASC, entity_id ASC, name_key ASC;")
    m_names = qrows(m_db, "SELECT entity_type, entity_id, name_key, distinctive FROM entity_name_index ORDER BY entity_type ASC, entity_id ASC, name_key ASC;")
    if #s_names != #m_names then
        return false, "entity_name_index count mismatch"
    end
    for i = 1, #s_names do
        if tostring(s_names[i].entity_type) != tostring(m_names[i].entity_type)
                or tonumber(s_names[i].entity_id) != tonumber(m_names[i].entity_id)
                or tostring(s_names[i].name_key) != tostring(m_names[i].name_key)
                or tonumber(s_names[i].distinctive) != tonumber(m_names[i].distinctive) then
            return false, "entity_name_index row " .. tostring(i) .. " diverged"
        end
    end

    return true, nil
end

OP_GEN = laws.record({
    op = laws.one_of({
        "create_project", "create_sample", "batch_samples", "update_sample",
        "create_doc", "reinforce_doc", "archive_any", "unarchive_any",
        "fold_doc", "resync_all",
    }),
    idx_a = laws.int(1, 20),
    idx_b = laws.int(1, 20),
    mass = laws.real(0.5, 99.5),
    delta = laws.real(0.1, 0.9),
    phase = laws.one_of({"seed", "growth", "harvest"}),
    flags = laws.list(laws.one_of({"sterile", "frozen", "priority"}), {min_len = 0, max_len = 2}),
    bool_flag = laws.boolean(),
})

function apply_step_on_target(target, step, state, seq)
    op = step.op
    if op == "create_project" then
        id, err = entity.create(target, "project", {
            code = "PRJ-" .. tostring(100 + seq),
            title = "Dual Project " .. tostring(seq),
        }, "alice")
        if id == nil then error("create_project failed: " .. tostring(err[1].message)) end
        return {kind = "project", id = id}
    elseif op == "create_sample" then
        vals = {
            batch_code = "SMP-" .. tostring(100 + seq),
            mass = step.mass,
            phase = step.phase,
            flags = step.flags,
        }
        if #state.projects >= 1 then
            pidx = ((step.idx_a - 1) % #state.projects) + 1
            vals.project = state.projects[pidx]
            vals.related_projects = {state.projects[pidx]}
            vals.lineage = {{type = "project", id = state.projects[pidx]}}
        end
        id, err = entity.create(target, "sample", vals, "bob")
        if id == nil then error("create_sample failed: " .. tostring(err[1].message)) end
        return {kind = "sample", id = id}
    elseif op == "batch_samples" then
        b1 = {batch_code = "BSMP-" .. tostring(seq) .. "-1", mass = step.mass, phase = step.phase, flags = step.flags}
        b2 = {batch_code = "BSMP-" .. tostring(seq) .. "-2", mass = step.mass + 1.0, phase = "growth", flags = {}}
        ids, err = entity.create_batch(target, "sample", {b1, b2}, "carol")
        if ids == nil then error("batch_samples failed: " .. tostring(err[1].message)) end
        return {kind = "samples", ids = ids}
    elseif op == "update_sample" then
        if #state.samples == 0 then return nil end
        sidx = ((step.idx_a - 1) % #state.samples) + 1
        sid = state.samples[sidx]
        if step.bool_flag then
            cur = entity.get(target, "sample", sid)
            entity.update(target, "sample", sid, {mass = cur.mass, phase = cur.phase, flags = cur.flags}, "bob")
        else
            vals = {mass = step.mass, phase = step.phase, flags = step.flags}
            if #state.samples >= 1 then
                lidx = ((step.idx_b - 1) % #state.samples) + 1
                vals.lineage = {{type = "sample", id = state.samples[lidx]}}
            end
            entity.update(target, "sample", sid, vals, "bob")
        end
        return nil
    elseif op == "create_doc" then
        title = "Dual Note " .. tostring(seq)
        body = "Dual backend protocol note " .. tostring(seq) .. "."
        if step.bool_flag and #state.docs >= 1 then
            didx = ((step.idx_a - 1) % #state.docs) + 1
            body = body .. " Links to [[" .. state.docs[didx].title .. "]]."
        end
        if #state.projects >= 1 then
            body = body .. " Mentions PRJ-101."
        end
        id, err = entity.create(target, "document", {title = title, content = body}, "alice")
        if id == nil then error("create_doc failed: " .. tostring(err[1].message)) end
        return {kind = "doc", id = id, title = title}
    elseif op == "reinforce_doc" then
        if #state.docs == 0 then return nil end
        didx = ((step.idx_a - 1) % #state.docs) + 1
        document.reinforce_pool_heat(target, state.docs[didx].id, step.delta)
        return nil
    elseif op == "archive_any" then
        if step.bool_flag and #state.docs >= 1 then
            didx = ((step.idx_a - 1) % #state.docs) + 1
            entity.archive(target, "document", state.docs[didx].id, "alice")
        elseif #state.samples >= 1 then
            sidx = ((step.idx_a - 1) % #state.samples) + 1
            entity.archive(target, "sample", state.samples[sidx], "alice")
        end
        return nil
    elseif op == "unarchive_any" then
        if step.bool_flag and #state.docs >= 1 then
            didx = ((step.idx_a - 1) % #state.docs) + 1
            entity.unarchive(target, "document", state.docs[didx].id, "alice")
        elseif #state.samples >= 1 then
            sidx = ((step.idx_a - 1) % #state.samples) + 1
            entity.unarchive(target, "sample", state.samples[sidx], "alice")
        end
        return nil
    elseif op == "fold_doc" then
        if #state.docs < 2 then return nil end
        ia = ((step.idx_a - 1) % #state.docs) + 1
        ib = ((step.idx_b - 1) % #state.docs) + 1
        if ia == ib then ib = (ia % #state.docs) + 1 end
        c_doc = state.docs[ia]
        k_doc = state.docs[ib]
        c_row = entity.get(target, "document", c_doc.id)
        k_row = entity.get(target, "document", k_doc.id)
        if not is_blank(k_row.archived_at) or not is_blank(k_row.merged_into) or not is_blank(c_row.merged_into) then
            return nil
        end
        duplicate.fold(target, c_doc.id, k_doc.id)
        return nil
    elseif op == "resync_all" then
        document.resync_all_links(target, true)
        reference.rebuild_names(target)
        reference.resync_all_documents(target)
        document.resync_pool_count(target)
        return nil
    end
    return nil
end

TRACE_GEN = laws.list(OP_GEN, {min_len = 12, max_len = 18})

function execute_dual_trace_steps(pair, trace)
    state = {projects = {}, samples = {}, docs = {}}
    for step_idx, step in ipairs(trace) do
        res_s = apply_step_on_target(pair.sqlite_db, step, state, step_idx)
        res_m = apply_step_on_target(pair.mariadb_db, step, state, step_idx)
        if res_s != nil then
            if res_s.kind == "project" then
                if res_s.id != res_m.id then
                    return false, "project id diverged"
                end
                table.insert(state.projects, res_s.id)
            elseif res_s.kind == "sample" then
                if res_s.id != res_m.id then
                    return false, "sample id diverged"
                end
                table.insert(state.samples, res_s.id)
            elseif res_s.kind == "samples" then
                for i, id in ipairs(res_s.ids) do
                    if id != res_m.ids[i] then
                        return false, "batch sample id diverged"
                    end
                    table.insert(state.samples, id)
                end
            elseif res_s.kind == "doc" then
                if res_s.id != res_m.id then
                    return false, "doc id diverged"
                end
                table.insert(state.docs, {id = res_s.id, title = res_s.title})
            end
        end

        eq_ok, eq_msg = compare_dual_state(pair.sqlite_db, pair.mariadb_db)
        if not eq_ok then
            return false, string.format("after step %d (%s): %s", step_idx, step.op, tostring(eq_msg))
        end
    end
    return true, nil
end

function prop_dual_backend_trace(trace)
    pair = create_dual_stores()
    run_ok, err_or_res, fail_reason = pcall(execute_dual_trace_steps, pair, trace)
    destroy_dual_stores(pair)
    if not run_ok then
        return false, "raised error: " .. tostring(err_or_res)
    end
    return err_or_res, fail_reason
end

ok = laws.forall("Law L6: SQLite vs. MariaDB observational equivalence", TRACE_GEN, prop_dual_backend_trace, {trials = 6, max_shrinks = 10})

if not ok then
    os.exit(1)
end
print("Law L6 dual-backend SQLite == MariaDB observational equivalence passed (6 traces).")
