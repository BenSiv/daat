-- tst/unit/document_link.lua
-- Unit tests for src/knowledge.lua's reinforce_link_strength (see
-- doc/link-strength-redesign.md, Phase 2): the usage-driven edge
-- reinforcement that will eventually weight spread_activation, once
-- Phase 3 of that doc cuts the read side over.
--
-- Same reasoning as tst/unit/document_pool.lua for touching a real
-- (temporary) SQLite file with a minimal, hand-rolled document_link
-- table rather than the full entity/schema/ledger machinery -- what's
-- being tested is a DB-state property (does a real UPDATE land
-- correctly, in both directions, under a simulated race), not a pure
-- function of its own inputs.

knowledge = require("knowledge")
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

-- Just the columns reinforce_link_strength actually touches -- no
-- entity/schema/ledger setup, same reasoning as document_pool.lua's
-- own new_test_db.
function new_test_db()
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document_link (from_document_id INTEGER NOT NULL, to_document_id INTEGER, link_text VARCHAR(255) NOT NULL, source VARCHAR(32) NOT NULL DEFAULT 'authored', raw_strength REAL NOT NULL DEFAULT 1.0, PRIMARY KEY (from_document_id, link_text));")
    return db_path
end

function link_strength(db_path, from_id, to_id)
    rows = db.query(db_path, string.format(
        "SELECT raw_strength FROM document_link WHERE from_document_id = %d AND to_document_id = %d;", from_id, to_id
    ))
    return tonumber(rows[1].raw_strength)
end

function test_reinforce_adds_exactly_the_configured_delta()
    print("Testing reinforce_link_strength adds exactly 0.15")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'co-retrieval');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = link_strength(db_path, 1, 2)
    check(close_enough(strength, 1.0 + 0.15),
        "expected " .. tostring(1.0 + 0.15) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_matches_the_row_regardless_of_which_direction_it_was_authored_in()
    print("Testing reinforce_link_strength finds an edge authored in either direction (task: link-strength-redesign Phase 2)")
    db_path = new_test_db()
    -- Row stored as (2 -> 1): e.g. document 2's own content contained
    -- the [[title]] link, or doc_a/doc_b happened to resolve opposite
    -- to co_retrieval_pairs' own doc_a < doc_b ordering. Reinforcing
    -- the pair as (1, 2) -- the order maybe_link_co_retrieved actually
    -- has on hand -- must still find and update this same row.
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (2, 1, 'Doc One', 'authored');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    strength = link_strength(db_path, 2, 1)
    check(close_enough(strength, 1.0 + 0.15),
        "reinforcing (1, 2) should have updated the (2, 1) row -- expected " .. tostring(1.0 + 0.15) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
    print("Testing two racing reinforcements of the same edge: neither delta is silently lost")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'co-retrieval');")

    -- Two "concurrent" reinforcements, applied as two ordinary
    -- sequential calls -- this is a plain additive UPDATE (raw_strength
    -- = raw_strength + delta), not a read-modify-write round trip in
    -- Lua, so unlike heat's own pool_scale history there's no lossy
    -- shape possible here to simulate a race against; this test exists
    -- to document and guard that property, not to demonstrate a fix
    -- for a bug this design could have had.
    knowledge.reinforce_link_strength(db_path, 1, 2)
    knowledge.reinforce_link_strength(db_path, 2, 1) -- same pair, opposite argument order
    strength = link_strength(db_path, 1, 2)
    check(close_enough(strength, 1.0 + (2 * 0.15)),
        "both reinforcements should land -- expected " .. tostring(1.0 + (2 * 0.15)) .. ", got " .. tostring(strength))
    os.remove(db_path)
end

function test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
    print("Testing reinforce_link_strength doesn't error when no matching row exists")
    db_path = new_test_db()
    ok = pcall(knowledge.reinforce_link_strength, db_path, 1, 2)
    check(ok == true, "reinforcing a non-existent pair should be a safe no-op, not an error")
    os.remove(db_path)
end

test_reinforce_adds_exactly_the_configured_delta()
test_reinforce_matches_the_row_regardless_of_which_direction_it_was_authored_in()
test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document_link.lua tests passed")
