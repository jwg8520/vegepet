import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:vegepet/ui/vegepet_gradient_text.dart';

/// VegePet 공통 확인창 — 844×390 논리좌표 (화면에는 FittedBox 와 동일 스케일로 맞춤).
const double kVegePetConfirmDialogLeft = 302;
const double kVegePetConfirmDialogTop = 129;
const double kVegePetConfirmDialogW = 240;
const double kVegePetConfirmDialogH = 116;

/// 마당 240×116 Glassmorphism 단일 확인 버튼 알림창 공통 설정.
class VegePetNoticeConfig {
  const VegePetNoticeConfig({
    required this.isOpen,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimaryTap,
    this.onOutsideTap,
    this.outsideDismissible = true,
    this.bodyColor = const Color(0xFF4A4A4A),
    this.bodyFontSizeEn,
    this.bodyMaxLines,
    this.bodyMaxLinesEn,
    this.bodyMaxLinesKo,
    this.bodyOverflow = TextOverflow.ellipsis,
    this.titleBlockTranslateYOffset = 0,
    this.useFadeTransitionForOverlay = false,
    this.dismissKeyboardOnOutsideTapFirst = false,
    this.blockDialogPointerWithGestureDetector = true,
  });

  final bool isOpen;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimaryTap;
  final VoidCallback? onOutsideTap;
  final bool outsideDismissible;
  final Color bodyColor;
  final double? bodyFontSizeEn;
  final int? bodyMaxLines;
  final int? bodyMaxLinesEn;
  final int? bodyMaxLinesKo;
  final TextOverflow bodyOverflow;
  final double titleBlockTranslateYOffset;
  final bool useFadeTransitionForOverlay;
  final bool dismissKeyboardOnOutsideTapFirst;
  final bool blockDialogPointerWithGestureDetector;
}

Widget buildVegePetConfirmDialogShell({
  required Widget child,
  required double width,
  required double height,
}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.60),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      ),
    ),
  );
}

Widget buildVegePetOneButtonNoticeDialog(
  VegePetNoticeConfig config, {
  required bool isEnglishLocale,
}) {
  final isEn = isEnglishLocale;
  final bodyFontSize =
      config.bodyFontSizeEn != null && isEn ? config.bodyFontSizeEn! : 10.0;
  final int? resolvedBodyMaxLines;
  if (config.bodyMaxLinesEn != null || config.bodyMaxLinesKo != null) {
    resolvedBodyMaxLines = isEn
        ? (config.bodyMaxLinesEn ?? config.bodyMaxLinesKo)
        : (config.bodyMaxLinesKo ?? config.bodyMaxLinesEn);
  } else {
    resolvedBodyMaxLines = config.bodyMaxLines;
  }

  const contentWidth = kVegePetConfirmDialogW - 32;
  const buttonWidth = kVegePetConfirmDialogW - 16;

  Widget titleBodyColumn = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: contentWidth,
        child: Text(
          config.title,
          textAlign: TextAlign.left,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF000000),
            height: 1.25,
          ),
        ),
      ),
      const SizedBox(height: 5),
      SizedBox(
        width: contentWidth,
        child: Text(
          config.body,
          textAlign: TextAlign.left,
          softWrap: true,
          maxLines: resolvedBodyMaxLines,
          overflow: config.bodyOverflow,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: bodyFontSize,
            fontWeight: FontWeight.w600,
            color: config.bodyColor,
            height: 1.25,
          ),
        ),
      ),
    ],
  );
  if (config.titleBlockTranslateYOffset != 0) {
    titleBodyColumn = Transform.translate(
      offset: Offset(0, config.titleBlockTranslateYOffset),
      child: titleBodyColumn,
    );
  }

  return buildVegePetConfirmDialogShell(
    width: kVegePetConfirmDialogW,
    height: kVegePetConfirmDialogH,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Align(
              alignment: Alignment.topLeft,
              child: titleBodyColumn,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: buttonWidth,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: config.onPrimaryTap,
                  borderRadius: BorderRadius.circular(14),
                  child: Ink(
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFFF1F1F1),
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Center(
                      child: buildVegePetPastelBlueGradientButtonText(
                        config.primaryLabel,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
