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
    if(!["all","matrix","controls","backend-total"].includes(suite))throw new Error("suite debe ser all, backend-total, matrix o controls");
    const rpc=async(name:string,params:Record<string,unknown>={})=>{const {data,error}=await client.rpc(name,params);if(error)throw error;return data};
    const output:Record<string,unknown>={suite,cleanup,version:"10.25.0"};

    if(suite==="matrix"){
      output.matrix=await rpc("erp_x_run_qa_matrix",{p_cleanup:cleanup});
    }else if(suite==="controls"){
      output.controls=await rpc("erp_x_run_qa_control_suite",{p_cleanup:cleanup});
    }else{
      const run=await rpc("erp_x_qa_robot_create_run",{p_options:{source:"SUPABASE_EDGE",backendOnly:true}});
      const runId=run?.runId;
      if(!runId)throw new Error("No fue posible crear la ejecución TOTAL_ROBOT.");
      let fatal:unknown=null;
      try{
        const integral=await rpc("erp_x_run_qa_v10_22",{p_cleanup:cleanup});
        output.integral=integral;
        await rpc("erp_x_qa_robot_record_check",{p_run_id:runId,p_check:{checkKey:"EDGE-INTEGRAL",layer:"DOMAIN",suite:"BACKEND_TOTAL",severity:"CRITICAL",status:integral?.success?"PASSED":"FAILED",actual:integral,errorMessage:integral?.success?null:"Backend integral con fallos"}});

        const contract=await rpc("erp_x_qa_robot_system_contract");output.contract=contract;
        await rpc("erp_x_qa_robot_record_check",{p_run_id:runId,p_check:{checkKey:"EDGE-CONTRACT",layer:"CONTRACT",suite:"BACKEND_TOTAL",severity:"CRITICAL",status:contract?.success?"PASSED":"FAILED",actual:contract,errorMessage:contract?.success?null:"Contrato del sistema con fallos"}});

        const branches=await rpc("erp_x_qa_robot_branch_suite",{p_run_id:runId});output.branches=branches;
        await rpc("erp_x_qa_robot_record_check",{p_run_id:runId,p_check:{checkKey:"EDGE-BRANCHES",layer:"DOMAIN",suite:"RAMAS_CRITICAS",severity:"CRITICAL",status:branches?.success?"PASSED":"FAILED",actual:branches,errorMessage:branches?.success?null:"Suite de ramas críticas con fallos"}});
      }catch(error){fatal=error;throw error}
      finally{
        output.robot=await rpc("erp_x_qa_robot_finish_run",{p_run_id:runId,p_cleanup:cleanup}).catch((error:unknown)=>({status:"FAILED",error:error instanceof Error?error.message:String(error),fatal:Boolean(fatal)}));
      }
    }

    const failed=Number((output.matrix as any)?.failed||0)>0||Number((output.controls as any)?.failed||0)>0||(output.robot as any)?.status==="FAILED";
    return new Response(JSON.stringify(output),{status:failed?409:200,headers:{...cors,"Content-Type":"application/json"}});
  }catch(error){
    return new Response(JSON.stringify({error:error instanceof Error?error.message:String(error),version:"10.25.0"}),{status:400,headers:{...cors,"Content-Type":"application/json"}})
  }
});
