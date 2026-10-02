// Innocent Studio — the Storage page: Telegram is the archive, R2 the working set.
//
// WHAT IT SHOWS. What R2 holds and what it costs against the free 10 GB; for
// every title, how much of it is in R2, how much only in Telegram, whether
// its Telegram copy was looked at lately and was still there, and when it
// was last watched. Why Infrequent Access is not used, in numbers.
//
// WHAT IT DOES, AND WHO MAY (migration 029 checks every one again).
//   * Pin — keep everything of a title in R2, whatever the policy says (owner)
//   * Keep only in Telegram — a film's original leaves R2; its streaming
//     copies stay, so the app plays exactly as before                   (owner)
//   * Bring back — the original back in R2, from the bin or Telegram  (editor)
//   * Archive — every file of the title's films leaves R2 and the title
//     leaves the app; Restore puts it back as it was                   (owner)
//   * Restore                                                         (editor)
//   * Check the Telegram copy now                                     (editor)
//   * The automatic policy and the alert threshold                     (owner)
// Nothing leaves R2 at once: it waits in the bin for seven days, and is only
// deleted if the runner has seen the same file in Telegram in the last three.
//
// Classic script, functions only — like the others.

let stData = null;

function stSize(b) {
  b = Number(b) || 0;
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
  if (b >= 1e3) return Math.round(b / 1e3) + ' KB';
  return b + ' B';
}
const stIsOwner = () => !!ME && ME.role === 'owner';
const stMoney = (x) => x <= 0 ? '$0' : x < 0.01 ? '<$0.01' : '$' + x.toFixed(2);

/// What a month costs, by R2's published prices (sent by the server so the
/// page cannot disagree with it). Standard: the first 10 GB free. Infrequent
/// Access: no free tier, and every byte read is charged.
function stMonthly(gbStandard, gbIa, gbReadFromIa, price) {
  const std = Math.max(0, gbStandard - price.freeGb) * price.perGbMonth;
  const ia = gbIa * price.iaPerGbMonth + gbReadFromIa * price.iaRetrievalPerGb;
  return std + ia;
}

async function loadStorage() {
  const host = $('stBody');
  if (!host) return;
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  try {
    stData = await api({ op: 'storageOverview' });
  } catch (e) {
    host.textContent = '';
    say('bad', String(e.message || e));
    return;
  }
  stDraw();
}

function stDraw() {
  const host = $('stBody');
  host.textContent = '';
  const d = stData;
  const price = d.price;
  const rows = (d.titles || []).filter((t) => t.films > 0);
  const inR2 = Number(d.catalogueBytes) || 0;
  const onlyTg = rows.reduce((a, t) => a + Number(t.master_bytes_telegram || 0), 0);
  const withCopy = rows.reduce((a, t) => a + Number(t.films_with_copy || 0), 0);
  const films = rows.reduce((a, t) => a + Number(t.films || 0), 0);
  const bad = rows.reduce((a, t) => a + Number(t.copies_bad || 0), 0);
  const gb = inR2 / 1e9;
  const month = stMonthly(gb, 0, 0, price);

  host.append(el('div', { className: 'cr-kpis' }, [
    stKpi('In R2', stSize(inR2), Math.round(100 * gb / price.freeGb) + '% of the free 10 GB'),
    stKpi('Per month', stMoney(month), month > 0 ? 'beyond the free 10 GB' : 'inside the free 10 GB'),
    stKpi('Only in Telegram', stSize(onlyTg), 'originals R2 does not hold'),
    stKpi('Telegram copies', withCopy + ' of ' + films,
      bad ? bad + ' GONE or changed' : 'films that can be fetched again', bad ? 'bad' : ''),
  ]));

  host.append(stAdvice(rows, inR2, price));
  if (stIsOwner()) host.append(stPolicy(d.settings || {}));

  const filter = el('input', { placeholder: 'Find a title', style: 'max-width:260px' });
  const list = el('div', { className: 'st-list' });
  const draw = () => {
    list.textContent = '';
    const q = filter.value.trim().toLowerCase();
    const shown = rows.filter((t) => !q || String(t.title || '').toLowerCase().includes(q) ||
      String(t.slug || '').includes(q));
    if (!shown.length) list.append(el('div', { className: 'empty' }, text(rows.length ? 'No title matches.' : 'No films yet.')));
    for (const t of shown) list.append(stRow(t));
  };
  filter.oninput = draw;
  host.append(el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Titles')), el('span', { className: 'spacer' }), filter]),
    el('p', { className: 'hint' }, text(
      'Biggest first. A film forwarded to the bot has a Telegram copy at once; one uploaded from the ' +
      'console gets one when the runner copies it to the archive channel (Status page) — until then ' +
      'it exists only in R2 and stays there.')),
    list,
  ]));
  draw();

  if ((d.jobs || []).length) host.append(stJobs(d.jobs, d.titles || []));
}

