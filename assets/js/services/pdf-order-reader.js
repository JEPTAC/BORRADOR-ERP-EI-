const PDF_JS_VERSION="3.11.174";
const PDF_JS_URL=`https://cdnjs.cloudflare.com/ajax/libs/pdf.js/${PDF_JS_VERSION}/pdf.min.js`;
const PDF_WORKER_URL=`https://cdnjs.cloudflare.com/ajax/libs/pdf.js/${PDF_JS_VERSION}/pdf.worker.min.js`;

let loaderPromise=null;

export async function ensurePdfReader(){
  if(window.pdfjsLib){
    configureWorker();
    return window.pdfjsLib;
  }
  if(loaderPromise)return loaderPromise;
  loaderPromise=new Promise((resolve,reject)=>{
    const existing=document.querySelector('script[data-erp-pdfjs]');
    if(existing){
      existing.addEventListener("load",()=>{configureWorker();resolve(window.pdfjsLib)}, {once:true});
      existing.addEventListener("error",()=>reject(new Error("No fue posible cargar el lector PDF.")), {once:true});
      return;
    }
    const script=document.createElement("script");
    script.src=PDF_JS_URL;
    script.defer=true;
    script.dataset.erpPdfjs="true";
    script.onload=()=>{configureWorker();resolve(window.pdfjsLib)};
    script.onerror=()=>reject(new Error("No fue posible cargar el lector PDF. Revisa la conexión e inténtalo nuevamente."));
    document.head.append(script);
  });
  return loaderPromise;
}

function configureWorker(){
  if(window.pdfjsLib?.GlobalWorkerOptions)window.pdfjsLib.GlobalWorkerOptions.workerSrc=PDF_WORKER_URL;
}

export async function readOrderPdf(fileOrBuffer){
  const pdfjs=await ensurePdfReader();
  const buffer=await toArrayBuffer(fileOrBuffer);
  const pdf=await pdfjs.getDocument({data:buffer}).promise;
  const pageTexts=[];
  for(let pageNumber=1;pageNumber<=pdf.numPages;pageNumber++){
    const page=await pdf.getPage(pageNumber);
    const content=await page.getTextContent();
    pageTexts.push(extractPageText(content.items||[]));
  }
  const raw=pageTexts.join("\n");
  return parseOrderText(raw);
}

async function toArrayBuffer(value){
  if(value instanceof ArrayBuffer)return value;
  if(ArrayBuffer.isView(value))return value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength);
  if(value instanceof Blob)return value.arrayBuffer();
  throw new Error("El archivo recibido no es un PDF válido.");
}

function extractPageText(items){
  if(!items.length)return "";
  const rows=new Map();
  for(const item of items){
    const text=cleanText(item.str);
    if(!text)continue;
    const y=Math.round(Number(item.transform?.[5]||0)*2)/2;
    const x=Number(item.transform?.[4]||0);
    if(!rows.has(y))rows.set(y,[]);
    rows.get(y).push({x,text});
  }
  return [...rows.entries()]
    .sort((a,b)=>b[0]-a[0])
    .map(([,parts])=>parts.sort((a,b)=>a.x-b.x).map(part=>part.text).join(" ").replace(/\s+/g," ").trim())
    .filter(Boolean)
    .join("\n");
}

export function parseOrderText(text){
  const raw=String(text||"").replace(/\r/g,"\n");
  const lines=raw.split(/\n+/).map(cleanText).filter(Boolean);
  const orderMatch=raw.match(/No\.\s*([A-Z0-9\-]+)/i)||raw.match(/(?:PEDIDO|PVN|PVC|PVE|PVP)[^\n]*?([0-9]{3,}[-A-Z0-9]*)/i);
  const dateMatch=raw.match(/\b(\d{2}\/\d{2}\/\d{4})\b/);
  const client=detectClient(lines);
  const items=[];

  for(let index=0;index<lines.length;index++){
    const current=sanitizeLine(lines[index]);
    const candidates=[current];
    if(lines[index+1])candidates.push(sanitizeLine(`${current} ${lines[index+1]}`));
    if(lines[index+1]&&lines[index+2])candidates.push(sanitizeLine(`${current} ${lines[index+1]} ${lines[index+2]}`));
    let parsed=null;
    let consumed=0;
    for(let candidateIndex=0;candidateIndex<candidates.length;candidateIndex++){
      parsed=parseItemLine(candidates[candidateIndex]);
      if(parsed){consumed=candidateIndex;break}
    }
    if(!parsed)continue;
    if(items.some(item=>sameDetectedItem(item,parsed)))continue;
    parsed.sourceLine=index+1;
    items.push(parsed);
    index+=consumed;
  }

  return {
    orderNumber:orderMatch?.[1]||"",
    date:dateMatch?.[1]||"",
    client,
    items,
    raw,
    pages:Math.max(1,(raw.match(/\f/g)||[]).length+1),
    readerVersion:`pedido-pdf-${PDF_JS_VERSION}`
  };
}

