#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch a setting the app stores and never reads.

WHAT KEEPS HAPPENING. A control is added to a Settings screen, wired to a
preference key, and nothing downstream ever asks for that key. The switch
moves, the subtitle updates to show the new value, and the app behaves
exactly as before. Nothing fails, nothing logs, and the user concludes the
feature is broken - or worse, believes it worked.

This is the single most repeated bug class in this project. Grepping the
tree's own comments for "had no reader" / "nothing read" returns TEN separate
instances, each found by somebody happening to notice:

    app.dart                          "Cache thumbnail", and one more
    local_screen.dart                 List -> "Floating button"
    video_option_menu.dart  (x2)      the delete confirmation, and one more
    library_local_datasource.dart     List -> "File extensions"
    settings_general_screen.dart      App language
    settings_list_screen.dart         two PlayerSetting keys
    player_controller_navigation.dart Previous-button behaviour
    player_screen.dart      (x2)      a description with no reader; a pause

Ten recurrences is not bad luck, it is a missing check. This is the check.

THE RULE. A setting must be referenced somewhere OUTSIDE lib/features/settings/.
A reference inside that folder is the screen reading its own value back to
display it - which every dead setting also does. Only a reference elsewhere
means something acts on it.

THE TRAP, and why the allow-list is not laziness. "Only referenced under
features/settings/" also matches a setting that is deliberately MIRRORED: the
real state lives elsewhere and the key is written so diagnostics and a future
export agree with it. `userLocale` is exactly that - its own comment reads
"which nothing read", which is the confession of a bug that was FIXED, and the
remaining write is intentional. Only the surrounding comment tells the two
apart, so each entry below was read by hand.

KNOWN_OPEN is a RATCHET. A new dead setting fails this check immediately. The
five listed there are the ones docs/audit_library_music_settings.md found
open; the list may only ever shrink, and removing an entry is the fix landing.

