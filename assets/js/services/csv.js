function splitLine(line,delimiter){
  const out=[];let value="",quoted=false;
  for(let i=0;i<line.length;i++){
    const ch=line[i];
    if(ch==='"'){if(quoted&&line[i+1]==='"'){value+='"';i++}else quoted=!quoted}
    else if(ch===delimiter&&!quoted){out.push(value.trim());value=""}
    else value+=ch;
  }
  out.push(value.trim());return out;
}
export function parseCsv(text){
  const lines=String(text).replace(/^\uFEFF/,"").split(/\r?\n/).filter(x=>x.trim());
  if(!lines.length)return [];
  const delimiter=(lines[0].match(/;/g)||[]).length>(lines[0].match(/,/g)||[]).length?";":",";
  const headers=splitLine(lines[0],delimiter).map(h=>h.trim());
  return lines.slice(1).map((line,index)=>Object.fromEntries(headers.map((h,i)=>[h,splitLine(line,delimiter)[i]??""]).concat([["__row",index+2]])));
}
export function normalizeHistoryRow(row){
  const pick=(...keys)=>{for(const k of keys){if(row[k]!==undefined&&row[k]!=="")return row[k]}return null};
  const bool=v=>["1","true","si","sí","yes","x"].includes(String(v||"").toLowerCase());
  return {
    orderNumber:pick("orderNumber","pedido","numero_pedido","número_pedido","PVE","PVC","PVN"),
    externalReference:pick("externalReference","referencia_externa","referencia"),
    orderType:String(pick("orderType","tipo_pedido","tipo")||"PVC").toUpperCase(),
    paymentCondition:String(pick("paymentCondition","condicion_pago","condición_pago")||"CREDIT").toUpperCase(),
    deliveryRoute:String(pick("deliveryRoute","ruta","modalidad_entrega")||"LOCAL_DISPATCH").toUpperCase(),
    clientName:pick("clientName","cliente","nombre_cliente")||"Cliente histórico",
    clientDocument:pick("clientDocument","nit","documento"),clientCity:pick("clientCity","ciudad"),
    status:String(pick("status","estado")||"CLOSED").toUpperCase(),priority:String(pick("priority","prioridad")||"MEDIUM").toUpperCase(),
    requiresCut:bool(pick("requiresCut","requiere_corte")),requiresPurchase:bool(pick("requiresPurchase","requiere_compra")),
    createdAt:pick("createdAt","fecha_creacion","fecha"),updatedAt:pick("updatedAt","fecha_actualizacion"),closedAt:pick("closedAt","fecha_cierre"),
    originalRow:row.__row
  };
}
export function chunk(array,size){const out=[];for(let i=0;i<array.length;i+=size)out.push(array.slice(i,i+size));return out}
