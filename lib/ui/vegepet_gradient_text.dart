import 'package:flutter/material.dart';

/// 프로필 입력창 「시작하기!」와 동일 그라데이션 텍스트 (먹이주기/놀아주기 등 공통).
///
/// 영어 locale 에서는 descender 가 있는 글자(y, g, p 등)가 height: 1.0 일 때
/// 그라데이션 클리핑 영역 밖으로 나가 흰색으로 보이는 문제가 있다.
/// → 그라데이션 텍스트는 line height 를 1.15 이상으로 키우고, gradient bounds 도
/// 텍스트 실제 높이를 그대로 채우도록 유지한다.
Widget buildVegePetPastelBlueGradientButtonText(
  String text, {
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.w600,
  TextAlign textAlign = TextAlign.center,
  int? maxLines,
  TextOverflow? overflow,
}) {
  return ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
    ).createShader(bounds),
    child: Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: Colors.white,
        height: 1.15,
      ),
    ),
  );
}
