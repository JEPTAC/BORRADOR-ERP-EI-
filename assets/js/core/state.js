export const state = {
  session: null,
  profile: null,
  organization: null,
  modules: [],
  catalogs: {},
  currentModule: "dashboard",
  currentParams: {},
  sidebarOpen: false,
  loading: false,
  ordersCache: new Map(),
  listeners: new Set()
};

export function setState(patch){
  Object.assign(state, patch);
  state.listeners.forEach(fn=>fn(state));
}

export function subscribe(fn){state.listeners.add(fn);return()=>state.listeners.delete(fn)}
export function hasRole(role){return state.profile?.roles?.includes(role) || false}
export function can(moduleCode, capability="canRead"){
  const mod=state.modules.find(m=>m.code===moduleCode);
  return Boolean(mod?.[capability]);
}
