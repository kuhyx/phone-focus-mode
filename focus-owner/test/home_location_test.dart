import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/home_location.dart';

void main() {
  late Directory dir;
  late HomeLocationStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('home_loc_test');
    store = HomeLocationStore(File('${dir.path}/${HomeLocationStore.fileName}'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('read', () {
    test('returns null when nothing is provisioned', () async {
      expect(await store.read(), isNull);
    });

    test('round-trips written coordinates', () async {
      await store.write(52.2297, 21.0122);
      final read = await store.read();
      expect(read?.latitude, closeTo(52.2297, 1e-9));
      expect(read?.longitude, closeTo(21.0122, 1e-9));
    });

    test('returns null on malformed JSON rather than throwing', () async {
      // A corrupt file must read as "location unknown", which the enforcement
      // layer treats as fail-closed. Throwing here would crash the service.
      await store.file.writeAsString('not json at all');
      expect(await store.read(), isNull);
    });

    test('returns null when the document is not an object', () async {
      await store.file.writeAsString('[1, 2, 3]');
      expect(await store.read(), isNull);
    });

    test('returns null when a coordinate is missing', () async {
      await store.file.writeAsString('{"latitude": 52.2}');
      expect(await store.read(), isNull);
    });

    test('returns null when a coordinate is not a number', () async {
      // This is the shape the shipped REDACTED_* placeholder would produce if
      // it ever reached the device.
      await store.file
          .writeAsString('{"latitude": "REDACTED_LAT", "longitude": 21.0}');
      expect(await store.read(), isNull);
    });

    test('returns null for out-of-range coordinates', () async {
      await store.file.writeAsString('{"latitude": 91.0, "longitude": 21.0}');
      expect(await store.read(), isNull);
    });
  });

  group('write', () {
    test('rejects an impossible latitude', () {
      expect(() => store.write(91, 0), throwsArgumentError);
    });

    test('rejects an impossible longitude', () {
      expect(() => store.write(0, 181), throwsArgumentError);
    });

    test('accepts the poles and the antimeridian', () async {
      await store.write(90, 180);
      expect((await store.read())?.latitude, 90);
    });
  });

  group('clear', () {
    test('removes provisioned coordinates', () async {
      await store.write(52.2297, 21.0122);
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('is a no-op when nothing is stored', () async {
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
