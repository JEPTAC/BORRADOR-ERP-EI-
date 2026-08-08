# ERP EI V10.14 · Maestro oficial Siesa

## Base requerida
V10.13 con la migración 029 aplicada.

## Fuente inicial
`Excel_siesa(1).xls`

- SHA-256: `800a3a12e54125913cebb3eb5c112f4483109f9afd6318ee7963a7762bb19f7e`
- Materiales oficiales únicos: **1959**
- Registros físicos de inventario: **2961**
- Identidad oficial: **Referencia + Nombre exacto**
- Variantes físicas: `Desc_ext1` cuando aplique (por ejemplo color)
- Identidad de existencia: referencia + bodega + ubicación + lote + variante + descripción secundaria

## Instalación en una base existente
1. Ejecutar UNA SOLA VEZ `sql/migrations/030_siesa_material_master_v10_14.sql` en Supabase SQL Editor.
2. No ejecutar `sql/00_INSTALL_ALL.sql` sobre la base existente.
3. Reemplazar/agregar las rutas listadas en `RUTAS_A_REEMPLAZAR.txt`.
4. Desplegar el repositorio completo fusionado.
5. Desregistrar el Service Worker, limpiar datos del sitio y recargar con Ctrl+Shift+R.

La migración 030 ya contiene el snapshot inicial completo del Excel suministrado. No es necesario volver a subir ese mismo Excel después de instalar V10.14.

## Ventas
- Ya no se escribe referencia, nombre ni unidad manualmente.
- El asesor busca el material oficial por referencia, nombre, familia o marca.
- Supabase vuelve a validar la identidad al crear la línea, por lo que manipular el navegador no permite crear materiales libres.
- Cuando una referencia tiene varias variantes activas (por ejemplo colores), se debe seleccionar la variante correspondiente.

## Recepción de pedidos
- Las líneas leídas del PDF se intentan resolver automáticamente contra el maestro Siesa.
- Si no existe coincidencia segura, la línea queda marcada como pendiente de resolución.
- No se puede confirmar Recepción hasta que todas las líneas estén vinculadas a materiales oficiales y, cuando aplique, a su variante.

## Inventario
- La operación normal muestra exclusivamente materiales oficiales activos.
- Los registros históricos/pruebas no vinculados se conservan para auditoría, pero no se suman al saldo operativo.
- Si un registro antiguo usó una referencia oficial con otro nombre, se pone en cuarentena y no puede contaminar el inventario oficial.
- Un ajuste manual solo se permite sobre un material cuya referencia y nombre continúan coincidiendo con el maestro.
- La actualización futura del Excel se realiza desde **Inventario → Actualizar maestro Siesa** y es transaccional: el snapshot vigente no cambia hasta validar todas las filas.

## Corte
- Los grupos se forman por `material_master_id + material_variant_id`, no solo por texto de referencia.
- El optimizador solo ofrece carretos de la misma referencia y variante/color.
- Supabase valida nuevamente esa identidad antes de registrar el lote de corte; un carreto incorrecto revierte toda la transacción.
- Los carretos creados por el ERP desde Corte heredan la variante del requerimiento.

## Actualizaciones futuras de Siesa
La importación valida antes de aplicar:
- referencia, nombre, unidad, bodega y ubicación obligatorios;
- una referencia no puede aparecer con dos nombres o unidades incompatibles;
- no puede existir una fila física duplicada;
- referencias ausentes del nuevo snapshot se desactivan, no se borran;
- lotes Siesa ausentes se ocultan del saldo actual, pero conservan historial.

## Instalaciones nuevas
`sql/00_INSTALL_ALL.sql` queda actualizado para instalaciones desde cero. No usarlo como migración incremental.
