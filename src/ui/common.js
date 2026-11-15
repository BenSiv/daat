window.PlatformJS = (function(){
    function getCsrfToken() {
        var match = document.cookie.match(/(?:^|;\s*)csrf=([^;]*)/);
        return match ? match[1] : "";
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function fetchJSON(url) {
        return fetch(url).then(function(res){ return res.json(); });
    }

    function postJSON(url, body) {
        return fetch(url, {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken()},
            body: JSON.stringify(body)
        }).then(function(res){ return res.json(); });
    }

    function debounce(fn, waitMs) {
        var timer;
        return function() {
            var args = arguments, ctx = this;
            clearTimeout(timer);
            timer = setTimeout(function(){ fn.apply(ctx, args); }, waitMs);
        };
    }

    // triggerEl: the element a click ON does not count as "outside".
    // getContainer(): returns the currently-open results element, or
    // null/undefined if none is open right now.
    function onOutsideClick(triggerEl, getContainer, closeFn) {
        document.addEventListener('click', function(e){
            var container = getContainer();
            if (e.target !== triggerEl && container && !container.contains(e.target)) {
                closeFn();
            }
        });
    }

    function showStatus(el, msg, isError) {
        el.textContent = msg;
        el.className = isError ? 'platform-status-error' : 'platform-status-ok';
    }

    function clearCellError(input) {
        input.classList.remove('error');
        var badge = input.parentElement.querySelector('.error-badge');
        if (badge) badge.remove();
    }

    function highlightError(input, message) {
        input.classList.add('error');
        var parent = input.parentElement;
        var badge = parent.querySelector('.error-badge');
        if (!badge) {
            badge = document.createElement('span');
            badge.classList.add('error-badge');
            parent.appendChild(badge);
        }
        badge.innerText = message;
    }

    function clearAllErrors(scopeEl, statusEl) {
        scopeEl.querySelectorAll('.cell-input').forEach(clearCellError);
        if (statusEl) {
            statusEl.className = 'status-msg';
            statusEl.innerText = '';
            statusEl.style.display = 'none';
        }
    }

    // Reference-field autocomplete: debounced search, a transient results
    // dropdown, pick via mousedown+preventDefault+refocus (avoids the
    // blur race a plain click/onclick handler has), and clearCellError on
    // pick. Previously two near-identical hand copies (register's batch
    // table and the single-row edit form) that had silently drifted:
    // edit's showed the literal text "undefined" for every suggestion
    // (it read item.label, but /api/autocomplete only ever returns
    // {id, name}) and never cleared a prior error-highlight on pick.
    // Both are fixed here by construction, not by choice -- there's only
    // one implementation now.
    function setupAutocomplete(input, refType, multi, baseUrl) {
        // input.parentElement is read fresh at render time, not captured
        // here -- setupAutocomplete is always called before its caller
        // appends `input` into the DOM (both addRow() and buildFields()
        // build the whole cell before attaching it), so a captured
        // `const wrapper = input.parentElement` would be null forever.
        var resultsContainer = null;
        function closeResults() {
            if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
        }
        var doSearch = debounce(function(query) {
            fetchJSON(baseUrl + '/api/autocomplete?type=' + refType + '&query=' + encodeURIComponent(query))
                .then(function(data) {
                    closeResults();
                    if (!data || data.length === 0) return;
                    resultsContainer = document.createElement('div');
                    resultsContainer.className = 'autocomplete-results';
                    data.forEach(function(item) {
                        var opt = document.createElement('div');
                        opt.innerText = '[#' + item.id + '] ' + item.name;
                        opt.addEventListener('mousedown', function(e) {
                            e.preventDefault();
                            if (multi) {
                                var existing = input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length > 0; });
                                existing.pop();
                                if (existing.indexOf(String(item.id)) === -1) { existing.push(String(item.id)); }
                                input.value = existing.join(', ') + ', ';
                            } else {
                                input.value = item.id;
                            }
                            clearCellError(input);
                            closeResults();
                            input.focus();
                        });
                        resultsContainer.appendChild(opt);
                    });
                    input.parentElement.appendChild(resultsContainer);
                })
                .catch(function(err) { console.error('Autocomplete fetch error', err); });
        }, 200);
        input.addEventListener('input', function() {
            var raw = input.value;
            var query = (multi ? raw.split(',').pop() : raw).trim();
            closeResults();
            if (query.length === 0) return;
            doSearch(query);
        });
        onOutsideClick(input, function(){ return resultsContainer; }, closeResults);
    }

    // Same search/pick UX as setupAutocomplete, but the target type
    // comes from typeSelect's own current value at query/pick time
    // (re-read live, not captured once) since a polymorphic field's
    // target type is chosen by the user, not declared by the schema.
    // Inserts "type:id", not a bare id, so the submitted value
    // round-trips through schema.normalize_polymorphic_value the same
    // way a hand-typed one would.
    function setupPolymorphicAutocomplete(input, typeSelect, multi, baseUrl) {
        // See setupAutocomplete's own comment: input.parentElement must
        // be read fresh at render time, not captured at setup time.
        var resultsContainer = null;
        function closeResults() {
            if (resultsContainer) { resultsContainer.remove(); resultsContainer = null; }
        }
        var doSearch = debounce(function(query) {
            var refType = typeSelect.value;
            fetchJSON(baseUrl + '/api/autocomplete?type=' + refType + '&query=' + encodeURIComponent(query))
                .then(function(data) {
                    closeResults();
                    if (!data || data.length === 0) return;
                    resultsContainer = document.createElement('div');
                    resultsContainer.className = 'autocomplete-results';
                    data.forEach(function(item) {
                        var opt = document.createElement('div');
                        opt.innerText = '[' + refType + ' #' + item.id + '] ' + item.name;
                        opt.addEventListener('mousedown', function(e) {
                            e.preventDefault();
                            var entry = refType + ':' + item.id;
                            if (multi) {
                                var existing = input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length > 0; });
                                existing.pop();
                                if (existing.indexOf(entry) === -1) { existing.push(entry); }
                                input.value = existing.join(', ') + ', ';
                            } else {
                                input.value = entry;
                            }
                            clearCellError(input);
                            closeResults();
                            input.focus();
                        });
                        resultsContainer.appendChild(opt);
                    });
                    input.parentElement.appendChild(resultsContainer);
                })
                .catch(function(err) { console.error('Autocomplete fetch error', err); });
        }, 200);
        input.addEventListener('input', function() {
            var raw = input.value;
            var query = (multi ? raw.split(',').pop() : raw).trim();
            closeResults();
            if (query.length === 0) return;
            doSearch(query);
        });
        onOutsideClick(input, function(){ return resultsContainer; }, closeResults);
    }

    // Builds one field's input control, appending it (and, for a
    // polymorphic field, its type-picker <select> too) into `container`
    // -- the caller's own per-field wrapper div. Previously two ~120-line
    // near-duplicate switches (register's addRow() and the single-row
    // edit form's buildFields()); the only real difference between the
    // two pages was whether a field has an existing value to prefill
    // (opts.value) -- register's blank rows simply never pass one.
    // opts.locked (register-only) short-circuits everything
    // else for a `?lock_<field>=<value>` field.
    function buildFieldInput(field, container, opts) {
        opts = opts || {};
        var current = opts.value;
        var input;

        if (opts.locked !== undefined) {
            var display = document.createElement('span');
            display.className = 'cell-locked-value';
            display.innerText = opts.locked.label;
            container.appendChild(display);
            var hidden = document.createElement('input');
            hidden.type = 'hidden';
            hidden.name = field.name;
            hidden.value = opts.locked.value;
            container.appendChild(hidden);
            return hidden;
        }

        if (field.type === 'select') {
            input = document.createElement('select');
            input.classList.add('cell-input');
            var optEmpty = document.createElement('option');
            optEmpty.value = ''; optEmpty.innerText = '';
            input.appendChild(optEmpty);
            field.values.forEach(function(val) {
                var opt = document.createElement('option');
                opt.value = val; opt.innerText = val;
                if (current === val) { opt.selected = true; }
                input.appendChild(opt);
            });
        } else if (field.type === 'multi_select') {
            input = document.createElement('select');
            input.classList.add('cell-input');
            input.multiple = true;
            var currentList = Array.isArray(current) ? current : [];
            field.values.forEach(function(val) {
                var opt = document.createElement('option');
                opt.value = val; opt.innerText = val;
                if (currentList.indexOf(val) !== -1) { opt.selected = true; }
                input.appendChild(opt);
            });
        } else if (field.type === 'polymorphic_reference' || field.type === 'multi_polymorphic_reference') {
            var multiPoly = field.type === 'multi_polymorphic_reference';
            var typeSelect = document.createElement('select');
            typeSelect.classList.add('cell-input', 'cell-source-type');
            (field.allowed_entity_types || []).forEach(function(t) {
                var opt = document.createElement('option');
                opt.value = t; opt.innerText = t;
                typeSelect.appendChild(opt);
            });
            container.appendChild(typeSelect);

            input = document.createElement('input');
            input.classList.add('cell-input');
            input.type = 'text';
            input.setAttribute('autocomplete', 'off');
            input.placeholder = multiPoly ? 'Search ID or name, pick several...' : 'Search ID or name...';
            var currentPoly = Array.isArray(current) ? current : [];
            if (currentPoly.length > 0) {
                input.value = currentPoly.map(function(v){ return v.type + ':' + v.id; }).join(', ') + ', ';
            }
            setupPolymorphicAutocomplete(input, typeSelect, multiPoly, opts.baseUrl);
        } else {
            input = document.createElement('input');
            input.classList.add('cell-input');
            if (field.type === 'number') {
                input.type = 'number'; input.step = 'any';
                if (field.min !== undefined && field.min !== null) { input.min = field.min; }
                if (field.max !== undefined && field.max !== null) { input.max = field.max; }
                if (current !== undefined && current !== null) { input.value = current; }
            } else if (field.type === 'date') {
                input.type = 'date';
                if (current) { input.value = current; }
            } else if (field.type === 'multi_reference') {
                input.type = 'text';
                input.setAttribute('autocomplete', 'off');
                input.placeholder = 'Search ID or name, pick several...';
                var currentRefs = Array.isArray(current) ? current : [];
                if (currentRefs.length > 0) { input.value = currentRefs.join(', ') + ', '; }
                setupAutocomplete(input, field.ref_entity_type, true, opts.baseUrl);
            } else {
                input.type = 'text';
                if (current !== undefined && current !== null) { input.value = current; }
                if (field.type === 'reference') {
                    input.setAttribute('autocomplete', 'off');
                    input.placeholder = 'Search ID or name...';
                    setupAutocomplete(input, field.ref_entity_type, false, opts.baseUrl);
                }
            }
        }

        input.name = field.name;
        input.addEventListener('input', function(){ clearCellError(input); });
        input.addEventListener('change', function(){ clearCellError(input); });
        container.appendChild(input);
        return input;
    }

    return {
        getCsrfToken: getCsrfToken, escapeHtml: escapeHtml,
        fetchJSON: fetchJSON, postJSON: postJSON,
        debounce: debounce, onOutsideClick: onOutsideClick,
        showStatus: showStatus,
        clearCellError: clearCellError, highlightError: highlightError, clearAllErrors: clearAllErrors,
        setupAutocomplete: setupAutocomplete, setupPolymorphicAutocomplete: setupPolymorphicAutocomplete,
        buildFieldInput: buildFieldInput
    };
})();
