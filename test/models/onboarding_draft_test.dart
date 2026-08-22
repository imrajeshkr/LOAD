import 'package:flutter_test/flutter_test.dart';
import 'package:load_app/models/v2_models.dart';

void main() {
  test('OnboardingDraft carries experience and environment', () {
    const d = OnboardingDraft(
      goals: [],
      coachChoice: true,
      metric: true,
      bodyweightKg: 80,
      targetDirection: 'declined',
      targetWeightKg: null,
      weekdaysIso: [1, 3, 5],
      splitPreference: 'full_body',
      experience: 'beginner',
      environment: 'home_gym',
      barWeightKg: 20,
      hasBenched: false,
      benchStartKg: null,
      flags: [],
      otherPain: '',
    );

    expect(d.experience, 'beginner');
    expect(d.environment, 'home_gym');
  });
}
