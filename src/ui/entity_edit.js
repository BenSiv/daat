(function(){
    const layout = JSON.parse(document.getElementById("platform-entity-edit-layout").textContent);
    const row = JSON.parse(document.getElementById("platform-entity-edit-row").textContent);
    const boot = JSON.parse(document.getElementById("platform-entity-edit-boot").textContent);
    const entityType = boot.entity_type;
    const entityId = boot.entity_id;
    const baseUrl = window.location.pathname.replace(/\/entity-edit\/?$/, "");

    // Field lookup stays bespoke here (document-global, not
    // row-scoped like register's) -- only the "mark this input
    // errored" mechanics are shared.
    function highlightError(fieldName, message) {
        const input = document.querySelector(`[name="${fieldName}"]`);
        if (!input) return;
        PlatformJS.highlightError(input, message);
    }

    function buildFields() {
        const container = document.getElementById("edit-fields");
        layout.fields.forEach(field => {
            const wrapper = document.createElement("div");
            wrapper.classList.add("platform-edit-field");
            const label = document.createElement("label");
            label.innerHTML = PlatformJS.escapeHtml(field.label) + (field.required ? ' <span class="req-dot">*</span>' : '');
            wrapper.appendChild(label);

            const current = row[field.name];
            PlatformJS.buildFieldInput(field, wrapper, { value: current, baseUrl: baseUrl });
            container.appendChild(wrapper);
        });

        const reasonWrapper = document.createElement("div");
        reasonWrapper.classList.add("platform-edit-field");
        const reasonLabel = document.createElement("label");
        reasonLabel.innerText = "Reason for this change (optional unless required)";
        reasonWrapper.appendChild(reasonLabel);
        const reasonInput = document.createElement("input");
        reasonInput.type = "text";
        reasonInput.classList.add("cell-input");
        reasonInput.id = "platform-edit-reason";
        reasonInput.placeholder = "Why is this changing?";
        reasonWrapper.appendChild(reasonInput);
        container.appendChild(reasonWrapper);
    }

    function submitEdit() {
        document.querySelectorAll(".cell-input").forEach(PlatformJS.clearCellError);
        const payload = {};
        layout.fields.forEach(field => {
            const el = document.querySelector(`[name="${field.name}"]`);
            if (!el) return;
            let val = el.value;
            if (field.type === "number" && val !== "") { val = parseFloat(val); }
            if (field.type === "multi_select") {
                val = Array.from(el.selectedOptions).map(o => o.value);
            } else if (field.type === "multi_reference" || field.type === "multi_polymorphic_reference") {
                val = val.split(",").map(s => s.trim()).filter(s => s.length > 0);
            }
            payload[field.name] = val;
        });

        const msg = document.getElementById("status-message");
        msg.className = "status-msg";
        msg.innerText = "Saving...";
        msg.style.display = "block";

        const reasonEl = document.getElementById("platform-edit-reason");
        const reasonParam = reasonEl.value ? `&reason=${encodeURIComponent(reasonEl.value)}` : "";
        PlatformJS.postJSON(`${baseUrl}/api/update?type=${encodeURIComponent(entityType)}&entity_id=${encodeURIComponent(entityId)}${reasonParam}`, payload)
        .then(data => {
            if (data.success) {
                window.location.href = `${baseUrl}/detail?type=${encodeURIComponent(entityType)}&entity_id=${encodeURIComponent(entityId)}`;
            } else {
                msg.className = "status-msg error";
                msg.innerText = "Save failed. Please check highlighted errors below.";
                if (data.issues && data.issues.length > 0) {
                    data.issues.forEach(issue => {
                        if (issue.field) { highlightError(issue.field, issue.message); }
                        else { msg.innerText = issue.message; }
                    });
                }
            }
        })
        .catch(err => {
            console.error("Save error", err);
            msg.className = "status-msg error";
            msg.innerText = "An unexpected error occurred while saving.";
        });
    }

    buildFields();
    document.getElementById("btn-save").addEventListener("click", submitEdit);
})();

