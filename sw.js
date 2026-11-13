// ARDOR 서비스워커 — 화면 파일만 저장하고, 데이터(Supabase)는 항상 새로 받아요.
const V = 'ardor-v1';
const SHELL = ['/', '/index.html', '/staff', '/staff.html', '/config.js', '/manifest.webmanifest', '/manifest-staff.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL).catch(() => {}))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  // 화면 파일: 인터넷 먼저, 안 되면 저장본
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(V).then(x => x.put(e.request, c)); return r; })
    .catch(() => caches.match(e.request).then(r => r || caches.match(u.pathname.startsWith('/staff') ? '/staff.html' : '/index.html'))));
});
