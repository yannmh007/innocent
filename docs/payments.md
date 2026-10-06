# Paying for Premium: the receipt screenshot

Owner request (2026-10-05): let viewers send the payment screenshot. "A KPay
transaction id cannot be copied in one go, and most users do not know what
it is."

## 1. How people in Myanmar pay a small seller today

* **The screenshot is the receipt.** Facebook shops, Telegram sellers and
  delivery services all ask for the same thing after a KBZPay / Wave /
  AYA Pay transfer: a screenshot of the "transfer successful" page
  (ငွေလွှဲပြေစာ). Everyone knows how; nobody has to understand what a
  transaction id is.
* **The transaction id is hard to give.** KBZPay shows a long Transaction
  No. on the receipt that cannot be selected and copied; the old form asked
  for it to be retyped digit by digit from one app into another, right after
  sending money.
* **Automatic confirmation exists, for registered merchants.** KBZPay's
  payment gateway (directly, or through an aggregator such as 2C2P) confirms
  the payment to the merchant's server by itself — no screenshot, no human
  check. It needs a registered business, a merchant contract and the bank's
  UAT/production keys ([2C2P: KBZPay](https://developer.2c2p.com/docs/sdk-method-kbzpay),
  [kbz_pay Flutter plugin](https://github.com/Sabahna/kbz_pay),
  [KBZ QuickPay](https://www.kbzbank.com/en/other-services-en/kbz-quick-pay/)).
  That is the end state; until there is a merchant account, the receipt is
  the honest proof.

## 2. The flow now

**Viewer** (PremiumRequestScreen):

1. The payee card: name, number (copy button), the amount.
2. **Open KPay** — one tap to the wallet (`launchPackage`
   com.kbzbank.kpaycustomer; "KPay is not installed" if it is not).
   Pay, then screenshot the receipt.
3. **Attach the receipt**: the phone's recent screenshots as a strip (only
   when the app already may read photos — nothing here asks for a
   permission), and "Choose from your photos" (Android's own picker, no
   permission). The chosen receipt is shown large with "check the amount and
   the transaction are visible" and Change. The transaction id is folded
   away under "Add the transaction ID (optional)". The sending number is
   pre-filled from the account.

A receipt over 1.5 MB is redrawn 1080 px wide before it is sent.

**Server** (`premium-request` edge function, migration 040):

* the user from their JWT; a plan with a price;
* the image checked by its bytes (PNG / JPEG / WebP, ≤ 5 MB);
* **one receipt, one request**: the same screenshot sent again by the same
  account while it is pending returns that request (a retry after a
  timeout never files twice); sent by another account it is filed but marked
  `duplicate_of`, and the owner is told in red;
* at most 3 pending and 6 a day per account;
* stored in the private `payment-proofs` bucket (only the service role can
  read it);
* the owner's Telegram gets the screenshot itself with the plan, the price
  the viewer saw, the sending number and the request id.

**Operator** (console → Requests): each request shows the receipt (tap for
full size, a 10-minute signed link), the plan and price, the sending number,
the transaction id if given, and the duplicate warning. Approve / Reject as
before (`approve_request` writes the subscription; nothing else does).

## 3. What was checked

* Live database: the owner trigger keeps the user the service role names
  and still forces `pending`; a request with neither a screenshot nor a
  transaction id is refused by the `premium_requests_has_proof` constraint
  (run in a transaction that was rolled back).
* The function is deployed (`premium-request` v2). It could not be called
  from the development container (its network does not reach the project)
  and there is no test account with a session, so **the first real payment
  is its end-to-end test**: the Telegram photo arriving is the sign it works.
* Unit tests: the receipt shrinking. Harness renders: the new screen.

## 4. The note, and the inbox (2026-10-06, migration 042)

Owner, after trying it: "a screenshot alone is not enough — there must be
somewhere to write a note; and the console must announce these, with the
receipts right there."

**Viewer.** Step 4, *Add a note (optional)*: up to 500 characters in the
payer's own words. Every request now goes through the function (a
transaction id with no screenshot too), so the note is never lost. The
screen opens with what is being bought (plan, price, what it opens); the
steps are a stepper that ticks when the receipt is attached; after sending,
*What happens next* — received, checked against KPay, Premium turns on by
itself. In Account each request shows its state in colour, what the payer
wrote, and Innocent's reply.

**Console** (`docs/studio/inbox.js`). The Payments page: a card per request
with the receipt large (tap for full size), the payer's note, the account
(NEW, returning payer, Premium until, receipt already used), the plan and the
price shown. Approve with the plan's days and an optional word to the payer;
Reject with a reason (presets or typed) — the payer's app shows it.
Waiting / Approved / Rejected / All; decided ones say who and when. A new
payment is announced on any page: menu badge (red while unseen), "(n)" in
the tab title, a card in the corner, and — once switched on with *Notify me*
and *Sound* — a system notification and a chime. Opening the waiting list
marks it seen. The count every 30 s is not "activity": the idle sign-out
still works.

**Server.** `premium_requests.message / seen_at / reviewed_by`;
`admin_requests` (service role only). premium-request v3 serves the
console's ops (pulse, inbox, seen, proofs, approve, reject) behind the
editor+/MFA gate, and writes approvals and rejections to `admin_audit`.

## 5. Next

* KBZPay merchant gateway, once there is a registered business: payment
  confirms itself, Premium turns on in seconds, no screenshot.
* Wave Pay / AYA Pay as further payees (payment_instructions holds one).
* Approve/Reject buttons on the Telegram message itself (the bot's webhook
  would need to handle callback queries).
* A retention rule for the screenshots (they hold names and numbers):
  delete a decided request's receipt after 90 days.
