import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _debugDots = bool.fromEnvironment(
  'CONNECSO_MAP_DOTS',
  defaultValue: false,
);
const _debugRadar = bool.fromEnvironment(
  'CONNECSO_MAP_RADAR',
  defaultValue: true,
);
const _debugCountryGlow = bool.fromEnvironment(
  'CONNECSO_COUNTRY_GLOW',
  defaultValue: true,
);
const _debugTexture = bool.fromEnvironment(
  'CONNECSO_MAP_TEXTURE',
  defaultValue: false,
);
const _debugAtmosphere = bool.fromEnvironment(
  'CONNECSO_MAP_ATMOSPHERE',
  defaultValue: false,
);

class GlobeTarget {
  const GlobeTarget(this.name, this.lat, this.lon);
  final String name;
  final double lat, lon;
}

const _iranFocus = GlobeTarget('Iran', 32.4, 53.7);

const _oceanLabels = <GlobeTarget>[
  GlobeTarget('PACIFIC OCEAN', 0, -150),
  GlobeTarget('ATLANTIC OCEAN', 18, -35),
  GlobeTarget('INDIAN OCEAN', -20, 78),
  GlobeTarget('ARCTIC OCEAN', 74, 20),
  GlobeTarget('SOUTHERN OCEAN', -58, 20),
  GlobeTarget('MEDITERRANEAN SEA', 35, 18),
  GlobeTarget('ARABIAN SEA', 15, 64),
  GlobeTarget('PERSIAN GULF', 26.3, 52.0),
  GlobeTarget('NORTH SEA', 56, 3),
  GlobeTarget('BLACK SEA', 43, 35),
  GlobeTarget('CASPIAN SEA', 41.5, 51.2),
];

const _ambientGeo = <GlobeTarget>[
  GlobeTarget('node', 52.4, 4.9),
  GlobeTarget('node', 48.8, 2.3),
  GlobeTarget('node', 51.5, 10.1),
  GlobeTarget('node', 41.9, 12.5),
  GlobeTarget('node', 40.4, -3.7),
  GlobeTarget('node', 59.3, 18.1),
  GlobeTarget('node', 35.7, 139.7),
  GlobeTarget('node', 37.8, -122.4),
  GlobeTarget('node', 40.7, -74.0),
  GlobeTarget('node', 25.2, 55.3),
  GlobeTarget('node', -33.9, 18.4),
  GlobeTarget('node', -1.3, 36.8),
  GlobeTarget('node', 31.2, 121.5),
  GlobeTarget('node', -33.9, 151.2),
  GlobeTarget('node', 19.4, -99.1),
  GlobeTarget('node', 45.5, -73.6),
  GlobeTarget('node', 64.1, -21.9),
  GlobeTarget('node', 13.7, 100.5),
  GlobeTarget('node', 1.3, 103.8),
  GlobeTarget('node', -23.5, -46.6),
];

const _networkGeoArcs = <List<GlobeTarget>>[
  [GlobeTarget('a', 52.4, 4.9), GlobeTarget('b', 40.7, -74.0)],
  [GlobeTarget('a', 51.5, 10.1), GlobeTarget('b', 35.7, 139.7)],
  [GlobeTarget('a', 25.2, 55.3), GlobeTarget('b', -1.3, 36.8)],
  [GlobeTarget('a', -33.9, 151.2), GlobeTarget('b', 1.3, 103.8)],
];

const globeTargets = [
  GlobeTarget('Germany', 51.2, 10.4),
  GlobeTarget('Netherlands', 52.2, 5.3),
  GlobeTarget('United Kingdom', 54.2, -2.5),
  GlobeTarget('Turkey', 39, 35),
  GlobeTarget('United States', 39.8, -98.6),
  GlobeTarget('Canada', 56.1, -106.3),
  GlobeTarget('Japan', 36.2, 138.3),
  GlobeTarget('Australia', -25.3, 133.8),
];

class ResponsiveGlobe extends StatefulWidget {
  const ResponsiveGlobe({
    this.globeScale = 2.20,
    this.globeCenterYFraction = .35,
    this.showDebugControls = false,
    this.sourceTarget = _iranFocus,
    this.destinationTarget,
    this.lightMode = false,
    super.key,
  });
  final double globeScale, globeCenterYFraction;
  final bool showDebugControls;
  final GlobeTarget sourceTarget;
  final GlobeTarget? destinationTarget;
  final bool lightMode;
  @override
  State<ResponsiveGlobe> createState() => _GlobeState();
}

