/* Plinth landing page: scroll-driven bar demo, reveals, command bar typing. No dependencies. */
(() => {
  'use strict';
  document.documentElement.classList.remove('no-js');

  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const still = () => reduce.matches;
  const EASE = 'cubic-bezier(.22,.8,.24,1)';
  const $ = (s, r = document) => r.querySelector(s);

  /* ---------- nav ---------- */
  const nav = $('#nav');
  const onNav = () => nav.classList.toggle('scrolled', window.scrollY > 24);
  onNav();
  window.addEventListener('scroll', onNav, { passive: true });

  /* ---------- reveal ---------- */
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      e.target.classList.add('in');
      io.unobserve(e.target);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
  document.querySelectorAll('.reveal').forEach((el, i) => {
    if (el.closest('.hero')) el.style.transitionDelay = `${i * 90}ms`;
    io.observe(el);
  });

  /* ---------- latest version from GitHub ---------- */
  fetch('https://api.github.com/repos/brandonzalcman/Plinth/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : null))
    .then((rel) => {
      if (!rel || !rel.tag_name) return;
      const v = rel.tag_name.replace(/^v/, '');
      $('#version').textContent = `Version ${v} · Free and open source`;
    })
    .catch(() => {});

  /* ---------- seat map ---------- */
  const fus = $('#fuselage');
  const ROWS = [];
  for (let r = 10; r <= 26; r++) ROWS.push(r);
  const TAKEN = new Set(['10A', '10B', '11C', '11D', '11E', '12B', '12C', '12D', '12E', '12F', '13A', '13F', '14B', '14C', '15D', '15E', '15F', '16A', '17C', '17D', '18A', '18B', '18E', '19F', '20B', '20C', '20D', '21A', '21E', '22C', '22D', '22F', '23A', '23B', '24A', '24B', '24C', '24D', '24E', '25C', '25F', '26A', '26D', '26E']);
  const seatEls = {};
  ROWS.forEach((r) => {
    ['A', 'B', 'C', null, 'D', 'E', 'F'].forEach((c) => {
      const s = document.createElement('i');
      if (!c) { s.className = 's row-num'; s.textContent = r; }
      else {
        const id = `${r}${c}`;
        s.className = 's ' + (TAKEN.has(id) ? 'taken' : 'free') + (r === 12 || r === 24 ? ' leg' : '');
        seatEls[id] = s;
      }
      fus.appendChild(s);
    });
  });

  /* ---------- the bar ---------- */
  const stage = $('#stage');
  const stageWrap = $('#stageWrap');
  const win = $('.win', stage);
  const bar = $('#bar');
  const itemsEl = $('#items');
  const capsEl = $('#caps');
  const els = new Map();
  const caps = new Map();
  let scale = 1;
  let barState = null;

  const AIR = '#2F5BEA', NOTES = '#6A4BD0', NEWS = '#C98A3B';
  const PLUS = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>';
  const TRAY = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 13l2.5-7h11L20 13v5H4z"/><path d="M4 13h4.5l1 2h5l1-2H20"/></svg><span class="badge"></span>';
  const JOIN = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M9 7H7a5 5 0 0 0 0 10h2M15 7h2a5 5 0 0 1 0 10h-2M8 12h8"/></svg>';

  function describe(st) {
    const L = [
      { k: 'pin-m', t: 'pin', txt: 'M' },
      { k: 'pin-c', t: 'pin', txt: 'C' },
      { k: 'div', t: 'div' },
    ];
    const air = [['fs', 'Flight search'], ['fc', 'Fare calendar'], ['sm', 'Seat map']];
    if (!st.grouped) {
      air.forEach(([id, label], i) => {
        const g = i === 0 ? 'air' : `air-${id}`;
        L.push({ k: i === 0 ? 'ic-air' : `ic-air-${id}`, t: 'icon', c: AIR, txt: 'L', g });
        L.push({ k: `pg-${id}`, t: 'page', label, g, cur: id === 'sm', end: true });
      });
    } else {
      L.push({ k: 'ic-air', t: 'icon', c: AIR, txt: 'L', g: 'air' });
      const pages = st.split ? air.slice(0, 2) : air;
      pages.forEach(([id, label], i) => L.push({ k: `pg-${id}`, t: 'page', label, g: 'air', cur: id === 'sm', end: i === pages.length - 1 }));
      if (st.split) {
        L.push({ k: 'pg-sm', t: 'page', label: 'Seat map', g: 'split', cur: true, lead: true });
        L.push({ k: 'join', t: 'join', g: 'split' });
        L.push({ k: 'pg-tn', t: 'page', label: 'Trip notes', g: 'split', cur: true, end: true });
      }
    }
    L.push({ k: 'ic-notes', t: 'icon', c: NOTES, txt: 'N', g: 'notes' });
    if (!st.split) L.push({ k: 'pg-tn', t: 'page', label: 'Trip notes', g: 'notes' });
    L.push({ k: 'pg-bu', t: 'page', label: 'Budget', g: 'notes', end: true });
    if (st.news !== 'shelved') {
      const f = st.news === 'fading';
      L.push({ k: 'ic-news', t: 'icon', c: NEWS, txt: 'D', g: 'news', faded: f });
      L.push({ k: 'pg-mb', t: 'page', label: 'Morning briefing', g: 'news', faded: f, end: true });
    }
    L.push({ k: 'plus', t: 'plus' }, { k: 'sp', t: 'spacer' }, { k: 'tray', t: 'tray' }, { k: 'search', t: 'search' });
    return L;
  }

  function create(d) {
    const el = document.createElement('div');
    el.dataset.k = d.k;
    el.className = `it ${d.t}`;
    if (d.t === 'pin' || d.t === 'icon') el.textContent = d.txt;
    if (d.t === 'page') el.textContent = d.label;
    if (d.t === 'plus') el.innerHTML = PLUS;
    if (d.t === 'tray') el.innerHTML = TRAY;
    if (d.t === 'join') el.innerHTML = JOIN;
    if (d.t === 'search') el.innerHTML = 'Search <i>⌘L</i>';
    if (d.c) el.style.setProperty('--c', d.c);
    return el;
  }

  function update(el, d) {
    el.dataset.g = d.g || '';
    el.classList.toggle('cur', !!d.cur);
    el.classList.toggle('end', !!d.end);
    el.classList.toggle('faded', !!d.faded);
    el.style.marginLeft = d.lead ? '10px' : '';
    if (d.t === 'icon') el.style.marginLeft = '18px';
  }

  const rel = (r, base) => ({ x: (r.left - base.left) / scale, y: (r.top - base.top) / scale, w: r.width / scale, h: r.height / scale });

  function layoutCaps(st, animate) {
    const groups = new Map();
    itemsEl.querySelectorAll('.it').forEach((el) => {
      const g = el.dataset.g;
      if (!g) return;
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(el);
    });
    groups.forEach((members, g) => {
      const first = members[0];
      const last = members[members.length - 1];
      const left = first.offsetLeft - (first.classList.contains('icon') ? 10 : 4);
      const width = last.offsetLeft + last.offsetWidth + 2 - left;
      let cap = caps.get(g);
      const fresh = !cap;
      if (fresh) {
        cap = document.createElement('div');
        cap.className = 'cap';
        capsEl.appendChild(cap);
        caps.set(g, cap);
        cap.style.transition = 'none';
        cap.style.opacity = '0';
      }
      cap.classList.toggle('dashed', g === 'news' && st.news === 'fading');
      cap.classList.toggle('split', g === 'split');
      cap.style.left = `${left}px`;
      cap.style.width = `${width}px`;
      if (fresh) {
        cap.getBoundingClientRect();
        cap.style.transition = '';
        if (animate) setTimeout(() => { cap.style.opacity = ''; }, 120);
        else cap.style.opacity = '';
      }
    });
    caps.forEach((cap, g) => {
      if (groups.has(g)) return;
      caps.delete(g);
      cap.classList.add('leaving');
      setTimeout(() => cap.remove(), 600);
    });
  }

  function renderBar(st, flyTo = {}) {
    const animate = !still() && barState !== null;
    const desc = describe(st);
    const keys = new Set(desc.map((d) => d.k));
    const barRect = bar.getBoundingClientRect();
    const first = new Map();
    els.forEach((el, k) => first.set(k, el.getBoundingClientRect()));

    // elements leaving the bar
    const leaving = [];
    els.forEach((el, k) => {
      if (keys.has(k)) return;
      els.delete(k);
      if (!animate) { el.remove(); return; }
      const r = rel(first.get(k), barRect);
      el.classList.add('flyer');
      el.style.left = `${r.x}px`;
      el.style.top = `${r.y}px`;
      bar.appendChild(el);
      leaving.push([k, el, r]);
    });

    // reconcile order
    desc.forEach((d) => {
      let el = els.get(d.k);
      if (!el) { el = create(d); els.set(d.k, el); }
      update(el, d);
      itemsEl.appendChild(el);
    });

    // tray badge
    const tray = els.get('tray');
    const badge = tray.querySelector('.badge');
    const count = st.news === 'shelved' ? 3 : 2;
    if (badge.textContent !== String(count)) {
      badge.textContent = count;
      badge.classList.add('show');
      if (animate) { badge.classList.remove('bump'); void badge.offsetWidth; badge.classList.add('bump'); }
    }
    tray.classList.toggle('open', !!st.shelfOpen);

    layoutCaps(st, animate);
    if (!animate) return;

    // FLIP the items that stayed
    desc.forEach((d) => {
      const el = els.get(d.k);
      const f = first.get(d.k);
      if (!f) {
        el.animate([{ opacity: 0, transform: 'scale(.6)' }, { opacity: 1, transform: 'none' }], { duration: 500, delay: 220, easing: EASE, fill: 'backwards' });
        return;
      }
      const l = el.getBoundingClientRect();
      const dx = (f.left - l.left) / scale;
      const dy = (f.top - l.top) / scale;
      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) return;
      el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 700, easing: EASE });
    });

    // fly the leavers
    leaving.forEach(([k, el, r]) => {
      const target = flyTo[k] && els.get(flyTo[k]);
      let frames;
      let duration = 380;
      if (target) {
        const t = rel(target.getBoundingClientRect(), barRect);
        const dx = t.x + t.w / 2 - (r.x + r.w / 2);
        const dy = t.y + t.h / 2 - (r.y + r.h / 2);
        const drop = flyTo[k] === 'tray';
        duration = drop ? 900 : 600;
        frames = drop
          ? [{ transform: 'none', opacity: 1 }, { transform: `translate(${dx * 0.45}px, -26px) scale(.8)`, opacity: 1, offset: 0.4 }, { transform: `translate(${dx}px, ${dy}px) scale(.15)`, opacity: 0 }]
          : [{ transform: 'none', opacity: 1 }, { transform: `translate(${dx}px, ${dy}px) scale(.8)`, opacity: 0 }];
      } else {
        frames = [{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'scale(.6)' }];
      }
      el.animate(frames, { duration, easing: EASE, fill: 'forwards' }).onfinish = () => el.remove();
    });
  }

  /* ---------- page area ---------- */
  const answerEl = $('#askAnswer');
  const seatPick = $('#seatPick');
  const peekLink = $('#peekLink');
  const peek = $('#peek');
  let streamTimers = [];

  const ANSWER = 'Two open seats have extra legroom: [12A], a window seat in the exit row, and [24F], a window seat in the second exit row near the back. Row 12 is closer to the front, so you will get off sooner in Lisbon.';

  function clearStream() {
    streamTimers.forEach(clearTimeout);
    streamTimers = [];
    answerEl.innerHTML = '';
    Object.values(seatEls).forEach((s) => s.classList.remove('hl'));
    seatPick.textContent = '—';
  }

  function stream() {
    clearStream();
    const words = ANSWER.split(' ');
    const cur = document.createElement('span');
    cur.className = 'cur';
    answerEl.appendChild(cur);
    const add = (w) => {
      const m = w.match(/^\[(\w+)\](.*)$/);
      let node;
      if (m) {
        node = document.createElement('span');
        node.className = 'w';
        node.innerHTML = `<mark>${m[1]}</mark>${m[2]}`;
        seatEls[m[1]].classList.add('hl');
        if (seatPick.textContent === '—') seatPick.textContent = m[1];
      } else {
        node = document.createElement('span');
        node.className = 'w';
        node.textContent = w;
      }
      answerEl.insertBefore(node, cur);
      answerEl.insertBefore(document.createTextNode(' '), cur);
    };
    if (still()) { words.forEach(add); cur.remove(); return; }
    words.forEach((w, i) => streamTimers.push(setTimeout(() => add(w), 500 + i * 70)));
    streamTimers.push(setTimeout(() => cur.remove(), 500 + words.length * 70 + 600));
  }

  function renderPage(st) {
    win.classList.toggle('split', !!st.split);
    win.classList.toggle('shelving', !!st.shelfOpen);
    peekLink.classList.toggle('hot', !!st.linkHot || !!st.peek);
    if (st.peek && !win.classList.contains('peeking')) {
      const lr = peekLink.getBoundingClientRect();
      const vr = $('#viewport').getBoundingClientRect();
      const x = (lr.left - vr.left) / scale + lr.width / scale / 2 - peek.offsetLeft;
      const y = (lr.top - vr.top) / scale + lr.height / scale / 2 - peek.offsetTop;
      peek.style.transformOrigin = `${x}px ${y}px`;
    }
    win.classList.toggle('peeking', !!st.peek);
    const asking = win.classList.contains('asking');
    win.classList.toggle('asking', !!st.ask);
    if (st.ask && !asking) stream();
    if (!st.ask && asking) clearStream();
  }

  function apply(st, flyTo) {
    renderBar(st, flyTo);
    renderPage(st);
    barState = st;
  }

  /* ---------- steps ---------- */
  const base = { grouped: true, news: 'normal', split: false, peek: false, linkHot: false, ask: false, shelfOpen: false };
  const S = (o) => Object.assign({}, base, o);
  const STEPS = [
    [[S({ grouped: false }), 0]],
    [[S({}), 0]],
    [[S({ news: 'fading' }), 0], [S({ news: 'shelved', shelfOpen: true }), 1400]],
    [[S({ news: 'shelved', split: true }), 0]],
    [[S({ news: 'shelved', linkHot: true }), 0], [S({ news: 'shelved', peek: true }), 650]],
    [[S({ news: 'shelved', ask: true }), 0]],
  ];
  const FLY = {
    'ic-air-fc': 'ic-air', 'ic-air-sm': 'ic-air',
    'ic-news': 'tray', 'pg-mb': 'tray',
  };

  let step = -1;
  let seqTimers = [];
  const captions = [...document.querySelectorAll('.caption')];
  const dots = [...document.querySelectorAll('#progress li')];

  function goto(n) {
    if (n === step) return;
    const back = n < step;
    step = n;
    seqTimers.forEach(clearTimeout);
    seqTimers = [];
    captions.forEach((c, i) => { c.classList.toggle('on', i === n); c.classList.toggle('past', i < n); });
    dots.forEach((d, i) => d.classList.toggle('on', i === n));
    const seq = STEPS[n];
    if (back || still()) { apply(seq[seq.length - 1][0], FLY); return; }
    seq.forEach(([st, delay]) => {
      if (!delay) apply(st, FLY);
      else seqTimers.push(setTimeout(() => apply(st, FLY), delay));
    });
  }

  const story = $('#story');
  function onScroll() {
    const r = story.getBoundingClientRect();
    const span = r.height - window.innerHeight;
    const p = Math.min(0.9999, Math.max(0, -r.top / span));
    goto(Math.floor(p * STEPS.length));
  }

  function fit() {
    const w = stageWrap.clientWidth;
    const h = stageWrap.clientHeight;
    const sw = stage.offsetWidth;
    const sh = stage.offsetHeight;
    scale = Math.min(w / sw, h / sh, 1);
    stage.style.transform = `scale(${scale})`;
    // collapse the empty space a scaled-down stage leaves below it
    stage.style.marginBottom = `${-sh * (1 - scale)}px`;
  }

  fit();
  goto(0);
  onScroll();
  let ticking = false;
  window.addEventListener('scroll', () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; onScroll(); });
  }, { passive: true });
  window.addEventListener('resize', () => { fit(); layoutCaps(barState, false); onScroll(); });

  // intro: bar items arrive one by one the first time the stage is seen
  if (!still()) {
    itemsEl.style.opacity = '0';
    capsEl.style.opacity = '0';
    const introIO = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      introIO.disconnect();
      itemsEl.style.opacity = '';
      capsEl.style.opacity = '';
      capsEl.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 800, delay: 400, easing: EASE, fill: 'backwards' });
      [...itemsEl.children].forEach((el, i) => {
        el.animate([{ opacity: 0, transform: 'translateY(14px) scale(.9)' }, { opacity: 1, transform: 'none' }], { duration: 600, delay: 150 + i * 45, easing: EASE, fill: 'backwards' });
      });
      bar.animate([{ transform: 'translateY(30px)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 800, easing: EASE });
    }, { threshold: 0.35 });
    introIO.observe(stage);
  }

  /* ---------- command bar typing ---------- */
  const cmd = $('#cmd');
  const cmdText = $('#cmdText');
  const cmdResults = $('#cmdResults');
  const QUERY = 'lisbon trip';
  const cmdIO = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    cmdIO.disconnect();
    if (still()) { cmdText.textContent = QUERY; cmdResults.classList.add('show'); return; }
    [...QUERY].forEach((ch, i) => setTimeout(() => { cmdText.textContent += ch; }, 500 + i * 85));
    setTimeout(() => {
      [...cmdResults.children].forEach((el, i) => { el.style.transitionDelay = `${i * 70}ms`; });
      cmdResults.classList.add('show');
    }, 500 + QUERY.length * 85 + 200);
  }, { threshold: 0.4 });
  cmdIO.observe(cmd);
})();
