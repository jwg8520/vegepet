import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:vegepet/ads/vegepet_admob_config.dart';

/// 식단 인증용 전면 광고 preload / show 전담.
///
/// 정책 판정(첫 식단·일일 제한 등)은 호출측에서 하고,
/// 이 클래스는 로드·표시·콜백·dispose 만 담당한다.
class MealInterstitialController {
  InterstitialAd? _ad;
  bool _loadInFlight = false;
  bool _showInFlight = false;
  bool _disposed = false;

  bool get isReady => !_disposed && _ad != null;

  bool get isShowInFlight => _showInFlight;

  Future<void> preload() async {
    if (_disposed) return;
    if (!VegePetAdMobConfig.hasUsableInterstitialUnitId) {
      debugPrint('interstitial:skip:not_ready');
      return;
    }
    if (_loadInFlight || _ad != null || _showInFlight) return;

    _loadInFlight = true;
    debugPrint('interstitial:load_start');
    try {
      await InterstitialAd.load(
        adUnitId: VegePetAdMobConfig.iosInterstitialAdUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            _loadInFlight = false;
            if (_disposed) {
              ad.dispose();
              return;
            }
            _ad = ad;
            debugPrint('interstitial:load_success');
          },
          onAdFailedToLoad: (error) {
            _loadInFlight = false;
            _ad = null;
            debugPrint('interstitial:load_failed');
          },
        ),
      );
    } catch (e) {
      _loadInFlight = false;
      _ad = null;
      debugPrint('interstitial:load_failed');
    }
  }

  /// 준비된 광고를 1회 표시한다.
  ///
  /// - 미준비 / 중복 show / dispose 시 `false` 를 반환하고 [onFinished] 는
  ///   호출하지 않는다(호출측이 즉시 afterAd 를 실행해야 한다).
  /// - show 요청이 접수되면 `true` 를 반환하고, 이후 dismiss/fail 에서
  ///   [onFinished] 를 정확히 1회 호출한다.
  /// - [onShowed] 는 실제 전체화면 표시 시작 시 1회 호출한다.
  Future<bool> show({
    required VoidCallback onShowed,
    required VoidCallback onFinished,
  }) async {
    if (_disposed || _showInFlight) return false;
    final ad = _ad;
    if (ad == null) return false;

    _showInFlight = true;
    _ad = null;

    var finished = false;
    void finishOnce() {
      if (finished) return;
      finished = true;
      _showInFlight = false;
      onFinished();
      if (!_disposed) {
        unawaited(preload());
      }
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        debugPrint('interstitial:show');
        onShowed();
      },
      onAdDismissedFullScreenContent: (shown) {
        debugPrint('interstitial:dismissed');
        shown.dispose();
        finishOnce();
      },
      onAdFailedToShowFullScreenContent: (shown, error) {
        debugPrint('interstitial:show_failed');
        shown.dispose();
        finishOnce();
      },
    );

    try {
      await ad.show();
      return true;
    } catch (e) {
      debugPrint('interstitial:show_failed');
      try {
        ad.dispose();
      } catch (_) {}
      finishOnce();
      return true;
    }
  }

  void dispose() {
    _disposed = true;
    _loadInFlight = false;
    _showInFlight = false;
    final ad = _ad;
    _ad = null;
    ad?.dispose();
  }
}
