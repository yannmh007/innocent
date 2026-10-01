// Innocent Studio — the review queue.
//
// THE RULE: nothing reaches the app without one approval. Forwarded to the
// bot or uploaded here, a title is born a draft; whoever made it sends it for
// review; an editor or the owner watches it here and taps Approve. That is the
// whole flow, and on purpose — the operator asked for it not to be
// complicated.
//
//   editing  →  ready (waiting)  →  approved (live)
//                  ↓  sent back with a note  →  editing again
//                  ↓  rejected  →  out of the queue (can be reopened)
//
// THE PAGE DECIDES NOTHING. Every button sends one op; the database function
// `review_decide` checks the role, the state, the files and the two-person
// rule, and the page only shows what it answered. Buttons are hidden from a
// role that cannot use them because a button that always says "not allowed"
// is noise, not because hiding them is the protection.
//
// Classic script, functions only — like shell.js and control.js.

const RV_RANK = { viewer: 1, uploader: 2, editor: 3, owner: 4 };
const rvIsEditor = () => !!ME && RV_RANK[ME.role] >= RV_RANK.editor;
const rvIsMine = (createdBy) => !!ME && !!ME.id && createdBy === ME.id;

/// The chip a title wears everywhere: Library, Review, the editor.
function reviewChip(t) {
  if (t.published) return { cls: 'chip ok', label: 'live' };
  switch (t.review_state) {
    case 'ready': return { cls: 'chip info', label: 'waiting' };
    case 'changes': return { cls: 'chip draft', label: 'sent back' };
    case 'rejected': return { cls: 'chip bad', label: 'rejected' };
    default: return { cls: 'chip draft', label: 'draft' };
  }
}

/// What each review op says when it worked.
const RV_DONE = {
  reviewSubmit: 'Sent for review. The owner is told in Telegram.',
  reviewApprove: 'Approved — it is in the app now.',
  reviewSendBack: 'Sent back with your note.',
  reviewReject: 'Rejected. It has left the queue; it can be reopened.',
  reviewReopen: 'Reopened as a draft.',
  unpublish: 'Taken down. It is a draft again and no longer in the app.',
};

/// One decision. Asks for the note where one is wanted, sends the op, says
/// what happened, and redraws whatever is on screen.
async function decide(op, t, btn) {
  let note = '';
  if (op === 'reviewSendBack') {
    note = await askNote('Send back', 'What needs changing? The person who made it sees this.', true);
    if (note === null) return;
  } else if (op === 'reviewReject') {
    note = await askNote('Reject', 'Why? (optional)', false);
    if (note === null) return;
  } else if (op === 'unpublish') {
    if (!confirm('Take "' + (t.title || '') + '" out of the app? It becomes a draft again.')) return;
    note = await askNote('Take down', 'Why? (optional)', false);
    if (note === null) return;
  }
  if (btn) btn.disabled = true;
  try {
    await api({ op, id: t.id, note });
    say('ok', RV_DONE[op] || 'Done.');
    refreshBadges();
    if (!$('tab-review').hidden) loadReview();
    if (!$('tab-editor').hidden && cur && cur.title && cur.title.id === t.id) {
      await reloadReviewState();
    }
  } catch (e) {
    say('bad', String(e.message || e));
  }
  if (btn) btn.disabled = false;
}

/// A small dialog for a note. Resolves the text, or null on Cancel. When
/// `required`, an empty note is not accepted — a send-back with no reason is
/// a puzzle for whoever gets it.
function askNote(title, words, required) {
  return new Promise((resolve) => {
    const ta = el('textarea', { rows: 4, placeholder: words });
    const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px' });
    const ok = el('button', { className: 'b p', type: 'button' }, text(title));
    const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
    const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [
      el('div', { className: 'cr-dlg-in' }, [
        el('h3', {}, text(title)), ta, err,
        el('div', { className: 'srow end' }, [cancel, ok]),
      ]),
    ]);
    const finish = (v) => { dlg.remove(); resolve(v); };
    ok.onclick = () => {
      const v = ta.value.trim();
      if (required && !v) { err.textContent = 'Say what needs changing.'; return; }
      finish(v);
    };
    cancel.onclick = () => finish(null);
    document.body.append(dlg);
    ta.focus();
  });
}

// ── the Review page ──────────────────────────────────────────────────────

