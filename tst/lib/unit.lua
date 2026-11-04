-- tst/lib/unit.lua
-- The shared harness for tst/unit/*.lua. Each unit file used to carry
-- its own copy of check() and a FAILURES counter, then call every test
-- by hand in a list at the bottom -- so a test written without its
-- call line was silently never run, and a test that raised killed the
-- file at that point without saying which tests it had skipped.
--
-- A unit file now declares its tests in a suite and hands it to run():
--
--   unit = require("unit")
--   check = unit.check
--   tests = unit.suite()
--
--   function tests.parses_an_empty_body()
--       check(thing.parse("") == nil, "an empty body parses to nil")
--   end
--
--   unit.run(tests)
--
-- Every function put in the suite runs, in the order it was written.
-- A test that raises counts as a failure and the rest still run. The
-- process exits non-zero when anything failed, which is all
-- bld/test.sh looks at.

unit = {}

-- Checks counted across the whole file; run() reads them.
STATE = {failures = 0, checks = 0}

-- check(condition, message): a failed check prints and is counted, and
-- the test goes on, so one run shows every broken expectation rather
-- than the first one. `condition` must be exactly true -- a truthy
-- non-boolean is a failure, the same rule every unit file already used.
function unit.check(condition, message)
    STATE.checks = STATE.checks + 1
    if condition != true then
        STATE.failures = STATE.failures + 1
        print("FAIL: " .. tostring(message))
    end
end

-- unit.suite() -> a table that keeps its tests in the order they were
-- added and refuses a second test of the same name. A plain table would
-- let a copy-pasted test quietly replace the first one of that name;
-- this one errors at load time, naming it. Only functions go in a
-- suite: shared fixtures and helpers stay ordinary file-level names.
function unit.suite()
    order = {}
    by_name = {}
    suite = {}
    setmetatable(suite, {
        __newindex = function(_, name, fn)
            if type(fn) != "function" then
                error("unit.suite: '" .. tostring(name) .. "' is not a function -- keep fixtures outside the suite", 2)
            end
            if by_name[name] != nil then
                error("unit.suite: two tests named '" .. tostring(name) .. "'", 2)
            end
            by_name[name] = fn
            table.insert(order, name)
        end,
        __index = function(_, name)
            if name == "_order" then
                return order
            end
            return by_name[name]
        end,
    })
    return suite
end

-- The running script's file name, for the summary line. Its own
-- function because inside a vararg function (run, below) Lua 5.1 binds
-- `arg` to a hidden local for `...`, not to the script's arguments.
function script_name()
    if arg == nil or arg[0] == nil then
        return "unit test"
    end
    return string.match(arg[0], "([^/]+)$")
end

-- unit.run(suite, ...) runs every test in the suite, passing `...` to
-- each (a fixture built once for the file, such as a db_path), prints a
-- one-line summary named after the file, and exits non-zero on any
-- failed check or raised error. Never returns on failure.
function unit.run(suite, ...)
    file_name = script_name()
    raised = 0
    for _, name in ipairs(suite._order) do
        ok, err = pcall(suite[name], ...)
        if not ok then
            raised = raised + 1
            print("ERROR: " .. name .. " raised: " .. tostring(err))
        end
    end
    count = #suite._order
    if STATE.failures > 0 or raised > 0 then
        print(string.format("%s: %d test(s), %d failed check(s), %d raised", file_name, count, STATE.failures, raised))
        os.exit(1)
    end
    print(string.format("%s: %d test(s), %d check(s), all passed", file_name, count, STATE.checks))
end

return unit
