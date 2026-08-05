const CACHE="erp-supply-enterprise-v10-20260805-2";
const ASSETS=["./","./index.html","./assets/css/app.css","./assets/js/main.js","./assets/js/config.js"];
self.addEventListener("install",event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener("activate",event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",event=>{
  if(event.request.method!=="GET"||new URL(event.request.url).origin!==location.origin)return;
  event.respondWith(fetch(event.request).then(response=>{const clone=response.clone();caches.open(CACHE).then(c=>c.put(event.request,clone));return response}).catch(()=>caches.match(event.request).then(r=>r||caches.match("./index.html"))));
});
