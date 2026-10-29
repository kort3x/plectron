import { h } from './dom.js';

// A small, safe Markdown subset for New-PlxText -Markdown: headings, paragraphs,
// lists, fenced code, **bold**, *italic*, `code` and [links](https://…).
// Built with DOM nodes only, so page text can never inject markup.
export function renderMarkdown(text) {
  const root = h('div', { class: 'md' });
  const lines = String(text).replace(/\r\n?/g, '\n').split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    if (line.startsWith('```')) {
      const code = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++;
      root.append(h('pre', null, h('code', null, code.join('\n'))));
      continue;
    }
    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      root.append(h(`h${Math.min(heading[1].length + 1, 5)}`, null, inline(heading[2])));
      i++;
      continue;
    }
    if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\./.test(line);
      const list = h(ordered ? 'ol' : 'ul');
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
        list.append(h('li', null, inline(lines[i].replace(/^\s*([-*]|\d+\.)\s+/, ''))));
        i++;
      }
      root.append(list);
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,4}\s|```|\s*([-*]|\d+\.)\s)/.test(lines[i])) para.push(lines[i++].trim());
    root.append(h('p', null, inline(para.join(' '))));
  }
  return root;
}

const INLINE = /(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|_[^_\s][^_]*_|`[^`]+`|\[[^\]]+\]\([^)\s]+\))/;

function inline(text) {
  const out = [];
  let rest = text;
  while (rest) {
    const m = rest.match(INLINE);
    if (!m) { out.push(rest); break; }
    if (m.index > 0) out.push(rest.slice(0, m.index));
    const t = m[0];
    if (t.startsWith('**')) out.push(h('strong', null, t.slice(2, -2)));
    else if (t.startsWith('`')) out.push(h('code', null, t.slice(1, -1)));
    else if (t.startsWith('[')) {
      const [, label, href] = t.match(/^\[([^\]]+)\]\(([^)\s]+)\)$/);
      if (/^(https?:|mailto:|#|\/)/i.test(href)) out.push(h('a', { href, target: href.startsWith('#') ? null : '_blank', rel: 'noopener noreferrer' }, label));
      else out.push(label);
    } else out.push(h('em', null, t.slice(1, -1)));
    rest = rest.slice(m.index + t.length);
  }
  return out;
}
