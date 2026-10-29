import { h } from './dom.js';

// Collapsible JSON tree for nested output objects.
export function jsonTree(value, { open = 1 } = {}) {
  return h('div', { class: 'tree' }, node(null, value, 0, open));
}

function node(key, value, depth, open) {
  const label = key === null ? null : [h('span', { class: 'k' }, key), ': '];
  if (value === null || value === undefined) return h('div', { class: 'kv' }, label, h('span', { class: 'z' }, 'null'));
  if (typeof value !== 'object') return h('div', { class: 'kv' }, label, leaf(value));

  const isArr = Array.isArray(value);
  const entries = isArr ? value.map((v, i) => [String(i), v]) : Object.entries(value);
  const meta = isArr ? `[${entries.length}]` : `{${entries.length}}`;
  if (entries.length === 0) return h('div', { class: 'kv' }, label, h('span', { class: 'meta' }, isArr ? '[]' : '{}'));
  const d = h('details', { open: depth < open }, h('summary', null, label, h('span', { class: 'meta' }, meta)));
  let rendered = false;
  const fill = () => {
    if (rendered) return;
    rendered = true;
    for (const [k, v] of entries) d.append(node(k, v, depth + 1, open));
  };
  if (depth < open) fill();
  else d.addEventListener('toggle', fill);
  return d;
}

function leaf(v) {
  if (typeof v === 'string') return h('span', { class: 's' }, JSON.stringify(v));
  if (typeof v === 'number') return h('span', { class: 'n' }, String(v));
  if (typeof v === 'boolean') return h('span', { class: 'b' }, String(v));
  return h('span', null, String(v));
}

export function summarize(value, max = 120) {
  if (value === null || value === undefined) return 'null';
  if (typeof value !== 'object') return String(value);
  const text = Array.isArray(value)
    ? `[${value.map((v) => summarize(v, 30)).join(', ')}]`
    : `{ ${Object.entries(value).map(([k, v]) => `${k}: ${typeof v === 'object' && v !== null ? (Array.isArray(v) ? `[${v.length}]` : '{…}') : v}`).join(', ')} }`;
  return text.length > max ? text.slice(0, max - 1) + '…' : text;
}
