(() => {
    "use strict";

    const app = document.getElementById("app");
    const garagePanel = document.querySelector(".garage-panel");
    const modeLabel = document.getElementById("modeLabel");
    const garageTitle = document.getElementById("garageTitle");
    const garageSubtitle = document.getElementById("garageSubtitle");
    const closeButton = document.getElementById("closeButton");
    const scopeTabs = document.getElementById("scopeTabs");
    const searchInput = document.getElementById("searchInput");
    const toolbar = document.querySelector(".toolbar");
    const sortSelect = document.getElementById("sortSelect");
    const sortControl = sortSelect.closest(".sort-control");
    const sortLabel = sortControl.querySelector(".sr-only");
    const vehicleCount = document.getElementById("vehicleCount");
    const imageSource = document.getElementById("imageSource");
    const vehicleList = document.getElementById("vehicleList");
    const emptyState = document.getElementById("emptyState");
    const emptyTitle = document.getElementById("emptyTitle");
    const emptyMessage = document.getElementById("emptyMessage");
    const clearSearchButton = document.getElementById("clearSearchButton");
    const busyLayer = document.getElementById("busyLayer");
    const busyLabel = document.getElementById("busyLabel");

    const defaultLabels = Object.freeze({
        search: "Search by vehicle, model, or plate",
        empty: "No vehicles are available.",
        fuel: "Fuel",
        engine: "Engine",
        body: "Body",
        close: "Close garage",
        impoundReason: "Reason",
        impoundFee: "Release fee",
        impoundedBy: "Impounded by",
        impoundedAt: "Impounded at",
        impoundHold: "Authority hold",
        impoundHoldDescription: "This vehicle is on an authority hold and cannot be recovered here.",
        vehicleSingular: "vehicle",
        vehiclePlural: "vehicles",
        filteredCount: "{shown} of {total} vehicles",
        unavailableTitle: "Garage unavailable",
        noResultsTitle: "No vehicles found",
        noResultsMessage: "Try another vehicle name, plate, or category.",
        noImpoundedTitle: "No impounded vehicles",
        noStoredTitle: "No vehicles stored here",
        modeImpound: "Vehicle impound",
        modeGarage: "Vehicle garage",
        sortVehicles: "Sort vehicles",
        sortStatus: "Sort: Status",
        sortNameAsc: "Name A–Z",
        sortNameDesc: "Name Z–A",
        sortFuelDesc: "Fuel: High–low",
        sortFuelAsc: "Fuel: Low–high",
        sortImpoundedDesc: "Newest impounded",
        sortImpoundedAsc: "Oldest impounded",
        sortFeeDesc: "Fee: High–low",
        sortFeeAsc: "Fee: Low–high",
    });

    const state = {
        open: false,
        closeRequested: false,
        busy: false,
        sessionId: null,
        title: "DRS Garages",
        subtitle: "Select a vehicle",
        mode: "garage",
        activeScope: null,
        scopes: [],
        vehicles: [],
        imageSourceLabel: "",
        error: "",
        labels: { ...defaultLabels },
    };

    const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
    const asText = (value, fallback = "") => {
        if (typeof value === "string") return value.trim() || fallback;
        if (typeof value === "number" && Number.isFinite(value)) return String(value);
        return fallback;
    };

    const clampPercent = (value) => {
        const numeric = Number(value);
        if (!Number.isFinite(numeric)) return null;
        const percent = numeric > 100 ? numeric / 10 : numeric;
        return Math.round(Math.max(0, Math.min(100, percent)));
    };

    const normalizeMoney = (value) => {
        const numeric = Number(value);
        if (!Number.isFinite(numeric)) return null;
        return Math.max(0, Math.floor(numeric));
    };

    const normalizeTimestamp = (value) => {
        const numeric = Number(value);
        if (!Number.isFinite(numeric) || numeric < 1) return null;
        return Math.floor(numeric);
    };

    const formatMoney = (value) => `$${Math.max(0, value).toLocaleString()}`;

    const formatTimestamp = (value) => {
        if (!value) return "";
        const date = new Date(value * 1000);
        if (Number.isNaN(date.getTime())) return "";

        try {
            return new Intl.DateTimeFormat(undefined, {
                dateStyle: "medium",
                timeStyle: "short",
            }).format(date);
        } catch (_error) {
            return date.toLocaleString();
        }
    };

    const createElement = (tag, className, text) => {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
    };

    const getResourceName = () => {
        if (typeof window.GetParentResourceName === "function") {
            return window.GetParentResourceName();
        }
        return "drs_garages";
    };

    const postNui = async (route, payload) => {
        const response = await fetch(`https://${getResourceName()}/${route}`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify(payload),
        });

        if (!response.ok) {
            throw new Error(`NUI callback ${route} failed with ${response.status}`);
        }

        const result = await response.json().catch(() => ({ ok: true }));
        if (result && result.ok === false) {
            throw new Error(`NUI callback ${route} rejected the request`);
        }

        return result;
    };

    const normalizeScope = (scope, index) => {
        const source = scope && typeof scope === "object" ? scope : {};
        const id = source.id ?? `scope-${index}`;
        return {
            id,
            label: asText(source.label, `Scope ${index + 1}`),
        };
    };

    const defaultActionLabel = (kind) => {
        const value = asText(kind).toLowerCase();
        if (value.includes("locate") || value.includes("waypoint")) return "Locate";
        if (value.includes("retrieve") || value.includes("impound")) return "Retrieve";
        if (value.includes("disabled") || value.includes("unavailable")) return "Unavailable";
        return "Take out";
    };

    const normalizeCandidate = (candidate) => {
        if (typeof candidate !== "string") return null;
        const value = candidate.trim();
        if (!value || value.length > 2048) return null;

        if (/^(assets|images|html)\//i.test(value) && !value.includes("..")) {
            return value;
        }

        try {
            const url = new URL(value, window.location.href);
            const allowed = ["https:", "http:", "nui:", "blob:"];
            if (allowed.includes(url.protocol)) return value;
            if (url.protocol === "data:" && /^data:image\//i.test(value)) return value;
        } catch (_error) {
            return null;
        }

        return null;
    };

    const normalizeVehicle = (vehicle, index) => {
        const source = vehicle && typeof vehicle === "object" ? vehicle : {};
        const imageCandidates = Array.isArray(source.imageCandidates)
            ? source.imageCandidates.map(normalizeCandidate).filter(Boolean)
            : [];
        const actionKind = asText(source.actionKind ?? source.action, "spawn").toLowerCase();

        return {
            id: source.id ?? `vehicle-${index}`,
            name: asText(source.name, "Unknown vehicle"),
            brand: asText(source.brand),
            model: asText(source.model),
            plate: asText(source.plate, "NO PLATE"),
            status: asText(source.status, "unknown").toLowerCase(),
            statusLabel: asText(source.statusLabel, "Unknown"),
            fuel: clampPercent(source.fuel) ?? 0,
            engine: clampPercent(source.engine),
            body: clampPercent(source.body),
            classLabel: asText(source.classLabel),
            imageCandidates,
            actionLabel: asText(source.actionLabel, defaultActionLabel(actionKind)),
            actionKind,
            impoundReason: asText(source.impoundReason),
            impoundFee: normalizeMoney(source.impoundFee ?? source.price),
            impoundedBy: asText(source.impoundedBy),
            impoundedByJob: asText(source.impoundedByJob),
            impoundedAt: normalizeTimestamp(source.impoundedAt),
            impoundHold: Boolean(source.impoundHold),
            disabled: Boolean(source.disabled),
        };
    };

    const unwrapMessage = (message) => {
        if (!message || typeof message !== "object") return {};
        const nested = message.payload && typeof message.payload === "object"
            ? message.payload
            : message.data && typeof message.data === "object"
                ? message.data
                : null;
        return nested ? { ...message, ...nested } : message;
    };

    const applyPayload = (message, isOpen) => {
        const payload = unwrapMessage(message);

        if (isOpen) {
            state.sessionId = null;
            state.title = "DRS Garages";
            state.subtitle = "Select a vehicle";
            state.mode = "garage";
            state.activeScope = null;
            state.scopes = [];
            state.vehicles = [];
            state.imageSourceLabel = "";
            state.error = "";
            state.labels = { ...defaultLabels };
            searchInput.value = "";
            sortSelect.value = "status";
        }

        if (hasOwn(payload, "sessionId")) state.sessionId = payload.sessionId;
        if (hasOwn(payload, "title")) state.title = asText(payload.title, "DRS Garages");
        if (hasOwn(payload, "subtitle")) state.subtitle = asText(payload.subtitle, "Select a vehicle");
        if (hasOwn(payload, "mode")) state.mode = payload.mode === "impound" ? "impound" : "garage";
        if (hasOwn(payload, "activeScope")) state.activeScope = payload.activeScope;
        if (hasOwn(payload, "scopes")) {
            state.scopes = Array.isArray(payload.scopes) ? payload.scopes.map(normalizeScope) : [];
        }

        const vehiclePayload = hasOwn(payload, "vehicles") ? payload.vehicles : payload.items;
        if (vehiclePayload !== undefined) {
            state.vehicles = Array.isArray(vehiclePayload) ? vehiclePayload.map(normalizeVehicle) : [];
        }

        if (hasOwn(payload, "imageSourceLabel")) {
            state.imageSourceLabel = asText(payload.imageSourceLabel);
        }
        if (hasOwn(payload, "error")) state.error = asText(payload.error);
        if (payload.labels && typeof payload.labels === "object") {
            Object.keys(defaultLabels).forEach((key) => {
                if (hasOwn(payload.labels, key)) {
                    state.labels[key] = asText(payload.labels[key], defaultLabels[key]);
                }
            });
        }

        state.closeRequested = false;
        setBusy(false);
        render();
    };

    const setBusy = (busy, label) => {
        state.busy = Boolean(busy);
        busyLabel.textContent = asText(label, "Working…");
        busyLayer.classList.toggle("is-hidden", !state.busy);
        app.setAttribute("aria-busy", String(state.busy));
        vehicleList.setAttribute("aria-busy", String(state.busy));
        closeButton.disabled = false;
        searchInput.disabled = state.busy;
        sortSelect.disabled = state.busy || state.vehicles.length <= 1;
        scopeTabs.querySelectorAll("button").forEach((button) => {
            button.disabled = state.busy;
        });
        vehicleList.querySelectorAll("button").forEach((button) => {
            button.disabled = state.busy || button.dataset.itemDisabled === "true";
        });
    };

    const statusType = (status, disabled) => {
        if (disabled) return "unavailable";
        const value = asText(status).toLowerCase();
        if (value.includes("impound") || value.includes("seized")) return "impound";
        if (value.includes("out") || value.includes("active") || value.includes("street")) return "out";
        if (value.includes("garage") || value.includes("stored") || value.includes("available")) return "stored";
        if (value.includes("unavailable") || value.includes("disabled")) return "unavailable";
        return "unknown";
    };

    const statusRank = (vehicle) => {
        const type = statusType(vehicle.status, vehicle.disabled);
        return { stored: 0, out: 1, impound: 2, unknown: 3, unavailable: 4 }[type] ?? 3;
    };

    const renderSortOptions = () => {
        const previousValue = sortSelect.value;
        const options = state.mode === "impound"
            ? [
                ["impounded-desc", state.labels.sortImpoundedDesc],
                ["impounded-asc", state.labels.sortImpoundedAsc],
                ["fee-desc", state.labels.sortFeeDesc],
                ["fee-asc", state.labels.sortFeeAsc],
                ["name-asc", state.labels.sortNameAsc],
                ["name-desc", state.labels.sortNameDesc],
            ]
            : [
                ["status", state.labels.sortStatus],
                ["name-asc", state.labels.sortNameAsc],
                ["name-desc", state.labels.sortNameDesc],
                ["fuel-desc", state.labels.sortFuelDesc],
                ["fuel-asc", state.labels.sortFuelAsc],
            ];
        const selectedValue = options.some(([value]) => value === previousValue)
            ? previousValue
            : options[0][0];
        const fragment = document.createDocumentFragment();

        options.forEach(([value, label]) => {
            const option = createElement("option", "", label);
            option.value = value;
            fragment.append(option);
        });

        sortSelect.replaceChildren(fragment);
        sortSelect.value = selectedValue;
        sortLabel.textContent = state.labels.sortVehicles;
    };

    const getVisibleVehicles = () => {
        const query = searchInput.value.trim().toLocaleLowerCase();
        const visible = state.vehicles.filter((vehicle) => {
            if (!query) return true;
            return [
                vehicle.name,
                vehicle.brand,
                vehicle.model,
                vehicle.plate,
                vehicle.classLabel,
                vehicle.statusLabel,
                vehicle.impoundReason,
                vehicle.impoundedBy,
                vehicle.impoundedByJob,
            ].some((value) => asText(value).toLocaleLowerCase().includes(query));
        });

        const byName = (a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
        const byImpoundedAt = (a, b, newestFirst) => {
            const aTime = a.impoundedAt;
            const bTime = b.impoundedAt;
            if (aTime === null && bTime === null) return byName(a, b);
            if (aTime === null) return 1;
            if (bTime === null) return -1;
            const difference = newestFirst ? bTime - aTime : aTime - bTime;
            return difference || byName(a, b);
        };
        switch (sortSelect.value) {
            case "impounded-desc":
                visible.sort((a, b) => byImpoundedAt(a, b, true));
                break;
            case "impounded-asc":
                visible.sort((a, b) => byImpoundedAt(a, b, false));
                break;
            case "fee-desc":
                visible.sort((a, b) => (b.impoundFee ?? 0) - (a.impoundFee ?? 0) || byName(a, b));
                break;
            case "fee-asc":
                visible.sort((a, b) => (a.impoundFee ?? 0) - (b.impoundFee ?? 0) || byName(a, b));
                break;
            case "name-asc":
                visible.sort(byName);
                break;
            case "name-desc":
                visible.sort((a, b) => byName(b, a));
                break;
            case "fuel-desc":
                visible.sort((a, b) => b.fuel - a.fuel || byName(a, b));
                break;
            case "fuel-asc":
                visible.sort((a, b) => a.fuel - b.fuel || byName(a, b));
                break;
            default:
                visible.sort((a, b) => statusRank(a) - statusRank(b) || byName(a, b));
        }

        return visible;
    };

    const renderScopes = () => {
        const fragment = document.createDocumentFragment();

        state.scopes.forEach((scope) => {
            const button = createElement("button", "scope-tab", scope.label);
            button.type = "button";
            const active = String(scope.id) === String(state.activeScope);
            button.classList.toggle("is-active", active);
            button.setAttribute("aria-pressed", String(active));
            button.disabled = state.busy;
            button.addEventListener("click", () => requestScope(scope));
            fragment.append(button);
        });

        scopeTabs.replaceChildren(fragment);
        scopeTabs.classList.toggle("is-hidden", state.scopes.length < 2);
    };

    const makeMeter = (label, value) => {
        const condition = createElement("div", "condition");
        const heading = createElement("div", "condition-label");
        heading.append(createElement("span", "", label));
        heading.append(createElement("strong", "", `${value}%`));

        const meter = createElement("div", "meter");
        meter.setAttribute("role", "meter");
        meter.setAttribute("aria-label", label);
        meter.setAttribute("aria-valuemin", "0");
        meter.setAttribute("aria-valuemax", "100");
        meter.setAttribute("aria-valuenow", String(value));

        const fill = createElement("div", "meter-fill");
        fill.style.width = `${value}%`;
        if (value <= 25) fill.classList.add("meter-low");
        else if (value <= 55) fill.classList.add("meter-mid");
        meter.append(fill);
        condition.append(heading, meter);
        return condition;
    };

    const loadVehicleImage = (image, candidates, placeholder) => {
        let index = 0;

        const tryNext = () => {
            image.classList.remove("is-loaded");
            placeholder.classList.remove("is-replaced");
            if (index >= candidates.length) {
                image.removeAttribute("src");
                image.hidden = true;
                return;
            }
            image.hidden = false;
            image.src = candidates[index];
            index += 1;
        };

        image.addEventListener("load", () => {
            image.classList.add("is-loaded");
            placeholder.classList.add("is-replaced");
        });
        image.addEventListener("error", tryNext);
        tryNext();
    };

    const makeActionIcon = (kind) => {
        const namespace = "http://www.w3.org/2000/svg";
        const svg = document.createElementNS(namespace, "svg");
        svg.setAttribute("viewBox", "0 0 20 20");
        svg.setAttribute("aria-hidden", "true");

        const path = document.createElementNS(namespace, "path");
        const value = asText(kind).toLowerCase();
        if (value.includes("locate") || value.includes("waypoint")) {
            path.setAttribute("d", "M10 17s5-4.6 5-9a5 5 0 1 0-10 0c0 4.4 5 9 5 9Zm0-7.2A1.8 1.8 0 1 0 10 6.2a1.8 1.8 0 0 0 0 3.6Z");
        } else if (value.includes("retrieve") || value.includes("impound")) {
            path.setAttribute("d", "M4 10h12M10 4v12m-6.5-6A6.5 6.5 0 1 0 10 3.5 6.5 6.5 0 0 0 3.5 10Z");
        } else {
            path.setAttribute("d", "M3.5 12.5h13l-1-3.7a2.4 2.4 0 0 0-2.3-1.8H6.8a2.4 2.4 0 0 0-2.3 1.8l-1 3.7Zm2 0v2M14.5 12.5v2M6.5 10h1M12.5 10h1");
        }
        svg.append(path);
        return svg;
    };

    const makeVehicleCard = (vehicle) => {
        const card = createElement("article", "vehicle-card");
        if (vehicle.disabled) card.classList.add("is-disabled");
        const hasImpoundDetails = state.mode === "impound"
            && (vehicle.impoundReason || vehicle.impoundFee !== null || vehicle.impoundedBy || vehicle.impoundedAt || vehicle.impoundHold);
        if (hasImpoundDetails) card.classList.add("has-impound-details");

        const imageWrap = createElement("div", "vehicle-image");
        const placeholder = document.createElement("img");
        placeholder.className = "vehicle-placeholder";
        placeholder.src = "assets/vehicle-placeholder.svg";
        placeholder.alt = "";

        const photo = document.createElement("img");
        photo.className = "vehicle-photo";
        photo.alt = "";
        photo.loading = "lazy";
        photo.decoding = "async";
        loadVehicleImage(photo, vehicle.imageCandidates, placeholder);
        imageWrap.append(placeholder, photo);

        const details = createElement("div", "vehicle-details");
        const heading = createElement("div", "vehicle-heading");
        const nameWrap = createElement("div", "vehicle-name-wrap");
        nameWrap.append(createElement("span", "vehicle-brand", vehicle.brand || "Vehicle"));
        nameWrap.append(createElement("h2", "vehicle-name", vehicle.name));

        const type = statusType(vehicle.status, vehicle.disabled);
        const badge = createElement("span", `status-badge status-${type}`, vehicle.statusLabel);
        heading.append(nameWrap, badge);

        const meta = createElement("div", "vehicle-meta");
        meta.append(createElement("span", "plate", vehicle.plate));
        if (vehicle.classLabel) {
            meta.append(createElement("span", "meta-divider"));
            meta.append(createElement("span", "vehicle-class", vehicle.classLabel));
        }

        let impoundDetails = null;
        if (hasImpoundDetails) {
            impoundDetails = createElement("div", "impound-details");
            const summary = createElement("div", "impound-summary");
            if (vehicle.impoundReason || vehicle.impoundHold) {
                const reasonField = createElement("div", "impound-field impound-reason-field");
                const reason = createElement(
                    "p",
                    "impound-reason",
                    vehicle.impoundReason || state.labels.impoundHoldDescription,
                );
                reason.title = `${state.labels.impoundReason}: ${reason.textContent}`;
                reasonField.append(
                    createElement("span", "impound-field-label", state.labels.impoundReason),
                    reason,
                );
                summary.append(reasonField);
            } else {
                summary.classList.add("is-fee-only");
            }

            const feeText = vehicle.impoundHold
                ? state.labels.impoundHold
                : formatMoney(vehicle.impoundFee ?? 0);
            const fee = createElement("span", vehicle.impoundHold ? "impound-fee is-hold" : "impound-fee", feeText);
            fee.title = vehicle.impoundHold
                ? state.labels.impoundHoldDescription
                : `${state.labels.impoundFee}: ${feeText}`;
            const feeField = createElement("div", "impound-field impound-fee-field");
            feeField.append(
                createElement("span", "impound-field-label", state.labels.impoundFee),
                fee,
            );
            summary.append(feeField);

            const audit = createElement("dl", "impound-audit");
            const appendAuditItem = (label, value) => {
                const item = createElement("div", "impound-audit-item");
                const description = createElement("dd", "impound-audit-value", value);
                description.title = value;
                item.append(
                    createElement("dt", "impound-field-label", label),
                    description,
                );
                audit.append(item);
            };
            if (vehicle.impoundedBy) {
                const officer = vehicle.impoundedByJob
                    ? `${vehicle.impoundedBy} · ${vehicle.impoundedByJob}`
                    : vehicle.impoundedBy;
                appendAuditItem(state.labels.impoundedBy, officer);
            }
            const timestamp = formatTimestamp(vehicle.impoundedAt);
            if (timestamp) appendAuditItem(state.labels.impoundedAt, timestamp);

            impoundDetails.append(summary);
            if (audit.childElementCount) impoundDetails.append(audit);
        }

        const conditions = createElement("div", "condition-row");
        conditions.append(makeMeter(state.labels.fuel, vehicle.fuel));
        if (vehicle.engine !== null) conditions.append(makeMeter(state.labels.engine, vehicle.engine));
        if (vehicle.body !== null) conditions.append(makeMeter(state.labels.body, vehicle.body));
        details.append(heading, meta);
        if (impoundDetails) details.append(impoundDetails);
        details.append(conditions);

        const action = createElement("button", "vehicle-action");
        action.type = "button";
        action.dataset.itemDisabled = String(vehicle.disabled);
        action.disabled = state.busy || vehicle.disabled;
        const actionFee = state.mode === "impound" && vehicle.impoundFee !== null && !vehicle.impoundHold
            ? `, ${state.labels.impoundFee} ${formatMoney(vehicle.impoundFee)}`
            : "";
        action.setAttribute("aria-label", `${vehicle.actionLabel}: ${vehicle.name}, ${vehicle.plate}${actionFee}`);
        if (vehicle.actionKind.includes("locate") || vehicle.actionKind.includes("waypoint")) {
            action.classList.add("action-locate");
        } else if (vehicle.actionKind.includes("retrieve") || vehicle.actionKind.includes("impound")) {
            action.classList.add("action-retrieve");
        }
        action.append(makeActionIcon(vehicle.actionKind));
        action.append(createElement("span", "", vehicle.actionLabel));
        action.addEventListener("click", () => requestSelect(vehicle));

        card.append(imageWrap, details, action);
        return card;
    };

    const renderVehicles = () => {
        const visible = getVisibleVehicles();
        const fragment = document.createDocumentFragment();
        visible.forEach((vehicle) => fragment.append(makeVehicleCard(vehicle)));
        vehicleList.replaceChildren(fragment);

        const total = state.vehicles.length;
        const filtered = visible.length;
        const hideSort = total <= 1;
        garagePanel.classList.toggle("is-short-list", total > 0 && total <= 2 && !state.error);
        toolbar.classList.toggle("is-sort-hidden", hideSort);
        sortControl.classList.toggle("is-hidden", hideSort);
        sortSelect.disabled = state.busy || hideSort;
        const noun = total === 1 ? state.labels.vehicleSingular : state.labels.vehiclePlural;
        vehicleCount.textContent = filtered === total
            ? `${total} ${noun}`
            : state.labels.filteredCount
                .replace("{shown}", String(filtered))
                .replace("{total}", String(total));

        const hasSearch = searchInput.value.trim().length > 0;
        const showEmpty = filtered === 0 || Boolean(state.error);
        vehicleList.classList.toggle("is-hidden", showEmpty);
        emptyState.classList.toggle("is-hidden", !showEmpty);

        if (state.error) {
            emptyTitle.textContent = state.labels.unavailableTitle;
            emptyMessage.textContent = state.error;
            clearSearchButton.classList.add("is-hidden");
        } else if (hasSearch) {
            emptyTitle.textContent = state.labels.noResultsTitle;
            emptyMessage.textContent = state.labels.noResultsMessage;
            clearSearchButton.classList.remove("is-hidden");
        } else {
            emptyTitle.textContent = state.mode === "impound"
                ? state.labels.noImpoundedTitle
                : state.labels.noStoredTitle;
            emptyMessage.textContent = state.labels.empty;
            clearSearchButton.classList.add("is-hidden");
        }
    };

    const render = () => {
        app.classList.toggle("is-impound-mode", state.mode === "impound");
        modeLabel.textContent = state.mode === "impound" ? state.labels.modeImpound : state.labels.modeGarage;
        garageTitle.textContent = state.title;
        garageSubtitle.textContent = state.subtitle;
        searchInput.placeholder = state.labels.search;
        closeButton.setAttribute("aria-label", state.labels.close);
        imageSource.textContent = state.imageSourceLabel;
        imageSource.classList.toggle("is-hidden", !state.imageSourceLabel);
        renderSortOptions();
        renderScopes();
        renderVehicles();
        setBusy(state.busy, busyLabel.textContent);
    };

    const show = () => {
        state.open = true;
        state.closeRequested = false;
        app.classList.remove("is-hidden");
        app.setAttribute("aria-hidden", "false");
        window.requestAnimationFrame(() => app.focus({ preventScroll: true }));
    };

    const hide = () => {
        state.open = false;
        state.busy = false;
        app.classList.add("is-hidden");
        app.setAttribute("aria-hidden", "true");
        busyLayer.classList.add("is-hidden");
        vehicleList.replaceChildren();
        scopeTabs.replaceChildren();
        searchInput.value = "";
        app.blur();
    };

    const requestSelect = (vehicle) => {
        if (!state.open || state.busy || vehicle.disabled) return;
        setBusy(true, vehicle.actionKind.includes("locate") ? "Locating vehicle…" : "Preparing vehicle…");
        postNui("select", { sessionId: state.sessionId, itemId: vehicle.id }).catch(() => {
            if (state.open) setBusy(false);
        });
    };

    const requestScope = (scope) => {
        if (!state.open || state.busy || String(scope.id) === String(state.activeScope)) return;
        const previousScope = state.activeScope;
        state.activeScope = scope.id;
        renderScopes();
        setBusy(true, "Loading vehicles…");
        postNui("scope", { sessionId: state.sessionId, scope: scope.id }).catch(() => {
            if (!state.open) return;
            state.activeScope = previousScope;
            renderScopes();
            setBusy(false);
        });
    };

    const requestClose = () => {
        if (!state.open || state.closeRequested) return;
        state.closeRequested = true;
        const sessionId = state.sessionId;
        hide();
        postNui("close", { sessionId }).catch(() => {});
    };

    closeButton.addEventListener("click", requestClose);
    clearSearchButton.addEventListener("click", () => {
        searchInput.value = "";
        renderVehicles();
        searchInput.focus();
    });
    searchInput.addEventListener("input", renderVehicles);
    sortSelect.addEventListener("change", renderVehicles);

    document.addEventListener("keydown", (event) => {
        if (!state.open) return;
        if (event.key === "Escape") {
            event.preventDefault();
            requestClose();
            return;
        }
        if (event.key === "/" && document.activeElement !== searchInput) {
            event.preventDefault();
            searchInput.focus();
        }
    });

    window.addEventListener("message", (event) => {
        const message = event.data;
        if (!message || typeof message !== "object") return;
        const payload = unwrapMessage(message);
        const action = asText(message.action).toLowerCase();

        if (action === "ping") {
            postNui("ready", {}).catch(() => {});
            return;
        }

        if (action === "open") {
            applyPayload(message, true);
            show();
            return;
        }

        if (action === "update") {
            if (!state.open) show();
            applyPayload(message, false);
            return;
        }

        if (action === "loading") {
            if (hasOwn(payload, "sessionId") && payload.sessionId !== state.sessionId) return;
            if (hasOwn(payload, "scope")) state.activeScope = payload.scope;
            renderScopes();
            const loading = hasOwn(payload, "loading") ? Boolean(payload.loading) : true;
            setBusy(loading, asText(payload.label ?? payload.message, "Loading vehicles…"));
            return;
        }

        if (action === "busy") {
            if (hasOwn(payload, "sessionId") && payload.sessionId !== state.sessionId) return;
            const busy = hasOwn(payload, "busy")
                ? Boolean(payload.busy)
                : hasOwn(payload, "value")
                    ? Boolean(payload.value)
                    : true;
            setBusy(busy, asText(payload.label ?? payload.message, "Working…"));
            return;
        }

        if (action === "close") {
            if (hasOwn(payload, "sessionId") && payload.sessionId !== state.sessionId) return;
            hide();
        }
    });

    postNui("ready", {}).catch(() => {});
})();
