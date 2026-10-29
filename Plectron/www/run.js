import { h, clear, svg, icons, toast } from './dom.js';
import { api } from './api.js';
import { avatar, duration, statusPill, short } from './util.js';
import { createConsole, createProgress } from './console.js';
import { createTable } from './table.js';
export async function runView(main, id, { tools, navigate }) {
  let meta = await api.run(id);
  const tool = tools.find((t) => t.id === meta.toolId) || { id: meta.toolId, title: meta.toolTitle };
  let disposed = false;

  // ---- header -----------------------------------------------------------
  const pillHost = h('span');
  const elapsed = h('b');
  const cancelBtn = h('button', { class: 'btn danger', onclick: cancel }, svg(icons.stop, 14), 'Cancel');
  const rerunBtn = h('button', { class: 'btn', onclick: () => navigate(`#/tool/${encodeURIComponent(meta.toolId)}?run=${id}`) }, svg(icons.redo, 15), 'Run again');
  const progressList = h('div', { class: 'progress-list' });

  const head = h('div', { class: 'page-head' },
    avatar(tool, true),
    h('div', { class: 'titles' },
      h('div', { class: 'crumbs' }, h('a', { href: '#/' }, 'Tools'), ' / ', h('a', { href: `#/tool/${encodeURIComponent(meta.toolId)}` }, tool.title), ' / run'),
      h('h1', null, tool.title),
      h('div', { class: 'run-meta' },
        pillHost,
        h('span', null, 'Started ', h('b', null, new Date(meta.startedAt).toLocaleString())),
        h('span', null, 'Duration ', elapsed),
        h('span', { title: meta.engine }, 'Engine ', h('b', null, (meta.engine || '').split(/[\\/]/).pop())),
        h('span', { class: 'exit' }))),
    h('div', { class: 'form-actions' }, cancelBtn, rerunBtn));

  const chips = h('div', { class: 'param-chips' },
    Object.entries(meta.parameters || {}).map(([k, v]) => h('span', { class: 'param-chip', title: `${k} = ${short(v)}` }, h('span', null, `-${k} `), short(v))));

  // ---- console ----------------------------------------------------------
  const consoleEl = h('div', { class: 'console', role: 'log', 'aria-live': 'off' });
  const consoleView = createConsole(consoleEl);
  const progressView = createProgress(progressList);

  // ---- objects ----------------------------------------------------------
  const rows = [];
  let displayCols = null;
  const objectsPanel = h('div', { class: 'objects', hidden: true });
  const table = createTable(objectsPanel, { getRows: () => rows, getDisplay: () => displayCols, exportName: `${meta.toolId}-${id}` });

  // ---- tabs -------------------------------------------------------------
  const consoleCount = h('span', { class: 'count' }, '0');
  const objCount = h('span', { class: 'count' }, '0');
  const tabConsole = h('button', { class: 'tab', role: 'tab', 'aria-selected': 'true', onclick: () => selectTab('console', true) }, 'Console', consoleCount);
  const tabObjects = h('button', { class: 'tab', role: 'tab', 'aria-selected': 'false', onclick: () => selectTab('objects', true) }, 'Objects', objCount);
  let userPickedTab = false;
  const filters = h('div', { class: 'tools' },
    ['verbose', 'debug', 'info'].map((t) => {
      const b = h('button', { class: 'filter-toggle', 'aria-pressed': 'true', title: `Show ${t} messages` }, t);
      b.addEventListener('click', () => {
        const on = b.getAttribute('aria-pressed') !== 'true';
        b.setAttribute('aria-pressed', String(on));
        consoleEl.classList.toggle(`hide-${t}`, !on);
      });
      return b;
    }),
    h('button', { class: 'icon-btn', title: 'Copy console text', 'aria-label': 'Copy console text', onclick: copyConsole }, svg(icons.copy, 16)));

  function selectTab(name, byUser) {
    if (byUser) userPickedTab = true;
    tabConsole.setAttribute('aria-selected', String(name === 'console'));
    tabObjects.setAttribute('aria-selected', String(name === 'objects'));
    consoleEl.hidden = name !== 'console';
    filters.hidden = name !== 'console';
    objectsPanel.hidden = name !== 'objects';
    if (name === 'objects') table.render();
  }

  const card = h('div', { class: 'card' },
    h('div', { class: 'tabs', role: 'tablist' }, tabConsole, tabObjects, h('span', { class: 'spacer' }), filters),
    consoleEl, objectsPanel);

  main.append(h('div', { class: 'page' }, head, chips, progressList, card));
  if (tool.output === 'table' || tool.output === 'json') selectTab('objects');

  // ---- status -----------------------------------------------------------
  let timer = null;
  function setStatus(status, exitCode, durationMs) {
    clear(pillHost).append(statusPill(status));
    cancelBtn.hidden = status !== 'running';
    const exitEl = head.querySelector('.exit');
    exitEl.textContent = exitCode !== null && exitCode !== undefined ? `Exit code ${exitCode}` : '';
    if (status === 'running') {
      if (!timer) timer = setInterval(() => { elapsed.textContent = duration(Date.now() - new Date(meta.startedAt).getTime()); }, 250);
    } else {
      clearInterval(timer);
      timer = null;
      elapsed.textContent = duration(durationMs ?? meta.durationMs);
    }
  }
  setStatus(meta.status, meta.exitCode, meta.durationMs);

  async function cancel() {
    cancelBtn.disabled = true;
    try { await api.deleteRun(id); } catch (e) { toast(e.message); cancelBtn.disabled = false; }
  }

  function copyConsole() {
    navigator.clipboard.writeText(consoleView.text()).then(() => toast('Console copied'), () => toast('Copy failed'));
  }

  // ---- event handling ---------------------------------------------------
  let pending = [];
  let scheduled = false;

  function handle(ev) {
    pending.push(ev);
    if (!scheduled) { scheduled = true; requestAnimationFrame(flush); }
  }

  function flush() {
    scheduled = false;
    if (disposed) return;
    const batch = pending;
    pending = [];
    const lines = [];
    let newRows = false;
    for (const ev of batch) {
      if (ev.t === 'progress') { progressView.update(ev.data); continue; }
      if (ev.t === 'exit') continue;
      if (ev.t === 'output') newRows = collectRows(ev) || newRows;
      if (ev.t === 'end') onEnd(ev.data);
      lines.push(ev);
    }
    if (consoleView.append(lines)) consoleCount.textContent = String(consoleView.count);
    if (newRows) {
      objCount.textContent = String(rows.length);
      if (!objectsPanel.hidden) table.render();
    }
  }

  function collectRows(ev) {
    const items = Array.isArray(ev.data) ? ev.data : [ev.data];
    if (!displayCols && ev.display && ev.display.length) displayCols = ev.display;
    for (const item of items) rows.push(item !== null && typeof item === 'object' && !Array.isArray(item) ? item : { Value: item });
    return true;
  }

  function onEnd(data) {
    progressView.clear();
    meta = { ...meta, status: data.status, exitCode: data.exitCode, durationMs: data.durationMs };
    setStatus(data.status, data.exitCode, data.durationMs);
    if (!userPickedTab && data.status === 'succeeded' && rows.length && tool.output !== 'text' && rows.some((r) => !('Value' in r && Object.keys(r).length === 1))) selectTab('objects');
  }

  const es = api.events(id);
  es.onmessage = (e) => {
    let ev;
    try { ev = JSON.parse(e.data); } catch { return; }
    handle(ev);
    if (ev.t === 'end') es.close();
  };

  return () => {
    disposed = true;
    es.close();
    table.dispose();
    clearInterval(timer);
  };
}
