# V10.20 · Corte medido por referencia + evidencia final

## Base requerida
- Frontend V10.19.
- Migración 035 de Corte multi-carreto ya aplicada.

## Cambio estructural
Corte deja de ser únicamente una suma de batches/carretos y pasa a tener una entidad formal `cut_executions` por referencia.

Una ejecución:
1. Se inicia explícitamente con **Iniciar corte por referencia**.
2. Congela los pedidos y cortes que forman parte de esa ejecución.
3. Conserva todos los carretos/batches dentro de la misma ejecución.
4. Puede pausarse y reanudarse sin perder tiempo ni trazabilidad.
5. Cuando el último corte físico termina pasa a `WAITING_EVIDENCE`.
6. Los cortes NO se liberan a Alistamiento todavía.
7. Se exige una foto final del material/carretos ya cortados.
8. La foto se registra en Drive institucional.
9. Solo entonces se registra la hora final y se liberan los cortes para recogida.

## Tiempos
Se conservan:
- Tiempo calendario desde inicio a foto final.
- Tiempo laboral.
- Tiempo pausado.
- Tiempo activo/productivo medido.
- Cantidad de carretos utilizados.
- Metros cortados.
- Merma acumulada.

Las Novedades/Reportes bloqueantes pausan automáticamente una ejecución activa de Corte. La reanudación es manual.

## Sandbox
La misma secuencia se puede probar en Sandbox. La foto es simulada y NO sube bytes a Google Drive.

## Instalación
1. Ejecutar solamente `sql/migrations/036_cut_execution_timing_evidence_v10_20.sql`.
2. Reemplazar los archivos indicados en `RUTAS_A_REEMPLAZAR.txt`.
3. Desplegar.
4. Desregistrar el Service Worker y limpiar datos del sitio.
5. Reabrir el ERP y hacer Ctrl+Shift+R.

No ejecutar `sql/00_INSTALL_ALL.sql` en una base existente.
