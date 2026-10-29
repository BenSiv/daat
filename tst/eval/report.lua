-- Turns a run's results.jsonl into results.json + report.md
-- (doc/agent-eval.md, "Runner and report"), and prints the summary.
--
--   luam report.lua <run_dir> [compare_results.json]
--
-- Exit status 1 when any run failed a check: in test mode, where every
-- scripted reply is correct by construction, that means the workflow
-- around the model broke.

json = require("dkjson")

run_dir = arg[1]
compare_path = arg[2]
if run_dir == nil then
    print("Usage: luam report.lua <run_dir> [compare_results.json]")
    os.exit(2)
end

runs = {}
results_path = run_dir .. "/results.jsonl"
probe = io.open(results_path, "r")
if probe != nil then
    io.close(probe)
    for line in io.lines(results_path) do
        if line != "" then
            row = json.decode(line)
            if row != nil then
                table.insert(runs, row)
            end
        end
    end
end

function check_of(run, kind)
    for _, c in ipairs(run.checks) do
        if c.kind == kind then
            return c
        end
    end
    return nil
end

-- Share of runs whose `kind` checks all passed, among runs that have
-- one (a scenario may check two parts of one answer).
function rate(kind)
    have = 0
    passed = 0
    for _, run in ipairs(runs) do
        found = false
        all_pass = true
        for _, c in ipairs(run.checks) do
            if c.kind == kind then
                found = true
                if c.pass != true then
                    all_pass = false
                end
            end
        end
        if found == true then
            have = have + 1
            if all_pass == true then
                passed = passed + 1
            end
        end
    end
    if have == 0 then
        return nil
    end
    return passed / have
end

by_scenario = {}
order = {}
for _, run in ipairs(runs) do
    if by_scenario[run.scenario] == nil then
        by_scenario[run.scenario] = {}
        table.insert(order, run.scenario)
    end
    table.insert(by_scenario[run.scenario], run)
end
table.sort(order)

-- Consistent: every repeat of a scenario reached the same answer -- the
-- answer check's outcome and what it found (for a number, the value)
-- agree across repeats. Scenarios run once don't count either way.
consistent = 0
repeated = 0
for _, name in ipairs(order) do
    list = by_scenario[name]
    if #list > 1 and check_of(list[1], "answer") != nil then
        repeated = repeated + 1
        first = check_of(list[1], "answer")
        same = true
        for i = 2, #list do
            c = check_of(list[i], "answer")
            if c.pass != first.pass or c.detail != first.detail then
                same = false
            end
        end
        if same == true then
            consistent = consistent + 1
        end
    end
end

-- Solved: every repeat of the scenario passed every check. The strict
-- headline: a scenario the agent gets right two times out of three is
-- not one a person can rely on.
solved = 0
for _, name in ipairs(order) do
    all_repeats = true
    for _, run in ipairs(by_scenario[name]) do
        if run.pass != true then
            all_repeats = false
        end
    end
    if all_repeats == true then
        solved = solved + 1
    end
end

lookups = 0
tokens = 0
passed_runs = 0
passed_tokens = 0
peak_sum = 0
repeats = 0
compactions = 0
entity_gets = 0
for _, run in ipairs(runs) do
    if tonumber(run.entity_get_calls) != nil then
        entity_gets = entity_gets + tonumber(run.entity_get_calls)
    end
    if tonumber(run.peak_prompt_tokens) != nil then
        peak_sum = peak_sum + tonumber(run.peak_prompt_tokens)
    end
    if tonumber(run.exact_repeat_calls) != nil then
        repeats = repeats + tonumber(run.exact_repeat_calls)
    end
    if tonumber(run.compactions) != nil then
        compactions = compactions + tonumber(run.compactions)
    end
    if run.pass == true and tonumber(run.tokens) != nil then
        passed_tokens = passed_tokens + tonumber(run.tokens)
    end
    c = check_of(run, "no_failed_lookup")
    if c != nil and c.count != nil then
        lookups = lookups + c.count
    end
    if tonumber(run.tokens) != nil then
        tokens = tokens + tonumber(run.tokens)
    end
    if run.pass == true then
        passed_runs = passed_runs + 1
    end
end

summary = {
    runs = #runs,
    scenarios = #order,
    solved_every_repeat = nil,
    all_checks_passed = nil,
    correct = rate("answer"),
    no_latex = rate("no_latex"),
    labels_not_ids = rate("labels_not_ids"),
    names_record = rate("names_record"),
    links_documents = rate("links_documents"),
    no_dangling_links = rate("no_dangling_links"),
    not_filed_under = rate("not_filed_under"),
    keeps_content = rate("keeps_content"),
    approval_safety = rate("approval"),
    cites_sources = rate("cites"),
    shows_method = rate("shows_method"),
    says_unknown = rate("says_unknown"),
    finished = rate("finished"),
    consistency = nil,
    failed_lookups_per_run = nil,
    tokens_per_run = nil,
    tokens_per_passed_run = nil,
    peak_prompt_tokens = nil,
    repeat_calls_per_run = nil,
    compactions_per_run = nil,
    entity_get_calls_per_run = nil,
}
if #order > 0 then
    summary.solved_every_repeat = solved / #order
end
if #runs > 0 then
    summary.all_checks_passed = passed_runs / #runs
    summary.failed_lookups_per_run = lookups / #runs
    summary.tokens_per_run = tokens / #runs
    summary.peak_prompt_tokens = peak_sum / #runs
    summary.repeat_calls_per_run = repeats / #runs
    summary.compactions_per_run = compactions / #runs
    summary.entity_get_calls_per_run = entity_gets / #runs
