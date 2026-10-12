import 'dart:convert';

import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/models/connection_map_state.dart';
import 'package:connecso_client/domain/models/map_projection.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/location_resolver.dart';
import 'package:connecso_client/ui/widgets/connection_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'world-map country identifiers are normalized for destination lookup',
    () async {
      final geoJson =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/maps/world_simplified.geojson',
                ),
              )
              as Map<String, dynamic>;
      final features = geoJson['features'] as List<dynamic>;
      final uk = features.cast<Map<String, dynamic>>().singleWhere(
        (feature) =>
            (feature['properties'] as Map<String, dynamic>)['countryCode'] ==
            'GB',
      );
      expect(
        (uk['properties'] as Map<String, dynamic>)['country'],
        'United Kingdom',
      );
      expect(jsonEncode(geoJson), isNot(contains(r'\u0000')));
    },
  );

  test(
    'equirectangular projection maps origin to center and clamps bounds',
    () {
      final center = MapProjection.toScreen(
        latitude: 0,
        longitude: 0,
        size: const Size(400, 200),
      );
      expect(center.dx, 200);
      expect(center.dy, 100);

      final northEast = MapProjection.toUnit(90, 180);
      final southWest = MapProjection.toUnit(-90, -180);
      expect(northEast, const Offset(1, 0));
      expect(southWest, const Offset(0, 1));
    },
  );

  test(
    'world viewport centers the geographic origin and fits world bounds',
    () {
      const size = Size(400, 200);
      final viewport = MapViewport.interpolate(
        size: size,
        fromLocation: null,
        toLocation: null,
        progress: 0,
        destinationZoom: 6.2,
      );

      expect(viewport.projectLocation(Offset.zero), const Offset(200, 100));
      expect(viewport.projectMapPlane(const Offset(0, 0)), const Offset(0, 0));
      expect(
        viewport.projectMapPlane(const Offset(360, 180)),
        const Offset(400, 200),
      );
    },
  );

  test('destination camera and geographic marker use the same projection', () {
    const size = Size(400, 300);
    const destination = Offset(-74.006, 40.7128); // longitude, latitude
    final viewport = MapViewport.interpolate(
      size: size,
      fromLocation: null,
      toLocation: destination,
      progress: 1,
      destinationZoom: 6.2,
    );

    final expectedFocus = Offset(size.width / 2, size.height * .30);
    expect(viewport.projectLocation(destination).dx, expectedFocus.dx);
    expect(
      viewport.projectLocation(destination).dy,
      closeTo(expectedFocus.dy, 1e-9),
    );
    expect(
      viewport.projectMapPlane(
        MapProjection.toMapPlane(destination.dy, destination.dx),
      ),
      viewport.projectLocation(destination),
    );
  });

  test('map states follow the authoritative connection phase', () {
    expect(mapStateFor(ConnectionPhase.disconnected), ConnectionMapState.world);
    expect(
      mapStateFor(ConnectionPhase.connecting),
      ConnectionMapState.connecting,
    );
    expect(
      mapStateFor(ConnectionPhase.verifying),
      ConnectionMapState.connecting,
    );
    expect(
      mapStateFor(ConnectionPhase.reconnecting),
      ConnectionMapState.reconnecting,
    );
    expect(
      mapStateFor(ConnectionPhase.connected),
      ConnectionMapState.zoomingToDestination,
    );
    expect(
      mapStateFor(ConnectionPhase.connected, settled: true),
      ConnectionMapState.connected,
    );
    expect(mapStateFor(ConnectionPhase.failed), ConnectionMapState.failed);
    expect(
      mapStateFor(ConnectionPhase.disconnecting),
      ConnectionMapState.returningToWorld,
    );
  });

  testWidgets('draws and animates the map toward a verified VPN destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionMap(
            phase: ConnectionPhase.connected,
            destination: DestinationLocation(
              country: 'United States',
              countryCode: 'US',
              city: 'New York',
              latitude: 40.71,
              longitude: -74.01,
              source: LocationSource.database,
              confidence: .65,
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 950));
    expect(tester.takeException(), isNull);
  });

  testWidgets('country-only destination renders without a city marker crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionMap(
            phase: ConnectionPhase.connected,
            destination: DestinationLocation(
              country: 'Germany',
              countryCode: 'DE',
              city: '',
              latitude: null,
              longitude: null,
              source: LocationSource.serverMetadata,
              confidence: .75,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion and verified failover transitions stay stable', (
    tester,
  ) async {
    Widget map(ConnectionPhase phase, String city, double longitude) =>
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: ConnectionMap(
                phase: phase,
                destination: DestinationLocation(
                  country: city == 'Frankfurt' ? 'Germany' : 'Netherlands',
                  countryCode: city == 'Frankfurt' ? 'DE' : 'NL',
                  city: city,
                  latitude: 52,
                  longitude: longitude,
                  source: LocationSource.database,
                  confidence: .65,
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(map(ConnectionPhase.connected, 'Frankfurt', 8.68));
    await tester.pumpWidget(
      map(ConnectionPhase.reconnecting, 'Frankfurt', 8.68),
    );
    await tester.pumpWidget(map(ConnectionPhase.connected, 'Amsterdam', 4.90));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnecting keeps an in-progress map mounted', (tester) async {
    const destination = DestinationLocation(
      country: 'United States',
      countryCode: 'US',
      city: 'New York',
      latitude: 40.71,
      longitude: -74.01,
      source: LocationSource.database,
      confidence: .65,
    );
    Widget map(ConnectionPhase phase) => MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('map-capture'),
          child: SizedBox(
            width: 400,
            height: 300,
            child: ConnectionMap(
              phase: phase,
              destination: phase == ConnectionPhase.disconnected
                  ? null
                  : destination,
            ),
          ),
        ),
      ),
    );

    // Replace the initial disconnected map with a verified connection while
    // retaining its State, then interrupt its camera transition.
    await tester.pumpWidget(map(ConnectionPhase.disconnected));
    // The bundled geometry is loaded asynchronously; use bounded frames so a
    // repeating ticker in the test binding cannot make this test hang.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(map(ConnectionPhase.connected));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(map(ConnectionPhase.reconnecting));
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 2400));
    expect(find.byKey(const ValueKey('map-capture')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
