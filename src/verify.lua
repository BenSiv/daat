-- Formal store specification & invariant verifier (`daat store verify`).
--
-- Checks four families of algebraic / state invariants directly against any
-- SQLite or MariaDB store (read-only, zero mutations):
--   L1 (`verify.pool_thermodynamics`): Knowledge-pool conservation of total
--       effective heat (`sum H_eff == |D_active| * BASE_HEAT`), strict
--       positivity, `document_count` and `pool_active` exactness, and
--       `document_link.raw_strength >= 1.0`.
--   L2 (`verify.ledger_projection`): Event-sourcing fold homomorphism from
--       `entity_event` onto every registered entity table and its companion
--       multi-value / polymorphic junction tables, plus event-id identity
--       and orphan-row detection.
--   L3 (`verify.derived_indexes`): Agreement between live source tables and
--       derived indexes (`document_link` active outgoing links,
--       `entity_name_index`, and `tag_centre` vector sums / member counts).
--   L4 (`verify.ontology_and_tiers`): Acyclicity of `document.parent_id` and
--       active `tag.parent` forests, plus tier-ladder provenance (`tier > 0`
--       implies `knowledge.can_hold_tier(source_type)`).

db = require("database")
json = require("dkjson")
schema = require("schema")
entity = require("entity")
document = require("document")
reference = require("reference")
tag = require("tag")
knowledge = require("knowledge")

verify = {}

VERIFY_LINK_PATTERN = "%[%[([^%[%]\n]+)%]%]"
VERIFY_SKIPPED_NAME_TYPES = {
    document = true,
    document_tag = true,
    tag = true,
    tag_relation = true,
    tag_evidence = true,
}

function sql_is_blank(v)
    return v == nil or tostring(v) == ""
end

function has_column(db_path, table_name, col_name)
    for _, c in ipairs(db.get_columns(db_path, table_name)) do
        if c == col_name then
            return true
        end
    end
    return false
end

function is_finite_number(x)
    if type(x) != "number" then
        return false
    end
    if x != x then
        return false
    end
    if x == math.huge or x == -math.huge then
        return false
    end
    return true
end

function make_violation(law, code, message, details)
    v = {
        law = law,
        code = code,
        message = message,
    }
    if details != nil then
        v.details = details
    end
    return v
end

--------------------------------------------------------------------------
-- Law L1: Knowledge-pool thermodynamics & conservation of heat
--------------------------------------------------------------------------

