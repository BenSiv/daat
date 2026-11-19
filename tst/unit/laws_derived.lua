-- tst/unit/laws_derived.lua
-- Formal derived-index, forest-acyclicity, tier-provenance, repair-idempotence,
-- and after-hook job queue laws (Laws L3 & L4 + entity.run_pending_jobs).

laws = require("laws")
unit = require("unit")
check = unit.check
tests = unit.suite()

lfs = require("lfs")
init = require("init")
db = require("database")
schema = require("schema")
entity = require("entity")
extension = require("extension")
document = require("document")
reference = require("document.reference")
tag = require("tag")
duplicate = require("document.duplicate")
verify = require("verify")

ORIGIN_CWD = lfs.currentdir()
package.path = ORIGIN_CWD .. "/src/?.lua;" .. ORIGIN_CWD .. "/tst/lib/?.lua;" .. package.path

function make_derived_env()
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    pf = io.open(dir .. "/config.lua", "w")
    io.write(pf, """return {agent = {provider = "test", turn_mode = "inline"}, knowledge = {embedding_quiet_minutes = 0, tag_min_text = 0, search_review_mode = "inline"}, search = {provider = "test"}}""")
    io.close(pf)
    lfs.chdir(dir)
    init.do_init({}, dir)
    db_path = dir .. "/.store/store.db"
    document.init_schema(db_path)
    reference.init_schema(db_path)
    tag.init_schema(db_path)

    schema.register(db_path, {
        name = "experiment",
        fields = {
            {name = "exp_code", type = "text", required = true, identifier = true},
            {name = "title", type = "text", required = true, display = true},
        },
    })

    return {dir = dir, db_path = db_path}
end

function cleanup_derived_env(sut)
    lfs.chdir(ORIGIN_CWD)
    if sut != nil and sut.dir != nil then
        os.execute("rm -rf '" .. sut.dir .. "'")
    end
end

--------------------------------------------------------------------------
-- State-Machine Handlers (`laws.state_machine`)
--------------------------------------------------------------------------

function derived_sm_init()
    sut = make_derived_env()
    return sut, {exps = {}, tags = {}, docs = {}, memberships = {}, seq = 0}
end

function derived_has_docs_and_tags(model)
    return #model.docs >= 1 and #model.tags >= 1
end

