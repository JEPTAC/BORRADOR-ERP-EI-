import {CONFIG} from "../config.js";
import {api} from "./api.js";

const BRIDGE_TIMEOUT_MS=180000;
const MAX_FILE_BYTES=Number(CONFIG?.drive?.maxFileBytes||15*1024*1024);

function bridgeUrl(){
  return String(CONFIG?.drive?.bridgeUrl||"").trim();
}

function validateBridge(){
  if(!/^https:\/\/script\.google\.com\/macros\/s\/[A-Za-z0-9_-]+\/exec$/i.test(bridgeUrl())){
    throw new Error("El puente institucional de Google Drive no está configurado correctamente.");
  }
}

function safeName(value,fallback="archivo"){
  return String(value||fallback).trim()
    .replace(/[\\/:*?"<>|#%{}~&]/g,"-")
    .replace(/\s+/g," ")
    .slice(0,120)||fallback;
}

async function currentSession(){
  const authService=await import("./supabase.js");
  if(typeof authService.getSession==="function")return authService.getSession();
  if(typeof authService.getSupabase==="function"){
    const {data,error}=await authService.getSupabase().auth.getSession();
    if(error)throw error;
    return data?.session||null;
  }
  throw new Error("No fue posible consultar la sesión activa del ERP.");
}

async function fileToBase64(file){
  const bytes=new Uint8Array(await file.arrayBuffer());
  const chunkSize=0x8000;
  let binary="";
  for(let offset=0;offset<bytes.length;offset+=chunkSize){
    binary+=String.fromCharCode(...bytes.subarray(offset,Math.min(offset+chunkSize,bytes.length)));
  }
  return btoa(binary);
}

function base64ToBlob(dataBase64,mimeType="application/octet-stream"){
  const binary=atob(String(dataBase64||""));
  const bytes=new Uint8Array(binary.length);
  for(let index=0;index<binary.length;index++)bytes[index]=binary.charCodeAt(index);
  return new Blob([bytes],{type:mimeType||"application/octet-stream"});
}

function isBridgeOrigin(origin){
  try{
    const url=new URL(origin);
    return url.protocol==="https:"&&(
      url.hostname==="script.google.com"||
      url.hostname==="script.googleusercontent.com"||
      url.hostname.endsWith(".googleusercontent.com")
    );
  }catch{
    return false;
  }
}

function createRequestId(){
  return typeof crypto?.randomUUID==="function"
    ? crypto.randomUUID()
    : `drive_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

function submitToBridge(payload){
  validateBridge();
  return new Promise((resolve,reject)=>{
    const id=String(payload.requestId||createRequestId());
    payload.requestId=id;
    const frameName=`erp_drive_${id.replace(/[^a-z0-9_-]/gi,"")}`;

    const iframe=document.createElement("iframe");
    iframe.name=frameName;
    iframe.hidden=true;
    iframe.setAttribute("aria-hidden","true");

    const form=document.createElement("form");
    form.method="POST";
    form.action=bridgeUrl();
    form.target=frameName;
    form.enctype="application/x-www-form-urlencoded";
    form.hidden=true;

    const field=document.createElement("textarea");
    field.name="payload";
    field.value=JSON.stringify(payload);
    form.appendChild(field);

    let settled=false;
    const cleanup=()=>{
      window.removeEventListener("message",onMessage);
      clearTimeout(timer);
      form.remove();
      iframe.remove();
    };
    const finish=(handler,value)=>{
      if(settled)return;
      settled=true;
      cleanup();
      handler(value);
    };
    const onMessage=event=>{
      const data=event.data;
      if(!isBridgeOrigin(event.origin)||data?.source!=="ERP_EI_DRIVE_BRIDGE"||data?.requestId!==id)return;
      if(data.ok)finish(resolve,data);
      else finish(reject,new Error(data.error||"No fue posible completar la operación institucional con Google Drive."));
    };
    const timer=setTimeout(
      ()=>finish(reject,new Error("El puente institucional no respondió. Revisa la implementación de Apps Script.")),
      BRIDGE_TIMEOUT_MS
    );

    window.addEventListener("message",onMessage);
    document.body.appendChild(iframe);
    document.body.appendChild(form);
    form.submit();
  });
}

async function authenticatedPayload(extra={}){
  const session=await currentSession();
  if(!session?.access_token)throw new Error("Tu sesión venció. Ingresa nuevamente al ERP.");
  return {
    requestId:createRequestId(),
    origin:window.location.origin,
    accessToken:session.access_token,
    clientVersion:CONFIG?.version||"ERP_EI",
    ...extra
  };
}

export async function uploadOrderFile(orderId,file,category="EVIDENCE",taskId=null,orderNumber=null){
  if(!orderId)throw new Error("No se recibió el identificador del pedido.");
  if(!(file instanceof File))throw new Error("Seleccione un archivo válido.");
  if(file.size<=0)throw new Error("El archivo está vacío.");
  if(file.size>MAX_FILE_BYTES){
    throw new Error(`El archivo supera el máximo permitido de ${Math.floor(MAX_FILE_BYTES/1024/1024)} MB.`);
  }

  const response=await submitToBridge(await authenticatedPayload({
    action:"UPLOAD",
    orderId:String(orderId),
    taskId:taskId?String(taskId):null,
    orderNumber:orderNumber?String(orderNumber):null,
    category:String(category||"EVIDENCE"),
    fileName:safeName(file.name,"archivo"),
    mimeType:file.type||"application/octet-stream",
    sizeBytes:file.size,
    dataBase64:await fileToBase64(file)
  }));

  const uploaded=response.file;
  if(!uploaded?.id)throw new Error("El puente no devolvió el identificador del archivo.");

  return api.registerDriveFile({
    orderId,
    taskId,
    category,
    driveFileId:uploaded.id,
    fileName:uploaded.name,
    mimeType:uploaded.mimeType||file.type||"application/octet-stream",
    sizeBytes:Number(uploaded.size||file.size),
    webViewLink:uploaded.webViewLink||null,
    webContentLink:null,
    metadata:{
      orderNumber:orderNumber||null,
      driveParentId:uploaded.parentId||null,
      uploadMode:"INSTITUTIONAL_APPS_SCRIPT",
      uploadedByProfileId:uploaded.uploadedByProfileId||null,
      uploadedByEmail:uploaded.uploadedByEmail||null
    }
  });
}

export async function downloadDriveFile(fileId,orderId=null){
  if(!fileId)throw new Error("No se recibió el identificador del archivo.");
  if(!orderId)throw new Error("No se recibió el pedido asociado al archivo.");

  const response=await submitToBridge(await authenticatedPayload({
    action:"DOWNLOAD",
    orderId:String(orderId),
    fileId:String(fileId)
  }));

  const downloaded=response.file;
  if(!downloaded?.dataBase64)throw new Error("El puente no devolvió el contenido del archivo.");
  return base64ToBlob(downloaded.dataBase64,downloaded.mimeType);
}
