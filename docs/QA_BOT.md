# QA del ERP · V10.25

La referencia vigente es **V10.25 · Robot QA total del sistema**.

El QA ya no se limita a la matriz histórica de rutas. Combina:

- 336 combinaciones finitas de enrutamiento comercial;
- 10 controles empresariales;
- 10 ramas críticas adicionales (prioridad aprobada/rechazada, cambio de ruta, reapertura, excepciones y cancelación/limpieza);
- autodiagnóstico estructural e integridad cruzada;
- pedidos `TEST-QA-*` aislados en Sandbox;
- recorrido automático de módulos y controles seguros;
- barrido responsive;
- E2E con Playwright y navegador real;
- ledger detallado por comprobación dentro de `qa_runs` / `qa_robot_checks`.

El módulo **QA total del sistema** es exclusivo de `super_admin`.

Documentación completa: `docs/QA_TOTAL_V10_25.md`.

## Matriz canónica

```text
7 estados financieros de entrada
× 3 condiciones de pago
× 4 modalidades de entrega
× 2 opciones de corte
× 2 opciones de compra
= 336 rutas
```

La matriz usa `initial_step(text,text,boolean,boolean,boolean)` y no admite volver a la firma histórica de tres parámetros.

## Ejecución backend

```sql
select public.erp_x_run_qa_v10_22(true);
select public.erp_x_qa_robot_system_contract();
```

## Ejecución total desde UI

Super Admin → **QA total del sistema** → **Ejecutar prueba total**.

## E2E externo

```bash
npm run test:total
```

Para ejecución desatendida en GitHub se requieren `ERP_QA_BASE_URL`, `ERP_QA_EMAIL` y `ERP_QA_PASSWORD` como Repository Secrets.
