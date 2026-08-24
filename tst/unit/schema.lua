-- tst/unit/schema_test.lua
-- Unit tests for src/schema.lua's structural validation (schema.validate).

schema = require("schema")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_valid_schema_passes()
    print("Testing a well-formed schema definition")
    def = {
        name = "reagent",
        fields = {
            {name = "lot_number", type = "text", required = true},
            {name = "concentration", type = "number", required = true},
            {name = "prepared_on", type = "date", required = true},
            {name = "status", type = "select", required = true, values = {"active", "depleted"}},
            {name = "prepared_from", type = "reference", required = false, entity_type = "reagent"},
        },
    }
    err = schema.validate(def)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_non_table_rejected()
    print("Testing a non-table definition is rejected")
    err = schema.validate("not a table")
    check(err != nil, "expected an error for a non-table definition")
end

function test_missing_name_rejected()
    print("Testing a schema with no name is rejected")
    err = schema.validate({fields = {}})
    check(err != nil, "expected an error for missing name")
end

function test_empty_name_rejected()
    print("Testing a schema with an empty string name is rejected")
    err = schema.validate({name = "", fields = {}})
    check(err != nil, "expected an error for empty name")
end

function test_missing_fields_rejected()
    print("Testing a schema with no 'fields' list is rejected")
    err = schema.validate({name = "task"})
    check(err != nil, "expected an error for missing fields")
end

