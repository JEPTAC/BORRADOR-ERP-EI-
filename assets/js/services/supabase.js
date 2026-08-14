import {CONFIG} from "../config.js";
let client;
function message(error){
  const raw=String(error?.message||error||"");
  const rules=[
    [/invalid login credentials/i,"Correo o contraseña incorrectos."],
    [/email not confirmed/i,"El correo todavía no ha sido confirmado."],
    [/user not found/i,"No existe una cuenta activa con ese correo."],
    [/password should be/i,"La contraseña no cumple los requisitos de seguridad."],
    [/jwt expired|token.*expired/i,"Tu sesión venció. Ingresa nuevamente."],
    [/failed to fetch|networkerror|load failed/i,"No fue posible conectar con el ERP. Revisa la conexión e inténtalo nuevamente."]
  ];
  return rules.find(([re])=>re.test(raw))?.[1]||raw||"No fue posible completar la solicitud.";
}
function throwError(error){const e=new Error(message(error));Object.assign(e,error||{});throw e}
export function getSupabase(){
  if(client)return client;
  if(!window.supabase?.createClient)throw new Error("No fue posible iniciar el servicio del ERP. Recarga la página e inténtalo nuevamente.");
  client=window.supabase.createClient(CONFIG.supabase.url,CONFIG.supabase.publishableKey,{
    auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:"pkce",storageKey:"ei-erp-supply-v10"},
    // Evita reintentos automáticos de PostgREST ante 503/504; la interfaz informa el fallo y permite reintentar de forma controlada.
    db:{retry:false}
  });
  return client;
}
export async function signIn(email,password){const {data,error}=await getSupabase().auth.signInWithPassword({email,password});if(error)throwError(error);return data}
export async function signOut(){const {error}=await getSupabase().auth.signOut();if(error)throwError(error)}
export async function getSession(){const {data,error}=await getSupabase().auth.getSession();if(error)throwError(error);return data.session}
export function onAuthChange(callback){return getSupabase().auth.onAuthStateChange((_event,session)=>callback(session))}
