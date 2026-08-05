// Bump CACHE_VERSION whenever checklist.html (or any cached asset) changes,
// so installed/offline copies pick up the update instead of serving stale files.
var CACHE_VERSION = "v6";
var CACHE_NAME = "checklist-" + CACHE_VERSION;
var ASSETS = [
  "./checklist.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", function (event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      return cache.addAll(ASSETS);
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.filter(function (key) { return key !== CACHE_NAME; })
            .map(function (key) { return caches.delete(key); })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener("fetch", function (event) {
  if (event.request.method !== "GET") return;

  // As chamadas ao Supabase NUNCA passam pelo cache. Se a rede cair, a queda
  // precisa ser uma queda — servir uma resposta antiga como se fosse atual
  // faria o app achar que o servidor está desatualizado e sobrescrever dados
  // bons com velhos.
  if (event.request.url.indexOf("supabase.co") !== -1) return;

  event.respondWith(
    fetch(event.request).then(function (response) {
      var copy = response.clone();
      caches.open(CACHE_NAME).then(function (cache) { cache.put(event.request, copy); });
      return response;
    }).catch(function () {
      return caches.match(event.request).then(function (cached) {
        return cached || caches.match("./checklist.html");
      });
    })
  );
});
