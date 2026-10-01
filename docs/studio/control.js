// Innocent Studio — two-step sign-in, Security, Admins and Activity.
//
// Same rules as shell.js: a classic script loaded before the page's own,
// declaring functions only. Nothing here runs until the shell calls it.
//
// THE AUTHENTICATOR IS SUPABASE AUTH'S OWN (TOTP), not something built here.
// The page asks Supabase to enrol a factor and to verify a code; Supabase
// issues a session marked `aal2` with the time of the code in it, and the
// edge functions read those two claims. Nothing on this page decides whether
// a code is right.

// ── the code, when the server asks for it ────────────────────────────────

/// At sign-in: an account that HAS an authenticator gives its code before
/// the console opens. One with none is let through here and is asked to set
/// one up only if the console requires it (see askForCode).
async function ensureSecondStep() {
  const { data, error } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || !data) return;
  if (data.nextLevel === 'aal2' && data.currentLevel !== 'aal2') {
    const ok = await askForCode('signin');
    if (!ok) {
      const e = new Error('mfa_required');
      e.code = 'mfa_required';
      throw e;
    }
  }
}

/// `mfa_required`, `reauth_required` or `signin`. Shows the code dialog —
/// or, for an account with no authenticator yet, the setup — and answers
/// whether a code was verified. api() then sends the refused request again.
async function askForCode(why) {
  const factor = await verifiedFactor();
  if (!factor) {
    if (why === 'reauth_required' || why === 'mfa_required' || why === 'signin') {
      return enrolDialog(why === 'mfa_required'
        ? 'This console now requires two-step sign-in. Set it up once, now — it takes a minute.'
        : 'Set up two-step sign-in to continue.');
    }
    return false;
  }
  const title = why === 'reauth_required' ? 'Confirm it is you' : 'Two-step code';
  const words = why === 'reauth_required'
    ? 'This change cannot be undone, so it needs a code from the last few minutes. Open your authenticator app and type the 6-digit code.'
    : 'Open your authenticator app and type the 6-digit code for Innocent Studio.';
  return codeDialog(title, words, factor.id);
}

async function verifiedFactor() {
  const { data } = await sb.auth.mfa.listFactors();
  const list = (data && data.totp) || [];
  return list.find((f) => f.status === 'verified') || null;
}

/// A dialog that takes a 6-digit code and verifies it with Supabase. Resolves
/// true when verified, false when the admin chose Cancel. A wrong code keeps
/// the dialog open and says so.
function codeDialog(title, words, factorId) {
  return new Promise((resolve) => {
    const input = codeInput();
    const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px;margin-top:6px' });
    const go = el('button', { className: 'b p', type: 'button' }, text('Verify'));
    const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
    const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [
      el('div', { className: 'cr-dlg-in' }, [
        el('h3', {}, text(title)),
        el('p', { className: 'hint' }, text(words)),
        input, err,
        el('div', { className: 'srow end' }, [cancel, go]),
      ]),
    ]);
    const finish = (ok) => { dlg.remove(); resolve(ok); };
    const submit = async () => {
      const code = input.value.replace(/\D/g, '');
      if (code.length !== 6) { err.textContent = 'Six digits.'; return; }
      go.disabled = true;
      err.textContent = '';
      const { error } = await sb.auth.mfa.challengeAndVerify({ factorId, code });
      go.disabled = false;
      if (error) {
        err.textContent = /invalid|expired/i.test(error.message || '')
          ? 'That code is not right, or has just changed. Try the current one.'
          : String(error.message || error);
        input.select();
        return;
      }
      finish(true);
    };
    go.onclick = submit;
    cancel.onclick = () => finish(false);
    input.oninput = () => { if (input.value.replace(/\D/g, '').length === 6) submit(); };
    input.onkeydown = (e) => { if (e.key === 'Enter') submit(); };
    document.body.append(dlg);
    input.focus();
  });
}

function codeInput() {
  return el('input', {
    className: 'cr-code', inputMode: 'numeric', autocomplete: 'one-time-code',
    maxLength: 6, placeholder: '••••••', pattern: '[0-9]*',
  });
}

