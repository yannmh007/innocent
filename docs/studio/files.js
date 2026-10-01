// Innocent Studio — the Files page: what is in R2, who uses it, the bin, moves.
//
// WHAT IT SHOWS. Every folder with its size and how much of it nothing uses;
// inside a folder, every file with its size, the title that uses it (or
// "unused"), where it came from (upload, Telegram, a streaming copy) and what
// it costs a month. What it costs in all, against R2's free 10 GB.
//
// WHAT IT DOES, AND WHO MAY.
//   * a display name for a folder — instant, moves nothing      (editor)
//   * the bin: unused files wait seven days, then the runner
//     deletes them; restorable until then                       (owner)
//   * move: rename a folder, or gather one title's files into a
//     folder of its own (how the old flat v/… p/… uploads are
//     tidied) — copied inside R2, checked, every reference
//     switched in one transaction, the old files kept seven days (owner)
// Deleting and moving ask for the authenticator code (once 2-step is on) and
// for a typed confirmation. The database refuses to bin anything a title
// uses, and checks again on the day it is deleted.
//
// THE LISTING IS A COPY. Sizes and costs come from the console's own copy of
// the bucket listing (refreshed by Scan), not from R2 on every visit — that
// would be slow on a phone and slower as the catalogue grows. The date of the
// last scan is always shown.
//
// Classic script, functions only — like the others.

let fmData = null;     // the last filesSummary
let fmFolder = null;   // the folder open, or null for the overview
let fmScanning = false;

const fmGB = (b) => (b || 0) / 1e9;
function fmSize(b) {
  b = Number(b) || 0;
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
  if (b >= 1e3) return Math.round(b / 1e3) + ' KB';
  return b + ' B';
}
function fmCost(b) {
  const per = (fmData && fmData.price && fmData.price.perGbMonth) || 0.015;
  const c = fmGB(b) * per;
  return c >= 0.01 ? '$' + c.toFixed(2) : c > 0 ? '<$0.01' : '$0';
}
const fmIsOwner = () => !!ME && ME.role === 'owner';
const fmKind = (key) => {
  const m = /\/(video|photo|thumb)\/[^/]+$/.exec(key);
  if (m) return /-(\d{3,4})p\.mp4$/.test(key) ? 'copy' : m[1];
  return /^v\//.test(key) ? 'video' : /^p\//.test(key) ? 'photo' : 'file';
};

// ── the overview ─────────────────────────────────────────────────────────

async function loadFiles() {
  const host = $('fmBody');
  if (!host) return;
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  try {
    fmData = await api({ op: 'filesSummary' });
  } catch (e) {
    host.textContent = '';
    say('bad', String(e.message || e));
    return;
  }
  // Never scanned: scan now, once — an empty page would only say "press Scan".
  if (!(fmData.scans || []).length && !fmScanning) {
    await fmScan();
    return;
  }
  if (fmFolder !== null) return fmOpenFolder(fmFolder);
  fmDrawOverview();
}

