import {CONFIG} from "../config.js";

/*
 * Servicio estable de archivos.
 * Mantiene siempre el mismo contrato para que una falla de Google Drive no
 * interrumpa el arranque general del ERP. El proveedor real se carga solo
 * cuando el usuario sube o descarga un archivo.
 */
let servicePromise;

function configuredMode(){
  return String(CONFIG?.drive?.mode||"oauth").trim().toLowerCase()==="bridge"?"bridge":"oauth";
}

async function loadService(){
  if(servicePromise)return servicePromise;
  servicePromise=configuredMode()==="bridge"
    ? import("./drive-bridge.js")
    : import("./drive-oauth.js");
  try{
    return await servicePromise;
  }catch(error){
    servicePromise=null;
    throw error;
  }
}

export async function uploadOrderFile(...args){
  const service=await loadService();
  if(typeof service.uploadOrderFile!=="function"){
    throw new Error("El servicio de archivos no tiene disponible la función de carga.");
  }
  return service.uploadOrderFile(...args);
}

export async function downloadDriveFile(...args){
  const service=await loadService();
  if(typeof service.downloadDriveFile!=="function"){
    throw new Error("El servicio de archivos no tiene disponible la función de descarga.");
  }
  return service.downloadDriveFile(...args);
}

export function getDriveMode(){
  return configuredMode();
}
