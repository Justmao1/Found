'use strict';

(() => {
  const $ = (id) => document.getElementById(id);
  const JOURNAL_KEY = 'found.admin.manualOpen.v1';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const SLOT_IDS = new Set(['01', '02', '03', '04']);
  const OP_STATES = new Set(['actuating', 'awaiting_confirmation', 'uncertain', 'completed']);
  const LABELS = {
    free: "Available", reserved: "Awaiting deposit", occupied: "Occupied", retrieving: "Collection in progress", recovery: "Needs inspection",
    maintenance: "Maintenance", stored: "Stored", collected: "Collected", recorded: "Recorded",
    deposit_pending: "Awaiting deposit", retrieval_pending: "Awaiting collection", actuating: "Opening request in progress",
    awaiting_confirmation: "Awaiting confirmation", uncertain: "Outcome unknown", completed: "Completed"
  };
  const state = {
    authenticated: false, epoch: 0, overview: null, lastSuccess: 0, online: false,
    pollTimer: null, pollBusy: false, mutationBusy: false, pending: null, pendingOperation: null,
    pendingMessage: '', journalError: '', items: [], itemTotal: 0, offset: 0, limit: 25,
    query: '', status: '', itemSequence: 0, itemController: null, itemBusy: false,
    inventoryFingerprint: '', inventoryLoadedAt: 0, selectedItem: null, dialog: null, toastTimer: null
  };

  function text(id, value) { $(id).textContent = value == null ? '—' : String(value); }
  function finite(value) { return typeof value === 'number' && Number.isFinite(value); }
  function numeric(value, decimals = 0) { return finite(value) ? value.toLocaleString('en-GB', { maximumFractionDigits: decimals }) : "Not available"; }
  function percent(value) { return finite(value) ? numeric(value, 1) + '%' : "Not available"; }
  function bytes(value) {
    if (!finite(value) || value < 0) return "Not available";
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i += 1; }
    return numeric(value, i ? 1 : 0) + ' ' + units[i];
  }
  function rate(value) { return finite(value) ? bytes(value) + '/s' : "Not available"; }
  function timestamp(value) {
    if (value == null) return "Time not available";
    const date = new Date(typeof value === 'number' ? value * 1000 : value);
    if (!Number.isFinite(date.getTime())) return "Time not available";
    return date.toLocaleString('en-GB', { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });
  }
  function uptime(value) {
    if (!finite(value) || value < 0) return "Uptime not available";
    const days = Math.floor(value / 86400);
    const hours = Math.floor(value % 86400 / 3600);
    const minutes = Math.floor(value % 3600 / 60);
    return "Uptime " + (days ? days + " d " : '') + (hours ? hours + " h " : '') + minutes + " min";
  }
  function title(item) { return item?.recognition?.tags?.[0] || "Unidentified item"; }
  function label(value) { return LABELS[value] || "Unknown state"; }
  function tone(value) {
    if (['free', 'stored', 'completed'].includes(value)) return 'success';
    if (['uncertain', 'recovery'].includes(value)) return 'danger';
    if (['reserved', 'retrieving', 'maintenance', 'actuating', 'awaiting_confirmation', 'deposit_pending', 'retrieval_pending'].includes(value)) return 'warning';
    return 'neutral';
  }
  function badge(element, value, caption) {
    element.className = 'badge ' + tone(value);
    element.textContent = caption || label(value);
  }
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#i-' + name);
    svg.setAttribute('aria-hidden', 'true');
    svg.append(use);
    return svg;
  }
  function element(tag, className, content) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content != null) node.textContent = content;
    return node;
  }
  function button(caption, action, data = {}) {
    const node = element('button', 'button small', caption);
    node.type = 'button'; node.dataset.action = action;
    Object.entries(data).forEach(([key, value]) => { node.dataset[key] = String(value); });
    return node;
  }
  function safeID(value) {
    if (typeof value !== 'string' || !UUID.test(value)) throw new Error("The server returned an invalid record ID.");
    return value.toLowerCase();
  }
  function imageURL(item) {
    if (!item || !UUID.test(item.id) || typeof item.image_url !== 'string') return null;
    try {
      const url = new URL(item.image_url, location.origin);
      return url.origin === location.origin && !url.username && !url.password && !url.search && !url.hash &&
        url.pathname.toLowerCase() === '/images/' + item.id.toLowerCase() ? url.href : null;
    } catch { return null; }
  }
  function photo(container, item) {
    let image = container.querySelector('img');
    let fallback = container.querySelector('svg');
    if (!image) {
      image = document.createElement('img'); image.hidden = true;
      fallback = icon('box'); container.append(image, fallback);
      image.addEventListener('error', () => { image.hidden = true; fallback.style.display = ''; });
      image.addEventListener('load', () => { image.hidden = false; fallback.style.display = 'none'; });
    }
    const url = imageURL(item);
    image.alt = item ? title(item) + " photo" : '';
    if (url) {
      if (image.getAttribute('src') !== url) { image.hidden = true; fallback.style.display = ''; image.src = url; }
    } else { image.removeAttribute('src'); image.hidden = true; fallback.style.display = ''; }
  }
  function keyed(container, entries, key, create, update) {
    const current = new Map(Array.from(container.children).filter((node) => node.dataset.key).map((node) => [node.dataset.key, node]));
    const wanted = new Set();
    entries.forEach((entry, index) => {
      const id = String(key(entry)); wanted.add(id);
      let node = current.get(id);
      if (!node) { node = create(entry); node.dataset.key = id; }
      update(node, entry);
      const at = container.children[index];
      if (at !== node) container.insertBefore(node, at || null);
    });
    Array.from(container.children).forEach((node) => { if (!wanted.has(node.dataset.key)) node.remove(); });
  }
  function toast(message) {
    text('toast', message); $('toast').hidden = false;
    clearTimeout(state.toastTimer); state.toastTimer = setTimeout(() => { $('toast').hidden = true; }, 6500);
  }
  function fresh() { return state.authenticated && state.online && state.overview && Date.now() - state.lastSuccess < 10000; }
  function canAct() { return fresh() && !state.mutationBusy; }

  class RequestError extends Error {
    constructor(message, status = 0) { super(message); this.status = status; }
  }
  async function api(path, options = {}) {
    const controller = options.controller || new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    const config = { method: options.method || 'GET', credentials: 'same-origin', cache: 'no-store', signal: controller.signal, headers: { Accept: 'application/json' } };
    if (config.method === 'POST') {
      config.headers['Content-Type'] = 'application/json';
      config.headers['X-Requested-With'] = 'lost-found-box';
      config.body = JSON.stringify(options.body || {});
    }
    try {
      const response = await fetch(path, config);
      let data;
      try { data = await response.json(); } catch { throw new RequestError("The server response could not be read. Check the connection.", response.status); }
      if (!response.ok) {
        if (response.status === 401 && state.authenticated) setAuthenticated(false, "Your session has expired. Sign in again.");
        throw new RequestError(typeof data.error === 'string' ? data.error : "Request failed (" + response.status + ').', response.status);
      }
      return data;
    } catch (error) {
      if (error instanceof RequestError) throw error;
      throw new RequestError(error.name === 'AbortError' ? "The request timed out or was canceled. Check its status before continuing." : "Unable to reach the station. Check the network.");
    } finally { clearTimeout(timeout); }
  }

  function readJournal() {
    state.journalError = '';
    try {
      const raw = localStorage.getItem(JOURNAL_KEY);
      if (!raw) return null;
      const request = JSON.parse(raw);
      if (!UUID.test(request.request_id) || !SLOT_IDS.has(request.compartment_id) || typeof request.reason !== 'string' || !request.reason.trim() || request.reason.length > 200) {
        throw new Error("The saved opening request could not be read. Keep the browser data and ask staff to check it before attempting another opening.");
      }
      return Object.freeze({ request_id: request.request_id, compartment_id: request.compartment_id, reason: request.reason });
    } catch (error) {
      state.journalError = error.message || "The browser could not read the saved request.";
      return null;
    }
  }
  function saveJournal(payload) {
    const existing = localStorage.getItem(JOURNAL_KEY);
    if (existing) throw new Error("An opening request still needs checking. Resolve it first.");
    const encoded = JSON.stringify(payload);
    localStorage.setItem(JOURNAL_KEY, encoded);
    if (localStorage.getItem(JOURNAL_KEY) !== encoded) throw new Error("The opening request could not be saved reliably. Nothing was sent.");
    state.pending = Object.freeze({ ...payload });
    state.pendingOperation = null; state.pendingMessage = "Request saved. Sending now.";
    renderJournal();
  }
  function clearJournal(id) {
    if (state.pending?.request_id !== id) return;
    try {
      const stored = localStorage.getItem(JOURNAL_KEY);
      if (stored && JSON.parse(stored).request_id !== id) throw new Error("The saved request was updated in another tab. Refresh to check its status.");
      localStorage.removeItem(JOURNAL_KEY);
      state.pending = null; state.pendingOperation = null; state.pendingMessage = ''; state.journalError = '';
    } catch (error) { state.pendingMessage = "The operation is complete, but its local record could not be cleared: " + error.message; }
    renderJournal();
  }
  function validManual(operation, expected) {
    if (!operation || !UUID.test(operation.id) || !SLOT_IDS.has(operation.compartment_id) || !OP_STATES.has(operation.state)) throw new Error("The opening response is incomplete. Check the original request instead of creating another.");
    if (expected && (operation.id !== expected.request_id || operation.compartment_id !== expected.compartment_id)) throw new Error("The opening response does not match the request. Ask staff to inspect it.");
    return operation;
  }
  function observeManual(operation) {
    if (!state.pending || operation.id !== state.pending.request_id) return;
    state.pendingOperation = validManual(operation, state.pending);
    state.pendingMessage = "Server status: " + label(operation.state) + (operation.error ? ' · ' + operation.error : '');
    if (operation.state === 'completed') clearJournal(operation.id);
    renderJournal();
  }
  function renderJournal() {
    const visible = state.pending || state.journalError;
    $('pending-journal').hidden = !visible;
    if (!visible) return;
    text('pending-description', state.pending ? "Compartment " + state.pending.compartment_id + ' · ' + state.pending.reason : state.journalError);
    text('pending-status', state.pendingMessage || "Refreshing or signing in only checks status. It never opens the compartment again automatically.");
    $('pending-check').hidden = !state.pending;
    $('pending-retry').hidden = !state.pending || !!state.pendingOperation;
    updateControls();
  }
  async function recoverPending() {
    const request = state.pending;
    if (!request || !state.authenticated) return;
    const epoch = state.epoch;
    try {
      const result = await api('/api/admin/manual-open/' + safeID(request.request_id));
      if (epoch !== state.epoch || state.pending?.request_id !== request.request_id) return;
      observeManual(validManual(result.operation, request));
    } catch (error) {
      if (epoch !== state.epoch) return;
      state.pendingMessage = error.status === 404 ? "The server has no record of this request yet. Check the compartment before retrying the same request." : error.message;
      renderJournal();
    }
  }

  function setAuthenticated(authenticated, message) {
    state.epoch += 1; state.authenticated = authenticated;
    clearTimeout(state.pollTimer); state.pollTimer = null;
    $('dashboard').hidden = !authenticated; $('login-view').hidden = authenticated;
    if (!authenticated) {
      state.online = false; state.overview = null; state.lastSuccess = 0; state.inventoryFingerprint = ''; state.inventoryLoadedAt = 0;
      state.itemController?.abort(); state.items = []; state.selectedItem = null;
      if ($('action-dialog').open) $('action-dialog').close();
      if ($('item-dialog').open) $('item-dialog').close();
      state.dialog = null;
      if (message) { text('login-status', message); $('login-status').classList.add('error'); }
      $('login-submit').disabled = false;
    } else {
      state.pending = readJournal(); renderJournal();
      refreshDashboard(); recoverPending();
    }
  }
  async function checkSession() {
    try {
      const result = await api('/api/admin/session');
      if (result.authenticated) { setAuthenticated(true); return; }
      text('login-status', result.configured ? "Use the administrator password configured for this station." : "An administrator password has not been configured. Complete setup on the Raspberry Pi first.");
      $('login-submit').disabled = !result.configured;
      $('password').disabled = !result.configured;
    } catch (error) {
      text('login-status', error.message + " You can try signing in again.");
      $('login-status').classList.add('error'); $('login-submit').disabled = false;
    }
  }
  function schedulePoll() {
    clearTimeout(state.pollTimer);
    if (state.authenticated && !document.hidden) state.pollTimer = setTimeout(refreshDashboard, 3000);
  }
  async function refreshDashboard() {
    if (!state.authenticated || document.hidden || state.pollBusy) return;
    state.pollBusy = true;
    const epoch = state.epoch;
    updateControls();
    try {
      const data = await api('/api/admin/overview');
      if (epoch !== state.epoch || !state.authenticated) return;
      if (!data.device || !data.metrics || !data.lockers || !Array.isArray(data.lockers.compartments)) throw new Error("Station data is incomplete. Check the server version.");
      state.overview = data; state.online = true; state.lastSuccess = Date.now();
      renderOverview(data);
      const fingerprint = JSON.stringify(data.inventory);
      if (!state.itemBusy && (fingerprint !== state.inventoryFingerprint || Date.now() - state.inventoryLoadedAt >= 15000)) {
        state.inventoryFingerprint = fingerprint;
        await loadItems();
      }
    } catch (error) {
      if (epoch === state.epoch) {
        state.online = false;
        text('connection-notice', "Connection lost. Showing the last received data. Opening and state changes are paused. " + error.message);
        $('connection-notice').hidden = false;
      }
    } finally {
      state.pollBusy = false; updateFreshness(); updateControls(); schedulePoll();
    }
  }
  function updateFreshness() {
    if (!state.authenticated) return;
    const age = state.lastSuccess ? Math.floor((Date.now() - state.lastSuccess) / 1000) : null;
    const current = fresh();
    $('freshness').className = 'freshness ' + (current ? 'live' : 'stale');
    text('freshness', current ? (age < 3 ? "Live" : age + " s ago") : (age == null ? "Not connected" : "Data is stale"));
    document.querySelector('.station-dot').classList.toggle('online', !!current);
    if (current) $('connection-notice').hidden = true;
    else if (state.overview && state.online) {
      text('connection-notice', "Fresh data has not arrived. Opening and state changes are paused until the connection recovers.");
      $('connection-notice').hidden = false;
    }
    updateControls();
  }

  function renderOverview(data) {
    const { device, metrics, services = {}, inventory = {}, lockers } = data;
    const slots = lockers.compartments;
    const manual = (data.manual_operations || []).filter((operation) => operation.state !== 'completed');
    const visitor = (lockers.operations || []).filter((operation) => operation.state !== 'completed');
    text('sidebar-host', device.hostname || device.name || 'Found Station');
    text('sidebar-address', Array.isArray(device.ip_addresses) && device.ip_addresses.length ? device.ip_addresses.join(' · ') : "IP address not available");
    text('device-summary', [device.name || 'Found Station', device.model || device.platform, device.hostname].filter(Boolean).join(' · '));
    const driverName = lockers.driver === 'gpio' ? "Live GPIO control" : lockers.driver === 'simulated' ? "Simulation · No hardware" : "Locks disabled";
    badge($('driver-badge'), lockers.enabled ? 'free' : 'recorded', driverName);
    text('count-stored', numeric(inventory.stored)); text('count-collected', numeric(inventory.collected));
    text('count-free', slots.filter((slot) => slot.state === 'free').length); text('count-capacity', ' / ' + slots.length);
    text('count-attention', visitor.length + manual.length); text('nav-slot-count', slots.length);
    text('cpu-value', percent(metrics.cpu_percent)); text('memory-value', percent(metrics.memory?.percent));
    text('temperature-value', finite(metrics.cpu_temperature_celsius) ? numeric(metrics.cpu_temperature_celsius, 1) + '°C' : "Not available");
    text('disk-value', percent(metrics.disk?.percent));
    text('load-value', "Load " + (Array.isArray(metrics.load_average) && metrics.load_average.length ? metrics.load_average.map((v) => numeric(v, 2)).join(' / ') : "Not available"));
    text('memory-detail', bytes(metrics.memory?.used_bytes) + ' / ' + bytes(metrics.memory?.total_bytes));
    text('disk-detail', bytes(metrics.disk?.used_bytes) + ' / ' + bytes(metrics.disk?.total_bytes));
    $('disk-meter').style.width = finite(metrics.disk?.percent) ? Math.min(100, Math.max(0, metrics.disk.percent)) + '%' : '0';
    text('system-uptime', uptime(device.system_uptime_seconds));
    const history = Array.isArray(metrics.history) ? metrics.history : [];
    chart($('cpu-chart'), history, 'cpu_percent', 100); chart($('memory-chart'), history, 'memory_percent', 100);
    chart($('temperature-chart'), history, 'cpu_temperature_celsius'); chart($('network-chart'), history, 'rx_bytes_per_second');
    text('api-status', services.api === 'online' ? "Online" : "Unavailable"); text('database-status', services.database === 'online' ? "Online" : "Unavailable");
    text('tls-status', services.tls_enabled ? 'HTTPS' : "HTTP · Local connection");
    text('ai-status', services.recognition?.configured ? "Configured" : "Not configured");
    text('queue-status', numeric(services.recognition?.queue_depth) + " queued / " + numeric(services.recognition?.pending_count) + " pending");
    badge($('service-health'), services.api === 'online' && services.database === 'online' ? 'free' : 'recovery', services.api === 'online' && services.database === 'online' ? "All services online" : "Needs attention");
    text('network-rate', '↓ ' + rate(metrics.network?.rx_bytes_per_second) + '    ↑ ' + rate(metrics.network?.tx_bytes_per_second));
    text('network-total', "Total received ↓ " + bytes(metrics.network?.rx_bytes) + ' / ↑ ' + bytes(metrics.network?.tx_bytes));
    text('device-info', (device.platform || "System information not available") + " · Service " + uptime(device.service_uptime_seconds));
    text('footer-time', "Server update: " + timestamp(data.generated_at));
    keyed($('slot-grid'), slots, (slot) => slot.id, createSlot, updateSlot);
    const recoveries = manual.map((op) => ({ ...op, recoveryKind: 'manual' })).concat(visitor.map((op) => ({ ...op, recoveryKind: 'visitor' })));
    $('recovery-panel').hidden = !recoveries.length; text('recovery-count', recoveries.length + " pending");
    keyed($('recovery-list'), recoveries, (op) => op.recoveryKind + '-' + op.id, createRecovery, updateRecovery);
    if (state.pending) {
      const observed = (data.manual_operations || []).find((op) => op.id === state.pending.request_id);
      if (observed) observeManual(observed);
    }
    const activity = Array.isArray(data.activity) ? data.activity : [];
    keyed($('activity-list'), activity, (entry) => entry.type + '-' + entry.id, createActivity, updateActivity);
    $('activity-empty').hidden = !!activity.length; text('activity-empty', "No operations recorded yet."); text('activity-count', "Recent events: " + activity.length);
  }

  function chart(container, history, key, ceiling) {
    const values = history.map((point) => ({ at: Date.parse(point.at), value: point[key] }));
    const valid = values.filter((point) => Number.isFinite(point.at) && finite(point.value));
    if (valid.length < 2) {
      if (!container.querySelector('.chart-empty')) container.replaceChildren(element('span', 'chart-empty', "Waiting for more samples"));
      return;
    }
    const start = Math.min(...valid.map((point) => point.at));
    const end = Math.max(...valid.map((point) => point.at));
    if (start === end) { container.replaceChildren(element('span', 'chart-empty', "Waiting for more samples")); return; }
    const max = ceiling || Math.max(1, ...valid.map((point) => point.value)) * 1.12;
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg'); svg.setAttribute('viewBox', '0 0 240 48'); svg.setAttribute('preserveAspectRatio', 'none');
    const baseline = document.createElementNS(ns, 'path'); baseline.setAttribute('d', 'M0 45H240'); baseline.setAttribute('stroke', '#e9eee8'); baseline.setAttribute('stroke-width', '1'); svg.append(baseline);
    let path = ''; let segment = false;
    values.forEach((point) => {
      if (!Number.isFinite(point.at) || !finite(point.value)) { segment = false; return; }
      const x = (point.at - start) / (end - start) * 240;
      const y = 43 - Math.min(max, Math.max(0, point.value)) / max * 38;
      path += (segment ? ' L' : ' M') + x.toFixed(2) + ' ' + y.toFixed(2); segment = true;
    });
    const line = document.createElementNS(ns, 'path'); line.setAttribute('d', path); line.setAttribute('fill', 'none'); line.setAttribute('stroke', '#6b9579'); line.setAttribute('stroke-width', '1.8'); line.setAttribute('vector-effect', 'non-scaling-stroke'); svg.append(line);
    svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', "Recent " + valid.length + " samples; latest value " + numeric(valid[valid.length - 1].value, 1));
    container.replaceChildren(svg);
  }
  function createSlot(slot) {
    const card = element('article', 'slot-card');
    const head = element('div', 'slot-head'); head.append(element('strong', 'slot-number'), element('span', 'badge'));
    const facts = element('div', 'slot-facts'); facts.append(element('span', 'slot-gpio'), element('span', 'slot-level'), element('span', '', "Door: unknown (no sensor)"));
    const open = button("Open manually", 'open-slot', { slot: slot.id, control: 'open' }); open.prepend(icon('door'));
    card.append(head, element('div', 'slot-visual'), element('h3', 'slot-title'), element('p', 'slot-subtitle'), facts, open, element('p', 'slot-detail'));
    return card;
  }
  function updateSlot(card, slot) {
    card.className = 'slot-card ' + (slot.state === 'free' ? 'free' : slot.state === 'occupied' ? 'occupied' : 'warning');
    card.querySelector('.slot-number').textContent = slot.id;
    badge(card.querySelector('.badge'), slot.state);
    photo(card.querySelector('.slot-visual'), slot.item);
    card.querySelector('.slot-title').textContent = slot.item ? title(slot.item) : slot.state === 'free' ? "Ready for an item" : "Physical check needed";
    card.querySelector('.slot-subtitle').textContent = slot.item ? (slot.item.recognition?.tags || []).slice(1, 3).join(' · ') || "No additional tags" : slot.state === 'free' ? "Available for a new item" : "Resolve the pending operation first";
    card.querySelector('.slot-gpio').textContent = 'GPIO ' + numeric(slot.gpio) + " · Physical pin " + numeric(slot.pin);
    card.querySelector('.slot-level').textContent = "GPIO level: " + (slot.output_level === 1 ? "High" : slot.output_level === 0 ? "Low" : "Not available");
    const remaining = slot.cooldown_remaining_seconds;
    card.querySelector('.slot-detail').textContent = finite(remaining) && remaining > 0 ? "Cooldown: " + Math.ceil(remaining) + " s remaining" : slot.state === 'maintenance' ? "Confirm unchanged contents after inspection" : '';
  }
  function createRecovery(op) {
    const row = element('div', 'recovery-row');
    const info = element('div', 'recovery-info');
    const heading = element('div', 'recovery-title'); heading.append(element('span'), element('span', 'badge'));
    info.append(heading, element('p'));
    const actions = element('div', 'recovery-actions');
    if (op.recoveryKind === 'manual') actions.append(button("Door closed, contents unchanged", 'confirm-manual', { id: op.id, control: 'manual-confirm' }));
    else {
      actions.append(button(op.kind === 'deposit' ? "Confirm item stored" : "Confirm item collected", 'resolve-visitor', { id: op.id, outcome: op.kind === 'deposit' ? 'stored' : 'collected', control: 'resolve' }));
      actions.append(button(op.kind === 'deposit' ? "Confirm compartment empty" : "Confirm item still inside", 'resolve-visitor', { id: op.id, outcome: op.kind === 'deposit' ? 'empty' : 'stored', control: 'resolve' }));
    }
    row.append(info, actions); return row;
  }
  function updateRecovery(row, op) {
    row.querySelector('.recovery-title>span').textContent = "Compartment " + op.compartment_id + ' · ' + (op.recoveryKind === 'manual' ? "Open manually" : op.kind === 'deposit' ? "Deposit" : "Collection");
    badge(row.querySelector('.badge'), op.state);
    row.querySelector('.recovery-info>p').textContent = op.error || op.reason || (op.state === 'actuating' ? "The opening request is still in progress. Wait for an update." : "Inspect the item and door, then select the matching outcome.");
  }
  function createActivity() {
    const row = element('div', 'activity-row');
    const detail = element('div', 'activity-text'); detail.append(element('strong'), element('p'));
    const meta = element('div', 'activity-meta'); meta.append(element('span', 'badge'), element('time'));
    row.append(element('span', 'activity-icon'), detail, meta); return row;
  }
  function updateActivity(row, entry) {
    row.querySelector('.activity-icon').replaceChildren(icon(entry.type === 'manual' ? 'door' : entry.type === 'retrieve' ? 'check' : 'box'));
    row.querySelector('.activity-text strong').textContent = "Compartment " + entry.compartment_id + ' · ' + (entry.type === 'manual' ? "Manual opening" : entry.type === 'retrieve' ? "Collect item" : "Store item");
    row.querySelector('.activity-text p').textContent = entry.error || entry.reason || (entry.item_id ? "Item ID " + entry.item_id.slice(0, 8) : "Operation ID " + String(entry.id).slice(0, 8));
    badge(row.querySelector('.badge'), entry.state); row.querySelector('time').textContent = timestamp(entry.created_at);
  }

  async function loadItems() {
    if (!state.authenticated) return;
    const sequence = ++state.itemSequence; const epoch = state.epoch;
    state.itemController?.abort(); const controller = new AbortController(); state.itemController = controller; state.itemBusy = true;
    updateControls();
    const query = new URLSearchParams({ q: state.query, status: state.status, offset: String(state.offset), limit: String(state.limit) });
    try {
      const result = await api('/api/admin/items?' + query, { controller });
      if (sequence !== state.itemSequence || epoch !== state.epoch) return;
      if (!Array.isArray(result.items) || !finite(result.total)) throw new Error("The inventory response is incomplete.");
      state.items = result.items; state.itemTotal = result.total;
      if (state.offset >= result.total && state.offset > 0) { state.offset = Math.max(0, Math.ceil(result.total / state.limit) - 1) * state.limit; await loadItems(); return; }
      state.inventoryLoadedAt = Date.now();
      keyed($('item-rows'), result.items, (item) => item.id, createItemRow, updateItemRow);
      text('inventory-total', "Records: " + result.total);
      $('inventory-empty').hidden = !!result.items.length; $('inventory-error').hidden = true;
      text('page-label', result.total ? "Showing " + (state.offset + 1) + '—' + (state.offset + result.items.length) + " of " + result.total : "0 items");
      if (state.selectedItem) {
        const selected = result.items.find((item) => item.id === state.selectedItem.id);
        if (selected) { state.selectedItem = selected; renderItemDetail(selected); }
      }
    } catch (error) {
      if (sequence !== state.itemSequence || epoch !== state.epoch) return;
      text('inventory-error', error.message + (state.items.length ? " Showing the previous records." : '')); $('inventory-error').hidden = false;
    } finally {
      if (sequence === state.itemSequence) { state.itemBusy = false; updateControls(); }
    }
  }
  function createItemRow(item) {
    const row = document.createElement('tr');
    const cell = document.createElement('td'); const content = element('div', 'item-cell');
    const words = document.createElement('div'); words.append(element('strong'), element('small'));
    content.append(element('div', 'item-thumb item-thumb-fallback'), words); cell.append(content);
    const status = document.createElement('td'); status.append(element('span', 'badge'));
    const actions = document.createElement('td'); const detail = button("View details", 'view-item', { id: item.id }); detail.className = 'text-button'; actions.append(detail);
    row.append(cell, element('td', 'item-slot'), status, element('td', 'item-date'), actions); return row;
  }
  function updateItemRow(row, item) {
    const thumb = row.querySelector('.item-thumb'); photo(thumb, item);
    row.querySelector('.item-cell strong').textContent = title(item);
    row.querySelector('.item-cell small').textContent = String(item.id).slice(0, 8) + ' · ' + (item.recognition_status === 'complete' ? "Tagged" : ['pending', 'processing'].includes(item.recognition_status) ? "Identifying" : "Tags not ready");
    row.querySelector('.item-slot').textContent = item.compartment_id || "Unassigned";
    badge(row.querySelector('.badge'), item.status); row.querySelector('.item-date').textContent = timestamp(item.created_at);
  }
  function showItem(item) {
    state.selectedItem = item; renderItemDetail(item); $('item-detail-error').hidden = true; $('item-dialog').showModal(); updateControls();
  }
  function renderItemDetail(item) {
    text('item-dialog-title', title(item));
    const url = imageURL(item); const image = $('item-detail-image');
    $('item-detail-placeholder').hidden = !!url; image.hidden = !url;
    if (url) { if (image.getAttribute('src') !== url) image.src = url; }
    else image.removeAttribute('src');
    image.alt = title(item) + " photo";
    const status = element('span', 'badge'); badge(status, item.status);
    $('item-detail-meta').replaceChildren(status, element('span', '', item.compartment_id ? "Compartment " + item.compartment_id : "No compartment assigned"), element('span', '', timestamp(item.created_at)));
    $('item-detail-tags').replaceChildren(...(Array.isArray(item.recognition?.tags) ? item.recognition.tags : []).map((tag) => element('span', 'tag', tag)));
    text('item-detail-note', item.note || "No additional notes.");
  }

  function currentSlot(id) { return state.overview?.lockers?.compartments?.find((slot) => slot.id === id); }
  function currentManual(id) { return state.overview?.manual_operations?.find((op) => op.id === id) || (state.pendingOperation?.id === id ? state.pendingOperation : null); }
  function currentVisitor(id) { return state.overview?.lockers?.operations?.find((op) => op.id === id); }
  function slotActuating(id) {
    return [...(state.overview?.manual_operations || []), ...(state.overview?.lockers?.operations || [])].some((op) => op.compartment_id === id && op.state === 'actuating');
  }
  function openAllowed(slot) {
    return canAct() && !!state.overview?.lockers?.enabled && !!slot && SLOT_IDS.has(slot.id) &&
      !state.pending && !state.journalError && slot.state !== 'maintenance' && !slotActuating(slot.id) &&
      !(finite(slot.cooldown_remaining_seconds) && slot.cooldown_remaining_seconds > 0) &&
      !(state.overview?.manual_operations || []).some((op) => op.state !== 'completed');
  }
  function updateControls() {
    $('refresh-button').disabled = state.pollBusy || state.mutationBusy;
    $('logout-button').disabled = state.mutationBusy;
    $('pending-check').disabled = !state.authenticated || state.mutationBusy || !state.pending;
    $('pending-retry').disabled = !canAct() || !state.pending;
    $('previous-page').disabled = state.itemBusy || state.offset <= 0;
    $('next-page').disabled = state.itemBusy || state.offset + state.limit >= state.itemTotal;
    const recognitionStatus = state.selectedItem?.recognition_status;
    text('retry-recognition', recognitionStatus === 'complete' ? "Tags ready" : ['pending', 'processing'].includes(recognitionStatus) ? "Identifying…" : "Retry recognition");
    $('retry-recognition').disabled = !canAct() || !state.selectedItem || !['incomplete', 'failed', 'disabled'].includes(recognitionStatus);
    document.querySelectorAll('[data-control]').forEach((control) => {
      if (control.dataset.control === 'open') control.disabled = !openAllowed(currentSlot(control.dataset.slot));
      else if (control.dataset.control === 'manual-confirm') {
        const op = currentManual(control.dataset.id); control.disabled = !canAct() || !op || !['awaiting_confirmation', 'uncertain'].includes(op.state);
      } else {
        const op = currentVisitor(control.dataset.id);
        control.disabled = !canAct() || !op || op.state === 'actuating' || currentSlot(op?.compartment_id)?.state === 'maintenance';
      }
    });
    if ($('action-dialog').open) {
      const dialog = state.dialog;
      let allowed = canAct();
      if (dialog?.type === 'open') allowed = openAllowed(currentSlot(dialog.slot));
      if (dialog?.type === 'retry') allowed = canAct() && state.pending?.request_id === dialog.request.request_id;
      if (dialog?.type === 'manual-confirm') allowed = canAct() && ['awaiting_confirmation', 'uncertain'].includes(currentManual(dialog.id)?.state);
      if (dialog?.type === 'resolve') allowed = canAct() && currentVisitor(dialog.id)?.state !== 'actuating' && currentSlot(dialog.slot)?.state !== 'maintenance';
      $('dialog-submit').disabled = !allowed;
      $('dialog-submit').setAttribute('aria-busy', String(state.mutationBusy));
      $('dialog-cancel').disabled = state.mutationBusy;
      $('action-dialog').querySelector('[data-close-dialog]').disabled = state.mutationBusy;
      $('open-reason').disabled = state.mutationBusy;
      $('physical-confirmed').disabled = state.mutationBusy;
    }
  }
  function requestDetails(values) {
    const list = element('dl', 'request-detail');
    values.forEach(([name, value]) => { list.append(element('dt', '', name), element('dd', '', String(value))); });
    return list;
  }
  function showAction(config) {
    if (!canAct()) { toast("Wait for fresh station data before continuing."); return; }
    state.dialog = config;
    text('dialog-title', config.title); text('dialog-description', config.description); text('dialog-submit', config.submit);
    $('dialog-icon').replaceChildren(icon(config.type === 'open' || config.type === 'retry' ? 'door' : 'check'));
    $('dialog-content').replaceChildren(...(config.details ? [requestDetails(config.details)] : []));
    $('reason-field').hidden = config.type !== 'open'; $('open-reason').value = ''; $('open-reason').required = config.type === 'open';
    $('physical-check').hidden = !config.check; $('physical-confirmed').checked = false; $('physical-confirmed').required = !!config.check;
    text('physical-check-label', config.check || ''); $('dialog-error').hidden = true;
    $('action-dialog').showModal(); updateControls();
    if (config.type === 'open') $('open-reason').focus();
  }
  function showOpen(slot) {
    if (!openAllowed(slot)) { toast("This compartment cannot be opened now. Check the connection, cooldown and pending operations."); return; }
    showAction({ type: 'open', slot: slot.id, title: "Open compartment " + slot.id, submit: "Confirm opening",
      description: "This sends one opening pulse and reserves the compartment for inspection. It does not mark the item as collected. After inspection, confirm that the door is closed and the contents are unchanged.",
      details: [["Current item", slot.item ? title(slot.item) : "No linked item"], ["Recorded state", label(slot.state)], ["Door state", "Unknown · No sensor; check in person"]] });
  }
  function showManualConfirmation(op) {
    if (!op) return;
    showAction({ type: 'manual-confirm', id: op.id, slot: op.compartment_id, title: "Finish inspecting compartment " + op.compartment_id, submit: "Confirm unchanged contents",
      description: "This restores the recorded state from before the manual opening. Any unfinished visitor operation must still be resolved separately. It does not mark an item as collected.",
      details: [["Reason for opening", op.reason || "Not available"]], check: "I have checked that the door is closed and the original contents are unchanged." });
  }
  function showResolution(op, outcome) {
    if (!op) return;
    const wording = outcome === 'stored' ? "the item is inside and the door is closed" : outcome === 'collected' ? "the item has been removed and the door is closed" : "the compartment is empty and the door is closed";
    showAction({ type: 'resolve', id: op.id, slot: op.compartment_id, outcome, title: "Inspect compartment " + op.compartment_id,
      submit: outcome === 'stored' ? "Confirm stored" : outcome === 'collected' ? "Confirm collected" : "Confirm empty and release",
      description: "Check the compartment in person first. This updates the storage record without sending an opening pulse. " + (outcome === 'stored' ? "The item will become available for collection." : "The compartment will become available for a new item."),
      check: "I have checked that " + wording + '.' });
  }
  function showRetry() {
    if (!state.pending) return;
    showAction({ type: 'retry', request: state.pending, title: "Retry opening compartment " + state.pending.compartment_id, submit: "Retry same request",
      description: "This uses the original request ID and reason. If the server already recorded it, no new pulse is sent. If it never arrived, retrying may send one opening pulse.",
      details: [["Original request ID", state.pending.request_id], ["Original reason", state.pending.reason]], check: "I have checked the compartment and confirmed it is safe to continue this request." });
  }
  function newUUID() {
    if (crypto.randomUUID) return crypto.randomUUID();
    const data = crypto.getRandomValues(new Uint8Array(16)); data[6] = (data[6] & 15) | 64; data[8] = (data[8] & 63) | 128;
    const hex = Array.from(data, (n) => n.toString(16).padStart(2, '0')).join('');
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
  }
  async function performAction(event) {
    event.preventDefault();
    const action = state.dialog;
    if (!action || state.mutationBusy || !canAct() || $('dialog-submit').disabled) return;
    if (action.check && !$('physical-confirmed').checked) { $('physical-confirmed').reportValidity(); return; }
    let payload;
    if (action.type === 'open') {
      const reason = $('open-reason').value.trim();
      if (!reason) { text('dialog-error', "Enter a reason for opening this compartment."); $('dialog-error').hidden = false; $('open-reason').focus(); return; }
      if (!openAllowed(currentSlot(action.slot))) return;
      payload = Object.freeze({ request_id: newUUID(), compartment_id: action.slot, reason });
      try { saveJournal(payload); } catch (error) { text('dialog-error', "Request not sent: " + error.message); $('dialog-error').hidden = false; return; }
    } else if (action.type === 'retry') {
      if (state.pending?.request_id !== action.request.request_id) { text('dialog-error', "The pending request has changed. Check its status again."); $('dialog-error').hidden = false; return; }
      payload = action.request;
    }
    state.mutationBusy = true; const epoch = state.epoch;
    text('dialog-submit', "Submitting…"); $('dialog-error').hidden = true; updateControls();
    try {
      if (payload) {
        const result = await api('/api/admin/manual-open', { method: 'POST', body: payload });
        if (epoch !== state.epoch) return;
        observeManual(validManual(result.operation, payload));
        state.inventoryFingerprint = '';
        toast(result.operation.state === 'completed' ? "The original request is already complete. No new opening pulse was sent." : "Opening request recorded. Inspect the compartment, then confirm its contents are unchanged.");
      } else if (action.type === 'manual-confirm') {
        const result = await api('/api/admin/manual-open/' + safeID(action.id) + '/confirm', { method: 'POST' });
        if (epoch !== state.epoch) return;
        const operation = validManual(result.operation);
        if (operation.id !== action.id || operation.state !== 'completed') throw new Error("Completion has not been confirmed. Check the operation status.");
        observeManual(operation); state.inventoryFingerprint = ''; toast("Contents confirmed unchanged. The previous compartment state has been restored.");
      } else {
        await api('/api/admin/locker-operations/' + safeID(action.id) + '/resolve', { method: 'POST', body: { outcome: action.outcome } });
        if (epoch !== state.epoch) return;
        state.inventoryFingerprint = ''; toast("Inspection outcome saved.");
      }
      if ($('action-dialog').open) $('action-dialog').close(); state.dialog = null;
    } catch (error) {
      if (epoch !== state.epoch) return;
      if (payload) {
        state.pendingMessage = error.message + " The original request is saved. Check its status; it will not retry automatically."; renderJournal();
        if ($('action-dialog').open) $('action-dialog').close(); state.dialog = null;
        toast("The opening outcome needs checking. Select “Check status”.");
      } else { text('dialog-error', error.message + " Completion is not confirmed. Check the status before continuing."); $('dialog-error').hidden = false; }
    } finally {
      state.mutationBusy = false;
      if (state.dialog) text('dialog-submit', state.dialog.submit);
      updateControls();
      if (epoch === state.epoch && state.authenticated) refreshDashboard();
    }
  }

  $('login-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if ($('login-submit').disabled) return;
    const password = $('password').value;
    $('password').value = ''; $('login-submit').disabled = true;
    text('login-status', "Signing in…"); $('login-status').classList.remove('error');
    try { const result = await api('/api/admin/login', { method: 'POST', body: { password } }); if (result.authenticated !== true) throw new Error("Sign-in was not confirmed."); setAuthenticated(true); }
    catch (error) { text('login-status', error.message); $('login-status').classList.add('error'); $('password').focus(); }
    finally { $('login-submit').disabled = false; }
  });
  $('logout-button').addEventListener('click', async () => {
    if (state.mutationBusy) return;
    state.mutationBusy = true; updateControls();
    try { await api('/api/admin/logout', { method: 'POST' }); setAuthenticated(false, "Signed out."); $('password').value = ''; }
    catch (error) { toast("Unable to confirm sign-out: " + error.message); }
    finally { state.mutationBusy = false; updateControls(); }
  });
  $('refresh-button').addEventListener('click', () => { state.inventoryFingerprint = ''; refreshDashboard(); });
  $('pending-check').addEventListener('click', async () => { $('pending-check').disabled = true; await recoverPending(); refreshDashboard(); updateControls(); });
  $('pending-retry').addEventListener('click', showRetry);
  $('action-form').addEventListener('submit', performAction);
  $('action-dialog').addEventListener('cancel', (event) => { if (state.mutationBusy) event.preventDefault(); else state.dialog = null; });
  document.querySelectorAll('[data-close-dialog]').forEach((node) => node.addEventListener('click', () => { if (!state.mutationBusy) { $('action-dialog').close(); state.dialog = null; } }));
  document.querySelectorAll('[data-close-item]').forEach((node) => node.addEventListener('click', () => { if (!state.mutationBusy) $('item-dialog').close(); }));
  $('item-dialog').addEventListener('cancel', (event) => { if (state.mutationBusy) event.preventDefault(); });
  $('item-detail-image').addEventListener('error', () => { $('item-detail-image').hidden = true; $('item-detail-placeholder').hidden = false; });
  document.addEventListener('click', (event) => {
    const control = event.target.closest('[data-action]');
    if (!control || control.disabled) return;
    try {
      switch (control.dataset.action) {
        case 'open-slot': showOpen(currentSlot(control.dataset.slot)); break;
        case 'confirm-manual': showManualConfirmation(currentManual(control.dataset.id)); break;
        case 'resolve-visitor': showResolution(currentVisitor(control.dataset.id), control.dataset.outcome); break;
        case 'view-item': { const item = state.items.find((entry) => entry.id === control.dataset.id); if (item) showItem(item); break; }
      }
    } catch (error) { toast(error.message); }
  });
  $('inventory-filter').addEventListener('submit', (event) => { event.preventDefault(); state.query = $('item-query').value.trim(); state.status = $('item-status').value; state.offset = 0; loadItems(); });
  $('item-status').addEventListener('change', () => $('inventory-filter').requestSubmit());
  $('item-query').addEventListener('search', () => $('inventory-filter').requestSubmit());
  $('previous-page').addEventListener('click', () => { if (state.offset > 0) { state.offset -= state.limit; loadItems(); } });
  $('next-page').addEventListener('click', () => { if (state.offset + state.limit < state.itemTotal) { state.offset += state.limit; loadItems(); } });
  $('retry-recognition').addEventListener('click', async () => {
    const item = state.selectedItem;
    if (!canAct() || !item || $('retry-recognition').disabled) return;
    state.mutationBusy = true; updateControls(); $('item-detail-error').hidden = true;
    const epoch = state.epoch;
    try {
      const result = await api('/api/admin/items/' + safeID(item.id) + '/recognize', { method: 'POST' });
      if (epoch !== state.epoch) return;
      if (result.item?.id === item.id) { state.selectedItem = result.item; renderItemDetail(result.item); }
      state.inventoryFingerprint = ''; toast("Recognition requested. Tags will update when processing finishes.");
    } catch (error) { if (epoch === state.epoch) { text('item-detail-error', error.message); $('item-detail-error').hidden = false; } }
    finally { state.mutationBusy = false; updateControls(); refreshDashboard(); }
  });
  document.querySelectorAll('.nav-link').forEach((link) => link.addEventListener('click', () => {
    document.querySelectorAll('.nav-link').forEach((entry) => { entry.classList.toggle('active', entry === link); if (entry === link) entry.setAttribute('aria-current', 'location'); else entry.removeAttribute('aria-current'); });
  }));
  document.addEventListener('visibilitychange', () => {
    clearTimeout(state.pollTimer);
    if (!document.hidden && state.authenticated) { updateFreshness(); refreshDashboard(); }
  });
  window.addEventListener('storage', (event) => {
    if (event.key !== JOURNAL_KEY) return;
    state.pending = readJournal(); state.pendingOperation = null;
    state.pendingMessage = "The saved request changed in another tab. Check its status first."; renderJournal();
    if (state.pending && state.authenticated) recoverPending();
  });
  setInterval(() => { if (!document.hidden) updateFreshness(); }, 1000);
  checkSession();
})();