function derived_has_any_item(model)
    return (#model.docs + #model.exps + #model.memberships) >= 1
end

function derived_has_docs(model)
    return #model.docs >= 1
end

function cmd_create_experiment_run(sut, _, model)
    nseq = model.seq + 1
    eid, issues = entity.create(sut.db_path, "experiment", {
        exp_code = "EXP-" .. tostring(100 + nseq),
        title = "Trial Run " .. tostring(nseq),
    }, "tester")
    if eid == nil then
        error("experiment create failed: " .. tostring(issues[1].message))
    end
    return {id = eid, code = "EXP-" .. tostring(100 + nseq)}
end

function cmd_create_experiment_next(model, _, res)
    model.seq = model.seq + 1
    table.insert(model.exps, res)
end

function cmd_create_tag_args(model)
    return laws.record({
        with_parent = laws.boolean(),
        parent_idx = laws.int(1, math.max(1, #model.tags)),
    })
end

function cmd_create_tag_run(sut, args_val, model)
    nseq = model.seq + 1
    vals = {
        label = "tag-topic-" .. tostring(nseq),
        source = "manual",
    }
    if args_val.with_parent and #model.tags >= 1 then
        pidx = ((args_val.parent_idx - 1) % #model.tags) + 1
        p_row = entity.get(sut.db_path, "tag", model.tags[pidx])
        if p_row != nil and (p_row.archived_at == nil or p_row.archived_at == "") then
            vals.parent = model.tags[pidx]
        end
    end
    tid, issues = entity.create(sut.db_path, "tag", vals, "tester")
    if tid == nil then
        error("tag create failed: " .. tostring(issues[1].message))
    end
    return tid
end

function cmd_create_tag_next(model, _, tid)
    model.seq = model.seq + 1
    table.insert(model.tags, tid)
end

function cmd_create_document_args(model)
    return laws.record({
        with_link = laws.boolean(),
        link_idx = laws.int(1, math.max(1, #model.docs)),
        with_exp = laws.boolean(),
        exp_idx = laws.int(1, math.max(1, #model.exps)),
        with_parent = laws.boolean(),
        parent_idx = laws.int(1, math.max(1, #model.docs)),
    })
end

function cmd_create_document_run(sut, args_val, model)
    nseq = model.seq + 1
    title = "Notebook Page " .. tostring(nseq)
    content = "Cell culture protocol step " .. tostring(nseq) .. " with sucrose medium."
    if args_val.with_link and #model.docs >= 1 then
        lidx = ((args_val.link_idx - 1) % #model.docs) + 1
        content = content .. " Related to [[" .. model.docs[lidx].title .. "]]."
    end
    if args_val.with_exp and #model.exps >= 1 then
        eidx = ((args_val.exp_idx - 1) % #model.exps) + 1
        content = content .. " Mentions " .. model.exps[eidx].code .. " directly."
    end
    vals = {title = title, content = content}
    if args_val.with_parent and #model.docs >= 1 then
        pidx = ((args_val.parent_idx - 1) % #model.docs) + 1
        vals.parent_id = model.docs[pidx].id
    end
    did, issues = entity.create(sut.db_path, "document", vals, "tester")
    if did == nil then
        error("document create failed: " .. tostring(issues[1].message))
    end
    document.reindex_embedding(sut.db_path, did)
    return {id = did, title = title}
end

function cmd_create_document_next(model, _, res)
    model.seq = model.seq + 1
    table.insert(model.docs, res)
end

function cmd_tag_membership_args(model)
    return laws.record({
        doc_idx = laws.int(1, #model.docs),
        tag_idx = laws.int(1, #model.tags),
        decision = laws.one_of({"computed", "pinned", "excluded"}),
    })
end

function cmd_tag_membership_run(sut, args_val, model)
    didx = ((args_val.doc_idx - 1) % #model.docs) + 1
    tidx = ((args_val.tag_idx - 1) % #model.tags) + 1
    did = model.docs[didx].id
    tid = model.tags[tidx]
    existing = db.query(sut.db_path, string.format(
        "SELECT id FROM document_tag WHERE document = %d AND tag = %d LIMIT 1;", did, tid))
    if existing != nil and existing[1] != nil then
        mid = tonumber(existing[1].id)
        entity.unarchive(sut.db_path, "document_tag", mid, "tester")
        entity.update(sut.db_path, "document_tag", mid, {decision = args_val.decision}, "tester")
        return mid
    end
    mid, _ = entity.create(sut.db_path, "document_tag", {
        document = did,
        tag = tid,
        decision = args_val.decision,
    }, "tester")
    if mid == nil then
        return nil
    end
    return mid
end

function cmd_tag_membership_next(model, _, mid)
    if mid != nil then
        table.insert(model.memberships, mid)
    end
end

function cmd_archive_or_unarchive_args(_)
    return laws.record({
        kind = laws.one_of({"doc", "exp", "membership"}),
        do_archive = laws.boolean(),
        idx = laws.int(1, 20),
    })
end

function cmd_archive_or_unarchive_run(sut, args_val, model)
    if args_val.kind == "doc" and #model.docs >= 1 then
        i = ((args_val.idx - 1) % #model.docs) + 1
        did = model.docs[i].id
        if args_val.do_archive then
            entity.archive(sut.db_path, "document", did, "tester")
        else
            entity.unarchive(sut.db_path, "document", did, "tester")
            document.reindex_embedding(sut.db_path, did)
        end
    elseif args_val.kind == "exp" and #model.exps >= 1 then
        i = ((args_val.idx - 1) % #model.exps) + 1
        eid = model.exps[i].id
        if args_val.do_archive then
            entity.archive(sut.db_path, "experiment", eid, "tester")
        else
            entity.unarchive(sut.db_path, "experiment", eid, "tester")
        end
    elseif #model.memberships >= 1 then
        i = ((args_val.idx - 1) % #model.memberships) + 1
        mid = model.memberships[i]
        if args_val.do_archive then
            entity.archive(sut.db_path, "document_tag", mid, "tester")
        else
            entity.unarchive(sut.db_path, "document_tag", mid, "tester")
        end
    end
    return true
end

function cmd_perturb_and_repair_run(sut, _, _)
    db.exec(sut.db_path, "DELETE FROM entity_name_index;")
    db.exec(sut.db_path, "DELETE FROM tag_centre;")
    db.exec(sut.db_path, "UPDATE knowledge_pool_state SET document_count = 999 WHERE id = 1;")
    document.resync_all_links(sut.db_path, true)
    reference.rebuild_names(sut.db_path)
    reference.resync_all_documents(sut.db_path)
    tag.rebuild_centres(sut.db_path)
    document.resync_pool_count(sut.db_path)
    return true
end

function inv_all_four_core_laws(sut, _)
    rep = verify.check_all(sut.db_path)
    if rep.ok then
        return true
    end
    v = rep.violations[1]
    return false, v.law .. "/" .. v.code .. ": " .. v.message
end

--------------------------------------------------------------------------
-- Suite Entries
--------------------------------------------------------------------------

function tests.stateful_derived_indexes_and_repair_commutativity()
    print("Testing Laws L3 & L4: derived indexes (links, entity_name_index, tag_centre) + forest acyclicity + repair healing")

    ok = laws.state_machine({
        name = "derived-index agreement & repair healing",
        trials = 12,
        max_steps = 20,
        init = derived_sm_init,
        teardown = cleanup_derived_env,
        commands = {
            {
                name = "create_experiment",
                weight = 3,
                run = cmd_create_experiment_run,
                next_model = cmd_create_experiment_next,
            },
            {
                name = "create_tag",
                weight = 2,
                args = cmd_create_tag_args,
                run = cmd_create_tag_run,
                next_model = cmd_create_tag_next,
            },
            {
                name = "create_document",
                weight = 4,
                args = cmd_create_document_args,
                run = cmd_create_document_run,
                next_model = cmd_create_document_next,
            },
            {
                name = "tag_membership",
                weight = 3,
                applicable = derived_has_docs_and_tags,
                args = cmd_tag_membership_args,
                run = cmd_tag_membership_run,
                next_model = cmd_tag_membership_next,
            },
            {
                name = "archive_or_unarchive",
                weight = 3,
                applicable = derived_has_any_item,
                args = cmd_archive_or_unarchive_args,
                run = cmd_archive_or_unarchive_run,
            },
            {
                name = "perturb_and_repair_derived",
                weight = 2,
                applicable = derived_has_docs,
                run = cmd_perturb_and_repair_run,
            },
        },
        invariants = {
            {
                name = "all_four_core_laws_L1_L2_L3_L4",
                check = inv_all_four_core_laws,
            },
        },
    })
    check(ok == true, "stateful derived-index and repair-healing laws passed")
end

function tests.verify_detects_corruptions_and_run_pending_jobs_lifecycle()
    print("Testing verify.check_all detects deliberate L1/L2/L3/L4 violations and entity.run_pending_jobs drains jobs")
    sut = make_derived_env()
    db_path = sut.db_path

    d1, _ = entity.create(db_path, "document", {title = "Alpha", content = "Links to [[Beta]]."}, "tester")
    entity.create(db_path, "document", {title = "Beta", content = "Target note."}, "tester")
    check(verify.check_all(db_path).ok == true, "clean store passes verify.check_all")

    db.exec(db_path, "UPDATE knowledge_pool_state SET document_count = 77 WHERE id = 1;")
    db.exec(db_path, string.format("UPDATE document SET title = 'Tampered', parent_id = %d, tier = 2 WHERE id = %d;", d1, d1))
    db.exec(db_path, string.format("DELETE FROM document_link WHERE from_document_id = %d;", d1))

    bad = verify.check_all(db_path)
    check(bad.ok == false, "tampered store fails verify.check_all")
    codes = {}
    for _, v in ipairs(bad.violations) do
        codes[v.code] = true
    end
    check(codes["pool_count_mismatch"] == true, "detected L1 pool_count_mismatch")
    check(codes["scalar_field_mismatch"] == true, "detected L2 scalar_field_mismatch")
    check(codes["missing_active_document_link"] == true, "detected L3 missing_active_document_link")
    check(codes["document_parent_cycle"] == true, "detected L4 document_parent_cycle")
    check(codes["unauthorized_document_tier"] == true, "detected L4 unauthorized_document_tier")

    db.exec(db_path, string.format("UPDATE document SET title = 'Alpha', parent_id = NULL, tier = 0 WHERE id = %d;", d1))
    document.resync_all_links(db_path, true)
    document.resync_pool_count(db_path)
    check(verify.check_all(db_path).ok == true, "healed store passes verify.check_all again")

    lfs.mkdir(sut.dir .. "/extensions")
    lfs.mkdir(sut.dir .. "/extensions/audit_hook")
    mf = io.open(sut.dir .. "/extensions/audit_hook/manifest.lua", "w")
    io.write(mf, """
return {
    name = "audit_hook",
    events = {"entity.after_create"},
    entity_types = {"experiment"},
    capabilities = {read = {}, write = {}, net = "none"},
}
""")
    io.close(mf)
    hf = io.open(sut.dir .. "/extensions/audit_hook/main.lua", "w")
    io.write(hf, """
M = {}
function M.on_after(new_values, old_values, ctx)
    if new_values.exp_code == "EXP-FAIL" then
        error("simulated hook failure")
    end
    return true
end
return M
""")
    io.close(hf)

    manifest, merr = extension.load_manifest(sut.dir .. "/extensions", "audit_hook")
    check(manifest != nil, "loaded audit_hook manifest: " .. tostring(merr))

    extension.approve(db_path, manifest, "admin")
    e_ok, _ = entity.create(db_path, "experiment", {exp_code = "EXP-OK", title = "Good Exp"}, "tester")
    e_fail, _ = entity.create(db_path, "experiment", {exp_code = "EXP-FAIL", title = "Bad Exp"}, "tester")
    check(e_ok != nil and e_fail != nil, "created experiments with queued after-hooks")

    res1 = entity.run_pending_jobs(db_path, 10)
    check(res1.ran == 1 and res1.failed == 1, "first run_pending_jobs ran 1 and failed 1")

    extension.revoke(db_path, "audit_hook")
    res2 = entity.run_pending_jobs(db_path, 10)
    check(res2.ran == 0 and res2.failed == 1, "unapproved retry marked failed")

    -- Atomic job claiming prevents double-claim while stale running:<tok> jobs are reclaimed
    extension.approve(db_path, manifest, "admin")
    e_claim, _ = entity.create(db_path, "experiment", {exp_code = "EXP-CLAIM", title = "Claim Exp"}, "tester")
    check(e_claim != nil, "created experiment for claim test")
    jobs = extension.pending_jobs(db_path, 10)
    target_job_id = nil
    for _, j in ipairs(jobs) do
        if tonumber(j.entity_id) == tonumber(e_claim) then
            target_job_id = tonumber(j.job_id)
        end
    end
    check(target_job_id != nil, "found pending job for EXP-CLAIM")
    check(extension.claim_job(db_path, target_job_id) == true, "first claim_job succeeds")
    check(extension.claim_job(db_path, target_job_id) == false, "second concurrent claim_job on fresh running job is refused")

    -- Backdating updated_at past 900s allows reclamation
    db.exec(db_path, string.format(
        "UPDATE system_job SET updated_at = datetime('now', 'localtime', '-1200 seconds') WHERE job_id = %d;",
        target_job_id))
    reclaimed = entity.run_pending_jobs(db_path, 10)
    check(reclaimed.ran == 1, "stale running:<token> job reclaimed and executed, got ran=" .. tostring(reclaimed.ran))

    cleanup_derived_env(sut)
end

unit.run(tests)
