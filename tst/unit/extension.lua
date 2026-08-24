-- tst/unit/extension.lua
-- Unit tests for src/extension.lua's sandboxed hook invocation
-- (extension.invoke). Previously untested end to end -- this is also
-- the mechanism that was silently broken by relying on a since-fixed
-- Luam compiler gap (bare `function name() end` leaking to the real
-- global instead of being implicit-local like `name = value` already
-- was; see ../../luam/doc/manifesto.md tenet 5 and doc/why-luam.md).
-- Pins the migration: hooks are returned as a table (matching
-- manifest.lua's own convention), never read back from a bare global.

extension = require("extension")
lfs = require("lfs")
paths = require("paths")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

-- Fresh temp directory containing <ext_dir>/<name>/main.lua with the
-- given source. No manifest.lua on disk -- extension.invoke() takes
-- an already-loaded manifest table directly, it never reads
-- manifest.lua itself.
function make_extension(main_src)
    ext_dir = os.tmpname()
    os.remove(ext_dir)
    lfs.mkdir(ext_dir)
    name = "test-ext"
    lfs.mkdir(paths.joinpath(ext_dir, name))
    f = io.open(paths.joinpath(ext_dir, name, "main.lua"), "w")
    io.write(f, main_src)
    io.close(f)
    return ext_dir, name
end

function test_hook_returned_in_table_is_invoked()
    print("Testing a hook returned as return {on_before = ...} is found and called")
    ext_dir, name = make_extension("""
return {
    on_before = function(new, old, ctx)
        return {new.quantity}
    end,
}
""")
    manifest = {capabilities = {}}
    ok, result = extension.invoke(ext_dir, name, manifest, "on_before", {quantity = 5}, nil, {})
    check(ok == true, "expected invoke to succeed, got: " .. tostring(result))
    check(type(result) == "table" and result[1] == 5, "expected the hook's own return value passed through")
end

function test_missing_hook_is_a_graceful_noop()
    print("Testing a main.lua that returns a table without the requested hook is treated as no-op, not an error")
    ext_dir, name = make_extension("""
return {
    on_after = function(new, old, ctx) end,
}
""")
    manifest = {capabilities = {}}
    ok, result = extension.invoke(ext_dir, name, manifest, "on_before", {}, nil, {})
    check(ok == true, "expected (true, nil) when the hook isn't defined, got ok=" .. tostring(ok))
    check(result == nil, "expected nil result for an undefined hook")
end

function test_bare_function_statement_no_longer_exposes_a_hook()
    print("Testing the old bare `function on_before() end` convention (pre-fix) is now correctly inert, not silently broken in some other way")
    ext_dir, name = make_extension("""
function on_before(new, old, ctx)
    return {new.quantity}
end
""")
    manifest = {capabilities = {}}
    ok, result = extension.invoke(ext_dir, name, manifest, "on_before", {quantity = 5}, nil, {})
    check(ok == true, "a chunk with no return value must still run cleanly, got ok=" .. tostring(ok))
    check(result == nil, "the bare function is implicit-local now -- it must never reach the host as a hook")
end

function test_no_return_value_at_all_is_also_a_graceful_noop()
    print("Testing a main.lua with no return statement at all doesn't error")
    ext_dir, name = make_extension("""
x = 1
""")
    manifest = {capabilities = {}}
    ok, result = extension.invoke(ext_dir, name, manifest, "on_before", {}, nil, {})
    check(ok == true, "expected success even with no return value, got ok=" .. tostring(ok))
    check(result == nil, "expected nil result")
end

-- Run them
test_hook_returned_in_table_is_invoked()
test_missing_hook_is_a_graceful_noop()
test_bare_function_statement_no_longer_exposes_a_hook()
test_no_return_value_at_all_is_also_a_graceful_noop()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All extension.lua tests passed")
