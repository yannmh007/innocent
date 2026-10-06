// The payment inbox: the Requests page, and the notice that something is in
// it (migration 042, premium-request v3).
//
// Owner request (2026-10-06): "these must show in the console as
// notifications; opening it, the receipts must be right there."
//
// THE NOTICE. Every half minute (two minutes while the tab is in the
// background) the console asks premium-request `pulse`: how many are
// waiting, how many nobody has looked at, and the newest. A new one shows
// four ways, so it is seen whatever the operator is doing:
//   * the menu badge — the waiting count, red while any is unseen;
//   * the tab title — "(2) Innocent Studio", visible from another tab;
//   * a card in the corner of whatever page is open, with Open;
//   * a system notification and a short chime, when the operator has
//     switched them on (the browser asks once; both off by default for the
//     chime, because a console that beeps unasked is a console that gets
//     muted).
// The pulse is QUIET: it is not activity. The idle sign-out (shell.js) counts
// a person's touches, and a timer asking for a count every thirty seconds
// would otherwise keep an abandoned, signed-in console open forever.
//
// THE PAGE. A card per request with the receipt large enough to read, the
// payer's own note, the account (and whether they have paid before), the
// plan and the price they were shown. Approve takes the days the plan is
// for and an optional word to the payer; Reject takes a reason, which is
// what the payer's app shows. Waiting / Approved / Rejected / All — the
// decided ones say who decided and when. Opening the Waiting list marks
// what is on screen as seen.

const RQ_NOTIFY_KEY = 'innocent.rq.notify';
const RQ_SOUND_KEY = 'innocent.rq.sound';
const RQ_BASE_TITLE = document.title;

let rqTimer = null;
let rqLastUnseen = null;
let rqLastNewest = null;
let rqStatus = 'pending';
let rqAudio = null;

const rqRank = () => (ME && SH_RANK[ME.role]) || 0;
const rqMayDecide = () => rqRank() >= SH_RANK.editor;

function rqPref(key) {
  try { return localStorage.getItem(key) === '1'; } catch { return false; }
}
function rqSetPref(key, on) {
  try { localStorage.setItem(key, on ? '1' : '0'); } catch { /* private mode */ }
}

/// The API, without counting as a touch and without stopping to ask for an
/// authenticator code: a background count that fails just tries again.
async function rqQuiet(payload) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('signed out');
  const res = await fetch(PREMIUM_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json',
      Authorization: 'Bearer ' + session.access_token },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(body.error || String(res.status)); e.code = body.error; throw e; }
  return body;
}

// ── the pulse ────────────────────────────────────────────────────────────

function startPulse() {
  stopPulse();
  if (!rqMayDecide()) return;
  rqLastUnseen = null;
  rqLastNewest = null;
  rqPulse();
  document.addEventListener('visibilitychange', rqOnVisibility);
}

function stopPulse() {
  clearTimeout(rqTimer);
  rqTimer = null;
  document.removeEventListener('visibilitychange', rqOnVisibility);
  document.title = RQ_BASE_TITLE;
}

function rqOnVisibility() {
  if (!document.hidden) { clearTimeout(rqTimer); rqPulse(); }
}

async function rqPulse() {
  clearTimeout(rqTimer);
  if (!ME) return;
  try {
    const p = await rqQuiet({ op: 'pulse' });
    rqApplyPulse(p);
  } catch (e) {
    // A count that could not be fetched changes nothing on screen.
  }
  rqTimer = setTimeout(rqPulse, document.hidden ? 120000 : 30000);
}

function rqApplyPulse(p) {
  const pending = p.pending || 0;
  const unseen = p.unseen || 0;
  shBadges.requests = { n: pending, bad: unseen > 0 };
  drawBadges();
  document.title = unseen ? '(' + unseen + ') ' + RQ_BASE_TITLE : RQ_BASE_TITLE;

  const newest = p.newest && p.newest.id;
  // NEW means: more unseen than last time, or a different newest one. The
  // first answer after sign-in only sets the baseline — what was already
  // waiting is announced by the badge and the dashboard, not by a chime.
  const fresh = rqLastUnseen !== null && unseen > 0 &&
    (unseen > rqLastUnseen || (newest && newest !== rqLastNewest));
  rqLastUnseen = unseen;
  rqLastNewest = newest || rqLastNewest;
  if (!fresh) return;

  const what = [p.newest.plan_id, p.newest.price_shown].filter(Boolean).join(' · ');
  if (shCurrentTab() === 'requests' && rqStatus === 'pending' && !document.hidden) {
    loadRequests();
  } else {
    rqToast(unseen, what);
  }
  if (rqPref(RQ_SOUND_KEY)) rqChime();
  if (rqPref(RQ_NOTIFY_KEY) && document.hidden && 'Notification' in window &&
      Notification.permission === 'granted') {
    try {
      const n = new Notification('Innocent · new payment', {
        body: (what ? what + ' — ' : '') + 'a receipt is waiting for you',
        tag: 'innocent-payments',
        renotify: true,
      });
      n.onclick = () => { window.focus(); location.hash = '#/requests'; n.close(); };
    } catch { /* some browsers only allow it from a service worker */ }
  }
}

