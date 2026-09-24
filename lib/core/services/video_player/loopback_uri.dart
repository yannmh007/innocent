/// Whether an address is this app talking to itself.
///
/// WHY IT NEEDS A NAME. A URL on 127.0.0.1 is `http://`, so every test in
/// the player that asks "is this a network stream?" says yes about the
/// caching proxy — and for most of them that is the right answer, because
/// the proxy really does fetch over the network and really can stall. Two
/// things it is NOT right about: libmpv must not spill a second copy of the
/// film to disk when the proxy has already written it, and a read served
/// from flash at a hundred megabytes a second must not be recorded as a
/// measurement of somebody's mobile connection.
///
/// Both of those have to tell loopback from the internet, and neither should
/// be re-deriving the rule from a string prefix on its own.
bool isLoopbackUri(String uri) {
  final u = Uri.tryParse(uri);
  if (u == null) return false;
  if (u.scheme != 'http' && u.scheme != 'https') return false;
  final h = u.host;
  // `::1` arrives with the brackets already stripped by Uri.
  return h == '127.0.0.1' || h == 'localhost' || h == '::1';
}
