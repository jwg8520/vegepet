import 'package:flutter/material.dart';

/// 프로필/설정 패널 컴팩트 select 드롭다운 — 수동 스크롤 thumb.
Widget buildProfileSelectManualScrollbar({
  required ScrollController controller,
  required double listHeight,
  required int optionCount,
}) {
  if (optionCount <= 3) {
    return const SizedBox.shrink();
  }

  return AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.hasClients) {
        return const SizedBox.shrink();
      }

      const itemHeight = 30.0;
      final contentHeight = optionCount * itemHeight;
      final maxScroll = controller.position.maxScrollExtent;
      if (maxScroll <= 0) {
        return const SizedBox.shrink();
      }

      final thumbHeight = (listHeight * (listHeight / contentHeight)).clamp(
        16.0,
        listHeight,
      );
      final maxThumbTop = listHeight - thumbHeight;
      final fraction = (controller.offset / maxScroll).clamp(0.0, 1.0);
      final thumbTop = fraction * maxThumbTop;

      return Stack(
        children: [
          Positioned(
            top: thumbTop,
            right: 0,
            width: 3,
            height: thumbHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x99000000),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 프로필/설정 패널 컴팩트 select 드롭다운 — 옵션 목록.
Widget buildProfileSelectOptionsList({
  required BuildContext context,
  required ScrollController scrollController,
  required List<String> options,
  required String? selectedValue,
  required ValueChanged<String> onChanged,
  required double listWidth,
  required double listHeight,
  required bool isEnglishLocale,
  String Function(String raw)? optionLabelBuilder,
  Color selectedBackgroundColor = const Color(0xFFEFF6FF),
  Color splashColor = const Color(0xFFF4F8FF),
}) {
  final showScrollThumb = options.length > 3;
  final listView = ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: ListView.builder(
      controller: scrollController,
      padding: EdgeInsets.only(right: showScrollThumb ? 8 : 0),
      itemExtent: 30,
      itemCount: options.length,
      primary: false,
      shrinkWrap: false,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, index) {
        final option = options[index];
        final isSelected = option == selectedValue;
        final isFirst = index == 0;
        final isLast = index == options.length - 1;
        return InkWell(
          splashColor: splashColor.withValues(alpha: 0.45),
          highlightColor: splashColor.withValues(alpha: 0.35),
          hoverColor: splashColor.withValues(alpha: 0.25),
          onTap: () => onChanged(option),
          child: Container(
            height: 30,
            width: double.infinity,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isSelected ? selectedBackgroundColor : Colors.transparent,
              borderRadius: BorderRadius.vertical(
                top: isFirst ? const Radius.circular(12) : Radius.zero,
                bottom: isLast ? const Radius.circular(12) : Radius.zero,
              ),
            ),
            child: Text(
              optionLabelBuilder?.call(option) ?? option,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: isEnglishLocale && optionLabelBuilder != null ? 10 : 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF4A4A4A),
              ),
            ),
          ),
        );
      },
    ),
  );
  return SizedBox(
    width: listWidth,
    height: listHeight,
    child: Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: listView),
        if (showScrollThumb)
          Positioned(
            right: 3,
            top: 0,
            bottom: 0,
            width: 3,
            child: buildProfileSelectManualScrollbar(
              controller: scrollController,
              listHeight: listHeight,
              optionCount: options.length,
            ),
          ),
      ],
    ),
  );
}
