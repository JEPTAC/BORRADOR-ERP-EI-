import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const failures=[];
const check=(ok,msg)=>{if(!ok)failures.push(msg)};
const read=rel=>fs.readFileSync(path.join(root,rel),"utf8");
const jsFiles=[];
function walk(dir){
  if(!fs.existsSync(dir))return;
  for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    const full=path.join(dir,entry.name);
    if(entry.isDirectory())walk(full);
    else if(entry.name.endsWith(".js"))jsFiles.push(full);
  }
}
walk(path.join(root,"assets/js"));
const runtimeFiles=[...jsFiles,path.join(root,"assets/css/app.css"),path.join(root,"service-worker.js"),path.join(root,"index.html"),path.join(root,"package.json")].filter(fs.existsSync);
const runtime=runtimeFiles.map(f=>fs.readFileSync(f,"utf8")).join("\n");
const banned=/\b(QA_BOT|erp_x_qa_|erp_x_run_qa_|erp_x_sandbox_|sandboxMode|manualSandbox|sandboxCutStatus|require_sandbox_admin|TEST-QA-|erp-e2e-bot|erp_x_flow_integrity|erp_x_queue_integrity|erp_x_runtime_diagnostics|erp_x_save_cut_job)\b/i;
check(!banned.test(runtime),"El runtime todavía contiene referencias al Robot QA/Sandbox.");
check(!runtime.includes('id:"qa"')&&!runtime.includes('id:"sandbox"'),"El menú todavía expone QA/Sandbox.");
check(!fs.existsSync(path.join(root,"assets/js/modules/qa.js")),"qa.js no debe existir.");
check(!fs.existsSync(path.join(root,"assets/js/modules/sandbox.js")),"sandbox.js no debe existir.");
check(!fs.existsSync(path.join(root,"assets/js/modules/qa-total.js")),"qa-total.js no debe existir.");
check(!fs.existsSync(path.join(root,"assets/js/modules/qa-flow.js")),"qa-flow.js no debe existir.");
check(!/\.from\s*\(/.test(jsFiles.map(f=>fs.readFileSync(f,"utf8")).join("\n")),"El navegador no debe acceder a tablas directamente; use RPC.");
check(read("assets/js/config.js").includes('10.31.0-blue-immersive'),"Versión visual incorrecta.");
check(read("service-worker.js").includes('10-31-0-blue-immersive'),"Cache del Service Worker no corresponde a V10.31.0.");
check(read("assets/js/services/drive.js").includes("export async function uploadWorkEvidence"),"drive.js no exporta uploadWorkEvidence requerido por Workforce.");
check(read("assets/js/services/supabase.js").includes("export async function clearLocalSession"),"Falta recuperación de sesión local obsoleta.");
check(read("assets/js/main.js").includes("await clearLocalSession()"),"Login no limpia una sesión anterior antes de autenticar.");
check(read("assets/js/main.js").includes("La sesión anterior ya no es válida"),"Falta recuperación visible para perfil eliminado.");
check(fs.existsSync(path.join(root,"templates/historical_orders.csv")),"Falta la plantilla de importación histórica.");
check(read("assets/js/modules/admin.js").includes("Consola Super Admin"),"Falta la consola de Super Admin.");
check(read("assets/js/services/api.js").includes('edgeFunction("erp-admin-users"'),"El frontend no está integrado con la función segura de administración Auth.");
check(fs.existsSync(path.join(root,"supabase/functions/erp-admin-users/index.ts")),"Falta el código fuente de la Edge Function erp-admin-users.");
check(read("supabase/config.toml").includes("[functions.erp-admin-users]")&&read("supabase/config.toml").includes("verify_jwt = true"),"La Edge Function administrativa debe exigir JWT.");


if(failures.length){
  console.error("VALIDACIÓN FALLIDA");
  failures.forEach(x=>console.error(`- ${x}`));
  process.exit(1);
}
const css=read("assets/css/app.css");
check(css.includes("Blue Immersive Experience"),"Falta el sistema visual V10.31.0.");
check((css.match(/:root\{/g)||[]).length===1,"app.css debe tener una sola raíz de tokens visuales.");
check(css.includes('font-family:"Century Gothic"'),"La tipografía institucional no está aplicada en el sistema visual.");
check(css.includes('.btn-primary{')&&css.includes('.btn-create{')&&css.includes('.btn-search{')&&css.includes('.modal-overlay{')&&css.includes('.sidebar{'),"Faltan componentes visuales o semánticos base.");
check(css.includes(".global-shell{")&&read("assets/js/core/layout.js").includes("global-shell"),"Falta la shell global Blue Immersive.");
check(read("assets/js/core/guided.js").includes("Acciones disponibles"),"El centro de trabajo no usa la nueva jerarquía de acciones.");
check(css.includes(".guided-action-card.accent .guided-action-icon:after"),"Las acciones de creación guiadas no tienen símbolo + inequívoco.");
check(read("assets/js/core/ui.js").includes("semanticActionClass"),"Los asistentes no aplican semántica visual automática a Crear/Agregar/Nuevo.");
check(read("assets/js/core/layout.js").includes("btn btn-create shell-new-order"),"Nuevo pedido debe usar la familia visual de creación.");
check(read("assets/js/modules/admin.js").includes("btn btn-create")&&read("assets/js/modules/orders.js").includes("btn btn-create")&&read("assets/js/modules/workforce.js").includes("btn btn-create"),"Las acciones de creación principales no están unificadas.");
check(!css.includes('.page-head .btn-primary,.page-head .btn-accent{color:#071a'),"Existe una regla histórica que altera la semántica de botones en encabezados.");
check(!/V10\.(6|7|8|9|11|12|13|14|15|22|25|27).*Consola|V10\.27\.0 · Consola/.test(css),"app.css conserva capas históricas de estilos por versión.");
if(failures.length){
  console.error("VALIDACIÓN VISUAL FALLIDA");
  failures.forEach(x=>console.error(`- ${x}`));
  process.exit(1);
}
console.log("VALIDACIÓN V10.31.0 CORRECTA");
console.log(`- ${jsFiles.length} archivos JavaScript de producción revisados.`);
console.log("- Sin rutas, módulos ni RPC de Robot QA/Sandbox en el runtime.");
console.log("- Acceso a datos productivos mediante RPC y administración Auth mediante Edge Function protegida.");
