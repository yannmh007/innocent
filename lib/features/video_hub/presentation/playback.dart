import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/video_player/stream_renewal.dart';
import '../data/device_identity.dart';
import '../domain/access.dart';
import '../domain/access_policy.dart';
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

  if (grant.isGranted) {
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
    StreamRenewal.register(grant.url!, () async {
      final fresh = await ref.read(contentRepositoryProvider).requestPlayback(
            content: content,
            source: source,
            deviceId: deviceId,
          );
      return fresh.isGranted ? fresh.url : null;
    });
    context.push(
      Routes.player,
      extra: <String, dynamic>{
        'uri': grant.url,
        // audit_video_hub.md M5: the player's title bar gets the Burmese
        // title too, when that is the language the app is in.
        'title': titleOverride ?? content.displayTitle(s.locale.languageCode),
        'secure': content.accessTier == AccessTier.premium,
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
