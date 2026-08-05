# EI ERP Nova V9 · Supabase Native

Reconstrucción independiente del ERP de Electroingeniería.

## Arquitectura

- Supabase Auth: inicio de sesión.
- Supabase PostgreSQL: información operativa.
- RPC `erp_v9_*`: API del frontend.
- Google Drive API: archivos y evidencias.
- JavaScript ES Modules: sin Node, sin compilación y sin Firebase.

## No contiene

- `supabase-compat.js`
- `supabase-legacy-adapter.js`
- `window.firebase`
- `DocumentRef`, `QueryRef` o snapshots
- llamadas `collection().doc()`
- escritura genérica `erp_apply_operations` desde el navegador

## Instalación

1. Ejecutar `sql/01_ERP_V9_NATIVE_API.sql` en Supabase SQL Editor.
2. Crear un repositorio GitHub nuevo.
3. Subir todo el contenido de esta carpeta a la raíz del repositorio.
4. Activar GitHub Pages desde la rama `main` y carpeta `/root`.
5. Abrir la URL de Pages e iniciar sesión con un usuario existente de Supabase Auth.

No requiere `npm install`, Node.js ni una acción de build.

## Módulos incluidos

- Inicio y métricas.
- Registro de ventas y creación de pedidos.
- Todos los pedidos con paginación real.
- Pedidos PVP / Proyectos.
- Cartera.
- Caja.
- Compras.
- Recepción de pedidos.
- Recepción de mercancía y stickers imprimibles.
- Alistamiento.
- Corte.
- Facturación.
- Despachos locales y nacionales.
- Solicitudes y aprobaciones.
- Solicitudes de crédito.
- Novedades.
- Inventario de chipas.
- VSM.
- Auditoría.
- Usuarios y roles.

Los módulos operativos consultan la misma tabla de pedidos, pero se filtran por proceso. Las acciones son específicas y se ejecutan mediante funciones de dominio en PostgreSQL.
