import 'dart:convert';
import 'dart:io';

class SourceCountryResolver {
  const SourceCountryResolver();

  Future<String?> resolve() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('https://ipwho.is/'));
      final response = await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final code = json['country_code'];
      return code is String && code.length == 2 ? code.toUpperCase() : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
