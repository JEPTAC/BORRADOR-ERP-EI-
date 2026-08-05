import { CONFIG } from "./config.js";

let token = null;
let tokenClient = null;
const TOKEN_KEY = "ei_erp_v9_drive_token";

function loadStored(){
  try{
    const x = JSON.parse(sessionStorage.getItem(TOKEN_KEY) || "null");
    if(x && x.access_token && x.expires_at > Date.now()+60000) token=x;
  }catch(_){ token=null; }
}
loadStored();

function ensureGoogleScript(){
  if(window.google?.accounts?.oauth2) return Promise.resolve();
  return new Promise((resolve,reject)=>{
    const existing=document.querySelector('script[data-google-identity="1"]');
    if(existing){ existing.addEventListener("load",resolve,{once:true}); return; }
    const s=document.createElement("script");
    s.src="https://accounts.google.com/gsi/client";s.async=true;s.defer=true;s.dataset.googleIdentity="1";
    s.onload=resolve;s.onerror=()=>reject(new Error("No fue posible cargar Google Identity."));document.head.appendChild(s);
  });
}

export async function connectDrive(interactive=true){
  if(token?.access_token && token.expires_at>Date.now()+60000) return token;
  await ensureGoogleScript();
  return new Promise((resolve,reject)=>{
    tokenClient = window.google.accounts.oauth2.initTokenClient({
      client_id:CONFIG.drive.googleClientId,scope:CONFIG.drive.scope,
      callback:r=>{
        if(!r?.access_token){ reject(new Error(r?.error_description||"Drive no autorizó el acceso.")); return; }
        token={...r,expires_at:Date.now()+Number(r.expires_in||3500)*1000};
        sessionStorage.setItem(TOKEN_KEY,JSON.stringify(token));resolve(token);
      },error_callback:e=>reject(new Error(e?.message||"No fue posible abrir Google Drive."))
    });
    tokenClient.requestAccessToken({prompt:interactive?"consent":""});
  });
}

async function request(url,options={}){
  const t=await connectDrive(false).catch(()=>connectDrive(true));
  const response=await fetch(url,{...options,headers:{...(options.headers||{}),Authorization:`Bearer ${t.access_token}`}});
  if(response.status===401){token=null;sessionStorage.removeItem(TOKEN_KEY);throw new Error("La sesión de Drive venció. Conéctela nuevamente.");}
  if(!response.ok){const body=await response.text();throw new Error(`Drive ${response.status}: ${body.slice(0,240)}`);}
  if(response.status===204) return null;
  return response.json();
}

function escapeQuery(value){return String(value).replace(/'/g,"\\'");}
async function findFolder(name,parent){
  const q=`name = '${escapeQuery(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false${parent?` and '${escapeQuery(parent)}' in parents`:""}`;
  const r=await request(`https://www.googleapis.com/drive/v3/files?spaces=drive&fields=files(id,name)&pageSize=10&q=${encodeURIComponent(q)}`);
  return r.files?.[0]||null;
}
async function createFolder(name,parent){
  return request("https://www.googleapis.com/drive/v3/files?fields=id,name",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name,mimeType:"application/vnd.google-apps.folder",...(parent?{parents:[parent]}:{})})});
}
async function ensureFolderPath(parts){let parent=null;for(const part of parts){let folder=await findFolder(part,parent);if(!folder)folder=await createFolder(part,parent);parent=folder.id;}return parent;}

export async function uploadToDrive(file,path=[]){
  if(!file) throw new Error("Seleccione un archivo.");
  const folderId=await ensureFolderPath([CONFIG.drive.rootFolderName,...path.filter(Boolean)]);
  const metadata={name:file.name,mimeType:file.type||"application/octet-stream",parents:[folderId]};
  const boundary=`ei_v9_${Date.now()}`;
  const body=new Blob([`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n`,JSON.stringify(metadata),`\r\n--${boundary}\r\nContent-Type: ${file.type||"application/octet-stream"}\r\n\r\n`,file,`\r\n--${boundary}--`],{type:`multipart/related; boundary=${boundary}`});
  const r=await request("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,size,webViewLink,webContentLink,createdTime",{method:"POST",headers:{"Content-Type":`multipart/related; boundary=${boundary}`},body});
  return {fileId:r.id,driveId:r.id,url:r.webViewLink||r.webContentLink||`https://drive.google.com/file/d/${r.id}/view`,driveUrl:r.webViewLink||r.webContentLink,fileName:r.name,mimeType:r.mimeType,sizeBytes:Number(r.size||file.size||0),uploadedAt:r.createdTime||new Date().toISOString()};
}
