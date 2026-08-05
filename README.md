# EI ERP Electroingeniería V10.1.0.4

> Paquete completo con instalador SQL corregido V10.0.4.


ERP transaccional independiente para controlar de extremo a extremo la operación de suministros y logística de Electroingeniería. Fue construido directamente para **Supabase PostgreSQL + Supabase Auth + Google Drive**, sin reutilizar el runtime heredado de V8/V9.

No utiliza Firebase, Firestore, `supabase-compat.js`, `DocumentRef`, snapshots simulados ni operaciones genéricas traducidas.

## Alcance funcional

- Centro de operación con KPIs, colas, SLA, carga por etapa y cuellos de botella.
- Pedidos PVC, PVN, PVE y PVP; crédito, contado y mixto; cuatro modalidades de entrega.
- Registro comercial con múltiples materiales, corte, compra, prioridad y condiciones de pago.
- Cartera, Caja, Compras, recepción documental y recepción física.
- Calidad, lotes, ubicaciones, movimientos de inventario y stickers.
- Alistamiento, corte, consumo de chipas y desperdicio.
- Facturación, rutas locales y nacionales, entrega, no entrega, reprogramación y cierre.
- Tareas por rol, asignación, toma de trabajo, sesiones, espera, bloqueo y reanudación.
- Calendario laboral exacto: lunes a viernes, 07:00–12:00 y 13:40–17:30, zona `America/Bogota`.
- Control de concurrencia, versión optimista e idempotencia.
- Checklists y puertas obligatorias antes de completar etapas.
- Aprobaciones para cancelación, prioridad, cambio de ruta, reapertura y excepciones.
- Expediente del pedido con ítems, controles, tiempos, documentos, comentarios y auditoría.
- Archivos físicos y evidencias en Google Drive.
- Importación histórica por CSV sin activar tareas ni alterar las colas operativas.
- Solicitudes de crédito, administración de usuarios y roles, VSM, auditoría y reportes.
- Bot QA sobre el mismo motor transaccional: **192 combinaciones comerciales + 10 controles empresariales = 202 verificaciones integrales**.
- Pruebas Playwright y workflows de GitHub Actions.

## Arquitectura

```text
GitHub Pages / navegador
        │
        ├── Supabase Auth
        ├── RPC public.erp_x_* nativos
        │       └── esquema privado erp_supply
        │              ├── motor transaccional
        │              ├── tareas y sesiones
        │              ├── inventario y documentos
        │              ├── controles y aprobaciones
        │              └── auditoría y QA
        └── Google Drive API
                └── archivos físicos y evidencias
```

El navegador no accede directamente a las tablas. El esquema `erp_supply` permanece oculto y la aplicación solo ejecuta RPC `SECURITY DEFINER` autorizados para usuarios autenticados.

## Instalación resumida

1. Confirme que `j.perez@ei.com.co` existe en **Supabase Authentication > Users**.
2. Ejecute [`sql/00_INSTALL_ALL.sql`](sql/00_INSTALL_ALL.sql) en Supabase SQL Editor.
3. Ejecute [`sql/99_POST_INSTALL_CHECK.sql`](sql/99_POST_INSTALL_CHECK.sql).
4. Cree un repositorio nuevo y cargue todo el contenido de esta carpeta.
5. Active GitHub Pages mediante el workflow incluido.
6. Agregue la URL de Pages a los orígenes autorizados del cliente OAuth de Google Drive.
7. Inicie sesión, sincronice usuarios Auth y configure roles.
8. Ejecute **Pruebas automáticas → Ejecutar validación completa**.

## Puerta de salida a producción

No habilite la operación real hasta que:

- `public.erp_x_health_check()` no tenga controles fallidos.
- La matriz comercial termine `192/192`.
- La suite empresarial termine `10/10`.
- Las pruebas por rol y concurrencia estén aprobadas.
- Las reglas de asignación local y nacional estén vinculadas a los usuarios Auth reales.
- Google Drive permita cargar y abrir evidencia desde la URL definitiva.

Documentos principales:

- [Instalación](docs/INSTALLATION.md)
- [Arquitectura](docs/ARCHITECTURE.md)
- [Matriz funcional](docs/FEATURE_MATRIX.md)
- [Pruebas de aceptación](docs/ACCEPTANCE.md)
- [Puerta de liberación](docs/RELEASE_GATE.md)
- [Bot QA](docs/QA_BOT.md)
- [Importación CSV](docs/CSV_IMPORT.md)
