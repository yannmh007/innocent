// Innocent Studio — the control-room shell.
//
// The menu, the address bar, the idle sign-out and the dashboard. A separate
// file from index.html because the page was three and a half thousand lines
// of one script, and the part that decides who sees what should be readable
// on its own.
//
// CLASSIC SCRIPT, NOT A MODULE, on purpose: it shares the page's global
// scope, so `api`, `$`, `el`, `show` and the rest are simply there. It is
// loaded BEFORE the page's own script and therefore declares functions and
// nothing else — none of them runs until boot() calls startShell(), by which
// time everything they use exists.
//
// THE MENU IS MANNERS, NOT SECURITY. A page hidden from a viewer is hidden
// because it would only show them refusals; every op is checked again on the
// server, which is the only place a check means anything.

/// Every page, in menu order. `tab` is the section id in index.html (kept
/// from before the shell, so none of the existing code had to change);
/// `route` is what the address bar shows. `need` is the lowest role the page
/// is any use to. `bar` marks the four pages on a phone's bottom bar.
const SH_PAGES = [
  { tab: 'dashboard', route: 'dashboard', label: 'Dashboard', group: 'Overview', need: 'viewer', icon: 'grid', bar: 1 },
  { tab: 'review', route: 'review', label: 'Review', group: 'Content', need: 'viewer', icon: 'check', bar: 2, badge: 'review' },
  { tab: 'catalogue', route: 'library', label: 'Library', group: 'Content', need: 'viewer', icon: 'film', bar: 3 },
  { tab: 'new', route: 'upload', label: 'Upload', group: 'Content', need: 'uploader', icon: 'upload', bar: 4 },
  { tab: 'telegram', route: 'telegram', label: 'Telegram', group: 'Content', need: 'viewer', icon: 'send', bar: 5, badge: 'telegram' },
  { tab: 'cats', route: 'categories', label: 'Categories', group: 'Content', need: 'viewer', icon: 'tag' },
  { tab: 'requests', route: 'requests', label: 'Requests', group: 'Business', need: 'viewer', icon: 'inbox', badge: 'requests' },
  { tab: 'stats', route: 'insights', label: 'Insights', group: 'Business', need: 'viewer', icon: 'chart' },
  { tab: 'health', route: 'health', label: 'Health', group: 'System', need: 'viewer', icon: 'pulse' },
  { tab: 'files', route: 'files', label: 'Files', group: 'System', need: 'editor', icon: 'folder' },
  { tab: 'activity', route: 'activity', label: 'Activity', group: 'Control', need: 'editor', icon: 'clock' },
  { tab: 'admins', route: 'admins', label: 'Admins', group: 'Control', need: 'owner', icon: 'users' },
  { tab: 'security', route: 'security', label: 'Security', group: 'Control', need: 'viewer', icon: 'shield' },
];

const SH_RANK = { viewer: 1, uploader: 2, editor: 3, owner: 4 };

/// Stroke icons, 24-unit grid. Inline rather than an icon font: no request,
/// no licence, and they take the text colour.
const SH_ICONS = {
  grid: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z',
  film: 'M4 4h16v16H4zM8 4v16M16 4v16M4 9h4M4 15h4M16 9h4M16 15h4',
  upload: 'M12 16V4M7 9l5-5 5 5M4 16v4h16v-4',
  send: 'M21 3L10 14M21 3l-7 18-4-7-7-4z',
  tag: 'M3 12V3h9l9 9-9 9zM7.5 7.5h.01',
  inbox: 'M3 13l3-8h12l3 8v6H3zM3 13h5l1 3h6l1-3h5',
  chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  pulse: 'M3 12h4l3-8 4 16 3-8h4',
  folder: 'M3 6h6l2 2h10v11H3z',
  clock: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2',
  users: 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21v-1a6 6 0 0 1 12 0v1M16 3.5a4 4 0 0 1 0 7.5M22 21v-1a6 6 0 0 0-4-5.6',
  shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  check: 'M4 12.5l5 5L20 6.5',
};

function shIcon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('class', 'sh-ico');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(ns, 'path');
  path.setAttribute('d', SH_ICONS[name] || SH_ICONS.grid);
  svg.append(path);
  return svg;
}

/// Who is signed in, as the server answered `whoami`. Null when nobody is.
let ME = null;
let shBadges = {};
let shLastActive = Date.now();
let shIdleTimer = null;
let shWired = false;

function shAllowed(page) {
  return !!ME && SH_RANK[ME.role] >= SH_RANK[page.need];
}
function shPageFor(tab) {
  return SH_PAGES.find((p) => p.tab === tab) || null;
}

// ── starting and stopping ────────────────────────────────────────────────

