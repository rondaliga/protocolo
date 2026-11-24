/* Livro de Protocolo — avisos no aparelho (Web Push). Não guarda nada em cache e nunca recebe descrição de documentos. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (ev) => ev.waitUntil(self.clients.claim()));

self.addEventListener('push', (ev) => {
  let d = {};
  try { d = ev.data ? ev.data.json() : {}; } catch { d = { body: ev.data ? ev.data.text() : '' }; }
  ev.waitUntil(self.registration.showNotification(d.title || 'Livro de Protocolo', {
    body: d.body || 'Toque para abrir o Livro de Protocolo.',
    icon: 'assets/icone-192.png',
    badge: 'assets/icone-192.png',
    tag: 'protocolo',
    renotify: true,
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', (ev) => {
  ev.notification.close();
  const alvo = (ev.notification.data && ev.notification.data.url) || './';
  ev.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((abas) => {
    for (const a of abas) { if ('focus' in a) return a.focus(); }
    return self.clients.openWindow(alvo);
  }));
});
