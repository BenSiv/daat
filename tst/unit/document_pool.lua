-- tst/unit/document_pool.lua
-- Unit tests for src/document.lua's conserved heat-pool primitives:
-- reinforce_pool_heat, return_pool_heat, register_pool_document,
-- resync_pool_count, and the conservation + idempotence + log-space
-- underflow-freedom laws they hold across all state transitions.

document = require("document")
db = require("database")
entity = require("entity")

-- Bare tables here (no entity registry), so unarchive's re-read of
-- the document's links and references finds nothing to read.
entity.get = function() return nil end

unit = require("unit")
check = unit.check
tests = unit.suite()

function close_enough(a, b, tolerance)
    if tolerance == nil then
        tolerance = 0.0000001
    end
    return math.abs(a - b) < tolerance
end

function new_test_db(document_count)
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document (id INTEGER PRIMARY KEY, raw_heat REAL DEFAULT 1.0, scale_at_write REAL DEFAULT 1.0, log_scale_at_write REAL NOT NULL DEFAULT 0.0, pool_active INTEGER NOT NULL DEFAULT 0, archived_at TEXT, merged_into INTEGER);")
    db.exec(db_path, "CREATE TABLE document_embedding (document_id INTEGER PRIMARY KEY);")
    db.exec(db_path, "CREATE TABLE document_embedding_due (document_id INTEGER PRIMARY KEY, queued_at TEXT);")
    db.exec(db_path, "CREATE TABLE document_aspect (document_id INTEGER, aspect INTEGER);")
    db.exec(db_path, "CREATE TABLE document_mention (document_id INTEGER);")
    db.exec(db_path, "CREATE TABLE document_link_sync (document_id INTEGER PRIMARY KEY, content_hash VARCHAR(64) NOT NULL);")
    db.exec(db_path, "CREATE TABLE document_tag (id INTEGER PRIMARY KEY, document INTEGER, tag INTEGER, decision TEXT, archived_at TEXT);")
    db.exec(db_path, "CREATE TABLE entity_name_index (name_key TEXT, entity_type TEXT, entity_id INTEGER);")
    db.exec(db_path, "CREATE TABLE document_link (id INTEGER PRIMARY KEY AUTOINCREMENT, from_document_id INTEGER NOT NULL, to_document_id INTEGER, link_text TEXT NOT NULL, link_hash CHAR(64) NOT NULL, raw_strength REAL NOT NULL DEFAULT 1.0, archived_at TEXT DEFAULT NULL, created_at TEXT DEFAULT NULL);")
    for i = 1, document_count do
        db.exec(db_path, string.format("INSERT INTO document (id, raw_heat, scale_at_write, log_scale_at_write, pool_active) VALUES (%d, 1.0, 1.0, 0.0, 1);", i))
    end
    return db_path
end

function pool_total(db_path, document_ids)
    document.ensure_pool_state(db_path)
    rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = tonumber(rows[1].log_pool_scale)
    total = 0.0
    for _, id in ipairs(document_ids) do
        doc_rows = db.query(db_path, string.format("SELECT raw_heat, log_scale_at_write FROM document WHERE id = %d;", id))
        total = total + document.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].log_scale_at_write, log_pool_scale)
    end
    return total
end

function tests.reinforcement_conserves_total_across_the_pool()
    print("Testing a single reinforcement leaves the pool's total heat unchanged")
    db_path = new_test_db(3)
    before = pool_total(db_path, {1, 2, 3})
    document.reinforce_pool_heat(db_path, 1, 0.5)
    after = pool_total(db_path, {1, 2, 3})
    check(close_enough(before, 3.0), "3 fresh documents should start at total 3.0, got " .. tostring(before))
    check(close_enough(after, before), "reinforcement should conserve the total, before=" .. tostring(before) .. " after=" .. tostring(after))
    os.remove(db_path)
end

