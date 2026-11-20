-- tst/unit/laws_ledger.lua
-- Formal event-sourcing ledger projection & append-only monotonicity laws (Law L2).
-- Exercises scalar, select, reference, multi_select, multi_reference, and
-- multi_polymorphic_reference fields across create, create_batch, update
-- (mutating and no-op), archive (first and repeated), and unarchive (first
-- and repeated), plus entity.counts_by_type cache agreement.

laws = require("laws")
unit = require("unit")
check = unit.check
tests = unit.suite()

lfs = require("lfs")
init = require("init")
db = require("database")
schema = require("schema")
entity = require("entity")
verify = require("verify")

ORIGIN_CWD = lfs.currentdir()
package.path = ORIGIN_CWD .. "/src/?.lua;" .. ORIGIN_CWD .. "/tst/lib/?.lua;" .. package.path

function make_ledger_env()
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    pf = io.open(dir .. "/config.lua", "w")
    io.write(pf, """return {agent = {provider = "test"}, search = {provider = "test"}}""")
    io.close(pf)
    lfs.chdir(dir)
    init.do_init({}, dir)
    db_path = dir .. "/.store/store.db"

    schema.register(db_path, {
        name = "project",
        fields = {
            {name = "code", type = "text", required = true, identifier = true},
            {name = "title", type = "text", required = true, display = true},
        },
    })

    schema.register(db_path, {
        name = "sample",
        fields = {
            {name = "batch_code", type = "text", required = true, identifier = true},
            {name = "mass", type = "number", required = true},
            {name = "phase", type = "select", required = true, values = {"seed", "growth", "harvest"}},
            {name = "project", type = "reference", required = false, entity_type = "project"},
            {name = "flags", type = "multi_select", required = false, values = {"sterile", "frozen", "priority", "qc"}},
            {name = "related_projects", type = "multi_reference", required = false, entity_type = "project"},
            {name = "lineage", type = "multi_polymorphic_reference", required = false, allowed_entity_types = {"project", "sample"}},
        },
    })

    return {dir = dir, db_path = db_path, prev_events = {}}
end

function cleanup_ledger_env(sut)
    lfs.chdir(ORIGIN_CWD)
    if sut != nil and sut.dir != nil then
        os.execute("rm -rf '" .. sut.dir .. "'")
    end
end

function snapshot_events(db_path)
    rows = db.query(db_path, "SELECT event_id, entity_id, entity_type, event_type, field_changes FROM entity_event ORDER BY event_id ASC;")
    if rows == nil then
        return {}
    end
    out = {}
    for i, r in ipairs(rows) do
        out[i] = string.format("%s|%s|%s|%s|%s",
            tostring(r.event_id), tostring(r.entity_id), tostring(r.entity_type),
            tostring(r.event_type), tostring(r.field_changes))
    end
    return out
end

