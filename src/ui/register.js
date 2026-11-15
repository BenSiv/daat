(function(){
    const layout = JSON.parse(document.getElementById("platform-register-layout").textContent);
    const boot = JSON.parse(document.getElementById("platform-register-boot").textContent);
    const entityType = boot.entity_type;
    const lockedFields = boot.locked_fields;
    const baseUrl = window.location.pathname.replace(/\/register\/?$/, "");
    let rowCounter = 0;

    // Which document this registration table is embedded in, for
    // ledger provenance (source_notebook_entry_id).
    // An explicit ?entry= on this iframe's own src overrides
    // auto-detection via document.referrer (the parent page's URL,
    // set by the browser for a same-origin iframe navigation) --
    // useful when referrer policies strip it, or to label it by
    // something other than a raw URL.
    const urlParams = new URLSearchParams(window.location.search);
    let notebookEntry = urlParams.get("entry");
    if (!notebookEntry && document.referrer) {
        notebookEntry = document.referrer;
    }

    function initTable() {
        const headerRow = document.getElementById("table-headers");
        headerRow.innerHTML = "";

        layout.fields.forEach(field => {
            const th = document.createElement("th");
            th.innerText = field.label;
            if (field.required) { th.classList.add("required"); }
            headerRow.appendChild(th);
        });

        const deleteTh = document.createElement("th");
        deleteTh.style.width = "40px";
        headerRow.appendChild(deleteTh);

        addRow();
    }

    function addRow() {
        rowCounter++;
        const tbody = document.getElementById("table-body");
        const tr = document.createElement("tr");
        tr.id = `row-${rowCounter}`;

        layout.fields.forEach(field => {
            const td = document.createElement("td");
            const wrapper = document.createElement("div");
            wrapper.classList.add("cell-input-wrapper");

            // A locked field (?lock_<name>=<value>) shows a fixed,
            // read-only display -- e.g. which mixture these
            // ingredients belong to -- plus a same-named hidden
            // input so submitBatch()'s existing
            // querySelector(`[name="..."]`) collection picks up the
            // value with no changes needed there at all.
            const locked = lockedFields[field.name];
            PlatformJS.buildFieldInput(field, wrapper, { locked: locked, baseUrl: baseUrl });
            td.appendChild(wrapper);
            tr.appendChild(td);
        });

        const deleteTd = document.createElement("td");
        const deleteBtn = document.createElement("button");
        deleteBtn.type = "button";
        deleteBtn.classList.add("btn-delete");
        deleteBtn.innerHTML = "&times;";
        deleteBtn.onclick = () => {
            const rows = tbody.getElementsByTagName("tr");
            if (rows.length > 1) {
                tr.remove();
            } else {
                alert("Cannot delete the only row.");
            }
        };
        deleteTd.appendChild(deleteBtn);
        tr.appendChild(deleteTd);
        tbody.appendChild(tr);
    }

    // Row/field lookup stays bespoke here (register's inputs share
    // one bare `name` per <tr>, so a lookup needs the row too) --
    // only the "mark this input errored" mechanics are shared.
    function highlightError(rowIndex, fieldName, message) {
        const tbody = document.getElementById("table-body");
        const tr = tbody.getElementsByTagName("tr")[rowIndex];
        if (!tr) return;
        const input = tr.querySelector(`[name="${fieldName}"]`);
        if (!input) return;
        PlatformJS.highlightError(input, message);
    }

    function clearAllErrors() {
        PlatformJS.clearAllErrors(document, document.getElementById("status-message"));
    }

    function submitBatch() {
        clearAllErrors();
        const tbody = document.getElementById("table-body");
        const trs = tbody.getElementsByTagName("tr");
        const payload = [];

        for (let i = 0; i < trs.length; i++) {
            const tr = trs[i];
            const rowData = {};
            layout.fields.forEach(field => {
                const el = tr.querySelector(`[name="${field.name}"]`);
                if (el) {
                    let val = el.value;
                    if (field.type === "number" && val !== "") { val = parseFloat(val); }
                    // Both multivalue types send a real JSON array
                    // in the payload, not a joined string -- /api/
                    // submit's body is already JSON, so there's no
                    // wire-format reason to flatten one.
                    if (field.type === "multi_select") {
                        val = Array.from(el.selectedOptions).map(o => o.value);
                    } else if (field.type === "multi_reference" || field.type === "multi_polymorphic_reference") {
                        val = val.split(",").map(s => s.trim()).filter(s => s.length > 0);
                    }
                    rowData[field.name] = val;
                }
            });
            payload.push(rowData);
        }

        const msg = document.getElementById("status-message");
        msg.className = "status-msg";
        msg.innerText = "Validating and submitting...";
        msg.style.display = "block";

        const entryParam = notebookEntry ? `&entry=${encodeURIComponent(notebookEntry)}` : "";
        PlatformJS.postJSON(`${baseUrl}/api/submit?type=${encodeURIComponent(entityType)}${entryParam}`, payload)
        .then(data => {
            if (data.success) {
                msg.className = "status-msg success";
                msg.innerText = `Successfully registered ${data.created_ids.length} entities (IDs: ${data.created_ids.join(", ")}).`;
                tbody.innerHTML = "";
                rowCounter = 0;
                addRow();
            } else {
                msg.className = "status-msg error";
                msg.innerText = "Submission failed. Please check highlighted errors in the form.";
                if (data.issues && data.issues.length > 0) {
                    data.issues.forEach(issue => {
                        highlightError(issue.row_index - 1, issue.field, issue.message);
                    });
                }
            }
        })
        .catch(err => {
            console.error("Submit error", err);
            msg.className = "status-msg error";
            msg.innerText = "An unexpected error occurred during submission.";
        });
    }

    window.onload = initTable;
    document.getElementById("btn-add-row").addEventListener("click", addRow);
    document.getElementById("btn-submit-batch").addEventListener("click", submitBatch);
})();

