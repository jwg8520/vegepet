import 'package:flutter/material.dart';
import 'package:vegepet/l10n/app_localizations.dart';

// 게임 메뉴 가방 패널 / 놀아주기 드래그 등에서 쓰는 아이템 정보 모델.
//
// category 는 'ticket' | 'furniture' | 'toy' 중 하나.
class BagItem {
  final String category;
  final String name;
  final String description;
  final int quantity;
  final IconData icon;
  final bool usable;
  final String? targetPetFamily;

  const BagItem({
    required this.category,
    required this.name,
    required this.description,
    required this.quantity,
    required this.icon,
    this.usable = false,
    this.targetPetFamily,
  });
}

/// 가방/놀아주기 아이템 표시명. [BagItem.name] 슬롯에는 안정적인 code 가
/// 들어가고, 실제 화면 표시 시점에만 l10n 으로 변환한다.
String localizedBagItemName(BagItem item, AppLocalizations l10n) {
  switch (item.name) {
    case 'random_adoption_ticket':
      return l10n.bagItemRandomTicketName;
    case 'bone_doll':
      return l10n.bagItemBoneDollName;
    case 'yarn_ball':
      return l10n.bagItemYarnBallName;
    default:
      return item.name;
  }
}

String localizedBagItemDescription(BagItem item, AppLocalizations l10n) {
  switch (item.name) {
    case 'random_adoption_ticket':
      return l10n.bagItemRandomTicketDesc;
    case 'bone_doll':
      return l10n.bagItemBoneDollDesc;
    case 'yarn_ball':
      return l10n.bagItemYarnBallDesc;
    default:
      return item.description;
  }
}

BagItem bagWireframeRandomTicketDef(int ticketCount) {
  return BagItem(
    category: 'ticket',
    name: 'random_adoption_ticket',
    description: '',
    quantity: ticketCount > 0 ? ticketCount : 1,
    icon: Icons.confirmation_number_outlined,
    usable: false,
  );
}

List<BagItem> defaultToyBagItems() {
  return const [
    BagItem(
      category: 'toy',
      name: 'bone_doll',
      description: '',
      quantity: 1,
      icon: Icons.cruelty_free_outlined,
      usable: false,
      targetPetFamily: 'dog',
    ),
    BagItem(
      category: 'toy',
      name: 'yarn_ball',
      description: '',
      quantity: 1,
      icon: Icons.sports_baseball_outlined,
      usable: false,
      targetPetFamily: 'cat',
    ),
  ];
}
