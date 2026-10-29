import { h, clear, svg, icons, toast } from './dom.js';
import { api } from './api.js';
import { avatar, clockTime, duration, statusPill, short, download } from './util.js';
import { jsonTree, summarize } from './tree.js';

const CONSOLE_LIMIT = 5000;
const HOST_COLORS = {
  Black: '#5c6370', DarkBlue: '#4a7fd6', DarkGreen: '#3fae6a', DarkCyan: '#3aa7b5', DarkRed: '#d75f5f',
  DarkMagenta: '#b76bd6', DarkYellow: '#c9a227', Gray: '#b5b9c9', DarkGray: '#7f8499', Blue: '#7cb4ff',
  Green: '#7ee2a0', Cyan: '#7fe3ef', Red: '#ff8f97', Magenta: '#f39cff', Yellow: '#ffe17a', White: '#ffffff',
};

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
  const consoleEmpty = h('div', { class: 'console-empty' }, 'Waiting for output…');
  consoleEl.append(consoleEmpty);
  let lineCount = 0;

  // ---- objects ----------------------------------------------------------
  const rows = [];
  let displayCols = null;
  const objectsPanel = h('div', { class: 'objects', hidden: true });
  const table = createTable(objectsPanel, () => rows, () => displayCols, `${meta.toolId}-${id}`);

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
    const text = [...consoleEl.querySelectorAll('.line')].filter((l) => l.offsetParent !== null).map((l) => l.lastChild.textContent).join('\n');
    navigator.clipboard.writeText(text).then(() => toast('Console copied'), () => toast('Copy failed'));
  }

  // ---- event handling ---------------------------------------------------
  let pending = [];
  let scheduled = false;
  const progress = new Map();

  function handle(ev) {
    pending.push(ev);
    if (!scheduled) { scheduled = true; requestAnimationFrame(flush); }
  }

  function flush() {
    scheduled = false;
    if (disposed) return;
    const batch = pending;
    pending = [];
    const stick = consoleEl.scrollTop + consoleEl.clientHeight >= consoleEl.scrollHeight - 30;
    const frag = document.createDocumentFragment();
    let newRows = false;
    for (const ev of batch) {
      if (ev.t === 'progress') { updateProgress(ev.data); continue; }
      if (ev.t === 'exit') continue;
      if (ev.t === 'output') newRows = collectRows(ev) || newRows;
      if (ev.t === 'end') onEnd(ev.data);
      const line = renderLine(ev);
      if (line) { frag.append(line); lineCount++; }
    }
    if (frag.childNodes.length) {
      consoleEmpty.remove();
      consoleEl.append(frag);
      while (consoleEl.childElementCount > CONSOLE_LIMIT) consoleEl.firstElementChild.remove();
      consoleCount.textContent = String(lineCount);
      if (stick) consoleEl.scrollTop = consoleEl.scrollHeight;
    }
    if (newRows) {
      objCount.textContent = String(rows.length);
      if (!objectsPanel.hidden) table.render();
    }
    renderProgress();
  }

  function collectRows(ev) {
    const items = Array.isArray(ev.data) ? ev.data : [ev.data];
    if (!displayCols && ev.display && ev.display.length) displayCols = ev.display;
    for (const item of items) rows.push(item !== null && typeof item === 'object' && !Array.isArray(item) ? item : { Value: item });
    return true;
  }

  function updateProgress(p) {
    if (p.completed) progress.delete(p.id);
    else progress.set(p.id, p);
  }

  function renderProgress() {
    clear(progressList);
    const ordered = [...progress.values()].sort((a, b) => (a.parentId === b.id ? 1 : b.parentId === a.id ? -1 : a.id - b.id));
    for (const p of ordered) {
      const pct = p.percent >= 0 ? Math.min(100, p.percent) : null;
      const eta = p.secondsRemaining > 0 ? ` · ${duration(p.secondsRemaining * 1000)} left` : '';
      progressList.append(h('div', { class: `card progress${p.parentId >= 0 && progress.has(p.parentId) ? ' child' : ''}` },
        h('div', { class: 'row' },
          h('span', { class: 'act' }, p.activity),
          h('span', { class: 'st' }, [p.status, p.operation].filter(Boolean).join(' — ') + eta + (pct !== null ? ` · ${pct}%` : ''))),
        h('div', { class: `bar${pct === null ? ' indeterminate' : ''}` }, h('i', { style: { width: `${pct ?? 0}%` } }))));
    }
  }

  function onEnd(data) {
    progress.clear();
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
    clearInterval(timer);
  };
}

