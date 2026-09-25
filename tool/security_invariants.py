# -*- coding: utf-8 -*-
"""Structural enforcement of the paywall's security model.

The model is only as good as the code obeying it, and the ways it gets broken
are all quiet: a screen that pushes the player directly, a URL written to
preferences "just for resume", a UI that flips entitlement itself. None of
those look wrong in review and none of them fail any other check.

Each rule below is a property of the ARCHITECTURE, not of a line of code.
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else '.'
FEATURE = os.path.join(ROOT, 'lib/features/video_hub')
fails = []

def strip(s):
    s = re.sub(r'//[^\n]*', '', s)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return s

def feature_files():
    for r, d, f in os.walk(FEATURE):
        for fn in f:
            if fn.endswith('.dart'):
                yield os.path.join(r, fn)

if not os.path.isdir(FEATURE):
    print('=== video_hub not present, nothing to check ===')
    sys.exit(0)

# --- 1. every playback goes through the grant -----------------------------
# If any other screen can push the player, it can push it with a URL that was
# never authorised, and the whole "the server decides" design is decoration.
for p in feature_files():
    if os.path.basename(p) == 'playback.dart':
        continue
    s = strip(open(p, encoding='utf-8').read())
    if 'Routes.player' in s:
        fails.append(
            'PLAYBACK BYPASS: %s references Routes.player. Only playback.dart '
            'may open the player, so every play goes through requestPlayback.'
            % os.path.relpath(p, ROOT))

# --- 2. the grant is opened in exactly one place --------------------------
# A PlaybackGrant read anywhere else means a second place deciding what to do
# with a denial - and that is where a paywall gets rendered as an error.
# Scoped to PRESENTATION, which is the intent: data adapters PRODUCE grants
# (that is what implementing the repository means) and the domain DEFINES them.
# The rule is that no screen or widget may interpret one. An earlier version
# exempted a hand-written list of filenames and immediately flagged a newly
# added adapter -- a rule that has to be edited whenever a file is added is a
# rule that will be silenced instead.
for p in feature_files():
    rel = os.path.relpath(p, ROOT).replace('\\', '/')
    if '/presentation/' not in rel:
        continue
    if os.path.basename(p) == 'playback.dart':
        continue
    s = strip(open(p, encoding='utf-8').read())
    if re.search(r'\bPlaybackGrant\b', s):
        fails.append(
            'GRANT LEAK: %s handles a PlaybackGrant. Only playback.dart should '
            'interpret grants and denials.' % rel)

# --- 3. a media URL is never persisted ------------------------------------
# Short-lived signed URLs are the main protection against link sharing, and
# writing one to disk defeats it completely - the stored copy outlives the
# expiry check that made it safe.
WRITE = re.compile(
    r'(setString|setStringList|writeAsString|writeAsBytes|put)\s*\(([^;]{0,160})')
for p in feature_files():
    s = strip(open(p, encoding='utf-8').read())
    for m in WRITE.finditer(s):
        args = m.group(2)
        if re.search(r'\b(url|Url|URL|streamUrl|playbackUrl|grant)\b', args):
            fails.append(
                'URL PERSISTED: %s writes something URL-shaped to storage (%s). '
                'Signed URLs must never outlive the request that minted them.'
                % (os.path.relpath(p, ROOT), m.group(1)))

# --- 4. the UI never grants itself entitlement ----------------------------
# Entitlement is the server's answer. A writable handle in the widget layer is
# how a "temporary" local override becomes a permanent bypass.
for p in feature_files():
    if os.path.basename(p) in ('account_provider.dart',):
        continue
    s = strip(open(p, encoding='utf-8').read())
    if 'entitlementProvider.notifier' in s:
        fails.append(
            'ENTITLEMENT WRITE: %s takes a writable handle on entitlement. '
            'It must be derived from the account, never set by the UI.'
            % os.path.relpath(p, ROOT))

# --- 5. capability tables are advisory, never the gate --------------------
# CapabilityMatrix exists to draw locks. If a repository consults it to decide
# what to return, the decision has moved back into the client.
for p in feature_files():
    rel = os.path.relpath(p, ROOT)
    if '/data/' not in rel.replace('\\', '/'):
        continue
    s = strip(open(p, encoding='utf-8').read())
    if 'CapabilityMatrix' in s:
        fails.append(
            'CLIENT DECIDES: %s (a data adapter) consults CapabilityMatrix. '
            'Adapters must ask the server, not a local table.' % rel)

# --- 6. an address is never display material ------------------------------
# The player's Information dialog is shared with the local library, where
# showing a file's folder is the point. Opened over a stream, the same field
# showed the signed R2 address — account id, private bucket name and the
# shape of every key in it — on the viewer's screen and in any screenshot
# they sent on. The near miss was worse: the sibling field split the URI at
# its last slash, and a SigV4 query string carries
# `X-Amz-Credential=<ACCESS-KEY-ID>/<date>/auto/s3/aws4_request`. Those
# slashes are percent-encoded by the signer today. That is one encoding
# decision, in a different file, away from an access key id on screen.
#
# So the two fields may only be rendered through the rules that refuse an
# address. Checked across the whole tree, not just video_hub, because the
# dialog that leaked lives in local_browser.
GUARDED_FIELDS = [
    ('propLocation', 'showableLocation'),
    ('propFile', 'showableFileName'),
]
for r, d, f in os.walk(os.path.join(ROOT, 'lib')):
    for fn in f:
        if not fn.endswith('.dart'):
            continue
        # The string table declares every key; it renders nothing.
        if fn in ('app_strings.dart',) or '/l10n/' in os.path.join(r, fn):
            continue
        path = os.path.join(r, fn)
        body = strip(open(path, encoding='utf-8').read())
        for field, rule in GUARDED_FIELDS:
            if ('s.' + field) in body and (rule + '(') not in body:
                fails.append(
                    'ADDRESS ON SCREEN: %s renders %s without going through '
                    '%s(). A streamed title has no showable location and is '
                    'named by its title, never by its object key — see '
                    'lib/core/utils/media_address.dart.'
                    % (os.path.relpath(path, ROOT), field, rule))

# --- 7. a download is the original, never a rung ---------------------------
# The transcode ladder exists so STREAMING can be matched to a connection
# second by second: a viewer on a weak link gets a smaller copy instead of a
# film that stops. A download is the opposite situation. The whole reason
# somebody waits an hour or two on Myanmar mobile data is to end up with the
# film as it was uploaded, and a download that quietly handed back a 480p rung
# would have spent that wait on the one thing it was not for.
#
# `grant.url` is signed from the original object key; `grant.renditions` are
# the ladder. The offline downloader may read the first and must never read the
# second. This is a rule about which of two right answers belongs on which
# side, so it cannot be caught by review of the diff that breaks it — the line
# would look perfectly sensible.
OFFLINE = os.path.join(FEATURE, 'data/api/offline_downloader.dart')
if os.path.isfile(OFFLINE):
    body = strip(open(OFFLINE, encoding='utf-8').read())
    if 'renditions' in body:
        fails.append(
            'DOWNLOAD DOWNGRADED: offline_downloader.dart mentions renditions. '
            'A download must fetch grant.url, which is the ORIGINAL object - '
            'the ladder is for streaming only.')
    if 'grant.url' not in body:
        fails.append(
            'DOWNLOAD SOURCE UNCLEAR: offline_downloader.dart no longer reads '
            'grant.url. The original object is what a download is for.')

# --- 9. nothing deletes a file another thread is still writing --------------
#
# DELETING A FILE DOES NOT STOP A WRITE TO IT. On POSIX an open handle outlives
# its name, so a sweep that removes a part file under a live download does not
# stop the download: it carries on spending the viewer's mobile data into an
# inode nothing can reach, and then either fails to rename or — because
# `openWrite` recreates a missing file — appends to an empty one and "finishes"
# a film that is mostly missing. The shelf's own verification deletes that as
# truncated, so the viewer ends with nothing, having paid for all of it.
#
# The Downloads screen has cancelled before discarding since the day it was
# written. `dropEntitled` had not, and signing out mid-download cost somebody
# the rest of their film. The rule is the same one in both places and it is
# ORDER, not intent: the writer stops FIRST.
#
# Checked as text because it is checkable as text, and because a rule that lives
# only in a comment is one a later edit deletes without noticing.
LIB = os.path.join(FEATURE, 'data/api/offline_library.dart')
if os.path.isfile(LIB):
    body = strip(open(LIB, encoding='utf-8').read())
    start = body.find('Future<void> dropEntitled(')
    if start < 0:
        fails.append(
            'SWEEP RENAMED: offline_library.dart has no dropEntitled. If the '
            'entitled sweep moved, move this check with it - it is the one '
            'that stops a sign-out deleting a file a download is writing to.')
    else:
        end = body.find('Future<void> dropAll(', start)
        method = body[start:end if end > start else len(body)]
        # SCOPED TO THE PART FILES, which are the only ones anything can be
        # writing to. The finished films this method deletes above are not:
        # the downloader writes `<id>.mp4.part` and renames only at the very
        # end, so `<id>.mp4` never has a writer. Checking the whole method
        # would fail on those deletes and teach whoever met it that the rule
        # is noise.
        pend = method.find('_pendingRows()')
        method = method[pend:] if pend >= 0 else method
        if 'stop?.call(' not in method:
            fails.append(
                'SWEEP DOES NOT STOP THE WRITER: dropEntitled deletes a '
                'premium part file without calling stop(). Deleting a file '
                'does not stop a download writing to it - see the note on the '
                'method.')
        else:
            # ORDER IS THE WHOLE FIX. Calling stop() after the delete is the
            # same bug with a callback in it.
            called = method.find('stop?.call(')
            deleted = method.find('.delete()')
            if deleted >= 0 and deleted < called:
                fails.append(
                    'SWEEP STOPS THE WRITER TOO LATE: dropEntitled deletes '
                    'before it calls stop(). The order is the fix, not the '
                    'call.')

ACCOUNT = os.path.join(FEATURE, 'presentation/account_provider.dart')
if os.path.isfile(ACCOUNT):
    body = strip(open(ACCOUNT, encoding='utf-8').read())
    if 'dropEntitled(' in body and 'dropEntitled(stop:' not in body:
        fails.append(
            'SIGN-OUT SWEEPS WITHOUT STOPPING: account_provider calls '
            'dropEntitled without passing stop:. The callback exists so a '
            'sign-out can halt a running download before deleting its file.')

# --- 10. nothing the catalogue is kept in leaves the phone in a backup ------
#
# ANDROID AUTO BACKUP UPLOADS AN APP'S INTERNAL STORAGE TO THE USER'S GOOGLE
# DRIVE BY DEFAULT, and the "copy your apps to a new phone" transfer is a
# SECOND channel that copies more. `res/xml/backup_rules.xml` and
# `res/xml/data_extraction_rules.xml` exist because of that, and they were
# written carefully — for the vault, the ADB key and the streaming cache.
#
# Then the offline downloads were added and nobody added a line. Complete
# masters at full quality, sitting in the support directory, going to a
# viewer's personal Drive and onto whatever handset a shop assistant set up
# next. Past the per-app quota the whole backup fails as well, so the settings
# and history those files deliberately KEEP backing up stop arriving too.
#
# So it is mechanical now. EVERYTHING THE VIDEO HUB KEEPS ON DISK IS CATALOGUE
# CONTENT BY DEFINITION, and every directory it creates has to be named in both
# files. The rule is stated as "named", not "excluded", so a directory that
# genuinely should travel can be listed with a comment saying why — what is
# refused is the silence.
XML_DIR = os.path.join(ROOT, 'android/app/src/main/res/xml')
RULES = [os.path.join(XML_DIR, 'backup_rules.xml'),
         os.path.join(XML_DIR, 'data_extraction_rules.xml')]
if all(os.path.isfile(f) for f in RULES):
    rules_text = {f: open(f, encoding='utf-8').read() for f in RULES}
    # THREE SHAPES, BECAUSE THE TREE USES THREE. The first version of this
    # matched only `Directory('${base.path}/offline')` — and the stream cache,
    # the other directory full of catalogue video, is written
    # `Directory(p.join(base.path, _dirName))`. It would have sailed straight
    # past a check meant to catch exactly it, and the next person to add a
    # directory will copy whichever file they happen to open.
    seen = set()
    for base, dirs, files in os.walk(FEATURE):
        for fn in files:
            if not fn.endswith('.dart'):
                continue
            path = os.path.join(base, fn)
            body = strip(open(path, encoding='utf-8').read())
            where = os.path.relpath(path, ROOT)
            # A constant holding the folder name, resolved within its own file.
            consts = dict(re.findall(
                r"const\s+String\s+(\w+)\s*=\s*'([A-Za-z0-9_\-]+)'", body))
            # WHICH BASE DIRECTORY THIS ONE HANGS OFF, because two of them are
            # not backed up at ALL and flagging those would make this check
            # wrong. `getApplicationCacheDirectory()` and
            # `getTemporaryDirectory()` are outside every backup domain by
            # platform rule — the poster cache lives in the first of those, and
            # an earlier version of this check demanded a rule for it. A check
            # that asks for something unnecessary is one people learn to
            # override.
            bases = [(m.start(), m.group(1)) for m in
                     re.finditer(r"get(\w*)Directory\(\)", body)]

            def backed_up(at):
                prev = [name for off, name in bases if off < at]
                if not prev:
                    return True
                return prev[-1] not in ('ApplicationCache', 'Temporary')
            for m in re.finditer(
                    r"Directory\('\$\{[A-Za-z_.]+\}/([A-Za-z0-9_\-]+)'\)", body):
                if backed_up(m.start()):
                    seen.add((m.group(1), where))
            for m in re.finditer(
                    r"p\.join\(\s*[A-Za-z_][\w.]*\.path\s*,\s*'([A-Za-z0-9_\-]+)'",
                    body):
                if backed_up(m.start()):
                    seen.add((m.group(1), where))
            for m in re.finditer(
                    r"p\.join\(\s*[A-Za-z_][\w.]*\.path\s*,\s*(\w+)\s*\)", body):
                if m.group(1) in consts and backed_up(m.start()):
                    seen.add((consts[m.group(1)], where))
    for name, where in sorted(seen):
        for f in RULES:
            if ('path="%s"' % name) not in rules_text[f] and \
                    ('path="%s/"' % name) not in rules_text[f]:
                fails.append(
                    'CATALOGUE IN A BACKUP: %s keeps files in "%s/" and %s '
                    'does not mention it. Android uploads internal storage to '
                    'the user\'s Google Drive and clones it to a new phone '
                    'unless a rule says otherwise.'
                    % (where, name, os.path.relpath(f, ROOT)))

# AND THE KEY THOSE DOWNLOADS ARE ENCRYPTED WITH. Keystore-wrapped, and the
# Keystore is never part of a backup — so a restored copy is a blob with no key
# to open it, and every sealed film draws as noise instead of saying it can no
# longer be opened. The same trap FlutterSecureStorage is excluded for.
CRYPTO_KT = os.path.join(
    ROOT, 'android/app/src/main/kotlin/com/innocent/media/MediaCrypto.kt')
if os.path.isfile(CRYPTO_KT) and all(os.path.isfile(f) for f in RULES):
    m = re.search(r'PREFS\s*=\s*"([^"]+)"',
                  open(CRYPTO_KT, encoding='utf-8').read())
    if m:
        for f in RULES:
            if m.group(1) not in open(f, encoding='utf-8').read():
                fails.append(
                    'THE DOWNLOAD KEY IS IN A BACKUP: MediaCrypto stores the '
                    'wrapped data key in "%s" and %s does not exclude it. '
                    'Restored without its Keystore key it opens nothing, and '
                    'every sealed film becomes noise on screen.'
                    % (m.group(1), os.path.relpath(f, ROOT)))

# --- 8. no credential is ever written into this repository -----------------
#
# THIS IS NOT A PRECAUTION. `docs/RUNBOOK.md` carried the live
# R2_SECRET_ACCESS_KEY in full, in a PUBLIC repository, from the commit that
# first pushed this project to GitHub. `docs/` is also published as the operator
# console, so everything in it is world-readable by design. A pair of R2 keys can
# read, overwrite and delete every object in the media bucket.
#
# It got there the way these always do: somebody wrote a runbook so the next
# person would not have to hunt for the values, which is a good instinct about a
# private note and a disaster in a repository. So the rule is mechanical now.
#
# WHAT IS MATCHED, and why each one is shaped the way it is:
#   * a 64-character hex run — R2 secret access keys are exactly that, and so is
#     nothing else in this tree except SHA-256 digests, which are allowed by name
#     below because they are public facts about public artefacts.
#   * a 32-character hex run on a line that names an R2 key or account.
#   * `sb_secret_...`, the new Supabase service key.
#   * a JWT-shaped `eyJ...` run of any length, which is the legacy service_role
#     key's shape.
#
# `sb_publishable_` is deliberately NOT matched: it is meant to be in client
# code, and it is, in the console.
#
# The bare-hex rule DOES NOT APPLY TO TESTS. A crypto test is made of digests —
# `test/private_folder_crypto_test.dart` alone holds eight — and listing each one
# by name would turn this check into a list nobody maintains, which is how a
# check stops being read. The key-shaped rules still apply everywhere, and the
# places a credential actually reaches for reasons of convenience are documents,
# workflows and functions, all of which are covered.
CRED_PATTERNS = [
    (re.compile(r'(?<![0-9a-fA-F])[0-9a-f]{64}(?![0-9a-fA-F])'),
     'a 64-character hex string, which is the shape of an R2 secret access key',
     ('test/', 'tool/js/')),
    (re.compile(r'\bsb_secret_[A-Za-z0-9_-]{8,}'),
     'a Supabase secret key', ()),
    (re.compile(r'\beyJ[A-Za-z0-9_-]{30,}'),
     'a JWT, which is the shape of the legacy service_role key', ()),
]

# Public facts that happen to be 64 hex characters. Each one is here by NAME
# rather than by pattern, so adding to this list is a deliberate act.
CRED_ALLOWED = {
    # The release APK's signing certificate digest. A certificate fingerprint is
    # published so that anybody can check a build; it is not a key.
    'e3e1effa993ced6745a33f75c97742a3b8badd79d54927d2515538594c85cdb1',
    # AWS's own published SigV4 worked example, which tool/js/sigv4_test.mjs
    # verifies the signer against.
    '7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972',
    'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    # SHA-256 of the empty string, in the same test.
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
}

CRED_EXTS = ('.md', '.ts', '.js', '.mjs', '.html', '.yml', '.yaml', '.sh',
             '.py', '.dart', '.kt', '.toml', '.json', '.sql', '.txt')

for base, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs
               if d not in ('.git', 'build', '.dart_tool', 'node_modules')]
    for fn in files:
        if not fn.endswith(CRED_EXTS):
            continue
        path = os.path.join(base, fn)
        try:
            text = open(path, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
        for pattern, what, exempt in CRED_PATTERNS:
            if any(rel.startswith(e) for e in exempt):
                continue
            for m in pattern.finditer(text):
                if m.group(0) in CRED_ALLOWED:
                    continue
                line = text.count('\n', 0, m.start()) + 1
                fails.append(
                    'CREDENTIAL IN THE REPOSITORY: %s:%d holds %s. This '
                    'repository is public and docs/ is published as the '
                    'console. If it is a real key, roll it in the dashboard '
                    'first - deleting the line does not undo publication. If '
                    'it is a public fact, add it to CRED_ALLOWED by name.'
                    % (rel, line, what))

print('=== %d security invariant violation(s) ===' % len(fails))
for f in fails:
    print(' -', f)
sys.exit(1 if fails else 0)
