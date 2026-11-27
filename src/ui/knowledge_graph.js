(function() {
    var canvas = document.getElementById('platform-kg-canvas');
    var ctx = canvas.getContext('2d');
    var status = document.getElementById('platform-kg-status');
    var tooltip = document.getElementById('platform-kg-tooltip');
    var resetBtn = document.getElementById('platform-kg-reset');
    var forcesToggle = document.getElementById('platform-kg-forces-toggle');
    var forcesPanel = document.getElementById('platform-kg-forces');
    var repelInput = document.getElementById('platform-kg-repel');
    var linkForceInput = document.getElementById('platform-kg-link-force');
    var linkDistanceInput = document.getElementById('platform-kg-link-distance');
    var centerInput = document.getElementById('platform-kg-center');
    var tagForceInput = document.getElementById('platform-kg-tag-force');
    var forcesResetBtn = document.getElementById('platform-kg-forces-reset');
    var nodes = [], links = [], byId = {};
    // Only linked nodes (degree > 0) run O(n^2) physics; orphans sit in a static grid (placeOrphans). See doc/knowledge-graph-explorer.md.
    var simNodes = [], orphans = [];

    // Legend and orphan filters hide nodes at draw time without perturbing simulation coordinates.
    var boot = JSON.parse(document.getElementById('platform-kg-boot').textContent);
    var TIER_LEGEND = boot.tier_legend;
    var TIER_DEFAULTS = {};
    TIER_LEGEND.forEach(function(t) { TIER_DEFAULTS[t.tier] = t.color; });
    var TAG_PALETTE = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948',
                       '#b07aa1', '#ff9da7', '#9c755f', '#17becf', '#bcbd22', '#8c564b'];
    var OTHER_TAG_COLOR = '#94a3b8', NO_TAG_COLOR = '#cbd5e1';
    var colorBy = document.getElementById('platform-kg-color-by');
    var hideOrphansInput = document.getElementById('platform-kg-hide-orphans');
    var legendItems = document.getElementById('platform-kg-legend-items');
    var VIEW_KEY = 'platform-kg-view-v2';
    var view = { colorBy: 'tier', hideOrphans: true };
    try {
        var saved = JSON.parse(localStorage.getItem(VIEW_KEY) || 'null');
        if (saved) {
            view.colorBy = (saved.colorBy === 'tag' || saved.colorBy === 'subtag') ? saved.colorBy : 'tier';
            view.hideOrphans = saved.hideOrphans !== false;
        } else {
            var old = JSON.parse(localStorage.getItem('platform-kg-view-v1') || 'null');
            if (old) { view.colorBy = old.colorBy === 'tag' ? 'tag' : 'tier'; }
        }
    } catch (e) {}
    var hiddenKeys = {}, tagColors = {};

    function saveView() { try { localStorage.setItem(VIEW_KEY, JSON.stringify(view)); } catch (e) {} }

    // "tag" groups by parent tag; "subtag" uses specific tags.
    function firstLabel(n) {
        var list = view.colorBy === 'subtag' ? n.tags : ((n.groups && n.groups.length) ? n.groups : n.tags);
        return (list && list.length) ? list[0] : null;
    }

    function nodeKey(n) {
        if (view.colorBy === 'tier') { return 'tier:' + n.tier; }
        var first = firstLabel(n);
        if (first === null) { return 'none'; }
        return tagColors[first] ? 'tag:' + first : 'other';
    }

    function nodeColor(n) {
        var key = nodeKey(n);
        if (key.indexOf('tier:') === 0) { return tierColor(n.tier); }
        if (key === 'none') { return NO_TAG_COLOR; }
        if (key === 'other') { return OTHER_TAG_COLOR; }
        return tagColors[key.slice(4)];
    }

    function isVisible(n) {
        if (hiddenKeys[nodeKey(n)]) { return false; }
        return !(view.hideOrphans && n.degree === 0);
    }

    function buildLegend() {
        var entries = [];
        if (view.colorBy === 'tier') {
            TIER_LEGEND.forEach(function(t) { entries.push({ key: 'tier:' + t.tier, label: t.label, color: tierColor(t.tier) }); });
        } else {
            // Ranks top 12 tags across currently included nodes so counts match the visible graph.
            var counts = {}, untagged = 0;
            nodes.forEach(function(n) {
                if (view.hideOrphans && n.degree === 0) { return; }
                var first = firstLabel(n);
                if (first === null) { untagged++; } else { counts[first] = (counts[first] || 0) + 1; }
            });
            var ranked = Object.keys(counts).sort(function(a, b) { return (counts[b] - counts[a]) || a.localeCompare(b); });
            tagColors = {};
            ranked.slice(0, TAG_PALETTE.length).forEach(function(tag, i) {
                tagColors[tag] = TAG_PALETTE[i];
                entries.push({ key: 'tag:' + tag, label: tag + ' (' + counts[tag] + ')', color: TAG_PALETTE[i] });
            });
            if (ranked.length > TAG_PALETTE.length) {
                var rest = ranked.slice(TAG_PALETTE.length);
                var restCount = rest.reduce(function(sum, tag) { return sum + counts[tag]; }, 0);
                entries.push({ key: 'other', label: 'Other tags: ' + rest.length + ' (' + restCount + ')', color: OTHER_TAG_COLOR });
            }
            entries.push({ key: 'none', label: (ranked.length ? 'No tag' : 'No tags yet') + ' (' + untagged + ')', color: NO_TAG_COLOR });
        }
        legendItems.innerHTML = '';
        entries.forEach(function(entry) {
            var item = document.createElement('button');
            item.type = 'button';
            item.className = 'platform-kg-legend-item' + (hiddenKeys[entry.key] ? ' platform-kg-legend-off' : '');
            item.title = 'Show or hide';
            var dot = document.createElement('span');
            dot.className = 'platform-kg-legend-dot';
            dot.style.background = entry.color;
            item.appendChild(dot);
            item.appendChild(document.createTextNode(entry.label));
            item.addEventListener('click', function() {
                hiddenKeys[entry.key] = !hiddenKeys[entry.key];
                item.classList.toggle('platform-kg-legend-off', hiddenKeys[entry.key]);
                draw();
            });
            legendItems.appendChild(item);
        });
    }

    colorBy.value = view.colorBy;
    hideOrphansInput.checked = view.hideOrphans;
    colorBy.addEventListener('change', function() {
        view.colorBy = colorBy.value; hiddenKeys = {}; saveView(); buildLegend(); draw();
    });
    hideOrphansInput.addEventListener('change', function() {
        view.hideOrphans = hideOrphansInput.checked; saveView(); buildLegend(); draw();
    });

    // World coordinates stay fixed during pan/zoom; autoFit frames visible nodes until user interaction.
    var camera = { x: 0, y: 0, scale: 1 };
    var MIN_SCALE = 0.02, MAX_SCALE = 4;
    var autoFit = true;
    function fitView() {
        var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        nodes.forEach(function(n) {
            if (!isVisible(n) || typeof n.x !== 'number') { return; }
            var r = nodeRadius(n.heat);
            minX = Math.min(minX, n.x - r); maxX = Math.max(maxX, n.x + r);
            minY = Math.min(minY, n.y - r); maxY = Math.max(maxY, n.y + r);
        });
        if (minX === Infinity) { camera = { x: 0, y: 0, scale: 1 }; return; }
        var pad = 24;
        var scale = Math.min((canvas.width - 2 * pad) / Math.max(1, maxX - minX),
                             (canvas.height - 2 * pad) / Math.max(1, maxY - minY));
        scale = Math.max(MIN_SCALE, Math.min(1, scale));
        camera = {
            scale: scale,
            x: canvas.width / 2 - (minX + maxX) / 2 * scale,
            y: canvas.height / 2 - (minY + maxY) / 2 * scale
        };
    }

    function resize() {
        canvas.width = canvas.parentElement.clientWidth - 16;
        var top = canvas.getBoundingClientRect().top + window.scrollY;
        var legend = document.querySelector('.platform-kg-legend');
        var below = (legend ? legend.offsetHeight + 12 : 0) + 32;
        canvas.height = Math.max(400, window.innerHeight - top - below);
    }
    resize();
    window.addEventListener('resize', function() { resize(); draw(); });

    // Cache root CSS variables once instead of calling getComputedStyle per frame.
    var cssVarCache = {};
    function cssVar(name, fallback) {
        if (!(name in cssVarCache)) {
            var v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
            cssVarCache[name] = v || fallback;
        }
        return cssVarCache[name];
    }

    function tierColor(tier) {
        return cssVar('--platform-tier-' + tier, TIER_DEFAULTS[tier] || '#4f46e5');
    }

    function accentColor() {
        return cssVar('--platform-accent', '#4f46e5');
    }

    function nodeRadius(heat) {
        var h = (typeof heat === 'number') ? heat : 1.0;
        return Math.max(4, Math.min(22, 4 + h * 6));
    }

    // Batch strokes by (width, alpha) and fills by color, culling off-screen primitives.
    function draw() {
        if (autoFit) { fitView(); }
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.setTransform(camera.scale, 0, 0, camera.scale, camera.x, camera.y);
        var pad = 24;
        var minX = -camera.x / camera.scale - pad, minY = -camera.y / camera.scale - pad;
        var maxX = (canvas.width - camera.x) / camera.scale + pad, maxY = (canvas.height - camera.y) / camera.scale + pad;

        var edgeBuckets = {};
        links.forEach(function(e) {
            var a = byId[e.from], b = byId[e.to];
            if (!a || !b || !isVisible(a) || !isVisible(b)) { return; }
            if ((a.x < minX && b.x < minX) || (a.x > maxX && b.x > maxX) ||
                (a.y < minY && b.y < minY) || (a.y > maxY && b.y > maxY)) { return; }
            var strength = (typeof e.strength === 'number') ? e.strength : 1.0;
            var width = Math.round(Math.max(0.5, Math.min(6, strength)) * 2) / 2;
            var alpha = Math.round(Math.max(0.15, Math.min(0.85, strength / 3)) * 20) / 20;
            var key = width + '|' + alpha;
            (edgeBuckets[key] = edgeBuckets[key] || { width: width, alpha: alpha, list: [] }).list.push(a, b);
        });
        ctx.strokeStyle = accentColor();
        Object.keys(edgeBuckets).forEach(function(key) {
            var bucket = edgeBuckets[key];
            ctx.beginPath();
            for (var i = 0; i < bucket.list.length; i += 2) {
                ctx.moveTo(bucket.list[i].x, bucket.list[i].y);
                ctx.lineTo(bucket.list[i + 1].x, bucket.list[i + 1].y);
            }
            ctx.lineWidth = bucket.width;
            ctx.globalAlpha = bucket.alpha;
            ctx.stroke();
        });
        ctx.globalAlpha = 1;

        var nodeBuckets = {};
        nodes.forEach(function(n) {
            if (!isVisible(n)) { return; }
            var r = nodeRadius(n.heat);
            if (n.x + r < minX || n.x - r > maxX || n.y + r < minY || n.y - r > maxY) { return; }
            var color = nodeColor(n);
            (nodeBuckets[color] = nodeBuckets[color] || []).push(n);
        });
        Object.keys(nodeBuckets).forEach(function(color) {
            ctx.beginPath();
            nodeBuckets[color].forEach(function(n) {
                var r = nodeRadius(n.heat);
                ctx.moveTo(n.x + r, n.y);
                ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
            });
            ctx.fillStyle = color;
            ctx.fill();
        });
    }

    function screenToWorld(sx, sy) {
        return { x: (sx - camera.x) / camera.scale, y: (sy - camera.y) / camera.scale };
    }

    function nodeAt(wx, wy) {
        var best = null, bestDist = Infinity;
        nodes.forEach(function(n) {
            if (!isVisible(n)) { return; }
            var dx = n.x - wx, dy = n.y - wy;
            var d = Math.sqrt(dx * dx + dy * dy);
            if (d <= nodeRadius(n.heat) && d < bestDist) { best = n; bestDist = d; }
        });
        return best;
    }

    function pointSegmentDistance(px, py, ax, ay, bx, by) {
        var dx = bx - ax, dy = by - ay;
        var lenSq = dx * dx + dy * dy;
        var t = lenSq > 0 ? ((px - ax) * dx + (py - ay) * dy) / lenSq : 0;
        t = Math.max(0, Math.min(1, t));
        var cx = ax + t * dx, cy = ay + t * dy;
        return Math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
    }

    function edgeAt(wx, wy) {
        var threshold = 6 / camera.scale;
        var best = null, bestDist = Infinity;
        links.forEach(function(e) {
            var a = byId[e.from], b = byId[e.to];
            if (!a || !b || !isVisible(a) || !isVisible(b)) { return; }
            var d = pointSegmentDistance(wx, wy, a.x, a.y, b.x, b.y);
            if (d <= threshold && d < bestDist) { best = e; bestDist = d; }
        });
        return best;
    }

    function showTooltip(clientX, clientY, text) {
        tooltip.textContent = text;
        tooltip.style.left = (clientX + 14) + 'px';
        tooltip.style.top = (clientY + 14) + 'px';
        tooltip.style.display = 'block';
    }

    function hideTooltip() {
        tooltip.style.display = 'none';
    }

    var dragNode = null, dragMoved = false;
    var isPanning = false, panStart = { x: 0, y: 0 }, camStart = { x: 0, y: 0 };

    function onDragMove(ev) {
        var rect = canvas.getBoundingClientRect();
        var w = screenToWorld(ev.clientX - rect.left, ev.clientY - rect.top);
        dragNode.x = w.x;
        dragNode.y = w.y;
        dragNode.manual = true;
        dragMoved = true;
        hideTooltip();
        wakeSimulation();
        draw();
    }
    function onDragEnd(ev) {
        window.removeEventListener('mousemove', onDragMove);
        window.removeEventListener('mouseup', onDragEnd);
        if (dragMoved === false && dragNode != null) {
            window.location.href = 'document?entity_id=' + dragNode.id;
            return;
        }
        if (dragNode != null) {
            dragNode.fixed = false;
            saveCachedLayout();
            wakeSimulation(1.0);
        }
        dragNode = null;
    }

    function onPanMove(ev) {
        var rect = canvas.getBoundingClientRect();
        var mx = ev.clientX - rect.left, my = ev.clientY - rect.top;
        camera.x = camStart.x + (mx - panStart.x);
        camera.y = camStart.y + (my - panStart.y);
        draw();
    }
    function onPanEnd() {
        window.removeEventListener('mousemove', onPanMove);
        window.removeEventListener('mouseup', onPanEnd);
        isPanning = false;
        canvas.style.cursor = 'grab';
    }

    canvas.addEventListener('mousedown', function(ev) {
        var rect = canvas.getBoundingClientRect();
        var mx = ev.clientX - rect.left, my = ev.clientY - rect.top;
        var w = screenToWorld(mx, my);
        var n = nodeAt(w.x, w.y);
        if (n) {
            dragNode = n;
            autoFit = false;
            // Pin during pointer hold so neighbors react live without force integration fighting the cursor.
            dragNode.fixed = true;
            dragMoved = false;
            wakeSimulation();
            window.addEventListener('mousemove', onDragMove);
            window.addEventListener('mouseup', onDragEnd);
            return;
        }
        isPanning = true;
        autoFit = false;
        panStart = { x: mx, y: my };
        camStart = { x: camera.x, y: camera.y };
        canvas.style.cursor = 'grabbing';
        window.addEventListener('mousemove', onPanMove);
        window.addEventListener('mouseup', onPanEnd);
    });

    canvas.addEventListener('mousemove', function(ev) {
        if (dragNode != null || isPanning) { return; }
        var rect = canvas.getBoundingClientRect();
        var w = screenToWorld(ev.clientX - rect.left, ev.clientY - rect.top);
        var n = nodeAt(w.x, w.y);
        if (n) {
            canvas.style.cursor = 'pointer';
            var heat = (typeof n.heat === 'number') ? n.heat : 1.0;
            var groupLine = (n.groups && n.groups.length && n.groups.join(', ') !== (n.tags || []).join(', ')) ? n.groups.join(', ') + ' › ' : '';
            var tagLine = (n.tags && n.tags.length) ? '\n' + groupLine + n.tags.join(', ') : '';
            showTooltip(ev.clientX, ev.clientY, n.title + tagLine + '\nheat ' + heat.toFixed(2));
            return;
        }
        var e = edgeAt(w.x, w.y);
        if (e) {
            canvas.style.cursor = 'default';
            var a = byId[e.from], b = byId[e.to];
            var strength = (typeof e.strength === 'number') ? e.strength : 1.0;
            var edgeText = a.title + ' ↔ ' + b.title + '\nstrength ' + strength.toFixed(2);
            showTooltip(ev.clientX, ev.clientY, edgeText);
            return;
        }
        canvas.style.cursor = 'grab';
        hideTooltip();
    });

    canvas.addEventListener('mouseleave', function() {
        hideTooltip();
        if (dragNode == null && isPanning === false) { canvas.style.cursor = 'grab'; }
    });

    canvas.addEventListener('wheel', function(ev) {
        ev.preventDefault();
        var rect = canvas.getBoundingClientRect();
        var mx = ev.clientX - rect.left, my = ev.clientY - rect.top;
        var before = screenToWorld(mx, my);
        var zoomFactor = Math.exp(-ev.deltaY * 0.001);
        autoFit = false;
        camera.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, camera.scale * zoomFactor));
        camera.x = mx - before.x * camera.scale;
        camera.y = my - before.y * camera.scale;
        hideTooltip();
        draw();
    }, { passive: false });

    resetBtn.addEventListener('click', function() {
        autoFit = true;
        draw();
    });

    var REPULSION = 6000;
    var SPRING = 0.02;
    var SPRING_LENGTH = 70;
    var CENTER_PULL = 0.001;
    // O(n) attraction toward each broad tag's centroid so unlinked same-topic nodes cluster.
    var TAG_PULL = 0.005;
    var FORCE_DEFAULTS = { repulsion: REPULSION, spring: SPRING, springLength: SPRING_LENGTH, centerPull: CENTER_PULL, tagPull: TAG_PULL };
    var SPRING_STRENGTH_CAP = 3;
    var DAMPING = 0.8;
    var MAX_SPEED = 8;
    var SLEEP_ENERGY = 0.02;
    var simRunning = false;
    var COLLISION_PADDING = 4;
    var CENTER_CONNECTIVITY_GAIN = 0.6;

    var FORCES_OPEN_KEY = 'platform-kg-controls-open';
    var FORCES_VALUES_KEY = 'platform-kg-physics-v1';

    function loadForcesOpen() {
        try {
            return window.localStorage.getItem(FORCES_OPEN_KEY) === '1';
        } catch (err) {
            return false;
        }
    }

    function saveForcesOpen(open) {
        try {
            window.localStorage.setItem(FORCES_OPEN_KEY, open ? '1' : '0');
        } catch (err) {}
    }

    function loadForceValues() {
        try {
            var raw = window.localStorage.getItem(FORCES_VALUES_KEY);
            return raw ? JSON.parse(raw) : null;
        } catch (err) {
            return null;
        }
    }

    function saveForceValues() {
        try {
            window.localStorage.setItem(FORCES_VALUES_KEY, JSON.stringify({
                repulsion: REPULSION, spring: SPRING, springLength: SPRING_LENGTH, centerPull: CENTER_PULL, tagPull: TAG_PULL
            }));
        } catch (err) {}
    }

    function updateForceLabels() {
        document.getElementById('platform-kg-repel-val').textContent = REPULSION;
        document.getElementById('platform-kg-link-force-val').textContent = SPRING;
        document.getElementById('platform-kg-link-distance-val').textContent = SPRING_LENGTH;
        document.getElementById('platform-kg-center-val').textContent = CENTER_PULL;
        document.getElementById('platform-kg-tag-force-val').textContent = TAG_PULL;
    }

    function applyForceValuesToInputs() {
        repelInput.value = REPULSION;
        linkForceInput.value = SPRING;
        linkDistanceInput.value = SPRING_LENGTH;
        centerInput.value = CENTER_PULL;
        tagForceInput.value = TAG_PULL;
        updateForceLabels();
    }

    var savedForces = loadForceValues();
    if (savedForces) {
        if (typeof savedForces.repulsion === 'number') { REPULSION = savedForces.repulsion; }
        if (typeof savedForces.spring === 'number') { SPRING = savedForces.spring; }
        if (typeof savedForces.springLength === 'number') { SPRING_LENGTH = savedForces.springLength; }
        if (typeof savedForces.centerPull === 'number') { CENTER_PULL = savedForces.centerPull; }
        if (typeof savedForces.tagPull === 'number') { TAG_PULL = savedForces.tagPull; }
    }
    applyForceValuesToInputs();

    if (loadForcesOpen()) {
        forcesPanel.classList.add('platform-kg-forces-open');
        forcesToggle.classList.add('platform-kg-forces-toggle-active');
    }

    forcesToggle.addEventListener('click', function() {
        var open = forcesPanel.classList.toggle('platform-kg-forces-open');
        forcesToggle.classList.toggle('platform-kg-forces-toggle-active', open);
        saveForcesOpen(open);
    });

    repelInput.addEventListener('input', function() {
        REPULSION = parseFloat(repelInput.value);
        updateForceLabels();
        saveForceValues();
        wakeSimulation();
    });
    linkForceInput.addEventListener('input', function() {
        SPRING = parseFloat(linkForceInput.value);
        updateForceLabels();
        saveForceValues();
        wakeSimulation();
    });
    linkDistanceInput.addEventListener('input', function() {
        SPRING_LENGTH = parseFloat(linkDistanceInput.value);
        updateForceLabels();
        saveForceValues();
        wakeSimulation();
    });
    centerInput.addEventListener('input', function() {
        CENTER_PULL = parseFloat(centerInput.value);
        updateForceLabels();
        saveForceValues();
        wakeSimulation();
    });
    tagForceInput.addEventListener('input', function() {
        TAG_PULL = parseFloat(tagForceInput.value);
        updateForceLabels();
        saveForceValues();
        wakeSimulation();
    });
    forcesResetBtn.addEventListener('click', function() {
        REPULSION = FORCE_DEFAULTS.repulsion;
        SPRING = FORCE_DEFAULTS.spring;
        SPRING_LENGTH = FORCE_DEFAULTS.springLength;
        CENTER_PULL = FORCE_DEFAULTS.centerPull;
        TAG_PULL = FORCE_DEFAULTS.tagPull;
        applyForceValuesToInputs();
        try {
            window.localStorage.removeItem(FORCES_VALUES_KEY);
        } catch (err) {}
        wakeSimulation();
    });

    // Two-pass position separation plus closing-velocity cancellation so tight springs still settle below SLEEP_ENERGY.
    function resolveCollisions() {
        for (var pass = 0; pass < 2; pass++) {
            for (var i = 0; i < simNodes.length; i++) {
                for (var j = i + 1; j < simNodes.length; j++) {
                    var a = simNodes[i], b = simNodes[j];
                    if (a.fixed && b.fixed) { continue; }
                    var dx = a.x - b.x, dy = a.y - b.y;
                    var dist = Math.sqrt(dx * dx + dy * dy) || 0.01;
                    var minDist = nodeRadius(a.heat) + nodeRadius(b.heat) + COLLISION_PADDING;
                    if (dist >= minDist) { continue; }
                    var overlap = minDist - dist;
                    var nx = dx / dist, ny = dy / dist;
                    var aMove = a.fixed ? 0 : (b.fixed ? 1 : 0.5);
                    var bMove = b.fixed ? 0 : (a.fixed ? 1 : 0.5);
                    a.x += nx * overlap * aMove;
                    a.y += ny * overlap * aMove;
                    b.x -= nx * overlap * bMove;
                    b.y -= ny * overlap * bMove;
                    if (!a.fixed) {
                        var avn = a.vx * nx + a.vy * ny;
                        if (avn < 0) { a.vx -= avn * nx; a.vy -= avn * ny; }
                    }
                    if (!b.fixed) {
                        var bvn = b.vx * nx + b.vy * ny;
                        if (bvn > 0) { b.vx -= bvn * nx; b.vy -= bvn * ny; }
                    }
                }
            }
        }
    }

    function groupTags(n) {
        var list = (n.groups && n.groups.length) ? n.groups : n.tags;
        return list || [];
    }

    function tagCentres() {
        var centres = {};
        simNodes.forEach(function(n) {
            groupTags(n).forEach(function(tag) {
                var c = centres[tag] || (centres[tag] = { x: 0, y: 0, count: 0 });
                c.x += n.x; c.y += n.y; c.count++;
            });
        });
        Object.keys(centres).forEach(function(tag) {
            var c = centres[tag];
            c.x /= c.count; c.y /= c.count;
        });
        return centres;
    }

    function simStep(w, h, alpha) {
        var aScale = (typeof alpha === 'number') ? alpha : 1.0;
        for (var i = 0; i < simNodes.length; i++) {
            for (var j = i + 1; j < simNodes.length; j++) {
                var a = simNodes[i], b = simNodes[j];
                var dx = a.x - b.x, dy = a.y - b.y;
                var distSq = (dx * dx + dy * dy) || 0.01;
                var dist = Math.sqrt(distSq);
                var force = (REPULSION / distSq) * aScale;
                var fx = (dx / dist) * force, fy = (dy / dist) * force;
                if (!a.fixed) { a.vx += fx; a.vy += fy; }
                if (!b.fixed) { b.vx -= fx; b.vy -= fy; }
            }
        }
        links.forEach(function(e) {
            var a = byId[e.from], b = byId[e.to];
            if (!a || !b) { return; }
            var strength = (typeof e.strength === 'number') ? e.strength : 1.0;
            var pull = Math.min(SPRING_STRENGTH_CAP, Math.max(0.2, strength));
            var dx = b.x - a.x, dy = b.y - a.y;
            var dist = Math.sqrt(dx * dx + dy * dy) || 0.01;
            var force = (dist - SPRING_LENGTH) * SPRING * pull * aScale;
            var fx = (dx / dist) * force, fy = (dy / dist) * force;
            if (!a.fixed) { a.vx += fx; a.vy += fy; }
            if (!b.fixed) { b.vx -= fx; b.vy -= fy; }
        });
        if (TAG_PULL > 0) {
            var centres = tagCentres();
            simNodes.forEach(function(n) {
                if (n.fixed) { return; }
                var tags = groupTags(n).filter(function(tag) { return centres[tag].count > 1; });
                tags.forEach(function(tag) {
                    var c = centres[tag];
                    n.vx += (c.x - n.x) * TAG_PULL * aScale / tags.length;
                    n.vy += (c.y - n.y) * TAG_PULL * aScale / tags.length;
                });
            });
        }
        simNodes.forEach(function(n) {
            if (n.fixed) { n.vx = 0; n.vy = 0; return; }
            var centerBoost = 1 + CENTER_CONNECTIVITY_GAIN * Math.log(1 + (n.connWeight || 0));
            n.vx += (w / 2 - n.x) * CENTER_PULL * centerBoost * aScale;
            n.vy += (h / 2 - n.y) * CENTER_PULL * centerBoost * aScale;
            n.vx *= DAMPING;
            n.vy *= DAMPING;
            n.vx = Math.max(-MAX_SPEED, Math.min(MAX_SPEED, n.vx));
            n.vy = Math.max(-MAX_SPEED, Math.min(MAX_SPEED, n.vy));
            n.x += n.vx;
            n.y += n.vy;
        });
        resolveCollisions();
        var energy = 0;
        simNodes.forEach(function(n) {
            energy += n.vx * n.vx + n.vy * n.vy;
        });
        return energy;
    }

    // Deterministic heat/tier/tag/id grid below the linked cluster; preserves manually dragged orphans.
    function orphanOrder(a, b) {
        var ta = groupTags(a)[0], tb = groupTags(b)[0];
        return ((b.heat || 0) - (a.heat || 0)) ||
            ((b.tier || 0) - (a.tier || 0)) ||
            ((ta === undefined) - (tb === undefined)) ||
            (ta && tb ? ta.localeCompare(tb) : 0) ||
            (a.id - b.id);
    }

    function placeOrphans() {
        var grid = orphans.filter(function(n) { return !n.manual; });
        if (grid.length === 0) { return; }
        var minX = Infinity, maxX = -Infinity, maxY = -Infinity;
        simNodes.forEach(function(n) {
            minX = Math.min(minX, n.x); maxX = Math.max(maxX, n.x); maxY = Math.max(maxY, n.y);
        });
        if (simNodes.length === 0) { minX = 0; maxX = canvas.width; maxY = 0; }
        var cell = 2 * nodeRadius(Math.max.apply(null, grid.map(function(n) { return n.heat || 0; }))) + COLLISION_PADDING;
        var cols = Math.ceil(Math.sqrt(grid.length));
        var left = (minX + maxX) / 2 - (cols - 1) * cell / 2;
        var top = maxY + 4 * cell;
        grid.sort(orphanOrder);
        grid.forEach(function(n, i) {
            n.x = left + (i % cols) * cell;
            n.y = top + Math.floor(i / cols) * cell;
            n.vx = 0;
            n.vy = 0;
        });
    }

    // Alpha decay guarantees sleep convergence on dense clusters; held at 1.0 during active drag.
    var simAlpha = 1.0;
    var simFrames = 0;
    var ALPHA_DECAY = 0.982;
    var MIN_SIM_ALPHA = 0.02;
    var MAX_SIM_FRAMES = 240;

    function simLoop() {
        if (dragNode != null) {
            simAlpha = 1.0;
            simFrames = 0;
        } else {
            simFrames += 1;
            simAlpha *= ALPHA_DECAY;
        }
        var energy = simStep(canvas.width, canvas.height, simAlpha);
        draw();
        var avgEnergy = simNodes.length > 0 ? energy / simNodes.length : 0;
        if (dragNode != null || (avgEnergy > SLEEP_ENERGY && simAlpha >= MIN_SIM_ALPHA && simFrames < MAX_SIM_FRAMES)) {
            if (simFrames > 0 && (simFrames % 30) === 0) {
                saveCachedLayout();
            }
            requestAnimationFrame(simLoop);
        } else {
            simRunning = false;
            placeOrphans();
            draw();
            saveCachedLayout();
        }
    }

    function wakeSimulation(initialAlpha) {
        simAlpha = (typeof initialAlpha === 'number') ? initialAlpha : 1.0;
        simFrames = 0;
        if (!simRunning) {
            simRunning = true;
            requestAnimationFrame(simLoop);
        }
    }

    // Cache only simNodes and manually dragged orphans; exact graphSig hit skips initial physics settle.
    var LAYOUT_CACHE_KEY = 'platform-kg-layout-v2';
    var LEGACY_LAYOUT_CACHE_KEY = 'platform-kg-layout-v1';

    function graphTopologySignature() {
        var nodeIds = simNodes.map(function(n) { return n.id; }).sort(function(a, b) { return a - b; });
        var edgeKeys = links.map(function(e) { return e.from + '>' + e.to; }).sort();
        var forceKey = [REPULSION, SPRING, SPRING_LENGTH, CENTER_PULL, TAG_PULL].join('|');
        return 'v2|' + forceKey + '|N:' + nodeIds.join(',') + '|E:' + edgeKeys.join(',');
    }

    function loadCachedLayout() {
        try {
            var raw = window.localStorage.getItem(LAYOUT_CACHE_KEY);
            if (!raw) { return null; }
            var parsed = JSON.parse(raw);
            if (!parsed || parsed.v !== 2 || typeof parsed.positions !== 'object' || parsed.positions === null) {
                return null;
            }
            return parsed;
        } catch (err) {
            return null;
        }
    }

    function roundCoord(v) {
        return Math.round(v * 100) / 100;
    }

    function saveCachedLayout() {
        if (nodes.length === 0) { return; }
        try {
            var positions = {};
            simNodes.forEach(function(n) {
                if (typeof n.x === 'number' && typeof n.y === 'number') {
                    positions[n.id] = { x: roundCoord(n.x), y: roundCoord(n.y) };
                }
            });
            var manualOrphans = {};
            orphans.forEach(function(n) {
                if (n.manual && typeof n.x === 'number' && typeof n.y === 'number') {
                    manualOrphans[n.id] = { x: roundCoord(n.x), y: roundCoord(n.y) };
                }
            });
            window.localStorage.setItem(LAYOUT_CACHE_KEY, JSON.stringify({
                v: 2,
                graphSig: graphTopologySignature(),
                positions: positions,
                manualOrphans: manualOrphans
            }));
            window.localStorage.removeItem(LEGACY_LAYOUT_CACHE_KEY);
        } catch (err) {}
    }

    window.addEventListener('pagehide', function() {
        if (simRunning) { saveCachedLayout(); }
    });

    function layout() {
        var w = canvas.width, h = canvas.height;
        var cached = loadCachedLayout();
        var cachedPositions = cached ? cached.positions : null;
        var cachedManual = (cached && cached.manualOrphans) ? cached.manualOrphans : null;
        var currentSig = graphTopologySignature();
        var neighborsOf = {};
        links.forEach(function(e) {
            if (!neighborsOf[e.from]) { neighborsOf[e.from] = []; }
            if (!neighborsOf[e.to]) { neighborsOf[e.to] = []; }
            neighborsOf[e.from].push(e.to);
            neighborsOf[e.to].push(e.from);
        });
        orphans.forEach(function(n) {
            var mp = cachedManual ? cachedManual[n.id] : null;
            if (mp && typeof mp.x === 'number' && typeof mp.y === 'number') {
                n.x = mp.x;
                n.y = mp.y;
                n.manual = true;
            }
            n.vx = 0;
            n.vy = 0;
            n.fixed = false;
        });
        var uncachedCount = 0;
        simNodes.forEach(function(n) {
            var pos = cachedPositions ? cachedPositions[n.id] : null;
            if (pos && typeof pos.x === 'number' && typeof pos.y === 'number') {
                n.x = pos.x;
                n.y = pos.y;
            } else {
                uncachedCount++;
                // Spawn newly linked nodes near cached neighbors.
                var neighborIds = neighborsOf[n.id] || [];
                var sumX = 0, sumY = 0, count = 0;
                neighborIds.forEach(function(nid) {
                    var np = cachedPositions ? cachedPositions[nid] : null;
                    if (np && typeof np.x === 'number' && typeof np.y === 'number') {
                        sumX += np.x; sumY += np.y; count++;
                    }
                });
                if (count > 0) {
                    n.x = (sumX / count) + (Math.random() - 0.5) * 40;
                    n.y = (sumY / count) + (Math.random() - 0.5) * 40;
                } else {
                    n.x = Math.random() * w;
                    n.y = Math.random() * h;
                }
            }
            n.vx = 0;
            n.vy = 0;
            n.fixed = false;
        });
        if (cached != null && uncachedCount === 0 && cached.graphSig === currentSig) {
            placeOrphans();
            return;
        }
        var coldStart = (cached == null || uncachedCount > Math.max(1, simNodes.length / 2));
        var settleIterations = coldStart ? 120 : 24;
        var settleUntil = Date.now() + (coldStart ? 400 : 160);
        for (var iter = 0; iter < settleIterations && Date.now() < settleUntil; iter++) {
            simStep(w, h, 1.0);
        }
        placeOrphans();
        saveCachedLayout();
        wakeSimulation(coldStart ? 1.0 : 0.65);
    }

    fetch('api/v1/knowledge/graph').then(function(r) {
        if (!r.ok) { throw new Error('status ' + r.status); }
        return r.json();
    }).then(function(data) {
        nodes = data.nodes || [];
        byId = {};
        nodes.forEach(function(n) { byId[n.id] = n; n.connWeight = 0; n.degree = 0; });
        links = (data.edges || []).filter(function(e) { return byId[e.from] && byId[e.to]; });
        links.forEach(function(e) {
            var strength = (typeof e.strength === 'number') ? e.strength : 1.0;
            byId[e.from].connWeight += strength;
            byId[e.to].connWeight += strength;
            byId[e.from].degree += 1;
            byId[e.to].degree += 1;
        });
        simNodes = nodes.filter(function(n) { return n.degree > 0; });
        var nested = nodes.some(function(n) {
            return n.groups && n.tags && n.groups.join('\n') !== n.tags.join('\n');
        });
        if (!nested) {
            var subOption = colorBy.querySelector('option[value="subtag"]');
            if (subOption) { subOption.remove(); }
            if (view.colorBy === 'subtag') { view.colorBy = 'tag'; colorBy.value = 'tag'; }
        }
        orphans = nodes.filter(function(n) { return n.degree === 0; });
        buildLegend();
        if (nodes.length === 0) {
            status.textContent = 'No documents in the pool yet.';
            return;
        }
        status.style.display = 'none';
        layout();
        draw();
    }).catch(function(err) {
        status.textContent = 'Failed to load graph data.';
    });
})();
