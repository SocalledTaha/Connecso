# Dynamic Connection Map

## Purpose and privacy

The map is a decorative, local visualization on the Android home screen. It explains the VPN exit region and connection state; it is not a navigation map or a source of network truth. It does not request GPS, Android location permission, device location, or an online map service. `ConnectionMap` receives a typed connection phase and resolved destination. It does not inspect subscription strings, select nodes, probe servers, or control Xray.

## Data flow

```text
Normalized VpnNode
  → LocationResolver
  → DestinationLocation
  → verified ConnectionPhase
  → ConnectionMap
```

`LocationResolver` trusts explicit coordinates first, then known normalized city metadata and whole-word city patterns. It can return country-only data with no coordinates and no city. The map highlights the country geometry in that case; it does not show a city marker. Unknown locations keep the map in world view. A city marker is shown only for a resolved city with coordinates and only after the application enters its verified `connected` phase.

`assets/locations/locations.json` lists the initial known cities and approximate city-center coordinates. Matching typed entries in `LocationResolver` are currently compiled into Dart so resolution stays synchronous in the existing connection-state flow. Keep the JSON and typed entries in sync when adding cities.

## Geometry, projection, and license

`assets/maps/world_simplified.geojson` contains simplified Natural Earth 1:110m Admin 0 country outlines, country names/codes, and Natural Earth label points used for country-only framing. The DBF reader trims both whitespace and NUL padding so ISO codes such as `GB` match normalized node metadata. `tool/generate_world_map.py` converts the downloaded shapefile to compact GeoJSON using Ramer-Douglas-Peucker line simplification at 0.12 degrees. Regenerate it with:

```text
python tool/generate_world_map.py <natural-earth-shapefile-directory> assets/maps/world_simplified.geojson
```

Natural Earth describes its public-domain map data as free for use: [Natural Earth downloads](https://www.naturalearthdata.com/downloads/) and [1:110m Admin 0 Countries](https://www.naturalearthdata.com/downloads/110m-cultural-vectors/110m-admin-0-countries/). The app uses a simple equirectangular projection: longitude maps linearly across the horizontal world axis and latitude maps linearly across the vertical axis. `MapProjection` owns the coordinate conversion and has projection tests. Country geometry and paths are loaded from the local asset once per map widget and reused while the camera and marker animate.

## State and animation

`ConnectionMapState` derives from the app's `ConnectionPhase`; it is never an independent network state. The map stays in world view while preparing, connecting, and verifying. When verification succeeds, it eases to the resolved country/city over about 1.15 seconds with a regional 6.2× framing, reveals a city marker late in the transition, then animates only the small marker pulse. Country-only locations highlight and frame the country without a city dot. During reconnecting the last verified marker is dimmed and the old viewport remains in place. Only after a replacement node verifies does the camera move to its new location. Disconnect and failure fade the active marker and return to world view; failure uses a restrained red accent.

Reduced Motion skips camera movement and the continuous pulse while retaining textual connection state and location. The map canvas is excluded from accessibility semantics; the home screen exposes destination, ping, stability, and connection status as text.

## Visual layering

The map uses low-opacity country outlines/fills for both themes, fades at its vertical edges into the Home background, omits decorative graticules, and skips Antarctica. The camera uses a uniform longitude/latitude scale so countries are not stretched; the connected framing is offset within the scene so the exit marker and label sit above the compact Power control. City labels are anchored to the coordinate-derived exit marker. If only a country is resolved from the connection name, the country geometry is framed/highlighted and its label is anchored to the bundled country center, without a fabricated city marker. The home scene separates map-pulse painting from the cached map geometry so the pulse does not repaint country paths each frame. There are no streets, roads, navigation controls, user-origin markers, route lines, or interactive map gestures.

## Validation

Projection, map-state derivation, country-only fallback, non-ambiguous city matching, reduced-motion, and map-transition tests are in `test/connection_map_test.dart` and `test/domain_test.dart`. Android build and complete test validation are required before calling the feature ready to download.
