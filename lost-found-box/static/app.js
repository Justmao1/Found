"use strict";

const el = Object.fromEntries([...document.querySelectorAll("[id]")].map(node => [node.id, node]));
let stream = null;
let photo = null;
let busy = false;
let submitted = null;
let cameraAttempt = 0;
let listAttempt = 0;
let previewURL = null;
let aiConfigured = false;
let pollTimer = null;
const recognizing = new Set();
const recognitionErrors = new Map();

function feedback(message, kind = "") {
  el.feedback.textContent = message;
  el.feedback.className = `feedback ${kind}`;
}

function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return "10000000-1000-4000-8000-100000000000".replace(/[018]/g, c =>
    (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
}

function updateControls() {
  for (const id of ["start-camera", "choose-photo", "take-photo", "reset-photo"]) el[id].disabled = busy;
  el["save-photo"].disabled = busy || !photo;
  el.note.disabled = busy || Boolean(submitted);
  el["save-photo"].firstChild.textContent = busy ? "Saving… " : "Save item ";
}

function stopCamera() {
  cameraAttempt += 1;
  if (stream) stream.getTracks().forEach(track => track.stop());
  stream = null;
  el.camera.srcObject = null;
  el.camera.hidden = true;
  el["take-photo"].hidden = true;
  el["start-camera"].hidden = Boolean(photo);
  el["empty-camera"].hidden = Boolean(photo);
}

function resetPhoto() {
  stopCamera();
  photo = null;
  submitted = null;
  el.preview.hidden = true;
  el.preview.removeAttribute("src");
  if (previewURL) URL.revokeObjectURL(previewURL);
  previewURL = null;
  el["empty-camera"].hidden = false;
  el["start-camera"].hidden = false;
  el["reset-photo"].hidden = true;
  el["photo-file"].value = "";
  el["frame-label"].textContent = "Photo preview";
  updateControls();
}

function setPhoto(source, width, height) {
  if (!width || !height) throw new Error("The photo is not ready. Please take it again.");
  const scale = Math.min(1, 1600 / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  const context = canvas.getContext("2d");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(source, 0, 0, canvas.width, canvas.height);
  const dataURL = canvas.toDataURL("image/jpeg", 0.85);
  if (!dataURL.startsWith("data:image/jpeg;base64,")) throw new Error("Could not process the photo. Please choose it again.");
  photo = {image: dataURL.split(",")[1], mime_type: "image/jpeg", request_id: uuid()};
  submitted = null;
  stopCamera();
  if (previewURL) URL.revokeObjectURL(previewURL);
  const bytes = Uint8Array.from(atob(photo.image), character => character.charCodeAt(0));
  previewURL = URL.createObjectURL(new Blob([bytes], {type: "image/jpeg"}));
  el.preview.src = previewURL;
  el.preview.hidden = false;
  el["reset-photo"].hidden = false;
  el["frame-label"].textContent = "Ready to save";
  feedback("Photo ready. Add a note if needed, then save.");
  updateControls();
}

async function startCamera() {
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    el["camera-help"].hidden = false;
    el["camera-help"].textContent = "Live camera is unavailable. Use a trusted HTTPS address or choose an existing photo.";
    return;
  }
  resetPhoto();
  const attempt = ++cameraAttempt;
  el["start-camera"].disabled = true;
  feedback("Allow camera access and place the item in view.");
  try {
    const nextStream = await navigator.mediaDevices.getUserMedia({
      video: {facingMode: {ideal: "environment"}, width: {ideal: 1600}, height: {ideal: 1200}},
      audio: false,
    });
    if (attempt !== cameraAttempt) {
      nextStream.getTracks().forEach(track => track.stop());
      return;
    }
    stream = nextStream;
    el.camera.srcObject = stream;
    el.camera.hidden = false;
    await el.camera.play();
    if (attempt !== cameraAttempt) return;
    el["empty-camera"].hidden = true;
    el["start-camera"].hidden = true;
    el["take-photo"].hidden = false;
    el["reset-photo"].hidden = false;
    el["camera-help"].hidden = true;
    el["frame-label"].textContent = "Camera preview";
    feedback("Keep the whole item in focus, then take a photo.");
  } catch (error) {
    if (attempt !== cameraAttempt) return;
    stopCamera();
    const reason = error.name === "NotAllowedError" ? "Camera permission denied. Allow access in browser settings or choose a photo." : "Could not open the camera. Check your device or choose a photo.";
    feedback(reason, "error");
  } finally {
    updateControls();
  }
}

async function request(url, options = {}, timeoutMs = 20000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {...options, signal: controller.signal, cache: "no-store"});
    let body;
    try { body = await response.json(); } catch { throw new Error("Unexpected server response. Check your connection and try again."); }
    if (!response.ok) throw new Error(body.error || `Request failed (${response.status}). Please try again.`);
    el.connection.textContent = "Connected";
    el.connection.className = "connection online";
    return body;
  } catch (error) {
    if (error.name === "AbortError" || error instanceof TypeError) {
      el.connection.textContent = "Disconnected";
      el.connection.className = "connection offline";
      throw new Error("Connection lost or request timed out. Reconnect and try again.");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function renderItems(items, total) {
  el.records.replaceChildren();
  el["record-count"].textContent = String(total);
  el["records-status"].hidden = items.length > 0;
  el["records-status"].textContent = "No items yet. Save your first photo to see it here.";
  el["records-title"].title = total > items.length ? `Showing the latest ${items.length} of ${total} items` : "Saved items";
  for (const item of items) {
    const card = document.createElement("article");
    card.className = "record";
    const link = document.createElement("a");
    link.href = item.image_url;
    link.target = "_blank";
    link.rel = "noopener";
    link.setAttribute("aria-label", "View original photo");
    const image = document.createElement("img");
    image.className = "record-photo";
    image.src = item.image_url;
    image.alt = item.note || "Registered item photo";
    image.loading = "lazy";
    link.append(image);
    const info = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = item.note || "Saved item";
    const time = document.createElement("time");
    time.dateTime = item.created_at;
    time.textContent = new Intl.DateTimeFormat("en-GB", {month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false}).format(new Date(item.created_at));
    const status = document.createElement("span");
    status.className = "record-status";
    status.textContent = "Photo saved";
    info.append(title, time, status);
    if (item.recognition?.tags?.length) {
      const tags = document.createElement("div");
      tags.className = "item-tags";
      tags.setAttribute("aria-label", "Item tags");
      for (const label of item.recognition.tags) {
        const tag = document.createElement("span");
        tag.className = "item-tag";
        tag.textContent = label;
        tags.append(tag);
      }
      info.append(tags);
      status.textContent = "Tagged";
    } else if (["pending", "processing"].includes(item.recognition_status) || recognizing.has(item.id)) {
      status.textContent = "Identifying…";
    } else {
      status.textContent = aiConfigured ? "Tags unavailable" : "Tagging not enabled";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "button secondary recognize-button";
      button.textContent = "Retry tagging";
      button.disabled = !aiConfigured;
      button.addEventListener("click", () => recognizeItem(item.id));
      const error = document.createElement("p");
      error.className = "recognition-error";
      error.setAttribute("role", "status");
      error.textContent = recognitionErrors.get(item.id) || (item.recognition_status === "failed" ? "Photo saved. Please retry tagging." : "");
      info.append(button, error);
    }
    card.append(link, info);
    el.records.append(card);
  }
}

async function loadAIStatus() {
  try {
    const status = await request("/api/ai/status");
    aiConfigured = status.configured;
    el["ai-status"].textContent = aiConfigured
      ? "Save a photo to automatically tag its type, color and shape."
      : "You can save photos. Set up AI tagging, then refresh.";
  } catch {
    aiConfigured = false;
    el["ai-status"].textContent = "Could not check AI status. You can still save photos; refresh later.";
  }
}

async function recognizeItem(id) {
  if (!aiConfigured || recognizing.has(id)) return;
  recognizing.add(id);
  recognitionErrors.delete(id);
  const loading = loadItems();
  try {
    await request(`/api/items/${id}/recognize`, {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"},
      body: "{}",
    }, 45000);
  } catch (error) {
    recognitionErrors.set(id, `${error.message} Your photo is saved. Select Retry tagging to try again.`);
  } finally {
    recognizing.delete(id);
    await loading;
    await loadItems();
  }
}

async function loadItems() {
  clearTimeout(pollTimer);
  const attempt = ++listAttempt;
  el.refresh.disabled = true;
  try {
    const result = await request("/api/items");
    if (attempt !== listAttempt) return true;
    renderItems(result.items, result.total);
    if (!document.hidden && result.items.some(item => ["pending", "processing"].includes(item.recognition_status))) {
      pollTimer = setTimeout(loadItems, 1500);
    }
    return true;
  } catch (error) {
    if (attempt !== listAttempt) return false;
    el["records-status"].hidden = false;
    el["records-status"].textContent = "Could not load the latest items. Check your connection and refresh.";
    return false;
  } finally {
    if (attempt === listAttempt) el.refresh.disabled = false;
  }
}

el["start-camera"].addEventListener("click", startCamera);
el["reset-photo"].addEventListener("click", () => { resetPhoto(); feedback("Take another photo or choose a different one."); });
el["take-photo"].addEventListener("click", () => {
  try { setPhoto(el.camera, el.camera.videoWidth, el.camera.videoHeight); }
  catch (error) { feedback(error.message, "error"); }
});
el["choose-photo"].addEventListener("click", () => {
  stopCamera();
  el["photo-file"].value = "";
  el["photo-file"].click();
});
el["photo-file"].addEventListener("change", async event => {
  const file = event.target.files[0];
  if (!file) return;
  if (file.size > 25 * 1024 * 1024) { feedback("This photo exceeds 25 MB. Choose a smaller image.", "error"); return; }
  busy = true;
  updateControls();
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    setPhoto(image, image.naturalWidth, image.naturalHeight);
  } catch {
    feedback("Could not read this photo. Choose a JPEG or PNG, or take a new photo.", "error");
  } finally {
    URL.revokeObjectURL(url);
    busy = false;
    updateControls();
  }
});
el.note.addEventListener("input", () => { el["note-count"].textContent = `${el.note.value.length} / 200`; });
el["register-form"].addEventListener("submit", async event => {
  event.preventDefault();
  if (!photo || busy) return;
  submitted ??= {...photo, note: el.note.value.trim()};
  busy = true;
  updateControls();
  feedback("Saving your photo…");
  try {
    const saved = await request("/api/items", {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"},
      body: JSON.stringify(submitted),
    });
    resetPhoto();
    el.note.value = "";
    el["note-count"].textContent = "0 / 200";
    const refreshed = await loadItems();
    feedback(refreshed ? (saved.item.recognition ? "Item saved and tagged." : (aiConfigured ? "Photo saved. Tags will appear automatically. You can add another item." : "Photo saved. AI tagging needs to be configured.")) : "Photo saved. Refresh to update the list.", "success");
  } catch (error) {
    feedback(`${error.message} Retrying will not create a duplicate item.`, "error");
  } finally {
    busy = false;
    updateControls();
  }
});
el.refresh.addEventListener("click", async () => { await loadAIStatus(); await loadItems(); });
window.addEventListener("pagehide", stopCamera);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    clearTimeout(pollTimer);
    const wasActive = Boolean(stream) || el["start-camera"].disabled;
    stopCamera();
    updateControls();
    if (wasActive && !busy) feedback("Camera paused. Select Open camera to continue.");
  } else {
    loadAIStatus().then(loadItems);
  }
});
if (!window.isSecureContext) {
  el["camera-help"].hidden = false;
  el["camera-help"].textContent = "Live camera requires trusted HTTPS. You can choose a photo instead.";
}
loadAIStatus().then(loadItems);

