# V10.17 · Operación guiada y listas de alto volumen

Base requerida: V10.16.2.

## No requiere SQL
Esta actualización no modifica el modelo de datos ni las reglas de negocio.
No ejecutes `sql/00_INSTALL_ALL.sql`.

## Cambios principales
- Las colas operativas dejan de usar tarjetas de pedido y usan listas compactas.
- Control de pedidos también usa lista como única vista de operación.
- Sandbox usa lista de pedidos TEST y conserva accesos separados a Alistamiento/Corte paralelo.
- Centro de Corte usa lista por referencia.
- Popup de Corte reconstruido como flujo de 3 pasos:
  1. Revisar cortes.
  2. Elegir carreto.
  3. Confirmar balance y ejecutar.
- Casos especiales de Corte quedan ocultos bajo `Caso especial` hasta que sean necesarios.
- Encabezados de módulos simplificados y más compactos.
- Refuerzo global de contraste y visibilidad de botones X.
- Estados operativos compactados para reducir saturación visual.

## Después de reemplazar
1. Despliega el repositorio.
2. Desregistra el Service Worker si el navegador conserva V10.16.x.
3. Limpia datos del sitio.
4. Abre nuevamente y usa `Ctrl + Shift + R`.

## Prueba recomendada
- Abrir una cola con varios pedidos y verificar que cada fila tenga su acción a la derecha.
- Crear un pedido Sandbox de Corte.
- Abrir Corte Sandbox y comprobar los tres pasos guiados.
- Volver a Alistamiento y comprobar que el corte sigue en paralelo.