/// Everything that happens between "Google said yes" and the first page:
/// the 2-step code if this account has one, who the server says this is,
/// the menu for that role, and the page in the address bar.
async function startShell() {
  wireShellOnce();
  try {
    // ANYONE WHO HAS AN AUTHENTICATOR GIVES ITS CODE AT SIGN-IN, whether or
    // not the console requires it yet. A session that has given the code is
    // the one the server will accept once MFA is switched on; asking now
    // means switching it on later does not bounce anyone mid-task.
    await ensureSecondStep();
    ME = await api({ op: 'whoami' });
  } catch (e) {
    ME = null;
    shShowRefusal(e);
    return;
  }
  document.body.classList.add('sh-on');
  $('roleChip').hidden = false;
  $('roleChip').textContent = ME.role;
  drawMenu();
  shLastActive = Date.now();
  clearInterval(shIdleTimer);
  shIdleTimer = setInterval(shIdleTick, 15000);
  routeFromHash(true);
  refreshBadges();
}

function stopShell() {
  ME = null;
  document.body.classList.remove('sh-on');
  $('side').hidden = true;
  $('tabbar').hidden = true;
  $('sheet').hidden = true;
  $('roleChip').hidden = true;
  $('crumb').textContent = '';
  clearInterval(shIdleTimer);
  shIdleTimer = null;
  const idle = document.querySelector('.cr-idle');
  if (idle) idle.remove();
}

/// The server said no to `whoami`. Says why, in words, on the sign-in card —
/// with a way out, because a signed-in account that is not an admin would
/// otherwise be stuck looking at an empty page.
function shShowRefusal(e) {
  const code = e && e.code ? e.code : '';
  const why = code === 'not_an_admin'
    ? 'This Google account is not an admin of this console. An owner can add it on the Admins page.'
    : code === 'mfa_required'
      ? 'This console requires two-step sign-in, and the code was not given.'
      : 'Could not open the console: ' + String((e && e.message) || e);
  say('bad', why);
  // Signed in to Google but not into the console: the way forward is to try
  // again (after the code, or after an owner adds the account) or to sign
  // out and use another account — the button for which is in the top bar.
  const again = el('button', { className: 'b', type: 'button', style: 'margin-left:8px' },
    text('Try again'));
  again.onclick = () => location.reload();
  $('msg').append(again);
}

function wireShellOnce() {
  if (shWired) return;
  shWired = true;
  window.addEventListener('hashchange', () => routeFromHash(false));
  for (const ev of ['pointerdown', 'keydown', 'wheel', 'touchstart']) {
    window.addEventListener(ev, noteActivity, { passive: true });
  }
  $('signout').onclick = async () => {
    if (uploadsInFlight > 0 &&
        !confirm('An upload is still running. Sign out and stop it?')) return;
    await sb.auth.signOut();
  };
  $('sheet').onclick = (e) => { if (e.target === $('sheet')) $('sheet').hidden = true; };
}

// ── the menu ─────────────────────────────────────────────────────────────

function drawMenu() {
  const pages = SH_PAGES.filter(shAllowed);

  const side = $('side');
  side.textContent = '';
  side.append(el('div', { className: 'sh-brand' }, [
    el('span', { className: 'sh-mark' }, text('I')),
    el('span', {}, [text('Innocent '), el('em', {}, text('Studio'))]),
  ]));
  let group = '';
  for (const p of pages) {
    if (p.group !== group) {
      group = p.group;
      side.append(el('div', { className: 'sh-group' }, text(group)));
    }
    side.append(shItem(p, 'sh-item'));
  }
  side.append(el('div', { className: 'sh-foot' },
    text((ME.email || '') + ' · ' + ME.role)));
  side.hidden = false;

  // Phone: the four most-used pages this role can open, then More.
  const bar = $('tabbar');
  bar.textContent = '';
  const onBar = pages.filter((p) => p.bar).sort((a, b) => a.bar - b.bar).slice(0, 4);
  for (const p of onBar) bar.append(shItem(p, 'sh-tab'));
  const more = el('button', { className: 'sh-tab', type: 'button' },
    [shIcon('more'), text('More')]);
  more.dataset.more = '1';
  more.onclick = () => openMoreSheet(pages.filter((p) => !onBar.includes(p)));
  bar.append(more);
  bar.hidden = false;
}

function shItem(p, cls) {
  const a = el('a', { className: cls, href: '#/' + p.route },
    [shIcon(p.icon), el('span', {}, text(p.label))]);
  a.dataset.tab = p.tab;
  if (p.badge) {
    const b = el('span', { className: 'sh-badge' });
    b.dataset.badge = p.badge;
    b.hidden = true;
    a.append(b);
  }
  return a;
}

