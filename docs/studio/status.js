// Innocent Studio — the Status page: is the machine running?
//
// WHAT IT SHOWS, IN ONE PLACE (migration 032):
//   * the bot and its webhook, as Telegram sees them right now — whether it
//     points here, how many updates are waiting, the last delivery error;
//   * each runner: when it last came by, and which of its secrets it had;
//   * the queues: forwarded films, Telegram checks / restores / archive
//     copies, the encoder, album previews;
//   * the daily database backups, with Back up now and Download (owner);
//   * the archive channel: which, since when, whether the bot may still post
//     there, how many films are in it — and how to connect one;
//   * which project secrets are set. Yes or no; never a value.
//
// Classic script, functions only — like the others.

let ssData = null;

const ssIsOwner = () => !!ME && ME.role === 'owner';

function ssSize(b) {
  b = Number(b) || 0;
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
  if (b >= 1e3) return Math.round(b / 1e3) + ' KB';
  return b + ' B';
}

/// "4 min ago", "3 h ago", "2 days ago" — and the Myanmar clock time on hover.
function ssAgo(iso) {
  if (!iso) return 'never';
  const ms = Date.now() - Date.parse(iso);
  if (!(ms >= 0)) return 'just now';
  const m = Math.round(ms / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return m + ' min ago';
  const h = Math.round(m / 60);
  if (h < 48) return h + ' h ago';
  return Math.round(h / 24) + ' days ago';
}
function ssMmt(iso) {
  if (!iso) return '';
  return new Date(Date.parse(iso) + 6.5 * 3600 * 1000).toISOString()
    .slice(0, 16).replace('T', ' ') + ' Myanmar time';
}
const ssMinutes = (iso) => iso ? (Date.now() - Date.parse(iso)) / 60000 : Infinity;

async function loadStatus() {
  const host = $('ssBody');
  if (!host) return;
  host.textContent = '';
  host.append(el('div', { className: 'empty' }, text('Loading…')));
  try {
    ssData = await api({ op: 'status' });
  } catch (e) {
    host.textContent = '';
    say('bad', String(e.message || e));
    return;
  }
  ssDraw();
}

function ssKpi(k, v, sub, tone) {
  return el('div', { className: 'cr-kpi' + (tone ? ' ' + tone : '') }, [
    el('div', { className: 'k' }, text(k)), el('div', { className: 'v' }, text(v)),
    el('div', { className: 's' }, text(sub)),
  ]);
}

function ssSec(title, hint, body, extra) {
  return el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text(title)),
      el('span', { className: 'spacer' }), ...(extra || [])]),
    hint ? el('p', { className: 'hint' }, text(hint)) : null,
    ...body,
  ].filter(Boolean));
}

/// One fact: a label, a value, and a tone for the dot.
function ssFact(label, value, tone, title) {
  return el('div', { className: 'ss-fact' }, [
    el('span', { className: 'ss-dot ' + (tone || '') }),
    el('span', { className: 'ss-k' }, text(label)),
    el('span', { className: 'ss-v', title: title || '' }, text(value)),
  ]);
}

function ssDraw() {
  const host = $('ssBody');
  host.textContent = '';
  const d = ssData || {};
  const ingest = (d.runners || []).find((r) => r.name === 'ingest');
  const runnerAge = ssMinutes(ingest && ingest.seen_at);
  const last = (d.backups || [])[0];
  const backupAge = ssMinutes(last && last.taken_at);
  const hook = d.webhook || {};
  const films = d.films || {};
  const arch = d.archive || {};

  host.append(el('div', { className: 'cr-kpis' }, [
    ssKpi('Runner', ingest ? ssAgo(ingest.seen_at) : 'never',
      runnerAge < 40 ? 'running on schedule' : runnerAge < 180 ? 'late — GitHub is slow' : 'NOT RUNNING',
      runnerAge < 40 ? '' : runnerAge < 180 ? 'warn' : 'bad'),
    ssKpi('Webhook', hook.error ? 'no answer' : hook.ours ? 'ours' : hook.set ? 'ELSEWHERE' : 'NOT SET',
      hook.error ? hook.error : hook.last_error ? 'last error ' + ssAgo(hook.last_error_at) : 'no delivery errors',
      hook.error || !hook.ours ? 'bad' : hook.last_error && ssMinutes(hook.last_error_at) < 60 ? 'warn' : ''),
    ssKpi('Last backup', last ? ssAgo(last.taken_at) : 'none yet',
      last ? ssSize(last.bytes) + ' · ' + Object.keys(last.tables || {}).length + ' tables'
        : 'the first one is made on the next runner tick',
      backupAge < 30 * 60 ? '' : backupAge < 72 * 60 ? 'warn' : 'bad'),
    ssKpi('Archive channel', arch.chat_id ? (films.archived || 0) + ' of ' + (films.total || 0) : 'not connected',
      arch.chat_id ? 'films copied there' : 'films live in R2 and the bot chat only',
      arch.chat_id ? (d.archive_live && d.archive_live.ok === false ? 'bad' : '') : 'warn'),
  ]));

  host.append(ssTelegram(d));
  host.append(ssArchive(d));
  host.append(ssBackups(d));
  host.append(ssRunners(d));
  host.append(ssQueues(d));
  host.append(ssSecrets(d));
  host.append(ssSec('Database', null, [el('div', { className: 'ss-facts' }, [
    ssFact('Size', ssSize(d.db_bytes), Number(d.db_bytes) > 400e6 ? 'warn' : 'ok',
      'The free plan allows 500 MB.'),
    ssFact('Newest migration', String(d.migration || '—'), 'ok'),
    ssFact('Released app', d.release ? d.release.version + ' (' + d.release.code + ')' : '—', 'ok',
      d.release ? ssMmt(d.release.at) : ''),
  ])]));
}

