/// A language's own name for itself — "English", "မြန်မာ", "ไทย" — from the
/// code a film's audio or subtitle track carries: ISO 639-1 ("en") or 639-2
/// in either form ("bur" / "mya", "chi" / "zho"). A viewer finds their
/// language by its own name whatever language the app is in, which is why
/// the track pickers use these and not a translation. Null for a code not
/// listed, "und" (undetermined) and an empty code: the caller shows what it
/// has instead.
String? languageName(String? code) {
  if (code == null) return null;
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return null;
  // "en-US", "pt_BR": the language is the part before the region.
  final base = c.split(RegExp('[-_]')).first;
  return _names[base];
}

const Map<String, String> _names = <String, String>{
  'en': 'English', 'eng': 'English',
  'my': 'မြန်မာ', 'mya': 'မြန်မာ', 'bur': 'မြန်မာ',
  'th': 'ไทย', 'tha': 'ไทย',
  'zh': '中文', 'zho': '中文', 'chi': '中文',
  'ja': '日本語', 'jpn': '日本語',
  'ko': '한국어', 'kor': '한국어',
  'hi': 'हिन्दी', 'hin': 'हिन्दी',
  'ta': 'தமிழ்', 'tam': 'தமிழ்',
  'te': 'తెలుగు', 'tel': 'తెలుగు',
  'bn': 'বাংলা', 'ben': 'বাংলা',
  'ne': 'नेपाली', 'nep': 'नेपाली',
  'si': 'සිංහල', 'sin': 'සිංහල',
  'km': 'ខ្មែរ', 'khm': 'ខ្មែរ',
  'lo': 'ລາວ', 'lao': 'ລາວ',
  'vi': 'Tiếng Việt', 'vie': 'Tiếng Việt',
  'id': 'Bahasa Indonesia', 'ind': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu', 'msa': 'Bahasa Melayu', 'may': 'Bahasa Melayu',
  'tl': 'Filipino', 'tgl': 'Filipino', 'fil': 'Filipino',
  'fr': 'Français', 'fra': 'Français', 'fre': 'Français',
  'de': 'Deutsch', 'deu': 'Deutsch', 'ger': 'Deutsch',
  'es': 'Español', 'spa': 'Español',
  'pt': 'Português', 'por': 'Português',
  'it': 'Italiano', 'ita': 'Italiano',
  'nl': 'Nederlands', 'nld': 'Nederlands', 'dut': 'Nederlands',
  'ru': 'Русский', 'rus': 'Русский',
  'uk': 'Українська', 'ukr': 'Українська',
  'pl': 'Polski', 'pol': 'Polski',
  'tr': 'Türkçe', 'tur': 'Türkçe',
  'ar': 'العربية', 'ara': 'العربية',
  'fa': 'فارسی', 'fas': 'فارسی', 'per': 'فارسی',
  'he': 'עברית', 'heb': 'עברית',
  'ur': 'اردو', 'urd': 'اردو',
  'mn': 'Монгол', 'mon': 'Монгол',
};

/// "5.1", "Stereo"-free: a channel count as the number people know it by
/// (2 → "2.0", 6 → "5.1", 8 → "7.1"), so it reads the same in every
/// language.
String channelLayout(int channels) {
  switch (channels) {
    case 1:
      return '1.0';
    case 2:
      return '2.0';
    case 6:
      return '5.1';
    case 8:
      return '7.1';
    default:
      return '${channels}ch';
  }
}
