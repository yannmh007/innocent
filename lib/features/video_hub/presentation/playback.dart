import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/video_player/stream_renewal.dart';
import '../data/api/event_sender.dart';
import '../data/device_identity.dart';
import '../domain/access.dart';
import '../data/cache/stream_cache_id.dart';
import '../data/cache/stream_cache_server.dart';
import '../domain/rendition.dart';
import '../../../core/services/network/throughput_memory.dart';
import '../domain/access_policy.dart';
import '../domain/capability.dart';
import '../domain/video_content.dart';
import 'video_hub_provider.dart';
import 'widgets/paywall_sheet.dart';
import 'account_provider.dart';

/// Asks the repository for a playable URL and acts on the answer.
///
/// One function, because four surfaces need it - the hero's Play button, the
/// detail screen, the album viewer and the search results - and playback is
/// exactly the kind of thing that quietly diverges when written four times:
/// one caller forgets the mounted check, another shows a message where a
/// paywall belongs, a third passes the wrong title into the player.
///
/// THE UI NEVER DECIDES WHETHER PLAYBACK IS ALLOWED. It asks, and it renders
/// whichever of three answers comes back:
///
///   * a URL          -> open the player;
///   * needsPremium   -> open the paywall, not an error;
///   * unavailable    -> a plain message.
///
/// Telling the second two apart is the whole reason [PlaybackGrant] carries a
/// reason instead of returning null: a paywall rendered as "something went
/// wrong" loses the sale AND reads as a bug.
Future<void> playMedia(
  BuildContext context,
  WidgetRef ref, {
  required VideoContent content,
  required MediaRef source,
  String? titleOverride,
}) async {
  final s = AppStrings.of(context);
  // The device id lets the server bind this grant and enforce the
  // concurrency cap. It is sent as information, not as an argument for
  // access - the server ignores anything the client claims about its rights.
  final deviceId = await DeviceIdentity.get();
  final grant = await ref.read(contentRepositoryProvider).requestPlayback(
        content: content,
        source: source,
        deviceId: deviceId,
      );

  if (!context.mounted) return;

  // BOTH BRANCHES ARE RECORDED, and the refusal is the more valuable of the
  // two. `playback_denied` over `play_start` is the conversion funnel: if many
  // people hit the paywall and few subscribe, the price or the size of the
  // free tier is wrong — and that is a business answer no amount of code
  // produces. It is also the number nobody can estimate by guessing.
  if (grant.isGranted) {
    logEvent(
      ref,
      Ev.playStart,
      titleId: content.id,
      // The album clip, when this is one. Without it every clip in a title
      // would be indistinguishable from the main film, and "which extra do
      // people actually watch" would be unanswerable.
      assetId: source.provider == 'asset' ? source.locator : null,
    );
    // Screen-capture protection for paid content is requested here but HELD
    // BY THE PLAYER, which acquires it in initState and releases it in
    // dispose. The service is ref-counted, so a claim taken by the caller
    // would never be released and would leave the whole app capture-blocked
    // until it restarted.
    //
    // Honest about what it buys: it blocks Android screenshots and most screen
    // recorders, which is the cheap and common leak. It does nothing against a
    // rooted device, a patched build, or a second camera - and nothing can.
    //
    // A GRANT CAN DIE MID-FILM, AND THE PLAYER MUST BE ABLE TO ASK AGAIN.
    //
    // The URL is signed and short-lived - that is the protection. But libmpv
    // re-issues an HTTP request on any seek outside its buffer, and the
    // player's reconnect logic was written for a Wi-Fi blip: it reopened the
    // same address, which cannot work once a signature has expired. A film
    // longer than the URL's lifetime simply stopped part of the way through.
    //
    // So the player is handed a closure, never a grant: it can ask for a fresh
    // URL without learning what entitlement is, and THIS file stays the only
    // place a [PlaybackGrant] is interpreted. A renewal is a new server
    // request, so entitlement, expiry and the concurrency cap are all decided
    // again - a subscription that lapsed mid-film is refused here, not
    // extended.
    // ─── WHICH COPY OF THIS FILM ───────────────────────────────────────
    //
    // The server hands over every rung it has; the choice is made here,
    // because the fact that decides it — what this phone's connection is
    // actually delivering — exists only on this phone. `renditions` is empty
    // for everything uploaded before the transcoding pipeline, and for
    // anything small enough not to need a ladder, and empty means "play the
    // original", which is exactly what this line did before.
    await ThroughputMemory.read();
    final chosen = pickRendition(
      grant.renditions,
      measuredKbps: ThroughputMemory.current,
    );
    final playUrl = chosen?.url ?? grant.url!;

    // ─── AND THE PHONE KEEPS WHAT IT RECEIVES ──────────────────────────
    //
    // Bytes already downloaded are the cheapest bytes there are. Without
    // this, dragging the bar back thirty seconds re-downloads thirty
    // seconds, and watching a clip twice downloads it twice — over the very
    // connections the rest of this work has spent weeks apologising to.
    //
    // The player is handed a LOCAL address. Behind it, the cache serves what
    // the phone already has and fetches only what it does not — and quietly
    // replaces the signed URL when it expires, so a film longer than ten
    // minutes stops stumbling once per URL lifetime.
    //
    // NULL MEANS PLAY THE REMOTE URL, which is what this line did before any
    // of it existed. A cache that cannot start costs smoothness, never
    // playback.
    final assetId = source.provider == 'asset' && source.locator.isNotEmpty
        ? source.locator
        : null;
    final cacheId = streamCacheId(
      titleId: content.id,
      assetId: assetId,
      height: chosen?.height ?? 0,
    );
    StreamCacheServer.instance.releaseAllExcept(<String>{cacheId});
    final localUrl = await StreamCacheServer.instance.localUrlFor(
      cacheId: cacheId,
      upstream: playUrl,
      total: chosen?.bytes,
      // A title, never an object key: a key is a map of the bucket and has
      // no business on a viewer's storage screen.
      label: titleOverride ?? content.displayTitle(s.locale.languageCode),
      // The proxy's own way of dealing with an expired link. It goes back
      // through `requestPlayback`, so entitlement, expiry and the device cap
      // are decided again — a lapsed subscription stops the film here rather
      // than being cached along with the bytes.
      refresh: () async {
        final fresh = await ref.read(contentRepositoryProvider).requestPlayback(
              content: content,
              source: source,
              deviceId: deviceId,
            );
        if (!fresh.isGranted) return null;
        final same = fresh.renditions
            .where((r) => r.height == (chosen?.height ?? -1))
            .toList();
        // The SAME rung, because the cache entry is that rung's bytes and
        // mixing two encodes into one file is a corrupted film.
        if (same.isNotEmpty) return same.first.url;
        return chosen == null ? fresh.url : null;
      },
    );
    final openUrl = localUrl ?? playUrl;

    // The renewal picks again rather than reusing this rung. A film longer
    // than a signature's life is renewed mid-playback, and by then the
    // player has measured the connection for real — so the second half of a
    // long film can be a better or a smaller copy than the first, decided on
    // evidence the first choice did not have.
    StreamRenewal.register(openUrl, ({int? belowKbps}) async {
      final fresh = await ref.read(contentRepositoryProvider).requestPlayback(
            content: content,
            source: source,
            deviceId: deviceId,
          );
      if (!fresh.isGranted) return null;
      final again = pickRendition(
        fresh.renditions,
        measuredKbps: ThroughputMemory.current,
        // Set only when the player has MEASURED the current copy as too
        // heavy for this connection. Then this is not a renewal at all, it
        // is a downgrade, and handing back the same rung would repeat the
        // stall that asked for it.
        ceilingKbps: belowKbps,
      );
      // No ladder and a downgrade was asked for: there is nothing smaller to
      // give, so say so rather than handing back the same URL and making the
      // player reopen for no reason.
      if (belowKbps != null && again == null) return null;
      final freshUrl = again?.url ?? fresh.url;
      if (freshUrl == null) return null;

      // A DOWNGRADE IS A DIFFERENT FILE, so it is a different cache entry.
      // Pointing the existing entry at a smaller encode would write two
      // different videos into one set of byte ranges, and the result is not
      // a video at all.
      final nextId = streamCacheId(
        titleId: content.id,
        assetId: assetId,
        height: again?.height ?? 0,
      );
      if (nextId == cacheId) {
        // Same rung: the URL was only stale. Hand the proxy the new one and
        // keep the player on the address it already has.
        StreamCacheServer.instance.updateUpstream(cacheId, freshUrl);
        return openUrl;
      }
      StreamCacheServer.instance.releaseAllExcept(<String>{nextId});
      final nextLocal = await StreamCacheServer.instance.localUrlFor(
        cacheId: nextId,
        upstream: freshUrl,
        total: again?.bytes,
        label: titleOverride ?? content.displayTitle(s.locale.languageCode),
        refresh: () async {
          final f2 = await ref.read(contentRepositoryProvider).requestPlayback(
                content: content,
                source: source,
                deviceId: deviceId,
              );
          if (!f2.isGranted) return null;
          final same = f2.renditions
              .where((r) => r.height == (again?.height ?? -1))
              .toList();
          if (same.isNotEmpty) return same.first.url;
          return again == null ? f2.url : null;
        },
      );
      return nextLocal ?? freshUrl;
    });
    context.push(
      Routes.player,
      extra: <String, dynamic>{
        'uri': openUrl,
        // audit_video_hub.md M5: the player's title bar gets the Burmese
        // title too, when that is the language the app is in.
        'title': titleOverride ?? content.displayTitle(s.locale.languageCode),
        'secure': content.accessTier == AccessTier.premium,
        // What the player reports progress against. Two opaque strings: it
        // never learns what a title is, only what to put in an event.
        'titleId': content.id,
        if (source.provider == 'asset' && source.locator.isNotEmpty)
          'assetId': source.locator,
        // NEVER WRITE THIS URL DOWN.
        //
        // It is a different string every time the same title is opened, so a
        // resume point or history entry keyed on it can never match twice -
        // every title would restart at 00:00 and Continue Watching would fill
        // with duplicates. Worse, those rows live on the LOCAL tab, in front
        // of the age gate rather than behind it, and each one would open a URL
        // that expired hours ago.
        'ephemeral': true,
      },
    );
    return;
  }

  logEvent(
    ref,
    Ev.playbackDenied,
    titleId: content.id,
    assetId: source.provider == 'asset' ? source.locator : null,
    // The reason, because the three are completely different problems: a
    // paywall is a sale not made, a wrong device is a paying customer locked
    // out, and unavailable is an outage. One count of "denied" would hide
    // all three behind each other.
    meta: <String, dynamic>{'reason': grant.denial?.name ?? 'unknown'},
  );

  if (grant.denial == AccessDenial.needsPremium) {
    final policy = ref.read(accessPolicyProvider);
    final tier = ref.read(viewerProvider).tier;
    final unlocked = await PaywallSheet.show(
      context,
      content: content,
      lockedCount: policy.lockedCountFor(content, tier),
    );
    // Straight through on success: making someone who has just paid hunt for
    // the play button again is the worst possible moment to add a step.
    if (unlocked && context.mounted) {
      await playMedia(
        context,
        ref,
        content: content,
        source: source,
        titleOverride: titleOverride,
      );
    }
    return;
  }

  // A device refusal gets its own message and a longer read. It is the only
  // refusal here the user can actually do something about, and the sentence
  // has to carry the instruction - there is no screen behind it yet.
  final isDevice = grant.denial == AccessDenial.wrongDevice;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(isDevice ? s.vhWrongDevice : s.vhUnavailable),
      duration: Duration(seconds: isDevice ? 5 : 2),
    ),
  );
}

