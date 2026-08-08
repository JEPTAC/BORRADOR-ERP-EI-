const municipalityCache=new Map();
const DIVIPOLA_BASE="https://www.datos.gov.co/resource/gdxc-w37w.json";

const DEPARTMENTS=Object.freeze([
  ["05","Antioquia"],["08","Atlántico"],["11","Bogotá, D.C."],["13","Bolívar"],["15","Boyacá"],["17","Caldas"],["18","Caquetá"],["19","Cauca"],["20","Cesar"],["23","Córdoba"],["25","Cundinamarca"],["27","Chocó"],["41","Huila"],["44","La Guajira"],["47","Magdalena"],["50","Meta"],["52","Nariño"],["54","Norte de Santander"],["63","Quindío"],["66","Risaralda"],["68","Santander"],["70","Sucre"],["73","Tolima"],["76","Valle del Cauca"],["81","Arauca"],["85","Casanare"],["86","Putumayo"],["88","Archipiélago de San Andrés, Providencia y Santa Catalina"],["91","Amazonas"],["94","Guainía"],["95","Guaviare"],["97","Vaupés"],["99","Vichada"]
].map(([code,name])=>({code,name})));

function normalizeText(value){return String(value||"").trim().replace(/\s+/g," ")}
function finite(value){const parsed=Number(String(value??"").replace(",","."));return Number.isFinite(parsed)?parsed:null}
function titlePlace(value){
  const lowerWords=new Set(["de","del","la","las","los","y","e"]);
  return normalizeText(value).toLocaleLowerCase("es-CO").split(/(\s+|-)/).map((part,index)=>{
    if(/^\s+$|-$/.test(part))return part;
    if(/^d\.?c\.?$/i.test(part))return "D.C.";
    if(index>0&&lowerWords.has(part))return part;
    return part.charAt(0).toLocaleUpperCase("es-CO")+part.slice(1);
  }).join("").replace(/Bogotá, D\.c\./i,"Bogotá, D.C.");
}

export function colombianDepartments(){return DEPARTMENTS.map(item=>({...item}))}

export async function colombianMunicipalities(departmentCode){
  const code=String(departmentCode||"").replace(/\D/g,"").padStart(2,"0").slice(-2);
  if(!DEPARTMENTS.some(item=>item.code===code))throw new Error("Selecciona un departamento válido.");
  if(municipalityCache.has(code))return municipalityCache.get(code).map(item=>({...item}));

  const storageKey=`erp_divipola_${code}_2026`;
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
  const response=await fetch(url,{headers:{Accept:"application/json"}});
  if(!response.ok)throw new Error("No fue posible cargar la lista oficial de municipios.");
  const rows=await response.json();
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