function stKpi(k, v, sub, tone) {
  return el('div', { className: 'cr-kpi' + (tone ? ' ' + tone : '') }, [
    el('div', { className: 'k' }, text(k)), el('div', { className: 'v' }, text(v)),
    el('div', { className: 's' }, text(sub)),
  ]);
}

/// WHY NOT INFREQUENT ACCESS, with this catalogue's own numbers: the titles
/// nobody watched in 30 days, what they would cost there, and what they cost
/// now. Advice only — moving storage class is not something this page does.
function stAdvice(rows, inR2, price) {
  const cold = rows.filter((t) => t.storage_state === 'hot' && !t.pinned && Number(t.views_30d || 0) === 0);
  const coldBytes = cold.reduce((a, t) => a + Number(t.master_bytes_r2 || 0) + Number(t.ladder_bytes || 0), 0);
  const now = stMonthly(inR2 / 1e9, 0, 0, price);
  const withIa = stMonthly((inR2 - coldBytes) / 1e9, coldBytes / 1e9, 0, price);
  const verdict = coldBytes === 0
    ? 'Every title was watched in the last 30 days.'
    : withIa < now
      ? 'Infrequent Access would save ' + stMoney(now - withIa) + ' a month on ' + stSize(coldBytes) +
        ' nobody watched in 30 days — before the charge for every byte read and the 30-day minimum. ' +
        'Archiving them saves all of it.'
      : 'Infrequent Access would cost ' + stMoney(withIa) + ' a month instead of ' + stMoney(now) +
        ': it has no free tier, so moving ' + stSize(coldBytes) + ' out of the free 10 GB costs money. Not used.';
  return el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Cheaper storage'))]),
    el('p', { className: 'hint' }, text(verdict)),
  ]);
}

function stPolicy(s) {
  const auto = el('input', { type: 'checkbox' });
  auto.checked = !!s.auto_offload;
  const alert = el('input', { type: 'number', min: '0', step: '0.5', value: String(s.storage_alert_gb ?? 9),
    style: 'max-width:90px' });
  const save = el('button', { className: 'b', type: 'button' }, text('Save'));
  save.onclick = async () => {
    if (auto.checked && !s.auto_offload && !confirm(
      'Free originals automatically? A film\'s original will leave R2 a day after its streaming copies ' +
      'are made, if its Telegram copy was just checked. The app keeps playing the streaming copies; ' +
      'downloads get the best streaming copy instead of the original.')) return;
    save.disabled = true;
    try {
      await api({ op: 'storageSettings', autoOffload: auto.checked, alertGb: Number(alert.value) });
      say('ok', 'Storage policy saved.');
      loadStorage();
    } catch (e) { say('bad', String(e.message || e)); save.disabled = false; }
  };
  return el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Policy'))]),
    el('label', { className: 'st-opt' }, [auto, text(' Keep originals only in Telegram automatically, once their streaming copies exist')]),
    el('label', { className: 'st-opt' }, [text('Tell me in Telegram when R2 passes '), alert, text(' GB')]),
    el('div', { className: 'srow' }, [save]),
    s.storage_notice ? el('p', { className: 'hint' }, text('Last notice: ' + s.storage_notice)) : null,
  ]);
}

function stCopyWords(f) {
  if (!f.copy) return { t: 'no Telegram copy', c: '' };
  if (f.copy === 'missing') return { t: 'Telegram copy GONE', c: 'bad' };
  if (f.copy === 'changed') return { t: 'Telegram copy is a different file', c: 'bad' };
  if (f.copy === 'ok' && f.verified_at) {
    const days = Math.floor((Date.now() - Date.parse(f.verified_at)) / 86400000);
    return { t: 'Telegram copy checked ' + (days <= 0 ? 'today' : days + ' day(s) ago'), c: days <= 3 ? 'ok' : '' };
  }
  return { t: 'Telegram copy not checked yet', c: 'info' };
}

