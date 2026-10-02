# third_party

## media_kit_libs_android_video

A copy of `media_kit_libs_android_video` 1.3.8 from pub.dev, used through
`dependency_overrides` in `pubspec.yaml`. The **only** change is
`android/build.gradle`: it downloads the **full** flavour of
[libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build)
v1.1.11 instead of the **default** flavour of v1.1.7.

Why: the default build is configured `--disable-decoders` / `--disable-demuxers`
/ `--disable-parsers` with a hand-picked list switched back on. Missing from it,
among others: VC-1, RealVideo 1–4, TrueHD/MLP, AMR-NB/WB (most phone-recorded
3GP), Cook, ProRes, DV, Cinepak, Indeo; the Blu-ray PGS, MicroDVD, SAMI and
MPL2 subtitle formats; raw H.264/H.265/AMR/CAF/MXF/NUT/IVF demuxers. The full
build enables every LGPL decoder, demuxer and parser.

Checked before switching (2026-10-02), both `arm64-v8a` libraries:

| | v1.1.7 default (was) | v1.1.11 full (now) |
|---|---|---|
| mpv | v0.36.0-549-g78d43740f5 | v0.36.0-549-g78d43740f5 |
| FFmpeg | n6.0 | n6.0 |
| `libmediakitandroidhelper.so` md5 | f87a484a… | f87a484a… |
| exported `mpv_*` functions | 55 | 55, identical names |
| licence flags | `--disable-gpl --disable-nonfree` | `--disable-gpl --disable-nonfree` |
| `libmpv.so` size | 12.4 MB | 16.1 MB |

So media_kit's Dart bindings and helper are unchanged; the APK grows by about
2 MB (only arm64-v8a is shipped). The MD5 of every jar is checked by the
Gradle task, as upstream does.

To go back: delete the `dependency_overrides` entry.
