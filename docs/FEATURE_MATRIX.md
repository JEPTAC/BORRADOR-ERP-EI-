# Matriz funcional

| Dominio | Capacidades principales | Control transaccional |
|---|---|---|
| Ventas | PVC, PVN, PVE, PVP; múltiples ítems; condiciones de pago; rutas; corte y compra | Idempotencia, validación de catálogos y propiedad comercial |
| Crédito | Radicación, revisión, decisión y trazabilidad | Estados y permisos por rol |
| Cartera | Validación de crédito, riesgo y liberación | Puerta obligatoria antes de avanzar |
| Caja | Registro de pago, soporte y liberación | Validación financiera y auditoría |
| Compras | Orden de compra, proveedor y liberación | Documento obligatorio para flujo PVE/compra |
| Recepción | Recepción documental/física, calidad, aceptados/rechazados, lotes y ubicación | Genera inventario y movimientos trazables |
| Alistamiento | Asignación, inicio, checklist, espera, bloqueo y finalización | Una tarea activa y una sesión abierta por operario |
| Corte | Lote/chipa, longitud solicitada/real y desperdicio | Descuento de inventario y movimiento de consumo |
| Facturación | Número, fecha, valor, moneda y soporte Drive | Puerta de factura antes de despacho |
| Despacho | Local, nacional, punto y recogida; transportadora y guía | Enrutamiento por rol y responsable |
| Entrega | Entregado, no entregado, evidencia y reprogramación | Historial y aprobación de excepciones |
| Cierre | Validación integral y cierre final | Impide cierre con controles incompletos |
| Inventario | Artículos, lotes, ubicaciones, ajustes y movimientos | Auditoría automática de cambios sensibles |
| Tiempos/VSM | Sesiones, tiempo bruto, laboral, espera, SLA, percentiles y throughput | Calendario exacto de operación |
| Aprobaciones | Cancelación, prioridad, ruta, reapertura y excepciones | Roles aprobadores canónicos y ejecución auditada |
| Histórico CSV | Carga reanudable, errores por fila y hasta 500 filas por llamada | `is_history=true`, sin tareas activas |
| QA | 192 rutas + 10 controles empresariales | Usa el motor transaccional real |
| Administración | Sincronización Auth, activación y roles | Solo Super Admin |
