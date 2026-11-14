(function(){
    var index = JSON.parse(document.getElementById('platform-document-search-boot').textContent);
    var input = document.getElementById('platform-document-search-input');
    var results = document.getElementById('platform-document-search-results');

    // Simple ordered-subsequence fuzzy match: every character of
    // the query must appear in the title, in order (not
    // necessarily contiguous) -- consecutive matches score higher,
    // so "exp277" ranks "Experiment 277" above a title that merely
    // contains the same letters scattered further apart. A title
    // that contains the query as typed ranks above every scattered
    // match, and one that starts with it above that: "Chat: " lists
    // the chat transcripts first, not "Characterisation: ..." titles
    // that only share its letters.
    function fuzzyScore(query, title) {
        var qi = 0, score = 0, lastMatch = -2;
        var q = query.toLowerCase(), t = title.toLowerCase();
        for (var ti = 0; ti < t.length && qi < q.length; ti++) {
            if (t[ti] === q[qi]) {
                score += (ti === lastMatch + 1) ? 3 : 1;
                lastMatch = ti;
                qi++;
            }
        }
        if (qi < q.length) { return -1; }
        var at = t.indexOf(q);
        if (at === 0) { score += 2000; } else if (at > 0) { score += 1000; }
        return score;
    }

    // Enough to list a whole group ("Chat: ") in the scrolling
    // dropdown; past it, say how many matched so nothing looks missing.
    var MAX_RESULTS = 50;

    function renderResults(query) {
        if (!query) { results.classList.remove('platform-document-search-open'); results.innerHTML = ''; return; }
        var scored = [];
        index.forEach(function(item){
            var score = fuzzyScore(query, item.title);
            if (score >= 0) scored.push({item: item, score: score});
        });
        scored.sort(function(a, b){ return (b.score - a.score) || a.item.title.localeCompare(b.item.title); });
        var total = scored.length;
        scored = scored.slice(0, MAX_RESULTS);
        if (scored.length === 0) {
            results.innerHTML = '<div class="platform-document-search-empty">No matching documents.</div>';
        } else {
            results.innerHTML = scored.map(function(s){
                var title = PlatformJS.escapeHtml(s.item.title);
                return '<a href="document?entity_id=' + s.item.id + '">' + title + '</a>';
            }).join('');
            if (total > scored.length) {
                results.innerHTML += '<div class="platform-document-search-empty">Showing ' + scored.length +
                    ' of ' + total + ' matches. Type more to narrow.</div>';
            }
        }
        results.classList.add('platform-document-search-open');
    }

    input.addEventListener('input', function(){ renderResults(input.value); });
    input.addEventListener('focus', function(){ if (input.value) renderResults(input.value); });
    PlatformJS.onOutsideClick(input, function(){ return results; }, function(){
        results.classList.remove('platform-document-search-open');
    });
    // Enter searches the contents (the form submits), unless a title
    // was picked with the arrow keys, which opens it.
    var active = -1;
    function highlight(links) {
        links.forEach(function(a, i){ a.classList.toggle('platform-search-active', i === active); });
    }
    input.addEventListener('keydown', function(e){
        var links = Array.prototype.slice.call(results.querySelectorAll('a'));
        if (e.key === 'ArrowDown' && links.length) {
            e.preventDefault(); active = Math.min(active + 1, links.length - 1); highlight(links);
        } else if (e.key === 'ArrowUp' && links.length) {
            e.preventDefault(); active = Math.max(active - 1, -1); highlight(links);
        } else if (e.key === 'Enter' && active >= 0 && links[active]) {
            e.preventDefault(); window.location.href = links[active].getAttribute('href');
        } else if (e.key === 'Escape') {
            results.classList.remove('platform-document-search-open');
        }
    });
    input.addEventListener('input', function(){ active = -1; });
})();
