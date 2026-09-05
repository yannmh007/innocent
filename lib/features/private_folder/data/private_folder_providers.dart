import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/private_folder/private_folder_service.dart';

/// Single shared instance of the vault service. Kept in its own file (not
/// inside a screen) so every Private Folder surface — the main screen, the
/// recovery flow, the anti-theft settings — can import it without creating
/// a circular dependency between those screens.
final privateFolderServiceProvider = Provider<PrivateFolderService>((ref) {
  return PrivateFolderService();
});

/// Set of URIs hidden in Private Folder — filtered out of every public library
/// view so a vaulted video never resurfaces in the Local tab.
///
/// Moved here from library_provider.dart. It never had anything to do with the
/// library: it just builds a set from the vault's own entries. Living there
/// meant user_data_providers.dart had to import the whole library layer to
/// reach it, and once the library layer needed the watch registries back the
/// two files imported each other. Dart tolerates that cycle, but two files
/// this central pointing at each other is the kind of knot that makes every
/// later change harder than it should be. Both now depend on this leaf and
/// neither depends on the other.
final privateFolderUrisProvider = FutureProvider<Set<String>>((ref) async {
  final svc = ref.watch(privateFolderServiceProvider);
  final entries = await svc.loadEntries();
  return entries.map((e) => e.videoUri).toSet();
});