function fmDrawOverview() {
  const host = $('fmBody');
  host.textContent = '';
  const d = fmData;
  const folders = d.folders || [];
  const total = folders.reduce((a, f) => a + Number(f.bytes || 0), 0);
  const unused = folders.reduce((a, f) => a + Number(f.unused_bytes || 0), 0);
  const binned = (d.bin || []).reduce((a, b) => a + Number(b.bytes || 0), 0);
  const free = (d.price && d.price.freeGb) || 10;
  const billed = Math.max(0, fmGB(total) - free) * ((d.price && d.price.perGbMonth) || 0.015);

  const scans = d.scans || [];
  const last = scans.map((s) => s.finished_at).filter(Boolean).sort().shift();
  const scan = el('button', { className: 'b', type: 'button' }, text(fmScanning ? 'Scanning…' : 'Scan again'));
  scan.disabled = fmScanning;
  scan.onclick = () => fmScan();

  host.append(
    el('div', { className: 'sechead', style: 'margin-top:4px' }, [
      el('h2', {}, text('Files in R2')),
      el('span', { className: 'spacer' }),
      el('span', { className: 'hint' }, text(last ? 'listing taken ' + crWhen(last) : 'not scanned yet')),
      scan,
    ]),
    el('div', { className: 'cr-kpis' }, [
      fmKpi('Stored', fmSize(total), folders.reduce((a, f) => a + (f.files || 0), 0) + ' files'),
      fmKpi('Per month', billed > 0 ? '$' + billed.toFixed(2) : '$0',
        billed > 0 ? 'beyond the free ' + free + ' GB' : 'inside the free ' + free + ' GB'),
      fmKpi('Unused', fmSize(unused), 'nothing points at these', unused > 0 ? 'warn' : ''),
      fmKpi('In the bin', fmSize(binned), (d.bin || []).length + ' file(s), deleted after 7 days'),
    ]),
  );

  // Moves still copying come first: they hold a folder half in two places.
  fmDrawMoves(host);

  const filter = el('input', { placeholder: 'Find a folder', style: 'max-width:260px' });
  const list = el('div', { className: 'fm-folders' });
  const draw = () => {
    list.textContent = '';
    const q = filter.value.trim().toLowerCase();
    const shown = folders.filter((f) => !q || String(f.folder).includes(q) ||
      String(f.label || '').toLowerCase().includes(q) || String(f.title || '').toLowerCase().includes(q));
    if (!shown.length) list.append(el('div', { className: 'empty' }, text('No folder matches.')));
    for (const f of shown) list.append(fmFolderRow(f));
  };
  filter.oninput = draw;
  host.append(el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Folders')), el('span', { className: 'spacer' }), filter]),
    el('p', { className: 'hint' }, text(
      'Biggest first. A folder normally belongs to one title; "unused" is what no title, ' +
      'cover, streaming copy or Telegram file points at.')),
    list,
  ]));
  draw();

  if ((d.bin || []).length) host.append(fmBinSection(d.bin));
}

function fmKpi(k, v, sub, tone) {
  return el('div', { className: 'cr-kpi' + (tone ? ' ' + tone : '') }, [
    el('div', { className: 'k' }, text(k)), el('div', { className: 'v' }, text(v)),
    el('div', { className: 's' }, text(sub)),
  ]);
}

function fmFolderRow(f) {
  const name = f.folder === '' ? '(no folder)' : f.folder;
  const row = el('a', { className: 'cr-todo fm-row', href: '#/files' }, [
    el('span', { className: 'fm-name' }, [
      el('b', {}, text(f.label || name)),
      f.label ? el('span', { className: 'mono fm-dim' }, text(' ' + name)) : null,
      el('div', { className: 'fm-dim' }, text(
        (f.title ? f.title : (f.folder === 'v' || f.folder === 'p' ? 'early uploads, before folders' : 'no title')) +
        ' · ' + f.files + ' file(s)')),
    ]),
    el('span', { className: 'fm-num' }, [
      el('div', {}, text(fmSize(f.bytes))),
      Number(f.unused_bytes) > 0
        ? el('div', { className: 'fm-bad' }, text(fmSize(f.unused_bytes) + ' unused')) : null,
    ]),
    el('span', { className: 'cr-go' }, text('›')),
  ]);
  row.onclick = (e) => { e.preventDefault(); fmOpenFolder(f.folder); };
  return row;
}

// ── one folder ───────────────────────────────────────────────────────────