function renderLine(ev) {
  const ts = h('span', { class: 'ts' }, ev.ts ? clockTime(ev.ts) : '');
  let body;
  switch (ev.t) {
    case 'output':
      if (ev.data !== null && typeof ev.data === 'object') {
        const wrap = h('span');
        const label = h('span', { class: 'obj', title: ev.type || '' }, summarize(ev.data));
        let tree = null;
        label.addEventListener('click', () => {
          if (tree) { tree.remove(); tree = null; } else { tree = jsonTree(ev.data, { open: 2 }); wrap.append(tree); }
        });
        wrap.append(label);
        body = wrap;
      } else {
        body = h('span', null, ev.data === null ? '' : String(ev.data));
      }
      break;
    case 'error':
      body = h('span', { class: 'error' }, ev.data.message || 'Error',
        ev.data.position ? h('span', { class: 'pos' }, ev.data.position.trim()) : null);
      break;
    case 'warning': body = h('span', { class: 'warning' }, h('span', { class: 'prefix' }, 'WARNING: '), ev.data); break;
    case 'verbose': body = h('span', { class: 'verbose' }, h('span', { class: 'prefix' }, 'VERBOSE: '), ev.data); break;
    case 'debug': body = h('span', { class: 'debug' }, h('span', { class: 'prefix' }, 'DEBUG: '), ev.data); break;
    case 'info': {
      const style = {};
      if (ev.data.fg && HOST_COLORS[ev.data.fg]) style.color = HOST_COLORS[ev.data.fg];
      if (ev.data.bg && HOST_COLORS[ev.data.bg]) style.background = HOST_COLORS[ev.data.bg];
      body = h('span', { style }, ev.data.message);
      break;
    }
    case 'raw': body = h('span', { class: 'raw' }, ev.data); break;
    case 'stderr': body = h('span', { class: 'stderr' }, ev.data); break;
    case 'end':
      body = h('span', null, `Finished: ${ev.data.status}`,
        ev.data.exitCode !== null && ev.data.exitCode !== undefined ? ` · exit code ${ev.data.exitCode}` : '',
        ev.data.durationMs !== undefined ? ` · ${duration(ev.data.durationMs)}` : '');
      return h('div', { class: 'line end', dataset: { t: 'end' } }, ts, body);
    default:
      return null;
  }
  return h('div', { class: 'line', dataset: { t: ev.t } }, ts, body);
}