async function loadReview() {
  const host = $('revBody');
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  let rows;
  let inbox = [];
  try {
    const [q, ing] = await Promise.all([
      api({ op: 'reviewQueue' }),
      api({ op: 'list' }, INGEST_API).catch(() => ({ rows: [] })),
    ]);
    rows = q.rows || [];
    if (q.me && ME) ME.id = q.me;
    inbox = (ing.rows || []).filter((r) => r.state === 'done' && !r.title_id);
  } catch (e) {
    host.textContent = '';
    say('bad', String(e.message || e));
    return;
  }
  host.textContent = '';

  const by = (s) => rows.filter((r) => r.review_state === s);
  const waiting = by('ready');
  const back = by('changes');
  const drafts = by('editing');
  const rejected = by('rejected');
  const folders = rvInboxFolders(inbox);

  host.append(el('div', { className: 'cr-kpis' }, [
    rvKpi('Waiting', waiting.length, 'for an approval', waiting.length ? 'warn' : ''),
    rvKpi('Sent back', back.length, 'with a note'),
    rvKpi('Drafts', drafts.length, 'being prepared'),
    rvKpi('Telegram', inbox.length, 'files in no title yet', inbox.length ? 'warn' : ''),
  ]));

  rvSection(host, 'Waiting for approval', waiting,
    rvIsEditor() ? 'Watch it, then Approve — one tap puts it in the app.'
      : 'An editor or the owner approves these.',
    'Nothing is waiting.');
  if (folders.length) {
    const sec = el('div', { className: 'sec' }, [
      el('div', { className: 'sechead' }, [
        el('h2', {}, text('From Telegram, not yet a title')),
        el('span', { className: 'spacer' }),
        el('a', { className: 'sh-link', href: '#/telegram' }, text('Telegram page')),
      ]),
      el('p', { className: 'hint' }, text(
        'Make a title from an album, then send it for review like anything else.')),
    ]);
    for (const f of folders) sec.append(rvInboxCard(f));
    host.append(sec);
  }
  rvSection(host, 'Sent back', back, 'Fix what the note says, then send it again.', null);
  rvSection(host, 'Drafts being prepared', drafts,
    'Not sent for review yet. Open one to finish it.', null);
  if (rejected.length) {
    const det = el('details', { className: 'sec' }, [
      el('summary', {}, el('h2', { style: 'display:inline' },
        text('Rejected (' + rejected.length + ')'))),
    ]);
    for (const t of rejected) det.append(rvCard(t));
    host.append(det);
  }
}

function rvKpi(k, v, sub, tone) {
  return el('div', { className: 'cr-kpi' + (tone ? ' ' + tone : '') }, [
    el('div', { className: 'k' }, text(k)),
    el('div', { className: 'v' }, text(v)),
    el('div', { className: 's' }, text(sub)),
  ]);
}

function rvSection(host, title, rows, hint, empty) {
  if (!rows.length && empty === null) return;
  const sec = el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text(title)),
      el('span', { className: 'hint' }, text(rows.length ? String(rows.length) : ''))]),
    el('p', { className: 'hint' }, text(hint)),
  ]);
  if (!rows.length) sec.append(el('div', { className: 'empty' }, text(empty)));
  for (const t of rows) sec.append(rvCard(t));
  host.append(sec);
}

/// One title in the queue: its cover, who made it, what is in it, the note
/// if it was sent back, and the buttons this admin can use.
function rvCard(t) {
  const chip = reviewChip(t);
  const img = el('img', { className: 'cr-rv-cover', alt: '', loading: 'lazy' });
  if (t.poster_url) img.src = t.poster_url;
  const when = t.review_state === 'ready' ? t.submitted_at : (t.decided_at || t.created_at);
  const facts = [
    t.creator_email ? 'by ' + t.creator_email : null,
    when ? crWhen(when) : null,
    (t.videos || 0) + ' video, ' + (t.photos || 0) + ' photo',
    t.category || null,
  ].filter(Boolean).join(' · ');

  const open = el('button', { className: 'b', type: 'button' }, text('Open'));
  open.onclick = () => openEditor(t.id);
  const acts = [open, ...rvButtons(t)];

  return el('div', { className: 'cr-rv' }, [
    img,
    el('div', { className: 'cr-rv-main' }, [
      el('div', { className: 'cr-rv-title' }, [
        el('span', { className: chip.cls }, text(chip.label)), text(' '),
        el('b', {}, text(t.title || '(untitled)')),
        t.title_mm ? el('span', { className: 'cr-rv-mm' }, text(' ' + t.title_mm)) : null,
      ]),
      el('div', { className: 'cr-rv-facts' }, text(facts)),
      t.review_note ? el('div', { className: 'cr-rv-note' }, text(
        (t.review_state === 'rejected' ? 'Rejected: ' : 'Sent back: ') + t.review_note +
        (t.decider_email ? ' — ' + t.decider_email : ''))) : null,
      el('div', { className: 'cr-rv-acts' }, acts),
    ]),
  ]);
}

