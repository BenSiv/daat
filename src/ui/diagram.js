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

    // ViewBox camera: cursor-anchored wheel zoom and background drag pan.
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

    // Dragging translates node <g> elements and offsets captured field-row edge endpoints (see doc/relation-diagram-interactivity.md).
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
        catch(err) {}
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

    // Fruchterman-Reingold auto-arrange with box-diagonal idealDistance floor and stronger center pull for isolated nodes.
    var types = Object.keys(nodeBase);
    var vb0 = svg.viewBox.baseVal;
    var AUTO_AREA = vb0.width * vb0.height;
    var AUTO_EDGE_GAP = 40;
    var AUTO_BASE_K = Math.sqrt(AUTO_AREA / Math.max(1, types.length));
    var AUTO_ITERATIONS = 300;
    var AUTO_T0 = Math.max(vb0.width, vb0.height) / 10;
    var AUTO_CENTER_PULL = 0.01;
    var AUTO_CENTER_PULL_ISOLATED = 0.12;
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

    // Post-FR AABB separation pass to eliminate residual axis-aligned box overlaps.
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
            node.parentNode.appendChild(node);
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