function tests.reinforcement_gives_the_reinforced_document_the_extracted_amount()
    print("Testing the reinforced document gains exactly the extracted amount, not the raw nominal delta")
    db_path = new_test_db(3)
    delta = 0.5
    denominator = 2.0
    expected = 1.0 + denominator * (1 - math.exp(-(delta / denominator)))
    new_heat = document.reinforce_pool_heat(db_path, 1, delta)
    check(close_enough(new_heat, expected), "document 1 should read " .. tostring(expected) .. " after a +0.5 reinforcement, got " .. tostring(new_heat))
    check(new_heat < 1.0 + delta, "extracted must be strictly less than the raw nominal delta once the pool isn't infinite")
    os.remove(db_path)
end

function tests.reinforcement_shrinks_every_other_document_by_the_same_factor()
    print("Testing every OTHER document shrinks, and by the same proportional factor")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = tonumber(rows[1].log_pool_scale)
    doc2 = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 2;")[1]
    doc3 = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 3;")[1]
    heat2 = document.pool_effective_heat(doc2.raw_heat, doc2.log_scale_at_write, log_pool_scale)
    heat3 = document.pool_effective_heat(doc3.raw_heat, doc3.log_scale_at_write, log_pool_scale)
    check(heat2 < 1.0, "document 2 should have cooled below its starting 1.0, got " .. tostring(heat2))
    check(close_enough(heat2, heat3), "documents 2 and 3 started equal and weren't reinforced, so they should still be equal")
    os.remove(db_path)
end

function tests.repeated_reinforcement_of_different_documents_still_conserves_total()
    print("Testing a sequence of reinforcements across different documents still conserves the total")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.3)
    document.reinforce_pool_heat(db_path, 2, 0.2)
    document.reinforce_pool_heat(db_path, 1, 0.15)
    document.reinforce_pool_heat(db_path, 3, 0.4)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total should still be 3.0 after 4 reinforcements, got " .. tostring(total))
    os.remove(db_path)
end

function tests.creation_grows_the_total_by_exactly_base_heat()
    print("Testing registering a newly created document grows the total by exactly BASE_HEAT")
    db_path = new_test_db(2)
    document.ensure_pool_state(db_path)
    db.exec(db_path, "INSERT INTO document (id, raw_heat, log_scale_at_write, pool_active) VALUES (3, 1.0, 0.0, 0);")
    document.register_pool_document(db_path, 3)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total should be 2.0 (seeded) + 1.0 (new doc) = 3.0, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 3, "document_count should be 3, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function tests.a_new_document_reads_exactly_base_heat_even_after_pool_scale_has_drifted()
    print("Testing a new document still reads exactly BASE_HEAT even once log_pool_scale has drifted from 0.0")
    db_path = new_test_db(2)
    document.reinforce_pool_heat(db_path, 1, 0.5)
    db.exec(db_path, "INSERT INTO document (id, raw_heat, log_scale_at_write, pool_active) VALUES (3, 1.0, 0.0, 0);")
    document.register_pool_document(db_path, 3)
    rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = tonumber(rows[1].log_pool_scale)
    check(not close_enough(log_pool_scale, 0.0), "log_pool_scale should have drifted from 0.0 by now")
    doc3 = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 3;")[1]
    heat3 = document.pool_effective_heat(doc3.raw_heat, doc3.log_scale_at_write, log_pool_scale)
    check(close_enough(heat3, 1.0), "document 3 should read exactly BASE_HEAT (1.0), got " .. tostring(heat3))
    os.remove(db_path)
end