class _GlobeState extends State<ResponsiveGlobe> with TickerProviderStateMixin {
  List<_GeoRing> rings = [];
  late double scale = widget.globeScale, centerY = widget.globeCenterYFraction;
  GlobeTarget? active = _iranFocus, pendingActive = _iranFocus;
  late bool lightMode = widget.lightMode;
  int index = 0;
  double rotation = -54,
      zoom = 1.65,
      fromR = -54,
      toR = -54,
      fromZ = 1.65,
      toZ = 1.7;
  late final anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  Timer? demoTimer;
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  );
  @override
  void initState() {
    super.initState();
    active = widget.sourceTarget;
    pendingActive = widget.sourceTarget;
    rotation = -widget.sourceTarget.lon;
    fromR = rotation;
    toR = rotation;
    _load();
    anim.addListener(_onAnimationTick);
    pulse.addListener(_onAnimationTick);
    anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        rotation = toR;
        zoom = toZ;
        active = pendingActive;
        pulse.repeat();
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant ResponsiveGlobe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lightMode != widget.lightMode) {
      lightMode = widget.lightMode;
    }
    final next = widget.destinationTarget;
    final previous = oldWidget.destinationTarget;
    if (next == null) {
      final sourceChanged =
          oldWidget.sourceTarget.name != widget.sourceTarget.name ||
          oldWidget.sourceTarget.lat != widget.sourceTarget.lat ||
          oldWidget.sourceTarget.lon != widget.sourceTarget.lon;
      if (previous != null || sourceChanged) {
        // Return from the selected destination to the current source through
        // the same camera path instead of snapping back to the source.
        _selectTarget(widget.sourceTarget);
      }
    } else if (next.name != previous?.name) {
      _selectTarget(next);
    }
  }

  Future<void> _load() async {
    final j =
        jsonDecode(
              await rootBundle.loadString(
                'assets/maps/world_simplified.geojson',
              ),
            )
            as Map<String, dynamic>;
    final out = <_GeoRing>[];
    for (final f in j['features'] as List) {
      final feature = f as Map<String, dynamic>;
      final g = feature['geometry'] as Map<String, dynamic>;
      final props = (feature['properties'] as Map?)?.cast<String, dynamic>();
      final country = (props?['country'] ?? '').toString();
      for (final rr in g['coordinates'] as List) {
        if (rr is! List) continue;
        final r = <Offset>[];
        for (final p in rr) {
          final a = p is String ? p.trim().split(RegExp(r'\s+')) : p as List;
          if (a.length > 1) {
            final x = double.tryParse(a[0].toString()),
                y = double.tryParse(a[1].toString());
            if (x != null && y != null) r.add(Offset(x, y));
          }
        }
        if (r.length > 2) out.add(_GeoRing(country, r));
      }
    }
    if (mounted) setState(() => rings = out);
  }

  double _short(double lon) {
    var d = -lon - rotation;
    while (d > 180) d -= 360;
    while (d < -180) d += 360;
    return rotation + d;
  }

  void _onAnimationTick() {
    if (mounted) setState(() {});
  }

  void startDemo() {
    demoTimer?.cancel();
    active = widget.sourceTarget;
    pendingActive = widget.sourceTarget;
    rotation = -widget.sourceTarget.lon;
    zoom = 1.7;
    select(index);
  }

  void select(int i) {
    _selectTarget(globeTargets[i % globeTargets.length]);
  }

  void _selectTarget(GlobeTarget t) {
    setState(() {
      pendingActive = t;
      fromR = rotation;
      toR = _short(t.lon);
      fromZ = zoom;
      toZ = 1.7;
    });
    pulse.stop();
    anim.forward(from: 0);
  }

  void reset() {
    demoTimer?.cancel();
    demoTimer = null;
    pulse
      ..stop()
      ..value = 0;
    anim.stop();
    setState(() {
      active = widget.sourceTarget;
      pendingActive = widget.sourceTarget;
      rotation = -widget.sourceTarget.lon;
      zoom = 1.65;
    });
  }

  @override
  void dispose() {
    anim.removeListener(_onAnimationTick);
    pulse.removeListener(_onAnimationTick);
    anim.dispose();
    demoTimer?.cancel();
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, k) {
      final s = Size(k.maxWidth, k.maxHeight),
          d = math.min(s.width, s.height) * scale,
          t = Curves.easeInOutCubic.transform(anim.value),
          r = anim.isAnimating ? _lerp(fromR, toR, t) : rotation,
          focusLat = anim.isAnimating
              ? _lerp(
                  active?.lat ?? (pendingActive?.lat ?? 0),
                  pendingActive?.lat ?? 0,
                  t,
                )
              : (active?.lat ?? 0),
          z = anim.isAnimating
              ? (t < .35
                    ? _lerp(fromZ, 1.0, t / .35)
                    : (t < .65 ? 1.0 : _lerp(1.0, toZ, (t - .65) / .35)))
              : zoom;
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: lightMode
                ? const Color(0xFFF2FAFD)
                : const Color(0xFF04131C),
          ),
          CustomPaint(
            painter: _Painter(
              rings,
              Offset(s.width / 2, s.height * centerY),
              d,
              r,
              z,
              active,
              pendingActive,
              focusLat,
              pulse.value,
              lightMode,
            ),
          ),
          if (widget.showDebugControls)
            Positioned(
              top: 36,
              right: 12,
              child: IconButton(
                onPressed: () => setState(() => lightMode = !lightMode),
                icon: Icon(
                  lightMode ? Icons.dark_mode : Icons.light_mode,
                  color: lightMode ? Colors.black87 : Colors.white,
                ),
              ),
            ),
          if (widget.showDebugControls)
            Positioned(
              left: 10,
              right: 10,
              bottom: 12,
              child: _Controls(
                scale,
                centerY,
                z,
                globeTargets[index],
                (v) => setState(() => scale = v),
                (v) => setState(() => centerY = v),
                startDemo,
                () => setState(() => index = (index + 1) % globeTargets.length),
                reset,
              ),
            ),
        ],
      );
    },
  );
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

