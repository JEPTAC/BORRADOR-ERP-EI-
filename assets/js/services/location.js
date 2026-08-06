const reverseCache=new Map();
const searchCache=new Map();
const elevationCache=new Map();
const municipalityCache=new Map();

const NOMINATIM_BASE="https://nominatim.openstreetmap.org";
const DIVIPOLA_BASE="https://www.datos.gov.co/resource/gdxc-w37w.json";
const LEAFLET_JS="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
const LEAFLET_CSS="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
const DEFAULT_CENTER=[4.5709,-74.2973];
const DEPARTMENTS=Object.freeze([
  ["05","Antioquia"],["08","Atlántico"],["11","Bogotá, D.C."],["13","Bolívar"],["15","Boyacá"],["17","Caldas"],["18","Caquetá"],["19","Cauca"],["20","Cesar"],["23","Córdoba"],["25","Cundinamarca"],["27","Chocó"],["41","Huila"],["44","La Guajira"],["47","Magdalena"],["50","Meta"],["52","Nariño"],["54","Norte de Santander"],["63","Quindío"],["66","Risaralda"],["68","Santander"],["70","Sucre"],["73","Tolima"],["76","Valle del Cauca"],["81","Arauca"],["85","Casanare"],["86","Putumayo"],["88","Archipiélago de San Andrés, Providencia y Santa Catalina"],["91","Amazonas"],["94","Guainía"],["95","Guaviare"],["97","Vaupés"],["99","Vichada"]
].map(([code,name])=>({code,name})));
let lastNominatimRequestAt=0;
let leafletPromise=null;

function getPosition(options){
  return new Promise((resolve,reject)=>{
    if(!navigator.geolocation){reject(new Error("Este dispositivo no permite obtener la ubicación."));return;}
    navigator.geolocation.getCurrentPosition(resolve,error=>{
      const messages={1:"Debes permitir el acceso a la ubicación para completar este paso.",2:"No fue posible determinar la ubicación actual.",3:"La ubicación tardó demasiado. Inténtalo nuevamente en un lugar con mejor señal."};
      reject(new Error(messages[error.code]||"No fue posible obtener la ubicación."));
    },options);
  });
}

function addressParts(data={}){
  const address=data.address||{};
  return {
    address:String(data.display_name||"").trim(),
    municipality:String(address.city||address.town||address.village||address.municipality||address.city_district||address.county||"").trim(),
    department:String(address.state||address.region||"").trim(),
    country:String(address.country||"").trim(),
    postalCode:String(address.postcode||"").trim(),
    neighborhood:String(address.neighbourhood||address.suburb||address.quarter||"").trim(),
    source:"OpenStreetMap Nominatim",
    placeId:data.place_id||null,
    displayName:String(data.display_name||"").trim(),
    type:String(data.type||data.addresstype||"").trim()
  };
}

function normalizeText(value){return String(value||"").trim().replace(/\s+/g," ")}
function normalizeComparable(value){return normalizeText(value).normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-z0-9]/gi,"").toLowerCase()}
function finite(value){const parsed=Number(String(value??"").replace(",","."));return Number.isFinite(parsed)?parsed:null}
function sleep(ms){return new Promise(resolve=>setTimeout(resolve,ms))}
function titlePlace(value){
  const lowerWords=new Set(["de","del","la","las","los","y","e"]);
  return normalizeText(value).toLocaleLowerCase("es-CO").split(/(\s+|-)/).map((part,index)=>{
    if(/^\s+$|-$/.test(part))return part;
    if(/^d\.?c\.?$/i.test(part))return "D.C.";
    if(index>0&&lowerWords.has(part))return part;
    return part.charAt(0).toLocaleUpperCase("es-CO")+part.slice(1);
  }).join("").replace(/Bogotá, D\.c\./i,"Bogotá, D.C.");
}

async function nominatimJson(url){
  const elapsed=Date.now()-lastNominatimRequestAt;
  if(elapsed<1050)await sleep(1050-elapsed);
  lastNominatimRequestAt=Date.now();
  const response=await fetch(url,{headers:{Accept:"application/json","Accept-Language":"es-CO,es;q=0.9"}});
  if(!response.ok)throw new Error("El servicio de ubicación no respondió. Inténtalo nuevamente.");
  return response.json();
}

async function divipolaJson(url){
  const response=await fetch(url,{headers:{Accept:"application/json"}});
  if(!response.ok)throw new Error("No fue posible cargar la lista oficial de municipios.");
  return response.json();
}

