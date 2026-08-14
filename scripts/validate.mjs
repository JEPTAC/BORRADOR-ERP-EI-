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
check(read("assets/js/config.js").includes('10.26.1-produccion-limpia'),"Versión de producción limpia incorrecta.");
check(read("service-worker.js").includes('10-26-1-produccion-limpia'),"Cache del Service Worker no corresponde a V10.26.1.");
check(fs.existsSync(path.join(root,"templates/historical_orders.csv")),"Falta la plantilla de importación histórica.");

if(failures.length){
  console.error("VALIDACIÓN FALLIDA");
  failures.forEach(x=>console.error(`- ${x}`));
  process.exit(1);
}
console.log("VALIDACIÓN V10.26.1 CORRECTA");
console.log(`- ${jsFiles.length} archivos JavaScript de producción revisados.`);
console.log("- Sin rutas, módulos ni RPC de Robot QA/Sandbox en el runtime.");
console.log("- Acceso a datos únicamente mediante RPC.");