function openMoreSheet(pages) {
  const sheet = $('sheet');
  sheet.textContent = '';
  const inner = el('div', { className: 'sh-sheet-in' },
    [el('div', { className: 'sh-grip' })]);
  for (const p of pages) {
    const a = shItem(p, 'sh-item');
    a.onclick = () => { sheet.hidden = true; };
    inner.append(a);
  }
  sheet.append(inner);
  sheet.hidden = false;
  markMenu(shCurrentTab());
  drawBadges();
}

/// Called by show() for every page change: highlights the page in the menu,
/// names it in the top bar, and keeps the address bar in step without adding
/// a history entry (the menu's own links add those).
function markMenu(tab) {
  for (const n of document.querySelectorAll('.sh-item,.sh-tab')) {
    if (n.dataset.more) continue;
    if (n.dataset.tab === tab) n.setAttribute('aria-current', 'page');
    else n.removeAttribute('aria-current');
  }
  // More is "current" when the page is one of the pages inside it.
  const more = document.querySelector('.sh-tab[data-more]');
  if (more) {
    const onBar = [...document.querySelectorAll('.sh-tabbar .sh-tab[data-tab]')]
      .some((n) => n.dataset.tab === tab);
    if (!onBar && tab !== 'editor') more.setAttribute('aria-current', 'page');
    else more.removeAttribute('aria-current');
  }
  const page = shPageFor(tab);
  $('crumb').textContent = tab === 'editor' ? 'Library · Edit' : page ? page.label : '';
  const want = tab === 'editor'
    ? (editingId ? '#/title/' + editingId : '#/library')
    : page ? '#/' + page.route : '';
  if (want && location.hash !== want) history.replaceState(null, '', want);
}

function shCurrentTab() {
  return TABS.find((t) => !$('tab-' + t).hidden) || null;
}

