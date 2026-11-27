(function(){
    var cache = {};
    function loadInto(trigger, pop){
        var src = trigger.getAttribute('data-platform-popover-src');
        if(cache[src] != null){ pop.innerHTML = cache[src]; return; }
        pop.innerHTML = '<span class="platform-popover-loading">Loading...</span>';
        fetch(src).then(function(resp){ return resp.json(); }).then(function(data){
            var html = (data && data.html) ? data.html : 'No preview available.';
            cache[src] = html;
            pop.innerHTML = html;
        }).catch(function(){
            pop.innerHTML = '<span class="platform-popover-error">Preview failed to load.</span>';
        });
    }
    document.querySelectorAll('.platform-popover-trigger[data-platform-popover-src]').forEach(function(trigger){
        var pop = trigger.querySelector('.platform-popover');
        if(!pop) return;
        var timer = null;
        var loaded = false;
        trigger.addEventListener('mouseenter', function(){
            // Viewport-relative position:fixed prevents clipping inside .platform-table-wrapper (overflow-x:auto).
            var rect = trigger.getBoundingClientRect();
            var popWidth = 320;
            var left = Math.min(rect.left, window.innerWidth - popWidth - 12);
            left = Math.max(left, 8);
            pop.style.position = 'fixed';
            pop.style.left = left + 'px';
            pop.style.top = (rect.bottom + 6) + 'px';
            pop.style.margin = '0';
            timer = setTimeout(function(){
                if(!loaded){ loaded = true; loadInto(trigger, pop); }
            }, 200);
        });
        trigger.addEventListener('mouseleave', function(){
            if(timer) clearTimeout(timer);
        });
    });
})();
