# Actualización V10.4 · Corrección de raíz

Orden obligatorio:

1. Ejecutar `sql/02_CORRECCION_RAIZ_COLAS_QA_PEDIDOS.sql` completo en Supabase SQL Editor.
2. Reemplazar los 10 archivos del frontend respetando sus rutas.
3. En el navegador: F12 → Application → Service Workers → Unregister.
4. Limpiar los datos del sitio y recargar con Ctrl + Shift + R.
5. Entrar a **Pruebas automáticas → Verificar integridad de colas**.
6. Si aparecen problemas, usar **Reparar colas**. La reparación no elimina pedidos.

Cambios:
- Corrige `erp_x_qa_runs` y el módulo QA.
- Corrige lotes de inventario.
- Corrige la matriz de 192 pruebas y las puertas de la suite empresarial.
- Añade diagnóstico y reparación de colas.
- La cola abre en `Toda la cola`, no en `Mis tareas`.
- Añade filtro `Sin asignar`.
- Hace toda la tarjeta del pedido clicable.
- Valida materiales y longitudes de corte antes de crear pedidos.
- Mejora los mensajes de error de Supabase.