async function fmOpenFolder(folder) {
  fmFolder = folder;
  const host = $('fmBody');
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  let rows;
  try {
    rows = (await api({ op: 'filesList', folder })).rows || [];
  } catch (e) { say('bad', String(e.message || e)); return; }
  const info = (fmData.folders || []).find((f) => f.folder === folder) || { folder };
  host.textContent = '';

  const back = el('button', { className: 'b', type: 'button' }, text('←'));
  back.onclick = () => { fmFolder = null; fmDrawOverview(); };
  const acts = [];
  const label = el('button', { className: 'b', type: 'button' }, text('Display name'));
  label.onclick = async () => {
    const v = prompt('A name to show for this folder. It moves nothing; leave empty to clear.', info.label || '');
    if (v === null) return;
    try {
      await api({ op: 'folderLabel', folder, label: v });
      say('ok', v.trim() ? 'Display name saved.' : 'Display name cleared.');
      fmData = await api({ op: 'filesSummary' });
      fmOpenFolder(folder);
    } catch (e) { say('bad', String(e.message || e)); }
  };
  acts.push(label);
  if (info.title_id) {
    const open = el('button', { className: 'b', type: 'button' }, text('Open title'));
    open.onclick = () => openEditor(info.title_id);
    acts.push(open);
  }
  if (fmIsOwner() && folder && info.title_id) {
    const mv = el('button', { className: 'b', type: 'button' }, text('Rename / move folder…'));
    mv.onclick = () => fmMoveDialog({ mode: 'folder', from: folder, title: info.title });
    acts.push(mv);
  }

  host.append(el('div', { className: 'sechead', style: 'margin-top:4px' }, [
    back,
    el('div', {}, [
      el('b', {}, text(info.label || (folder || '(no folder)'))),
      el('div', { className: 'mono fm-dim' }, text((folder || '(no folder)') + '/ · ' +
        fmSize(info.bytes) + ' · ' + fmCost(info.bytes) + '/month at R2 prices')),
    ]),
    el('span', { className: 'spacer' }),
    ...acts,
  ]));

  // EARLY UPLOADS, from before folders: one folder holds files of several
  // titles, so it cannot be renamed as a whole. Each title's files can be
  // gathered into a folder of its own instead.
  const owners = new Map();
  for (const r of rows) if (r.used_by && !owners.has(r.used_by)) owners.set(r.used_by, r.used_title);
  if (fmIsOwner() && !info.title_id && owners.size) {
    const box = el('div', { className: 'cr-rv-note' }, [
      text('These files belong to ' + owners.size + ' title(s) but sit outside their folders. ' +
        'Gather each into a folder of its own:'),
    ]);
    for (const [id, title] of owners) {
      const b = el('button', { className: 'b', type: 'button', style: 'margin:6px 6px 0 0' },
        text('“' + (title || 'untitled') + '” →'));
      b.onclick = () => fmMoveDialog({ mode: 'title', titleId: id, title });
      box.append(b);
    }
    host.append(box);
  }

  const fresh = (r) => r.modified && Date.now() - Date.parse(r.modified) < 86400000;
  const picked = new Set();
  const binBtn = el('button', { className: 'b d', type: 'button', disabled: true }, text('Move to bin'));
  const updateBin = () => {
    binBtn.disabled = !picked.size;
    binBtn.textContent = picked.size ? 'Move ' + picked.size + ' to bin' : 'Move to bin';
  };
  binBtn.onclick = () => fmBinDialog(rows.filter((r) => picked.has(r.bucket + '|' + r.key)));

  const table = el('div', { className: 'fm-files' });
  for (const r of rows) {
    const id = r.bucket + '|' + r.key;
    const unused = !r.used_by && r.how !== 'telegram inbox';
    const canPick = fmIsOwner() && unused && !r.bin_id && !fresh(r);
    const cb = canPick ? el('input', { type: 'checkbox' }) : el('span', { className: 'fm-cb' });
    if (canPick) cb.onchange = () => { if (cb.checked) picked.add(id); else picked.delete(id); updateBin(); };
    const used = r.bin_id
      ? el('span', { className: 'chip bad' }, text('in bin · ' + fmDaysLeft(r.purge_after)))
      : r.used_by
        ? el('a', { className: 'chip ok', href: '#/title/' + r.used_by }, text(r.used_title || 'title'))
        : r.how === 'telegram inbox'
          ? el('span', { className: 'chip info' }, text('Telegram inbox'))
          : fresh(r)
            ? el('span', { className: 'chip' }, text('new — may still be uploading'))
            : el('span', { className: 'chip bad' }, text('unused'));
    const name = el('button', { className: 'fm-file', type: 'button', title: 'Look at it' },
      text(r.key.split('/').pop()));
    name.onclick = () => fmPreview(r);
    const restore = r.bin_id && fmIsOwner()
      ? el('button', { className: 'b', type: 'button' }, text('Restore')) : null;
    if (restore) restore.onclick = () => fmRestore(r.bin_id);
    table.append(el('div', { className: 'fm-frow' }, [
      cb,
      el('div', { className: 'fm-fmain' }, [
        name,
        el('div', { className: 'fm-dim' }, text(
          fmKind(r.key) + ' · ' + r.source + ' · ' + (r.modified ? crWhen(r.modified) : '') +
          (r.how && r.used_by ? ' · ' + r.how : ''))),
      ]),
      el('div', { className: 'fm-num' }, [
        el('div', {}, text(fmSize(r.bytes))),
        el('div', { className: 'fm-dim' }, text(fmCost(r.bytes) + '/mo')),
      ]),
      el('div', { className: 'fm-used' }, [used, restore]),
    ]));
  }
  host.append(el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [
      el('h2', {}, text(rows.length + ' file(s)')),
      el('span', { className: 'spacer' }),
      fmIsOwner() ? binBtn : null,
    ]),
    fmIsOwner() ? el('p', { className: 'hint' }, text(
      'Only unused files can be ticked. Anything uploaded in the last day is left alone — ' +
      'until its title is saved it looks exactly like an unused file.')) : null,
    rows.length ? table : el('div', { className: 'empty' }, text('Empty.')),
  ]));
}

