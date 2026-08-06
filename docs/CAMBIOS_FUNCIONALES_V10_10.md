# V10.10 · Corte primero

## Flujo

- Pedido sin corte: Recepción → Alistamiento → Facturación.
- Pedido con corte: Recepción → Corte → Alistamiento → Facturación.
- El backend bloquea el cierre de Alistamiento mientras exista un corte sin terminar o sin recoger.

## Centro de corte

- Módulo independiente, no usa la cola estándar.
- Agrupa pendientes por referencia y descripción.
- Consolida cortes, longitud total y pedidos asociados.
- Permite ejecutar todos los cortes del grupo con un mismo carreto.
- Calcula longitud inicial, consumo, merma y remanente.
- Registra lote, movimientos de inventario, trabajo de corte y trazabilidad por pedido.
- Acciones individuales: `Carreto completo` y `No necesita corte`.

## Cortes por recoger

- Alistamiento recibe una bandeja independiente de cortes listos.
- Una referencia resuelta individualmente puede recogerse antes de que terminen los demás cortes del pedido.
- El pedido permanece en Corte hasta completar todas sus referencias.
- La recogida puede confirmarse parcialmente; solo desaparecen las referencias entregadas.
- Cuando todo Corte termina, el pedido pasa a Alistamiento y continúa con la verificación normal.
