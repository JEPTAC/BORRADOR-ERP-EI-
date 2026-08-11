# V10.21.5 · Responsive móvil reconstruido

## Alcance
Reconstrucción estructural del shell responsive del ERP. No se agrega una capa visual sobre el menú anterior: se sustituyen las reglas heredadas del sidebar/topbar por un único subsistema canónico de navegación.

## Comportamiento móvil
- Menú lateral convertido en drawer real.
- Botón de cierre dentro del drawer.
- Fondo de bloqueo detrás del menú.
- Cierre al tocar fuera.
- Cierre con tecla Escape.
- Cierre automático al navegar a otro módulo.
- Bloqueo del scroll de la página mientras el menú está abierto.
- Scroll independiente dentro del menú.
- Control de foco dentro del drawer.
- Restitución del foco al botón de menú al cerrar.
- `aria-expanded`, `aria-hidden` e `inert` sincronizados.
- Altura dinámica `100dvh` y safe areas para móviles.
- Al cambiar entre móvil/escritorio se normaliza el estado del drawer.

## Escritorio
El sidebar continúa fijo a la izquierda. La reconstrucción no modifica lógica de negocio ni módulos.

## Archivos a reemplazar
- `assets/css/app.css`
- `assets/js/core/layout.js`
- `assets/js/config.js`
- `package.json`
- `service-worker.js`

## Base requerida
V10.21.4 ya desplegada.

## SQL
No hay SQL nuevo.

## Después del despliegue
1. Desregistrar Service Worker.
2. Limpiar datos/cache del sitio.
3. Cerrar todas las pestañas del ERP.
4. Abrir nuevamente.
5. Forzar recarga.
