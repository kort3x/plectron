import { h, clear, svg, icons, toast } from './dom.js';
import { api } from './api.js';
import { avatar, relTime, duration, statusPill, formatParams } from './util.js';
import { buildForm } from './form.js';

export async function homeView(main, { tools, info }) {
  const runs = await api.runs(6).catch(() => []);
  const groups = groupTools(tools);
  main.append(h('div', { class: 'page' },
    h('section', { class: 'hero' },
      h('img', { src: 'logo.svg', width: 56, height: 56, alt: '' }),
      h('div', null,
        h('h1', null, 'Your PowerShell toolbox'),
        h('p', null, `${tools.length} tool${tools.length === 1 ? '' : 's'} from `, h('code', null, info.root || ''), '. Pick one, fill in the form, and watch it run.'))),
    runs.length ? [
      h('h2', { class: 'section-title' }, 'Recent runs'),
      h('div', { class: 'card' }, h('div', { class: 'mini-runs', style: { padding: '8px' } }, runs.map(miniRun))),
    ] : null,
    groups.map(([cat, list]) => [
      h('h2', { class: 'section-title' }, cat),
      h('div', { class: 'tool-grid' }, list.map((t) => h('a', { class: 'card tool-card', href: `#/tool/${encodeURIComponent(t.id)}` },
        avatar(t),
        h('div', { style: { minWidth: 0 } }, h('div', { class: 't' }, t.title), h('div', { class: 'd' }, t.parseError ? 'Has errors — open for details' : (t.synopsis || 'No description')))))),
    ]),
    tools.length ? null : h('div', { class: 'card empty-state' }, h('div', { class: 'big' }, '📂'), 'No .ps1 scripts found in this folder.')));
}

export async function toolView(main, id, query, { navigate }) {
  const tool = await api.tool(id);
  let initial = null;
  if (query.get('run')) {
    try { initial = (await api.run(query.get('run'))).parameters; } catch { initial = null; }
  }
  const recent = (await api.runs(50).catch(() => [])).filter((r) => r.toolId === tool.id).slice(0, 6);

  const head = h('div', { class: 'page-head' },
    avatar(tool, true),
    h('div', { class: 'titles' },
      h('div', { class: 'crumbs' }, h('a', { href: '#/' }, 'Tools'), tool.category ? ` / ${tool.category}` : ''),
      h('h1', null, tool.title),
      tool.synopsis ? h('div', { class: 'sub' }, tool.synopsis) : null));

  let body;
  if (tool.parseError) {
    body = h('div', { class: 'alert' }, `This script cannot be run because it has errors:\n\n${tool.parseError}`);
  } else {
    const form = buildForm(tool, initial, async (values) => {
      const run = await api.startRun(tool.id, values);
      navigate(`#/run/${run.id}`);
    });
    body = h('div', { class: 'card' }, h('div', { class: 'card-body' },
      tool.requiresDesktop ? h('div', { class: 'alert warn', style: { marginBottom: '16px' } }, 'Requires Windows PowerShell (Desktop edition).') : null,
      initial ? h('div', { class: 'alert warn', style: { marginBottom: '16px' } }, 'Prefilled from a previous run. Secret values have to be entered again.') : null,
      form.el));
    setTimeout(() => form.focus(), 0);
  }

  const side = h('div', { class: 'card side-card' },
    tool.description ? [h('h3', null, 'About'), h('div', { class: 'prose' }, tool.description)] : null,
    tool.examples && tool.examples.length ? [h('h3', null, 'Examples'), tool.examples.map((e) => h('pre', null, e))] : null,
    h('h3', null, 'Recent runs'),
    recent.length ? h('div', { class: 'mini-runs' }, recent.map(miniRun)) : h('div', { class: 'hint' }, 'No runs yet.'));

  main.append(h('div', { class: 'page' }, head, h('div', { class: 'tool-layout' }, body, side)));
}