function stRow(t) {
  const state = t.storage_state === 'archived' ? { t: 'archived', c: 'draft' }
    : t.storage_state === 'restoring' ? { t: 'restoring', c: 'info' }
      : t.published ? { t: 'in the app', c: 'ok' } : { t: 'draft', c: '' };
  const chips = [el('span', { className: 'chip ' + state.c }, text(state.t))];
  if (t.pinned) chips.push(el('span', { className: 'chip ok' }, text('pinned')));
  const facts = [
    'R2 ' + stSize(Number(t.master_bytes_r2 || 0) + Number(t.ladder_bytes || 0) + Number(t.other_bytes || 0)),
  ];
  if (Number(t.master_bytes_telegram) > 0) facts.push('only in Telegram ' + stSize(t.master_bytes_telegram));
  facts.push(t.last_viewed ? 'last watched ' + t.last_viewed : 'never watched');
  if (t.views_30d) facts.push(t.views_30d + ' view(s) in 30 days');

  const acts = [];
  const owner = stIsOwner();
  const allCopies = t.films > 0 && t.films_with_copy === t.films;
  if (owner) {
    const pin = el('button', { className: 'b', type: 'button' }, text(t.pinned ? 'Unpin' : 'Pin'));
    pin.onclick = () => stDo({ op: 'storagePin', titleId: t.title_id, pinned: !t.pinned },
      t.pinned ? 'Unpinned.' : 'Pinned — everything of it stays in R2.');
    acts.push(pin);
  }
  if (t.storage_state === 'hot' && owner && !t.pinned) {
    const arc = el('button', { className: 'b d', type: 'button' }, text('Archive…'));
    arc.disabled = !allCopies;
    if (!allCopies) arc.title = 'Every film needs a Telegram copy first';
    arc.onclick = () => stArchiveDialog(t);
    acts.push(arc);
  }
  if (t.storage_state !== 'hot') {
    const back = el('button', { className: 'b p', type: 'button' }, text('Restore'));
    back.onclick = () => stDo({ op: 'titleRestore', titleId: t.title_id }, (r) => r.state === 'hot'
      ? 'Restored — it is back as it was.'
      : 'Restoring: ' + (r.fetching || 0) + ' film(s) are being fetched from Telegram; ' +
        'streaming copies are made again after. It goes back in the app by itself.');
    acts.push(back);
  }
  if (t.storage_state === 'restoring' && owner && /failed/.test(t.storage_note || '')) {
    const fin = el('button', { className: 'b', type: 'button' }, text('Finish restore'));
    fin.onclick = () => {
      if (!confirm('Put it back in the app on its originals, without streaming copies? It may stutter on slow connections.')) return;
      stDo({ op: 'titleRestoreFinish', titleId: t.title_id }, 'Back in the app.');
    };
    acts.push(fin);
  }
  if (t.films_with_copy > 0) {
    const chk = el('button', { className: 'b', type: 'button' }, text('Check Telegram copy'));
    chk.onclick = () => stDo({ op: 'vaultCheck', titleId: t.title_id },
      'Asked — the next runner tick looks (usually within twenty minutes).');
    acts.push(chk);
  }

  const films = el('div', { className: 'st-films' });
  for (const f of t.assets || []) {
    const cw = stCopyWords(f);
    const where = f.master === 'r2' ? 'original in R2' : f.master === 'restoring' ? 'original coming back from Telegram'
      : 'original only in Telegram';
    const fa = [];
    if (t.storage_state === 'hot' && owner && f.master === 'r2' && f.ladder && f.copy && !t.pinned) {
      const off = el('button', { className: 'b', type: 'button' }, text('Keep only in Telegram'));
      off.onclick = () => {
        if (!confirm('Take this film\'s original out of R2? Its streaming copies stay, so the app plays as before; ' +
          'downloads get the best streaming copy. The original waits in the bin for seven days and is deleted ' +
          'only if its Telegram copy was seen in the last three.')) return;
        stDo({ op: 'masterOffload', assetId: f.id }, 'The original is in the bin; Telegram keeps it.');
      };
      fa.push(off);
    }
    if (t.storage_state === 'hot' && f.master === 'telegram') {
      const keep = el('button', { className: 'b', type: 'button' }, text('Bring the original back'));
      keep.onclick = () => stDo({ op: 'masterKeep', assetId: f.id }, (r) => r.result === 'kept'
        ? 'Back in R2 (it was still in the bin).' : 'Being fetched from Telegram.');
      fa.push(keep);
    }
    films.append(el('div', { className: 'st-film' }, [
      el('div', { className: 'st-fmain' }, [
        el('div', { className: 'mono fm-dim' }, text((f.key || '').split('/').pop())),
        el('div', { className: 'fm-dim' }, text(stSize(f.bytes) + ' · ' + where +
          (f.ladder ? ' · streaming copies ready' : ''))),
      ]),
      el('span', { className: 'chip ' + cw.c }, text(cw.t)),
      fa.length ? el('div', { className: 'st-facts' }, fa) : null,
    ]));
  }

  return el('div', { className: 'cr-rv st-row' }, [el('div', { className: 'cr-rv-main' }, [
    el('div', { className: 'st-head' }, [el('b', { className: 'cr-rv-title' }, text(t.title || t.slug || 'untitled')), ...chips]),
    el('div', { className: 'cr-rv-facts' }, text(facts.join(' · '))),
    t.storage_note ? el('div', { className: 'cr-rv-note' }, text(t.storage_note)) : null,
    films,
    acts.length ? el('div', { className: 'cr-rv-acts' }, acts) : null,
  ])]);
}

