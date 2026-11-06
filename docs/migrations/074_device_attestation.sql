-- 074 — what a phone's Keystore certified about its media key
-- (docs/security_review_2026_11.md S3/P3, docs/edge/key_attest.js).
--
-- request-playback wraps each film's DEK for the RSA key a phone sends. From
-- the build after 6 Nov 2026 the phone also sends the key's attestation
-- chain, and request-playback records here what it found: whether the chain
-- reaches Google's attestation root, whether it is revoked, whether it
-- certifies this very key, made by our package and signer in secure
-- hardware, on a phone that boots a locked, verified system.
--
-- LOG MODE: nothing is refused because of it yet. This is the evidence the
-- switch to requiring it for premium and sealed grants will be judged on.
--
-- No identifier is in it: only the verdict's fields (see key_attest.js
-- `verdict`). Not readable by the app: `devices` grants authenticated only
-- device_id, label and last_seen, column by column, and a new column is not
-- among them.

alter table public.devices
  add column if not exists attest jsonb,
  add column if not exists attest_at timestamptz;

comment on column public.devices.attest is
  'key_attest.js verdict for this install''s media key (no identifiers); log mode';
