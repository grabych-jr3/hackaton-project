import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/catch/ar_math.dart';
import 'package:hackaton_project/features/catch/ar_sensors.dart';

void main() {
  group('circularEma', () {
    test('wraps 359° → 1° through north, not through 180°', () {
      final v = circularEma(359, 1, 0.5);
      expect(v, closeTo(0, 1e-9));
      expect(circularEma(1, 359, 0.15), closeTo(0.7, 1e-9));
      expect(circularEma(null, 370, 0.15), closeTo(10, 1e-9));
    });

    test('converges across the wrap', () {
      double? h = 350;
      for (var i = 0; i < 100; i++) {
        h = circularEma(h, 10, 0.15);
      }
      expect(h, closeTo(10, 1e-3));
    });
  });

  group('HeadingSmoother', () {
    test('dead-band holds output within ±1°', () {
      final s = HeadingSmoother(alpha: 1); // no EMA: isolate dead-band
      expect(s.add(100), 100);
      expect(s.add(100.8), 100);
      expect(s.add(99.2), 100);
      expect(s.add(101.5), 101.5);
      expect(s.add(0.5), 0.5);
      expect(s.add(359.8), 0.5); // within 1° across the wrap
    });

    test('declination added for magnetic source', () {
      final s = HeadingSmoother(declinationDeg: krakowDeclinationDeg);
      expect(s.add(357), closeTo(3, 1e-9));
      expect(krakowDeclinationDeg, 6.0);
    });
  });

  group('smoothHeadings', () {
    test('reliability: accuracy limit and 2 s silence timeout', () {
      fakeAsync((async) {
        final src = StreamController<CompassReading>();
        final out = <ArHeading>[];
        smoothHeadings(src.stream, magnetic: false).listen(out.add);
        src.add(const CompassReading(heading: 10, accuracyDeg: 5));
        async.flushMicrotasks();
        expect(out.last.reliable, isTrue);
        expect(out.last.needsCalibration, isFalse);

        async.elapse(const Duration(milliseconds: 1900));
        expect(out, hasLength(1));
        async.elapse(const Duration(milliseconds: 200));
        expect(out, hasLength(2));
        expect(out.last.reliable, isFalse);
        expect(out.last.degrees, closeTo(10, 1e-9));

        src.add(const CompassReading(heading: 10, accuracyDeg: 45));
        async.flushMicrotasks();
        expect(out.last.reliable, isFalse);
        expect(out.last.needsCalibration, isTrue);

        src.add(const CompassReading(heading: 10, accuracyDeg: null));
        async.flushMicrotasks();
        expect(out.last.reliable, isFalse);
        expect(out.last.needsCalibration, isFalse);

        src.add(const CompassReading(heading: null, accuracyDeg: 5));
        async.flushMicrotasks();
        expect(out, hasLength(4)); // null heading ignored
        src.close();
        async.flushMicrotasks();
      });
    });
  });

  test('arHeadingProvider emits from a fake compass (magnetic → true)', () async {
    final src = StreamController<CompassReading>();
    final c = ProviderContainer(overrides: [
      arCompassSourceProvider.overrideWithValue(src.stream),
      arCompassIsMagneticProvider.overrideWithValue(true),
    ]);
    addTearDown(c.dispose);
    final first = c.read(arHeadingProvider).first;
    src.add(const CompassReading(heading: 90, accuracyDeg: 10));
    final h = await first;
    expect(h.degrees, closeTo(96, 1e-9));
    expect(h.reliable, isTrue);
    await src.close();
  });

  test('arPitchProvider: low-passed accelerometer elevation in radians', () async {
    final c = ProviderContainer(overrides: [
      arSensorStreamsProvider.overrideWithValue(ArSensorStreams(
          accel: Stream.fromIterable(const [Vec3(0, 9.81, 0), Vec3(0, 0, 9.81)]))),
    ]);
    addTearDown(c.dispose);
    final v = await c.read(arPitchProvider).toList();
    expect(v[0], closeTo(0, 1e-9)); // upright → horizon
    expect(v[1], lessThan(0)); // tilting down, filtered (not yet −90°)
    expect(v[1], greaterThan(-1.0));
  });
}
