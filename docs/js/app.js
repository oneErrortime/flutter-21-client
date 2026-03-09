// VoiceCall Docs — SPA app
// Pattern: load docs.json manifest → fetch MD on demand → render with marked.js

(function () {
  'use strict';

  // ── State ──────────────────────────────────────────────────────────────────
  let allDocs = [];
  let currentDoc = null;
  let searchIndex = null;

  // ── DOM refs ───────────────────────────────────────────────────────────────
  const sidebar     = document.getElementById('sidebar');
  const content     = document.getElementById('content');
  const searchInput = document.getElementById('search-input');
  const navList     = document.getElementById('nav-list');
  const mobileBtn   = document.getElementById('mobile-menu-btn');
  const overlay     = document.getElementById('overlay');

  // ── Sidebar toggle (mobile) ────────────────────────────────────────────────
  mobileBtn.addEventListener('click', () => {
    sidebar.classList.toggle('open');
    overlay.classList.toggle('open');
  });
  overlay.addEventListener('click', () => {
    sidebar.classList.remove('open');
    overlay.classList.remove('open');
  });

  // ── marked.js configuration ───────────────────────────────────────────────
  marked.setOptions({
    highlight: function (code, lang) {
      if (hljs && lang && hljs.getLanguage(lang)) {
        try { return hljs.highlight(code, { language: lang }).value; } catch (_) {}
      }
      return hljs ? hljs.highlightAuto(code).value : code;
    },
    breaks: false,
    gfm: true,
    tables: true,
  });

  // Custom renderer for better output
  const renderer = new marked.Renderer();

  renderer.heading = function (text, level) {
    const id = text.toLowerCase().replace(/[^\w]+/g, '-');
    return `<h${level} id="${id}">${text}</h${level}>\n`;
  };

  renderer.table = function (header, body) {
    return `<div class="table-wrap"><table><thead>${header}</thead><tbody>${body}</tbody></table></div>`;
  };

  renderer.code = function (code, lang) {
    const highlighted = lang && hljs && hljs.getLanguage(lang)
      ? hljs.highlight(code, { language: lang }).value
      : hljs ? hljs.highlightAuto(code).value : escapeHtml(code);
    const label = lang || 'code';
    return `<div class="codeblock">
  <div class="codeblock-header">
    <span class="codeblock-lang">${label}</span>
    <button class="codeblock-copy" onclick="copyBlock(this)">Copy</button>
  </div>
  <pre><code class="hljs language-${lang || ''}">${highlighted}</code></pre>
</div>`;
  };

  renderer.blockquote = function (quote) {
    return `<div class="callout callout-info"><span class="callout-icon">ℹ️</span><div class="callout-body">${quote}</div></div>`;
  };

  marked.use({ renderer });

  function escapeHtml(str) {
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  // ── Load manifest ──────────────────────────────────────────────────────────
  async function loadDocs() {
    try {
      const res = await fetch('docs.json');
      const data = await res.json();
      allDocs = data.docs;
      buildNav(allDocs);
      buildSearchIndex(allDocs);

      // Route on load
      const name = getQueryParam('name');
      if (name) {
        loadDoc(name);
      } else {
        loadDoc(allDocs[0]?.name);
      }
    } catch (e) {
      content.innerHTML = `<div class="error">Failed to load documentation manifest.<br><small>${e.message}</small></div>`;
    }
  }

  // ── Nav rendering ──────────────────────────────────────────────────────────
  const NAV_SECTIONS = {
    'Introduction': 'Overview',
    'Architecture': 'Overview',
    'Quick Start Server': 'Getting Started',
    'Quick Start Flutter': 'Getting Started',
    'Device Emulation': 'Getting Started',
    'Security': 'Core Concepts',
    'QUIC Noise Architecture': 'Core Concepts',
    'TURN Server': 'Core Concepts',
    'Deep Links': 'Core Concepts',
    'WebSocket Protocol': 'Reference',
    'REST API': 'Reference',
    'Deployment': 'Reference',
  };

  const BADGES = {
    'QUIC Noise Architecture': { text: 'NEW', cls: 'tag-new' },
    'Security': { text: 'E2E', cls: 'tag-e2e' },
  };

  function buildNav(docs) {
    const sections = {};
    docs.forEach(doc => {
      const section = NAV_SECTIONS[doc.name] || 'Other';
      if (!sections[section]) sections[section] = [];
      sections[section].push(doc);
    });

    // Ordered sections
    const order = ['Overview', 'Getting Started', 'Core Concepts', 'Reference', 'Other'];
    navList.innerHTML = '';

    order.forEach(sectionName => {
      if (!sections[sectionName]) return;
      const group = document.createElement('div');
      group.className = 'nav-section';
      group.innerHTML = `<div class="nav-label">${sectionName}</div>`;

      sections[sectionName].forEach(doc => {
        const a = document.createElement('a');
        a.href = `?name=${encodeURIComponent(doc.name)}`;
        a.dataset.name = doc.name;
        a.className = 'nav-link';

        const badge = BADGES[doc.name];
        a.innerHTML = doc.name + (badge ? ` <span class="tag ${badge.cls}">${badge.text}</span>` : '');

        a.addEventListener('click', e => {
          e.preventDefault();
          loadDoc(doc.name);
          history.pushState({}, '', `?name=${encodeURIComponent(doc.name)}`);
          // Close mobile sidebar
          sidebar.classList.remove('open');
          overlay.classList.remove('open');
        });

        group.appendChild(a);
      });

      navList.appendChild(group);
    });
  }

  function setActiveNav(name) {
    document.querySelectorAll('.nav-link').forEach(a => {
      a.classList.toggle('active', a.dataset.name === name);
    });
  }

  // ── Search ─────────────────────────────────────────────────────────────────
  function buildSearchIndex(docs) {
    searchIndex = docs.map(doc => ({
      name: doc.name,
      content: doc.content,
      lower: (doc.name + ' ' + doc.content).toLowerCase(),
    }));
  }

  searchInput.addEventListener('input', () => {
    const q = searchInput.value.trim().toLowerCase();
    if (!q) {
      buildNav(allDocs);
      return;
    }
    const results = searchIndex
      .filter(d => d.lower.includes(q))
      .map(d => ({ name: d.name, content: d.content }));
    buildNav(results);
  });

  // ── Doc loading & rendering ────────────────────────────────────────────────
  async function loadDoc(name) {
    if (!name) return;
    const doc = allDocs.find(d => d.name === name);
    if (!doc) {
      content.innerHTML = `<div class="error">Document not found: <code>${name}</code></div>`;
      return;
    }

    currentDoc = doc;
    setActiveNav(name);
    renderDoc(doc);
    content.scrollTop = 0;
    window.scrollTo(0, 0);
  }

  function renderDoc(doc) {
    const html = marked.parse(doc.content);
    content.innerHTML = `
      <div class="doc-body">
        <div class="doc-markdown">${html}</div>
        <div class="doc-footer">
          <a href="https://github.com/oneErrortime/flutter-21-client/blob/main/docs/content/${encodeURIComponent(doc.name)}.md"
             target="_blank" class="edit-link">
            Edit this page on GitHub →
          </a>
        </div>
      </div>`;

    // Build in-page TOC
    buildTOC();

    // Syntax highlight any un-highlighted blocks
    content.querySelectorAll('pre code:not(.hljs)').forEach(el => hljs?.highlightElement(el));
  }

  function buildTOC() {
    const headings = content.querySelectorAll('h2, h3');
    if (headings.length < 2) {
      document.getElementById('toc')?.remove();
      return;
    }

    let tocEl = document.getElementById('toc');
    if (!tocEl) {
      tocEl = document.createElement('div');
      tocEl.id = 'toc';
      content.querySelector('.doc-markdown')?.prepend(tocEl);
    }

    let html = '<div class="toc-label">On this page</div><ul>';
    headings.forEach(h => {
      const level = h.tagName === 'H2' ? '' : 'toc-sub';
      html += `<li class="${level}"><a href="#${h.id}">${h.textContent}</a></li>`;
    });
    html += '</ul>';
    tocEl.innerHTML = html;
  }

  // ── popstate (back/forward) ────────────────────────────────────────────────
  window.addEventListener('popstate', () => {
    const name = getQueryParam('name');
    loadDoc(name || allDocs[0]?.name);
  });

  // ── Utility ────────────────────────────────────────────────────────────────
  function getQueryParam(key) {
    return new URLSearchParams(window.location.search).get(key) || '';
  }

  // Global copy helper for code blocks
  window.copyBlock = function (btn) {
    const pre = btn.closest('.codeblock').querySelector('pre');
    navigator.clipboard.writeText(pre.innerText).then(() => {
      btn.textContent = 'Copied!';
      setTimeout(() => btn.textContent = 'Copy', 2000);
    });
  };

  // ── Boot ───────────────────────────────────────────────────────────────────
  loadDocs();
})();
