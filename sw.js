/* PERROQUET JUNIOR — Service Worker : coquille applicative disponible hors connexion.
   Les données métier ne passent jamais par ce cache : elles vivent dans IndexedDB. */
const VERSION = 'pj-shell-v2';
const SHELL = ['./', './index.html', './manifest.json', './icon.svg', './icon-192.png', './icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== location.origin) return; // API / IA : jamais mises en cache
  // réseau d'abord (mises à jour), repli sur le cache hors connexion
  e.respondWith(fetch(req).then(res => { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); return res; }).catch(() => caches.match(req).then(r => r || caches.match('./index.html'))));
});
