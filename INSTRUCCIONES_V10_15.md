# V10.15 · Ventas por necesidad, reservas y origen físico

## Qué reconstruye

- Paso 2 de Ventas: búsqueda oficial Siesa, disponibilidad comercial, entrega directa o plan de cortes.
- Reserva lógica: cada línea pendiente reserva automáticamente la cantidad requerida sin seleccionar lote.
- Inventario: diferencia existencia física, disponible Siesa, reservado ERP y disponible para venta.
- Alistamiento: al marcar Encontrado en una línea sin corte, exige seleccionar uno o varios lotes/ubicaciones oficiales. El ERP propone el origen más eficiente.
- Corte: conserva la selección de carreto existente. Cuando Corte consume físicamente material, la reserva lógica se consume para evitar doble descuento.

## Reglas

1. Ventas nunca selecciona bodega, ubicación, lote ni carreto.
2. Materiales normales: cantidad directa.
3. Materiales en metros: entrega directa o varias medidas de corte.
4. En corte, cada medida se convierte en una línea operativa homogénea para mantener trazabilidad exacta.
5. La reserva lógica puede registrar faltante proyectado, pero no inventa existencia.
6. Alistamiento puede dividir una cantidad entre varios lotes; la suma debe coincidir exactamente con lo solicitado.
7. El backend vuelve a validar material, variante, lote, cantidad y existencia al confirmar.

## Instalación en base existente

1. Reemplazar las rutas de `RUTAS_A_REEMPLAZAR.txt`.
2. Ejecutar una sola vez `sql/migrations/032_sales_material_reservations_and_picking_origins_v10_15.sql`.
3. No ejecutar `sql/00_INSTALL_ALL.sql` sobre una base existente.
4. Desplegar el repositorio completo fusionado.
5. Desregistrar el Service Worker, limpiar datos del sitio y recargar con Ctrl+Shift+R.
