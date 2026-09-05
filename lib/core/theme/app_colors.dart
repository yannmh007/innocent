import 'package:flutter/material.dart';

/// Innocent color palette based on actual MX Player screenshots
class AppColors {
  AppColors._();

  // === DARK THEME (default, like MX Player) ===
  static const Color darkBackground = Color(0xFF0F0F0F);
  static const Color darkSurface = Color(0xFF1A1A1A);
  static const Color darkSurfaceVariant = Color(0xFF2A2A2A);
  static const Color darkOnSurface = Color(0xFFE0E0E0);
  static const Color darkOnSurfaceMuted = Color(0xFF888888);
  static const Color darkDivider = Color(0xFF2C2C2C);

  // === LIGHT THEME (placeholder for future) ===
  static const Color lightBackground = Color(0xFFFAFAFA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightOnSurface = Color(0xFF212121);
  static const Color lightOnSurfaceMuted = Color(0xFF666666);

  // === ACCENT (blue, per MX Player FAB and selected toggles) ===
  static const Color accentBlue = Color(0xFF2196F3);
  static const Color primaryBlue = accentBlue; // Alias used across screens
  static const Color accentBlueLight = Color(0xFF64B5F6);
  static const Color accentBlueDark = Color(0xFF1976D2);

  // === SEMANTIC ===
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFA726);
  static const Color error = Color(0xFFE53935);
  static const Color newBadge = Color(0xFFE53935);

  // === BOTTOM NAVIGATION ===
  static const Color bottomNavSelected = accentBlue;
  static const Color bottomNavUnselected = Color(0xFF888888);
  static const Color bottomNavBackground = Color(0xFF000000);

  // === FAB ===
  static const Color fabBackground = accentBlue;
  static const Color fabIcon = Color(0xFFFFFFFF);

  // === innocent_folders_spec tokens (Folders / Local screen) ===
  // Exact values from the design spec (innocent_folders_spec.md / .png),
  // applied to the Folders screen, quick-action row, FAB and bottom nav.
  static const Color specScaffold = Color(0xFF000000);      // true-black AMOLED bg
  static const Color specSurface = Color(0xFF444D56);       // folder thumbnails + quick discs
  static const Color specChipSurface = Color(0xFF2C2F36);   // size pill bg
  static const Color specPrimary = Color(0xFF3D8DF0);       // FAB + active nav
  static const Color specNavBar = Color(0xFF121212);        // bottom nav bg
  static const Color specTextSecondary = Color(0xFFC5C8CF); // counts, chip text, labels
  static const Color specNavInactive = Color(0xFF6F7889);   // inactive nav icon + label
  // Grid-view accents (innocent_folders_grid_spec) — also wired into the
  // list view so badge + selected-folder states match across both.
  static const Color specBadge = Color(0xFFF4405D);         // unread count bubble
  static const Color specSelectedLabel = Color(0xFF81D5FA); // highlighted folder name
  static const Color specFolderIcon = Color(0xFF535C63);    // folder glyph inside thumb
  // Player ▸ Video Options overlay (innocent_player_options_spec). The
  // accent here is a lighter blue than the browse-screen primary.
  static const Color specSheetBg = Color(0xFF191919);       // overlay sheet bg
  static const Color specInnerPanel = Color(0xFF222222);    // shortcuts inner panel
  static const Color specCheckbox = Color(0xFF66BAFF);      // checkbox fill
  static const Color specSwitchOn = Color(0xFF64B7FD);      // master switch ON track
  static const Color specNotifDot = Color(0xFFFF3B4E);      // notification dot
  static const Color specRing = Color(0x1FFFFFFF);          // icon-button ring, white ~12%
  // Player ▸ Main Controls overlay (innocent_player_controls_spec).
  // Brand #3D8DF0 (=specPrimary) is the seek fill; accent #66BAFF
  // (=specCheckbox) is the seek thumb. Two more are unique here:
  static const Color specSeekRail = Color(0xFF4D4D4D);      // seekbar rail
  static const Color specActiveToggle = Color(0xFF4D628D);  // active quick-toggle circle
  // Player ▸ Sleep Timer dialog (innocent_sleep_timer_spec). Reuses the
  // single accent #66BAFF (=specCheckbox) for STOP/START + the close ring.
  static const Color specSleepKeyFill = Color(0xFF2B2B2B);     // keypad button fill
  static const Color specSleepClose = Color(0xFF505978);       // close (X) circle bg
  static const Color specSleepCheckBorder = Color(0xFF4A5B8C); // checkbox border
  static const Color specSleepDivider = Color(0xFF3A3A3A);     // divider under time
  // Private Folder ▸ Add Files flow (innocent_add_files_flow_spec). Brand
  // #3D8DF0 (=specPrimary) drives the FAB + Add Now; the folder thumb
  // #444D56 (=specSurface) is reused from the browse list.
  static const Color specAddGlyph = Color(0xFF5298DD);        // empty-state "?" glyph
  static const Color specAddBreadcrumb = Color(0xFF5B8DEF);   // active breadcrumb crumb
  static const Color specAddBarBg = Color(0xFF18191B);        // breadcrumb bar bg
  static const Color specAddSizeChip = Color(0xFF525357);     // file size chip
  static const Color specAddCheckBorder = Color(0xFF4B4F52);  // picker checkbox border
  static const Color specAddDisabled = Color(0xFF1C1D1F);     // Add Now disabled bg
  // Audio Effect / Equalizer bottom sheet (MX Player parity). Steel-blue
  // slider track/thumb + translucent dial fill; the bright accentBlue is
  // reused for the active tab underline and selected preset text.
  static const Color specEqThumb = Color(0xFF3D7AB8);     // slider thumb + dial accent
  static const Color specEqTrack = Color(0xFF34618F);     // slider track
  static const Color specEqDialFill = Color(0xFF22384F);  // dial circle fill

