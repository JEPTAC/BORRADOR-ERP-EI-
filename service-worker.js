const CACHE="erp-electroingenieria-v10-30-0-modern-erp-20260814";
const ASSETS=[
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./assets/css/app.css",
  "./assets/img/logo-electroingenieria.png",
  "./assets/img/iso-electroingenieria.png",
  "./assets/js/main.js",
  "./assets/js/config.js",
  "./assets/js/core/icons.js",
  "./assets/js/core/layout.js",
  "./assets/js/modules/active-work.js",
  "./assets/js/modules/work-clock.js",
  "./assets/js/modules/workforce.js",
  "./assets/js/modules/order-cancellation.js",
  "./assets/js/modules/support-flow.js",
  "./assets/js/modules/receiving-order.js",
  "./assets/js/modules/financial-flow.js",
  "./assets/js/modules/picking-flow.js",
  "./assets/js/modules/cutting-flow.js",
  "./assets/js/modules/shipping-flow.js",
  "./assets/js/modules/queue.js",
  "./assets/js/modules/orders.js",
  "./assets/js/modules/inventory.js",
  "./assets/js/services/api.js",
  "./assets/js/services/supabase.js",
  "./assets/js/services/materials.js",
  "./assets/js/services/drive.js",
  "./assets/js/services/location.js",
  "./assets/js/services/pdf-order-reader.js"
];
self.addEventListener("install",event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener("activate",event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",event=>{
  if(event.request.method!=="GET"||new URL(event.request.url).origin!==location.origin)return;
  event.respondWith(fetch(event.request).then(response=>{const clone=response.clone();caches.open(CACHE).then(c=>c.put(event.request,clone));return response}).catch(()=>caches.match(event.request).then(r=>r||caches.match("./index.html"))));
});
