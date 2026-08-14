import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {loading,empty,wizard,toast,actionCards,guide,modal,closeDialog} from "../core/ui.js";
import {state,hasRole} from "../core/state.js";
import {workspaceIntro} from "../core/guided.js";

let directoryCache=null;

export async function renderAdmin(root){
  const superAdmin=hasRole("super_admin");
  const cards=superAdmin?[
    {id:"new-user",title:"Crear usuario",description:"Crea la cuenta de acceso, contraseña inicial y perfil ERP.",icon:"＋",tone:"accent"},
    {id:"manage-users",title:"Usuarios, accesos y roles",description:"Administra perfiles, roles, estado, contraseña y eliminación de acceso.",icon:"♟",tone:"primary"},
    {id:"calendar-view",title:"Calendario laboral",description:"Consulta jornada semanal y festivos configurados.",icon:"▣",tone:"warning"},
    {id:"health-view",title:"Revisar sistema",description:"Ejecuta controles de estructura, permisos y funcionamiento.",icon:"✓"}
  ]:[
    {id:"calendar-view",title:"Calendario laboral",description:"Consulta jornada semanal y festivos configurados.",icon:"▣",tone:"warning"},
    {id:"health-view",title:"Revisar sistema",description:"Ejecuta controles de estructura, permisos y funcionamiento.",icon:"✓"}
  ];

  root.innerHTML=`
    <section class="page-head"><div><h2>${superAdmin?"Consola Super Admin":"Administración del ERP"}</h2><p>${superAdmin?"Control central de cuentas, perfiles, roles y seguridad de acceso del ERP.":"Consulta calendario y controles del sistema según tus permisos."}</p></div><div class="page-actions"><button class="btn btn-ghost" id="admin-help">Ver guía</button></div></section>
    ${superAdmin?`<section class="admin-security-banner"><div><span class="admin-security-icon">◆</span><div><strong>Privilegios de Super Admin activos</strong><p>Las operaciones de Supabase Auth se ejecutan en servidor. La clave administrativa nunca se expone en el navegador y cada cambio queda auditado.</p></div></div><span class="badge badge-green"><span class="badge-dot"></span>Acceso total</span></section>`:""}
    ${workspaceIntro({title:superAdmin?"Centro de administración":"Herramientas administrativas",description:superAdmin?"Gestiona accesos reales de Supabase Auth y perfiles operativos desde un único lugar.":"Solo se muestran las acciones disponibles para tu rol.",cards:actionCards(cards)})}
    <section class="card"><div class="card-body" id="admin-panel">${loading()}</div></section>`;

  const show=async view=>{
    const panel=root.querySelector("#admin-panel");
    panel.innerHTML=loading();
    if(view==="users")await users(panel);
    if(view==="calendar")await calendar(panel);
    if(view==="health")await health(panel);
  };

  root.querySelector("#new-user")?.addEventListener("click",async()=>{
    const data=directoryCache||await api.adminDirectory();
    directoryCache=data;
    userWizard({roles:data.roles||[],reload:()=>show("users")});
  });
  root.querySelector("#manage-users")?.addEventListener("click",()=>show("users"));
  root.querySelector("#calendar-view")?.addEventListener("click",()=>show("calendar"));
  root.querySelector("#health-view")?.addEventListener("click",()=>show("health"));
  root.querySelector("#admin-help").onclick=()=>guide({
    title:superAdmin?"Administración de cuentas y perfiles":"Administración segura",
    description:superAdmin?"La consola separa la identidad de acceso de Supabase Auth y el perfil operativo del ERP para proteger la trazabilidad.":"Los controles administrativos disponibles dependen de tu rol.",
    items:superAdmin?[
      {title:"Crear usuario",detail:"Crea la cuenta Auth, confirma el correo, registra la contraseña inicial y asigna roles ERP."},
      {title:"Editar perfil y roles",detail:"Modifica nombre, correo, código, estado y todos los roles disponibles, incluido Líder logístico."},
      {title:"Cambiar contraseña",detail:"Define una nueva contraseña sin conocer ni exponer la contraseña anterior."},
      {title:"Eliminar usuario",detail:"Elimina la identidad de acceso y desactiva el perfil, pero conserva el perfil histórico para no romper pedidos, inventario, corte ni auditoría."},
      {title:"Protección del Super Admin",detail:"El sistema impide eliminar tu propia cuenta o retirar el último Super Admin activo."}
    ]:[
      {title:"Calendario",detail:"Consulta la jornada y festivos usados por el motor de tiempos."},
      {title:"Salud del sistema",detail:"Revisa los controles de estructura disponibles para tu rol."}
    ]
  });

  await show(superAdmin?"users":"calendar");
}

