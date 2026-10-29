-- Demo-lab generator (doc/agent-eval.md, "The demo lab").
--
-- Deterministic: the same seed always yields the same records,
-- documents and facts. The facts -- the answers scenarios check
-- against -- come from the same parameters that produced the data, so
-- no expected value is ever typed by hand and the two can't drift.
--
-- Records reference each other by key ("@exp-03"), never by id: ids
-- come from the database's own sequence when tst/eval/load.lua creates
-- the rows, and load.lua resolves keys to real ids in facts.json.
--
-- Returns {records = {...}, documents = {...}, facts = {...}}:
--   records:   ordered {key, type, values, archive}; a value "@key" is a
--              reference, a list of them a multi_reference, and
--              {type = "...", ref = "@key"} a polymorphic reference
--   documents: ordered {key, title, content}
--   facts:     plain data scenarios read (see the end of this file)

-- Park-Miller minimal standard generator: every intermediate product
-- stays below 2^53, so it is exact in Lua's double-precision numbers
-- and gives the same sequence on every platform.
function new_rng(seed)
    rng = {state = seed % 2147483646 + 1}
    function rng.next()
        rng.state = (rng.state * 16807) % 2147483647
        return (rng.state - 1) / 2147483646
    end
    function rng.int(lo, hi)
        return lo + math.floor(rng.next() * (hi - lo + 1))
    end
    function rng.pick(list)
        return list[rng.int(1, #list)]
    end
    return rng
end

function round(x, places)
    m = 10 ^ places
    return math.floor(x * m + 0.5) / m
end

-- Days since 1970-01-01 for a proleptic Gregorian date, and back --
-- plain arithmetic, so no dependence on the host's time zone.
function days_from_civil(y, m, d)
    if m <= 2 then
        y = y - 1
    end
    era = math.floor(y / 400)
    yoe = y - era * 400
    mp = (m + 9) % 12
    doy = math.floor((153 * mp + 2) / 5) + d - 1
    doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function civil_from_days(z)
    z = z + 719468
    era = math.floor(z / 146097)
    doe = z - era * 146097
    yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    mp = math.floor((5 * doy + 2) / 153)
    d = doy - math.floor((153 * mp + 2) / 5) + 1
    m = mp + 3
    if m > 12 then
        m = m - 12
    end
    if m <= 2 then
        y = y + 1
    end
    return string.format("%04d-%02d-%02d", y, m, d)
end

PEOPLE = {
    {"Mira Kovac", "scientist"},
    {"Tomas Lindqvist", "scientist"},
    {"Aiko Tanabe", "technician"},
    {"Ruben Okafor", "technician"},
    {"Lena Haddad", "student"},
    {"Jonas Weber", "student"},
}

PROJECTS = {
    {"Sugar utilisation in S. demo", 1, "active"},
    {"Low-cost media screening", 2, "active"},
    {"Temperature tolerance", 1, "closed"},
}

INGREDIENTS = {
    {"Glucose", 20}, {"Sucrose", 20}, {"Yeast extract", 10}, {"Peptone", 20},
    {"Ammonium sulfate", 5}, {"Potassium phosphate", 3}, {"Magnesium sulfate", 0.5},
    {"Agar", 15}, {"Molasses", 40}, {"Corn steep liquor", 15},
}

MEDIA = {
    {"YPD", {1, 3, 4}, 6.5},
    {"Minimal glucose", {1, 5, 6, 7}, 5.5},
    {"Sucrose broth", {2, 3, 5}, 6.0},
    {"Molasses medium", {9, 10, 5, 6}, 5.8},
}

INCUBATORS = {"Incubator A", "Incubator B", "Incubator C", "Shaker room 2"}

OBSERVATIONS = {
    "Cultures looked healthy throughout; no clumping.",
    "Slight foaming after the first day; added one drop of antifoam.",
    "Lag phase was longer than usual, probably an old inoculum.",
    "Colour shifted to light brown by the end, as expected for this medium.",
}

function generate(opts)
    if opts == nil then
        opts = {}
    end
    seed = opts.seed
    if seed == nil then
        seed = 20261020
    end
    experiment_count = opts.experiments
    if experiment_count == nil then
        experiment_count = 24
    end
    rng = new_rng(seed)

    out = {records = {}, documents = {}, facts = {}}
    facts = out.facts
    facts.seed = seed
    facts.experiments = {}
    facts.experiment_order = {}
    facts.media = {}
    facts.projects = {}

    function add(key, entity_type, values, archive)
        table.insert(out.records, {key = key, type = entity_type, values = values, archive = archive == true})
    end

    for i, p in ipairs(PEOPLE) do
        add("person-" .. i, "person", {full_name = p[1], role = p[2]})
    end
    for i, p in ipairs(PROJECTS) do
        add("project-" .. i, "project", {title = p[1], lead = "@person-" .. p[2], status = p[3]})
        facts.projects[i] = {key = "project-" .. i, title = p[1], lead = PEOPLE[p[2]][1], finished_count = 0}
    end
    for i, ing in ipairs(INGREDIENTS) do
        add("ingredient-" .. i, "ingredient", {label = ing[1], grams_per_litre = ing[2]})
    end
    for i, m in ipairs(MEDIA) do
        refs = {}
        labels = {}
        for _, ing_index in ipairs(m[2]) do
            table.insert(refs, "@ingredient-" .. ing_index)
            table.insert(labels, INGREDIENTS[ing_index][1])
        end
        add("medium-" .. i, "culture_medium", {label = m[1], ingredients = refs, ph = m[3]})
        facts.media[i] = {key = "medium-" .. i, label = m[1], ingredients = labels}
    end

    first_day = days_from_civil(2026, 1, 5)
    hours = {0, 3, 6, 9, 12}
    for i = 1, experiment_count do
        -- 17 is coprime with 43, so these lab numbers are all distinct;
        -- offset from 10 so none can be mistaken for a small row id.
        lab_number = string.format("EXP-%03d", 10 + (i * 17) % 43)
        project_index = rng.int(1, #PROJECTS)
        medium_index = rng.int(1, #MEDIA)
        owner_index = rng.int(1, #PEOPLE)
        start_day = first_day + (i - 1) * 6 + rng.int(0, 2)
        duration = rng.int(2, 6)
        status = "finished"
        if i > experiment_count - 2 then
            status = "planned"
        elseif i > experiment_count - 5 then
            status = "running"
        end
        -- Every eighth finished experiment is superseded by a repeat and
        -- archived: counts must filter archived_at to be right.
        archived = status == "finished" and i % 8 == 0
        medium_label = MEDIA[medium_index][1]
        title = "Growth of S. demo on " .. medium_label
        values = {
            title = title,
            lab_number = lab_number,
            project = "@project-" .. project_index,
            medium = "@medium-" .. medium_index,
            owner = "@person-" .. owner_index,
            status = status,
        }
        started_on = nil
        ended_on = nil
        if status != "planned" then
            started_on = civil_from_days(start_day)
            values.started_on = started_on
        end
        if status == "finished" then
            ended_on = civil_from_days(start_day + duration)
            values.ended_on = ended_on
        end
        exp_key = "exp-" .. i
        add(exp_key, "experiment", values, archived)

        fact = {
            key = exp_key, lab_number = lab_number, title = title, status = status,
            archived = archived, project = PROJECTS[project_index][1], project_index = project_index,
            medium = medium_label, medium_index = medium_index, owner = PEOPLE[owner_index][1],
            started_on = started_on, ended_on = ended_on,
        }
        if ended_on != nil then
            fact.days = duration
        end
        if status == "finished" and archived == false then
            facts.projects[project_index].finished_count = facts.projects[project_index].finished_count + 1
        end

        if status != "planned" then
            -- Two samples: the first inoculated from the experiment, the
            -- second subcultured from the first (polymorphic source).
            s1 = exp_key .. "-s1"
            s2 = exp_key .. "-s2"
            add(s1, "sample", {label = lab_number .. "-A", experiment = "@" .. exp_key,
                source = {type = "experiment", ref = "@" .. exp_key}})
            add(s2, "sample", {label = lab_number .. "-B", experiment = "@" .. exp_key,
                source = {type = "sample", ref = "@" .. s1}})
            doubling = round(1.5 + rng.next() * 3.5, 2)
            od0 = round(0.05 + rng.next() * 0.05, 3)
            for j, h in ipairs(hours) do
                od = round(od0 * 2 ^ (h / doubling), 4)
                add(s1 .. "-m" .. j, "measurement", {sample = "@" .. s1, hours = h, od600 = od})
                if j == 1 then
                    fact.od_first = od
                end
                fact.od_last = od
            end
            fact.sample_label = lab_number .. "-A"
            fact.doubling_time_hours = doubling
            fact.incubator = rng.pick(INCUBATORS)
            fact.observation = rng.pick(OBSERVATIONS)
            fact.notes_key = "doc-notes-" .. i
            table.insert(out.documents, {
                key = fact.notes_key,
                title = "Notes: " .. title .. " (" .. lab_number .. ")",
                content = "# " .. lab_number .. " lab notes\n\n" ..
                    "Owner: " .. fact.owner .. ". Started " .. started_on .. ".\n\n" ..
                    "Cultures were grown in " .. fact.incubator .. " at 30 C, 180 rpm.\n\n" ..
                    fact.observation .. "\n",
            })
        end
        facts.experiments[lab_number] = fact
        table.insert(facts.experiment_order, lab_number)
    end

    -- A replicate series whose cultures level off (the growth-phase
    -- trap): OD600 rises exponentially, then plateaus at PLATEAU_OD. The
    -- doubling time is only right fitted over the growth phase; first-
    -- vs-last over the whole run counts the plateau as slow growth. The
    -- replicates' doubling times are far enough apart that no single
    -- one is within 5% of their mean.
    PLATEAU_OD = 0.8
    replicate_doubling = {2.0, 2.8, 3.6, 4.6}
    series_key = "exp-replicates"
    series_number = "EXP-061"
    add(series_key, "experiment", {
        title = "Replicate growth series on YPD", lab_number = series_number,
        project = "@project-1", medium = "@medium-1", owner = "@person-1",
        started_on = "2026-06-01", ended_on = "2026-06-02", status = "finished",
    })
    -- A finished, live experiment in project 1 like any other: counts
    -- of finished experiments must include it.
    facts.projects[1].finished_count = facts.projects[1].finished_count + 1
    series = {lab_number = series_number, key = series_key, replicates = {}}
    total = 0
    for r, doubling in ipairs(replicate_doubling) do
        sample_key = series_key .. "-r" .. r
        label = series_number .. "-R" .. r
        add(sample_key, "sample", {label = label, experiment = "@" .. series_key,
            source = {type = "experiment", ref = "@" .. series_key}})
        for h = 0, 24, 2 do
            od = round(math.min(0.05 * 2 ^ (h / doubling), PLATEAU_OD), 4)
            add(sample_key .. "-h" .. h, "measurement", {sample = "@" .. sample_key, hours = h, od600 = od})
        end
        table.insert(series.replicates, {label = label, doubling_time_hours = doubling,
            endpoint_estimate_hours = round(24 * math.log(2) / math.log(PLATEAU_OD / 0.05), 2)})
        total = total + doubling
    end
    series.mean_doubling_time_hours = total / #replicate_doubling
    facts.replicate_series = series

    -- Three weekly meeting notes share one title; only the middle one
    -- records the media decision (the duplicate-title trap). The first
    -- and last disagree on how often to read OD600, and the last one
    -- replaces the first (the conflicting-sources trap: the answer is the
    -- latest decision, not whichever note a search returns first).
    meetings = {"2026-02-02", "2026-02-09", "2026-02-16"}
    decision_medium = MEDIA[4][1]
    for i, day in ipairs(meetings) do
        body = "# Weekly lab meeting\n\nDate: " .. day .. "\n\n- Status round, no blockers.\n"
        if i == 1 then
            body = body .. "- Decision: during growth runs, read OD600 every 3 hours.\n"
        elseif i == 2 then
            body = body .. "- Decision: all new screening runs use " .. decision_medium ..
                " from March, to cut media cost.\n"
        elseif i == 3 then
            body = body .. "- Decision: read OD600 every 2 hours during growth runs from now on; " ..
                "the 3-hour schedule missed the end of the exponential phase.\n"
        end
        table.insert(out.documents, {key = "doc-meeting-" .. i, title = "Weekly lab meeting", content = body})
    end
    facts.media_decision = {medium = decision_medium, meeting_date = meetings[2], doc_key = "doc-meeting-2"}
    facts.od_interval = {hours = 2, replaced_hours = 3, meeting_date = meetings[3], doc_key = "doc-meeting-3",
        replaced_doc_key = "doc-meeting-1"}

    -- A long, multi-section protocol (the distillation trap).
    table.insert(out.documents, {
        key = "doc-protocol-od",
        title = "Protocol: measuring culture density (OD600)",
        content = "# Measuring culture density (OD600)\n\n" ..
            "## Purpose\n\nTrack growth of liquid cultures by optical density at 600 nm.\n\n" ..
            "## Equipment\n\n- Spectrophotometer, 1 cm cuvettes\n- Sterile medium for blanks\n\n" ..
            "## Steps\n\n1. Blank the instrument with sterile medium.\n" ..
            "2. Take 1 ml of culture aseptically.\n" ..
            "3. Dilute 1:10 if the reading is above 0.8, and multiply back.\n" ..
            "4. Record the reading with the sample label and hours since inoculation.\n\n" ..
            "## Calculating doubling time\n\nFit ln(OD600) against time in hours over the exponential phase. " ..
            "The doubling time is ln(2) divided by the slope.\n\n" ..
            "## Safety\n\nWork at the bench with gloves; autoclave cuvettes after use.\n",
    })
    facts.protocol_doc_key = "doc-protocol-od"

    -- A long lab handbook whose facts sit in late sections and share few
    -- words with how people ask about them (doc/passage-retrieval-
    -- plan.md): a keyword excerpt lands on its opening sections; the
    -- passage that answers is found by meaning. Fixed text, no rng(), so
    -- every other generated fact stays the same.
    filler_sections = {
        {"Working hours and access", "The lab is open on weekdays from eight in the morning until seven in the evening. Visitors sign in at the front desk and are accompanied at all times. Badges are renewed every January, and lost badges are reported to the office the same day. Weekend work is agreed with the lab manager a week ahead, and nobody works alone after hours."},
        {"Ordering", "Consumables are ordered through the purchasing sheet every Tuesday. Write the catalogue number, the supplier and the quantity, and mark anything urgent. Deliveries arrive on Thursdays and are unpacked by whoever placed the order. Keep the packing slips in the blue folder for the monthly reconciliation."},
        {"Waste", "Biological waste goes into the orange bags, which are autoclaved before disposal. Sharps go into the yellow containers, never into ordinary bins. Chemical waste is collected in labelled bottles by type, and the safety officer arranges collection when a bottle is three quarters full. Glass is rinsed and put in the cardboard glass box."},
        {"Cleaning", "Benches are wiped with seventy percent ethanol at the start and end of each session. The shared centrifuge is cleaned after any spill and checked weekly. Every Friday someone from the rota empties the water baths, defrosts the small fridge if needed, and restocks gloves and paper towels."},
        {"Equipment booking", "The plate reader, the spectrophotometer and the shaking platforms are booked on the shared calendar. Book in blocks of at most two hours during the day, and leave a note if a run will go overnight. Report any fault in the equipment log and put an out of order sign on the instrument."},
        {"Data and notebooks", "Every experiment gets a lab number before it starts. Raw instrument files are saved to the shared drive under that number on the same day, and the notebook entry links to them. Never overwrite a raw file; corrections go in a new version with a note explaining the change."},
    }
    body = "# Lab handbook\n\nHow the lab runs day to day. Ask the lab manager about anything not covered here.\n\n"
    for _, section in ipairs(filler_sections) do
        body = body .. "## " .. section[1] .. "\n\n" .. section[2] .. " " .. section[2] .. "\n\n"
    end
    body = body ..
        "## Glycerol stocks\n\nGlycerol stocks of every strain are kept in freezer F3, rack B, box 12, at minus eighty. " ..
        "Take a stock out only on dry ice and put it back within ten minutes; never let it thaw.\n\n" ..
        "## Antibiotics\n\nLet autoclaved media cool for forty-five minutes, to about 55 C, before adding antibiotics, " ..
        "or the heat breaks them down.\n"
    table.insert(out.documents, {key = "doc-handbook", title = "Lab handbook", content = body})
    facts.handbook = {
        doc_key = "doc-handbook",
        stocks_location = "F3",
        stocks_question = "Where are the frozen backups of our yeast kept?",
        cooling_minutes = "45",
        cooling_question = "How long do I wait after sterilising broth before putting in the antibiotics?",
    }

    -- Asked about, but recorded nowhere: the agent should say so.
    facts.unknown = {
        {question = "Which supplier provided the yeast extract?", subject = "yeast extract supplier"},
    }
    return out
end

return {generate = generate}