function resultFromRow(row){
  const latitude=finite(row.lat),longitude=finite(row.lon);
  return {
    ...addressParts(row),
    latitude,
    longitude,
    altitude:null,
    accuracy:null,
    capturedAt:new Date().toISOString(),
    source:"ADDRESS_SEARCH"
  };
}

export function colombianDepartments(){return DEPARTMENTS.map(item=>({...item}))}

export function findDepartmentByName(name){
  const wanted=normalizeComparable(name);
  return DEPARTMENTS.find(item=>normalizeComparable(item.name)===wanted)||null;
}

export async function colombianMunicipalities(departmentCode){
  const code=String(departmentCode||"").replace(/\D/g,"").padStart(2,"0").slice(-2);
  if(!DEPARTMENTS.some(item=>item.code===code))throw new Error("Selecciona un departamento válido.");
  if(municipalityCache.has(code))return municipalityCache.get(code).map(item=>({...item}));
  const storageKey=`erp_divipola_${code}_2024`;
  try{
    const cached=sessionStorage.getItem(storageKey);
    if(cached){
      const parsed=JSON.parse(cached);
      if(Array.isArray(parsed)&&parsed.length){municipalityCache.set(code,parsed);return parsed.map(item=>({...item}));}
    }
  }catch{}

  const url=new URL(DIVIPOLA_BASE);
  url.searchParams.set("$select","cod_mpio,nom_mpio,tipo_municipio,latitud,longitud");
  url.searchParams.set("$where",`cod_dpto='${code}'`);
  url.searchParams.set("$order","nom_mpio");
  url.searchParams.set("$limit","1500");
  const rows=await divipolaJson(url);
  const unique=new Map();
  for(const row of rows||[]){
    const municipality={
      code:String(row.cod_mpio||"").trim(),
      name:titlePlace(row.nom_mpio||""),
      type:titlePlace(row.tipo_municipio||"Municipio"),
      latitude:finite(row.latitud),
      longitude:finite(row.longitud)
    };
    if(municipality.code&&municipality.name)unique.set(municipality.code,municipality);
  }
  const result=[...unique.values()].sort((a,b)=>a.name.localeCompare(b.name,"es"));
  if(!result.length)throw new Error("El departamento seleccionado no devolvió municipios.");
  municipalityCache.set(code,result);
  try{sessionStorage.setItem(storageKey,JSON.stringify(result))}catch{}
  return result.map(item=>({...item}));
}

export function findMunicipalityByName(items,name){
  const wanted=normalizeComparable(name);
  return (items||[]).find(item=>normalizeComparable(item.name)===wanted)||null;
}

export function buildColombianAddress({mode="URBAN",roadType,mainRoad,crossRoad,propertyNumber,neighborhood,complement,ruralType,ruralName,propertyName,ruralReference,landmarkName,landmarkDetail}={}){
  const clean=value=>normalizeText(value).replace(/\s*,\s*/g,", ");
  if(mode==="RURAL"){
    if(!clean(ruralName))return "";
    const first=[clean(ruralType)||"Vereda",clean(ruralName)].filter(Boolean).join(" ");
    return [first,clean(propertyName),clean(ruralReference)].filter(Boolean).join(", ");
  }
  if(mode==="LANDMARK")return clean(landmarkName)?[clean(landmarkName),clean(landmarkDetail)].filter(Boolean).join(", "):"";
  if(!clean(mainRoad))return "";
  const principal=[clean(roadType)||"Calle",clean(mainRoad)].filter(Boolean).join(" ");
  const plate=[clean(crossRoad),clean(propertyNumber)].filter(Boolean).join("-");
  const nomenclature=plate?`${principal} # ${plate}`:principal;
  return [nomenclature,clean(complement),clean(neighborhood)?`Barrio ${clean(neighborhood)}`:""].filter(Boolean).join(", ");
}

export async function captureCurrentLocation(){
  const position=await getPosition({enableHighAccuracy:true,timeout:18000,maximumAge:30000});
  const {latitude,longitude,altitude,accuracy,altitudeAccuracy}=position.coords;
  return {
    latitude:Number(latitude),longitude:Number(longitude),
    altitude:Number.isFinite(altitude)?Number(altitude):null,
    accuracy:Number.isFinite(accuracy)?Number(accuracy):null,
    altitudeAccuracy:Number.isFinite(altitudeAccuracy)?Number(altitudeAccuracy):null,
    capturedAt:new Date(position.timestamp||Date.now()).toISOString()
  };
}

