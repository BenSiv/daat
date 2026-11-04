-- src/aspect.lua: grouping passages by meaning and packing aspect
-- vectors (doc/aspect-retrieval-plan.md).

aspect = require("aspect")

unit = require("unit")
check = unit.check
tests = unit.suite()

function unit_vector(values)
    norm = 0
    for _, x in ipairs(values) do
        norm = norm + x * x
    end
    norm = math.sqrt(norm)
    out = {}
    for i, x in ipairs(values) do
        out[i] = x / norm
    end
    return out
end

function dot(a, b)
    s = 0
    for i = 1, #a do
        s = s + a[i] * b[i]
    end
    return s
end

-- Each index appears in exactly one group.
function check_partition(groups, n, label)
    seen = {}
    count = 0
    for _, g in ipairs(groups) do
        check(#g.members > 0, label .. ": no empty group")
        medoid_is_member = false
        for _, i in ipairs(g.members) do
            check(seen[i] == nil, label .. ": index " .. i .. " in one group only")
            seen[i] = true
            count = count + 1
            if i == g.medoid then
                medoid_is_member = true
            end
        end
        check(medoid_is_member, label .. ": the medoid is one of the group's members")
    end
    check(count == n, label .. ": every vector is in a group (" .. count .. " of " .. n .. ")")
end

function tests.group_count_grows_with_the_square_root()
    print("Testing aspect counts: about the square root of the passages, capped")
    check(aspect.group_count(0, 8) == 0, "no passages, no aspects")
    check(aspect.group_count(1, 8) == 1, "one passage, one aspect")
    check(aspect.group_count(4, 8) == 2, "4 passages give 2")
    check(aspect.group_count(10, 8) == 4, "10 passages give 4")
    check(aspect.group_count(170, 8) == 8, "a long document stops at the cap")
    check(aspect.group_count(170, 16) == 14, "a higher cap allows more")
end

-- Two subjects: vectors near the first axis, and vectors near the second.
function two_subjects()
    vs = {}
    for i = 1, 5 do
        table.insert(vs, unit_vector({1, 0.05 * i, 0, 0.01}))
    end
    for i = 1, 3 do
        table.insert(vs, unit_vector({0.02 * i, 0, 1, 0.01}))
    end
    return vs
end

function tests.group_separates_subjects()
    print("Testing grouping puts each subject in its own group, in document order")
    vs = two_subjects()
    groups = aspect.group(vs, 2, unit_vector({1, 0, 0, 0}))
    check(#groups == 2, "two subjects give two groups, got " .. #groups)
    check_partition(groups, #vs, "two subjects")
    check(groups[1].members[1] == 1 and #groups[1].members == 5, "the first subject's five passages form the first group")
    check(groups[2].members[1] == 6 and #groups[2].members == 3, "the second subject's three passages form the second group")
    check(dot(groups[2].centroid, unit_vector({0, 0, 1, 0})) > 0.99, "the second group's centroid points at its subject")
    check(math.abs(dot(groups[1].centroid, groups[1].centroid) - 1) < 1e-9, "centroids are unit vectors")
end

function tests.group_is_deterministic()
    print("Testing grouping gives the same groups every time")
    vs = two_subjects()
    a = aspect.group(vs, 3, nil)
    b = aspect.group(vs, 3, nil)
    check(#a == #b, "same number of groups")
    for gi = 1, #a do
        check(table.concat(a[gi].members, ",") == table.concat(b[gi].members, ","), "group " .. gi .. " has the same members")
        check(a[gi].medoid == b[gi].medoid, "group " .. gi .. " has the same medoid")
    end
    check_partition(a, #vs, "three groups of two subjects")
end

function tests.group_edge_cases()
    print("Testing grouping with more groups than vectors, identical vectors, and nothing")
    vs = {unit_vector({1, 0}), unit_vector({0, 1})}
    groups = aspect.group(vs, 5, nil)
    check(#groups == 2, "at most one group per vector, got " .. #groups)
    check_partition(groups, 2, "k > n")
    same = {}
    for i = 1, 4 do
        table.insert(same, unit_vector({1, 1}))
    end
    groups = aspect.group(same, 3, nil)
    check_partition(groups, 4, "identical vectors")
    check(#aspect.group({}, 3, nil) == 0, "no vectors, no groups")
end

function tests.pack_round_trips_as_int8()
    print("Testing int8 packing keeps the direction, and cutting to fewer dimensions")
    math.randomseed(7)
    raw = {}
    for i = 1, 768 do
        raw[i] = math.random() * 2 - 1
    end
    v = unit_vector(raw)
    packed = aspect.pack(v, 0)
    check(string.len(packed) == 768, "one byte per dimension, got " .. string.len(packed))
    back = aspect.unpack(packed)
    check(#back == 768, "unpacks to every dimension")
    check(dot(back, v) > 0.999, "the direction survives int8 (cosine " .. dot(back, v) .. ")")
    check(math.abs(dot(back, back) - 1) < 1e-9, "unpacked vectors are unit vectors")
    packed = aspect.pack(v, 256)
    check(string.len(packed) == 256, "aspect_dims cuts the stored vector")
    back = aspect.unpack(packed)
    cut = aspect.cut(v, 256)
    check(#cut == 256 and dot(back, cut) > 0.999, "a cut vector compares with the query cut the same way")
    check(#aspect.cut(v, 0) == 768 and #aspect.cut(v, 1000) == 768, "0 or too many dimensions keeps all")
    check(aspect.pack({0, 0, 0}, 0) == nil, "a zero vector has no direction to store")
    negative = aspect.unpack(aspect.pack(unit_vector({-1, 0.5}), 0))
    check(negative[1] < 0 and negative[2] > 0, "signs survive")
end

unit.run(tests)