/// Setting up an authenticator, as a dialog — for the moment the server
/// requires one and this account has none. Resolves true once verified.
function enrolDialog(words) {
  return new Promise((resolve) => {
    const host = el('div');
    const cancel = el('button', { className: 'b', type: 'button' }, text('Cancel'));
    const dlg = el('div', { className: 'cr-dlg', role: 'dialog' }, [
      el('div', { className: 'cr-dlg-in' }, [
        el('h3', {}, text('Two-step sign-in')),
        el('p', { className: 'hint' }, text(words)),
        host,
        el('div', { className: 'srow end' }, [cancel]),
      ]),
    ]);
    cancel.onclick = () => { dlg.remove(); resolve(false); };
    document.body.append(dlg);
    enrolInto(host, () => { dlg.remove(); resolve(true); });
  });
}

/// The setup itself, drawn into `host`. Used by the dialog above and by the
/// Security page.
///
/// FOR A PHONE FIRST. The operator runs this console on the same phone the
/// authenticator app is on, and a phone cannot scan its own screen. So the
/// first option is a link that opens the authenticator app directly, the
/// second is the setup key to paste into it, and the QR code is last — for
/// when the console is open on a computer.
async function enrolInto(host, onDone) {
  host.textContent = '';
  host.append(el('div', { className: 'hint' }, text('Preparing…')));
  // A setup that was started and abandoned leaves an unverified factor
  // behind, and Supabase refuses a second one with the same name. Cleared
  // first so "try again" always works.
  const { data: f } = await sb.auth.mfa.listFactors();
  for (const x of (f && f.all) || []) {
    if (x.factor_type === 'totp' && x.status !== 'verified') {
      await sb.auth.mfa.unenroll({ factorId: x.id });
    }
  }
  const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
  const { data, error } = await sb.auth.mfa.enroll({
    factorType: 'totp',
    friendlyName: 'Studio ' + stamp,
    issuer: 'Innocent Studio',
  });
  host.textContent = '';
  if (error || !data) {
    host.append(el('div', { className: 'msg bad' }, text(
      'Could not start the setup: ' + String((error && error.message) || 'no answer') +
      '. If this says MFA is disabled, two-step sign-in has to be switched on in ' +
      'Supabase (Authentication → Multi-Factor) first.')));
    return;
  }
  const secret = data.totp.secret;
  const grouped = secret.replace(/(.{4})/g, '$1 ').trim();
  const svg = String(data.totp.qr_code || '').replace(/^data:image\/svg\+xml;[^,]*,/, '');

  const copy = el('button', { className: 'b', type: 'button' }, text('Copy key'));
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(secret); copy.textContent = 'Copied'; }
    catch { copy.textContent = 'Select and copy it'; }
  };
  const input = codeInput();
  const err = el('div', { className: 'hint', style: 'color:var(--bad);min-height:18px;margin-top:6px' });
  const go = el('button', { className: 'b p', type: 'button' }, text('Turn on'));

  host.append(
    el('ol', { className: 'cr-steps' }, [
      el('li', {}, [
        text('Install an authenticator app if you have none (Google Authenticator, Microsoft Authenticator, 2FAS…). Then '),
        el('a', { href: data.totp.uri, style: 'color:var(--acc)' }, text('open it with this link')),
        text(' — or, if the link does nothing, add an account by "setup key" and paste this key:'),
      ]),
    ]),
    el('div', { className: 'srow' }, [
      el('input', { className: 'mono', readOnly: true, value: grouped, style: 'flex:1' }),
      copy,
    ]),
    el('details', { style: 'margin-top:8px' }, [
      el('summary', { className: 'hint' }, text('On a computer? Scan this instead')),
      el('div', { className: 'cr-qr', style: 'margin-top:8px' }, [
        el('img', { alt: 'QR code for the authenticator app',
          src: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg) }),
      ]),
    ]),
    el('p', { className: 'hint', style: 'margin-top:10px' },
      text('2. Type the 6-digit code the app now shows for Innocent Studio:')),
    input, err,
    el('div', { className: 'srow end' }, [go]),
  );

  const submit = async () => {
    const code = input.value.replace(/\D/g, '');
    if (code.length !== 6) { err.textContent = 'Six digits.'; return; }
    go.disabled = true;
    const r = await sb.auth.mfa.challengeAndVerify({ factorId: data.id, code });
    go.disabled = false;
    if (r.error) {
      err.textContent = 'That code did not match. Check the app shows "Innocent Studio" and try the current code.';
      return;
    }
    onDone();
  };
  go.onclick = submit;
  input.oninput = () => { if (input.value.replace(/\D/g, '').length === 6) submit(); };
}

