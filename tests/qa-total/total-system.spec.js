import {test,expect} from "@playwright/test";
import {requireCredentials,login,diagnostics,navigateModule,assertNoHorizontalOverflow,closeModal,mutationRe,safeRe} from "./helpers.js";

test.describe.configure({mode:"serial"});

const criticalModules=["dashboard","orders","sales","credit","cartera","caja","purchasing","receiving","picking","cutting","billing","shipping","workforce","inventory","approvals","vsm","reports","imports","sandbox","qa","audit","admin"];

test.beforeEach(async({page})=>{requireCredentials(test);await login(page)});

test("Super Admin ve y ejecuta el Robot QA total",async({page},testInfo)=>{
  const errors=diagnostics(page);
  await navigateModule(page,"qa");
  await expect(page.getByRole("heading",{name:"Robot QA total del sistema"})).toBeVisible();
  const totalButton=page.getByRole("button",{name:/Ejecutar prueba total/});
  await expect(totalButton).toBeVisible();
  if(process.env.RUN_TOTAL_ROBOT==="true"&&testInfo.project.name==="chromium"){
    test.setTimeout(50*60*1000);
    await totalButton.click();
    await page.getByRole("button",{name:"Continuar"}).click();
    await page.getByRole("button",{name:"Continuar"}).click();
    await page.getByRole("button",{name:"Iniciar recorrido total"}).click();
    await expect(page.locator("#qa-total-phase")).toHaveText("ERP CERTIFICADO PARA LIBERACIÓN",{timeout:45*60*1000});
    await expect(page.locator("#qa-total-counts")).toContainText("0 fallidas");
  }
  expect(errors).toEqual([]);
});

test("recorre todos los módulos, controles seguros y detecta errores de interfaz",async({page})=>{
  test.setTimeout(20*60*1000);
  const errors=diagnostics(page);
  for(const moduleId of criticalModules){
    const exists=await page.locator(`[data-nav="${moduleId}"]`).count();if(!exists)continue;
    const before=errors.length;
    await navigateModule(page,moduleId);
    await assertNoHorizontalOverflow(page);
    const buttons=page.locator("#page-content button:visible");
    const n=Math.min(await buttons.count(),25);
    let clicked=0;
    for(let i=0;i<n&&clicked<8;i++){
      const b=buttons.nth(i);const label=((await b.getAttribute("aria-label"))||await b.innerText().catch(()=>"")).trim();
      if(!label||mutationRe.test(label)||!safeRe.test(label)||await b.isDisabled())continue;
      await b.click().catch(()=>{});clicked++;await page.waitForTimeout(150);await closeModal(page);
      if(!(page.url().includes(`#/${moduleId}`)))await navigateModule(page,moduleId);
    }
    expect(errors.slice(before),`Errores al recorrer ${moduleId}`).toEqual([]);
  }
});

test("Sandbox puede mover y abrir un pedido TEST a través de todas las etapas",async({page})=>{
  test.setTimeout(25*60*1000);
  const errors=diagnostics(page);
  await navigateModule(page,"sandbox");
  await page.getByRole("button",{name:/Flujo completo/}).click();
  await page.locator("#sandbox-count").selectOption("1");
  await page.locator("#sandbox-create").click();
  await expect(page.locator(".lab-order-row").first()).toBeVisible({timeout:20000});
  const orderNumber=(await page.locator(".lab-order-row .lab-col-main strong").first().innerText()).trim();
  const steps=["CARTERA","CAJA","COMPRAS","RECEPCION_MERCANCIA","RECEPCION_PEDIDO","ALISTAMIENTO","FACTURACION","CAJA_FACTURACION","CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"];
  try{
    for(const step of steps){
      const row=page.locator(".lab-order-row").filter({hasText:orderNumber}).first();
      await row.getByRole("button",{name:"Mover"}).click();
      await page.locator('#modal-root select[name="step"]').selectOption(step);
      await page.getByRole("button",{name:"Mover pedido"}).click();
      await expect(page.locator(".lab-order-row").filter({hasText:orderNumber})).toContainText(/./,{timeout:10000});
      const moved=page.locator(".lab-order-row").filter({hasText:orderNumber}).first();
      const moduleButton=moved.getByRole("button",{name:/Abrir módulo|Alistamiento/}).first();
      if(await moduleButton.count()){
        await moduleButton.click();await page.waitForTimeout(500);
        await expect(page.locator("#page-content .module-error")).toHaveCount(0);
        await navigateModule(page,"sandbox");
      }
    }
  }finally{
    await navigateModule(page,"sandbox");
    const row=page.locator(".lab-order-row").filter({hasText:orderNumber}).first();
    if(await row.count()){await row.getByRole("button",{name:"Eliminar"}).click();await page.getByRole("button",{name:"Eliminar definitivamente"}).click()}
  }
  expect(errors).toEqual([]);
});

test("Corte Sandbox moderno aparece y abre sin tocar inventario real",async({page})=>{
  test.setTimeout(10*60*1000);
  const errors=diagnostics(page);
  await navigateModule(page,"sandbox");
  await page.getByRole("button",{name:/Corte \+ Alistamiento/}).click();
  await page.locator("#sandbox-create").click();
  await expect(page.locator(".lab-order-row.parallel").first()).toBeVisible({timeout:15000});
  const row=page.locator(".lab-order-row.parallel").first();
  const orderNumber=(await row.locator(".lab-col-main strong").innerText()).trim();
  try{
    await row.getByRole("button",{name:"Corte"}).click();
    await expect(page.getByRole("heading",{name:"Centro de corte"})).toBeVisible({timeout:15000});
    await expect(page.locator("#page-content .module-error")).toHaveCount(0);
  }finally{
    await navigateModule(page,"sandbox");
    const cleanup=page.locator(".lab-order-row").filter({hasText:orderNumber}).first();
    if(await cleanup.count()){await cleanup.getByRole("button",{name:"Eliminar"}).click();await page.getByRole("button",{name:"Eliminar definitivamente"}).click()}
  }
  expect(errors).toEqual([]);
});

test("responsive de módulos críticos no desborda el viewport",async({page})=>{
  const errors=diagnostics(page);
  for(const moduleId of ["dashboard","orders","inventory","workforce","approvals","sandbox","cutting","receiving","shipping"]){
    if(!await page.locator(`[data-nav="${moduleId}"]`).count())continue;
    await navigateModule(page,moduleId);await assertNoHorizontalOverflow(page);
  }
  expect(errors).toEqual([]);
});
