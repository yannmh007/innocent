// A photo says nothing about where or when it was taken once it leaves the
// operator's phone (docs/MEDIA_ENCRYPTION.md §7.3).
//
// WHAT GOES: EXIF (GPS position, camera and phone model, serial numbers, the
// time, an embedded thumbnail of the uncropped picture), XMP, IPTC and
// Photoshop blocks, comments, and every other application block a decoder
// does not need. Photos land in the public bucket, so before this a picture
// taken at home could carry the address of that home to anyone with its URL.
//
// WHAT STAYS: the compressed picture itself, byte for byte (nothing is
// re-encoded, so nothing is lost), the colour profile (APP2 ICC) and the
// JFIF and Adobe blocks decoding depends on — and THE ORIENTATION. A phone
// stores "this picture is on its side" as an EXIF tag, so dropping EXIF
// whole would turn every portrait photo sideways; it is written back as a
// minimal EXIF holding that one tag and nothing else.
//
// Plain ES module, no dependencies: the console imports it when it uploads a
// photo, Node from tool/js/jpeg_clean_test.mjs.

const SOI = 0xd8;
const SOS = 0xda;
const EOI = 0xd9;

/** True when [b] starts like a JPEG. */
export function isJpeg(b) {
  return b.length > 4 && b[0] === 0xff && b[1] === SOI && b[2] === 0xff;
}

/// The EXIF Orientation (1-8) in an APP1 Exif payload, or 0.
function orientationOf(payload) {
  // "Exif\0\0", then a TIFF header: byte order, 42, offset of IFD0.
  if (payload.length < 14) return 0;
  const t = 6;
  const le = payload[t] === 0x49 && payload[t + 1] === 0x49;
  const be = payload[t] === 0x4d && payload[t + 1] === 0x4d;
  if (!le && !be) return 0;
  const u16 = (o) => (o + 2 > payload.length ? -1
    : le ? payload[o] | (payload[o + 1] << 8) : (payload[o] << 8) | payload[o + 1]);
  const u32 = (o) => (o + 4 > payload.length ? -1
    : le ? (payload[o] | (payload[o + 1] << 8) | (payload[o + 2] << 16) | (payload[o + 3] << 24)) >>> 0
      : ((payload[o] << 24) | (payload[o + 1] << 16) | (payload[o + 2] << 8) | payload[o + 3]) >>> 0);
  if (u16(t + 2) !== 42) return 0;
  const ifd = t + u32(t + 4);
  const n = u16(ifd);
  if (n < 0 || n > 512) return 0;
  for (let i = 0; i < n; i++) {
    const e = ifd + 2 + i * 12;
    if (u16(e) === 0x0112 && u16(e + 2) === 3) {
      const v = u16(e + 8);
      return v >= 1 && v <= 8 ? v : 0;
    }
  }
  return 0;
}

/// An APP1 segment holding a big-endian EXIF with Orientation alone.
function orientationSegment(v) {
  const body = [
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00,          // "Exif\0\0"
    0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, // MM, 42, IFD0 at 8
    0x00, 0x01,                                   // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // Orientation, SHORT, 1
    0x00, v, 0x00, 0x00,                          // its value
    0x00, 0x00, 0x00, 0x00,                       // no next IFD
  ];
  const len = body.length + 2;
  return Uint8Array.from([0xff, 0xe1, len >> 8, len & 0xff, ...body]);
}

/// Which blocks before the picture stay. APP0 (JFIF), APP2 (ICC colour)
/// and APP14 (Adobe colour transform) are needed to show it as it is; every
/// table and frame header (DQT, DHT, SOF, DRI…) is the picture.
function keeps(marker) {
  if (marker === 0xe0 || marker === 0xe2 || marker === 0xee) return true;
  if (marker >= 0xe0 && marker <= 0xef) return false; // APP1, APP3-13, APP15
  if (marker === 0xfe) return false;                  // COM
  return true;
}

/**
 * [bytes] without what it says about where and when, or null when it is not
 * a JPEG this can walk (the caller then decides; the console refuses to
 * upload a photo it could not clean rather than publish its location).
 *
 * @param {Uint8Array} bytes
 * @returns {{bytes: Uint8Array, removed: number, orientation: number} | null}
 */
export function cleanJpeg(bytes) {
  if (!isJpeg(bytes)) return null;
  const out = [];
  let orientation = 0;
  let removed = 0;
  let i = 2;
  const head = [];       // APP0, if it comes first, stays first
  let sawFirst = false;
  while (i < bytes.length) {
    if (bytes[i] !== 0xff) return null;
    // Fill bytes before a marker.
    while (i < bytes.length && bytes[i] === 0xff) i++;
    if (i >= bytes.length) return null;
    const marker = bytes[i++];
    if (marker === EOI) return null;              // no picture at all
    if (marker === SOI || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) return null;
    if (i + 2 > bytes.length) return null;
    const len = (bytes[i] << 8) | bytes[i + 1];
    if (len < 2 || i + len > bytes.length) return null;
    const segment = bytes.subarray(i - 2, i + len);
    const payload = bytes.subarray(i + 2, i + len);
    if (marker === SOS) {
      // The picture: everything from here to the end, untouched.
      const ori = orientation >= 2 ? [orientationSegment(orientation)] : [];
      const total = [Uint8Array.of(0xff, SOI), ...head, ...ori, ...out, bytes.subarray(i - 2)];
      const res = new Uint8Array(total.reduce((t, x) => t + x.length, 0));
      let at = 0;
      for (const x of total) { res.set(x, at); at += x.length; }
      return { bytes: res, removed, orientation: orientation || 1 };
    }
    if (marker === 0xe1 && payload.length >= 6 &&
        payload[0] === 0x45 && payload[1] === 0x78 && payload[2] === 0x69 && payload[3] === 0x66 &&
        payload[4] === 0 && payload[5] === 0) {
      orientation = orientation || orientationOf(payload);
    }
    if (keeps(marker)) {
      if (!sawFirst && marker === 0xe0) head.push(segment);
      else out.push(segment);
    } else {
      removed += segment.length;
    }
    sawFirst = true;
    i += len;
  }
  return null;
}
