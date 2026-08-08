# ERP EI V10.12.0 · Flujos paralelos, excepciones y aprobaciones

## Base
Aplicar sobre V10.11.9.

## Instalación en una base existente
1. Combinar los archivos del paquete diferencial con el repositorio V10.11.9 respetando las rutas.
2. En Supabase SQL Editor ejecutar **una sola vez** `/sql/migrations/028_parallel_flow_exceptions_approvals_v10_12.sql`.
3. No ejecutar `/sql/00_INSTALL_ALL.sql` ni migraciones anteriores.
4. Desplegar el repositorio completo fusionado.
5. En el navegador: F12 → Application → Service Workers → Unregister; limpiar datos del sitio; cerrar pestañas; abrir y recargar con Ctrl+Shift+R.

## Cambios funcionales principales
### Alistamiento y Corte paralelos
- Después de Recepción, la tarea principal pasa a Alistamiento.
- Las líneas sin corte se verifican inmediatamente en Alistamiento.
- Solo las líneas `requires_cut` trabajan en Corte como subflujo paralelo.
- Las líneas terminadas pasan a `Cortes por recoger` y se incorporan al mismo pedido.
- Alistamiento puede guardar avance mientras espera Corte, pero no puede enviar a Facturación hasta que los cortes requeridos estén terminados y recogidos.
- Pedidos activos que hubieran quedado en la etapa CORTE por la versión anterior se migran de forma segura a Alistamiento sin borrar sus cortes ni historial.

### Nota / Novedad / Reporte globales
Disponibles en los popups operativos:
- **Nota:** trazabilidad menor; no bloquea el pedido.
- **Novedad:** etiqueta `Espera con novedad`; pausa el flujo hasta resolución.
- **Reporte:** etiqueta `Reporte`; bloquea el flujo hasta resolución.
- Al resolver la última incidencia bloqueante el pedido vuelve a su tarea vigente sin perder responsable ni trazabilidad.
- El faltante de una línea marcado como `No encontrado` en Alistamiento sigue siendo parte del proceso de pedido parcial; no se convierte automáticamente en una Novedad global.

### No entrega
- Ventas o super_admin generan el reporte de no entrega.
- Se crea un Reporte bloqueante dirigido a Logística.
- Logística abre, gestiona y cierra el reporte; después el flujo puede continuar según la resolución.

### PVE · Compras y Recepción en paralelo
- Mientras el PVE está en Compras también aparece en una bandeja paralela de Recepción.
- Recepción usa `Marcar espera` y luego `Mercancía OK`.
- No se crea una segunda tarea principal: se usa un estado paralelo de llegada física.
- Si Mercancía OK se registró antes de que Compras libere, el dato queda guardado y se aplica automáticamente cuando corresponda.

### Aprobaciones de excepciones
- Todos los popups permiten `Enviar aprobación`.
- Destinos permitidos: Auditoría, Gerencia y Jefatura Logística. Super admin puede decidir como contingencia.
- La solicitud de aprobación no congela trabajo que no dependa de la excepción.
- La acción excepcional sí queda protegida hasta obtener aprobación.
- Casos implementados: liberación de prioridad urgente/crítica, salida sin factura y remanente de carreto mayor a 0 y menor de 50 m, además de excepciones trazables de flujo/inventario.

## Instalaciones nuevas
`/sql/00_INSTALL_ALL.sql` fue actualizado para conservar una instalación consolidada coherente. Solo debe usarse para una base nueva, nunca para actualizar una base existente.
