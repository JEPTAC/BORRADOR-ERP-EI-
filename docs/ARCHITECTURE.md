# Arquitectura técnica

## 1. Separación respecto del ERP anterior

Esta aplicación no importa código operativo de V8 ni V9. Utiliza un esquema nuevo llamado `erp_supply`, por lo que puede instalarse en el mismo proyecto Supabase sin mezclar sus tablas con las versiones anteriores.

## 2. Modelo de operación

Cada pedido tiene:

- Un estado global.
- Una etapa actual.
- Una versión de concurrencia.
- Una tarea activa como máximo.
- Un responsable o una cola por rol.
- Un historial inmutable de eventos.

Cada operario puede mantener una sola sesión de trabajo abierta. Al finalizar o suspender una tarea, se calculan:

- Segundos calendario.
- Segundos dentro del horario laboral.
- Tiempo por etapa.
- Tiempo por operario.
- Esperas y bloqueos.

## 3. Flujo base

```text
Ventas
 ├─ Crédito/Mixto → Cartera
 │                    └─ Mixto → Caja
 └─ Contado → Caja

Después de la liberación financiera:
 ├─ PVE o compra requerida → Compras → Recepción mercancía
 └─ Sin compra → Recepción pedido

Recepción pedido → Alistamiento
 ├─ Requiere corte → Corte
 └─ Sin corte → Facturación

Corte → Facturación → Ruta de entrega → Cierre → Cerrado
```

Las reglas están centralizadas en `erp_supply.initial_step()` y `erp_supply.next_step()`.

## 4. Control de concurrencia

- `orders.version`: control optimista para impedir que una pestaña sobrescriba cambios nuevos.
- `SELECT ... FOR UPDATE`: serializa las acciones sobre el mismo pedido.
- Índice único de tarea activa: impide dos procesos simultáneos para un pedido.
- Índice único de sesión abierta por usuario: impide tomar tiempos en dos tareas a la vez.
- `idempotency_key`: evita duplicar acciones por doble clic, reintentos o mala conectividad.

## 5. Seguridad

- El esquema `erp_supply` está revocado para `anon` y `authenticated`.
- El frontend accede por RPC `erp_x_*` con `SECURITY DEFINER` y validación explícita de perfil, organización, rol y capacidad.
- El rol anónimo no recibe `EXECUTE`.
- Auditoría y eventos son append-only desde la API.

## 6. Calendario laboral

Calendario inicial:

- Lunes a viernes.
- 07:00–12:00.
- 13:40–17:30.
- 8 horas 50 minutos diarios, calculados sobre los intervalos reales.
- Festivos configurables por organización.
- Zona horaria `America/Bogota`.

## 7. Archivos

Google Drive conserva los archivos físicos. PostgreSQL almacena:

- ID del archivo.
- Nombre y tipo MIME.
- Categoría.
- Pedido y tarea asociados.
- Usuario que lo subió.
- Enlaces de visualización.

## 8. Escalabilidad funcional

La solución está preparada para agregar transacciones nuevas sin modificar el motor de pedidos:

- Nuevos módulos en `modules`.
- Nuevos pasos en `workflow_steps`.
- Capacidades por rol en `role_module_permissions` y `step_roles`.
- Reglas de asignación en `routing_rules`.
- Nuevos dominios mediante RPC específicos.
