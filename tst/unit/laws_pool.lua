-- tst/unit/laws_pool.lua
-- Formal algebraic & stateful laws for knowledge-pool thermodynamics (Law L1).
-- Exercises both pure operators (`laws.forall`) and full database transitions
-- (`laws.state_machine` + `verify.pool_thermodynamics` / `verify.ledger_projection`).

laws = require("laws")
unit = require("unit")
check = unit.check
tests = unit.suite()

lfs = require("lfs")
init = require("init")
db = require("database")
schema = require("schema")
entity = require("entity")
document = require("document")
knowledge = require("knowledge")
duplicate = require("duplicate")
verify = require("verify")

ORIGIN_CWD = lfs.currentdir()
package.path = ORIGIN_CWD .. "/src/?.lua;" .. ORIGIN_CWD .. "/tst/lib/?.lua;" .. package.path

function make_pool_env()
    dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    pf = io.open(dir .. "/platform.lua", "w")
    io.write(pf, """return {agent_provider = "test", search_provider = "test", embedding_quiet_minutes = 0, tag_min_text = 0, agent_turn_mode = "inline", search_review_mode = "inline"}""")
    io.close(pf)
    lfs.chdir(dir)
    init.do_init({}, dir)
    db_path = dir .. "/.store/store.db"
    document.init_schema(db_path)
    knowledge.init_schema(db_path)
    return {dir = dir, db_path = db_path}
end

function cleanup_pool_env(sut)
    lfs.chdir(ORIGIN_CWD)
    if sut != nil and sut.dir != nil then
        os.execute("rm -rf '" .. sut.dir .. "'")
    end
end

-- Pure model of the log-space zero-sum reinforcement step on a vector of
-- positive weights (raw_heats[i], log_saws[i]) with global log_pool_scale L.
function step_pure_pool(raw_heats, log_saws, log_scale, target_idx, delta)
    n = #raw_heats
    total_cap = n * document.base_heat()
    if n <= 1 or delta <= 0.0 then
        return raw_heats, log_saws, log_scale
    end
    f = math.max(0.0, (total_cap - delta) / total_cap)
    if f <= 0.0 then
        return raw_heats, log_saws, log_scale
    end
    next_L = log_scale + math.log(f)
    extracted = (1.0 - f) * total_cap
    x_eff = raw_heats[target_idx] * math.exp(log_scale - log_saws[target_idx])
    next_raw = {}
    next_saw = {}
    for i = 1, n do
        next_raw[i] = raw_heats[i]
        next_saw[i] = log_saws[i]
    end
    next_raw[target_idx] = (x_eff * f) + extracted
    next_saw[target_idx] = next_L
    return next_raw, next_saw, next_L
end

function tests.pure_conservation_and_bystander_ratio_laws()
    print("Testing Law L1.1 & L1.2: zero-sum conservation and bystander ratio invariance across random pools")
    pool_case_gen = laws.bind(laws.int(2, 30), function(n)
        return laws.record({
            n = laws.constant(n),
            weights = laws.list(laws.real(0.05, 5.0), {min_len = n, max_len = n}),
            log_offsets = laws.list(laws.real(-20.0, 20.0), {min_len = n, max_len = n}),
            base_log_scale = laws.real(-5000.0, 50.0),
            target = laws.int(1, n),
            delta = laws.real(0.001, n * 0.95),
        })
    end)

    ok = laws.forall("zero-sum conservation & bystander ratio invariance", pool_case_gen, function(tc)
        n = tc.n
        w_sum = 0.0
        for i = 1, n do
            w_sum = w_sum + tc.weights[i]
        end
        raw_heats = {}
        log_saws = {}
        eff_before = {}
        for i = 1, n do
            eff_i = (tc.weights[i] / w_sum) * (n * document.base_heat())
            eff_before[i] = eff_i
            log_saws[i] = tc.base_log_scale + tc.log_offsets[i]
            raw_heats[i] = eff_i * math.exp(log_saws[i] - tc.base_log_scale)
        end

        next_raw, next_saw, next_L = step_pure_pool(raw_heats, log_saws, tc.base_log_scale, tc.target, tc.delta)
        sum_after = 0.0
        eff_after = {}
        for i = 1, n do
            ei = document.pool_effective_heat(next_raw[i], next_saw[i], next_L)
            if ei <= 0.0 or ei != ei or ei == math.huge then
                return false, "non-positive or non-finite effective heat at index " .. tostring(i)
            end
            eff_after[i] = ei
            sum_after = sum_after + ei
        end

        if math.abs(sum_after - n * document.base_heat()) > 1e-10 * n then
            return false, string.format("sum drifted: %.15g vs %d", sum_after, n)
        end
        if eff_after[tc.target] <= eff_before[tc.target] then
            return false, "reinforced target did not gain net effective heat"
        end

        -- Bystander ratio invariance: for any two non-target indices y, z, H'(y)/H'(z) == H(y)/H(z)
        if n >= 3 then
            y = 1
            if y == tc.target then y = 2 end
            z = y + 1
            if z == tc.target then z = z + 1 end
            if z <= n then
                r_before = eff_before[y] / eff_before[z]
                r_after = eff_after[y] / eff_after[z]
                if math.abs(r_after - r_before) > 1e-11 * math.max(1.0, r_before) then
                    return false, string.format("bystander ratio drifted: %.15g vs %.15g", r_before, r_after)
                end
            end
        end
        return true
    end, {trials = 120})
    check(ok == true, "pure conservation and bystander ratio laws hold")
