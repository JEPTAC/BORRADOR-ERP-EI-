# ERP Electroingeniería · V10.22.0

Revisión integral de experiencia de usuario e integridad de flujos sobre la base funcional V10.21.4 y el shell responsive V10.21.5.

## Qué cambia

- Sistema canónico de diálogos: una sola geometría base para modal, cabecera, cuerpo y pie.
- Comportamiento accesible centralizado: foco contenido, `Esc`, retorno de foco, fondo inerte y atributos ARIA.
- Navegación responsive afinada y búsqueda global disponible también en móvil.
- Corrección transversal de dobles envíos y referencias a `event.currentTarget` después de operaciones asíncronas.
- QA de enrutamiento actualizada de la matriz histórica de 192 a 336 combinaciones con mora y retención de Caja.
- Autodiagnóstico V10.22 para la arquitectura vigente de Corte y sesiones concurrentes, más health check alineado con 336 rutas.
- Gate de servidor: una línea que requiere Corte no puede quedar alistada antes de estar `READY + COLLECTED`.
- Recepción PVE parcial/acumulada endurecida de extremo a extremo: saldo por línea, idempotencia, identidad oficial Siesa y gate de cierre.
- `Mercancía OK` de PVE publica lote y movimiento de inventario oficial de forma idempotente.
- Diagnóstico `erp_x_flow_integrity()` para inconsistencias cruzadas entre Corte, Alistamiento, Recepción, inventario y sesiones.
- SQL consolidado: migraciones 034 y 038–044 incorporadas al instalador; el antiguo parche raíz V10.4 queda solo en `sql/legacy/`.

## Instalación

Consulta `sql/LEEME_SQL.txt`.

- Instalación nueva: `sql/00_INSTALL_ALL.sql`.
- Base existente: aplicar únicamente las migraciones nuevas que aún no estén instaladas.
- No ejecutar archivos de `sql/legacy/`.

## Auditoría

El detalle de hallazgos, combinaciones revisadas, correcciones y pruebas pendientes contra una base autenticada está en `docs/AUDITORIA_V10_22.md`.

La norma visual para nuevas ventanas está en `docs/UX_DIALOG_SYSTEM_V10_22.md`.
