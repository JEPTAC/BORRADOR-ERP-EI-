import http from "k6/http";
import {check,sleep} from "k6";
import {Trend,Rate,Counter} from "k6/metrics";
import {CONFIG} from "../../assets/js/config.js";

const SUPABASE_URL=__ENV.ERP_QA_SUPABASE_URL||CONFIG.supabase.url;
const ANON_KEY=__ENV.ERP_QA_SUPABASE_ANON_KEY||CONFIG.supabase.publishableKey;
const EMAIL=__ENV.ERP_TEST_EMAIL||__ENV.ERP_QA_EMAIL;
const PASSWORD=__ENV.ERP_TEST_PASSWORD||__ENV.ERP_QA_PASSWORD;
const PROFILE=String(__ENV.ERP_LOAD_PROFILE||"NORMAL").toUpperCase();
const WRITE_RATIO=Math.max(0,Math.min(0.35,Number(__ENV.ERP_LOAD_WRITE_RATIO||0.12)));
const BREAKPOINT_MAX=Math.max(20,Math.min(500,Number(__ENV.ERP_BREAKPOINT_MAX_VUS||200)));
const USER_POOL_RAW=__ENV.ERP_QA_USER_POOL||"";

function breakpointStages(max){
  const targets=[10,20,35,50,70,90,120,160,200,250,300,400,500].filter(x=>x<=max);
  if(!targets.includes(max))targets.push(max);
  return [...new Set(targets)].sort((a,b)=>a-b).flatMap(target=>[{duration:"25s",target},{duration:"35s",target}]).concat([{duration:"20s",target:0}]);
}
const stagesByProfile={
  SMOKE:[{duration:"10s",target:2},{duration:"20s",target:2},{duration:"5s",target:0}],
  NORMAL:[{duration:"20s",target:5},{duration:"40s",target:10},{duration:"40s",target:15},{duration:"15s",target:0}],
  BUSY:[{duration:"20s",target:10},{duration:"40s",target:20},{duration:"50s",target:30},{duration:"20s",target:0}],
  PEAK:[{duration:"20s",target:15},{duration:"40s",target:30},{duration:"60s",target:50},{duration:"20s",target:0}],
  SPIKE:[{duration:"10s",target:5},{duration:"5s",target:75},{duration:"60s",target:75},{duration:"10s",target:5},{duration:"10s",target:0}],
  SOAK:[{duration:"20s",target:20},{duration:"10m",target:20},{duration:"20s",target:0}],
  BREAKPOINT:breakpointStages(BREAKPOINT_MAX)
};
const stages=stagesByProfile[PROFILE]||stagesByProfile.NORMAL;
const breakpoint=PROFILE==="BREAKPOINT";

const erpLatency=new Trend("erp_rpc_duration",true);
const erpErrors=new Rate("erp_rpc_errors");
const erpWrites=new Counter("erp_test_writes");
const erpReads=new Counter("erp_reads");
const authErrors=new Rate("erp_auth_errors");

export const options={
  scenarios:{erp_capacity:{executor:"ramping-vus",stages,gracefulRampDown:"10s"}},
  thresholds:{
    http_req_failed:[breakpoint?{threshold:"rate<0.01",abortOnFail:true,delayAbortEval:"20s"}:{threshold:"rate<0.01",abortOnFail:false}],
    http_req_duration:[breakpoint?{threshold:"p(95)<1800",abortOnFail:true,delayAbortEval:"20s"}:"p(95)<1800","p(99)<3500"],
    erp_rpc_errors:[breakpoint?{threshold:"rate<0.01",abortOnFail:true,delayAbortEval:"20s"}:"rate<0.01"],
    checks:["rate>0.99"],
    erp_auth_errors:["rate<0.01"]
  },
  summaryTrendStats:["avg","min","med","p(90)","p(95)","p(99)","max"]
};

function baseHeaders(token){return {"Content-Type":"application/json","apikey":ANON_KEY,"Authorization":`Bearer ${token}`}}
function rpc(token,name,payload={},tags={}){
  const started=Date.now();
  const res=http.post(`${SUPABASE_URL}/rest/v1/rpc/${name}`,JSON.stringify(payload),{headers:baseHeaders(token),tags:{rpc:name,...tags}});
  erpLatency.add(Date.now()-started,{rpc:name});
  const ok=res.status>=200&&res.status<300;
  erpErrors.add(!ok,{rpc:name});
  check(res,{[`${name} status 2xx`]:r=>r.status>=200&&r.status<300});
  return res;
}
function json(res){try{return res.json()}catch{return null}}
function credentials(){
  if(USER_POOL_RAW){
    try{
      const pool=JSON.parse(USER_POOL_RAW);
      if(Array.isArray(pool)&&pool.length)return pool.filter(x=>x?.email&&x?.password);
    }catch(error){throw new Error(`ERP_QA_USER_POOL no es JSON válido: ${error.message}`)}
  }
  return EMAIL&&PASSWORD?[{email:EMAIL,password:PASSWORD,label:"primary"}]:[];
}
function login(credential){
  const res=http.post(`${SUPABASE_URL}/auth/v1/token?grant_type=password`,JSON.stringify({email:credential.email,password:credential.password}),{headers:{"Content-Type":"application/json","apikey":ANON_KEY},tags:{kind:"auth"}});
  const ok=res.status>=200&&res.status<300;authErrors.add(!ok);
  if(!ok)throw new Error(`Login QA falló para ${credential.email}: ${res.status} ${res.body}`);
  const data=json(res);if(!data?.access_token)throw new Error(`Supabase no devolvió access_token para ${credential.email}.`);
  return {token:data.access_token,email:credential.email,label:credential.label||credential.email};
}

