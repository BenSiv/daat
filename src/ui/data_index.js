(function(){
    var input = document.getElementById('platform-entity-search-input');
    var results = document.getElementById('platform-entity-search-results');

    function render(items) {
        if (items.length === 0) {
            results.innerHTML = '<div class="platform-entity-search-empty">No matching entities.</div>';
        } else {
            results.innerHTML = items.map(function(item){
                var sub = item.subtitle ? '<span class="platform-entity-search-sub">&middot; ' + PlatformJS.escapeHtml(item.subtitle) + '</span>' : '';
                return '<a href="detail?type=' + encodeURIComponent(item.entity_type) + '&entity_id=' + item.id + '"><span>' +
                    PlatformJS.escapeHtml(item.label) + sub + '</span><span class="platform-entity-search-type">' + PlatformJS.escapeHtml(item.entity_type) + '</span></a>';
            }).join('');
        }
        results.classList.add('platform-entity-search-open');
    }

    var doSearch = PlatformJS.debounce(function(query){
        PlatformJS.fetchJSON('api/entity-search?query=' + encodeURIComponent(query)).then(render);
    }, 200);
    input.addEventListener('input', function(){
        var query = input.value.trim();
        if (!query) { results.classList.remove('platform-entity-search-open'); results.innerHTML = ''; return; }
        doSearch(query);
    });
    PlatformJS.onOutsideClick(input, function(){ return results; }, function(){
        results.classList.remove('platform-entity-search-open');
    });
    input.addEventListener('keydown', function(e){
        if (e.key === 'Escape') { results.classList.remove('platform-entity-search-open'); }
    });
})();

