/// What went wrong, in terms the UI can act on.
///
/// A single "request failed" is useless here, because the responses mean
/// completely different things to a user: an expired session needs a re-login,
/// a missing subscription needs a paywall, and a dead network needs a retry
/// button. Collapsing them is how a paywall gets rendered as "something went
/// wrong" - which loses the sale and looks like a bug.
enum ApiErrorKind {
  /// No connection, DNS failure, timeout. Retryable.
  network,

  /// 401 - the session is missing or expired. Sign in again.
  unauthenticated,

  /// 403 with `needs_premium`. NOT an error: show the paywall.
  needsPremium,

  /// 403 for any other reason - region block, banned account, too many
  /// devices. Distinct from [needsPremium] because paying will not fix it.
  forbidden,

  /// 404.
  notFound,

  /// 429 - rate limited or too many concurrent streams.
  tooManyRequests,

  /// 5xx, or a response that could not be parsed.
  server,
}

class ApiException implements Exception {
  final ApiErrorKind kind;

  /// Server-supplied code, e.g. `needs_premium`, `too_many_devices`.
  final String? code;

  /// Safe to log. NEVER contains the URL, a token or a signed link - a crash
  /// report is a place logs go to be read by strangers.
  final String message;

  final int? statusCode;

  const ApiException(
    this.kind, {
    this.message = '',
    this.code,
    this.statusCode,
  });

  bool get isRetryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.server ||
      kind == ApiErrorKind.tooManyRequests;

  @override
  String toString() => 'ApiException(${kind.name}${code == null ? '' : ':$code'})';
}
