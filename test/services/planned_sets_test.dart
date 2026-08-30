import 'package:flutter_test/flutter_test.dart';
import 'package:load_app/services/planned_sets.dart';

void main() {
  test('seeds every row with the same prefill', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    expect(p.length, 3);
    expect(p.at(0), (60.0, 8));
    expect(p.at(2), (60.0, 8));
  });

  test('adjusting one row leaves the others alone', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    p.adjust(1, dKg: -5, dReps: 2);
    expect(p.at(0), (60.0, 8));
    expect(p.at(1), (55.0, 10));
    expect(p.at(2), (60.0, 8));
  });

  test('weight never goes negative and reps never go below one', () {
    final p = PlannedSets.seed(count: 1, kg: 2.5, reps: 1);
    p.adjust(0, dKg: -10, dReps: -5);
    expect(p.at(0), (0.0, 1));
  });

  test('grow adds rows carrying the last row values', () {
    final p = PlannedSets.seed(count: 2, kg: 60, reps: 8);
    p.adjust(1, dKg: 5);
    p.grow(4);
    expect(p.length, 4);
    expect(p.at(2), (65.0, 8));
    expect(p.at(3), (65.0, 8));
  });

  test('grow never shrinks', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    p.grow(2);
    expect(p.length, 3);
  });

  test('half-kilo steps stay on a quarter-kilo grid', () {
    // Twenty raw additions of 0.5 lands on 22.500000000000004. That formats
    // fine and compares wrong, which is the worst combination.
    final p = PlannedSets.seed(count: 1, kg: 20, reps: 8);
    for (var i = 0; i < 20; i++) {
      p.adjust(0, dKg: 0.5);
    }
    expect(p.at(0).$1, 30.0);

    p.adjust(0, dKg: -0.5);
    expect(p.at(0).$1, 29.5);
  });
}