async function users(panel){
  if(!hasRole("super_admin"))throw new Error("Solo Super Admin puede administrar cuentas de usuario.");
  const data=await api.adminDirectory();
  directoryCache=data;
  const rows=data.users||[];
  const roles=data.roles||[];
  const activeCount=rows.filter(u=>u.active).length;
  const disabledCount=rows.filter(u=>!u.active).length;
  const noAccess=rows.filter(u=>!u.authLinked).length;
  panel.innerHTML=`
    <section class="admin-directory-head">
      <div><span class="eyebrow">Directorio de seguridad</span><h3>Usuarios, accesos y roles</h3><p>Gestiona tanto la cuenta real de Supabase Auth como el perfil operativo del ERP.</p></div>
      <button class="btn btn-primary" id="directory-new-user">＋ Crear usuario</button>
    </section>
    <div class="summary-grid admin-summary-grid">
      <div class="summary-box"><span class="muted">Perfiles</span><strong>${rows.length}</strong></div>
      <div class="summary-box"><span class="muted">Activos</span><strong class="success">${activeCount}</strong></div>
      <div class="summary-box"><span class="muted">Inactivos</span><strong>${disabledCount}</strong></div>
      <div class="summary-box"><span class="muted">Sin cuenta Auth</span><strong class="${noAccess?"danger":"success"}">${noAccess}</strong></div>
    </div>
    <div class="admin-directory-toolbar">
      <label class="field admin-search-field"><span>Buscar usuario</span><input class="control" id="admin-user-search" placeholder="Nombre, correo o código…"></label>
      <label class="field"><span>Estado</span><select class="control" id="admin-user-status"><option value="ALL">Todos</option><option value="ACTIVE">Activos</option><option value="INACTIVE">Inactivos</option><option value="NO_AUTH">Sin acceso Auth</option></select></label>
      <label class="field"><span>Rol</span><select class="control" id="admin-user-role"><option value="ALL">Todos los roles</option>${roles.map(role=>`<option value="${fmt.escape(role.code)}">${fmt.escape(role.name||fmt.role(role.code))}</option>`).join("")}</select></label>
    </div>
    <div id="admin-user-results"></div>`;

  const results=panel.querySelector("#admin-user-results");
  const search=panel.querySelector("#admin-user-search");
  const status=panel.querySelector("#admin-user-status");
  const role=panel.querySelector("#admin-user-role");
  const byKey=new Map(rows.map(user=>[userKey(user),user]));

  const render=()=>{
    const q=String(search.value||"").trim().toLowerCase();
    const s=status.value;
    const r=role.value;
    const filtered=rows.filter(user=>{
      const matchesSearch=!q||[user.name,user.email,user.employeeCode].some(value=>String(value||"").toLowerCase().includes(q));
      const matchesStatus=s==="ALL"||(s==="ACTIVE"&&user.active)||(s==="INACTIVE"&&!user.active)||(s==="NO_AUTH"&&!user.authLinked);
      const matchesRole=r==="ALL"||(user.roles||[]).includes(r);
      return matchesSearch&&matchesStatus&&matchesRole;
    });
    results.innerHTML=filtered.length?`<div class="user-grid admin-user-grid">${filtered.map(user=>userCard(user,roles)).join("")}</div>`:empty("Sin coincidencias","No hay usuarios que cumplan los filtros seleccionados.");
    results.querySelectorAll("[data-admin-user]").forEach(button=>button.onclick=()=>{
      const user=byKey.get(button.dataset.adminUser);
      if(user)userDetail({user,roles,reload:()=>users(panel)});
    });
  };
  [search,status,role].forEach(control=>control.addEventListener(control.tagName==="INPUT"?"input":"change",render));
  panel.querySelector("#directory-new-user").onclick=()=>userWizard({roles,reload:()=>users(panel)});
  render();
}

function userKey(user){return user.id||`auth:${user.authUserId}`}

