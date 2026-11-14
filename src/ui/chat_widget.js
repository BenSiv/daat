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

    // Builds a short, readable description from whatever page_shell
    // (see its own header comment) put in window.PLATFORM_PAGE_CONTEXT
    // for the current page -- every page sets at least page_type/title
    // now, entity pages/documents/views add entity_type+entity_id or
    // view_name on top.
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
    // Same roles as html.lua's own CHAT_MARKDOWN_ROLES -- the server
    // (chat_widget_state, cgi.lua) already rendered these through
    // cmark-gfm before this JSON ever reached the browser, so this JS
    // trusts and embeds that HTML directly rather than re-escaping it
    // (which would just show the literal tags) or re-implementing
    // Markdown rendering client-side.
    var MARKDOWN_ROLES = {assistant: true, self_check: true, compaction_summary: true, progress: true};
    function render(state) {
        awaitingApproval = !!(state && state.pending);
        updateToggleState();
        if (!state || !state.messages || state.messages.length === 0) {
            messagesEl.innerHTML = '<p class="platform-chat-widget-empty">Ask something, or ask the assistant to search or create a document...</p>';
        } else {
            var html = '';
            state.messages.forEach(function(msg){
                // is_final (agent.assistant_message_is_final, agent.lua)
                // tells a turn's real bottom-line reply apart from an
                // earlier round in the same turn that narrated some
                // text alongside a tool call it also proposed -- both
                // are role "assistant" with non-empty text, so without
                // this flag they'd render identically.
                var isFinal = msg.role === 'assistant' && msg.is_final === true;
                var label = isFinal ? 'Answer' : (ROLE_LABELS[msg.role] || msg.role);
                var body = MARKDOWN_ROLES[msg.role] ? msg.content : PlatformJS.escapeHtml(msg.content);
                var extraClass = '';
                if (isFinal) {
                    extraClass = ' platform-chat-final';
                } else if (msg.role === 'assistant' || msg.role === 'tool_result' || msg.role === 'self_check' || msg.role === 'progress' || msg.role === 'decision') {
                    extraClass = ' platform-chat-step';
                }
                html += '<div class="platform-chat-msg platform-chat-' + msg.role + extraClass + '"><strong>' + PlatformJS.escapeHtml(label) + ':</strong> ' + body + '</div>';
                // Feedback only makes sense on a turn's real final
                // answer -- not on the user's own message, a tool
                // result, in-turn narration, or a compaction summary
                // the user never actually sees as a "reply".
                if (isFinal) {
                    html += '<div class="platform-chat-feedback" data-feedback-for="' + msg.id + '">' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="up" title="Helpful">👍</button>' +
                        '<button type="button" data-feedback-message="' + msg.id + '" data-feedback="down" title="Not helpful">👎</button>' +
                        '</div>';
                }
            });
            messagesEl.innerHTML = html;
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
        messagesEl.scrollTop = messagesEl.scrollHeight;
        syncSqlConsole(state);
    }

    // Prefills the /sql console's own query textarea from the agent's
    // most recent entity.query call this session (chat_widget_state,
    // cgi.lua) -- only on this specific page (page_type "sql", set by
    // page_shell), and only once per new value, so re-renders after an
    // unrelated turn don't keep clobbering text the user is actively
    // editing by hand. Writes the query text only -- running it is
    // still a deliberate click on /sql's own Run button, through its
    // own real capability check and row cap, not something this widget
    // ever does itself.
    //
    // /sql's own "Run" button is a plain GET form submit, a full page
    // reload -- which re-runs this whole script, including the initial
    // history-rehydrate fetch below. That fetch's own state always
    // carries whatever last_query_sql the chat agent produced, which
    // could be from an entirely unrelated conversation -- with no
    // guard, it would silently overwrite the query the user JUST ran
    // and is looking at results for, seconds after the page finished
    // loading. page_context.query_ran (cgi.lua's /sql route)
    // is true exactly when this page load itself came from running a
    // query (?q= present) -- suppress exactly that one rehydrate-
    // triggered sync in that case, so the box keeps showing what the
    // user actually ran. A live chat message sent *after* this page
    // loaded still prefills normally -- only the automatic history
    // rehydrate is suppressed, and only once.
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
        return PlatformJS.postJSON('api/chat-widget-start', {}).then(function(state){
            localStorage.setItem(STORAGE_KEY, state.session_id);
            return state.session_id;
        });
    }

    var OPEN_KEY = 'platform_chat_widget_open';
    var SIZE_KEY = 'platform_chat_widget_size';
    var panel = root.querySelector('.platform-chat-widget-panel');

    // A full page load (not a SPA route change) re-renders this whole
    // widget from scratch every navigation, so "is the panel open"
    // needs its own persisted flag -- same reasoning as the session id
    // itself, just for UI state instead of conversation state.
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
            // ResizeObserver fires once immediately on observe(), even
            // while the panel is display:none (offsetWidth/Height 0) --
            // guard against that firing clobbering a real saved size.
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
            // The handle sits at the panel's top-left corner, the
            // corner that's free to move (bottom-right is pinned via
            // the panel's own right:0; bottom:64px anchoring) -- so
            // dragging up-left (negative delta) grows the panel,
            // dragging down-right shrinks it. CSS min/max-width/height
            // on the panel itself still clamp the result.
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

    // The button's state class (see platform_chat_widget_css): waiting
    // (an approval prompt is up) wins over thinking (a turn in flight --
    // a send/approve or a turn resumed on page load), which wins over
    // unread (a turn finished while the panel was closed). unread is
    // kept in localStorage so it survives navigating to another page,
    // and clears when the panel is opened.
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

    // sessionId is embedded as a data-stop attribute, not closed over,
    // because the Stop button is found later purely via messagesEl's
    // own delegated click listener (same pattern as data-approve/
    // data-deny/data-feedback below) -- it has to survive this element
    // being replaced on every poll tick without re-registering a
    // listener each time.
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

    // Shown the instant the user hits send, before the server has even
    // seen the message -- run_turn (agent.lua) can take several
    // round-trips before it returns, and without this the user's own
    // words disappeared from the screen the moment they hit send (the
    // input was cleared) until the whole turn finished. This is purely
    // a placeholder: the very next render(state), whether from a poll
    // tick or the final response, redraws the real persisted row in
    // its place (agent.run_turn persists the user message before doing
    // anything else, so it's already there well before the turn ends).
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
    // run_turn (agent.lua) persists each step -- the user message, each
    // assistant round, every tool result -- to agent_message as it
    // happens, well before the request that's running it returns. So
    // rather than sitting on "Thinking..." until the whole (possibly
    // multi-tool-call) turn completes, poll the same read-only history
    // endpoint the widget already uses for page-load rehydration and
    // redraw as real rows land -- no server or provider changes needed,
    // this is just reading what's already there sooner. `sendPromise`
    // is the in-flight send/approve call itself; once it resolves (or
    // fails) polling stops and the final state wins.
    function pollWhilePending(sessionId, sendPromise) {
        // `settled` guards against a tick whose fetch was already in
        // flight (HISTORY_POLL_MS is 800ms -- easy to have one in flight
        // at any moment) when sendPromise resolves: clearInterval only
        // stops *future* ticks, it doesn't cancel one already started, so
        // that tick's own .then() can still fire after the block below
        // already removed thinkingEl and rendered the real final state --
        // and unconditionally re-adding a Stop button at that point left
        // a live, clickable "Thinking... Stop" sitting under an already-
        // answered reply (found live: reported as "the Stop button
        // didn't stop the agent" -- clicking a Stop tied to a turn that
        // finished before the button even reappeared can't do anything).
        //
        // A detached turn (agent_turn_mode "detached", agent.lua) answers
        // the send at once with running: true; the turn is over when a
        // poll says running: false. The server settles a turn whose
        // worker died (agent.turn_status), so that always comes.
        var settled = false;
        var sendDone = false;
        var finishTurn, failTurn;
        var turnOver = new Promise(function(resolve, reject){ finishTurn = resolve; failTurn = reject; });
        var thinkingEl = showThinking(sessionId);
        turnStarted();
        var timer = setInterval(function(){
            fetch('api/chat-widget-history?session_id=' + encodeURIComponent(sessionId))
                .then(function(res){ if (!res.ok) { throw new Error('poll failed'); } return res.json(); })
                .then(function(state){
                    if (settled) { return; }
                    render(state);
                    if (sendDone && !state.running) { finishTurn(state); return; }
                    thinkingEl = showThinking(sessionId);
                })
                .catch(function(){ /* transient -- the next tick tries again */ });
        }, HISTORY_POLL_MS);
        sendPromise.then(function(state){
            // An error-only reply (e.g. 409: a turn is still running)
            // has no messages -- rendering it would blank the panel.
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

    // /api/chat-widget-send runs the whole (possibly multi-tool-call)
    // turn synchronously server-side before its HTTP response returns
    // (cgi.lua's /api/chat-widget-send handler calls agent.run_turn
    // directly), and a full-page navigation is a real, separate CGI
    // process per request -- navigating away mid-turn aborts the
    // browser's own fetch and tears down pollWhilePending's interval,
    // but does *not* stop the already-running server process, which
    // keeps persisting the turn's steps to agent_message regardless
    // (confirmed live: reported as the widget "clearing" an in-progress
    // or just-finished thinking/answer on page change -- the answer was
    // never lost, the new page's one-shot rehydrate fetch below just
    // ran before the turn finished writing it, and nothing was watching
    // for it afterward). isTurnPending/resumePollIfPending close that
    // gap: a session whose last message is the user's own (no reply,
    // no pending approval) means a turn was in flight when this page
    // loaded, so resume the same poll-and-render loop pollWhilePending
    // uses instead of leaving it at that one stale fetch.
    function isTurnPending(state) {
        if (!state || !state.messages || state.messages.length === 0) { return false; }
        if (state.pending) { return false; } // an approval prompt is a settled, actionable state, not "still running"
        // A detached turn says so itself; an inline one is inferred.
        if (typeof state.running === 'boolean') { return state.running; }
        return state.messages[state.messages.length - 1].role === 'user';
    }

    // Capped, unlike pollWhilePending's own loop -- that one's stop
    // condition is tied to the sendPromise it's awaiting, which a page
    // load resuming someone else's already-in-flight turn doesn't have.
    // Without a cap, a turn that crashed/was killed server-side before
    // ever writing a reply would leave its session's last message stuck
    // as role "user" forever, polling this session on every future page
    // load indefinitely.
    var RESUME_POLL_MAX_ATTEMPTS = 60; // HISTORY_POLL_MS(800) * 60 =~ 48s
    function resumePollIfPending(sessionId, state) {
        if (!isTurnPending(state)) { return; }
        var attempts = 0;
        var thinkingEl = showThinking(sessionId);
        turnStarted();
        var timer = setInterval(function(){
            attempts++;
            fetch('api/chat-widget-history?session_id=' + encodeURIComponent(sessionId))
                .then(function(res){ if (!res.ok) { throw new Error('poll failed'); } return res.json(); })
                .then(function(freshState){
                    render(freshState);
                    // The cap is for inline turns, which can't say they
                    // died; a detached one is settled by the server.
                    var capped = typeof freshState.running !== 'boolean' && attempts >= RESUME_POLL_MAX_ATTEMPTS;
                    if (!isTurnPending(freshState) || capped) {
                        clearInterval(timer);
                        thinkingEl.remove();
                        turnEnded(!isTurnPending(freshState));
                    } else {
                        thinkingEl = showThinking(sessionId);
                    }
                })
                .catch(function(){ /* transient -- the next tick tries again */ });
        }, HISTORY_POLL_MS);
    }

    // A rejected fetch (network drop, a request landing mid-server-
    // restart, CORS, whatever) would otherwise vanish completely -- the
    // thinking indicator removed and nothing else happening, so a real
    // failure looks identical to "nothing was typed". This is a
    // different gap than agent_tools.execute_tool's own errors (agent.lua,
    // server-persisted, shows as a real transcript row) -- a fetch that
    // never reaches the server has nothing for the server to persist,
    // so this has to be a client-side-only message instead.
    function showFetchError() {
        var el = document.createElement('div');
        el.className = 'platform-chat-widget-error';
        el.textContent = 'Something went wrong sending that -- please try again.';
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    // Attachments (brex #53) -- "documents for context," not vision or
    // a real platform Document: /api/chat-widget-attach (cgi.lua)
    // extracts a PDF/.docx's text and hands it straight back, stateless
    // -- nothing is persisted server-side until the text is folded into
    // the next outgoing message below and sent through the normal
    // chat-widget-send path, one-shot (cleared the moment a message is
    // actually sent, never re-attached to a later message).
    var pendingAttachment = null; // {filename, text}

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

    // attachBtn/fileInput only exist in the DOM at all when
    // config.platform_config().chat_attachments_enabled is on for this
    // deployment (html.render_chat_widget's own attach_html) -- guard
    // the whole wiring, not just individual calls, so a disabled
    // deployment's widget script has nothing left that ever touches
    // these two elements.
    if (attachBtn) {
        attachBtn.addEventListener('click', function(){ fileInput.click(); });

        fileInput.addEventListener('change', function(){
            var file = fileInput.files[0];
            if (!file) { return; }
            showAttachmentStatus('Attaching ' + file.name + '...', false);
            attachBtn.disabled = true;
            var formData = new FormData();
            formData.append('file', file);
            fetch('api/chat-widget-attach', {
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
        // Read lazily, at send time, not at widget-init time -- whatever
        // page.PLATFORM_PAGE_CONTEXT is *right now* is what the agent
        // should be told, every message, not just the first -- if the
        // widget's conversation carries over as the user browses to a
        // different page, the agent should track that, not still think
        // it's on wherever the chat happened to start.
        var pageDescription = describeCurrentPage();
        if (pageDescription) {
            text = '[Current page: ' + pageDescription + ']\n\n' + text;
        }
        if (window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.current_user) {
            text = '[Current user: ' + window.PLATFORM_PAGE_CONTEXT.current_user + ']\n' + text;
        }
        // Outermost wrapper (matches agent.display_content's own strip
        // order, agent.lua -- it peels this off first, then Current
        // user/page) -- one-shot: cleared the moment it's folded in, so
        // a later message never carries a stale attachment along.
        if (pendingAttachment) {
            // Dash delimiters, not triple-double-quotes -- this whole
            // template is itself a Luam long string (html.lua) using
            // that same triple-double-quote token, so using it here
            // too would terminate the outer string early (confirmed --
            // it did, as a real parse error, before this fix).
            text = '[Attached file: ' + pendingAttachment.filename + ']\n---\n' + pendingAttachment.text + '\n---\n\n' + text;
            clearAttachment();
        }
        appendOptimisticUserMessage(typedText);
        ensureSession().then(function(sessionId){
            return pollWhilePending(sessionId, PlatformJS.postJSON('api/chat-widget-send', {session_id: sessionId, message: text}));
        }).catch(function(){ showFetchError(); input.value = typedText; });
    });

    messagesEl.addEventListener('click', function(e){
        var sessionId = localStorage.getItem(STORAGE_KEY);
        if (e.target.hasAttribute('data-approve')) {
            pollWhilePending(sessionId, PlatformJS.postJSON('api/chat-widget-approve', {pending_id: e.target.getAttribute('data-approve'), session_id: sessionId}))
                .catch(function(){ showFetchError(); });
        } else if (e.target.hasAttribute('data-deny')) {
            // The optional reason beside Deny goes to the decision row
            // and the result the model reads (doc/approval-request-rows.md).
            var reasonEl = e.target.parentNode.querySelector('.platform-chat-deny-reason');
            var reason = reasonEl ? reasonEl.value : '';
            pollWhilePending(sessionId, PlatformJS.postJSON('api/chat-widget-deny', {pending_id: e.target.getAttribute('data-deny'), session_id: sessionId, reason: reason}))
                .catch(function(){ showFetchError(); });
        } else if (e.target.hasAttribute('data-stop')) {
            // Fire-and-forget: this doesn't resolve the in-flight
            // chat-widget-send call itself -- it just flags the session
            // so run_turn's own loop (agent.lua) notices and stops
            // between turns, which is what makes that original call
            // resolve sooner. pollWhilePending's own poll/resolve
            // handling then renders the resulting "stopped" message the
            // same way it renders any other final reply -- nothing
            // extra to do here beyond disabling the button so a slow
            // stop (up to one more full turn) doesn't invite repeat
            // clicks.
            e.target.disabled = true;
            e.target.textContent = 'Stopping…';
            PlatformJS.postJSON('api/chat-widget-stop', {session_id: e.target.getAttribute('data-stop')}).catch(function(){});
        } else if (e.target.hasAttribute('data-feedback')) {
            var messageId = e.target.getAttribute('data-feedback-message');
            var feedback = e.target.getAttribute('data-feedback');
            var container = e.target.closest('.platform-chat-feedback');
            // Mark the clicked button as pressed and disable both
            // immediately, before the request even resolves -- otherwise
            // nothing happens visually until (and unless) the async call
            // both succeeds and resolves, which reads as "the button
            // does nothing" even when it's working.
            if (container) {
                container.querySelectorAll('button').forEach(function(b){ b.disabled = true; });
                e.target.classList.add('platform-feedback-pressed');
            }
            function showFeedbackError() {
                if (container) { container.innerHTML = '<span class="platform-chat-feedback-error">Couldn\'t record feedback.</span>'; }
            }
            PlatformJS.postJSON('api/chat-widget-feedback', {message_id: messageId, feedback: feedback}).then(function(result){
                if (!container) return;
                if (result && result.ok) {
                    container.innerHTML = feedback === 'up' ? 'Thanks for the feedback 👍' : 'Thanks for the feedback 👎';
                } else {
                    showFeedbackError();
                }
            }).catch(showFeedbackError);
        }
    });

    // A page can hand off a specific session to resume (currently only
    // /chat's history browser does this, via cgi.lua's page_context.
    // open_chat_session_id -- clicking a past session there should pop
    // the widget open onto that exact conversation, not leave it
    // closed or on whatever it had cached). Wins over an existing
    // cached session id, since the user just explicitly picked this one.
    if (window.PLATFORM_PAGE_CONTEXT && window.PLATFORM_PAGE_CONTEXT.open_chat_session_id) {
        localStorage.setItem(STORAGE_KEY, window.PLATFORM_PAGE_CONTEXT.open_chat_session_id);
        root.classList.add('platform-chat-widget-open');
        localStorage.setItem(OPEN_KEY, '1');
    }

    updateToggleState();
    var existingSessionId = localStorage.getItem(STORAGE_KEY);
    if (existingSessionId) {
        fetch('api/chat-widget-history?session_id=' + encodeURIComponent(existingSessionId))
            .then(function(res){ if (!res.ok) { throw new Error('no session'); } return res.json(); })
            .then(function(state){
                render(state);
                resumePollIfPending(existingSessionId, state);
            })
            .catch(function(){ localStorage.removeItem(STORAGE_KEY); });
    }
})();
