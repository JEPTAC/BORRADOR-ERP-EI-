# Pruebas de aceptación V9

## Sesión

- Usuario activo ingresa.
- Usuario inactivo es rechazado.
- El menú cambia según el rol.

## Pedidos

- El conteo no está limitado a 25.
- La paginación permite recorrer más de 100 pedidos.
- Búsqueda por referencia, cliente e ID.
- Filtros de estado, ruta, tipo y asignación.
- Detalle con ítems, historial, comentarios y solicitudes.

## Operación

- Ventas crea un pedido.
- Cartera libera.
- Caja valida pago.
- Compras libera PVE.
- Recepción asigna auxiliar.
- Alistamiento inicia y termina.
- Corte inicia y termina.
- Facturación registra factura.
- Duvan opera rutas locales.
- Javier opera ruta nacional.
- Entrega registra evidencia.
- Jefe logístico cierra el pedido.

## Seguridad

- `anon` no puede ejecutar `erp_v9_execute`.
- Auditoría no opera pedidos.
- Gerencia consulta y decide, pero no ejecuta procesos.
- Auxiliar de alistamiento solo opera asignados.
- Auxiliar de corte solo opera asignados.

## Drive

- Conexión OAuth.
- Carga de factura.
- Carga de soporte de pago.
- Carga de evidencia de entrega.
