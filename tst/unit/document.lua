-- tst/unit/document.lua
-- Unit tests for src/document.lua's pure math/heuristics: the
-- reinforcement formula, tier-promotion (content-maturity, not
-- retrieval/heat -- see promotion_target_tier's own comment), heat
-- decay, and the rule-based review heuristics (content_shape,
-- title-guessing, content hashing) -- all ported/adapted from a Fossil
-- SCM fork's ai_note/ai_retrieval system (see document.lua's own
-- header). Moved here from tst/unit/knowledge.lua under task #106,
-- when these columns/heuristics moved from a separate knowledge_note
-- table onto `document` itself.

document = require("document")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_reinforcement_delta_matches_tier_weights()
    print("Testing reinforcement_delta for each tier")
    check(document.reinforcement_delta(0) == 0.15, "tier 0 should be 0.15, got " .. tostring(document.reinforcement_delta(0)))
    check(document.reinforcement_delta(1) == 0.25, "tier 1 should be 0.25, got " .. tostring(document.reinforcement_delta(1)))
    check(document.reinforcement_delta(2) == 0.35, "tier 2 should be 0.35, got " .. tostring(document.reinforcement_delta(2)))
    check(document.reinforcement_delta(3) == 0.50, "tier 3 should be 0.50, got " .. tostring(document.reinforcement_delta(3)))
end

function test_promotion_requires_revised_regardless_of_content_shape()
    print("Testing an unrevised document stays at tier 0 no matter how its content looks")
    check(document.promotion_target_tier(0, false, false, "developed") == 0, "unrevised developed content should not promote")
    check(document.promotion_target_tier(0, false, false, "atomic") == 0, "unrevised atomic-shaped content should not promote")
end

function test_promotion_simple_or_thin_content_lands_tier_1()
    print("Testing revised content that's neither developed nor atomic lands at tier 1 (Curated Draft)")
    check(document.promotion_target_tier(0, false, true, "simple") == 1, "revised + simple should be tier 1")
    check(document.promotion_target_tier(0, false, true, "thin") == 1, "revised + thin should be tier 1")
end

function test_promotion_developed_content_lands_tier_2()
    print("Testing revised, developed (multi-section/long) content lands at tier 2 (Developed Reference)")
    check(document.promotion_target_tier(0, false, true, "developed") == 2, "revised + developed should be tier 2")
end

function test_promotion_atomic_content_lands_tier_3()
    print("Testing revised, atomic (short single-subject) content lands at tier 3 (Atomic Record)")
    check(document.promotion_target_tier(0, false, true, "atomic") == 3, "revised + atomic should be tier 3")
end

function test_promotion_duplicate_never_advances()
    print("Testing a duplicate document never advances tier regardless of other inputs")
    check(document.promotion_target_tier(0, true, true, "atomic") == 0, "duplicate should stay at tier 0 even with atomic content")
    check(document.promotion_target_tier(2, true, true, "atomic") == 2, "duplicate should stay at its current tier, not advance")
end

function test_promotion_demotes_when_edited_down_to_a_smaller_shape()
    print("Testing a document at tier 3 demotes if its current content no longer earns that shape (task #87, redesigned for content-maturity)")
    -- Recomputed fresh from the CURRENT body every review (no
    -- ratcheting) -- a document that was legitimately tier 3 once (an
    -- atomic-shaped edit) but has since been edited down to something
    -- merely "simple" drops back down on its next review.
    result = document.promotion_target_tier(3, false, true, "simple")
    check(result == 1, "tier-3 document edited down to 'simple' content should demote to tier 1, got " .. tostring(result))
end

function test_content_shape_developed_on_multiple_headings()
    print("Testing content_shape flags multiple headings as developed")
    body = "# First heading\nSome text.\n\n# Second heading\nMore text."
    check(document.content_shape(body) == "developed", "2 headings should be developed, got " .. document.content_shape(body))
end

function test_content_shape_developed_on_many_paragraphs()
    print("Testing content_shape flags more than 6 paragraphs as developed")
    body = "P1.\n\nP2.\n\nP3.\n\nP4.\n\nP5.\n\nP6.\n\nP7."
    check(document.content_shape(body) == "developed", "7 paragraphs should be developed, got " .. document.content_shape(body))
end

function test_content_shape_thin_on_very_short_body()
    print("Testing content_shape flags a body under 6 words as thin")
    check(document.content_shape("Too short.") == "thin", "a 2-word body should be thin, got " .. document.content_shape("Too short."))
end

function test_content_shape_atomic_on_short_single_subject_body()
    print("Testing content_shape flags a short, single-paragraph, single-subject body as atomic")
    body = "Beer's Law states that absorbance is directly proportional to the concentration of a solution and the path length of light through it."
    check(document.content_shape(body) == "atomic", "a short single-subject definition should be atomic, got " .. document.content_shape(body))
end

function test_content_shape_simple_when_too_long_for_atomic_but_not_developed()
    print("Testing content_shape falls back to simple for a single-paragraph body over the atomic word ceiling")
    body = string.rep("word ", 130)
    check(document.content_shape(body) == "simple", "130 words in one paragraph should be simple, got " .. document.content_shape(body))
end

function test_connectivity_status_format()
    print("Testing connectivity_status formats peer count")
    check(document.connectivity_status(3) == "linked-3", "expected linked-3, got " .. document.connectivity_status(3))
    check(document.connectivity_status(0) == "linked-0", "expected linked-0, got " .. document.connectivity_status(0))
end