/// The decisions this admin can make on this title, as buttons.
function rvButtons(t) {
  const out = [];
  const add = (op, label, cls) => {
    const b = el('button', { className: 'b' + (cls ? ' ' + cls : ''), type: 'button' }, text(label));
    b.onclick = () => decide(op, t, b);
    out.push(b);
  };
  const editor = rvIsEditor();
  const mine = rvIsMine(t.created_by);
  if (t.published) {
    if (editor) add('unpublish', 'Take down', 'd');
    return out;
  }
  const st = t.review_state || 'editing';
  if (st === 'rejected') {
    if (editor || mine) add('reviewReopen', 'Reopen');
    return out;
  }
  if (editor && st !== 'rejected') add('reviewApprove', 'Approve', 'p');
  if ((st === 'editing' || st === 'changes') && (editor || mine)) {
    add('reviewSubmit', 'Send for review');
  }
  if (editor && (st === 'ready' || st === 'editing')) add('reviewSendBack', 'Send back');
  if (editor) add('reviewReject', 'Reject', 'd');
  return out;
}

/// Telegram files in no title, grouped by the folder the album agreed on.
/// `inbox` — files forwarded with no caption — is one group of loose files.
function rvInboxFolders(rows) {
  const by = new Map();
  for (const r of rows) {
    const folder = String(r.object_key || '').split('/')[0] || 'inbox';
    if (!by.has(folder)) by.set(folder, { folder, files: [], caption: '' });
    const g = by.get(folder);
    g.files.push(r);
    if (!g.caption && r.tg_caption) g.caption = r.tg_caption;
  }
  return [...by.values()];
}

function rvInboxCard(g) {
  const videos = g.files.filter((f) => f.kind !== 'photo').length;
  const first = (g.caption || '').split('\n')[0].trim();
  const acts = [];
  if (g.folder !== 'inbox' && RV_RANK[ME.role] >= RV_RANK.uploader) {
    const make = el('button', { className: 'b p', type: 'button' }, text('New title from this'));
    make.onclick = () => startTitleFromIngest(g.folder, g.caption, make);
    acts.push(make);
  }
  if (rvIsEditor()) {
    const drop = el('button', { className: 'b d', type: 'button' }, text('Discard'));
    drop.onclick = async () => {
      const what = g.folder === 'inbox' ? 'these ' + g.files.length + ' loose file(s)'
        : 'the album "' + (first || g.folder) + '"';
      if (!confirm('Discard ' + what + '? They leave the inbox; the files stay in R2 ' +
        'and can be forwarded again.')) return;
      drop.disabled = true;
      try {
        let n = 0;
        if (g.folder === 'inbox') {
          for (const f of g.files) {
            n += (await api({ op: 'discard', job_id: f.id }, INGEST_API)).discarded || 0;
          }
        } else {
          n = (await api({ op: 'discard', folder: g.folder }, INGEST_API)).discarded || 0;
        }
        say('ok', 'Discarded ' + n + ' file(s).');
        refreshBadges();
        loadReview();
      } catch (e) {
        say('bad', String(e.message || e));
        drop.disabled = false;
      }
    };
    acts.push(drop);
  }
  return el('div', { className: 'cr-rv' }, [
    el('div', { className: 'cr-rv-cover cr-rv-tg' }, text('TG')),
    el('div', { className: 'cr-rv-main' }, [
      el('div', { className: 'cr-rv-title' }, [
        el('b', {}, text(g.folder === 'inbox' ? 'No caption (inbox)' : (first || g.folder))),
      ]),
      el('div', { className: 'cr-rv-facts' }, text(
        g.files.length + ' file(s) · ' + videos + ' video · folder ' + g.folder)),
      el('div', { className: 'cr-rv-acts' }, acts),
    ]),
  ]);
}

// ── the editor's review bar ──────────────────────────────────────────────

