# Puerta de liberación

La puesta en producción requiere aprobar todos los bloques.

## Base y seguridad

- Instalador SQL ejecutado sin error.
- Esquema `erp_supply` oculto a `anon` y `authenticated`.
- RPC `erp_x_*` con `SECURITY DEFINER`.
- `anon` sin permiso de ejecución.
- Sin acceso directo a tablas desde el navegador.

## Integridad

- Cero pedidos activos sin exactamente una tarea activa.
- Cero sesiones abiertas fuera de una tarea `IN_PROGRESS`.
- Una sola sesión abierta por operario.
- Etapa del pedido alineada con su tarea activa.
- Índice de idempotencia presente.
- Auditoría automática activa en dominios sensibles.

## QA automático

- Última matriz: `PASSED`, `192/192`, `0` fallos.
- Última suite: `PASSED`, `10/10`, `0` fallos.
- `erp_x_health_check()` sin controles fallidos.

## Prueba operativa

- Un caso representativo completado por cada rol.
- Un pedido de cada tipo PVC/PVN/PVE/PVP cerrado correctamente.
- Rutas local y nacional verificadas.
- Espera, bloqueo, no entrega, reprogramación y aprobación verificadas.
- Recepción, inventario, corte, factura y evidencia Drive verificadas.
- Conflicto de edición probado en dos navegadores.

## Liberación

La fecha, responsable y versión aprobada deben registrarse en el acta interna de liberación. Ante cualquier fallo, se corrige en el repositorio de pruebas y se repite la puerta completa.
