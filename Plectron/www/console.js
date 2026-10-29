import { h, clear } from './dom.js';
import { clockTime, duration } from './util.js';
import { jsonTree, summarize } from './tree.js';

// Console lines and progress bars for streamed PowerShell events. Used by the
// run view and by custom pages' output panels.

const CONSOLE_LIMIT = 5000;
const HOST_COLORS = {
  Black: '#5c6370', DarkBlue: '#4a7fd6', DarkGreen: '#3fae6a', DarkCyan: '#3aa7b5', DarkRed: '#d75f5f',
  DarkMagenta: '#b76bd6', DarkYellow: '#c9a227', Gray: '#b5b9c9', DarkGray: '#7f8499', Blue: '#7cb4ff',
  Green: '#7ee2a0', Cyan: '#7fe3ef', Red: '#ff8f97', Magenta: '#f39cff', Yellow: '#ffe17a', White: '#ffffff',
};

// A console: append() takes protocol events, keeps the view pinned to the bottom
// while the user hasn't scrolled up, and caps the number of lines.
export function createConsole(el, { emptyText = 'Waiting for output…' } = {}) {
  const empty = h('div', { class: 'console-empty' }, emptyText);
  el.append(empty);
  let count = 0;
  return {
    get count() { return count; },
    append(events) {
      const stick = el.scrollTop + el.clientHeight >= el.scrollHeight - 30;
      const frag = document.createDocumentFragment();
      for (const ev of events) {
        const line = renderLine(ev);
        if (line) { frag.append(line); count++; }
      }
      if (!frag.childNodes.length) return 0;
      empty.remove();
      el.append(frag);
      while (el.childElementCount > CONSOLE_LIMIT) el.firstElementChild.remove();
      if (stick) el.scrollTop = el.scrollHeight;
      return frag.childNodes.length;
    },
    clear() { clear(el).append(empty); count = 0; },
    text() {
      return [...el.querySelectorAll('.line')].filter((l) => l.offsetParent !== null).map((l) => l.lastChild.textContent).join('\n');
    },
  };
}

// Live progress bars keyed by ActivityId, children nested under their parent.
export function createProgress(host) {
  const progress = new Map();
  const progressList = host;
  function update(p) {
    if (p.completed) progress.delete(p.id);
    else progress.set(p.id, p);
    renderProgress();
  }
  function renderProgress() {
    clear(progressList);
    // Depth-first: each record directly followed by its children.
    const ordered = [];
    const visit = (parentId) => {
      for (const p of [...progress.values()].filter((x) => x.parentId === parentId).sort((a, b) => a.id - b.id)) {
        ordered.push(p);
        visit(p.id);
      }
    };
    const roots = new Set([...progress.values()].filter((p) => !progress.has(p.parentId)).map((p) => p.parentId));
    for (const r of [...roots].sort((a, b) => a - b)) visit(r);
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

  return { update, clear() { progress.clear(); renderProgress(); } };
}

export function renderLine(ev) {
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

