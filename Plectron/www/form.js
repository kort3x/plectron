import { h, append, clear, svg, icons } from './dom.js';

// Builds a form from a tool schema. Returns { el, focus }.
// onSubmit receives the collected parameter values.
export function buildForm(tool, initial, onSubmit) {
  const sets = tool.parameterSets || [];
  let currentSet = sets.length ? (initialSet(tool, initial) || tool.defaultParameterSet || sets[0]) : null;
  const fields = tool.parameters.map((p) => createField(p, initial ? initial[p.name] : undefined));

  const fieldsHost = h('div', { class: 'form' });
  const submit = h('button', { class: 'btn primary', type: 'submit' }, svg(icons.play, 15), 'Run');
  const note = h('span', { class: 'note' });
  const form = h('form', { class: 'form', novalidate: true });

  let setSwitch = null;
  if (sets.length > 1) {
    setSwitch = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Parameter set' },
      sets.map((s) => h('button', {
        type: 'button', 'aria-pressed': String(s === currentSet),
        onclick: () => { currentSet = s; renderFields(); },
      }, s)));
  }

  function visible(p) {
    return !currentSet || p.sets.length === 0 || p.sets.includes(currentSet);
  }
  function required(p) {
    return p.mandatoryIn.includes('__AllParameterSets') || (currentSet && p.mandatoryIn.includes(currentSet));
  }

  function renderFields() {
    if (setSwitch) for (const b of setSwitch.children) b.setAttribute('aria-pressed', String(b.textContent === currentSet));
    clear(fieldsHost);
    for (const f of fields) {
      if (!visible(f.param)) continue;
      f.setRequired(required(f.param));
      fieldsHost.append(f.el);
    }
    if (!fieldsHost.children.length) fieldsHost.append(h('p', { class: 'hint' }, 'This tool takes no parameters.'));
  }

  append(form, [setSwitch, fieldsHost, h('div', { class: 'form-actions' }, submit, note)]);
  renderFields();

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    let firstBad = null;
    const values = {};
    for (const f of fields) {
      if (!visible(f.param)) continue;
      const v = f.value();
      const problem = validate(f.param, v, required(f.param));
      f.setError(problem);
      if (problem && !firstBad) firstBad = f;
      if (!problem && v !== undefined) values[f.param.name] = v;
    }
    if (firstBad) { firstBad.focus(); return; }
    submit.disabled = true;
    note.textContent = 'Starting…';
    try {
      await onSubmit(values);
      note.textContent = '';
    } catch (err) {
      note.textContent = err.message;
    } finally {
      submit.disabled = false;
    }
  });

  return { el: form, focus: () => fields.find((f) => visible(f.param))?.focus() };
}

function initialSet(tool, initial) {
  if (!initial) return null;
  const used = Object.keys(initial);
  return (tool.parameterSets || []).find((s) => tool.parameters.some((p) => p.sets.includes(s) && used.includes(p.name)));
}

function isEmpty(v) {
  return v === undefined || v === null || v === '' || (Array.isArray(v) && v.length === 0);
}

function validate(p, v, isRequired) {
  if (p.widget === 'credential') {
    if (isRequired && (!v || !v.user)) return 'A user name is required.';
    return null;
  }
  if (isEmpty(v)) return isRequired && p.widget !== 'toggle' ? 'This field is required.' : null;
  if (p.widget === 'number') {
    if (typeof v !== 'number' || Number.isNaN(v)) return 'Enter a number.';
    if (p.integer && !Number.isInteger(v)) return 'Enter a whole number.';
    if (p.min !== null && v < p.min) return `Must be at least ${p.min}.`;
    if (p.max !== null && v > p.max) return `Must be at most ${p.max}.`;
  }
  if (p.pattern) {
    let re = null;
    try { re = new RegExp(p.pattern, 'i'); } catch { re = null; }
    const items = Array.isArray(v) ? v : [v];
    if (re && items.some((x) => !re.test(String(x)))) return `Must match ${p.pattern}`;
  }
  return null;
}

function createField(p, initialValue) {
  const id = `f-${p.name}`;
  const start = initialValue !== undefined && initialValue !== '***' ? initialValue : p.default;
  const widget = WIDGETS[p.widget] || WIDGETS.text;
  const control = widget(p, id, start);
  const reqMark = h('span', { class: 'req', 'aria-hidden': 'true' }, '*');
  const err = h('div', { class: 'err', role: 'alert' });
  const help = p.help || p.helpMessage;
  const hints = [];
  if (help) hints.push(help);
  if (p.default === null && p.defaultText) hints.push(`Default: ${p.defaultText}`);
  const el = h('div', { class: 'field' },
    h('label', { class: 'lbl', for: id }, p.label || p.name, reqMark, h('span', { class: 'type' }, p.type)),
    control.el,
    hints.length ? h('div', { class: 'hint' }, hints.join(' · ')) : null,
    err);
  return {
    param: p,
    el,
    value: control.value,
    focus: () => (el.querySelector('input, select, textarea, button') || el).focus(),
    setRequired(r) { reqMark.hidden = !r || p.widget === 'toggle'; },
    setError(msg) { err.textContent = msg || ''; el.classList.toggle('invalid', !!msg); },
  };
}

