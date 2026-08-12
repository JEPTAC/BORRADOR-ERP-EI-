# ERP Electroingeniería · V10.25.0

Base consolidada del ERP sobre V10.24, con **Robot QA total exclusivo de Super Admin** como gate de liberación.

## Estado actual

- Flujo comercial/logístico desde Ventas hasta cierre, con Cartera/Caja condicionales, Compras, Recepción, Alistamiento, Corte agrupado, Facturación y Despachos.
- Inventario oficial Siesa y reservas.
- Sandbox aislado `TEST-*` / `QA_BOT`.
- Cancelación de pedidos por autorización.
- Mi Jornada, planificación, catálogo dinámico, aprobación de actividades y ocupación integrada.
- Responsive estructural para escritorio, tablet y móvil.
- QA V10.25: 336 rutas comerciales, 10 controles empresariales, gates de integridad, recorrido automático de módulos, pruebas Sandbox por etapa, responsive y E2E Playwright.

## Instalación

Consulta `sql/LEEME_SQL.txt`.

- **Instalación nueva:** `sql/00_INSTALL_ALL.sql`.
- **Base existente:** aplicar únicamente las migraciones incrementales que todavía no estén instaladas.
- No ejecutar archivos de `sql/legacy/`.

Para actualizar desde V10.24 a V10.25, aplicar `sql/migrations/053_total_system_qa_robot_v10_25.sql` y luego `sql/99_POST_INSTALL_CHECK.sql`.

## Robot QA total

Documentación: `docs/QA_TOTAL_V10_25.md`.

El módulo **QA total del sistema** es exclusivo de `super_admin`. La capa externa de navegador real se ejecuta con:

```bash
npm run test:total
```

o mediante el workflow manual `.github/workflows/qa-total.yml`.
