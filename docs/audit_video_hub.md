# Domain 6 — Video Hub: an audit

*13 September 2026. No code changed by this document.*

11,451 lines across 49 files — the largest surface in the app and the only one
never audited. It is also the only one that handles **money** and **access**,
and the only one whose failures cost the user in Kyat rather than in patience.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## How this one had to be read differently

The other five domains grew in this repository and `git log` explains them.
This one did not:

```
$ git log --oneline -- lib/features/video_hub/
596ab26 dart fix the style lints: 705 → 295 (#11)
501d9b1 Extract Innocent v1.64.7 GitHub-ready release into repo root
```

**Two commits, one of which is the whole feature arriving at once.** There is
no history to consult about why anything is the way it is. So the evidence for
"deliberate" here is the in-file comments and `docs/premium_backend_spec.md`,
and both turn out to be unusually good — this is the most carefully reasoned
code in the project. Several things that look like defects are decisions with
the argument written next to them, and §2 lists seventeen of them rather than
reporting them.

That cuts the other way too. Where a file argues at length for a rule and then
does not follow it, the gap is evidence rather than ambiguity — and four of the
findings below are exactly that shape.

## The short version

**The enforcement model is sound and I could not find a hole in it.** No code
path in this feature produces a playable URL on its own; `requestPlayback` asks
the server and renders whichever of three answers comes back; the catalogue
query never selects the locator column; the client never sees a media path.
The dev "approve my own payment" button that once shipped in release is now
behind `kDebugMode` with a paragraph explaining why. That is the part that
matters most and it is in good order.

**What is not in good order is everything around the money.**

Three separate failures land on the two screens where somebody is trying to
pay, and each is a few lines:

* the payment-claim form **has no error path at all** — a failed submit stops
  the spinner and says nothing, on the screen where the user has already sent
  real money by KPay;
* a failed instructions fetch silently falls back to a **bundled placeholder
  KPay number, `09-000-000-000`, rendered with a Copy button** under the words
  "send the money here";
* the sign-in sheet tells every user, in production, against the live backend,
  **"Development build: use code 000000"**.

None of the three is subtle and none is hard to fix. They are on this list
together because the same reviewer clearly did think hard about the payment
model — `_SubmittedState` even carries a comment about never claiming access
before a human confirms — and then nobody walked the unhappy path.

**Second theme: the catalogue is paged in the UI and not on the wire.**
`ApiContentRepository._page` fetches *the entire result set* and slices it in
Dart. Every "load more" re-downloads everything. So does every filter preview.
The notifier that calls it opens with "Fetching four hundred posters to show
nine is slow on a good connection and a wall on a bad one", which is an exact
description of what the layer beneath it does.

**Third: the app is built for Burmese users and the Burmese title is never
shown.** `title_mm` is in the column list, is fetched on every catalogue
request, is parsed into the model, and is rendered by nothing. Search does not
look at it either — though the *demo* repository does.

---

## 1. Findings

### M1 — the payment claim form has no error path

`lib/features/video_hub/presentation/account/premium_request_screen.dart:55`

```dart
Future<void> _submit() async {
  if (_reference.text.trim().isEmpty) return;
  setState(() => _busy = true);
  try {
    await ref.read(accountRepositoryProvider).submitPremiumRequest(...);
    ref.invalidate(myPremiumRequestsProvider);
    if (!mounted) return;
    setState(() => _submitted = true);
  } finally {
    if (mounted) setState(() => _busy = false);
  }
}
```

`try`/`finally`, with **no `catch`**. `submitPremiumRequest` reaches
`_api.postJson`, which throws `ApiException` on a timeout, a dropped
connection, a 401, an RLS refusal, or a 429.

When it does: the `finally` clears `_busy`, `_submitted` stays false, and the
exception escapes an async callback with nothing awaiting it. The spinner
becomes a button again. **Nothing else happens.** No message, no retry, no
change to the screen.

This is the screen a user reaches *after* sending money through KPay. What
they have in hand is a transaction reference and no idea whether it was
recorded. The two things they will do are both bad: submit again, which on a
partial success writes a second `premium_requests` row for one payment and
gives the operator a reconciliation problem the spec explicitly warns about
(§5); or close the app believing the claim is queued when it is not, and wait
for an approval that can never come because nobody knows to make it.

The rest of the file is written by someone who understood this. `_SubmittedState`
carries: *"Says 'waiting for review', never 'you are premium'. Telling someone
they have access before a human has confirmed the money arrived is how a free
account ends up watching paid content."* The success path was thought about
carefully. The failure path was not written.

Compare `sign_in_sheet.dart`, twelve files away, which catches on all three of
its actions.

| | |
|---|---|
| likelihood | **မကြာခဏ** — one flaky request on a Myanmar mobile network |
| severity | **high** — money already sent, claim silently lost |
| fix | **easy** — a `catch` and a localised message with a Retry |

### M2 — a failed instructions fetch shows a KPay number that does not exist

`lib/features/video_hub/data/api/api_account_repository.dart:183`
`lib/features/video_hub/domain/account.dart:131`

```dart
} on ApiException {
  // Falls through to the bundled defaults. Showing the last-known KPay
  // number beats showing an error on the one screen where the user is
  // trying to give you money.
}
return PaymentInstructions.placeholder;
```

**It is not the last-known number.** Nothing persists a successful fetch. The
fallback is a compile-time constant:

