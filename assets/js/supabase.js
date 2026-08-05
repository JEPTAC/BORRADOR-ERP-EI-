import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { CONFIG } from "./config.js";

export const supabase = createClient(CONFIG.supabase.url, CONFIG.supabase.publishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  global: { headers: { "X-ERP-Client": `EI-ERP-Nova/${CONFIG.version}` } }
});

export async function requireSession(){
  const { data, error } = await supabase.auth.getSession();
  if(error) throw error;
  return data.session || null;
}

export async function signIn(email,password){
  const { data, error } = await supabase.auth.signInWithPassword({email,password});
  if(error) throw error;
  return data;
}

export async function signOut(){
  const { error } = await supabase.auth.signOut();
  if(error) throw error;
}
