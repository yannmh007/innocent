import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ---------------------------------------------------------------------------
/// LAN presence + discovery for the Transfer tab.
///
/// WHY THIS EXISTS
/// Before this, connecting two phones meant the receiver had to scan a QR code
/// or type `http://192.168.x.y:8765/<36-char-token>` by hand. That is the one
/// thing that made Innocent feel unlike Zapya/SHAREit, where the other phone
/// simply *appears* in a list and you tap it.
///
/// HOW IT WORKS
/// A single UDP socket on port 8766 does both jobs (announce + listen), because
/// one device can be sharing AND looking at the same time and two sockets can't
/// hold the same port.
///
///   • While a share is live the sender broadcasts an "ann" packet every 1.5 s.
///   • A device that opens the Receive tab sends one "probe"; every sender
///     answers it immediately by unicast, so a device shows up in well under a
///     second instead of waiting for the next beacon tick.
///   • Entries expire after [_deviceTtl] with no packet, so a sender that walks
///     away or stops sharing drops off the list on its own.
///
/// DELIBERATELY NOT IN THE PACKET: the share token. Anyone on a café Wi-Fi can
/// read a broadcast, and a token in the clear would mean anyone can pull the
/// files. The receiver has to ask the sender for it over HTTP (`/pair`), which
/// is also what lets the sender show "Ko Ko's phone connected" and, optionally,
/// require a tap to approve.
///
/// Pure Dart — no new package. The only native help is a Wi-Fi MulticastLock
/// (see [_setMulticastLock]); without it many Android devices silently drop
/// 255.255.255.255 frames before the app ever sees them.
/// ---------------------------------------------------------------------------

/// UDP port both sides bind. Fixed on purpose: discovery can't discover a port.
const int kDiscoveryPort = 8766;

/// Protocol version. Bumped only on a breaking packet change; a device that
/// sees a version it doesn't know ignores the packet rather than guessing.
const int _kProtocolVersion = 1;

const Duration _beaconInterval = Duration(milliseconds: 1500);
const Duration _deviceTtl = Duration(seconds: 6);

/// Another Innocent device seen on the network.
class DiscoveredDevice {
  /// Stable per-install id, so the same phone doesn't appear twice after a
  /// DHCP lease change.
  final String id;
  final String name;

  /// Source address of the datagram — trusted over any IP the peer claims,
  /// because that is the address packets from us will actually reach.
  final String ip;
  final int port;
  final int fileCount;
  final int totalBytes;

  /// Wall-clock of the last packet from this device (used for TTL expiry).
  final DateTime seenAt;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.fileCount,
    required this.totalBytes,
    required this.seenAt,
  });

  /// Base URL for the HTTP control plane. The token is NOT part of this — it
  /// comes back from `/pair` once the sender lets us in.
  String get origin => 'http://$ip:$port';

  DiscoveredDevice copyWith({DateTime? seenAt}) => DiscoveredDevice(
        id: id,
        name: name,
        ip: ip,
        port: port,
        fileCount: fileCount,
        totalBytes: totalBytes,
        seenAt: seenAt ?? this.seenAt,
      );
}

/// What this device advertises while it is sharing.
class SelfAnnouncement {
  final int port;
  final int fileCount;
  final int totalBytes;
  const SelfAnnouncement({
    required this.port,
    required this.fileCount,
    required this.totalBytes,
  });
}

class TransferDiscovery {
  TransferDiscovery._();
  static final TransferDiscovery instance = TransferDiscovery._();

  static const MethodChannel _channel =
      MethodChannel('mx_clone/transfer_service');

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _reaperTimer;
  SelfAnnouncement? _self;
  bool _listening = false;
  bool _lockHeld = false;

  final Map<String, DiscoveredDevice> _devices = {};
  final StreamController<List<DiscoveredDevice>> _devicesCtrl =
      StreamController<List<DiscoveredDevice>>.broadcast();

  /// Live list of nearby devices, newest-seen last.
  Stream<List<DiscoveredDevice>> get devices => _devicesCtrl.stream;
  List<DiscoveredDevice> get currentDevices =>
      List.unmodifiable(_devices.values);

  String? _deviceId;
  String? _deviceName;

