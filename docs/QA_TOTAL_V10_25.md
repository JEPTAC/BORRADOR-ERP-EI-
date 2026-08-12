# V10.25 · Robot QA total del sistema

## Objetivo

El Robot QA total es el gate de liberación exclusivo de Super Admin. No sustituye una sola clase de prueba: coordina pruebas de dominio, integridad, Sandbox, interfaz, responsive y un E2E externo con navegador real.

## Qué significa «total»

Para las entradas comerciales finitas se ejecuta la matriz exhaustiva vigente de 336 combinaciones. Para caminos que pueden crecer de forma combinatoria (parciales, devoluciones, reprogramaciones, excepciones, Corte, evidencias, cancelaciones, etc.) se aplica cobertura explícita por familia de ramas y gates, en lugar de repetir el mismo camino miles de veces sin aumentar cobertura.

Capas:

1. **Dominio**: matriz de 336 rutas + 10 controles empresariales.
2. **Ramas críticas**: prioridad aprobada/rechazada, cambio de ruta en despacho, reapertura, excepciones de inventario/flujo/pago/datos y limpieza de cancelación.
3. **Integridad**: `erp_x_v10_22_self_check`, `erp_x_flow_integrity`, health global, reservas, colas, Workforce y contratos estructurales V10.25.
4. **Sandbox operativo**: pedidos `TEST-QA-*` aislados con `is_test=true`, `source=QA_BOT`, ligados a la ejecución `TOTAL_ROBOT`.
5. **UI crawler interno**: navega todos los módulos visibles para Super Admin, abre controles no destructivos, detecta `.module-error`, excepciones JS, promesas rechazadas, RPC 4xx/5xx y overflow horizontal.
6. **Responsive**: 360, 390, 424, 768, 960 y 1440 px en módulos críticos.
7. **Playwright externo**: navegador real, autenticación de una cuenta QA Super Admin, navegación, Sandbox, screenshots/video en fallo y trazas de diagnóstico.

## Aislamiento de producción

Toda mutación creada por el Robot usa pedidos `TEST-QA-*`, `source=QA_BOT` e `is_test=true`. El Robot registra `qa_run_id` y al finalizar ejecuta limpieza únicamente sobre pedidos TEST ligados a esa ejecución. Un fallo de limpieza se registra como defecto QA en vez de ocultarse.

El Robot no debe utilizar pedidos productivos como fixture de escritura.

## Portal Super Admin

Módulo: **QA total del sistema**.

Acciones:

- **Ejecutar prueba total**: orquesta todas las capas internas.
- **336 combinaciones**: solo matriz comercial.
- **10 controles**: controles empresariales.
- **Backend integral**: matriz + controles + gates.
- **Verificar colas**: diagnósticos dirigidos.

Cada ejecución `TOTAL_ROBOT` conserva el detalle en `erp_supply.qa_robot_checks` con capa, suite, módulo, estado, severidad, entrada, esperado, real, evidencia, error y duración.

## E2E Playwright

Archivos:

- `tests/qa-total/helpers.js`
- `tests/qa-total/total-system.spec.js`
- `playwright.config.js`
- `.github/workflows/qa-total.yml`

El workflow se ejecuta manualmente desde GitHub Actions y nunca contiene credenciales en el repositorio.

### Configuración única requerida en GitHub

Crear una cuenta **dedicada de QA** con rol `super_admin` y registrar estos Repository Secrets:

- `ERP_QA_BASE_URL`: URL desplegada del ERP.
- `ERP_QA_EMAIL`: correo de la cuenta QA Super Admin.
- `ERP_QA_PASSWORD`: contraseña de la cuenta QA Super Admin.

Después: **Actions → ERP QA Total → Run workflow**.

La cuenta QA debe ser exclusiva para automatización. No utilizar la cuenta personal cotidiana de un administrador.

## Ejecución local

```bash
ERP_TEST_EMAIL="qa@example.com" \
ERP_TEST_PASSWORD="..." \
ERP_BASE_URL="https://erp.example.com" \
RUN_TOTAL_ROBOT="true" \
npm run test:total
```

Para depuración interactiva:

```bash
npm run test:total:headed
```

## Supabase

Sobre una base existente V10.24 ejecutar únicamente:

```text
053_total_system_qa_robot_v10_25.sql
```

Luego `99_POST_INSTALL_CHECK.sql`.

No ejecutar `00_INSTALL_ALL.sql` sobre una instalación existente.

## Gate de liberación recomendado

No liberar una versión si ocurre cualquiera de estos casos:

- matriz comercial menor a 336/336;
- un control empresarial falla;
- un gate de integridad falla;
- un chequeo CRITICAL/HIGH del Robot queda FAILED;
- un pedido `QA_BOT` aparece como no TEST;
- falla la limpieza de fixtures;
- Playwright registra `pageerror`, rechazo de promesa, `.module-error` o HTTP 4xx/5xx inesperado;
- existe overflow horizontal en los viewports críticos;
- el E2E no puede completar la navegación Sandbox definida.

Una advertencia (`WARNING`) requiere revisión, pero no equivale por sí sola a una aprobación automática de release.