class _Controls extends StatelessWidget {
  const _Controls(
    this.s,
    this.cy,
    this.z,
    this.a,
    this.os,
    this.ocy,
    this.start,
    this.next,
    this.reset,
  );
  final double s, cy, z;
  final GlobeTarget? a;

  final ValueChanged<double> os, ocy;
  final VoidCallback start, next, reset;
  @override
  Widget build(BuildContext c) => Material(
    color: Colors.black54,
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: start,
                  child: const Text('START DEMO'),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: OutlinedButton(
                  onPressed: next,
                  child: const Text('NEXT COUNTRY'),
                ),
              ),
              IconButton(
                onPressed: reset,
                icon: const Icon(Icons.restart_alt, color: Colors.white),
              ),
            ],
          ),
          Text(a?.name ?? 'World', style: TextStyle(color: Colors.white)),
          _sl('Scale', s, .45, 2.2, os),
          _sl('Center Y', cy, .2, .8, ocy),
          Text(
            'Zoom ${z.toStringAsFixed(2)}',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    ),
  );
  Widget _sl(
    String n,
    double v,
    double mn,
    double mx,
    ValueChanged<double> f,
  ) => Row(
    children: [
      SizedBox(
        width: 94,
        child: Text(
          '$n  ${v.toStringAsFixed(2)}',
          style: TextStyle(color: Colors.white),
        ),
      ),
      Expanded(
        child: Slider(value: v, min: mn, max: mx, onChanged: f),
      ),
    ],
  );
}

class _Painter extends CustomPainter {
  _Painter(
    this.rs,
    this.center,
    this.d,
    this.rot,
    this.zoom,
    this.active,
    this.focus,
    this.focusLat,
    this.pulse,
    this.lightMode,
  );
  final List<_GeoRing> rs;
  final Offset center;
  final double d, rot, zoom, focusLat, pulse;
  final bool lightMode;

