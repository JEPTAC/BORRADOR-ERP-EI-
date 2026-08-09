# ERP EI V10.16 · Sandbox exclusivo Super Admin

## Objetivo
Crear pedidos manuales de prueba completamente aislados para recorrer los módulos reales del ERP sin contaminar producción.

## Aislamiento
Los pedidos creados por el bot usan `is_test = true`, `source = QA_BOT` y `metadata.manualSandbox = true`.

- Solo `super_admin` puede verlos y operarlos.
- No usan el maestro Siesa ni materiales del Excel.
- No crean reservas ni consumen inventario real.
- Corte usa carretos ficticios internos del Sandbox.
- Los archivos de prueba se registran de forma simulada y NO se suben al Drive institucional.
- No entran a Dashboard, VSM, SLA, Centro de Excepciones, Pareto/analítica ni conteos productivos.
- Novedades, reportes o aprobaciones creados dentro de un pedido TEST afectan únicamente la prueba y quedan fuera de métricas productivas.

## Escenarios disponibles
- Flujo completo
- Cartera
- Caja
- Compras PVE
- Recepción
- Alistamiento
- Corte
- Facturación
- Caja / factura PVN
- Despacho
- Cierre

El Super Admin puede crear de 1 a 10 pedidos, abrir el popup real, abrir la bandeja del módulo en Modo Sandbox, mover manualmente la prueba a otra etapa y eliminar una o todas las pruebas manuales.

## Instalación sobre una base existente
1. La base requerida es V10.15 con la migración 032 aplicada.
2. Ejecutar una sola vez `sql/migrations/033_superadmin_sandbox_bot_v10_16.sql` en Supabase SQL Editor.
3. NO ejecutar `sql/00_INSTALL_ALL.sql` sobre una base existente.
4. Reemplazar/agregar las rutas indicadas en `RUTAS_A_REEMPLAZAR.txt` y desplegar.
5. Desregistrar el Service Worker, limpiar datos del sitio y recargar con Ctrl+Shift+R.
6. Iniciar sesión con un usuario que tenga rol `super_admin`. Aparecerá `Control y análisis > Bot de pruebas`.

## Instalaciones nuevas
`sql/00_INSTALL_ALL.sql` ya incluye la migración 033, pero se mantiene únicamente para instalaciones desde cero.
