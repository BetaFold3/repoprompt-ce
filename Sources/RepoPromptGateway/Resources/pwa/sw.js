// RepoPrompt Remote service worker: Web Push wake + notification click handling.
//
// Push payloads are identifier-only by contract ({v, kind, session_id,
// interaction_id?}); the notification never renders prompt text, transcript
// content, paths, or model names. All state is fetched after wake via the
// authenticated WebSocket catch-up flow in app.js.

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = {};
  }
  const kind = payload.kind === 'session_terminal' ? 'session_terminal' : 'waiting_for_input';
  const body = kind === 'session_terminal'
    ? 'An agent session finished.'
    : 'An agent session is waiting for your input.';
  const data = {
    v: payload.v || 1,
    kind,
    session_id: typeof payload.session_id === 'string' ? payload.session_id : null,
    interaction_id: typeof payload.interaction_id === 'string' ? payload.interaction_id : null,
  };
  event.waitUntil(self.registration.showNotification('RepoPrompt Remote', {
    body,
    tag: data.session_id || 'repoprompt-remote',
    data,
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const sessionID = event.notification.data && event.notification.data.session_id;
  const target = sessionID ? `./?session_id=${encodeURIComponent(sessionID)}` : './';
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('focus' in client) {
        if ('navigate' in client) {
          try { await client.navigate(target); } catch { /* keep existing view */ }
        }
        return client.focus();
      }
    }
    return self.clients.openWindow(target);
  })());
});
