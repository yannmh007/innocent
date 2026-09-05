# Innocent — signing identity (docs/signing_identity.md)

ဒီစာရွက်က app ရဲ့ **အမှတ်သညာ (identity)** နှစ်ခုကို မှတ်တမ်းတင်ဖို့ပါ။
နောင် build တစ်ခုဟာ "အရင်အတိုင်း app တစ်ခုတည်း" ဟုတ်မဟုတ် ဒီနေရာနဲ့ တိုက်စစ်လို့ရပါတယ်။

---

## 1. Application id

| | |
|---|---|
| အရင် | `com.example.mx_clone` |
| အခု | `com.innocent.media` |
| ပြောင်းသည့်ရက် | 30 Aug 2026 |
| namespace | `com.innocent.media` — applicationId နဲ့ တူအောင် ပြောင်းပြီး (Kotlin/AIDL package ၂၃ ဖိုင်လုံး) |

---

## 2. Release keystore

**ထုတ်ပြီးပါပြီ — 30 Aug 2026 (Google Colab, ဖုန်းကနေ)။**

```
ဖိုင်နာမည်     : innocent.jks
alias         : innocent
key           : RSA 2048  (SHA384withRSA)
Owner         : CN=Innocent, O=Innocent, L=Yangon, C=MM
ထုတ်သည့်ရက်    : 2026-08-30
သက်တမ်း       : 10000 ရက် — 2054-01-15 အထိ
SHA-256       : E3:E1:EF:FA:99:3C:ED:67:45:A3:3F:75:C9:77:42:A3:
                B8:BA:DD:79:D5:49:27:D2:51:55:38:59:4C:85:CD:B1
```

နောင် build တစ်ခုရဲ့ SHA-256 က အပေါ်ကနဲ့ **မတူရင်** key ပြောင်းသွားပြီ ဖြစ်လို့
အဲဒီ APK ကို ဘယ်သူ့မှ မပေးပါနဲ့ — user တွေ update လုပ်လို့ မရတော့ပါဘူး။

စကားဝှက်ကို ဒီစာရွက်ထဲ **ဘယ်တော့မှ မရေးပါနဲ့။** ဒီဖိုင်က zip တိုင်းမှာ ပါသွားပါတယ်။

**FlutLab မှာ signing လုပ်နည်း (31 Aug 2026 မှာ သင်ခန်းစာရခဲ့တာ):**
`android/key.properties` ကို FlutLab က ပိုင်ထားလို့ ကိုယ့်ဟာ မရောက်ပါဘူး။
ဒါကြောင့် build.gradle က **`android/signing.properties`** ကို အရင်ဖတ်ပါတယ်။
Settings → App Signing မှာ ⬆ နဲ့ keystore တင်ပါ၊ **➕ / Create New မနှိပ်ရ**
(key အသစ် ထွက်ပြီး ဒီစာရွက်က SHA မမှန်တော့ပါ)။
APK ထုတ်တိုင်း လက်မှတ်ကို စစ်ပါ — Settings ကောင်းနေရုံနဲ့ မယုံရပါ။

SHA-256 ကို Colab cell ထဲမှာ ဒီလိုကြည့်ပါ —

```python
!keytool -list -v -keystore innocent.jks -storepass YOUR_PASSWORD | grep SHA256
```

ထွက်လာတဲ့ `SHA256: AB:CD:...` စာကြောင်းကို အပေါ်က နေရာမှာ ကူးထည့်ပါ။

---

## 3. Backup — နေရာ ၃ ခု

`.jks` ဖိုင်နဲ့ စကားဝှက် နှစ်ခုလုံး ပျောက်ရင် **app ကို update လုပ်လို့ ဘယ်တော့မှ မရတော့ပါ**
(user တိုင်း uninstall ပြန်လုပ်ပြီး data အကုန်ဆုံးမှ ရမယ်)။ ဒါကြောင့် ၃ နေရာ။

- [x] နေရာ ၁ : Google Drive — `My Drive / innocent_keystore / innocent.jks`
- [ ] နေရာ ၂ : ......................... (ဥပမာ — ကိုယ်ပိုင် Telegram Saved Messages)
- [ ] နေရာ ၃ : ......................... (ဥပမာ — ဖုန်း/SD card ထဲ folder တစ်ခု)

စကားဝှက်ကို သိမ်းထားတဲ့နေရာ : ......................... (`.jks` နဲ့ **မတူတဲ့** နေရာ)

စကားဝှက်ကို `.jks` နဲ့ **သီးခြားနေရာမှာ** သိမ်းပါ။

---

## 4. စစ်ဆေးနည်း

build log ထဲမှာ ဒီစာကြောင်း **မပါရင်** signing အောင်မြင်ပါပြီ —

```
* Innocent: NO RELEASE KEYSTORE FOUND.
```

ပါနေရင် `key.properties` ဒါမှမဟုတ် `.jks` က မမှန်သေးလို့ပါ။ အဲဒီ APK ကို ဘယ်သူ့မှ မပေးပါနဲ့။