function ssTelegram(d) {
  const hook = d.webhook || {};
  const facts = [
    ssFact('Bot', d.bot && d.bot.username ? '@' + d.bot.username : (d.bot && d.bot.error) || '—',
      d.bot && d.bot.username ? 'ok' : 'bad'),
  ];
  if (hook.error) {
    facts.push(ssFact('Webhook', hook.error, 'bad'));
  } else {
    facts.push(ssFact('Webhook points here', hook.ours ? 'yes' : hook.set ? 'NO — somewhere else' : 'NOT SET',
      hook.ours ? 'ok' : 'bad'));
    facts.push(ssFact('Waiting updates', String(hook.pending || 0), (hook.pending || 0) > 20 ? 'warn' : 'ok',
      'Updates Telegram has not delivered yet. A few is normal; a growing number means deliveries fail.'));
    facts.push(ssFact('Last delivery error', hook.last_error ? hook.last_error + ' · ' + ssAgo(hook.last_error_at) : 'none',
      hook.last_error ? (ssMinutes(hook.last_error_at) < 60 ? 'bad' : 'warn') : 'ok', ssMmt(hook.last_error_at)));
    facts.push(ssFact('Hears channel changes', hook.hears_channels ? 'yes' : 'NO',
      hook.hears_channels ? 'ok' : 'warn',
      'Needed for an archive channel to connect itself when the bot is made its admin.'));
  }
  const extra = [];
  if (ssIsOwner()) {
    const fix = el('button', { className: 'ghost' }, text('Repair webhook'));
    fix.onclick = () => ssDo(fix, { op: 'webhookRepair' }, 'Webhook set: it points here, with the secret, and hears channel changes.');
    extra.push(fix);
  }
  return ssSec('Telegram', 'What Telegram says right now. "Repair webhook" points the bot back ' +
    'at this project with its secret — safe to press; nothing queued is lost.',
  [el('div', { className: 'ss-facts' }, facts)], extra);
}