function fmDaysLeft(at) {
  const d = Math.ceil((Date.parse(at) - Date.now()) / 86400000);
  return d <= 0 ? 'deleting soon' : d + ' day(s) left';
}

async function fmPreview(r) {
  let url;
  try { url = (await api({ op: 'objectUrl', bucket: r.bucket, key: r.key })).url; }
  catch (e) { say('bad', String(e.message || e)); return; }
  const isVideo = /\.(mp4|mov|m4v|webm|mkv)$/i.test(r.key);
  const media = isVideo
    ? el('video', { src: url, controls: true, playsInline: true, preload: 'metadata' })
    : el('img', { src: url, alt: '', style: 'width:100%;border-radius:6px' });
  const close = el('button', { className: 'b', type: 'button' }, text('Close'));
  const back = el('div', { className: 'modal' }, [el('div', { className: 'sheet' }, [
    el('div', { className: 'sh mono' }, text(r.key)),
    media,
    el('div', { className: 'hint' }, text(fmSize(r.bytes) + ' · ' + (r.used_title ? 'used by ' + r.used_title : 'not used by any title'))),
    el('div', { className: 'srow end' }, [close]),
  ])]);
  const shut = () => { if (media.pause) media.pause(); media.removeAttribute('src'); back.remove(); };
  close.onclick = shut;
  back.onclick = (e) => { if (e.target === back) shut(); };
  document.body.append(back);
}

// ── the bin ──────────────────────────────────────────────────────────────

function fmBinDialog(items) {
  if (!items.length) return;
  const total = items.reduce((a, r) => a + Number(r.bytes || 0), 0);
  const input = el('input', { placeholder: 'Type DELETE', autocapitalize: 'characters' });
  const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px' });
  const go = el('button', { className: 'b d', type: 'button' }, text('Move to bin'));
  const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
  const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [el('div', { className: 'cr-dlg-in' }, [
    el('h3', {}, text('Move ' + items.length + ' file(s) to the bin')),
    el('p', { className: 'hint' }, text(fmSize(total) + '. They are deleted from R2 after seven days, ' +
      'and can be restored until then. Files a title uses are refused.')),
    input, err,
    el('div', { className: 'srow end' }, [cancel, go]),
  ])]);
  cancel.onclick = () => dlg.remove();
  go.onclick = async () => {
    if (input.value.trim() !== 'DELETE') { err.textContent = 'Type DELETE to confirm.'; return; }
    go.disabled = true;
    try {
      const r = await api({ op: 'trashObjects', confirm: 'DELETE',
        items: items.map((x) => ({ bucket: x.bucket, key: x.key })) });
      dlg.remove();
      const refused = (r.refused || []).length;
      say(refused ? 'warn' : 'ok', r.added + ' file(s) in the bin.' +
        (refused ? ' ' + refused + ' refused — a title uses them.' : ''));
      fmData = await api({ op: 'filesSummary' });
      fmOpenFolder(fmFolder);
    } catch (e) {
      go.disabled = false;
      err.textContent = String(e.message || e);
    }
  };
  document.body.append(dlg);
  input.focus();
}

