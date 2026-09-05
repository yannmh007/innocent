# Phase 1 — the simple version that actually ships

Written 30 Aug 2026. **This is the authoritative plan until the first hundred
titles are live and the app is released.** Everything in the other documents that
this contradicts is deferred, not cancelled.

The other plans describe a good system. This one describes the shortest path to
a working one, for an operator who has a phone, no terminal, and no appetite for
tools he cannot check.

---

## The principle

> **Do nothing by machine that has not first been done by hand.**
> **Add no tool that is not yet the bottleneck.**

Every deferral below follows from those two lines.

---

## What phase 1 deliberately does NOT have

| Deferred | Why it is safe to defer | When it comes back |
|---|---|---|
| **HLS + AES encryption** | one file per title instead of ninety; no `ffmpeg`, so no terminal | when there is a real machine, or offline downloads are built |
| **Cloudflare Worker** | R2 presigned URLs are generated wherever the decision is made; nothing needs the edge | if Supabase egress passes 3 GB/month |
| **GitHub Actions for media** | not what Actions is for, and the pipeline is manual anyway | never for media; Actions stays for build/migrate/gate |
| **Domain** | only the public bucket needs one, and only at release | at release, ~$10.44 |
| **Termux / CLI tools** | the dashboard covers files under 300 MB | only if files are larger |
| **In-app admin screen** | not needed until the 300 MB limit bites | see §4 |
| **Seven workflows, staging, monitoring** | none of them is the bottleneck at 100 titles | after launch |

---

## 1. Content: MP4, not HLS

One file per title, in the **private** bucket, served by a presigned URL with a
short expiry.

**What is lost:** during the URL's lifetime a determined user can pull the file
down. But a paying user could obtain the AES key just as easily, so the real gap
is narrower than it looks — encryption mainly raises the bar against casual
scraping and is what makes encrypted-at-rest offline downloads possible later.

**Why it is reversible:** `titles.locator` stores a **path**, never a URL, and
`titles.provider` already exists. New titles can be HLS while old ones stay MP4;
nothing in the app or the schema has to change to mix them.

**One caveat worth knowing:** an MP4 whose index sits at the end of the file
seeks badly over HTTP. Most files are fine. If one behaves strangely — slow to
start, seeking stalls — that single file needs remuxing, not the design.

---

## 2. Upload: the dashboard, until it stops working

**The Cloudflare dashboard accepts single files up to 300 MB.** Above that it
refuses and asks for the API or a tool.

| | Typical size | Dashboard |
|---|---|---|
| Poster / photo | ~200 KB | yes |
| 720p, 20 min | ~250 MB | yes |
| 720p, 40 min | ~500 MB | no |
| 1080p | 1 GB+ | no |

**So the first action is a measurement, not a decision:** upload one real title
and see which side of 300 MB the catalogue sits on. If most files fit, the first
hundred titles need no tooling at all.

The 40 GB total is the real constraint, not the tooling. At 100 titles averaging
400 MB that is roughly 9 hours of uploading on a 10 Mbps connection — two to
three weeks at five to ten titles a day. **Wi-Fi only. 40 GB of mobile data
would cost more than a year of the entire platform.**

---

## 3. Metadata: the Supabase Table Editor

Insert the row through the dashboard's form: title, tier, `locator` (the object
path), `poster_key`, and whatever else the schema requires. Everything optional
should be nullable so a title can go live with four fields filled in.

For the first ten titles this is also the best way to learn what a title record
actually is. When it becomes tedious, that is the signal for §4 — not before.

---

## 4. The admin build, if and when it is needed

Only needed if files exceed 300 MB, or when hand-entry becomes the bottleneck.

**The security question, answered.** The risk was never the screen; it is what
the screen needs — R2 credentials or a privileged write path. Anything inside a
shipped APK is public, because APKs decompile. A hidden gesture is not security.

**The fix is to not ship the code at all:**

```
operator build   flutter build apk --dart-define=ADMIN=true
user build       flutter build apk
```

Dart's compiler removes unreachable code, so the user's APK contains no admin
screen, no endpoint, no credential — not hidden, absent.

**And note the comparison:** pasting R2 write keys into a third-party Android S3
client hands them to software you cannot inspect. Putting them in an operator
build that never leaves your own phone is the smaller trust decision, and an R2
token can be revoked from the dashboard in seconds either way.

---

## 5. Identity: two things, done before the first public build

**Application id — one line.** `namespace` and `applicationId` may differ, so:

```kotlin
namespace     = "com.innocent.media"
applicationId = "com.innocent.media"
```

**Superseded 30 Aug 2026.** The one-line version above was the cheap option.
The operator chose the full rename instead, while there were still no users:
`namespace`, all 22 Kotlin files and `IUserService.aidl` now read
`com.innocent.media`, and their directories moved to match. Done and verified
in v1.60.0+302. It does not need to match any domain.

**Release keystore — one hour, then never again.** Release builds currently use
the debug key, which means the app cannot be reliably updated, and the in-app
updater is the only distribution channel there is.

Check FlutLab's project settings for a signing or keystore section first. If
there is none, one Google Colab cell does it:

```python
!apt-get install -y default-jdk -qq
!keytool -genkeypair -v -keystore innocent.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 -alias innocent \
  -storepass YOUR_PASSWORD -keypass YOUR_PASSWORD \
  -dname "CN=Innocent, O=Innocent, C=MM"

from google.colab import files
files.download('innocent.jks')
```

Then delete the Colab runtime, upload the `.jks` into `android/app/`, add
`android/key.properties`, and point the release build type at it.

**Back the keystore and its password up in three places.** Losing them ends the
app's ability to update, permanently, for every user.

---

## 6. The order

```
1  applicationId — one line in build.gradle.kts             10 min
2  keystore: generate, wire up, back up ×3, record SHA-256   1 hr
3  Supabase project (region Singapore) + titles table        2 hr
4  R2: private bucket + public bucket                       15 min
5  ONE title: upload by hand, add the row, play it in-app    1 day
6  five more titles — check posters, listing, premium lock
7  the remaining ninety-odd, five to ten a day
```

**Do not upload title two until title one plays in the app.** That single rule
is what prevents doing a hundred of anything twice.

Steps 1–2 and 3–5 are independent. Content can be uploaded while the app is
still being changed.

---

## 7. What phase 1 costs

| | |
|---|---|
| Cloudflare R2, 40 GB | ~$0.45/month |
| Supabase | $0 |
| Everything else | $0 |
| Domain | **not yet** |

---

## 8. What ends phase 1

Any one of these is the signal to open the fuller plans again:

* the first hundred titles are live and the app is ready to release → buy the
  domain, connect the public bucket, ship the first signed public build
* files routinely exceed 300 MB → build the admin build (§4)
* hand-entry becomes the bottleneck → same
* real users and real money exist → Supabase Pro, then the archive's cold copy
* Supabase egress passes 3 GB/month → the Cloudflare Worker
