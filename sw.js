/* 아르더짐 서비스 워커: 알림 수신 + 오프라인 안내. 건강정보·API 응답은 절대 캐시하지 않는다. */
const SHELL = 'ardor-shell-v2';
const SHELL_FILES = ['/', '/offline.html', '/icons/icon-192.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// 페이지 이동만 처리: 네트워크 우선, 실패하면 오프라인 안내. API(다른 도메인)는 손대지 않는다.
self.addEventListener('fetch', (e) => {
  const r = e.request;
  if (r.mode !== 'navigate') return;
  e.respondWith(fetch(r).catch(() => caches.match('/offline.html')));
});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  const title = d.title || '아르더짐';
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || '',
    icon: '/icons/icon-192.png',
    badge: '/icons/badge-96.png',
    tag: d.tag || 'ardor',          // 같은 tag면 알림이 쌓이지 않고 교체됨
    data: { url: d.url || '/' }
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) if ('focus' in c) { c.navigate(url); return c.focus(); }
      return self.clients.openWindow(url);
    })
  );
});
