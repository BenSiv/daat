-- tst/unit/agent_vertex.lua
-- Unit tests for src/provider/agent_vertex.lua's vertex_url: no real
-- API calls -- exercises the pure URL-building logic, matching this
-- repo's existing tst/unit/ style (require the module, check(), run
-- inline, exit 1 on failure).

agent_vertex = require("provider.agent_vertex")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_vertex_url_regional_uses_region_subdomain()
    print("Testing vertex_url prefixes the host with region for a regional location")
    url = agent_vertex.vertex_url("celleste-elab", "europe-west1", "gemini-2.5-flash:generateContent")
    expected = "https://europe-west1-aiplatform.googleapis.com/v1/projects/celleste-elab" ..
        "/locations/europe-west1/publishers/google/models/gemini-2.5-flash:generateContent"
    check(url == expected, "expected " .. expected .. ", got " .. tostring(url))
end

function test_vertex_url_global_has_no_subdomain_prefix()
    print("Testing vertex_url uses the bare host for the global location")
    url = agent_vertex.vertex_url("celleste-elab", "global", "gemini-3.5-flash-lite:generateContent")
    expected = "https://aiplatform.googleapis.com/v1/projects/celleste-elab" ..
        "/locations/global/publishers/google/models/gemini-3.5-flash-lite:generateContent"
    check(url == expected, "expected " .. expected .. ", got " .. tostring(url))
end

test_vertex_url_regional_uses_region_subdomain()
test_vertex_url_global_has_no_subdomain_prefix()

if FAILURES > 0 then
    print(tostring(FAILURES) .. " failure(s)")
    os.exit(1)
end
print("All tests passed")
