// Bump CACHE_VERSION whenever checklist.html (or any cached asset) changes,
// so installed/offline copies pick up the update instead of serving stale files.
var CACHE_VERSION = "v36";
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

  // Só http(s) entra no cache. Extensão do navegador tem esquema próprio
  // (chrome-extension:) e o cache recusa — virava erro vermelho no console
  // sem nada a ver com o app.
  if (!/^https?:$/.test(new URL(event.request.url).protocol)) return;

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

/* ============================================================
   NOTIFICAÇÕES
   Esta parte roda com o app fechado — é ela que recebe o aviso do
   servidor e o mostra na tela do celular.
   ============================================================ */

self.addEventListener("push", function (event) {
  var dados = {};
  try { dados = event.data ? event.data.json() : {}; } catch (e) { dados = {}; }

  // O navegador exige que todo aviso recebido vire uma notificação visível.
  // Se algo vier vazio ou quebrado, mostra algo genérico em vez de silenciar —
  // silenciar repetidamente faz o navegador cortar o direito de notificar.
  var titulo = dados.titulo || "Checklist";
  var opcoes = {
    body: dados.corpo || "",
    icon: "./icon-192.png",
    badge: "./icon-192.png",
    lang: "pt-BR",
    // tag igual substitui o aviso anterior em vez de empilhar: dois resumos
    // do mesmo dia viram um só na barra de notificações.
    tag: dados.tag || "checklist",
    renotify: true,
    data: { url: dados.url || "./checklist.html" }
  };
  event.waitUntil(self.registration.showNotification(titulo, opcoes));
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();
  var destino = (event.notification.data && event.notification.data.url) || "./checklist.html";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (abertas) {
      // Se o app já está aberto em algum lugar, traz para a frente em vez de
      // abrir uma segunda cópia.
      for (var i = 0; i < abertas.length; i++) {
        if (abertas[i].url.indexOf("checklist") !== -1 && "focus" in abertas[i]) {
          return abertas[i].focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(destino);
    })
  );
});
