# V10.19 · Sandbox reconstruido desde raíz

## Objetivo
Reconstrucción visual y operativa del módulo **Bot de pruebas / Sandbox** para que funcione como una herramienta clara, compacta y profesional de alto volumen.

## Qué cambia
- Se elimina la presentación tipo tarjetas mezcladas y se reemplaza por una **lista operativa compacta**.
- Encabezado más sobrio y profesional.
- Creador de escenarios más claro y con mejor jerarquía.
- Estadísticas rápidas del Sandbox.
- Filas de pedidos con columnas fijas y acciones alineadas.
- Mejor lectura del escenario **Corte + Alistamiento** en paralelo.
- Sin SQL ni cambios de lógica de negocio; es una reconstrucción frontend del módulo Sandbox.

## Archivos a reemplazar
- `assets/css/app.css`
- `assets/js/modules/sandbox.js`
- `assets/js/config.js`
- `package.json`
- `service-worker.js`

## Instalación
1. Reemplazar los archivos del paquete.
2. Desplegar.
3. Desregistrar Service Worker.
4. Limpiar datos del sitio.
5. Reabrir el ERP y hacer `Ctrl + Shift + R`.

## Nota
No ejecutar SQL. Esta versión se monta sobre la base ya funcional actual.
