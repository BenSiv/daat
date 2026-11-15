(function(){
    // Starts in 'markdown' mode -- the familiar plain-text +
    // toolbar experience -- with 'wysiwyg' (syntax hidden, edit
    // the rendered view directly) one click away via the
    // editor's own built-in mode tab, not a separate feature to
    // build. getMarkdown() on submit keeps document-save's
    // contract (a plain markdown `content` field) unchanged --
    // schema.lua/document.lua/cmark downstream never know the
    // editor changed.
    var editor = new toastui.Editor({
        el: document.querySelector('#platform-toastui-editor'),
        height: '460px',
        initialEditType: 'markdown',
        previewStyle: 'vertical',
        // Toast UI reports each page load to Google Analytics
        // unless told not to -- the deployment's hostname and page
        // URLs would leave for a third party. The CSP's connect-src
        // blocks it too; this stops it being attempted at all.
        usageStatistics: false,
        initialValue: JSON.parse(document.getElementById('platform-document-edit-boot').textContent).initial_value,
        placeholder: 'Write in Markdown. Type [[ to link another document, or @ to reference an entity.',
        // WYSIWYG mode has no built-in notion of this project's own
        // "[[title]]" link syntax -- without a widget rule it shows
        // as inert literal text. This only styles it as recognized
        // syntax while editing; resolved-vs-dangling status is still
        // computed server-side (document.render_html), same as
        // before -- getMarkdown() on submit is untouched either way.
        widgetRules: [{
            rule: /\[\[([^\]]+)\]\]/,
            toDOM: function(text) {
                var matched = text.match(/\[\[([^\]]+)\]\]/);
                var span = document.createElement('span');
                span.className = 'platform-wikilink';
                span.textContent = '[[' + matched[1] + ']]';
                return span;
            }
        }]
    });
    var form = document.getElementById('platform-document-edit-form');
    var hiddenContent = document.getElementById('platform-document-content-hidden');
    var currentDocId = form.elements['entity_id'] ? form.elements['entity_id'].value : '';
    form.addEventListener('submit', function(){
        // ToastUI v3's Markdown mode unwraps `widgetRules` nodes in
        // getMarkdown(), whereas its WYSIWYG convertor leaves
        // `$$widget0 [[...]]$$` intact -- strip the wrapper here so
        // saving from either tab writes plain `[[...]]` Markdown.
        hiddenContent.value = editor.getMarkdown().replace(/\$\$widget\d+\s(\[\[[^\[\]\n]+\]\])\$\$/g, '$1');
    });

    // One shared inline link picker for both grammars in a document:
    //   1. `[[` searches active documents (/api/document-search ->
    //      document.search_for_link) and inserts `item.link_ref`
    //      (`[[title]]` or `[[folder/title]]`), so saved content
    //      keeps human titles rather than internal ids.
    //   2. `@` searches entities across types (/api/entity-search ->
    //      entity.search_across_types, including `identifier = true`
    //      fields) and inserts `[label](detail?type=...&entity_id=...)`
    //      so document.sync_links' [[...]] regex never turns an
    //      entity mention into a document_link edge.
    //
    // ToastUI v3's Markdown-mode selection coordinates are 1-based
    // (`[1, 1]` is line 1, col 1), so reading the current line via
    // `editor.getSelectedText([line, 1], [line, ch])` avoids both
    // the 0-vs-1 line offset bug and re-serializing the whole
    // document on every keystroke; WYSIWYG mode uses numeric
    // ProseMirror offsets (`[from, to]`).
    var mentionWrap = document.querySelector('.platform-mention-wrap');
    var mentionResults = document.getElementById('platform-mention-results');
    var mentionState = null;
    var activeIndex = -1;
    var requestSeq = 0;

    function closeMentions() {
        mentionState = null;
        activeIndex = -1;
        requestSeq++;
        mentionResults.classList.remove('platform-mention-open');
        mentionResults.innerHTML = '';
    }

    function positionPopover() {
        var topPx = 40, leftPx = 8;
        var domSel = window.getSelection ? window.getSelection() : null;
        if (domSel && domSel.rangeCount > 0 && mentionWrap) {
            var range = domSel.getRangeAt(0);
            if (mentionWrap.contains(range.startContainer)) {
                var rect = range.getBoundingClientRect();
                var wrapRect = mentionWrap.getBoundingClientRect();
                if (rect && (rect.height > 0 || rect.top > 0)) {
                    topPx = Math.max(36, Math.round(rect.bottom - wrapRect.top + 6));
                    leftPx = Math.max(8, Math.min(Math.round(rect.left - wrapRect.left), Math.max(8, Math.round(wrapRect.width - 320))));
                }
            }
        }
        mentionResults.style.top = topPx + 'px';
        mentionResults.style.left = leftPx + 'px';
    }

    function setActiveItem(nextIdx) {
        var nodes = mentionResults.querySelectorAll('.platform-mention-item');
        if (nodes.length === 0) { activeIndex = -1; return; }
        if (nextIdx < 0) { nextIdx = nodes.length - 1; }
        if (nextIdx >= nodes.length) { nextIdx = 0; }
        activeIndex = nextIdx;
        for (var i = 0; i < nodes.length; i++) {
            nodes[i].classList.toggle('platform-mention-active', i === activeIndex);
        }
        if (nodes[activeIndex] && nodes[activeIndex].scrollIntoView) {
            nodes[activeIndex].scrollIntoView({block: 'nearest'});
        }
    }

    function renderDocumentItems(items, seq) {
        if (!mentionState || mentionState.kind !== 'document' || seq !== requestSeq) { return; }
        activeIndex = -1;
        if (items.length === 0) {
            mentionResults.innerHTML = '<div class="platform-mention-empty">No matching documents.</div>';
        } else {
            mentionResults.innerHTML = items.map(function(item){
                var badge = item.parent_title ? PlatformJS.escapeHtml(item.parent_title) : 'document';
                return '<div class="platform-mention-item" data-kind="document" data-ref="' + PlatformJS.escapeHtml(item.link_ref) + '">' +
                    '<span>' + PlatformJS.escapeHtml(item.title) + '</span>' +
                    '<span class="platform-mention-type">' + badge + '</span></div>';
            }).join('');
        }
        positionPopover();
        mentionResults.classList.add('platform-mention-open');
    }

    function renderEntityItems(items, seq) {
        if (!mentionState || mentionState.kind !== 'entity' || seq !== requestSeq) { return; }
        activeIndex = -1;
        if (items.length === 0) {
            mentionResults.innerHTML = '<div class="platform-mention-empty">No matching entities.</div>';
        } else {
            mentionResults.innerHTML = items.map(function(item){
                var sub = item.subtitle ? '<span class="platform-mention-sub">&middot; ' + PlatformJS.escapeHtml(item.subtitle) + '</span>' : '';
                return '<div class="platform-mention-item" data-kind="entity" data-label="' + PlatformJS.escapeHtml(item.label) +
                    '" data-type="' + PlatformJS.escapeHtml(item.entity_type) + '" data-id="' + item.id + '">' +
                    '<span>' + PlatformJS.escapeHtml(item.label) + sub + '</span>' +
                    '<span class="platform-mention-type">' + PlatformJS.escapeHtml(item.entity_type) + '</span></div>';
            }).join('');
        }
        positionPopover();
        mentionResults.classList.add('platform-mention-open');
    }

    var searchDocuments = PlatformJS.debounce(function(query, seq){
        var url = 'api/document-search?query=' + encodeURIComponent(query);
        if (currentDocId) { url += '&exclude_id=' + encodeURIComponent(currentDocId); }
        PlatformJS.fetchJSON(url).then(function(items){ renderDocumentItems(items, seq); });
    }, 150);

    var searchEntities = PlatformJS.debounce(function(query, seq){
        PlatformJS.fetchJSON('api/entity-search?query=' + encodeURIComponent(query)).then(function(items){ renderEntityItems(items, seq); });
    }, 200);

    function safeSelectedText(startPos, endPos) {
        try { return editor.getSelectedText(startPos, endPos) || ''; } catch (_) { return ''; }
    }

    function getCursorLineContext() {
        var sel = editor.getSelection();
        if (!sel || sel.length < 2) { return null; }
        if (editor.isMarkdownMode && editor.isMarkdownMode()) {
            if (!Array.isArray(sel[0]) || !Array.isArray(sel[1])) { return null; }
            if (sel[0][0] !== sel[1][0] || sel[0][1] !== sel[1][1]) { return null; }
            var line = sel[1][0], ch = sel[1][1];
            return {
                mode: 'markdown',
                line: line,
                ch: ch,
                before: safeSelectedText([line, 1], [line, ch]),
                afterTwo: safeSelectedText([line, ch], [line, ch + 2])
            };
        }
        if (typeof sel[0] === 'number' && typeof sel[1] === 'number' && sel[0] === sel[1]) {
            var pos = sel[1];
            var chunk = safeSelectedText(Math.max(1, pos - 200), pos);
            var parts = chunk.split('\n');
            return {
                mode: 'wysiwyg',
                pos: pos,
                before: parts[parts.length - 1] || '',
                afterTwo: safeSelectedText(pos, pos + 2)
            };
        }
        return null;
    }

    function applyMentionItem(itemEl) {
        if (!itemEl || !mentionState) { return; }
        var state = mentionState;
        var kind = itemEl.getAttribute('data-kind');
        if (kind === 'document') {
            var refText = itemEl.getAttribute('data-ref') || '';
            if (state.mode === 'markdown') {
                editor.replaceSelection(refText, [state.line, state.ch - state.tokenLen], [state.line, state.ch + state.closingLen]);
            } else {
                editor.replaceSelection(refText, state.pos - state.tokenLen, state.pos + state.closingLen);
            }
        } else if (kind === 'entity') {
            var label = itemEl.getAttribute('data-label') || '';
            var url = 'detail?type=' + itemEl.getAttribute('data-type') + '&entity_id=' + itemEl.getAttribute('data-id');
            if (state.mode === 'markdown') {
                editor.replaceSelection('[' + label + '](' + url + ')', [state.line, state.ch - state.tokenLen], [state.line, state.ch]);
            } else {
                editor.deleteSelection(state.pos - state.tokenLen, state.pos);
                editor.exec('addLink', {linkText: label, linkUrl: url});
            }
        }
        closeMentions();
    }

    editor.on('changeMode', closeMentions);
    editor.on('keyup', function(editorType, ev){
        if (ev && (ev.key === 'ArrowDown' || ev.key === 'ArrowUp' || ev.key === 'Enter' || ev.key === 'Escape')) {
            return;
        }
        var ctx = getCursorLineContext();
        if (!ctx) { closeMentions(); return; }

        // Open `[[...` without a closing bracket on this line: document link picker.
        var docMatch = ctx.before.match(/\[\[([^\[\]]*)$/);
        if (docMatch) {
            var docQuery = docMatch[1];
            var closingLen = ctx.afterTwo === ']]' ? 2 : 0;
            mentionState = {
                kind: 'document',
                mode: ctx.mode,
                line: ctx.line,
                ch: ctx.ch,
                pos: ctx.pos,
                tokenLen: docMatch[0].length,
                closingLen: closingLen
            };
            var seq = ++requestSeq;
            searchDocuments(docQuery, seq);
            return;
        }

        // `@query` at line start or after whitespace (never inside user@example.com): entity picker.
        var entMatch = ctx.before.match(/(^|\s)@([\w-]*)$/);
        if (entMatch) {
            var entQuery = entMatch[2];
            mentionState = {
                kind: 'entity',
                mode: ctx.mode,
                line: ctx.line,
                ch: ctx.ch,
                pos: ctx.pos,
                tokenLen: entQuery.length + 1,
                closingLen: 0
            };
            var entSeq = ++requestSeq;
            if (entQuery.length === 0) {
                activeIndex = -1;
                mentionResults.innerHTML = '<div class="platform-mention-empty">Type to search entities&hellip;</div>';
                positionPopover();
                mentionResults.classList.add('platform-mention-open');
                return;
            }
            searchEntities(entQuery, entSeq);
            return;
        }

        closeMentions();
    });

    mentionResults.addEventListener('mousedown', function(e){
        // mousedown, not click -- fires before the editor's own
        // blur/selection-change handling, so mentionState is still
        // the one captured on the keyup that opened this popover.
        var item = e.target.closest('.platform-mention-item');
        if (!item || !mentionState) { return; }
        e.preventDefault();
        applyMentionItem(item);
    });
    PlatformJS.onOutsideClick(null, function(){ return mentionState ? mentionResults : null; }, closeMentions);
    document.addEventListener('keydown', function(e){
        if (!mentionState || !mentionResults.classList.contains('platform-mention-open')) { return; }
        if (e.key === 'Escape') {
            e.preventDefault();
            closeMentions();
            return;
        }
        var items = mentionResults.querySelectorAll('.platform-mention-item');
        if (items.length === 0) { return; }
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            e.stopPropagation();
            setActiveItem(activeIndex + 1);
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            e.stopPropagation();
            setActiveItem(activeIndex <= 0 ? items.length - 1 : activeIndex - 1);
        } else if (e.key === 'Enter' && activeIndex >= 0 && items[activeIndex]) {
            e.preventDefault();
            e.stopPropagation();
            applyMentionItem(items[activeIndex]);
        }
    }, true);
})();