// ── Security page ────────────────────────────────────────────────────────

async function loadSecurity() {
  const host = $('mfaBody');
  host.textContent = '';
  const { data } = await sb.auth.mfa.listFactors();
  const factors = ((data && data.totp) || []).filter((f) => f.status === 'verified');
  const aal = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
  const level = aal.data ? aal.data.currentLevel : null;

  if (!factors.length) {
    host.append(el('div', { className: 'msg warn' },
      text('Two-step sign-in is OFF for your account.')));
    const start = el('button', { className: 'b p', type: 'button' }, text('Set it up'));
    const area = el('div', { style: 'margin-top:10px' });
    start.onclick = () => enrolInto(area, () => {
      say('ok', 'Two-step sign-in is on. You will be asked for a code each time you sign in.');
      loadSecurity();
    });
    host.append(start, area);
  } else {
    host.append(el('div', { className: 'msg ok' }, text(
      'Two-step sign-in is ON. This session ' +
      (level === 'aal2' ? 'gave a code.' : 'has not given a code yet.'))));
    for (const f of factors) {
      const rm = el('button', { className: 'b d', type: 'button' }, text('Remove'));
      rm.onclick = async () => {
        if (!confirm('Remove this authenticator? Until you add another, your account is protected by Google sign-in alone.')) return;
        const r = await sb.auth.mfa.unenroll({ factorId: f.id });
        if (r.error) { say('bad', String(r.error.message || r.error)); return; }
        say('ok', 'Removed.');
        loadSecurity();
      };
      host.append(el('div', { className: 'cr-adm' }, [
        el('span', { className: 'cr-em' }, text(f.friendly_name || 'Authenticator')),
        el('span', { className: 'spacer' }),
        rm,
        el('span', { className: 'cr-meta' }, text('Added ' + String(f.created_at || '').slice(0, 10))),
      ]));
    }
  }

  // The console's own rules: owners only.
  const sec = $('secSettings');
  sec.hidden = !ME || ME.role !== 'owner';
  if (sec.hidden) return;
  const body = $('secSettingsBody');
  body.textContent = '';
  let st;
  try { st = (await api({ op: 'settings' })).settings || {}; }
  catch (e) { body.append(el('div', { className: 'msg bad' }, text(String(e.message || e)))); return; }

  const req = el('input', { type: 'checkbox', checked: st.require_mfa === true });
  const two = el('input', { type: 'checkbox', checked: st.two_person === true });
  const idle = el('input', { type: 'number', min: 5, max: 480, value: st.idle_minutes ?? 30, style: 'width:90px' });
  const step = el('input', { type: 'number', min: 1, max: 120, value: st.stepup_minutes ?? 10, style: 'width:90px' });
  const save = el('button', { className: 'b p', type: 'button' }, text('Save rules'));
  body.append(
    el('label', { style: 'display:flex;gap:8px;align-items:center;font-size:13px;color:var(--fg)' },
      [req, text('Every admin must give a two-step code')]),
    el('p', { className: 'hint' }, text(
      'Switch this on only when every admin on the Admins page shows "2-step on" — the server ' +
      'refuses otherwise, because an admin with no authenticator could have one added by ' +
      'whoever holds their Google session.')),
    el('label', { style: 'display:flex;gap:8px;align-items:center;font-size:13px;color:var(--fg);margin-top:10px' },
      [two, text('Two-person rule: whoever made a title cannot approve it')]),
    el('p', { className: 'hint' }, text(
      'Needs at least two editors or owners, or nothing could ever be approved.')),
    el('div', { className: 'cr-form', style: 'margin-top:8px' }, [
      el('div', {}, [el('label', {}, text('Sign out after (minutes idle)')), idle]),
      el('div', {}, [el('label', {}, text('Fresh code for deletes (minutes)')), step]),
    ]),
    el('div', { className: 'srow' }, [save]),
  );
  save.onclick = async () => {
    save.disabled = true;
    try {
      await api({ op: 'settingsSave', require_mfa: req.checked, two_person: two.checked,
        idle_minutes: Number(idle.value), stepup_minutes: Number(step.value) });
      ME.idleMinutes = Number(idle.value);
      ME.stepupMinutes = Number(step.value);
      say('ok', 'Saved.');
    } catch (e) {
      say('bad', String(e.message || e));
      req.checked = st.require_mfa === true;
      two.checked = st.two_person === true;
    }
    save.disabled = false;
  };
}