function userCard(user,roles){
  const roleLabels=(user.roles||[]).map(code=>roles.find(role=>role.code===code)?.name||fmt.role(code));
  const accessText=user.authLinked?(user.authConfirmed?"Auth confirmada":"Auth sin confirmar"):"Sin cuenta Auth";
  return `<article class="user-card admin-user-card ${user.isCurrentUser?"current-admin":""}">
    <header><div class="avatar">${fmt.initials(user.name)}</div><div class="admin-user-identity"><strong>${fmt.escape(user.name||"Sin nombre")}</strong><span>${fmt.escape(user.email||"Sin correo")}</span></div>${statusBadge(user.active?"ACTIVE":"INACTIVE")}</header>
    <div class="user-card-body">
      <div class="admin-account-state ${user.authLinked?"linked":"unlinked"}"><span>${user.authLinked?"✓":"!"}</span><div><strong>${fmt.escape(accessText)}</strong><small>${user.authLinked?"Identidad de acceso vinculada al perfil ERP.":"El perfil histórico se conserva, pero no puede iniciar sesión."}</small></div></div>
      <div class="user-roles">${roleLabels.map(label=>`<span class="badge badge-blue"><span class="badge-dot"></span>${fmt.escape(label)}</span>`).join(" ")||'<span class="muted">Sin roles asignados</span>'}</div>
      <div class="user-meta"><span>Código: <strong>${fmt.escape(user.employeeCode||"No registrado")}</strong></span><span>Último ingreso: <strong>${fmt.escape(user.lastSignInAt?fmt.date(user.lastSignInAt):"Nunca")}</strong></span>${user.isCurrentUser?'<span>Cuenta actual: <strong class="success">Tu sesión</strong></span>':""}</div>
    </div>
    <footer><button class="btn btn-primary" data-admin-user="${fmt.escape(userKey(user))}">Administrar perfil</button></footer>
  </article>`;
}

function userDetail({user,roles,reload}){
  if(user.profileMissing){
    const dialog=modal({title:"Cuenta Auth sin perfil ERP",confirmLabel:"",cancelLabel:"Cerrar",size:"wide",body:`<div class="wizard-tip">La cuenta <strong>${fmt.escape(user.email)}</strong> existe en Supabase Auth pero todavía no tiene perfil operativo. Usa Sincronizar cuentas para crear el perfil inactivo y luego asígnale roles.</div><div class="modal-action-grid"><button class="btn btn-primary" id="orphan-sync">Sincronizar cuenta</button></div>`});
    dialog.root.querySelector("#orphan-sync").onclick=async()=>{await api.syncAuth();closeDialog();toast("Cuenta sincronizada con perfiles ERP.");await reload()};
    return;
  }
  const roleLabels=(user.roles||[]).map(code=>roles.find(role=>role.code===code)?.name||fmt.role(code));
  const dialog=modal({title:user.name||"Perfil de usuario",confirmLabel:"",cancelLabel:"Cerrar",size:"wide",body:`
    <section class="admin-profile-sheet">
      <div class="admin-profile-main"><div class="avatar avatar-lg">${fmt.initials(user.name)}</div><div><span class="eyebrow">Perfil operativo</span><h3>${fmt.escape(user.name)}</h3><p>${fmt.escape(user.email)}</p></div>${statusBadge(user.active?"ACTIVE":"INACTIVE")}</div>
      <div class="detail-grid admin-profile-details">
        <div><label>Código</label><strong>${fmt.escape(user.employeeCode||"No registrado")}</strong></div>
        <div><label>Cuenta Supabase Auth</label><strong>${user.authLinked?"Vinculada":"Sin acceso"}</strong></div>
        <div><label>Correo confirmado</label><strong>${user.authConfirmed?"Sí":"No"}</strong></div>
        <div><label>Último ingreso</label><strong>${fmt.escape(user.lastSignInAt?fmt.date(user.lastSignInAt):"Nunca")}</strong></div>
      </div>
      <div class="admin-profile-role-list"><label>Roles asignados</label><div class="user-roles">${roleLabels.map(label=>`<span class="badge badge-blue"><span class="badge-dot"></span>${fmt.escape(label)}</span>`).join(" ")||'<span class="muted">Sin roles</span>'}</div></div>
      <div class="admin-profile-actions">
        <button class="admin-command" id="profile-edit"><span>01</span><div><strong>Editar datos y roles</strong><small>Nombre, correo, código, estado y permisos.</small></div></button>
        ${user.authLinked?`<button class="admin-command" id="profile-password"><span>02</span><div><strong>Cambiar contraseña</strong><small>Define una contraseña nueva desde Super Admin.</small></div></button>`:`<button class="admin-command" id="profile-provision"><span>02</span><div><strong>Crear cuenta de acceso</strong><small>Vuelve a habilitar una identidad Auth para este perfil histórico.</small></div></button>`}
        <button class="admin-command" id="profile-toggle"><span>03</span><div><strong>${user.active?"Desactivar usuario":"Activar usuario"}</strong><small>${user.active?"Bloquea Auth y el perfil ERP sin borrar trazabilidad.":"Habilita nuevamente Auth y el perfil ERP."}</small></div></button>
        <button class="admin-command danger ${user.isCurrentUser?"disabled":""}" id="profile-delete" ${user.isCurrentUser?"disabled":""}><span>04</span><div><strong>Eliminar usuario</strong><small>Elimina la cuenta Auth y conserva el perfil histórico desactivado.</small></div></button>
      </div>
      ${user.isCurrentUser?'<div class="wizard-tip">Por seguridad no puedes eliminar tu propia cuenta desde la sesión actual. El sistema tampoco permite retirar el último Super Admin activo.</div>':""}
    </section>`});
  dialog.root.querySelector("#profile-edit").onclick=()=>{closeDialog();userWizard({user,roles,reload})};
  dialog.root.querySelector("#profile-password")?.addEventListener("click",()=>{closeDialog();passwordDialog({user,reload})});
  dialog.root.querySelector("#profile-provision")?.addEventListener("click",()=>{closeDialog();userWizard({user:{...user,active:true},roles,reload,provision:true})});
  dialog.root.querySelector("#profile-toggle").onclick=()=>{closeDialog();toggleDialog({user,reload})};
  dialog.root.querySelector("#profile-delete")?.addEventListener("click",()=>{closeDialog();deleteDialog({user,reload})});
}

