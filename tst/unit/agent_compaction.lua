-- Phase 3 of doc/context-management-plan.md: the verbatim user requests
-- an anchored summary carries from one compaction to the next.
-- tst/integration/agent_compaction.bats covers the turn loop.

agent = require("agent")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.user_requests_round_trip()
    print("Testing verbatim user requests read back as written, lists inside a request included")
    summary = "## Established facts\nnone\n\n" .. agent.COMPACTION_USER_REQUESTS_HEADER .. "\n" ..
        agent.format_user_request("compare these:\n- batch A\n- batch B") .. "\n" ..
        agent.format_user_request("continue")
    body, requests = agent.parse_user_requests(summary)
    check(body == "## Established facts\nnone", "the prose comes back without the requests: " .. body)
    check(#requests == 2, "two requests, got " .. #requests)
    check(requests[1] == "compare these:\n- batch A\n- batch B", "a multi-line request is one entry, verbatim: " .. tostring(requests[1]))
    check(requests[2] == "continue", "then the next one")
end

function tests.no_requests()
    print("Testing a summary without requests")
    body, requests = agent.parse_user_requests("## Decisions\nnone")
    check(body == "## Decisions\nnone" and #requests == 0, "the text is all prose")
end

unit.run(tests)