let searchBusy = false;
function showMode(searchMode) {
  if (searchMode) stopCamera();
  el['search-panel'].hidden = !searchMode;
  el['register-panel'].hidden = searchMode;
  for (const [id, selected] of [['show-search', searchMode], ['show-register', !searchMode]]) {
    el[id].setAttribute('aria-pressed', String(selected));
    el[id].className = `button ${selected ? 'primary' : 'secondary'}`;
  }
}
el['show-register'].addEventListener('click', () => showMode(false));
el['show-search'].addEventListener('click', () => showMode(true));
el['search-query'].addEventListener('input', () => {
  el['search-count'].textContent = `${el['search-query'].value.length} / 500`;
  if (!searchBusy) {
    el['search-results'].replaceChildren();
    el['search-status'].textContent = 'Select Find matches to search with this description.';
  }
});

function renderSearchMatches(matches) {
  el['search-results'].replaceChildren();
  for (const {item, reason} of matches) {
    const card = document.createElement('article');
    card.className = 'record search-result';
    const link = document.createElement('a');
    link.href = item.image_url;
    link.target = '_blank';
    link.rel = 'noopener';
    link.setAttribute('aria-label', 'View candidate photo');
    const photo = document.createElement('img');
    photo.src = item.image_url;
    photo.alt = item.recognition.tags[0] || 'Possible match';
    photo.className = 'record-photo';
    link.append(photo);
    const info = document.createElement('div');
    const title = document.createElement('h3');
    title.textContent = item.recognition.tags[0] || 'Possible match';
    const tags = document.createElement('div');
    tags.className = 'item-tags';
    for (const label of item.recognition.tags) {
      const tag = document.createElement('span');
      tag.className = 'item-tag';
      tag.textContent = label;
      tags.append(tag);
    }
    const explanation = document.createElement('p');
    explanation.className = 'match-reason';
    explanation.textContent = reason;
    info.append(title, tags, explanation);
    if (item.note) {
      const note = document.createElement('p');
      note.className = 'match-note';
      note.textContent = `Finder's note: ${item.note}`;
      info.append(note);
    }
    const time = document.createElement('time');
    time.dateTime = item.created_at;
    time.textContent = `Registered ${new Intl.DateTimeFormat('en-GB', {dateStyle:'medium', timeStyle:'short'}).format(new Date(item.created_at))}`;
    info.append(time);
    card.append(link, info);
    el['search-results'].append(card);
  }
}

