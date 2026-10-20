/* Cumpre: recebe os lembretes e mostra-os como notificação. */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { titulo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Cumpre', {
    body: d.corpo || '', icon: 'icons/icon-192.png', badge: 'icons/favicon-32.png', tag: d.tag || undefined, data: { url: d.url || './' }
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (L) {
    for (var i = 0; i < L.length; i++) { if ('focus' in L[i]) return L[i].focus(); }
    return self.clients.openWindow(url);
  }));
});
