import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum ProfileSourceType { builtin, file, url }

class ProfileSource {
  const ProfileSource({
    required this.kind,
    required this.raw,
    this.label,
    this.priority = 0,
  });

  final ProfileSourceType kind;
  final String raw;
  final String? label;
  final int priority;

  bool get hasContent => raw.trim().isNotEmpty;
}

class ProfileCondition {
  const ProfileCondition({
    required this.googleReachable,
    required this.yandexReachable,
    required this.internetAvailable,
    required this.whitelistEnabled,
  });

  final bool googleReachable;
  final bool yandexReachable;
  final bool internetAvailable;
  final bool whitelistEnabled;
}

class BuiltinProfile {
  const BuiltinProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.whitelistMode,
    required this.configJson,
  });

  final String id;
  final String name;
  final String description;
  final bool whitelistMode;
  final String configJson;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'whitelistMode': whitelistMode,
        'config': jsonDecode(configJson),
      };
}

class ForkProfileBootstrap {
  static Future<List<String>> bootstrap() async {
    final profiles = await BuiltinProfileCatalog.loadProfiles();
    final baseDir = await _resolveWritableProfileDirectory();
    final seedDir = Directory(path.join(baseDir, 'fork_profiles'));
    await seedDir.create(recursive: true);

    final written = <String>[];
    for (final profile in profiles) {
      final file = File(path.join(seedDir.path, '${profile.id}.json'));
      if (!await file.exists()) {
        await file.writeAsString(profile.configJson, flush: true);
      }
      written.add(file.path);
    }

    final selected = selectProfileForCondition(
      const ProfileCondition(
        googleReachable: true,
        yandexReachable: true,
        internetAvailable: true,
        whitelistEnabled: false,
      ),
    );

    final manifest = File(path.join(baseDir, 'fork_profile_manifest.json'));
    await manifest.writeAsString(
      jsonEncode({
        'selectedProfileId': selected.id,
        'selectedProfileFile': path.join(seedDir.path, '${selected.id}.json'),
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'sourceOrder': [
          ProfileSourceType.url.name,
          ProfileSourceType.file.name,
          ProfileSourceType.builtin.name,
        ],
      }),
      flush: true,
    );

    return written;
  }

  static Future<String> _resolveWritableProfileDirectory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      final dir = await getTemporaryDirectory();
      return dir.path;
    }
  }
}

class BuiltinProfileCatalog {
  static Future<List<BuiltinProfile>> loadProfiles() async {
    try {
      final raw = await rootBundle.loadString(
        'assets/datas/fork_profiles/default_profiles.json',
      );
      final map = jsonDecode(raw);
      final list = (map['profiles'] as List?) ?? const [];
      return list
          .map((item) => BuiltinProfile(
                id: item['id'] as String,
                name: item['name'] as String,
                description: item['description'] as String? ?? '',
                whitelistMode: item['whitelistMode'] == true,
                configJson: jsonEncode(item['config']),
              ))
          .toList(growable: false);
    } catch (_) {
      return const [
        BuiltinProfile(
          id: 'normal_full_access',
          name: 'Normal Full Access',
          description: 'Default working profile with full internet access.',
          whitelistMode: false,
          configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"8.8.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["auto","direct"],"default":"auto"},{"type":"urltest","tag":"auto","outbounds":["direct"],"url":"https://www.google.com","interval":"5m","tolerance":100},{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}',
        ),
        BuiltinProfile(
          id: 'whitelist_google_blocked_yandex_ok',
          name: 'Whitelist Google Blocked / Yandex OK',
          description: 'Whitelist profile for restricted networks where Google is blocked but Yandex is reachable.',
          whitelistMode: true,
          configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"77.88.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["yandex","direct"],"default":"yandex"},{"type":"direct","tag":"direct"},{"type":"http","tag":"yandex","server":"213.180.204.3","server_port":443},{"type":"block","tag":"block"}]}',
        ),
        BuiltinProfile(
          id: 'offline_fallback',
          name: 'Offline Fallback',
          description: 'Emergency profile when no internet is available.',
          whitelistMode: false,
          configJson: '{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}',
        ),
      ];
    }
  }
}

