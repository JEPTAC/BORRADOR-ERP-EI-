/**
 * ERP EI · Puente institucional de carga a Google Drive
 *
 * DESPLIEGUE OBLIGATORIO:
 * - Ejecutar como: Yo
 * - Quién tiene acceso: Cualquier persona
 *
 * Los trabajadores no autorizan Google Drive. El script valida la sesión
 * activa de Supabase y carga usando la cuenta institucional propietaria.
 */

const SETTINGS = Object.freeze({
  SUPABASE_URL: 'https://hezjxcxxcjlpmyalftam.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_yxgyHILzQVDHrS2MYYkBkA_UfN77JtT',

  // Carpeta institucional suministrada.
  ROOT_FOLDER_ID: '1B9IsvURgsDWxLP84Z7uD3wsDNhh43n_x',

  // Dominio desde el que actualmente se ejecuta el ERP.
  // Cuando el ERP cambie de dominio, agrega el nuevo origen exacto aquí,
  // siempre sin slash al final.
  ALLOWED_ORIGINS: [
    'https://ei-erp-google-auth.vercel.app'
  ],

  // Máximo por archivo. Apps Script no es adecuado para archivos gigantes.
  MAX_FILE_BYTES: 15 * 1024 * 1024,

  // PRIVATE mantiene los documentos privados en el Drive institucional.
  SHARING_MODE: 'PRIVATE'
});

/**
 * Abre la URL /exec para comprobar que el puente esté activo.
 */
function doGet() {
  return HtmlService.createHtmlOutput(
    '<!doctype html><html lang="es"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>ERP EI · Drive</title></head>' +
    '<body style="font-family:Arial,sans-serif;padding:32px;color:#12345b">' +
    '<h1>ERP EI</h1>' +
    '<p>Puente institucional de Google Drive activo.</p>' +
    '<p>Carpeta configurada: <strong>' + escapeHtml_(SETTINGS.ROOT_FOLDER_ID) + '</strong></p>' +
    '</body></html>'
  ).setTitle('ERP EI · Drive');
}

/**
 * Ejecuta manualmente esta función una vez desde el editor.
 * Autoriza Drive y confirma que la carpeta institucional existe.
 */
function probarConfiguracion() {
  const folder = DriveApp.getFolderById(SETTINGS.ROOT_FOLDER_ID);
  const result = {
    ok: true,
    folderId: folder.getId(),
    folderName: folder.getName(),
    folderUrl: folder.getUrl(),
    sharingMode: SETTINGS.SHARING_MODE,
    allowedOrigins: SETTINGS.ALLOWED_ORIGINS
  };
  console.log(JSON.stringify(result, null, 2));
  return result;
}

/**
 * Recibe el archivo enviado por el ERP mediante un formulario oculto.
 */
function doPost(e) {
  let request = {};
  try {
    if (!e || !e.parameter || !e.parameter.payload) {
      throw new Error('Solicitud de carga incompleta.');
    }

    request = JSON.parse(e.parameter.payload);
    validateRequest_(request);

    const session = validateErpSession_(request.accessToken);
    const result = saveFile_(request, session);

    return callbackPage_(request, {
      ok: true,
      uploadId: request.uploadId,
      file: result
    });
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    return callbackPage_(request, {
      ok: false,
      uploadId: request.uploadId || null,
      error: safeError_(error)
    });
  }
}

function validateRequest_(request) {
  if (!request || typeof request !== 'object') {
    throw new Error('Solicitud inválida.');
  }
  if (!request.uploadId) {
    throw new Error('No se recibió el identificador de carga.');
  }
  if (!request.origin || SETTINGS.ALLOWED_ORIGINS.indexOf(request.origin) === -1) {
    throw new Error('El dominio del ERP no está autorizado para cargar archivos.');
  }
  if (!request.accessToken) {
    throw new Error('La sesión del ERP no fue recibida.');
  }
  if (!request.orderId && !request.contextId) {
    throw new Error('No se recibió el contexto del archivo.');
  }
  if (!request.fileName || !request.dataBase64) {
    throw new Error('No se recibió el archivo.');
  }

  const size = Number(request.sizeBytes || 0);
  if (!Number.isFinite(size) || size <= 0) {
    throw new Error('El archivo está vacío.');
  }
  if (size > SETTINGS.MAX_FILE_BYTES) {
    throw new Error(
      'El archivo supera el máximo permitido de ' +
      Math.floor(SETTINGS.MAX_FILE_BYTES / 1024 / 1024) +
      ' MB.'
    );
  }

  const estimatedBytes = Math.floor(String(request.dataBase64).length * 0.75);
  if (estimatedBytes > SETTINGS.MAX_FILE_BYTES + 2048) {
    throw new Error('El contenido recibido supera el tamaño permitido.');
  }
}

/**
 * Valida el JWT de Supabase contra el RPC del ERP y confirma que el usuario
 * tenga un perfil operativo activo.
 */
