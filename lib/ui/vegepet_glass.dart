import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 게임 메뉴 하위 패널 대제목 top (한국어 14 · 영어 +1px, 뒤로가기 버튼은 9 고정).
const double kVegePetGameMenuSubPanelTitleTop = 14;
const double kVegePetGameMenuSubPanelTitleTopEnOffset = 1.0;
const double kVegePetGameMenuPanelW = 246;
const double kVegePetGameMenuPanelH = 310;

/// Glassmorphism 패널 shell (ClipRRect + BackdropFilter + white 60%).
Widget buildVegePetGlassPanel({
  required double width,
  required double height,
  required Widget child,
  double borderRadius = 20,
  double blurSigma = 10,
  Color? backgroundColor,
  double shadowBlurRadius = 12,
}) {
  final bg = backgroundColor ?? Colors.white.withValues(alpha: 0.60);
  return ClipRRect(
    borderRadius: BorderRadius.circular(borderRadius),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: shadowBlurRadius,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      ),
    ),
  );
}

/// 게임 메뉴 하위 패널 공통: 뒤로가기(9,9) + 대제목(37 또는 프로필 inset).
List<Widget> buildGameSubPanelHeader({
  required String title,
  required VoidCallback onBack,
  required double titleTop,
  bool showBackButton = true,
  bool useProfileTitleInset = false,
  TextStyle? titleStyle,
}) {
  final effectiveTitleStyle = titleStyle ??
      const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFF000000),
        height: 1.0,
      );
  final titleWidget = Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: effectiveTitleStyle,
  );

  return [
    if (showBackButton)
      Positioned(
        left: 9,
        top: 9,
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(10),
            child: const SizedBox(
              width: 28,
              height: 28,
              child: Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      ),
    if (useProfileTitleInset)
      Positioned(
        left: 9,
        top: titleTop,
        right: 8,
        child: Padding(
          padding: const EdgeInsets.only(left: 28),
          child: titleWidget,
        ),
      )
    else
      Positioned(
        left: 37,
        top: titleTop,
        right: 8,
        child: titleWidget,
      ),
  ];
}

/// 게임 메뉴 하위 패널(246×310) shell + 헤더 + 본문 영역.
Widget buildGameMenuSubPanelShell({
  required String title,
  required Widget body,
  required VoidCallback onBack,
  required double titleTop,
  bool showBackButton = true,
  double width = kVegePetGameMenuPanelW,
  double height = kVegePetGameMenuPanelH,
  double blurSigma = 10,
  double shadowBlurRadius = 12,
  double bodyTop = 48,
  double bodyLeft = 0,
  double bodyRight = 0,
  double? bodyBottom,
  EdgeInsets bodyPadding = const EdgeInsets.fromLTRB(8, 0, 8, 8),
  bool useProfileTitleInset = false,
  TextStyle? titleStyle,
}) {
  Widget bodyChild = body;
  if (bodyPadding != EdgeInsets.zero) {
    bodyChild = Padding(padding: bodyPadding, child: body);
  }

  return buildVegePetGlassPanel(
    width: width,
    height: height,
    blurSigma: blurSigma,
    shadowBlurRadius: shadowBlurRadius,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        ...buildGameSubPanelHeader(
          title: title,
          onBack: onBack,
          titleTop: titleTop,
          showBackButton: showBackButton,
          useProfileTitleInset: useProfileTitleInset,
          titleStyle: titleStyle,
        ),
        Positioned(
          left: bodyLeft,
          right: bodyRight,
          top: bodyTop,
          bottom: bodyBottom ?? 0,
          child: bodyChild,
        ),
      ],
    ),
  );
}
