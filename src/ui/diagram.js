(function(){
    var toggle = document.getElementById('platform-view-toggle');
    var listView = document.getElementById('platform-view-list');
    var diagramView = document.getElementById('platform-view-diagram');
    if(toggle && listView && diagramView){
        toggle.querySelectorAll('button').forEach(function(btn){
            btn.addEventListener('click', function(){
                var view = btn.getAttribute('data-view');
                listView.style.display = (view === 'list') ? '' : 'none';
                diagramView.style.display = (view === 'diagram') ? '' : 'none';
                toggle.querySelectorAll('button').forEach(function(b){
                    b.classList.toggle('platform-view-active', b === btn);
                });
            });
        });
    }

    var hideEmpty = document.getElementById('platform-hide-empty');
    if(hideEmpty && listView){
        hideEmpty.addEventListener('change', function(){
            listView.querySelectorAll('li[data-count]').forEach(function(li){
                var isEmpty = li.getAttribute('data-count') === '0';
                li.style.display = (hideEmpty.checked && isEmpty) ? 'none' : '';
            });
        });
    }

    var svg = document.getElementById('platform-diagram-svg');
    if(!svg) return;
    var nodes = svg.querySelectorAll('.platform-diagram-node');
    var edges = svg.querySelectorAll('.platform-diagram-edge');

    // -- Pan/zoom: the SVG's own viewBox is the "camera" (no group
    // transform needed) -- scroll to zoom (cursor-anchored, so the
    // point under the pointer stays put), drag the background to pan.
    // Node drag/click (wired further down) already stops its own
    // mousedown from doing anything else; this only starts a pan when
    // the press didn't land on a node in the first place.
    var naturalView = (svg.getAttribute('data-natural-view') || svg.getAttribute('viewBox')).split(' ').map(Number);
    var MIN_VB_W = naturalView[2] * 0.15, MAX_VB_W = naturalView[2] * 4;

    function currentViewBox(){
        var v = svg.getAttribute('viewBox').split(' ').map(Number);
        return {x: v[0], y: v[1], w: v[2], h: v[3]};
    }
    document.getElementById('platform-diagram-reset-view').addEventListener('click', function(){
        svg.setAttribute('viewBox', naturalView.join(' '));
    });
    svg.addEventListener('wheel', function(ev){
        ev.preventDefault();
        var vb = currentViewBox();
        var rect = svg.getBoundingClientRect();
        var mx = ev.clientX - rect.left, my = ev.clientY - rect.top;
        var svgX = vb.x + (mx / rect.width) * vb.w;
        var svgY = vb.y + (my / rect.height) * vb.h;
        var factor = Math.exp(ev.deltaY * 0.001);
        var newW = Math.max(MIN_VB_W, Math.min(MAX_VB_W, vb.w * factor));
        var newH = newW * (vb.h / vb.w);
        var newX = svgX - (mx / rect.width) * newW;
        var newY = svgY - (my / rect.height) * newH;
        svg.setAttribute('viewBox', newX + ' ' + newY + ' ' + newW + ' ' + newH);
    }, {passive: false});
    svg.addEventListener('mousedown', function(ev){
        if(ev.button !== 0 || (ev.target.closest && ev.target.closest('.platform-diagram-node'))){ return; }
        var vb = currentViewBox();
        var rect = svg.getBoundingClientRect();
        var startClientX = ev.clientX, startClientY = ev.clientY;
        svg.classList.add('platform-diagram-panning');
        function onPanMove(ev2){
            var dx = (ev2.clientX - startClientX) * (vb.w / rect.width);
            var dy = (ev2.clientY - startClientY) * (vb.h / rect.height);
            svg.setAttribute('viewBox', (vb.x - dx) + ' ' + (vb.y - dy) + ' ' + vb.w + ' ' + vb.h);
        }
        function onPanEnd(){
            window.removeEventListener('mousemove', onPanMove);
            window.removeEventListener('mouseup', onPanEnd);
            svg.classList.remove('platform-diagram-panning');
        }
        window.addEventListener('mousemove', onPanMove);
        window.addEventListener('mouseup', onPanEnd);
    });
    function related(a, b){
        var isRelated = false;
        edges.forEach(function(edge){
            var from = edge.getAttribute('data-from'), to = edge.getAttribute('data-to');
            if((from === a && to === b) || (from === b && to === a)){ isRelated = true; }
        });
        return isRelated;
    }

    // -- Drag-to-reposition (doc/relation-diagram-interactivity.md).
    // No physics/simulation here, unlike /knowledge-graph -- this
    // layout already starts from a sane packed grid, a live sim would
    // just be solving a problem that doesn't exist for this page. Each
    // node's own <g> gets a translate() offset (its child rects/text
    // stay in the server-computed coordinates untouched); edges are
    // separate elements connecting specific field *rows*, not box
    // centers, so each one's original x1/y1/x2/y2 is captured once at
    // load and re-derived from its two endpoint boxes' current offsets
    // on every move, rather than recomputed from scratch.
    var LAYOUT_CACHE_KEY = 'platform-relation-diagram-layout-v1';
    var nodeOffsets = {};

    function loadCachedOffsets(){
        try {
            var raw = window.localStorage.getItem(LAYOUT_CACHE_KEY);
            return raw ? JSON.parse(raw) : null;
        } catch(err) { return null; }
    }
    function saveCachedOffsets(){
        try {
            var out = {};
            Object.keys(nodeOffsets).forEach(function(type){
                var base = nodeBase[type], off = nodeOffsets[type];
                out[type] = base ? {dx: off.dx, dy: off.dy, x: base.x + off.dx, y: base.y + off.dy} : off;
            });
            window.localStorage.setItem(LAYOUT_CACHE_KEY, JSON.stringify(out));
        }
        catch(err) { /* private browsing / storage disabled / quota -- skip, not load-bearing */ }
    }
    function svgPoint(ev){
        var pt = svg.createSVGPoint();
        pt.x = ev.clientX; pt.y = ev.clientY;
        var ctm = svg.getScreenCTM();
        if(!ctm){ return {x: ev.clientX, y: ev.clientY}; }
        var p = pt.matrixTransform(ctm.inverse());
        return {x: p.x, y: p.y};
    }
    function updateEdgesFor(type){
        edges.forEach(function(edge){
            var from = edge.getAttribute('data-from'), to = edge.getAttribute('data-to');
            if(from !== type && to !== type){ return; }
            var orig = edge._platformOrig;
            if(!orig){ return; }
            var fromOff = nodeOffsets[from] || {dx: 0, dy: 0};
            var toOff = nodeOffsets[to] || {dx: 0, dy: 0};
            var line = edge.querySelector('line');
            line.setAttribute('x1', orig.x1 + fromOff.dx);
            line.setAttribute('y1', orig.y1 + fromOff.dy);
            line.setAttribute('x2', orig.x2 + toOff.dx);
            line.setAttribute('y2', orig.y2 + toOff.dy);
            var texts = edge.querySelectorAll('text');
            texts[0].setAttribute('x', orig.labels[0].x + fromOff.dx);
            texts[0].setAttribute('y', orig.labels[0].y + fromOff.dy);
            texts[1].setAttribute('x', orig.labels[1].x + toOff.dx);
            texts[1].setAttribute('y', orig.labels[1].y + toOff.dy);
        });
    }
    edges.forEach(function(edge){
        var line = edge.querySelector('line');
        var texts = edge.querySelectorAll('text');
        edge._platformOrig = {
            x1: parseFloat(line.getAttribute('x1')), y1: parseFloat(line.getAttribute('y1')),
            x2: parseFloat(line.getAttribute('x2')), y2: parseFloat(line.getAttribute('y2')),
            labels: [
                {x: parseFloat(texts[0].getAttribute('x')), y: parseFloat(texts[0].getAttribute('y'))},
                {x: parseFloat(texts[1].getAttribute('x')), y: parseFloat(texts[1].getAttribute('y'))}
            ]
        };
    });
    var nodeBase = {};
    var nodeElementByType = {};
    nodes.forEach(function(node){
        var type = node.getAttribute('data-entity-type');
        nodeOffsets[type] = {dx: 0, dy: 0};
        nodeElementByType[type] = node;
        var rect = node.querySelector('.platform-diagram-box');
        nodeBase[type] = {
            x: parseFloat(rect.getAttribute('x')), y: parseFloat(rect.getAttribute('y')),
            w: parseFloat(rect.getAttribute('width')), h: parseFloat(rect.getAttribute('height'))
        };
    });
    var cached = loadCachedOffsets();

    // -- Auto-arrange: Fruchterman-Reingold force-directed placement
    // (Fruchterman & Reingold, "Graph Drawing by Force-directed
    // Placement", 1991) -- the standard, well-documented algorithm for
    // this job, not an ad-hoc force mix. Repulsion (k*k/d) acts between
    // EVERY pair, not just overlapping ones -- an earlier version here
    // only pushed apart boxes whose margins already overlapped, so any
    // pair that wasn't already touching felt no separating force at
    // all, and the constant center-pull (nothing opposed it for most
    // pairs) dragged the whole layout inward over time. Attraction
    // (d*d/k) pulls along edges. Displacement per node is capped by a
    // "temperature" that cools linearly from AUTO_T0 to ~0 over
    // AUTO_ITERATIONS -- convergence is guaranteed by the schedule
    // itself, not an energy-below-threshold heuristic that depends on
    // the forces happening to settle cleanly.
    //
    // k (ideal distance) isn't one global constant, since boxes vary a
    // lot in size (field count) at a fixed width -- idealDistance(a, b)
    // floors the classic sqrt(area/n) value at the two boxes' own
    // combined half-diagonals (the largest gap either could need
    // regardless of relative angle) plus a gap, so equilibrium distance
    // never asks two boxes to sit closer than their footprints allow.
    var types = Object.keys(nodeBase);
    var vb0 = svg.viewBox.baseVal;
    var AUTO_AREA = vb0.width * vb0.height;
    var AUTO_EDGE_GAP = 40;
    var AUTO_BASE_K = Math.sqrt(AUTO_AREA / Math.max(1, types.length));
    var AUTO_ITERATIONS = 300;
    var AUTO_T0 = Math.max(vb0.width, vb0.height) / 10;
    var AUTO_CENTER_PULL = 0.01;
    // A node with no edges has nothing else pulling it toward the rest
    // of the graph -- a connected node is anchored by its spring, but
    // an isolated one only has this one weak term opposing every other
    // node's repulsion, so it equilibrates arbitrarily far away
    // ("lost in the void") unless its own pull is much stronger.
    var AUTO_CENTER_PULL_ISOLATED = 0.12;
    // Backstop regardless of how well the force balance is tuned --
    // nothing should ever be able to drift further than this from
    // center, isolated or not.
    var AUTO_MAX_DIST_FROM_CENTER = Math.max(vb0.width, vb0.height) * 0.75;
    var AUTO_CLEANUP_ITERATIONS = 40;
    var AUTO_BOX_MARGIN = 16;
    var autoRunning = false;

    var degree = {};
    types.forEach(function(type){ degree[type] = 0; });
    edges.forEach(function(edge){
        var from = edge.getAttribute('data-from'), to = edge.getAttribute('data-to');
        if(degree[from] != null){ degree[from]++; }
        if(degree[to] != null && to !== from){ degree[to]++; }
    });

    function nodeRect(type){
        var base = nodeBase[type], off = nodeOffsets[type];
        return {x: base.x + off.dx, y: base.y + off.dy, w: base.w, h: base.h};
    }
    function nodeCenter(type){
        var r = nodeRect(type);
        return {x: r.x + r.w / 2, y: r.y + r.h / 2};
    }
    function idealDistance(a, b){
        var ra = nodeBase[a], rb = nodeBase[b];
        var halfA = Math.sqrt(ra.w * ra.w + ra.h * ra.h) / 2;
        var halfB = Math.sqrt(rb.w * rb.w + rb.h * rb.h) / 2;
        return Math.max(AUTO_BASE_K, halfA + halfB + AUTO_EDGE_GAP);
    }
    function applyOffset(type){
        var node = nodeElementByType[type];
        if(node){ node.setAttribute('transform', 'translate(' + nodeOffsets[type].dx + ',' + nodeOffsets[type].dy + ')'); }
        updateEdgesFor(type);
    }
    function moveBy(type, dx, dy){
        nodeOffsets[type].dx += dx;
        nodeOffsets[type].dy += dy;
        applyOffset(type);
    }

    function frStep(centerX, centerY, temperature){
        var disp = {};
        types.forEach(function(type){ disp[type] = {x: 0, y: 0}; });
        for(var i = 0; i < types.length; i++){
            for(var j = i + 1; j < types.length; j++){
                var a = types[i], b = types[j];
                var ca = nodeCenter(a), cb = nodeCenter(b);
                var dx = ca.x - cb.x, dy = ca.y - cb.y;
                var dist = Math.sqrt(dx * dx + dy * dy) || 0.01;
                var k = idealDistance(a, b);
                var force = (k * k) / dist;
                disp[a].x += (dx / dist) * force; disp[a].y += (dy / dist) * force;
                disp[b].x -= (dx / dist) * force; disp[b].y -= (dy / dist) * force;
            }
        }
        edges.forEach(function(edge){
            var from = edge.getAttribute('data-from'), to = edge.getAttribute('data-to');
            if(!nodeBase[from] || !nodeBase[to] || from === to){ return; }
            var pa = nodeCenter(from), pb = nodeCenter(to);
            var dx = pb.x - pa.x, dy = pb.y - pa.y;
            var dist = Math.sqrt(dx * dx + dy * dy) || 0.01;
            var k = idealDistance(from, to);
            var force = (dist * dist) / k;
            disp[from].x += (dx / dist) * force; disp[from].y += (dy / dist) * force;
            disp[to].x -= (dx / dist) * force; disp[to].y -= (dy / dist) * force;
        });
        types.forEach(function(type){
            var c = nodeCenter(type);
            var pull = (degree[type] > 0) ? AUTO_CENTER_PULL : AUTO_CENTER_PULL_ISOLATED;
            disp[type].x += (centerX - c.x) * pull;
            disp[type].y += (centerY - c.y) * pull;
            var len = Math.sqrt(disp[type].x * disp[type].x + disp[type].y * disp[type].y) || 0.01;
            var capped = Math.min(len, temperature);
            moveBy(type, (disp[type].x / len) * capped, (disp[type].y / len) * capped);

            // Hard backstop: clamp back onto the max-distance circle
            // around center regardless of how the force balance played
            // out this step.
            var nc = nodeCenter(type);
            var fromCenterX = nc.x - centerX, fromCenterY = nc.y - centerY;
            var distFromCenter = Math.sqrt(fromCenterX * fromCenterX + fromCenterY * fromCenterY);
            if(distFromCenter > AUTO_MAX_DIST_FROM_CENTER){
                var scale = AUTO_MAX_DIST_FROM_CENTER / distFromCenter;
                var targetX = centerX + fromCenterX * scale, targetY = centerY + fromCenterY * scale;
                moveBy(type, targetX - nc.x, targetY - nc.y);
            }
        });
    }

    // Point-based FR doesn't know a box's actual footprint beyond
    // idealDistance's floor, which is a worst-case (diagonal) safe
    // distance -- two boxes settling axis-aligned at exactly that
    // distance can still clip. A few pure AABB-overlap separation
    // passes (push apart along whichever axis overlaps less), no
    // attraction/repulsion involved, cleans up what's left.
    function cleanupStep(){
        for(var i = 0; i < types.length; i++){
            for(var j = i + 1; j < types.length; j++){
                var a = types[i], b = types[j];
                var ra = nodeRect(a), rb = nodeRect(b);
                var ax1 = ra.x - AUTO_BOX_MARGIN, ay1 = ra.y - AUTO_BOX_MARGIN, ax2 = ra.x + ra.w + AUTO_BOX_MARGIN, ay2 = ra.y + ra.h + AUTO_BOX_MARGIN;
                var overlapX = Math.min(ax2, rb.x + rb.w) - Math.max(ax1, rb.x);
                var overlapY = Math.min(ay2, rb.y + rb.h) - Math.max(ay1, rb.y);
                if(overlapX <= 0 || overlapY <= 0){ continue; }
                var ca = nodeCenter(a), cb = nodeCenter(b);
                if(overlapX < overlapY){
                    var dirX = (ca.x <= cb.x) ? -1 : 1;
                    moveBy(a, dirX * overlapX * 0.5, 0); moveBy(b, -dirX * overlapX * 0.5, 0);
                } else {
                    var dirY = (ca.y <= cb.y) ? -1 : 1;
                    moveBy(a, 0, dirY * overlapY * 0.5); moveBy(b, 0, -dirY * overlapY * 0.5);
                }
            }
        }
    }

    function autoLoop(iteration){
        var vb = svg.viewBox.baseVal;
        if(iteration < AUTO_ITERATIONS){
            var temperature = AUTO_T0 * (1 - iteration / AUTO_ITERATIONS);
            frStep(vb.x + vb.width / 2, vb.y + vb.height / 2, temperature);
            requestAnimationFrame(function(){ autoLoop(iteration + 1); });
        } else if(iteration < AUTO_ITERATIONS + AUTO_CLEANUP_ITERATIONS){
            cleanupStep();
            requestAnimationFrame(function(){ autoLoop(iteration + 1); });
        } else {
            autoRunning = false;
            saveCachedOffsets();
        }
    }

    var autoBtn = document.getElementById('platform-diagram-auto-arrange');
    if(autoBtn){
        autoBtn.addEventListener('click', function(){
            if(autoRunning){ return; }
            autoRunning = true;
            requestAnimationFrame(function(){ autoLoop(0); });
        });
    }

    nodes.forEach(function(node){
        var type = node.getAttribute('data-entity-type');
        function highlight(){
            edges.forEach(function(edge){
                if(edge.getAttribute('data-from') === type || edge.getAttribute('data-to') === type){
                    edge.classList.add('platform-diagram-edge-active');
                }else{
                    edge.classList.add('platform-diagram-edge-dim');
                }
            });
            nodes.forEach(function(other){
                var otherType = other.getAttribute('data-entity-type');
                if(otherType != type && !related(type, otherType)){
                    other.classList.add('platform-diagram-node-dim');
                }
            });
        }
        function clear(){
            edges.forEach(function(edge){ edge.classList.remove('platform-diagram-edge-active', 'platform-diagram-edge-dim'); });
            nodes.forEach(function(other){ other.classList.remove('platform-diagram-node-dim'); });
        }
        node.addEventListener('mouseenter', highlight);
        node.addEventListener('focus', highlight);
        node.addEventListener('mouseleave', clear);
        node.addEventListener('blur', clear);

        if(cached && cached[type]){
            var c = cached[type], base = nodeBase[type];
            var dx = (typeof c.x === 'number' && base) ? (c.x - base.x) : (c.dx || 0);
            var dy = (typeof c.y === 'number' && base) ? (c.y - base.y) : (c.dy || 0);
            nodeOffsets[type] = {dx: dx, dy: dy};
            node.setAttribute('transform', 'translate(' + nodeOffsets[type].dx + ',' + nodeOffsets[type].dy + ')');
            updateEdgesFor(type);
        }

        var moved = false, startX = 0, startY = 0, startOffset = {dx: 0, dy: 0};
        function onMove(ev){
            var p = svgPoint(ev);
            var dx = p.x - startX, dy = p.y - startY;
            if(Math.abs(dx) > 2 || Math.abs(dy) > 2){ moved = true; }
            nodeOffsets[type] = {dx: startOffset.dx + dx, dy: startOffset.dy + dy};
            node.setAttribute('transform', 'translate(' + nodeOffsets[type].dx + ',' + nodeOffsets[type].dy + ')');
            updateEdgesFor(type);
        }
        function onUp(){
            window.removeEventListener('mousemove', onMove);
            window.removeEventListener('mouseup', onUp);
            node.classList.remove('platform-diagram-node-dragging');
            saveCachedOffsets();
        }
        node.addEventListener('mousedown', function(ev){
            if(ev.button !== 0){ return; }
            moved = false;
            var p = svgPoint(ev);
            startX = p.x; startY = p.y;
            startOffset = {dx: nodeOffsets[type].dx, dy: nodeOffsets[type].dy};
            node.classList.add('platform-diagram-node-dragging');
            node.parentNode.appendChild(node); // bring to front while dragging, above any box it's moved over
            ev.preventDefault();
            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
        });

        node.addEventListener('click', function(){
            if(moved){ return; }
            window.location.href = 'browse?type=' + encodeURIComponent(type);
        });
        node.addEventListener('keydown', function(e){
            if(e.key === 'Enter' || e.key === ' '){
                e.preventDefault();
                window.location.href = 'browse?type=' + encodeURIComponent(type);
            }
        });
    });
})();