function verify.pool_thermodynamics(db_path)
    violations = {}
    if db.table_exists(db_path, "document") == false then
        return {ok = true, violations = violations, active_documents = 0, total_effective_heat = 0.0}
    end

    has_log_saw = has_column(db_path, "document", "log_scale_at_write")
    has_pool_active = has_column(db_path, "document", "pool_active")
    has_merged_into = has_column(db_path, "document", "merged_into")

    select_cols = {"id", "archived_at", "raw_heat"}
    if has_merged_into then
        table.insert(select_cols, "merged_into")
    end
    if has_log_saw then
        table.insert(select_cols, "log_scale_at_write")
    end
    if has_pool_active then
        table.insert(select_cols, "pool_active")
    end

    docs = db.query(db_path, "SELECT " .. table.concat(select_cols, ", ") .. " FROM document ORDER BY id ASC;")
    if docs == nil then
        docs = {}
    end

    active_docs = {}
    for _, d in ipairs(docs) do
        is_active = sql_is_blank(d.archived_at) and (not has_merged_into or sql_is_blank(d.merged_into))
        if has_pool_active then
            flag_active = tonumber(d.pool_active) == 1
            if flag_active != is_active then
                table.insert(violations, make_violation("L1", "pool_active_mismatch",
                    string.format("document #%s has pool_active=%s but active_predicate=%s",
                        tostring(d.id), tostring(d.pool_active), tostring(is_active)),
                    {document_id = tonumber(d.id), pool_active = tonumber(d.pool_active), expected_active = is_active}))
            end
        end
        if is_active then
            table.insert(active_docs, d)
        end
    end

    active_count = #active_docs
    total_eff = 0.0

    if db.table_exists(db_path, "knowledge_pool_state") then
        state_rows = db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")
        if state_rows == nil or state_rows[1] == nil then
            if active_count > 0 then
                table.insert(violations, make_violation("L1", "missing_pool_state",
                    string.format("knowledge_pool_state row 1 is missing while %d active document(s) exist", active_count),
                    {active_count = active_count}))
            end
        else
            recorded_count = tonumber(state_rows[1].document_count)
            log_pool_scale = tonumber(state_rows[1].log_pool_scale)
            if recorded_count != active_count then
                table.insert(violations, make_violation("L1", "pool_count_mismatch",
                    string.format("knowledge_pool_state.document_count=%s does not match active pool count %d",
                        tostring(state_rows[1].document_count), active_count),
                    {recorded_count = recorded_count, active_count = active_count}))
            end
            if not is_finite_number(log_pool_scale) then
                table.insert(violations, make_violation("L1", "invalid_log_pool_scale",
                    "knowledge_pool_state.log_pool_scale is not a finite number",
                    {log_pool_scale = tostring(state_rows[1].log_pool_scale)}))
            elseif active_count > 0 then
                for _, d in ipairs(active_docs) do
                    raw_h = tonumber(d.raw_heat)
                    log_saw = 0.0
                    if has_log_saw then
                        log_saw = tonumber(d.log_scale_at_write)
                    end
                    if not is_finite_number(raw_h) or raw_h <= 0.0 or not is_finite_number(log_saw) then
                        table.insert(violations, make_violation("L1", "invalid_document_heat",
                            string.format("document #%s has invalid raw_heat=%s or log_scale_at_write=%s",
                                tostring(d.id), tostring(d.raw_heat), tostring(d.log_scale_at_write)),
                            {document_id = tonumber(d.id)}))
                    else
                        eff = raw_h * math.exp(log_pool_scale - log_saw)
                        if not is_finite_number(eff) or eff <= 0.0 then
                            table.insert(violations, make_violation("L1", "non_positive_effective_heat",
                                string.format("document #%s effective heat underflowed or overflowed (%s)",
                                    tostring(d.id), tostring(eff)),
                                {document_id = tonumber(d.id), effective_heat = tostring(eff)}))
                        else
                            total_eff = total_eff + eff
                        end
                    end
                end
                expected_total = active_count * document.base_heat()
                tol = math.max(1e-6, 1e-9 * active_count)
                if math.abs(total_eff - expected_total) > tol then
                    table.insert(violations, make_violation("L1", "heat_conservation_drift",
                        string.format("sum(effective_heat)=%.12f differs from |D_active|*BASE_HEAT=%.12f by %.3e (tol %.3e)",
                            total_eff, expected_total, total_eff - expected_total, tol),
                        {total_effective_heat = total_eff, expected_total = expected_total, drift = total_eff - expected_total}))
                end
            end
        end
    elseif active_count > 0 then
        table.insert(violations, make_violation("L1", "missing_pool_state_table",
            "knowledge_pool_state table is missing while active documents exist",
            {active_count = active_count}))
    end

    if db.table_exists(db_path, "document_link") then
        bad_links = db.query(db_path, "SELECT id, from_document_id, raw_strength FROM document_link WHERE raw_strength IS NULL OR raw_strength < 0.999999999999;")
        if bad_links != nil then
            for _, lnk in ipairs(bad_links) do
                table.insert(violations, make_violation("L1", "link_strength_below_floor",
                    string.format("document_link #%s (from #%s) has raw_strength=%s < 1.0",
                        tostring(lnk.id), tostring(lnk.from_document_id), tostring(lnk.raw_strength)),
                    {link_id = tonumber(lnk.id), raw_strength = tonumber(lnk.raw_strength)}))
            end
        end
    end

    return {
        ok = (#violations == 0),
        violations = violations,
        active_documents = active_count,
        total_effective_heat = total_eff,
    }
end

--------------------------------------------------------------------------
-- Law L2: Ledger fold homomorphism & event-id identity
--------------------------------------------------------------------------

function normalize_scalar_for_compare(val, field_type)
    if val == nil or tostring(val) == "" then
        return nil
    end
    if field_type == "number" or field_type == "reference" then
        return tonumber(val)
    end
    return tostring(val)
end

function scalars_equal(a, b, field_type)
    na = normalize_scalar_for_compare(a, field_type)
    nb = normalize_scalar_for_compare(b, field_type)
    if na == nil and nb == nil then
        return true
    end
    if na == nil or nb == nil then
        return false
    end
    if field_type == "number" then
        tol = 1e-9 * math.max(1.0, math.abs(na), math.abs(nb))
        return math.abs(na - nb) <= tol
    end
    return na == nb
end

function multi_set_signature(items, is_ref)
    norm = schema.normalize_multi_value(items)
    seen = {}
    keys = {}
    for _, item in ipairs(norm) do
        k = tostring(item)
        if is_ref then
            n = tonumber(item)
            if n != nil then
                k = tostring(n)
            end
        end
        if seen[k] == nil then
            seen[k] = true
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    return table.concat(keys, "\x1f")
end

function poly_set_signature(items)
    norm = schema.normalize_polymorphic_value(items)
    seen = {}
    keys = {}
    for _, item in ipairs(norm) do
        k = tostring(item.type) .. ":" .. tostring(tonumber(item.id))
        if seen[k] == nil then
            seen[k] = true
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    return table.concat(keys, "\x1f")
end

function verify.ledger_projection(db_path)
    violations = {}
    if db.table_exists(db_path, "entity_event") == false then
        return {ok = true, violations = violations, checked_events = 0, checked_entities = 0}
    end

    events = db.query(db_path, "SELECT event_id, entity_id, entity_type, event_type, field_changes FROM entity_event ORDER BY event_id ASC;")
    if events == nil then
        events = {}
    end

    folded = {}
    for _, ev in ipairs(events) do
        ev_id = tonumber(ev.event_id)
        ent_id = tonumber(ev.entity_id)
        et = tostring(ev.entity_type)
        ev_type = tostring(ev.event_type)

        if ev_type == "create" and ent_id == nil then
            table.insert(violations, make_violation("L2", "null_create_entity_id",
                string.format("entity_event #%s (%s create) has NULL entity_id", tostring(ev.event_id), et),
                {event_id = ev_id, entity_type = et}))
        elseif ent_id == nil then
            table.insert(violations, make_violation("L2", "null_event_entity_id",
                string.format("entity_event #%s (%s %s) has NULL entity_id", tostring(ev.event_id), et, ev_type),
                {event_id = ev_id, entity_type = et}))
        else
            if folded[et] == nil then
                folded[et] = {}
            end
            state = folded[et][ent_id]
            if ev_type == "create" then
                if ev_id != ent_id then
                    table.insert(violations, make_violation("L2", "create_id_mismatch",
                        string.format("%s #%d create event has event_id=%d != entity_id=%d", et, ent_id, ev_id, ent_id),
                        {entity_type = et, entity_id = ent_id, event_id = ev_id}))
                end
                if state != nil then
                    table.insert(violations, make_violation("L2", "duplicate_create_event",
                        string.format("%s #%d has multiple create events (second at event_id=%d)", et, ent_id, ev_id),
                        {entity_type = et, entity_id = ent_id, event_id = ev_id}))
                else
                    state = {fields = {}, touched = {}, archived = false, last_event_id = ev_id}
                    folded[et][ent_id] = state
                end
                changes = json.decode(ev.field_changes)
                if type(changes) == "table" then
                    for fname, diff in pairs(changes) do
                        if type(diff) == "table" then
                            state.fields[fname] = diff.new
                        else
                            state.fields[fname] = nil
                        end
                        state.touched[fname] = true
                    end
                end
                state.last_event_id = ev_id
            elseif state == nil then
                table.insert(violations, make_violation("L2", "event_without_create",
                    string.format("entity_event #%d (%s #%d %s) has no preceding create event", ev_id, et, ent_id, ev_type),
                    {event_id = ev_id, entity_type = et, entity_id = ent_id}))
            elseif ev_type == "update" then
                changes = json.decode(ev.field_changes)
                if type(changes) == "table" then
                    for fname, diff in pairs(changes) do
                        new_val = nil
                        if type(diff) == "table" then
                            new_val = diff.new
                        end
                        if fname == "archived_at" then
                            state.archived = (not sql_is_blank(new_val))
                        else
                            state.fields[fname] = new_val
                            state.touched[fname] = true
                        end
                    end
                end
                state.last_event_id = ev_id
            elseif ev_type == "archive" then
                state.archived = true
                state.last_event_id = ev_id
            else
                table.insert(violations, make_violation("L2", "unknown_event_type",
                    string.format("entity_event #%d has unknown event_type '%s'", ev_id, ev_type),
                    {event_id = ev_id, event_type = ev_type}))
            end
        end
    end

    registered_set = {}
    checked_entities = 0
    for _, type_row in ipairs(schema.list(db_path)) do
        et = type_row.name
        registered_set[et] = true
        if db.table_exists(db_path, et) then
            fields = schema.fields(db_path, et)
            multi_fields = schema.multi_fields_by_name(db_path, et)
            poly_fields = schema.polymorphic_fields_by_name(db_path, et)
            live_rows = entity.list(db_path, et, nil, nil, true)
            live_by_id = {}
            for _, row in ipairs(live_rows) do
                rid = tonumber(row.id)
                live_by_id[rid] = row
                checked_entities = checked_entities + 1
                if folded[et] == nil or folded[et][rid] == nil then
                    table.insert(violations, make_violation("L2", "orphan_projected_row",
                        string.format("projected row %s #%d has no create event in entity_event", et, rid),
                        {entity_type = et, entity_id = rid}))
                end
            end

            if folded[et] != nil then
                for eid, state in pairs(folded[et]) do
                    live = live_by_id[eid]
                    if live == nil then
                        table.insert(violations, make_violation("L2", "missing_projected_row",
                            string.format("ledger entity %s #%d is missing from projected table %s", et, eid, et),
                            {entity_type = et, entity_id = eid}))
                    else
                        live_last = tonumber(live.last_event_id)
                        if live_last != state.last_event_id then
                            table.insert(violations, make_violation("L2", "last_event_id_mismatch",
                                string.format("%s #%d has last_event_id=%s but ledger fold ended at %d",
                                    et, eid, tostring(live.last_event_id), state.last_event_id),
                                {entity_type = et, entity_id = eid, projected = live_last, expected = state.last_event_id}))
                        end

                        live_archived = not sql_is_blank(live.archived_at)
                        if live_archived != state.archived then
                            table.insert(violations, make_violation("L2", "archived_state_mismatch",
                                string.format("%s #%d archived state=%s does not match ledger fold=%s",
                                    et, eid, tostring(live_archived), tostring(state.archived)),
                                {entity_type = et, entity_id = eid, projected = live_archived, expected = state.archived}))
                        end

                        for _, f in ipairs(fields) do
                            fname = f.name
                            if multi_fields[fname] != nil then
                                exp_sig = multi_set_signature(state.fields[fname], f.type == "multi_reference")
                                got_sig = multi_set_signature(live[fname], f.type == "multi_reference")
                                if exp_sig != got_sig then
                                    table.insert(violations, make_violation("L2", "multi_field_mismatch",
                                        string.format("%s #%d multivalue field '%s' differs from ledger fold", et, eid, fname),
                                        {entity_type = et, entity_id = eid, field = fname}))
                                end
                            elseif poly_fields[fname] != nil then
                                exp_sig = poly_set_signature(state.fields[fname])
                                got_sig = poly_set_signature(live[fname])
                                if exp_sig != got_sig then
                                    table.insert(violations, make_violation("L2", "polymorphic_field_mismatch",
                                        string.format("%s #%d polymorphic field '%s' differs from ledger fold", et, eid, fname),
                                        {entity_type = et, entity_id = eid, field = fname}))
                                end
                            else
                                if not scalars_equal(state.fields[fname], live[fname], f.type) then
                                    table.insert(violations, make_violation("L2", "scalar_field_mismatch",
                                        string.format("%s #%d field '%s' projected=%s != ledger=%s",
                                            et, eid, fname, tostring(live[fname]), tostring(state.fields[fname])),
                                        {entity_type = et, entity_id = eid, field = fname,
                                         projected = tostring(live[fname]), expected = tostring(state.fields[fname])}))
                                end
                            end
                        end

                        for _, builtin_col in ipairs({"name", "external_id"}) do
                            if state.touched[builtin_col] == true then
                                if not scalars_equal(state.fields[builtin_col], live[builtin_col], "text") then
                                    table.insert(violations, make_violation("L2", "builtin_field_mismatch",
                                        string.format("%s #%d builtin '%s' projected=%s != ledger=%s",
                                            et, eid, builtin_col, tostring(live[builtin_col]), tostring(state.fields[builtin_col])),
                                        {entity_type = et, entity_id = eid, field = builtin_col}))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for et, entities_map in pairs(folded) do
        if registered_set[et] == nil and db.table_exists(db_path, et) == false then
            count_unreg = 0
            for _, _ in pairs(entities_map) do
                count_unreg = count_unreg + 1
            end
            if count_unreg > 0 then
                table.insert(violations, make_violation("L2", "missing_projected_table",
                    string.format("entity_event has %d entity(s) for missing table '%s'", count_unreg, et),
                    {entity_type = et, count = count_unreg}))
            end
        end
    end

    return {
        ok = (#violations == 0),
        violations = violations,
        checked_events = #events,
        checked_entities = checked_entities,
    }
end

--------------------------------------------------------------------------
-- Law L3: Derived-index agreement (document_link, entity_name_index, tag_centre)
--------------------------------------------------------------------------

function verify.derived_indexes(db_path)
    violations = {}

    -- 3a. document_link agreement with active document [[link]] syntax
    if db.table_exists(db_path, "document") and db.table_exists(db_path, "document_link") then
        doc_rows = db.query(db_path, "SELECT id, content, archived_at FROM document;")
        if doc_rows == nil then
            doc_rows = {}
        end
        active_doc_links = {}
        for _, dr in ipairs(doc_rows) do
            did = tonumber(dr.id)
            if sql_is_blank(dr.archived_at) then
                seen_lt = {}
                content_str = ""
                if dr.content != nil then
                    content_str = tostring(dr.content)
                end
                for _, raw_link in ipairs(document.extract_links(content_str)) do
                    seen_lt[raw_link] = true
                end
                active_doc_links[did] = seen_lt
            end
        end

        link_rows = db.query(db_path, "SELECT id, from_document_id, to_document_id, link_text, archived_at FROM document_link;")
        if link_rows == nil then
            link_rows = {}
        end
        present_active = {}
        present_archived_self = {}
        for _, lr in ipairs(link_rows) do
            from_id = tonumber(lr.from_document_id)
            to_id = tonumber(lr.to_document_id)
            ltext = tostring(lr.link_text)
            is_live_link = sql_is_blank(lr.archived_at)
            if is_live_link then
                if active_doc_links[from_id] == nil then
                    table.insert(violations, make_violation("L3", "active_link_from_inactive_document",
                        string.format("active document_link #%s originates from archived or missing document #%d",
                            tostring(lr.id), from_id),
                        {link_id = tonumber(lr.id), from_document_id = from_id}))
                elseif active_doc_links[from_id][ltext] == nil then
                    table.insert(violations, make_violation("L3", "stale_active_document_link",
                        string.format("active document_link #%s ('[[%s]]') no longer appears in document #%d content",
                            tostring(lr.id), ltext, from_id),
                        {link_id = tonumber(lr.id), from_document_id = from_id, link_text = ltext}))
                else
                    if present_active[from_id] == nil then
                        present_active[from_id] = {}
                    end
                    present_active[from_id][ltext] = true
                end
            else
                -- duplicate.fold intentionally archives a link from keep_id to a folded copy of itself.
                if present_archived_self[from_id] == nil then
                    present_archived_self[from_id] = {}
                end
                present_archived_self[from_id][ltext] = to_id
            end
        end

        for did, expected_set in pairs(active_doc_links) do
            for ltext, _ in pairs(expected_set) do
                has_live = present_active[did] != nil and present_active[did][ltext] == true
                if not has_live then
                    -- Allow an archived link only when duplicate.fold archived a link to a copy merged into `did`.
                    folded_self = false
                    if present_archived_self[did] != nil and present_archived_self[did][ltext] != nil then
                        target_id = present_archived_self[did][ltext]
                        if target_id == did then
                            folded_self = true
                        elseif has_column(db_path, "document", "merged_into") then
                            mrows = db.query(db_path, string.format(
                                "SELECT merged_into FROM document WHERE id = %d;", target_id))
                            if mrows != nil and mrows[1] != nil and tonumber(mrows[1].merged_into) == did then
                                folded_self = true
                            end
                        end
                    end
                    if not folded_self then
                        table.insert(violations, make_violation("L3", "missing_active_document_link",
                            string.format("document #%d contains '[[%s]]' with no active document_link row", did, ltext),
                            {from_document_id = did, link_text = ltext}))
                    end
                end
            end
        end
    end

    -- 3b. entity_name_index agreement with active named entities
    if db.table_exists(db_path, "entity_name_index") then
        expected_names = {}
        expected_count = 0
        for _, type_row in ipairs(schema.list(db_path)) do
            et = type_row.name
            if VERIFY_SKIPPED_NAME_TYPES[et] == nil and db.table_exists(db_path, et) then
                fields = schema.fields(db_path, et)
                rows = entity.list(db_path, et, nil, nil, false)
                for _, r in ipairs(rows) do
                    eid = tonumber(r.id)
                    for _, item in ipairs(reference.expected_index_rows(fields, r)) do
                        dist_num = 0
                        if item.distinctive then
                            dist_num = 1
                        end
                        sig = et .. "\x1f" .. tostring(eid) .. "\x1f" .. item.key
                        expected_names[sig] = dist_num
                        expected_count = expected_count + 1
                    end
                end
            end
        end

        actual_rows = db.query(db_path, "SELECT name_key, entity_type, entity_id, distinctive FROM entity_name_index;")
        if actual_rows == nil then
            actual_rows = {}
        end
        seen_actual = {}
        for _, ar in ipairs(actual_rows) do
            sig = tostring(ar.entity_type) .. "\x1f" .. tostring(tonumber(ar.entity_id)) .. "\x1f" .. tostring(ar.name_key)
            act_dist = tonumber(ar.distinctive)
            if seen_actual[sig] == true then
                table.insert(violations, make_violation("L3", "duplicate_entity_name_index_row",
                    string.format("duplicate entity_name_index row for %s #%s key '%s'",
                        tostring(ar.entity_type), tostring(ar.entity_id), tostring(ar.name_key)),
                    {entity_type = ar.entity_type, entity_id = tonumber(ar.entity_id), name_key = ar.name_key}))
            else
                seen_actual[sig] = true
                if expected_names[sig] == nil then
                    table.insert(violations, make_violation("L3", "stale_entity_name_index_row",
                        string.format("unexpected entity_name_index row for %s #%s key '%s'",
                            tostring(ar.entity_type), tostring(ar.entity_id), tostring(ar.name_key)),
                        {entity_type = ar.entity_type, entity_id = tonumber(ar.entity_id), name_key = ar.name_key}))
                elseif expected_names[sig] != act_dist then
                    table.insert(violations, make_violation("L3", "entity_name_distinctive_mismatch",
                        string.format("entity_name_index distinctive=%s != expected %d for %s #%s key '%s'",
                            tostring(ar.distinctive), expected_names[sig], tostring(ar.entity_type),
                            tostring(ar.entity_id), tostring(ar.name_key)),
                        {entity_type = ar.entity_type, entity_id = tonumber(ar.entity_id), name_key = ar.name_key}))
                end
            end
        end

        for sig, _ in pairs(expected_names) do
            if seen_actual[sig] == nil then
                et_part, id_part, key_part = string.match(sig, "^([^\x1f]+)\x1f([^\x1f]+)\x1f(.*)$")
                table.insert(violations, make_violation("L3", "missing_entity_name_index_row",
                    string.format("missing entity_name_index row for %s #%s key '%s'",
                        tostring(et_part), tostring(id_part), tostring(key_part)),
                    {entity_type = et_part, entity_id = tonumber(id_part), name_key = key_part}))
            end
        end
    end

    -- 3c. tag_centre agreement with active document_tag + document_embedding
    if db.table_exists(db_path, "tag_centre") and db.table_exists(db_path, "document_tag")
            and db.table_exists(db_path, "document") and db.table_exists(db_path, "document_embedding") then
        dt_rows = db.query(db_path, """
            SELECT dt.document, dt.tag FROM document_tag dt JOIN document d ON d.id = dt.document
            WHERE (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
              AND (d.archived_at IS NULL OR d.archived_at = '')
            ORDER BY dt.id ASC;""")
        if dt_rows == nil then
            dt_rows = {}
        end
        vectors = {}
        missing_vec = {}
        exp_sums = {}
        exp_counts = {}
        for _, r in ipairs(dt_rows) do
            doc_id = tonumber(r.document)
            if vectors[doc_id] == nil and missing_vec[doc_id] == nil then
                vectors[doc_id] = tag.document_vector(db_path, doc_id)
                if vectors[doc_id] == nil then
                    missing_vec[doc_id] = true
                end
            end
            vec = vectors[doc_id]
            if vec != nil then
                tid = tonumber(r.tag)
                if exp_sums[tid] == nil then
                    exp_sums[tid] = {}
                    exp_counts[tid] = 0
                    for i = 1, #vec do
                        exp_sums[tid][i] = 0.0
                    end
                end
                if #exp_sums[tid] == #vec then
                    for i = 1, #vec do
                        exp_sums[tid][i] = exp_sums[tid][i] + vec[i]
                    end
                    exp_counts[tid] = exp_counts[tid] + 1
                end
            end
        end

        tc_rows = db.query(db_path, "SELECT tag_id, members, sum_json FROM tag_centre;")
        if tc_rows == nil then
            tc_rows = {}
        end
        seen_tc = {}
        for _, tc in ipairs(tc_rows) do
            tid = tonumber(tc.tag_id)
            members = tonumber(tc.members)
            seen_tc[tid] = true
            exp_m = exp_counts[tid]
            if exp_m == nil then
                exp_m = 0
            end
            if members != exp_m then
                table.insert(violations, make_violation("L3", "tag_centre_member_mismatch",
                    string.format("tag_centre for tag #%d has members=%s, expected %d", tid, tostring(tc.members), exp_m),
                    {tag_id = tid, members = members, expected_members = exp_m}))
            elseif exp_m > 0 then
                actual_sum = json.decode(tc.sum_json)
                exp_s = exp_sums[tid]
                if type(actual_sum) != "table" or #actual_sum != #exp_s then
                    table.insert(violations, make_violation("L3", "tag_centre_dimension_mismatch",
                        string.format("tag_centre for tag #%d has invalid vector dimension", tid),
                        {tag_id = tid}))
                else
                    max_diff = 0.0
                    for i = 1, #exp_s do
                        diff = math.abs(tonumber(actual_sum[i]) - exp_s[i])
                        if diff > max_diff then
                            max_diff = diff
                        end
                    end
                    if max_diff > 1e-6 * math.max(1, exp_m) then
                        table.insert(violations, make_violation("L3", "tag_centre_vector_drift",
                            string.format("tag_centre for tag #%d drifted by %.3e from member embeddings", tid, max_diff),
                            {tag_id = tid, max_diff = max_diff}))
                    end
                end
            end
        end

        for tid, exp_m in pairs(exp_counts) do
            if exp_m > 0 and seen_tc[tid] == nil then
                table.insert(violations, make_violation("L3", "missing_tag_centre",
                    string.format("tag #%d has %d embedded member(s) but no tag_centre row", tid, exp_m),
                    {tag_id = tid, expected_members = exp_m}))
            end
        end
    end

    return {
        ok = (#violations == 0),
        violations = violations,
    }
end

--------------------------------------------------------------------------
-- Law L4: Forest acyclicity (document.parent_id, tag.parent) & tier provenance
--------------------------------------------------------------------------

function detect_parent_cycles(parent_of, law_code, label_prefix, violations)
    state = {}
    ids = {}
    for id, _ in pairs(parent_of) do
        table.insert(ids, id)
    end
    table.sort(ids)

    for _, start_id in ipairs(ids) do
        if state[start_id] == nil then
            path = {}
            on_path = {}
            cur = start_id
            while cur != nil and parent_of[cur] != nil do
                if on_path[cur] == true then
                    table.insert(violations, make_violation("L4", law_code,
                        string.format("%s #%d participates in a parent cycle (revisited #%d)", label_prefix, start_id, cur),
                        {id = start_id, cycle_at = cur}))
                    break
                end
                if state[cur] == 2 then
                    break
                end
                on_path[cur] = true
                table.insert(path, cur)
                p = parent_of[cur]
                if p == false then
                    break
                end
                cur = p
            end
            for _, visited_id in ipairs(path) do
                state[visited_id] = 2
            end
        end
    end
end

function verify.ontology_and_tiers(db_path)
    violations = {}

    if db.table_exists(db_path, "document") then
        has_tier = has_column(db_path, "document", "tier")
        has_stype = has_column(db_path, "document", "source_type")
        has_parent = has_column(db_path, "document", "parent_id")

        cols = {"id"}
        if has_parent then
            table.insert(cols, "parent_id")
        end
        if has_tier then
            table.insert(cols, "tier")
        end
        if has_stype then
            table.insert(cols, "source_type")
        end

        drows = db.query(db_path, "SELECT " .. table.concat(cols, ", ") .. " FROM document;")
        if drows == nil then
            drows = {}
        end
        doc_parent = {}
        for _, r in ipairs(drows) do
            did = tonumber(r.id)
            p = false
            if has_parent and not sql_is_blank(r.parent_id) then
                p = tonumber(r.parent_id)
            end
            doc_parent[did] = p

            if has_tier and not sql_is_blank(r.tier) then
                tval = tonumber(r.tier)
                if tval == nil or tval < 0 or tval > 3 or math.floor(tval) != tval then
                    table.insert(violations, make_violation("L4", "invalid_document_tier",
                        string.format("document #%d has out-of-range tier=%s", did, tostring(r.tier)),
                        {document_id = did, tier = r.tier}))
                elseif tval > 0 then
                    stype = nil
                    if has_stype and not sql_is_blank(r.source_type) then
                        stype = tostring(r.source_type)
                    end
                    if not knowledge.can_hold_tier(stype) then
                        table.insert(violations, make_violation("L4", "unauthorized_document_tier",
                            string.format("document #%d holds tier %d with non-curated source_type=%s",
                                did, tval, tostring(stype)),
                            {document_id = did, tier = tval, source_type = stype}))
                    end
                end
            end
        end
        detect_parent_cycles(doc_parent, "document_parent_cycle", "document", violations)
    end

    if db.table_exists(db_path, "tag") and has_column(db_path, "tag", "parent") then
        trows = db.query(db_path, "SELECT id, parent, archived_at FROM tag;")
        if trows == nil then
            trows = {}
        end
        tag_parent = {}
        for _, r in ipairs(trows) do
            if sql_is_blank(r.archived_at) then
                tid = tonumber(r.id)
                p = false
                if not sql_is_blank(r.parent) then
                    p = tonumber(r.parent)
                end
                tag_parent[tid] = p
            end
        end
        detect_parent_cycles(tag_parent, "tag_parent_cycle", "tag", violations)
    end

    return {
        ok = (#violations == 0),
        violations = violations,
    }
end

--------------------------------------------------------------------------
-- Full store verification & CLI entry point (`daat store verify [--json]`)
--------------------------------------------------------------------------

function verify.check_all(db_path)
    l1 = verify.pool_thermodynamics(db_path)
    l2 = verify.ledger_projection(db_path)
    l3 = verify.derived_indexes(db_path)
    l4 = verify.ontology_and_tiers(db_path)

    all_violations = {}
    for _, sec in ipairs({l1, l2, l3, l4}) do
        for _, v in ipairs(sec.violations) do
            table.insert(all_violations, v)
        end
    end

    return {
        ok = (#all_violations == 0),
        violation_count = #all_violations,
        sections = {
            pool_thermodynamics = l1,
            ledger_projection = l2,
            derived_indexes = l3,
            ontology_and_tiers = l4,
        },
        violations = all_violations,
    }
end

function format_status(ok)
    if ok then
        return "PASS"
    end
    return "FAIL"
end

function verify.do_verify(cmd_args, db_path)
    want_json = false
    for _, a in ipairs(cmd_args) do
        if a == "--json" then
            want_json = true
        elseif a != "verify" then
            print("Usage: daat store verify [--json]")
            os.exit(1)
        end
    end

    report = verify.check_all(db_path)
    if want_json then
        print(json.encode(report))
    else
        l1 = report.sections.pool_thermodynamics
        l2 = report.sections.ledger_projection
        l3 = report.sections.derived_indexes
        l4 = report.sections.ontology_and_tiers
        print(string.format("L1 pool_thermodynamics: %s (%d active document(s), total_heat=%.6f)",
            format_status(l1.ok), l1.active_documents, l1.total_effective_heat))
        print(string.format("L2 ledger_projection:   %s (%d event(s), %d projected entity(s))",
            format_status(l2.ok), l2.checked_events, l2.checked_entities))
        print(string.format("L3 derived_indexes:     %s", format_status(l3.ok)))
        print(string.format("L4 ontology_and_tiers:  %s", format_status(l4.ok)))
        if report.ok then
            print("Store verification passed (0 violations).")
        else
            print(string.format("Store verification FAILED (%d violation(s)):", report.violation_count))
            for _, v in ipairs(report.violations) do
                print(string.format("  [%s/%s] %s", v.law, v.code, v.message))
            end
        end
    end

    if not report.ok then
        os.exit(1)
    end
end

return verify
