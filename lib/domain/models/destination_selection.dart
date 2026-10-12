import 'connection_method.dart';

enum DestinationMode { auto, countryLocked }

class DestinationSelection {
  const DestinationSelection.auto({this.method})
    : mode = DestinationMode.auto,
      countryCode = null;
  const DestinationSelection.country(this.countryCode, {this.method})
    : mode = DestinationMode.countryLocked;

  final DestinationMode mode;
  final String? countryCode;
  final ConnectionMethod? method;

  DestinationSelection copyWith({ConnectionMethod? method}) {
    return mode == DestinationMode.auto
        ? DestinationSelection.auto(method: method)
        : DestinationSelection.country(countryCode!, method: method);
  }

  bool get isAuto => mode == DestinationMode.auto;
}