  final GlobeTarget? active, focus;
  @override
  void paint(Canvas c, Size s) {
    final rad = d / 2 * zoom,
        globe = Rect.fromCircle(center: center, radius: rad);
    c.drawCircle(
      center,
      rad,
      Paint()
        ..color = lightMode
            ? const Color(0xFF86CFE8)
            : const Color(0xFF05202C),
    );
    if (_debugDots) {
      const ambient = <Offset>[
        Offset(.08, .08),
        Offset(.22, .16),
        Offset(.39, .10),
        Offset(.63, .12),
        Offset(.84, .08),
        Offset(.12, .27),
        Offset(.31, .33),
        Offset(.56, .28),
        Offset(.76, .35),
        Offset(.93, .29),
        Offset(.06, .54),
        Offset(.25, .62),
        Offset(.48, .56),
        Offset(.70, .64),
        Offset(.89, .55),
        Offset(.14, .82),
        Offset(.36, .76),
        Offset(.58, .86),
        Offset(.80, .78),
        Offset(.94, .88),
        Offset(.04, .42),
        Offset(.97, .46),
        Offset(.44, .20),
        Offset(.67, .45),
      ];
      final ambientColor = lightMode
          ? const Color(0xFF6EAAC1)
          : const Color(0xFF36BCE0);
      for (var i = 0; i < ambient.length; i++) {
        final q = Offset(ambient[i].dx * s.width, ambient[i].dy * s.height);
        final size = i % 7 == 0 ? 1.8 : (i % 3 == 0 ? 1.15 : .65);
        final alpha = lightMode ? .18 : (i % 7 == 0 ? .72 : .34);
        c.drawCircle(
          q,
          size,
          Paint()..color = ambientColor.withValues(alpha: alpha),
        );
        if (!lightMode && i % 7 == 0) {
          c.drawCircle(
            q,
            7,
            Paint()
              ..color = ambientColor.withValues(alpha: .10)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
          );
        }
      }
    }
    c.save();
    c.clipPath(Path()..addOval(globe));
    if (_debugAtmosphere) {
      final speckColor = lightMode
          ? const Color(0xFF4B94AA).withValues(alpha: .22)
          : const Color(0xFF7DE6F5).withValues(alpha: .38);
      for (var i = 0; i < 28; i++) {
        final a = (i * 137.5) * math.pi / 180;
        final rr = rad * (.18 + (i % 7) * .095);
        final q = Offset(
          center.dx + math.cos(a) * rr,
          center.dy + math.sin(a * 1.37) * rr,
        );
        c.drawCircle(q, i % 9 == 0 ? 1.35 : .55, Paint()..color = speckColor);
      }
    }
    final fill = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: lightMode
                ? const [Color(0xFFF2F8FA), Color(0xFFDCECF2)]
                : const [Color(0xFF123F50), Color(0xFF092B3A)],
          ).createShader(globe)
          ..color =
              (lightMode ? const Color(0xFFEAF4F8) : const Color(0xFF10394A))
                  .withValues(alpha: lightMode ? .90 : .52),
        line = Paint()
          ..color =
              (lightMode ? const Color(0xFF6EAAC1) : const Color(0xFF20A8D0))
                  .withValues(alpha: lightMode ? .86 : .68)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    if (_debugDots) {
      final dots = <Offset>[
        Offset(center.dx - rad * .72, center.dy - rad * .30),
        Offset(center.dx - rad * .18, center.dy - rad * .56),
        Offset(center.dx + rad * .44, center.dy - rad * .18),
        Offset(center.dx + rad * .62, center.dy + rad * .34),
        Offset(center.dx - rad * .48, center.dy + rad * .42),
      ];
      final dotPaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF6EAAC1) : const Color(0xFF20A8D0))
                .withValues(alpha: .45);
      for (final dot in dots) {
        c.drawCircle(dot, 1.5, dotPaint);
      }
    }
    for (final geo in rs) {
      final activeCountry =
          active != null && _sameCountry(geo.country, active!.name);
      final paintFill = activeCountry
          ? (Paint()
              ..shader = LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: lightMode
                    ? const [
                        Color(0xFF8AF0C1),
                        Color(0xFF48D69E),
                        Color(0xFF1FA978),
                      ]
                    : const [
                        Color(0xFF78F1B7),
                        Color(0xFF22C989),
                        Color(0xFF087A58),
                      ],
                stops: const [0.0, 0.48, 1.0],
              ).createShader(globe)
              ..color = const Color(0xFF1DBE89).withValues(alpha: .72))
          : (Paint()..color = _countrySurfaceColor(geo.country, lightMode));
      for (final wrap in const [0.0]) {
        final r = geo.points;
        final p = Path();
        var started = false;
        for (var i = 0; i < r.length; i++) {
          final q = r[i];
          final lon = (q.dx + rot + wrap) * math.pi / 180;
          final lat = q.dy * math.pi / 180;
          final cam = focusLat * math.pi / 180;
          final depth =
              math.sin(lat) * math.sin(cam) +
              math.cos(lat) * math.cos(cam) * math.cos(lon);
          // Never paint the far hemisphere. A small positive cutoff keeps
          // the rim clean and prevents back-side borders/textures leaking
          // through during camera rotation.
          if (depth < 0.06) {
            started = false;
            continue;
          }
          final px = math.sin(lon) * math.cos(lat);
          final py =
              math.sin(lat) * math.cos(cam) -
              math.cos(lat) * math.sin(cam) * math.cos(lon);
          final x = center.dx + px * rad;
          final y = center.dy - py * rad;
          if (!started) {
            p.moveTo(x, y);
            started = true;
          } else {
            p.lineTo(x, y);
          }
        }
        p.close();
        c.drawPath(p, paintFill);
        if (!activeCountry) {
          // A restrained inner wash gives each country a slightly different
          // surface tone, so the map reads as layered geography rather than
          // one flat filled sheet.
          final wash = Paint()
            ..color = _countryWashColor(
              geo.country,
              lightMode,
            ).withValues(alpha: lightMode ? .16 : .12)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8;
          c.drawPath(p, wash);
        }
        c.drawPath(p, line);
        if (activeCountry && _debugCountryGlow) {
          c.drawPath(
            p,
            Paint()
              ..color = (lightMode
                      ? const Color(0xFF129B72)
                      : const Color(0xFF55E6AD))
                  .withValues(alpha: lightMode ? .90 : .72)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.35,
          );
        }
      }
    }
    // Nearby country labels share the same spherical camera as the borders.
    // They are intentionally limited to the visible neighborhood of the
    // active country so the map stays readable.
    if (active != null) {
      final labeled = <String>{};
      final labelRings = <String, _GeoRing>{};
      for (final candidate in rs) {
        final current = labelRings[candidate.country];
        if (current == null || _ringArea(candidate.points) > _ringArea(current.points)) {
          labelRings[candidate.country] = candidate;
        }
      }
      final activeLat = active!.lat * math.pi / 180;
      final activeLon = active!.lon * math.pi / 180;
      for (final geo in labelRings.values) {
        final name = geo.country.trim();
        if (name.isEmpty ||
            labeled.contains(name) ||
            _sameCountry(name, active!.name)) {
          continue;
        }
        final centroid = _ringCentroid(geo.points);
        final lon = centroid.dx;
        final lat = centroid.dy;
        final bounds = geo.points.fold<List<double>>(
          <double>[
            double.infinity,
            double.infinity,
            double.negativeInfinity,
            double.negativeInfinity,
          ],
          (b, p) => <double>[
            math.min(b[0], p.dx),
            math.min(b[1], p.dy),
            math.max(b[2], p.dx),
            math.max(b[3], p.dy),
          ],
        );
        final geographicSpan = math.max(
          bounds[2] - bounds[0],
          bounds[3] - bounds[1],
        );
        if (geographicSpan < 5.5) continue;
        final latRad = lat * math.pi / 180;
        final lonRad = lon * math.pi / 180;
        final distance = math.acos(
          (math.sin(activeLat) * math.sin(latRad)) +
              (math.cos(activeLat) *
                  math.cos(latRad) *
                  math.cos(lonRad - activeLon)),
        );
        if (distance > 1.05) continue;
        final projectedLon = (lon + rot) * math.pi / 180;
        final cam = focusLat * math.pi / 180;
        final depth =
            math.sin(latRad) * math.sin(cam) +
            math.cos(latRad) * math.cos(cam) * math.cos(projectedLon);
        if (depth < .22) continue;
        final x = math.sin(projectedLon) * math.cos(latRad);
        final y =
            math.sin(latRad) * math.cos(cam) -
            math.cos(latRad) * math.sin(cam) * math.cos(projectedLon);
        final point = Offset(center.dx + x * rad, center.dy - y * rad);
        final label = name.toUpperCase();
        final text = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: lightMode
                  ? const Color(0xFF587481).withValues(alpha: .72)
                  : const Color(0xFF9CB6C2).withValues(alpha: .72),
              fontSize: math.min(8.5, math.max(6.5, rad * .009)),
              fontWeight: FontWeight.w500,
              letterSpacing: .1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 110);
        text.paint(c, point - Offset(text.width / 2, text.height / 2));
        labeled.add(name);
      }
    }
    // Draw water labels after land so enclosed seas such as the Caspian Sea
    // remain readable when the bundled country polygons cover their shoreline.
    for (final ocean in _oceanLabels) {
      final lon = (ocean.lon + rot) * math.pi / 180;
      final lat = ocean.lat * math.pi / 180;
      final cam = focusLat * math.pi / 180;
      final depth =
          math.sin(lat) * math.sin(cam) +
          math.cos(lat) * math.cos(cam) * math.cos(lon);
      if (depth < .28) continue;
      final x = math.sin(lon) * math.cos(lat);
      final y =
          math.sin(lat) * math.cos(cam) -
          math.cos(lat) * math.sin(cam) * math.cos(lon);
      final point = Offset(center.dx + x * rad, center.dy - y * rad);
      final compactWaterLabel =
          ocean.name == 'CASPIAN SEA' || ocean.name == 'PERSIAN GULF';
      final text = TextPainter(
        text: TextSpan(
          text: ocean.name,
          style: TextStyle(
            color: lightMode
                ? const Color(0xFF4F7D8D).withValues(alpha: .78)
                : const Color(0xFF8DB9C8).withValues(alpha: .70),
            fontSize: compactWaterLabel
                ? (ocean.name == 'PERSIAN GULF' ? 6.0 : 6.8)
                : math.min(10, math.max(7, rad * .010)),
            fontWeight: FontWeight.w600,
            letterSpacing: compactWaterLabel ? .2 : .8,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: compactWaterLabel ? 92 : 150);
      c.save();
      c.translate(point.dx, point.dy);
      if (ocean.name == 'PERSIAN GULF') c.rotate(.65);
      text.paint(c, Offset(-text.width / 2, -text.height / 2));
      c.restore();
    }
    // Low-cost atmospheric detail keeps the vector globe visually alive
    // without animated particles or raster textures.
    if (_debugDots) {
      final points = <Offset>[
        Offset(center.dx - rad * .72, center.dy - rad * .30),
        Offset(center.dx - rad * .18, center.dy - rad * .56),
        Offset(center.dx + rad * .44, center.dy - rad * .18),
        Offset(center.dx + rad * .62, center.dy + rad * .34),
        Offset(center.dx - rad * .48, center.dy + rad * .42),
        Offset(center.dx + rad * .05, center.dy + rad * .60),
      ];
      final dotPaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF6EAAC1) : const Color(0xFF20A8D0))
                .withValues(alpha: .48);
      final arcPaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF6EAAC1) : const Color(0xFF20A8D0))
                .withValues(alpha: .16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8;
      for (var i = 0; i < points.length; i++) {
        c.drawCircle(points[i], i.isEven ? 1.8 : 1.2, dotPaint);
        if (i > 0) {
          final path = Path()
            ..moveTo(points[i - 1].dx, points[i - 1].dy)
            ..quadraticBezierTo(
              center.dx,
              center.dy - rad * .12,
              points[i].dx,
              points[i].dy,
            );
          c.drawPath(path, arcPaint);
        }
      }
    }
    if (_debugTexture) {
      final texturePaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF6EAAC1) : const Color(0xFF36BCE0))
                .withValues(alpha: lightMode ? .24 : .30);
      final nodePaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF4F9BB5) : const Color(0xFF7EE8F6))
                .withValues(alpha: lightMode ? .30 : .52);
      // A deterministic latitude/longitude lattice provides lightweight
      // geographic texture without a bitmap or per-frame asset decoding.
      for (var lat = -72; lat <= 72; lat += 5) {
        for (var lon = -180; lon < 180; lon += 5) {
          final longitude = (lon + rot) * math.pi / 180;
          final latitude = lat * math.pi / 180;
          final camera = focusLat * math.pi / 180;
          final depth =
              math.sin(latitude) * math.sin(camera) +
              math.cos(latitude) * math.cos(camera) * math.cos(longitude);
          if (depth < .12) continue;
          final x = center.dx + math.sin(longitude) * math.cos(latitude) * rad;
          final y =
              center.dy -
              (math.sin(latitude) * math.cos(camera) -
                      math.cos(latitude) *
                          math.sin(camera) *
                          math.cos(longitude)) *
                  rad;
          final point = Offset(x, y);
          final bright = (lon + lat) % 25 == 0;
          c.drawCircle(point, bright ? 1.35 : .48, texturePaint);
          if (bright) {
            c.drawCircle(
              point,
              4.2,
              Paint()
                ..color = texturePaint.color.withValues(alpha: .10)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
            );
          }
        }
      }
      for (final node in const [
        Offset(-.44, -.12),
        Offset(-.18, -.42),
        Offset(.18, -.22),
        Offset(.42, .04),
        Offset(.06, .34),
        Offset(-.30, .40),
        Offset(-.58, -.28),
        Offset(-.34, .06),
        Offset(-.08, -.04),
        Offset(.30, -.42),
        Offset(.56, -.22),
        Offset(.64, .22),
        Offset(.36, .40),
        Offset(-.56, .30),
        Offset(-.14, .52),
        Offset(.22, .58),
      ]) {
        final point = Offset(
          center.dx + node.dx * rad,
          center.dy + node.dy * rad,
        );
        c.drawCircle(point, 2.15, nodePaint);
        c.drawCircle(
          point,
          7.5,
          Paint()
            ..color = nodePaint.color.withValues(alpha: .14)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .7,
        );
        if (!lightMode) {
          c.drawCircle(
            point,
            5,
            Paint()
              ..color = nodePaint.color.withValues(alpha: .08)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
          );
        }
      }
    }
    if (_debugDots) {
      Offset? project(double latDeg, double lonDeg, {double lift = 1}) {
        final lon = (lonDeg + rot) * math.pi / 180;
        final lat = latDeg * math.pi / 180;
        final cam = focusLat * math.pi / 180;
        final depth =
            math.sin(lat) * math.sin(cam) +
            math.cos(lat) * math.cos(cam) * math.cos(lon);
        if (depth < .04) return null;
        final x = math.sin(lon) * math.cos(lat);
        final y =
            math.sin(lat) * math.cos(cam) -
            math.cos(lat) * math.sin(cam) * math.cos(lon);
        return Offset(center.dx + x * rad * lift, center.dy - y * rad * lift);
      }

      final oceanLight = Paint()
        ..color =
            (lightMode ? const Color(0xFF5FABC1) : const Color(0xFF55D8F1))
                .withValues(alpha: lightMode ? .34 : .58);
      final landLight = Paint()
        ..color =
            (lightMode ? const Color(0xFF4D93A8) : const Color(0xFF8DEAF5))
                .withValues(alpha: lightMode ? .24 : .42);
      for (var i = 0; i < _ambientGeo.length; i++) {
        final point = project(_ambientGeo[i].lat, _ambientGeo[i].lon);
        if (point == null) continue;
        final paint = i.isEven ? oceanLight : landLight;
        final radius = i % 5 == 0 ? 2.1 : 1.0;
        c.drawCircle(point, radius, paint);
        if (i % 5 == 0 && !lightMode) {
          c.drawCircle(
            point,
            5.5,
            Paint()
              ..color = paint.color.withValues(alpha: .12)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
          );
        }
      }
      final arcPaint = Paint()
        ..color =
            (lightMode ? const Color(0xFF6EAFC0) : const Color(0xFF42CDE8))
                .withValues(alpha: lightMode ? .22 : .30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .75;
      for (final arc in _networkGeoArcs) {
        final a = arc.first, b = arc.last;
        final path = Path();
        var visible = false;
        for (var i = 0; i <= 18; i++) {
          final t = i / 18;
          final lat = _lerp(a.lat, b.lat, t);
          final lon = _lerp(a.lon, b.lon, t);
          final p = project(lat, lon, lift: 1.012);
          if (p == null) {
            visible = false;
            continue;
          }
          if (!visible) {
            path.moveTo(p.dx, p.dy);
            visible = true;
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        c.drawPath(path, arcPaint);
      }
    }
    if (active != null) {
      final markerLon = (active!.lon + rot) * math.pi / 180;
      final markerLat = active!.lat * math.pi / 180;
      final markerCam = focusLat * math.pi / 180;
      final markerX = math.sin(markerLon) * math.cos(markerLat);
      final markerY =
          math.sin(markerLat) * math.cos(markerCam) -
          math.cos(markerLat) * math.sin(markerCam) * math.cos(markerLon);
      final p = Offset(center.dx + markerX * rad, center.dy - markerY * rad);
      if (_debugRadar) {
        for (var i = 1; i <= 3; i++) {
          final t = (pulse + (i - 1) / 3) % 1;
          c.drawCircle(
            p,
            6 + t * 34,
            Paint()
              ..color = const Color(0xFF35E59A).withValues(alpha: (1 - t) * .16)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
        }
      }
      c.drawCircle(
        p,
        25,
        Paint()
          ..color = const Color(0xFF35E59A).withValues(alpha: .26)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
      c.drawCircle(
        p,
        11,
        Paint()
          ..color = const Color(0xFF35E59A).withValues(alpha: .42)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      c.drawCircle(
        p,
        9,
        Paint()
          ..color = const Color(0xFF62E7B5).withValues(alpha: .72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
      c.drawCircle(p, 4.8, Paint()..color = Colors.white);
      c.drawCircle(p, 3.1, Paint()..color = const Color(0xFF35E59A));
      final label = '${_flagFor(active!.name)}  ${active!.name}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: lightMode ? const Color(0xFF0B2940) : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 180);
      final popup = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(p.dx, p.dy - 42),
          width: tp.width + 24,
          height: tp.height + 14,
        ),
        const Radius.circular(12),
      );
      final connector = Paint()
        ..color = const Color(0xAA62E7B5)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      c.drawLine(Offset(p.dx, p.dy - 4), Offset(p.dx, popup.bottom), connector);
      c.drawRRect(
        popup.shift(const Offset(0, 2)),
        Paint()..color = const Color(0x33000000),
      );
      c.drawRRect(
        popup,
        Paint()
          ..color = lightMode
              ? const Color(0xF2FFFFFF)
              : const Color(0xE61A3A4B),
      );
      final border = Paint()
        ..color = const Color(0xAA62E7B5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      c.drawRRect(popup, border);
      tp.paint(c, Offset(popup.left + 12, popup.top + 7));
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _Painter o) =>
      o.rot != rot ||
      o.zoom != zoom ||
      o.pulse != pulse ||
      o.active != active ||
      o.center != center ||
      o.d != d;
}

class _GeoRing {
  const _GeoRing(this.country, this.points);
  final String country;
  final List<Offset> points;
}

bool _sameCountry(String a, String b) {
  final n = a.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  final t = b.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (n == t) return true;
  if (t.contains('unitedkingdom'))
    return n == 'uk' || n == 'gb' || n.contains('kingdom') || n == 'england';
  if (t.contains('unitedstates'))
    return n == 'usa' || n == 'us' || n.contains('unitedstates');
  return n.contains(t) || t.contains(n);
}

double _ringArea(List<Offset> points) {
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return sum.abs() / 2;
}

Offset _ringCentroid(List<Offset> points) {
  var areaTwice = 0.0, x = 0.0, y = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    final cross = a.dx * b.dy - b.dx * a.dy;
    areaTwice += cross;
    x += (a.dx + b.dx) * cross;
    y += (a.dy + b.dy) * cross;
  }
  if (areaTwice.abs() < 1e-6) {
    return points[points.length ~/ 2];
  }
  return Offset(x / (3 * areaTwice), y / (3 * areaTwice));
}

Color _countrySurfaceColor(String country, bool light) {
  const dark = <Color>[
    Color(0xFF10394A),
    Color(0xFF123F50),
    Color(0xFF0D3344),
    Color(0xFF16465A),
    Color(0xFF0F3B4D),
    Color(0xFF18495A),
  ];
  const pale = <Color>[
    Color(0xFFEAF4F8),
    Color(0xFFE3F0F4),
    Color(0xFFDCECF2),
    Color(0xFFF2F8FA),
    Color(0xFFE5F2F6),
    Color(0xFFD8EAF0),
  ];
  final index =
      _stableCountryHash(country) % (light ? pale.length : dark.length);
  return (light ? pale : dark)[index];
}

Color _countryWashColor(String country, bool light) {
  final h = _stableCountryHash('$country-wash');
  if (light) {
    return h.isEven ? const Color(0xFF9FCFDE) : const Color(0xFFB9DDE8);
  }
  return h.isEven ? const Color(0xFF2B7890) : const Color(0xFF1A5A72);
}

int _stableCountryHash(String value) {
  var hash = 17;
  for (final code in value.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return hash;
}

String _flagFor(String country) {
  const flags = {
    'Germany': '🇩🇪',
    'Netherlands': '🇳🇱',
    'United Kingdom': '🇬🇧',
    'Turkey': '🇹🇷',
    'United States': '🇺🇸',
    'Canada': '🇨🇦',
    'Japan': '🇯🇵',
    'Australia': '🇦🇺',
    'Iran': '🇮🇷',
  };
  return flags[country] ?? '🌐';
}
