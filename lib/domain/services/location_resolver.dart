import '../models/vpn_node.dart';
import 'country_lookup.dart';

class DestinationLocation {
  const DestinationLocation({
    required this.country,
    required this.countryCode,
    required this.city,
    required this.latitude,
    required this.longitude,
    required this.source,
    required this.confidence,
  });

  final String country;
  final String countryCode;
  final String city;
  final double? latitude;
  final double? longitude;
  final LocationSource source;
  final double confidence;

  bool get hasCity => city.isNotEmpty;
  bool get hasCoordinates => latitude != null && longitude != null;
}

/// Resolves only VPN exit metadata. This service never reads device location.
class LocationResolver {
  const LocationResolver();

  static DestinationLocation? forCountryCode(String? value) {
    final code = canonicalCountryCode(value);
    if (code.isEmpty) return null;
    for (final location in cities) {
      if (location.countryCode == code) return location;
    }
    return null;
  }

  /// Canonical ISO-3166 alpha-2 code for metadata or a server display name.
  static String canonicalCountryCode(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '';
    return _countryForCode(text)?.code.toUpperCase() ??
        _matchCountry(text)?.code.toUpperCase() ??
        '';
  }

  static String flagForCode(String? value) {
    final code = canonicalCountryCode(value);
    if (code.length != 2) return '🌐';
    return String.fromCharCodes(
      code.codeUnits.map((unit) => 0x1F1E6 + unit - 65),
    );
  }

  static const cities = <DestinationLocation>[
    DestinationLocation(
      country: 'Germany',
      countryCode: 'DE',
      city: 'Frankfurt',
      latitude: 50.1109,
      longitude: 8.6821,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Netherlands',
      countryCode: 'NL',
      city: 'Amsterdam',
      latitude: 52.3676,
      longitude: 4.9041,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'United Kingdom',
      countryCode: 'GB',
      city: 'London',
      latitude: 51.5072,
      longitude: -.1276,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'France',
      countryCode: 'FR',
      city: 'Paris',
      latitude: 48.8566,
      longitude: 2.3522,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Turkey',
      countryCode: 'TR',
      city: 'Istanbul',
      latitude: 41.0082,
      longitude: 28.9784,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'United States',
      countryCode: 'US',
      city: 'New York',
      latitude: 40.7128,
      longitude: -74.006,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Italy',
      countryCode: 'IT',
      city: 'Milan',
      latitude: 45.4642,
      longitude: 9.19,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Poland',
      countryCode: 'PL',
      city: 'Warsaw',
      latitude: 52.2297,
      longitude: 21.0122,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Finland',
      countryCode: 'FI',
      city: 'Helsinki',
      latitude: 60.1699,
      longitude: 24.9384,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Japan',
      countryCode: 'JP',
      city: 'Tokyo',
      latitude: 35.6762,
      longitude: 139.6503,
      source: LocationSource.database,
      confidence: .65,
    ),
    DestinationLocation(
      country: 'Canada',
      countryCode: 'CA',
      city: 'Toronto',
      latitude: 43.6532,
      longitude: -79.3832,
      source: LocationSource.database,
      confidence: .65,
    ),
  ];

  static final countryNamesByCode = _countryNamesByCode();
  static final countryCodesByName = _countryCodesByName();

  DestinationLocation? resolve(VpnNode node) {
    final rawCountryCode = node.countryCode?.trim() ?? '';
    final rawCountry = node.country?.trim() ?? '';
    final countryReference =
        _countryForCode(rawCountryCode) ??
        (rawCountry.isEmpty ? null : _matchCountry(rawCountry));
    final countryCode =
        countryReference?.code.toUpperCase() ?? rawCountryCode.toUpperCase();
    final country = countryReference?.displayName ?? rawCountry;

    // Explicit subscription coordinates take priority and are not rewritten.
    if (node.latitude != null && node.longitude != null) {
      return DestinationLocation(
        country: country.isEmpty ? 'Unknown' : country,
        countryCode: countryCode,
        city: node.city?.trim() ?? '',
        latitude: node.latitude,
        longitude: node.longitude,
        source: node.locationSource,
        confidence: node.locationConfidence,
      );
    }

    if (node.locationSource == LocationSource.subscription &&
        (country.isNotEmpty || node.city?.trim().isNotEmpty == true)) {
      return DestinationLocation(
        country: country.isEmpty ? 'Unknown' : country,
        countryCode: countryCode.isEmpty
            ? countryReference?.code ?? countryCodesByName[country] ?? ''
            : countryCode,
        city: node.city?.trim() ?? '',
        latitude: null,
        longitude: null,
        source: LocationSource.subscription,
        confidence: node.locationConfidence,
      );
    }

    // Normalized city metadata may use the bundled database, but country-only
    // metadata stays country-only. No city is fabricated from a country.
    final query = '${node.city ?? ''} ${node.name}';
    for (final known in cities) {
      if (_containsWholePhrase(query, known.city)) {
        return DestinationLocation(
          country: country.isEmpty ? known.country : country,
          countryCode: countryCode.isEmpty
              ? countryReference?.code ?? known.countryCode
              : countryCode,
          city: known.city,
          latitude: known.latitude,
          longitude: known.longitude,
          source: node.city?.trim().isNotEmpty == true
              ? node.locationSource
              : LocationSource.database,
          confidence: node.city?.trim().isNotEmpty == true
              ? node.locationConfidence
              : known.confidence,
        );
      }
    }

    if (country.isNotEmpty) {
      return DestinationLocation(
        country: country,
        countryCode: countryCode.isEmpty
            ? countryReference?.code ?? countryCodesByName[country] ?? ''
            : countryCode,
        city: '',
        latitude: null,
        longitude: null,
        source: node.locationSource == LocationSource.unknown
            ? LocationSource.serverMetadata
            : node.locationSource,
        confidence: node.locationConfidence > 0 ? node.locationConfidence : .75,
      );
    }

    // Infer a country and its bundled map label center from the connection
    // name only when exactly one distinct country is present. This never
    // invents a city; contradictory or multi-country labels remain unresolved.
    final inferred = _matchCountry(node.name);
    if (inferred == null) return null;
    return DestinationLocation(
      country: inferred.displayName,
      countryCode: inferred.code,
      city: '',
      latitude: inferred.latitude,
      longitude: inferred.longitude,
      source: LocationSource.serverMetadata,
      confidence: .55,
    );
  }

