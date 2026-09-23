// Bridges the content scripts and the popup to mmco.app's native-messaging host. One native port,
// connected on demand; the host answers with `run` messages while a checkout runs and every
// `run` is broadcast to all connected pages and popups. When the host cannot be reached (mmco.app
// not installed, extension id not allowed), the requester gets `checkout-fallback` and opens the
// mmco:// URL instead, without progress feedback.
const HOST = 'com.aweisser.mmco';
const RETRY_AFTER_MS = 10_000;

const key = (repo) => (repo || '').toLowerCase();

let host = null;
let hostError = null;
let hostFailedAt = 0;
const clients = new Set();
const runs = new Map(); // key(repo) -> last `run` message from the host
const pending = new Map(); // key(repo) -> {repo, branch} checkout requests awaiting the host

const broadcast = (message) => {
  for (const port of clients) {
    try { port.postMessage(message); } catch { clients.delete(port); }
  }
};

const failHost = (message) => {
  hostError = message;
  hostFailedAt = Date.now();
  host = null;
  broadcast({ type: 'host-error', message, extensionId: chrome.runtime.id });
  for (const { repo, branch } of pending.values()) broadcast({ type: 'checkout-fallback', repo, branch });
  pending.clear();
};

const connectHost = () => {
  if (host) return host;
  if (Date.now() - hostFailedAt < RETRY_AFTER_MS) return null;
  const port = chrome.runtime.connectNative(HOST);
  host = port;
  port.onMessage.addListener((message) => {
    hostError = null;
    if (message?.type === 'run' && message.repo) {
      runs.set(key(message.repo), message);
      pending.delete(key(message.repo));
    }
    broadcast(message);
  });
  port.onDisconnect.addListener(() => {
    if (host !== port) return;
    const reason = chrome.runtime.lastError?.message;
    if (reason) failHost(reason);
    else host = null;
  });
  return port;
};

const toHost = (message) => {
  const port = connectHost();
  if (!port) return false;
  try {
    port.postMessage(message);
    return true;
  } catch (error) {
    failHost(error.message);
    return false;
  }
};

let nextId = 1;

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'mmco') return;
  clients.add(port);
  port.onDisconnect.addListener(() => clients.delete(port));
  port.onMessage.addListener((message) => {
    const repo = message?.repo || '';
    const id = nextId++;
    switch (message?.type) {
      case 'checkout': {
        const branch = message.branch || '';
        pending.set(key(repo), { repo, branch });
        if (!toHost({ id, type: 'checkout', repo, branch })) {
          pending.delete(key(repo));
          port.postMessage({ type: 'checkout-fallback', repo, branch });
        }
        break;
      }
      case 'status': {
        const cached = runs.get(key(repo));
        if (cached) port.postMessage(cached);
        if (!toHost({ id, type: 'status', repo }) && hostError) {
          port.postMessage({ type: 'host-error', message: hostError, extensionId: chrome.runtime.id });
        }
        break;
      }
      case 'stop':
        toHost({ id, type: 'stop', repo });
        break;
      case 'open-log':
        if (!toHost({ id, type: 'open-log', repo })) port.postMessage({ type: 'open-log-fallback' });
        break;
      default:
        break;
    }
  });
});
