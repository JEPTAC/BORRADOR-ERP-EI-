# V10.11 · Despachos y entregas guiados

## Alcance

Esta versión reemplaza el microproceso de todas las modalidades de despacho y entrega:

- Entrega en punto.
- Cliente recoge.
- Despacho local.
- Despacho nacional.

## Flujo operativo

1. Tomar pedido.
2. Agregar guía y transportadora; el soporte de guía es opcional.
3. Especificar el lugar de entrega.
   - Buscar un destino escrito o usar la ubicación actual.
   - Completar municipio, dirección, latitud, longitud y altitud estimada.
   - Permitir corrección manual antes de guardar.
4. Pasar a cierre.
5. Tomar el cierre cuando la mercancía haya llegado.
6. Subir una fotografía de la mercancía entregada mediante Google Drive.
7. Marcar Pedido finalizado.

## Novedad de no entrega

- Solo Ventas y Superadministración pueden registrarla.
- Cada asesor ve únicamente sus pedidos enviados; Superadministración ve todos.
- Una no entrega detiene el cierre y deja la tarea en espera.
- Los pedidos ya finalizados no admiten una no entrega.

## Trazabilidad

Se registran hitos independientes para guía, ubicación, salida, asignación del cierre, evidencia, entrega y no entrega. El expediente incorpora tiempos de gestión, espera, tránsito, cierre, tiempo productivo y tiempo muerto laboral.

## Rendimiento

No se agregaron librerías de interfaz, mapas ni procesos de sondeo. La geocodificación se ejecuta únicamente cuando el usuario pulsa el botón de ubicación. La foto y los soportes continúan usando la integración de Google Drive ya instalada.
