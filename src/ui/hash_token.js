(function() {
    var field = document.getElementById('reset-token') || document.getElementById('verify-token');
    var missing = document.getElementById('reset-missing') || document.getElementById('verify-missing');
    if (!field) { return; }
    var match = /(?:^#|&)token=([0-9a-f]+)/.exec(window.location.hash);
    if (match) {
        field.value = match[1];
        history.replaceState(null, '', window.location.pathname);
    }
    if (!field.value) {
        field.form.hidden = true;
        if (missing) { missing.hidden = false; }
    }
})();

