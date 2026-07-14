const CACHE = 'dashboard-v2';
const ASSETS = [
  '/production-dashboard-pumpa/',
  '/production-dashboard-pumpa/index.html',
  '/production-dashboard-pumpa/manifest.json',
  '/production-dashboard-pumpa/icon-192.png',
  '/production-dashboard-pumpa/icon-512.png'
];
self.addEventListener('install', e => {
  self.skipWaiting(); // не ждать закрытия всех вкладок — новая версия должна применяться сразу
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
});
self.addEventListener('activate', e => e.waitUntil(
  Promise.all([
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE).map(k => caches.delete(k))
    )),
    self.clients.claim(),
  ])
));
// Network-first: пока есть сеть — всегда отдаём актуальную версию с сервера
// (и обновляем кеш попутно). Кеш — только запасной вариант для оффлайна,
// а не постоянная копия, иначе цех годами видит версию с первого визита.
self.addEventListener('fetch', e => e.respondWith(
  fetch(e.request)
    .then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return res;
    })
    .catch(() => caches.match(e.request))
));
