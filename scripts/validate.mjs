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
check(sql.includes("total_scenarios) values(v_org,v_actor,192)"),"El bot no declara la matriz de 192 escenarios.");
check(sql.includes("CTRL-10-CUT-CONSUMPTION")&&sql.includes("run_type='CONTROL_SUITE'"),"La suite de 10 controles empresariales no está completa.");
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