BuiltinProfile selectProfileForCondition(ProfileCondition cond) {
  if (!cond.internetAvailable) {
    return _profileById('offline_fallback');
  }

  if (cond.whitelistEnabled) {
    if (cond.googleReachable == false && cond.yandexReachable == true) {
      return _profileById('whitelist_google_blocked_yandex_ok');
    }

    if (cond.googleReachable == false && cond.yandexReachable == false) {
      return _profileById('whitelist_blocked_all');
    }

    return _profileById('whitelist_google_allowed');
  }

  if (cond.googleReachable == true && cond.yandexReachable == true) {
    return _profileById('normal_full_access');
  }

  if (cond.googleReachable == false && cond.yandexReachable == true) {
    return _profileById('normal_yandex_only');
  }

  return _profileById('offline_fallback');
}

BuiltinProfile _profileById(String id) {
  final profiles = [
    const BuiltinProfile(
      id: 'normal_full_access',
      name: 'Normal Full Access',
      description: 'Default working profile with full internet access.',
      whitelistMode: false,
      configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"8.8.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["auto","direct"],"default":"auto"},{"type":"urltest","tag":"auto","outbounds":["direct"],"url":"https://www.google.com","interval":"5m","tolerance":100},{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}',
    ),
    const BuiltinProfile(
      id: 'normal_yandex_only',
      name: 'Normal Yandex Only',
      description: 'Optimized profile when internet works but Google is blocked.',
      whitelistMode: false,
      configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"77.88.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["yandex","direct"],"default":"yandex"},{"type":"direct","tag":"direct"},{"type":"http","tag":"yandex","server":"213.180.204.3","server_port":443},{"type":"block","tag":"block"}]}',
    ),
    const BuiltinProfile(
      id: 'whitelist_google_blocked_yandex_ok',
      name: 'Whitelist Google Blocked / Yandex OK',
      description: 'Whitelist profile for restricted networks where Google is blocked but Yandex is reachable.',
      whitelistMode: true,
      configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"77.88.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["yandex","direct"],"default":"yandex"},{"type":"direct","tag":"direct"},{"type":"http","tag":"yandex","server":"213.180.204.3","server_port":443},{"type":"block","tag":"block"}]}',
    ),
    const BuiltinProfile(
      id: 'whitelist_google_allowed',
      name: 'Whitelist Full Allowed',
      description: 'Whitelist profile with full allowed domains access.',
      whitelistMode: true,
      configJson: '{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"tag":"dns","address":"8.8.8.8"}]},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["google","yandex","direct"],"default":"google"},{"type":"direct","tag":"direct"},{"type":"http","tag":"google","server":"216.58.214.206","server_port":443},{"type":"http","tag":"yandex","server":"213.180.204.3","server_port":443},{"type":"block","tag":"block"}]}',
    ),
    const BuiltinProfile(
      id: 'whitelist_blocked_all',
      name: 'Whitelist Blocked All',
      description: 'Whitelist profile when internet is intentionally restricted and all routes are blocked.',
      whitelistMode: true,
      configJson: '{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"selector","tag":"proxy","outbounds":["direct"],"default":"direct"},{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}',
    ),
    const BuiltinProfile(
      id: 'offline_fallback',
      name: 'Offline Fallback',
      description: 'Emergency profile when no internet is available.',
      whitelistMode: false,
      configJson: '{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"karing","inet4_address":"172.18.0.1/30","auto_route":true,"strict_route":false}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}',
    ),
  ];

  final match = profiles.firstWhere(
    (e) => e.id == id,
    orElse: () => profiles.first,
  );
  return match;
}

class ProfileLoader {
  static Future<String> load(ProfileSource source) async {
    switch (source.kind) {
      case ProfileSourceType.builtin:
        final profile = source.raw == 'builtin' || !source.hasContent
            ? selectProfileForCondition(
                const ProfileCondition(
                  googleReachable: true,
                  yandexReachable: true,
                  internetAvailable: true,
                  whitelistEnabled: false,
                ),
              )
            : _profileById(source.raw);
        return profile.configJson;
      case ProfileSourceType.file:
        final file = File(source.raw);
        if (!await file.exists()) {
          throw StateError('Profile file not found: ${source.raw}');
        }
        return await file.readAsString();
      case ProfileSourceType.url:
        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(source.raw));
          final response = await request.close();
          return await response.transform(utf8.decoder).join();
        } finally {
          client.close();
        }
    }
  }
}
