import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ko'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In ko, this message translates to:
  /// **'VegePet'**
  String get appTitle;

  /// No description provided for @settings.
  ///
  /// In ko, this message translates to:
  /// **'설정'**
  String get settings;

  /// No description provided for @account.
  ///
  /// In ko, this message translates to:
  /// **'계정'**
  String get account;

  /// No description provided for @language.
  ///
  /// In ko, this message translates to:
  /// **'언어'**
  String get language;

  /// No description provided for @languageSettingsTitle.
  ///
  /// In ko, this message translates to:
  /// **'Language'**
  String get languageSettingsTitle;

  /// No description provided for @pushNotifications.
  ///
  /// In ko, this message translates to:
  /// **'푸쉬 알림'**
  String get pushNotifications;

  /// No description provided for @customerSupport.
  ///
  /// In ko, this message translates to:
  /// **'고객지원'**
  String get customerSupport;

  /// No description provided for @korean.
  ///
  /// In ko, this message translates to:
  /// **'한국어'**
  String get korean;

  /// No description provided for @english.
  ///
  /// In ko, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @selectLanguage.
  ///
  /// In ko, this message translates to:
  /// **'언어 선택'**
  String get selectLanguage;

  /// No description provided for @languageDescription.
  ///
  /// In ko, this message translates to:
  /// **'앱에서 사용할 언어를 선택해주세요.'**
  String get languageDescription;

  /// No description provided for @languageChanged.
  ///
  /// In ko, this message translates to:
  /// **'언어가 변경되었어요.'**
  String get languageChanged;

  /// No description provided for @languageKorean.
  ///
  /// In ko, this message translates to:
  /// **'한국어'**
  String get languageKorean;

  /// No description provided for @languageEnglish.
  ///
  /// In ko, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @comingSoon.
  ///
  /// In ko, this message translates to:
  /// **'2차 오픈 예정이에요.'**
  String get comingSoon;

  /// No description provided for @paymentHistory.
  ///
  /// In ko, this message translates to:
  /// **'결제 내역'**
  String get paymentHistory;

  /// No description provided for @withdrawAccount.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴'**
  String get withdrawAccount;

  /// No description provided for @emailAccountLink.
  ///
  /// In ko, this message translates to:
  /// **'이메일 계정 연동'**
  String get emailAccountLink;

  /// No description provided for @emailLinkCompleted.
  ///
  /// In ko, this message translates to:
  /// **'이메일 연동 완료'**
  String get emailLinkCompleted;

  /// No description provided for @guestAccount.
  ///
  /// In ko, this message translates to:
  /// **'게스트 체험 계정'**
  String get guestAccount;

  /// No description provided for @emailLinkedAccount.
  ///
  /// In ko, this message translates to:
  /// **'이메일 연동 계정'**
  String get emailLinkedAccount;

  /// No description provided for @noLinkedEmail.
  ///
  /// In ko, this message translates to:
  /// **'연동된 이메일 없음'**
  String get noLinkedEmail;

  /// No description provided for @pushNoticeEvent.
  ///
  /// In ko, this message translates to:
  /// **'공지 및 이벤트'**
  String get pushNoticeEvent;

  /// No description provided for @pushMealReminder.
  ///
  /// In ko, this message translates to:
  /// **'먹이(식단사진)'**
  String get pushMealReminder;

  /// No description provided for @pushNoticeEventDescription.
  ///
  /// In ko, this message translates to:
  /// **'운영자가 보내는 공지와 이벤트 알림을 받아요.'**
  String get pushNoticeEventDescription;

  /// No description provided for @pushMealReminderDescription.
  ///
  /// In ko, this message translates to:
  /// **'아점과 저녁 시간에 식단 사진 알림을 받아요.'**
  String get pushMealReminderDescription;

  /// No description provided for @notificationPermissionDenied.
  ///
  /// In ko, this message translates to:
  /// **'알림 권한이 꺼져 있어요. 기기 설정에서 알림을 허용해주세요.'**
  String get notificationPermissionDenied;

  /// No description provided for @mealReminderEnabled.
  ///
  /// In ko, this message translates to:
  /// **'먹이 알림이 켜졌어요.'**
  String get mealReminderEnabled;

  /// No description provided for @mealReminderDisabled.
  ///
  /// In ko, this message translates to:
  /// **'먹이 알림이 꺼졌어요.'**
  String get mealReminderDisabled;

  /// No description provided for @noticeEventEnabled.
  ///
  /// In ko, this message translates to:
  /// **'공지 및 이벤트 알림이 켜졌어요.'**
  String get noticeEventEnabled;

  /// No description provided for @noticeEventDisabled.
  ///
  /// In ko, this message translates to:
  /// **'공지 및 이벤트 알림이 꺼졌어요.'**
  String get noticeEventDisabled;

  /// No description provided for @mealNotificationMessage1.
  ///
  /// In ko, this message translates to:
  /// **'베지펫이 배가 고플 시간이에요!'**
  String get mealNotificationMessage1;

  /// No description provided for @mealNotificationMessage2.
  ///
  /// In ko, this message translates to:
  /// **'베지펫에게 건강한 음식을 줄 시간이에요!'**
  String get mealNotificationMessage2;

  /// No description provided for @mealNotificationTitle.
  ///
  /// In ko, this message translates to:
  /// **'베지펫 식사 시간'**
  String get mealNotificationTitle;

  /// No description provided for @sound.
  ///
  /// In ko, this message translates to:
  /// **'사운드'**
  String get sound;

  /// No description provided for @backgroundMusic.
  ///
  /// In ko, this message translates to:
  /// **'배경음악'**
  String get backgroundMusic;

  /// No description provided for @backgroundMusicDescription.
  ///
  /// In ko, this message translates to:
  /// **'마당에서 흐르는 배경음악을 켜거나 꺼요.'**
  String get backgroundMusicDescription;

  /// No description provided for @soundEffects.
  ///
  /// In ko, this message translates to:
  /// **'효과음'**
  String get soundEffects;

  /// No description provided for @soundEffectsDescription.
  ///
  /// In ko, this message translates to:
  /// **'버튼과 상호작용 효과음을 켜거나 꺼요.'**
  String get soundEffectsDescription;

  /// No description provided for @backgroundMusicEnabled.
  ///
  /// In ko, this message translates to:
  /// **'배경음악이 켜졌어요.'**
  String get backgroundMusicEnabled;

  /// No description provided for @backgroundMusicDisabled.
  ///
  /// In ko, this message translates to:
  /// **'배경음악이 꺼졌어요.'**
  String get backgroundMusicDisabled;

  /// No description provided for @soundEffectsEnabled.
  ///
  /// In ko, this message translates to:
  /// **'효과음이 켜졌어요.'**
  String get soundEffectsEnabled;

  /// No description provided for @soundEffectsDisabled.
  ///
  /// In ko, this message translates to:
  /// **'효과음이 꺼졌어요.'**
  String get soundEffectsDisabled;

  /// No description provided for @supportCenter.
  ///
  /// In ko, this message translates to:
  /// **'고객센터'**
  String get supportCenter;

  /// No description provided for @contactAndFeedback.
  ///
  /// In ko, this message translates to:
  /// **'문의 및 건의'**
  String get contactAndFeedback;

  /// No description provided for @supportEmail.
  ///
  /// In ko, this message translates to:
  /// **'문의 및 건의 : acoustic.jwg@gmail.com'**
  String get supportEmail;

  /// No description provided for @copyEmail.
  ///
  /// In ko, this message translates to:
  /// **'이메일 복사'**
  String get copyEmail;

  /// No description provided for @emailCopied.
  ///
  /// In ko, this message translates to:
  /// **'이메일 주소가 복사되었어요.'**
  String get emailCopied;

  /// No description provided for @termsOfService.
  ///
  /// In ko, this message translates to:
  /// **'이용약관'**
  String get termsOfService;

  /// No description provided for @privacyPolicy.
  ///
  /// In ko, this message translates to:
  /// **'개인정보 보호정책'**
  String get privacyPolicy;

  /// No description provided for @operationPolicy.
  ///
  /// In ko, this message translates to:
  /// **'운영정책'**
  String get operationPolicy;

  /// No description provided for @guardianGuide.
  ///
  /// In ko, this message translates to:
  /// **'보호자용 가이드'**
  String get guardianGuide;

  /// No description provided for @accountDataDeletionGuide.
  ///
  /// In ko, this message translates to:
  /// **'계정 및 데이터 삭제 안내'**
  String get accountDataDeletionGuide;

  /// No description provided for @legalNoticeDraft.
  ///
  /// In ko, this message translates to:
  /// **'본 문서는 베지펫 앱 내 안내용 초안이며, 실제 출시 전 법무/개인정보 전문가 검토가 필요합니다.'**
  String get legalNoticeDraft;

  /// No description provided for @lastUpdated.
  ///
  /// In ko, this message translates to:
  /// **'최종 업데이트'**
  String get lastUpdated;

  /// No description provided for @effectiveDate.
  ///
  /// In ko, this message translates to:
  /// **'시행일'**
  String get effectiveDate;

  /// No description provided for @close.
  ///
  /// In ko, this message translates to:
  /// **'닫기'**
  String get close;

  /// No description provided for @petInfoTooltip.
  ///
  /// In ko, this message translates to:
  /// **'펫 정보'**
  String get petInfoTooltip;

  /// No description provided for @petInfoTitle.
  ///
  /// In ko, this message translates to:
  /// **'베지펫 정보'**
  String get petInfoTitle;

  /// No description provided for @petInfoNameLabel.
  ///
  /// In ko, this message translates to:
  /// **'이름'**
  String get petInfoNameLabel;

  /// No description provided for @petInfoSpeciesLabel.
  ///
  /// In ko, this message translates to:
  /// **'종류'**
  String get petInfoSpeciesLabel;

  /// No description provided for @petInfoStageLabel.
  ///
  /// In ko, this message translates to:
  /// **'단계'**
  String get petInfoStageLabel;

  /// No description provided for @petInfoFeedAction.
  ///
  /// In ko, this message translates to:
  /// **'먹이(식단사진) 주기'**
  String get petInfoFeedAction;

  /// No description provided for @petInfoPlayAction.
  ///
  /// In ko, this message translates to:
  /// **'놀아주기'**
  String get petInfoPlayAction;

  /// No description provided for @petInfoPetAction.
  ///
  /// In ko, this message translates to:
  /// **'쓰다듬기'**
  String get petInfoPetAction;

  /// No description provided for @petInfoMealTimeGuide.
  ///
  /// In ko, this message translates to:
  /// **'아점 : 06시~14시 / 저녁 : 17시~22시'**
  String get petInfoMealTimeGuide;

  /// No description provided for @petInfoStatusDone.
  ///
  /// In ko, this message translates to:
  /// **'완료'**
  String get petInfoStatusDone;

  /// No description provided for @petInfoStatusAvailable.
  ///
  /// In ko, this message translates to:
  /// **'가능'**
  String get petInfoStatusAvailable;

  /// No description provided for @petInfoCurrentAffection.
  ///
  /// In ko, this message translates to:
  /// **'현재 애정도'**
  String get petInfoCurrentAffection;

  /// No description provided for @petInfoStageComplete.
  ///
  /// In ko, this message translates to:
  /// **'성숙기 달성 완료'**
  String get petInfoStageComplete;

  /// No description provided for @petInfoUntilAdult.
  ///
  /// In ko, this message translates to:
  /// **'성숙기까지'**
  String get petInfoUntilAdult;

  /// No description provided for @petInfoUntilGrown.
  ///
  /// In ko, this message translates to:
  /// **'성장기까지'**
  String get petInfoUntilGrown;

  /// No description provided for @petInfoUntilChild.
  ///
  /// In ko, this message translates to:
  /// **'유년기까지'**
  String get petInfoUntilChild;

  /// No description provided for @gameMenuTooltip.
  ///
  /// In ko, this message translates to:
  /// **'게임 메뉴'**
  String get gameMenuTooltip;

  /// No description provided for @profileSetupTitle.
  ///
  /// In ko, this message translates to:
  /// **'프로필을 입력해주세요!'**
  String get profileSetupTitle;

  /// No description provided for @nickname.
  ///
  /// In ko, this message translates to:
  /// **'닉네임'**
  String get nickname;

  /// No description provided for @gender.
  ///
  /// In ko, this message translates to:
  /// **'성별'**
  String get gender;

  /// No description provided for @ageRange.
  ///
  /// In ko, this message translates to:
  /// **'나이대'**
  String get ageRange;

  /// No description provided for @dietGoal.
  ///
  /// In ko, this message translates to:
  /// **'식단목적'**
  String get dietGoal;

  /// No description provided for @start.
  ///
  /// In ko, this message translates to:
  /// **'시작하기'**
  String get start;

  /// No description provided for @inYardLoading.
  ///
  /// In ko, this message translates to:
  /// **'불러오는 중...'**
  String get inYardLoading;

  /// No description provided for @inYardErrorTitle.
  ///
  /// In ko, this message translates to:
  /// **'앱 준비 중 문제가 발생했어요'**
  String get inYardErrorTitle;

  /// No description provided for @retry.
  ///
  /// In ko, this message translates to:
  /// **'다시 시도'**
  String get retry;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
