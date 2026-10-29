import { h, clear, svg, icons } from './dom.js';
import { download } from './util.js';
import { jsonTree, summarize } from './tree.js';

// Sortable, filterable object table with column picker, CSV/JSON export and
// row details. With selection 'single' or 'multiple', rows get checkboxes and
// onSelect receives the selected rows' keys (from getKey).
export function createTable(host, { getRows, getDisplay = () => null, exportName = 'objects', selection = 'none',
  getKey = null, onSelect = null, emptyText = 'No objects were written to the pipeline.' }) {
  const selected = new Set();
  let rowRefs = [];
  let headCheck = null;
  let sortKey = null;
  let sortDir = 1;
  let filter = '';
  let hidden = null;
  let openRow = null;

  const filterInput = h('input', { class: 'input', type: 'search', placeholder: 'Filter rows', 'aria-label': 'Filter rows' });
  filterInput.addEventListener('input', () => { filter = filterInput.value.toLowerCase(); render(); });
  const menu = h('div', { class: 'menu', hidden: true });
  const colsBtn = h('button', { class: 'btn sm', onclick: (e) => { e.stopPropagation(); menu.hidden = !menu.hidden; } }, svg(icons.columns, 14), 'Columns');
  const closeMenu = (e) => { if (!menu.contains(e.target)) menu.hidden = true; };
  document.addEventListener('click', closeMenu);
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
      tableWrap.append(h('div', { class: 'empty-state' }, h('div', { class: 'big' }, '∅'), emptyText));
      return;
    }
    const selectable = selection !== 'none' && getKey;
    const visibleKeys = selectable ? list.slice(0, 2000).map(getKey) : [];
    headCheck = null;
    rowRefs = [];
    if (selectable && selection === 'multiple') {
      headCheck = h('input', { type: 'checkbox', 'aria-label': 'Select all rows', checked: visibleKeys.length > 0 && visibleKeys.every((k) => selected.has(k)) });
      headCheck.addEventListener('change', () => {
        for (const k of visibleKeys) { if (headCheck.checked) selected.add(k); else selected.delete(k); }
        changed();
      });
    }
    const thead = h('thead', null, h('tr', null, selectable ? h('th', { class: 'sel' }, headCheck) : null, cols.map((c) => h('th', {
      'aria-sort': sortKey === c ? (sortDir > 0 ? 'ascending' : 'descending') : 'none',
      onclick: () => {
        if (sortKey !== c) { sortKey = c; sortDir = 1; } else if (sortDir === 1) sortDir = -1; else sortKey = null;
        render();
      },
    }, c, sortKey === c ? h('span', { class: 'arrow' }, sortDir > 0 ? '▲' : '▼') : null))));
    const tbody = h('tbody');
    for (const r of list.slice(0, 2000)) {
      const key = selectable ? getKey(r) : null;
      let check = null;
      if (selectable) {
        check = h('input', { type: selection === 'single' ? 'radio' : 'checkbox', name: `sel-${exportName}`, 'aria-label': 'Select row', checked: selected.has(key) });
        check.addEventListener('click', (e) => e.stopPropagation());
        check.addEventListener('change', () => {
          if (selection === 'single') selected.clear();
          if (check.checked) selected.add(key); else selected.delete(key);
          changed();
        });
      }
      const tr = h('tr', { class: selectable && selected.has(key) ? 'selected' : null }, selectable ? h('td', { class: 'sel' }, check) : null, cols.map((c) => renderCell(r[c])));
      if (selectable) rowRefs.push({ key, tr, check });
      tr.addEventListener('click', () => {
        if (openRow && openRow.owner === tr) { openRow.el.remove(); openRow = null; return; }
        if (openRow) openRow.el.remove();
        const detail = h('tr', { class: 'detail' }, h('td', { colspan: String(cols.length + (selectable ? 1 : 0)) }, jsonTree(r, { open: 2 })));
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

  // Update the rendered rows in place (a full render would replace the checkboxes being clicked).
  function changed() {
    for (const ref of rowRefs) {
      ref.check.checked = selected.has(ref.key);
      ref.tr.classList.toggle('selected', selected.has(ref.key));
    }
    if (headCheck) headCheck.checked = rowRefs.length > 0 && rowRefs.every((ref) => selected.has(ref.key));
    if (onSelect) onSelect([...selected]);
  }

  return {
    render,
    selected: () => [...selected],
    clearSelection() { selected.clear(); if (onSelect) onSelect([]); },
    setSelection(keys) { selected.clear(); for (const k of keys) selected.add(k); changed(); },
    dispose: () => document.removeEventListener('click', closeMenu),
  };
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
