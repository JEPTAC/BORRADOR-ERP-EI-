# V10.21 · Corte guiado reconstruido

## Objetivo
Reconstruir los popups de Corte para que acompañen la lógica V10.20 de tiempo, pausa, multi-carreto y evidencia final.

## Flujo visual
1. **Iniciar corte**: revisión corta + una sola acción principal.
2. **Revisar**: pedidos y medidas pendientes.
3. **Carreto**: buscar y seleccionar origen compatible; confirmar cantidad física.
4. **Confirmar**: revisar consumo, remanente y pedidos afectados antes de descontar inventario.
5. **Foto final**: evidencia obligatoria y cierre de la ejecución.

Las acciones especiales `Carreto completo` y `No necesita corte` permanecen ocultas dentro de `Caso especial`.

## Pausas
El botón **Pausar corte** está visible durante la ejecución. Al pausar se presenta una pantalla dedicada con un único botón **Continuar corte**.

## Evidencia
Cuando termina el corte físico, la interfaz cambia a una pantalla dedicada donde la acción principal es **Anexar foto y finalizar corte**. No se libera a Alistamiento antes de ese cierre.

## Archivos a reemplazar
- `assets/css/app.css`
- `assets/js/config.js`
- `assets/js/modules/cutting-flow.js`
- `package.json`
- `service-worker.js`

## SQL
No hay SQL nuevo. Esta versión utiliza la estructura V10.20 / migración 036 ya aplicada.
