# V10.7 · Flujo financiero simple

## Enrutamiento al crear pedidos

- **PVC y PVP:** ingresan a Cartera únicamente cuando se marca `Cliente con mora en crédito`.
- **PVN:** ingresa inicialmente a Caja únicamente cuando se marca `Pedido retenido por Caja`.
- Sin la condición correspondiente, el pedido entra directamente a `RECEPCION_PEDIDO`.
- **PVE:** conserva el ingreso a Compras.

## Popup de Cartera y Caja retenidos

1. Iniciar gestión.
2. Actualizar Estado: En gestión, En espera, Con novedad o Cerrado.
3. Al cerrar la gestión se habilita Liberar pedido.
4. Liberar pedido lo envía directamente a Recepción de pedidos.

## Facturación PVN desde Caja

Se agregó la etapa técnica `CAJA_FACTURACION`, visible dentro del módulo Caja.

1. Aceptar pedido.
2. Subir factura PDF y registrar su número.
3. Enviar a logística.

El destino final se resuelve con la modalidad del pedido: entrega en punto, recogida, despacho local o despacho nacional.

Los PVN con corte pasan primero por Corte y luego por Caja facturación. Los demás PVN pasan desde Alistamiento a Caja facturación.

## Fuera de alcance

El popup y el proceso de Solicitudes de crédito no fueron modificados.