export function setup(){
  const creds=credentials();if(!creds.length)throw new Error("Configura ERP_QA_EMAIL/ERP_QA_PASSWORD o ERP_QA_USER_POOL.");
  const sessions=creds.map(login);
  // El primer usuario debe ser Super Admin para crear/limpiar la corrida QA.
  const owner=sessions[0];
  const run=rpc(owner.token,"erp_x_qa_robot_create_run",{p_options:{source:"K6",profile:PROFILE,writeRatio:WRITE_RATIO,sessionCount:sessions.length,startedAt:new Date().toISOString()}});
  const runData=json(run);if(!runData?.runId)throw new Error(`No se pudo crear qa_run para capacidad: ${run.body}`);
  return {sessions,ownerToken:owner.token,runId:runData.runId,startedAt:new Date().toISOString(),profile:PROFILE};
}

const readCalls=[
  ["erp_x_dashboard",{}],
  ["erp_x_list_orders",{p_search:null,p_step:null,p_status:null,p_order_type:null,p_route:null,p_assignment:"ALL",p_page:1,p_page_size:25,p_include_history:false}],
  ["erp_x_inventory_filtered",{p_payload:{page:1,pageSize:25,search:"",availability:"ALL"}}],
  ["erp_x_work_my_day",{p_day:null}],
  ["erp_x_list_approvals",{p_status:"PENDING",p_page:1,p_page_size:25}],
  ["erp_x_exception_summary",{}],
  ["erp_x_runtime_diagnostics",{}]
];

function readJourney(token){
  const [name,payload]=readCalls[Math.floor(Math.random()*readCalls.length)];erpReads.add(1);
  rpc(token,name,payload,{kind:"read"});
}
function writeJourney(token,runId){
  erpWrites.add(1);
  const seed=rpc(token,"erp_x_qa_robot_seed_order",{p_run_id:runId,p_payload:{scenarioKey:`LOAD-${__VU}-${__ITER}-${Date.now()}`,stepCode:"RECEPCION_PEDIDO",orderType:["PVC","PVN","PVE","PVP"][__VU%4],paymentCondition:__VU%4===1?"CASH":"CREDIT",deliveryRoute:["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH"][__ITER%4],requiresCut:(__ITER%5===0),requiresPurchase:(__VU%4===2)}},{kind:"write"});
  const data=json(seed),orderId=data?.orderId;if(!orderId)return;
  if(__ITER%3===0){
    const issue=rpc(token,"erp_x_create_order_issue",{p_order_id:orderId,p_payload:{type:__ITER%2===0?"NOVELTY":"REPORT",title:"Carga QA",detail:"Novedad sintética de carga",targetRole:"jefe_logistica",sourceCode:"QA_LOAD"}},{kind:"write"});
    const issueId=json(issue)?.issue?.id;
    if(issueId)rpc(token,"erp_x_resolve_order_issue",{p_issue_id:issueId,p_payload:{resolution:"Resuelta por prueba de carga",resolutionCode:"RESOLVED"}},{kind:"write"});
  }
  rpc(token,"erp_x_sandbox_delete",{p_order_id:orderId},{kind:"cleanup"});
}

export default function(data){
  const sessions=data.sessions||[];const session=sessions[(__VU-1)%Math.max(1,sessions.length)]||{token:data.ownerToken};
  // Las escrituras QA requieren permisos Super Admin. Si el pool contiene
  // otros roles, usa WRITE_RATIO=0 o mantén Super Admin como todos los miembros
  // del pool de capacidad. Las pruebas funcionales de permisos se ejecutan aparte.
  if(Math.random()<WRITE_RATIO)writeJourney(session.token,data.runId);else readJourney(session.token);
  sleep(0.15+Math.random()*0.35);
}

export function teardown(data){
  if(!data?.ownerToken||!data?.runId)return;
  rpc(data.ownerToken,"erp_x_qa_robot_cleanup",{p_run_id:data.runId},{kind:"cleanup"});
  rpc(data.ownerToken,"erp_x_qa_robot_finish_run",{p_run_id:data.runId,p_cleanup:true},{kind:"cleanup"});
}

export function handleSummary(data){
  const m=data.metrics||{};
  const compact={
    profile:PROFILE,writeRatio:WRITE_RATIO,configuredBreakpointMax:BREAKPOINT_MAX,
    maxVirtualUsers:m.vus_max?.values?.max??m.vus_max?.values?.value??null,
    activeVirtualUsersPeak:m.vus?.values?.max??null,
    totalRequests:m.http_reqs?.values?.count??0,requestRate:m.http_reqs?.values?.rate??0,
    errorRate:m.http_req_failed?.values?.rate??0,checksRate:m.checks?.values?.rate??0,authErrorRate:m.erp_auth_errors?.values?.rate??0,
    p50Ms:m.http_req_duration?.values?.med??0,p90Ms:m.http_req_duration?.values?.["p(90)"]??0,p95Ms:m.http_req_duration?.values?.["p(95)"]??0,
    p99Ms:m.http_req_duration?.values?.["p(99)"]??0,maxMs:m.http_req_duration?.values?.max??0,
    customRpcP95:m.erp_rpc_duration?.values?.["p(95)"]??0,testWrites:m.erp_test_writes?.values?.count??0,reads:m.erp_reads?.values?.count??0,
    thresholdsPassed:Object.values(m).every(metric=>!metric?.thresholds||Object.values(metric.thresholds).every(x=>x.ok!==false)),stages
  };
  return {"qa-capacity-summary.json":JSON.stringify(compact,null,2),stdout:`\nERP QA CAPACITY ${PROFILE}\n${JSON.stringify(compact,null,2)}\n`};
}
