-- tst/unit/knowledge.lua
-- Unit tests for src/knowledge.lua's remaining pure heuristics: reply
-- classification for chat evaluation (task #87). The tier/heat/dedup
-- heuristics that used to live here moved to src/document.lua under
-- task #106 (see tst/unit/document.lua) when knowledge_note was
-- collapsed into `document` directly.

knowledge = require("knowledge")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_reply_has_visible_reasoning_detects_markers()
    print("Testing reply_has_visible_reasoning detects <think> tags and 'Thinking...' prefix")
    check(knowledge.reply_has_visible_reasoning("<think>some reasoning</think>Final answer") == true, "should detect <think> tag")
    check(knowledge.reply_has_visible_reasoning("Thinking...\nStep 1...") == true, "should detect 'Thinking...' marker")
    check(knowledge.reply_has_visible_reasoning("A plain final answer.") == false, "plain text should not be flagged")
    check(knowledge.reply_has_visible_reasoning(nil) == false, "nil should not be flagged")
    check(knowledge.reply_has_visible_reasoning("") == false, "empty string should not be flagged")
end

function test_unverified_claims_need_both_documents()
    print("Testing unverified_claims: cited authors, years and identifiers must appear in both documents")
    review = {title = "Cacao biotechnology review", content = "Somatic embryogenesis (Dillinger et al., 2000) and CCN51 clones."}
    thesis = {title = "Phospholipase D thesis", content = "Bargmann et al. found LePLD relocalization. Dillinger 2000 cited."}
    check(#knowledge.unverified_claims("the review cites Bargmann et al. on PLD", review, thesis) == 1,
        "an author only one side mentions is unverified (B cites A's author)")
    check(#knowledge.unverified_claims("both cite Dillinger et al. (2000) on etymology", review, thesis) == 0,
        "an author and year both documents mention are verified")
    check(#knowledge.unverified_claims("both discuss plant stress signalling", review, thesis) == 0,
        "a reason with no checkable specifics passes (paraphrase can't be checked)")
    missing = knowledge.unverified_claims("the CCN51 protocol relies on it", review, thesis)
    check(#missing == 1 and missing[1] == "CCN51", "a letters-and-digits identifier is a claim")

    summary = {title = "Experiment 208 - Summary", content = "Source material from Exp. 141; follow-up in experiment #226."}
    run = {title = "Experiment 226", content = "Media variants from exp208 and Exp 141."}
    check(#knowledge.unverified_claims("Experiment 226 executes the design in Experiment 208, both using Exp141", summary, run) == 0,
        "numbered references match Exp. 141 / experiment #226 / exp208 spellings")
    check(#knowledge.unverified_claims("Experiment 228 is its source", summary, run) == 1,
        "a numbered reference neither document mentions is unverified")
    check(#knowledge.unverified_claims("the 1,058 samples", summary, run) == 0,
        "a plain number isn't a claim on its own")
end

function test_classify_reply_four_way_split()
test_unverified_claims_need_both_documents()
    print("Testing classify_reply's four-way classification (error/reasoning-visible/final/empty)")
    kind, quality, reasoning = knowledge.classify_reply(true, nil)
    check(kind == "error" and quality == "error" and reasoning == "none",
        "error case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "<think>reasoning</think>answer")
    check(kind == "reasoning-visible" and quality == "review" and reasoning == "visible",
        "reasoning-visible case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "A clean final answer.")
    check(kind == "final" and quality == "ok" and reasoning == "none",
        "final case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "")
    check(kind == "empty" and quality == "empty" and reasoning == "none",
        "empty case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))
end

function test_co_retrieval_eligible_threshold_and_hub_ratio()
    print("Testing co_retrieval_eligible's absolute threshold + hub-ratio guard (task #109)")
    -- Below the absolute threshold (3) at all -- never eligible
    -- regardless of how favorable the ratio would be.
    check(knowledge.co_retrieval_eligible(2, 2, 2) == false, "co_count below CO_RETRIEVAL_LINK_THRESHOLD should never be eligible")
    -- Clears the threshold, and co_count(3)/min(4,10)=0.75 clears the
    -- 0.25 hub ratio comfortably.
    check(knowledge.co_retrieval_eligible(3, 4, 10) == true, "threshold met + healthy ratio should be eligible")
    -- A hub document: co_count(3) clears the absolute threshold, but
    -- its own retrieval_count(50) is so high that 3/50 = 0.06 falls
    -- well under the 0.25 ratio guard -- must NOT be eligible.
    check(knowledge.co_retrieval_eligible(3, 50, 4) == false, "a hub document's low co_count/retrieval_count ratio should be rejected")
    -- Both retrieval_counts zero (shouldn't really happen alongside a
    -- real co_count, but must not divide by zero/crash).
    check(knowledge.co_retrieval_eligible(3, 0, 0) == false, "both retrieval_counts zero should be rejected, not error")
end

function test_due_for_link_review_first_time_and_reevaluation_step()
    print("Testing due_for_link_review's first-time/decline/re-evaluation-step logic (task #109)")
    check(knowledge.due_for_link_review(nil, 3) == true, "a never-reviewed pair should be due")
    check(knowledge.due_for_link_review({decision = "linked", last_co_count = 3}, 10) == false, "an already-linked pair should never be re-evaluated")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 4) == false, "co_count only 1 past a decline (< CO_RETRIEVAL_REEVALUATION_STEP=3) should not be due yet")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 6) == true, "co_count exactly last_co_count + CO_RETRIEVAL_REEVALUATION_STEP should be due")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 9) == true, "co_count well past the re-evaluation step should be due")
