import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const failures=[];
const notes=[];
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const walk=(dir,ext=null)=>fs.readdirSync(path.join(root,dir),{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(dir,e.name),ext):(!ext||e.name.endsWith(ext)?[path.join(dir,e.name)]:[]));
const check=(condition,message)=>{if(!condition)failures.push(message)};

const jsFiles=walk("assets/js",".js");
for(const rel of jsFiles){
  const body=read(rel);
  for(const m of body.matchAll(/(?:import|export)\s+(?:[^"']+\s+from\s+)?["']([^"']+)["']/g)){
    const spec=m[1];
    if(!spec.startsWith("."))continue;
    const target=path.normalize(path.join(path.dirname(path.join(root,rel)),spec));
    check(fs.existsSync(target),`Import local inexistente: ${rel} -> ${spec}`);
  }
}

for(const html of ["index.html","404.html"]){
  const body=read(html);
  for(const m of body.matchAll(/(?:src|href)=["']([^"']+)["']/g)){
    const spec=m[1].split("?")[0];
    if(!spec.startsWith("."))continue;
    check(fs.existsSync(path.normalize(path.join(root,path.dirname(html),spec))),`Recurso HTML inexistente: ${html} -> ${spec}`);
  }
}

const executable=jsFiles.map(read).join("\n");
const css=read("assets/css/app.css");
for(const selector of [".modal-overlay",".modal",".modal-head",".modal-body",".modal-foot"]){
  const escaped=selector.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
  const count=(css.match(new RegExp(`^${escaped}\\{`,"gm"))||[]).length;
  check(count===1,`El selector genérico ${selector} debe tener una única definición canónica; encontradas: ${count}`);
}
check(!/addEventListener\([^\n]+async\s+button\s*=>/.test(executable),"Se detectó un event listener que trata Event como botón en una acción asíncrona.");
for(const term of ["supabase-compat","supabase-legacy","window.firebase","DocumentRef","QueryRef","CollectionRef","snapshot.forEach","erp_apply_operations"]){
  check(!executable.includes(term),`Término heredado detectado en JS ejecutable: ${term}`);
}
check(!/\.from\s*\(/.test(executable),"El frontend contiene acceso directo .from(...); toda operación debe pasar por RPC nativo.");

const migrationsDir=path.join(root,"sql/migrations");
const migrations=fs.existsSync(migrationsDir)?walk("sql/migrations",".sql").sort():[];
const install=read("sql/00_INSTALL_ALL.sql");
const supplementalSql=["sql/02_CORRECCION_RAIZ_COLAS_QA_PEDIDOS.sql"].filter(rel=>fs.existsSync(path.join(root,rel))).map(read).join("\n");
const sql=(migrations.length?migrations.map(read).join("\n"):install)+"\n"+supplementalSql;
for(const rel of migrations){
  const marker=read(rel).split("\n").slice(0,3).join("\n").trim();
  check(install.includes(marker),`La migración no está incluida en 00_INSTALL_ALL.sql: ${rel}`);
  const body=read(rel);
  check((body.match(/\$\$/g)||[]).length%2===0,`Bloques $$ desbalanceados: ${rel}`);
  check(/^\s*begin\s*;/im.test(body)&&/commit\s*;\s*$/im.test(body),`Migración sin transacción completa: ${rel}`);
}

const rpcDefs=new Set([...sql.matchAll(/create\s+or\s+replace\s+function\s+public\.(erp_x_[a-z0-9_]+)\s*\(/gi)].map(x=>x[1]));
const rpcCalls=new Set([...executable.matchAll(/rpc\(["'](erp_x_[a-z0-9_]+)["']/gi)].map(x=>x[1]));
for(const rpc of rpcCalls)check(rpcDefs.has(rpc),`RPC usado por frontend pero no definido: ${rpc}`);
for(const rpc of rpcDefs){
  const re=new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${rpc}\\s*\\([\\s\\S]*?security\\s+definer`,`i`);
  check(re.test(sql),`RPC público sin SECURITY DEFINER detectado estáticamente: ${rpc}`);
}
check(sql.includes("p.proname like 'erp_x_%'")&&sql.includes("grant execute on function %s to authenticated"),"No se encontró reconciliación final de permisos RPC.");
check(sql.includes("revoke all on schema erp_supply from public, anon, authenticated"),"El esquema interno no queda oculto.");
check(sql.includes("uq_active_task_per_order"),"Falta unicidad de tarea activa por pedido.");
check(sql.includes("drop index if exists erp_supply.uq_open_session_per_user")&&sql.includes("uq_open_session_per_task"),"La política de sesiones debe permitir varios pedidos por usuario y conservar una sola sesión abierta por tarea.");
check(sql.includes("p_expected_version"),"Falta control de versión optimista.");
check(sql.includes("p_idempotency_key"),"Falta idempotencia en acciones.");
check(sql.includes("business_seconds_between"),"Falta cálculo de tiempo laboral.");
check(sql.includes("trg_validate_task_completion"),"Faltan puertas de cierre por etapa.");
check(sql.includes("task_checklist"),"Falta checklist obligatorio por tarea.");
check(sql.includes("336")&&sql.includes("financialEntryVariants")&&sql.includes("initial_step(text,text,boolean,boolean,boolean)"),"El bot QA no declara la matriz V10.22 de enrutamiento vigente.");
check(sql.includes("CTRL-09-RECEIPT-PARTIAL-PROGRESS")&&sql.includes("CTRL-10-CUT-CONSUMPTION")&&sql.includes("run_type='CONTROL_SUITE'"),"La suite V10.22 de controles empresariales no está alineada con Recepción y Corte.");
check(sql.includes("erp_x_v10_22_self_check")&&sql.includes("CUT_QUEUE_CANONICAL_SOURCE")&&sql.includes("ROUTING_LEGACY_SIGNATURE_REMOVED"),"Falta el autodiagnóstico estructural V10.22.");
check(sql.includes("drop function if exists erp_supply.initial_step(text,text,boolean)"),"La firma histórica de initial_step sigue habilitada.");
check(sql.includes("trg_require_collected_cut_for_picking")&&sql.includes("erp_x_flow_integrity"),"Falta el endurecimiento transversal V10.22 entre Corte, Alistamiento y diagnósticos.");
check(sql.includes("MERCANCIA_OK_V10_22")&&sql.includes("ERP_RECEIPT"),"Mercancía OK PVE no publica inventario mediante la ruta canónica V10.22.");
check(sql.includes("erp_x_receipt_progress")&&sql.includes("RECEPCION_PVE_V10_22")&&sql.includes("trg_require_complete_receipt_before_task_complete"),"Recepción PVE no contiene progreso acumulado, identidad Siesa estricta y gate de cierre V10.22.");
check(sql.includes("create or replace function public.erp_x_health_check()")&&sql.includes("Última matriz de 336 rutas aprobada"),"El health check no está alineado con la QA V10.22.");
check(executable.includes('runQaV1022')&&!executable.includes('192 combinaciones')&&!executable.includes('202 pruebas'),"La interfaz QA conserva textos o ejecución de la matriz histórica.");
check(css.includes(".modal-task-panel-shell{")&&css.includes(".modal-task-panel-scrim{")&&css.includes(".modal-task-panel{"),"El panel de tarea integrado no tiene geometría canónica completa.");
check(fs.existsSync(path.join(root,"sql/migrations/044_release_health_qa_alignment_v10_22.sql")),"Falta la migración final de alineación QA/health V10.22.");
check(fs.existsSync(path.join(root,"sql/migrations/047_order_cancellation_approval_v10_22_4.sql")),"Falta la migración 047 de cancelación por aprobación.");
check(sql.includes("erp_x_request_order_cancellation")&&sql.includes("erp_x_decide_order_cancellation")&&sql.includes("trg_guard_cancellation_decision")&&sql.includes("trg_cleanup_cancelled_order"),"La cancelación de pedidos no está protegida integralmente por solicitud, decisión y limpieza operacional.");
check(executable.includes("Solicitar cancelación")&&executable.includes("requestOrderCancellation")&&executable.includes("decideOrderCancellation"),"El frontend no expone el flujo dedicado de cancelación V10.22.4.");
check(!fs.existsSync(path.join(root,"sql/02_CORRECCION_RAIZ_COLAS_QA_PEDIDOS.sql")),"El parche raíz V10.4 no debe permanecer como SQL ejecutable de nivel raíz.");
check(fs.existsSync(path.join(root,"sql/migrations/034_sandbox_parallel_cut_hotfix_v10_16_2.sql")),"La migración 034 debe formar parte del árbol canónico de migraciones.");
check(sql.includes("create or replace function erp_supply.safe_date")&&sql.includes("create or replace function erp_supply.safe_uuid"),"Falta endurecimiento de contratos de entrada.");

const manifest=JSON.parse(read("manifest.webmanifest"));
check(Boolean(manifest.name&&manifest.start_url),"Manifest PWA incompleto.");
check(fs.existsSync(path.join(root,"templates/historical_orders.csv")),"Falta plantilla CSV histórica.");
check(fs.existsSync(path.join(root,"supabase/functions/erp-e2e-bot/index.ts")),"Falta Edge Function del bot QA.");

notes.push(`${jsFiles.length} archivos JavaScript revisados.`);
notes.push(migrations.length?`${migrations.length} migraciones incluidas.`:"Instalador SQL consolidado revisado.");
notes.push(`${rpcDefs.size} RPC nativos definidos y ${rpcCalls.size} consumidos por el frontend.`);
notes.push("No se detectaron accesos directos a tablas desde el navegador.");

if(failures.length){
  console.error("VALIDACIÓN FALLIDA");
  failures.forEach(x=>console.error(`- ${x}`));
  process.exit(1);
}
console.log("VALIDACIÓN ESTÁTICA CORRECTA");
notes.forEach(x=>console.log(`- ${x}`));