// ── Admins page ──────────────────────────────────────────────────────────

const CR_ROLES = ['owner', 'editor', 'uploader', 'viewer'];

async function loadAdmins() {
  const host = $('admList');
  host.textContent = '';
  let admins;
  try { admins = (await api({ op: 'admins' })).admins || []; }
  catch (e) { say('bad', String(e.message || e)); return; }
  for (const a of admins) {
    const role = el('select', { style: 'width:auto' },
      CR_ROLES.map((r) => el('option', { value: r, selected: r === a.role }, text(r))));
    role.disabled = a.disabled;
    role.onchange = async () => {
      try {
        await api({ op: 'adminSave', email: a.email, role: role.value });
        say('ok', a.email + ' is now ' + role.value + '.');
      } catch (e) {
        say('bad', String(e.message || e));
      }
      loadAdmins();
    };
    const rm = el('button', { className: 'b d', type: 'button' }, text('Remove'));
    rm.hidden = a.disabled;
    rm.onclick = async () => {
      if (!confirm('Remove ' + a.email + '? They are refused from their next click. Their past activity stays in the log.')) return;
      try {
        await api({ op: 'adminRemove', id: a.id });
        say('ok', a.email + ' removed.');
      } catch (e) {
        say('bad', String(e.message || e));
      }
      loadAdmins();
    };
    const facts = [
      a.disabled ? 'removed' : a.linked ? 'signed in before' : 'has not signed in yet',
      a.mfa ? '2-step on' : '2-step OFF',
      a.last_seen_at ? 'last seen ' + crWhen(a.last_seen_at) : null,
    ].filter(Boolean).join(' · ');
    host.append(el('div', { className: 'cr-adm' + (a.disabled ? ' off' : '') }, [
      el('span', { className: 'cr-em' }, text(a.email)),
      el('span', { className: 'spacer' }),
      role, rm,
      el('span', { className: 'cr-meta' }, text(facts)),
    ]));
  }
  $('admAdd').onclick = async () => {
    const email = $('admEmail').value.trim();
    if (!email) return;
    $('admAdd').disabled = true;
    try {
      const r = await api({ op: 'adminSave', email, role: $('admRole').value });
      say('ok', email + (r.result === 'added' ? ' added.' : ' updated.'));
      $('admEmail').value = '';
      loadAdmins();
    } catch (e) {
      say('bad', String(e.message || e));
    }
    $('admAdd').disabled = false;
  };
}

// ── Activity page ────────────────────────────────────────────────────────

let crActOldest = 0;

