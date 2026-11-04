-- tst/unit/template.lua
-- Unit tests for src/template.lua: pure validation/rendering logic for
-- reusable Entry templates, including the "lookup_view" section type
-- (inline per-experiment lookup tables, see html.lua's
-- expand_inline_views). No prior test coverage existed for this
-- module at all before this file.

template = require("template")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.validate_rejects_lookup_view_missing_view_name()
    print("Testing validate rejects a lookup_view section with no view_name")
    def = {name = "t", sections = {{type = "lookup_view"}}}
    err = template.validate(def)
    check(err != nil, "missing view_name should be rejected")

    def_empty = {name = "t", sections = {{type = "lookup_view", view_name = ""}}}
    err_empty = template.validate(def_empty)
    check(err_empty != nil, "empty-string view_name should be rejected too")
end

function tests.validate_accepts_well_formed_lookup_view()
    print("Testing validate accepts a well-formed lookup_view section")
    def = {name = "t", sections = {{type = "lookup_view", view_name = "samples_by_experiment", label = "Samples"}}}
    err = template.validate(def)
    check(err == nil, "well-formed lookup_view section should be accepted: " .. tostring(err))
end

function tests.render_lookup_view_emits_marker_with_placeholder()
    print("Testing render emits an inert {{view:name:EXPERIMENT_ID}} marker for a lookup_view section")
    def = {
        name = "t",
        sections = {
            {type = "lookup_view", view_name = "samples_by_experiment", label = "Samples for this experiment"},
        },
    }
    rendered = template.render(def)
    check(string.find(rendered, "{{view:samples_by_experiment:EXPERIMENT_ID}}", 1, true) != nil,
        "rendered output should contain the literal marker with an EXPERIMENT_ID placeholder: " .. rendered)
    check(string.find(rendered, "Samples for this experiment", 1, true) != nil,
        "rendered output should include the section's own label: " .. rendered)
end

function tests.render_lookup_view_falls_back_to_view_name_as_label()
    print("Testing render falls back to view_name as the label when none is given")
    def = {name = "t", sections = {{type = "lookup_view", view_name = "samples_by_experiment"}}}
    rendered = template.render(def)
    check(string.find(rendered, "samples_by_experiment", 1, true) != nil,
        "rendered output should fall back to view_name when label is absent: " .. rendered)
end

function tests.render_mixed_sections_unchanged_behavior()
    print("Testing render still handles heading/text/registration_table exactly as before, alongside a new lookup_view section")
    def = {
        name = "t",
        sections = {
            {type = "heading", text = "Objective"},
            {type = "text", text = "Describe the goal."},
            {type = "registration_table", entity_type = "experiment", label = "Experiment"},
            {type = "lookup_view", view_name = "samples_by_experiment", label = "Samples"},
        },
    }
    rendered = template.render(def)
    check(string.find(rendered, "## Objective", 1, true) != nil, "heading section should still render as a markdown heading")
    check(string.find(rendered, "Describe the goal.", 1, true) != nil, "text section should still render verbatim")
    check(string.find(rendered, "/register?type=experiment", 1, true) != nil, "registration_table section should still render its link")
    check(string.find(rendered, "{{view:samples_by_experiment:EXPERIMENT_ID}}", 1, true) != nil, "lookup_view section should render alongside the others")
end

function tests.validate_still_rejects_invalid_section_type()
    print("Testing validate still rejects an unrecognized section type (unchanged behavior)")
    def = {name = "t", sections = {{type = "not_a_real_type"}}}
    err = template.validate(def)
    check(err != nil, "an invalid section type should still be rejected")
end

unit.run(tests)
