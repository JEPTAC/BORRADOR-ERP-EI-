import {CONFIG} from "../config.js";
import {api} from "./api.js";

/*
 * V10.11.2 · Carga institucional a Google Drive
 *
 * Las cargas se envían al Apps Script institucional, que valida la sesión
 * de Supabase y escribe con la cuenta propietaria. Por eso el trabajador no
 * inicia sesión en Google ni autoriza Drive para subir archivos.
 *
 * La autorización OAuth de Google se conserva únicamente como compatibilidad
 * para descargar un PDF privado ya existente cuando el lector de Recepción
 * lo necesita. No se utiliza para subir facturas, fotos, anexos o evidencias.
 */
const MAX_FILE_BYTES = Number(CONFIG.drive.maxFileBytes || 15 * 1024 * 1024);
const BRIDGE_TIMEOUT_MS = 180000;

let tokenClient;
let accessToken;

function safeName(value, fallback = "SIN_REFERENCIA") {
  return String(value || fallback)
    .trim()
    .replace(/[\\/:*?"<>|#%{}~&]/g, "-")
    .replace(/\s+/g, " ")
    .slice(0, 120) || fallback;
}

function bridgeUrl() {
  const url = String(CONFIG.drive.bridgeUrl || "").trim();
  if (!/^https:\/\/script\.google\.com\/macros\/s\/.+\/exec$/i.test(url)) {
    throw new Error("El administrador todavía no configuró el puente institucional de Google Drive.");
  }
  return url;
}

async function currentSession() {
  const authService = await import("./supabase.js");

  if (typeof authService.getSession === "function") {
    return authService.getSession();
  }

  if (typeof authService.getSupabase === "function") {
    const {data, error} = await authService.getSupabase().auth.getSession();
    if (error) throw error;
    return data?.session || null;
  }

  throw new Error("No fue posible consultar la sesión activa del ERP.");
}

async function fileToBase64(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const chunkSize = 0x8000;
  let binary = "";

  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(
      ...bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length))
    );
  }

  return btoa(binary);
}

function isBridgeOrigin(origin) {
  try {
    const url = new URL(origin);
    return url.protocol === "https:" && (
      url.hostname === "script.google.com" ||
      url.hostname === "script.googleusercontent.com" ||
      url.hostname.endsWith(".googleusercontent.com")
    );
  } catch {
    return false;
  }
}

function submitToBridge(payload) {
  return new Promise((resolve, reject) => {
    const frameName = `erp_drive_${String(payload.uploadId).replace(/[^a-z0-9_-]/gi, "")}`;
    const iframe = document.createElement("iframe");
    iframe.name = frameName;
    iframe.hidden = true;
    iframe.setAttribute("aria-hidden", "true");

    const form = document.createElement("form");
    form.method = "POST";
    form.action = bridgeUrl();
    form.target = frameName;
    form.enctype = "application/x-www-form-urlencoded";
    form.hidden = true;

    const field = document.createElement("textarea");
    field.name = "payload";
    field.value = JSON.stringify(payload);
    form.appendChild(field);

    let settled = false;
    let timer;

    const cleanup = () => {
      window.removeEventListener("message", onMessage);
      if (timer) clearTimeout(timer);
      form.remove();
      iframe.remove();
    };

    const finish = (handler, value) => {
      if (settled) return;
      settled = true;
      cleanup();
      handler(value);
    };

    const onMessage = event => {
      const data = event.data;
      if (
        !isBridgeOrigin(event.origin) ||
        data?.source !== "ERP_EI_DRIVE_BRIDGE" ||
        data?.uploadId !== payload.uploadId
      ) return;

      if (data.ok && data.file) finish(resolve, data.file);
      else finish(reject, new Error(data.error || "No fue posible cargar el archivo en Google Drive."));
    };

    timer = setTimeout(() => {
      finish(reject, new Error("La carga institucional tardó demasiado. Revisa que el Apps Script siga desplegado e inténtalo nuevamente."));
    }, BRIDGE_TIMEOUT_MS);

    window.addEventListener("message", onMessage);
    document.body.appendChild(iframe);
    document.body.appendChild(form);
    form.submit();
  });
}

