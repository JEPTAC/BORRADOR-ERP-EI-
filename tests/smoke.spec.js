import {test,expect} from "@playwright/test";

async function login(page){
  await page.goto("/");
  await page.getByLabel("Correo corporativo").fill(process.env.ERP_TEST_EMAIL);
  await page.getByLabel("Contraseña").fill(process.env.ERP_TEST_PASSWORD);
  await page.getByRole("button",{name:"Ingresar al ERP"}).click();
  await expect(page.getByRole("heading",{name:"Centro de operación"})).toBeVisible({timeout:30000});
}

test("login shell renders",async({page})=>{
  await page.goto("/");
  await expect(page.getByRole("heading",{name:"Bienvenido al ERP"})).toBeVisible();
  await expect(page.getByLabel("Correo corporativo")).toBeVisible();
  await expect(page.getByLabel("Contraseña")).toBeVisible();
});

test("authenticated shell, modules and native API",async({page})=>{
  test.skip(!process.env.ERP_TEST_EMAIL||!process.env.ERP_TEST_PASSWORD,"Configure ERP_TEST_EMAIL and ERP_TEST_PASSWORD");
  const errors=[];
  page.on("console",msg=>{if(msg.type()==="error")errors.push(msg.text())});
  await login(page);

  const modules=[
    ["Control de pedidos","Control integral de pedidos"],
    ["Inventario","Inventario"],
    ["Aprobaciones","Aprobaciones"],
    ["Flujo y tiempos","Flujo y tiempos de la operación"],
    ["Pruebas automáticas","Pruebas automáticas del ERP"]
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
  await page.getByRole("button",{name:"Pruebas automáticas"}).click();
  await page.getByRole("button",{name:"Validación integral"}).click();
  await page.getByRole("button",{name:"Iniciar pruebas"}).click();
  await expect(page.getByText(/Validación completa aprobada: 202 pruebas sin fallos/i)).toBeVisible({timeout:25*60*1000});
});
