(function(){
    var container = document.querySelector('.platform-canvas-container');
    if (!container) { return; }

    function collectInputArgs() {
        var args = {};
        container.querySelectorAll('.platform-canvas-input').forEach(function(el){
            var name = el.getAttribute('data-input-name');
            if (name) { args[name] = el.value; }
        });
        return args;
    }

    function runAction(btn) {
        var action = btn.getAttribute('data-action');
        var staticArgs = {};
        try { staticArgs = JSON.parse(btn.getAttribute('data-args') || '{}'); } catch (parseErr) {}
        // Object.assign into a fresh {} (never the parsed value
        // directly) -- an empty Lua table has no way to say "object,
        // not array", so a button with no static args of its own
        // renders as data-args="[]"; assigning string keys straight
        // onto a real Array works in JS but JSON.stringify then
        // silently drops them (only numeric indices survive), so the
        // typed input's value would vanish on the wire. A plain object
        // literal as the merge target sidesteps the ambiguity entirely.
        var args = Object.assign({}, staticArgs, collectInputArgs());
        btn.disabled = true;
        PlatformJS.postJSON(window.location.pathname + '/action', {action: action, args: args})
            .then(function(result){
                btn.disabled = false;
                if (result && result.html != null) { container.innerHTML = result.html; }
            })
            .catch(function(){ btn.disabled = false; });
    }

    container.addEventListener('click', function(e){
        var btn = e.target.closest('.platform-canvas-action');
        if (!btn) { return; }
        runAction(btn);
    });
    container.addEventListener('keydown', function(e){
        if (e.key !== 'Enter' || !e.target.closest('.platform-canvas-input')) { return; }
        var btn = container.querySelector('.platform-canvas-action');
        if (btn) { e.preventDefault(); runAction(btn); }
    });
})();
