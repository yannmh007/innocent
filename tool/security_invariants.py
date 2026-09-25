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

print('=== %d security invariant violation(s) ===' % len(fails))
for f in fails:
    print(' -', f)
sys.exit(1 if fails else 0)
