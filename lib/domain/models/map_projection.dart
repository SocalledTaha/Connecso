import 'package:flutter/widgets.dart';

/// Equirectangular world projection for a decorative, non-interactive map.
class MapProjection {
  const MapProjection._();

  static Offset toMapPlane(double latitude, double longitude) => Offset(
    longitude.clamp(-180, 180).toDouble() + 180,
    90 - latitude.clamp(-90, 90).toDouble(),
  );

  static Offset toUnit(double latitude, double longitude) => Offset(
    ((longitude.clamp(-180, 180) + 180) / 360).toDouble(),
    ((90 - latitude.clamp(-90, 90)) / 180).toDouble(),
  );

  static Offset toScreen({
    required double latitude,
    required double longitude,
    required Size size,
  }) {
    final unit = toUnit(latitude, longitude);
    return Offset(unit.dx * size.width, unit.dy * size.height);
  }
}

/// Shared camera and geographic-to-screen transform for map geometry/markers.
/// Locations are passed as `(longitude, latitude)` offsets.
class MapViewport {
  const MapViewport._({
    required this.size,
    required this.zoom,
    required this.camera,
  });

  final Size size;
  final double zoom;
  final Offset camera;

  double get scale => size.width / 360 * zoom;

  factory MapViewport.interpolate({
    required Size size,
    required Offset? fromLocation,
    required Offset? toLocation,
    required double progress,
    required double destinationZoom,
    double destinationOffsetFactor = .20,
  }) {
    final t = progress.clamp(0.0, 1.0).toDouble();
    final worldCenter = const Offset(0, 0); // longitude, latitude
    final start = fromLocation ?? worldCenter;
    final end = toLocation ?? worldCenter;
    final zoom = _lerp(
      fromLocation == null ? 1 : destinationZoom,
      toLocation == null ? 1 : destinationZoom,
      t,
    );
    final destinationOffset = size.width == 0
        ? 0.0
        : size.height *
              destinationOffsetFactor /
              (size.width / 360 * destinationZoom);
    final startOffset = fromLocation == null ? 0.0 : destinationOffset;
    final endOffset = toLocation == null ? 0.0 : destinationOffset;
    final longitude = _lerp(start.dx, end.dx, t);
    final latitude = _lerp(start.dy - startOffset, end.dy - endOffset, t);
    return MapViewport._(
      size: size,
      zoom: zoom,
      camera: MapProjection.toMapPlane(latitude, longitude),
    );
  }

  Offset projectMapPlane(Offset point) {
    final center = Offset(size.width / 2, size.height / 2);
    return center + (point - camera) * scale;
  }

  Offset projectLocation(Offset longitudeLatitude) => projectMapPlane(
    MapProjection.toMapPlane(longitudeLatitude.dy, longitudeLatitude.dx),
  );

  /// Applies the same geographic transform used by [projectMapPlane].
  void apply(Canvas canvas) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.translate(
      center.dx - camera.dx * scale,
      center.dy - camera.dy * scale,
    );
    canvas.scale(scale, scale);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
