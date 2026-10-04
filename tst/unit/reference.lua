-- reference.lua's pure rules: which names are distinctive enough to be
-- reference targets, and which keys a text offers for lookup.

reference = require("reference")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function has(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

function test_only_distinctive_names_are_targets()
    print("Testing a name is a target only with 4+ characters, a letter, and a digit or inner punctuation")
    check(reference.name_key("Exp185") == "exp185", "Exp185 -> exp185")
    check(reference.name_key("C.COT.IN-1.2") == "ccotin12", "C.COT.IN-1.2 -> ccotin12, got " .. tostring(reference.name_key("C.COT.IN-1.2")))
    check(reference.name_key("C.SE.IND") == "cseind", "C.SE.IND has inner punctuation, no digit")
    check(reference.name_key("Exp227 Sample96") == "exp227sample96", "spaces are ignored")
    check(reference.name_key("A") == nil, "A is too short")
    check(reference.name_key("Water") == nil, "Water has no digit or inner punctuation")
    check(reference.name_key("error") == nil, "error is a word, not a name")
    check(reference.name_key("391") == nil, "391 has no letter")
    check(reference.name_key("B2") == nil, "B2 is under 4 characters")
end

function test_text_offers_spacing_insensitive_keys()
    print("Testing a text's keys ignore case, spacing and separators, and keep shorter runs inside longer ones")
    keys = reference.candidate_keys("Callus from exp 227 sample 96, then EXP-185 on c.cot.in-1.2.", nil)
    check(has(keys, "exp227sample96"), "'exp 227 sample 96' should offer exp227sample96")
    check(has(keys, "exp227"), "and its experiment, exp227")
    check(has(keys, "exp185"), "'EXP-185' should offer exp185")
    check(has(keys, "ccotin12"), "the medium code should survive its trailing full stop")
    check(not has(keys, "callusfrom"), "word runs with no digit or inner punctuation aren't looked up")
end

function test_aliases_rewrite_how_people_write_names()
    print("Testing a deployment alias turns 'Experiment 185' into exp185")
    keys = reference.candidate_keys("Results of Experiment 185.", {{"experiment%s*(%d)", "exp%1"}})
    check(has(keys, "exp185"), "alias should give exp185")
    check(not has(reference.candidate_keys("Results of Experiment 185.", nil), "exp185"), "without it, no exp185")
end

test_only_distinctive_names_are_targets()
test_text_offers_spacing_insensitive_keys()
test_aliases_rewrite_how_people_write_names()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All reference.lua tests passed")
