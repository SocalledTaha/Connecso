import 'connection_method.dart';

enum DestinationMode { auto, countryLocked }

class DestinationSelection {
  const DestinationSelection.auto({this.method, this.nodeId})
    : mode = DestinationMode.auto,
      countryCode = null;
  const DestinationSelection.country(
    this.countryCode, {
    this.method,
    this.nodeId,
  }) : mode = DestinationMode.countryLocked;

  final DestinationMode mode;
  final String? countryCode;
  final ConnectionMethod? method;
  final String? nodeId;

  DestinationSelection copyWith({ConnectionMethod? method, String? nodeId}) {
    return mode == DestinationMode.auto
        ? DestinationSelection.auto(
            method: method,
            nodeId: nodeId ?? this.nodeId,
          )
        : DestinationSelection.country(
            countryCode!,
            method: method,
            nodeId: nodeId ?? this.nodeId,
          );
  }

  bool get isAuto => mode == DestinationMode.auto;
}
