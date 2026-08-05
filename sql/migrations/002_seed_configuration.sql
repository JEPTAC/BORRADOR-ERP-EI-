-- ERP Supply Enterprise V10
-- Migration 002: roles, modules, workflow, schedules and default organization.

begin;

insert into erp_supply.organizations(code, name, timezone, settings)
values ('EI', 'Electroingeniería S.A.S.', 'America/Bogota', jsonb_build_object('currency','COP','locale','es-CO'))
on conflict (code) do update set name = excluded.name, timezone = excluded.timezone;

insert into erp_supply.roles(code, name, description) values
  ('super_admin','Superadministración','Control total, configuración y pruebas'),
  ('gerencia','Gerencia','Lectura integral, aprobaciones y control ejecutivo'),
  ('jefe_logistica','Jefatura logística','Supervisión de la operación y excepciones'),
  ('ventas','Ventas','Registro y seguimiento de pedidos propios'),
  ('cartera','Cartera','Validación de crédito y liberación financiera'),
  ('caja','Caja','Validación de pagos y soportes'),
  ('compras','Compras','Gestión de PVE, proveedores y órdenes de compra'),
  ('recepcion_mercancia','Recepción de mercancía','Recepción física, calidad y stickers'),
  ('coordinador_logistico','Coordinación logística','Recepción documental, facturación y rutas locales'),
  ('aux_logistica','Auxiliar de logística','Alistamiento y preparación de pedidos'),
  ('auxiliar_corte','Auxiliar de corte','Prealistamiento y corte de materiales'),
  ('despacho_nacional','Despacho nacional','Facturación y despachos nacionales'),
  ('auditoria','Auditoría','Lectura integral sin operación')
on conflict (code) do update set name = excluded.name, description = excluded.description, active = true;

insert into erp_supply.modules(code,name,description,icon,sort_order) values
  ('dashboard','Centro de operación','KPIs, alertas y cuellos de botella','layout-dashboard',10),
  ('orders','Control de pedidos','Registro, consulta y trazabilidad total','clipboard-list',20),
  ('sales','Registro de ventas','Creación y control comercial','badge-dollar-sign',30),
  ('credit','Crédito','Solicitudes y decisiones de crédito','landmark',40),
  ('cartera','Cartera','Liberaciones de cartera y riesgo','wallet-cards',50),
  ('caja','Caja','Validación de pagos','banknote',60),
  ('purchasing','Compras','Órdenes PVE, proveedores y abastecimiento','shopping-cart',70),
  ('receiving','Recepción','Recepción documental y física','package-check',80),
  ('picking','Alistamiento','Picking, checklist y novedades','list-checks',90),
  ('cutting','Corte','Colas de corte, chipas y desperdicio','scissors',100),
  ('billing','Facturación','Facturas, soportes y liberación','receipt-text',110),
  ('shipping','Despachos','Rutas locales, nacionales y recogidas','truck',120),
  ('inventory','Inventario','Existencias, lotes, ubicaciones y movimientos','boxes',130),
  ('approvals','Aprobaciones','Excepciones, cancelaciones y reaperturas','shield-check',140),
  ('vsm','VSM y tiempos','Lead time, tiempos productivos y esperas','activity',150),
  ('reports','Reportes','Indicadores y exportaciones','chart-no-axes-combined',160),
  ('imports','Importaciones','Carga histórica por CSV','file-up',170),
  ('qa','Bot QA','Pruebas matriciales y trazas E2E','bot',180),
  ('audit','Auditoría','Eventos, cambios y evidencias','scan-search',190),
  ('admin','Administración','Usuarios, roles, calendarios y reglas','settings',200)
on conflict (code) do update set name=excluded.name, description=excluded.description, icon=excluded.icon, sort_order=excluded.sort_order, active=true;

insert into erp_supply.order_types(code,name,description,requires_purchase_default,sort_order) values
  ('PVC','Pedido de venta crédito','Pedido comercial con validación de crédito',false,10),
  ('PVN','Pedido de venta nacional','Pedido con despacho de cobertura nacional',false,20),
  ('PVE','Pedido de venta especial','Pedido sujeto a abastecimiento o compra',true,30),
  ('PVP','Pedido de venta proyecto','Pedido asociado a proyecto o suministro especial',false,40)
