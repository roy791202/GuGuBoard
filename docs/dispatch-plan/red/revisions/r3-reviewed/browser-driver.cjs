// Browser driver for the test-only UI, never the installed GuGuBoard product.
const fs=require('fs'),path=require('path');
const {chromium}=require(path.join(process.env.TEMP,'guguboard-red-browser/node_modules/playwright'));
(async()=>{
 const [url,task,artifact]=process.argv.slice(2);const responses=[],pending=[],errors=[];
 const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 try{
  const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
  page.on('response',r=>{if(r.url().endsWith('/command'))pending.push(r.text().then(text=>responses.push({url:r.url(),status:r.status(),text})));});
  await page.goto(url);await page.locator('#settled[data-sequence="1"]').waitFor({state:'attached'});
  if(task==='UI-02-1'){await page.reload();await page.locator('#settled[data-sequence="1"]').waitFor({state:'attached'});}
  if(task==='UI-01-2'){await page.locator('#start').fill('invalid');await page.locator('#save').click();await page.locator('#settled[data-sequence="2"]').waitFor({state:'attached'});}
  if(task==='UI-01-3' && !await page.locator('#save').isDisabled()){await page.locator('#start').fill('2026-11-07T09:00:00+08:00');await page.locator('#save').click();await page.locator('#settled[data-sequence="2"]').waitFor({state:'attached'});}
  if(task==='UI-02-2'){await page.locator('#test').click();await page.locator('#settled[data-sequence="2"]').waitFor({state:'attached'});}
  if(task==='UI-02-3'){await page.locator('#pause').click();await page.locator('#settled[data-sequence="2"]').waitFor({state:'attached'});}
  let forcedResponse=null;
  if(task==='UI-01-3'||task==='UI-03-2')forcedResponse=await page.evaluate(async task=>{const r=await fetch('/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({operation:task==='UI-01-3'?'SaveScheduleView':'ApproveCompletion',request:{notBefore:'2026-11-07T09:00:00+08:00',ticketId:'FIX-1'}})});return r.json();},task);
  const observed=await page.evaluate(()=>({enabled:document.querySelector('#enabled').checked,maxConcurrent:document.querySelector('#concurrent').value,error:document.querySelector('#error').textContent,saveDisabled:document.querySelector('#save').disabled,key:document.querySelector('#key').textContent,health:document.querySelector('#health').textContent,runner:document.querySelector('#runner').textContent,pauseDisabled:document.querySelector('#pause').disabled,process:document.querySelector('#process').textContent,completion:document.querySelector('#completion').textContent,completeDisabled:document.querySelector('#complete').disabled,reason:document.querySelector('#reason').textContent,empty:document.querySelector('#empty').textContent,success:document.querySelector('#success').textContent,body:document.body.innerText}));
  fs.mkdirSync(path.dirname(artifact),{recursive:true});await page.screenshot({path:artifact,fullPage:true});
  await Promise.all(pending);
  const fullHTML=await page.content();const errorField=await page.locator('#error').getAttribute('data-field');const readOnly=await page.locator('#concurrent').getAttribute('readonly');
  console.log(JSON.stringify({observed,errorField,concurrencyReadOnly:readOnly!==null,fullHTML,responses,forcedResponse,errors,browserVersion:browser.version(),screenshot:artifact}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e.stack);process.exit(2);});