  // === PRE-COMPUTED OPACITY CONSTANTS ===
  // Pre-computed equivalents of `Colors.white.withOpacity(x)` and
  // similar runtime calls. Same visual result, but const-able, so
  // widgets that use these can themselves be const (saving rebuilds).
  // Values: alpha = (opacity * 255).round() encoded in ARGB hex.
  static const Color white05 = Color(0x0DFFFFFF); // 0.05
  static const Color white06 = Color(0x0FFFFFFF); // 0.06
  static const Color white08 = Color(0x14FFFFFF); // 0.08
  static const Color white10 = Color(0x1AFFFFFF); // 0.10
  static const Color white15 = Color(0x26FFFFFF); // 0.15
  static const Color white20 = Color(0x33FFFFFF); // 0.20
  static const Color white30 = Color(0x4DFFFFFF); // 0.30
  static const Color white40 = Color(0x66FFFFFF); // 0.40
  static const Color white50 = Color(0x80FFFFFF); // 0.50
  static const Color white55 = Color(0x8CFFFFFF); // 0.55
  static const Color white60 = Color(0x99FFFFFF); // 0.60
  static const Color white70 = Color(0xB3FFFFFF); // 0.70
  static const Color white85 = Color(0xD9FFFFFF); // 0.85
  static const Color white90 = Color(0xE6FFFFFF); // 0.90

  static const Color black25 = Color(0x40000000); // 0.25
  static const Color black40 = Color(0x66000000); // 0.40
  static const Color black55 = Color(0x8C000000); // 0.55
  static const Color black65 = Color(0xA6000000); // 0.65
  static const Color black75 = Color(0xBF000000); // 0.75

  // Accent blue opacity stops (base = 0xFF2196F3).
  static const Color accentBlue10 = Color(0x1A2196F3); // 0.10
  static const Color accentBlue12 = Color(0x1F2196F3); // 0.12
  static const Color accentBlue15 = Color(0x262196F3); // 0.15
  static const Color accentBlue20 = Color(0x332196F3); // 0.20
  static const Color accentBlue40 = Color(0x662196F3); // 0.40
  static const Color accentBlue70 = Color(0xB32196F3); // 0.70

  // === PLAYER OVERLAYS ===
  static const Color playerBackground = Color(0xFF000000);
  static const Color playerOverlayDim = Color(0x80000000);
  static const Color playerOverlayDark = Color(0xCC000000);
  static const Color playerOverlayDarker = Color(0xE6000000);

  // === PLAYER PROGRESS ===
  static const Color progressFilled = accentBlue;
  static const Color progressUnfilled = Color(0x4DFFFFFF);
  static const Color progressBuffered = Color(0x66FFFFFF);

  // === PLAYER SHORTCUTS ===
  static const Color shortcutInactive = Color(0xCC1F1F1F);
  static const Color shortcutActive = accentBlue;

  // === TEXT ===
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xCCFFFFFF);
  static const Color textMuted = Color(0x80FFFFFF);
}
