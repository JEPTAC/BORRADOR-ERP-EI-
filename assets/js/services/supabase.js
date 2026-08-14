import {CONFIG} from "../config.js";

let client;
const AUTH_STORAGE_KEY="ei-erp-supply-v10";
const PROJECT_REF=(()=>{try{return new URL(CONFIG.supabase.url).hostname.split(".")[0]||""}catch{return ""}})();

function message(error){
  const raw=String(error?.message||error||"");
  const code=String(error?.code||"");
  if(code==="invalid_credentials")return "Correo o contraseña incorrectos.";
  const rules=[
    [/invalid login credentials/i,"Correo o contraseña incorrectos."],
    [/email not confirmed/i,"El correo todavía no ha sido confirmado."],
    [/user not found/i,"No existe una cuenta activa con ese correo."],
    [/password should be/i,"La contraseña no cumple los requisitos de seguridad."],
    [/jwt expired|token.*expired|refresh token.*not found|invalid refresh token/i,"Tu sesión venció. Ingresa nuevamente."],
    [/failed to fetch|networkerror|load failed/i,"No fue posible conectar con el ERP. Revisa la conexión e inténtalo nuevamente."]
  ];
  return rules.find(([re])=>re.test(raw))?.[1]||raw||"No fue posible completar la solicitud.";
}
function throwError(error){
  const e=new Error(message(error));
  Object.assign(e,error||{});
  e.message=message(error);
  throw e;
}
function removeStoredAuth(){
  try{
    const prefixes=[AUTH_STORAGE_KEY,PROJECT_REF?`sb-${PROJECT_REF}-auth-token`:""] .filter(Boolean);
    for(let i=localStorage.length-1;i>=0;i--){
      const key=localStorage.key(i);
      if(key&&prefixes.some(prefix=>key===prefix||key.startsWith(`${prefix}.`)||key.startsWith(`${prefix}-`)))localStorage.removeItem(key);
    }
  }catch{}
}
export function getSupabase(){
  if(client)return client;
  if(!window.supabase?.createClient)throw new Error("No fue posible iniciar el servicio del ERP. Recarga la página e inténtalo nuevamente.");
  client=window.supabase.createClient(CONFIG.supabase.url,CONFIG.supabase.publishableKey,{
    auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:"pkce",storageKey:AUTH_STORAGE_KEY},
    db:{retry:false}
  });
  return client;
}
export async function clearLocalSession(){
  const auth=getSupabase().auth;
  try{await auth.signOut({scope:"local"})}catch{}
  removeStoredAuth();
}
export async function signIn(email,password){
  const normalized=String(email||"").trim().toLowerCase();
  const {data,error}=await getSupabase().auth.signInWithPassword({email:normalized,password});
  if(error)throwError(error);
  return data;
}
export async function signOut(){
  const {error}=await getSupabase().auth.signOut({scope:"local"});
  removeStoredAuth();
  if(error)throwError(error);
}
export async function getSession(){
  const {data,error}=await getSupabase().auth.getSession();
  if(error){await clearLocalSession();throwError(error)}
  return data.session;
}
export function onAuthChange(callback){return getSupabase().auth.onAuthStateChange((event,session)=>callback(session,event))}