```dart
static const PaymentInstructions placeholder = PaymentInstructions(
  payeeName: 'Innocent',
  payeeNumber: '09-000-000-000',
  prices: <String, String>{'yearly': 'MMK 34,000', 'monthly': 'MMK 3,500'},
);
```

`account.dart` is honest about what it is — *"bundled defaults exist only so the
screen renders before there is one"* — and the two comments contradict each
other. The one that reaches the user is the code.

`premium_request_screen.dart:98` renders it identically to real data: step 1,
"send the money to", the number in bold, **a Copy button** beside it (added,
per its own comment, "because a mistyped digit sends money to a stranger"), and
a price. There is no visual difference between a number the operator set this
morning and a number that has never received a Kyat.

Two ways this bites, in order of cost:

1. `09-000-000-000` is not a real KPay account. A user copies it, KPay refuses
   or the transfer goes nowhere, and the app has just given a payment
   instruction it invented.
2. The **prices** are stale by construction. Raise the yearly plan on the
   server and every user with a bad connection is quoted MMK 34,000 — and will
   pay it, and will be right to be annoyed.

The comment's instinct is sound: an error on the payment screen is bad. The
answer is to make the sentence true — cache the last successful fetch and show
that, or say plainly "could not load the current payment details, try again" —
rather than to invent a payee.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — any failed request on that screen |
| severity | **high** — a payment instruction the operator never gave |
| fix | **easy** — persist the last good fetch; refuse to show a placeholder as if it were real |

### M3 — "Development build: use code 000000" ships in release

`lib/features/video_hub/presentation/account/sign_in_sheet.dart:216`

```dart
if (_codeSent) ...<Widget>[
  ...
  // Stated plainly rather than hidden. A development stub that
  // pretends to be secure teaches the wrong lesson to whoever
  // wires the real backend.
  Text(
    s.vhSignInDevCode(LocalAccountRepository.devCode),
    style: VH.meta.copyWith(fontSize: 11.5),
  ),
],
```

No `kDebugMode`. No check that the repository in use is the stub. The only
condition is `_codeSent`, which is true on **every** phone sign-in.

`BackendConfig` has been wired to the live project since 1 September 2026
(`backend_config.dart:41`), so `accountRepositoryProvider` returns
`ApiAccountRepository` and the OTP is a real SMS from Supabase. The sheet then
prints, in the user's own language:

```
en  Development build: use code 000000
my  စမ်းသပ် ဗားရှင်း: ကုဒ် 000000 သုံးပါ
th  เวอร์ชันพัฒนา: ใช้รหัส 000000
```

The user types `000000`, the server rejects it, and `_verify`'s catch says
"That code is not correct" — which is true of the code the app just told them
to use. There is nothing on the screen suggesting the SMS matters. The most
likely outcome is that they give up before signing in, which for this app means
before paying, because sign-in is a precondition of the payment flow
(`paywall_sheet.dart:174`).

**The comment is right and is in the wrong build.** Its argument — a dev stub
that pretends to be secure teaches the wrong lesson — applies to a developer
looking at a debug build. It has no application to a user in Yangon.

The identical hazard forty lines away in `account_screen.dart:463` **is**
guarded, with an unusually good paragraph:

> *"In a release build it is a one-tap self-upgrade… `LocalAccountRepository`
> makes it harmless once a backend is configured — but 'harmless as long as a
> config value is set' is not a control… `kDebugMode` is a compile-time
> constant, so the tree-shaker removes this branch from a release binary
> entirely: the button is not hidden, it is absent."*

Every word of that applies here. It was applied to one of the two.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every phone sign-in, every user |
| severity | **high** — blocks sign-in, and sign-in gates payment |
| fix | **trivial** — `if (kDebugMode && repo is LocalAccountRepository)` |

### M4 — the catalogue is paged in the UI and not on the wire

`lib/features/video_hub/data/api/api_content_repository.dart:127`

```dart
Future<ContentPage> _page({
  String path = '/rest/v1/titles',
  required Map<String, String> query,
  required int page,
  required int pageSize,
}) async {
  final from = page * pageSize;
  final to = from + pageSize - 1;
  final body = await _api.getJson(
    path,
    query: query,
    // `count=exact` is what makes "42 titles" and "Show 24 results"
    // possible. Without it the UI can only say "some".
    // Range is a header in PostgREST, but passing offset/limit keeps this
    // readable and works through RPC too.
  );
  final all = _titles(body);
  final total = all.length;
  ...
  return ContentPage(items: all.sublist(from, end), ...);
}
```

**The comment describes code that is not there.** No `Range` header is sent, no
`count=exact` is requested, and no `offset` or `limit` reaches `query` —
`_filterQuery` contributes only `genres`, `year`, `quality_label` and `order`.
Every call downloads the complete result set and throws away all but thirty
rows.

The layer above states the requirement precisely
(`paged_catalogue.dart:230`):

> *"Paging is not optional at catalogue scale. Fetching four hundred posters to
> show nine is slow on a good connection and a wall on a bad one, and this app
> is built for phones where the connection is the constraint."*

So scrolling a 400-title category to the fourth page transfers the catalogue
four times, and the fourth page arrives no sooner than the first.

**The amplifier is the filter sheet.** `video_hub_screen.dart:378`:

```dart
Future<int> _countFor({...}) async {
  final page = await ref.read(contentRepositoryProvider).getCatalogue(
        category: category, filters: filters, pageSize: 1,
      );
  return page.totalCount;
}
```