function parseItemLine(line){
  const units="M|MT|MTS|ML|METRO|METROS|UND|UN|UNIDAD|UNIDADES|KG|KGS|ROLLO|ROLLOS|CJ|CAJA|JGO|JUEGO|PAR|PZA|PZAS";
  const expressions=[
    new RegExp(`^(?:\\d{1,3}\\s+)?([A-Z0-9][A-Z0-9.\\-_/]{3,})\\s+(.+?)\\s+(\\d+(?:[\\.,]\\d+)?)\\s+(${units})\\b`,`i`),
    new RegExp(`^(?:L[IÍ]NEA\\s+)?\\d{1,3}\\s+([A-Z0-9][A-Z0-9.\\-_/]{3,})\\s+(.+?)\\s+(${units})\\s+(\\d+(?:[\\.,]\\d+)?)\\b`,`i`)
  ];

  let match=line.match(expressions[0]);
  let unitIndex=4;
  let qtyIndex=3;
  if(!match){
    match=line.match(expressions[1]);
    unitIndex=3;
    qtyIndex=4;
  }
  if(!match)return null;

  const reference=cleanText(match[1]);
  const description=cleanText(match[2]).replace(/\s{2,}/g," ");
  const quantity=normalizeDecimal(match[qtyIndex]);
  const unit=normalizeUnit(match[unitIndex]);
  if(!reference||!/\d/.test(reference)||!description||!Number.isFinite(quantity)||quantity<=0)return null;

  const explicitCut=/\b(CORTE|CORTAR|TRAMO|TRAMOS|LONGITUD|MEDIDA|CHIPA|CARRETE)\b/i.test(line);
  const metric=isMeterUnit(unit);
  const requiresCut=explicitCut||metric;
  const cutLength=detectCutLength(line,quantity,requiresCut);

  return {
    sku:reference,
    reference,
    description,
    quantity,
    unit,
    warehouseLocation:"",
    requiresCut,
    requestedCutLength:requiresCut?cutLength:null,
    readerConfidence:explicitCut?"HIGH":metric?"MEDIUM":"LOW"
  };
}

function detectClient(lines){
  const labels=[/^Cliente:?$/i,/^Raz[oó]n social:?$/i,/^Señor(?:es)?:?$/i,/^Nombre cliente:?$/i];
  for(let index=0;index<lines.length;index++){
    if(labels.some(label=>label.test(lines[index]))&&lines[index+1])return lines[index+1];
    const inline=lines[index].match(/^(?:Cliente|Raz[oó]n social|Señor(?:es)?):\s*(.+)$/i);
    if(inline?.[1])return cleanText(inline[1]);
  }
  const phoneIndex=lines.findIndex(line=>/^Tel[eé]fono:?$/i.test(line));
  return phoneIndex>=0&&lines[phoneIndex+1]?lines[phoneIndex+1]:"";
}

function detectCutLength(line,quantity,requiresCut){
  if(!requiresCut)return null;
  const explicit=line.match(/(?:CORTE|LONGITUD|MEDIDA|TRAMO)\s*[:=\-]?\s*(\d+(?:[\.,]\d+)?)\s*(?:M|MT|MTS|METROS?)\b/i);
  const value=explicit?normalizeDecimal(explicit[1]):quantity;
  return Number.isFinite(value)&&value>0?value:null;
}

function sanitizeLine(value){
  return cleanText(value)
    .replace(/\$\s?[\d\.,]+/g," ")
    .replace(/\b(?:IVA|TOTAL|SUBTOTAL|VALOR UNITARIO|VALOR TOTAL)\b.*$/i," ")
    .replace(/\s+/g," ")
    .trim();
}

function sameDetectedItem(a,b){
  return String(a.reference).toUpperCase()===String(b.reference).toUpperCase()
    && Number(a.quantity)===Number(b.quantity)
    && String(a.unit).toUpperCase()===String(b.unit).toUpperCase();
}

export function isMeterUnit(unit){
  return ["M","MT","MTS","ML","METRO","METROS"].includes(String(unit||"").toUpperCase());
}

function normalizeUnit(unit){
  const value=String(unit||"UND").toUpperCase();
  if(["UN","UNIDAD","UNIDADES"].includes(value))return "UND";
  if(["MT","MTS","ML","METRO","METROS"].includes(value))return "M";
  if(["KGS"].includes(value))return "KG";
  if(["ROLLOS"].includes(value))return "ROLLO";
  return value;
}

function normalizeDecimal(value){
  const text=String(value||"").trim();
  if(!text)return NaN;
  if(text.includes(",")&&text.includes(".")){
    return Number(text.lastIndexOf(",")>text.lastIndexOf(".")?text.replaceAll(".","").replace(",","."):text.replaceAll(",",""));
  }
  return Number(text.replace(",","."));
}

function cleanText(value){
  return String(value||"").replace(/\u00a0/g," ").replace(/\s+/g," ").trim();
}
