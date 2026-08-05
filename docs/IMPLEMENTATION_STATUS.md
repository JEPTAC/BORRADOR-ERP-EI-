# Estado de implementación

## Incluido

- Esquema independiente `erp_supply`.
- Supabase Auth, RPC nativos y esquema privado.
- Motor transaccional completo de pedidos.
- Roles, permisos, colas, tareas, sesiones y calendario laboral.
- Creación, paginación, búsqueda, expediente y acciones del pedido.
- Cartera, Caja, Compras, Recepción, Alistamiento, Corte, Facturación, entrega y cierre.
- Calidad, inventario, lotes, movimientos y stickers.
- Crédito, aprobaciones, comentarios, Drive y auditoría.
- Importación histórica reanudable por CSV.
- VSM, reportes y administración.
- Matriz QA de 192 escenarios.
- Suite empresarial de 10 controles.
- Pruebas Playwright y workflows de Pages/E2E.

## Validación estática completada

- Sintaxis JavaScript.
- Imports y rutas locales.
- Inclusión de las 16 migraciones en el instalador consolidado.
- Correspondencia entre RPC usados por el frontend y RPC definidos en SQL.
- Ausencia de accesos directos `.from(...)` desde el navegador.
- Ausencia de Firebase, Firestore y adaptadores heredados.

## Validación obligatoria en el proyecto real

La instalación y el bot aún deben ejecutarse contra el proyecto Supabase real. La aplicación no debe etiquetarse como producción hasta:

- Ejecutar todas las migraciones sin error.
- Vincular las cuentas Auth reales.
- Obtener `192/192` en la matriz comercial.
- Obtener `10/10` en controles empresariales.
- Aprobar pruebas manuales por rol, concurrencia y Google Drive.
