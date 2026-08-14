import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {fileURLToPath,pathToFileURL} from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const files=[];
function walk(dir){
  if(!fs.existsSync(dir))return;
  for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    const full=path.join(dir,entry.name);
    if(entry.isDirectory())walk(full);
    else if(entry.name.endsWith(".js"))files.push(path.resolve(full));
  }
}
walk(path.join(root,"assets/js"));

const modules=new Map(files.map(file=>[
  file,
  new vm.SourceTextModule(fs.readFileSync(file,"utf8"),{
    identifier:pathToFileURL(file).href,
    initializeImportMeta(meta){meta.url=pathToFileURL(file).href;}
  })
]));

function resolve(specifier,referencingModule){
  if(!specifier.startsWith(".")&&!specifier.startsWith("/")){
    throw new Error(`Import externo no soportado en runtime: ${specifier} (${referencingModule.identifier})`);
  }
  const base=path.dirname(fileURLToPath(referencingModule.identifier));
  let target=path.resolve(base,specifier);
  if(!path.extname(target))target+=".js";
  const dependency=modules.get(target);
  if(!dependency)throw new Error(`Módulo inexistente: ${specifier} -> ${target}`);
  return dependency;
}

const failures=[];
for(const [file,module] of modules){
  if(module.status!=="unlinked")continue;
  try{await module.link(resolve);}catch(error){
    failures.push(`${path.relative(root,file)}: ${error.message}`);
  }
}

if(failures.length){
  console.error("VALIDACIÓN DE MÓDULOS FALLIDA");
  failures.forEach(item=>console.error(`- ${item}`));
  process.exit(1);
}
console.log(`ENLACE ES MODULES CORRECTO · ${files.length} archivos · 0 contratos rotos.`);
