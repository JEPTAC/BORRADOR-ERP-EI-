# V10.25.1 · Robot QA total, diagnóstico profundo y capacidad

## Objetivo

El módulo **QA total del sistema** es el gate de liberación exclusivo de Super Admin. Combina dominio, integridad, Sandbox, interfaz, responsive, E2E externo y capacidad/concurrencia.

## Corrección V10.25.1

La matriz antigua podía perder el error funcional original: si una acción fallaba dentro de la subtransacción del escenario, PostgreSQL revertía el pedido TEST, pero el manejador de errores conservaba el UUID en memoria e intentaba guardarlo en `qa_scenarios.order_id`. La FK terminaba mostrando `qa_scenarios_order_id_fkey` y ocultaba el error que realmente había ocurrido.

V10.25.1 corrige la raíz:

- `qa_existing_order_id()` solo conserva `order_id` cuando el pedido sigue existiendo.
- Cada escenario reinicia sus variables antes de ejecutarse.
- Se guardan `failure_step_code`, `failure_action`, `error_sqlstate` y `diagnostics`.
- Si el pedido fue revertido, su UUID se conserva únicamente en `diagnostics.rolledBackOrDeletedOrderId`.
- Los casos profundos se ejecutan uno por RPC/transacción: un fallo nunca revierte ni oculta los demás casos.

## Cobertura funcional

### Matriz de enrutamiento

Las 336 entradas comerciales siguen recorriéndose de extremo a extremo hasta cierre, cruzando variante financiera, condición de pago, ruta, Corte y Compra.

### Campaña profunda TOTAL

Cada tipo `PVC/PVN/PVE/PVP` se coloca en cada etapa activa y prueba:

- Nota.
- Novedad: apertura, bloqueo/espera, resolución y reanudación.
- Reporte: apertura bloqueante, resolución y reanudación.
- Espera → reanudación.
- Aprobaciones aprobadas/rechazadas.
- Cancelación aprobada/rechazada.
- Reapertura.

### Campaña EXTREME

Cruza las 336 entradas con **cada etapa real de su ruta** y prueba, por contexto aplicable:

- NOTE.
- NOVELTY.
- REPORT.
- WAIT/RESUME.
- PRIORITY aprobado y rechazado.
- CANCELLATION aprobada y rechazada.
- STOCK_EXCEPTION aprobado/rechazado.
- FLOW_EXCEPTION aprobado/rechazado.
- PAYMENT_EXCEPTION aprobado/rechazado.
- DATA_CORRECTION aprobado/rechazado.
- ROUTE_CHANGE aprobado/rechazado.
- REOPEN aprobado/rechazado.
- NO_DELIVERY con REPROGRAM, RETURN y RESOLVED en rutas de despacho.

No intenta crear permutaciones infinitas de eventos repetidos. La exhaustividad se define sobre las entradas, estados y transiciones finitas del modelo de negocio.

## Botón principal

**Ejecutar prueba total** ejecuta ahora:

1. 336 rutas end-to-end.
2. 10 controles empresariales + gates de integridad.
3. Ramas críticas.
4. Campaña EXTREME.
5. Health checks.
6. Navegación automática de todos los módulos Super Admin.
7. Controles UI seguros y errores JS/RPC.
8. Responsive 360, 390, 424, 768, 960 y 1440 px.
9. Pedidos Sandbox en cada etapa operativa.
10. Corte Sandbox moderno.
11. Limpieza de todos los `TEST-QA-*` asociados a la corrida.

## Capacidad y concurrencia

El botón **Pulso concurrente** del navegador hace una comprobación rápida con 5 → 10 → 20 → 40 solicitudes paralelas. Sirve para detectar degradaciones evidentes, pero no representa el límite de capacidad.

La medición de capacidad se hace con `tests/load/erp-capacity.js` mediante k6 y guarda el resumen en `erp_supply.qa_capacity_runs`.

Perfiles:

- `SMOKE`: verificación mínima.
- `NORMAL`: carga cotidiana.
- `BUSY`: operación intensa.
- `PEAK`: pico sostenido.
- `SPIKE`: salto brusco de 5 a 75 VUs.
- `SOAK`: 20 VUs durante 10 minutos para observar estabilidad.
- `BREAKPOINT`: incrementa carga por escalones hasta el máximo configurado o hasta romper los umbrales.

Métricas registradas:

- solicitudes totales;
- RPS;
- error rate;
- p50;
- p90;
- p95;
- p99;
- máximo;
- checks rate;
- VUs máximos;
- cantidad de lecturas y escrituras TEST.

Umbrales iniciales de certificación:

