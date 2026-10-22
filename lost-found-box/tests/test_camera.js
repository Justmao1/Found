"use strict";

// Exercise app.js directly with a small DOM/permission harness; no browser or packages.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const staticDirectory = path.join(__dirname, "..", "static");
const html = fs.readFileSync(path.join(staticDirectory, "index.html"), "utf8");
const application = fs.readFileSync(path.join(staticDirectory, "app.js"), "utf8");

function permissionHarness() {
  const elements = new Map();
  for (const match of html.matchAll(/<[^>]*\bid="([^"]+)"[^>]*>/g)) {
    const [tag, id] = match;
    elements.set(id, {
      id,
      hidden: /\shidden(?:\s|>)/.test(tag),
      disabled: /\sdisabled(?:\s|>)/.test(tag),
      value: "",
      textContent: "",
      firstChild: {textContent: ""},
      events: {},
      addEventListener(event, callback) { this.events[event] = callback; },
      removeAttribute(name) { delete this[name]; },
      async play() {},
    });
  }
  const document = {
    hidden: false,
    events: {},
    querySelectorAll: () => [...elements.values()],
    addEventListener(event, callback) { this.events[event] = callback; },
  };
  let resolvePermission;
  let rejectPermission;
  const permission = new Promise((resolve, reject) => {
    resolvePermission = resolve;
    rejectPermission = reject;
  });
  const context = {
    document,
    window: {isSecureContext: true, addEventListener() {}},
    navigator: {mediaDevices: {getUserMedia: () => permission}},
    // Leave the unrelated initial record-list request pending without real timers.
    fetch: () => new Promise(() => {}),
    AbortController,
    setTimeout: () => 1,
    clearTimeout() {},
  };
  vm.createContext(context);
  vm.runInContext(application, context, {filename: "app.js"});
  return {elements, document, resolvePermission, rejectPermission};
}

test("permission granted after backgrounding closes the late stream", async () => {
  const harness = permissionHarness();
  const start = harness.elements.get("start-camera");
  const attempt = start.events.click();
  assert.equal(start.disabled, true, "permission request disables its start button");

  harness.document.hidden = true;
  harness.document.events.visibilitychange();
  let stoppedTracks = 0;
  harness.resolvePermission({getTracks: () => [{stop() { stoppedTracks += 1; }}]});
  await attempt;

  assert.equal(stoppedTracks, 1, "late camera stream must be stopped");
  assert.equal(harness.elements.get("camera").hidden, true);
  assert.equal(harness.elements.get("camera").srcObject, null);
  assert.equal(harness.elements.get("take-photo").hidden, true);
  assert.equal(start.disabled, false);
  assert.equal(start.hidden, false);
});

test("permission rejection restores controls and explains how to recover", async () => {
  const harness = permissionHarness();
  const start = harness.elements.get("start-camera");
  const attempt = start.events.click();
  assert.equal(start.disabled, true);

  const error = new Error("Permission denied");
  error.name = "NotAllowedError";
  harness.rejectPermission(error);
  await attempt;

  assert.equal(start.disabled, false);
  assert.equal(start.hidden, false);
  assert.equal(harness.elements.get("choose-photo").disabled, false);
  assert.equal(harness.elements.get("camera").hidden, true);
  assert.equal(harness.elements.get("camera").srcObject, null);
  assert.equal(harness.elements.get("take-photo").hidden, true);
  assert.equal(harness.elements.get("save-photo").disabled, true);
  assert.match(harness.elements.get("feedback").textContent, /Camera permission denied/);
});