  /// This install's stable id. Generated once and kept in SharedPreferences so
  /// a device keeps its identity across restarts and IP changes.
  Future<String> deviceId() async {
    final cached = _deviceId;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('transfer_device_id');
      if (id == null || id.isEmpty) {
        final rnd = Random.secure();
        const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
        id = List.generate(12, (_) => cs[rnd.nextInt(cs.length)]).join();
        await prefs.setString('transfer_device_id', id);
      }
      _deviceId = id;
      return id;
    } catch (_) {
      // Prefs unavailable — a per-session id still keeps this run coherent.
      final rnd = Random.secure();
      final id = 'tmp${rnd.nextInt(1 << 32)}';
      _deviceId = id;
      return id;
    }
  }

  /// Name shown to other phones. The user's own label wins; otherwise the
  /// phone's marketing model ("Galaxy S23 Ultra") which is what people
  /// recognise in a list.
  Future<String> deviceName() async {
    final cached = _deviceName;
    if (cached != null) return cached;
    String name = 'Innocent phone';
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getString('transfer_device_name');
      if (custom != null && custom.trim().isNotEmpty) {
        _deviceName = custom.trim();
        return _deviceName!;
      }
    } catch (_) {}
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        final model = info.model.trim();
        final brand = info.brand.trim();
        if (model.isNotEmpty) {
          name = (brand.isNotEmpty &&
                  !model.toLowerCase().startsWith(brand.toLowerCase()))
              ? '$brand $model'
              : model;
        }
      }
    } catch (_) {}
    _deviceName = name;
    return name;
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _deviceName = trimmed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('transfer_device_name', trimmed);
    } catch (_) {}
  }

  // ---- socket lifecycle ---------------------------------------------------

  /// Bind the shared UDP socket if it isn't already up. Safe to call from both
  /// the announce and the listen path; whichever gets there first wins.
  Future<bool> _ensureSocket() async {
    if (_socket != null) return true;
    if (kIsWeb) return false;
    // Prime the id BEFORE the socket exists. `_onDatagram` drops packets whose
    // id is ours, and it reads the cached field synchronously — if the first
    // datagram arrived while that field was still null we would list our own
    // broadcast as a nearby device.
    await deviceId();
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      s.broadcastEnabled = true;
      // Best-effort: a stale socket from a previous process can leave the port
      // reusable but with a small buffer. Not fatal if it fails.
      s.listen(_onDatagram, onError: (_) {}, cancelOnError: false);
      _socket = s;
      await _setMulticastLock(true);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('TransferDiscovery.bind: $e');
      return false;
    }
  }

  /// Android filters broadcast/multicast frames not addressed to this device
  /// unless a MulticastLock is held. Without it, discovery works on some
  /// phones and mysteriously doesn't on others — the single most common cause
  /// of "it finds nothing on my Redmi".
  Future<void> _setMulticastLock(bool on) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (on == _lockHeld) return;
    try {
      await _channel.invokeMethod(
          on ? 'acquireMulticastLock' : 'releaseMulticastLock');
      _lockHeld = on;
    } catch (e) {
      if (kDebugMode) debugPrint('TransferDiscovery.multicastLock: $e');
    }
  }

  Future<void> _closeSocketIfIdle() async {
    if (_self != null || _listening) return;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _reaperTimer?.cancel();
    _reaperTimer = null;
    await _setMulticastLock(false);
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  // ---- announcing (sender side) -------------------------------------------

  /// Start advertising this device as a live share. Called when the sender
  /// presses Start; refreshing the file count later is just another call.
  Future<void> startAnnouncing(SelfAnnouncement ann) async {
    _self = ann;
    if (!await _ensureSocket()) return;
    _beaconTimer?.cancel();
    // Send one immediately so a phone already watching sees it now, then keep
    // a slow heartbeat going for phones that open the tab later.
    unawaited(_sendAnnounce(null));
    _beaconTimer = Timer.periodic(_beaconInterval, (_) {
      if (_self == null) return;
      unawaited(_sendAnnounce(null));
    });
  }

  Future<void> stopAnnouncing() async {
    final was = _self;
    _self = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (was != null) {
      // Courtesy goodbye so watchers drop us instantly instead of waiting out
      // the TTL. Best-effort: a lost packet just means a 6 s stale entry.
      unawaited(_sendBye());
    }
    await _closeSocketIfIdle();
  }

  Future<void> _sendAnnounce(InternetAddress? to) async {
    final s = _socket;
    final self = _self;
    if (s == null || self == null) return;
    final payload = jsonEncode({
      't': 'ann',
      'v': _kProtocolVersion,
      'id': await deviceId(),
      'name': await deviceName(),
      'port': self.port,
      'n': self.fileCount,
      'b': self.totalBytes,
    });
    _sendTo(payload, to);
  }

  Future<void> _sendBye() async {
    final s = _socket;
    if (s == null) return;
    _sendTo(
      jsonEncode({'t': 'bye', 'v': _kProtocolVersion, 'id': await deviceId()}),
      null,
    );
  }

  /// Send [payload] to one peer, or broadcast it when [to] is null.
  ///
  /// Broadcast goes to two addresses on purpose. 255.255.255.255 is the
  /// standard one but some Android builds and some routers drop it; the
  /// subnet-directed address (192.168.43.255 for a hotspot, 192.168.1.255 for
  /// a home router) survives where the other doesn't. Dart's NetworkInterface
  /// doesn't expose netmasks, so the /24 assumption below is a heuristic —
  /// correct for essentially every phone hotspot and consumer router.
  void _sendTo(String payload, InternetAddress? to) {
    final s = _socket;
    if (s == null) return;
    final data = utf8.encode(payload);
    try {
      if (to != null) {
        s.send(data, to, kDiscoveryPort);
        return;
      }
      s.send(data, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (e) {
      if (kDebugMode) debugPrint('TransferDiscovery.send: $e');
    }
    if (to != null) return;
    unawaited(_broadcastToSubnets(data));
  }

  Future<void> _broadcastToSubnets(List<int> data) async {
    final s = _socket;
    if (s == null) return;
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final sent = <String>{};
      for (final ni in ifaces) {
        for (final addr in ni.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          if (!sent.add(bcast)) continue;
          try {
            s.send(data, InternetAddress(bcast), kDiscoveryPort);
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('TransferDiscovery.subnetBroadcast: $e');
    }
  }

  // ---- listening (receiver side) ------------------------------------------

  /// Begin watching for nearby senders. Sends one probe straight away so the
  /// list fills in immediately rather than after a beacon tick.
  Future<void> startListening() async {
    _listening = true;
    if (!await _ensureSocket()) return;
    _reaperTimer?.cancel();
    _reaperTimer = Timer.periodic(const Duration(seconds: 2), (_) => _reap());
    await probe();
  }

  Future<void> stopListening() async {
    _listening = false;
    _reaperTimer?.cancel();
    _reaperTimer = null;
    _devices.clear();
    _emit();
    await _closeSocketIfIdle();
  }

  /// Ask every sender on the network to identify itself right now.
  Future<void> probe() async {
    if (!await _ensureSocket()) return;
    _sendTo(
      jsonEncode({
        't': 'probe',
        'v': _kProtocolVersion,
        'id': await deviceId(),
      }),
      null,
    );
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return; // Not ours — some other app broadcasting on the same port.
    }
    if ((msg['v'] as num?)?.toInt() != _kProtocolVersion) return;
    final id = msg['id'] as String?;
    if (id == null || id.isEmpty) return;
    // Our own broadcast comes back to us on the same socket. Ignore it, or the
    // sender would list itself as a nearby device.
    if (id == _deviceId) return;

    switch (msg['t']) {
      case 'probe':
        // Someone just opened their Receive tab. If we're sharing, answer by
        // unicast so they see us without waiting for the next beacon.
        if (_self != null) unawaited(_sendAnnounce(dg.address));
        break;
      case 'ann':
        if (!_listening) return;
        final port = (msg['port'] as num?)?.toInt();
        if (port == null || port <= 0) return;
        _devices[id] = DiscoveredDevice(
          id: id,
          name: (msg['name'] as String?)?.trim().isNotEmpty == true
              ? (msg['name'] as String).trim()
              : 'Unknown device',
          ip: dg.address.address,
          port: port,
          fileCount: (msg['n'] as num?)?.toInt() ?? 0,
          totalBytes: (msg['b'] as num?)?.toInt() ?? 0,
          seenAt: DateTime.now(),
        );
        _emit();
        break;
      case 'bye':
        if (_devices.remove(id) != null) _emit();
        break;
    }
  }

  void _reap() {
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere((_, d) => now.difference(d.seenAt) > _deviceTtl);
    if (_devices.length != before) _emit();
  }

  void _emit() {
    if (_devicesCtrl.isClosed) return;
    _devicesCtrl.add(List.unmodifiable(_devices.values));
  }

  /// Tear everything down (app shutdown). Not called in normal use — the
  /// socket closes itself once neither role needs it.
  Future<void> dispose() async {
    _self = null;
    _listening = false;
    await _closeSocketIfIdle();
  }
}
