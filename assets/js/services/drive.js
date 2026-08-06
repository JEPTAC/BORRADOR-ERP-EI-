import {api} from "./api.js";
import {getSession} from "./supabase.js";

/*
 * Pegue aquí la URL /exec del Apps Script desplegado como aplicación web.
 * Ejemplo: https://script.google.com/macros/s/AKfycb.../exec
 */
const DRIVE_BRIDGE_URL = "https://script.google.com/macros/s/AKfycbygBt_yd5vQXIIZKZux_YCqhm37VSR3tKG109e_ED8NvmZzrUp179jkKSA6DnHNf2N3/exec";
const MAX_FILE_BYTES = 15 * 1024 * 1024;

function safeName(value,fallback="SIN_REFERENCIA"){
  return String(value||fallback).trim().replace(/[\\/:*?"<>|#%{}~&]/g,"-").replace(/\s+/g," ").slice(0,120)||fallback;
}

function validateBridge(){
  if(!/^https:\/\/script\.google\.com\/macros\/s\/.+\/exec$/i.test(DRIVE_BRIDGE_URL)){
    throw new Error("El administrador todavía no configuró la URL institucional de carga a Google Drive.");
  }
}

async function fileToBase64(file){
  const buffer=await file.arrayBuffer();
  const bytes=new Uint8Array(buffer);
  const chunkSize=0x8000;
  let binary="";
  for(let offset=0;offset<bytes.length;offset+=chunkSize){
    binary+=String.fromCharCode(...bytes.subarray(offset,Math.min(offset+chunkSize,bytes.length)));
  }
  return btoa(binary);
}

function submitToBridge(payload){
  return new Promise((resolve,reject)=>{
    const frameName=`erp_drive_${payload.uploadId.replace(/[^a-z0-9_\-]/gi,"")}`;
    const iframe=document.createElement("iframe");
    iframe.name=frameName;
    iframe.hidden=true;
    iframe.setAttribute("aria-hidden","true");

    const form=document.createElement("form");
    form.method="POST";
    form.action=DRIVE_BRIDGE_URL;
    form.target=frameName;
    form.enctype="application/x-www-form-urlencoded";
    form.hidden=true;

    const field=document.createElement("textarea");
    field.name="payload";
    field.value=JSON.stringify(payload);
    form.append(field);

    let settled=false;
    const cleanup=()=>{
      window.removeEventListener("message",onMessage);
      clearTimeout(timer);
      form.remove();
      iframe.remove();
    };
    const finish=(fn,value)=>{
      if(settled)return;
      settled=true;
      cleanup();
      fn(value);
    };
    const onMessage=event=>{
      const data=event.data;
      const googleOrigin=event.origin==="https://script.google.com"||/\.googleusercontent\.com$/i.test(new URL(event.origin).hostname);
      if(!googleOrigin||data?.source!=="ERP_EI_DRIVE_BRIDGE"||data?.uploadId!==payload.uploadId)return;
      if(data.ok&&data.file)finish(resolve,data.file);
      else finish(reject,new Error(data.error||"No fue posible cargar el archivo en Google Drive."));
    };
    const timer=setTimeout(()=>finish(reject,new Error("La carga institucional tardó demasiado. Inténtalo nuevamente.")),180000);

    window.addEventListener("message",onMessage);
    document.body.append(iframe,form);
    form.submit();
  });
}

export async function uploadOrderFile(orderId,file,category="EVIDENCE",taskId=null,orderNumber=null){
  validateBridge();
  if(!orderId)throw new Error("No se recibió el identificador del pedido.");
  if(!(file instanceof File))throw new Error("Seleccione un archivo válido.");
  if(file.size<=0)throw new Error("El archivo está vacío.");
  if(file.size>MAX_FILE_BYTES)throw new Error("El archivo supera el máximo permitido de 15 MB.");

  const session=await getSession();
  if(!session?.access_token)throw new Error("Tu sesión venció. Ingresa nuevamente al ERP.");

  const uploadId=crypto.randomUUID();
  const uploaded=await submitToBridge({
    uploadId,
    origin:window.location.origin,
    accessToken:session.access_token,
    orderId:String(orderId),
    taskId:taskId?String(taskId):null,
    orderNumber:orderNumber?String(orderNumber):null,
    category:String(category||"EVIDENCE"),
    fileName:safeName(file.name,"archivo"),
    mimeType:file.type||"application/octet-stream",
    sizeBytes:file.size,
    dataBase64:await fileToBase64(file)
  });

  return api.registerDriveFile({
    orderId,
    taskId,
    category,
    driveFileId:uploaded.id,
    fileName:uploaded.name,
    mimeType:uploaded.mimeType||file.type||"application/octet-stream",
    sizeBytes:Number(uploaded.size||file.size),
    webViewLink:uploaded.webViewLink,
    webContentLink:uploaded.webContentLink,
    metadata:{
      orderNumber:orderNumber||null,
      driveParentId:uploaded.parentId||null,
      uploadMode:"INSTITUTIONAL_APPS_SCRIPT",
      uploadedByProfileId:uploaded.uploadedByProfileId||null,
      uploadedByEmail:uploaded.uploadedByEmail||null
    }
  });
}