/// Archive: typed, like a delete, because it takes a title out of the app.
function stArchiveDialog(t) {
  const input = el('input', { placeholder: 'Type ARCHIVE', autocapitalize: 'characters' });
  const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px' });
  const go = el('button', { className: 'b d', type: 'button' }, text('Archive'));
  const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
  const total = Number(t.master_bytes_r2 || 0) + Number(t.ladder_bytes || 0);
  const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [el('div', { className: 'cr-dlg-in' }, [
    el('h3', {}, text('Archive “' + (t.title || t.slug) + '”')),
    el('p', { className: 'hint' }, text(
      'It leaves the app now. Its films (' + stSize(total) + ' with their streaming copies) go to the bin ' +
      'and are deleted from R2 after seven days — only if the runner has seen them in Telegram in the last ' +
      'three. Its photos stay. Restore brings it back: at once while the files are in the bin, from Telegram after.')),
    input, err,
    el('div', { className: 'srow end' }, [cancel, go]),
  ])]);
  cancel.onclick = () => dlg.remove();
  go.onclick = async () => {
    if (input.value.trim() !== 'ARCHIVE') { err.textContent = 'Type ARCHIVE to confirm.'; return; }
    go.disabled = true;
    try {
      const r = await api({ op: 'titleArchive', titleId: t.title_id, confirm: 'ARCHIVE' });
      dlg.remove();
      say('ok', 'Archived — ' + r.binned + ' file(s) in the bin for seven days.');
      loadStorage();
    } catch (e) {
      go.disabled = false;
      err.textContent = String(e.message || e);
    }
  };
  document.body.append(dlg);
  input.focus();
}

async function stDo(payload, done) {
  try {
    const r = await api(payload);
    say('ok', typeof done === 'function' ? done(r) : done);
    loadStorage();
  } catch (e) { say('bad', String(e.message || e)); }
}

function stJobs(jobs, titles) {
  const byAsset = new Map();
  for (const t of titles) for (const f of t.assets || []) byAsset.set(f.id, t.title || t.slug);
  const sec = el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Telegram work'))]),
    el('p', { className: 'hint' }, text('Checks and restores, done by the runner that fetches forwarded films.')),
  ]);
  for (const j of jobs) {
    const tone = j.state === 'failed' ? ' no' : '';
    sec.append(el('div', { className: 'cr-line' + tone }, [
      el('span', { className: 'cr-ok' }),
      el('span', {}, [
        el('span', { className: 'cr-act' }, text((j.kind === 'restore' ? 'restore' : 'check') + ' · ' + j.state)),
        text(' '),
        el('span', { className: 'cr-who' }, text(byAsset.get(j.asset_id) || '')),
      ]),
      el('span', { className: 'cr-at' }, text(crWhen(j.finished_at || j.created_at))),
      el('span', { className: 'cr-tgt' }, text(j.note || '')),
    ]));
  }
  return sec;
}