/// A short two-note chime, made here — no sound file to fetch or host.
function rqChime() {
  try {
    rqAudio = rqAudio || new (window.AudioContext || window.webkitAudioContext)();
    const t = rqAudio.currentTime;
    for (const [f, at] of [[880, 0], [1320, 0.14]]) {
      const o = rqAudio.createOscillator();
      const g = rqAudio.createGain();
      o.type = 'sine';
      o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, t + at);
      g.gain.exponentialRampToValueAtTime(0.18, t + at + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t + at + 0.32);
      o.connect(g).connect(rqAudio.destination);
      o.start(t + at);
      o.stop(t + at + 0.34);
    }
  } catch { /* no audio is not an error */ }
}

function rqToast(n, what) {
  document.querySelector('.rq-toast')?.remove();
  const open = el('a', { className: 'b p rq-toast-go', href: '#/requests' }, text('Open'));
  const shut = el('button', { className: 'i', type: 'button', title: 'Dismiss' }, text('✕'));
  const card = el('div', { className: 'rq-toast', role: 'status' }, [
    el('div', { className: 'rq-toast-ico' }, text('💳')),
    el('div', { className: 'rq-toast-words' }, [
      el('div', { className: 'rq-toast-t' },
        text(n === 1 ? 'New payment to check' : n + ' payments to check')),
      what ? el('div', { className: 'rq-toast-s' }, text(what)) : null,
    ]),
    open, shut,
  ]);
  const gone = () => card.remove();
  open.onclick = gone;
  shut.onclick = gone;
  document.body.append(card);
  setTimeout(gone, 20000);
}

// ── the page ─────────────────────────────────────────────────────────────

const RQ_REASONS = [
  'The payment has not arrived.',
  'The amount is not the price of this plan.',
  'The screenshot is not clear — please send it again.',
  'This receipt was already used for another request.',
];

/// Days for a plan id: what the plan is called is what it is for.
function rqDaysFor(plan) {
  const p = String(plan || '').toLowerCase();
  if (/month/.test(p)) return 30;
  if (/quarter|3m/.test(p)) return 90;
  if (/week/.test(p)) return 7;
  return 365;
}

function rqAgo(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + ' min ago';
  if (s < 86400) return Math.floor(s / 3600) + ' h ago';
  return Math.floor(s / 86400) + ' d ago';
}
const rqWhen = (iso) => (iso || '').slice(0, 16).replace('T', ' ');

function rqDrawControls(counts) {
  const tabs = $('reqTabs');
  tabs.textContent = '';
  for (const [k, label] of [['pending', 'Waiting'], ['approved', 'Approved'],
    ['rejected', 'Rejected'], ['all', 'All']]) {
    const n = k === 'all' ? null : (counts || {})[k];
    const b = el('button', { type: 'button',
      className: 'rq-tab' + (rqStatus === k ? ' on' : '') }, [
      text(label),
      n != null ? el('span', { className: 'rq-tab-n' }, text(n)) : null,
    ]);
    b.onclick = () => { rqStatus = k; loadRequests(); };
    tabs.append(b);
  }
  const notify = $('reqNotify');
  const sound = $('reqSound');
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  const on = rqPref(RQ_NOTIFY_KEY) && perm === 'granted';
  notify.textContent = perm === 'denied' ? '🔕 Notifications blocked'
    : perm === 'unsupported' ? '🔕 No notifications here'
    : on ? '🔔 Notifications on' : '🔔 Notify me';
  notify.className = 'b' + (on ? ' rq-on' : '');
  notify.disabled = perm === 'denied' || perm === 'unsupported';
  notify.onclick = async () => {
    if (on) { rqSetPref(RQ_NOTIFY_KEY, false); return rqDrawControls(counts); }
    const r = await Notification.requestPermission();
    rqSetPref(RQ_NOTIFY_KEY, r === 'granted');
    if (r === 'granted') rqSetPref(RQ_SOUND_KEY, true);
    rqDrawControls(counts);
  };
  const s = rqPref(RQ_SOUND_KEY);
  sound.textContent = s ? '🔊 Sound on' : '🔈 Sound off';
  sound.className = 'b' + (s ? ' rq-on' : '');
  sound.onclick = () => {
    rqSetPref(RQ_SOUND_KEY, !s);
    if (!s) rqChime();
    rqDrawControls(counts);
  };
}

