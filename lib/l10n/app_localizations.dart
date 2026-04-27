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