- error HTTP < 1 %;
- errores RPC < 1 %;
- checks > 99 %;
- p95 < 1800 ms;
- p99 < 3500 ms.

En `BREAKPOINT`, los umbrales críticos pueden detener el test al degradarse para no seguir aumentando carga innecesariamente. El máximo por defecto es 200 VUs y puede configurarse entre 20 y 500 con `ERP_BREAKPOINT_MAX_VUS`.

## Simulación de múltiples usuarios

Con solo `ERP_QA_EMAIL` y `ERP_QA_PASSWORD`, todos los VUs generan concurrencia real contra Supabase pero reutilizan la sesión de la cuenta QA.

Opcionalmente puede crearse el secret `ERP_QA_USER_POOL` con varias cuentas QA independientes:

```json
[
  {"email":"qa1@ei.com.co","password":"...","label":"QA-1"},
  {"email":"qa2@ei.com.co","password":"...","label":"QA-2"}
]
```

La primera cuenta debe ser `super_admin` porque crea y limpia la corrida. Para pruebas con escrituras (`write_ratio > 0`), las cuentas del pool deben tener permisos para los RPC QA utilizados. Para una medición pura de lectura con perfiles de distintos roles puede utilizarse `write_ratio=0`.

## GitHub Actions

Workflows:

- `.github/workflows/qa-total.yml`: E2E Playwright.
- `.github/workflows/qa-capacity.yml`: k6.

Secrets mínimos ya utilizados:

- `ERP_QA_EMAIL`.
- `ERP_QA_PASSWORD`.
- `ERP_QA_BASE_URL` para Playwright.

Secret opcional:

- `ERP_QA_USER_POOL` para sesiones independientes durante capacidad.

En **Actions → ERP QA Capacity → Run workflow** selecciona el perfil. Para `BREAKPOINT` también define el máximo de VUs.

## Supabase existente

Si la base ya está en V10.25.2 y tiene aplicadas las migraciones 053, 054 y 055, ejecutar únicamente:

```text
056_qa_release_stability_real_journeys_v10_25_3.sql
```

Después puede ejecutarse `99_POST_INSTALL_CHECK.sql` como verificación de solo lectura.

No ejecutar `00_INSTALL_ALL.sql` sobre una base existente. No reanudar una corrida V10.25.2 que ya acumuló timeouts/transporte: iniciar una corrida nueva V10.25.3.

## V10.25.2 · Certificación de liberación

La prueba total ya no acepta una ejecución parcial como resultado satisfactorio. El orquestador construye casos persistentes y reanudables y solo emite `CERTIFIED` cuando todos los gates están completos.

Criterios mínimos de certificación:

- 336/336 rutas canónicas ejecutadas y aprobadas como casos independientes.
- 336/336 recorridos secuenciales completos ejecutados y aprobados.
- Campaña EXTREME: ejecutados = planificados, fallidos = 0, pendientes = 0 y transporte = 0.
- Todos los módulos visibles para Super Admin abren sin errores de runtime/RPC.
- 54 comprobaciones responsive (6 anchos × 9 módulos) aprobadas.
- 14 pruebas Sandbox UI abren la tarjeta y ejecutan su acción primaria; `found=true` sin `opened=true` ya no aprueba.
- Integridad global, Workforce, colas, reservas y diagnósticos estructurales/flujo aprobados.
- 0 pedidos `TEST-QA` remanentes después de la limpieza.

Los errores de transporte se reintentan por caso y nunca detienen los casos restantes. Las ejecuciones incompletas pueden reanudarse desde el portal QA. La antigua matriz monolítica susceptible a `statement_timeout` no forma parte del gate de liberación V10.25.2.

## V10.25.3 · Estabilidad de certificación

Las rutas canónicas y los recorridos completos ya no se ejecutan en una sola sentencia larga. Cada invocación procesa una etapa operativa real y persiste el avance. El orden es 336 rutas, 336 recorridos completos y después la campaña EXTREME. La concurrencia deliberadamente se limita a 2 workers para rutas/recorridos y 3 para casos profundos.

Los recorridos crean los prerrequisitos que un usuario real debe registrar: validación financiera, orden de compra, recepción física, asignación de auxiliares, Corte paralelo con pausa/reanudación/evidencia/recogida, Alistamiento, factura o Anexo PVP, guía + destino, evidencia de entrega y cierre. Los archivos QA son registros sintéticos exclusivos de pedidos TEST y no escriben bytes en Drive.

Una corrida de V10.25.2 con timeouts/transporte no debe reanudarse: iniciar una corrida nueva V10.25.3.

