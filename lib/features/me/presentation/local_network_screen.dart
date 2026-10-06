import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../network/data/net_repository.dart';
import '../../network/data/net_server.dart';
import '../../network/presentation/net_browser_screen.dart';
import '../../network/presentation/net_widgets.dart';
import '../../network/presentation/server_form.dart';

/// Me → Local Network: MX Player's "Networks" — SMB, FTP, FTPS and SFTP
/// servers on this Wi-Fi, browsed and played like files on the phone.
///
/// The page is MX's: the blue band with the protocols, "How to use?" until
/// there is a server to show, and the blue + that adds one. What is added on
/// top: the saved servers themselves (MX keeps them in a drawer), signing in
/// before saving, Scan that names what it finds, and errors in words.
class LocalNetworkScreen extends ConsumerWidget {
  const LocalNetworkScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final p = await pickProtocol(context);
    if (p == null || !context.mounted) return;
    final server = await showServerForm(context, protocol: p);
    if (server == null || !context.mounted) return;
    unawaited(_browse(context, server));
  }

  Future<void> _browse(BuildContext context, NetServer server) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NetBrowserScreen(server: server),
    ));
  }

  Future<void> _edit(BuildContext context, NetServer server) async {
    final saved = await showServerForm(context,
        protocol: server.protocol, existing: server);
    if (saved == null || !context.mounted) return;
    unawaited(_browse(context, saved));
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, NetServer server) async {
    final s = AppStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => NetDialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(s.netDeleteConfirm(server.title),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(s.netDeleteBody,
                style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child:
                    Text(s.cancel, style: const TextStyle(color: Colors.white)),
              ),
              TextButton(
                key: const ValueKey('net-delete-ok'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(s.netDelete,
                    style: const TextStyle(color: NetColors.error)),
              ),
            ]),
          ],
        ),
      ),
    );
    if (ok == true) {
      await ref.read(netServersProvider.notifier).remove(server.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final servers = ref.watch(netServersProvider);
    final mm = s.locale.languageCode == 'my';
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        foregroundColor: Colors.white,
        title: Text(s.networks,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700)),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('net-info'),
            tooltip: s.howToUse,
            icon: Icon(Icons.info_outline_rounded,
                color: Colors.white, semanticLabel: s.howToUse),
            onPressed: () => unawaited(showNetInfo(context)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('net-add'),
        tooltip: s.addNewServer,
        backgroundColor: NetColors.fab,
        shape: const CircleBorder(),
        onPressed: () => unawaited(_add(context)),
        child: Icon(Icons.add_rounded,
            color: Colors.white, size: 30, semanticLabel: s.addNewServer),
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          const SliverToBoxAdapter(child: NetHero()),
          if (servers.isEmpty)
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 100),
              sliver: SliverToBoxAdapter(child: NetHowTo()),
            )
          else ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
                child: Text(s.netMyServers,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: mm ? 1.6 : 1.2)),
              ),
            ),
            SliverList.builder(
              itemCount: servers.length,
              itemBuilder: (_, i) => _ServerTile(
                server: servers[i],
                onOpen: () => unawaited(_browse(context, servers[i])),
                onEdit: () => unawaited(_edit(context, servers[i])),
                onDelete: () => unawaited(_delete(context, ref, servers[i])),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile(
      {required this.server,
      required this.onOpen,
      required this.onEdit,
      required this.onDelete});
  final NetServer server;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final who = server.anonymous
        ? s.netAnonymousTag
        : (server.domain.isNotEmpty
            ? '${server.domain}\\${server.user}'
            : server.user);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: const Color(0xFF1E1E20),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('net-server-${server.title}'),
          borderRadius: BorderRadius.circular(12),
          onTap: onOpen,
          onLongPress: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(children: <Widget>[
              ProtocolGlyph(server.protocol, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(server.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(server.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12.5)),
                      if (who.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Row(children: <Widget>[
                          Icon(
                              server.anonymous
                                  ? Icons.public_rounded
                                  : Icons.person_rounded,
                              size: 13,
                              color: Colors.white38),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(who,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 12)),
                          ),
                        ]),
                      ],
                    ]),
              ),
              PopupMenuButton<int>(
                key: ValueKey('net-menu-${server.title}'),
                icon:
                    const Icon(Icons.more_vert_rounded, color: Colors.white70),
                color: NetColors.dialog,
                onSelected: (v) => v == 0 ? onEdit() : onDelete(),
                itemBuilder: (_) => <PopupMenuEntry<int>>[
                  PopupMenuItem<int>(
                      value: 0,
                      child: Text(s.netEdit,
                          style: const TextStyle(color: Colors.white))),
                  PopupMenuItem<int>(
                      value: 1,
                      child: Text(s.netDelete,
                          style: const TextStyle(color: NetColors.error))),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
