# V10.3 · Operación guiada reconstruida

Esta versión reemplaza la interacción directa basada en formularios extensos. No agrega un adaptador ni una capa sobre los módulos anteriores: los archivos funcionales de cada módulo fueron reconstruidos para trabajar con un patrón operativo único.

## Patrón de trabajo

1. Seleccionar una tarjeta de acción disponible para el rol.
2. Elegir visualmente el pedido o registro.
3. Completar pasos cortos con instrucciones y validaciones.
4. Revisar un resumen.
5. Confirmar la operación.

## Módulos reconstruidos

- Centro de operación.
- Control y creación de pedidos.
- Colas de Cartera, Caja, Compras, Recepción, Alistamiento, Corte, Facturación y Despachos.
- Inventario y movimientos.
- Solicitudes de crédito.
- Aprobaciones.
- Importación histórica.
- Administración de usuarios.
- Bot QA.
- Auditoría, VSM y reportes.

## Backend

No requiere cambios SQL. Se conservan los mismos RPC `erp_x_*` y las reglas transaccionales instaladas.