async function loadRequests() {
  const host = $('reqList');
  if (!rqMayDecide()) {
    host.textContent = '';
    host.append(el('div', { className: 'empty' },
      text('Payments are an editor\'s: approving one gives somebody Premium.')));
    return;
  }
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  let inbox;
  try {
    inbox = await api({ op: 'inbox', status: rqStatus }, PREMIUM_API);
  } catch (e) {
    host.textContent = '';
    return say('bad', String(e.message || e));
  }
  rqDrawControls(inbox.counts);
  const rows = inbox.requests || [];
  // The receipts, as ten-minute signed addresses. A failure here leaves the
  // list usable: everything but the picture is still on the card.
  let urls = {};
  const withProof = rows.filter((r) => r.proof_path).map((r) => r.id);
  if (withProof.length) {
    try {
      urls = (await api({ op: 'proofs', ids: withProof.slice(0, 60) }, PREMIUM_API)).urls || {};
    } catch (e) { say('bad', 'Receipts could not be loaded: ' + String(e.message || e)); }
  }
  host.textContent = '';
  if (!rows.length) {
    host.append(el('div', { className: 'rq-empty' }, [
      el('div', { className: 'rq-empty-ico' }, text(rqStatus === 'pending' ? '✓' : '·')),
      el('div', {}, text(rqStatus === 'pending'
        ? 'All caught up — no payment is waiting.'
        : 'Nothing here yet.')),
    ]));
  }
  for (const r of rows) host.append(rqCard(r, urls[r.id]));

  // Marked seen when a person has the list in front of them, not when a
  // background tab loads it.
  const unseen = rows.filter((r) => r.status === 'pending' && !r.seen_at).map((r) => r.id);
  if (unseen.length && !document.hidden) {
    try {
      await rqQuiet({ op: 'seen', ids: unseen });
      rqPulse();
    } catch { /* stays unseen; the badge says so */ }
  }
}

function rqCard(r, url) {
  const pending = r.status === 'pending';
  const proof = url
    ? el('button', { type: 'button', className: 'rq-proof', title: 'Open the receipt' },
      [el('img', { src: url, alt: 'Payment receipt', loading: 'lazy' })])
    : el('div', { className: 'rq-proof none' },
      text(r.proof_path ? 'receipt…' : 'no screenshot'));
  if (url) proof.onclick = () => rqLightbox(url, r);

  const who = r.display_name || r.email || r.phone || String(r.user_id || r.id).slice(0, 8);
  const badges = [];
  if (pending && !r.seen_at) badges.push(el('span', { className: 'chip draft' }, text('NEW')));
  if (r.approved_before > 0) {
    badges.push(el('span', { className: 'chip ok' },
      text('Returning · paid ' + r.approved_before + '×')));
  }
  if (r.premium_until && new Date(r.premium_until) > new Date()) {
    badges.push(el('span', { className: 'chip info' },
      text('Premium until ' + r.premium_until.slice(0, 10))));
  }
  if (r.duplicate_of) {
    badges.push(el('span', { className: 'chip bad' },
      text('⚠ Receipt already used (' + String(r.duplicate_of).slice(0, 8) + ')')));
  }

  const facts = [
    r.sender_phone ? ['Paid from', r.sender_phone] : null,
    r.reference ? ['Transaction', r.reference] : null,
    r.email && r.display_name ? ['Account', r.email] : null,
    ['Sent', rqWhen(r.submitted_at) + ' · ' + rqAgo(r.submitted_at)],
  ].filter(Boolean);

  const main = el('div', { className: 'rq-main' }, [
    el('div', { className: 'rq-top' }, [
      el('div', { className: 'rq-who' }, text(who)),
      el('div', { className: 'rq-plan' }, [
        el('span', { className: 'rq-plan-id' }, text(r.plan_id)),
        r.price_shown ? el('span', { className: 'rq-price' }, text(r.price_shown)) : null,
      ]),
    ]),
    badges.length ? el('div', { className: 'rq-badges' }, badges) : null,
    r.message ? el('blockquote', { className: 'rq-msg' }, text(r.message)) : null,
    el('dl', { className: 'rq-facts' }, facts.flatMap(([k, v]) =>
      [el('dt', {}, text(k)), el('dd', { className: k === 'Transaction' ? 'mono' : '' }, text(v))])),
    pending ? rqActions(r) : rqOutcome(r),
  ]);
  return el('article', { className: 'rq-card' + (pending && !r.seen_at ? ' new' : '') },
    [proof, main]);
}