function tests.departure_returns_heat_to_survivors_so_their_new_total_matches_the_smaller_pool()
    print("Testing a departing document's heat is returned to survivors, matching the (N-1)*BASE_HEAT invariant")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    document.return_pool_heat(db_path, 1)
    total = pool_total(db_path, {2, 3})
    check(close_enough(total, 2.0), "2 survivors should sum to exactly 2.0 after document 1 departs, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 2, "document_count should be 2 after a departure, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function tests.departure_of_the_last_document_does_not_error()
    print("Testing the last document leaving the pool decrements the count without dividing by zero")
    db_path = new_test_db(1)
    status, err = pcall(document.return_pool_heat, db_path, 1)
    check(status == true, "return_pool_heat on the last document should not raise, got " .. tostring(err))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 0, "document_count should be 0, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function tests.archiving_a_document_returns_its_heat_same_as_a_merge_departure()
    print("Testing on_entity_archived returns heat to survivors, same as the merge path")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    db.exec(db_path, "UPDATE document SET archived_at = '2026-11-17 00:00:00' WHERE id = 1;")
    document.on_entity_archived(db_path, "document", 1)
    total = pool_total(db_path, {2, 3})
    check(close_enough(total, 2.0), "2 survivors should sum to exactly 2.0 after document 1 is archived, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 2, "document_count should be 2 after an archive, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function tests.on_entity_archived_ignores_non_document_entity_types()
    print("Testing on_entity_archived is a no-op for any entity_type other than document")
    db_path = new_test_db(3)
    document.on_entity_archived(db_path, "sample", 1)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "a non-document archive should not touch the pool at all, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 3, "document_count should stay 3 for a non-document archive")
    os.remove(db_path)
end

function tests.unarchiving_a_document_rejoins_the_pool_at_exactly_base_heat()
    print("Testing on_entity_unarchived rejoins a document at exactly BASE_HEAT, not its stale pre-archive heat")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    db.exec(db_path, "UPDATE document SET archived_at = '2026-11-17 00:00:00' WHERE id = 1;")
    document.on_entity_archived(db_path, "document", 1)
    db.exec(db_path, "UPDATE document SET archived_at = NULL WHERE id = 1;")
    document.on_entity_unarchived(db_path, "document", 1)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total should be back to exactly 3.0 after rejoining, got " .. tostring(total))
    rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    doc1 = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 1;")[1]
    heat1 = document.pool_effective_heat(doc1.raw_heat, doc1.log_scale_at_write, tonumber(rows[1].log_pool_scale))
    check(close_enough(heat1, 1.0), "document 1 should read exactly BASE_HEAT after rejoining, got " .. tostring(heat1))
    os.remove(db_path)
end

function tests.racing_reinforcements_of_the_same_document_never_lose_a_delta()
    print("Testing two racing reinforcements of the same document in full log-space: neither delta is lost")
    db_path = new_test_db(50)
    document.ensure_pool_state(db_path)

    state = db.query(db_path, "SELECT log_pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")[1]
    log_pool_scale = tonumber(state.log_pool_scale)
    document_count = tonumber(state.document_count)
    doc = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 1;")[1]
    x_eff_before = document.pool_effective_heat(doc.raw_heat, doc.log_scale_at_write, log_pool_scale)

    delta_a = 0.15
    delta_b = 0.25
    total = document_count * document.base_heat()
    denominator = total - x_eff_before
    log_f_a = -(delta_a / denominator)
    log_f_b = -(delta_b / denominator)
    extracted_a = denominator * (1 - math.exp(log_f_a))
    extracted_b = denominator * (1 - math.exp(log_f_b))

    new_log_a = log_pool_scale + log_f_a
    db.exec(db_path, string.format("UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g WHERE id = 1;", log_f_a))
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = (raw_heat * EXP(%.17g - log_scale_at_write)) + %.17g, log_scale_at_write = %.17g WHERE id = 1 AND pool_active = 1;",
        log_pool_scale, extracted_a, new_log_a
    ))

    new_log_b = log_pool_scale + log_f_a + log_f_b
    db.exec(db_path, string.format("UPDATE knowledge_pool_state SET log_pool_scale = log_pool_scale + %.17g WHERE id = 1;", log_f_b))
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = (raw_heat * EXP(%.17g - log_scale_at_write)) + %.17g, log_scale_at_write = %.17g WHERE id = 1 AND pool_active = 1;",
        log_pool_scale, extracted_b, new_log_b
    ))

    final_state = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")[1]
    final_doc = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 1;")[1]
    final_eff = document.pool_effective_heat(final_doc.raw_heat, final_doc.log_scale_at_write, tonumber(final_state.log_pool_scale))

    lost_update_floor = x_eff_before + extracted_b
    check(final_eff > lost_update_floor + (extracted_a * 0.9), "delta_a must not be silently lost")
    check(close_enough(final_eff, x_eff_before + extracted_a + extracted_b, 0.01), "expected within bounded distance of exact sum")
    os.remove(db_path)
