-- tag.lifts (src/tag.lua): lift per evidence row, by its own kind only,
-- shrunk towards 1 on little evidence; tag.text_tags: the #tag syntax.
-- Both pure, so no store is needed.

tag = require("tag")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function lift_of(lifts, a, b, kind)
    for _, row in ipairs(lifts) do
        if row.tag_a == a and row.tag_b == b and row.kind == kind then
            return row.lift
        end
    end
    return nil
end

function row(a, b, kind, direction, weight, support)
    return {tag_a = a, tag_b = b, kind = kind, direction = direction, weight = weight,
        support = support, producer = "core"}
end

function test_a_pair_linked_more_than_its_tags_predict_lifts_above_one()
    print("Testing a pair linked more than the tags' own totals predict has lift above 1, one linked less below")
    rows = {
        row(1, 2, "link", "directed", 30, 30),
        row(1, 3, "link", "directed", 2, 3),
        row(3, 2, "link", "directed", 2, 3),
        row(3, 3, "link", "directed", 30, 30),
    }
    lifts = tag.lifts(rows, 3)
    check(lift_of(lifts, 1, 2, "link") > 1.0, "1 -> 2 should lift above 1, got " .. tostring(lift_of(lifts, 1, 2, "link")))
    check(lift_of(lifts, 1, 3, "link") < 1.0, "1 -> 3 should lift below 1, got " .. tostring(lift_of(lifts, 1, 3, "link")))
end

function test_rows_under_min_support_get_no_lift()
    print("Testing a pair resting on fewer than min_support edges gets no lift at all")
    lifts = tag.lifts({row(1, 2, "link", "directed", 2, 2), row(2, 1, "link", "directed", 9, 9)}, 3)
    check(lift_of(lifts, 1, 2, "link") == nil, "support 2 < 3 should be dropped")
    check(lift_of(lifts, 2, 1, "link") != nil, "support 9 should be kept")
end

function test_kinds_are_scored_apart()
    print("Testing a kind with thousands of edges doesn't change another kind's lift")
    few = {row(1, 2, "connection", "undirected", 6, 6), row(1, 1, "connection", "undirected", 2, 3),
           row(2, 2, "connection", "undirected", 2, 3)}
    alone = lift_of(tag.lifts(few, 3), 1, 2, "connection")
    many = {row(1, 2, "lineage", "directed", 5000, 5000), row(2, 1, "lineage", "directed", 10, 10)}
    for _, r in ipairs(few) do
        table.insert(many, r)
    end
    together = lift_of(tag.lifts(many, 3), 1, 2, "connection")
    check(alone != nil and math.abs(alone - together) < 1e-9,
        "connection lift should be the same with or without a heavy lineage kind, got " .. tostring(alone) .. " vs " .. tostring(together))
end

function test_lift_is_pulled_towards_one()
    print("Testing shrinkage: lift lies between 1 and the raw observed/expected ratio")
    -- 1 -> 2 and 3 -> 4, four edges each: expected 4 * 4 / 8 = 2, raw ratio 2.
    lift = lift_of(tag.lifts({row(1, 2, "link", "directed", 4, 4), row(3, 4, "link", "directed", 4, 4)}, 3), 1, 2, "link")
    check(lift > 1.0 and lift < 2.0, "shrunk lift should sit between 1 and 2, got " .. tostring(lift))
end

function same(list, expected)
    if #list != #expected then
        return false
    end
    for i = 1, #list do
        if list[i] != expected[i] then
            return false
        end
    end
    return true
end

function test_text_tags_follow_the_syntax()
    print("Testing #tag syntax: a letter first, - and _ inside, each tag once, in order, lowercased")
    found = tag.text_tags("#Fermentation notes on #cocoa-butter and #cocoa_bean, again #fermentation.")
    check(same(found, {"fermentation", "cocoa-butter", "cocoa_bean"}), "got " .. table.concat(found, ","))
end

function test_text_tags_skip_what_isnt_a_tag()
    print("Testing headings, #123, URL fragments, #a/b, spreadsheet errors, [[links]] and code are not tags")
    content = "# Heading\n## Sub\n#123 and page#section, http://x.org/#frag\n#a/b and [[Notes #draft]]\n`#inline` code\n```\n#fenced\n```\n#REF! and #NAME? cells\n(#real)"
    found = tag.text_tags(content)
    check(same(found, {"real"}), "only (#real) should count, got " .. table.concat(found, ","))
end

function test_slug_matches_how_a_label_is_written()
    print("Testing a label's slug is how it's written as a #tag")
    check(tag.slug("Cocoa bean fermentation") == "cocoa-bean-fermentation", "got " .. tag.slug("Cocoa bean fermentation"))
    check(tag.slug("R and D: meetings!") == "r-and-d-meetings", "got " .. tag.slug("R and D: meetings!"))
end


test_a_pair_linked_more_than_its_tags_predict_lifts_above_one()
test_rows_under_min_support_get_no_lift()
test_kinds_are_scored_apart()
test_lift_is_pulled_towards_one()
test_text_tags_follow_the_syntax()
test_text_tags_skip_what_isnt_a_tag()
test_slug_matches_how_a_label_is_written()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All tag.lua tests passed")