/// The address bar decides the page: on sign-in (so a bookmark or a reload
/// lands where it pointed), and on the back button and the menu's links.
function routeFromHash(first) {
  if (!ME) return;
  const h = location.hash.replace(/^#\/?/, '');
  const title = /^title\/([0-9a-f-]{36})$/i.exec(h);
  if (title) {
    if (editingId !== title[1] || shCurrentTab() !== 'editor') openEditor(title[1]);
    return;
  }
  const page = SH_PAGES.find((p) => p.route === h);
  const target = page && shAllowed(page) ? page : SH_PAGES[0];
  if (!first && shCurrentTab() === target.tab) return;
  show(target.tab);
  // show() can decline — leaving an editor with unsaved changes asks first.
  // When it does, put the address bar back to the page still on screen.
  markMenu(shCurrentTab());
}

// ── badges: what is waiting, on the menu itself ──────────────────────────

async function refreshBadges() {
  try {
    const s = await api({ op: 'summary' });
    shApplySummary(s);
  } catch (e) {
    // Badges are a convenience; a page that cannot load them still works.
  }
}

function shApplySummary(s) {
  const tg = s.telegram || {};
  const rv = s.review || {};
  // WHAT IS WAITING FOR THIS PERSON. An editor's badge counts what waits for
  // an approval; an uploader's counts what was sent back to them.
  const decides = !!ME && SH_RANK[ME.role] >= SH_RANK.editor;
  shBadges = {
    review: decides ? { n: rv.waiting || 0, bad: false } : { n: rv.mine || 0, bad: true },
    telegram: { n: (tg.unattached || 0) + (tg.failed || 0), bad: (tg.failed || 0) > 0 },
    requests: { n: s.requests || 0, bad: false },
  };
  drawBadges();
}

function drawBadges() {
  for (const b of document.querySelectorAll('.sh-badge[data-badge]')) {
    const v = shBadges[b.dataset.badge];
    b.hidden = !v || !v.n;
    if (v) {
      b.textContent = v.n > 99 ? '99+' : String(v.n);
      b.className = 'sh-badge' + (v.bad ? ' bad' : '');
    }
  }
}

// ── dashboard ────────────────────────────────────────────────────────────

async function loadDashboard() {
  const kpis = $('dashKpis');
  const todo = $('dashTodo');
  kpis.textContent = '';
  todo.textContent = '';
  todo.append(el('div', { className: 'empty' }, text('Loading…')));
  let s;
  try {
    s = await api({ op: 'summary' });
  } catch (e) {
    todo.textContent = '';
    say('bad', String(e.message || e));
    return;
  }
  shApplySummary(s);
  const t = s.titles || {};
  const tg = s.telegram || {};
  const kpi = (k, v, sub, href, tone) => {
    const a = el('a', { className: 'cr-kpi' + (tone ? ' ' + tone : ''), href }, [
      el('div', { className: 'k' }, text(k)),
      el('div', { className: 'v' }, text(v)),
      el('div', { className: 's' }, text(sub)),
    ]);
    kpis.append(a);
  };
  const rv = s.review || {};
  kpi('Live', t.live ?? 0, 'titles in the app', '#/library');
  kpi('Review', rv.waiting ?? 0, 'waiting for approval', '#/review', rv.waiting ? 'warn' : '');
  kpi('Telegram', (tg.queued || 0) + (tg.running || 0),
    tg.running ? tg.running + ' fetching now' : 'waiting to fetch', '#/telegram');
  kpi('Requests', s.requests ?? 0, 'premium, waiting', '#/requests', s.requests ? 'warn' : '');

  // WHAT NEEDS A PERSON, as a list of things to tap — not numbers to
  // interpret. Empty is the good state and says so.
  todo.textContent = '';
  const item = (dot, words, href) => todo.append(el('a', { className: 'cr-todo', href }, [
    el('span', { className: 'cr-dot' + (dot === 'bad' ? ' bad' : '') }),
    el('span', {}, text(words)),
    el('span', { className: 'cr-go' }, text('›')),
  ]));
  // Approving is an editor's; an uploader is shown what they can act on.
  const canApprove = SH_RANK[ME.role] >= SH_RANK.editor;
  if (rv.mine) item('bad', rv.mine + ' of your title(s) sent back with a note — fix and send again', '#/review');
  if (canApprove && rv.waiting) item('', rv.waiting + ' title(s) waiting for your approval', '#/review');
  if (tg.failed) item('bad', tg.failed + ' Telegram file(s) failed to fetch — try again or forward them again', '#/telegram');
  if (tg.unattached) item('', tg.unattached + ' Telegram file(s) in no title yet — make titles from them on Review', '#/review');
  if (s.requests && canApprove) item('', s.requests + ' premium request(s) waiting for approval', '#/requests');
  if (t.drafts) item('', t.drafts + ' draft title(s) not in the app', '#/review');
  if (!todo.childNodes.length) {
    todo.append(el('div', { className: 'empty' }, text('Nothing is waiting. All clear.')));
  }

  const recent = Array.isArray(s.recent) ? s.recent : [];
  $('dashRecentSec').hidden = !recent.length || !canApprove;
  const host = $('dashRecent');
  host.textContent = '';
  if (recent.length) host.append(drawFeed(recent));
}

// ── idle sign-out ────────────────────────────────────────────────────────

function noteActivity() {
  shLastActive = Date.now();
  const idle = document.querySelector('.cr-idle');
  if (idle) idle.remove();
}

/// Signs out after the owner's chosen minutes without a touch — never in the
/// middle of an upload, which is not idleness however long it takes, and
/// with a minute's warning first so a half-typed edit can be rescued.
function shIdleTick() {
  if (!ME) return;
  const limit = (ME.idleMinutes || 30) * 60000;
  const quiet = Date.now() - shLastActive;
  if (uploadsInFlight > 0) { shLastActive = Date.now(); return; }
  if (quiet >= limit) {
    stopShell();
    sb.auth.signOut().then(() => {
      say('info', 'Signed out after ' + Math.round(limit / 60000) +
        ' minutes without use. Sign in again to continue.');
    });
    return;
  }
  if (quiet >= limit - 60000 && !document.querySelector('.cr-idle')) {
    const n = el('div', { className: 'cr-idle', role: 'alert' },
      text('Signing out in a minute for inactivity — tap anywhere to stay.'));
    document.body.append(n);
  }
}

// ── words for the server's refusals ──────────────────────────────────────

/// The server answers with codes. The common refusals get a sentence; the
/// code stays in the message in brackets, because other code on this page
/// matches on it and because it is what to search for.
function explainError(code, status) {
  const c = code ? String(code) : String(status);
  const words = {
    not_allowed: 'Your role does not allow this.',
    not_your_draft: 'An uploader can change only their own drafts, before they are published.',
    needs_editor_to_publish: 'Only an editor or an owner can publish.',
    not_an_admin: 'This account is not an admin.',
    not_signed_in: 'Signed out. Sign in again.',
    mfa_required: 'This needs your two-step code.',
    reauth_required: 'This needs a fresh two-step code.',
    enrol_mfa_first: 'Turn on two-step sign-in for your own account first.',
    last_owner: 'There must always be at least one owner.',
    not_owner: 'Only an owner can do this.',
    bad_email: 'That is not an email address.',
    already_disabled: 'That admin is already removed.',
    unknown_op: 'This console is newer than the server — the server has not been updated yet.',
    two_person: 'The person who made a title cannot also approve it (two-person rule).',
    needs_two_approvers: 'The two-person rule needs at least two editors or owners.',
    note_required: 'Say what needs changing.',
    no_files: 'A title with no files cannot be sent or approved.',
    bad_state: 'Somebody has already moved this title on — reload to see where it is.',
    already_live: 'It is already in the app.',
    not_live: 'It is not in the app.',
  }[c];
  return words ? words + ' (' + c + ')' : c;
}
