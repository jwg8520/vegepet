// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'VegePet';

  @override
  String get settings => '설정';

  @override
  String get account => '계정';

  @override
  String get language => '언어';

  @override
  String get pushNotifications => '푸쉬 알림';

  @override
  String get customerSupport => '고객지원';

  @override
  String get korean => '한국어';

  @override
  String get english => 'English';

  @override
  String get selectLanguage => '언어 선택';

  @override
  String get languageDescription => '앱에서 사용할 언어를 선택해주세요.';

  @override
  String get languageChanged => '언어가 변경되었어요.';

  @override
  String get languageKorean => '한국어';

  @override
  String get languageEnglish => 'English';

  @override
  String get comingSoon => '2차 오픈 예정이에요.';

  @override
  String get paymentHistory => '결제 내역';

  @override
  String get withdrawAccount => '회원 탈퇴';

  @override
  String get emailAccountLink => '이메일 계정 연동';

  @override
  String get emailLinkCompleted => '이메일 연동 완료';

  @override
  String get guestAccount => '게스트 체험 계정';

  @override
  String get emailLinkedAccount => '이메일 연동 계정';

  @override
  String get noLinkedEmail => '연동된 이메일 없음';

  @override
  String get pushNoticeEvent => '공지 및 이벤트';

  @override
  String get pushMealReminder => '먹이(식단사진)';

  @override
  String get pushNoticeEventDescription => '운영자가 보내는 공지와 이벤트 알림을 받아요.';

  @override
  String get pushMealReminderDescription => '아점과 저녁 시간에 식단 사진 알림을 받아요.';

  @override
  String get notificationPermissionDenied =>
      '알림 권한이 꺼져 있어요. 기기 설정에서 알림을 허용해주세요.';

  @override
  String get mealReminderEnabled => '먹이 알림이 켜졌어요.';

  @override
  String get mealReminderDisabled => '먹이 알림이 꺼졌어요.';

  @override
  String get noticeEventEnabled => '공지 및 이벤트 알림이 켜졌어요.';

  @override
  String get noticeEventDisabled => '공지 및 이벤트 알림이 꺼졌어요.';

  @override
  String get mealNotificationMessage1 => '베지펫이 배가 고플 시간이에요!';

  @override
  String get mealNotificationMessage2 => '베지펫에게 건강한 음식을 줄 시간이에요!';

  @override
  String get mealNotificationTitle => '베지펫 식사 시간';
}
