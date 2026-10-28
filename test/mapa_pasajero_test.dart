import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:taxi1/config/garita_config.dart';
import 'package:taxi1/config/map_config.dart';
import 'package:taxi1/l10n/app_localizations.dart';
import 'package:taxi1/models/colectivo_activo.dart';
import 'package:taxi1/models/recorrido.dart';
import 'package:taxi1/screens/map_screen.dart';
import 'package:taxi1/services/firebase_telemetria_service.dart';
import 'package:taxi1/services/location_service.dart';
import 'package:taxi1/services/preferences_service.dart';
import 'package:taxi1/services/recorridos_service.dart';
import 'package:taxi1/services/route_service.dart';
import 'package:taxi1/services/simulacion_flota_service.dart';
import 'package:taxi1/theme/app_theme.dart';
import 'package:taxi1/utils/polyline.dart';
import 'package:taxi1/widgets/app_map.dart';

/// Pruebas del muestreo dinámico de rutas por proximidad de colectivos:
/// - Modo Radar (1 km): muestra las rutas de los colectivos cercanos; carga una
///   línea cuando entra un vehículo al radio y la oculta cuando sale.
/// - Modo Foco (2 km): al hacer clic en un vehículo muestra sólo su línea,
///   incluye otros vehículos de esa misma línea hasta 2 km y oculta otras líneas.
/// - Simulación de 3 vehículos en movimiento (`SimulacionFlotaService`).
void main() {
  final centro = kQuilpueCenter;

  Trayecto recto(double lon) {
    final puntos = [
      for (var i = 0; i <= 10; i++) LatLng(-33.040 - i * 0.005, lon),
    ];
    return Trayecto(
      puntos: [puntos.first, puntos.last],
      geometria: encodePolyline(puntos),
      trazado: puntos,
    );
  }

  Trayecto invertido(Trayecto t) => Trayecto(
    puntos: t.puntos.reversed.toList(),
    geometria: encodePolyline(t.trazado.reversed.toList()),
    trazado: t.trazado.reversed.toList(),
  );

  final t = Recorrido(
    id: 't',
    garitaId: kGaritaPublica,
    nombre: 'Línea 10 T · Belloto 2000',
    colorValue: 0xFFB0338A,
    linea: 'Línea 10',
    codigoVariante: 'T',
    nombreVariante: 'Belloto 2000',
    ida: recto(centro.longitude + 0.001),
    vuelta: invertido(recto(centro.longitude + 0.005)),
    callesIda: const ['QUILPUÉ', 'SERRANO', 'ALTO EL YUGO'],
    callesVuelta: const ['ALTO EL YUGO', 'SERRANO', 'QUILPUÉ'],
  );
  final v1 = Recorrido(
    id: 'v1',
    garitaId: kGaritaPublica,
    nombre: 'Línea 10 V-1 · Troncos Viejos',
    colorValue: 0xFF00727C,
    linea: 'Línea 10',
    codigoVariante: 'V-1',
    nombreVariante: 'Troncos Viejos',
    ida: recto(centro.longitude + 0.002),
  );
  final v2 = Recorrido(
    id: 'v2',
    garitaId: kGaritaPublica,
    nombre: 'Línea 10 V-2 · Cumming',
    colorValue: 0xFFD95F02,
    linea: 'Línea 10',
    codigoVariante: 'V-2',
    nombreVariante: 'Cumming',
    ida: recto(centro.longitude + 0.003),
  );

  Widget app() => MaterialApp(
    theme: buildAppTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: const MapScreen(),
  );

  AppMap mapa(WidgetTester tester) =>
      tester.widget<AppMap>(find.byType(AppMap));
  MapMarker marcador(WidgetTester tester, String id) =>
      mapa(tester).markers.firstWhere((m) => m.id == id);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance.load();
  });

  setUp(() {
    SimulacionFlotaService.instance.stop();
    LocationService.instance.debugSetPosition(centro);
    RecorridosService.instance.debugSetRecorridos([t, v1, v2]);
    FirebaseTelemetriaService.instance.debugSetColectivos(const []);
  });

  tearDown(() {
    SimulacionFlotaService.instance.stop();
    RecorridosService.instance.clearSelection();
    RecorridosService.instance.debugSetRecorridos(const []);
    FirebaseTelemetriaService.instance.debugSetColectivos(const []);
    RouteService.instance.clearDestination();
    LocationService.instance.debugSetPosition(null);
  });

  testWidgets('sin colectivos cercanos en el radio de 1 km: el mapa queda '
      'limpio, sin líneas encimadas', (tester) async {
    // Un colectivo a ~1,5 km (fuera del radio base de 1 km).
    FirebaseTelemetriaService.instance.debugSetColectivos([
      ColectivoActivo(
        uid: 'lejos',
        idVehiculo: 'ABCD12',
        latitud: centro.latitude - 0.0135,
        longitud: centro.longitude,
        recorridoId: 't',
      ),
    ]);
    await tester.pumpWidget(app());
    await tester.pump();

    expect(mapa(tester).lines, isEmpty);
    expect(
      mapa(tester).markers.where((m) => m.id.startsWith('colectivo_')),
      isEmpty,
    );
  });

  testWidgets('con 2 colectivos cercanos (<= 1 km) aparecen sus rutas; si '
      'entra uno nuevo se carga su línea y si sale desaparece', (tester) async {
    final c1 = ColectivoActivo(
      uid: 'c1',
      idVehiculo: 'BBCC10',
      latitud: centro.latitude - 0.002, // ~220 m
      longitud: centro.longitude + 0.001,
      recorridoId: 't',
    );
    final c2 = ColectivoActivo(
      uid: 'c2',
      idVehiculo: 'DDEE11',
      latitud: centro.latitude - 0.003, // ~330 m
      longitud: centro.longitude + 0.002,
      recorridoId: 'v1',
    );

    FirebaseTelemetriaService.instance.debugSetColectivos([c1, c2]);
    await tester.pumpWidget(app());
    await tester.pump();

    // `t` tiene ida y vuelta (2 líneas) y `v1` sólo ida (1 línea) = 3 trazos.
    final insigniasIniciales = mapa(tester)
        .lines
        .map((l) => l.badge?.text)
        .toSet();
    expect(insigniasIniciales, unorderedEquals(['10 T', '10 V-1']));

    // Entra un tercer vehículo de la variante V-2 al radio de 1 km (~450 m).
    final c3 = ColectivoActivo(
      uid: 'c3',
      idVehiculo: 'FFGG12',
      latitud: centro.latitude - 0.004,
      longitud: centro.longitude + 0.003,
      recorridoId: 'v2',
    );
    FirebaseTelemetriaService.instance.debugSetColectivos([c1, c2, c3]);
    await tester.pump();

    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      unorderedEquals(['10 T', '10 V-1', '10 V-2']),
    );

    // Sale c2 del radio (se aleja a ~1,6 km): desaparece la línea 10 V-1.
    final c2Lejos = c2.copyWith(latitud: centro.latitude - 0.015);
    FirebaseTelemetriaService.instance.debugSetColectivos([c1, c2Lejos, c3]);
    await tester.pump();

    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      unorderedEquals(['10 T', '10 V-2']),
    );
  });

  testWidgets('al hacer clic en un vehículo: muestra sólo su línea, expande '
      'el radio al doble (2 km) para esa misma línea y permite volver', (
    tester,
  ) async {
    // c1 (Línea 10 T) a 300 m; c1Lejos (misma Línea 10 T) a 1,5 km (entre 1 km
    // y 2 km); cOtra (Línea 10 V-1) a 400 m.
    final c1 = ColectivoActivo(
      uid: 'c1',
      idVehiculo: 'BBCC10',
      latitud: centro.latitude - 0.0027,
      longitud: centro.longitude + 0.001,
      recorridoId: 't',
      recorridoNombre: t.nombre,
    );
    final c1RadioDoble = ColectivoActivo(
      uid: 'c1_2km',
      idVehiculo: 'BBCC99',
      latitud: centro.latitude - 0.0135, // ~1,5 km
      longitud: centro.longitude + 0.001,
      recorridoId: 't',
      recorridoNombre: t.nombre,
    );
    final cOtra = ColectivoActivo(
      uid: 'c_otra',
      idVehiculo: 'DDEE11',
      latitud: centro.latitude - 0.0035, // ~390 m
      longitud: centro.longitude + 0.002,
      recorridoId: 'v1',
      recorridoNombre: v1.nombre,
    );

    FirebaseTelemetriaService.instance.debugSetColectivos([
      c1,
      c1RadioDoble,
      cOtra,
    ]);
    await tester.pumpWidget(app());
    await tester.pump();

    // En Modo Radar (1 km): se ven c1 y cOtra (y sus dos rutas), pero no
    // c1_2km que está a 1,5 km.
    expect(
      mapa(tester).markers.map((m) => m.id),
      containsAll(['colectivo_c1', 'colectivo_c_otra']),
    );
    expect(
      mapa(tester).markers.map((m) => m.id),
      isNot(contains('colectivo_c1_2km')),
    );

    // El pasajero toca el vehículo c1.
    marcador(tester, 'colectivo_c1').onTap!();
    await tester.pump();

    // Ahora sólo se dibuja la línea 10 T, con flechas de sentido y puntos de
    // seña; se oculta el colectivo de la otra línea (c_otra) y aparece el
    // compañero de la misma línea en el radio de 2 km (c1_2km).
    expect(RecorridosService.instance.selected?.id, 't');
    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      equals({'10 T'}),
    );
    expect(mapa(tester).lines.every((l) => l.arrows), isTrue);
    final idsEnFoco = mapa(tester).markers.map((m) => m.id).toSet();
    expect(idsEnFoco, containsAll(['colectivo_c1', 'colectivo_c1_2km']));
    expect(idsEnFoco, isNot(contains('colectivo_c_otra')));
    expect(idsEnFoco, containsAll(['sena_ida', 'sena_vuelta']));
    expect(find.textContaining('BBCC·10'), findsOneWidget);

    // Al cerrar la tarjeta con la X vuelve al Modo Radar (1 km).
    await tester.tap(find.byTooltip('Quitar recorrido'));
    await tester.pump();
    expect(RecorridosService.instance.selected, isNull);
    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      unorderedEquals(['10 T', '10 V-1']),
    );
  });

  testWidgets('los 3 vehículos de prueba de SimulacionFlotaService se mueven '
      'y demuestran la entrada/salida del radio de 1 km', (tester) async {
    SimulacionFlotaService.instance.start(centro: centro, conTimer: false);
    await tester.pumpWidget(app());
    await tester.pump();

    // En el paso 0, los 3 vehículos están dentro de 1 km (~200 m a ~500 m),
    // por lo que aparecen las 3 rutas de prueba en el mapa.
    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      unorderedEquals(['10 T', '10 V-1', '10 V-2']),
    );
    final posInicial1 = marcador(tester, 'colectivo_sim_vehiculo_1').point;

    // Al avanzar 9 pasos, los vehículos se desplazan y el vehículo 3 supera
    // el radio de 1 km (~1,3 km), haciendo que su ruta 10 V-2 desaparezca en
    // Modo Radar mientras 10 T y 10 V-1 siguen activas.
    for (var i = 0; i < 9; i++) {
      SimulacionFlotaService.instance.avanzarPaso();
    }
    await tester.pump();

    final posMovida1 = marcador(tester, 'colectivo_sim_vehiculo_1').point;
    expect(posMovida1, isNot(equals(posInicial1)));
    expect(
      mapa(tester).lines.map((l) => l.badge?.text).toSet(),
      unorderedEquals(['10 T', '10 V-1']),
    );
  });

  testWidgets('elegida desde lejos, no propone caminar 15 km: dice a cuánto '
      'pasa', (tester) async {
    LocationService.instance.debugSetPosition(const LatLng(-33.0458, -71.6197));
    await tester.pumpWidget(app());
    await tester.pump();

    RecorridosService.instance.select(t);
    await tester.pump();
    expect(mapa(tester).lines, isNotEmpty);
    expect(RouteService.instance.destination, isNull);
    expect(find.textContaining('km de ti'), findsOneWidget);
  });
}