on conflict (code) do update set name=excluded.name, description=excluded.description, requires_purchase_default=excluded.requires_purchase_default;

insert into erp_supply.payment_conditions(code,name,requires_cartera,requires_caja,sort_order) values
  ('CREDIT','Crédito',true,false,10),
  ('CASH','Contado',false,true,20),
  ('MIXED','Mixto',true,true,30)
on conflict (code) do update set name=excluded.name, requires_cartera=excluded.requires_cartera, requires_caja=excluded.requires_caja;

insert into erp_supply.delivery_routes(code,name,route_group,sort_order) values
  ('CLIENT_POINT','Entrega en punto','POINT',10),
  ('CLIENT_PICKUP','Cliente recoge','PICKUP',20),
  ('LOCAL_DISPATCH','Despacho local','LOCAL',30),
  ('NATIONAL_DISPATCH','Despacho nacional','NATIONAL',40)
on conflict (code) do update set name=excluded.name, route_group=excluded.route_group;

insert into erp_supply.workflow_steps(code,name,module_code,queue_code,sla_hours,sort_order,terminal,metadata) values
  ('CARTERA','Validación de cartera','cartera','CARTERA',4,10,false,'{"phase":"financial"}'),
  ('CAJA','Validación de caja','caja','CAJA',2,20,false,'{"phase":"financial"}'),
  ('COMPRAS','Gestión de compras','purchasing','COMPRAS',24,30,false,'{"phase":"supply"}'),
  ('RECEPCION_MERCANCIA','Recepción de mercancía','receiving','RECEPCION_MERCANCIA',8,40,false,'{"phase":"inbound"}'),
  ('RECEPCION_PEDIDO','Recepción documental y asignación','receiving','RECEPCION_PEDIDO',2,50,false,'{"phase":"inbound"}'),
  ('ALISTAMIENTO','Alistamiento','picking','ALISTAMIENTO',8,60,false,'{"phase":"warehouse"}'),
  ('CORTE','Corte y prealistamiento','cutting','CORTE',8,70,false,'{"phase":"warehouse"}'),
  ('FACTURACION','Facturación','billing','FACTURACION',4,80,false,'{"phase":"outbound"}'),
  ('CLIENT_POINT','Entrega en punto','shipping','CLIENT_POINT',4,90,false,'{"phase":"delivery"}'),
  ('CLIENT_PICKUP','Cliente recoge','shipping','CLIENT_PICKUP',8,100,false,'{"phase":"delivery"}'),
  ('LOCAL_DISPATCH','Despacho local','shipping','LOCAL_DISPATCH',8,110,false,'{"phase":"delivery"}'),
  ('NATIONAL_DISPATCH','Despacho nacional','shipping','NATIONAL_DISPATCH',24,120,false,'{"phase":"delivery"}'),
  ('CLOSURE','Cierre y verificación','shipping','CLOSURE',2,130,false,'{"phase":"closure"}'),
  ('CLOSED','Pedido cerrado','orders','CLOSED',null,140,true,'{"phase":"terminal"}')
on conflict (code) do update set name=excluded.name,module_code=excluded.module_code,queue_code=excluded.queue_code,sla_hours=excluded.sla_hours,sort_order=excluded.sort_order,metadata=excluded.metadata;

-- Step permissions. Super Admin has full control; supervisory roles receive override rights.
insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'super_admin', true,true,true,true,true,true,true from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true,can_claim=true,can_assign=true,can_start=true,can_complete=true,can_block=true,can_override=true;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'gerencia', true,false,false,false,false,false,true from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true,can_override=true;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'auditoria', true,false,false,false,false,false,false from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true;