function ssArchive(d) {
  const arch = d.archive || {};
  const films = d.films || {};
  const live = d.archive_live;
  const body = [];
  if (arch.chat_id) {
    body.push(el('div', { className: 'ss-facts' }, [
      ssFact('Channel', arch.title || String(arch.chat_id), live && live.ok === false ? 'bad' : 'ok'),
      ssFact('Bot may post there', live ? (live.ok ? 'yes' : 'NO — ' + live.why) : '—',
        live && live.ok ? 'ok' : 'bad'),
      ssFact('Connected', ssAgo(arch.connected_at) + (arch.connected_by ? ' · by ' + arch.connected_by : ''),
        'ok', ssMmt(arch.connected_at)),
      ssFact('Films in the channel', (films.archived || 0) + ' of ' + (films.total || 0),
        films.archived >= films.total ? 'ok' : 'warn'),
      ssFact('Console uploads still to send', String(Math.max(0, (films.console_only || 0) - (films.too_big || 0))),
        'ok', 'Sent one at a time by the runner: fetched from R2, uploaded to the channel.'),
    ]));
    if (films.too_big) {
      body.push(el('p', { className: 'hint' }, text(films.too_big + ' film(s) are over Telegram\'s 2000 MB ' +
        'and cannot be archived there; they stay in R2.')));
    }
    const vj = (d.vault || {}).archive;
    if (vj && (vj.queued || vj.running || vj.failed_7d)) {
      body.push(el('p', { className: 'hint' }, text('Archive work: ' + (vj.queued || 0) + ' queued, ' +
        (vj.running || 0) + ' running, ' + (vj.failed_7d || 0) + ' failed this week' +
        (vj.last_note ? ' — last: ' + vj.last_note : ''))));
    }
  } else {
    if (arch.note) body.push(el('p', { className: 'hint warn' }, text('Last channel: ' + arch.note)));
    body.push(el('ol', { className: 'ss-steps' }, [
      el('li', {}, text('In Telegram, create a PRIVATE channel (for example "Innocent archive").')),
      el('li', {}, text('Add the bot' + (d.bot && d.bot.username ? ' @' + d.bot.username : '') +
        ' to the channel as an ADMIN, with "Post messages" on.')),
      el('li', {}, text('That is all: the bot tells you in your chat that the channel is connected, ' +
        'and every film is copied there — forwarded ones in seconds, console uploads one by one.')),
    ]));
  }
  const extra = [];
  if (ssIsOwner()) {
    if (arch.chat_id) {
      const off = el('button', { className: 'ghost' }, text('Disconnect'));
      off.onclick = () => {
        if (!confirm('Stop copying films to "' + (arch.title || arch.chat_id) + '"? ' +
          'Copies already there stay recorded.')) return;
        ssDo(off, { op: 'archiveDisconnect' }, 'Archive channel disconnected.');
      };
      extra.push(off);
    } else {
      const input = el('input', { placeholder: '@channel or -100…', style: 'max-width:200px' });
      const go = el('button', { className: 'ghost' }, text('Connect'));
      go.onclick = () => ssDo(go, { op: 'archiveConnect', chat: input.value.trim() },
        'Archive channel connected.');
      body.push(el('div', { className: 'ss-connect' }, [
        el('span', { className: 'hint' }, text('Already an admin and nothing happened? Connect it by name:')),
        input, go,
      ]));
    }
  }
  return ssSec('Archive channel', 'A private Telegram channel that keeps a copy of every film. ' +
    'It is what a film is restored from, and what lets R2 free a film\'s original.', body, extra);
}

function ssBackups(d) {
  const rows = d.backups || [];
  const list = el('div', { className: 'ss-list' });
  if (!rows.length) {
    list.append(el('div', { className: 'empty' }, text('No backup yet — the first is made on the next runner tick.')));
  }
  for (const b of rows) {
    const tables = Object.keys(b.tables || {}).length;
    const rowsN = Object.values(b.tables || {}).reduce((a, n) => a + Number(n || 0), 0);
    const line = el('div', { className: 'ss-row' }, [
      el('div', { className: 'ss-main' }, [
        el('div', {}, text(ssAgo(b.taken_at) + ' · ' + (b.trigger === 'manual' ? 'by hand' : 'daily'))),
        el('div', { className: 'hint' }, text(ssMmt(b.taken_at) + ' · ' + ssSize(b.bytes) + ' · ' +
          tables + ' tables, ' + rowsN + ' rows')),
      ]),
    ]);
    if (ssIsOwner()) {
      const dl = el('button', { className: 'ghost' }, text('Download'));
      dl.onclick = async () => {
        dl.disabled = true;
        try {
          const r = await api({ op: 'backupUrl', id: b.id });
          const a = el('a', { href: r.url, download: r.name || 'backup.json.gz' });
          document.body.append(a);
          a.click();
          a.remove();
        } catch (e) {
          say('bad', String(e.message || e));
        } finally {
          dl.disabled = false;
        }
      };
      line.append(dl);
    }
    list.append(line);
  }
  const extra = [];
  if (ssIsOwner()) {
    const now = el('button', { className: 'ghost' }, text('Back up now'));
    now.onclick = () => ssDo(now, { op: 'backupNow' }, 'Backed up.');
    extra.push(now);
  }
  return ssSec('Database backups', 'Made every day by the runner, into the private bucket: every table ' +
    'and the account list, gzipped. Fourteen days are kept, and the first of each month for a year. ' +
    'The download holds every account\'s email — keep it somewhere private. RUNBOOK part 4 says how ' +
    'to restore one.', [list], extra);
}