function fmBinSection(bin) {
  const sec = el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('The bin'))]),
    el('p', { className: 'hint' }, text(
      'Deleted from R2 when their seven days are up, by the runner that fetches Telegram ' +
      'files. A file a title starts using again in the meantime is kept automatically.')),
  ]);
  for (const b of bin) {
    const restore = fmIsOwner() ? el('button', { className: 'b', type: 'button' }, text('Restore')) : null;
    if (restore) restore.onclick = () => fmRestore(b.id);
    sec.append(el('div', { className: 'fm-frow' }, [
      el('span', { className: 'fm-cb' }),
      el('div', { className: 'fm-fmain' }, [
        el('div', { className: 'mono' }, text(b.key)),
        el('div', { className: 'fm-dim' }, text((b.reason || '') + ' · ' + (b.requested_email || '') +
          (b.purge_error ? ' · ' + b.purge_error : ''))),
      ]),
      el('div', { className: 'fm-num' }, [el('div', {}, text(fmSize(b.bytes))),
        el('div', { className: 'fm-dim' }, text(fmDaysLeft(b.purge_after)))]),
      el('div', { className: 'fm-used' }, [restore]),
    ]));
  }
  return sec;
}

async function fmRestore(id) {
  try {
    await api({ op: 'trashRestore', id });
    say('ok', 'Restored — it stays.');
    fmData = await api({ op: 'filesSummary' });
    if (fmFolder !== null) fmOpenFolder(fmFolder); else fmDrawOverview();
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── scanning ─────────────────────────────────────────────────────────────

/// Refreshes the console's copy of both buckets' listings, a thousand keys
/// a request, through `apiPatient` so a dropped connection waits instead of
/// failing half-way.
async function fmScan() {
  if (fmScanning) return;
  fmScanning = true;
  const host = $('fmBody');
  const line = el('div', { className: 'msg info' }, text('Scanning the bucket…'));
  host.textContent = '';
  host.append(line);
  try {
    for (const bucket of [fmData.buckets.media, fmData.buckets.public]) {
      let token = '';
      let scan = '';
      let seen = 0;
      for (;;) {
        const r = await apiPatient({ op: 'inventoryScan', bucket, token, scan },
          (t) => { line.textContent = t; });
        scan = r.scan;
        seen += r.seen;
        line.textContent = 'Scanning ' + bucket + '… ' + seen + ' file(s)';
        if (r.done) break;
        token = r.next;
      }
    }
    fmData = await api({ op: 'filesSummary' });
  } catch (e) {
    say('bad', 'The scan stopped: ' + String(e.message || e));
  }
  fmScanning = false;
  if (fmFolder !== null) fmOpenFolder(fmFolder); else fmDrawOverview();
}

// ── moves ────────────────────────────────────────────────────────────────

async function fmDrawMoves(host) {
  let moves = [];
  try { moves = (await api({ op: 'moveList' })).moves || []; } catch { return; }
  const open = moves.filter((m) => m.state === 'copying');
  if (!open.length) return;
  const sec = el('div', { className: 'sec' }, [el('div', { className: 'sechead' }, [el('h2', {}, text('Moves not finished'))])]);
  for (const m of open) {
    const done = (m.objects || []).filter((o) => o.done).length;
    const go = el('button', { className: 'b p', type: 'button' }, text('Continue'));
    const stop = el('button', { className: 'b d', type: 'button' }, text('Cancel'));
    go.onclick = () => fmRunMove(m.id, m.to_folder);
    stop.onclick = async () => {
      if (!confirm('Cancel this move? Nothing changes for the title; the copies made so far are deleted.')) return;
      try { await api({ op: 'moveCancel', id: m.id }); say('ok', 'Cancelled.'); loadFiles(); }
      catch (e) { say('bad', String(e.message || e)); }
    };
    sec.append(el('div', { className: 'cr-rv' }, [el('div', { className: 'cr-rv-main' }, [
      el('b', {}, text((m.from_folder || '?') + '  →  ' + m.to_folder)),
      el('div', { className: 'fm-dim' }, text(done + ' of ' + (m.objects || []).length + ' file(s) copied · started ' + crWhen(m.created_at))),
      fmIsOwner() ? el('div', { className: 'cr-rv-acts' }, [go, stop]) : null,
    ])]));
  }
  // Inserted after the numbers, before the folders.
  const kpis = host.querySelector('.cr-kpis');
  if (kpis && kpis.nextSibling) host.insertBefore(sec, kpis.nextSibling); else host.append(sec);
}

/// Asks for the new folder, then copies, checks and switches — with the
/// steps on screen, because a move of a big folder takes minutes.
function fmMoveDialog(opt) {
  const input = el('input', { placeholder: 'new-folder-name', autocapitalize: 'off', spellcheck: false,
    value: opt.mode === 'title' ? (opt.title || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') : '' });
  const again = el('input', { placeholder: 'type it again to confirm', autocapitalize: 'off', spellcheck: false });
  const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px' });
  const go = el('button', { className: 'b p', type: 'button' }, text('Move'));
  const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
  const what = opt.mode === 'folder'
    ? 'Every file in ' + opt.from + '/ (both buckets) moves to the new folder, and "' + (opt.title || '') + '" with it.'
    : 'Every file of "' + (opt.title || '') + '" — the film, the photos, the thumbnails, the streaming copies — ' +
      'is gathered into this folder.';
  const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [el('div', { className: 'cr-dlg-in' }, [
    el('h3', {}, text(opt.mode === 'folder' ? 'Rename / move folder' : 'Give "' + (opt.title || '') + '" its own folder')),
    el('p', { className: 'hint' }, text(what + ' The files are copied inside R2 (no phone data), checked, ' +
      'then every reference switches at once. The old copies are kept seven days, so an app holding an ' +
      'old picture address still finds it, then deleted. Lower-case letters, digits, hyphens; "/" to nest.')),
    el('label', {}, text('New folder')), input,
    el('label', { style: 'margin-top:8px' }, text('Again')), again,
    err,
    el('div', { className: 'srow end' }, [cancel, go]),
  ])]);
  cancel.onclick = () => dlg.remove();
  go.onclick = async () => {
    const to = input.value.trim();
    if (!to) { err.textContent = 'Name the new folder.'; return; }
    if (again.value.trim() !== to) { err.textContent = 'The two do not match.'; return; }
    go.disabled = true;
    try {
      const r = await api({ op: 'moveStart', mode: opt.mode, from: opt.from, titleId: opt.titleId, to, confirm: to });
      dlg.remove();
      await fmRunMove(r.id, to);
    } catch (e) {
      go.disabled = false;
      err.textContent = String(e.message || e);
    }
  };
  document.body.append(dlg);
  input.focus();
}

/// Copies (a step at a time until every file is done), then switches.
/// Resumable: if the page closes half-way, the move waits under "Moves not
/// finished" and Continue picks up where it stopped.
async function fmRunMove(id, to) {
  const host = $('fmBody');
  const line = el('div', { className: 'msg info' }, text('Copying inside R2…'));
  host.prepend(line);
  try {
    for (;;) {
      const r = await apiPatient({ op: 'moveCopy', id }, (t) => { line.textContent = t; });
      line.textContent = 'Copied ' + r.done + ' of ' + r.total + ' file(s) (' + fmSize(r.bytesDone) + ')…';
      if (r.finished) break;
    }
    line.textContent = 'Switching every reference to the new folder…';
    const s = await api({ op: 'moveSwitch', id });
    line.remove();
    say('ok', 'Moved ' + s.switched + ' file(s) to ' + to + '/. The old copies are in the bin for seven days.');
    fmFolder = null;
    await fmScan();
  } catch (e) {
    line.remove();
    say('bad', 'The move stopped: ' + String(e.message || e) + ' — nothing was switched; Continue it from Files.');
    loadFiles();
  }
}