insert into erp_supply.step_roles values
  ('CARTERA','cartera',true,true,false,true,true,true,false),
  ('CAJA','caja',true,true,false,true,true,true,false),
  ('COMPRAS','compras',true,true,true,true,true,true,false),
  ('RECEPCION_MERCANCIA','recepcion_mercancia',true,true,true,true,true,true,false),
  ('RECEPCION_PEDIDO','coordinador_logistico',true,true,true,true,true,true,false),
  ('ALISTAMIENTO','aux_logistica',true,true,false,true,true,true,false),
  ('CORTE','auxiliar_corte',true,true,false,true,true,true,false),
  ('FACTURACION','coordinador_logistico',true,true,false,true,true,true,false),
  ('FACTURACION','despacho_nacional',true,true,false,true,true,true,false),
  ('CLIENT_POINT','coordinador_logistico',true,true,false,true,true,true,false),
  ('CLIENT_PICKUP','coordinador_logistico',true,true,false,true,true,true,false),
  ('LOCAL_DISPATCH','coordinador_logistico',true,true,false,true,true,true,false),
  ('NATIONAL_DISPATCH','despacho_nacional',true,true,false,true,true,true,false),
  ('CLOSURE','jefe_logistica',true,true,true,true,true,true,true)
on conflict (step_code,role_code) do update set
  can_view=excluded.can_view,can_claim=excluded.can_claim,can_assign=excluded.can_assign,
  can_start=excluded.can_start,can_complete=excluded.can_complete,can_block=excluded.can_block,can_override=excluded.can_override;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code,'jefe_logistica',true,false,true,false,false,true,true from erp_supply.workflow_steps s
where not s.terminal
on conflict (step_code,role_code) do update set can_view=true,can_assign=true,can_block=true,can_override=true;

-- Module permissions: precise role menu and action rights.
insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
select 'super_admin',m.code,true,true,true,true,true from erp_supply.modules m
on conflict (role_code,module_code) do update set can_read=true,can_create=true,can_update=true,can_approve=true,can_admin=true;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
select r.code,m.code,true,false,false,(r.code='gerencia'),false
from erp_supply.roles r cross join erp_supply.modules m
where r.code in ('gerencia','auditoria')
on conflict (role_code,module_code) do update set can_read=excluded.can_read,can_approve=excluded.can_approve;

insert into erp_supply.role_module_permissions values
  ('ventas','dashboard',true,false,false,false,false),('ventas','orders',true,true,true,false,false),('ventas','sales',true,true,true,false,false),('ventas','credit',true,true,true,false,false),('ventas','approvals',true,true,false,false,false),
  ('cartera','dashboard',true,false,false,false,false),('cartera','orders',true,false,false,false,false),('cartera','cartera',true,false,true,true,false),('cartera','credit',true,false,true,true,false),('cartera','approvals',true,true,true,true,false),
  ('caja','dashboard',true,false,false,false,false),('caja','orders',true,false,false,false,false),('caja','caja',true,false,true,false,false),('caja','approvals',true,true,true,false,false),
  ('compras','dashboard',true,false,false,false,false),('compras','orders',true,false,false,false,false),('compras','purchasing',true,true,true,false,false),('compras','receiving',true,false,false,false,false),('compras','approvals',true,true,true,false,false),
  ('recepcion_mercancia','dashboard',true,false,false,false,false),('recepcion_mercancia','orders',true,false,false,false,false),('recepcion_mercancia','receiving',true,true,true,false,false),('recepcion_mercancia','inventory',true,true,true,false,false),('recepcion_mercancia','approvals',true,true,true,false,false),
  ('coordinador_logistico','dashboard',true,false,false,false,false),('coordinador_logistico','orders',true,false,true,false,false),('coordinador_logistico','receiving',true,true,true,false,false),('coordinador_logistico','picking',true,false,true,false,false),('coordinador_logistico','billing',true,true,true,false,false),('coordinador_logistico','shipping',true,true,true,false,false),('coordinador_logistico','approvals',true,true,true,false,false),
  ('aux_logistica','dashboard',true,false,false,false,false),('aux_logistica','orders',true,false,false,false,false),('aux_logistica','picking',true,false,true,false,false),('aux_logistica','approvals',true,true,false,false,false),
  ('auxiliar_corte','dashboard',true,false,false,false,false),('auxiliar_corte','orders',true,false,false,false,false),('auxiliar_corte','cutting',true,true,true,false,false),('auxiliar_corte','inventory',true,false,true,false,false),('auxiliar_corte','approvals',true,true,false,false,false),
  ('despacho_nacional','dashboard',true,false,false,false,false),('despacho_nacional','orders',true,false,true,false,false),('despacho_nacional','billing',true,true,true,false,false),('despacho_nacional','shipping',true,true,true,false,false),('despacho_nacional','approvals',true,true,true,false,false),
  ('jefe_logistica','dashboard',true,false,false,false,false),('jefe_logistica','orders',true,false,true,true,false),('jefe_logistica','purchasing',true,false,true,true,false),('jefe_logistica','receiving',true,false,true,true,false),('jefe_logistica','picking',true,false,true,true,false),('jefe_logistica','cutting',true,false,true,true,false),('jefe_logistica','billing',true,false,true,true,false),('jefe_logistica','shipping',true,false,true,true,false),('jefe_logistica','inventory',true,false,true,true,false),('jefe_logistica','approvals',true,true,true,true,false),('jefe_logistica','vsm',true,false,false,false,false),('jefe_logistica','reports',true,false,false,false,false),('jefe_logistica','qa',true,false,false,false,false),('jefe_logistica','audit',true,false,false,false,false)
