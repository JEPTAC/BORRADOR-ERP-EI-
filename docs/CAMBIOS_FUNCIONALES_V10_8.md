# V10.8 · Alistamiento guiado y pedidos parciales

## Popup de Alistamiento

1. Tomar pedido o Retomar pedido.
2. Verificación de mercancía línea por línea.
3. Dos decisiones por línea: **Encontrado** y **No encontrado**.
4. Si se marca **No encontrado**, la novedad y su motivo son obligatorios.
5. Confirmación final mediante **Enviar a facturación**.

## Pedido completo

Cuando todas las líneas se encuentran, la ronda se registra como completa y el pedido continúa al siguiente proceso. Si existen cortes, conserva la ruta previa por Corte antes de facturación.

## Pedido parcial

Cuando falta al menos una línea:

- La ronda se registra como parcial.
- El pedido continúa con las líneas encontradas.
- Todas las colas muestran la etiqueta **Pedido parcial**.
- Las líneas encontradas no vuelven a aparecer en una ronda posterior.
- Cuando la salida anterior termina, el mismo pedido aparece en **Pedidos parciales pendientes** dentro de Alistamiento.
- Al pulsar **Retomar pedido**, se crea una nueva ronda del mismo pedido y solamente se muestran las líneas faltantes.

No se duplica el número de pedido ni se crea una orden comercial independiente.

## VSM y dashboard

Los pedidos que tuvieron una salida parcial muestran dos tiempos:

- **Tiempo parcial:** tiempo productivo de la primera ronda de Alistamiento.
- **Tiempo real:** tiempo laboral desde el inicio de la primera ronda hasta la finalización de la mercancía pendiente; mientras siga pendiente, se calcula hasta el momento de la consulta.

El pedido aparece una sola vez con el número de rondas y las líneas todavía pendientes.
