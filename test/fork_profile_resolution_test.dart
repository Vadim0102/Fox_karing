import 'package:test/test.dart';

import 'package:karing/fork/karing_fork_profiles.dart';

void main() {
  group('fork default profile resolution', () {
    test('whitelist with Google blocked and Yandex available selects whitelist profile', () {
      final profile = selectProfileForCondition(
        ProfileCondition(
          googleReachable: false,
          yandexReachable: true,
          internetAvailable: true,
          whitelistEnabled: true,
        ),
      );

      expect(profile.id, 'whitelist_google_blocked_yandex_ok');
      expect(profile.whitelistMode, isTrue);
    });

    test('full internet with whitelist disabled selects normal profile', () {
      final profile = selectProfileForCondition(
        ProfileCondition(
          googleReachable: true,
          yandexReachable: true,
          internetAvailable: true,
          whitelistEnabled: false,
        ),
      );

      expect(profile.id, 'normal_full_access');
      expect(profile.whitelistMode, isFalse);
    });

    test('no internet selects offline profile', () {
      final profile = selectProfileForCondition(
        ProfileCondition(
          googleReachable: false,
          yandexReachable: false,
          internetAvailable: false,
          whitelistEnabled: true,
        ),
      );

      expect(profile.id, 'offline_fallback');
    });

    test('loader tries built-in config when file and URL are missing', () async {
      final result = await ProfileLoader.load(
        ProfileSource(
          kind: ProfileSourceType.builtin,
          raw: 'builtin',
        ),
      );

      expect(result, isNotEmpty);
      expect(result, contains('whitelist_google_blocked_yandex_ok'));
    });
  });
}
