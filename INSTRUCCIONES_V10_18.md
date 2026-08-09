# V10.18 · Corte agrupado por referencia y multi-carreto

## Base requerida
V10.17 en frontend y migraciones previas, incluida la corrección Sandbox 034 si se está usando el Bot.

## En una base existente
Ejecutar **únicamente**:

`sql/migrations/035_grouped_cut_multi_reel_v10_18.sql`

No ejecutar `sql/00_INSTALL_ALL.sql`.

## Qué cambia

- La unidad operativa de Corte es la **referencia/material + variante**, no el pedido.
- Un grupo puede reunir muchos pedidos y muchas medidas.
- Corte selecciona un origen físico oficial compatible con esa misma referencia/variante.
- El auxiliar confirma la cantidad real encontrada en el carreto antes de cortar.
- Si existe diferencia contra el inventario ERP, se registra el recuento físico y su movimiento de ajuste.
- El ERP calcula qué cortes completos caben en ese carreto.
- Si un carreto no alcanza para todo el grupo, ejecuta el lote posible y conserva el resto para continuar con otro carreto.
- Cada batch conserva la relación carreto → requerimiento → pedido → línea → metros consumidos.
- El remanente se actualiza en `inventory_lots`.
- La trazabilidad física también se registra en `order_item_allocations` con `allocation_type='CUTTING'`.
- Las reservas lógicas se reducen cuando una línea se ha consumido parcialmente y se consumen por completo cuando el corte termina.
- La aprobación por remanente menor de 50 m queda ligada al carreto y al plan exacto, no solamente a la referencia.
- Alistamiento puede identificar cuando una línea provino de varios carretos.

## Flujo de Corte

1. Lista de referencias pendientes.
2. Abrir una referencia.
3. Revisar pedidos, cantidades y medidas pendientes.
4. Buscar/seleccionar carreto, lote o ubicación compatible.
5. Confirmar cantidad física real y merma.
6. El ERP calcula qué cortes caben.
7. Confirmar ejecución de ese carreto.
8. Si aún faltan cortes, seleccionar el siguiente carreto.
9. Cuando toda la referencia queda lista, los pedidos continúan con su recogida en Alistamiento.

## Despliegue frontend
Después de reemplazar los archivos:
1. Desplegar en Vercel.
2. Desregistrar el Service Worker anterior.
3. Limpiar datos/caché del sitio.
4. Abrir nuevamente y usar `Ctrl + Shift + R`.