on conflict (role_code,module_code) do update set can_read=excluded.can_read,can_create=excluded.can_create,can_update=excluded.can_update,can_approve=excluded.can_approve,can_admin=excluded.can_admin;

-- Default calendar: 07:00–12:00 and 13:40–17:30, Monday through Friday (8 h 50 min/day).
insert into erp_supply.work_calendars(organization_id,code,name,timezone)
select id,'OPERATIONS_CO','Operación Colombia','America/Bogota' from erp_supply.organizations where code='EI'
on conflict (organization_id,code) do update set name=excluded.name,timezone=excluded.timezone,active=true;

insert into erp_supply.work_calendar_segments(calendar_id,iso_weekday,start_time,end_time)
select c.id,d,'07:00','12:00' from erp_supply.work_calendars c cross join generate_series(1,5) d where c.code='OPERATIONS_CO'
on conflict do nothing;
insert into erp_supply.work_calendar_segments(calendar_id,iso_weekday,start_time,end_time)
select c.id,d,'13:40','17:30' from erp_supply.work_calendars c cross join generate_series(1,5) d where c.code='OPERATIONS_CO'
on conflict do nothing;

-- Colombian public holidays for 2026. Administrators can maintain future years in the calendar module.
insert into erp_supply.holidays(organization_id,holiday_date,name,source)
select o.id,h.d,h.n,case when h.d='2026-07-13'::date then 'Ley 2578 de 2026' else 'Colombia 2026' end from erp_supply.organizations o cross join (values
  ('2026-01-01'::date,'Año Nuevo'),('2026-01-12','Día de los Reyes Magos'),('2026-03-23','Día de San José'),
  ('2026-04-02','Jueves Santo'),('2026-04-03','Viernes Santo'),('2026-05-01','Día del Trabajo'),
  ('2026-05-18','Ascensión del Señor'),('2026-06-08','Corpus Christi'),('2026-06-15','Sagrado Corazón'),
  ('2026-06-29','San Pedro y San Pablo'),('2026-07-13','Nuestra Señora del Rosario de Chiquinquirá'),
  ('2026-07-20','Independencia de Colombia'),('2026-08-07','Batalla de Boyacá'),('2026-08-17','Asunción de la Virgen'),
  ('2026-10-12','Día de la Diversidad Étnica y Cultural'),('2026-11-02','Todos los Santos'),
  ('2026-11-16','Independencia de Cartagena'),('2026-12-08','Inmaculada Concepción'),('2026-12-25','Navidad')
) h(d,n) where o.code='EI'
on conflict (organization_id,holiday_date) do update set name=excluded.name,source=excluded.source;

commit;
