const reverseCache=new Map();
const searchCache=new Map();
const elevationCache=new Map();

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
    municipality:String(address.city||address.town||address.village||address.municipality||address.county||"").trim(),
    department:String(address.state||address.region||"").trim(),
    country:String(address.country||"").trim(),
    postalCode:String(address.postcode||"").trim(),
    source:"OpenStreetMap Nominatim",
    placeId:data.place_id||null
  };
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
  const url=new URL("https://nominatim.openstreetmap.org/reverse");
  url.searchParams.set("format","jsonv2");
  url.searchParams.set("lat",String(lat));
  url.searchParams.set("lon",String(lon));
  url.searchParams.set("zoom","18");
  url.searchParams.set("addressdetails","1");
  url.searchParams.set("accept-language","es");
  const response=await fetch(url,{headers:{Accept:"application/json"}});
  if(!response.ok)throw new Error("Se obtuvieron las coordenadas, pero no fue posible consultar la dirección.");
  const result=addressParts(await response.json());
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

export async function geocodePlace(query){
  const text=String(query||"").trim();
  if(text.length<4)throw new Error("Escribe un lugar, municipio o dirección más específica.");
  const key=text.toLocaleLowerCase("es");
  if(searchCache.has(key))return searchCache.get(key);
  const url=new URL("https://nominatim.openstreetmap.org/search");
  url.searchParams.set("format","jsonv2");
  url.searchParams.set("q",text);
  url.searchParams.set("limit","1");
  url.searchParams.set("addressdetails","1");
  url.searchParams.set("accept-language","es");
  const response=await fetch(url,{headers:{Accept:"application/json"}});
  if(!response.ok)throw new Error("No fue posible consultar el lugar escrito.");
  const rows=await response.json();
  if(!rows.length)throw new Error("No encontramos ese lugar. Agrega municipio, departamento o una dirección más completa.");
  const row=rows[0],latitude=Number(row.lat),longitude=Number(row.lon);
  const result={...addressParts(row),latitude,longitude,altitude:await elevationFor(latitude,longitude),accuracy:null,capturedAt:new Date().toISOString(),source:"PLACE_SEARCH"};
  searchCache.set(key,result);
  return result;
}

export async function locateCurrentPlace(){
  const coordinates=await captureCurrentLocation();
  if(coordinates.altitude==null)coordinates.altitude=await elevationFor(coordinates.latitude,coordinates.longitude);
  try{return {...coordinates,...await reverseGeocode(coordinates.latitude,coordinates.longitude)};}
  catch(error){return {...coordinates,address:"",municipality:"",department:"",country:"",postalCode:"",source:"GPS del dispositivo",geocodingWarning:error.message};}
}
