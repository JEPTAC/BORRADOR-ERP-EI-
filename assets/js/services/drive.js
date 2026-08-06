import {CONFIG} from "../config.js";
import {api} from "./api.js";

let tokenClient,accessToken,rootFolderId;
const folderCache=new Map();

function requireGsi(){
  if(!window.google?.accounts?.oauth2)throw new Error("El servicio de archivos no está disponible. Recarga la página e inténtalo nuevamente.");
}
function safeName(value,fallback="SIN_REFERENCIA"){
  return String(value||fallback).trim().replace(/[\\/:*?"<>|#%{}~&]/g,"-").replace(/\s+/g," ").slice(0,120)||fallback;
}
async function token(){
  if(accessToken)return accessToken;
  requireGsi();
  return new Promise((resolve,reject)=>{
    tokenClient=tokenClient||google.accounts.oauth2.initTokenClient({
      client_id:CONFIG.drive.clientId,
      scope:CONFIG.drive.scope,
      callback:r=>r.error?reject(new Error(r.error)):resolve(accessToken=r.access_token)
    });
    tokenClient.requestAccessToken({prompt:""});
  });
}
async function driveFetch(url,options={}){
  const t=await token();
  const res=await fetch(url,{...options,headers:{...(options.headers||{}),Authorization:`Bearer ${t}`}});
  if(!res.ok){await res.text().catch(()=>"");throw new Error(`No fue posible completar la operación con el archivo (código ${res.status}).`);}
  return res.status===204?{}:res.json();
}
async function ensureFolder(name,parentId=null){
  const folderName=safeName(name,"CARPETA");
  const cacheKey=`${parentId||"ROOT"}:${folderName}`;
  if(folderCache.has(cacheKey))return folderCache.get(cacheKey);
  const escaped=folderName.replaceAll("'","\\'");
  const clauses=[`name='${escaped}'`,`mimeType='application/vnd.google-apps.folder'`,`trashed=false`];
  if(parentId)clauses.push(`'${parentId}' in parents`);
  const q=encodeURIComponent(clauses.join(" and "));
  const found=await driveFetch(`https://www.googleapis.com/drive/v3/files?q=${q}&spaces=drive&fields=files(id,name)&pageSize=10`);
  if(found.files?.[0]){folderCache.set(cacheKey,found.files[0].id);return found.files[0].id}
  const body={name:folderName,mimeType:"application/vnd.google-apps.folder"};
  if(parentId)body.parents=[parentId];
  const created=await driveFetch("https://www.googleapis.com/drive/v3/files?fields=id",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
  folderCache.set(cacheKey,created.id);
  return created.id;
}
async function ensureRoot(){
  if(rootFolderId)return rootFolderId;
  rootFolderId=await ensureFolder(CONFIG.drive.rootFolderName);
  return rootFolderId;
}
async function ensureOrderFolder(orderId,orderNumber){
  const root=await ensureRoot();
  const year=new Date().getFullYear().toString();
  const yearFolder=await ensureFolder(year,root);
  return ensureFolder(`PEDIDO_${safeName(orderNumber||orderId)}`,yearFolder);
}

export async function uploadOrderFile(orderId,file,category="EVIDENCE",taskId=null,orderNumber=null){
  if(!orderId)throw new Error("No se recibió el identificador del pedido.");
  if(!(file instanceof File))throw new Error("Seleccione un archivo válido.");
  const orderFolder=await ensureOrderFolder(orderId,orderNumber);
  const categoryFolder=await ensureFolder(safeName(category,"EVIDENCE"),orderFolder);
  const metadata={
    name:safeName(file.name,"archivo"),
    parents:[categoryFolder],
    description:`ERP Electroingeniería · pedido ${orderNumber||orderId} · ${category}`,
    appProperties:{erp:"ERP_ELECTROINGENIERIA",orderId:String(orderId),orderNumber:String(orderNumber||""),category:String(category)}
  };
  const boundary=`erp_${Date.now()}_${crypto.randomUUID()}`;
  const body=new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${file.type||"application/octet-stream"}\r\n\r\n`,
    file,
    `\r\n--${boundary}--`
  ]);
  const created=await driveFetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,size,webViewLink,webContentLink,parents",{
    method:"POST",headers:{"Content-Type":`multipart/related; boundary=${boundary}`},body
  });
  return api.registerDriveFile({
    orderId,taskId,category,driveFileId:created.id,fileName:created.name,mimeType:created.mimeType,
    sizeBytes:Number(created.size||file.size),webViewLink:created.webViewLink,webContentLink:created.webContentLink,
    metadata:{orderNumber:orderNumber||null,driveParentId:categoryFolder}
  });
}
