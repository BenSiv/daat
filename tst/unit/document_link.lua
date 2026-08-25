-- tst/unit/document_link.lua
-- Unit tests for src/knowledge.lua's reinforce_link_strength (see
-- doc/link-strength-redesign.md, Phase 2): the usage-driven edge
-- reinforcement that will eventually weight spread_activation, once
-- Phase 3 of that doc cuts the read side over. Also covers
-- src/document.lua's source_set_add/source_set_remove/upsert_link and
-- the archive-not-delete sync_links behavior they support
-- (doc/document-link-flow.md's "Archiving and reintroduction").
--
-- Same reasoning as tst/unit/document_pool.lua for touching a real
-- (temporary) SQLite file with a minimal, hand-rolled document_link
-- table rather than the full entity/schema/ledger machinery -- what's
-- being tested is a DB-state property (does a real UPDATE land
-- correctly, in both directions, under a simulated race), not a pure
-- function of its own inputs.

knowledge = require("knowledge")
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

-- NOT a general-purpose blank/empty check -- scoped specifically to a
-- column value just read back via db.query, where a SQL NULL renders
-- as Lua "" here, never nil (confirmed: both TEXT and INTEGER NULL
-- columns come back this way; same reason every SQL read of
-- archived_at in src/document.lua checks "IS NULL OR = ''" rather than
-- a bare "IS NULL"). Do not reach for this on a value where "" is a
-- real, intentional distinct-from-NULL result -- e.g. document_link's
-- own `source` after document.source_set_remove, where "" specifically
-- means "no tags left" and is compared with a plain `== ""` below, not
-- this helper.
function is_sql_null(value)
    return value == nil or value == ""
end

-- Just the columns reinforce_link_strength/sync_links/upsert_link
-- actually touch -- no entity/schema/ledger setup, same reasoning as
-- document_pool.lua's own new_test_db.
function new_test_db()
    db_path = os.tmpname()
    db.exec(db_path, "CREATE TABLE document_link (from_document_id INTEGER NOT NULL, to_document_id INTEGER, link_text VARCHAR(255) NOT NULL, source VARCHAR(32) NOT NULL DEFAULT 'authored', raw_strength REAL NOT NULL DEFAULT 1.0, archived_at TEXT DEFAULT NULL, PRIMARY KEY (from_document_id, link_text));")
    -- Minimal document table -- only sync_links' own resolve_link
    -- reads this, to turn a [[title]] into a real to_document_id.
    db.exec(db_path, "CREATE TABLE document (id INTEGER PRIMARY KEY, title TEXT, parent_id INTEGER, archived_at TEXT DEFAULT NULL);")
    return db_path
end

function link_strength(db_path, from_id, to_id)
    rows = db.query(db_path, string.format(
        "SELECT raw_strength FROM document_link WHERE from_document_id = %d AND to_document_id = %d;", from_id, to_id
    ))
    return tonumber(rows[1].raw_strength)
end

function link_row(db_path, from_id, link_text)
    rows = db.query(db_path, string.format(
        "SELECT source, archived_at, to_document_id, raw_strength FROM document_link WHERE from_document_id = %d AND link_text = %s;",
        from_id, db.quote(link_text)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1]
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

function test_reinforce_unarchives_and_adds_the_co_retrieval_tag()
    print("Testing reinforce_link_strength unarchives an archived pair and folds in 'co-retrieval'")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, archived_at) VALUES (1, 2, 'Doc Two', 'authored', '2026-01-01 00:00:00');")
    knowledge.reinforce_link_strength(db_path, 1, 2)
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "a repeat co-retrieval hit should unarchive the row")
    check(row.source == "authored,co-retrieval", "expected merged source 'authored,co-retrieval', got " .. tostring(row.source))
    os.remove(db_path)
end

function test_source_set_add_dedupes_and_sorts()
    print("Testing document.source_set_add dedupes and keeps the set sorted (task: document_link archiving)")
    check(document.source_set_add(nil, "authored") == "authored", "adding to an empty set should just be the tag")
    check(document.source_set_add("authored", "authored") == "authored", "adding an already-present tag should be a no-op")
    check(document.source_set_add("co-retrieval", "authored") == "authored,co-retrieval", "expected sorted 'authored,co-retrieval'")
end

function test_source_set_remove_can_empty_the_set()
    print("Testing document.source_set_remove")
    check(document.source_set_remove("authored,co-retrieval", "authored") == "co-retrieval", "expected only 'co-retrieval' left")
    check(document.source_set_remove("authored", "authored") == "", "removing the only tag should leave an empty set")
end

