-- src/passage.lua: splitting documents into passages along their own
-- structure (doc/passage-retrieval-plan.md, commit 1).

passage = require("passage")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

-- Every passage must be the exact slice its offset says, the passages
-- must tile the document's text in order with no gaps or overlaps, and
-- none may be longer than max (a merged sliver may add up to min).
function check_tiling(content, passages, first, max_chars, min_chars, label)
    expected = first
    for i, p in ipairs(passages) do
        check(string.sub(content, p.offset, p.offset + string.len(p.text) - 1) == p.text, label .. ": passage " .. i .. " is the slice its offset names")
        check(p.offset == expected, label .. ": passage " .. i .. " starts where the previous ended (" .. tostring(p.offset) .. " vs " .. tostring(expected) .. ")")
        check(string.len(p.text) <= max_chars + min_chars, label .. ": passage " .. i .. " is within max + min (" .. string.len(p.text) .. ")")
        expected = p.offset + string.len(p.text)
    end
    check(expected == string.len(content) + 1, label .. ": passages reach the end of the document")
end

function test_headings_start_passages()
    print("Testing headings start passages, and each passage knows its heading")
    body = string.rep("Cells were counted daily under the microscope. ", 6)
    content = "# Intro\n" .. body .. "\n## Method\n" .. body .. "\n## Results\n" .. body
    ps = passage.split(content, 1500, 50)
    check(#ps == 3, "three sections give three passages, got " .. #ps)
    check(ps[1].heading == "# Intro" and ps[2].heading == "## Method" and ps[3].heading == "## Results", "headings attached in order")
    check(string.sub(ps[2].text, 1, 9) == "## Method", "a passage keeps its heading line")
    check_tiling(content, ps, 1, 1500, 50, "headings")
end

function test_long_sections_split_at_paragraphs_then_sentences()
    print("Testing long sections split at paragraphs, then sentences, never mid-word")
    para = string.rep("The culture grew steadily in the dark incubator. ", 8)
    content = "# Log\n" .. para .. "\n\n" .. para .. "\n\n" .. para
    ps = passage.split(content, 500, 50)
    check(#ps >= 3, "a long section is split, got " .. #ps)
    check_tiling(content, ps, 1, 500, 50, "paragraphs")
    for i, p in ipairs(ps) do
        if i < #ps then
            last_char = string.sub(p.text, -1)
            check(string.find(last_char, "[%s%.]") != nil, "piece " .. i .. " ends at a break, not mid-word: '" .. last_char .. "'")
        end
    end
    one_paragraph = "# Long\n" .. string.rep("A sentence about growth rates. ", 60)
    ps = passage.split(one_paragraph, 400, 50)
    check(#ps > 1, "a single long paragraph is split at sentences")
    check_tiling(one_paragraph, ps, 1, 400, 50, "sentences")
end

function test_slivers_merge()
    print("Testing short pieces merge into a neighbour")
    content = "# A\nshort\n# B\n" .. string.rep("long enough text here. ", 20) .. "\n# C\ntiny"
    ps = passage.split(content, 1500, 100)
    for i, p in ipairs(ps) do
        check(string.len(p.text) >= 100, "no passage under min_chars, passage " .. i .. " is " .. string.len(p.text))
    end
    check_tiling(content, ps, 1, 1500, 100, "slivers")
    check(passage.split("# Only\nshort", 1500, 100)[1].text == "# Only\nshort", "a document shorter than min is one passage, not none")
end

function test_preamble_skipped()
    print("Testing a synced file's metadata preamble isn't a passage")
    preamble = "> Source: R&D/notes.docx\n> Synced daily\n\n---\n\n"
    content = preamble .. "# Notes\n" .. string.rep("Real content of the note. ", 10)
    ps = passage.split(content, 1500, 50)
    check(#ps == 1, "one passage of real content, got " .. #ps)
    check(string.find(ps[1].text, "Synced daily", 1, true) == nil, "the preamble is skipped")
    check_tiling(content, ps, string.len(preamble) + 1, 1500, 50, "preamble")
    quoted = "> A quote that opens the note\n\nThen the note itself, long enough to stand alone as a passage."
    check(string.find(passage.split(quoted, 1500, 10)[1].text, "A quote", 1, true) != nil, "a leading quote without a closing rule is content, not preamble")
end

function test_edge_cases_and_determinism()
    print("Testing empty input, no headings, an unbreakable run, and determinism")
    check(#passage.split("", 1500, 200) == 0, "empty content gives no passages")
    check(#passage.split(nil, 1500, 200) == 0, "nil content gives no passages")
    plain = string.rep("No headings at all in this text. ", 10)
    ps = passage.split(plain, 1500, 50)
    check(#ps == 1 and ps[1].heading == nil, "text without headings is one passage with no heading")
    blob = string.rep("x", 1000)
    ps = passage.split(blob, 300, 50)
    check_tiling(blob, ps, 1, 300, 50, "unbreakable")
    content = "# A\n" .. string.rep("Same input, same passages. ", 50)
    a = passage.split(content, 300, 50)
    b = passage.split(content, 300, 50)
    same = #a == #b
    for i = 1, #a do
        same = same and a[i].offset == b[i].offset and a[i].text == b[i].text
    end
    check(same, "splitting the same content twice gives the same passages")
end

function test_select()
    print("Testing select: best scores first, within the budget and the per-document count, shown in document order")
    ps = {
        {text = string.rep("a", 300), offset = 1, heading = "# A"},
        {text = string.rep("b", 300), offset = 301, heading = "# B"},
        {text = string.rep("c", 300), offset = 601, heading = "# C"},
    }
    chosen = passage.select(ps, {0.1, 0.9, 0.5}, 700, 2)
    check(#chosen == 2, "two passages chosen, got " .. #chosen)
    check(chosen[1].offset == 301, "the best-scoring passage is chosen first")
    check(chosen[2].offset == 601, "then the next best")
    out = passage.format_passages(chosen)
    check(string.find(out, "[at character 300, under # B]", 1, true) != nil and string.find(out, "[at character 300", 1, true) < string.find(out, "[at character 600", 1, true), "shown in document order with their positions and headings")
    chosen = passage.select(ps, {0.1, 0.9, 0.5}, 400, 2)
    check(#chosen == 1, "a second passage that would overflow the budget is left out")
    chosen = passage.select(ps, {0.1, 0.9, 0.5}, 100, 2)
    check(#chosen == 1 and string.len(chosen[1].shown) <= 104, "a best passage longer than the budget is cut to it")
    chosen = passage.select(ps, {0.5, 0.5, 0.5}, 700, 1)
    check(chosen[1].offset == 1, "ties go to the earlier passage")
end

test_headings_start_passages()
test_long_sections_split_at_paragraphs_then_sentences()
test_slivers_merge()
test_preamble_skipped()
test_edge_cases_and_determinism()
test_select()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All passage.lua tests passed")