export async function uploadOrderFile(
  orderId,
  file,
  category = "EVIDENCE",
  taskId = null,
  orderNumber = null
) {
  if (!orderId) throw new Error("No se recibió el identificador del pedido.");
  if (!(file instanceof File)) throw new Error("Seleccione un archivo válido.");
  if (file.size <= 0) throw new Error("El archivo está vacío.");
  if (file.size > MAX_FILE_BYTES) {
    throw new Error(`El archivo supera el máximo permitido de ${Math.floor(MAX_FILE_BYTES / 1024 / 1024)} MB.`);
  }

  const session = await currentSession();
  if (!session?.access_token) throw new Error("Tu sesión venció. Ingresa nuevamente al ERP.");

  const uploadId = typeof crypto?.randomUUID === "function"
    ? crypto.randomUUID()
    : `upload_${Date.now()}_${Math.random().toString(36).slice(2)}`;

  const uploaded = await submitToBridge({
    uploadId,
    origin: window.location.origin,
    accessToken: session.access_token,
    orderId: String(orderId),
    taskId: taskId ? String(taskId) : null,
    orderNumber: orderNumber ? String(orderNumber) : null,
    category: String(category || "EVIDENCE"),
    fileName: safeName(file.name, "archivo"),
    mimeType: file.type || "application/octet-stream",
    sizeBytes: file.size,
    dataBase64: await fileToBase64(file),
    clientVersion: CONFIG.version || "ERP_EI"
  });

  return api.registerDriveFile({
    orderId,
    taskId,
    category,
    driveFileId: uploaded.id,
    fileName: uploaded.name,
    mimeType: uploaded.mimeType || file.type || "application/octet-stream",
    sizeBytes: Number(uploaded.size || file.size),
    webViewLink: uploaded.webViewLink,
    webContentLink: uploaded.webContentLink,
    metadata: {
      orderNumber: orderNumber || null,
      driveParentId: uploaded.parentId || null,
      uploadMode: "INSTITUTIONAL_APPS_SCRIPT",
      uploadedByProfileId: uploaded.uploadedByProfileId || null,
      uploadedByEmail: uploaded.uploadedByEmail || null
    }
  });
}

/* Compatibilidad exclusiva para el lector PDF de Recepción. */
function requireGsi() {
  if (!window.google?.accounts?.oauth2) {
    throw new Error("El servicio de lectura de PDF no está disponible. Recarga la página e inténtalo nuevamente.");
  }
}

async function downloadToken() {
  if (accessToken) return accessToken;
  requireGsi();

  return new Promise((resolve, reject) => {
    tokenClient = tokenClient || google.accounts.oauth2.initTokenClient({
      client_id: CONFIG.drive.clientId,
      scope: CONFIG.drive.scope,
      callback: response => response.error
        ? reject(new Error(response.error))
        : resolve(accessToken = response.access_token)
    });
    tokenClient.requestAccessToken({prompt: ""});
  });
}

export async function downloadDriveFile(fileId) {
  const id = String(fileId || "").trim();
  if (!id) throw new Error("No se recibió el identificador del archivo.");

  const token = await downloadToken();
  const response = await fetch(
    `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(id)}?alt=media`,
    {headers: {Authorization: `Bearer ${token}`}}
  );

  if (!response.ok) {
    await response.text().catch(() => "");
    if (response.status === 403 || response.status === 404) {
      throw new Error("No fue posible abrir el PDF cargado por el asesor. Verifica que esté compartido con tu cuenta o selecciónalo manualmente.");
    }
    throw new Error(`No fue posible descargar el PDF (código ${response.status}).`);
  }

  return response.blob();
}