function test_title_is_generic_case_insensitive()
    print("Testing title_is_generic detects generic titles case-insensitively")
    check(document.title_is_generic("Note") == true, "'Note' should be generic")
    check(document.title_is_generic("UNTITLED NOTE") == true, "'UNTITLED NOTE' should be generic")
    check(document.title_is_generic("") == true, "empty string should be generic")
    check(document.title_is_generic(nil) == true, "nil should be generic")
    check(document.title_is_generic("Bioreactor cleaning steps") == false, "a real title should not be generic")
end

function test_guess_title_skips_heading_uses_first_real_line()
    print("Testing guess_title_from_body skips the heading and uses the first real line")
    title = document.guess_title_from_body("# Heading\n\nFirst real line here.")
    check(title == "First real line here.", "expected 'First real line here.', got '" .. tostring(title) .. "'")
end

function test_guess_title_strips_bullet_decoration()
    print("Testing guess_title_from_body strips leading bullet/quote decoration")
    title = document.guess_title_from_body("- A bulleted first line")
    check(title == "A bulleted first line", "expected stripped bullet, got '" .. tostring(title) .. "'")
end

function test_guess_title_truncates_long_lines_on_word_boundary()
    print("Testing guess_title_from_body truncates a long line on a word boundary")
    long_line = "This is a very long first line that definitely exceeds the seventy two character budget we allow"
    title = document.guess_title_from_body(long_line)
    check(string.len(title) <= 72, "truncated title should be <= 72 chars, got " .. string.len(title))
    check(string.sub(title, -1) != " ", "truncated title should not end with a trailing space")
end

function test_guess_title_empty_body_returns_untitled()
    print("Testing guess_title_from_body falls back to 'Untitled note' for empty/nil body")
    check(document.guess_title_from_body(nil) == "Untitled note", "nil body should return 'Untitled note'")
    check(document.guess_title_from_body("") == "Untitled note", "empty body should return 'Untitled note'")
end

function test_content_hash_is_deterministic()
    print("Testing content_hash is deterministic and content-sensitive")
    check(document.content_hash("hello world") == document.content_hash("hello world"), "same content should hash the same")
    check(document.content_hash("hello world") != document.content_hash("hello there"), "different content should hash differently")
end

function timestamp_days_ago(days)
    return os.date("%Y-%m-%d %H:%M:%S", os.time() - math.floor(days * 86400))
end

function test_days_since_computes_elapsed_days()
    print("Testing days_since computes elapsed days from a timestamp")
    elapsed = document.days_since(timestamp_days_ago(10))
    check(elapsed > 9.99 and elapsed < 10.01, "expected ~10 days, got " .. tostring(elapsed))
end

function test_days_since_nil_for_missing_or_unparseable()
    print("Testing days_since returns nil for missing/unparseable timestamps")
    check(document.days_since(nil) == nil, "nil timestamp should return nil")
    check(document.days_since("") == nil, "empty timestamp should return nil")
    check(document.days_since("not-a-date") == nil, "garbage timestamp should return nil")
end

function test_effective_heat_unchanged_with_no_last_retrieved()
    print("Testing effective_heat returns heat unchanged when last_retrieved_at is nil")
    check(document.effective_heat(2.5, nil) == 2.5, "no last_retrieved_at should mean no decay, got " .. tostring(document.effective_heat(2.5, nil)))
end

function test_effective_heat_halves_at_one_half_life()
    print("Testing effective_heat halves heat after one half-life (14 days)")
    result = document.effective_heat(2.0, timestamp_days_ago(14))
    check(result > 0.99 and result < 1.01, "expected ~1.0 (half of 2.0) after one half-life, got " .. tostring(result))
end

function test_effective_heat_decays_heavily_over_many_half_lives()
    print("Testing effective_heat decays heavily after many half-lives")
    result = document.effective_heat(3.0, timestamp_days_ago(140))
    check(result < 0.01, "expected heavily decayed heat after 10 half-lives, got " .. tostring(result))
end

function test_tier_weight_known_and_unknown_tiers()
    print("Testing tier_weight returns each tier's weight and 0.0 for an unknown tier")
    check(document.tier_weight(0) == 0.0, "tier 0 weight should be 0.0")
    check(document.tier_weight(3) == 0.35, "tier 3 weight should be 0.35")
    check(document.tier_weight(99) == 0.0, "unknown tier should default to 0.0")
end

-- Run them
test_reinforcement_delta_matches_tier_weights()
test_promotion_requires_revised_regardless_of_content_shape()
test_promotion_simple_or_thin_content_lands_tier_1()
test_promotion_developed_content_lands_tier_2()
test_promotion_atomic_content_lands_tier_3()
test_promotion_duplicate_never_advances()
test_promotion_demotes_when_edited_down_to_a_smaller_shape()
test_content_shape_developed_on_multiple_headings()
test_content_shape_developed_on_many_paragraphs()
test_content_shape_thin_on_very_short_body()
test_content_shape_atomic_on_short_single_subject_body()
test_content_shape_simple_when_too_long_for_atomic_but_not_developed()
test_connectivity_status_format()
test_title_is_generic_case_insensitive()
test_guess_title_skips_heading_uses_first_real_line()
test_guess_title_strips_bullet_decoration()
test_guess_title_truncates_long_lines_on_word_boundary()
test_guess_title_empty_body_returns_untitled()
test_content_hash_is_deterministic()
test_days_since_computes_elapsed_days()
test_days_since_nil_for_missing_or_unparseable()
test_effective_heat_unchanged_with_no_last_retrieved()
test_effective_heat_halves_at_one_half_life()
test_effective_heat_decays_heavily_over_many_half_lives()
test_tier_weight_known_and_unknown_tiers()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All document.lua tests passed")
