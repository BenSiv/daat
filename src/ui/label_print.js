(function(){
    var select = document.getElementById('platform-label-printer');
    var btn = document.getElementById('platform-print-label-btn');
    var status = document.getElementById('platform-print-label-status');
    var devices = [];
    if (!select || !btn || !status) { return; }

    function showStatus(msg, isError){
        status.textContent = msg;
        status.className = isError ? 'platform-admin-message-error' : '';
    }

    if(typeof BrowserPrint === 'undefined'){
        showStatus('Zebra Browser Print not detected -- install it from zebra.com/us/en/support-downloads/software/printer-setup-utilities/browser-print.html and reload this page.', true);
        btn.disabled = true;
        return;
    }

    BrowserPrint.getLocalDevices(function(deviceList){
        devices = deviceList || [];
        select.innerHTML = '';
        if(devices.length === 0){
            showStatus('No local Zebra printers found.', true);
            btn.disabled = true;
            return;
        }
        devices.forEach(function(d, i){
            var opt = document.createElement('option');
            opt.value = i;
            opt.textContent = d.name;
            select.appendChild(opt);
        });
    }, function(){
        showStatus('Could not reach Zebra Browser Print -- is the app running?', true);
        btn.disabled = true;
    }, 'printer');

    btn.addEventListener('click', function(){
        var device = devices[parseInt(select.value, 10)];
        if(!device){ showStatus('No printer selected.', true); return; }
        showStatus('Printing...', false);
        var entityType = btn.getAttribute('data-entity-type') || '';
        var entityId = btn.getAttribute('data-entity-id') || '';
        var url = 'label?type=' + encodeURIComponent(entityType) + '&entity_id=' + encodeURIComponent(entityId);
        fetch(url).then(function(resp){
            if(!resp.ok){ throw new Error('label render failed'); }
            return resp.text();
        }).then(function(zpl){
            device.send(zpl, function(){
                showStatus('Sent to ' + device.name + '.', false);
            }, function(err){
                showStatus('Print failed: ' + err, true);
            });
        }).catch(function(){
            showStatus('Could not fetch label content.', true);
        });
    });
})();