end

function tests.lyapunov_equilibrium_contraction_law()
    print("Testing Law L1.3: Lyapunov error contraction |eps'| = f * |eps| on perturbed pools")
    pert_gen = laws.bind(laws.int(2, 20), function(n)
        return laws.record({
            n = laws.constant(n),
            eps = laws.real(-0.4 * n, 2.0 * n),
            target = laws.int(1, n),
            delta = laws.real(0.05, 0.8 * n),
        })
    end)

    ok = laws.forall("Lyapunov contraction toward N * BASE_HEAT", pert_gen, function(tc)
        n = tc.n
        total_actual = n * document.base_heat() + tc.eps
        raw_heats = {}
        log_saws = {}
        for i = 1, n do
            raw_heats[i] = total_actual / n
            log_saws[i] = 0.0
        end
        next_raw, next_saw, next_L = step_pure_pool(raw_heats, log_saws, 0.0, tc.target, tc.delta)
        sum_after = 0.0
        for i = 1, n do
            sum_after = sum_after + document.pool_effective_heat(next_raw[i], next_saw[i], next_L)
        end
        eps_after = sum_after - n * document.base_heat()
        f = (n * document.base_heat() - tc.delta) / (n * document.base_heat())
        if math.abs(eps_after - f * tc.eps) > 1e-10 * math.max(1.0, math.abs(tc.eps)) then
            return false, string.format("expected eps'=%.15g, got %.15g", f * tc.eps, eps_after)
        end
        return true
    end, {trials = 100})
    check(ok == true, "Lyapunov equilibrium contraction holds")
end

function tests.gauge_translation_and_spreading_laws()
    print("Testing Law L1.4 & L1.5: log-gauge translation invariance down to -1e6 and spreading partition")
    gauge_gen = laws.record({
        raw_heat = laws.real(0.01, 50.0),
        diff = laws.real(-20.0, 20.0),
        base = laws.real(-1000.0, 1000.0),
        shift = laws.real(-1000000.0, 1000000.0),
    })

    ok_gauge = laws.commutative_diagram("log-gauge shift invariance", gauge_gen,
        function(g)
            return document.pool_effective_heat(g.raw_heat, g.base, g.base + g.diff)
        end,
        function(g)
            return document.pool_effective_heat(g.raw_heat, g.base + g.shift, g.base + g.diff + g.shift)
        end,
        {trials = 120, tolerance = 1e-11}
    )
    check(ok_gauge == true, "gauge translation invariance holds across [-1e6, +1e6]")

    spread_gen = laws.bind(laws.int(1, 15), function(k)
        return laws.record({
            base_delta = laws.real(0.01, 2.0),
            strengths = laws.list(laws.real(1.0, 25.0), {min_len = k, max_len = k}),
        })
    end)

    ok_spread = laws.forall("weighted spreading sums to SPREADING_ACTIVATION_FACTOR * base_delta", spread_gen, function(sc)
        tot = 0.0
        for _, s in ipairs(sc.strengths) do
            tot = tot + s
        end
        acc = 0.0
        for _, s in ipairs(sc.strengths) do
            share = document.weighted_spreading_delta(sc.base_delta, s, tot)
            if share < 0.0 then
                return false, "negative spreading share"
            end
            acc = acc + share
        end
        expected = sc.base_delta * 0.35
        if math.abs(acc - expected) > 1e-12 then
            return false, string.format("sum %.15g != expected %.15g", acc, expected)
        end
        return true
    end, {trials = 100})
    check(ok_spread == true, "weighted spreading partition law holds")
end