/// Under the editor's header: where this title stands, the note if any, and
/// the decisions. Replaces the old "Published" checkbox, which was a way to
/// go live that skipped every rule this page exists for.
function drawReviewBar() {
  const host = $('revBar');
  host.textContent = '';
  if (!cur || !cur.title) return;
  const t = cur.title;
  const chip = reviewChip(t);
  const words = t.published ? 'In the app.'
    : t.review_state === 'ready' ? 'Waiting for an editor to approve it.'
    : t.review_state === 'changes' ? 'Sent back — change it, then send it again.'
    : t.review_state === 'rejected' ? 'Rejected — not in the queue.'
    : 'Draft — not in the app. Send it for review when it is ready.';
  const btns = rvButtons(t);
  // Deciding on a title with unsaved typing would approve the old text.
  for (const b of btns) {
    const go = b.onclick;
    b.onclick = () => {
      if (dirty) { say('warn', 'Save your changes first, then decide.'); return; }
      go();
    };
  }
  const hist = el('details', { className: 'cr-hist' }, [el('summary', {}, text('History'))]);
  hist.ontoggle = async () => {
    if (!hist.open || hist.dataset.loaded) return;
    hist.dataset.loaded = '1';
    try {
      const { rows } = await api({ op: 'reviewHistory', id: t.id });
      if (!rows.length) hist.append(el('div', { className: 'hint' }, text('No decisions yet.')));
      for (const r of rows) {
        hist.append(el('div', { className: 'hint' }, text(
          crWhen(r.at) + ' — ' + (CR_REVIEW_WORDS[r.action] || r.action) + ' by ' +
          (r.actor_email || '?') + (r.note ? ': ' + r.note : ''))));
      }
    } catch (e) { hist.append(el('div', { className: 'hint' }, text(String(e.message || e)))); }
  };
  host.append(el('div', { className: 'cr-revbar' }, [
    el('span', { className: chip.cls }, text(chip.label)),
    el('span', { className: 'cr-revbar-words' }, text(words)),
    el('span', { className: 'spacer' }),
    ...btns,
  ]));
  if (t.review_note && !t.published) {
    host.append(el('div', { className: 'cr-rv-note' }, text(
      (t.review_state === 'rejected' ? 'Rejected: ' : 'Note: ') + t.review_note)));
  }
  host.append(hist);
}

const CR_REVIEW_WORDS = {
  submit: 'sent for review', approve: 'approved', send_back: 'sent back',
  reject: 'rejected', reopen: 'reopened', unpublish: 'taken down',
};

/// After a decision in the editor: the title's state changed, the form did
/// not. Re-reads the title and redraws the bar without touching the form.
async function reloadReviewState() {
  try {
    const fresh = await api({ op: 'get', id: cur.title.id });
    for (const k of ['published', 'status', 'review_state', 'review_note',
      'submitted_at', 'decided_at']) cur.title[k] = fresh.title[k];
    drawReviewBar();
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── watching a file inside the console ───────────────────────────────────

/// Plays a video (or shows a photo) from the title, in the console, before
/// anyone approves it. The URL lives ten minutes and goes through the same
/// Worker viewers use; for a large original the streaming copy is played
/// rather than the master, so a preview on mobile data costs what a viewer's
/// play would.
async function previewAsset(a) {
  let p;
  try {
    p = await api({ op: 'previewUrl', id: a.id });
  } catch (e) { say('bad', String(e.message || e)); return; }
  const media = p.kind === 'photo'
    ? el('img', { src: p.url, alt: '', style: 'width:100%;border-radius:6px' })
    : el('video', { src: p.url, controls: true, playsInline: true, autoplay: true,
      preload: 'metadata' });
  const close = el('button', { className: 'b', type: 'button' }, text('Close'));
  const back = el('div', { className: 'modal' }, [
    el('div', { className: 'sheet' }, [
      el('div', { className: 'sh' }, text(a.label || (a.object_key || '').split('/').pop() || 'Preview')),
      media,
      el('div', { className: 'hint', style: 'margin-top:6px' }, text(
        p.kind === 'photo' ? '' : (p.height ? p.height + 'p streaming copy' : 'original file') +
          (p.via === 'worker' ? ' · through the streaming Worker' : ' · straight from R2'))),
      el('div', { className: 'srow end' }, [close]),
    ]),
  ]);
  const shut = () => {
    if (media.pause) media.pause();
    media.removeAttribute('src');
    back.remove();
  };
  close.onclick = shut;
  back.onclick = (e) => { if (e.target === back) shut(); };
  if (media.addEventListener) {
    media.addEventListener('error', () => {
      say('bad', 'This file would not play here. If it is a format phones cannot ' +
        'decode, its streaming copies will be — they are made after upload.');
    });
  }
  document.body.append(back);
}
