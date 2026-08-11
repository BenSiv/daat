-- tst/unit/document_pool.lua
-- Unit tests for src/document.lua's conserved heat-pool primitives
-- (see doc/heat-decay-redesign.md, Phase 2): reinforce_pool_heat,
-- return_pool_heat, register_pool_document, and the invariant they're
-- all built to hold -- total heat across the pool stays exactly
-- document_count * BASE_HEAT.
--
-- Unlike document.lua's own unit tests, these touch a real (temporary)
-- SQLite file, the same way tst/unit/view.lua's reference_columns tests
-- already do (os.tmpname(), hand-rolled minimal schema, no entity/
-- schema/ledger machinery) -- the invariant being tested is fundamentally
-- a DB-state property across a sequence of writes, not a pure function
-- of its own inputs.

document = require("document")
db = require("db")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function close_enough(a, b, tolerance)
    if tolerance == nil then
        tolerance = 0.0000001
    end
    return math.abs(a - b) < tolerance
end

-- A minimal `document` table -- just the columns reinforce_pool_heat/
-- return_pool_heat/register_pool_document/ensure_pool_state actually
-- touch. No entity/schema/ledger setup at all, same reasoning as
-- view.lua's own minimal entity_field table.
function new_test_db(document_count)
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document (id INTEGER PRIMARY KEY, raw_heat REAL DEFAULT 1.0, scale_at_write REAL DEFAULT 1.0, archived_at TEXT, merged_into INTEGER);")
    for i = 1, document_count do
        db.exec(db_path, string.format("INSERT INTO document (id, raw_heat, scale_at_write) VALUES (%d, 1.0, 1.0);", i))
    end
    return db_path
end

function pool_total(db_path, document_ids)
    document.ensure_pool_state(db_path)
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = tonumber(rows[1].pool_scale)
    total = 0.0
    for _, id in ipairs(document_ids) do
        doc_rows = db.query(db_path, string.format("SELECT raw_heat, scale_at_write FROM document WHERE id = %d;", id))
        total = total + document.pool_effective_heat(doc_rows[1].raw_heat, doc_rows[1].scale_at_write, pool_scale)
    end
    return total
end

function test_reinforcement_conserves_total_across_the_pool()
    print("Testing a single reinforcement leaves the pool's total heat unchanged")
    db_path = new_test_db(3)
    before = pool_total(db_path, {1, 2, 3})
    document.reinforce_pool_heat(db_path, 1, 0.5)
    after = pool_total(db_path, {1, 2, 3})
    check(close_enough(before, 3.0), "3 fresh documents should start at total 3.0, got " .. tostring(before))
    check(close_enough(after, before), "reinforcement should conserve the total, before=" .. tostring(before) .. " after=" .. tostring(after))
    os.remove(db_path)
end

function test_reinforcement_gives_the_reinforced_document_exactly_delta()
    print("Testing the reinforced document itself gains exactly delta")
    db_path = new_test_db(3)
    new_heat = document.reinforce_pool_heat(db_path, 1, 0.5)
    check(close_enough(new_heat, 1.5), "document 1 should read 1.5 after a +0.5 reinforcement, got " .. tostring(new_heat))
    os.remove(db_path)
end

function test_reinforcement_shrinks_every_other_document_by_the_same_factor()
    print("Testing every OTHER document shrinks, and by the same proportional factor")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = tonumber(rows[1].pool_scale)
    doc2 = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 2;")[1]
    doc3 = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 3;")[1]
    heat2 = document.pool_effective_heat(doc2.raw_heat, doc2.scale_at_write, pool_scale)
    heat3 = document.pool_effective_heat(doc3.raw_heat, doc3.scale_at_write, pool_scale)
    check(heat2 < 1.0, "document 2 should have cooled below its starting 1.0, got " .. tostring(heat2))
    check(close_enough(heat2, heat3), "documents 2 and 3 started equal and weren't reinforced, so they should still be equal: " .. tostring(heat2) .. " vs " .. tostring(heat3))
    os.remove(db_path)
end

function test_repeated_reinforcement_of_different_documents_still_conserves_total()
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