function userWizard({user=null,roles=[],reload,provision=false}){
  const editing=Boolean(user?.id&&!provision);
  const creatingAccess=!editing;
  const selected=new Set(user?.roles||[]);
  const identityStep=`<input type="hidden" name="id" value="${fmt.escape(user?.id||"")}"><div class="form-grid"><div class="field"><label>Nombre completo *</label><input class="control" name="name" value="${fmt.escape(user?.name||"")}" required></div><div class="field"><label>Correo corporativo *</label><input class="control" name="email" type="email" value="${fmt.escape(user?.email||"")}" required></div><div class="field"><label>Código del empleado</label><input class="control" name="employeeCode" value="${fmt.escape(user?.employeeCode||"")}"></div><div class="field"><label>Cuenta de acceso</label><input class="control" value="${creatingAccess?"Se creará automáticamente en Supabase Auth":user?.authLinked?"Vinculada a Supabase Auth":"Perfil sin cuenta de acceso"}" disabled></div></div>`;
  const passwordStep=creatingAccess?{title:"Contraseña inicial",description:"Define la contraseña con la que la persona ingresará por primera vez.",content:`<div class="form-grid"><div class="field"><label>Contraseña *</label><input class="control" name="password" type="password" minlength="8" autocomplete="new-password" required></div><div class="field"><label>Confirmar contraseña *</label><input class="control" name="passwordConfirm" type="password" minlength="8" autocomplete="new-password" required></div></div><div class="wizard-tip">La contraseña nunca se almacena en el perfil ERP ni se muestra después. Solo Supabase Auth conserva su hash seguro.</div>`,validate:({data})=>{if(data.password!==data.passwordConfirm)throw new Error("Las contraseñas no coinciden.");return true}}:null;
  const steps=[
    {title:"Identidad",description:creatingAccess?"Crea o reutiliza el perfil operativo y su identidad de acceso.":"Actualiza la información visible del perfil.",content:identityStep},
    ...(passwordStep?[passwordStep]:[]),
    {title:"Roles y permisos",description:"El catálogo se carga directamente de la base. Los roles futuros aparecerán automáticamente.",content:`<div class="role-choice-grid">${roles.map(role=>`<label class="role-choice"><input type="checkbox" name="role" value="${fmt.escape(role.code)}" ${selected.has(role.code)?"checked":""}><span><strong>${fmt.escape(role.name||fmt.role(role.code))}</strong><small>${fmt.escape(role.description||"Permiso operativo del ERP.")}</small></span></label>`).join("")}</div>`,validate:({form})=>{const active=form.querySelector('[name="active"]')?.checked??true;if(active&&!form.querySelectorAll('[name="role"]:checked').length)throw new Error("Selecciona al menos un rol para un usuario activo.");return true}},
    {title:"Estado",description:"Controla simultáneamente el acceso Auth y la habilitación del perfil ERP.",content:`<label class="status-choice"><input type="checkbox" name="active" ${user?.active===false?"":"checked"}><span><strong>Usuario activo</strong><small>Al desactivarlo se bloquea el acceso en Supabase Auth y el perfil deja de operar en el ERP.</small></span></label>${user?.isCurrentUser?'<div class="wizard-tip">Si eres el último Super Admin activo, el backend impedirá que te desactives o retires tu rol de Super Admin.</div>':""}`},
    {title:"Revisión",description:"Comprueba la identidad, el estado y los roles antes de confirmar.",content:`<div class="wizard-summary"><div class="wizard-summary-item"><label>Nombre</label><strong data-user-name></strong></div><div class="wizard-summary-item"><label>Correo</label><strong data-user-email></strong></div><div class="wizard-summary-item"><label>Estado</label><strong data-user-status></strong></div><div class="wizard-summary-item"><label>Roles</label><strong data-user-roles></strong></div></div>`,onEnter:({root,form,data})=>{root.querySelector("[data-user-name]").textContent=data.name||"—";root.querySelector("[data-user-email]").textContent=data.email||"—";root.querySelector("[data-user-status]").textContent=data.active?"Activo":"Inactivo";root.querySelector("[data-user-roles]").textContent=[...form.querySelectorAll('[name="role"]:checked')].map(input=>roles.find(role=>role.code===input.value)?.name||fmt.role(input.value)).join(" · ")||"Sin roles"}}
  ];

  wizard({title:editing?"Editar usuario":provision?"Crear acceso para perfil existente":"Crear usuario",subtitle:editing?"Los cambios se aplicarán al perfil ERP y, cuando corresponda, a Supabase Auth.":"La cuenta Auth y el perfil ERP se crearán como una sola operación administrativa.",finishLabel:editing?"Guardar cambios":"Crear usuario",steps,onFinish:async({form,data})=>{
    const payload={
      id:user?.id||null,
      profileId:user?.id||null,
      name:data.name,
      email:data.email,
      employeeCode:data.employeeCode||null,
      active:Boolean(data.active),
      roles:[...form.querySelectorAll('[name="role"]:checked')].map(input=>input.value),
      ...(creatingAccess?{password:data.password}:{}),
    };
    if(editing)await api.adminUpdateUser(payload);else await api.adminCreateUser(payload);
    directoryCache=null;
    toast(editing?"Usuario actualizado correctamente.":"Usuario creado y vinculado a Supabase Auth.");
    await reload();
  }});
}