export async function reverseGeocode(latitude,longitude){
  const lat=Number(latitude),lon=Number(longitude);
  if(!Number.isFinite(lat)||!Number.isFinite(lon))throw new Error("Las coordenadas no son válidas.");
  const key=`${lat.toFixed(5)},${lon.toFixed(5)}`;
  if(reverseCache.has(key))return reverseCache.get(key);
  const url=new URL(`${NOMINATIM_BASE}/reverse`);
  url.searchParams.set("format","jsonv2");
  url.searchParams.set("lat",String(lat));
  url.searchParams.set("lon",String(lon));
  url.searchParams.set("zoom","18");
  url.searchParams.set("addressdetails","1");
  url.searchParams.set("accept-language","es");
  const result=addressParts(await nominatimJson(url));
  reverseCache.set(key,result);
  return result;
}

export async function elevationFor(latitude,longitude){
  const lat=Number(latitude),lon=Number(longitude);
  if(!Number.isFinite(lat)||!Number.isFinite(lon))return null;
  const key=`${lat.toFixed(4)},${lon.toFixed(4)}`;
  if(elevationCache.has(key))return elevationCache.get(key);
  try{
    const url=new URL("https://api.open-meteo.com/v1/forecast");
    url.searchParams.set("latitude",String(lat));
    url.searchParams.set("longitude",String(lon));
    url.searchParams.set("current","temperature_2m");
    url.searchParams.set("forecast_days","1");
    const response=await fetch(url,{headers:{Accept:"application/json"}});
    if(!response.ok)throw new Error("elevation unavailable");
    const data=await response.json();
    const value=Number(data.elevation);
    const elevation=Number.isFinite(value)?value:null;
    elevationCache.set(key,elevation);
    return elevation;
  }catch{return null;}
}

/** Busca una dirección colombiana ya validada contra departamento y municipio. */
export async function geocodeAddress({department,municipality,address,country="Colombia",limit=5,mode="URBAN"}={}){
  const state=normalizeText(department),city=normalizeText(municipality),street=normalizeText(address),searchMode=String(mode||"URBAN").toUpperCase();
  if(!state)throw new Error("Selecciona el departamento.");
  if(!city)throw new Error("Selecciona el municipio o ciudad.");
  if(!street)throw new Error("Completa la dirección o el lugar que deseas ubicar.");
  const safeLimit=Math.max(1,Math.min(Number(limit)||5,5));
  const key=[searchMode,street,city,state,country].join("|").toLocaleLowerCase("es");
  if(searchCache.has(key))return searchCache.get(key);

  let rows=[];
  if(searchMode==="URBAN"){
    const structured=new URL(`${NOMINATIM_BASE}/search`);
    structured.searchParams.set("format","jsonv2");
    structured.searchParams.set("street",street);
    structured.searchParams.set("city",city);
    structured.searchParams.set("state",state);
    structured.searchParams.set("country",country);
    structured.searchParams.set("countrycodes","co");
    structured.searchParams.set("limit",String(safeLimit));
    structured.searchParams.set("addressdetails","1");
    structured.searchParams.set("accept-language","es");
    rows=await nominatimJson(structured);
  }
  if(!Array.isArray(rows)||!rows.length){
    const fallback=new URL(`${NOMINATIM_BASE}/search`);
    fallback.searchParams.set("format","jsonv2");
    fallback.searchParams.set("q",`${street}, ${city}, ${state}, ${country}`);
    fallback.searchParams.set("countrycodes","co");
    fallback.searchParams.set("limit",String(safeLimit));
    fallback.searchParams.set("addressdetails","1");
    fallback.searchParams.set("accept-language","es");
    rows=await nominatimJson(fallback);
  }
  if(!Array.isArray(rows)||!rows.length)throw new Error("No encontramos una coincidencia exacta. El mapa se centrará en el municipio para que marques el punto manualmente.");

  const results=rows.map(resultFromRow).filter(row=>Number.isFinite(row.latitude)&&Number.isFinite(row.longitude));
  await Promise.all(results.slice(0,1).map(async row=>{row.altitude=await elevationFor(row.latitude,row.longitude)}));
  searchCache.set(key,results);
  return results;
}

