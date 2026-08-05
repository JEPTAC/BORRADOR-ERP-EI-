# Instalación en un repositorio nuevo

La aplicación es estática y no requiere instalar Node.js en el computador de trabajo. Node solo se utiliza opcionalmente en GitHub Actions para las pruebas Playwright.

## 1. Crear una copia de seguridad

Antes de instalar, exporte una copia de seguridad del proyecto Supabase actual. El instalador crea el esquema independiente `erp_supply`; no importa pedidos antiguos ni modifica el runtime anterior.

## 2. Instalar la base en Supabase

1. Abra **Supabase → SQL Editor → New query**.
2. Copie y ejecute completo `sql/00_INSTALL_ALL.sql`.
3. Confirme que la ejecución termine sin errores.
4. Ejecute `sql/99_POST_INSTALL_CHECK.sql`.
5. Confirme que `j.perez@ei.com.co` existe en **Authentication → Users**.

La migración vincula ese correo como `super_admin` cuando la cuenta Auth existe. Si la cuenta fue creada después, inicie sesión con otro Super Admin o vuelva a ejecutar la sección de sincronización desde Administración.

## 3. Crear el repositorio nuevo

1. Cree un repositorio vacío, por ejemplo `erp-supply-enterprise`.
2. Descomprima el ZIP.
3. Suba el contenido interno a la raíz del repositorio; `index.html` debe quedar en la raíz.
4. No mezcle estos archivos con V8 o V9.

## 4. Activar GitHub Pages

En GitHub:

```text
Settings → Pages → Source: GitHub Actions
```

El workflow `.github/workflows/pages.yml` despliega el sitio al hacer `push` a `main`.

## 5. Configurar Google Drive

En Google Cloud Console, abra el cliente OAuth indicado en `assets/js/config.js` y agregue la URL definitiva de GitHub Pages en **Authorized JavaScript origins**.

La aplicación solicita el alcance `drive.file`; crea y administra únicamente archivos creados o seleccionados mediante el ERP.

## 6. Vincular usuarios y roles

1. Cree las cuentas en **Supabase Authentication**.
2. Inicie sesión como Super Admin.
3. Abra **Administración**.
4. Ejecute **Sincronizar Auth**.
5. Active cada perfil y asigne uno o varios roles.
6. Confirme responsables de rutas:
   - Local: Duvan Díaz.
   - Nacional: Javier Laverde.

## 7. Ejecutar la validación integral

Abra **Bot QA E2E** y pulse **Ejecutar validación integral**.

Resultado exigido:

```text
Matriz comercial: 192/192 aprobados
Controles empresariales: 10/10 aprobados
Resultado integral: 202 verificaciones sin fallos
```

Después ejecute:

```sql
select *
from public.erp_x_health_check()
where not ok
order by section, check_name;
```

Debe devolver cero filas.

## 8. Importar historial

Use la plantilla `templates/historical_orders.csv`. La importación histórica:

- No crea tareas.
- No aparece en colas activas.
- Conserva fecha de creación y cierre.
- Puede ejecutarse por lotes reanudables.

## 9. Pruebas finales por rol

Siga `docs/ACCEPTANCE.md` y `docs/RELEASE_GATE.md`. No use datos reales de producción hasta aprobar la puerta de liberación.
