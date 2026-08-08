import 'package:flutter/foundation.dart';

/// AdMob 단위 ID 설정.
///
/// 개발 단계에서는 Google 공식 테스트 ID만 사용한다.
/// 스토어 배포 전에 [useTestAdUnitIds] 를 `false` 로 바꾸고
/// [iosInterstitialAdUnitIdProd] / Info.plist App ID 를 운영 값으로 교체한다.
///
/// Android 광고는 이번 범위에서 설정하지 않는다.
class AvoPetAdMobConfig {
  AvoPetAdMobConfig._();

  /// `true` 이면 항상 테스트 전면 광고 단위를 사용한다.
  /// release 빌드에서 이 값이 `true` 로 남아 있으면 로그로 경고한다.
  static const bool useTestAdUnitIds = true;

  /// Google 공식 iOS 테스트 App ID.
  static const String iosAppIdTest = 'ca-app-pub-3940256099942544~1458002511';

  /// Google 공식 iOS 테스트 전면 광고 단위 ID.
  static const String iosInterstitialAdUnitIdTest =
      'ca-app-pub-3940256099942544/4411468910';

  /// 운영 App ID (배포 전 교체). 빈 값이면 미설정.
  static const String iosAppIdProd = '';

  /// 운영 전면 광고 단위 ID (배포 전 교체). 빈 값이면 미설정.
  static const String iosInterstitialAdUnitIdProd = '';

  /// 실제 load/show 에 사용할 iOS 전면 광고 단위 ID.
  static String get iosInterstitialAdUnitId {
    if (useTestAdUnitIds) {
      if (kReleaseMode) {
        debugPrint('interstitial:config_warn:test_ids_enabled_in_release');
      }
      return iosInterstitialAdUnitIdTest;
    }

    if (iosInterstitialAdUnitIdProd.isEmpty) {
      debugPrint('interstitial:config_error:prod_unit_id_empty');
      // 운영 ID 미설정 시 테스트 ID로 폴백하지 않고 빈 문자열을 반환해
      // 호출측이 광고를 생략하게 한다.
      return '';
    }

    if (iosInterstitialAdUnitIdProd.contains('3940256099942544')) {
      debugPrint('interstitial:config_warn:prod_unit_id_looks_like_test');
    }

    return iosInterstitialAdUnitIdProd;
  }

  static bool get hasUsableInterstitialUnitId =>
      iosInterstitialAdUnitId.trim().isNotEmpty;
}