end

function tests.reinforcement_stays_well_behaved_when_delta_exceeds_the_rest_of_the_pool()
    print("Testing reinforcement doesn't break when delta exceeds the room left to redistribute")
    db_path = new_test_db(2)
    document.reinforce_pool_heat(db_path, 1, 0.98)
    before = pool_total(db_path, {1, 2})

    status, err = pcall(document.reinforce_pool_heat, db_path, 1, 0.5)
    check(status == true, "reinforcement should not raise, got " .. tostring(err))

    after = pool_total(db_path, {1, 2})
    check(close_enough(before, 2.0), "pool should start at 2.0")
    check(close_enough(after, before), "invariant must still hold exactly, before=" .. tostring(before) .. " after=" .. tostring(after))

    rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    doc2 = db.query(db_path, "SELECT raw_heat, log_scale_at_write FROM document WHERE id = 2;")[1]
    heat2 = document.pool_effective_heat(doc2.raw_heat, doc2.log_scale_at_write, tonumber(rows[1].log_pool_scale))
    check(heat2 > 0, "document 2's heat must stay strictly positive, got " .. tostring(heat2))
    os.remove(db_path)
end

function tests.idempotent_departure_and_rejoin_guards_preserve_conservation()
    print("Testing repeated return_pool_heat / register_pool_document and merged_into+archive never double-count")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.5)

    -- Calling register_pool_document on already-active Doc 1 must NOT wipe its heat or bump document_count
    document.register_pool_document(db_path, 1)
    state_a = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")[1]
    check(tonumber(state_a.document_count) == 3, "register_pool_document on active doc must not bump count")
    check(close_enough(pool_total(db_path, {1, 2, 3}), 3.0), "register_pool_document on active doc must preserve heat")

    -- Depart via merged_into, then also archive: heat returned once, count decremented once, reinforcing departed doc is a no-op
    db.exec(db_path, "UPDATE document SET merged_into = 3 WHERE id = 2;")
    document.return_pool_heat(db_path, 2)
    document.return_pool_heat(db_path, 2)
    db.exec(db_path, "UPDATE document SET archived_at = '2026-11-17 00:00:00' WHERE id = 2;")
    document.on_entity_archived(db_path, "document", 2)
    check(document.reinforce_pool_heat(db_path, 2, 0.5) == nil, "departed document must not accept reinforcement")

    state_b = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")[1]
    check(tonumber(state_b.document_count) == 2, "double departure must decrement count once, got " .. tostring(state_b.document_count))
    check(close_enough(pool_total(db_path, {1, 3}), 2.0), "survivors {1, 3} must conserve 2.0, got " .. tostring(pool_total(db_path, {1, 3})))

    -- Unarchiving Doc 2 while merged_into=3 is still set must NOT re-enter active pool
    db.exec(db_path, "UPDATE document SET archived_at = NULL WHERE id = 2;")
    document.on_entity_unarchived(db_path, "document", 2)
    state_c = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")[1]
    check(tonumber(state_c.document_count) == 2, "still-merged unarchived doc must stay outside pool")
    os.remove(db_path)
end

function tests.deep_log_pool_scale_past_ieee754_linear_underflow_conserves_exact_heat()
    print("Testing log_pool_scale = -5000 (past IEEE-754 exp(-745) == 0 cliff) never underflows or loses conservation")
    db_path = new_test_db(3)
    document.ensure_pool_state(db_path)
    -- Jump straight past 10+ million hits: linear math.exp(-5000) == 0.0!
    db.exec(db_path, "UPDATE knowledge_pool_state SET log_pool_scale = -5000.0 WHERE id = 1;")
    db.exec(db_path, "UPDATE document SET raw_heat = 1.0, log_scale_at_write = -5000.0;")

    document.reinforce_pool_heat(db_path, 1, 0.4)
    document.reinforce_pool_heat(db_path, 2, 0.3)
    document.reinforce_pool_heat(db_path, 3, 0.2)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total must remain 3.0 even at log_pool_scale ~= -5000, got " .. tostring(total))
    os.remove(db_path)
end

unit.run(tests)
