import { h, svg, icons } from './dom.js';

export function avatar(tool, large = false) {
  const key = tool.id || tool.toolId || '';
  let hash = 0;
  for (const c of key) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
  const hue = hash % 360;
  const style = { background: `linear-gradient(135deg, hsl(${hue} 70% 58%), hsl(${(hue + 40) % 360} 70% 48%))` };
  const cls = large ? 'avatar lg' : 'avatar';
  const icon = tool.icon && icons[String(tool.icon).toLowerCase()];
  if (icon) return h('span', { class: cls, style, 'aria-hidden': 'true' }, svg(icon, large ? 26 : 16));
  if (tool.icon && [...String(tool.icon)].length <= 2) return h('span', { class: cls, style, 'aria-hidden': 'true' }, tool.icon);
  const title = tool.title || tool.toolTitle || key || '?';
  const letters = title.replace(/[^A-Za-z0-9]/g, ' ').trim().split(/\s+|(?=[A-Z][a-z])/).filter(Boolean);
  const initials = (letters.length > 1 ? letters[0][0] + letters[1][0] : title.slice(0, 2)).toUpperCase();
  return h('span', { class: cls, style, 'aria-hidden': 'true' }, initials);
}

export function logoUrl(info) {
  return info && info.logo ? '/api/logo' : 'logo.svg';
}

export function relTime(iso) {
  if (!iso) return '';
  const diff = (Date.now() - new Date(iso).getTime()) / 1000;
  if (diff < 45) return 'just now';
  if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.round(diff / 3600)} h ago`;
  if (diff < 86400 * 7) return `${Math.round(diff / 86400)} d ago`;
  return new Date(iso).toLocaleDateString();
}

export function duration(ms) {
  if (ms === null || ms === undefined) return '';
  if (ms < 1000) return `${ms} ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)} s`;
  const m = Math.floor(s / 60);
  return `${m}m ${Math.round(s % 60)}s`;
}

export function clockTime(iso) {
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export function statusPill(status) {
  return h('span', { class: `status ${status}` }, status);
}

export function formatParams(params) {
  if (!params) return '';
  return Object.entries(params).map(([k, v]) => `-${k} ${short(v)}`).join(' ');
}

export function short(v) {
  if (v === true) return '$true';
  if (v === false) return '$false';
  if (Array.isArray(v)) return v.map(short).join(',');
  if (v && typeof v === 'object') return v.user ? `${v.user}/***` : JSON.stringify(v);
  const s = String(v);
  return /\s/.test(s) ? `'${s}'` : s;
}

export function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = h('a', { href: url, download: name });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(`plectron.${key}`); return v === null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(`plectron.${key}`, JSON.stringify(value)); } catch { /* storage unavailable */ }
  },
};