function rqOutcome(r) {
  const ok = r.status === 'approved';
  return el('div', { className: 'rq-outcome ' + (ok ? 'ok' : 'bad') }, [
    el('span', { className: 'rq-outcome-t' }, text(ok ? '✓ Approved' : '✕ Rejected')),
    el('span', {}, text([r.reviewed_by ? 'by ' + r.reviewed_by : null,
      r.reviewed_at ? rqWhen(r.reviewed_at) : null].filter(Boolean).join(' · '))),
    r.note ? el('div', { className: 'rq-outcome-note' }, text('“' + r.note + '”')) : null,
  ]);
}

function rqActions(r) {
  const days = el('select', { className: 'rq-days', title: 'Premium for' },
    [7, 30, 90, 180, 365, 730].map((d) => el('option', { value: String(d) },
      text(d === 365 ? '1 year' : d === 730 ? '2 years' : d + ' days'))));
  days.value = String(rqDaysFor(r.plan_id));
  const note = el('input', { type: 'text', maxLength: 300, className: 'rq-note',
    placeholder: 'A word to the payer (optional) — e.g. “Thank you!”' });
  const ok = el('button', { className: 'b p rq-approve', type: 'button' }, text('Approve'));
  const no = el('button', { className: 'b d', type: 'button' }, text('Reject…'));
  const row = el('div', { className: 'rq-acts' }, [
    el('label', { className: 'rq-for' }, [text('Premium for'), days]), note, ok, no]);

  const busy = (b) => { ok.disabled = no.disabled = b; };
  ok.onclick = async () => {
    busy(true);
    try {
      await api({ op: 'approve', id: r.id, days: Number(days.value) || 365,
        note: note.value.trim() || undefined }, PREMIUM_API);
      say('ok', 'Approved — ' + (r.display_name || r.email || 'the payer') +
        ' is Premium for ' + days.selectedOptions[0].textContent + '.');
      loadRequests();
      rqPulse();
    } catch (e) { say('bad', String(e.message || e)); busy(false); }
  };
  no.onclick = () => {
    const pick = el('select', {}, [
      ...RQ_REASONS.map((t) => el('option', { value: t }, text(t))),
      el('option', { value: '' }, text('Something else…')),
    ]);
    const other = el('input', { type: 'text', maxLength: 300, hidden: true,
      placeholder: 'The reason, as the payer will read it' });
    pick.onchange = () => { other.hidden = pick.value !== ''; if (!other.hidden) other.focus(); };
    const send = el('button', { className: 'b d', type: 'button' }, text('Reject with this reason'));
    const back = el('button', { className: 'b', type: 'button' }, text('Cancel'));
    const box = el('div', { className: 'rq-reject' }, [
      el('div', { className: 'hint' }, text('The payer\'s app shows this reason.')),
      pick, other, el('div', { className: 'rq-acts' }, [send, back])]);
    row.replaceWith(box);
    back.onclick = () => box.replaceWith(row);
    send.onclick = async () => {
      const reason = (pick.value || other.value).trim();
      if (!reason) { other.focus(); return; }
      send.disabled = back.disabled = true;
      try {
        await api({ op: 'reject', id: r.id, note: reason }, PREMIUM_API);
        say('ok', 'Rejected. The payer sees: “' + reason + '”');
        loadRequests();
        rqPulse();
      } catch (e) { say('bad', String(e.message || e)); send.disabled = back.disabled = false; }
    };
  };
  return row;
}

/// The receipt, full screen, over the page — zoomable by the browser, closed
/// by a tap, Escape or Back.
function rqLightbox(url, r) {
  const img = el('img', { src: url, alt: 'Payment receipt' });
  const cap = el('div', { className: 'rq-light-cap' }, text(
    [r.display_name || r.email, r.plan_id, r.price_shown].filter(Boolean).join(' · ')));
  const full = el('a', { href: url, target: '_blank', rel: 'noopener', className: 'b' },
    text('Open original'));
  const box = el('div', { className: 'rq-light' },
    [img, el('div', { className: 'rq-light-bar' }, [cap, full])]);
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-label', 'Receipt');
  const close = () => { box.remove(); document.removeEventListener('keydown', esc); };
  const esc = (e) => { if (e.key === 'Escape') close(); };
  box.onclick = (e) => { if (e.target !== full) close(); };
  document.addEventListener('keydown', esc);
  document.body.append(box);
}