el['search-form'].addEventListener('submit', async event => {
  event.preventDefault();
  if (searchBusy) return;
  const query = el['search-query'].value.trim();
  if (!query) {
    el['search-status'].textContent = 'Please describe the item you lost.';
    return;
  }
  searchBusy = true;
  el['search-submit'].disabled = true;
  el['search-query'].disabled = true;
  el['search-submit'].textContent = 'Searching…';
  el['search-status'].className = 'feedback';
  el['search-status'].textContent = 'Looking for possible matches in saved items…';
  el['search-results'].replaceChildren();
  try {
    const result = await request('/api/search', {
      method:'POST',
      headers:{'Content-Type':'application/json', 'X-Requested-With':'lost-found-box'},
      body:JSON.stringify({query}),
    }, 45000);
    renderSearchMatches(result.matches);
    const count = result.matches.length;
    let message = count ? `${count} possible ${count === 1 ? 'match' : 'matches'} found. Compare the photos and details.`
      : (result.searched_count ? 'No matching items found. Try another detail or check back later.' : 'No tagged items are available to search yet. Please check back later.');
    if (result.pending_count) message += ` ${result.pending_count} ${result.pending_count === 1 ? 'item is' : 'items are'} not tagged yet and could not be searched.`;
    el['search-status'].textContent = message;
  } catch (error) {
    el['search-status'].className = 'feedback error';
    el['search-status'].textContent = `${error.message} Your description is still here; you can try again.`;
  } finally {
    searchBusy = false;
    el['search-submit'].disabled = false;
    el['search-query'].disabled = false;
    el['search-submit'].textContent = 'Find matches';
  }
});
