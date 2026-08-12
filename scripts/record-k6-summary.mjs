import fs from "node:fs/promises";
import {CONFIG} from "../assets/js/config.js";

const summary=JSON.parse(await fs.readFile(process.argv[2]||"qa-capacity-summary.json","utf8"));
const url=process.env.ERP_QA_SUPABASE_URL||CONFIG.supabase.url;
const key=process.env.ERP_QA_SUPABASE_ANON_KEY||CONFIG.supabase.publishableKey;
const email=process.env.ERP_QA_EMAIL||process.env.ERP_TEST_EMAIL;
const password=process.env.ERP_QA_PASSWORD||process.env.ERP_TEST_PASSWORD;
if(!email||!password)throw new Error("Faltan ERP_QA_EMAIL / ERP_QA_PASSWORD");
const login=await fetch(`${url}/auth/v1/token?grant_type=password`,{method:"POST",headers:{"Content-Type":"application/json","apikey":key},body:JSON.stringify({email,password})});
if(!login.ok)throw new Error(`Login QA falló ${login.status}: ${await login.text()}`);
const auth=await login.json();
const payload={source:"K6_GITHUB",profile:summary.profile,status:summary.thresholdsPassed?"PASSED":"FAILED",maxVirtualUsers:summary.maxVirtualUsers,totalRequests:summary.totalRequests,requestRate:summary.requestRate,errorRate:summary.errorRate,p50Ms:summary.p50Ms,p90Ms:summary.p90Ms,p95Ms:summary.p95Ms,p99Ms:summary.p99Ms,maxMs:summary.maxMs,checksRate:summary.checksRate,thresholds:{http_req_failed:"<1%",p95:"<1800ms",p99:"<3500ms",checks:">99%"},stages:summary.stages,summary};
const res=await fetch(`${url}/rest/v1/rpc/erp_x_qa_capacity_record`,{method:"POST",headers:{"Content-Type":"application/json","apikey":key,"Authorization":`Bearer ${auth.access_token}`},body:JSON.stringify({p_payload:payload})});
if(!res.ok)throw new Error(`No se pudo registrar capacidad ${res.status}: ${await res.text()}`);
console.log("Capacidad registrada en ERP:",await res.text());