  static CountryReference? _countryForCode(String code) {
    if (code.isEmpty) return null;
    final normalized = _normalize(code);
    for (final country in offlineCountries) {
      if (country.code.toUpperCase() == code.toUpperCase()) return country;
      if ((countryAliasesByCode[country.code] ?? const []).any(
        (alias) => _normalize(alias) == normalized,
      )) {
        return country;
      }
    }
    return null;
  }

  static CountryReference? _matchCountry(String input) {
    final normalized = _normalize(input);
    if (normalized.isEmpty) return null;
    final candidates = <_CountryMatch>[];

    for (final country in offlineCountries) {
      final variants = <String>{
        country.name,
        country.displayName,
        if (country.code.length == 2) country.code,
        ...?countryAliasesByCode[country.code],
      };
      for (final variant in variants) {
        final phrase = _normalize(variant);
        if (phrase.isEmpty) continue;
        final expression = RegExp(r'(^| )' + RegExp.escape(phrase) + r'( |$)');
        for (final match in expression.allMatches(normalized)) {
          final start = match.start + (match.group(1)?.length ?? 0);
          final end = match.end - (match.group(2)?.length ?? 0);
          candidates.add(_CountryMatch(country, start, end));
        }
      }
    }

    // Prefer a longer complete country phrase over a shorter name contained
    // within it (for example, Guinea within Guinea-Bissau).
    final maximal = candidates.where((candidate) {
      return !candidates.any(
        (other) =>
            other.country.code != candidate.country.code &&
            other.start <= candidate.start &&
            other.end >= candidate.end &&
            other.end - other.start > candidate.end - candidate.start,
      );
    });
    final byCode = <String, CountryReference>{};
    for (final match in maximal) {
      byCode.putIfAbsent(match.country.code, () => match.country);
    }
    if (byCode.length == 1) return byCode.values.first;

    // Some providers prefix the country label (for example XNetherlands).
    // If the normal whole-phrase match did not resolve it, accept a unique
    // longest country token contained in the normalized label. This keeps
    // aliases such as NL-1 and XNetherlands in the same country group.
    final contained = <String, CountryReference>{};
    var longest = 0;
    for (final country in offlineCountries) {
      final variants = <String>{
        country.name,
        country.displayName,
        ...?countryAliasesByCode[country.code],
      };
      for (final variant in variants) {
        final phrase = _normalize(variant);
        if (phrase.length < 4 || !normalized.contains(phrase)) continue;
        if (phrase.length > longest) {
          contained
            ..clear()
            ..[country.code] = country;
          longest = phrase.length;
        } else if (phrase.length == longest) {
          contained[country.code] = country;
        }
      }
    }
    return contained.length == 1 ? contained.values.first : null;
  }

  static Map<String, String> _countryNamesByCode() {
    final result = <String, String>{};
    for (final country in offlineCountries) {
      if (country.code.isNotEmpty) {
        result.putIfAbsent(
          country.code.toUpperCase(),
          () => country.displayName,
        );
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<String, String> _countryCodesByName() {
    final result = <String, String>{};
    for (final country in offlineCountries) {
      if (country.code.isNotEmpty) {
        result.putIfAbsent(_normalize(country.name), () => country.code);
        result.putIfAbsent(_normalize(country.displayName), () => country.code);
        for (final alias in countryAliasesByCode[country.code] ?? const []) {
          result.putIfAbsent(_normalize(alias), () => country.code);
        }
      }
    }
    return Map.unmodifiable(result);
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  bool _containsWholePhrase(String source, String phrase) {
    final normalizedSource = _normalize(source);
    final normalizedPhrase = _normalize(phrase);
    if (normalizedPhrase.isEmpty) return false;
    return RegExp(
      r'(^| )' + RegExp.escape(normalizedPhrase) + r'( |$)',
    ).hasMatch(normalizedSource);
  }
}

class _CountryMatch {
  const _CountryMatch(this.country, this.start, this.end);

  final CountryReference country;
  final int start;
  final int end;
}
