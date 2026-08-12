import {defineConfig,devices} from "@playwright/test";
export default defineConfig({
  testDir:"./tests",
  timeout:60000,
  expect:{timeout:10000},
  fullyParallel:false,
  workers:process.env.CI?1:undefined,
  retries:process.env.CI?2:0,
  reporter:process.env.CI?[["github"],["html",{open:"never"}]]:[["list"],["html",{open:"never"}]],
  use:{
    baseURL:process.env.ERP_BASE_URL||"http://127.0.0.1:4173",
    trace:"on-first-retry",
    screenshot:"only-on-failure",
    video:"retain-on-failure"
  },
  projects:[
    {name:"chromium",use:{...devices["Desktop Chrome"]}},
    {name:"mobile",use:{...devices["Pixel 7"]}}
  ],
  webServer:process.env.ERP_BASE_URL?undefined:{command:"npm run serve",url:"http://127.0.0.1:4173",reuseExistingServer:true,timeout:120000}
});
