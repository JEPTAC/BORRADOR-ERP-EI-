import {expect} from "@playwright/test";

export function requireCredentials(test){
  test.skip(!process.env.ERP_TEST_EMAIL||!process.env.ERP_TEST_PASSWORD,"Configure ERP_TEST_EMAIL y ERP_TEST_PASSWORD para el Super Admin QA.");
}
export async function login(page){
  await page.goto("/");
  await page.getByLabel("Correo corporativo").fill(process.env.ERP_TEST_EMAIL);
  await page.getByLabel("Contraseña").fill(process.env.ERP_TEST_PASSWORD);
  await page.getByRole("button",{name:"Ingresar al ERP"}).click();
  await expect(page.getByRole("heading",{name:"Centro de operación"})).toBeVisible({timeout:30000});
}
export function diagnostics(page){
  const errors=[];
  page.on("pageerror",error=>errors.push({type:"pageerror",message:error.message}));
  page.on("console",msg=>{if(msg.type()==="error")errors.push({type:"console",message:msg.text()})});
  page.on("response",response=>{
    const status=response.status(),url=response.url();
    if(status>=400&&(url.startsWith(process.env.ERP_BASE_URL||"")||/supabase\.co\/(rest|auth)\//i.test(url)))errors.push({type:"http",message:`${status} ${url}`});
  });
  return errors;
}
export async function navigateModule(page,moduleId){
  const button=page.locator(`[data-nav="${moduleId}"]`);
  if(!(await button.isVisible().catch(()=>false))){
    const menu=page.locator("#menu-toggle");if(await menu.isVisible())await menu.click();
  }
  await expect(button).toBeVisible({timeout:10000});
  await button.click();
  await expect(page.locator("#page-content")).toBeVisible();
  await page.waitForTimeout(350);
  await expect(page.locator("#page-content .module-error")).toHaveCount(0);
}
export async function assertNoHorizontalOverflow(page,tolerance=4){
  const overflow=await page.evaluate(()=>Math.max(document.documentElement.scrollWidth-window.innerWidth,document.body.scrollWidth-window.innerWidth));
  expect(overflow,`Desbordamiento horizontal de ${overflow}px`).toBeLessThanOrEqual(tolerance);
}
export async function closeModal(page){
  const modal=page.locator("#modal-root .modal");
  if(await modal.count()){await page.keyboard.press("Escape");await page.waitForTimeout(120)}
}
export const mutationRe=/(crear|guardar|enviar|aprobar|rechazar|eliminar|borrar|cancelar pedido|iniciar|finalizar|tomar|mover|ajustar|registrar|solicitar|confirmar|liberar|subir|anexar|aceptar|reprogramar|agregar actividad|vaciar|importar|sincronizar|ejecutar)/i;
export const safeRe=/(actualizar|buscar|filtr|ayuda|qué|semana|mes|mi jornada|planificación|aprobaciones|ocupación|analítica|anterior|siguiente|limpiar|restablecer|ver detalle|mostrar|ocultar|expandir|contraer)/i;