export async function historyView(main, { tools, navigate }) {
  let runs = await api.runs(200);
  const toolFilter = h('select', { class: 'input', 'aria-label': 'Filter by tool' },
    h('option', { value: '' }, 'All tools'),
    [...new Set(runs.map((r) => r.toolId))].map((t) => h('option', { value: t }, (tools.find((x) => x.id === t) || { title: t }).title)));
  const statusFilter = h('select', { class: 'input', 'aria-label': 'Filter by status' },
    h('option', { value: '' }, 'Any status'), ['running', 'succeeded', 'failed', 'cancelled', 'abandoned'].map((s) => h('option', { value: s }, s)));
  const host = h('div', { class: 'card' });
  toolFilter.addEventListener('change', render);
  statusFilter.addEventListener('change', render);

  function render() {
    clear(host);
    const list = runs.filter((r) => (!toolFilter.value || r.toolId === toolFilter.value) && (!statusFilter.value || r.status === statusFilter.value));
    if (!list.length) { host.append(h('div', { class: 'empty-state' }, h('div', { class: 'big' }, '🕘'), 'No runs to show.')); return; }
    host.append(h('div', { class: 'table-wrap', style: { maxHeight: 'none' } }, h('table', { class: 'grid history-table' },
      h('thead', null, h('tr', null, ['Status', 'Tool', 'Started', 'Duration', 'Parameters', ''].map((c) => h('th', { style: { cursor: 'default' } }, c)))),
      h('tbody', null, list.map((r) => {
        const tr = h('tr', { onclick: () => navigate(`#/run/${r.id}`) },
          h('td', null, statusPill(r.status)),
          h('td', null, h('span', { style: { display: 'inline-flex', gap: '8px', alignItems: 'center' } }, avatar({ id: r.toolId, title: r.toolTitle, icon: (tools.find((t) => t.id === r.toolId) || {}).icon }), r.toolTitle)),
          h('td', { title: new Date(r.startedAt).toLocaleString() }, relTime(r.startedAt)),
          h('td', null, duration(r.durationMs)),
          h('td', { class: 'params', title: formatParams(r.parameters) }, formatParams(r.parameters)),
          h('td', null,
            h('button', { class: 'btn ghost sm', title: 'Run again', 'aria-label': 'Run again', onclick: (e) => { e.stopPropagation(); navigate(`#/tool/${encodeURIComponent(r.toolId)}?run=${r.id}`); } }, svg(icons.redo, 14)),
            r.status === 'running' ? null : h('button', {
              class: 'btn ghost sm', title: 'Delete', 'aria-label': 'Delete run',
              onclick: async (e) => {
                e.stopPropagation();
                try { await api.deleteRun(r.id); runs = runs.filter((x) => x.id !== r.id); render(); } catch (err) { toast(err.message); }
              },
            }, svg(icons.trash, 14))));
        return tr;
      })))));
  }

  main.append(h('div', { class: 'page' },
    h('div', { class: 'page-head' }, h('div', { class: 'titles' }, h('h1', null, 'Run history'), h('div', { class: 'sub' }, `${runs.length} run${runs.length === 1 ? '' : 's'} kept on disk`))),
    h('div', { class: 'history-filter' }, toolFilter, statusFilter),
    host));
  render();

  const poll = setInterval(async () => {
    if (!runs.some((r) => r.status === 'running')) return;
    try { runs = await api.runs(200); render(); } catch { /* keep the old list */ }
  }, 2000);
  return () => clearInterval(poll);
}

function miniRun(r) {
  return h('a', { class: 'mini-run', href: `#/run/${r.id}` },
    h('span', { class: `dot ${r.status}`, title: r.status }), r.toolTitle,
    h('span', { class: 'when' }, relTime(r.startedAt)));
}

export function groupTools(tools) {
  const map = new Map();
  for (const t of tools) {
    const c = t.category || 'Tools';
    if (!map.has(c)) map.set(c, []);
    map.get(c).push(t);
  }
  return [...map.entries()].sort(([a], [b]) => (a === 'Tools' ? 1 : b === 'Tools' ? -1 : a.localeCompare(b)));
}