Exit code 1 if a setting outside the allow-list has no reader.
"""
import os
import re
import sys

# Where the enums live, and the name of each enum in the file.
SOURCES = [
    ('lib/core/services/preferences/extra_settings_service.dart',
     ('StringSetting', 'IntSetting', 'BoolSetting')),
    ('lib/core/services/preferences/player_settings_service.dart',
     ('PlayerSetting',)),
]

# The folder whose references do not count as "something acts on it".
UI_ONLY_DIR = os.path.join('lib', 'features', 'settings')

# Settings that are referenced only under features/settings/ and are NOT bugs.
# Each needs a reason, and the reason must be checkable by reading the code.
DELIBERATE = {
    'userLocale':
        'mirrored on purpose. The real state is localeProvider; the key is '
        'written so diagnostics and a future export agree with it. See the '
        'comment at settings_general_screen.dart.',
}

# Known-open findings, from docs/audit_library_music_settings.md L1. This list
# may only shrink. Do not add to it: a NEW dead setting is what this check is
# for, and silencing one here defeats the entire point.
# Known-open findings. This list is the BACKLOG, and it may only ever shrink.
# Do not add to it: a NEW dead setting is what this check exists for, and
# silencing one here defeats the entire point. Removing an entry is the fix
# landing — either the setting got a reader, or the control was removed.
#
# HOW THE COUNT GOT TO 35. docs/audit_library_music_settings.md L1 found five,
# by extracting the enum values from extra_settings_service.dart and grepping
# each. It never looked at PlayerSetting, which has a hundred values in a
# different file — and thirty of those are dead too. The audit undercounted by
# sevenfold, and writing this check is what found that out. That is the case
# for a check rather than a sweep in one sentence.
#
# Two of them (listRecognizeNomedia, listShowHiddenFiles) are referenced
# NOWHERE — not even by a settings screen. They are pure dead code and are the
# cheapest five minutes on this list.
KNOWN_OPEN = {
    # From docs/audit_library_music_settings.md L1 — StringSetting/IntSetting.
    'scanFolders':
        'settings_list_screen.dart. Its sibling scanExtensions IS wired, '
        'through setExtensionFilter; the walk still visits every volume.',
    'bluetoothAudioDelay':
        'settings_audio_screen.dart. audioDelay is applied at '
        'player_controller_playback.dart; the Bluetooth variant is not.',
    'videoZoomDelay':
        'settings_player_screen.dart. Reaches libmpv decoder config; '
        'removing the control may be the better fix.',
    'hwPlusVideoCodecs':
        'settings_decoder_screen.dart. The screen is wired to the setting; '
        'the decoder is not wired to either.',
    'hwPlusAudioCodecs':
        'settings_decoder_screen.dart. Same.',
    # PlayerSetting — found by this check, missed by the audit.
    'listRecognizeNomedia':
        'not referenced anywhere at all — pure dead code',
    'listShowHiddenFiles':
        'not referenced anywhere at all — pure dead code',
    'screenDimNotch':
        'player_screen_settings_screen.dart',
    'screenUseCutout':
        'player_screen_settings_screen.dart',
    'styleCompactMode':
        'player_style_screen.dart',
    'styleShowBattery':
        'player_style_screen.dart',
    'audioAsPlayer':
        'settings_audio_screen.dart',
    'audioSystemVolumePanel':
        'settings_audio_screen.dart',
    'decCorrectAspect':
        'settings_decoder_screen.dart',
    'decCustomCodec':
        'settings_decoder_screen.dart',
    'decHwAudioOnSwVideo':
        'settings_decoder_screen.dart',
    'decHwAudioTrackSelectable':
        'settings_decoder_screen.dart',
    'decSwAudio':
        'settings_decoder_screen.dart',
    'decSwAudioLocal':
        'settings_decoder_screen.dart',
    'decSwAudioNetwork':
        'settings_decoder_screen.dart',
    'devEnableDebugLog':
        'settings_development_screen.dart',
    'generalPlayMediaLinks':
        'settings_general_screen.dart',
    'tvMode':
        'settings_general_screen.dart',
    'listLastMediaInFolder':
        'settings_list_screen.dart',
    'listScrollToLastMedia':
        'settings_list_screen.dart',
    'listSelectThumbnail':
        'settings_list_screen.dart',
    'albumArt':
        'settings_player_screen.dart',
    'android40Mode':
        'settings_player_screen.dart',
    'honourHeadsetMultiPress':
        'settings_player_screen.dart',
    'smoothSwitch':
        'settings_player_screen.dart',
    'softwareNavButtons':
        'settings_player_screen.dart',
    'turnOffBacklight':
        'settings_player_screen.dart',
    'subtitleForceLtr':
        'settings_subtitle_screen.dart',
    'subtitleHwAccel':
        'settings_subtitle_screen.dart',
    'subtitleShowHw':
        'settings_subtitle_screen.dart',
}

VALUE = re.compile(r'^\s{2}([a-zA-Z][A-Za-z0-9]*)\s*\(', re.M)


def enum_values(text, enum_name):
    """Values declared inside `enum <enum_name> { ... }`."""
    start = text.find('enum %s {' % enum_name)
    if start < 0:
        return []
    depth = 0
    end = start
    for i in range(text.index('{', start), len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    body = text[start:end]
    # Stop at the first method/field declaration; enum values come first.
    cut = re.search(r'^\s+(const|final|static|[A-Z][A-Za-z]*\??\s+get)\s', body, re.M)
    if cut:
        body = body[:cut.start()]
    return [m.group(1) for m in VALUE.finditer(body)]


def references(root, enum_name, value):
    """Files referencing `<Enum>.<value>`, excluding the declaring file."""
    needle = '%s.%s' % (enum_name, value)
    pattern = re.compile(re.escape(needle) + r'\b')
    hits = []
    lib = os.path.join(root, 'lib')
    for d, dirs, files in os.walk(lib):
        dirs[:] = [x for x in dirs if x not in ('.dart_tool', 'build')]
        for f in sorted(files):
            if not f.endswith('.dart'):
                continue
            path = os.path.join(d, f)
            rel = os.path.relpath(path, root)
            if rel.replace('\\', '/').endswith('_settings_service.dart'):
                continue
            try:
                with open(path, encoding='utf-8') as fh:
                    text = fh.read()
            except OSError:
                continue
            # A mention inside a comment is documentation, not a reader.
            code = re.sub(r'//[^\n]*', '', text)
            code = re.sub(r'/\*.*?\*/', '', code, flags=re.S)
            if pattern.search(code):
                hits.append(rel)
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    problems = []
    listed = []
    stale = []

    seen = set()
    for rel_source, enums in SOURCES:
        path = os.path.join(root, rel_source)
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        for enum_name in enums:
            for value in enum_values(text, enum_name):
                seen.add(value)
                hits = references(root, enum_name, value)
                acted_on = [
                    h for h in hits
                    if not h.replace('\\', '/').startswith(
                        UI_ONLY_DIR.replace('\\', '/'))
                ]
                if acted_on:
                    continue
                if value in DELIBERATE:
                    continue
                if value in KNOWN_OPEN:
                    listed.append((enum_name, value, hits))
                    continue
                problems.append((enum_name, value, hits))

    # An allow-list entry for a setting that no longer exists, or that now has
    # a reader, is stale — and a stale allow-list is how a ratchet slips.
    for name in sorted(set(KNOWN_OPEN) | set(DELIBERATE)):
        if name not in seen:
            stale.append((name, 'no such setting any more'))
    for enum_name, value, _ in []:
        pass
    for rel_source, enums in SOURCES:
        path = os.path.join(root, rel_source)
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        for enum_name in enums:
            for value in enum_values(text, enum_name):
                if value not in KNOWN_OPEN and value not in DELIBERATE:
                    continue
                hits = references(root, enum_name, value)
                acted_on = [
                    h for h in hits
                    if not h.replace('\\', '/').startswith(
                        UI_ONLY_DIR.replace('\\', '/'))
                ]
                if acted_on and value in KNOWN_OPEN:
                    stale.append(
                        (value,
                         'now read by %s — remove it from KNOWN_OPEN'
                         % acted_on[0]))

    for enum_name, value, hits in problems:
        print(' - %s.%s is stored and never read' % (enum_name, value))
        if hits:
            print('     only referenced in: %s' % ', '.join(hits))
        else:
            print('     referenced nowhere at all')
        print('     -> give it a reader outside lib/features/settings/, or '
              'remove the control. A switch that does nothing is worse than '
              'no switch.')

    for name, why in stale:
        print(' - allow-list entry "%s" is stale: %s' % (name, why))

    if listed:
        print('[info] %d known-open setting(s) tolerated: %s'
              % (len(listed), ', '.join(v for _, v, _ in listed)))

    total = len(problems) + len(stale)
    print('=== %d dead-setting issue(s) ===' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
