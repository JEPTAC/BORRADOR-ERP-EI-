import {CONFIG} from "../config.js";
let client;
export function getSupabase(){
  if(client)return client;
  if(!window.supabase?.createClient)throw new Error("No cargó Supabase JS.");
  client=window.supabase.createClient(CONFIG.supabase.url,CONFIG.supabase.publishableKey,{
    auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:"pkce",storageKey:"ei-erp-supply-v10"}
  });
  return client;
}
export async function signIn(email,password){const {data,error}=await getSupabase().auth.signInWithPassword({email,password});if(error)throw error;return data}
export async function signOut(){const {error}=await getSupabase().auth.signOut();if(error)throw error}
export async function getSession(){const {data,error}=await getSupabase().auth.getSession();if(error)throw error;return data.session}
export function onAuthChange(callback){return getSupabase().auth.onAuthStateChange((_event,session)=>callback(session))}
