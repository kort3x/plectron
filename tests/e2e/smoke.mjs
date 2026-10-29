import { spawn } from 'node:child_process';
import { writeFileSync, rmSync } from 'node:fs';
// Browser smoke test against a running server on ./examples/ContosoOps.
// Usage: node tests/e2e/smoke.mjs <url-printed-by-Start-Plectron> [outDir]
// Set CHROME to the Chrome/Edge executable if it is not in the default macOS location.
const SP = process.argv[3] || process.cwd();
const URL = process.argv[2];
rmSync(`${SP}/chrome-e2e`, { recursive: true, force: true });
const chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--remote-debugging-port=9333', `--user-data-dir=${SP}/chrome-e2e`, 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch('http://127.0.0.1:9333/json/list')).json()).find((t) => t.type === 'page'); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let seq = 0; const waiting = new Map(); const errors = [];
ws.addEventListener('message', (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
  if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
  if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') errors.push(msg.params.args.map((a) => a.value ?? a.description).join(' '));
  if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error') errors.push(msg.params.entry.text + ' ' + (msg.params.entry.url || ''));
});
const send = (method, params = {}) => new Promise((r) => { const id = ++seq; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value;
const waitFor = async (expr, ms = 15000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await evaluate(expr)) return true; await sleep(100); } throw new Error(`timeout: ${expr}`); };
const shot = async (name) => { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(`${SP}/${name}.png`, Buffer.from(r.result.data, 'base64')); };
const check = (name, ok) => { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`); if (!ok) process.exitCode = 1; };

await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 950, deviceScaleFactor: 1, mobile: false });
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
await send('Page.navigate', { url: URL + '#/tool/contosoops.invoke-deployment' });
await waitFor(`!!document.querySelector('#f-Environment')`);
check('project branding applied', await evaluate(`document.title === 'Contoso Ops' && document.querySelector('.brand span').textContent === 'Contoso Ops' && getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() === '#0a7cff'`));
check('command name shown', await evaluate(`document.querySelector('.cmd-name')?.textContent === 'ContosoOps\\\\Invoke-Deployment'`));
check('no stray null text in form', !(await evaluate(`document.querySelector('form').firstChild.nodeType === 3`)));
check('array default preselected', await evaluate(`[...document.querySelectorAll('.pill-opt[aria-pressed=true]')].map(b=>b.textContent).join(',') === 'api,web,worker'`));

// validation: submit without required Environment
await evaluate(`document.querySelector('form button[type=submit]').click()`);
await sleep(200);
check('required validation shown', await evaluate(`document.querySelector('.field.invalid .err')?.textContent === 'This field is required.'`));
// parameter set switch shows Url field
await evaluate(`[...document.querySelectorAll('.segmented button')].find(b=>b.textContent==='Custom').click()`);
check('param set switch shows Url', await evaluate(`!!document.querySelector('#f-Url') && !document.querySelector('#f-Environment')`));
await evaluate(`document.querySelector('#f-Url').value='ftp://x'; document.querySelector('form button[type=submit]').click()`);
await sleep(200);
check('pattern validation', await evaluate(`(document.querySelector('.field.invalid .err')?.textContent||'').startsWith('Must match')`));
await evaluate(`[...document.querySelectorAll('.segmented button')].find(b=>b.textContent==='Named').click()`);
await evaluate(`{ const s=document.querySelector('#f-Environment'); s.value='Staging'; s.dispatchEvent(new Event('change')) }`);
await evaluate(`[...document.querySelectorAll('.pill-opt')].find(b=>b.textContent==='scheduler').click()`);
await shot('e2e-form-light');
await evaluate(`document.querySelector('form button[type=submit]').click()`);
await waitFor(`location.hash.startsWith('#/run/')`);
await waitFor(`!!document.querySelector('.progress')`, 10000);
await shot('e2e-running');
check('progress bars render while running', await evaluate(`document.querySelectorAll('.progress').length >= 1`));
check('cancel visible while running', await evaluate(`!document.querySelector('.btn.danger').hidden`));
await waitFor(`document.querySelector('.status')?.textContent === 'succeeded'`, 30000);
check('objects tab auto-selected on success', await evaluate(`document.querySelectorAll('table.grid tbody tr').length === 4`));
await evaluate(`[...document.querySelectorAll('.tab')][0].click()`);
check('console has host + verbose lines', await evaluate(`!!document.querySelector('.console .line[data-t=info]') && !!document.querySelector('.console .line[data-t=verbose]')`));
check('progress cleared at end', await evaluate(`document.querySelectorAll('.progress').length === 0`));
await shot('e2e-console-light');

// sorting
await evaluate(`[...document.querySelectorAll('.tab')][1].click()`);
await evaluate(`[...document.querySelectorAll('table.grid th')].find(t=>t.textContent.startsWith('Service')).click()`);
await evaluate(`[...document.querySelectorAll('table.grid th')].find(t=>t.textContent.startsWith('Service')).click()`);
check('sort descending', await evaluate(`document.querySelector('table.grid tbody tr td').textContent === 'worker'`));
await evaluate(`document.querySelector('table.grid tbody tr').click()`);
check('row detail opens', await evaluate(`!!document.querySelector('tr.detail .tree')`));

// re-run prefill
await evaluate(`[...document.querySelectorAll('.btn')].find(b=>b.textContent.includes('Run again')).click()`);
await waitFor(`!!document.querySelector('#f-Environment')`);
check('rerun prefills values', await evaluate(`document.querySelector('#f-Environment').value === 'Staging'`));

// cancel flow
await evaluate(`document.querySelector('form button[type=submit]').click()`);
await waitFor(`location.hash.startsWith('#/run/') && !!document.querySelector('.btn.danger') && !document.querySelector('.btn.danger').hidden`);
await sleep(800);
await evaluate(`document.querySelector('.btn.danger').click()`);
await waitFor(`document.querySelector('.status')?.textContent === 'cancelled'`, 15000);
check('cancel works', true);

// history
await send('Page.navigate', { url: URL.split('?')[0] + '#/history' });
await waitFor(`document.querySelectorAll('.history-table tbody tr').length > 0`);
check('history lists runs', true);
await shot('e2e-history-light');

// greeting: secrets + list input
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
await send('Page.navigate', { url: URL.split('?')[0] + '#/tool/contosoops.new-greeting' });
await waitFor(`!!document.querySelector('#f-Name')`);
await evaluate(`document.querySelector('#f-Name').value='Ada'; const t=document.querySelector('#f-Tags'); t.value='x, y'; t.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'})); document.querySelector('#f-ApiKey').value='k3y'; document.querySelector('#f-Login').value='ada'`);
check('list input makes chips', await evaluate(`document.querySelectorAll('.tag').length === 2`));
await evaluate(`document.querySelector('form button[type=submit]').click()`);
await waitFor(`document.querySelector('.status')?.textContent === 'succeeded'`, 30000);
check('secret not shown in param chips', await evaluate(`!document.querySelector('.param-chips').textContent.includes('k3y')`));
await evaluate(`[...document.querySelectorAll('.tab')][0].click()`);
check('secret reached script', await evaluate(`document.querySelector('.console').textContent.includes('API key of length 3')`));
await shot('e2e-console-dark');

// mobile layout
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
await send('Page.navigate', { url: URL.split('?')[0] + '#/tool/contosoops.invoke-deployment' });
await waitFor(`!!document.querySelector('#f-Environment')`);
await sleep(300);
check('no horizontal scroll on mobile', await evaluate(`document.documentElement.scrollWidth <= 390 && document.querySelector('.main').scrollWidth <= 390`));
await shot('e2e-mobile');


// ---- custom pages ----------------------------------------------------------
await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 1000, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: URL.split('?')[0] + '#/page/fleetdashboard' });
await waitFor(`document.querySelector('.page-head h1')?.textContent === 'Fleet dashboard' && document.querySelectorAll('.pg-data .objects table.grid tbody tr').length === 12`, 20000);
check('page table loads', true);
check('bar chart draws both series', await evaluate(`document.querySelectorAll('.chart path.mark').length === 24 && document.querySelectorAll('.chart-legend span').length === 2`));
check('markdown rendered safely', await evaluate(`!!document.querySelector('.md strong') && !!document.querySelector('.md li code')`));
await evaluate(`{ const s = document.querySelector('#pg-Region'); s.value = 'eu-west'; s.dispatchEvent(new Event('change')) }`);
await waitFor(`document.querySelectorAll('.pg-data .objects table.grid tbody tr').length === 4`, 15000);
check('filter refreshes table', true);
await evaluate(`[...document.querySelectorAll('.pg-data .objects table.grid tbody td.sel input')].slice(0, 2).forEach((c) => c.click())`);
await evaluate(`[...document.querySelectorAll('.pg-action')].find((b) => b.textContent.includes('Restart')).click()`);
await waitFor(`!!document.querySelector('dialog.pg-dialog[open]')`);
check('confirm dialog shown', true);
await evaluate(`[...document.querySelectorAll('dialog.pg-dialog button')].find((b) => b.textContent === 'Restart').click()`);
await waitFor(`[...document.querySelectorAll('.toast')].some((t) => t.textContent === 'Restarted 2 server(s).')`, 20000);
check('action ran on selected rows', true);
check('action output streamed to panel', await evaluate(`document.querySelector('.pg-output .console').textContent.includes('Restarting')`));
await sleep(500);
check('selection cleared after refresh', await evaluate(`document.querySelectorAll('.pg-data td.sel input:checked').length === 0`));
await shot('e2e-page');
await evaluate(`[...document.querySelectorAll('.pg-tabs .tab')].find((t) => t.textContent === 'Uptime').click()`);
check('tabs switch and line chart draws', await evaluate(`!!document.querySelector('.chart path.line-mark') && document.querySelector('.chart path.line-mark').getAttribute('d').length > 10`));
await send('Page.navigate', { url: URL.split('?')[0] + '#/page/taskmanager' });
await waitFor(`document.querySelector('.page-head h1')?.textContent === 'Task manager' && document.querySelectorAll('.pg-data .objects table.grid tbody tr').length > 0`, 20000);
await evaluate(`[...document.querySelectorAll('.pg-action')].find((b) => b.textContent.includes('Details')).click()`);
await waitFor(`[...document.querySelectorAll('.toast')].some((t) => t.textContent.includes('Select one or more processes'))`, 15000);
check('task manager page works without selection', true);
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
await send('Page.navigate', { url: URL.split('?')[0] + '#/page/fleetdashboard' });
await waitFor(`document.querySelector('.page-head h1')?.textContent === 'Fleet dashboard' && document.querySelectorAll('.pg-data .objects table.grid tbody tr').length > 0`, 20000);
await sleep(300);
check('page has no horizontal scroll on mobile', await evaluate(`document.documentElement.scrollWidth <= 390 && document.querySelector('.main').scrollWidth <= 390`));
await shot('e2e-page-mobile');

check(`no JS errors (${errors.join(' | ')})`, errors.length === 0);
ws.close(); chrome.kill();
