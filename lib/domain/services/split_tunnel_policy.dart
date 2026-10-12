import 'dart:convert';

enum SplitTunnelMode { off, includeSelected, excludeSelected }

class SplitTunnelPolicy {
  const SplitTunnelPolicy({required this.mode, required this.packageNames});

  final SplitTunnelMode mode;
  final Set<String> packageNames;

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'packageNames': packageNames.toList()..sort(),
  };

  String exportText() => jsonEncode({
    'format': 'connecso-split-tunnel',
    'version': 1,
    'policy': toJson(),
  });

  static SplitTunnelPolicy importText(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['format'] != 'connecso-split-tunnel' ||
        decoded['version'] != 1 ||
        decoded['policy'] is! Map) {
      throw const FormatException('Split tunneling backup is invalid.');
    }
    return SplitTunnelPolicy.fromJson(
      Map<String, Object?>.from(decoded['policy'] as Map),
    );
  }

  factory SplitTunnelPolicy.fromJson(Map<String, Object?> json) {
    final mode = SplitTunnelMode.values.byName(json['mode']! as String);
    final packages = json['packageNames'];
    if (packages is! List<Object?> ||
        packages.any((value) => value is! String)) {
      throw const FormatException('Split tunneling package list is invalid.');
    }
    return SplitTunnelPolicy(
      mode: mode,
      packageNames: packages.cast<String>().toSet(),
    );
  }

  void validateInstalledPackages(Set<String> installedPackages) {
    if (!installedPackages.containsAll(packageNames)) {
      throw ArgumentError(
        'Split tunneling contains applications that are not installed.',
      );
    }
  }
}