end
-- Tokens per completed task: what a correct answer costs, so a change
-- that saves tokens by failing more doesn't look like a win.
if passed_runs > 0 then
    summary.tokens_per_passed_run = passed_tokens / passed_runs
end
if repeated > 0 then
    summary.consistency = consistent / repeated
end

previous = nil
if compare_path != nil then
    cfile = io.open(compare_path, "r")
    if cfile != nil then
        previous = json.decode(io.read(cfile, "*all")).summary
        io.close(cfile)
    end
end

SCORES = {
    {"solved_every_repeat", "Scenarios solved on every repeat", "pct"},
    {"all_checks_passed", "All checks passed", "pct"},
    {"correct", "Correct answers", "pct"},
    {"no_latex", "Plain-text formulas (no LaTeX)", "pct"},
    {"labels_not_ids", "Names records by label, not id", "pct"},
    {"names_record", "Names the record itself", "pct"},
    {"links_documents", "Links the right documents", "pct"},
    {"no_dangling_links", "No links to nothing", "pct"},
    {"not_filed_under", "Files new documents sensibly", "pct"},
    {"keeps_content", "Keeps content on edit", "pct"},
    {"approval_safety", "Approval safety", "pct"},
    {"cites_sources", "Cites sources", "pct"},
    {"shows_method", "Shows method", "pct"},
    {"says_unknown", "Says when data lacks the answer", "pct"},
    {"finished", "Finished", "pct"},
    {"consistency", "Consistency across repeats", "pct"},
    {"failed_lookups_per_run", "Failed lookups per run", "num"},
    {"tokens_per_run", "Tokens per run", "int"},
    {"tokens_per_passed_run", "Tokens per passed run", "int"},
    {"peak_prompt_tokens", "Peak prompt tokens (avg per run)", "int"},
    {"repeat_calls_per_run", "Exact repeat calls per run", "num"},
    {"compactions_per_run", "Compactions per run", "num"},
    {"entity_get_calls_per_run", "entity.get calls per run", "num"},
}

function fmt(value, kind)
    if value == nil then
        return "-"
    end
    if kind == "pct" then
        return string.format("%.0f%%", value * 100)
    elseif kind == "int" then
        return string.format("%d", math.floor(value + 0.5))
    end
    return string.format("%.2f", value)
end

function delta(name, kind)
    if previous == nil or previous[name] == nil or summary[name] == nil then
        return "-"
    end
    d = summary[name] - previous[name]
    if kind == "pct" then
        return string.format("%+.0f pts", d * 100)
    elseif kind == "int" then
        return string.format("%+d", math.floor(d + 0.5))
    end
    return string.format("%+.2f", d)
end

lines = {"# Agent scorecard", ""}
if #runs > 0 then
    table.insert(lines, string.format("Mode: %s. %d scenarios, %d runs.", tostring(runs[1].mode), #order, #runs))
    table.insert(lines, "")
end
table.insert(lines, "| Score | Value | Change |")
table.insert(lines, "|-------|-------|--------|")
for _, s in ipairs(SCORES) do
    table.insert(lines, string.format("| %s | %s | %s |", s[2], fmt(summary[s[1]], s[3]), delta(s[1], s[3])))
end
table.insert(lines, "")
table.insert(lines, "| Scenario | Set | Passed | Failing checks |")
table.insert(lines, "|----------|-----|--------|----------------|")
failures = {}
for _, name in ipairs(order) do
    list = by_scenario[name]
    ok = 0
    failing = {}
    for _, run in ipairs(list) do
        if run.pass == true then
            ok = ok + 1
        else
            for _, c in ipairs(run.checks) do
                if c.pass != true then
                    failing[c.kind] = true
                end
            end
            table.insert(failures, run)
        end
    end
    kinds = {}
    for k, _ in pairs(failing) do
        table.insert(kinds, k)
    end
    table.sort(kinds)
    table.insert(lines, string.format("| %s | %s | %d/%d | %s |", name, tostring(list[1].set), ok, #list, table.concat(kinds, ", ")))
end
if #failures > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Failures")
    table.insert(lines, "")
    for _, run in ipairs(failures) do
        table.insert(lines, string.format("### %s, repeat %s (status %s)", run.scenario, tostring(run["repeat"]), tostring(run.status)))
        table.insert(lines, "")
        for _, c in ipairs(run.checks) do
            if c.pass != true then
                table.insert(lines, "- `" .. c.kind .. "`: " .. tostring(c.detail))
            end
        end
        if run.error != nil then
            table.insert(lines, "- error: " .. tostring(run.error))
        end
        table.insert(lines, string.format("- transcript: `work/%s-%s/transcript.md`", run.scenario, tostring(run["repeat"])))
        table.insert(lines, "")
    end
end

report = table.concat(lines, "\n") .. "\n"
out = io.open(run_dir .. "/report.md", "w")
io.write(out, report)
io.close(out)
out = io.open(run_dir .. "/results.json", "w")
io.write(out, json.encode({summary = summary, runs = runs}, {indent = true}))
io.close(out)

for _, s in ipairs(SCORES) do
    print(string.format("%-34s %8s  %s", s[2], fmt(summary[s[1]], s[3]), delta(s[1], s[3])))
end
print("Report: " .. run_dir .. "/report.md")

if passed_runs < #runs or #runs == 0 then
    os.exit(1)
end
