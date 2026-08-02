import 'package:vegepet/game/pet_motion.dart';

/// 모션별 기본 spd/rep 설정.
class PetMotionTuneConfig {
  const PetMotionTuneConfig({
    required this.speedMultiplier,
    required this.repeatCount,
  });

  final double speedMultiplier;
  final int repeatCount;
}

const PetMotionTuneConfig kPetMotionDefaultTuningFallback = PetMotionTuneConfig(
  speedMultiplier: 1.0,
  repeatCount: 1,
);

const Map<PetMotion, PetMotionTuneConfig> kPetMotionDefaultTunings = {
  PetMotion.idle: PetMotionTuneConfig(speedMultiplier: 0.7, repeatCount: 1),
  PetMotion.walk: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.run: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.lieDown: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.lyingIdle: PetMotionTuneConfig(
    speedMultiplier: 0.7,
    repeatCount: 1,
  ),
  PetMotion.standUp: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.kneading: PetMotionTuneConfig(speedMultiplier: 0.8, repeatCount: 5),
  PetMotion.play: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 6),
};

PetMotionTuneConfig kPetMotionDefaultTuningFor(PetMotion motion) {
  return kPetMotionDefaultTunings[motion] ?? kPetMotionDefaultTuningFallback;
}