function validateErpSession_(accessToken) {
  const url =
    SETTINGS.SUPABASE_URL.replace(/\/$/, '') +
    '/rest/v1/rpc/erp_x_session';

  const response = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    payload: '{}',
    muteHttpExceptions: true,
    headers: {
      apikey: SETTINGS.SUPABASE_PUBLISHABLE_KEY,
      Authorization: 'Bearer ' + accessToken
    }
  });

  const status = response.getResponseCode();
  const body = response.getContentText();

  if (status < 200 || status >= 300) {
    throw new Error(
      status === 401 || status === 403
        ? 'La sesión del ERP venció o el usuario no está autorizado.'
        : 'No fue posible validar la sesión del ERP.'
    );
  }

  let session;
  try {
    session = JSON.parse(body || '{}');
  } catch (error) {
    throw new Error('Supabase devolvió una sesión inválida.');
  }

  if (!session.profile || !session.profile.id) {
    throw new Error('El usuario no tiene un perfil operativo activo.');
  }

  return session;
}

function saveFile_(request, session) {
  const bytes = Utilities.base64Decode(request.dataBase64);
  if (bytes.length > SETTINGS.MAX_FILE_BYTES) {
    throw new Error('El archivo supera el tamaño permitido.');
  }

  const safeFileName = safeName_(request.fileName, 'archivo');
  const mimeType = String(
    request.mimeType || 'application/octet-stream'
  ).slice(0, 150);
  const blob = Utilities.newBlob(bytes, mimeType, safeFileName);

  const lock = LockService.getScriptLock();
  lock.waitLock(30000);

  let categoryFolder;
  try {
    const root = DriveApp.getFolderById(SETTINGS.ROOT_FOLDER_ID);
    const yearFolder = findOrCreateFolder_(
      root,
      String(new Date().getFullYear())
    );
    const contextType = String(request.contextType || 'ORDER').toUpperCase();
    const contextId = request.contextId || request.orderId;
    const contextLabel = request.contextLabel || request.orderNumber || contextId;
    const contextPrefix = contextType === 'ACTIVITY' ? 'ACTIVIDAD_' : 'PEDIDO_';
    const contextFolder = findOrCreateFolder_(
      yearFolder,
      contextPrefix + safeName_(contextLabel, 'SIN_REFERENCIA')
    );
    categoryFolder = findOrCreateFolder_(
      contextFolder,
      safeName_(request.category || 'EVIDENCE', 'EVIDENCE')
    );
  } finally {
    lock.releaseLock();
  }

  const file = categoryFolder.createFile(blob);
  const contextType = String(request.contextType || 'ORDER').toUpperCase();
  const contextId = request.contextId || request.orderId;
  const contextLabel = request.contextLabel || request.orderNumber || contextId;
  file.setDescription([
    'ERP EI',
    (contextType === 'ACTIVITY' ? 'Actividad: ' : 'Pedido: ') + String(contextLabel),
    'Contexto: ' + String(contextId),
    'Categoría: ' + String(request.category || 'EVIDENCE'),
    'Usuario ERP: ' + String(
      session.profile.name ||
      session.profile.email ||
      session.profile.id
    ),
    'Perfil ERP: ' + String(session.profile.id),
    'Fecha: ' + new Date().toISOString()
  ].join(' · '));

  if (SETTINGS.SHARING_MODE === 'ANYONE_WITH_LINK') {
    file.setSharing(
      DriveApp.Access.ANYONE_WITH_LINK,
      DriveApp.Permission.VIEW
    );
  }

  return {
    id: file.getId(),
    name: file.getName(),
    mimeType: mimeType,
    size: bytes.length,
    webViewLink: file.getUrl(),
    webContentLink:
      'https://drive.google.com/uc?export=download&id=' +
      encodeURIComponent(file.getId()),
    parentId: categoryFolder.getId(),
    ownerMode: 'INSTITUTIONAL_APPS_SCRIPT',
    uploadedByProfileId: session.profile.id,
    uploadedByEmail: session.profile.email || null
  };
}

function findOrCreateFolder_(parent, name) {
  const folders = parent.getFoldersByName(name);
  return folders.hasNext() ? folders.next() : parent.createFolder(name);
}

function safeName_(value, fallback) {
  const cleaned = String(value || fallback || 'SIN_REFERENCIA')
    .trim()
    .replace(/[\\/:*?"<>|#%{}~&]/g, '-')
    .replace(/\s+/g, ' ')
    .slice(0, 120);

  return cleaned || fallback || 'SIN_REFERENCIA';
}

/**
 * Devuelve el resultado al iframe oculto que inició la carga en el ERP.
 */
function callbackPage_(request, data) {
  const requestedOrigin = request && request.origin;
  const targetOrigin =
    SETTINGS.ALLOWED_ORIGINS.indexOf(requestedOrigin) >= 0
      ? requestedOrigin
      : '*';

  const json = JSON.stringify({
    source: 'ERP_EI_DRIVE_BRIDGE',
    ...data
  })
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026');

  const scriptBody =
    'window.parent.postMessage(' +
    json +
    ',' +
    JSON.stringify(targetOrigin) +
    ');';

  return HtmlService.createHtmlOutput(
    '<!doctype html><html><head><meta charset="utf-8"></head><body>' +
    '<script>' + scriptBody + '</scr' + 'ipt>' +
    '</body></html>'
  ).setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function safeError_(error) {
  const message = String(
    error && error.message
      ? error.message
      : error || 'No fue posible cargar el archivo.'
  );

  if (/Exception|DriveApp|UrlFetch|Utilities|ScriptError/i.test(message)) {
    return 'No fue posible completar la carga institucional. Revisa la configuración del puente de Drive.';
  }

  return message.slice(0, 240);
}

function escapeHtml_(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
