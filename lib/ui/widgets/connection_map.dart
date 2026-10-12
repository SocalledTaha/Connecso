import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/connection_map_state.dart';
import '../../domain/models/connection_state.dart';
import '../../domain/models/map_projection.dart';
import '../../domain/services/location_resolver.dart';

const _destinationZoom = 6.2;

class ConnectionMap extends StatefulWidget {
  const ConnectionMap({
    required this.phase,
    this.destination,
    this.destinationLabel,
    this.destinationTextDirection = TextDirection.ltr,
    this.height = 158,
    super.key,
  });

  final ConnectionPhase phase;
  final DestinationLocation? destination;
  final String? destinationLabel;
  final TextDirection destinationTextDirection;
  final double height;

  @override
  State<ConnectionMap> createState() => _ConnectionMapState();
}

class _ConnectionMapState extends State<ConnectionMap>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  late final AnimationController _focus = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );
  List<_MapCountry> _countries = const [];
  DestinationLocation? _transitionFrom;
  DestinationLocation? _verifiedDestination;
  DestinationLocation? _departingDestination;
  DestinationLocation? _cameraDestination;
  bool _disableMotion = false;

  @override
  void initState() {
    super.initState();
    if (widget.phase == ConnectionPhase.connected) {
      _focus.value = 1;
      _verifiedDestination = widget.destination;
      _cameraDestination = widget.destination;
    }
    _focus.addStatusListener(_onFocusStatus);
    _loadMap();
  }

  Future<void> _loadMap() async {
    try {
      final source = await rootBundle.loadString(
        'assets/maps/world_simplified.geojson',
      );
      final data = jsonDecode(source) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>;
      final countries = features
          .map(
            (feature) => _MapCountry.fromJson(feature as Map<String, dynamic>),
          )
          .where((country) => country.paths.isNotEmpty)
          .toList(growable: false);
      if (mounted) setState(() => _countries = countries);
    } catch (_) {
      // A missing/corrupt decorative asset must not affect VPN connectivity.
    }
  }

  void _onFocusStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _transitionFrom = null;
      _syncPulse();
      if (mounted) setState(() {});
    } else if (status == AnimationStatus.dismissed) {
      _transitionFrom = null;
      _cameraDestination = null;
      _departingDestination = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced == _disableMotion) {
      _syncPulse();
      return;
    }
    _disableMotion = reduced;
    if (reduced) {
      _focus.stop();
      _focus.value = widget.phase == ConnectionPhase.connected ? 1 : 0;
      _pulse
        ..stop()
        ..value = 0;
    } else {
      _syncPulse();
    }
  }

  @override
  void didUpdateWidget(covariant ConnectionMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newConnected = widget.phase == ConnectionPhase.connected;
    final oldConnected = oldWidget.phase == ConnectionPhase.connected;
    final changedDestination = !_sameLocation(
      oldWidget.destination,
      widget.destination,
    );

    if (newConnected && (!oldConnected || changedDestination)) {
      final previouslyVerified = _verifiedDestination;
      _departingDestination = null;
      _transitionFrom =
          oldWidget.phase == ConnectionPhase.reconnecting || oldConnected
          ? previouslyVerified
          : null;
      _verifiedDestination = widget.destination;
      _cameraDestination = widget.destination;
      if (_disableMotion) {
        _focus.value = 1;
      } else {
        _focus.forward(from: 0);
      }
    } else if (widget.phase == ConnectionPhase.reconnecting) {
      // Hold the last viewport while finding and verifying a replacement.
      _focus.stop();
      _pulse
        ..stop()
        ..value = 0;
      // Keep the previous camera framing while SmartSelector finds and
      // verifies a replacement node.
    } else if (widget.phase == ConnectionPhase.disconnecting ||
        (widget.phase == ConnectionPhase.disconnected &&
            oldWidget.phase == ConnectionPhase.disconnecting)) {
      _departingDestination ??= _verifiedDestination;
      _verifiedDestination = null;
      _pulse
        ..stop()
        ..value = 0;
      if (_disableMotion) {
        _focus.value = 0;
      } else {
        _focus.reverse();
      }
    } else if (widget.phase == ConnectionPhase.disconnected ||
        widget.phase == ConnectionPhase.noProfile ||
        widget.phase == ConnectionPhase.failed) {
      _verifiedDestination = null;
      _departingDestination = null;
      _pulse
        ..stop()
        ..value = 0;
      if (_disableMotion) {
        _focus.value = 0;
      } else {
        _focus.reverse();
      }
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
    _syncPulse();
  }

  bool _sameLocation(DestinationLocation? a, DestinationLocation? b) =>
      a?.countryCode == b?.countryCode &&
      a?.country == b?.country &&
      a?.city == b?.city &&
      a?.latitude == b?.latitude &&
      a?.longitude == b?.longitude;

  void _syncPulse() {
    final active =
        widget.phase == ConnectionPhase.connected &&
        _pointFor(widget.destination) != null &&
        _focus.status == AnimationStatus.completed &&
        !_disableMotion;
    if (active) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  Offset? _pointFor(DestinationLocation? location) {
    if (location == null) return null;
    final country = _findCountry(location);
    // Keep the visual destination anchored to the resolved country geometry.
    // City metadata can be approximate or use a different coordinate source;
    // the country label is the stable point shared by map and popup.
    if (country != null) return country.label;
    if (location.hasCity && location.hasCoordinates) {
      return Offset(location.longitude!, location.latitude!);
    }
    return null;
  }

  _MapCountry? _findCountry(DestinationLocation? location) {
    if (location == null) return null;
    for (final country in _countries) {
      if (location.countryCode.isNotEmpty &&
          country.code.toUpperCase() == location.countryCode.toUpperCase()) {
        return country;
      }
      if (country.name.toLowerCase() == location.country.toLowerCase()) {
        return country;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _focus.removeStatusListener(_onFocusStatus);
    _pulse.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final destination = _verifiedDestination ?? _departingDestination;
    final mapState =
        _departingDestination != null && widget.phase != ConnectionPhase.failed
        ? ConnectionMapState.returningToWorld
        : mapStateFor(
            widget.phase,
            settled: _focus.status == AnimationStatus.completed,
          );
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0, .06, .94, 1],
          ).createShader(bounds),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [.06, .92, 1],
            ).createShader(bounds),
            child: AnimatedBuilder(
              animation: _focus,
              builder: (context, _) {
                final progress = Curves.easeInOutCubic.transform(_focus.value);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _WorldPainter(
                          countries: _countries,
                          state: mapState,
                          destination: destination,
                          fromPoint: _pointFor(_transitionFrom),
                          toPoint: _pointFor(destination),
                          progress: progress,
                          land: dark
                              ? const Color(0xFF174B73).withValues(alpha: .60)
                              : const Color(0xFFB7D4E5).withValues(alpha: .30),
                          outline: dark
                              ? const Color(0xFF3DB7E8).withValues(alpha: .36)
                              : const Color(0xFF397C9B).withValues(alpha: .82),
                          atmosphere: dark
                              ? const Color(0xFF168AC2)
                              : const Color(0xFF78B7D1),
                          ocean: dark
                              ? const Color(0xFF061A2A).withValues(alpha: .38)
                              : const Color(0xFFDCECF3).withValues(alpha: .72),
                          connected: const Color(0xFF31D393),
                          failed: scheme.error,
                          simplified:
                              widget.phase == ConnectionPhase.disconnected ||
                              widget.phase == ConnectionPhase.noProfile,
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: Listenable.merge([_pulse, _focus]),
                      builder: (context, _) => RepaintBoundary(
                        child: CustomPaint(
                          foregroundPainter: _DestinationMarkerPainter(
                            state: mapState,
                            destination: destination,
                            fromPoint: _pointFor(_transitionFrom),
                            toPoint: _pointFor(destination),
                            destinationPoint: _pointFor(destination),
                            progress: Curves.easeInOutCubic.transform(
                              _focus.value,
                            ),
                            pulse: _pulse.value,
                            marker: const Color(0xFF31D393),
                            label: widget.destinationLabel,
                            textDirection: widget.destinationTextDirection,
                            labelColor: scheme.onSurface,
                            labelSurface: scheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MapCountry {
  const _MapCountry({
    required this.name,
    required this.code,
    required this.label,
    required this.paths,
  });

  final String name;
  final String code;
  final Offset label;
  final List<Path> paths;

  factory _MapCountry.fromJson(Map<String, dynamic> json) {
    final properties = json['properties'] as Map<String, dynamic>;
    final geometry = json['geometry'] as Map<String, dynamic>;
    final rings = geometry['coordinates'] as List<dynamic>;
    final rawLabel = (properties['label'] as List<dynamic>?) ?? const [0, 0];
    final labelLongitude = (rawLabel[0] as num).toDouble();
    final labelLatitude = (rawLabel[1] as num).toDouble();
    final isAfrica =
        labelLongitude >= -20 &&
        labelLongitude <= 55 &&
        labelLatitude >= -35 &&
        labelLatitude <= 30;
    final isSouthAmerica =
        labelLongitude >= -85 &&
        labelLongitude <= -30 &&
        labelLatitude >= -58 &&
        labelLatitude <= 15;
    final paths = <Path>[];
    for (final rawRing in rings) {
      final coordinates = _simplifyRing(
        (rawRing as List<dynamic>)
            .cast<List<dynamic>>()
            .map(
              (point) => Offset(
                (point[0] as num).toDouble(),
                (point[1] as num).toDouble(),
              ),
            )
            .toList(growable: false),
        isAfrica || isSouthAmerica ? 0.38 : 0.0,
      );
      if (coordinates.length < 4) continue;
      final path = Path()..fillType = PathFillType.evenOdd;
      var previousLongitude = coordinates.first.dx;
      var unwrappedLongitude = previousLongitude;
      path.moveTo(unwrappedLongitude + 180, 90 - coordinates.first.dy);
      var minX = unwrappedLongitude;
      var maxX = unwrappedLongitude;
      for (var index = 1; index < coordinates.length; index++) {
        final point = coordinates[index];
        var longitude = point.dx;
        final delta = longitude - previousLongitude;
        if (delta > 180) longitude -= 360;
        if (delta < -180) longitude += 360;
        unwrappedLongitude += longitude - previousLongitude;
        previousLongitude = point.dx;
        minX = math.min(minX, unwrappedLongitude);
        maxX = math.max(maxX, unwrappedLongitude);
        path.lineTo(unwrappedLongitude + 180, 90 - point.dy);
      }
      path.close();
      paths.add(path);
      if (minX < -180) {
        paths.add(path.shift(const Offset(360, 0)));
      } else if (maxX > 180) {
        paths.add(path.shift(const Offset(-360, 0)));
      }
    }
    return _MapCountry(
      name: (properties['country'] as String? ?? '')
          .replaceAll('\u0000', '')
          .trim(),
      code: (properties['countryCode'] as String? ?? '')
          .replaceAll('\u0000', '')
          .trim(),
      label: Offset(labelLongitude, labelLatitude),
      paths: paths,
    );
  }

  static List<Offset> _simplifyRing(List<Offset> points, double tolerance) {
    if (points.length < 5) return points;
    final squaredTolerance = tolerance * tolerance;
    final keep = List<bool>.filled(points.length, false)..[0] = true;
    keep[points.length - 1] = true;

    void simplify(int first, int last) {
      var maxDistance = squaredTolerance;
      var split = -1;
      final a = points[first];
      final b = points[last];
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      for (var i = first + 1; i < last; i++) {
        final p = points[i];
        final distance = dx == 0 && dy == 0
            ? (p - a).distanceSquared
            : _segmentDistanceSquared(p, a, b, dx, dy);
        if (distance > maxDistance) {
          maxDistance = distance;
          split = i;
        }
      }
      if (split >= 0) {
        keep[split] = true;
        simplify(first, split);
        simplify(split, last);
      }
    }

    simplify(0, points.length - 1);
    final result = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      if (keep[i]) result.add(points[i]);
    }
    return result.length >= 4 ? result : points;
  }

  static double _segmentDistanceSquared(
    Offset p,
    Offset a,
    Offset b,
    double dx,
    double dy,
  ) {
    final t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / (dx * dx + dy * dy);
    final clamped = t.clamp(0.0, 1.0);
    final x = a.dx + clamped * dx;
    final y = a.dy + clamped * dy;
    final ox = p.dx - x;
    final oy = p.dy - y;
    return ox * ox + oy * oy;
  }
}

class _WorldPainter extends CustomPainter {
  const _WorldPainter({
    required this.countries,
    required this.state,
    required this.destination,
    required this.fromPoint,
    required this.toPoint,
    required this.progress,
    required this.land,
    required this.outline,
    required this.connected,
    required this.failed,
    required this.atmosphere,
    required this.ocean,
    required this.simplified,
  });

  final List<_MapCountry> countries;
  final ConnectionMapState state;
  final DestinationLocation? destination;
  final Offset? fromPoint;
  final Offset? toPoint;
  final double progress;
  final Color land;
  final Color outline;
  final Color connected;
  final Color failed;
  final Color atmosphere;
  final Color ocean;
  final bool simplified;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final viewport = MapViewport.interpolate(
      size: size,
      fromLocation: fromPoint,
      toLocation: toPoint,
      progress: progress,
      destinationZoom: _destinationZoom,
      destinationOffsetFactor: 0,
    );
    // Keep longitude and latitude at the same visual scale. This preserves
    // geographic proportions while the scene is framed around a destination.
    final lineScale = viewport.scale;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Ocean overscan belongs to the full-screen canvas, not the geographic
    // projection. This lets the background continue beyond the northern and
    // southern world bounds without altering any country geometry.
    canvas.drawRect(Offset.zero & size, Paint()..color = ocean);
    viewport.apply(canvas);
    canvas.translate(0, -size.height * .025);
    // In the neutral world view keep the geographic layer visually below the
    // header/secondary action. Destination-focused views retain their normal
    // camera anchor and are not shifted.
    // Only the return-to-world path uses the lower neutral anchor. A fresh
    // connection may start without a destination, but must not inherit this
    // offset while zooming toward its destination.
    final worldAnchorProgress = toPoint == null ? (1 - progress) : 0.0;
    if (worldAnchorProgress > 0) {
      canvas.translate(0, size.height * .0 * worldAnchorProgress);
    }
    if (fromPoint == null && toPoint == null) {
      // The viewport remains full-screen; enlarge only the neutral world
      // artwork so continents continue behind the power area.
      final center = Offset(size.width / 2, size.height * .50);
      canvas.translate(center.dx, center.dy);
      // Keep the complete world recognizable while filling the available
      // width; use a uniform scale so no geographic dimension is distorted.
      canvas.scale(1.38, 1.38);
      canvas.translate(-center.dx, -center.dy);
    }

    final outlinePaint = Paint()
      ..color = state == ConnectionMapState.failed
          ? failed.withValues(alpha: .27)
          : outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55 / lineScale;
    final landPaint = Paint()..color = land;
    final destinationCode = destination?.countryCode.trim().toUpperCase();
    final destinationName = destination?.country.trim().toLowerCase();
    final showDestinationHighlight =
        (state == ConnectionMapState.connected ||
            state == ConnectionMapState.zoomingToDestination) &&
        destination != null;
    final highlightPaint = Paint()..color = connected.withValues(alpha: .28);
    for (final country in countries) {
      // The Antarctic landmass consumes map space without helping users
      // understand a VPN exit destination.
      if (country.name.toLowerCase() == 'antarctica') continue;
      final isDestination =
          showDestinationHighlight &&
          ((destinationCode?.isNotEmpty == true &&
                  country.code.toUpperCase() == destinationCode) ||
              (destinationName?.isNotEmpty == true &&
                  country.name.toLowerCase() == destinationName));
      for (final path in country.paths) {
        canvas.drawPath(path, isDestination ? highlightPaint : landPaint);
        canvas.drawPath(path, outlinePaint);
      }
    }

    // A soft center bloom keeps the geographic layer readable in the middle
    // while the surrounding map remains subdued by the outer ShaderMasks.
    final center = Offset(size.width / 2, size.height * .48);
    final bloom = Paint()
      ..shader =
          RadialGradient(
            colors: [atmosphere.withValues(alpha: .12), Colors.transparent],
            stops: const [.05, 1],
          ).createShader(
            Rect.fromCircle(center: center, radius: size.shortestSide * .62),
          );
    canvas.drawCircle(center, size.shortestSide * .62, bloom);

    canvas.restore();
  }

  bool _isAfrica(Offset point) =>
      point.dx >= -20 && point.dx <= 55 && point.dy >= -35 && point.dy <= 30;

  bool _isOceania(Offset point) =>
      point.dx >= 110 && point.dx <= 180 && point.dy >= -50 && point.dy <= 5;

  @override
  bool shouldRepaint(covariant _WorldPainter oldDelegate) =>
      oldDelegate.countries != countries ||
      oldDelegate.state != state ||
      oldDelegate.destination != destination ||
      oldDelegate.fromPoint != fromPoint ||
      oldDelegate.toPoint != toPoint ||
      oldDelegate.progress != progress ||
      oldDelegate.land != land ||
      oldDelegate.outline != outline ||
      oldDelegate.connected != connected ||
      oldDelegate.failed != failed ||
      oldDelegate.atmosphere != atmosphere ||
      oldDelegate.ocean != ocean ||
      oldDelegate.simplified != simplified;
}

class _DestinationMarkerPainter extends CustomPainter {
  const _DestinationMarkerPainter({
    required this.state,
    required this.destination,
    required this.fromPoint,
    required this.toPoint,
    required this.destinationPoint,
    required this.progress,
    required this.pulse,
    required this.marker,
    required this.label,
    required this.textDirection,
    required this.labelColor,
    required this.labelSurface,
  });

  final ConnectionMapState state;
  final DestinationLocation? destination;
  final Offset? fromPoint;
  final Offset? toPoint;
  final Offset? destinationPoint;
  final double progress;
  final double pulse;
  final Color marker;
  final String? label;
  final TextDirection textDirection;
  final Color labelColor;
  final Color labelSurface;

  @override
  void paint(Canvas canvas, Size size) {
    final location = destination;
    // Confirmed destination visuals are only allowed while the authoritative
    // connection phase is Connected (including its settling zoom frame).
    // Reconnecting, disconnecting, failed and disconnected states must not
    // present the old exit as an active destination.
    if (location == null ||
        (state != ConnectionMapState.connected &&
            state != ConnectionMapState.zoomingToDestination)) {
      return;
    }
    final viewport = MapViewport.interpolate(
      size: size,
      fromLocation: fromPoint,
      toLocation: toPoint,
      progress: progress,
      destinationZoom: _destinationZoom,
      destinationOffsetFactor: 0,
    );
    canvas.translate(0, -size.height * .025);
    // Use the resolved destination point regardless of whether it came from
    // city coordinates or the country's fallback label point.
    if (destinationPoint == null) return;
    final point = destinationPoint!;
    final screenPoint = viewport.projectLocation(point);
    if (!screenPoint.dx.isFinite || !screenPoint.dy.isFinite) return;
    final alpha = state == ConnectionMapState.reconnecting
        ? .48
        : state == ConnectionMapState.returningToWorld
        ? progress
        : state == ConnectionMapState.zoomingToDestination
        ? ((progress - .68) / .32).clamp(0, 1).toDouble()
        : 1.0;
    final radius = 3.2;
    // Country-level destinations still have a deterministic map label point;
    // use it for the marker when city coordinates are unavailable.
    if (destinationPoint != null) {
      final pulseValue = state == ConnectionMapState.connected
          ? pulse
          : (state == ConnectionMapState.reconnecting ? .35 : 0);
      // Layered radar rings provide the destination focus without lighting up
      // the entire country polygon.
      for (var ring = 1; ring <= 3; ring++) {
        final ringProgress = (pulseValue + (ring - 1) / 3) % 1.0;
        canvas.drawCircle(
          screenPoint,
          8 + ringProgress * 26,
          Paint()
            ..color = marker.withValues(alpha: (1 - ringProgress) * .22 * alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
      canvas.drawCircle(
        screenPoint,
        18 + pulseValue * 9,
        Paint()
          ..shader = RadialGradient(
            colors: [
              marker.withValues(alpha: .40 * alpha),
              marker.withValues(alpha: .10 * alpha),
              Colors.transparent,
            ],
            stops: const [.05, .35, 1],
          ).createShader(Rect.fromCircle(center: screenPoint, radius: 28)),
      );
      canvas.drawCircle(
        screenPoint,
        radius + 5,
        Paint()..color = marker.withValues(alpha: .26 * alpha),
      );
      canvas.drawCircle(
        screenPoint,
        radius,
        Paint()..color = marker.withValues(alpha: .95 * alpha),
      );
      canvas.drawCircle(
        screenPoint,
        1.7,
        Paint()..color = Colors.white.withValues(alpha: .98 * alpha),
      );
      canvas.drawCircle(
        screenPoint,
        radius + 5,
        Paint()
          ..color = marker.withValues(alpha: .32 * (1 - pulse) * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final markerLabel = label;
    if (markerLabel != null && markerLabel.isNotEmpty) {
      final text = TextPainter(
        text: TextSpan(
          text: markerLabel,
          style: TextStyle(
            color: labelColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ).copyWith(color: labelColor.withValues(alpha: alpha)),
        ),
        textDirection: textDirection,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width * .55);
      final gap = 12.0;
      final pillWidth = text.width + gap * 2;
      final pillHeight = text.height + 9;
      final pill = Rect.fromLTWH(
        (screenPoint.dx - pillWidth / 2).clamp(6, size.width - pillWidth - 6),
        (screenPoint.dy - radius - pillHeight - 18).clamp(
          6,
          size.height - pillHeight - 6,
        ),
        pillWidth,
        pillHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, const Radius.circular(12)),
        Paint()
          ..color = Colors.black.withValues(
            alpha: darken(labelSurface) * .18 * alpha,
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, const Radius.circular(12)),
        Paint()
          ..color = labelSurface.withValues(alpha: .84 * alpha)
          ..style = PaintingStyle.fill
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, const Radius.circular(12)),
        Paint()
          ..color = marker.withValues(alpha: .34 * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7,
      );
      text.paint(canvas, Offset(pill.left + gap, pill.top + 4.5));
    }
  }

  @override
  bool shouldRepaint(covariant _DestinationMarkerPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.destination != destination ||
      oldDelegate.fromPoint != fromPoint ||
      oldDelegate.toPoint != toPoint ||
      oldDelegate.destinationPoint != destinationPoint ||
      oldDelegate.progress != progress ||
      oldDelegate.pulse != pulse ||
      oldDelegate.marker != marker ||
      oldDelegate.label != label ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.labelColor != labelColor ||
      oldDelegate.labelSurface != labelSurface;
}

double darken(Color color) => color.computeLuminance() < .5 ? 1 : .65;
