-- tst/unit/render.lua
-- Unit tests for src/render.lua's autoescape-by-default templating.

render = require("render")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.plain_interpolation_escapes_by_default()
    print("Testing {{ }} escapes HTML-significant characters")
    out = render.render("<p>{{ name }}</p>", {name = "<script>alert(1)</script>"})
    check(out == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>", "expected escaped output, got: " .. out)
end

function tests.triple_brace_is_raw()
    print("Testing {{{ }}} passes value through unescaped")
    out = render.render("<div>{{{ body }}}</div>", {body = "<b>bold</b>"})
    check(out == "<div><b>bold</b></div>", "expected raw output, got: " .. out)
end

function tests.dotted_path_lookup()
    print("Testing dotted-path context lookup")
    out = render.render("{{ theme.site_name }}", {theme = {site_name = "Celleste & Co"}})
    check(out == "Celleste &amp; Co", "expected nested lookup + escape, got: " .. out)
end

function tests.missing_key_errors()
    print("Testing a missing context key raises an error rather than rendering blank")
    ok, err = pcall(render.render, "{{ missing }}", {})
    check(ok == false, "expected an error for a missing key")
end

function tests.quotes_and_ampersand_escaped()
    print("Testing quotes and ampersands are escaped for safe attribute use")
    out = render.render('<a title="{{ t }}">', {t = "Bob & \"friends\""})
    check(out == '<a title="Bob &amp; &quot;friends&quot;">', "expected quote/ampersand escaping, got: " .. out)
end

function tests.multiple_interpolations()
    print("Testing multiple interpolations in one template")
    out = render.render("{{ a }}-{{ b }}", {a = "x", b = "y"})
    check(out == "x-y", "expected both substituted, got: " .. out)
end

unit.run(tests)