function textInput(p, id, start, type = 'text') {
  const input = h('input', { class: 'input', id, type, value: start ?? '', placeholder: p.placeholder || '', autocomplete: type === 'password' ? 'new-password' : 'off' });
  return { el: input, value: () => input.value };
}

const WIDGETS = {
  text: (p, id, start) => textInput(p, id, start),
  password: (p, id) => textInput(p, id, '', 'password'),
  color: (p, id, start) => textInput(p, id, start || '#6355e8', 'color'),
  file: (p, id, start) => textInput(p, id, start),
  textarea(p, id, start) {
    const t = h('textarea', { class: 'input', id, placeholder: p.placeholder || '' });
    t.value = start ?? '';
    return { el: t, value: () => t.value };
  },
  number(p, id, start) {
    const input = h('input', { class: 'input', id, type: 'number', value: start ?? '', step: p.integer ? '1' : 'any', min: p.min ?? undefined, max: p.max ?? undefined, placeholder: p.placeholder || '' });
    return { el: input, value: () => (input.value === '' ? '' : Number(input.value)) };
  },
  toggle(p, id, start) {
    const input = h('input', { type: 'checkbox', id, checked: start === true });
    return { el: h('label', { class: 'switch' }, input, h('span', { class: 'track' }), h('span', { class: 'hint' }, p.type === 'switch' ? `-${p.name}` : '$true / $false')), value: () => input.checked };
  },
  datetime(p, id, start) {
    const input = h('input', { class: 'input', id, type: 'datetime-local', value: start ? String(start).slice(0, 16) : '' });
    return { el: input, value: () => input.value };
  },
  select(p, id, start) {
    const sel = h('select', { class: 'input', id },
      h('option', { value: '' }, p.mandatory ? 'Choose…' : '(default)'),
      (p.options || []).map((o) => h('option', { value: o, selected: o === start }, o)));
    return { el: sel, value: () => sel.value };
  },
  multiselect(p, id, start) {
    const chosen = new Set(Array.isArray(start) ? start : start ? [start] : []);
    const el = h('div', { class: 'pills', id, role: 'group' },
      (p.options || []).map((o) => {
        const b = h('button', { type: 'button', class: 'pill-opt', 'aria-pressed': String(chosen.has(o)) }, o);
        b.addEventListener('click', () => {
          if (chosen.has(o)) chosen.delete(o); else chosen.add(o);
          b.setAttribute('aria-pressed', String(chosen.has(o)));
        });
        return b;
      }));
    return { el, value: () => (p.options || []).filter((o) => chosen.has(o)) };
  },
  list(p, id, start) {
    const items = Array.isArray(start) ? start.map(String) : start ? [String(start)] : [];
    const input = h('input', { id, placeholder: p.placeholder || 'Type and press Enter' });
    const box = h('div', { class: 'tags' });
    const render = () => {
      clear(box);
      items.forEach((it, i) => box.append(h('span', { class: 'tag' }, it,
        h('button', { type: 'button', 'aria-label': `Remove ${it}`, onclick: () => { items.splice(i, 1); render(); input.focus(); } }, '×'))));
      box.append(input);
    };
    const commit = () => {
      for (const part of input.value.split(/[,\n]/)) if (part.trim()) items.push(part.trim());
      input.value = '';
      render();
      input.focus();
    };
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); commit(); }
      else if (e.key === 'Backspace' && !input.value && items.length) { items.pop(); render(); input.focus(); }
    });
    input.addEventListener('blur', () => { if (input.value.trim()) commit(); });
    box.addEventListener('click', (e) => { if (e.target === box) input.focus(); });
    render();
    return { el: box, value: () => { if (input.value.trim()) commit(); return items.slice(); } };
  },
  credential(p, id, start) {
    const user = h('input', { class: 'input', id, placeholder: 'User name', value: (start && start.user) || '', autocomplete: 'off' });
    const pass = h('input', { class: 'input', type: 'password', placeholder: 'Password', autocomplete: 'new-password' });
    return { el: h('div', { class: 'pair' }, user, pass), value: () => (user.value ? { user: user.value, password: pass.value } : undefined) };
  },
};
