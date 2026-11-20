-- Retention strategies per data type, overrides, legacy alias, and
-- pruned tool-trace stub handling (doc/agent-data.md, "Retention"; #35).

config = require("config")
agent = require("agent")
json = require("dkjson")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.strategies_resolve_to_doc_table()
    print("Testing full, standard and lean strategies resolve to doc/agent-data.md's table")
    def = config.resolve_retention(nil)
    check(def.strategy == "standard", "nil defaults to standard")
    check(def.knowledge_days == "forever", "standard knowledge_days")
    check(def.tool_trace_days == 90, "standard tool_trace_days")
    check(def.model_input_days == 30, "standard model_input_days")
    check(def.metrics_days == "forever", "standard metrics_days")
    check(def.transcript_documents == "off", "standard transcript_documents")

    full = config.resolve_retention({agent_retention = "full"})
    check(full.strategy == "full", "full strategy")
    check(full.knowledge_days == "forever", "full knowledge_days")
    check(full.tool_trace_days == "forever", "full tool_trace_days")
    check(full.model_input_days == "forever", "full model_input_days")
    check(full.metrics_days == "forever", "full metrics_days")
    check(full.transcript_documents == "whole", "full transcript_documents")

    lean = config.resolve_retention({agent_retention = "lean"})
    check(lean.strategy == "lean", "lean strategy")
    check(lean.knowledge_days == 30, "lean knowledge_days")
    check(lean.tool_trace_days == 14, "lean tool_trace_days")
    check(lean.model_input_days == 0, "lean model_input_days (not stored)")
    check(lean.metrics_days == "forever", "lean metrics_days")
    check(lean.transcript_documents == "off", "lean transcript_documents")

    bogus = config.resolve_retention({agent_retention = "unknown"})
    check(bogus.strategy == "standard", "unknown strategy falls back to standard")
end

function tests.override_wins_over_strategy()
    print("Testing agent_retention_override wins over its strategy per key")
    ov = config.resolve_retention({
        agent_retention = "standard",
        agent_retention_override = {
            tool_trace_days = 30,
            metrics_days = 180,
            transcript_documents = "whole",
        },
    })
    check(ov.strategy == "standard", "strategy stays standard")
    check(ov.tool_trace_days == 30, "tool_trace_days overridden")
    check(ov.metrics_days == 180, "metrics_days overridden")
    check(ov.transcript_documents == "whole", "transcript_documents overridden")
    check(ov.model_input_days == 30, "unmentioned model_input_days keeps strategy value")
    check(ov.knowledge_days == "forever", "unmentioned knowledge_days keeps strategy value")

    forever_ov = config.resolve_retention({
        agent_retention = "lean",
        agent_retention_override = {
            knowledge_days = "forever",
            model_input_days = 7,
        },
    })
    check(forever_ov.knowledge_days == "forever", "lean knowledge_days overridden to forever")
    check(forever_ov.model_input_days == 7, "lean model_input_days overridden to 7")
    check(forever_ov.tool_trace_days == 14, "lean tool_trace_days kept")
end


function tests.tool_trace_stub_and_repeat_pinned_guards()
    print("Testing tool_trace_stub shape and pruned-stub guards in find_repeat / pinned_schema_block")
    stub = agent.tool_trace_stub("entity.query", 4210, 90)
    check(stub == "[result pruned after 90 days: entity.query, 4210 characters]", "stub shape: " .. tostring(stub))

    history = {
        {role = "assistant", content = {{type = "toolCall", id = "c1", name = "entity.fields", arguments = {entity_type = "sample"}}}},
        {role = "toolResult", toolCallId = "c1", toolName = "entity.fields", content = {{type = "text", text = stub}}, isError = false, pruned = true},
    }
    check(agent.find_repeat(history, "entity.fields", {entity_type = "sample"}, function() return false end) == nil,
        "a pruned toolResult must not satisfy find_repeat")

    rows = {
        {role = "assistant", content = json.encode({blocks = {{type = "toolCall", id = "c1", name = "entity.list_types", arguments = {}}}})},
        {role = "tool_result", content = json.encode({tool_call_id = "c1", tool_name = "entity.list_types", text = stub, is_error = false, pruned = true})},
    }
    check(agent.pinned_schema_block(rows, 6000) == nil, "a pruned schema result must not be pinned")
end

unit.run(tests)

