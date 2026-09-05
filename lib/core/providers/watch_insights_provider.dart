import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/user_data/user_data_providers.dart';
import '../services/insights/watch_insights_service.dart';

/// Reactive insights snapshot derived from the live history list.
/// Recomputes automatically whenever a new HistoryEntry is added or
/// updated. Computation is cheap (single pass over the entries) so
/// no caching layer is needed; the provider just re-runs on changes.
final watchInsightsProvider = Provider<WatchInsights>((ref) {
  final history = ref.watch(historyProvider);
  return WatchInsightsService.compute(history);
});
