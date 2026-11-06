// The pages the admin console runs on, which the edge functions answer with
// CORS (docs/security_review_2026_11.md S4/P4).
//
// Two while the console moves: GitHub Pages, where it has always been, and
// console.innocentplayer.com, its own origin (docs/console/README.md). A
// GitHub Pages origin is shared by every Pages site of the account; a page
// of our own is not, and it can send real headers (CSP with frame-ancestors,
// HSTS, COOP) that a <meta> cannot. When the new one is proven, the Pages
// copy is retired and removed from here.
//
// STUDIO_ORIGINS (an Edge secret, comma-separated) can ADD an origin, for a
// test page; it can no longer replace these by accident.

export const CONSOLE_ORIGINS = [
  'https://yannmh007.github.io',
  'https://console.innocentplayer.com',
];

/**
 * @param {string | undefined} extra the STUDIO_ORIGINS secret, if set
 * @returns {string[]}
 */
export function consoleOrigins(extra) {
  const more = String(extra ?? '').split(',').map((s) => s.trim())
    .filter((s) => /^(https:\/\/[a-z0-9.-]+|http:\/\/(localhost|127\.0\.0\.1))(:\d+)?$/i.test(s));
  return [...new Set([...CONSOLE_ORIGINS, ...more])];
}