async function loadActivity(fresh) {
  const host = $('actList');
  if (fresh) {
    host.textContent = '';
    crActOldest = 0;
    $('actRefresh').onclick = () => loadActivity(true);
    $('actWho').onchange = () => loadActivity(true);
    $('actMore').onclick = () => loadActivity(false);
  }
  let rows;
  try {
    rows = (await api({ op: 'audit', before: crActOldest || undefined,
      actor: $('actWho').value || undefined })).rows || [];
  } catch (e) { say('bad', String(e.message || e)); return; }
  if (fresh && !rows.length) {
    host.append(el('div', { className: 'empty' }, text('Nothing yet.')));
  }
  if (rows.length) {
    host.append(drawFeed(rows));
    crActOldest = rows[rows.length - 1].id;
  }
  $('actMore').hidden = rows.length < 100;
  // The person filter fills from what the log has shown, so it never
  // offers somebody with nothing to show.
  const sel = $('actWho');
  const have = new Set([...sel.options].map((o) => o.value));
  for (const r of rows) {
    if (r.actor_email && !have.has(r.actor_email)) {
      have.add(r.actor_email);
      sel.append(el('option', { value: r.actor_email }, text(r.actor_email)));
    }
  }
}

/// Plain words for what each op did, for the feed. An op with no entry is
/// shown by its name, which is still accurate, just terser.
const CR_ACTIONS = {
  create: 'created a title', publish: 'created a title', save: 'edited a title',
  addAssets: 'added files', updateAsset: 'changed a file', reorder: 'reordered files',
  setPrimary: 'chose the cover', deleteAsset: 'removed a file', deleteTitle: 'DELETED a title',
  approve: 'approved a request', reject: 'rejected a request',
  saveCategory: 'changed a category', addCategory: 'added a category',
  completeMultipart: 'finished an upload', abortMultipart: 'abandoned an upload',
  adminSave: 'changed an admin', adminRemove: 'removed an admin',
  settingsSave: 'changed the console rules',
  attach: 'filed a Telegram file', attach_folder: 'filed a Telegram album',
  create_title: 'made a title from Telegram', retry: 'retried a Telegram file',
  queue: 'queued streaming copies',
  reviewSubmit: 'sent a title for review', reviewApprove: 'APPROVED a title',
  reviewSendBack: 'sent a title back', reviewReject: 'rejected a title',
  reviewReopen: 'reopened a title', unpublish: 'took a title down',
  discard: 'discarded Telegram files',
  folderLabel: 'named a folder', trashObjects: 'put files in the bin',
  trashRestore: 'restored a file from the bin', moveStart: 'started moving files',
  moveCopy: 'copied files for a move',
  moveSwitch: 'MOVED files to a new folder', moveCancel: 'cancelled a move',
  storagePin: 'pinned a title', masterOffload: 'kept an original only in Telegram',
  masterKeep: 'brought an original back to R2', titleArchive: 'ARCHIVED a title',
  titleRestore: 'restored a title', titleRestoreFinish: 'finished a restore by hand',
  vaultCheck: 'asked for a Telegram check', storageSettings: 'changed the storage policy',
};

function drawFeed(rows) {
  const feed = el('div', { className: 'cr-feed' });
  for (const r of rows) {
    const what = CR_ACTIONS[r.action] || r.action;
    feed.append(el('div', { className: 'cr-line' + (r.ok ? '' : ' no') }, [
      el('span', { className: 'cr-ok', title: r.ok ? 'done' : 'refused or failed' }),
      el('span', {}, [
        el('span', { className: 'cr-act' }, text(what + (r.ok ? '' : ' — failed'))),
        text(' '),
        el('span', { className: 'cr-who' }, text((r.actor_email || '?') + ' · ' + (r.actor_role || ''))),
      ]),
      el('span', { className: 'cr-at' }, text(crWhen(r.at))),
      el('span', { className: 'cr-tgt' }, text(
        [r.target, r.ok ? null : r.error].filter(Boolean).join(' · '))),
    ]));
  }
  return feed;
}

/// Myanmar time, because that is what every admin's phone shows. A server
/// timestamp in UTC is six and a half hours away from the clock on the wall.
function crWhen(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const mm = new Date(d.getTime() + 6.5 * 3600000);
  const ago = (Date.now() - d.getTime()) / 60000;
  if (ago < 1) return 'just now';
  if (ago < 60) return Math.round(ago) + ' min ago';
  return mm.toISOString().slice(0, 16).replace('T', ' ');
}
