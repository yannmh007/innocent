import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/preferences/settings_migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for SettingsMigrationService. The service is intentionally
/// thin right now (v0 → v1 is a no-op baseline) but we still want
/// the scaffolding tested: idempotency, version-marker writing,
/// and resilience against missing keys.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('runMigrations on fresh install returns previous version 0', () async {
    final previous = await SettingsMigrationService.runMigrations();
    expect(previous, 0);
  });

  test('runMigrations writes currentSchemaVersion after running', () async {
    await SettingsMigrationService.runMigrations();
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('_schemaVersion'),
        SettingsMigrationService.currentSchemaVersion);
  });

  test('runMigrations is idempotent — second call is a no-op', () async {
    // First call: writes the version.
    final first = await SettingsMigrationService.runMigrations();
    expect(first, 0);
    // Second call: stored version already matches; returns the
    // already-current value without re-running.
    final second = await SettingsMigrationService.runMigrations();
    expect(second, SettingsMigrationService.currentSchemaVersion);
  });

  test('runMigrations on a future-version SharedPreferences leaves it alone',
      () async {
    // Simulate a downgrade scenario: a SharedPreferences blob written
    // by a newer build than this one. We must NOT roll the version
    // backward or run any migration ladder backwards.
    SharedPreferences.setMockInitialValues({'_schemaVersion': 99});
    final previous = await SettingsMigrationService.runMigrations();
    expect(previous, 99);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('_schemaVersion'), 99);
  });

  test('currentSchemaVersion is at least 1', () {
    // Smoke test: anyone bumping the schema must keep the version
    // monotonically increasing. Catching a copy-paste mistake here
    // is cheaper than catching it after release.
    expect(SettingsMigrationService.currentSchemaVersion,
        greaterThanOrEqualTo(1));
  });
}
