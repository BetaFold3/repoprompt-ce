// RepoPrompt Remote — plain ES module PWA client (no build toolchain).
//
// Implements the paired-device remote wire protocol v1:
// - pairing bootstrap via the gateway pairing relay (/api/pair/*, /api/ticket),
// - one-time app-minted ticket + per-frame P256 device signatures (DPoP-lite),
// - sessions list / transcript catch-up / respond / steer / cancel,
// - binding_required window picker surface,
// - Web Push wake registration (push_subscribe) with identifier-only payloads.

const WIRE_VERSION = 1;
const SIGNING_CONTEXT = 'RemoteFrameV1';
const PROOF_CONTEXT = 'RepoPromptRemotePairingDeviceChallengeV1';
const SCOPES = {
  observe: 'sessions:observe',
  operate: 'sessions:operate',
  respond: 'interactions:respond',
};
const DB_NAME = 'repoprompt-remote';
const DB_STORE = 'identity';
const TRANSCRIPT_PAGE = 200;

// ---------------------------------------------------------------------------
// Small utilities

const $ = (id) => document.getElementById(id);
const utf8 = (text) => new TextEncoder().encode(text);

function bytesToBase64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64ToBytes(base64) {
  const normalized = base64.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256Bytes(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

// Canonical JSON matching the gateway's JSONValue.canonicalString():
// object keys sorted, compact separators, JSON string/number primitives.
function canonicalJSON(value) {
  if (value === null || value === undefined) return 'null';
  const kind = typeof value;
  if (kind === 'boolean' || kind === 'number' || kind === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(',')}]`;
  }
  const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
}

function logLine(message) {
  const log = $('log');
  const stamp = new Date().toISOString().slice(11, 19);
  log.textContent = `[${stamp}] ${message}\n${log.textContent}`.slice(0, 8000);
}

async function postJSON(path, body) {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `HTTP ${response.status}`);
  }
  return payload;
}

// ---------------------------------------------------------------------------
// Device identity (non-extractable P-256 key pair in IndexedDB)

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function dbGet(key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, 'readonly').objectStore(DB_STORE).get(key);
    tx.onsuccess = () => resolve(tx.result);
    tx.onerror = () => reject(tx.error);
  });
}

async function dbSet(key, value) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, 'readwrite').objectStore(DB_STORE).put(value, key);
    tx.onsuccess = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function dbDelete(key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, 'readwrite').objectStore(DB_STORE).delete(key);
    tx.onsuccess = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function signP256(privateKey, bytes) {
  // WebCrypto ECDSA P-256 emits the raw 64-byte r||s form the gateway verifies.
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, bytes);
  return new Uint8Array(signature);
}

// ---------------------------------------------------------------------------
// Client state

const state = {
  keyPair: null,
  deviceId: null,
  displayName: null,
  scopes: [],
  ws: null,
  ticketId: null,
  counter: 0,
  connected: false,
  vapidPublicKey: null,
  pending: new Map(), // request_id -> {resolve, reject}
  sessions: new Map(), // session_id -> snapshot payload
  currentSessionId: null,
  transcriptOffset: 0,
  lastSeqBySession: new Map(),
  pendingStartMessage: null, // last start message refused with binding_required/ambiguous_start_target
};

function setBadge(text, cls) {
  const badge = $('conn-badge');
  badge.textContent = text;
  badge.className = `badge ${cls || ''}`;
}

// ---------------------------------------------------------------------------
// Pairing flow

async function pairDevice() {
  const displayName = ($('device-name').value || '').trim() || 'Remote device';
  const scopes = [SCOPES.observe];
  if ($('scope-operate').checked) scopes.push(SCOPES.operate);
  if ($('scope-respond').checked) scopes.push(SCOPES.respond);
  const sortedScopes = [...scopes].sort();

  $('pair-status').textContent = 'Requesting pairing challenge…';
  const begin = await postJSON('/api/pair/begin', {});
  $('host-fingerprint').textContent = begin.host_fingerprint || '–';

  const keyPair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const rawPoint = new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey));
  // The app expects the 64-byte P-256 rawRepresentation (x||y, no 0x04 prefix).
  const raw64 = rawPoint.slice(1);
  const publicKeyBase64 = bytesToBase64(raw64);
  const fingerprintHex = bytesToHex(await sha256Bytes(raw64));
  const deviceId = `remote:${fingerprintHex.slice(0, 8)}`;

  const proofPayload = [
    PROOF_CONTEXT,
    String(begin.pairing_id).toLowerCase(),
    begin.challenge,
    deviceId,
    displayName,
    publicKeyBase64,
    sortedScopes.join(','),
  ].join('\n') + '\n';
  const proof = bytesToBase64(await signP256(keyPair.privateKey, utf8(proofPayload)));

  $('pair-status').textContent = 'Waiting for approval on your Mac…';
  const complete = await postJSON('/api/pair/complete', {
    pairing_id: begin.pairing_id,
    display_name: displayName,
    public_key: publicKeyBase64,
    proof,
    scopes: sortedScopes,
    device_id: deviceId,
  });

  const device = complete.device || {};
  state.keyPair = keyPair;
  state.deviceId = device.id || deviceId;
  state.displayName = device.display_name || displayName;
  state.scopes = device.scopes || sortedScopes;
  await dbSet('keyPair', keyPair);
  await dbSet('device', {
    deviceId: state.deviceId,
    displayName: state.displayName,
    scopes: state.scopes,
  });
  $('pair-status').textContent = '';
  logLine(`Paired as ${state.deviceId}`);
  renderIdentity();
}

async function loadIdentity() {
  const [keyPair, device] = await Promise.all([dbGet('keyPair'), dbGet('device')]);
  if (keyPair && device) {
    state.keyPair = keyPair;
    state.deviceId = device.deviceId;
    state.displayName = device.displayName;
    state.scopes = device.scopes || [];
  }
}

async function forgetIdentity() {
  await dbDelete('keyPair');
  await dbDelete('device');
  state.keyPair = null;
  state.deviceId = null;
  disconnect();
  renderIdentity();
}

function renderIdentity() {
  const paired = Boolean(state.keyPair && state.deviceId);
  $('pair-panel').classList.toggle('hidden', paired);
  $('connect-panel').classList.toggle('hidden', !paired);
  if (paired) {
    $('paired-name').textContent = state.displayName || '–';
    $('paired-device-id').textContent = state.deviceId || '–';
  }
}

// ---------------------------------------------------------------------------
// Signed WebSocket frames

async function signedFrame(frame) {
  const unsigned = { ...frame };
  delete unsigned.sig;
  const hashHex = bytesToHex(await sha256Bytes(utf8(canonicalJSON(unsigned))));
  state.counter = Math.max(state.counter + 1, Date.now());
  const signingPayload = [
    SIGNING_CONTEXT,
    state.ticketId,
    state.deviceId,
    String(state.counter),
    hashHex,
  ].join('\n') + '\n';
  const signature = await signP256(state.keyPair.privateKey, utf8(signingPayload));
  return {
    ...frame,
    sig: {
      ticket_id: state.ticketId,
      device_id: state.deviceId,
      counter: state.counter,
      algorithm: 'P256-SHA256',
      signature: bytesToBase64(signature),
    },
  };
}

function sendCommand(frame) {
  return new Promise((resolve, reject) => {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
      reject(new Error('Not connected.'));
      return;
    }
    const requestId = frame.request_id || crypto.randomUUID();
    const complete = { v: WIRE_VERSION, request_id: requestId, ...frame };
    state.pending.set(requestId, { resolve, reject });
    signedFrame(complete)
      .then((signed) => state.ws.send(JSON.stringify(signed)))
      .catch((error) => {
        state.pending.delete(requestId);
        reject(error);
      });
    setTimeout(() => {
      if (state.pending.delete(requestId)) {
        reject(new Error(`Timed out waiting for ${frame.type}.`));
      }
    }, 120000);
  });
}

async function connect() {
  if (!state.keyPair || !state.deviceId) return;
  $('connect-status').textContent = 'Requesting connection ticket…';
  let ticket;
  try {
    const minted = await postJSON('/api/ticket', { device_id: state.deviceId });
    ticket = minted.ticket;
  } catch (error) {
    $('connect-status').textContent = `Ticket request failed: ${error.message}`;
    return;
  }
  state.ticketId = String(ticket.ticket_id).toLowerCase();
  state.counter = Date.now();

  const wsURL = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
  const ws = new WebSocket(wsURL);
  state.ws = ws;
  setBadge('connecting…', 'warn');
  $('connect-status').textContent = 'Connecting…';

  ws.onopen = async () => {
    const hello = await signedFrame({
      v: WIRE_VERSION,
      type: 'hello',
      payload: { ticket },
    });
    ws.send(JSON.stringify(hello));
  };
  ws.onmessage = (event) => handleServerFrame(event.data);
  ws.onclose = () => {
    if (state.ws === ws) {
      state.connected = false;
      state.ws = null;
      setBadge('disconnected', 'err');
      $('connect-status').textContent = 'Disconnected.';
      $('push-button').disabled = true;
    }
  };
  ws.onerror = () => logLine('WebSocket error.');
}

function disconnect() {
  if (state.ws) state.ws.close();
  state.ws = null;
  state.connected = false;
  setBadge('disconnected', '');
}

// ---------------------------------------------------------------------------
// Server frame handling

function handleServerFrame(raw) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    return;
  }
  switch (frame.type) {
    case 'hello_ack': {
      state.connected = true;
      setBadge('connected', 'ok');
      $('connect-status').textContent = '';
      const payload = frame.payload || {};
      if (payload.vapid_public_key) {
        state.vapidPublicKey = payload.vapid_public_key;
        $('push-button').disabled = false;
      }
      $('sessions-panel').classList.remove('hidden');
      refreshSessions();
      logLine(`hello_ack auth=${payload.auth || '?'}`);
      break;
    }
    case 'command_result':
    case 'command_error': {
      const pending = frame.request_id ? state.pending.get(frame.request_id) : null;
      if (pending) {
        state.pending.delete(frame.request_id);
        if (frame.type === 'command_result') {
          pending.resolve(frame.payload || {});
        } else {
          const code = frame.payload && frame.payload.code;
          const message = (frame.payload && frame.payload.message) || 'Command failed.';
          if (code === 'binding_required' || code === 'ambiguous_start_target') {
            showBindingOverlay(message, frame.payload && frame.payload.details);
          }
          const error = new Error(message);
          error.code = code;
          pending.reject(error);
        }
      } else if (frame.type === 'command_error') {
        const code = frame.payload && frame.payload.code;
        if (code === 'binding_required' || code === 'ambiguous_start_target') {
          showBindingOverlay(frame.payload.message, frame.payload.details);
        }
        logLine(`error: ${code || 'unknown'}`);
      }
      break;
    }
    case 'session_update':
    case 'session_terminal': {
      if (frame.session_id) {
        detectSeqGap(frame);
        state.sessions.set(frame.session_id, frame.payload || {});
        renderSessions();
        if (frame.session_id === state.currentSessionId) {
          renderSessionDetail();
          if (frame.type === 'session_update') maybeRefreshTranscript();
        }
        if (frame.type === 'session_terminal') {
          logLine(`session ${shortID(frame.session_id)} finished`);
        }
      }
      break;
    }
    case 'interaction_resolved': {
      if (frame.session_id) {
        // interaction_resolved consumes the same per-session seq stream as
        // updates/terminal frames; track it so the next snapshot does not look
        // like a missed update and trigger a spurious get_log catch-up.
        detectSeqGap(frame);
      }
      break;
    }
    case 'session_expired': {
      if (frame.session_id) {
        state.sessions.delete(frame.session_id);
        renderSessions();
        logLine(`session ${shortID(frame.session_id)} expired`);
      }
      break;
    }
    case 'channel_closing': {
      const reason = (frame.payload && frame.payload.reason) || 'unknown';
      logLine(`channel closing: ${reason}`);
      setBadge('app link lost', 'warn');
      break;
    }
    case 'pong':
      break;
    default:
      // Additive evolution: ignore unknown server frame types.
      break;
  }
}

function detectSeqGap(frame) {
  if (typeof frame.seq !== 'number' || !frame.session_id) return;
  const last = state.lastSeqBySession.get(frame.session_id) || 0;
  if (last && frame.seq > last + 1 && frame.session_id === state.currentSessionId) {
    // Missed updates: catch up through get_log rather than trusting the stream.
    maybeRefreshTranscript();
  }
  state.lastSeqBySession.set(frame.session_id, frame.seq);
}

// ---------------------------------------------------------------------------
// Sessions list (scoped to the bound window's active workspace)

function shortID(sessionId) {
  return String(sessionId).slice(0, 8);
}

function sessionStatus(payload) {
  return (payload && payload.status) || 'unknown';
}

async function refreshSessions() {
  try {
    const result = await sendCommand({ type: 'list_sessions', payload: { limit: 50 } });
    const items = result.sessions || result.items || (Array.isArray(result) ? result : []);
    for (const item of items) {
      const sessionId = item.session_id || item.id;
      if (sessionId) state.sessions.set(sessionId, item);
    }
    renderSessions();
    const ids = [...state.sessions.keys()];
    if (ids.length) {
      await sendCommand({ type: 'subscribe', payload: { session_ids: ids } }).catch(() => {});
    }
  } catch (error) {
    logLine(`list_sessions failed: ${error.message}`);
  }
}

function renderSessions() {
  const list = $('sessions-list');
  list.textContent = '';
  const entries = [...state.sessions.entries()];
  if (!entries.length) {
    const empty = document.createElement('li');
    empty.textContent = 'No sessions in the bound workspace.';
    empty.style.color = 'var(--muted)';
    list.appendChild(empty);
    return;
  }
  for (const [sessionId, payload] of entries) {
    const item = document.createElement('li');
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = payload.session_name || payload.name || shortID(sessionId);
    const status = document.createElement('span');
    status.className = 'badge';
    status.textContent = sessionStatus(payload);
    if (sessionStatus(payload) === 'waiting_for_input') status.classList.add('warn');
    item.append(name, status);
    item.onclick = () => openSession(sessionId);
    list.appendChild(item);
  }
}

// ---------------------------------------------------------------------------
// Session detail: transcript pager + respond / steer / cancel

async function openSession(sessionId) {
  state.currentSessionId = sessionId;
  state.transcriptOffset = 0;
  $('detail-panel').classList.remove('hidden');
  $('detail-session-id').textContent = shortID(sessionId);
  $('transcript').textContent = '';
  renderSessionDetail();
  await sendCommand({ type: 'subscribe', session_id: sessionId }).catch(() => {});
  await loadTranscript(false);
}

function renderSessionDetail() {
  const payload = state.sessions.get(state.currentSessionId) || {};
  const status = sessionStatus(payload);
  const badge = $('detail-status');
  badge.textContent = status;
  badge.className = `badge ${status === 'waiting_for_input' ? 'warn' : ''}`;
  const interaction = payload.interaction || null;
  const interactionId = payload.interaction_id || (interaction && interaction.id) || null;
  const box = $('interaction-box');
  if (status === 'waiting_for_input') {
    box.classList.remove('hidden');
    box.dataset.interactionId = interactionId || '';
    const text = interaction
      ? (interaction.prompt || interaction.title || interaction.question || 'The agent is waiting for input.')
      : 'The agent is waiting for input.';
    $('interaction-text').textContent = text;
  } else {
    box.classList.add('hidden');
  }
}

function transcriptText(result) {
  if (typeof result === 'string') return result;
  if (result.log && typeof result.log === 'string') return result.log;
  const items = result.entries || result.messages || result.log || result.transcript;
  if (Array.isArray(items)) {
    return items
      .map((entry) => {
        if (typeof entry === 'string') return entry;
        const role = entry.role || entry.kind || entry.type || '';
        const text = entry.text || entry.content || entry.message || JSON.stringify(entry);
        return role ? `[${role}] ${text}` : text;
      })
      .join('\n');
  }
  return JSON.stringify(result, null, 2);
}

async function loadTranscript(older) {
  if (!state.currentSessionId) return;
  if (older) state.transcriptOffset += TRANSCRIPT_PAGE;
  try {
    const result = await sendCommand({
      type: 'get_log',
      session_id: state.currentSessionId,
      payload: { offset: state.transcriptOffset, limit: TRANSCRIPT_PAGE },
    });
    const text = transcriptText(result);
    const transcript = $('transcript');
    transcript.textContent = older ? `${text}\n${transcript.textContent}` : text;
    if (!older) transcript.scrollTop = transcript.scrollHeight;
  } catch (error) {
    logLine(`get_log failed: ${error.message}`);
  }
}

let transcriptRefreshTimer = null;
function maybeRefreshTranscript() {
  if (transcriptRefreshTimer) return;
  transcriptRefreshTimer = setTimeout(() => {
    transcriptRefreshTimer = null;
    state.transcriptOffset = 0;
    loadTranscript(false);
  }, 750);
}

async function respond() {
  const response = $('respond-input').value;
  if (!state.currentSessionId) return;
  const interactionId = $('interaction-box').dataset.interactionId;
  const payload = { response };
  if (interactionId) payload.interaction_id = interactionId;
  try {
    await sendCommand({ type: 'respond', session_id: state.currentSessionId, payload });
    $('respond-input').value = '';
    logLine('respond delivered');
  } catch (error) {
    logLine(`respond failed: ${error.code || error.message}`);
  }
}

async function steer() {
  const message = $('steer-input').value.trim();
  if (!message || !state.currentSessionId) return;
  try {
    await sendCommand({ type: 'steer', session_id: state.currentSessionId, payload: { message } });
    $('steer-input').value = '';
    logLine('steer delivered');
  } catch (error) {
    logLine(`steer failed: ${error.code || error.message}`);
  }
}

async function cancelSession() {
  if (!state.currentSessionId) return;
  try {
    await sendCommand({ type: 'cancel', session_id: state.currentSessionId });
    logLine('cancel delivered');
  } catch (error) {
    logLine(`cancel failed: ${error.code || error.message}`);
  }
}

async function startSession(message, target) {
  try {
    const payload = { message };
    if (target && target.window_id != null) payload.window_id = target.window_id;
    if (target && target.workspace_id) payload.workspace_id = target.workspace_id;
    const result = await sendCommand({ type: 'start', payload });
    state.pendingStartMessage = null;
    const sessionId = result.session_id;
    logLine(`started session ${sessionId ? shortID(sessionId) : '?'}`);
    await refreshSessions();
    if (sessionId) openSession(sessionId);
  } catch (error) {
    if (error.code === 'binding_required' || error.code === 'ambiguous_start_target') {
      // Keep the message so the binding overlay's window picker can re-issue
      // the start with an explicit window_id target (M6.6).
      state.pendingStartMessage = message;
      updateBindingConfirmVisibility();
    }
    logLine(`start failed: ${error.code || error.message}`);
  }
}

// ---------------------------------------------------------------------------
// binding_required window/workspace picker

function showBindingOverlay(message, details) {
  $('binding-message').textContent = message || 'The gateway link is not bound to a RepoPrompt window.';
  const pickerRow = $('binding-picker-row');
  const picker = $('binding-picker');
  picker.textContent = '';
  const windows = details && Array.isArray(details.windows) ? details.windows : [];
  if (windows.length) {
    for (const window of windows) {
      const option = document.createElement('option');
      const windowId = window.window_id != null ? window.window_id : window.id;
      option.value = windowId != null ? String(windowId) : '';
      option.textContent = window.workspace_name || window.title || window.workspace || `Window ${option.value}`;
      picker.appendChild(option);
    }
    pickerRow.classList.remove('hidden');
  } else {
    pickerRow.classList.add('hidden');
  }
  updateBindingConfirmVisibility();
  $('binding-overlay').classList.remove('hidden');
}

// The explicit start-target confirm is only useful when the picker has windows
// AND a start was just refused for missing/ambiguous binding (M6.6).
function updateBindingConfirmVisibility() {
  const confirmButton = $('binding-confirm');
  if (!confirmButton) return;
  const hasOptions = $('binding-picker').options.length > 0;
  confirmButton.classList.toggle('hidden', !(hasOptions && state.pendingStartMessage));
}

// ---------------------------------------------------------------------------
// Web Push wake registration

async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return null;
  try {
    return await navigator.serviceWorker.register('./sw.js');
  } catch (error) {
    logLine(`service worker registration failed: ${error.message}`);
    return null;
  }
}

async function enablePush() {
  if (!state.vapidPublicKey) {
    logLine('push unavailable: no VAPID key from gateway');
    return;
  }
  const registration = await navigator.serviceWorker.ready;
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    logLine('push permission denied');
    return;
  }
  const subscription = await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: base64ToBytes(state.vapidPublicKey),
  });
  try {
    await sendCommand({ type: 'push_subscribe', payload: { subscription: subscription.toJSON() } });
    $('push-button').textContent = 'Push wake enabled';
    $('push-button').disabled = true;
    logLine('push wake enabled');
  } catch (error) {
    logLine(`push_subscribe failed: ${error.code || error.message}`);
  }
}

// ---------------------------------------------------------------------------
// Wire-up

async function main() {
  await registerServiceWorker();
  await loadIdentity();
  renderIdentity();

  $('pair-button').onclick = () => pairDevice().catch((error) => {
    $('pair-status').textContent = `Pairing failed: ${error.message}`;
  });
  $('connect-button').onclick = () => connect();
  $('unpair-button').onclick = () => forgetIdentity();
  $('push-button').onclick = () => enablePush();
  $('refresh-sessions').onclick = () => refreshSessions();
  $('back-to-sessions').onclick = () => {
    state.currentSessionId = null;
    $('detail-panel').classList.add('hidden');
  };
  $('load-older').onclick = () => loadTranscript(true);
  $('respond-button').onclick = () => respond();
  $('steer-button').onclick = () => steer();
  $('cancel-button').onclick = () => cancelSession();
  $('start-session').onclick = () => $('start-overlay').classList.remove('hidden');
  $('start-cancel').onclick = () => $('start-overlay').classList.add('hidden');
  $('start-confirm').onclick = () => {
    const message = $('start-message').value.trim();
    $('start-overlay').classList.add('hidden');
    if (message) startSession(message);
  };
  $('binding-retry').onclick = () => {
    $('binding-overlay').classList.add('hidden');
    refreshSessions();
  };
  $('binding-confirm').onclick = () => {
    const value = $('binding-picker').value;
    const message = state.pendingStartMessage;
    $('binding-overlay').classList.add('hidden');
    if (!message || !value) return;
    const windowId = Number(value);
    startSession(message, { window_id: Number.isFinite(windowId) ? windowId : value });
  };
  $('binding-dismiss').onclick = () => $('binding-overlay').classList.add('hidden');

  // Push-wake deep link: ?session_id=… opens the session after connect.
  const wakeSession = new URLSearchParams(location.search).get('session_id');
  if (wakeSession) {
    const openOnConnect = setInterval(() => {
      if (state.connected) {
        clearInterval(openOnConnect);
        openSession(wakeSession);
      }
    }, 500);
    setTimeout(() => clearInterval(openOnConnect), 30000);
  }
}

main();