`pageSize: 1` — to render "Show 24 titles" on the Apply button. It downloads
everything to count it. `FilterSheet` debounces at 120 ms
(`filter_sheet.dart:87`), which is a real and correct mitigation, but a user
deliberating over genres still triggers one full catalogue download per pause.
On mobile data that is the user paying, in money, to be told a number the
server could have computed.

**And `totalCount` becomes a lie at scale.** PostgREST enforces a `max-rows`
cap (Supabase Cloud commonly sets 1000); past it the array is silently
truncated, so `all.length` reports the cap, `hasMore` goes false at the wrong
place, and the grid ends early with no error. *Verify this project's
`db-max-rows` before sizing the fix* — see §3.

Note that `getRowCatalogue` cannot be fixed by the same edit: it goes through
`/rest/v1/rpc/row_catalogue`, and offset/limit on an RPC is the function's
business, not a query parameter's.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every second page and every filter change |
| severity | **high** — the app's stated primary constraint, inverted |
| fix | **moderate** — `Range` header plus `Prefer: count=exact` for the table path; add `p_offset`/`p_limit` to the two RPCs |

### M5 — the Burmese title is fetched, and shown to nobody

`api_content_repository.dart:39` selects `title_mm`. Line 449 parses it into
`VideoContent.titleMm`, whose doc says *"Localized title shown when the active
locale has one."*

```
$ grep -rn "titleMm" lib/features/video_hub/presentation/
$
```

**Nothing.** Every render site — `poster_card.dart:185`,
`featured_hero.dart:93`, `content_detail_screen.dart:81`,
`album_viewer_screen.dart:118`, the player route in `playback.dart:91` — uses
`content.title`. The Burmese title crosses the network on every catalogue
request and is discarded.

Search is the same omission with sharper teeth
(`api_content_repository.dart:236`):

```dart
'title': 'ilike.*$q*',
```

One column. **A user typing a Burmese title into the search box gets nothing
back**, in an app whose audience is mostly Burmese, against a catalogue that
stores the Burmese title.

The clinching detail: `VideoContent.searchHaystack` (`video_content.dart:277`)
*does* include `titleMm`, and `DemoContentRepository.search` uses it
(`demo_content_repository.dart:268`). **The bundled demo catalogue searches in
Burmese; the real one does not.** Whoever wrote the API adapter reimplemented
search server-side — correctly, for payload reasons — and dropped a field on
the way across.

The fix for search is one query parameter:
`or=(title.ilike.*q*,title_mm.ilike.*q*)`. The fix for display is a helper on
`VideoContent` that prefers `titleMm` when the locale is `my`, used at the five
render sites. Neither needs a schema change; the data is already arriving.

| | |
|---|---|
| likelihood | **မကြာခဏ** — for the app's primary audience |
| severity | **moderate-high** — a whole feature paid for and not delivered |
| fix | **easy** — one `or=` filter, one accessor, five call sites |

### M6 — the age-consent record is uploaded to Google Drive

`lib/features/video_hub/data/age_consent_store.dart:19`

```dart
static const String _kVersion  = 'vh_age_consent_version';
static const String _kAtMillis = 'vh_age_consent_at';
static const String _kDeclined = 'vh_age_declined';
```

Plain `SharedPreferences`. `backup_rules.xml` and `data_extraction_rules.xml`
exclude exactly four things — `private_vault/`, `intruder_shots/`, and the two
spellings of the `FlutterSecureStorage` file — and both files say so in the
same words: *"Everything NOT listed here still backs up normally."*

So these three keys go to the user's Google Drive on every Auto Backup, and to
the new handset on device transfer.

**This is the third instance of one bug class in this feature, and the first
two were found and fixed with the reason written down.**

* `session_store.dart:8` (v1.55.16): *"Android's Auto Backup uploads an app's
  SharedPreferences to the user's Google Drive by default, while the
  device-transfer flow copies it to a new handset — so the long-lived half of
  the session was leaving the phone by two channels nobody had looked at."*
* `device_identity.dart:26` (v1.63.5): *"the one value whose entire job is to
  say 'this is a different phone' was being carried onto the different phone
  automatically."*

Both moved to `FlutterSecureStorage` — the file the backup rules already
exclude — precisely so no manifest change was needed. The sweep stopped at two.

What leaks is small and specific: `vh_age_consent_version = 1` in a Drive
backup is a durable record that this Google account's owner opened the adult
section of this app and accepted its terms. For an app that ships a decoy PIN,
an intruder selfie and a vault whose entire design assumes the phone may be
looked at by someone else, a cloud record of that is out of keeping with
everything around it. The vault's own PIN store is excluded from backup for
exactly this reason.

The second half is weaker and I will not overstate it: on device transfer the
new handset inherits "already accepted", so the 18+ door does not appear. Same
person, usually, so this is closer to untidy than harmful.

Moving three keys to `FlutterSecureStorage` costs about fifteen lines and needs
the same read-once migration `SessionStore._read` already demonstrates.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every backup, automatically |
| severity | **moderate** — a privacy trace, in the app least entitled to leave one |
| fix | **easy** — the migration pattern is already written twice in this folder |

### M7 — three async failures with nowhere to land

Three places call a throwing async function and discard the future. Each leaves
a screen the user cannot get out of.

**a. `AccountNotifier.refresh()` — the spinner that never stops**
`account_provider.dart:240`, `:252`

```dart
AccountNotifier(this._repo) : super(const AccountState()) {
  refresh();
}
```

