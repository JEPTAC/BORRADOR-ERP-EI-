# Bot QA E2E

El bot usa el mismo motor transaccional interno que utiliza el frontend. No ejecuta una simulación paralela ni modifica el flujo para “hacer pasar” las pruebas.

## Matriz comercial: 192 escenarios

```text
4 tipos de pedido
× 3 condiciones de pago
× 4 modalidades de entrega
× 2 opciones de corte
× 2 opciones de compra
= 192 escenarios
```

Para cada escenario:

1. Crea un pedido marcado como prueba.
2. Calcula la ruta esperada.
3. Ejecuta las tareas y controles requeridos.
4. Recorre el pedido hasta su estado final.
5. Compara la ruta real con la esperada.
6. Registra resultado, tiempos y error.
7. Elimina los datos de prueba cuando `cleanup = true`.

## Suite empresarial: 10 controles

1. Idempotencia de acciones repetidas.
2. Conflicto de versión optimista.
3. Una sola sesión simultánea por operario.
4. Espera, reanudación y cierre de sesiones de tiempo.
5. Checklist y puerta financiera obligatoria.
6. No entrega y reprogramación.
7. Solicitud, aprobación y ejecución de prioridad.
8. Aislamiento de la importación histórica.
9. Recepción, lote y movimiento de inventario.
10. Corte, consumo de material y desperdicio.

## Evidencia

Cada ejecución crea un registro en `qa_runs` y sus resultados en `qa_scenarios`. El historial se consulta desde el módulo **Bot QA E2E**.

## Edge Function opcional

`supabase/functions/erp-e2e-bot/index.ts` permite ejecutar:

```json
{"suite":"all","cleanup":true}
```

Valores válidos de `suite`:

- `matrix`
- `controls`
- `all`

La función puede usar el JWT del Super Admin que realiza la solicitud o los secretos `ERP_QA_EMAIL` y `ERP_QA_PASSWORD`.