function tests.stateful_pool_thermodynamics_machine()
    print("Testing stateful command traces preserve Law L1 & L2 across create/update/reinforce/search/archive/unarchive/fold/repair")
    topics = {"fermentation", "bioreactor", "auxin", "sucrose", "osmolarity", "viscosity"}

    ok = laws.state_machine({
        name = "knowledge-pool conservation & ledger agreement",
        trials = 14,
        max_steps = 22,
        init = function()
            sut = make_pool_env()
            return sut, {docs = {}, seq = 0}
        end,
        teardown = cleanup_pool_env,
        commands = {
            {
                name = "create_doc",
                weight = 4,
                args = function(model)
                    link_idx_max = math.max(1, #model.docs)
                    return laws.record({
                        topic = laws.one_of(topics),
                        with_link = laws.boolean(),
                        link_idx = laws.int(1, link_idx_max),
                    })
                end,
                run = function(sut, args_val, model)
                    nseq = model.seq + 1
                    title = "Pool Note " .. tostring(nseq)
                    body = "Experimental observation on " .. args_val.topic .. " batch " .. tostring(nseq) .. "."
                    if args_val.with_link and #model.docs >= 1 then
                        idx = ((args_val.link_idx - 1) % #model.docs) + 1
                        body = body .. " See [[" .. model.docs[idx].title .. "]]."
                    end
                    id, issues = entity.create(sut.db_path, "document", {title = title, content = body}, "tester")
                    if id == nil then
                        msg = "unknown"
                        if issues != nil and issues[1] != nil then
                            msg = tostring(issues[1].message)
                        end
                        error("entity.create failed: " .. msg)
                    end
                    return {id = id, title = title}
                end,
                next_model = function(model, _, res)
                    model.seq = model.seq + 1
                    table.insert(model.docs, {id = res.id, title = res.title, archived = false, folded = false})
                end,
            },
            {
                name = "reinforce_doc",
                weight = 4,
                applicable = function(model) return #model.docs >= 1 end,
                args = function(model)
                    return laws.record({
                        idx = laws.int(1, #model.docs),
                        delta = laws.real(0.05, 1.25),
                    })
                end,
                run = function(sut, args_val, model)
                    idx = ((args_val.idx - 1) % #model.docs) + 1
                    document.reinforce_pool_heat(sut.db_path, model.docs[idx].id, args_val.delta)
                    return true
                end,
            },
            {
                name = "search_pool",
                weight = 2,
                applicable = function(model) return #model.docs >= 1 end,
                args = function(_)
                    return laws.one_of(topics)
                end,
                run = function(sut, q, _)
                    knowledge.search_and_log(sut.db_path, q, 5, false, "law-session", "tester")
                    return true
                end,
            },
            {
                name = "archive_doc",
                weight = 3,
                applicable = function(model) return #model.docs >= 1 end,
                args = function(model)
                    -- Intentionally picks already-archived docs too to test idempotence!
                    return laws.int(1, #model.docs)
                end,
                run = function(sut, idx_raw, model)
                    idx = ((idx_raw - 1) % #model.docs) + 1
                    entity.archive(sut.db_path, "document", model.docs[idx].id, "tester")
                    return idx
                end,
                next_model = function(model, _, idx)
                    model.docs[idx].archived = true
                end,
            },
            {
                name = "unarchive_doc",
                weight = 3,
                applicable = function(model) return #model.docs >= 1 end,
                args = function(model)
                    -- Intentionally picks active or folded docs too!
                    return laws.int(1, #model.docs)
                end,
                run = function(sut, idx_raw, model)
                    idx = ((idx_raw - 1) % #model.docs) + 1
                    entity.unarchive(sut.db_path, "document", model.docs[idx].id, "tester")
                    return idx
                end,
                next_model = function(model, _, idx)
                    model.docs[idx].archived = false
                end,
            },
            {
                name = "fold_duplicate",
                weight = 2,
                applicable = function(model) return #model.docs >= 2 end,
                args = function(model)
                    return laws.record({
                        a = laws.int(1, #model.docs),
                        b = laws.int(1, #model.docs),
                    })
                end,
                run = function(sut, args_val, model)
                    ia = ((args_val.a - 1) % #model.docs) + 1
                    ib = ((args_val.b - 1) % #model.docs) + 1
                    if ia == ib then
                        ib = (ia % #model.docs) + 1
                    end
                    copy_doc = model.docs[ia]
                    keep_doc = model.docs[ib]
                    if keep_doc.archived or keep_doc.folded or copy_doc.folded or copy_doc.id == keep_doc.id then
                        return nil
                    end
                    duplicate.fold(sut.db_path, copy_doc.id, keep_doc.id)
                    return ia
                end,
                next_model = function(model, _, folded_idx)
                    if folded_idx != nil then
                        model.docs[folded_idx].archived = true
                        model.docs[folded_idx].folded = true
                    end
                end,
            },
            {
                name = "resync_pool_count",
                weight = 1,
                applicable = function(model) return #model.docs >= 1 end,
                run = function(sut, _, _)
                    document.resync_pool_count(sut.db_path)
                    return true
                end,
            },
        },
        invariants = {
            {
                name = "L1_pool_thermodynamics",
                check = function(sut, _)
                    rep = verify.pool_thermodynamics(sut.db_path)
                    if rep.ok then
                        return true
                    end
                    return false, rep.violations[1].code .. ": " .. rep.violations[1].message
                end,
            },
            {
                name = "L2_ledger_projection",
                check = function(sut, _)
                    rep = verify.ledger_projection(sut.db_path)
                    if rep.ok then
                        return true
                    end
                    return false, rep.violations[1].code .. ": " .. rep.violations[1].message
                end,
            },
        },
    })
    check(ok == true, "stateful knowledge-pool thermodynamics machine passed")
end

unit.run(tests)