`refresh()` awaits `_repo.currentUser()`, which **deliberately rethrows** on a
non-401 `ApiException` (`api_account_repository.dart:40`: *"A NETWORK failure is
not a sign-out"*) — the right decision, with nobody catching it. The
constructor discards the future, so the throw becomes an unhandled async error
and `state` stays at its initial value: `isLoading: true`, `installId: ''`.

Nothing ever sets it false. Open the Video Hub on a bad connection and the
account button stays in its loading state for the life of the process; pulling
to refresh does not touch it. `video_hub_screen.dart:84` re-arms the same trap
on every app resume, also unawaited.

**b. `AgeGateScreen._resolve()` — a black rectangle**
`age_gate_screen.dart:49`, `:52`

```dart
void initState() { super.initState(); _resolve(); }

Future<void> _resolve() async {
  final declined = await _store.hasDeclined();
  final accepted = await _store.isAccepted();
  ...
}
```

`SharedPreferences.getInstance()` can throw. If it does, `_state` stays
`_GateState.checking`, and `checking` renders — by an otherwise good decision —
a bare `ColoredBox(color: VH.canvas)`:

> *"Blank canvas, not a spinner: this resolves in milliseconds from local
> storage, and a spinner that flashes for one frame reads as a stutter."*

Correct for the case it was written for. In the failure case the user gets a
**full-screen black rectangle with no text, no control and no back gesture** —
`AgeGateScreen` is the whole route body. The app looks dead.

**c. `AgeGateScreen._accept()` — the door that will not open**
`age_gate_screen.dart:63`

```dart
Future<void> _accept() async {
  setState(() => _busy = true);
  await _store.accept();
  ...
}
```

No try/finally. A throw leaves `_busy` true, and `_Actions` disables **both**
buttons on `_busy` — so a user who taps "I am 18 or older" once gets a
permanent spinner and cannot accept, decline, or leave.

All three want the same three lines. (b) additionally wants `checking` to fail
toward `asking` rather than toward a blank screen: re-asking is annoying,
a dead app is worse.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — a throwing storage call or a request that is not a 401 |
| severity | **moderate-high** — (b) and (c) are unrecoverable without a force-stop |
| fix | **easy** — try/catch, and a failure state for each |

### M8 — the playback timeout is 20 seconds, not the 30 it documents

`backend_config.dart:80`

```dart
/// Playback authorization is worth waiting a little longer for: the server
/// has to check the subscription AND mint a signed URL.
static const Duration playbackTimeout = Duration(seconds: 30);
```

```
$ grep -rn "playbackTimeout" lib/
lib/features/video_hub/data/api/backend_config.dart:84: static const Duration playbackTimeout = ...
```

**Declared once, read nowhere.** And `requestPlayback` does not merely forget
it — it passes the opposite (`api_content_repository.dart:363`):

```dart
timeout: null,
```

`_send` resolves `timeout ?? BackendConfig.timeout`, so `null` selects the
**general 20-second** budget for the one request the file above says needs
longer. A `null` here reads at the call site as "no timeout" and does the
reverse, which is why this survived.

The consequence is the worst-shaped one available: an entitlement check that
takes 21 seconds — a cold Edge Function, plus a subscription lookup, plus URL
signing, on a Myanmar mobile link — becomes `ApiErrorKind.network`, which
`requestPlayback` maps to `AccessDenial.unavailable`, which
`playback.dart:135` shows as `s.vhUnavailable`. **A paying subscriber is told
the film is unavailable because the server took one second too long.** The
fail-safe direction is right; the threshold is the one the file argued against.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — a cold function on a slow link |
| severity | **moderate** — a paid film refused, with a message that misdescribes why |
| fix | **trivial** — `timeout: BackendConfig.playbackTimeout` |

### M9 — the session never refreshes until something has already failed

`session_store.dart:110`

```dart
/// True when the access token is past its expiry, with a safety margin.
///
/// The margin matters: a token that is valid when the request is built can
/// expire while it is in flight on a slow network, and the user sees a
/// spurious sign-out.
Future<bool> isExpired() async { ... }
```

```
$ grep -rn "isExpired" lib/ | grep -i session
$
```

**Never called.** `ApiClient._headers` attaches whatever `accessToken()`
returns without asking whether it is still good (`api_client.dart:54`), and the
expiry is written on every save (`session_store.dart:126`) and read by nothing.

So the only route to a refresh is the 401 handler at `api_client.dart:139`.
Every first authenticated request after a token lapses costs a full failed
round trip before the real one starts. On a cold start after an hour away — the
common case — that is the catalogue arriving in roughly double the time, on the
network where round trips are the expensive resource.

`SessionStore.describe()` is likewise dead. Trivial, but it is the second
unread member of the same small class.

Two honest notes against fixing it aggressively. The 401 path is the one that
*must* exist and is correct as written, including its once-only retry and its
serialised `_refreshInFlight`, which I checked closely and found right (see §2).
And a proactive refresh adds a request for users who never make a second one.
The cheap version is to consult `isExpired()` inside `_headers` and refresh
first when it says so — the machinery is already there.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every cold start after the token lapses |
| severity | **low-moderate** — a wasted round trip, felt as slowness |
| fix | **easy** — one call in `_headers`, or delete the dead member and say so |

### M10 — pull-to-refresh and load-more can interleave

`paged_catalogue.dart:293`, `:317`

`loadMore()` guards on `_busy`. `refresh()` does not:

```dart
Future<void> refresh() async {
  if (!mounted) return;
  _nextPage = 0;
  state = const PagedCatalogueState();
  await _loadFirstPage();
}
```

Pull to refresh while a next page is in flight and both run. The order that
follows is:

1. `loadMore`'s fetch returns, sees `mounted`, sets `_nextPage = 1`, and
   **appends page 1's items to the freshly emptied list** — so page 2's
   content is briefly displayed as though it were page 1;
2. its `finally` sets `_busy = false` **while `_loadFirstPage` is still
   running**, so a scroll in that window starts a third concurrent fetch;
3. `_loadFirstPage` returns and overwrites everything.

Visible as a flash of the wrong rows and, if the user is scrolling, a
duplicated block. Nothing crashes and nothing is lost — the last write is
correct — which is why this is a middle-order finding rather than a high one.

There is no generation token, so no fetch can tell that it has been superseded.
Every other notifier in this file guards `mounted`, which is the *disposal*
question; this is the *staleness* question, and they are different. One `int
_generation` incremented in `refresh()` and compared after each await settles
all three symptoms.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — pull-to-refresh near the bottom of a grid |
| severity | **moderate** — wrong content on screen, briefly |
| fix | **easy** — a generation counter |

### M11 — the poster pruner stats the directory from inside a sort comparator

`poster_cache.dart:184`

```dart
files.sort((a, b) =>
    a.statSync().modified.compareTo(b.statSync().modified));
```

Two **synchronous** filesystem calls per comparison, on the UI isolate, inside
an `n log n` sort. At the cap (48 MB of ~40 KB posters ≈ 1,200 files) that is
on the order of 20,000 blocking `stat` calls in one uninterrupted block.

`_pruneOnce` is fired `unawaited` from `_resolve` right after a poster is
written — i.e. **during a scroll**, which is the only time posters are written.
The rest of the method is properly async (`await entity.length()`,
`await file.delete()`); the sort is the one place it drops to sync, and it is
the expensive one.

Mitigating, and the reason this is not higher: it runs at most once per session
(`_pruned`), and only when the directory is already over 48 MB, which takes
sustained use to reach. When it does fire the freeze is a second or more, at
the worst possible moment, and it will be reported as "the app hangs when I
scroll" with no way to reproduce it on demand.

`stat` each file once into a list of `(file, modified)` pairs before sorting,
and the comparator becomes free.

| | |
|---|---|
| likelihood | **ရှားပါး** — needs a full cache first |
| severity | **moderate** — a visible freeze mid-scroll |
| fix | **easy** — decorate-sort-undecorate |

### M12 — every poster opens its own connection

`poster_cache.dart:116`

```dart
final response =
    await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
```

`package:http`'s top-level `get` creates a `Client`, issues one request, and
closes it. **No connection is ever reused.** A grid of thirty posters is thirty
TCP handshakes and thirty TLS negotiations — on a link where the handshake
often costs more than the payload, and the payload is 40 KB.

The class is otherwise carefully built for exactly this network: it exists
because *"this app is used on Myanmar mobile data — so the cost of scrolling
the same grid twice in a day was being paid twice, by the user, in money"*. It
deduplicates concurrent requests per URL (`_inFlight`), it writes through a
`.part` file, it hashes names. The one thing it does not do is keep the socket.

Related and smaller: there is no cap on *concurrent* resolves. `_inFlight`
prevents two requests for the same poster, not thirty requests for thirty
posters. A fast flick starts them all at once and they compete for the same
narrow link, so every poster arrives late rather than the visible ones arriving
first.

One shared `http.Client` held as a static, closed nowhere (this is a
process-lifetime cache), plus a small semaphore — four or five requests in
flight — addresses both.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every cold catalogue scroll |
| severity | **moderate** — the exact cost this class was written to remove |
| fix | **easy** — one shared client; a counting gate for concurrency |

### M13 — a renewal closure outlives the player

`playback.dart:79`, `stream_renewal.dart:62`, `player_controller_playback.dart:24`

`StreamRenewal.register` stores a static closure that captures the calling
widget's `WidgetRef` and the `VideoContent`. It is replaced by the next
`register`, and cleared by `openVideo` **only when the next video is not
ephemeral**:

```dart
if (!ephemeral) {
  StreamRenewal.clear();
}
```

Every Video Hub playback is `ephemeral: true` (`playback.dart:101`). So after
watching a premium film and backing out, the registration — and through the
`WidgetRef`, the element it belongs to — is held until the user opens a local
file. If they never do, it is held for the life of the process.

The `_window` of six hours governs `canRenew` only; nothing nulls the fields
when it lapses, so the class's own stated bound (*"Bounded all the same so a
closure cannot be held for the life of the process after the user has moved
on"*) does not hold for the case it was written for.

Small in bytes and it cannot produce a wrong result — `renew` catches
everything and returns null, and a stale registration is keyed to a URL that is
no longer being played. Worth fixing because the class already intends to.

| | |
|---|---|
| likelihood | **မကြာခဏ** — after any Hub playback |
| severity | **low** — a retained reference, no user-visible symptom |
| fix | **easy** — clear on player dispose, and null the fields when `_window` lapses |

### M14 — two sign-in errors that mislead

`sign_in_sheet.dart:83`

```dart
} catch (e) {
  if (!mounted) return;
  setState(() => _error = e.toString());
}
```

The user sees `ApiException(network)` — untranslated developer text, as the
whole message, in a sheet whose other two handlers use `s.vhSignInGoogleSoon`
and `s.vhSignInBadCode`. One of three, so an oversight rather than a policy.

(`HubErrorState` also renders `error.toString()`, and that one is **deliberate
and fine** — a localised line sits above it and the doc explains the choice.
See §2. The difference is that here the raw string is all there is.)

`sign_in_sheet.dart:125` is the more expensive of the two:

```dart
} catch (_) {
  setState(() => _error = AppStrings.of(context).vhSignInBadCode);
}
```

**Every** failure of `verifyPhone` becomes "That code is not correct" — a
timeout, a dropped connection, a 500. The user, holding a correct SMS code,
retypes it. Supabase OTPs expire in minutes; by the third attempt the code
genuinely is dead and the account is unreachable. `ApiException.isRetryable`
exists (`api_exception.dart:51`) and is unused here; branching on it gives
"check your connection" for the retryable kinds.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** |
| severity | **moderate** — the second one can strand a paying user |
| fix | **easy** — a localised network message; branch on `isRetryable` |

### M15 — 48 MB of adult poster art with no way to clear it from the app

`poster_cache.dart:219`

```dart
/// Empties the cache. For a "clear cached images" action, and for tests.
static Future<void> clear() async { ... }
```

There is no such action, and there are no tests. The method is unreferenced.

The cache holds up to 48 MB of artwork from an adult catalogue, in
`getApplicationCacheDirectory()`. Honest mitigations, both real: the filenames
are SHA-1 hashes so a directory listing reveals nothing, and Android's own
Settings → Storage → Clear cache empties it — the class doc says choosing the
cache directory was partly *for* that.

Still: this app puts a "clear" control on nearly everything else it stores,
and a user who wants that artwork gone should not have to know where Android
keeps app caches. One tile on the account screen wired to an existing method.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** |
| severity | **low-moderate** — a privacy affordance the app offers everywhere else |
| fix | **easy** — the method exists |

### M16 — two access-policy members nothing reads

`access_policy.dart:40` and `:65`.

`showLockedItems` is documented as *"Set false only if a jurisdiction or a
partner requires locked content to be invisible."* Nothing reads it. Setting it
false would change nothing, and the person who set it would not find out.

`canDownload` is unreferenced anywhere in the feature (the `canDownload`
matches elsewhere in `lib/` belong to `AppRelease`, which is unrelated).
Downloads are stubbed — `account_screen.dart:87` routes the tile to `_notYet` —
so this is a policy waiting for its caller rather than rot. Worth a comment
saying so, since the risk is that whoever implements downloads writes their own
check instead, which is precisely what the file's opening paragraph forbids.

**This is the same bug class `tool/dead_settings.py` was written for in #30**,
in a third place that checker does not look: it covers
`extra_settings_service.dart` and `player_settings_service.dart` only.
`AccessPolicy` is a settings surface too.

| | |
|---|---|
| likelihood | — (structural) |
| severity | **low** — a switch that does nothing, and a rule with no caller |
| fix | **easy** — wire `showLockedItems` or delete it; comment `canDownload` |

### M17 — pull-to-refresh on the All tab finishes before the data does

`video_hub_screen.dart:163`

```dart
Future<void> _refresh(ContentCategory selected) async {
  if (selected.showsRows) {
    ref.invalidate(featuredContentProvider);
    ref.invalidate(contentRowsProvider);
    return;
  }
  await ref.read(pagedCatalogueProvider(_categoryKey()).notifier).refresh();
}
```

`invalidate` is synchronous; the returned future completes immediately.
`RefreshIndicator` therefore retracts before the request has been sent, and the
rows swap to skeletons a moment later. The gesture reads as having failed, so
people do it again.

The category branch, four lines down, awaits properly.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every pull on the landing tab |
| severity | **low** — a gesture that looks ignored |
| fix | **easy** — await the two futures after invalidating |

### M18 — the filter count throws into a Timer

`filter_sheet.dart:87`

```dart
_debounce = Timer(const Duration(milliseconds: 120), () async {
  final candidate = _draft;
  final n = await widget.countFor(candidate);
  ...
});
```

`countFor` reaches the network. A throw inside a `Timer` callback has nowhere
to go; `_count` stays null and the Apply button falls back to
`(_count ?? 1) > 0`, so it stays enabled — which is the right default — but the
count line simply never appears and never explains itself.

Low, and noted mainly because the staleness guard immediately below it
(`candidate.signature != _draft.signature`) shows the author was thinking about
exactly this method's async behaviour.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** |
| severity | **low** |
| fix | **easy** — try/catch, and leave the count blank deliberately |

### M19 — `data/` has no tests

`test/video_hub_logic_test.dart` has 30 tests. All thirty import from
`domain/`: `access`, `access_policy`, `capability`, `content_category`,
`content_filters`, `video_content`, `viewer`, plus one widget helper.

**Nothing imports `data/`.** No test touches `ApiClient` (the 401-refresh
serialisation, the status→kind mapping), `SessionStore` (the migration and
delete-legacy paths), `ApiContentRepository` (`_titleFrom`'s fail-locked tier
default, `_parseServerTime`'s zoneless-as-UTC rule, `_page`), `PosterCache`, or
`PagedCatalogueNotifier`.

The tested half is the half that decides nothing over the network. The
untested half contains four findings above, and at least five of the pure
functions in it are testable with no device, no mock and no plugin — the same
argument that produced #29 for the downloader and transfer.

The single highest-value test in the feature is one line of intent:
`_titleFrom` must return `AccessTier.premium` for an unknown or absent
`access_tier`. That is the fail-locked default the whole catalogue rests on,
and nothing would notice if a refactor flipped it.

| | |
|---|---|
| severity | **moderate** — structural |
| fix | **moderate** — a day, mostly writing fixtures |

---

## 2. Withdrawn after checking

Seventeen things that look like findings and are not. Listing them is the
point: several are the *most* suspicious-looking code in the feature and each
has its argument written beside it.

1. **The dev "approve my payment" button.** `account_screen.dart:463`. Guarded
   by `kDebugMode`, with a paragraph explaining that the tree-shaker removes the
   branch entirely and that "harmless as long as a config value is set is not a
   control". This is the incident that shipped once. It is properly closed.
   (M3 is the same hazard in a different file, and is *not* closed.)
2. **`HubErrorState(detail: error.toString())`.** Deliberate: a localised
   `s.vhLoadFailed` sits above it, and the doc says *"Users rarely read it; the
   person they forward a screenshot to always does."* Correct, and a good idea.
3. **`PlaybackGrant.isGranted` ignores `isExpired`.** Twelve lines of argument
   at `access.dart:120`: the device clock is not evidence, the CDN checks the
   signature, and a renewal path must exist anyway. Right, and I would not have
   thought of the flat-battery case.
4. **`ApiClient._refreshInFlight`.** I read this closely expecting a race and
   there is not one: `_refreshInFlight` is assigned *before* `_doRefresh()` is
   invoked, so a second caller in the same microtask sees it; the waiter
   re-reads the token rather than trusting a bool; `allowRefresh: false` on the
   retry makes a loop impossible.
5. **`_doRefresh` clears the session on a non-2xx but not on a network error.**
   Exactly the right asymmetry, and stated: *"A NETWORK failure must not sign
   the user out — they are offline, not logged out."*
6. **Unknown `access_tier` reads as premium** (`api_content_repository.dart:462`)
   and **unknown request status reads as pending**
   (`api_account_repository.dart:294`). Both fail toward locked, both
   documented, both matching spec §2.
7. **`recordView`, `recordAgeConsent` and `claimAnonymousHistory` swallow
   everything.** Three separate `catch` blocks with three separate reasons, all
   sound — the best being *"a sign-in that worked must not be reported as
   failed because a history merge did not. The merge can be retried later; the
   sign-in cannot be un-lost."*
8. **`_parseServerTime` reinterprets a zoneless timestamp as UTC.** Correct,
   and the reasoning — that `DateTime.parse` would otherwise be wrong by
   Myanmar's 6½-hour offset — is the kind of thing that is usually found in
   production.
9. **`_titleColumns` is an explicit list and never `*`.** Matches spec §3's
   "the column that must never be selectable". The locator is not in it.
10. **`MediaRef(provider: 'server', locator: id)`.** The client is handed an id,
    never a media address, on every path including album clips.
11. **The poster cache lives in `getApplicationCacheDirectory()`.** I checked
    this against M6: Android excludes the cache directory from Auto Backup by
    default, so hashed adult artwork does not reach Drive. Choosing the cache
    directory over the support directory is also documented, and right.
12. **`DeviceIdentity._persist` falls back to plaintext when the keystore write
    fails.** Deliberate, argued, and the correct trade: *"An id that is backed
    up is a smaller problem than an id that changes on every launch."*
13. **`_album` caps at 60 items.** Because the mosaic is a `Column` in a
    `SliverToBoxAdapter` with no virtualisation. Documented, with the right fix
    named for if the cap is ever hit.
14. **`getCatalogue` builds one `category` key.** The comment records a real
    past bug — two map entries, last one wins, "Movies" silently became "not
    adult". Correctly fixed.
15. **`_countedViews` is a top-level `Set` that is never cleared.** Bounded by
    the number of titles opened in one app run. Not worth a change.
16. **`paymentInstructions` is fetched with `authenticated: false`.** Plausibly
    deliberate — a signed-out user should be able to see the price before
    committing to an account. Flagged in §3 only because it depends on a server
    policy I cannot see, not because it looks wrong.
17. **`AccountState.copyWith` has a `clearUser` flag instead of nullable
    semantics.** The usual Dart `copyWith` wart, handled the usual way, and
    `signOut` constructs the state explicitly rather than relying on it.

---

## 3. What I could not settle from the client

Six questions whose answers live in the Supabase project. Each is written as a
check to run, not as a claim.

1. **`db-max-rows`.** M4's `totalCount` is correct only below the cap. Run
   `select count(*) from titles;` and compare with what the app reports as the
   total on the All tab. If they differ, the truncation is already happening.
2. **`row_catalogue` volatility.** `getRowCatalogue` calls it over **GET**
   (`api_content_repository.dart:135`). PostgREST allows GET on an RPC only for
   `STABLE` or `IMMUTABLE` functions; a `VOLATILE` one (the default) answers
   405. If See-all on a landing row is currently empty or erroring, this is
   why. `catalogue_facets` and `landing_rows` go over POST and are unaffected.
3. **`titles` RLS and anonymous browsing.** Spec §3 gives
   `using (auth.role() = 'authenticated')`. The app browses the catalogue
   before sign-in, sending only the publishable key — which is `anon`. Either
   the live policy is broader than the spec, or the catalogue is empty until
   sign-in. Open the Hub signed out and look.
4. **PostgREST reserved characters in search.** `'title': 'ilike.*$q*'`
   interpolates raw user input. `%` and `_` pass through as SQL LIKE wildcards,
   which is cosmetic. Whether a `,` `.` `(` `)` in the query alters the filter
   rather than being matched literally, I do not know without testing —
   PostgREST requires those to be double-quoted in some positions. **Search for
   `a,b` and for `a(b` and see whether the results are sane.** If not, the fix
   is quoting the value, not escaping it.
5. **`payment_instructions` readable by `anon`.** Fetched with
   `authenticated: false`. If the table's policy requires `authenticated`, the
   call fails, the `catch` swallows it, and **M2 fires on every single load** —
   which would promote M2 from "on a bad connection" to "always".
6. **`record_age_consent` callable without a JWT.** Called with
   `authenticated: true`, but that only attaches a bearer *if one exists*, and
   the comment says anonymous viewers are exactly the ones worth recording. If
   the RPC is `security definer` with execute revoked from `anon`, no anonymous
   consent is ever stored — silently, because the caller swallows the error.

---

## 4. The six categories, in this domain

**Crash risk** — low, and genuinely so. There is almost no unguarded cast in
the feature; parsing is defensive throughout (`whereType`, `is! Map` guards,
`int.tryParse`), and `_titles` returns an empty list rather than throwing on a
shape it does not recognise. The failures here are not crashes.

**Silent failure** — the dominant category, and where the money is. M1 loses a
payment claim without a word. M2 substitutes an invented payee. M18 loses a
count. Seven `catch` blocks swallow deliberately and correctly (§2.7), which
makes the two that swallow *accidentally* harder to see, not easier.

**Race conditions** — one (M10), and it is cosmetic. Everything else that
could race is already serialised on purpose: `_refreshInFlight`,
`DeviceIdentity._inFlight`, `PosterCache._inFlight`, `_busy` in the paging
notifier, and the filter sheet's signature check. Someone went looking for
these.

**Unclosed resources** — M13 (a static closure), M12 (a client per request,
which is the inverse — closed too eagerly). `ApiClient` is disposed by its
provider; `PageController` and both `TextEditingController` pairs are disposed;
`WidgetsBindingObserver` and the scroll listener are removed in `dispose`. Clean
otherwise.

**Invisible waits** — M7 is three of them, and two are unrecoverable. M4 is the
long one: every page and every filter preview waits on a full catalogue
download, and the UI has no way to say so. M8 turns a wait into a wrong answer.

**UX** — M5 is the important one and it is about the audience: an app for
Burmese users, storing Burmese titles, showing and searching only the English
ones. M3 blocks sign-in. M14 tells a user their correct code is wrong. M17
makes a gesture look ignored.

---

## 5. Fix order

By harm × likelihood ÷ cost. The first four are under thirty lines together.

**Now**

1. **M3** — guard the dev-code hint. One `if`. Stops every new user being told
   to type a code that cannot work.
2. **M1** — a `catch` on the payment submit. Money, and the failure is silent.
3. **M8** — `timeout: BackendConfig.playbackTimeout`. One word.
4. **M2** — persist the last good payment instructions; never present the
   placeholder as real.

**Next**

5. **M7** — three try/catches, and a failure state for the age gate.
6. **M6** — move the three consent keys to `FlutterSecureStorage`, with the
   read-once migration `SessionStore` already demonstrates.
7. **M5** — `or=(title.ilike…,title_mm.ilike…)`, plus a `displayTitle`
   accessor at five render sites.
8. **M14** — localise the send-code error; branch on `isRetryable` in verify.

**Then** — these want measurement or a server change, so they are their own
piece of work.

9. **M4** — real paging. Answer §3.1 and §3.2 first; the table path and the two
   RPC paths need different fixes.
10. **M12**, **M11** — one shared client and a concurrency gate; decorate the
    pruner's sort.
11. **M10** — a generation counter in the paging notifier.
12. **M19** — tests for `data/`, starting with the fail-locked `access_tier`
    default.

**Whenever**

13. M9, M13, M15, M17, M18, M16.

---

## 6. Do not touch

Repeating §2's list would be noise, but four things are load-bearing enough
that a future change should have to argue with them explicitly:

* **`requestPlayback` has no fallback, no cache and no retry with different
  arguments.** That absence *is* the enforcement. Adding a "try the last known
  URL if the server is unreachable" would end the model in one commit.
* **`_titleColumns`.** Never `*`, never widened without checking spec §3
  first. The locator column is the whole game.
* **`playback.dart` is the only file that interprets a `PlaybackGrant`**, and
  `StreamRenewal` exists specifically to keep it that way — the player is
  handed a closure so a grant never travels through five more layers. M13 is a
  bug *inside* that design, not an argument against it.
* **`PlaybackGrant.isGranted` does not consult the device clock.** See §2.3.
  This will look like a missing check to every future reader; it is not.

---

## Sources

* `docs/premium_backend_spec.md` §§2–5 — schema, RLS, the playback function,
  and the manual KPay approval flow. Every claim above about what the server is
  supposed to do is from there.
* `docs/movies_access_plan.md`, `docs/movies_data_model_v2.md` — for the
  `title_mm` and `title_media` shapes.
* `android/app/src/main/res/xml/backup_rules.xml` and
  `data_extraction_rules.xml` — read in full for M6.
* `lib/features/video_hub/data/api/session_store.dart:8` and
  `data/device_identity.dart:26` — the two prior Auto Backup fixes, which are
  what makes M6 a third instance rather than a new idea.
* `docs/audit_transfer.md`, `docs/audit_downloader.md` — for the method, and
  for the withdrawn-after-checking section, which earns its place again here.

## Changelog

* 13 Sep 2026 — first version. 19 findings, 17 withdrawn, 6 questions for the
  server.
