import {setState,state} from "./state.js";
let handler;
export function parseHash(){const raw=location.hash.replace(/^#\/?/,"")||"dashboard";const [path,q=""]=raw.split("?");return {module:path.split("/")[0]||"dashboard",params:Object.fromEntries(new URLSearchParams(q)),segments:path.split("/")}}
export function navigate(module,params={}){const q=new URLSearchParams(Object.entries(params).filter(([,v])=>v!==null&&v!==undefined&&v!=="")).toString();location.hash=`#/${module}${q?`?${q}`:""}`}
export function initRouter(fn){handler=fn;const run=()=>{const route=parseHash();setState({currentModule:route.module,currentParams:route.params});handler(route)};window.addEventListener("hashchange",run);run()}
export {state};
