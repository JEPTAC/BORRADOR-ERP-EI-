# V10.16.2 · Refuerzo visual ERP + Sandbox paralelo Corte/Alistamiento

## Qué incluye

### 1) Mejora visual global
- Popups con mejor jerarquía visual.
- Títulos y textos más grandes.
- Botones más consistentes y legibles.
- Botones **X / cerrar** mucho más visibles.
- Refuerzo de contraste para evitar texto oscuro sobre fondos oscuros.
- Tarjetas Sandbox más claras y profesionales.

### 2) Mejora del Bot Sandbox
- Cuando el pedido TEST requiere corte y está en **ALISTAMIENTO**, la tarjeta ahora muestra:
  - **Abrir popup**
  - **Alistamiento**
  - **Corte paralelo**
- Esto facilita probar el flujo en simultáneo.

### 3) Hotfix SQL Sandbox paralelo
El archivo SQL crea y mantiene requerimientos de corte sintéticos para pedidos TEST, de modo que:
- el pedido pueda mostrar **Corte en paralelo** desde Alistamiento,
- Corte Sandbox pueda dejar el corte en **READY**,
- luego Alistamiento pueda recoger esos cortes y continuar.

---

## Archivos frontend a reemplazar
1. `assets/css/app.css`
2. `assets/js/modules/sandbox.js`

## SQL a ejecutar
- `sql/034_sandbox_parallel_cut_hotfix_v10_16_2.sql`

---

## Orden recomendado
1. Reemplazar los archivos frontend.
2. Ejecutar el SQL hotfix en Supabase.
3. Recargar la app con cache limpio.
4. Probar en Sandbox el escenario **CORTE**.

---

## Prueba sugerida
1. Entrar al **Bot Sandbox**.
2. Crear escenario **CORTE**.
3. Abrir el popup del pedido y tomar **Alistamiento**.
4. Desde la tarjeta del bot usar **Corte paralelo**.
5. Ejecutar el corte ficticio.
6. Volver al popup del pedido para confirmar la recogida y continuar la verificación.
