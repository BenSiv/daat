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

-- capabilities.tools validation (agent-tools plugin surface, brex
-- 278013129) -- see extension.validate_manifest's own comment for why
-- an extension's name can never collide with a built-in AGENT_TOOLS
-- group: capabilities.tools entries dispatch under tool_name =
-- manifest.name, with no separate namespace.
function base_manifest(name)
    return {name = name, events = {}, entity_types = {}}
end

function test_valid_tools_capability_passes_validation()
    print("Testing a well-formed capabilities.tools entry passes validation")
    manifest = base_manifest("widget-tools")
    manifest.capabilities = {read = {}, write = {}, net = "none", tools = {
        {name = "lookup", description = "Looks something up.", parameters = {type = "object", properties = {}}},
    }}
    err = extension.validate_manifest(manifest)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_tools_entry_missing_description_is_rejected()
    print("Testing a capabilities.tools entry without a description is rejected")
    manifest = base_manifest("widget-tools")
    manifest.capabilities = {tools = {{name = "lookup", parameters = {}}}}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a missing description")
end

function test_tools_entry_missing_parameters_is_rejected()
    print("Testing a capabilities.tools entry without a parameters table is rejected")
    manifest = base_manifest("widget-tools")
    manifest.capabilities = {tools = {{name = "lookup", description = "x"}}}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a missing parameters table")
end

function test_extension_name_colliding_with_builtin_tool_group_is_rejected()
    print("Testing an extension named after a built-in AGENT_TOOLS group is rejected once it declares capabilities.tools")
    manifest = base_manifest("entity")
    manifest.capabilities = {tools = {
        {name = "lookup", description = "x", parameters = {}},
    }}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a reserved extension name")
end

function test_extension_without_tools_can_still_use_a_reserved_name()
    print("Testing the reserved-name check only fires once an extension actually declares capabilities.tools")
    manifest = base_manifest("entity")
    manifest.capabilities = {read = {"entity"}}
    err = extension.validate_manifest(manifest)
    check(err == nil, "expected no error: no capabilities.tools means no dispatch collision to guard against")
end

-- capabilities.manual_triggers validation (admin manual-trigger
-- surface, brex 925561615) -- structurally the same shape as
-- capabilities.tools' own tests above, minus the reserved-name check:
-- a trigger dispatches under /admin-triggers/<extension name>/<trigger
-- name>, a namespace scoped by construction, so there's nothing for a
-- trigger name to collide with.
function test_valid_manual_triggers_capability_passes_validation()
    print("Testing a well-formed capabilities.manual_triggers entry passes validation")
    manifest = base_manifest("snapshot-refresher")
    manifest.capabilities = {manual_triggers = {
        {name = "refresh", label = "Refresh now", description = "Refreshes the analysis snapshot."},
    }}
    err = extension.validate_manifest(manifest)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_manual_trigger_entry_missing_label_is_rejected()
    print("Testing a capabilities.manual_triggers entry without a label is rejected")
    manifest = base_manifest("snapshot-refresher")
    manifest.capabilities = {manual_triggers = {{name = "refresh", description = "x"}}}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a missing label")
end

function test_manual_trigger_entry_missing_description_is_rejected()
    print("Testing a capabilities.manual_triggers entry without a description is rejected")
    manifest = base_manifest("snapshot-refresher")
    manifest.capabilities = {manual_triggers = {{name = "refresh", label = "Refresh now"}}}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a missing description")
end

function test_manual_trigger_entry_missing_name_is_rejected()
    print("Testing a capabilities.manual_triggers entry without a name is rejected")
    manifest = base_manifest("snapshot-refresher")
    manifest.capabilities = {manual_triggers = {{label = "Refresh now", description = "x"}}}
    err = extension.validate_manifest(manifest)
    check(err != nil, "expected a validation error for a missing name")
end

-- capabilities_equal (approval invalidation, brex 925561615) -- like
-- capabilities.ui/tools, a manual trigger's presence is a real grant
-- (an admin-reachable entry point into the extension's own code), so
-- adding one or editing an existing one's label/description has to
-- invalidate a prior approval, not silently keep it.
function test_capabilities_equal_ignores_missing_manual_triggers_on_both_sides()
    print("Testing capabilities_equal treats two capability tables with no manual_triggers at all as equal")
    check(extension.capabilities_equal({read = {"entity"}}, {read = {"entity"}}) == true,
        "expected equal capability tables (neither declaring manual_triggers) to compare equal")
end

function test_capabilities_equal_detects_added_manual_trigger()
    print("Testing capabilities_equal detects a manual trigger added since approval")
    approved = {manual_triggers = {}}
    current = {manual_triggers = {{name = "refresh", label = "Refresh now", description = "x"}}}
    check(extension.capabilities_equal(approved, current) == false,
        "expected a newly-added manual trigger to invalidate approval")
end

function test_capabilities_equal_detects_edited_manual_trigger_label()
    print("Testing capabilities_equal detects a manual trigger's label changing since approval")
    approved = {manual_triggers = {{name = "refresh", label = "Refresh now", description = "x"}}}
    current = {manual_triggers = {{name = "refresh", label = "Refresh immediately", description = "x"}}}
    check(extension.capabilities_equal(approved, current) == false,
        "expected an edited manual trigger label to invalidate approval")
end

function test_capabilities_equal_accepts_identical_manual_triggers()
    print("Testing capabilities_equal accepts an unchanged manual_triggers list")
    approved = {manual_triggers = {{name = "refresh", label = "Refresh now", description = "x"}}}
    current = {manual_triggers = {{name = "refresh", label = "Refresh now", description = "x"}}}
    check(extension.capabilities_equal(approved, current) == true,
        "expected an unchanged manual_triggers list to still compare equal")
end

-- Run them
test_hook_returned_in_table_is_invoked()
test_missing_hook_is_a_graceful_noop()
test_bare_function_statement_no_longer_exposes_a_hook()
test_no_return_value_at_all_is_also_a_graceful_noop()
test_valid_tools_capability_passes_validation()
test_tools_entry_missing_description_is_rejected()
test_tools_entry_missing_parameters_is_rejected()
test_extension_name_colliding_with_builtin_tool_group_is_rejected()
test_extension_without_tools_can_still_use_a_reserved_name()
test_valid_manual_triggers_capability_passes_validation()
test_manual_trigger_entry_missing_label_is_rejected()
test_manual_trigger_entry_missing_description_is_rejected()
test_manual_trigger_entry_missing_name_is_rejected()
test_capabilities_equal_ignores_missing_manual_triggers_on_both_sides()
test_capabilities_equal_detects_added_manual_trigger()
test_capabilities_equal_detects_edited_manual_trigger_label()
test_capabilities_equal_accepts_identical_manual_triggers()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All extension.lua tests passed")