/// Convenience for a catalogue entry's primary source.
Future<void> playContent(
  BuildContext context,
  WidgetRef ref,
  VideoContent content,
) {
  return playMedia(context, ref, content: content, source: content.source);
}

/// Plays a title that is already on this device.
///
/// EXISTS IN THIS FILE, AND ONLY IN THIS FILE, because the structural checker
/// is right: `tool/checks/security_invariants.py` refuses any screen but this
/// one referencing `Routes.player`, so that every play in the feature passes
/// one gate. The first version of the Downloads screen pushed the player
/// itself, and the check failed the build — correctly. A downloaded file is
/// the one path where nothing would otherwise stop a viewer whose
/// subscription ended last week.
///
/// WHAT THIS CHECK IS AND IS NOT, stated rather than implied. Online, the
/// SERVER decides: `requestPlayback` re-reads the subscription, the tier and
/// the device binding, and the client cannot overrule it. Offline there is no
/// server to ask, so this is [AccessPolicy] — the client's own table — and a
/// client-side check protects nothing against anyone willing to modify the
/// app. It is a real weakening, and it is inherent to offline playback rather
/// than a shortcut taken here.
///
/// What limits it: the file only exists because the server authorised the
/// download, every resume during that download re-authorised it, and the
/// shelf is emptied on sign-out. The bytes are a plain file — see
/// [OfflineLibrary] — so this is friction, not enforcement, and the honest
/// description is that a download is a grant the app cannot take back on its
/// own.
Future<void> playOffline(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String titleId,
  required String title,
  required bool premium,
  required bool sealed,
}) async {
  final tier = ref.read(viewerProvider).tier;

  // The same capability the Download button was drawn from, asked again at
  // play time. A subscription that lapsed between downloading and watching is
  // exactly the case this catches.
  if (premium &&
      !CapabilityMatrix.allows(tier, Capability.downloadOffline)) {
    logEvent(ref, Ev.playbackDenied, titleId: titleId,
        meta: const <String, dynamic>{'reason': 'offline_not_entitled'});
    if (!context.mounted) return;
    await PaywallSheet.show(context, content: null, lockedCount: 0);
    return;
  }

  if (!context.mounted) return;
  context.push(
    Routes.player,
    extra: <String, dynamic>{
      // `sealed://` FOR A CIPHERTEXT FILM, and the plain path for everything
      // else. The player resolves the scheme to a loopback address that
      // decrypts on demand; handing it the path would draw noise, and handing
      // it the loopback address directly would key the resume point on a port
      // and a token that change every launch. See PlayerPlayback._doOpenVideo.
      'uri': sealed ? 'sealed://$path' : path,
      'title': title,
      // Same paid content it was online, so the same capture protection.
      'secure': premium,
      // NOT ephemeral, unlike a stream: a file path is a stable identity, so
      // a resume point keyed on it works and is worth keeping.
      'ephemeral': false,
      // No titleId: the reporter would have no network to flush to for the
      // whole session, and a device coming back online hours later would post
      // a burst of events timestamped to a viewing nobody can place. Offline
      // viewing is deliberately not measured rather than measured badly.
    },
  );
}

/// Opens the paywall for a locked album item.
///
/// Separate from [playMedia] because a locked PHOTO never had a stream to
/// request - there is nothing to ask the repository for, only something to
/// offer.
Future<void> promptUpgrade(
  BuildContext context,
  WidgetRef ref, {
  VideoContent? content,
}) async {
  int locked = 0;
  if (content != null) {
    locked = ref
        .read(accessPolicyProvider)
        .lockedCountFor(content, ref.read(viewerProvider).tier);
  }
  await PaywallSheet.show(context, content: content, lockedCount: locked);
}
