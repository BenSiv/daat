(function(){
    var STORAGE_KEY = 'platform_chat_widget_session';
    var root = document.getElementById('platform-chat-widget');
    var toggle = document.getElementById('platform-chat-widget-toggle');
    var messagesEl = document.getElementById('platform-chat-widget-messages');
    var form = document.getElementById('platform-chat-widget-form');
    var input = document.getElementById('platform-chat-widget-text');
    var attachBtn = document.getElementById('platform-chat-widget-attach-btn');
    var fileInput = document.getElementById('platform-chat-widget-file');
    var attachmentEl = document.getElementById('platform-chat-widget-attachment');
    var readonlyEl = document.getElementById('platform-chat-widget-readonly');

    function describeCurrentPage() {
        var ctx = window.PLATFORM_PAGE_CONTEXT;
        if (!ctx) { return null; }
        var parts = [ctx.page_type || 'unknown'];
        if (ctx.title) { parts.push('"' + ctx.title + '"'); }
        if (ctx.entity_type && ctx.entity_id != null) {
            parts.push('(' + ctx.entity_type + ' id=' + ctx.entity_id + ')');
        } else if (ctx.view_name) {
            parts.push('(view=' + ctx.view_name + ')');
        }
        return parts.join(' ');
    }

    var ROLE_LABELS = {user: 'You', assistant: 'Assistant', tool_result: 'Tool result', compaction_summary: 'Compacted summary', self_check: 'Self-check', error: 'Error', progress: 'Progress', decision: 'Decision'};
    // Pre-rendered server-side via cmark-gfm (matches ui.CHAT_MARKDOWN_ROLES); insert raw.
    var MARKDOWN_ROLES = {assistant: true, self_check: true, compaction_summary: true, progress: true};
    function render(state) {
        var isReadOnly = !!(state && state.read_only);
        awaitingApproval = !isReadOnly && !!(state && state.pending);
        updateToggleState();
        if (!state || !state.messages || state.messages.length === 0) {
            messagesEl.innerHTML = '<p class="platform-chat-widget-empty">' +
                (isReadOnly ? 'No messages in this conversation.' : 'Ask something, or ask the assistant to search or create a document...') +
                '</p>';
        } else {
            var html = '';
            state.messages.forEach(function(msg){
                // Distinguishes the turn's final answer from intermediate assistant tool-call narration.
                var isFinal = msg.role === 'assistant' && msg.is_final === true;
                var userLabel = (isReadOnly && state.owner) ? state.owner : ROLE_LABELS.user;
                var label = isFinal ? 'Answer' : (msg.role === 'user' ? userLabel : (ROLE_LABELS[msg.role] || msg.role));
                var body = MARKDOWN_ROLES[msg.role] ? (msg.content_html != null ? msg.content_html : msg.content) : PlatformJS.escapeHtml(msg.content);
                var extraClass = '';
                if (isFinal) {
                    extraClass = ' platform-chat-final';
                } else if (msg.role === 'assistant' || msg.role === 'tool_result' || msg.role === 'self_check' || msg.role === 'progress' || msg.role === 'decision') {
                    extraClass = ' platform-chat-step';
                }
                html += '<div class="platform-chat-msg platform-chat-' + msg.role + extraClass + '"><strong>' + PlatformJS.escapeHtml(label) + ':</strong> ' + body + '</div>';
                if (isFinal && !isReadOnly) {
                    html += '<div class="platform-chat-feedback" data-feedback-for="' + msg.id + '">' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="up" title="Helpful">👍</button>' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="down" title="Not helpful">👎</button>' +
                        '</div>';
                }
            });
            messagesEl.innerHTML = html;
        }
        if (isReadOnly) {
            form.style.display = 'none';
            if (readonlyEl) {
                var ownerText = state.owner ? (' by ' + state.owner) : '';
                readonlyEl.textContent = 'Viewing conversation' + ownerText + ' (read-only)';
                readonlyEl.style.display = 'block';
            }
        } else {
            if (readonlyEl) {
                readonlyEl.style.display = 'none';
                readonlyEl.textContent = '';
            }
            if (state && state.pending) {
                var argsLines = '';
                for (var k in state.pending.args) { argsLines += '<div>' + PlatformJS.escapeHtml(k) + ' = ' + PlatformJS.escapeHtml(state.pending.args[k]) + '</div>'; }
                messagesEl.innerHTML += '<div class="platform-chat-pending"><p><strong>Run:</strong> ' + PlatformJS.escapeHtml(state.pending.tool) + '.' + PlatformJS.escapeHtml(state.pending.method) + '</p>' + argsLines +
                    '<button type="button" class="btn btn-primary" data-approve="' + state.pending.id + '">Approve</button> ' +
                    '<button type="button" class="btn btn-danger" data-deny="' + state.pending.id + '">Deny</button> ' +
                    '<input type="text" class="platform-chat-deny-reason" maxlength="1000" placeholder="Why not? (optional)" aria-label="Reason for denying"></div>';
                form.style.display = 'none';
            } else {
                form.style.display = 'flex';
            }
        }
        messagesEl.scrollTop = messagesEl.scrollHeight;
        if (!isReadOnly) {
            syncSqlConsole(state);
        }
    }

    // Prefill #platform-sql-query once per new agent query, skipping initial rehydrate when /sql just ran ?q=.
    var lastAppliedQuerySql = null;
    var suppressNextSqlSync = !!(window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.query_ran);
    function syncSqlConsole(state) {
        if (!window.PLATFORM_PAGE_CONTEXT || window.PLATFORM_PAGE_CONTEXT.page_type !== 'sql') { return; }
        if (!state || !state.last_query_sql) { return; }
        if (state.last_query_sql === lastAppliedQuerySql) { return; }
        lastAppliedQuerySql = state.last_query_sql;
        if (suppressNextSqlSync) { suppressNextSqlSync = false; return; }
        var queryBox = document.getElementById('platform-sql-query');
        if (queryBox) { queryBox.value = state.last_query_sql; }
    }

    function ensureSession() {
        var sessionId = localStorage.getItem(STORAGE_KEY);
        if (sessionId) return Promise.resolve(sessionId);
        return PlatformJS.postJSON('api/v1/chat/sessions', {}).then(function(state){
            localStorage.setItem(STORAGE_KEY, state.session_id);
            return state.session_id;
        });
    }

    var OPEN_KEY = 'platform_chat_widget_open';
    var SIZE_KEY = 'platform_chat_widget_size';
    var panel = root.querySelector('.platform-chat-widget-panel');

    if (localStorage.getItem(OPEN_KEY) === '1') {
        root.classList.add('platform-chat-widget-open');
    }
    var savedSize = localStorage.getItem(SIZE_KEY);
    if (savedSize) {
        var parts = savedSize.split('x');
        if (parts.length === 2) {
            panel.style.width = parts[0] + 'px';
            panel.style.height = parts[1] + 'px';
        }
    }
    if (window.ResizeObserver) {
        new ResizeObserver(function(){
            // Ignore initial 0x0 observation while panel is display:none.
            if (panel.offsetWidth === 0 || panel.offsetHeight === 0) return;
            localStorage.setItem(SIZE_KEY, Math.round(panel.offsetWidth) + 'x' + Math.round(panel.offsetHeight));
        }).observe(panel);
    }

    var resizeHandle = document.getElementById('platform-chat-widget-resize-handle');
    resizeHandle.addEventListener('mousedown', function(e){
        e.preventDefault();
        var startX = e.clientX, startY = e.clientY;
        var startWidth = panel.offsetWidth, startHeight = panel.offsetHeight;
        function onMove(moveEvent) {
            // Top-left handle against bottom-right-anchored panel: negative pointer delta grows dimensions.
            panel.style.width = (startWidth - (moveEvent.clientX - startX)) + 'px';
            panel.style.height = (startHeight - (moveEvent.clientY - startY)) + 'px';
        }
        function onUp() {
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onUp);
        }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
    });

    // Precedence: waiting (approval) > thinking (in-flight) > unread.
    var UNREAD_KEY = 'platform_chat_widget_unread';
    var turnsInFlight = 0;
    var awaitingApproval = false;
    function isPanelOpen() { return root.classList.contains('platform-chat-widget-open'); }
    function updateToggleState() {
        if (isPanelOpen()) { localStorage.removeItem(UNREAD_KEY); }
        var state = awaitingApproval ? 'waiting' : (turnsInFlight > 0 ? 'thinking' :
            (localStorage.getItem(UNREAD_KEY) === '1' ? 'unread' : null));
        ['waiting', 'thinking', 'unread'].forEach(function(name){
            toggle.classList.toggle('platform-chat-state-' + name, state === name);
        });
        toggle.setAttribute('aria-label', {waiting: 'Chat -- waiting for your approval',
            thinking: 'Chat -- the assistant is working', unread: 'Chat -- new reply'}[state] || 'Chat');
    }
    function turnStarted() { turnsInFlight++; updateToggleState(); }
    function turnEnded(answered) {
        turnsInFlight = Math.max(0, turnsInFlight - 1);
        if (answered && !isPanelOpen()) { localStorage.setItem(UNREAD_KEY, '1'); }
        updateToggleState();
    }

    toggle.addEventListener('click', function(){
        var isOpen = root.classList.toggle('platform-chat-widget-open');
        localStorage.setItem(OPEN_KEY, isOpen ? '1' : '0');
        updateToggleState();
    });

    document.getElementById('platform-chat-widget-new').addEventListener('click', function(){
        localStorage.removeItem(STORAGE_KEY);
        localStorage.removeItem(UNREAD_KEY);
        render(null);
    });

    function showThinking(sessionId) {
        var el = document.createElement('div');
        el.className = 'platform-chat-widget-thinking';
        el.textContent = 'Thinking... ';
        var stopBtn = document.createElement('button');
        stopBtn.type = 'button';
        stopBtn.className = 'platform-chat-widget-stop';
        stopBtn.textContent = 'Stop';
        stopBtn.setAttribute('data-stop', sessionId);
        el.appendChild(stopBtn);
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
        return el;
    }

    function appendOptimisticUserMessage(text) {
        var empty = messagesEl.querySelector('.platform-chat-widget-empty');
        if (empty) { empty.remove(); }
        var el = document.createElement('div');
        el.className = 'platform-chat-msg platform-chat-user';
        el.innerHTML = '<strong>You:</strong> ' + PlatformJS.escapeHtml(text);
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    var HISTORY_POLL_MS = 800;
    function pollWhilePending(sessionId, sendPromise) {
        // Guard late poll ticks after turnOver settles; detached turns stay open until state.running is false.
        var settled = false;
        var sendDone = false;
        var finishTurn, failTurn;
        var turnOver = new Promise(function(resolve, reject){ finishTurn = resolve; failTurn = reject; });
        var thinkingEl = showThinking(sessionId);
        turnStarted();
        var timer = setInterval(function(){
            fetch('api/v1/chat/sessions/' + encodeURIComponent(sessionId))
                .then(function(res){ if (!res.ok) { throw new Error('poll failed'); } return res.json(); })
                .then(function(state){
                    if (settled) { return; }
                    render(state);
                    if (sendDone && !state.running) { finishTurn(state); return; }
                    thinkingEl = showThinking(sessionId);
                })
                .catch(function(){});
        }, HISTORY_POLL_MS);
        sendPromise.then(function(state){
            // Reject error-only payloads (e.g. 409) instead of wiping rendered messages.
            if (!state || !state.messages) { failTurn(new Error((state && state.error) || 'send failed')); return; }
            sendDone = true;
            if (!state.running) { finishTurn(state); }
        }, failTurn);
        return turnOver.then(function(state){
            settled = true;
            clearInterval(timer);
            thinkingEl.remove();
            render(state);
            turnEnded(true);
            return state;
        }, function(err){
            settled = true;
            clearInterval(timer);
            thinkingEl.remove();
            turnEnded(false);
            throw err;
        });
    }

    // Resume polling across full-page CGI navigations; cap inline-mode polls if a worker died.
    function isTurnPending(state) {
        if (!state || !state.messages || state.messages.length === 0) { return false; }
        if (state.pending) { return false; }
        if (typeof state.running === 'boolean') { return state.running; }
        return state.messages[state.messages.length - 1].role === 'user';
    }

    var RESUME_POLL_MAX_ATTEMPTS = 60;
    function resumePollIfPending(sessionId, state) {
        if (!isTurnPending(state)) { return; }
        var attempts = 0;
        var thinkingEl = showThinking(sessionId);
        turnStarted();
        var timer = setInterval(function(){
            attempts++;
            fetch('api/v1/chat/sessions/' + encodeURIComponent(sessionId))
                .then(function(res){ if (!res.ok) { throw new Error('poll failed'); } return res.json(); })
                .then(function(freshState){
                    render(freshState);
                    var capped = typeof freshState.running !== 'boolean' && attempts >= RESUME_POLL_MAX_ATTEMPTS;
                    if (!isTurnPending(freshState) || capped) {
                        clearInterval(timer);
                        thinkingEl.remove();
                        turnEnded(!isTurnPending(freshState));
                    } else {
                        thinkingEl = showThinking(sessionId);
                    }
                })
                .catch(function(){});
        }, HISTORY_POLL_MS);
    }

    function showFetchError() {
        var el = document.createElement('div');
        el.className = 'platform-chat-widget-error';
        el.textContent = 'Something went wrong sending that -- please try again.';
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    var pendingAttachment = null;

    function clearAttachment() {
        pendingAttachment = null;
        fileInput.value = '';
        attachmentEl.style.display = 'none';
        attachmentEl.className = 'platform-chat-widget-attachment';
        attachmentEl.innerHTML = '';
    }

    function showAttachmentStatus(text, isError) {
        attachmentEl.style.display = 'flex';
        attachmentEl.className = 'platform-chat-widget-attachment' + (isError ? ' platform-chat-widget-attachment-error' : '');
        attachmentEl.textContent = text;
    }

    if (attachBtn) {
        attachBtn.addEventListener('click', function(){ fileInput.click(); });

        fileInput.addEventListener('change', function(){
            var file = fileInput.files[0];
            if (!file) { return; }
            showAttachmentStatus('Attaching ' + file.name + '...', false);
            attachBtn.disabled = true;
            var formData = new FormData();
            formData.append('file', file);
            fetch('api/v1/chat/attachments/extract', {
                method: 'POST',
                headers: {'X-CSRF-Token': PlatformJS.getCsrfToken()},
                body: formData
            }).then(function(res){
                return res.json().then(function(data){ return {ok: res.ok, data: data}; });
            }).then(function(result){
                attachBtn.disabled = false;
                if (!result.ok || !result.data || result.data.error) {
                    showAttachmentStatus((result.data && result.data.error) || 'Could not attach this file.', true);
                    fileInput.value = '';
                    return;
                }
                pendingAttachment = {filename: result.data.filename, text: result.data.text};
                attachmentEl.style.display = 'flex';
                attachmentEl.className = 'platform-chat-widget-attachment';
                attachmentEl.innerHTML = '<span>Attached: ' + PlatformJS.escapeHtml(result.data.filename) + '</span>' +
                    '<button type="button" id="platform-chat-widget-attachment-clear" title="Remove">&times;</button>';
            }).catch(function(){
                attachBtn.disabled = false;
                showAttachmentStatus('Could not attach this file.', true);
                fileInput.value = '';
            });
        });
    }

    attachmentEl.addEventListener('click', function(e){
        if (e.target.id === 'platform-chat-widget-attachment-clear') { clearAttachment(); }
    });

    form.addEventListener('submit', function(e){
        e.preventDefault();
        var typedText = input.value;
        if (!typedText) return;
        input.value = '';
        var text = typedText;
        var pageDescription = describeCurrentPage();
        if (pageDescription) {
            text = '[Current page: ' + pageDescription + ']\n\n' + text;
        }
        if (window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.current_user) {
            text = '[Current user: ' + window.PLATFORM_PAGE_CONTEXT.current_user + ']\n' + text;
        }
        // Outermost wrapper order matches agent.display_content stripping; one-shot per send.
        if (pendingAttachment) {
            text = '[Attached file: ' + pendingAttachment.filename + ']\n---\n' + pendingAttachment.text + '\n---\n\n' + text;
            clearAttachment();
        }
        appendOptimisticUserMessage(typedText);
        ensureSession().then(function(sessionId){
            return pollWhilePending(sessionId, PlatformJS.postJSON('api/v1/chat/sessions/' + encodeURIComponent(sessionId) + '/messages', {message: text}));
        }).catch(function(){ showFetchError(); input.value = typedText; });
    });

    messagesEl.addEventListener('click', function(e){
        var sessionId = localStorage.getItem(STORAGE_KEY);
        if (e.target.hasAttribute('data-approve')) {
            pollWhilePending(sessionId, PlatformJS.postJSON('api/v1/chat/sessions/' + encodeURIComponent(sessionId) + '/approve', {pending_id: e.target.getAttribute('data-approve')}))
                .catch(function(){ showFetchError(); });
        } else if (e.target.hasAttribute('data-deny')) {
            var reasonEl = e.target.parentNode.querySelector('.platform-chat-deny-reason');
            var reason = reasonEl ? reasonEl.value : '';
            pollWhilePending(sessionId, PlatformJS.postJSON('api/v1/chat/sessions/' + encodeURIComponent(sessionId) + '/deny', {pending_id: e.target.getAttribute('data-deny'), reason: reason}))
                .catch(function(){ showFetchError(); });
        } else if (e.target.hasAttribute('data-stop')) {
            // Requests between-step cancellation; pollWhilePending renders the settled reply.
            e.target.disabled = true;
            e.target.textContent = 'Stopping…';
            PlatformJS.postJSON('api/v1/chat/sessions/' + encodeURIComponent(e.target.getAttribute('data-stop')) + '/stop', {}).catch(function(){});
        } else if (e.target.hasAttribute('data-feedback')) {
            var messageId = e.target.getAttribute('data-feedback-message');
            var feedback = e.target.getAttribute('data-feedback');
            var container = e.target.closest('.platform-chat-feedback');
            if (container) {
                container.querySelectorAll('button').forEach(function(b){ b.disabled = true; });
                e.target.classList.add('platform-feedback-pressed');
            }
            function showFeedbackError() {
                if (container) { container.innerHTML = '<span class="platform-chat-feedback-error">Couldn\'t record feedback.</span>'; }
            }
            PlatformJS.postJSON('api/v1/chat/messages/' + encodeURIComponent(messageId) + '/feedback', {feedback: feedback}).then(function(result){
                if (!container) return;
                if (result && result.ok) {
                    container.innerHTML = feedback === 'up' ? 'Thanks for the feedback 👍' : 'Thanks for the feedback 👎';
                } else {
                    showFeedbackError();
                }
            }).catch(showFeedbackError);
        }
    });

    // Admin read-only inspection opens the foreign session without overwriting the admin's own STORAGE_KEY.
    var initialSessionId = null;
    var initialReadOnly = false;
    if (window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.open_chat_session_id) {
        initialSessionId = window.PLATFORM_PAGE_CONTEXT.open_chat_session_id;
        initialReadOnly = !!(window.PLATFORM_PAGE_CONTEXT.open_chat_read_only);
        if (!initialReadOnly) {
            localStorage.setItem(STORAGE_KEY, initialSessionId);
        }
        root.classList.add('platform-chat-widget-open');
        localStorage.setItem(OPEN_KEY, '1');
    } else {
        initialSessionId = localStorage.getItem(STORAGE_KEY);
    }

    updateToggleState();
    if (initialSessionId) {
        fetch('api/v1/chat/sessions/' + encodeURIComponent(initialSessionId))
            .then(function(res){ if (!res.ok) { throw new Error('no session'); } return res.json(); })
            .then(function(state){
                render(state);
                if (!state.read_only) {
                    resumePollIfPending(initialSessionId, state);
                }
            })
            .catch(function(){
                if (!initialReadOnly) {
                    localStorage.removeItem(STORAGE_KEY);
                }
            });
    }
})();
