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
  /// **'먹이(식단인증)'**
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
  /// **'이메일이 복사되었어요.'**
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

  /// No description provided for @petInfoFeedShort.
  ///
  /// In ko, this message translates to:
  /// **'먹이주기'**
  String get petInfoFeedShort;

  /// No description provided for @petInfoMealCheckBubble.
  ///
  /// In ko, this message translates to:
  /// **'식단 인증!'**
  String get petInfoMealCheckBubble;

  /// No description provided for @gameMenuTooltip.
  ///
  /// In ko, this message translates to:
  /// **'게임 메뉴'**
  String get gameMenuTooltip;

  /// No description provided for @gameMenuPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'메뉴'**
  String get gameMenuPanelTitle;

  /// No description provided for @menuLabelProfile.
  ///
  /// In ko, this message translates to:
  /// **'프로필'**
  String get menuLabelProfile;

  /// No description provided for @menuLabelDietDiary.
  ///
  /// In ko, this message translates to:
  /// **'식단일지'**
  String get menuLabelDietDiary;

  /// No description provided for @menuLabelBag.
  ///
  /// In ko, this message translates to:
  /// **'가방'**
  String get menuLabelBag;

  /// No description provided for @menuLabelShop.
  ///
  /// In ko, this message translates to:
  /// **'상점'**
  String get menuLabelShop;

  /// No description provided for @menuLabelPokedex.
  ///
  /// In ko, this message translates to:
  /// **'도감'**
  String get menuLabelPokedex;

  /// No description provided for @menuLabelStory.
  ///
  /// In ko, this message translates to:
  /// **'스토리'**
  String get menuLabelStory;

  /// No description provided for @menuLabelHelp.
  ///
  /// In ko, this message translates to:
  /// **'도움말'**
  String get menuLabelHelp;

  /// No description provided for @menuLabelSettings.
  ///
  /// In ko, this message translates to:
  /// **'설정'**
  String get menuLabelSettings;

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
  /// **'식단 목적'**
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

  /// No description provided for @initialAdoptionTitle.
  ///
  /// In ko, this message translates to:
  /// **'아기 베지펫을 분양 받을 차례에요!'**
  String get initialAdoptionTitle;

  /// No description provided for @initialAdoptionDescription.
  ///
  /// In ko, this message translates to:
  /// **'베지펫은 사용자의 건강한 식단을 먹고 자라게 됩니다.'**
  String get initialAdoptionDescription;

  /// No description provided for @initialAdoptionDogSectionLabel.
  ///
  /// In ko, this message translates to:
  /// **'강아지'**
  String get initialAdoptionDogSectionLabel;

  /// No description provided for @initialAdoptionCatSectionLabel.
  ///
  /// In ko, this message translates to:
  /// **'고양이'**
  String get initialAdoptionCatSectionLabel;

  /// No description provided for @initialAdoptionReceiveButton.
  ///
  /// In ko, this message translates to:
  /// **'분양받기'**
  String get initialAdoptionReceiveButton;

  /// No description provided for @mealPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'먹이주기'**
  String get mealPanelTitle;

  /// No description provided for @mealPanelTodayCertLabel.
  ///
  /// In ko, this message translates to:
  /// **'오늘의 식단 인증!'**
  String get mealPanelTodayCertLabel;

  /// No description provided for @mealPanelBrunchButton.
  ///
  /// In ko, this message translates to:
  /// **'아점 식단'**
  String get mealPanelBrunchButton;

  /// No description provided for @mealPanelDinnerButton.
  ///
  /// In ko, this message translates to:
  /// **'저녁 식단'**
  String get mealPanelDinnerButton;

  /// No description provided for @mealPanelFootnote1.
  ///
  /// In ko, this message translates to:
  /// **'• 아점 : 06 ~ 14시 / 저녁 : 17 ~ 22시'**
  String get mealPanelFootnote1;

  /// No description provided for @mealPanelFootnote2.
  ///
  /// In ko, this message translates to:
  /// **'• 실시간 카메라로 촬영된 사진만 AI 판정에 사용돼요.'**
  String get mealPanelFootnote2;

  /// No description provided for @mealPanelFootnote3.
  ///
  /// In ko, this message translates to:
  /// **'• 촬영된 식단 사진은 식단 일지에서 조회 가능해요.'**
  String get mealPanelFootnote3;

  /// No description provided for @mealPanelUploading.
  ///
  /// In ko, this message translates to:
  /// **'판정 중...'**
  String get mealPanelUploading;

  /// No description provided for @profilePanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'프로필'**
  String get profilePanelTitle;

  /// No description provided for @profilePanelFootnoteAi.
  ///
  /// In ko, this message translates to:
  /// **'• 성별/나이대/식단 목적 기반으로 식단이 피드백돼요!'**
  String get profilePanelFootnoteAi;

  /// No description provided for @profileAutoSaveHint.
  ///
  /// In ko, this message translates to:
  /// **'• 프로필 변경 후 창을 나가면 자동으로 저장돼요!'**
  String get profileAutoSaveHint;

  /// No description provided for @petNamingTitle.
  ///
  /// In ko, this message translates to:
  /// **'아기 베지펫이 분양 되었어요🥹'**
  String get petNamingTitle;

  /// No description provided for @petNamingSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'귀여운 이름을 지어주세요!'**
  String get petNamingSubtitle;

  /// No description provided for @petNamingHint.
  ///
  /// In ko, this message translates to:
  /// **'이름을 지어주세요.'**
  String get petNamingHint;

  /// No description provided for @petNamingSave.
  ///
  /// In ko, this message translates to:
  /// **'저장'**
  String get petNamingSave;

  /// No description provided for @petNamingEnterNameError.
  ///
  /// In ko, this message translates to:
  /// **'이름을 입력해주세요.'**
  String get petNamingEnterNameError;

  /// No description provided for @petNamingLengthError.
  ///
  /// In ko, this message translates to:
  /// **'이름은 2~8자로 입력해주세요.'**
  String get petNamingLengthError;

  /// No description provided for @petNamingSpecialCharError.
  ///
  /// In ko, this message translates to:
  /// **'특수문자는 사용할 수 없어요.'**
  String get petNamingSpecialCharError;

  /// No description provided for @dietDiaryPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'식단일지'**
  String get dietDiaryPanelTitle;

  /// No description provided for @dietDiaryMonthPickerTitle.
  ///
  /// In ko, this message translates to:
  /// **'월 선택'**
  String get dietDiaryMonthPickerTitle;

  /// No description provided for @dietDiarySavedSnackbar.
  ///
  /// In ko, this message translates to:
  /// **'식단일지가 저장되었어요.'**
  String get dietDiarySavedSnackbar;

  /// No description provided for @bagPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'가방'**
  String get bagPanelTitle;

  /// No description provided for @bagSectionTickets.
  ///
  /// In ko, this message translates to:
  /// **'• 분양권'**
  String get bagSectionTickets;

  /// No description provided for @bagSectionToys.
  ///
  /// In ko, this message translates to:
  /// **'• 장난감'**
  String get bagSectionToys;

  /// No description provided for @bagSectionFurniture.
  ///
  /// In ko, this message translates to:
  /// **'• 가구'**
  String get bagSectionFurniture;

  /// No description provided for @bagUseAction.
  ///
  /// In ko, this message translates to:
  /// **'사용하기'**
  String get bagUseAction;

  /// No description provided for @bagItemRandomTicketName.
  ///
  /// In ko, this message translates to:
  /// **'분양권(랜덤)'**
  String get bagItemRandomTicketName;

  /// No description provided for @bagItemRandomTicketDesc.
  ///
  /// In ko, this message translates to:
  /// **' 성숙기를 달성하면 주는 베지펫 랜덤 분양양 티켓. 사용 시 귀여운 베지펫 1마리를 랜덤으로 분양받을 수 있다!'**
  String get bagItemRandomTicketDesc;

  /// No description provided for @bagItemBoneDollName.
  ///
  /// In ko, this message translates to:
  /// **'뼈다귀 인형'**
  String get bagItemBoneDollName;

  /// No description provided for @bagItemBoneDollDesc.
  ///
  /// In ko, this message translates to:
  /// **' 강아지 베지펫들이 좋아하는 뼈다귀 모양의 장난감. 깨물면 채소맛이 느껴지는 특수 제작 장난감이다.'**
  String get bagItemBoneDollDesc;

  /// No description provided for @bagItemYarnBallName.
  ///
  /// In ko, this message translates to:
  /// **'실뭉치'**
  String get bagItemYarnBallName;

  /// No description provided for @bagItemYarnBallDesc.
  ///
  /// In ko, this message translates to:
  /// **' 고양이 베지펫들이 좋아하는 실뭉치 장난감. 이리저리 툭툭 치고 노는 모습을 보면 애정이 솟아오르는 것 같다.'**
  String get bagItemYarnBallDesc;

  /// No description provided for @randomTicketUseConfirmMessage.
  ///
  /// In ko, this message translates to:
  /// **'\'분양권(랜덤)\'을 사용하시겠습니까?'**
  String get randomTicketUseConfirmMessage;

  /// No description provided for @randomTicketUseConfirmDesc.
  ///
  /// In ko, this message translates to:
  /// **'사용된 아이템은 되돌릴 수 없습니다.'**
  String get randomTicketUseConfirmDesc;

  /// No description provided for @useLabel.
  ///
  /// In ko, this message translates to:
  /// **'사용'**
  String get useLabel;

  /// No description provided for @cancelLabel.
  ///
  /// In ko, this message translates to:
  /// **'취소'**
  String get cancelLabel;

  /// No description provided for @confirmLabel.
  ///
  /// In ko, this message translates to:
  /// **'확인'**
  String get confirmLabel;

  /// No description provided for @pokedexPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'도감'**
  String get pokedexPanelTitle;

  /// No description provided for @pokedexSectionDogs.
  ///
  /// In ko, this message translates to:
  /// **'• 강아지'**
  String get pokedexSectionDogs;

  /// No description provided for @pokedexSectionCats.
  ///
  /// In ko, this message translates to:
  /// **'• 고양이'**
  String get pokedexSectionCats;

  /// No description provided for @pokedexUnknownLabel.
  ///
  /// In ko, this message translates to:
  /// **'???'**
  String get pokedexUnknownLabel;

  /// No description provided for @pokedexDefaultPetName.
  ///
  /// In ko, this message translates to:
  /// **'베지펫'**
  String get pokedexDefaultPetName;

  /// No description provided for @storyPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'스토리'**
  String get storyPanelTitle;

  /// No description provided for @helpPanelTitle.
  ///
  /// In ko, this message translates to:
  /// **'도움말'**
  String get helpPanelTitle;

  /// No description provided for @shopNoticeTitle.
  ///
  /// In ko, this message translates to:
  /// **'오픈 준비중...'**
  String get shopNoticeTitle;

  /// No description provided for @shopNoticeDescription.
  ///
  /// In ko, this message translates to:
  /// **'조금만 기다려주세요!'**
  String get shopNoticeDescription;

  /// No description provided for @withdrawConfirmTitle.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴'**
  String get withdrawConfirmTitle;

  /// No description provided for @withdrawConfirmDescription.
  ///
  /// In ko, this message translates to:
  /// **'현재 계정의 펫, 식단 일지 등 모든 기록이 초기화 되며, 되돌릴 수 없어요. 정말 탈퇴할까요?'**
  String get withdrawConfirmDescription;

  /// No description provided for @withdrawConfirmDeleteButton.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴'**
  String get withdrawConfirmDeleteButton;

  /// No description provided for @withdrawFinalTitle.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴 확인'**
  String get withdrawFinalTitle;

  /// No description provided for @withdrawFinalDescription.
  ///
  /// In ko, this message translates to:
  /// **'아래 버튼을 누르면 회원 탈퇴가 최종 완료됩니다.'**
  String get withdrawFinalDescription;

  /// No description provided for @withdrawFinalDeleteButton.
  ///
  /// In ko, this message translates to:
  /// **'최종 탈퇴'**
  String get withdrawFinalDeleteButton;

  /// No description provided for @nameInterlockMain.
  ///
  /// In ko, this message translates to:
  /// **'다시 입력해주세요.'**
  String get nameInterlockMain;

  /// No description provided for @nameInterlockSub.
  ///
  /// In ko, this message translates to:
  /// **'※ 2 ~ 8글자 제한 / 특수 문자 금지!'**
  String get nameInterlockSub;

  /// No description provided for @stageBaby.
  ///
  /// In ko, this message translates to:
  /// **'유아기'**
  String get stageBaby;

  /// No description provided for @stageChild.
  ///
  /// In ko, this message translates to:
  /// **'유년기'**
  String get stageChild;

  /// No description provided for @stageGrown.
  ///
  /// In ko, this message translates to:
  /// **'성장기'**
  String get stageGrown;

  /// No description provided for @stageAdult.
  ///
  /// In ko, this message translates to:
  /// **'성숙기'**
  String get stageAdult;

  /// No description provided for @familyDog.
  ///
  /// In ko, this message translates to:
  /// **'강아지'**
  String get familyDog;

  /// No description provided for @familyCat.
  ///
  /// In ko, this message translates to:
  /// **'고양이'**
  String get familyCat;

  /// No description provided for @defaultPetName.
  ///
  /// In ko, this message translates to:
  /// **'펫'**
  String get defaultPetName;

  /// No description provided for @adoptionTitleAlt.
  ///
  /// In ko, this message translates to:
  /// **'베지펫을 분양 받을 차례에요!'**
  String get adoptionTitleAlt;

  /// No description provided for @adoptionReceiveButtonExclaim.
  ///
  /// In ko, this message translates to:
  /// **'분양받기!'**
  String get adoptionReceiveButtonExclaim;

  /// No description provided for @snackLoginRequired.
  ///
  /// In ko, this message translates to:
  /// **'로그인이 필요해요.'**
  String get snackLoginRequired;

  /// No description provided for @snackInvalidEmail.
  ///
  /// In ko, this message translates to:
  /// **'올바른 이메일 형식으로 입력해주세요.'**
  String get snackInvalidEmail;

  /// No description provided for @snackEmailRequired.
  ///
  /// In ko, this message translates to:
  /// **'이메일을 입력해주세요.'**
  String get snackEmailRequired;

  /// No description provided for @snackOtpRequired.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드를 입력해주세요.'**
  String get snackOtpRequired;

  /// No description provided for @snackEmailAlreadyLinked.
  ///
  /// In ko, this message translates to:
  /// **'이미 이메일 계정으로 연동되어 있어요.'**
  String get snackEmailAlreadyLinked;

  /// No description provided for @snackEmailLinkCompleted.
  ///
  /// In ko, this message translates to:
  /// **'이메일 계정 연동이 완료되었어요.'**
  String get snackEmailLinkCompleted;

  /// No description provided for @snackTicketEmpty.
  ///
  /// In ko, this message translates to:
  /// **'보유 중인 랜덤 분양권이 없어요.'**
  String get snackTicketEmpty;

  /// No description provided for @snackTicketBlockedDuringGrowth.
  ///
  /// In ko, this message translates to:
  /// **'현재 육성 중인 베지펫이 있어요. 성숙기 달성 후 사용할 수 있어요.'**
  String get snackTicketBlockedDuringGrowth;

  /// No description provided for @snackTicketDuplicatePokedex.
  ///
  /// In ko, this message translates to:
  /// **'이미 도감에 등록된 베지펫이 반환되었어요. 분양 로직을 확인해주세요.'**
  String get snackTicketDuplicatePokedex;

  /// No description provided for @snackAdoptError.
  ///
  /// In ko, this message translates to:
  /// **'분양 결과를 해석할 수 없어요. 잠시 후 다시 시도해주세요.'**
  String get snackAdoptError;

  /// No description provided for @snackPetActionInvalid.
  ///
  /// In ko, this message translates to:
  /// **'펫 정보를 확인할 수 없어요.'**
  String get snackPetActionInvalid;

  /// No description provided for @snackAdoptFirst.
  ///
  /// In ko, this message translates to:
  /// **'먼저 펫을 분양받아주세요.'**
  String get snackAdoptFirst;

  /// No description provided for @snackPlayedToday.
  ///
  /// In ko, this message translates to:
  /// **'오늘은 이미 놀아줬어요.'**
  String get snackPlayedToday;

  /// No description provided for @snackRandomTicketGranted.
  ///
  /// In ko, this message translates to:
  /// **'랜덤 분양권을 획득했어요!'**
  String get snackRandomTicketGranted;

  /// No description provided for @snackStageReachedAdult.
  ///
  /// In ko, this message translates to:
  /// **'베지펫이 성숙기에 도달했어요! 육성이 완료되었어요!'**
  String get snackStageReachedAdult;

  /// No description provided for @settingsSectionAccountBullet.
  ///
  /// In ko, this message translates to:
  /// **'• 계정'**
  String get settingsSectionAccountBullet;

  /// No description provided for @settingsSectionLanguageBullet.
  ///
  /// In ko, this message translates to:
  /// **'• Language'**
  String get settingsSectionLanguageBullet;

  /// No description provided for @settingsSectionPushBullet.
  ///
  /// In ko, this message translates to:
  /// **'• 푸쉬 알림'**
  String get settingsSectionPushBullet;

  /// No description provided for @settingsSectionSoundBullet.
  ///
  /// In ko, this message translates to:
  /// **'• 사운드'**
  String get settingsSectionSoundBullet;

  /// No description provided for @settingsSectionSupportBullet.
  ///
  /// In ko, this message translates to:
  /// **'• 고객지원'**
  String get settingsSectionSupportBullet;

  /// No description provided for @settingsGuestUserIdLine.
  ///
  /// In ko, this message translates to:
  /// **'Guest : {userIdPrefix}'**
  String settingsGuestUserIdLine(String userIdPrefix);

  /// No description provided for @emailLinkSendOtpButton.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드 받기'**
  String get emailLinkSendOtpButton;

  /// No description provided for @emailLinkEmailRowLabel.
  ///
  /// In ko, this message translates to:
  /// **'• 이메일'**
  String get emailLinkEmailRowLabel;

  /// No description provided for @emailLinkOtpRowLabel.
  ///
  /// In ko, this message translates to:
  /// **'• 인증 코드'**
  String get emailLinkOtpRowLabel;

  /// No description provided for @emailLinkResendCodeButton.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드 다시 받기'**
  String get emailLinkResendCodeButton;

  /// No description provided for @emailLinkVerifyCompleteButton.
  ///
  /// In ko, this message translates to:
  /// **'인증 완료'**
  String get emailLinkVerifyCompleteButton;

  /// No description provided for @emailOtpRetryAfterSeconds.
  ///
  /// In ko, this message translates to:
  /// **'{seconds}초 후에 재전송 가능'**
  String emailOtpRetryAfterSeconds(int seconds);

  /// No description provided for @emailAlreadyUsedTitle.
  ///
  /// In ko, this message translates to:
  /// **'이메일 연동 불가'**
  String get emailAlreadyUsedTitle;

  /// No description provided for @emailAlreadyUsedBody.
  ///
  /// In ko, this message translates to:
  /// **'이미 사용된 이메일입니다.\n다른 이메일을 입력해주세요.'**
  String get emailAlreadyUsedBody;

  /// No description provided for @emailLinkInviteTitle.
  ///
  /// In ko, this message translates to:
  /// **'베지펫을 지켜주세요!'**
  String get emailLinkInviteTitle;

  /// No description provided for @emailLinkInviteBodyLine1.
  ///
  /// In ko, this message translates to:
  /// **'앱이 지워지면 귀여운 베지펫이 사라져요..😢'**
  String get emailLinkInviteBodyLine1;

  /// No description provided for @emailLinkInviteBodyLine2.
  ///
  /// In ko, this message translates to:
  /// **'지금 설정에서 이메일 연동을 진행할까요?'**
  String get emailLinkInviteBodyLine2;

  /// No description provided for @emailLinkInviteLater.
  ///
  /// In ko, this message translates to:
  /// **'나중에'**
  String get emailLinkInviteLater;

  /// No description provided for @emailLinkInviteNow.
  ///
  /// In ko, this message translates to:
  /// **'연동하기'**
  String get emailLinkInviteNow;

  /// No description provided for @emailLinkSuccessTitle.
  ///
  /// In ko, this message translates to:
  /// **'연동 완료💫'**
  String get emailLinkSuccessTitle;

  /// No description provided for @emailLinkSuccessBody.
  ///
  /// In ko, this message translates to:
  /// **'기존 계정 정보가 있다면 자동으로 불러옵니다.'**
  String get emailLinkSuccessBody;

  /// No description provided for @emailLinkSuccessConfirm.
  ///
  /// In ko, this message translates to:
  /// **'확인'**
  String get emailLinkSuccessConfirm;

  /// No description provided for @emailFormatErrorTitle.
  ///
  /// In ko, this message translates to:
  /// **'이메일 형식 오류'**
  String get emailFormatErrorTitle;

  /// No description provided for @emailFormatErrorBody.
  ///
  /// In ko, this message translates to:
  /// **'※ 올바른 이메일 형식을 입력해주세요!'**
  String get emailFormatErrorBody;

  /// No description provided for @emailFormatErrorConfirm.
  ///
  /// In ko, this message translates to:
  /// **'확인'**
  String get emailFormatErrorConfirm;

  /// No description provided for @saveLabel.
  ///
  /// In ko, this message translates to:
  /// **'저장'**
  String get saveLabel;

  /// No description provided for @diaryPhotoBrunchLabel.
  ///
  /// In ko, this message translates to:
  /// **'(아점)'**
  String get diaryPhotoBrunchLabel;

  /// No description provided for @diaryPhotoDinnerLabel.
  ///
  /// In ko, this message translates to:
  /// **'(저녁)'**
  String get diaryPhotoDinnerLabel;

  /// No description provided for @diaryWeightLabel.
  ///
  /// In ko, this message translates to:
  /// **'• 체중(Kg)'**
  String get diaryWeightLabel;

  /// No description provided for @diaryNoteLabel.
  ///
  /// In ko, this message translates to:
  /// **'• 식후 감정 & 실패 요인'**
  String get diaryNoteLabel;

  /// No description provided for @snackSelectGender.
  ///
  /// In ko, this message translates to:
  /// **'성별을 선택해주세요.'**
  String get snackSelectGender;

  /// No description provided for @snackSelectAgeRange.
  ///
  /// In ko, this message translates to:
  /// **'나이대를 선택해주세요.'**
  String get snackSelectAgeRange;

  /// No description provided for @snackSelectDietGoal.
  ///
  /// In ko, this message translates to:
  /// **'식단 목적을 선택해주세요.'**
  String get snackSelectDietGoal;

  /// No description provided for @snackProfileSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'프로필 저장 실패: {error}'**
  String snackProfileSaveFailed(String error);

  /// No description provided for @snackProfileSaved.
  ///
  /// In ko, this message translates to:
  /// **'프로필이 저장되었어요!'**
  String get snackProfileSaved;

  /// No description provided for @snackProfileLoadFailed.
  ///
  /// In ko, this message translates to:
  /// **'프로필 정보를 불러올 수 없어요.'**
  String get snackProfileLoadFailed;

  /// No description provided for @snackLanguageChangeFailed.
  ///
  /// In ko, this message translates to:
  /// **'언어 변경에 실패했어요. 다시 시도해주세요.'**
  String get snackLanguageChangeFailed;

  /// No description provided for @snackOtpSent.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드가 이메일로 발송되었어요.'**
  String get snackOtpSent;

  /// No description provided for @snackOtpSendFailed.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드 발송에 실패했어요: {error}'**
  String snackOtpSendFailed(String error);

  /// No description provided for @snackEmailOtpRequired.
  ///
  /// In ko, this message translates to:
  /// **'이메일과 인증 코드를 입력해주세요.'**
  String get snackEmailOtpRequired;

  /// No description provided for @snackOtpVerifyFailed.
  ///
  /// In ko, this message translates to:
  /// **'인증 코드 확인에 실패했어요: {error}'**
  String snackOtpVerifyFailed(String error);

  /// No description provided for @snackEmailLinkPartialSavedFailed.
  ///
  /// In ko, this message translates to:
  /// **'이메일 인증은 완료됐지만 프로필 상태 저장에 실패했어요. 설정을 다시 열어주세요.'**
  String get snackEmailLinkPartialSavedFailed;

  /// No description provided for @snackMealAlreadyCertified.
  ///
  /// In ko, this message translates to:
  /// **'이미 해당 식단 인증을 완료했어요.'**
  String get snackMealAlreadyCertified;

  /// No description provided for @snackMealSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'식단 인증 저장 실패: {error}'**
  String snackMealSaveFailed(String error);

  /// No description provided for @snackMealUploadFailed.
  ///
  /// In ko, this message translates to:
  /// **'사진 업로드에 실패했어요. 잠시 후 다시 시도해주세요.'**
  String get snackMealUploadFailed;

  /// No description provided for @snackMealAiFailed.
  ///
  /// In ko, this message translates to:
  /// **'AI 판정에 실패했어요. 잠시 후 다시 시도해주세요.'**
  String get snackMealAiFailed;

  /// No description provided for @snackMealUnknownError.
  ///
  /// In ko, this message translates to:
  /// **'식단 인증 중 오류가 발생했어요: {error}'**
  String snackMealUnknownError(String error);

  /// No description provided for @snackCameraUnavailable.
  ///
  /// In ko, this message translates to:
  /// **'카메라를 사용할 수 없어요: {error}'**
  String snackCameraUnavailable(String error);

  /// No description provided for @snackPetAlreadyGraduated.
  ///
  /// In ko, this message translates to:
  /// **'이미 졸업 처리된 베지펫이에요.'**
  String get snackPetAlreadyGraduated;

  /// No description provided for @snackPlayActionSuccess.
  ///
  /// In ko, this message translates to:
  /// **'{label} 성공! 애정도 +1'**
  String snackPlayActionSuccess(String label);

  /// No description provided for @snackPlayActionFailed.
  ///
  /// In ko, this message translates to:
  /// **'{label} 실패: {error}'**
  String snackPlayActionFailed(String label, String error);

  /// No description provided for @snackAlreadyRaising.
  ///
  /// In ko, this message translates to:
  /// **'이미 육성 중인 펫이 있어요.'**
  String get snackAlreadyRaising;

  /// No description provided for @snackPetSelectInvalid.
  ///
  /// In ko, this message translates to:
  /// **'펫 선택값이 올바르지 않아요.'**
  String get snackPetSelectInvalid;

  /// No description provided for @snackAdoptSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'분양 저장에 실패했어요: {error}'**
  String snackAdoptSaveFailed(String error);

  /// No description provided for @snackNameSaved.
  ///
  /// In ko, this message translates to:
  /// **'이름이 저장되었어요!'**
  String get snackNameSaved;

  /// No description provided for @snackNameSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'이름 저장 실패: {error}'**
  String snackNameSaveFailed(String error);

  /// No description provided for @snackPokedexFetchFailed.
  ///
  /// In ko, this message translates to:
  /// **'도감 정보를 불러오지 못했어요.'**
  String get snackPokedexFetchFailed;

  /// No description provided for @snackSpeciesFetchFailed.
  ///
  /// In ko, this message translates to:
  /// **'펫 종류 정보를 불러오지 못했어요.'**
  String get snackSpeciesFetchFailed;

  /// No description provided for @snackTicketUseFailed.
  ///
  /// In ko, this message translates to:
  /// **'분양권 사용 실패: {error}'**
  String snackTicketUseFailed(String error);

  /// No description provided for @snackOldPetDeactivateFailed.
  ///
  /// In ko, this message translates to:
  /// **'기존 펫 비활성화 실패: {error}'**
  String snackOldPetDeactivateFailed(String error);

  /// No description provided for @snackNewPetAdoptSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'새 베지펫 분양 저장 실패: {error}'**
  String snackNewPetAdoptSaveFailed(String error);

  /// No description provided for @snackNewPetAdopted.
  ///
  /// In ko, this message translates to:
  /// **'새 베지펫이 분양되었어요!'**
  String get snackNewPetAdopted;

  /// No description provided for @snackToyNotUsable.
  ///
  /// In ko, this message translates to:
  /// **'이 장난감은 이 베지펫에게 사용할 수 없어요.'**
  String get snackToyNotUsable;

  /// No description provided for @snackEnterName.
  ///
  /// In ko, this message translates to:
  /// **'이름을 입력해주세요.'**
  String get snackEnterName;

  /// No description provided for @snackComingLater.
  ///
  /// In ko, this message translates to:
  /// **'나중에 구현 예정: {label}'**
  String snackComingLater(String label);

  /// No description provided for @snackWithdrawCannotLogin.
  ///
  /// In ko, this message translates to:
  /// **'로그인 상태가 아니어서 탈퇴를 진행할 수 없어요.'**
  String get snackWithdrawCannotLogin;

  /// No description provided for @snackWithdrawCompleted.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴가 완료되었어요.'**
  String get snackWithdrawCompleted;

  /// No description provided for @snackWithdrawError.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴 처리 중 오류가 발생했어요: {error}'**
  String snackWithdrawError(String error);

  /// No description provided for @snackWeightNumberOnly.
  ///
  /// In ko, this message translates to:
  /// **'체중은 숫자로 입력해주세요.'**
  String get snackWeightNumberOnly;

  /// No description provided for @snackDiarySaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'식단일지 저장 실패: {error}'**
  String snackDiarySaveFailed(String error);

  /// No description provided for @snackStageGrewToChild.
  ///
  /// In ko, this message translates to:
  /// **'베지펫이 유년기로 성장했어요!'**
  String get snackStageGrewToChild;

  /// No description provided for @snackStageGrewToGrown.
  ///
  /// In ko, this message translates to:
  /// **'베지펫이 성장기로 자랐어요!'**
  String get snackStageGrewToGrown;

  /// No description provided for @snackStageGrewToAdult.
  ///
  /// In ko, this message translates to:
  /// **'베지펫이 성숙기에 도달했어요! 육성이 완료되었어요!'**
  String get snackStageGrewToAdult;

  /// No description provided for @snackGraduationFailed.
  ///
  /// In ko, this message translates to:
  /// **'성숙기 전환 처리 실패: {error}'**
  String snackGraduationFailed(String error);

  /// No description provided for @petActionPlay.
  ///
  /// In ko, this message translates to:
  /// **'놀아주기'**
  String get petActionPlay;

  /// No description provided for @petActionPet.
  ///
  /// In ko, this message translates to:
  /// **'쓰다듬기'**
  String get petActionPet;

  /// No description provided for @snackPlayedTodayAlready.
  ///
  /// In ko, this message translates to:
  /// **'오늘은 이미 놀아줬어요.'**
  String get snackPlayedTodayAlready;

  /// No description provided for @snackPettedTodayAlready.
  ///
  /// In ko, this message translates to:
  /// **'오늘은 이미 쓰다듬었어요.'**
  String get snackPettedTodayAlready;

  /// No description provided for @snackPetFetchFailed.
  ///
  /// In ko, this message translates to:
  /// **'펫 정보를 불러올 수 없어요: {error}'**
  String snackPetFetchFailed(String error);
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
