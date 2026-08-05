# Instalación en repositorio nuevo

## 1. Supabase

Ejecute completo:

`sql/01_ERP_V9_NATIVE_API.sql`

La consulta final debe indicar:

- `api_sesion`: `erp_v9_session()`
- `api_pedidos`: `erp_v9_cases(...)`
- `api_escritura`: `erp_v9_execute(text,text,jsonb)`
- `auth_sesion`: `true`
- `auth_escritura`: `true`
- `anon_escritura`: `false`

## 2. GitHub

1. Cree un repositorio vacío, por ejemplo `ei-erp-nova-v9`.
2. Use **Add file → Upload files**.
3. Arrastre todos los archivos y carpetas del ZIP.
4. Confirme en la rama `main`.
5. Abra **Settings → Pages**.
6. Seleccione `Deploy from a branch`.
7. Seleccione `main` y `/root`.

## 3. Google Drive

El cliente OAuth existente está configurado en `assets/js/config.js`.

En Google Cloud, agregue la nueva URL de GitHub Pages a los orígenes JavaScript autorizados. Ejemplo:

`https://USUARIO.github.io`

La primera carga de un archivo solicitará autorización de Google Drive.

## 4. Primera validación

1. Inicie sesión como Super Admin.
2. Abra Auditoría y confirme que la API V9 esté correcta.
3. Abra Todos los pedidos y avance entre páginas.
4. Cree un pedido de prueba.
5. Ejecute una acción según el proceso.
6. Agregue un comentario.
7. Pruebe un archivo de evidencia en Drive.