function passwordDialog({user,reload}){
  modal({title:`Cambiar contraseña · ${user.name}`,confirmLabel:"Cambiar contraseña",cancelLabel:"Cancelar",body:`<div class="form-grid"><div class="field"><label>Nueva contraseña *</label><input class="control" id="admin-new-password" type="password" minlength="8" autocomplete="new-password" required></div><div class="field"><label>Confirmar contraseña *</label><input class="control" id="admin-confirm-password" type="password" minlength="8" autocomplete="new-password" required></div></div><div class="wizard-tip">No es posible ver la contraseña actual. Esta operación define una nueva contraseña directamente en Supabase Auth.${user.isCurrentUser?" Al cambiar tu propia contraseña, Supabase puede cerrar tu sesión actual y pedirte ingresar nuevamente.":""}</div>`,onConfirm:async dialog=>{
    const password=dialog.querySelector("#admin-new-password").value;
    const confirm=dialog.querySelector("#admin-confirm-password").value;
    if(password!==confirm)throw new Error("Las contraseñas no coinciden.");
    await api.adminSetPassword(user.id,password);
    toast("Contraseña actualizada correctamente.");
    await reload();
  }});
}

function toggleDialog({user,reload}){
  const activate=!user.active;
  modal({title:activate?"Activar usuario":"Desactivar usuario",confirmLabel:activate?"Activar acceso":"Desactivar acceso",cancelLabel:"Cancelar",body:`<div class="wizard-confirm-box"><strong>${activate?"¿Habilitar nuevamente este usuario?":"¿Bloquear temporalmente este usuario?"}</strong><p>${activate?"Se quitará el bloqueo de Supabase Auth y el perfil ERP quedará activo con sus roles actuales.":"La cuenta Auth será bloqueada y el perfil ERP quedará inactivo. La trazabilidad histórica se conserva."}</p></div>`,onConfirm:async()=>{
    await api.adminUpdateUser({id:user.id,name:user.name,email:user.email,employeeCode:user.employeeCode,active:activate,roles:user.roles||[]});
    directoryCache=null;
    toast(activate?"Usuario activado.":"Usuario desactivado.");
    await reload();
  }});
}