// ---- object table -------------------------------------------------------
function createTable(host, getRows, getDisplay, exportName) {
  let sortKey = null;
  let sortDir = 1;
  let filter = '';
  let hidden = null;
  let openRow = null;

  const filterInput = h('input', { class: 'input', type: 'search', placeholder: 'Filter rows', 'aria-label': 'Filter rows' });
  filterInput.addEventListener('input', () => { filter = filterInput.value.toLowerCase(); render(); });
  const menu = h('div', { class: 'menu', hidden: true });
  const colsBtn = h('button', { class: 'btn sm', onclick: (e) => { e.stopPropagation(); menu.hidden = !menu.hidden; } }, svg(icons.columns, 14), 'Columns');
  document.addEventListener('click', (e) => { if (!menu.contains(e.target)) menu.hidden = true; });
  const info = h('span', { class: 'hint' });
  const tableWrap = h('div', { class: 'table-wrap' });

  host.append(
    h('div', { class: 'obj-toolbar' }, filterInput, info, h('span', { class: 'spacer' }),
      h('div', { class: 'cols-menu' }, colsBtn, menu),
      h('button', { class: 'btn sm', onclick: () => exportCsv() }, svg(icons.download, 14), 'CSV'),
      h('button', { class: 'btn sm', onclick: () => download(`${exportName}.json`, JSON.stringify(getRows(), null, 2), 'application/json') }, svg(icons.download, 14), 'JSON')),
    tableWrap);

  function allColumns() {
    const cols = [];
    const seen = new Set();
    for (const r of getRows()) for (const k of Object.keys(r)) if (!seen.has(k)) { seen.add(k); cols.push(k); }
    return cols;
  }

  function visibleColumns(cols) {
    if (!hidden) {
      const display = getDisplay();
      hidden = new Set(display ? cols.filter((c) => !display.includes(c)) : cols.slice(12));
    }
    return cols.filter((c) => !hidden.has(c));
  }

  function filteredRows() {
    let list = getRows();
    if (filter) list = list.filter((r) => Object.values(r).some((v) => cellText(v).toLowerCase().includes(filter)));
    if (sortKey) {
      list = list.slice().sort((a, b) => {
        const x = a[sortKey];
        const y = b[sortKey];
        if (typeof x === 'number' && typeof y === 'number') return (x - y) * sortDir;
        return cellText(x).localeCompare(cellText(y), undefined, { numeric: true }) * sortDir;
      });
    }
    return list;
  }

  function render() {
    const all = allColumns();
    const cols = visibleColumns(all);
    const list = filteredRows();
    const total = getRows().length;
    info.textContent = filter ? `${list.length} of ${total} rows` : `${total} row${total === 1 ? '' : 's'}`;

    clear(menu);
    for (const c of all) {
      const cb = h('input', { type: 'checkbox', checked: !hidden.has(c) });
      cb.addEventListener('change', () => { if (cb.checked) hidden.delete(c); else hidden.add(c); render(); });
      menu.append(h('label', null, cb, c));
    }

    clear(tableWrap);
    if (!total) {
      tableWrap.append(h('div', { class: 'empty-state' }, h('div', { class: 'big' }, '∅'), 'No objects were written to the pipeline.'));
      return;
    }
    const thead = h('thead', null, h('tr', null, cols.map((c) => h('th', {
      'aria-sort': sortKey === c ? (sortDir > 0 ? 'ascending' : 'descending') : 'none',
      onclick: () => {
        if (sortKey !== c) { sortKey = c; sortDir = 1; } else if (sortDir === 1) sortDir = -1; else sortKey = null;
        render();
      },
    }, c, sortKey === c ? h('span', { class: 'arrow' }, sortDir > 0 ? '▲' : '▼') : null))));
    const tbody = h('tbody');
    for (const r of list.slice(0, 2000)) {
      const tr = h('tr', null, cols.map((c) => renderCell(r[c])));
      tr.addEventListener('click', () => {
        if (openRow && openRow.owner === tr) { openRow.el.remove(); openRow = null; return; }
        if (openRow) openRow.el.remove();
        const detail = h('tr', { class: 'detail' }, h('td', { colspan: String(cols.length) }, jsonTree(r, { open: 2 })));
        tr.after(detail);
        openRow = { owner: tr, el: detail };
      });
      tbody.append(tr);
    }
    openRow = null;
    tableWrap.append(h('table', { class: 'grid' }, thead, tbody));
  }

  function exportCsv() {
    const cols = visibleColumns(allColumns());
    const esc = (v) => `"${cellText(v).replace(/"/g, '""')}"`;
    const lines = [cols.map(esc).join(','), ...filteredRows().map((r) => cols.map((c) => esc(r[c])).join(','))];
    download(`${exportName}.csv`, lines.join('\r\n'), 'text/csv');
  }

  return { render };
}

function cellText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function renderCell(v) {
  if (v === null || v === undefined) return h('td', null, h('span', { class: 'cell-null' }, 'null'));
  if (typeof v === 'boolean') return h('td', null, h('span', { class: `cell-bool-${v}` }, String(v)));
  if (typeof v === 'number') return h('td', { class: 'num' }, String(v));
  if (typeof v === 'object') return h('td', null, h('span', { class: 'cell-nested' }, Array.isArray(v) ? `[${v.length}]` : summarize(v, 60)));
  return h('td', { title: String(v) }, String(v));
}
