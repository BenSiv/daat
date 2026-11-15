(function(){
    var container = document.querySelector('.platform-actions');
    var status = document.getElementById('status-message');
    if (!container || !status) { return; }
    container.addEventListener('click', function(e){
        var btn = e.target.closest('button[data-ext]');
        if (!btn) { return; }
        var ext = btn.getAttribute('data-ext');
        var trigger = btn.getAttribute('data-trigger');
        btn.disabled = true;
        status.className = "status-msg";
        status.innerText = "Running...";
        PlatformJS.postJSON('/admin-triggers/' + encodeURIComponent(ext) + '/' + encodeURIComponent(trigger), {})
            .then(function(result){
                btn.disabled = false;
                if (result && result.success) {
                    status.className = "status-msg success";
                    status.innerText = result.message || "Done.";
                } else {
                    status.className = "status-msg error";
                    status.innerText = (result && result.error) || "Trigger failed.";
                }
            })
            .catch(function(){
                btn.disabled = false;
                status.className = "status-msg error";
                status.innerText = "An unexpected error occurred.";
            });
    });
})();