function test_creation_grows_the_total_by_exactly_base_heat()
    print("Testing registering a newly created document grows the total by exactly BASE_HEAT")
    db_path = new_test_db(2)
    document.ensure_pool_state(db_path) -- seeds document_count=2 from the 2 rows above
    db.exec(db_path, "INSERT INTO document (id, raw_heat, scale_at_write) VALUES (3, 1.0, 1.0);")
    document.register_pool_document(db_path, 3)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total should be 2.0 (seeded) + 1.0 (new doc) = 3.0, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 3, "document_count should be 3, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function test_a_new_document_reads_exactly_base_heat_even_after_pool_scale_has_drifted()
    print("Testing a new document still reads exactly BASE_HEAT even once pool_scale has drifted from 1.0")
    db_path = new_test_db(2)
    document.reinforce_pool_heat(db_path, 1, 0.5) -- drifts pool_scale away from 1.0
    db.exec(db_path, "INSERT INTO document (id, raw_heat, scale_at_write) VALUES (3, 1.0, 1.0);")
    document.register_pool_document(db_path, 3)
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = tonumber(rows[1].pool_scale)
    check(not close_enough(pool_scale, 1.0), "pool_scale should have drifted from 1.0 by now, got " .. tostring(pool_scale))
    doc3 = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 3;")[1]
    heat3 = document.pool_effective_heat(doc3.raw_heat, doc3.scale_at_write, pool_scale)
    check(close_enough(heat3, 1.0), "document 3 should read exactly BASE_HEAT (1.0) regardless of pool_scale drift, got " .. tostring(heat3))
    os.remove(db_path)
end