function deleteDialog({user,reload}){
  modal({title:`Eliminar usuario · ${user.name}`,confirmLabel:"Eliminar usuario",cancelLabel:"Cancelar",size:"wide",body:`<div class="admin-delete-warning"><strong>Esta acción elimina la cuenta de acceso.</strong><p>Se eliminará la identidad de Supabase Auth. El perfil ERP quedará desactivado y sin cuenta vinculada para conservar pedidos, movimientos, cortes, actividades y auditoría histórica.</p></div><div class="form-grid"><div class="field"><label>Motivo de eliminación *</label><textarea class="control" id="admin-delete-reason" rows="3" required placeholder="Ej. retiro de la empresa, cuenta duplicada, cambio de responsable…"></textarea></div><div class="field"><label>Escribe ELIMINAR para confirmar *</label><input class="control" id="admin-delete-confirm" pattern="ELIMINAR" autocomplete="off" required placeholder="ELIMINAR"></div></div>`,onConfirm:async dialog=>{
    const reason=dialog.querySelector("#admin-delete-reason").value.trim();
    if(dialog.querySelector("#admin-delete-confirm").value!=="ELIMINAR")throw new Error("Escribe ELIMINAR para confirmar la operación.");
    await api.adminDeleteUser(user.id,reason);
    directoryCache=null;
    toast("Cuenta Auth eliminada. El perfil histórico fue conservado y desactivado.");
    await reload();
  }});
}

async function calendar(panel){
  const data=await api.calendar();
  panel.innerHTML=`<div class="calendar-summary"><article class="card card-pad"><h3>Jornada semanal</h3><p class="muted">El motor calcula tiempos únicamente dentro de estos intervalos.</p><div class="table-wrap mobile-card-table"><table><thead><tr><th>Día</th><th>Hora de inicio</th><th>Hora de finalización</th></tr></thead><tbody>${data.segments.map(segment=>`<tr><td data-label="Día">${fmt.weekday(segment.iso_weekday)}</td><td data-label="Hora de inicio">${segment.start_time}</td><td data-label="Hora de finalización">${segment.end_time}</td></tr>`).join("")}</tbody></table></div></article><article class="card card-pad"><h3>Festivos configurados</h3><p class="muted">Los festivos se excluyen del tiempo laboral.</p><div class="table-wrap mobile-card-table calendar-holidays"><table><thead><tr><th>Fecha</th><th>Nombre</th><th>Origen</th></tr></thead><tbody>${data.holidays.map(holiday=>`<tr><td data-label="Fecha">${fmt.day(holiday.holiday_date)}</td><td data-label="Nombre">${fmt.escape(holiday.name)}</td><td data-label="Origen">${fmt.escape(holiday.source||"Configuración del ERP")}</td></tr>`).join("")}</tbody></table></div></article></div>`;
}

async function health(panel){
  const rows=await api.health();
  panel.innerHTML=`<div class="summary-grid"><div class="summary-box"><span class="muted">Controles</span><strong>${rows.length}</strong></div><div class="summary-box"><span class="muted">Correctos</span><strong class="success">${rows.filter(item=>item.ok).length}</strong></div><div class="summary-box"><span class="muted">Pendientes</span><strong class="danger">${rows.filter(item=>!item.ok).length}</strong></div><div class="summary-box"><span class="muted">Sistema</span><strong class="system-code">${state.organization?.code||"ERP"}</strong></div></div><div class="section-gap-small"></div><div class="health-grid">${rows.map(item=>`<article class="health-card ${item.ok?"ok":"pending"}"><header><strong>${fmt.escape(item.check_name)}</strong><span>${item.ok?"Correcto":"Revisar"}</span></header><p>${fmt.escape(item.detail)}</p><small>${fmt.escape(fmt.label(item.section))}</small></article>`).join("")}</div>`;
}