function ssRunners(d) {
  const names = { tg_api_id: 'TELEGRAM_API_ID', tg_api_hash: 'TELEGRAM_API_HASH',
    tg_bot_token: 'TELEGRAM_BOT_TOKEN', ingest_secret: 'INGEST_SECRET', supabase_url: 'SUPABASE_URL' };
  const body = [];
  const runners = d.runners || [];
  if (!runners.length) body.push(el('div', { className: 'empty' }, text('No runner has reported yet.')));
  for (const r of runners) {
    const age = ssMinutes(r.seen_at);
    const facts = [ssFact('Last seen', ssAgo(r.seen_at), age < 40 ? 'ok' : age < 180 ? 'warn' : 'bad', ssMmt(r.seen_at))];
    const info = r.info || {};
    const known = Object.keys(names).filter((k) => k in info);
    if (!known.length) {
      facts.push(ssFact('Secrets', 'not reported by this runner version', 'warn'));
    } else {
      for (const k of known) facts.push(ssFact(names[k], info[k] ? 'set' : 'MISSING', info[k] ? 'ok' : 'bad'));
    }
    body.push(el('h3', { className: 'ss-h3' }, text(r.name === 'ingest' ? 'Ingest runner (GitHub Actions)' : r.name)));
    body.push(el('div', { className: 'ss-facts' }, facts));
  }
  if (d.last_transcode) {
    body.push(el('h3', { className: 'ss-h3' }, text('Encoder')));
    body.push(el('div', { className: 'ss-facts' }, [ssFact('Last film encoded', ssAgo(d.last_transcode), 'ok', ssMmt(d.last_transcode))]));
  }
  return ssSec('Runners', 'GitHub runs these on a schedule — every five minutes in name, ' +
    'fourteen to twenty in practice. Over three hours without one means the schedule stopped ' +
    '(GitHub pauses it after 60 days without a push).', body);
}

function ssQueues(d) {
  const ing = d.ingest || {};
  const facts = [
    ssFact('Forwarded films waiting', String(ing.queued || 0) + (ing.running ? ' · ' + ing.running + ' running' : ''),
      'ok'),
    ssFact('Forwarded films failed', String(ing.failed || 0), ing.failed ? 'warn' : 'ok',
      'Retry them on the Telegram page.'),
  ];
  const labels = { verify: 'Telegram checks', restore: 'Restores', archive: 'Archive copies' };
  for (const [k, v] of Object.entries(d.vault || {})) {
    facts.push(ssFact(labels[k] || k, (v.queued || 0) + ' waiting · ' + (v.done_7d || 0) + ' done this week' +
      (v.failed_7d ? ' · ' + v.failed_7d + ' failed' : ''), v.failed_7d ? 'warn' : 'ok', v.last_note || ''));
  }
  const tc = d.transcode || {};
  const tcText = Object.entries(tc).map(([k, n]) => n + ' ' + k).join(' · ');
  facts.push(ssFact('Encoder', tcText || '—', tc.failed ? 'warn' : 'ok'));
  facts.push(ssFact('Album previews to make', String(d.previews_missing || 0),
    d.previews_missing ? 'warn' : 'ok', 'The data saver\'s blurred tiles; made by the runner.'));
  return ssSec('Queues', null, [el('div', { className: 'ss-facts' }, facts)]);
}

function ssSecrets(d) {
  const rows = d.secrets || [];
  const missing = rows.filter((r) => r.need && !r.set).length;
  return ssSec('Project secrets', 'Supabase → Edge Functions → Secrets. Shown as set or missing — ' +
    'the values never leave the server.' + (missing ? ' ' + missing + ' required secret(s) are missing.' : ''),
  [el('div', { className: 'ss-facts' }, rows.map((r) =>
    ssFact(r.name, r.set ? 'set' : r.need ? 'MISSING' : 'not set (optional)',
      r.set ? 'ok' : r.need ? 'bad' : '', r.what)))]);
}

/// Press, wait, say what happened, redraw.
async function ssDo(btn, payload, done) {
  btn.disabled = true;
  try {
    const r = await api(payload);
    let msg = done;
    if (payload.op === 'backupNow' && r.backup) {
      msg = 'Backed up: ' + ssSize(r.backup.bytes) + ', ' + r.backup.tables + ' tables.';
    }
    if (payload.op === 'archiveConnect' && r.title) msg = 'Archive channel connected: ' + r.title + '.';
    say('ok', msg);
    await loadStatus();
  } catch (e) {
    say('bad', String(e.message || e));
  } finally {
    btn.disabled = false;
  }
}