function test_departure_returns_heat_to_survivors_so_their_new_total_matches_the_smaller_pool()
    print("Testing a departing document's heat is returned to survivors, matching the (N-1)*BASE_HEAT invariant")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6) -- give document 1 real heat to return on departure
    document.return_pool_heat(db_path, 1)
    total = pool_total(db_path, {2, 3})
    check(close_enough(total, 2.0), "2 survivors should sum to exactly 2.0 (2 * BASE_HEAT) after document 1 departs, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 2, "document_count should be 2 after a departure, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function test_departure_of_the_last_document_does_not_error()
    print("Testing the last document leaving the pool decrements the count without dividing by zero")
    db_path = new_test_db(1)
    status, err = pcall(document.return_pool_heat, db_path, 1)
    check(status == true, "return_pool_heat on the last document should not raise, got " .. tostring(err))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 0, "document_count should be 0, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function test_archiving_a_document_returns_its_heat_same_as_a_merge_departure()
    print("Testing on_entity_archived returns heat to survivors, same as the merge path")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    document.on_entity_archived(db_path, "document", 1)
    total = pool_total(db_path, {2, 3})
    check(close_enough(total, 2.0), "2 survivors should sum to exactly 2.0 after document 1 is archived, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 2, "document_count should be 2 after an archive, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function test_on_entity_archived_ignores_non_document_entity_types()
    print("Testing on_entity_archived is a no-op for any entity_type other than document")
    db_path = new_test_db(3)
    document.on_entity_archived(db_path, "sample", 1)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "a non-document archive should not touch the pool at all, got " .. tostring(total))
    state = db.query(db_path, "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")
    check(tonumber(state[1].document_count) == 3, "document_count should stay 3 for a non-document archive, got " .. tostring(state[1].document_count))
    os.remove(db_path)
end

function test_unarchiving_a_document_rejoins_the_pool_at_exactly_base_heat()
    print("Testing on_entity_unarchived rejoins a document at exactly BASE_HEAT, not its stale pre-archive heat")
    db_path = new_test_db(3)
    document.reinforce_pool_heat(db_path, 1, 0.6)
    document.on_entity_archived(db_path, "document", 1) -- document 1's old heat is now spent
    document.on_entity_unarchived(db_path, "document", 1)
    total = pool_total(db_path, {1, 2, 3})
    check(close_enough(total, 3.0), "total should be back to exactly 3.0 (3 * BASE_HEAT) after rejoining, got " .. tostring(total))
    rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    doc1 = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 1;")[1]
    heat1 = document.pool_effective_heat(doc1.raw_heat, doc1.scale_at_write, tonumber(rows[1].pool_scale))
    check(close_enough(heat1, 1.0), "document 1 should read exactly BASE_HEAT after rejoining, not its stale pre-archive value, got " .. tostring(heat1))
    os.remove(db_path)
end

-- Simulates two reinforcements of the *same* document racing: both read
-- the document/pool state before either writes anything, then commit
-- in sequence -- the exact interleaving that used to silently discard
-- one delta entirely (see document.reinforce_pool_heat's own comment).
-- Reproduces reinforce_pool_heat's own statements directly (rather than
-- calling it twice, which -- being single-threaded Lua -- could never
-- actually race) so the specific interleaving is under this test's
-- control.
function test_racing_reinforcements_of_the_same_document_never_lose_a_delta()
    print("Testing two racing reinforcements of the same document: neither delta is silently lost")
    db_path = new_test_db(50) -- a large-ish pool keeps the shrink factors close to 1
    document.ensure_pool_state(db_path)

    state = db.query(db_path, "SELECT pool_scale, document_count FROM knowledge_pool_state WHERE id = 1;")[1]
    pool_scale = tonumber(state.pool_scale)
    document_count = tonumber(state.document_count)
    doc = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 1;")[1]
    x_eff_before = document.pool_effective_heat(doc.raw_heat, doc.scale_at_write, pool_scale)

    delta_a = 0.15
    delta_b = 0.25
    total = document_count * document.base_heat()
    f_a = 1 - (delta_a / (total - x_eff_before))
    f_b = 1 - (delta_b / (total - x_eff_before))

    -- A commits first: shrinks the shared row, then writes its own
    -- delta as an expression over the row's own live columns (the
    -- fixed shape) -- not a value it computed once and wrote back
    -- absolute (the old, lossy shape).
    db.exec(db_path, string.format("UPDATE knowledge_pool_state SET pool_scale = pool_scale * %.17g WHERE id = 1;", f_a))
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = (raw_heat * (%.17g / scale_at_write)) + %.17g, scale_at_write = %.17g WHERE id = 1;",
        pool_scale, delta_a, pool_scale * f_a
    ))

    -- B commits second, using its OWN pool_scale snapshot from before
    -- A committed -- exactly the race window this test targets.
    db.exec(db_path, string.format("UPDATE knowledge_pool_state SET pool_scale = pool_scale * %.17g WHERE id = 1;", f_b))
    db.exec(db_path, string.format(
        "UPDATE document SET raw_heat = (raw_heat * (%.17g / scale_at_write)) + %.17g, scale_at_write = %.17g WHERE id = 1;",
        pool_scale, delta_b, pool_scale * f_a * f_b
    ))

    final_state = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")[1]
    final_doc = db.query(db_path, "SELECT raw_heat, scale_at_write FROM document WHERE id = 1;")[1]
    final_eff = document.pool_effective_heat(final_doc.raw_heat, final_doc.scale_at_write, tonumber(final_state.pool_scale))

    -- The old (pre-fix) shape had B's absolute write completely
    -- overwrite A's -- final_eff would land at x_eff_before + delta_b,
    -- with delta_a contributing nothing at all. Assert the fix clears
    -- that floor by a wide margin: delta_a's contribution survives,
    -- even though it's scaled by a small, bounded factor rather than
    -- landing at the mathematically exact sum.
    lost_update_floor = x_eff_before + delta_b
    check(final_eff > lost_update_floor + (delta_a * 0.9),
        "delta_a must not be silently lost -- expected close to " .. tostring(x_eff_before + delta_a + delta_b) ..
        ", got " .. tostring(final_eff) .. " (old buggy code would have landed at " .. tostring(lost_update_floor) .. ")")
    check(close_enough(final_eff, x_eff_before + delta_a + delta_b, 0.01),
        "expected within a small, bounded distance of the exact sum " .. tostring(x_eff_before + delta_a + delta_b) ..
        ", got " .. tostring(final_eff))
    os.remove(db_path)
end

-- Run them
test_reinforcement_conserves_total_across_the_pool()
test_reinforcement_gives_the_reinforced_document_exactly_delta()
test_reinforcement_shrinks_every_other_document_by_the_same_factor()
test_repeated_reinforcement_of_different_documents_still_conserves_total()
test_creation_grows_the_total_by_exactly_base_heat()
test_a_new_document_reads_exactly_base_heat_even_after_pool_scale_has_drifted()
test_departure_returns_heat_to_survivors_so_their_new_total_matches_the_smaller_pool()
test_departure_of_the_last_document_does_not_error()
test_archiving_a_document_returns_its_heat_same_as_a_merge_departure()
test_on_entity_archived_ignores_non_document_entity_types()
test_unarchiving_a_document_rejoins_the_pool_at_exactly_base_heat()
test_racing_reinforcements_of_the_same_document_never_lose_a_delta()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document_pool.lua tests passed")
