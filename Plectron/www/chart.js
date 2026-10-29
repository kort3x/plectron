import { h, clear } from './dom.js';

// Bar and line charts as inline SVG (dataviz method: fixed categorical order,
// one axis, thin marks, recessive 1px grid, hover tooltips, a legend for two or
// more series, and a table view as relief for low-contrast hues).

const NS = 'http://www.w3.org/2000/svg';
const MAX_SERIES = 4;
const HEIGHT = 260;
const M = { top: 14, right: 14, bottom: 30, left: 48 };

function s(tag, attrs) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v !== null && v !== undefined) el.setAttribute(k, v);
  return el;
}

function compact(n) {
  const a = Math.abs(n);
  if (a >= 1e9) return `${+(n / 1e9).toFixed(1)}B`;
  if (a >= 1e6) return `${+(n / 1e6).toFixed(1)}M`;
  if (a >= 1e3) return `${+(n / 1e3).toFixed(1)}K`;
  return `${+n.toFixed(2)}`;
}

function niceTicks(min, max, count = 4) {
  if (min === max) max = min + 1;
  const raw = (max - min) / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((f) => f * mag).find((f) => f >= raw);
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const ticks = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(+v.toFixed(10));
  return ticks;
}

export function createChart(host, { type = 'bar', x, y = [], name }) {
  const series = y.slice(0, MAX_SERIES);
  const wrap = h('div', { class: 'chart' });
  const plot = h('div', { class: 'chart-plot' });
  const tip = h('div', { class: 'chart-tip', role: 'status', hidden: true });
  const tableBox = h('div', { class: 'chart-table', hidden: true });
  const legend = series.length > 1
    ? h('div', { class: 'chart-legend' }, series.map((n, i) => h('span', null, h('i', { style: { background: `var(--series-${i + 1})` } }), n)))
    : null;
  const toggle = h('button', { class: 'btn ghost sm', type: 'button', 'aria-pressed': 'false' }, 'Table');
  toggle.addEventListener('click', () => {
    const show = toggle.getAttribute('aria-pressed') !== 'true';
    toggle.setAttribute('aria-pressed', String(show));
    tableBox.hidden = !show;
    plot.hidden = show;
  });
  wrap.append(h('div', { class: 'chart-bar' }, legend, h('span', { class: 'spacer' }), toggle), plot, tableBox, tip);
  host.append(wrap);
  if (y.length > MAX_SERIES) wrap.append(h('div', { class: 'hint' }, `Showing the first ${MAX_SERIES} of ${y.length} series.`));

  let points = [];
  const observer = new ResizeObserver(() => draw());
  observer.observe(plot);

  function draw() {
    clear(plot);
    const width = plot.clientWidth || 600;
    if (!points.length) { plot.append(h('div', { class: 'empty-state' }, 'No data.')); return; }
    const values = points.flatMap((p) => series.map((n) => p.y[n])).filter((v) => typeof v === 'number');
    const ticks = niceTicks(Math.min(0, ...values), Math.max(0, ...values));
    const lo = ticks[0];
    const hi = ticks[ticks.length - 1];
    const iw = width - M.left - M.right;
    const ih = HEIGHT - M.top - M.bottom;
    const yPos = (v) => M.top + ih - ((v - lo) / (hi - lo)) * ih;
    const band = iw / points.length;
    const xMid = (i) => M.left + band * i + band / 2;

    const svg = s('svg', { width, height: HEIGHT, viewBox: `0 0 ${width} ${HEIGHT}`, role: 'img', 'aria-label': `${type} chart of ${series.join(', ')} by ${x}` });
    for (const t of ticks) {
      svg.append(s('line', { x1: M.left, x2: width - M.right, y1: yPos(t), y2: yPos(t), class: t === 0 ? 'axis' : 'grid' }));
      const label = s('text', { x: M.left - 8, y: yPos(t) + 4, 'text-anchor': 'end', class: 'tick' });
      label.textContent = compact(t);
      svg.append(label);
    }
    // Skip x labels when they would collide.
    const every = Math.max(1, Math.ceil(points.length / Math.max(1, Math.floor(iw / 64))));
    points.forEach((p, i) => {
      if (i % every) return;
      const label = s('text', { x: xMid(i), y: HEIGHT - 10, 'text-anchor': 'middle', class: 'tick' });
      label.textContent = p.x.length > 12 ? `${p.x.slice(0, 11)}…` : p.x;
      svg.append(label);
    });

    if (type === 'line') drawLines(svg, yPos, xMid, band);
    else drawBars(svg, yPos, band, ih);
    plot.append(svg);
  }

  function drawBars(svg, yPos, band) {
    const groupWidth = Math.min(band * 0.72, 28 * series.length + 2 * (series.length - 1));
    const barWidth = (groupWidth - 2 * (series.length - 1)) / series.length;
    const base = yPos(0);
    points.forEach((p, i) => {
      const start = M.left + band * i + (band - groupWidth) / 2;
      series.forEach((n, j) => {
        const v = p.y[n];
        if (typeof v !== 'number') return;
        const x0 = start + j * (barWidth + 2);
        const top = yPos(v);
        const hgt = Math.abs(base - top);
        const r = Math.min(4, barWidth / 2, hgt);
        const up = v >= 0;
        const y0 = up ? top : base;
        // Rounded at the data end, square at the baseline.
        const d = up
          ? `M${x0},${base}V${y0 + r}Q${x0},${y0} ${x0 + r},${y0}H${x0 + barWidth - r}Q${x0 + barWidth},${y0} ${x0 + barWidth},${y0 + r}V${base}Z`
          : `M${x0},${base}V${base + hgt - r}Q${x0},${base + hgt} ${x0 + r},${base + hgt}H${x0 + barWidth - r}Q${x0 + barWidth},${base + hgt} ${x0 + barWidth},${base + hgt - r}V${base}Z`;
        const bar = s('path', { d, class: 'mark', style: `fill: var(--series-${j + 1})` });
        // Hit target wider and taller than the mark.
        const hit = s('rect', { x: start - 2, y: M.top, width: groupWidth + 4, height: HEIGHT - M.top - M.bottom, class: 'hit' });
        const show = (e) => showTip(e, p);
        hit.addEventListener('mousemove', show);
        hit.addEventListener('mouseleave', hideTip);
        svg.append(bar, hit);
      });
    });
  }

  function drawLines(svg, yPos, xMid, band) {
    series.forEach((n, j) => {
      const pts = points.map((p, i) => (typeof p.y[n] === 'number' ? [xMid(i), yPos(p.y[n])] : null));
      let d = '';
      pts.forEach((pt, i) => { if (pt) d += `${d && pts[i - 1] ? 'L' : 'M'}${pt[0]},${pt[1]}`; });
      svg.append(s('path', { d, class: 'line-mark', style: `stroke: var(--series-${j + 1})` }));
      if (points.length <= 40) pts.forEach((pt) => { if (pt) svg.append(s('circle', { cx: pt[0], cy: pt[1], r: 4, class: 'dot', style: `fill: var(--series-${j + 1})` })); });
    });
    const cross = s('line', { y1: M.top, y2: HEIGHT - M.bottom, class: 'crosshair', visibility: 'hidden' });
    svg.append(cross);
    const overlay = s('rect', { x: M.left, y: M.top, width: band * points.length, height: HEIGHT - M.top - M.bottom, class: 'hit' });
    overlay.addEventListener('mousemove', (e) => {
      const box = svg.getBoundingClientRect();
      const i = Math.max(0, Math.min(points.length - 1, Math.floor((e.clientX - box.left - M.left) / band)));
      cross.setAttribute('x1', xMid(i));
      cross.setAttribute('x2', xMid(i));
      cross.setAttribute('visibility', 'visible');
      showTip(e, points[i]);
    });
    overlay.addEventListener('mouseleave', () => { cross.setAttribute('visibility', 'hidden'); hideTip(); });
    svg.append(overlay);
  }

  function showTip(e, p) {
    clear(tip).append(h('div', { class: 'tip-x' }, p.x),
      series.map((n, j) => h('div', { class: 'tip-row' },
        h('i', { style: { background: `var(--series-${j + 1})` } }), h('span', null, n), h('b', null, p.y[n] === null || p.y[n] === undefined ? '–' : p.y[n].toLocaleString()))));
    tip.hidden = false;
    const box = wrap.getBoundingClientRect();
    const left = Math.min(e.clientX - box.left + 14, box.width - tip.offsetWidth - 4);
    tip.style.left = `${Math.max(4, left)}px`;
    tip.style.top = `${e.clientY - box.top + 14}px`;
  }
  function hideTip() { tip.hidden = true; }

  function drawTable() {
    clear(tableBox).append(h('table', { class: 'grid' },
      h('thead', null, h('tr', null, h('th', null, x), series.map((n) => h('th', null, n)))),
      h('tbody', null, points.map((p) => h('tr', null, h('td', null, p.x), series.map((n) => h('td', { class: 'num' }, p.y[n] ?? '')))))));
  }

  return {
    update(data) { points = data.points || []; draw(); drawTable(); },
    dispose() { observer.disconnect(); },
  };
}
