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
        // Merge into {} because empty Lua tables serialize as data-args="[]", and JSON.stringify drops string keys on Arrays.
        var args = Object.assign({}, staticArgs, collectInputArgs());
        var actionUrl = window.location.pathname.replace(/\/ext\/([^/]+)\/?$/, '/api/v1/extensions/$1/actions');
        btn.disabled = true;
        PlatformJS.postJSON(actionUrl, {action: action, args: args})
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