end

function test_due_for_tier_judgment_first_time_and_content_change()
    print("Testing due_for_tier_judgment's first-time/unchanged/changed-content logic")
    check(knowledge.due_for_tier_judgment(nil, "abc") == true, "a never-judged document should be due")
    check(knowledge.due_for_tier_judgment({judged_hash = "abc", judged_tier = 1}, "abc") == false, "unchanged content_hash since the last judgment should not be due")
    check(knowledge.due_for_tier_judgment({judged_hash = "abc", judged_tier = 1}, "def") == true, "a changed content_hash since the last judgment should be due")
end

function test_hand_rolled_sql_columns_text_covers_every_event_log_table()
    print("Testing hand_rolled_sql_columns_text names the real columns for each knowledge event-log table")
    cases = {
        knowledge_retrieval = {"id", "session_id", "query_text", "hit_count", "created_at"},
        knowledge_retrieval_document = {"retrieval_id", "document_id", "rank", "score", "tier_weight", "reinforcement_delta"},
        knowledge_review = {"atomicity_status", "connectivity_status", "duplication_status", "title_status"},
        knowledge_context = {"prompt", "model_id", "reasoning_document_id", "prompt_tokens", "completion_tokens", "total_tokens"},
        knowledge_chat_eval = {"provider", "model", "reply_kind", "quality_status", "user_feedback"},
    }
    for table_name, columns in pairs(cases) do
        text = knowledge.hand_rolled_sql_columns_text(table_name)
        check(text != nil, "expected a non-nil result for '" .. table_name .. "'")
        for _, name in ipairs(columns) do
            check(string.find(text, name, 1, true) != nil, "expected column '" .. name .. "' for " .. table_name .. ", got:\n" .. tostring(text))
        end
    end
    check(knowledge.hand_rolled_sql_columns_text("not_a_real_table") == nil, "expected nil for an unrecognized table name")
end

-- Run them
test_reply_has_visible_reasoning_detects_markers()
test_classify_reply_four_way_split()
test_co_retrieval_eligible_threshold_and_hub_ratio()
test_due_for_link_review_first_time_and_reevaluation_step()
test_due_for_tier_judgment_first_time_and_content_change()
test_hand_rolled_sql_columns_text_covers_every_event_log_table()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All knowledge.lua tests passed")
