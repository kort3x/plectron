import { h, clear } from './dom.js';
import { api, AuthError } from './api.js';
import { avatar, store, logoUrl } from './util.js';
import { homeView, toolView, historyView, groupTools } from './views.js';
import { runView } from './run.js';

const main = document.getElementById('main');
const list = document.getElementById('tool-list');
const search = document.getElementById('search');
const appEl = document.querySelector('.app');
const ctx = { tools: [], info: {}, navigate };
let cleanup = null;
let renderToken = 0;

function navigate(hash) {
  if (location.hash === hash) route();
  else location.hash = hash;
}

async function loadTools() {
  ctx.tools = await api.tools();
  renderSidebar();
}

function renderSidebar() {
  const q = search.value.trim().toLowerCase();
  const current = decodeURIComponent((location.hash.match(/^#\/tool\/([^?]+)/) || [])[1] || '');
  const tools = ctx.tools.filter((t) => !q || [t.title, t.synopsis, t.category, t.id].some((s) => s && s.toLowerCase().includes(q)));
  clear(list);
  if (!tools.length) { list.append(h('div', { class: 'empty-list' }, q ? 'No matching tools.' : 'No tools found.')); return; }
  for (const [cat, items] of groupTools(tools)) {
    list.append(h('div', { class: 'tool-group' },
      h('h4', null, cat),
      items.map((t) => h('a', { class: `tool-link${t.id === current ? ' active' : ''}`, href: `#/tool/${encodeURIComponent(t.id)}`, title: t.synopsis || t.title },
        avatar(t), h('span', { class: 'name' }, t.title), t.parseError ? h('span', { class: 'warn-dot', title: 'Has errors' }) : null))));
  }
}

async function route() {
  const token = ++renderToken;
  if (cleanup) { cleanup(); cleanup = null; }
  appEl.classList.remove('nav-open');
  const [path, queryString] = location.hash.replace(/^#/, '').split('?');
  const query = new URLSearchParams(queryString || '');
  const parts = path.split('/').filter(Boolean).map(decodeURIComponent);
  document.querySelectorAll('[data-nav]').forEach((a) => a.classList.toggle('active', a.dataset.nav === parts[0]));
  renderSidebar();

  const host = h('div');
  try {
    let result;
    const single = ctx.info.single && ctx.tools.length === 1 ? ctx.tools[0].id : null;
    if (parts[0] === 'tool' && parts[1]) result = await toolView(host, parts[1], query, ctx);
    else if (single && parts[0] !== 'run' && parts[0] !== 'history') result = await toolView(host, single, query, ctx);
    else if (parts[0] === 'run' && parts[1]) result = await runView(host, parts[1], ctx);
    else if (parts[0] === 'history') result = await historyView(host, ctx);
    else result = await homeView(host, ctx);
    if (token !== renderToken) { if (typeof result === 'function') result(); return; }
    if (typeof result === 'function') cleanup = result;
  } catch (err) {
    if (token !== renderToken) return;
    clear(host).append(errorPage(err));
  }
  clear(main).append(host);
  main.scrollTop = 0;
}

function errorPage(err) {
  return h('div', { class: 'page' }, h('div', { class: 'card empty-state' },
    h('div', { class: 'big' }, err instanceof AuthError ? '🔒' : '⚠️'),
    h('p', null, err.message),
    err instanceof AuthError ? null : h('a', { class: 'btn', href: '#/' }, 'Back to tools')));
}

// Project branding from plectron.psd1: title, logo and accent colour.
function applyBranding(info) {
  const title = info.title || 'Plectron';
  document.title = title;
  document.querySelector('.brand span').textContent = title;
  document.querySelector('.brand img').src = logoUrl(info);
  document.querySelector('link[rel="icon"]').href = logoUrl(info);
  if (info.accent) {
    const root = document.documentElement.style;
    root.setProperty('--accent', info.accent);
    root.setProperty('--accent-soft', `color-mix(in srgb, ${info.accent} 16%, transparent)`);
  }
}

function applyTheme(theme) {
  if (theme) document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
}

function setupChrome() {
  applyTheme(store.get('theme', null));
  document.getElementById('theme-btn').addEventListener('click', () => {
    const dark = document.documentElement.dataset.theme
      ? document.documentElement.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    const next = dark ? 'light' : 'dark';
    applyTheme(next);
    store.set('theme', next);
  });
  document.getElementById('menu-btn').addEventListener('click', () => appEl.classList.toggle('nav-open'));
  search.addEventListener('input', renderSidebar);
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const first = list.querySelector('.tool-link');
      if (first) { location.hash = first.getAttribute('href'); search.blur(); }
    } else if (e.key === 'Escape') { search.value = ''; renderSidebar(); search.blur(); }
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) { e.preventDefault(); search.focus(); }
  });
  window.addEventListener('focus', () => loadTools().catch(() => {}));
  window.addEventListener('hashchange', route);
}

async function start() {
  setupChrome();
  try {
    ctx.info = await api.info();
    applyBranding(ctx.info);
    await loadTools();
    appEl.classList.toggle('single', !!ctx.info.single);
    const engine = (ctx.info.engine || '').split(/[\\/]/).pop();
    document.getElementById('sidebar-foot').textContent = `v${ctx.info.version} · ${engine} · ${ctx.info.root}`;
    document.getElementById('sidebar-foot').title = ctx.info.root;
  } catch (err) {
    clear(main).append(errorPage(err));
    return;
  }
  route();
}

start();
