# Pruebas de aceptación antes de producción

## Super Admin

- Inicia sesión.
- Visualiza todos los módulos.
- Sincroniza usuarios Auth.
- Asigna roles.
- Ejecuta diagnóstico y bot QA.
- Consulta todos los pedidos y auditoría.

## Ventas

- Crea PVC, PVN, PVE y PVP.
- Registra uno y varios ítems.
- Visualiza únicamente pedidos propios y expedientes relacionados.
- Crea solicitudes de crédito.

## Cartera y Caja

- Toman una tarea.
- Inician la sesión de trabajo.
- Registran espera o bloqueo.
- Reanudan y finalizan.
- El pedido avanza según tipo y condición de pago.

## Compras y Recepción

- PVE llega a Compras.
- Compras libera hacia Recepción de mercancía.
- Recepción registra proveedor, OC, cantidades y calidad.
- Se crean artículos, lotes y movimientos.
- Se imprimen stickers.

## Alistamiento y Corte

- Auxiliar reclama o recibe tarea.
- La sesión registra tiempo laboral.
- Un pedido sin corte avanza a Facturación.
- Un pedido con corte crea paso Corte.
- Corte descuenta la chipa/lote y registra desperdicio.

## Facturación y entrega

- Se registra la factura y su soporte.
- La ruta nacional se dirige a Despacho Nacional.
- Las rutas locales se dirigen a Coordinación Logística.
- Se registra despacho, no entrega y reprogramación.
- Cierre finaliza el pedido.

## Concurrencia

- Abra el mismo pedido en dos navegadores.
- Ejecute una acción en el primero.
- El segundo debe recibir error de versión y solicitar actualización.
- Haga doble clic o repita una petición con la misma clave: solo debe existir un evento.

## Histórico

- Importe un CSV.
- Los registros deben aparecer marcados como históricos.
- No deben crear tareas ni aparecer en colas activas.

## Criterio de aprobación

No se lanza producción si existe:

- Una combinación fallida en QA.
- Un rol que opere una etapa no autorizada.
- Una tarea duplicada.
- Una sesión simultánea por operario.
- Un movimiento de inventario sin trazabilidad.
- Una acción sin evento de auditoría.
