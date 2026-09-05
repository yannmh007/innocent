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

print('=== %d security invariant violation(s) ===' % len(fails))
for f in fails:
    print(' -', f)
sys.exit(1 if fails else 0)
