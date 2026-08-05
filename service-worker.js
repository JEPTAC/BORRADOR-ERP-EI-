const CACHE = "ei-erp-v9-supabase-native-20260805-1";
const CORE = [
  "./",
  "./index.html",
  "./assets/css/app.css?v=9.0.0",
  "./assets/js/app.js?v=9.0.0",
  "./assets/js/config.js",
  "./assets/js/supabase.js",
  "./assets/js/api.js",
  "./assets/js/ui.js",
  "./assets/js/drive.js",
  "./assets/img/app-icon.svg",
  "./assets/img/logo.jpeg"
];
self.addEventListener("install", event => event.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())));
self.addEventListener("activate", event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.hostname.includes("supabase.co") || url.hostname.includes("googleapis.com") || url.hostname.includes("jsdelivr.net")) return;
  event.respondWith(fetch(event.request).then(response => {
    const copy = response.clone();
    caches.open(CACHE).then(c => c.put(event.request, copy));
    return response;
  }).catch(() => caches.match(event.request).then(r => r || caches.match("./index.html"))));
});
