import {test,expect} from "@playwright/test";

async function login(page){
  await page.goto("/");
  await page.getByLabel("Correo corporativo").fill(process.env.ERP_TEST_EMAIL);
  await page.getByLabel("Contraseña").fill(process.env.ERP_TEST_PASSWORD);
  await page.getByRole("button",{name:"Ingresar al ERP"}).click();
  await expect(page.getByText("Operación en tiempo real")).toBeVisible({timeout:30000});
}

test("login shell renders",async({page})=>{
  await page.goto("/");
  await expect(page.getByRole("heading",{name:"ERP Supply Enterprise"})).toBeVisible();
  await expect(page.getByLabel("Correo corporativo")).toBeVisible();
  await expect(page.getByLabel("Contraseña")).toBeVisible();
});

test("authenticated shell, modules and native API",async({page})=>{
  test.skip(!process.env.ERP_TEST_EMAIL||!process.env.ERP_TEST_PASSWORD,"Configure ERP_TEST_EMAIL and ERP_TEST_PASSWORD");
  const errors=[];
  page.on("console",msg=>{if(msg.type()==="error")errors.push(msg.text())});
  await login(page);

  const modules=[
    ["Control de pedidos","Bandeja integral de pedidos"],
    ["Inventario","Inventario"],
    ["Aprobaciones","Aprobaciones"],
    ["VSM y tiempos","VSM"],
    ["Bot QA E2E","Centro de pruebas automatizadas"]
  ];
  for(const [button,text] of modules){
    await page.getByRole("button",{name:button}).click();
    await expect(page.getByText(text,{exact:false}).first()).toBeVisible({timeout:30000});
  }

  expect(errors.filter(x=>/firebase|firestore|DocumentRef|QueryRef|snapshot\.forEach|supabase-compat/i.test(x))).toEqual([]);
});

test("integral 202 verification can be triggered by super admin",async({page})=>{
  test.setTimeout(30*60*1000);
  test.skip(process.env.RUN_INTEGRAL_QA!=="true"||!process.env.ERP_TEST_EMAIL||!process.env.ERP_TEST_PASSWORD,"Set RUN_INTEGRAL_QA=true and credentials");
  await login(page);
  await page.getByRole("button",{name:"Bot QA E2E"}).click();
  await page.getByRole("button",{name:"Ejecutar validación integral"}).click();
  await expect(page.getByText(/Validación integral aprobada: 202 escenarios y controles sin fallos/i)).toBeVisible({timeout:25*60*1000});
});