function test_field_missing_name_rejected()
    print("Testing a field with no name is rejected")
    def = {name = "task", fields = {{type = "text"}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for a field with no name")
end

function test_invalid_field_type_rejected()
    print("Testing an unrecognized field type is rejected")
    def = {name = "task", fields = {{name = "priority", type = "integer"}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for type 'integer' (not one of the five real types)")
end

function test_select_without_values_rejected()
    print("Testing a 'select' field with no 'values' list is rejected")
    def = {name = "task", fields = {{name = "status", type = "select"}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for select with no values")
end

function test_select_with_values_passes()
    print("Testing a 'select' field with a 'values' list passes")
    def = {name = "task", fields = {{name = "status", type = "select", values = {"open", "done"}}}}
    err = schema.validate(def)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_every_real_field_type_individually()
    print("Testing each of the five real field types passes on its own")
    types_to_test = {"text", "number", "date", "reference"}
    for _, t in ipairs(types_to_test) do
        def = {name = "x", fields = {{name = "f", type = t}}}
        err = schema.validate(def)
        check(err == nil, "type '" .. t .. "' should be valid, got: " .. tostring(err))
    end
end

-- task #84: multi_select/multi_reference field types

function test_multi_select_without_values_or_dropdown_rejected()
    print("Testing a 'multi_select' field with neither 'values' nor 'dropdown' is rejected")
    def = {name = "sample", fields = {{name = "process", type = "multi_select"}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for multi_select with neither values nor dropdown")
end

function test_multi_select_with_inline_values_passes()
    print("Testing a 'multi_select' field with an inline 'values' list passes")
    def = {name = "sample", fields = {{name = "process", type = "multi_select", values = {"a", "b"}}}}
    err = schema.validate(def)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_multi_select_with_dropdown_reference_passes()
    print("Testing a 'multi_select' field with a 'dropdown' reference passes (no values needed)")
    def = {name = "sample", fields = {{name = "process", type = "multi_select", dropdown = "work_process"}}}
    err = schema.validate(def)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_multi_select_dropdown_must_be_nonempty_string()
    print("Testing a 'multi_select' field's 'dropdown' must be a non-empty string")
    def = {name = "sample", fields = {{name = "process", type = "multi_select", dropdown = ""}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for an empty dropdown name")
end

function test_multi_reference_passes_with_or_without_entity_type()
    print("Testing 'multi_reference' passes with an explicit entity_type, and without one (self-reference)")
    def1 = {name = "sample", fields = {{name = "descendants", type = "multi_reference", entity_type = "sample"}}}
    check(schema.validate(def1) == nil, "expected no error with explicit entity_type")
    def2 = {name = "sample", fields = {{name = "descendants", type = "multi_reference"}}}
    check(schema.validate(def2) == nil, "expected no error without entity_type (defaults to self)")
end

function test_multi_reference_entity_type_must_be_string()
    print("Testing 'multi_reference' rejects a non-string entity_type")
    def = {name = "sample", fields = {{name = "descendants", type = "multi_reference", entity_type = 42}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for a non-string entity_type")
end

function test_is_multi_field_type()
    print("Testing is_multi_field_type recognizes only the two multivalue types")
    check(schema.is_multi_field_type("multi_select") == true, "multi_select should be a multi field type")
    check(schema.is_multi_field_type("multi_reference") == true, "multi_reference should be a multi field type")
    check(schema.is_multi_field_type("select") == false, "select should not be a multi field type")
    check(schema.is_multi_field_type("reference") == false, "reference should not be a multi field type")
    check(schema.is_multi_field_type("text") == false, "text should not be a multi field type")
end

function test_multi_field_table_name()
    print("Testing multi_field_table_name's naming convention")
    check(schema.multi_field_table_name("sample", "source_plants") == "sample_source_plants",
        "expected 'sample_source_plants', got '" .. schema.multi_field_table_name("sample", "source_plants") .. "'")
end

function test_normalize_multi_value_passes_through_a_real_array()
    print("Testing normalize_multi_value passes a real Lua array through unchanged")
    result = schema.normalize_multi_value({1, 2, 3})
    check(#result == 3, "expected 3 items, got " .. tostring(#result))
    check(result[1] == 1 and result[2] == 2 and result[3] == 3, "expected [1,2,3] unchanged")
end

function test_normalize_multi_value_splits_a_comma_string()
    print("Testing normalize_multi_value splits a comma-separated string (CLI convenience)")
    result = schema.normalize_multi_value("1, 2,3")
    check(#result == 3, "expected 3 items, got " .. tostring(#result))
    check(result[1] == "1" and result[2] == "2" and result[3] == "3",
        "expected trimmed items ['1','2','3'], got ['" .. tostring(result[1]) .. "','" .. tostring(result[2]) .. "','" .. tostring(result[3]) .. "']")
end

function test_normalize_multi_value_handles_nil_and_empty()
    print("Testing normalize_multi_value returns an empty list for nil/empty input")
    check(#schema.normalize_multi_value(nil) == 0, "expected empty list for nil")
    check(#schema.normalize_multi_value("") == 0, "expected empty list for empty string")
    check(#schema.normalize_multi_value("  ,  ,") == 0, "expected empty list for all-blank comma string")
end

-- task #84: named dropdown value lists

function test_dropdown_requires_name_and_nonempty_values()
    print("Testing a dropdown definition requires a name and a non-empty values list")
    check(schema.validate_dropdown({name = "x", values = {"a"}}) == nil, "expected a well-formed dropdown to pass")
    check(schema.validate_dropdown({values = {"a"}}) != nil, "expected an error for a missing name")
    check(schema.validate_dropdown({name = "x", values = {}}) != nil, "expected an error for an empty values list")
    check(schema.validate_dropdown({name = "x"}) != nil, "expected an error for a missing values list")
end

function test_dropdown_values_must_be_nonempty_strings()
    print("Testing a dropdown's values must all be non-empty strings")
    err = schema.validate_dropdown({name = "x", values = {"a", ""}})
    check(err != nil, "expected an error for an empty-string value")
    err = schema.validate_dropdown({name = "x", values = {"a", 5}})
    check(err != nil, "expected an error for a non-string value")
end

function test_number_field_min_max_valid()
    print("Testing a number field with valid min/max passes")
    def = {name = "task", fields = {{name = "importance", type = "number", min = 1, max = 5}}}
    err = schema.validate(def)
    check(err == nil, "expected no error, got: " .. tostring(err))
end

function test_number_field_min_greater_than_max_rejected()
    print("Testing min greater than max is rejected")
    def = {name = "task", fields = {{name = "importance", type = "number", min = 5, max = 1}}}
    err = schema.validate(def)
    check(err != nil, "expected an error when min > max")
end

function test_number_field_non_numeric_min_rejected()
    print("Testing a non-numeric min is rejected")
    def = {name = "task", fields = {{name = "importance", type = "number", min = "one"}}}
    err = schema.validate(def)
    check(err != nil, "expected an error for a non-numeric min")
end

function test_valid_name_syntax_accepts_real_schema_names()
    print("Testing valid_name_syntax accepts real schema-name shapes")
    check(schema.valid_name_syntax("sample") == true, "expected 'sample' to be valid")
    check(schema.valid_name_syntax("bioreactor_run") == true, "expected 'bioreactor_run' to be valid")
    check(schema.valid_name_syntax("_private") == true, "expected '_private' to be valid")
    check(schema.valid_name_syntax("a1") == true, "expected 'a1' to be valid")
end

function test_valid_name_syntax_rejects_injection_and_traversal_shapes()
    print("Testing valid_name_syntax rejects SQL-injection/path-traversal shapes")
    check(schema.valid_name_syntax("sample; DROP TABLE sample;--") == false, "expected a stacked-statement payload to be rejected")
    check(schema.valid_name_syntax("sample WHERE 1=1") == false, "expected an embedded-SQL payload to be rejected")
    check(schema.valid_name_syntax("../../etc/passwd") == false, "expected a path-traversal payload to be rejected")
    check(schema.valid_name_syntax("sample/../other") == false, "expected an embedded slash to be rejected")
    check(schema.valid_name_syntax("Sample") == false, "expected an uppercase name to be rejected")
    check(schema.valid_name_syntax("1sample") == false, "expected a leading digit to be rejected")
    check(schema.valid_name_syntax("") == false, "expected an empty string to be rejected")
    check(schema.valid_name_syntax(nil) == false, "expected nil to be rejected")
    check(schema.valid_name_syntax(42) == false, "expected a non-string to be rejected")
end

-- Run them
test_valid_schema_passes()
test_non_table_rejected()
test_missing_name_rejected()
test_empty_name_rejected()
test_missing_fields_rejected()
test_field_missing_name_rejected()
test_invalid_field_type_rejected()
test_select_without_values_rejected()
test_select_with_values_passes()
test_every_real_field_type_individually()
test_multi_select_without_values_or_dropdown_rejected()
test_multi_select_with_inline_values_passes()
test_multi_select_with_dropdown_reference_passes()
test_multi_select_dropdown_must_be_nonempty_string()
test_multi_reference_passes_with_or_without_entity_type()
test_multi_reference_entity_type_must_be_string()
test_is_multi_field_type()
test_multi_field_table_name()
test_normalize_multi_value_passes_through_a_real_array()
test_normalize_multi_value_splits_a_comma_string()
test_normalize_multi_value_handles_nil_and_empty()
test_dropdown_requires_name_and_nonempty_values()
test_dropdown_values_must_be_nonempty_strings()
test_number_field_min_max_valid()
test_number_field_min_greater_than_max_rejected()
test_number_field_non_numeric_min_rejected()
test_valid_name_syntax_accepts_real_schema_names()
test_valid_name_syntax_rejects_injection_and_traversal_shapes()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All schema.lua tests passed")