export async function geocodePlace(query){
  const text=normalizeText(query);
  if(text.length<4)throw new Error("Escribe un lugar, municipio o dirección más específica.");
  const key=`free|${text.toLocaleLowerCase("es")}`;
  if(searchCache.has(key))return searchCache.get(key)[0];
  const url=new URL(`${NOMINATIM_BASE}/search`);
  url.searchParams.set("format","jsonv2");
  url.searchParams.set("q",text);
  url.searchParams.set("countrycodes","co");
  url.searchParams.set("limit","1");
  url.searchParams.set("addressdetails","1");
  url.searchParams.set("accept-language","es");
  const rows=await nominatimJson(url);
  if(!rows.length)throw new Error("No encontramos ese lugar. Agrega municipio, departamento o una dirección más completa.");
  const result=resultFromRow(rows[0]);
  result.altitude=await elevationFor(result.latitude,result.longitude);
  searchCache.set(key,[result]);
  return result;
}

export async function locateCurrentPlace(){
  const coordinates=await captureCurrentLocation();
  if(coordinates.altitude==null)coordinates.altitude=await elevationFor(coordinates.latitude,coordinates.longitude);
  try{return {...coordinates,...await reverseGeocode(coordinates.latitude,coordinates.longitude)};}
  catch(error){return {...coordinates,address:"",municipality:"",department:"",country:"",postalCode:"",source:"GPS del dispositivo",geocodingWarning:error.message};}
}

async function loadLeaflet(){
  if(window.L?.map)return window.L;
  if(leafletPromise)return leafletPromise;
  leafletPromise=new Promise((resolve,reject)=>{
    if(!document.querySelector('link[data-erp-leaflet]')){
      const link=document.createElement("link");
      link.rel="stylesheet";link.href=LEAFLET_CSS;link.dataset.erpLeaflet="true";
      document.head.append(link);
    }
    const existing=document.querySelector('script[data-erp-leaflet]');
    if(existing){existing.addEventListener("load",()=>resolve(window.L),{once:true});existing.addEventListener("error",()=>reject(new Error("No fue posible cargar el mapa.")),{once:true});return;}
    const script=document.createElement("script");
    script.src=LEAFLET_JS;script.async=true;script.dataset.erpLeaflet="true";
    script.onload=()=>window.L?.map?resolve(window.L):reject(new Error("No fue posible iniciar el mapa."));
    script.onerror=()=>reject(new Error("No fue posible cargar el mapa."));
    document.head.append(script);
  });
  return leafletPromise;
}

export async function createLocationMap(container,{latitude,longitude,onPointChange}={}){
  if(!container)throw new Error("No existe el contenedor del mapa.");
  const L=await loadLeaflet();
  const initialLat=finite(latitude),initialLon=finite(longitude),hasInitial=initialLat!=null&&initialLon!=null;
  const map=L.map(container,{zoomControl:true,attributionControl:true,scrollWheelZoom:true});
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png",{
    maxZoom:19,
    attribution:'&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>'
  }).addTo(map);
  map.setView(hasInitial?[initialLat,initialLon]:DEFAULT_CENTER,hasInitial?17:5);

  let marker=null;
  const notify=(latlng,reason)=>onPointChange?.({latitude:Number(latlng.lat),longitude:Number(latlng.lng),reason});
  const setView=(lat,lon,zoom=13)=>{
    const parsedLat=finite(lat),parsedLon=finite(lon);
    if(parsedLat==null||parsedLon==null)return;
    map.setView(L.latLng(parsedLat,parsedLon),zoom,{animate:true});
  };
  const setPoint=(lat,lon,{zoom=17,notifyChange=false,reason="PROGRAMMATIC"}={})=>{
    const parsedLat=finite(lat),parsedLon=finite(lon);
    if(parsedLat==null||parsedLon==null)return;
    const latlng=L.latLng(parsedLat,parsedLon);
    if(!marker){
      marker=L.marker(latlng,{draggable:true,autoPan:true}).addTo(map);
      marker.on("dragend",()=>notify(marker.getLatLng(),"MARKER_DRAG"));
    }else marker.setLatLng(latlng);
    map.setView(latlng,zoom,{animate:true});
    if(notifyChange)notify(latlng,reason);
  };

  map.on("click",event=>setPoint(event.latlng.lat,event.latlng.lng,{zoom:Math.max(map.getZoom(),16),notifyChange:true,reason:"MAP_CLICK"}));
  if(hasInitial)setPoint(initialLat,initialLon,{zoom:17});
  setTimeout(()=>map.invalidateSize(),80);

  return {
    map,
    setView,
    setPoint,
    invalidate:()=>map.invalidateSize(),
    destroy:()=>{if(map){map.remove();marker=null;}}
  };
}