function build_sample_values(spec, model)
    vals = {
        batch_code = "SMP-" .. tostring(spec.code_num),
        mass = spec.mass,
        phase = spec.phase,
        flags = spec.flags,
    }
    if spec.use_proj and #model.projects >= 1 then
        pidx = ((spec.proj_idx - 1) % #model.projects) + 1
        vals.project = model.projects[pidx]
    end
    rel_projs = {}
    if #model.projects >= 1 then
        for _, raw_idx in ipairs(spec.rel_idxs) do
            pidx = ((raw_idx - 1) % #model.projects) + 1
            table.insert(rel_projs, model.projects[pidx])
        end
    end
    vals.related_projects = rel_projs

    lineage = {}
    for _, item in ipairs(spec.poly_specs) do
        if item.use_sample and #model.samples >= 1 then
            sidx = ((item.idx - 1) % #model.samples) + 1
            table.insert(lineage, {type = "sample", id = model.samples[sidx]})
        elseif #model.projects >= 1 then
            pidx = ((item.idx - 1) % #model.projects) + 1
            table.insert(lineage, {type = "project", id = model.projects[pidx]})
        end
    end
    vals.lineage = lineage
    return vals
end

SAMPLE_SPEC_GEN = laws.record({
    code_num = laws.int(100, 999),
    mass = laws.real(0.1, 250.0),
    phase = laws.one_of({"seed", "growth", "harvest"}),
    flags = laws.list(laws.one_of({"sterile", "frozen", "priority", "qc"}), {min_len = 0, max_len = 3}),
    use_proj = laws.boolean(),
    proj_idx = laws.int(1, 10),
    rel_idxs = laws.list(laws.int(1, 10), {min_len = 0, max_len = 3}),
    poly_specs = laws.list(laws.record({
        use_sample = laws.boolean(),
        idx = laws.int(1, 10),
    }), {min_len = 0, max_len = 3}),
})

--------------------------------------------------------------------------
-- State-Machine Handlers (`laws.state_machine`)
--------------------------------------------------------------------------

function ledger_sm_init()
    sut = make_ledger_env()
    return sut, {projects = {}, samples = {}, seq = 0}
end

function ledger_has_samples(model)
    return #model.samples >= 1
end

function ledger_has_any_entity(model)
    return (#model.projects + #model.samples) >= 1
end

function cmd_create_project_run(sut, _, model)
    nseq = model.seq + 1
    pid, issues = entity.create(sut.db_path, "project", {
        code = "PRJ-" .. tostring(nseq),
        title = "Project Alpha " .. tostring(nseq),
    }, "alice")
    if pid == nil then
        error("project create failed: " .. tostring(issues[1].message))
    end
    return pid
end

function cmd_create_project_next(model, _, pid)
    model.seq = model.seq + 1
    table.insert(model.projects, pid)
end

function cmd_create_sample_args(_)
    return SAMPLE_SPEC_GEN
end

function cmd_create_sample_run(sut, spec, model)
    vals = build_sample_values(spec, model)
    sid, issues = entity.create(sut.db_path, "sample", vals, "bob")
    if sid == nil then
        error("sample create failed: " .. tostring(issues[1].message))
    end
    return sid
end

function cmd_create_sample_next(model, _, sid)
    model.seq = model.seq + 1
    table.insert(model.samples, sid)
end

function cmd_batch_samples_args(_)
    return laws.list(SAMPLE_SPEC_GEN, {min_len = 2, max_len = 3})
end

function cmd_batch_samples_run(sut, specs, model)
    batch = {}
    for i, sp in ipairs(specs) do
        v = build_sample_values(sp, model)
        v.batch_code = v.batch_code .. "-B" .. tostring(i)
        table.insert(batch, v)
    end
    ids, issues = entity.create_batch(sut.db_path, "sample", batch, "carol")
    if ids == nil then
        error("sample create_batch failed: " .. tostring(issues[1].message))
    end
    return ids
end

function cmd_batch_samples_next(model, _, ids)
    for _, sid in ipairs(ids) do
        model.seq = model.seq + 1
        table.insert(model.samples, sid)
    end
end

function cmd_update_sample_args(model)
    return laws.record({
        target_idx = laws.int(1, #model.samples),
        noop = laws.boolean(),
        spec = SAMPLE_SPEC_GEN,
    })
end

function cmd_update_sample_run(sut, args_val, model)
    sidx = ((args_val.target_idx - 1) % #model.samples) + 1
    sid = model.samples[sidx]
    if args_val.noop then
        cur = entity.get(sut.db_path, "sample", sid)
        before_len = #snapshot_events(sut.db_path)
        entity.update(sut.db_path, "sample", sid, {
            mass = cur.mass,
            phase = cur.phase,
            flags = cur.flags,
            related_projects = cur.related_projects,
            lineage = cur.lineage,
        }, "bob")
        after_len = #snapshot_events(sut.db_path)
        if after_len != before_len then
            error("no-op entity.update appended a spurious ledger event")
        end
        return true
    end
    vals = build_sample_values(args_val.spec, model)
    uid, issues = entity.update(sut.db_path, "sample", sid, vals, "bob")
    if uid == nil then
        error("sample update failed: " .. tostring(issues[1].message))
    end
    return true
end

function cmd_pick_entity_args(_)
    return laws.record({
        pick_project = laws.boolean(),
        idx = laws.int(1, 20),
    })
end

function cmd_archive_entity_run(sut, args_val, model)
    if args_val.pick_project and #model.projects >= 1 then
        pidx = ((args_val.idx - 1) % #model.projects) + 1
        entity.archive(sut.db_path, "project", model.projects[pidx], "alice")
    elseif #model.samples >= 1 then
        sidx = ((args_val.idx - 1) % #model.samples) + 1
        entity.archive(sut.db_path, "sample", model.samples[sidx], "alice")
    elseif #model.projects >= 1 then
        pidx = ((args_val.idx - 1) % #model.projects) + 1
        entity.archive(sut.db_path, "project", model.projects[pidx], "alice")
    end
    return true
end

function cmd_unarchive_entity_run(sut, args_val, model)
    if args_val.pick_project and #model.projects >= 1 then
        pidx = ((args_val.idx - 1) % #model.projects) + 1
        entity.unarchive(sut.db_path, "project", model.projects[pidx], "alice")
    elseif #model.samples >= 1 then
        sidx = ((args_val.idx - 1) % #model.samples) + 1
        entity.unarchive(sut.db_path, "sample", model.samples[sidx], "alice")
    elseif #model.projects >= 1 then
        pidx = ((args_val.idx - 1) % #model.projects) + 1
        entity.unarchive(sut.db_path, "project", model.projects[pidx], "alice")
    end
    return true
end

function inv_append_only_prefix_monotonicity(sut, _)
    cur_events = snapshot_events(sut.db_path)
    if #cur_events < #sut.prev_events then
        return false, "entity_event shrank from " .. tostring(#sut.prev_events) .. " to " .. tostring(#cur_events)
    end
    for i = 1, #sut.prev_events do
        if cur_events[i] != sut.prev_events[i] then
            return false, "historical entity_event #" .. tostring(i) .. " mutated"
        end
    end
    sut.prev_events = cur_events
    return true
end

function inv_ledger_projection_homomorphism(sut, _)
    rep = verify.ledger_projection(sut.db_path)
    if rep.ok then
        return true
    end
    return false, rep.violations[1].code .. ": " .. rep.violations[1].message
end

function inv_counts_by_type_agreement(sut, _)
    cached = entity.counts_by_type(sut.db_path, {"project", "sample"})
    real_p = entity.count(sut.db_path, "project", false)
    real_s = entity.count(sut.db_path, "sample", false)
    if cached.project != real_p or cached.sample != real_s then
        return false, string.format("counts_by_type (%s, %s) != real (%d, %d)",
            tostring(cached.project), tostring(cached.sample), real_p, real_s)
    end
    return true
end

--------------------------------------------------------------------------
-- Suite Entry
--------------------------------------------------------------------------

function tests.stateful_ledger_projection_and_monotonicity_laws()
    print("Testing Law L2: stateful ledger homomorphism, append-only prefix monotonicity, and counts_by_type cache")

    ok = laws.state_machine({
        name = "ledger projection homomorphism & append-only monotonicity",
        trials = 15,
        max_steps = 25,
        init = ledger_sm_init,
        teardown = cleanup_ledger_env,
        commands = {
            {
                name = "create_project",
                weight = 3,
                run = cmd_create_project_run,
                next_model = cmd_create_project_next,
            },
            {
                name = "create_sample",
                weight = 4,
                args = cmd_create_sample_args,
                run = cmd_create_sample_run,
                next_model = cmd_create_sample_next,
            },
            {
                name = "create_batch_samples",
                weight = 2,
                args = cmd_batch_samples_args,
                run = cmd_batch_samples_run,
                next_model = cmd_batch_samples_next,
            },
            {
                name = "update_sample",
                weight = 4,
                applicable = ledger_has_samples,
                args = cmd_update_sample_args,
                run = cmd_update_sample_run,
            },
            {
                name = "archive_entity",
                weight = 3,
                applicable = ledger_has_any_entity,
                args = cmd_pick_entity_args,
                run = cmd_archive_entity_run,
            },
            {
                name = "unarchive_entity",
                weight = 3,
                applicable = ledger_has_any_entity,
                args = cmd_pick_entity_args,
                run = cmd_unarchive_entity_run,
            },
        },
        invariants = {
            {
                name = "append_only_prefix_monotonicity",
                check = inv_append_only_prefix_monotonicity,
            },
            {
                name = "L2_ledger_projection_homomorphism",
                check = inv_ledger_projection_homomorphism,
            },
            {
                name = "counts_by_type_cache_agreement",
                check = inv_counts_by_type_agreement,
            },
        },
    })
    check(ok == true, "stateful ledger homomorphism and monotonicity laws passed")
end

unit.run(tests)
