const CACHE = 'dashboard-v1';
const ASSETS = [
  '/production-dashboard-pumpa/',
  '/production-dashboard-pumpa/index.html',
  '/production-dashboard-pumpa/manifest.json',
  '/production-dashboard-pumpa/icon-192.png',
  '/production-dashboard-pumpa/icon-512.png'
];
self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => c.addAll(ASSETS))
));
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(keys => Promise.all(
    keys.filter(k => k !== CACHE).map(k => caches.delete(k))
  ))
));
self.addEventListener('fetch', e => e.respondWith(
  caches.match(e.request).then(r => r || fetch(e.request))
));