function test_upsert_link_inserts_a_fresh_row()
    print("Testing document.upsert_link inserts when nothing exists yet")
    db_path = new_test_db()
    document.upsert_link(db_path, 1, 2, "Doc Two", "authored")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "expected a fresh row to exist")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(is_sql_null(row.archived_at), "a fresh row should not be archived")
    os.remove(db_path)
end

function test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
    print("Testing document.upsert_link unarchives and preserves raw_strength on reintroduction")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, raw_strength, archived_at) VALUES (1, 2, 'Doc Two', '', 1.45, '2026-01-01 00:00:00');")
    document.upsert_link(db_path, 1, 2, "Doc Two", "authored")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "reintroducing should unarchive")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction, not reset to 1.0 -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

function test_upsert_link_heals_a_dangling_row()
    print("Testing document.upsert_link resolves a previously-dangling to_document_id")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, NULL, 'Onboarding', 'authored');")
    document.upsert_link(db_path, 1, 9, "Onboarding", "co-retrieval")
    row = link_row(db_path, 1, "Onboarding")
    check(tonumber(row.to_document_id) == 9, "expected the dangling row to heal to to_document_id=9, got " .. tostring(row.to_document_id))
    check(row.source == "authored,co-retrieval", "expected merged source, got " .. tostring(row.source))
    os.remove(db_path)
end

function test_sync_links_archives_instead_of_deleting_when_removed_from_text()
    print("Testing sync_links archives an authored link with no other provenance, instead of deleting it")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    document.sync_links(db_path, 1, "See [[Doc Two]].")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "link should exist after the first save")
    db.exec(db_path, string.format("UPDATE document_link SET raw_strength = 1.45 WHERE from_document_id = 1 AND link_text = %s;", db.quote("Doc Two")))

    document.sync_links(db_path, 1, "No links here anymore.")
    row = link_row(db_path, 1, "Doc Two")
    check(row != nil, "row should still exist (archived), not be deleted")
    check(is_sql_null(row.archived_at) == false, "row should be archived once its only source tag is gone")
    check(row.source == "", "source set should be empty once 'authored' is removed")
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive archiving -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

function test_sync_links_leaves_a_co_retrieval_backed_row_active_when_authored_text_is_removed()
    print("Testing sync_links only drops the 'authored' tag, leaving a co-retrieval-backed row active")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source) VALUES (1, 2, 'Doc Two', 'authored,co-retrieval');")

    document.sync_links(db_path, 1, "No links here anymore.")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "a link retrieval still vouches for should stay active")
    check(row.source == "co-retrieval", "expected only 'co-retrieval' left, got " .. tostring(row.source))
    os.remove(db_path)
end

function test_sync_links_reintroduces_an_archived_link_at_its_old_strength()
    print("Testing sync_links unarchives and preserves raw_strength when the author retypes a deleted [[link]]")
    db_path = new_test_db()
    db.exec(db_path, "INSERT INTO document (id, title) VALUES (2, 'Doc Two');")
    db.exec(db_path, "INSERT INTO document_link (from_document_id, to_document_id, link_text, source, raw_strength, archived_at) VALUES (1, 2, 'Doc Two', '', 1.45, '2026-01-01 00:00:00');")

    document.sync_links(db_path, 1, "See [[Doc Two]] again.")
    row = link_row(db_path, 1, "Doc Two")
    check(is_sql_null(row.archived_at), "retyping the link should unarchive it")
    check(row.source == "authored", "expected source 'authored', got " .. tostring(row.source))
    check(close_enough(tonumber(row.raw_strength), 1.45), "raw_strength should survive reintroduction -- got " .. tostring(row.raw_strength))
    os.remove(db_path)
end

test_reinforce_adds_exactly_the_configured_delta()
test_reinforce_matches_the_row_regardless_of_which_direction_it_was_authored_in()
test_racing_reinforcements_of_the_same_edge_never_lose_a_delta()
test_reinforce_is_a_no_op_for_a_pair_with_no_existing_link()
test_reinforce_unarchives_and_adds_the_co_retrieval_tag()
test_source_set_add_dedupes_and_sorts()
test_source_set_remove_can_empty_the_set()
test_upsert_link_inserts_a_fresh_row()
test_upsert_link_reintroduces_an_archived_row_at_its_old_strength()
test_upsert_link_heals_a_dangling_row()
test_sync_links_archives_instead_of_deleting_when_removed_from_text()
test_sync_links_leaves_a_co_retrieval_backed_row_active_when_authored_text_is_removed()
test_sync_links_reintroduces_an_archived_link_at_its_old_strength()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document_link.lua tests passed")
