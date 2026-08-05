import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  try{
    const url=Deno.env.get("SUPABASE_URL")!;const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
    let authorization=req.headers.get("Authorization")||"";
    let client=createClient(url,anon,{global:{headers:authorization?{Authorization:authorization}:{}}});
    if(!authorization){
      const email=Deno.env.get("ERP_QA_EMAIL"),password=Deno.env.get("ERP_QA_PASSWORD");
      if(!email||!password)throw new Error("Configure ERP_QA_EMAIL y ERP_QA_PASSWORD o envíe un JWT de Super Admin.");
      const {data,error}=await client.auth.signInWithPassword({email,password});if(error)throw error;
      authorization=`Bearer ${data.session.access_token}`;
      client=createClient(url,anon,{global:{headers:{Authorization:authorization}}});
    }
    const {cleanup=true,suite="all"}=await req.json().catch(()=>({cleanup:true,suite:"all"}));
    if(!["all","matrix","controls"].includes(suite))throw new Error("suite debe ser all, matrix o controls");
    const output:Record<string,unknown>={suite,cleanup};
    if(suite==="all"||suite==="matrix"){
      const {data,error}=await client.rpc("erp_x_run_qa_matrix",{p_cleanup:cleanup});if(error)throw error;output.matrix=data;
      if(suite==="all"&&Number(data?.failed||0)>0)return new Response(JSON.stringify(output),{status:409,headers:{...cors,"Content-Type":"application/json"}});
    }
    if(suite==="all"||suite==="controls"){
      const {data,error}=await client.rpc("erp_x_run_qa_control_suite",{p_cleanup:cleanup});if(error)throw error;output.controls=data;
    }
    return new Response(JSON.stringify(output),{status:200,headers:{...cors,"Content-Type":"application/json"}});
  }catch(error){return new Response(JSON.stringify({error:error instanceof Error?error.message:String(error)}),{status:400,headers:{...cors,"Content-Type":"application/json"}})}
});
