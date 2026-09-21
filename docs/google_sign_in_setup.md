# Google sign-in — the setup that lives outside this repository

The code is done. What is left is four registrations in two consoles, and
one string handed to the build. Nothing here can be committed, which is why
it is written down: the next person to need it will be someone who has just
changed the signing key and cannot work out why the button went dead.

Read `lib/features/video_hub/data/api/backend_config.dart` alongside this.

---

## Why Google at all

It is the only sign-in this app can offer for free.

| Method | Cost | Works today |
|---|---|---|
| Google | nothing, per sign-in, forever | yes, once this page is done |
| Phone OTP | every SMS is billed by a provider | no — `phone_provider_disabled` |
| Email OTP | needs custom SMTP; free tiers exist | not implemented |

Supabase's built-in email sender only delivers to addresses that belong to
the project's own organisation team, so it cannot serve real users at all.
That is documented, not a limit we hit by accident.

---

## The one idea to hold on to

**Three client IDs, three jobs, and only one of them is ever typed into code.**

| Client | Created for | Where it goes |
|---|---|---|
| **Android** | package name + SHA-1 | Google Cloud only. Never named in code. |
| **Web** | nothing — it exists to be an audience | `serverClientId` in the app, **and** Supabase |
| *(iOS)* | not applicable; this app is Android | — |

The Android client is what lets Google sign anything for this app. The web
client is what the ID token is addressed to (`aud`), and that claim is what
Supabase checks. Handing the app its Android client ID instead of the web one
is the single most common way this is got wrong.

---

## 1. Google Cloud — create the clients

<https://console.cloud.google.com/auth/clients>

1. Create a project if there is not one already.
2. Configure the consent screen (**Audience**, **Branding**). A published app
   needs a privacy policy and terms URL here.
3. **Create OAuth client → Android**
   - Package name: `com.innocent.media`
   - SHA-1: see below
4. **Create OAuth client → Web**
   - No redirect URI is needed for the native flow.
   - Copy its **Client ID** and **Client secret**. Both are used in step 2.

### Getting the SHA-1

From the keystore, if you have it:

```
keytool -list -v -keystore innocent.jks -alias innocent -storepass <password> | grep SHA1
```

Or from a built APK, which needs no password at all:

```
keytool -printcert -jarfile innocent-1.64.13-326.apk | grep SHA1
```

Both print the fingerprint of the certificate the app is actually signed
with, which is the only one that matters. Debug builds are signed with a
different key and therefore have a different SHA-1 — register both if you
ever want sign-in to work from a debug build.

**Changing the signing key changes this fingerprint.** A new keystore means a
new Android client, or an added SHA-1 on the existing one, or Google stops
signing in and says nothing useful about why.

---

## 2. Supabase — enable the provider

<https://supabase.com/dashboard/project/_/auth/providers> → **Google**

- **Enabled**: on
- **Client ID**: the **web** client ID
- **Client Secret**: the web client secret
- **Authorized Client IDs**: the web client ID *and* the Android client ID,
  comma-separated, **web first**. Supabase's own documentation is explicit
  about the ordering.

---

## 3. The build — hand the app the web client ID

`BackendConfig.googleServerClientId` is empty by default, and an empty value
is a supported state: `googleEnabled` is false and the sign-in sheet hides
the Google button entirely rather than offering a way in that cannot work.

Either pass it at build time:

```
flutter build apk --release \
  --dart-define=VH_GOOGLE_SERVER_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
```

…or fill `_googleServerClientIdDefault` in `backend_config.dart`, which is
what the publishable key and base URL already do, and for the same reason:
a value that has to be retyped correctly on every build is a value that will
one day be typed wrong.

**It is not a secret.** It ships inside every APK and identifies the project.
The client **secret** is the half that matters, and it belongs on Supabase's
provider page and nowhere else — certainly not in this repository, which is
public.

---

## When it does not work

### The button does nothing. No error, no spinner, nothing.

**This is the normal symptom of a wrong SHA-1 or a wrong package name.**

Android's CredentialManager reports some configuration errors as a *cancel*,
even after an account has been chosen, and the plugin cannot tell that apart
from someone tapping Back. The app therefore treats it as a cancel and shows
nothing — which is right for every real cancel and confusing exactly once,
during first setup.

So: check the SHA-1 before looking anywhere else. Check it against the key
the APK was actually signed with, not the one you think it was.

### "Google sign-in is not available yet"

`clientConfigurationError` or `providerConfigurationError` — the Android
client does not exist, or `VH_GOOGLE_SERVER_CLIENT_ID` names a client Google
will not mint a token for. Confirm the ID in the build is the **web** one.

### It signs in, then fails

The exchange at `/auth/v1/token?grant_type=id_token` was refused. The token
is fine; Supabase did not recognise its audience. Add the Android client ID
to **Authorized Client IDs**, web first.

Read the reason in the project's **Auth Logs** — it is there, and it is not
visible from the phone.

---

## What is still not done

- **Phone OTP** is written, correct, and blocked on an SMS provider. The
  client sends exactly what GoTrue documents; only the provider is off.
- **Email OTP** is not implemented. It needs a repository method, a field on
  the sheet, and a custom SMTP service.

The sheet is laid out so either one drops in beside Google rather than
replacing it: the goal is that anybody can get in, by whichever route they
already have.
