import { h, clear, svg, icons, toast } from './dom.js';
import { api } from './api.js';
import { createConsole, createProgress } from './console.js';
import { createTable } from './table.js';
import { createChart } from './chart.js';
import { renderMarkdown } from './markdown.js';

// A custom page: the layout comes from the page process (New-Plx* DSL), and so
// do data updates and action output. Inputs and table selections live here and
// are sent with every action and refresh.

const STREAM_TYPES = new Set(['output', 'error', 'warning', 'verbose', 'debug', 'info', 'raw', 'stderr']);

export async function pageView(main, id, { navigate }) {
  const info = (await api.pages()).find((p) => p.id === id);
  if (!info) throw new Error(`Page '${id}' not found.`);
  const session = await api.createSession(id);
  const sid = session.id;

  const inputs = {};
  const selections = {};
  const controls = {};     // name -> { update(data) }
  const outputs = {};      // output name -> { console, progress }
  const requests = {};     // request id -> { target, button }
  const timers = [];
  const disposers = [];
  let busy = 0;
  let closed = false;

  const body = h('div', { class: 'pg-body' }, h('div', { class: 'pg-loading' }, h('span', { class: 'spinner' }), 'Starting page…'));
  const titleEl = h('h1', null, info.title);
  const descEl = h('div', { class: 'sub' }, info.description || '');
  const banner = h('div', { class: 'alert', hidden: true });
  const cancelBtn = h('button', { class: 'btn danger sm', hidden: true, onclick: () => api.cancel(sid).catch((e) => toast(e.message, 'error')) }, svg(icons.stop, 13), 'Cancel');

  // Output drawer for actions without -Output.
  const drawerConsole = h('div', { class: 'console' });
  const drawerProgress = h('div', { class: 'progress-list' });
  const drawer = h('section', { class: 'pg-drawer', hidden: true, 'aria-label': 'Action output' },
    h('div', { class: 'pg-drawer-head' }, h('b', null, 'Output'), h('span', { class: 'spacer' }), cancelBtn,
      h('button', { class: 'icon-btn', 'aria-label': 'Close output', onclick: () => { drawer.hidden = true; } }, '×')),
    drawerProgress, drawerConsole);
  const drawerView = { console: createConsole(drawerConsole, { emptyText: 'Action output appears here.' }), progress: createProgress(drawerProgress) };
  const outputBtn = h('button', { class: 'btn sm', onclick: () => { drawer.hidden = !drawer.hidden; } }, svg(icons.terminal, 14), 'Output');

  main.append(h('div', { class: 'page pg' },
    h('div', { class: 'page-head' },
      h('div', { class: 'titles' }, h('div', { class: 'crumbs' }, h('a', { href: '#/' }, 'Home'), ' / Pages'), titleEl, descEl),
      h('div', { class: 'form-actions' }, outputBtn)),
    banner, body, drawer));

  // ---- requests -----------------------------------------------------------
  function payload() {
    return { inputs: { ...inputs }, selections: JSON.parse(JSON.stringify(selections)) };
  }

  function setBusy(delta) {
    busy += delta;
    for (const b of main.querySelectorAll('.pg-action')) b.disabled = busy > 0 || closed;
    cancelBtn.hidden = busy === 0;
  }

  async function refresh(names) {
    if (closed || !names.length) return;
    try {
      const r = await api.refresh(sid, { names, ...payload() });
      requests[r.id] = { target: drawerView, quiet: true };
    } catch (e) { toast(e.message, 'error'); }
  }

  async function runAction(node, button) {
    if (node.props.confirm && !(await confirmDialog(node.props.confirm, node.props.text, node.props.variant === 'danger'))) return;
    const target = node.props.output ? outputs[node.props.output] : drawerView;
    if (!node.props.output) drawer.hidden = false;
    target.console.append([{ t: 'info', ts: new Date().toISOString(), data: { message: `▶ ${node.props.text}` } }]);
    button.classList.add('running');
    setBusy(1);
    try {
      const r = await api.invoke(sid, { handler: node.handler, ...payload() });
      requests[r.id] = { target, button, action: true };
    } catch (e) {
      toast(e.message, 'error');
      button.classList.remove('running');
      setBusy(-1);
    }
  }

  // ---- events ---------------------------------------------------------------
  const es = api.sessionEvents(sid);
  es.onmessage = (e) => {
    let ev;
    try { ev = JSON.parse(e.data); } catch { return; }
    handle(ev);
  };

  function handle(ev) {
    const req = ev.req ? (requests[ev.req] || null) : null;
    switch (ev.t) {
      case 'layout': renderLayout(ev.data); return;
      case 'data': {
        const c = controls[ev.data.name];
        if (c) c.update(ev.data);
        return;
      }
      case 'message': toast(ev.data.text, ev.data.level || 'info'); return;
      case 'progress': (req ? req.target : drawerView).progress.update(ev.data); return;
      case 'done': onDone(ev); return;
      case 'end': onEnd(); return;
      default:
        if (!STREAM_TYPES.has(ev.t)) return;
        // Data sources (load/refresh) only surface problems, not their objects.
        if (!req || req.quiet) {
          if (ev.t === 'error' || ev.t === 'warning' || ev.t === 'stderr') {
            drawerView.console.append([ev]);
            if (ev.t !== 'warning') drawer.hidden = false;
          }
          return;
        }
        req.target.console.append([ev]);
    }
  }

  function onDone(ev) {
    const req = requests[ev.req];
    delete requests[ev.req];
    const { status, error } = ev.data;
    if (ev.req === 'load') {
      if (status !== 'succeeded') showFailure(`This page could not be loaded:\n\n${error || 'unknown error'}`);
      return;
    }
    if (!req) return;
    req.target.progress.clear();
    if (req.action) {
      req.button.classList.remove('running');
      setBusy(-1);
      req.target.console.append([{ t: 'end', ts: new Date().toISOString(), data: { status } }]);
    }
    if (status === 'failed') toast(error || 'The action failed.', 'error');
    else if (status === 'cancelled') toast('Cancelled.', 'warning');
  }

  function onEnd() {
    if (closed) return;
    closed = true;
    es.close();
    setBusy(0);
    if (!banner.hidden) return;
    showFailure('The page process has stopped.');
  }

  function showFailure(message) {
    clear(banner).append(message, h('div', { style: { marginTop: '10px' } },
      h('button', { class: 'btn sm', onclick: () => navigate(location.hash) }, svg(icons.redo, 13), 'Reload page')));
    banner.hidden = false;
    if (body.querySelector('.pg-loading')) clear(body);
  }

  // ---- rendering -------------------------------------------------------------
  function renderLayout(layout) {
    titleEl.textContent = layout.props.title || info.title;
    descEl.textContent = layout.props.description || info.description || '';
    clear(body).append(...layout.children.map(renderNode));
  }

  function renderNode(node) {
    const p = node.props || {};
    switch (node.type) {
      case 'row': return h('div', { class: 'pg-row' }, node.children.map(renderNode));
      case 'column': return h('div', { class: 'pg-col', style: { flexGrow: String(p.width || 1) } }, node.children.map(renderNode));
      case 'card': return h('section', { class: 'card pg-card' }, p.title ? h('h3', null, p.title) : null, h('div', { class: 'pg-stack' }, node.children.map(renderNode)));
      case 'tabs': return renderTabs(node);
      case 'text': return p.markdown ? renderMarkdown(p.text) : h('p', { class: 'pg-text' }, p.text);
      case 'table': return renderTable(node);
      case 'chart': return renderChart(node);
      case 'button': return renderButton(node);
      case 'output': return renderOutput(node);
      case 'textbox': case 'dropdown': case 'checkbox': case 'number': return renderInput(node);
      default: return h('div', { class: 'hint' }, `Unknown control '${node.type}'.`);
    }
  }

  function renderTabs(node) {
    const tabs = node.children.filter((c) => c.type === 'tab');
    const panels = tabs.map((t) => h('div', { class: 'pg-stack', role: 'tabpanel', hidden: true }, t.children.map(renderNode)));
    const buttons = tabs.map((t, i) => h('button', { class: 'tab', role: 'tab', 'aria-selected': 'false', onclick: () => select(i) }, t.props.title));
    function select(i) {
      buttons.forEach((b, j) => b.setAttribute('aria-selected', String(i === j)));
      panels.forEach((pn, j) => { pn.hidden = i !== j; });
    }
    if (tabs.length) select(0);
    return h('section', { class: 'card pg-tabs' }, h('div', { class: 'tabs', role: 'tablist' }, buttons), h('div', { class: 'pg-tab-body' }, panels));
  }

  function dataHead(node, extra) {
    const p = node.props;
    const refreshBtn = p.refreshable
      ? h('button', { class: 'icon-btn', title: 'Refresh', 'aria-label': `Refresh ${p.title || node.name}`, onclick: () => refresh([node.name]) }, svg(icons.redo, 15))
      : null;
    if (p.refreshable && p.autoRefresh > 0) timers.push(setInterval(() => { if (!document.hidden) refresh([node.name]); }, p.autoRefresh * 1000));
    return h('div', { class: 'card-head' }, h('h3', null, p.title || node.name), extra, h('span', { class: 'spacer' }), refreshBtn);
  }

  function renderTable(node) {
    const p = node.props;
    let rows = [];
    let keys = new Map();
    let version = 0;
    let columns = null;
    const count = h('span', { class: 'count-pill' }, '…');
    const host = h('div', { class: 'objects' });
    const table = createTable(host, {
      getRows: () => rows, getDisplay: () => columns, exportName: node.name, selection: p.selection,
      getKey: (r) => keys.get(r), emptyText: 'No rows.',
      onSelect: (selected) => {
        if (selected.length) selections[node.name] = { version, keys: selected };
        else delete selections[node.name];
      },
    });
    disposers.push(() => table.dispose());
    controls[node.name] = {
      update(data) {
        version = data.version;
        columns = data.columns && data.columns.length ? data.columns : null;
        rows = data.rows.map((r) => (r.value !== null && typeof r.value === 'object' && !Array.isArray(r.value) ? r.value : { Value: r.value }));
        keys = new Map(rows.map((r, i) => [r, data.rows[i].key]));
        count.textContent = data.truncated ? `${data.rows.length} of ${data.count}` : String(data.count);
        table.clearSelection();
        table.render();
      },
    };
    table.render();
    return h('section', { class: 'card pg-data' }, dataHead(node, count), host);
  }

  function renderChart(node) {
    const p = node.props;
    const host = h('div', { class: 'pg-chart' });
    const chart = createChart(host, { type: p.chartType, x: p.x, y: [].concat(p.y || []), name: node.name });
    disposers.push(() => chart.dispose());
    controls[node.name] = { update: (data) => chart.update(data) };
    return h('section', { class: 'card pg-data' }, dataHead(node, null), host);
  }

  function renderButton(node) {
    const p = node.props;
    const cls = { primary: 'btn primary', danger: 'btn danger-solid' }[p.variant] || 'btn';
    const button = h('button', { class: `${cls} pg-action`, type: 'button' }, h('span', { class: 'spinner' }), p.text);
    button.addEventListener('click', () => runAction(node, button));
    return h('div', { class: 'pg-button' }, button);
  }

  function renderOutput(node) {
    const consoleEl = h('div', { class: 'console pg-console' });
    const progressEl = h('div', { class: 'progress-list' });
    outputs[node.name] = { console: createConsole(consoleEl, { emptyText: 'Output appears here.' }), progress: createProgress(progressEl) };
    return h('section', { class: 'card pg-output' }, h('div', { class: 'card-head' }, h('h3', null, node.props.title || node.name)), progressEl, consoleEl);
  }

  function renderInput(node) {
    const p = node.props;
    const id = `pg-${node.name}`;
    let control;
    let schedule = null;
    const changed = (value) => {
      inputs[node.name] = value;
      if (p.refresh && p.refresh.length) {
        clearTimeout(schedule);
        schedule = setTimeout(() => refresh([].concat(p.refresh)), node.type === 'textbox' || node.type === 'number' ? 350 : 0);
      }
    };
    switch (node.type) {
      case 'textbox': {
        control = p.multiline ? h('textarea', { class: 'input', id, placeholder: p.placeholder || '' }) : h('input', { class: 'input', id, placeholder: p.placeholder || '' });
        control.value = p.default ?? '';
        control.addEventListener('input', () => changed(control.value));
        break;
      }
      case 'number': {
        control = h('input', { class: 'input', id, type: 'number', step: 'any', min: p.min ?? undefined, max: p.max ?? undefined, value: p.default ?? '' });
        control.addEventListener('input', () => changed(control.value));
        break;
      }
      case 'checkbox': {
        const box = h('input', { type: 'checkbox', id, checked: !!p.default });
        box.addEventListener('change', () => changed(box.checked));
        control = h('label', { class: 'switch' }, box, h('span', { class: 'track' }), h('span', { class: 'hint' }, p.label || node.name));
        break;
      }
      case 'dropdown': {
        const select = h('select', { class: 'input', id });
        const fill = (options) => {
          const current = select.value || p.default || '';
          clear(select).append(...options.map((o) => h('option', { value: o, selected: o === current }, o)));
          if (!options.includes(select.value) && options.length) select.value = options[0];
          inputs[node.name] = select.value;
        };
        fill(p.options || []);
        select.addEventListener('change', () => changed(select.value));
        if (p.refreshable) controls[node.name] = { update: (data) => fill(data.options || []) };
        control = select;
        break;
      }
      default: control = h('span');
    }
    return h('div', { class: 'field pg-field' },
      node.type === 'checkbox' ? null : h('label', { class: 'lbl', for: id }, p.label || node.name),
      control);
  }

  // ---- lifecycle --------------------------------------------------------------
  const onUnload = () => api.closeSessionOnUnload(sid);
  window.addEventListener('pagehide', onUnload);

  return () => {
    closed = true;
    es.close();
    timers.forEach(clearInterval);
    disposers.forEach((d) => d());
    window.removeEventListener('pagehide', onUnload);
    api.closeSession(sid);
  };
}

function confirmDialog(message, action, danger) {
  return new Promise((resolve) => {
    const ok = h('button', { class: danger ? 'btn danger-solid' : 'btn primary', type: 'button' }, action || 'Continue');
    const cancel = h('button', { class: 'btn', type: 'button' }, 'Cancel');
    const dialog = h('dialog', { class: 'pg-dialog' }, h('p', null, message), h('div', { class: 'form-actions' }, cancel, ok));
    const finish = (value) => { dialog.close(); dialog.remove(); resolve(value); };
    ok.addEventListener('click', () => finish(true));
    cancel.addEventListener('click', () => finish(false));
    dialog.addEventListener('cancel', (e) => { e.preventDefault(); finish(false); });
    document.body.append(dialog);
    dialog.showModal();
    ok.focus();
  });
}
