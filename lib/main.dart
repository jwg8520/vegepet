import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:vegepet/l10n/app_localizations.dart';

const _supabaseUrl = 'https://rzsioxnqljywhfyxccuh.supabase.co';
const _supabaseAnonKey = 'sb_publishable_y9uJosVyntByD4xBPr4AUA_q1i0Dlci';

// ============================================================================
// 식단 사진 업로드 + AI 판정 구조 (Edge Function 연동 준비)
// ----------------------------------------------------------------------------
// 최종 아키텍처 (아직 구현 전, 이번 단계에서는 뼈대/주석만 잡는다):
//   1) Flutter: 실시간 카메라로 식단 사진 촬영 (사진첩 업로드 금지)
//   2) Flutter: Supabase Storage bucket `_kMealPhotoBucket`에 업로드
//      경로 규약 예) `{user_id}/{meal_date}/{slot}-{timestamp}.jpg`
//   3) Flutter: `supabase.functions.invoke(_kMealEvaluateFunction, ...)` 호출
//   4) Edge Function(서버 측):
//      - profiles.gender, profiles.age_range, profiles.diet_goal, meal_slot,
//        업로드된 이미지 URL을 기반으로 OpenAI(vision)에 판정 요청
//        (age_range까지 포함해 연령대별 영양 기준을 반영할 수 있도록 확장 가능)
//      - 응답에서 result_type/affection_gain을 계산
//      - meal_logs insert + user_pets.affection update까지 서버에서 수행
//        (서비스 롤 키 사용, RLS bypass)
//   5) Flutter: 결과를 받아 meal_logs / active pet을 재조회하고 UI에 반영
//
// 보안 원칙:
//   - OpenAI API 키는 앱 코드에 절대 포함하지 않는다.
//   - 키는 Edge Function 환경 변수(예: `OPENAI_API_KEY`)로만 보관한다.
//   - 따라서 Flutter(main.dart)에서는 OpenAI를 직접 호출하지 않는다.
//
// Edge Function 요청 바디(JSON) 예시:
//   {
//     "user_pet_id": "<uuid>",
//     "meal_slot": "brunch" | "dinner",
//     "meal_date": "yyyy-MM-dd",
//     "storage_path": "<step 2에서 얻은 storage 경로>"
//   }
//
// Edge Function 응답(JSON) 예시:
//   {
//     "result_type": "good" | "supplement_needed" | "bad" | "uncertain",
//     "affection_gain": 5 | 3 | 0
//   }
// ============================================================================

// Supabase Storage 버킷명: 촬영한 식단 사진이 올라가는 곳.
const String _kMealPhotoBucket = 'meal-photos';

// Supabase Edge Function 이름: OpenAI를 호출해서 식단을 판정해준다.
const String _kMealEvaluateFunction = 'meal-evaluate';

// ignore: unused_element
const List<String> _kMealResultTypes = <String>[
  'good',
  'supplement_needed',
  'bad',
  'uncertain',
];

const Map<String, int> _kMealAffectionGainByResult = <String, int>{
  'good': 5,
  'supplement_needed': 3,
  'bad': 0,
  'uncertain': 0,
};

// ----------------------------------------------------------------------------
// AI 판정 결과별 감성 메시지 세트.
//
// OpenAI(Edge Function)는 result_type 과 feedback_text 만 반환하고,
// 최종 유저용 메시지는 Flutter가 이 상수들로 조합한다.
// ----------------------------------------------------------------------------

const List<String> _kGoodMessages = <String>[
  '건강한 음식을 먹어서 그런가? 베지펫의 기분이 좋아 보인다!',
  '베지펫이 만족스러운 식사를 했다! 지금처럼 균형을 유지하면 좋을 것 같다!',
];

// feedback_text가 있을 때 사용. `{feedback}` 부분에 Edge Function이 돌려준 문장이 들어간다.
const List<String> _kSupplementMessagesWithFeedback = <String>[
  '베지펫이 맛있게 음식을 먹은 것 같다! 다음에는 {feedback}를 반영한 음식을 줘보는 것이 어떨까?!',
  '나름 기분이 좋아보인다! 다음에는 {feedback}를 반영한 음식을 줘보자!',
];

// feedback_text가 비어 있을 때 쓰는 기본 메시지.
const List<String> _kSupplementMessagesFallback = <String>[
  '베지펫이 맛있게 음식을 먹었다! 다음에는 영양 균형을 조금 더 맞춰보는 것이 좋을 것 같다!',
];

const List<String> _kBadMessagesWithFeedback = <String>[
  '기운이 빠지는 식사인 것 같다.. 다음에는 {feedback}를 반영한 음식을 줘보자..!',
  '다소 만족스럽지 않은 식사인 것 같다.. 다음에는 {feedback}를 반영한 음식을 줘보자..!',
];

const List<String> _kBadMessagesFallback = <String>[
  '베지펫이 음식을 먹었지만, 다음에는 식단 구성을 조금 더 조절해보는 것이 좋을 것 같다!',
];

// uncertain은 고정 문구 1개만 사용한다.
const String _kUncertainMessage = '사진이 잘 보이지 않는 것 같아요. 다시 촬영해보세요!';

const List<String> _kGoodMessagesEn = <String>[
  'Looks like VegePet enjoyed the meal! The balance looks great.',
  "VegePet looks happy after that meal! Let's keep that balance going.",
];

const List<String> _kSupplementMessagesWithFeedbackEn = <String>[
  'Looks like VegePet enjoyed the meal! Next time, try adding {feedback}.',
  'VegePet seems happy with this meal! Adding {feedback} next time could make it even better.',
];

const List<String> _kSupplementMessagesFallbackEn = <String>[
  'VegePet enjoyed the meal! A little more balance next time would make it even better.',
];

const List<String> _kBadMessagesWithFeedbackEn = <String>[
  'This meal could use a little more balance. Next time, try going with {feedback}.',
  'VegePet ate the meal, but it could be better balanced. Next time, going with {feedback} may help.',
];

const List<String> _kBadMessagesFallbackEn = <String>[
  'VegePet ate the meal, but a more balanced meal would be better next time.',
];

const String _kUncertainMessageEn =
    'The photo is a little hard to read. Please try taking it again.';

final Random _mealMessageRandom = Random();

/// 게임 메뉴 하위 패널을 외부 탭으로 닫을 때 페이드 퇴장 모션을 적용할 대상.
enum _GameMenuSubOutsideDismissKind {
  none,
  profile,
  dietDiary,
  bag,
  pokedex,
  story,
  settings,
  help,
}

/// English locale: comma-separated feedback phrases → natural "and" list.
String _formatFeedbackForEnglishSentence(String feedback) {
  final cleaned = feedback
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\band\s+and\s+and\b', caseSensitive: false), 'and')
      .replaceAll(RegExp(r'\band\s+and\b', caseSensitive: false), 'and');

  if (cleaned.isEmpty) return '';

  if (!cleaned.contains(',')) {
    return cleaned;
  }

  final parts = cleaned
      .split(',')
      .map((part) {
        return part
            .trim()
            .replaceFirst(RegExp(r'^(and\s+)+', caseSensitive: false), '')
            .trim();
      })
      .where((part) => part.isNotEmpty)
      .toList();

  if (parts.length <= 1) return cleaned;
  if (parts.length == 2) {
    return '${parts[0]} and ${parts[1]}';
  }

  return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
}

/// AI 판정 결과 + 피드백 문장 → 앱에 표시할 최종 감성 메시지 1개를 만든다.
///
/// feedback_text가 비어 있거나 null 이면 fallback 메시지 세트에서 선택한다.
String _buildAiStatusMessage(
  String? resultType,
  String? feedbackText, {
  String localeCode = 'ko',
}) {
  final isEn = localeCode == 'en';
  final rawFeedback = feedbackText?.trim() ?? '';
  final feedback = isEn
      ? _formatFeedbackForEnglishSentence(rawFeedback)
      : rawFeedback;
  final hasFeedback = feedback.isNotEmpty;

  List<String> pickList;
  switch (resultType) {
    case 'good':
      pickList = isEn ? _kGoodMessagesEn : _kGoodMessages;
      break;
    case 'supplement_needed':
      pickList = hasFeedback
          ? (isEn
                ? _kSupplementMessagesWithFeedbackEn
                : _kSupplementMessagesWithFeedback)
          : (isEn
                ? _kSupplementMessagesFallbackEn
                : _kSupplementMessagesFallback);
      break;
    case 'bad':
      pickList = hasFeedback
          ? (isEn ? _kBadMessagesWithFeedbackEn : _kBadMessagesWithFeedback)
          : (isEn ? _kBadMessagesFallbackEn : _kBadMessagesFallback);
      break;
    case 'uncertain':
    default:
      return isEn ? _kUncertainMessageEn : _kUncertainMessage;
  }

  final template = pickList[_mealMessageRandom.nextInt(pickList.length)];
  if (!hasFeedback) return template;
  return template.replaceAll('{feedback}', feedback);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);

  runApp(const VegePetApp());
}

final supabase = Supabase.instance.client;

// 전역 Navigator / ScaffoldMessenger key.
//
// HomePage 의 일시적인 BuildContext 변화(프로필 입력 → 첫 분양 → 마당 화면 전환,
// BottomSheet/Dialog 트리 dispose 등) 와 SnackBar/Dialog 호출 타이밍이 겹치면
// `_dependents.isEmpty is not true` assertion 이 발생할 수 있다. 전역 key 를
// 통해 SnackBar 를 띄워서 화면 전환 타이밍과의 충돌을 줄인다.
final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> _rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
const String _kLocalePrefKey = 'vegepet_locale_code';

class VegePetApp extends StatefulWidget {
  const VegePetApp({super.key});

  @override
  State<VegePetApp> createState() => _VegePetAppState();
}

class _VegePetAppState extends State<VegePetApp> {
  Locale _locale = const Locale('ko');

  @override
  void initState() {
    super.initState();
    _loadSavedLocale();
  }

  Future<void> _loadSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kLocalePrefKey) ?? 'ko';
    if (!mounted) return;
    setState(() {
      _locale = Locale(code == 'en' ? 'en' : 'ko');
    });
  }

  Future<void> _setLocale(Locale locale) async {
    final code = locale.languageCode == 'en' ? 'en' : 'ko';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocalePrefKey, code);
    if (!mounted) return;
    setState(() {
      _locale = Locale(code);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _LocaleControllerScope(
      locale: _locale,
      setLocale: _setLocale,
      child: MaterialApp(
        title: 'VegePet',
        debugShowCheckedModeBanner: false,
        navigatorKey: _rootNavigatorKey,
        scaffoldMessengerKey: _rootScaffoldMessengerKey,
        locale: _locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('ko'), Locale('en')],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class _LocaleControllerScope extends InheritedWidget {
  const _LocaleControllerScope({
    required this.locale,
    required this.setLocale,
    required super.child,
  });

  final Locale locale;
  final Future<void> Function(Locale locale) setLocale;

  static _LocaleControllerScope of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_LocaleControllerScope>();
    assert(scope != null, 'LocaleControllerScope not found');
    return scope!;
  }

  @override
  bool updateShouldNotify(_LocaleControllerScope oldWidget) {
    return locale != oldWidget.locale;
  }
}

class _MealNotificationTexts {
  const _MealNotificationTexts({required this.title, required this.messages});

  final String title;
  final List<String> messages;
}

enum _SupportDocType { terms, privacy, operation, guardian, dataDeletion }

class _SupportDocumentSection {
  const _SupportDocumentSection({required this.title, required this.body});

  final String title;
  final String body;
}

class _SupportDocument {
  const _SupportDocument({required this.title, required this.sections});

  final String title;
  final List<_SupportDocumentSection> sections;
}

/// 게임 메뉴 하위 패널 대제목 top (한국어 14 · 영어 +1px, 뒤로가기 버튼은 9 고정).
const double _kGameMenuSubPanelTitleTop = 14;
const double _kGameMenuSubPanelTitleTopEnOffset = 1.0;

enum _ViewStatus { loading, error, ready }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  static const double _kGameCanvasWidth = 844;
  static const double _kGameCanvasHeight = 390;

  /// VegePet 공통 확인창 — 844×390 논리좌표 (화면에는 FittedBox 와 동일 스케일로 맞춤).
  static const double _kVegePetConfirmDialogLeft = 302;
  static const double _kVegePetConfirmDialogTop = 129;
  static const double _kVegePetConfirmDialogW = 240;
  static const double _kVegePetConfirmDialogH = 116;

  /// 분양 후 이름 짓기 패널 — 프로필 입력창과 동일 앵커 (286, 83).
  static const double _kPetNicknameDialogLeft = 286;
  static const double _kPetNicknameDialogTop = 83;
  static const double _kPetNicknameDialogW = 272;
  static const double _kPetNicknameDialogH = 208;

  static const int _kProfileNicknameMaxLength = 8;
  static final RegExp _nameAllowedRegExp = RegExp(r'^[가-힣a-zA-Z0-9]{2,8}$');

  _ViewStatus _status = _ViewStatus.loading;
  String? _errorMessage;

  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _petSpecies = [];
  Map<String, dynamic>? _activePet;
  // 마당에 함께 거주하는 성숙기 졸업 펫 목록.
  // user_pets 에서 is_resident=true 이고 graduated_at != null 인 펫들이며,
  // 현재 activePet 과 별도로 마당 화면 하단에 작게 함께 표시한다.
  List<Map<String, dynamic>> _residentPets = [];

  String? _selectedSpeciesId;
  bool _isAdopting = false;

  List<Map<String, dynamic>> _todayMealLogs = [];
  // ignore: unused_field
  bool _isLoggingMeal = false; // 기존 _logMeal 경로 호환용 (현재 UI에서는 사용하지 않음)
  bool _firstMealPopupShownThisSession = false;

  // 사진 업로드 + AI 판정 관련 상태.
  bool _isUploadingMeal = false;
  String? _uploadingSlot; // 'brunch' | 'dinner' | null
  String? _lastResultType;
  String? _lastFeedbackText;
  String? _lastStatusMessage;
  int? _lastAffectionGain;
  String? _lastImagePath;

  final TextEditingController _nicknameController = TextEditingController();
  final FocusNode _nicknameFocusNode = FocusNode();
  String? _selectedGender;
  String? _selectedAgeRange;
  String? _selectedDietGoal;
  OverlayEntry? _profileSelectOverlayEntry;
  ScrollController? _profileSelectScrollController;
  String? _openProfileSelectKey;
  final Map<String, LayerLink> _profileSelectLinks = <String, LayerLink>{};
  bool _profileSelectOverlayVisible = false;
  bool _isClosingProfileSelectOverlay = false;
  bool _isProfileSetupPanelVisible = false;
  bool _isProfileSetupClosing = false;
  bool _isSavingProfile = false;
  bool _isNamingDialogOpen = false;
  bool _canShowActivePetDuringNaming = false;
  bool _isPetNamingPanelClosing = false;
  final TextEditingController _petNamingController = TextEditingController();
  final FocusNode _petNamingFocusNode = FocusNode();
  Completer<String?>? _petNamingCompleter;
  late AnimationController _petNamingPanelEnterController;
  late Animation<double> _petNamingPanelEnterCurve;

  static const List<String> _languageDisplayOptions = ['한국어', 'English'];

  static const List<String> _genderOptions = ['여자', '남자'];
  static const List<String> _ageRangeOptions = [
    '10대',
    '20대',
    '30대',
    '40대',
    '50대',
  ];
  static const List<String> _dietGoalOptions = ['다이어트', '근력향상', '혈당조정'];

  bool _debugExpanded = false;

  /// 개발 확인용 디버그 오버레이 창 열림 (버튼으로 토글).
  bool _isDebugPanelOpen = false;
  bool _isInteracting = false;

  // 가방 안의 랜덤 분양권(user_items.quantity 합계) 상태.
  // 졸업 처리 / 분양권 사용 테스트 후 디버그 섹션에 즉시 반영하기 위해 들고 다닌다.
  int _randomTicketCount = 0;

  // 가방에서 랜덤 분양권 사용 중 연타/중복 분양 방지 플래그.
  // RPC 호출 + user_pets insert 가 원자적이지 않으므로, UI 레벨에서라도 락을 걸어둔다.
  bool _isUsingRandomTicket = false;

  // 첫 펫 선택 분양창(프로필 완료 + activePet 없음) 오버레이.
  static const double _kInitialAdoptionPanelLeft = 270;
  static const double _kInitialAdoptionPanelTop = 67;
  static const double _kInitialAdoptionPanelWidth = 304;
  static const double _kInitialAdoptionPanelHeight = 256;

  bool _isInitialAdoptionPanelVisible = false;
  bool _isInitialAdoptionPanelClosing = false;
  bool _isInitialAdoptionInFlight = false;

  // 도감(pokedex) 화면 데이터.
  // 도감 BottomSheet 가 열릴 때 한 번 조회해 들고 있다가, 시트 안에서는 DB
  // 호출을 추가로 하지 않는다. 모달 안에서 또 다른 async 작업을 일으키면
  // BottomSheet/Dialog 트리 정리 타이밍이 꼬이면서 `_dependents.isEmpty
  // is not true` 오류가 다시 발생할 수 있기 때문이다.
  List<Map<String, dynamic>> _pokedexEntries = [];
  bool _isLoadingPokedex = false;

  // ----- 식단일지 (diet diary) -----
  //
  // 식단일지 BottomSheet 는 "달력 / 월 선택 / 상세" 3가지 모드로 동작한다.
  // mode/visibleMonth/selectedDate 는 [_DietDiarySheetPanel] State 에서만 관리해
  // iPhone 키보드 등장 시 BottomSheet builder 가 다시 돌아도 calendar 로
  // 초기화되지 않게 한다.
  //
  // HomePage 쪽 [_diaryVisibleMonth] / [_diaryLogsByDate] 는 현재 조회 중인 월과
  // 해당 월 meal_logs 캐시를 기억한다. 식단일지 창을 열 때는 매번 오늘(KST)이
  // 속한 월을 초기 진입 월로 사용한다.
  //
  // 범위: 2026-01 ~ 2035-12 (10년치)
  static final DateTime _diaryMinMonth = DateTime(2026, 1);
  static final DateTime _diaryMaxMonth = DateTime(2035, 12);

  DateTime _diaryVisibleMonth = DateTime(2026, 1);
  // 현재 _diaryVisibleMonth 의 meal_logs 캐시. 도장 표시용.
  // key: yyyy-MM-dd, value: 그 날짜의 meal_logs row 들.
  Map<String, List<Map<String, dynamic>>> _diaryLogsByDate = {};

  /// [_fetchDiaryMonthLogs] 가 마지막으로 성공 반영한 월(yyyy-MM). 프리로드 중복 방지용.
  String? _diaryLogsCachedMonthKey;
  bool _isPreloadingDiaryMonth = false;
  bool _isToyMenuOpen = false;
  bool _isToyDropHovering = false;
  bool _isCompletingToyPlay = false;
  bool _isPetInfoBannerOpen = false;

  /// 베지펫 정보창 ↔ 놀아주기 창 전환 애니메이션 진행 중.
  bool _petToySwapInProgress = false;

  /// 놀아주기를 베지펫 정보창의 「놀아주기」로 연 경우, 뒤로가기 시 정보창 복귀.
  bool _toyOpenedFromPetBanner = false;

  /// 베지펫 정보창 ↔ 먹이주기 패널 전환 애니메이션 진행 중.
  bool _petMealSwapInProgress = false;

  /// 먹이주기를 베지펫 정보창에서 연 경우, 뒤로가기 시 정보창 복귀.
  bool _mealOpenedFromPetBanner = false;

  /// 놀아주기/먹이주기 외부 탭으로 마당 복귀 중(우측 메뉴 아이콘 [_hideGameMenuHudIcon] 과 동일).
  bool _petChildPanelDismissingToYard = false;

  bool _isMealPanelOpen = false;
  bool _gameMenuPanelOpen = false;

  /// 메뉴창 슬라이드 아웃 중(베지펫 정보창 [_isPetInfoBannerOpen] 토글과 동일 패턴).
  bool _gameMenuPanelRetracting = false;

  /// 게임 메뉴 패널 내부에서 열리는 프로필 수정 창.
  bool _isProfilePanelOpen = false;
  bool _profilePanelSwapInProgress = false;
  bool _profileOpenedFromGameMenu = false; // ignore: unused_field
  bool _isSavingProfilePanel = false;
  String _profilePanelInitialNickname = '';
  String? _profilePanelInitialGender;
  String? _profilePanelInitialAgeRange;
  String? _profilePanelInitialDietGoal;
  late AnimationController _gameMenuPanelController;
  late Animation<double> _gameMenuPanelCurve;
  late AnimationController _gameProfileSwapController;
  late Animation<double> _gameProfileSwapCurve;

  /// 게임 메뉴 ↔ 식단일지 창 전환
  bool _isDietDiaryPanelOpen = false;
  bool _dietDiaryPanelSwapInProgress = false;
  final GlobalKey<_DietDiarySheetPanelState> _dietDiarySheetPanelKey =
      GlobalKey<_DietDiarySheetPanelState>();
  late AnimationController _gameDietDiarySwapController;
  late Animation<double> _gameDietDiarySwapCurve;

  /// 게임 메뉴 ↔ 가방 창 전환 (프로필/식단일지와 동일 계열)
  bool _isBagPanelOpen = false;
  bool _bagPanelSwapInProgress = false;
  _BagItem? _bagPanelDetailItem;
  late AnimationController _gameBagSwapController;
  late Animation<double> _gameBagSwapCurve;
  bool _isPokedexPanelOpen = false;
  bool _pokedexPanelSwapInProgress = false;
  Map<String, dynamic>? _pokedexPanelSelectedEntry;
  late AnimationController _gamePokedexSwapController;
  late Animation<double> _gamePokedexSwapCurve;

  /// 게임 메뉴 ↔ 스토리 창 전환 (도감창과 동일 계열).
  bool _isStoryPanelOpen = false;
  bool _storyPanelSwapInProgress = false;
  int _storyPageIndex = 0;
  late AnimationController _gameStorySwapController;
  late Animation<double> _gameStorySwapCurve;

  /// 게임 메뉴 ↔ 설정 패널 전환 (프로필/식단일지와 동일 계열).
  bool _isSettingsPanelOpen = false;
  bool _settingsPanelSwapInProgress = false;
  late AnimationController _gameSettingsSwapController;
  late Animation<double> _gameSettingsSwapCurve;

  /// 게임 메뉴 ↔ 도움말 창 전환 (가방/설정과 동일 계열 · fade only).
  bool _isHelpPanelOpen = false;
  bool _helpPanelSwapInProgress = false;
  late AnimationController _gameHelpSwapController;
  late Animation<double> _gameHelpSwapCurve;
  final ScrollController _settingsScrollController = ScrollController();
  _SupportDocType? _activeSettingsSupportDoc;
  _SupportDocType? _renderingSettingsSupportDoc;
  bool _settingsSupportDocSwapInProgress = false;
  bool _settingsSupportDocScrollbarReady = false;
  final ScrollController _settingsSupportDocScrollController =
      ScrollController();
  bool _settingsNoticePushBusy = false;
  bool _settingsMealPushBusy = false;
  bool _settingsBgmBusy = false;
  bool _settingsSfxBusy = false;

  /// 설정 위 마당 오버레이: 이메일 OTP 발송(인증 코드 받기) 전용 글래스 패널.
  bool _isEmailLinkPanelOpen = false;

  /// 설정 위 마당 오버레이: 고객센터(문의 이메일·복사) 글래스 패널.
  bool _isCustomerCenterPanelOpen = false;

  /// 마당 공통 알림창: 상점 MVP 준비중 안내.
  bool _isShopNoticeOpen = false;

  /// 가방 랜덤 분양권 사용 확인 (240×116 · 마당 좌표계).
  bool _isRandomTicketUseConfirmOpen = false;
  Completer<bool>? _randomTicketUseConfirmCompleter;

  bool _isNameInterlockNoticeOpen = false;

  /// 설정 > 회원 탈퇴 1차 확인 (240×116 · 마당 좌표계).
  bool _isWithdrawConfirmOpen = false;

  /// 설정 > 회원 탈퇴 2차 최종 확인 (240×116 · 마당 좌표계).
  bool _isWithdrawFinalConfirmOpen = false;

  /// 첫 식단 인증 성공 직후 이메일 연동 추천 (240×116 · 마당 좌표계).
  bool _isEmailLinkInviteNoticeOpen = false;

  /// 이메일 연동 성공 직후 안내 (240×116 · 마당 좌표계).
  bool _isEmailLinkSuccessNoticeOpen = false;
  bool _isEmailFormatErrorNoticeOpen = false;
  bool _isEmailDuplicateNoticeOpen = false;

  /// 도감 등록 펫과 동일한 이름으로 분양 펫 이름 저장 시도 시 (240×116 · 마당 좌표계).
  bool _isDuplicatePetNameNoticeOpen = false;

  /// 이미 등록된 이메일 OTP 로그인(기존 계정 복구) 모드.
  bool _emailLinkRestoreMode = false;
  bool _isDeletingAccount = false;
  bool _emailLinkPanelSendBusy = false;
  bool _emailLinkPanelVerifyBusy = false;
  bool _emailLinkPanelResendBusy = false;
  bool _emailLinkOtpSent = false;
  String _emailLinkOtpSentForEmail = '';
  DateTime? _emailLinkOtpSentAt;
  Timer? _emailLinkOtpSessionTimer;
  final TextEditingController _emailLinkController = TextEditingController();
  final TextEditingController _emailLinkOtpController = TextEditingController();
  final FocusNode _emailLinkFocusNode = FocusNode();
  final FocusNode _emailLinkOtpFocusNode = FocusNode();
  final FocusNode _keyboardAccessoryFocusNode = FocusNode();

  FocusNode? _activeKeyboardFocusNode;
  TextEditingController? _activeKeyboardController;
  String? _activeKeyboardInputKey;
  TextInputType _activeKeyboardInputType = TextInputType.text;
  final Set<String> _keyboardBoundInputKeys = <String>{};
  final Map<String, List<TextInputFormatter>> _keyboardAccessoryFormattersByKey =
      {};

  static const double _kKeyboardAccessoryBarHeight = 46;

  /// 게임 메뉴 하위 패널 외부 탭 → 마당: 슬라이드 없이 전체 페이드 아웃.
  late AnimationController _gameMenuSubOutsideDismissController;
  late Animation<double> _gameMenuSubOutsideDismissCurve;

  /// 마당 공통 알림창(상점/회원탈퇴) 등장 — scale 1.0 유지 fade.
  late AnimationController _yardConfirmOverlayFadeController;
  late Animation<double> _yardConfirmOverlayFadeCurve;
  _GameMenuSubOutsideDismissKind _gameMenuSubOutsideDismissKind =
      _GameMenuSubOutsideDismissKind.none;
  late AnimationController _petToySwapController;
  late Animation<double> _petToySwapCurve;
  late AnimationController _petMealSwapController;
  late Animation<double> _petMealSwapCurve;
  late AnimationController _dragHintPulseController;
  late Animation<double> _dragHintOpacityAnim;

  /// 마당 펫 터치 쓰다듬기: 하루·펫당 랜덤 목표 탭 수(3~5) 충족 시 [_interactPet] 호출.
  int _petPettingTapCount = 0;
  int? _petPettingRequiredTaps;
  String? _petPettingTargetDate;
  String? _petPettingTargetPetId;
  Timer? _emailOtpCooldownTimer;
  int _emailOtpCooldownSeconds = 0;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _noticeEventPushEnabled = false;
  bool _mealReminderPushEnabled = false;
  bool _isNotificationInitialized = false;
  bool _isSchedulingMealReminders = false;
  bool _backgroundMusicEnabled = true;
  bool _soundEffectsEnabled = true;
  bool _isSoundInitialized = false;
  bool _bgmAssetUnavailable = false;
  bool _sfxAssetUnavailable = false;
  final AudioPlayer _bgmPlayer = AudioPlayer();
  final AudioPlayer _sfxPlayer = AudioPlayer();

  static const String _kNoticeEventPushPrefKey =
      'vegepet_notice_event_push_enabled';
  static const String _kMealReminderPushPrefKey =
      'vegepet_meal_reminder_push_enabled';
  static const String _kBackgroundMusicPrefKey =
      'vegepet_background_music_enabled';
  static const String _kSoundEffectsPrefKey = 'vegepet_sound_effects_enabled';
  static const int _kMealReminderNotificationIdBase = 120000;
  static const int _kMealReminderDaysToSchedule = 14;
  /// 우측 게임 메뉴 6셀 + 2셀. String 슬롯은 표시용 라벨이 아니라
  /// **안정적인 key** 다. 실제 화면 라벨은 [_menuLabelForKey] 가 l10n 으로
  /// 매핑하고, onTap 분기도 이 key 를 기준으로 한다.
  static const List<(IconData, String)> _menuSheetItems = [
    (Icons.person_outline, 'profile'),
    (Icons.event_note_outlined, 'dietDiary'),
    (Icons.backpack_outlined, 'bag'),
    (Icons.storefront_outlined, 'shop'),
    (Icons.menu_book_outlined, 'pokedex'),
    (Icons.auto_stories_outlined, 'story'),
    (Icons.help_outline, 'help'),
    (Icons.settings_outlined, 'settings'),
  ];

  /// 844×390 마당 기준 우측 상단 게임 메뉴 글래스 패널.
  static const double _kGameMenuPanelLeft = 558;
  static const double _kGameMenuPanelTop = 40;
  static const double _kGameMenuPanelW = 246;
  static const double _kGameMenuPanelH = 310;

  /// 등장 전 패널을 화면 우측 밖에 둘 때의 left.
  static const double _kGameMenuPanelOffLeft = 844;

  /// 좌측 베지펫 정보창 슬라이드·우측 게임 메뉴 슬라이드 공통.
  static const Duration _kYardSidePanelSlideDuration = Duration(
    milliseconds: 240,
  );
  static const Curve _kYardSidePanelSlideCurve = Curves.easeOutCubic;

  /// 좌측 먹이·놀이 ↔ 우측 게임 메뉴 하위 패널 크로스페이드 공통.
  static const Duration _kYardSidePanelSwapDuration = Duration(
    milliseconds: 340,
  );
  static const Curve _kYardSidePanelSwapCurve = Curves.easeInOutCubic;

  /// 스토리 글래스 패널 (844×390 마당 기준).
  static const double _kStoryPanelLeft = 40;
  static const double _kStoryPanelTop = 40;
  static const double _kStoryPanelW = 766;
  static const double _kStoryPanelH = 310;
  static const double _kStoryIllustrationLeft = 36;
  static const double _kStoryIllustrationTop = 15;
  static const double _kStoryIllustrationW = 691;
  static const double _kStoryIllustrationH = 280;

  /// 추후 story png 삽입 시 경로 추가.
  static const List<String> _storyPageAssetPaths = <String>[
    // 'assets/images/story/story_01.png',
  ];

  /// 가방 아이템 설명창 (844×390 기준 593,84) — 가방 글래스 패널 내부 상대좌표.
  static const double _kBagItemDetailLeft = 593 - _kGameMenuPanelLeft;
  static const double _kBagItemDetailTop = 84 - _kGameMenuPanelTop;
  static const double _kBagItemDetailW = 176;
  static const double _kBagItemDetailH = 222;

  /// 마당 게임 메뉴 그리드: 아이콘+라벨 고정 행 높이로 overflow 방지 (패널 310 내 배치).
  static const double _kYardGameMenuIconTile = 48;
  static const double _kYardGameMenuIconLabelGap = 4;
  static const double _kYardGameMenuLabelAreaH = 12;
  static const double _kYardGameMenuRowCellH =
      _kYardGameMenuIconTile +
      _kYardGameMenuIconLabelGap +
      _kYardGameMenuLabelAreaH; // 64
  static const double _kYardGameMenuItemW = 64;
  static const double _kYardGameMenuRowGap = 8;
  static const double _kYardGameMenuTitleBelowGap = 8;
  static const double _kSettingsGrayRowW = 212;
  static const double _kSettingsGrayRowH = 22;

  /// 이메일 계정 연동 글래스 패널 (844×390 마당 기준).
  static const double _kEmailLinkPanelLeft = 567;
  static const double _kEmailLinkPanelTop = 88;
  static const double _kEmailLinkPanelW = 230;
  static const double _kEmailLinkPanelH = 212;

  /// 이메일 OTP 발송 후 인증코드 입력란 활성 유지 시간(창 닫았다 다시 열어도 유지).
  static const Duration _kEmailLinkOtpSessionDuration = Duration(hours: 1);

  static const String _kCustomerCenterEmail = 'acoustic.jwg@gmail.com';
  static const double _kCustomerCenterPanelLeft = 567;
  static const double _kCustomerCenterPanelTop = 130;
  static const double _kCustomerCenterPanelW = 230;
  static const double _kCustomerCenterPanelH = 130;

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(_enforceProfileNicknameMaxLength);
    _nicknameFocusNode.canRequestFocus = false;
    _petNamingFocusNode.canRequestFocus = false;
    _emailLinkFocusNode.canRequestFocus = false;
    _emailLinkOtpFocusNode.canRequestFocus = false;
    _ensureKeyboardFocusBinding(
      key: 'profile_nickname',
      controller: _nicknameController,
      focusNode: _nicknameFocusNode,
      inputFormatters: [
        LengthLimitingTextInputFormatter(
          _kProfileNicknameMaxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
        ),
      ],
    );
    _ensureKeyboardFocusBinding(
      key: 'pet_naming',
      controller: _petNamingController,
      focusNode: _petNamingFocusNode,
      inputFormatters: [
        LengthLimitingTextInputFormatter(
          8,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
        ),
      ],
    );
    _ensureKeyboardFocusBinding(
      key: 'email_link',
      controller: _emailLinkController,
      focusNode: _emailLinkFocusNode,
      keyboardType: TextInputType.emailAddress,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9@.]')),
      ],
    );
    _emailLinkController.addListener(_onEmailLinkControllerChangedForOtpSession);
    _ensureKeyboardFocusBinding(
      key: 'email_link_otp',
      controller: _emailLinkOtpController,
      focusNode: _emailLinkOtpFocusNode,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
    );
    _keyboardAccessoryFocusNode.addListener(() {
      if (!mounted) return;
      if (_keyboardAccessoryFocusNode.hasFocus) {
        _safeSetState(() {});
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.viewInsetsOf(context).bottom > 0) return;
        if (_hasActiveTextInput()) return;
        _clearActiveKeyboardInput();
        _safeSetState(() {});
      });
    });
    _petToySwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _petToySwapCurve = CurvedAnimation(
      parent: _petToySwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _petMealSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _petMealSwapCurve = CurvedAnimation(
      parent: _petMealSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _dragHintPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
    _dragHintOpacityAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.35,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.35,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 50,
      ),
    ]).animate(_dragHintPulseController);
    _gameMenuPanelController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSlideDuration,
    );
    _gameMenuPanelCurve = CurvedAnimation(
      parent: _gameMenuPanelController,
      curve: _kYardSidePanelSlideCurve,
      reverseCurve: _kYardSidePanelSlideCurve,
    );
    _gameProfileSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameProfileSwapCurve = CurvedAnimation(
      parent: _gameProfileSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameDietDiarySwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameDietDiarySwapCurve = CurvedAnimation(
      parent: _gameDietDiarySwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameBagSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameBagSwapCurve = CurvedAnimation(
      parent: _gameBagSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gamePokedexSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gamePokedexSwapCurve = CurvedAnimation(
      parent: _gamePokedexSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameStorySwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameStorySwapCurve = CurvedAnimation(
      parent: _gameStorySwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameSettingsSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameSettingsSwapCurve = CurvedAnimation(
      parent: _gameSettingsSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameHelpSwapController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameHelpSwapCurve = CurvedAnimation(
      parent: _gameHelpSwapController,
      curve: _kYardSidePanelSwapCurve,
    );
    _gameMenuSubOutsideDismissController = AnimationController(
      vsync: this,
      duration: _kYardSidePanelSwapDuration,
    );
    _gameMenuSubOutsideDismissCurve = CurvedAnimation(
      parent: _gameMenuSubOutsideDismissController,
      curve: _kYardSidePanelSwapCurve,
    );
    _yardConfirmOverlayFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _yardConfirmOverlayFadeCurve = CurvedAnimation(
      parent: _yardConfirmOverlayFadeController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _petNamingPanelEnterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _petNamingPanelEnterCurve = CurvedAnimation(
      parent: _petNamingPanelEnterController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _nicknameController.removeListener(_enforceProfileNicknameMaxLength);
    _profileSelectScrollController?.dispose();
    _closeProfileSelectOverlay(notify: false, animated: false);
    _emailOtpCooldownTimer?.cancel();
    _emailLinkOtpSessionTimer?.cancel();
    _bgmPlayer.dispose();
    _sfxPlayer.dispose();
    _nicknameController.dispose();
    _nicknameFocusNode.dispose();
    _emailLinkController.dispose();
    _emailLinkOtpController.dispose();
    _emailLinkFocusNode.dispose();
    _emailLinkOtpFocusNode.dispose();
    _keyboardAccessoryFocusNode.dispose();
    _petToySwapController.dispose();
    _petMealSwapController.dispose();
    _dragHintPulseController.dispose();
    _gameMenuPanelController.dispose();
    _gameProfileSwapController.dispose();
    _gameDietDiarySwapController.dispose();
    _gameBagSwapController.dispose();
    _gamePokedexSwapController.dispose();
    _gameStorySwapController.dispose();
    _gameSettingsSwapController.dispose();
    _gameHelpSwapController.dispose();
    _settingsScrollController.dispose();
    _settingsSupportDocScrollController.dispose();
    _gameMenuSubOutsideDismissController.dispose();
    _yardConfirmOverlayFadeController.dispose();
    _petNamingPanelEnterController.dispose();
    _petNamingController.dispose();
    _petNamingFocusNode.dispose();
    if (_petNamingCompleter != null && !_petNamingCompleter!.isCompleted) {
      _petNamingCompleter!.complete(null);
    }
    if (_randomTicketUseConfirmCompleter != null &&
        !_randomTicketUseConfirmCompleter!.isCompleted) {
      _randomTicketUseConfirmCompleter!.complete(false);
    }
    super.dispose();
  }

  bool _isProfileComplete() {
    final p = _profile;
    if (p == null) return false;
    bool nonEmpty(dynamic v) => v != null && v.toString().trim().isNotEmpty;
    return nonEmpty(p['nickname']) &&
        nonEmpty(p['gender']) &&
        nonEmpty(p['age_range']) &&
        nonEmpty(p['diet_goal']);
  }

  /// 프로필 완료 → 선택 분양 → 분양 펫 이름 저장이 끝나기 전까지
  /// 좌/우 상단 HUD 코너 버튼(베지펫 정보, 게임 메뉴) 터치를 막는다.
  bool _isInitialOnboardingHudBlocked() {
    if (!_isProfileComplete()) return true;
    if (_isSavingProfile || _isProfileSetupClosing) return true;
    if (_isInitialAdoptionPanelVisible ||
        _isInitialAdoptionPanelClosing ||
        _isInitialAdoptionInFlight) {
      return true;
    }
    if (_isNamingDialogOpen) return true;
    if (_activePet == null) return true;
    final nick = _activePet!['nickname']?.toString().trim() ?? '';
    if (nick.isEmpty) return true;
    return false;
  }

  void _syncProfileFormFromFetched() {
    final p = _profile;
    if (p == null) return;
    if (_nicknameController.text.isEmpty && p['nickname'] != null) {
      _nicknameController.text = p['nickname'].toString();
    }
    _selectedGender ??= p['gender']?.toString();
    _selectedAgeRange ??= p['age_range']?.toString();
    _selectedDietGoal ??= p['diet_goal']?.toString();
  }

  void _enforceProfileNicknameMaxLength() {
    final text = _nicknameController.text;
    if (text.characters.length <= _kProfileNicknameMaxLength) return;

    final truncated = text.characters
        .take(_kProfileNicknameMaxLength)
        .toString();
    _nicknameController.value = TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
      composing: TextRange.empty,
    );
  }

  bool _isValidNicknameOrPetName(String raw) {
    final value = raw.trim();
    return _nameAllowedRegExp.hasMatch(value);
  }

  Future<void> _showNameInterlockNotice() async {
    if (_isNameInterlockNoticeOpen) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isNameInterlockNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  Future<void> _hideNameInterlockNotice() async {
    if (!_isNameInterlockNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isNameInterlockNoticeOpen = false,
    );
  }

  Future<void> _saveProfile() async {
    if (_isSavingProfile || _isNameInterlockNoticeOpen) return;
    // 저장 시점에 키보드/입력 포커스가 살아 있으면 직후 화면 전환과 겹쳐
    // dispose 타이밍 오류가 날 수 있다. 먼저 포커스를 정리한다.
    _dismissFocus();
    await _closeProfileSelectOverlay(animated: true);

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(AppLocalizations.of(context).snackLoginRequired);
      return;
    }

    _enforceProfileNicknameMaxLength();
    final nickname = _nicknameController.text.trim();

    if (!_isValidNicknameOrPetName(nickname)) {
      await _showNameInterlockNotice();
      return;
    }
    final l10n = AppLocalizations.of(context);
    if (_selectedGender == null) {
      _showSnack(l10n.snackSelectGender);
      return;
    }
    if (_selectedAgeRange == null) {
      _showSnack(l10n.snackSelectAgeRange);
      return;
    }
    if (_selectedDietGoal == null) {
      _showSnack(l10n.snackSelectDietGoal);
      return;
    }

    _safeSetState(() => _isSavingProfile = true);
    final savedProfileComplete =
        nickname.isNotEmpty &&
        _selectedGender != null &&
        _selectedGender!.trim().isNotEmpty &&
        _selectedAgeRange != null &&
        _selectedAgeRange!.trim().isNotEmpty &&
        _selectedDietGoal != null &&
        _selectedDietGoal!.trim().isNotEmpty;
    debugPrint(
      'profile save request: user=${user.id}, '
      'nicknameLen=${nickname.length}, '
      'gender=$_selectedGender, '
      'age_range=$_selectedAgeRange, '
      'diet_goal=$_selectedDietGoal',
    );
    try {
      final nowIso = DateTime.now().toIso8601String();
      final profilePayload = <String, dynamic>{
        'id': user.id,
        'nickname': nickname,
        'gender': _selectedGender,
        'age_range': _selectedAgeRange,
        'diet_goal': _selectedDietGoal,
        'updated_at': nowIso,
      };

      final savedRows = await supabase
          .from('profiles')
          .upsert(profilePayload, onConflict: 'id')
          .select();

      Map<String, dynamic>? savedProfile;
      if (savedRows.isNotEmpty) {
        savedProfile = Map<String, dynamic>.from(savedRows.first);
      }

      _profile = {
        ...?_profile,
        ...profilePayload,
        if (savedProfile != null) ...savedProfile,
      };

      if (!mounted) return;
      _safeSetState(() {
        _isProfileSetupClosing = true;
        _isProfileSetupPanelVisible = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 230));
      if (!mounted) return;

      await _fetchActivePet();
      if (!mounted) return;

      debugPrint(
        'profile upsert success: '
        'profile=$_profile, '
        'savedProfileComplete=$savedProfileComplete, '
        'activePetId=${_activePet?['id']}',
      );

      _safeSetState(() {
        _isSavingProfile = false;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = false;

        if (savedProfileComplete && _activePet == null) {
          _isInitialAdoptionPanelVisible = true;
          _isInitialAdoptionPanelClosing = false;
          _isInitialAdoptionInFlight = false;
        } else {
          _isInitialAdoptionPanelVisible = false;
        }
      });
    } catch (e, st) {
      debugPrint('profile upsert failed: $e\n$st');
      if (!mounted) return;
      _safeSetState(() {
        _isSavingProfile = false;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = true;
      });
      _showSnack(
        AppLocalizations.of(context).snackProfileSaveFailed(e.toString()),
      );
    }
  }

  Future<void> _closeProfileSelectOverlay({
    bool notify = true,
    bool animated = true,
  }) async {
    final entry = _profileSelectOverlayEntry;
    if (entry == null) return;
    if (_isClosingProfileSelectOverlay) return;

    if (animated) {
      _isClosingProfileSelectOverlay = true;
      _profileSelectOverlayVisible = false;
      entry.markNeedsBuild();
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }

    if (_profileSelectOverlayEntry == entry) {
      entry.remove();
      _profileSelectOverlayEntry = null;
    }
    _profileSelectScrollController?.dispose();
    _profileSelectScrollController = null;

    _profileSelectOverlayVisible = false;
    _isClosingProfileSelectOverlay = false;
    _openProfileSelectKey = null;
    if (notify && mounted) {
      setState(() {});
    }
  }

  String _currentLanguageDisplayLabel() {
    final code = _LocaleControllerScope.of(context).locale.languageCode;
    return code == 'en' ? 'English' : '한국어';
  }

  Locale _localeFromLanguageLabel(String label) {
    return label == 'English' ? const Locale('en') : const Locale('ko');
  }

  /// 설정 고객지원 문서창 렌더링용. [_LocaleControllerScope.of]의 `!`를 피한다.
  String _safeLocaleCodeForBuild(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_LocaleControllerScope>();
    final code =
        scope?.locale.languageCode ??
        Localizations.localeOf(context).languageCode;
    return code == 'en' ? 'en' : 'ko';
  }

  /// meal-evaluate Edge Function 요청용 locale (en | ko).
  String _currentLocaleCodeForAi() {
    return _isEnglishLocale ? 'en' : 'ko';
  }

  Future<void> _onSettingsLanguageSelected(String label) async {
    try {
      await _applyAppLocaleFromLanguageLabel(label);
    } catch (e, st) {
      debugPrint('settings language change failed: $e\n$st');
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context).snackLanguageChangeFailed);
    }
  }

  Future<void> _applyAppLocaleFromLanguageLabel(String label) async {
    final targetCode = _localeFromLanguageLabel(label).languageCode;
    final localeScope = _LocaleControllerScope.of(context);
    final notificationTexts = _mealNotificationTextsForLocaleCode(targetCode);
    final changedMessage = targetCode == 'en'
        ? 'Language changed.'
        : '언어가 변경되었어요.';
    await localeScope.setLocale(Locale(targetCode));
    if (!mounted) return;
    _showSnack(changedMessage);

    if (_mealReminderPushEnabled) {
      try {
        await _scheduleMealReminderNotifications(
          notificationTitle: notificationTexts.title,
          notificationMessages: notificationTexts.messages,
          revertToggleWhenDenied: false,
        );
      } catch (e) {
        debugPrint('meal reminder reschedule on locale change failed: $e');
      }
    }
  }

  void _openProfileSelectOverlay({
    required String selectKey,
    required LayerLink link,
    required List<String> options,
    required String? selectedValue,
    required ValueChanged<String> onChanged,
    String Function(String raw)? optionLabelBuilder,
    double dropdownWidth = 176,
    double dropdownVerticalOffset = 30,
    Color menuBackgroundColor = Colors.white,
    Color selectedBackgroundColor = const Color(0xFFEFF6FF),
    bool menuBorderEnabled = true,
    Color menuBorderColor = const Color(0xFFEAEAEA),
    Color splashColor = const Color(0xFFF4F8FF),
  }) {
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    _openProfileSelectKey = selectKey;
    _profileSelectOverlayVisible = false;

    final overlay = Overlay.of(context, rootOverlay: true);
    _profileSelectScrollController?.dispose();
    _profileSelectScrollController = ScrollController();
    final menuHeight = min(options.length, 3) * 30.0;
    _profileSelectOverlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  unawaited(_closeProfileSelectOverlay());
                },
                child: const SizedBox.expand(),
              ),
              CompositedTransformFollower(
                link: link,
                showWhenUnlinked: false,
                offset: Offset(0, dropdownVerticalOffset),
                child: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: dropdownWidth,
                    child: IgnorePointer(
                      ignoring: !_profileSelectOverlayVisible,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        opacity: _profileSelectOverlayVisible ? 1 : 0,
                        child: AnimatedScale(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          scale: _profileSelectOverlayVisible ? 1 : 0.96,
                          alignment: Alignment.topCenter,
                          child: AnimatedSlide(
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            offset: _profileSelectOverlayVisible
                                ? Offset.zero
                                : const Offset(0, -0.04),
                            child: Container(
                              width: dropdownWidth,
                              decoration: BoxDecoration(
                                color: menuBackgroundColor,
                                borderRadius: BorderRadius.circular(12),
                                border: menuBorderEnabled
                                    ? Border.all(color: menuBorderColor)
                                    : null,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _buildProfileSelectOptionsList(
                                  options: options,
                                  selectedValue: selectedValue,
                                  onChanged: onChanged,
                                  optionLabelBuilder: optionLabelBuilder,
                                  listWidth: dropdownWidth,
                                  listHeight: menuHeight,
                                  selectedBackgroundColor:
                                      selectedBackgroundColor,
                                  splashColor: splashColor,
                                ),
                              ),
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
      },
    );
    overlay.insert(_profileSelectOverlayEntry!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_profileSelectOverlayEntry == null) return;
      _profileSelectOverlayVisible = true;
      _profileSelectOverlayEntry?.markNeedsBuild();
    });
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildCompactProfileSelect({
    required String selectKey,
    required String? value,
    required List<String> options,
    required ValueChanged<String> onChanged,
    required bool enabled,
    String Function(String raw)? optionLabelBuilder,
    double fieldWidth = 176,
    double? englishFieldFontSize,
  }) {
    final link = _profileSelectLinks.putIfAbsent(selectKey, LayerLink.new);
    final isOpen = _openProfileSelectKey == selectKey;
    final displayValue = value == null || value.isEmpty
        ? ''
        : (optionLabelBuilder?.call(value) ?? value);
    final isEn = _isEnglishLocale;
    final enValueFontSize = englishFieldFontSize ?? 10;

    final fieldChild = Container(
      width: fieldWidth,
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6E6E6), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: isEn
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      displayValue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: enValueFontSize,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF4A4A4A),
                      ),
                    ),
                  )
                : Text(
                    displayValue,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A4A4A),
                    ),
                  ),
          ),
          Icon(
            isOpen
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: const Color(0xFF757575),
          ),
        ],
      ),
    );

    return CompositedTransformTarget(
      link: link,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: !enabled
            ? null
            : () {
                _dismissFocus();
                if (isOpen) {
                  unawaited(_closeProfileSelectOverlay());
                  return;
                }
                _openProfileSelectOverlay(
                  selectKey: selectKey,
                  link: link,
                  options: options,
                  selectedValue: value,
                  onChanged: onChanged,
                  optionLabelBuilder: optionLabelBuilder,
                  dropdownWidth: fieldWidth,
                );
              },
        child: fieldChild,
      ),
    );
  }

  Widget _buildProfileSelectManualScrollbar({
    required double listHeight,
    required int optionCount,
  }) {
    final controller = _profileSelectScrollController;
    if (controller == null || optionCount <= 3) {
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

  Widget _buildProfileSelectOptionsList({
    required List<String> options,
    required String? selectedValue,
    required ValueChanged<String> onChanged,
    required double listWidth,
    required double listHeight,
    String Function(String raw)? optionLabelBuilder,
    Color selectedBackgroundColor = const Color(0xFFEFF6FF),
    Color splashColor = const Color(0xFFF4F8FF),
  }) {
    final showScrollThumb = options.length > 3;
    final listView = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.builder(
        controller: _profileSelectScrollController,
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
            onTap: () {
              onChanged(option);
              unawaited(_closeProfileSelectOverlay());
            },
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
                  fontSize: _isEnglishLocale && optionLabelBuilder != null
                      ? 10
                      : 11,
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
              child: _buildProfileSelectManualScrollbar(
                listHeight: listHeight,
                optionCount: options.length,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _bootstrap() async {
    setState(() {
      _status = _ViewStatus.loading;
      _errorMessage = null;
      // 부트스트랩 재조회 전에 이전 세션·탈퇴 직후 찌꺼기가 화면에 남지 않도록 캐시만 선비움.
      // (실 데이터는 아래 fetch 들로 다시 채움 — 깜빡임은 짧은 로딩 상태로 흡수)
      _pokedexEntries = [];
      _pokedexPanelSelectedEntry = null;
      _residentPets = [];
      _randomTicketCount = 0;
    });

    try {
      if (supabase.auth.currentSession == null) {
        await supabase.auth.signInAnonymously();
      }

      await Future.wait([
        _fetchProfile(),
        _fetchPetSpecies(),
        _fetchActivePet(),
        _fetchResidentPets(),
        _fetchTodayMealLogs(),
        _fetchRandomTicketCount(),
      ]);
      await _syncAuthEmailToProfileIfNeeded();

      _syncProfileFormFromFetched();

      if (!mounted) return;
      setState(() {
        final profileComplete = _isProfileComplete();
        final hasActivePet = _activePet != null;
        _status = _ViewStatus.ready;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = !profileComplete;
        _isInitialAdoptionPanelVisible = profileComplete && !hasActivePet;
        _isInitialAdoptionPanelClosing = false;
        if (profileComplete && !hasActivePet) {
          _isInitialAdoptionInFlight = false;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_bootstrapOptionalServices());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _ViewStatus.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _bootstrapOptionalServices() async {
    try {
      await _initNotificationsIfNeeded();
      await _loadPushSettings();
      if (_mealReminderPushEnabled) {
        final localeCode = await _loadSavedLocaleCodeForNotifications();
        final texts = _mealNotificationTextsForLocaleCode(localeCode);
        await _scheduleMealReminderNotifications(
          notificationTitle: texts.title,
          notificationMessages: texts.messages,
          revertToggleWhenDenied: false,
        );
      }
    } catch (e) {
      debugPrint('notification bootstrap failed: $e');
    }

    try {
      await _loadSoundSettings();
      await _initSoundIfNeeded();
      if (_backgroundMusicEnabled) {
        await _startBackgroundMusicIfEnabled();
      }
    } catch (e) {
      debugPrint('sound bootstrap failed: $e');
    }

    if (mounted) {
      _safeSetState(() {});
    }
  }

  Future<void> _fetchProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _profile = null;
      return;
    }

    final rows = await supabase
        .from('profiles')
        .select()
        .eq('id', user.id)
        .limit(1);

    if (rows.isNotEmpty) {
      _profile = Map<String, dynamic>.from(rows.first);
    } else {
      _profile = null;
    }
  }

  bool _isEmailLinkedProfile() {
    final p = _profile;
    if (p == null) return false;
    final accountType = p['account_type']?.toString();
    final email = p['email']?.toString().trim() ?? '';
    return accountType == 'email' && email.isNotEmpty;
  }

  String? _currentAuthEmail() {
    return supabase.auth.currentUser?.email;
  }

  /// 프로필 또는 Auth 세션 기준으로 이미 이메일 연동된 상태인지(UI 가드용).
  bool _hasEffectiveEmailLink() {
    final authEmail = _currentAuthEmail()?.trim();
    if (authEmail != null && authEmail.isNotEmpty) return true;
    return _isEmailLinkedProfile();
  }

  String _resolvedDisplayEmailLine([AppLocalizations? l10n]) {
    final isEn = _isEnglishLocale;
    final auth = _currentAuthEmail()?.trim();
    if (auth != null && auth.isNotEmpty) {
      return isEn ? 'Linked email: $auth' : '연결된 이메일: $auth';
    }
    final pe = _profile?['email']?.toString().trim() ?? '';
    if (pe.isNotEmpty) {
      return isEn ? 'Linked email: $pe' : '연결된 이메일: $pe';
    }
    return l10n?.noLinkedEmail ?? (isEn ? 'No email linked' : '연동된 이메일 없음');
  }

  bool _looksLikeEmail(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains(' ')) return false;
    final at = trimmed.indexOf('@');
    if (at <= 0 || at >= trimmed.length - 1) return false;
    final local = trimmed.substring(0, at);
    final domain = trimmed.substring(at + 1);
    if (local.isEmpty || domain.isEmpty) return false;
    if (!domain.contains('.')) return false;
    if (domain.startsWith('.') || domain.endsWith('.')) return false;
    return true;
  }

  String _formatAuthError(Object e) {
    if (e is AuthException) return e.message;
    return e.toString();
  }

  bool _isEmailAlreadyUsedError(Object e) {
    final message = _formatAuthError(e).toLowerCase();

    return message.contains('already') ||
        message.contains('exists') ||
        message.contains('registered') ||
        message.contains('duplicate') ||
        message.contains('unique') ||
        message.contains('already been registered') ||
        message.contains('email address is already') ||
        message.contains('user already registered') ||
        message.contains('email already') ||
        message.contains('already exists');
  }

  Future<void> _showEmailDuplicateNotice() async {
    if (_isEmailDuplicateNoticeOpen) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isEmailDuplicateNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  Future<void> _hideEmailDuplicateNotice() async {
    if (!_isEmailDuplicateNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isEmailDuplicateNoticeOpen = false,
    );
  }

  void _closeEmailDuplicateNoticeOverlay() {
    if (!_isEmailDuplicateNoticeOpen) return;
    unawaited(_hideEmailDuplicateNotice());
  }

  Future<void> _showDuplicatePetNameNotice() async {
    if (_isDuplicatePetNameNoticeOpen) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isDuplicatePetNameNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  Future<void> _hideDuplicatePetNameNotice() async {
    if (!_isDuplicatePetNameNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isDuplicatePetNameNoticeOpen = false,
    );
  }

  void _closeDuplicatePetNameNoticeOverlay() {
    if (!_isDuplicatePetNameNoticeOpen) return;
    unawaited(_hideDuplicatePetNameNotice());
  }

  Future<void> _showEmailAlreadyUsedDialog() async {
    await _showEmailDuplicateNotice();
  }

  void _startEmailOtpCooldown() {
    _emailOtpCooldownTimer?.cancel();

    _safeSetState(() {
      _emailOtpCooldownSeconds = 60;
    });

    _emailOtpCooldownTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_emailOtpCooldownSeconds <= 1) {
        timer.cancel();
        _emailOtpCooldownTimer = null;
        _safeSetState(() {
          _emailOtpCooldownSeconds = 0;
        });
        return;
      }

      _safeSetState(() {
        _emailOtpCooldownSeconds -= 1;
      });
    });
  }

  bool _isEmailOtpCooldownActive() {
    return _emailOtpCooldownSeconds > 0;
  }

  void _clearEmailLinkOtpSession() {
    _emailLinkOtpSessionTimer?.cancel();
    _emailLinkOtpSessionTimer = null;
    _emailLinkOtpSent = false;
    _emailLinkOtpSentForEmail = '';
    _emailLinkOtpSentAt = null;
    _emailLinkOtpController.clear();
    _emailLinkRestoreMode = false;
  }

  /// OTP 세션이 1시간을 넘기면 인증코드 입력란을 다시 비활성화한다.
  bool _expireEmailLinkOtpSessionIfNeeded() {
    if (!_emailLinkOtpSent) return false;
    final sentAt = _emailLinkOtpSentAt;
    if (sentAt == null ||
        DateTime.now().difference(sentAt) >= _kEmailLinkOtpSessionDuration) {
      _clearEmailLinkOtpSession();
      return true;
    }
    return false;
  }

  void _scheduleEmailLinkOtpSessionExpiry() {
    _emailLinkOtpSessionTimer?.cancel();
    _emailLinkOtpSessionTimer = null;
    if (!_emailLinkOtpSent) return;
    final sentAt = _emailLinkOtpSentAt;
    if (sentAt == null) return;

    final remaining = _kEmailLinkOtpSessionDuration - DateTime.now().difference(sentAt);
    if (remaining <= Duration.zero) {
      if (_expireEmailLinkOtpSessionIfNeeded() && mounted) {
        _safeSetState(() {});
      }
      return;
    }

    _emailLinkOtpSessionTimer = Timer(remaining, () {
      if (!mounted) return;
      if (_expireEmailLinkOtpSessionIfNeeded()) {
        _safeSetState(() {});
      }
    });
  }

  void _markEmailLinkOtpSessionActive(String email) {
    _emailLinkOtpSent = true;
    _emailLinkOtpSentForEmail = email;
    _emailLinkOtpSentAt = DateTime.now();
    _scheduleEmailLinkOtpSessionExpiry();
  }

  /// 연동창만 닫는다. OTP 세션(인증코드 입력 활성)은 1시간 동안 유지.
  void _closeEmailLinkPanel() {
    _emailLinkPanelSendBusy = false;
    _emailLinkPanelVerifyBusy = false;
    _emailLinkPanelResendBusy = false;
    _emailLinkController.clear();
    _emailLinkOtpController.clear();
    _isEmailLinkPanelOpen = false;
  }

  void _prepareEmailLinkPanelForOpen() {
    _expireEmailLinkOtpSessionIfNeeded();
    _emailLinkPanelSendBusy = false;
    _emailLinkPanelVerifyBusy = false;
    _emailLinkPanelResendBusy = false;
    _emailLinkRestoreMode = false;
    _emailLinkController.clear();
    _emailLinkOtpController.clear();
    if (_emailLinkOtpSent && _emailLinkOtpSentForEmail.isNotEmpty) {
      _emailLinkController.text = _emailLinkOtpSentForEmail;
    }
    _scheduleEmailLinkOtpSessionExpiry();
  }

  void _resetEmailLinkPanelOtpFlow() {
    _clearEmailLinkOtpSession();
    _emailLinkController.clear();
    _emailLinkPanelSendBusy = false;
    _emailLinkPanelVerifyBusy = false;
    _emailLinkPanelResendBusy = false;
  }

  Future<void> _refreshAllUserDataAfterAuthChange() async {
    _pokedexEntries = [];
    _pokedexPanelSelectedEntry = null;

    await Future.wait([
      _fetchProfile(),
      _fetchPetSpecies(),
      _fetchActivePet(),
      _fetchResidentPets(),
      _fetchTodayMealLogs(),
      _fetchRandomTicketCount(),
      _fetchPokedexEntries(),
    ]);

    if (!mounted) return;
    _syncProfileFormFromFetched();
    _safeSetState(() {});
  }

  Future<void> _showEmailLinkSuccessNotice() async {
    if (_isEmailLinkSuccessNoticeOpen) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isEmailLinkSuccessNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  Future<void> _hideEmailLinkSuccessNotice() async {
    if (!_isEmailLinkSuccessNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isEmailLinkSuccessNoticeOpen = false,
    );
  }

  Future<void> _showEmailFormatErrorNotice() async {
    if (_isEmailFormatErrorNoticeOpen) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isEmailFormatErrorNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  Future<void> _hideEmailFormatErrorNotice() async {
    if (!_isEmailFormatErrorNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isEmailFormatErrorNoticeOpen = false,
    );
  }

  void _closeEmailFormatErrorNoticeOverlay() {
    if (!_isEmailFormatErrorNoticeOpen) return;
    unawaited(_hideEmailFormatErrorNotice());
  }

  Future<bool> _promptEmailFormatErrorIfNeeded(String email) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty) return false;
    if (_looksLikeEmail(trimmed)) return false;
    await _showEmailFormatErrorNotice();
    return true;
  }

  void _closeEmailLinkSuccessNoticeOverlay() {
    if (!_isEmailLinkSuccessNoticeOpen) return;
    unawaited(_hideEmailLinkSuccessNotice());
  }

  _MealNotificationTexts _mealNotificationTextsForLocaleCode(
    String localeCode,
  ) {
    final code = localeCode == 'en' ? 'en' : 'ko';

    if (code == 'en') {
      return const _MealNotificationTexts(
        title: 'VegePet Meal Time',
        messages: [
          'VegePet may be getting hungry!',
          'It’s time to give VegePet a healthy meal!',
        ],
      );
    }

    return const _MealNotificationTexts(
      title: '베지펫 식사 시간',
      messages: ['베지펫이 배가 고플 시간이에요!', '베지펫에게 건강한 음식을 줄 시간이에요!'],
    );
  }

  Future<String> _loadSavedLocaleCodeForNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kLocalePrefKey) ?? 'ko';
    return code == 'en' ? 'en' : 'ko';
  }

  Future<void> _initNotificationsIfNeeded() async {
    if (_isNotificationInitialized) return;

    tz.initializeTimeZones();
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone));
    } catch (e) {
      debugPrint('timezone init failed: $e');
      tz.setLocalLocation(tz.getLocation('Asia/Seoul'));
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );
    await _notifications.initialize(initSettings);
    _isNotificationInitialized = true;
  }

  Future<bool> _requestNotificationPermissionIfNeeded() async {
    var granted = true;

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      final enabled = await androidPlugin.areNotificationsEnabled();
      if (enabled != true) {
        final requested = await androidPlugin.requestNotificationsPermission();
        if (requested != true) granted = false;
      }
    }

    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      final requested = await iosPlugin.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      if (requested != true) granted = false;
    }

    return granted;
  }

  Future<void> _loadPushSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _noticeEventPushEnabled = prefs.getBool(_kNoticeEventPushPrefKey) ?? false;
    _mealReminderPushEnabled =
        prefs.getBool(_kMealReminderPushPrefKey) ?? false;
  }

  Future<void> _loadSoundSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _backgroundMusicEnabled = prefs.getBool(_kBackgroundMusicPrefKey) ?? true;
    _soundEffectsEnabled = prefs.getBool(_kSoundEffectsPrefKey) ?? true;
  }

  Future<void> _resetSettingsToDefaultsForTesting() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(_kLocalePrefKey, 'ko');
      await prefs.setBool(_kNoticeEventPushPrefKey, false);
      await prefs.setBool(_kMealReminderPushPrefKey, false);
      await prefs.setBool(_kBackgroundMusicPrefKey, true);
      await prefs.setBool(_kSoundEffectsPrefKey, true);

      await _cancelMealReminderNotifications();
      await _stopBackgroundMusic();

      if (mounted) {
        _safeSetState(() {
          _noticeEventPushEnabled = false;
          _mealReminderPushEnabled = false;
          _backgroundMusicEnabled = true;
          _soundEffectsEnabled = true;
        });
      } else {
        _noticeEventPushEnabled = false;
        _mealReminderPushEnabled = false;
        _backgroundMusicEnabled = true;
        _soundEffectsEnabled = true;
      }

      if (mounted) {
        try {
          final localeScope = _LocaleControllerScope.of(context);
          await localeScope.setLocale(const Locale('ko'));
        } catch (e) {
          debugPrint('set locale to ko after reset failed: $e');
        }
      }

      try {
        await _startBackgroundMusicIfEnabled();
      } catch (e) {
        debugPrint('restart bgm after reset failed: $e');
      }
    } catch (e) {
      debugPrint('reset settings to defaults failed: $e');
    }
  }

  Future<void> _saveNoticeEventPushEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNoticeEventPushPrefKey, enabled);
  }

  Future<void> _saveMealReminderPushEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMealReminderPushPrefKey, enabled);
  }

  Future<void> _initSoundIfNeeded() async {
    if (_isSoundInitialized) return;

    try {
      await _bgmPlayer.setReleaseMode(ReleaseMode.loop);
      await _bgmPlayer.setVolume(0.45);

      await _sfxPlayer.setReleaseMode(ReleaseMode.stop);
      await _sfxPlayer.setVolume(0.8);

      _isSoundInitialized = true;
    } catch (e) {
      debugPrint('sound init failed: $e');
    }
  }

  Future<void> _startBackgroundMusicIfEnabled() async {
    if (!_backgroundMusicEnabled) return;
    if (_bgmAssetUnavailable) return;

    try {
      await _initSoundIfNeeded();
      // TODO(vegepet): 실제 BGM 파일 준비 후 assets/audio/bgm_yard.mp3를
      // pubspec.yaml assets에 등록하고 재생 연결.
      // TODO(vegepet): 실음원 연결 시 _bgmAssetUnavailable 처리 재검토.
      await _bgmPlayer.play(AssetSource('audio/bgm_yard.mp3'));
    } catch (e) {
      _bgmAssetUnavailable = true;
      debugPrint('start bgm skipped/failed: $e');
    }
  }

  Future<void> _stopBackgroundMusic() async {
    try {
      await _bgmPlayer.stop();
    } catch (e) {
      debugPrint('stop bgm failed: $e');
    }
  }

  Future<void> _playSoundEffect(String assetPath) async {
    if (!_soundEffectsEnabled) return;
    if (_sfxAssetUnavailable) return;

    try {
      await _initSoundIfNeeded();
      // TODO(vegepet): 실제 효과음 파일 준비 후 assets/audio/sfx_tap.mp3 등을
      // pubspec.yaml assets에 등록하고 연결.
      // TODO(vegepet): 효과음 파일 확장 시 _sfxAssetUnavailable 처리 세분화 검토.
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource(assetPath));
    } catch (e) {
      _sfxAssetUnavailable = true;
      debugPrint('play sfx skipped/failed: $e');
    }
  }

  // ignore: unused_element
  Future<void> _playTapSound() async {
    await _playSoundEffect('audio/sfx_tap.mp3');
  }

  // ignore: unused_element
  Future<void> _playSuccessSound() async {
    await _playSoundEffect('audio/sfx_success.mp3');
  }

  Future<bool> _toggleBackgroundMusic(
    bool enabled, {
    required String enabledMessage,
    required String disabledMessage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackgroundMusicPrefKey, enabled);

    if (mounted) {
      _safeSetState(() => _backgroundMusicEnabled = enabled);
    } else {
      _backgroundMusicEnabled = enabled;
    }

    if (enabled) {
      await _startBackgroundMusicIfEnabled();
      _showSnack(enabledMessage);
    } else {
      await _stopBackgroundMusic();
      _showSnack(disabledMessage);
    }

    return true;
  }

  Future<bool> _toggleSoundEffects(
    bool enabled, {
    required String enabledMessage,
    required String disabledMessage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSoundEffectsPrefKey, enabled);

    if (mounted) {
      _safeSetState(() => _soundEffectsEnabled = enabled);
    } else {
      _soundEffectsEnabled = enabled;
    }

    if (enabled) {
      _showSnack(enabledMessage);
    } else {
      _showSnack(disabledMessage);
    }

    return true;
  }

  Future<void> _cancelMealReminderNotifications() async {
    for (
      var dayIndex = 0;
      dayIndex < _kMealReminderDaysToSchedule;
      dayIndex++
    ) {
      for (var slotIndex = 0; slotIndex < 2; slotIndex++) {
        final id = _kMealReminderNotificationIdBase + dayIndex * 10 + slotIndex;
        await _notifications.cancel(id);
      }
    }
  }

  Future<void> _scheduleMealReminderNotifications({
    required String notificationTitle,
    required List<String> notificationMessages,
    String? permissionDeniedMessage,
    bool revertToggleWhenDenied = true,
  }) async {
    if (_isSchedulingMealReminders) return;
    _isSchedulingMealReminders = true;
    try {
      await _cancelMealReminderNotifications();
      final hasPermission = await _requestNotificationPermissionIfNeeded();
      if (!hasPermission) {
        if (revertToggleWhenDenied) {
          await _saveMealReminderPushEnabled(false);
          if (mounted) {
            _safeSetState(() {
              _mealReminderPushEnabled = false;
            });
          } else {
            _mealReminderPushEnabled = false;
          }
          if (permissionDeniedMessage != null &&
              permissionDeniedMessage.isNotEmpty) {
            _showSnack(permissionDeniedMessage);
          }
        } else {
          debugPrint(
            'meal reminder schedule skipped: notification permission denied',
          );
        }
        return;
      }
      if (notificationMessages.isEmpty) {
        debugPrint('meal reminder schedule skipped: no notification message');
        return;
      }
      const mealSlots = <(int, int)>[(12, 0), (18, 0)];
      final now = tz.TZDateTime.now(tz.local);

      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'vegepet_meal_reminders',
          'VegePet Meal Reminders',
          channelDescription: 'Daily scheduled reminders for VegePet meals.',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        ),
      );

      for (
        var dayIndex = 0;
        dayIndex < _kMealReminderDaysToSchedule;
        dayIndex++
      ) {
        final dayBase = tz.TZDateTime(
          tz.local,
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: dayIndex));

        for (var slotIndex = 0; slotIndex < mealSlots.length; slotIndex++) {
          final slot = mealSlots[slotIndex];
          final scheduledAt = tz.TZDateTime(
            tz.local,
            dayBase.year,
            dayBase.month,
            dayBase.day,
            slot.$1,
            slot.$2,
          );
          if (!scheduledAt.isAfter(now)) continue;
          final id =
              _kMealReminderNotificationIdBase + dayIndex * 10 + slotIndex;
          final message =
              notificationMessages[Random().nextInt(
                notificationMessages.length,
              )];
          await _notifications.zonedSchedule(
            id,
            notificationTitle,
            message,
            scheduledAt,
            details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      }
    } finally {
      _isSchedulingMealReminders = false;
    }
  }

  Future<bool> _toggleMealReminderPush(
    bool enabled, {
    required String notificationTitle,
    required List<String> notificationMessages,
    required String permissionDeniedMessage,
    required String enabledMessage,
    required String disabledMessage,
  }) async {
    await _initNotificationsIfNeeded();
    if (enabled) {
      final hasPermission = await _requestNotificationPermissionIfNeeded();
      if (!hasPermission) {
        await _saveMealReminderPushEnabled(false);
        if (mounted) {
          _safeSetState(() => _mealReminderPushEnabled = false);
        } else {
          _mealReminderPushEnabled = false;
        }
        _showSnack(permissionDeniedMessage);
        return false;
      }

      await _saveMealReminderPushEnabled(true);
      if (mounted) {
        _safeSetState(() => _mealReminderPushEnabled = true);
      } else {
        _mealReminderPushEnabled = true;
      }
      await _scheduleMealReminderNotifications(
        notificationTitle: notificationTitle,
        notificationMessages: notificationMessages,
        permissionDeniedMessage: permissionDeniedMessage,
      );
      _showSnack(enabledMessage);
      return true;
    }

    await _saveMealReminderPushEnabled(false);
    if (mounted) {
      _safeSetState(() => _mealReminderPushEnabled = false);
    } else {
      _mealReminderPushEnabled = false;
    }
    await _cancelMealReminderNotifications();
    _showSnack(disabledMessage);
    return true;
  }

  Future<bool> _toggleNoticeEventPush(
    bool enabled, {
    required String enabledMessage,
    required String disabledMessage,
  }) async {
    // TODO(vegepet): 추후 FCM/Supabase Edge Function 연동 시 이 토글 값을 수신 동의 상태로 사용
    await _saveNoticeEventPushEnabled(enabled);
    if (mounted) {
      _safeSetState(() => _noticeEventPushEnabled = enabled);
    } else {
      _noticeEventPushEnabled = enabled;
    }
    _showSnack(enabled ? enabledMessage : disabledMessage);
    return true;
  }

  Future<void> _syncAuthEmailToProfileIfNeeded() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final authEmail = user.email?.trim();
    if (authEmail == null || authEmail.isEmpty) return;

    final profileEmail = _profile?['email']?.toString().trim() ?? '';
    final accountType = _profile?['account_type']?.toString();

    if (profileEmail == authEmail && accountType == 'email') return;

    try {
      await supabase
          .from('profiles')
          .update({
            'email': authEmail,
            'account_type': 'email',
            'linked_at':
                _profile?['linked_at'] ?? DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', user.id);

      await _fetchProfile();
    } catch (e) {
      debugPrint('sync auth email to profile failed: $e');
    }
  }

  Future<bool> _sendEmailLinkOtp(String email) async {
    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return false;
    }
    final trimmed = email.trim();
    if (trimmed.isEmpty) {
      _showSnack(l10n.snackEmailRequired);
      return false;
    }
    try {
      await supabase.auth.updateUser(UserAttributes(email: trimmed));
      if (mounted) {
        _safeSetState(() => _emailLinkRestoreMode = false);
      } else {
        _emailLinkRestoreMode = false;
      }
      _showSnack(l10n.snackOtpSent);
      return true;
    } catch (e) {
      if (_isEmailAlreadyUsedError(e)) {
        await _showEmailDuplicateNotice();
        return false;
      }
      _showSnack(l10n.snackOtpSendFailed(_formatAuthError(e)));
      return false;
    }
  }

  Future<bool> _verifyEmailLinkOtp({
    required String email,
    required String token,
  }) async {
    final l10n = AppLocalizations.of(context);
    final trimmedEmail = email.trim();
    final trimmedToken = token.trim();
    if (trimmedEmail.isEmpty || trimmedToken.isEmpty) {
      _showSnack(l10n.snackEmailOtpRequired);
      return false;
    }
    final otpType =
        _emailLinkRestoreMode ? OtpType.email : OtpType.emailChange;
    try {
      await supabase.auth.verifyOTP(
        email: trimmedEmail,
        token: trimmedToken,
        type: otpType,
      );
    } catch (e) {
      if (_isEmailAlreadyUsedError(e)) {
        await _showEmailAlreadyUsedDialog();
        return false;
      }
      _showSnack(l10n.snackOtpVerifyFailed(_formatAuthError(e)));
      return false;
    }

    try {
      await _syncAuthEmailToProfileIfNeeded();
      await _refreshAllUserDataAfterAuthChange();
      if (mounted) {
        _safeSetState(() => _emailLinkRestoreMode = false);
      } else {
        _emailLinkRestoreMode = false;
      }
      return true;
    } catch (e) {
      _showSnack(l10n.snackEmailLinkPartialSavedFailed);
      debugPrint('verify email otp profile sync failed: $e');
      if (mounted) {
        _safeSetState(() => _emailLinkRestoreMode = false);
      } else {
        _emailLinkRestoreMode = false;
      }
      return true;
    }
  }

  Future<void> _fetchPetSpecies() async {
    final data = await supabase
        .from('pet_species')
        .select('id, code, name_ko, family, sort_order')
        .order('sort_order');

    _petSpecies = List<Map<String, dynamic>>.from(data);
  }

  Future<void> _fetchActivePet() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _activePet = null;
      return;
    }

    final data = await supabase
        .from('user_pets')
        .select(
          'id, user_id, pet_species_id, nickname, stage, affection, is_active, is_resident, graduated_at, created_at, last_played_on, last_petted_on, pet_species:pet_species_id(id, code, name_ko, family, sort_order)',
        )
        .eq('user_id', user.id)
        .eq('is_active', true)
        .maybeSingle();

    _activePet = data == null ? null : Map<String, dynamic>.from(data);
  }

  // 성숙기 졸업 후 마당에 거주 중인 펫 목록 조회.
  //
  // finalize_pet_graduation 이후의 펫(`is_resident=true`, `graduated_at !=
  // null`)들을 모두 가져와서 마당 화면에 함께 표시한다. 새 펫이 분양되어
  // 기존 성숙기 펫이 `is_active=false` 가 되어도 이 목록에는 계속 포함된다.
  //
  // 조회 자체가 실패해도 앱이 죽지 않도록 catch 해서 _residentPets 만 비운다.
  Future<void> _fetchResidentPets() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _residentPets = [];
      return;
    }
    try {
      final data = await supabase
          .from('user_pets')
          .select(
            'id, user_id, pet_species_id, nickname, stage, affection, is_active, is_resident, graduated_at, pet_species:pet_species_id(id, code, name_ko, family, sort_order)',
          )
          .eq('user_id', user.id)
          .eq('is_resident', true)
          .not('graduated_at', 'is', null)
          .order('graduated_at');

      _residentPets = (data as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      debugPrint('fetch resident pets failed: $e');
      _residentPets = [];
    }
  }

  Future<void> _fetchTodayMealLogs() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _todayMealLogs = [];
      return;
    }
    final today = _todayDateStr();
    final data = await supabase
        .from('meal_logs')
        .select('id, meal_slot, result_type, affection_gain, created_at')
        .eq('user_id', user.id)
        .eq('meal_date', today);

    _todayMealLogs = List<Map<String, dynamic>>.from(data);
  }

  /// 가방에 쌓여 있는 랜덤 분양권(`random_adoption_ticket`)의 총 수량을 조회한다.
  ///
  /// user_items 를 item_masters 와 join 해서 `code = 'random_adoption_ticket'`
  /// 인 행들의 quantity 합계를 계산한다. 실패해도 앱은 계속 동작해야 하므로
  /// 예외 발생 시 0 으로 떨어뜨린다.
  Future<void> _fetchRandomTicketCount() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _randomTicketCount = 0;
      return;
    }
    try {
      final data = await supabase
          .from('user_items')
          .select('quantity, item_masters:item_master_id(code)')
          .eq('user_id', user.id);

      var total = 0;
      for (final row in (data as List)) {
        if (row is! Map) continue;
        final master = row['item_masters'];
        final code = master is Map ? master['code']?.toString() : null;
        if (code != 'random_adoption_ticket') continue;
        total += (row['quantity'] as num?)?.toInt() ?? 0;
      }
      _randomTicketCount = total;
    } catch (e) {
      debugPrint('fetch random ticket count failed: $e');
      _randomTicketCount = 0;
    }
  }

  /// 랜덤 분양권은 `finalize_pet_graduation`(성숙기 졸업) 이후에만 지급된다.
  /// 테스트/마이그레이션 등으로 `user_items` 에만 남은 행은 졸업 이력이 없으면
  /// 가방·사용 플로우에서 노출하지 않는다.
  bool _hasCompletedMaturityGraduationForTicketUi() {
    if (_residentPets.isNotEmpty) return true;
    final p = _activePet;
    if (p != null && p['graduated_at'] != null && p['is_resident'] == true) {
      return true;
    }
    return false;
  }

  /// 가방/분양권 사용 버튼 등 사용자에게 보여 줄 유효 수량.
  int _effectiveRandomTicketCountForBag() {
    if (!_hasCompletedMaturityGraduationForTicketUi()) return 0;
    return _randomTicketCount;
  }

  // 도감(pokedex) 등록 펫 조회.
  //
  // 이전에는 pokedex_entries / pet_species / source_user_pet 을 PostgREST relation
  // alias 로 한 번에 join 해서 가져왔지만, 관계명/RLS 차이에 따라 join 자체가
  // 실패하면 도감이 통째로 비어 보이는 문제가 있었다.
  //
  // 그래서 아래 흐름으로 안전하게 가져온다:
  //   1) pokedex_entries 기본 row(컬럼만) 조회
  //   2) 거기서 모은 pet_species_id 들을 pet_species 에서 별도 조회
  //   3) source_user_pet_id 들을 user_pets 에서 별도 조회 (실패해도 도감은 표시)
  //   4) Flutter 쪽에서 row['pet_species'] / row['source_user_pet'] 에 직접 붙여
  //      기존 도감 UI 와 호환되는 형태로 합친다.
  //   5) sort_order(asc) → registered_at(asc) 로 정렬.
  Future<void> _fetchPokedexEntries() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      debugPrint('pokedex fetch skipped: user is null');
      _pokedexEntries = [];
      _pokedexPanelSelectedEntry = null;
      if (mounted) {
        _safeSetState(() {});
      }
      return;
    }

    debugPrint('pokedex current user id: ${user.id}');

    // 1) pokedex_entries 기본 row 만 먼저 조회.
    List<Map<String, dynamic>> entries = [];
    try {
      final rawEntries = await supabase
          .from('pokedex_entries')
          .select(
            'id, user_id, pet_species_id, source_user_pet_id, registered_at',
          )
          .eq('user_id', user.id);
      entries = (rawEntries as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e, st) {
      debugPrint('fetch pokedex base entries failed: $e\n$st');
      _pokedexEntries = [];
      _pokedexPanelSelectedEntry = null;
      if (mounted) {
        _safeSetState(() {});
      }
      return;
    }

    debugPrint('pokedex base entries count: ${entries.length}');

    if (entries.isEmpty) {
      _pokedexEntries = [];
      _pokedexPanelSelectedEntry = null;
      if (mounted) {
        _safeSetState(() {});
      }
      return;
    }

    try {
      // 2) pet_species_id 모음 → pet_species 별도 조회.
      final speciesIds = entries
          .map((e) {
            final raw = e['pet_species_id'];
            return raw is int ? raw : int.tryParse(raw?.toString() ?? '');
          })
          .whereType<int>()
          .toSet()
          .toList();

      debugPrint('pokedex species ids: $speciesIds');

      final speciesById = <int, Map<String, dynamic>>{};
      if (speciesIds.isNotEmpty) {
        try {
          final speciesRows = await supabase
              .from('pet_species')
              .select('id, code, name_ko, family, sort_order')
              .filter('id', 'in', '(${speciesIds.join(',')})');
          for (final s in (speciesRows as List).whereType<Map>()) {
            final raw = s['id'];
            final id = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
            if (id != null) {
              speciesById[id] = Map<String, dynamic>.from(s);
            }
          }
        } catch (e) {
          debugPrint('fetch pet_species for pokedex failed: $e');
        }
      }

      // 3) source_user_pet_id 모음 → user_pets 별도 조회 (실패해도 진행).
      final sourcePetIds = entries
          .map((e) => e['source_user_pet_id']?.toString())
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toSet()
          .toList();

      debugPrint('pokedex source pet ids: $sourcePetIds');

      final sourcePetById = <String, Map<String, dynamic>>{};
      if (sourcePetIds.isNotEmpty) {
        try {
          final quoted = sourcePetIds.map((id) => '"$id"').join(',');
          final sourcePetRows = await supabase
              .from('user_pets')
              .select('id, nickname, stage, graduated_at')
              .filter('id', 'in', '($quoted)');
          for (final p in (sourcePetRows as List).whereType<Map>()) {
            final id = p['id']?.toString();
            if (id != null && id.isNotEmpty) {
              sourcePetById[id] = Map<String, dynamic>.from(p);
            }
          }
        } catch (e) {
          debugPrint('fetch source user_pets for pokedex failed: $e');
        }
      }

      // 4) 각 row 에 species / source_user_pet 을 직접 붙인다.
      for (final e in entries) {
        final rawSpeciesId = e['pet_species_id'];
        final speciesId = rawSpeciesId is int
            ? rawSpeciesId
            : int.tryParse(rawSpeciesId?.toString() ?? '');
        if (speciesId != null) {
          e['pet_species'] = speciesById[speciesId];
        }

        final sourcePetId = e['source_user_pet_id']?.toString();
        if (sourcePetId != null && sourcePetId.isNotEmpty) {
          e['source_user_pet'] = sourcePetById[sourcePetId];
        }
      }

      // 5) sort_order(asc) → registered_at(asc) 로 정렬.
      int sortOrderOf(Map<String, dynamic> entry) {
        final species = entry['pet_species'];
        if (species is Map) {
          final v = species['sort_order'];
          if (v is int) return v;
          if (v is num) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? 9999;
        }
        return 9999;
      }

      DateTime registeredAtOf(Map<String, dynamic> entry) {
        final raw = entry['registered_at']?.toString();
        if (raw == null || raw.isEmpty) {
          return DateTime.fromMillisecondsSinceEpoch(0);
        }
        return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
      }

      entries.sort((a, b) {
        final c = sortOrderOf(a).compareTo(sortOrderOf(b));
        if (c != 0) return c;
        return registeredAtOf(a).compareTo(registeredAtOf(b));
      });

      debugPrint('pokedex merged entries count: ${entries.length}');
      _pokedexEntries = entries;
      if (mounted) {
        _invalidatePokedexPanelSelectedEntryIfStale();
        // 이전 캐시가 화면에 남지 않도록 목록 갱신을 반드시 반영한다.
        _safeSetState(() {});
      }
    } catch (e, st) {
      debugPrint('fetch pokedex merge/sort failed: $e\n$st');
      _pokedexEntries = [];
      _pokedexPanelSelectedEntry = null;
      if (mounted) {
        _safeSetState(() {});
      }
    }
  }

  /// [_fetchPokedexEntries] 이후 도감에 없어진 종이면 상세 선택만 해제.
  void _invalidatePokedexPanelSelectedEntryIfStale() {
    final sel = _pokedexPanelSelectedEntry;
    if (sel == null) return;
    final raw = sel['pet_species_id'];
    final id = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    final invalid = id == null || _pokedexEntryForSpeciesId(id) == null;
    if (invalid && mounted) {
      _safeSetState(() => _pokedexPanelSelectedEntry = null);
    }
  }

  // pet_species.family 문자열을 'cat' / 'dog' / '' 로 정규화한다.
  // DB 가 'CAT', '고양이', '강아지', '댕댕이' 같은 변형 값으로 들어와 있어도
  // 도감 화면에서 고양이/강아지 섹션에 표시될 수 있도록 한다.
  String _normalizePetFamily(String raw) {
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return '';
    if (v == 'cat' ||
        v.contains('cat') ||
        v.contains('고양') ||
        v.contains('냥')) {
      return 'cat';
    }
    if (v == 'dog' ||
        v.contains('dog') ||
        v.contains('강아') ||
        v.contains('댕')) {
      return 'dog';
    }
    return '';
  }

  // 도감 entry 에서 family('cat'/'dog'/'')를 안전하게 꺼낸다.
  // 미지의 값이 들어와 있을 때를 위해 _normalizePetFamily 로 한 번 정리한다.
  String _pokedexFamilyOf(Map<String, dynamic> entry) {
    final species = entry['pet_species'];
    if (species is Map) {
      return _normalizePetFamily(species['family']?.toString() ?? '');
    }
    return '';
  }

  // 현재 활성 펫의 family('dog'/'cat'/'')를 안전하게 꺼낸다.
  String _activePetFamily() {
    final species = _speciesForPet(_activePet);
    if (species != null) {
      return _normalizePetFamily(species['family']?.toString() ?? '');
    }
    return '';
  }

  /// activePet 에서 pet_species 맵을 꺼낸다. embed relation 없으면 _petSpecies 에서 매칭.
  Map<String, dynamic>? _speciesForPet(Map<String, dynamic>? pet) {
    if (pet == null) return null;

    final embedded = pet['pet_species'];
    if (embedded is Map<String, dynamic>) return embedded;
    if (embedded is Map) return Map<String, dynamic>.from(embedded);

    final rawId = pet['pet_species_id'];
    final speciesId = rawId is int ? rawId.toString() : rawId?.toString();
    if (speciesId == null || speciesId.isEmpty) return null;

    for (final species in _petSpecies) {
      if (species['id']?.toString() == speciesId) {
        return species;
      }
    }
    return null;
  }

  // 도감 entry 에서 종 이름(name_ko)을 안전하게 꺼낸다.
  String _pokedexSpeciesNameOf(Map<String, dynamic> entry) {
    final species = entry['pet_species'];
    if (species is Map) {
      final m = Map<String, dynamic>.from(species);
      final nameKo = m['name_ko']?.toString();
      final code = m['code']?.toString();
      final localized = _localizedPetSpeciesNameFromRaw(
        nameKo: nameKo,
        family: m['family']?.toString(),
        code: code,
      );
      if (localized.isNotEmpty) return localized;
    }
    return AppLocalizations.of(context).pokedexDefaultPetName;
  }

  // 도감 entry 에서 source_user_pet.nickname 을 안전하게 꺼낸다.
  // join 자체가 실패했거나 닉네임이 비어 있는 경우 '이름 없음' 으로 표시.
  String _pokedexNicknameOf(Map<String, dynamic> entry) {
    final sourcePet = entry['source_user_pet'];
    if (sourcePet is Map) {
      final nickname = sourcePet['nickname']?.toString().trim();
      if (nickname != null && nickname.isNotEmpty) return nickname;
    }
    return '이름 없음';
  }

  /// 도감(pokedex_entries)에 등록된 펫 닉네임과 동일한 이름인지 확인한다.
  /// 조회 실패 시 false(저장 흐름 유지), 정상 조회 시 중복이면 true.
  Future<bool> _hasDuplicatePokedexPetName(String rawName) async {
    final user = supabase.auth.currentUser;
    if (user == null) return false;

    final name = rawName.trim();
    if (name.isEmpty) return false;

    try {
      final rawEntries = await supabase
          .from('pokedex_entries')
          .select('source_user_pet_id')
          .eq('user_id', user.id);

      final sourcePetIds = (rawEntries as List)
          .map((e) => (e as Map)['source_user_pet_id']?.toString())
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toSet()
          .toList();

      if (sourcePetIds.isEmpty) return false;

      final quoted = sourcePetIds.map((id) => '"$id"').join(',');
      final sourcePetRows = await supabase
          .from('user_pets')
          .select('nickname')
          .filter('id', 'in', '($quoted)');

      final normalizedTarget = name.toLowerCase();
      for (final p in (sourcePetRows as List).whereType<Map>()) {
        final nickname = p['nickname']?.toString().trim();
        if (nickname == null || nickname.isEmpty) continue;
        if (nickname.toLowerCase() == normalizedTarget) {
          return true;
        }
      }
      return false;
    } catch (e, st) {
      debugPrint('duplicate pokedex pet name check failed: $e\n$st');
      return false;
    }
  }

  // 같은 pet_species_id 가 여러 건 등록되어 있어도 도감 화면에는 종당 1마리만
  // 노출한다. 정렬은 호출 측에서 끝내고 들어오므로 처음 만난 행을 그대로 채택.
  List<Map<String, dynamic>> _dedupePokedexEntriesBySpecies(
    List<Map<String, dynamic>> entries,
  ) {
    final seen = <int>{};
    final result = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final raw = entry['pet_species_id'];
      final speciesId = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
      if (speciesId == null) continue;
      if (seen.contains(speciesId)) continue;
      seen.add(speciesId);
      result.add(entry);
    }
    return result;
  }

  int _petSpeciesSortKey(Map<String, dynamic> species) {
    final v = species['sort_order'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 9999;
  }

  /// `family` 는 [_normalizePetFamily] 결과인 `dog` / `cat` 기준.
  List<Map<String, dynamic>> _petSpeciesSortedForFamilyNorm(String familyNorm) {
    final out = _petSpecies
        .where(
          (s) =>
              _normalizePetFamily(s['family']?.toString() ?? '') == familyNorm,
        )
        .toList();
    out.sort((a, b) => _petSpeciesSortKey(a).compareTo(_petSpeciesSortKey(b)));
    return out;
  }

  int? _speciesIdFromSpeciesMap(Map<String, dynamic> species) {
    final raw = species['id'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '');
  }

  /// 도감에 등록된 entry( pet_species / source_user_pet 병합 형태 ). 없으면 null.
  /// **잠금/해제는 오직 [_pokedexEntries] 만** — resident / activePet / 이전 선택으로는
  /// 잠금 해제로 취급하지 않는다.
  Map<String, dynamic>? _pokedexEntryForSpeciesId(int speciesId) {
    final ded = _dedupePokedexEntriesBySpecies(_pokedexEntries);
    for (final e in ded) {
      final raw = e['pet_species_id'];
      final id = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
      if (id == speciesId) return e;
    }
    return null;
  }

  // 기존: Flutter에서 직접 meal_logs insert + user_pets.affection update를 수행하던 경로.
  // 이제는 meal-evaluate Edge Function이 이 역할을 대신하므로 UI에서는 호출하지 않는다.
  // 향후 디버그/백업 용도로 남겨둔다.
  // ignore: unused_element
  Future<void> _logMeal(String slot) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }
    if (_activePet == null) {
      _showSnack('먼저 펫을 분양받아주세요.');
      return;
    }
    if (_isLoggingMeal) return;

    if (_todayMealLogs.any((m) => m['meal_slot'] == slot)) {
      _showSnack('이미 해당 식단 인증을 완료했어요.');
      return;
    }

    setState(() => _isLoggingMeal = true);

    try {
      final existing = await supabase
          .from('meal_logs')
          .select('id')
          .eq('user_id', user.id)
          .limit(1);
      final isFirstEver = (existing as List).isEmpty;

      final today = _todayDateStr();

      final dup = await supabase
          .from('meal_logs')
          .select('id')
          .eq('user_id', user.id)
          .eq('meal_date', today)
          .eq('meal_slot', slot)
          .maybeSingle();

      if (dup != null) {
        if (!mounted) return;
        setState(() => _isLoggingMeal = false);
        _showSnack('이미 해당 식단 인증을 완료했어요.');
        await _fetchTodayMealLogs();
        if (mounted) setState(() {});
        return;
      }

      final petId = _activePet!['id'];
      final currentAffection = (_activePet!['affection'] as num?)?.toInt() ?? 0;

      await supabase.from('meal_logs').insert({
        'user_id': user.id,
        'user_pet_id': petId,
        'meal_date': today,
        'meal_slot': slot,
        'result_type': 'good',
        'affection_gain': 5,
        'image_path': null,
        'memo': null,
      });

      await supabase
          .from('user_pets')
          .update({'affection': currentAffection + 5})
          .eq('id', petId);

      await Future.wait([_fetchTodayMealLogs(), _fetchActivePet()]);

      if (!mounted) return;
      setState(() => _isLoggingMeal = false);

      _showSnack(slot == 'brunch' ? '아점 인증 완료 (+5)' : '저녁 인증 완료 (+5)');

      if (isFirstEver) {
        await _maybeShowEmailLinkInviteAfterFirstMeal();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoggingMeal = false);
      _showSnack('식단 인증 저장 실패: $e');
    }
  }

  // --------------------------------------------------------------------------
  // 성장 단계 (stage) 자동 갱신 로직
  //
  // affection 값만을 기준으로 stage 를 결정한다:
  //   0 ~ 29    : baby    (유아기)
  //   30 ~ 69   : child   (유년기)
  //   70 ~ 109  : grown   (성장기)
  //   110 이상  : adult   (성숙기)
  //
  // 사용 위치:
  //   - 놀아주기 / 쓰다듬기 성공 시 (_interactPet)
  //   - AI 식단 판정 후 affection 이 서버에서 올라갔을 때
  //     (_applyMealEvaluationResult 에서 재조회 후 동기화)
  //   - 디버그 섹션의 애정도 조작 버튼
  //
  // 최초 adult 도달 시:
  //   user_pets.is_resident = true, graduated_at = now() 로 기록하고 "육성 완료" 처리.
  //   이미 adult 였거나 is_resident / graduated_at 이 이미 채워져 있으면 중복 실행하지 않는다.
  // --------------------------------------------------------------------------

  String _stageFromAffection(int affection) {
    if (affection >= 110) return 'adult';
    if (affection >= 70) return 'grown';
    if (affection >= 30) return 'child';
    return 'baby';
  }

  String? _stageGrowthMessage(String? beforeStage, String afterStage) {
    if (beforeStage == null || beforeStage == afterStage) return null;
    final l10n = AppLocalizations.of(context);
    switch (afterStage) {
      case 'child':
        return l10n.snackStageGrewToChild;
      case 'grown':
        return l10n.snackStageGrewToGrown;
      case 'adult':
        return l10n.snackStageGrewToAdult;
      default:
        return null;
    }
  }

  /// affection 변경 후 _activePet 을 다시 조회한 상태에서 호출한다.
  /// - DB 의 stage 가 affection 기준과 다르면 stage 컬럼을 맞춰준다.
  /// - 단계 변화가 있으면 SnackBar 로 안내.
  /// - 최초 adult 도달 시 [_handleAdultGraduationIfNeeded] 로 육성 완료 처리.
  Future<void> _syncStageAfterAffectionChange({
    required String? beforeStage,
  }) async {
    if (_activePet == null) return;
    final affection = (_activePet!['affection'] as num?)?.toInt() ?? 0;
    final dbStage = _activePet!['stage']?.toString() ?? 'baby';
    final targetStage = _stageFromAffection(affection);

    if (dbStage != targetStage) {
      try {
        await supabase
            .from('user_pets')
            .update({'stage': targetStage})
            .eq('id', _activePet!['id']);
        await _fetchActivePet();
        if (mounted) setState(() {});
      } catch (e) {
        debugPrint('stage sync failed: $e');
      }
    }

    // adult 도달은 _handleAdultGraduationIfNeeded 안에서 별도 스낵바를 띄우므로
    // 여기서는 child/grown 전환만 안내한다.
    if (targetStage != 'adult') {
      final message = _stageGrowthMessage(beforeStage, targetStage);
      if (message != null && mounted) _showSnack(message);
    }

    await _handleAdultGraduationIfNeeded(beforeStage: beforeStage);
  }

  /// 최초 성숙기(adult) 도달 처리.
  ///
  /// 실제 졸업(도감 등록 + 랜덤 분양권 지급 + user_pets 상태 갱신)은
  /// SQL 함수 `public.finalize_pet_graduation(p_user_pet_id uuid)` 가 원자적으로 수행한다.
  /// 여기서는 "언제 호출할지"만 책임진다.
  ///
  /// 호출 전 _activePet 이 최신 상태여야 한다.
  /// - beforeStage 가 이미 'adult' 이거나,
  ///   is_resident/graduated_at 이 이미 채워져 있으면 중복 실행하지 않는다.
  Future<void> _handleAdultGraduationIfNeeded({
    required String? beforeStage,
  }) async {
    if (_activePet == null) return;
    final currentStage = _activePet!['stage']?.toString() ?? 'baby';
    if (currentStage != 'adult') return;
    if (beforeStage == 'adult') return;

    final alreadyResident = _activePet!['is_resident'] == true;
    final alreadyGraduated = _activePet!['graduated_at'] != null;
    if (alreadyResident && alreadyGraduated) return;

    final petId = _activePet!['id']?.toString();
    if (petId == null) return;

    dynamic rpcResult;
    try {
      rpcResult = await supabase.rpc(
        'finalize_pet_graduation',
        params: {'p_user_pet_id': petId},
      );
    } catch (e) {
      if (mounted) {
        _showSnack(
          AppLocalizations.of(context).snackGraduationFailed(e.toString()),
        );
      }
      return;
    }

    // finalize_pet_graduation 실행 후 user_pets 상태와 가방(user_items) 이 모두 바뀌었을 수 있다.
    try {
      await Future.wait([
        _fetchActivePet(),
        _fetchResidentPets(),
        _fetchRandomTicketCount(),
      ]);
    } catch (e) {
      debugPrint('post-graduation refetch failed: $e');
    }
    if (!mounted) return;
    setState(() {});

    // 반환값은 DB 구현에 따라 Map 이거나 Map 배열일 수 있다. 방어적으로 파싱.
    Map<String, dynamic>? payload;
    if (rpcResult is Map) {
      payload = Map<String, dynamic>.from(rpcResult);
    } else if (rpcResult is List && rpcResult.isNotEmpty) {
      final first = rpcResult.first;
      if (first is Map) payload = Map<String, dynamic>.from(first);
    }

    final alreadyGraduatedFlag = payload?['already_graduated'] == true;
    // ticket_granted 키가 명시적으로 false 가 아닌 한 지급된 것으로 간주한다.
    final ticketGranted = payload == null
        ? true
        : payload['ticket_granted'] != false;

    final l10n = AppLocalizations.of(context);
    if (alreadyGraduatedFlag) {
      _showSnack(l10n.snackPetAlreadyGraduated);
      return;
    }

    _showSnack(l10n.snackStageReachedAdult);
    if (ticketGranted) {
      _showSnack(l10n.snackRandomTicketGranted);
    }
  }

  // 간단 MVP 상호작용: user_pets.affection을 +1 올리고 마지막 사용 날짜를 저장한다.
  // 하루 1회 제한은 user_pets.last_played_on / last_petted_on 값을
  // 오늘 날짜(yyyy-mm-dd)와 비교해서 강제한다.
  // action: 'play' | 'pet'
  Future<void> _interactPet(String action) async {
    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return;
    }
    if (_activePet == null) {
      _showSnack(l10n.snackAdoptFirst);
      return;
    }
    if (_isInteracting) return;

    final isPlay = action == 'play';
    final label = isPlay ? l10n.petActionPlay : l10n.petActionPet;
    final dateColumn = isPlay ? 'last_played_on' : 'last_petted_on';

    final today = _todayDateStr();
    final lastUsedOn = _activePet![dateColumn]?.toString();
    if (lastUsedOn == today) {
      _showSnack(
        isPlay ? l10n.snackPlayedTodayAlready : l10n.snackPettedTodayAlready,
      );
      return;
    }

    setState(() => _isInteracting = true);

    try {
      final petId = _activePet!['id'];
      final currentAffection = (_activePet!['affection'] as num?)?.toInt() ?? 0;
      final beforeStage = _activePet!['stage']?.toString() ?? 'baby';

      final nextAffection = currentAffection + 1;
      final nextStage = _stageFromAffection(nextAffection);

      await supabase
          .from('user_pets')
          .update({
            'affection': nextAffection,
            'stage': nextStage,
            dateColumn: today,
          })
          .eq('id', petId);

      await _fetchActivePet();

      if (!mounted) return;
      setState(() => _isInteracting = false);
      _showSnack(
        AppLocalizations.of(context).snackPlayActionSuccess(label),
      );

      await _syncStageAfterAffectionChange(beforeStage: beforeStage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isInteracting = false);
      _showSnack(
        AppLocalizations.of(context).snackPlayActionFailed(label, e.toString()),
      );
    }
  }

  Future<void> _maybeShowEmailLinkInviteAfterFirstMeal() async {
    if (_firstMealPopupShownThisSession) return;
    if (_hasEffectiveEmailLink()) return;
    _firstMealPopupShownThisSession = true;
    await _showEmailLinkInviteNotice();
  }

  Future<void> _showEmailLinkInviteNotice() async {
    if (_isEmailLinkInviteNoticeOpen) return;
    if (_hasEffectiveEmailLink()) return;
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    _safeSetState(() => _isEmailLinkInviteNoticeOpen = true);
    _playYardConfirmOverlayEnter();
  }

  void _closeEmailLinkInviteNoticeOverlay() {
    if (!_isEmailLinkInviteNoticeOpen) return;
    unawaited(
      _dismissYardConfirmOverlayAnimated(
        () => _isEmailLinkInviteNoticeOpen = false,
      ),
    );
  }

  Future<void> _onEmailLinkInviteLinkTap() async {
    if (!_isEmailLinkInviteNoticeOpen) return;
    await _dismissYardConfirmOverlayAnimated(
      () => _isEmailLinkInviteNoticeOpen = false,
    );
    if (!mounted) return;
    await _openSettingsFromGameMenu();
    if (!mounted) return;
    _dismissFocus();
    _safeSetState(() {
      _prepareEmailLinkPanelForOpen();
      _isCustomerCenterPanelOpen = false;
      _isEmailLinkPanelOpen = true;
    });
  }

  // Edge Function(meal-evaluate)이 KST 기준으로 meal_date 를 저장하므로,
  // Flutter 쪽 조회/비교 기준도 KST(UTC+9)로 고정한다.
  // (기기 로컬 타임존과 무관하게 항상 동일한 meal_date 문자열이 나오도록 처리)
  String _todayDateStr() {
    final d = DateTime.now().toUtc().add(const Duration(hours: 9));
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  bool _isActivePetPettedToday() {
    if (_activePet == null) return false;
    return _activePet!['last_petted_on']?.toString() == _todayDateStr();
  }

  void _ensurePettingTapTarget() {
    final today = _todayDateStr();
    final petId = _activePet?['id']?.toString();
    if (petId == null) return;

    if (_petPettingRequiredTaps == null ||
        _petPettingTargetDate != today ||
        _petPettingTargetPetId != petId) {
      _petPettingTapCount = 0;
      _petPettingRequiredTaps = 3 + Random().nextInt(3);
      _petPettingTargetDate = today;
      _petPettingTargetPetId = petId;
    }
  }

  /// 프로필/분양/이름창 등이 열리거나 장난감 모드일 때 마당 펫 탭 비활성.
  bool _isYardPetTapBlocked() {
    if (_activePet == null) return true;
    if (_isInteracting) return true;
    if (_isToyMenuOpen ||
        _isCompletingToyPlay ||
        _petToySwapInProgress ||
        _isMealPanelOpen ||
        _petMealSwapInProgress) {
      return true;
    }
    if (_isNamingDialogOpen && !_canShowActivePetDuringNaming) return true;
    if (_status != _ViewStatus.ready) return true;
    if (!_isProfileComplete()) return true;
    return false;
  }

  Future<void> _onYardPetTapped() async {
    if (_isYardPetTapBlocked()) return;
    if (_isActivePetPettedToday()) return;

    _ensurePettingTapTarget();
    _petPettingTapCount += 1;
    _safeSetState(() {});

    final required = _petPettingRequiredTaps ?? 3;
    if (_petPettingTapCount < required) {
      return;
    }

    _petPettingTapCount = 0;
    _petPettingRequiredTaps = null;

    await _interactPet('pet');
  }

  /// 프로필 입력창 「시작하기!」와 동일 그라데이션 텍스트 (먹이주기/놀아주기 등 공통).
  ///
  /// 영어 locale 에서는 descender 가 있는 글자(y, g, p 등)가 height: 1.0 일 때
  /// 그라데이션 클리핑 영역 밖으로 나가 흰색으로 보이는 문제가 있다.
  /// → 그라데이션 텍스트는 line height 를 1.15 이상으로 키우고, gradient bounds 도
  /// 텍스트 실제 높이를 그대로 채우도록 유지한다. 한국어는 descender 가 없어
  /// 시각 차이가 거의 없고, height 1.15 도 줄 위치는 유지된다.
  Widget _buildPastelBlueGradientButtonText(
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

  // 식단일지/식단 인증과 동일하게 KST(UTC+9) 기준 "오늘" 날짜.
  DateTime _todayKstDate() {
    return DateTime.now().toUtc().add(const Duration(hours: 9));
  }

  // 오늘이 속한 달(1일 기준)을 2026-01 ~ 2035-12 범위로 보정.
  DateTime _todayDiaryMonth() {
    final now = _todayKstDate();
    return _clampDiaryMonth(DateTime(now.year, now.month, 1));
  }

  Future<void> _animateOutInitialAdoptionPanel() async {
    if (_isInitialAdoptionPanelClosing || !_isInitialAdoptionPanelVisible)
      return;
    _safeSetState(() {
      _isInitialAdoptionPanelClosing = true;
      _isInitialAdoptionPanelVisible = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 240));
    if (!mounted) return;
    _safeSetState(() {
      _isInitialAdoptionPanelClosing = false;
    });
  }

  Future<void> _adoptSelectedPet() async {
    _dismissFocus();

    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return;
    }
    if (_selectedSpeciesId == null) return;
    if (_activePet != null) {
      _showSnack(l10n.snackAlreadyRaising);
      return;
    }

    final selectedSpeciesId = int.tryParse(_selectedSpeciesId!);
    if (selectedSpeciesId == null) {
      _showSnack(l10n.snackPetSelectInvalid);
      return;
    }

    _safeSetState(() {
      _isAdopting = true;
      // 분양 insert/fetch가 끝나기 전 중간 프레임에서
      // "activePet == null" 자동 표시 조건이 다시 패널을 열지 못하게 막는다.
      _isInitialAdoptionInFlight = true;
    });
    await _animateOutInitialAdoptionPanel();

    try {
      await supabase.from('user_pets').insert({
        'user_id': user.id,
        'pet_species_id': selectedSpeciesId,
        'nickname': null,
        'stage': 'baby',
        'affection': 0,
        'is_active': true,
        'is_resident': false,
        'graduated_at': null,
      });

      await _fetchActivePet();

      if (!mounted) return;
      _safeSetState(() {
        _selectedSpeciesId = null;
        _isAdopting = false;
        _isInitialAdoptionInFlight = false;
      });

      if (!mounted) return;
      await _showNicknameDialog();
    } catch (e) {
      if (!mounted) return;
      _safeSetState(() {
        _isAdopting = false;
        _isInitialAdoptionInFlight = false;
        _isInitialAdoptionPanelClosing = false;
        _isInitialAdoptionPanelVisible = true;
      });
      _showSnack(
        AppLocalizations.of(context).snackAdoptSaveFailed(e.toString()),
      );
    }
  }

  // 분양 직후 마당 캔버스(844×390) 위 이름 짓기 패널.
  // 허용 문자: 한글/영문 대소문자/숫자, 길이 2~8자, 공백·특수문자 금지.
  // 패널이 닫히고 한 frame 양보된 뒤 Supabase 저장/스낵바를 수행한다.
  Future<void> _showNicknameDialog() async {
    final pet = _activePet;
    if (pet == null || !mounted) return;

    final petId = pet['id']?.toString();
    if (petId == null || petId.isEmpty) return;

    _dismissFocus();
    _petNamingController.clear();

    final completer = Completer<String?>();
    _petNamingCompleter = completer;

    _safeSetState(() {
      _isNamingDialogOpen = true;
      _canShowActivePetDuringNaming = true;
      _isPetNamingPanelClosing = false;
    });
    _petNamingPanelEnterController.stop();
    _petNamingPanelEnterController.value = 0;
    unawaited(_petNamingPanelEnterController.forward());

    final nickname = await completer.future;
    _petNamingCompleter = null;

    if (!mounted || nickname == null) return;

    // Dialog dispose(특히 TextEditingController dispose)가 끝난 뒤 DB 작업/상태
    // 갱신이 일어나도록 한 frame 양보.
    await _waitForUiSettle();
    if (!mounted) return;

    try {
      await supabase
          .from('user_pets')
          .update({'nickname': nickname})
          .eq('id', petId);

      await _fetchActivePet();

      if (!mounted) return;
      _safeSetState(() {});

      await _waitForUiSettle();
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context).snackNameSaved);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(context).snackNameSaveFailed(e.toString()),
      );

      // 이름 저장에 실패하면 사용자가 다시 시도할 수 있도록 한 frame 양보 후
      // 같은 다이얼로그를 재호출한다.
      await _waitForUiSettle();
      if (!mounted) return;
      await _showNicknameDialog();
    }
  }

  Future<void> _refreshAll() async {
    await _bootstrap();
  }

  Future<void> _refreshSpecies() async {
    try {
      await _fetchPetSpecies();
      if (mounted) setState(() {});
    } catch (e) {
      _showSnack('분양 데이터 조회 실패: $e');
    }
  }

  Future<void> _refreshProfile() async {
    try {
      await _fetchProfile();
      if (mounted) setState(() {});
    } catch (e) {
      _showSnack('프로필 조회 실패: $e');
    }
  }

  Future<void> _refreshActivePet() async {
    try {
      await Future.wait([
        _fetchActivePet(),
        _fetchResidentPets(),
        _fetchTodayMealLogs(),
        _fetchRandomTicketCount(),
      ]);
      if (mounted) setState(() {});
    } catch (e) {
      _showSnack('펫 정보 조회 실패: $e');
    }
  }

  Future<void> _signOut() async {
    _dismissFocus();
    try {
      await supabase.auth.signOut();
      if (!mounted) return;
      _safeSetState(() {
        _emailOtpCooldownTimer?.cancel();
        _emailOtpCooldownTimer = null;
        _emailOtpCooldownSeconds = 0;
        _profile = null;
        _petSpecies = [];
        _activePet = null;
        _residentPets = [];
        _selectedSpeciesId = null;
        _todayMealLogs = [];
        _firstMealPopupShownThisSession = false;
        _randomTicketCount = 0;
        _pokedexEntries = [];
        _isLoadingPokedex = false;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};

        _isUploadingMeal = false;
        _uploadingSlot = null;
        _isInteracting = false;
        _isUsingRandomTicket = false;
        _isInitialAdoptionPanelVisible = false;
        _isInitialAdoptionPanelClosing = false;
        _isInitialAdoptionInFlight = false;
        _isNamingDialogOpen = false;
        _canShowActivePetDuringNaming = false;
        _isPetNamingPanelClosing = false;
        _petNamingController.clear();
        if (_petNamingCompleter != null && !_petNamingCompleter!.isCompleted) {
          _petNamingCompleter!.complete(null);
        }
        _petNamingCompleter = null;
        _petNamingPanelEnterController.stop();
        _petNamingPanelEnterController.value = 0;
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;
        _petToySwapInProgress = false;
        _toyOpenedFromPetBanner = false;
        _isMealPanelOpen = false;
        _petMealSwapInProgress = false;
        _mealOpenedFromPetBanner = false;
        _petChildPanelDismissingToYard = false;
        _gameMenuPanelOpen = false;
        _gameMenuPanelRetracting = false;
        _isProfilePanelOpen = false;
        _profilePanelSwapInProgress = false;
        _profileOpenedFromGameMenu = false;
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
        _isSettingsPanelOpen = false;
        _settingsPanelSwapInProgress = false;
        _isHelpPanelOpen = false;
        _helpPanelSwapInProgress = false;

        _nicknameController.clear();
        _selectedGender = null;
        _selectedAgeRange = null;
        _selectedDietGoal = null;
        _isProfileSetupPanelVisible = true;
        _isProfileSetupClosing = false;
      });
      _petToySwapController.value = 0;
      _petMealSwapController.value = 0;
      _gameMenuPanelController.value = 0;
      _gameProfileSwapController.value = 0;
      _gameDietDiarySwapController.value = 0;
      _gameBagSwapController.value = 0;
      _gamePokedexSwapController.value = 0;
      _gameSettingsSwapController.value = 0;
      _gameHelpSwapController.value = 0;
      await _waitForUiSettle();
      if (!mounted) return;
      await _bootstrap();
    } catch (e) {
      _showSnack('로그아웃 실패: $e');
    }
  }

  // --------------------------------------------------------------------------
  // 개발용 전체 초기화
  //
  // 현재 로그인된 익명 유저 기준으로 테스트 데이터를 싹 비우고,
  // 앱이 처음 시작된 것처럼 "프로필 입력 화면"부터 다시 흐름이 시작되게 만든다.
  //
  // 동작 순서 (FK 안전, supabase.auth.currentUser.id 기준):
  //   1) meal_logs
  //   2) meal_diary_notes — 테이블 없을 수 있음 → 개별 try/catch (선행 삭제)
  //   3) pokedex_entries — **반드시 user_pets 보다 먼저** (source_user_pet_id FK)
  //      삭제 직후 select 로 잔여 row 검증 → RLS 로 delete 가 무시되면 debugPrint + Snack
  //      ※ 그래도 DB 에 row 가 남으면 Supabase 쪽 대응이 필요함. 예시:
  //        (A) RLS: create policy "Users can delete own pokedex entries"
  //            on public.pokedex_entries for delete to authenticated
  //            using (auth.uid() = user_id);
  //        (B) 개발 전용 security definer RPC 예: debug_reset_user_data — 배포 전 접근 제한 검토
  //   4) user_items
  //   5) user_pets
  //   6) profiles 프로필 필드만 초기화 (개발용이므로 email/account_type/linked_at 은 유지)
  //   7) 로컬 상태·플래그·애니메이션 컨트롤러 정리 (도감 캐시·선택 상태 포함)
  //   8) _bootstrap() 재호출
  //
  // Storage bucket(meal-photos) 의 사진 파일 삭제는 이번 단계에서 다루지 않는다.
  // 오직 디버그 섹션에서만 노출하며, 실제 서비스 기능이 아님에 주의.
  // --------------------------------------------------------------------------

  Future<bool> _confirmResetForTesting() async {
    return _showVegePetConfirmDialog(
      message: '개발용 전체 초기화를 진행할까요?',
      description: '현재 계정의 펫, 식단·도감 기록, 보유 아이템/분양권, 프로필 입력값이 초기화됩니다.',
      primaryLabel: '초기화',
      secondaryLabel: '취소',
      barrierDismissible: false,
    );
  }

  Future<void> _resetForTesting() async {
    _dismissFocus();

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인 상태가 아니어서 초기화할 수 없어요.');
      return;
    }

    final ok = await _confirmResetForTesting();
    if (!ok) return;
    if (!mounted) return;

    // 확인 Dialog 가 dispose 된 직후에 _bootstrap 으로 큰 화면 전환이 이어지므로
    // 한 frame 양보해 트리 정리가 끝난 뒤 진행한다.
    await _waitForUiSettle();
    if (!mounted) return;

    try {
      await supabase.from('meal_logs').delete().eq('user_id', user.id);
      try {
        await supabase.from('meal_diary_notes').delete().eq('user_id', user.id);
      } catch (e) {
        debugPrint('meal_diary_notes delete skipped (reset): $e');
      }
      await supabase.from('pokedex_entries').delete().eq('user_id', user.id);

      var remainingPokedexCount = 0;
      try {
        final remains = await supabase
            .from('pokedex_entries')
            .select('id')
            .eq('user_id', user.id);
        remainingPokedexCount = (remains as List).length;
      } catch (e) {
        debugPrint(
          'developer reset warning: pokedex_entries verify select failed: $e',
        );
      }
      if (remainingPokedexCount > 0) {
        debugPrint(
          'developer reset warning: pokedex_entries still remain after delete. '
          'count=$remainingPokedexCount',
        );
        _showSnack(
          '도감 초기화가 완전히 처리되지 않았어요. Supabase RLS/RPC 확인 필요 '
          '(pokedex_entries remain=$remainingPokedexCount)',
        );
      }

      await supabase.from('user_items').delete().eq('user_id', user.id);
      await supabase.from('user_pets').delete().eq('user_id', user.id);
      // 개발용 초기화: 동일 Supabase 유저·세션 유지 — 이메일 연동 필드는 건드리지 않음.
      await supabase
          .from('profiles')
          .update({
            'nickname': null,
            'gender': null,
            'age_range': null,
            'diet_goal': null,
            'gold_balance': 1000,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', user.id);

      if (!mounted) return;
      _safeSetState(() {
        _emailOtpCooldownTimer?.cancel();
        _emailOtpCooldownTimer = null;
        _emailOtpCooldownSeconds = 0;
        _lastResultType = null;
        _lastFeedbackText = null;
        _lastStatusMessage = null;
        _lastAffectionGain = null;
        _lastImagePath = null;

        _isUploadingMeal = false;
        _uploadingSlot = null;
        _isInteracting = false;
        _isUsingRandomTicket = false;
        _isInitialAdoptionPanelVisible = false;
        _isInitialAdoptionPanelClosing = false;
        _isInitialAdoptionInFlight = false;
        _isNamingDialogOpen = false;
        _canShowActivePetDuringNaming = false;
        _isAdopting = false;
        _isSavingProfile = false;
        _isLoggingMeal = false;
        _firstMealPopupShownThisSession = false;
        _randomTicketCount = 0;
        _pokedexEntries = [];
        _isLoadingPokedex = false;
        _residentPets = [];
        _activePet = null;
        _todayMealLogs = [];
        _profile = null;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;
        _petToySwapInProgress = false;
        _toyOpenedFromPetBanner = false;
        _isMealPanelOpen = false;
        _petMealSwapInProgress = false;
        _mealOpenedFromPetBanner = false;
        _petChildPanelDismissingToYard = false;
        _gameMenuPanelOpen = false;
        _gameMenuPanelRetracting = false;
        _isProfilePanelOpen = false;
        _profilePanelSwapInProgress = false;
        _profileOpenedFromGameMenu = false;
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
        _isSettingsPanelOpen = false;
        _settingsPanelSwapInProgress = false;
        _isHelpPanelOpen = false;
        _helpPanelSwapInProgress = false;
        _gameMenuSubOutsideDismissKind = _GameMenuSubOutsideDismissKind.none;

        _selectedSpeciesId = null;
        _nicknameController.clear();
        _selectedGender = null;
        _selectedAgeRange = null;
        _selectedDietGoal = null;
        _isProfileSetupPanelVisible = true;
        _isProfileSetupClosing = false;
      });
      _petToySwapController.value = 0;
      _petMealSwapController.value = 0;
      _gameMenuPanelController.value = 0;
      _gameProfileSwapController.value = 0;
      _gameDietDiarySwapController.value = 0;
      _gameBagSwapController.value = 0;
      _gamePokedexSwapController.value = 0;
      _gameSettingsSwapController.value = 0;
      _gameHelpSwapController.value = 0;
      _gameMenuSubOutsideDismissController.value = 0;

      await _resetSettingsToDefaultsForTesting();
      await _waitForUiSettle();
      if (!mounted) return;
      await _bootstrap();

      if (!mounted) return;
      _showSnack('개발용 초기화가 완료되었어요.');
    } catch (e) {
      if (!mounted) return;
      _showSnack('개발용 초기화에 실패했어요: $e');
    }
  }

  // --------------------------------------------------------------------------
  // 개발용: 성장 단계 테스트 보조 함수
  //
  // 실제 서비스 기능이 아님. 디버그 섹션 버튼에서만 호출한다.
  // affection 을 임의로 조작한 뒤 _syncStageAfterAffectionChange 로
  // stage 갱신 / 성숙기 도달 처리가 의도대로 동작하는지 빠르게 확인하기 위한 용도.
  // --------------------------------------------------------------------------

  Future<void> _debugAdjustAffection(int delta) async {
    if (_activePet == null) {
      _showSnack('활성 펫이 없어요. 먼저 분양을 완료해주세요.');
      return;
    }
    final petId = _activePet!['id'];
    final current = (_activePet!['affection'] as num?)?.toInt() ?? 0;
    final beforeStage = _activePet!['stage']?.toString() ?? 'baby';
    final next = (current + delta) < 0 ? 0 : (current + delta);
    final nextStage = _stageFromAffection(next);

    try {
      await supabase
          .from('user_pets')
          .update({'affection': next, 'stage': nextStage})
          .eq('id', petId);

      await _fetchActivePet();
      if (!mounted) return;
      setState(() {});
      _showSnack('[디버그] 애정도 $current → $next');

      await _syncStageAfterAffectionChange(beforeStage: beforeStage);
    } catch (e) {
      if (!mounted) return;
      _showSnack('[디버그] 애정도 조작 실패: $e');
    }
  }

  Future<void> _debugSetAffectionAndStage({
    required int affection,
    required String stage,
  }) async {
    if (_activePet == null) {
      _showSnack('활성 펫이 없어요. 먼저 분양을 완료해주세요.');
      return;
    }
    final petId = _activePet!['id'];
    try {
      await supabase
          .from('user_pets')
          .update({'affection': affection, 'stage': stage})
          .eq('id', petId);

      await _fetchActivePet();
      if (!mounted) return;
      setState(() {});
      _showSnack('[디버그] 세팅 완료 (affection=$affection, stage=$stage)');
    } catch (e) {
      if (!mounted) return;
      _showSnack('[디버그] 세팅 실패: $e');
    }
  }

  Future<void> _debugSetJustBeforeAdult() async {
    // 성숙기 직전 상태로 세팅: affection=109, stage=grown
    //
    // 이전에 이미 졸업 처리됐던 펫이라면 is_resident/graduated_at 이 남아 있어
    // _handleAdultGraduationIfNeeded 의 중복 방지 가드에 걸려
    // finalize_pet_graduation 재테스트가 불가능하다.
    // 따라서 졸업 플래그도 함께 초기화한다.
    if (_activePet == null) {
      _showSnack('활성 펫이 없어요. 먼저 분양을 완료해주세요.');
      return;
    }
    final petId = _activePet!['id'];
    try {
      await supabase
          .from('user_pets')
          .update({
            'affection': 109,
            'stage': 'grown',
            'is_resident': false,
            'graduated_at': null,
          })
          .eq('id', petId);

      await _fetchActivePet();
      if (!mounted) return;
      setState(() {});
      _showSnack('[디버그] 세팅 완료 (affection=109, stage=grown, 졸업 플래그 초기화)');
    } catch (e) {
      if (!mounted) return;
      _showSnack('[디버그] 세팅 실패: $e');
    }
  }

  Future<void> _debugTriggerAdult() async {
    // 성숙기 도달 테스트: affection +1 (109 → 110) 으로 adult 전환을 유도.
    // _activePet 이 이미 adult 라면 _syncStageAfterAffectionChange 내부에서
    // 중복 실행이 방지된다.
    await _debugAdjustAffection(1);
  }

  /// 디버그: 가방(user_items) 의 랜덤 분양권 수량만 다시 조회해서 상태를 갱신한다.
  Future<void> _debugRefreshRandomTicket() async {
    try {
      await _fetchRandomTicketCount();
      if (!mounted) return;
      setState(() {});
      _showSnack('[디버그] 랜덤 분양권 수량: $_randomTicketCount');
    } catch (e) {
      if (!mounted) return;
      _showSnack('[디버그] 분양권 조회 실패: $e');
    }
  }

  /// 디버그: 랜덤 분양권을 1장 사용해 랜덤 pet_species_id 가 반환되는지 확인한다.
  ///
  /// SQL 함수 `public.use_random_adoption_ticket(p_user_id uuid)` 를 호출하고,
  /// 반환되는 pet_species_id / ticket_remaining 을 스낵바로 보여준다.
  /// 실제 분양(user_pets insert) 흐름까지는 이 단계에서 연결하지 않는다.
  Future<void> _debugUseRandomAdoptionTicket() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인 상태가 아니에요.');
      return;
    }

    dynamic rpcResult;
    try {
      rpcResult = await supabase.rpc(
        'use_random_adoption_ticket',
        params: {'p_user_id': user.id},
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('[디버그] 분양권 사용 실패: $e');
      return;
    }

    Map<String, dynamic>? payload;
    if (rpcResult is Map) {
      payload = Map<String, dynamic>.from(rpcResult);
    } else if (rpcResult is List && rpcResult.isNotEmpty) {
      final first = rpcResult.first;
      if (first is Map) payload = Map<String, dynamic>.from(first);
    }

    final speciesId = payload?['pet_species_id'];
    final remaining = payload?['ticket_remaining'];

    try {
      await _fetchRandomTicketCount();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});

    _showSnack(
      '[디버그] 분양권 사용 완료! pet_species_id: ${speciesId ?? '-'} / 남은 수량: ${remaining ?? _randomTicketCount}',
    );
  }

  // --------------------------------------------------------------------------
  // 가방 (Bag) 화면
  //
  // 우측 상단 게임 메뉴 그리드에서 진입. 프로필/식단일지와 같이 동일 오버레이 슬롯에서
  // 메뉴 패널과 크로스페이드 전환한다. 아이템 탭 → 패널 내부 Stack 으로 설명창.
  // 랜덤 분양권 사용 확인/ RPC 는 _confirmUseRandomTicket · _useRandomAdoptionTicketFromBag.
  // --------------------------------------------------------------------------

  Future<void> _openBagPanelFromGameMenu() async {
    if (_bagPanelSwapInProgress) return;
    if (_gameBagSwapController.isAnimating) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetStoryPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    if (!await _closeGameMenuProfilePanelForMenuSwitch()) return;
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    try {
      await _fetchRandomTicketCount();
    } catch (_) {}
    if (!mounted) return;
    await _waitForUiSettle();
    if (!mounted) return;
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }
    _safeSetState(() {
      _bagPanelDetailItem = null;
      _bagPanelSwapInProgress = true;
      _isBagPanelOpen = true;
    });
    await _gameBagSwapController.forward(from: 0.0);
    if (!mounted) return;
    _safeSetState(() {
      _bagPanelSwapInProgress = false;
    });
  }

  Future<void> _closeBagPanelToGameMenu() async {
    if (_bagPanelSwapInProgress) return;
    _dismissFocus();
    _gameBagSwapController.value = 1.0;
    _safeSetState(() {
      _bagPanelSwapInProgress = true;
    });
    await _gameBagSwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _bagPanelSwapInProgress = false;
      _isBagPanelOpen = false;
      _bagPanelDetailItem = null;
    });
  }

  Future<void> _openPokedexPanelFromGameMenu() async {
    if (_pokedexPanelSwapInProgress) return;
    if (_gamePokedexSwapController.isAnimating) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetStoryPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    if (!await _closeGameMenuProfilePanelForMenuSwitch()) return;
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    try {
      final pending = <Future<void>>[_fetchPokedexEntries()];
      if (_petSpecies.isEmpty) pending.add(_fetchPetSpecies());
      await Future.wait(pending);
    } catch (e) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context).snackPokedexFetchFailed);
      return;
    }
    if (!mounted) return;
    if (_petSpecies.isEmpty) {
      _showSnack(AppLocalizations.of(context).snackSpeciesFetchFailed);
      return;
    }
    await _waitForUiSettle();
    if (!mounted) return;
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    _safeSetState(() {
      _pokedexPanelSelectedEntry = null;
      _pokedexPanelSwapInProgress = true;
      _isPokedexPanelOpen = true;
    });
    await _gamePokedexSwapController.forward(from: 0.0);
    if (!mounted) return;
    _safeSetState(() {
      _pokedexPanelSwapInProgress = false;
    });
  }

  Future<void> _closePokedexPanelToGameMenu() async {
    if (_pokedexPanelSwapInProgress) return;
    _dismissFocus();
    _gamePokedexSwapController.value = 1.0;
    _safeSetState(() {
      _pokedexPanelSwapInProgress = true;
      _pokedexPanelSelectedEntry = null;
    });
    await _gamePokedexSwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _pokedexPanelSwapInProgress = false;
      _isPokedexPanelOpen = false;
    });
  }

  void _instantResetStoryPanelIfOpen() {
    _gameStorySwapController.stop();
    _gameStorySwapController.value = 0.0;
    if (!_isStoryPanelOpen && !_storyPanelSwapInProgress) return;
    _safeSetState(() {
      _isStoryPanelOpen = false;
      _storyPanelSwapInProgress = false;
    });
  }

  Future<void> _openStoryPanelFromGameMenu() async {
    if (_storyPanelSwapInProgress) return;
    if (_gameStorySwapController.isAnimating) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    if (!await _closeGameMenuProfilePanelForMenuSwitch()) return;
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    await _waitForUiSettle();
    if (!mounted) return;
    _gameStorySwapController.stop();
    _gameStorySwapController.value = 0.0;
    _safeSetState(() {
      _storyPageIndex = 0;
      _storyPanelSwapInProgress = true;
      _isStoryPanelOpen = true;
    });
    await _gameStorySwapController.forward(from: 0.0);
    if (!mounted) return;
    _safeSetState(() {
      _storyPanelSwapInProgress = false;
    });
  }

  Future<void> _closeStoryPanelToGameMenu() async {
    if (_storyPanelSwapInProgress) return;
    _dismissFocus();
    _gameStorySwapController.value = 1.0;
    _safeSetState(() {
      _storyPanelSwapInProgress = true;
    });
    await _gameStorySwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _storyPanelSwapInProgress = false;
      _isStoryPanelOpen = false;
    });
  }

  void _instantResetHelpPanelIfOpen() {
    _gameHelpSwapController.stop();
    _gameHelpSwapController.value = 0.0;
    if (!_isHelpPanelOpen && !_helpPanelSwapInProgress) return;
    _safeSetState(() {
      _isHelpPanelOpen = false;
      _helpPanelSwapInProgress = false;
    });
  }

  Future<void> _openHelpPanelFromGameMenu() async {
    if (_helpPanelSwapInProgress) return;
    if (_gameHelpSwapController.isAnimating) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetStoryPanelIfOpen();
    _gameProfileSwapController.stop();
    _gameProfileSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isProfilePanelOpen = false;
        _profilePanelSwapInProgress = false;
        _profileOpenedFromGameMenu = false;
      });
    }
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    await _waitForUiSettle();
    if (!mounted) return;
    _gameHelpSwapController.stop();
    _gameHelpSwapController.value = 0.0;
    _safeSetState(() {
      _helpPanelSwapInProgress = true;
      _isHelpPanelOpen = true;
    });
    await _gameHelpSwapController.forward(from: 0.0);
    if (!mounted) return;
    _safeSetState(() {
      _helpPanelSwapInProgress = false;
    });
  }

  Future<void> _closeHelpPanelToGameMenu() async {
    if (_helpPanelSwapInProgress) return;
    _dismissFocus();
    _gameHelpSwapController.value = 1.0;
    _safeSetState(() {
      _helpPanelSwapInProgress = true;
    });
    await _gameHelpSwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _helpPanelSwapInProgress = false;
      _isHelpPanelOpen = false;
    });
  }

  Widget _buildHelpGameMenuGlassPanel() {
    final l10n = AppLocalizations.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => unawaited(_closeHelpPanelToGameMenu()),
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
              Positioned(
                left: 37,
                top: _gameMenuSubPanelTitleTop,
                right: 8,
                child: Text(
                  l10n.helpPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                  ),
                ),
              ),
              // 상세 내용은 추후 구축 예정 — 좌우 8px 여백만 유지.
              const Positioned(
                left: 8,
                right: 8,
                top: 48,
                bottom: 8,
                child: SizedBox.expand(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _goStoryPrevPage() {
    if (_storyPageAssetPaths.isEmpty) return;
    if (_storyPageIndex <= 0) return;
    _safeSetState(() => _storyPageIndex--);
  }

  void _goStoryNextPage() {
    if (_storyPageAssetPaths.isEmpty) return;
    if (_storyPageIndex >= _storyPageAssetPaths.length - 1) return;
    _safeSetState(() => _storyPageIndex++);
  }

  Widget _buildStoryIllustrationArea() {
    final paths = _storyPageAssetPaths;
    final hasAssets = paths.isNotEmpty;
    final index = hasAssets
        ? _storyPageIndex.clamp(0, paths.length - 1)
        : 0;

    Widget illustrationChild;
    if (!hasAssets) {
      illustrationChild = const SizedBox.expand();
    } else {
      illustrationChild = Image.asset(
        paths[index],
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: _kStoryIllustrationW,
        height: _kStoryIllustrationH,
        color: Colors.white.withValues(alpha: 0.15),
        child: illustrationChild,
      ),
    );
  }

  Widget _buildStoryPageNavButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 16,
            color: onTap == null
                ? const Color(0xFF000000).withValues(alpha: 0.25)
                : const Color(0xFF000000),
          ),
        ),
      ),
    );
  }

  Widget _buildStoryGameMenuGlassPanel() {
    final paths = _storyPageAssetPaths;
    final canPage = paths.length > 1;
    final canPrev = canPage && _storyPageIndex > 0;
    final canNext = canPage && _storyPageIndex < paths.length - 1;
    const navButtonTop =
        _kStoryIllustrationTop + (_kStoryIllustrationH - 28) / 2;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: _kStoryPanelW,
            height: _kStoryPanelH,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 8,
                  right: 8,
                  width: 24,
                  height: 24,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => unawaited(_closeStoryPanelToGameMenu()),
                      borderRadius: BorderRadius.circular(12),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: Color(0xFF4A4A4A),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: _kStoryIllustrationLeft,
                  top: _kStoryIllustrationTop,
                  child: _buildStoryIllustrationArea(),
                ),
                Positioned(
                  left: 8,
                  top: navButtonTop,
                  child: _buildStoryPageNavButton(
                    icon: Icons.chevron_left,
                    onTap: canPrev ? _goStoryPrevPage : null,
                  ),
                ),
                Positioned(
                  left: _kStoryIllustrationLeft + _kStoryIllustrationW + 8,
                  top: navButtonTop,
                  child: _buildStoryPageNavButton(
                    icon: Icons.chevron_right,
                    onTap: canNext ? _goStoryNextPage : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStoryPanelLayer() {
    final yardExitFade =
        _gameMenuSubOutsideDismissKind != _GameMenuSubOutsideDismissKind.none;
    if (!_isStoryPanelOpen &&
        !_storyPanelSwapInProgress &&
        !yardExitFade) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _gameStorySwapController,
        _gameMenuSubOutsideDismissController,
      ]),
      builder: (context, _) {
        final storyT =
            _gameStorySwapCurve.value.clamp(0.0, 1.0) *
            _gameMenuYardExitFadeMultiplier;

        return Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => unawaited(
                  _dismissGameSubPanelWithCenterExit(
                    _GameMenuSubOutsideDismissKind.story,
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kStoryPanelLeft,
              top: _kStoryPanelTop,
              width: _kStoryPanelW,
              height: _kStoryPanelH,
              child: IgnorePointer(
                ignoring: storyT < 0.05,
                child: Opacity(
                  opacity: storyT,
                  child: _buildStoryGameMenuGlassPanel(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 가방 설명창의 「사용하기」에서 호출. 확인 후 RPC·분양까지 진행하고,
  /// **성공 시에만** [_dismissGameSubPanelWithCenterExit](bag) 로 외부 탭과 동일한 중앙 퇴장.
  Future<void> _onBagPanelUseTicketPressed() async {
    if (_isUsingRandomTicket) return;
    if (_effectiveRandomTicketCountForBag() <= 0) {
      _showSnack(AppLocalizations.of(context).snackTicketEmpty);
      return;
    }
    _dismissFocus();
    final confirmed = await _confirmUseRandomTicket();
    if (!mounted || !confirmed) return;
    await _useRandomAdoptionTicketFromBag();
    try {
      await _fetchRandomTicketCount();
    } catch (_) {}
  }

  /// 랜덤 분양권 분양까지 성공한 뒤: 설명 오버레이 제거 후 가방·게임메뉴 슬라브를 마당 상태로 내린다.
  Future<void> _dismissBagPanelAfterTicketAdoptSuccessLikeBackdrop() async {
    if (!mounted) return;
    _safeSetState(() => _bagPanelDetailItem = null);
    if (!mounted || !_isBagPanelOpen || !_gameMenuPanelOpen) return;
    await _dismissGameSubPanelWithCenterExit(
      _GameMenuSubOutsideDismissKind.bag,
    );
  }

  _BagItem _bagWireframeRandomTicketDef() {
    // name 슬롯에는 안정적인 code 만 들어가고, 화면에 표시될 때
    // [_localizedBagItemName] / [_localizedBagItemDescription] 가 l10n 으로 변환한다.
    return _BagItem(
      category: 'ticket',
      name: 'random_adoption_ticket',
      description: '',
      quantity: _effectiveRandomTicketCountForBag() > 0
          ? _effectiveRandomTicketCountForBag()
          : 1,
      icon: Icons.confirmation_number_outlined,
      usable: false,
    );
  }

  /// VegePet 더미 아이콘 터치 정책:
  /// 아이콘+라벨 구조에서는 실제 onTap을 반드시 48×48 아이콘 사각형 영역에만 연결한다.
  /// 라벨, 여백, 전체 타일 영역을 눌러서는 로직이 실행되면 안 된다.
  /// (스플래시/하이라이트는 borderRadius 20 기준으로 이 사각형 내부에만.)
  ///
  /// [child] 는 48×48 영역을 채우는 시각(보통 [Container] + [Icon]).
  Widget _buildVegePetDummyIconInkWell({
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(width: 48, height: 48, child: child),
      ),
    );
  }

  /// 와이어프레임용 48×48 카드형 슬롯. 추후 `Image.asset` 으로 교체하기 쉽게 한 곳에 모음.
  /// 터치는 [_buildVegePetDummyIconInkWell] 와 동일: **아이콘 사각형만** onTap.
  Widget _buildBagWireframeDummyTile({
    required _BagItem item,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildVegePetDummyIconInkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
                width: 0.9,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(item.icon, size: 22, color: const Color(0xFF5C5C5C)),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 72,
          // 영어 "Random Adoption Ticket" 처럼 긴 이름은 fontSize 만 줄여도
          // 폭을 못 채우므로, FittedBox 로 1줄 표시(혹은 2줄까지 허용)한다.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text(
              _localizedBagItemName(item),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isEnglishLocale ? 10 : 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF4A4A4A),
                height: 1.15,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBagGameMenuGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final toys = _defaultToyBagItems();
    final ticketDef = _effectiveRandomTicketCountForBag() > 0
        ? _bagWireframeRandomTicketDef()
        : null;
    const sectionTitleStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.2,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      if (_bagPanelDetailItem != null) {
                        _safeSetState(() => _bagPanelDetailItem = null);
                      } else {
                        unawaited(_closeBagPanelToGameMenu());
                      }
                    },
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
              Positioned(
                left: 37,
                top: _gameMenuSubPanelTitleTop,
                right: 8,
                child: Text(
                  l10n.bagPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 48,
                bottom: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.bagSectionTickets, style: sectionTitleStyle),
                        const SizedBox(height: 8),
                        if (ticketDef != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _buildBagWireframeDummyTile(
                              item: ticketDef,
                              onTap: () => _safeSetState(
                                () => _bagPanelDetailItem = ticketDef,
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        Text(l10n.bagSectionToys, style: sectionTitleStyle),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildBagWireframeDummyTile(
                              item: toys[0],
                              onTap: () => _safeSetState(
                                () => _bagPanelDetailItem = toys[0],
                              ),
                            ),
                            const SizedBox(width: 10),
                            _buildBagWireframeDummyTile(
                              item: toys[1],
                              onTap: () => _safeSetState(
                                () => _bagPanelDetailItem = toys[1],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPokedexGameMenuGlassPanel() {
    final l10n = AppLocalizations.of(context);
    const sectionTitleStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.2,
    );
    final dogs = _petSpeciesSortedForFamilyNorm('dog');
    final cats = _petSpeciesSortedForFamilyNorm('cat');

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      if (_pokedexPanelSelectedEntry != null) {
                        _safeSetState(() => _pokedexPanelSelectedEntry = null);
                      } else {
                        unawaited(_closePokedexPanelToGameMenu());
                      }
                    },
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
              Positioned(
                left: 37,
                top: _gameMenuSubPanelTitleTop,
                right: 8,
                child: Text(
                  l10n.pokedexPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 48,
                bottom: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.pokedexSectionDogs, style: sectionTitleStyle),
                        const SizedBox(height: 8),
                        _buildPokedexGameMenuThreeSpeciesRow(dogs, 'dog'),
                        const SizedBox(height: 12),
                        Text(l10n.pokedexSectionCats, style: sectionTitleStyle),
                        const SizedBox(height: 8),
                        _buildPokedexGameMenuThreeSpeciesRow(cats, 'cat'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 도감 성숙기 완료 펫 상세 (176×222 · 가방 아이템 설명창과 동일 글래스 셸).
  Widget _buildPokedexMaturePetDetailGlassPanel(Map<String, dynamic> entry) {
    final family = _pokedexFamilyOf(entry);
    final speciesName = _pokedexSpeciesNameOf(entry);
    final nicknameLine = _pokedexNicknameOf(entry);
    final iconData = family == 'cat'
        ? Icons.pets
        : family == 'dog'
        ? Icons.cruelty_free_outlined
        : Icons.eco_outlined;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: _kBagItemDetailW,
            height: _kBagItemDetailH,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: LayoutBuilder(
                builder: (context, c) {
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(
                                  0xFFE5E5E5,
                                ).withValues(alpha: 0.75),
                                width: 0.9,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              iconData,
                              size: 22,
                              color: const Color(0xFF5C5C5C),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            speciesName,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF000000),
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            nicknameLine,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4A4A4A),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 강아지/고양이 각 3슬롯 — 해당 family 의 pet_species 가 3개 미만이면 잠금 슬롯으로 채움.
  Widget _buildPokedexGameMenuThreeSpeciesRow(
    List<Map<String, dynamic>> sorted,
    String familyNorm,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: i < sorted.length
                ? _buildPokedexGameMenuSpeciesCell(sorted[i], familyNorm)
                : _buildPokedexGameMenuEmptySpeciesSlot(),
          ),
        ],
      ],
    );
  }

  Widget _buildPokedexGameMenuEmptySpeciesSlot() {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFFEAEAEA).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
              width: 0.9,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '?',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Colors.grey.withValues(alpha: 0.45),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 72,
          child: Text(
            l10n.pokedexUnknownLabel,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4A4A4A),
              height: 1.15,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPokedexGameMenuSpeciesCell(
    Map<String, dynamic> species,
    String familyNorm,
  ) {
    final l10n = AppLocalizations.of(context);
    final speciesId = _speciesIdFromSpeciesMap(species);
    final entry = speciesId != null
        ? _pokedexEntryForSpeciesId(speciesId)
        : null;
    final unlocked = entry != null;
    final speciesName = species['name_ko']?.toString().trim();
    final codeFallback = species['code']?.toString().trim();
    String unlockedLabel = _localizedPetSpeciesNameFromRaw(
      nameKo: speciesName,
      family: species['family']?.toString(),
      code: codeFallback,
    );
    if (unlockedLabel.isEmpty) {
      unlockedLabel = l10n.pokedexDefaultPetName;
    }
    final label = unlocked ? unlockedLabel : l10n.pokedexUnknownLabel;
    final iconData = familyNorm == 'cat'
        ? Icons.pets
        : familyNorm == 'dog'
        ? Icons.cruelty_free_outlined
        : Icons.eco_outlined;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildVegePetDummyIconInkWell(
          onTap: unlocked
              ? () => _safeSetState(() => _pokedexPanelSelectedEntry = entry)
              : null,
          child: Container(
            decoration: BoxDecoration(
              color: unlocked
                  ? Colors.white.withValues(alpha: 0.78)
                  : const Color(0xFFE8E8E8).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
                width: 0.9,
              ),
            ),
            alignment: Alignment.center,
            child: unlocked
                ? Icon(iconData, size: 22, color: const Color(0xFF5C5C5C))
                : Text(
                    '?',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.withValues(alpha: 0.52),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 72,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: unlocked
                  ? const Color(0xFF4A4A4A)
                  : const Color(0xFF8A8A8A),
              height: 1.15,
            ),
          ),
        ),
      ],
    );
  }

  /// 가방 아이템 설명창: 176×222 글래스 패널, 하늘빛 그라데이션 텍스트 「사용하기」는 분양권만.
  Widget _buildBagDetailPreviewIcon(_BagItem item) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
          width: 0.9,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(item.icon, size: 22, color: const Color(0xFF5C5C5C)),
    );
  }

  Widget _buildBagTicketGradientUseButton() {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _isUsingRandomTicket
            ? null
            : () => unawaited(_onBagPanelUseTicketPressed()),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          height: 30,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Center(
            child: _isUsingRandomTicket
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _buildPastelBlueGradientButtonText(
                    AppLocalizations.of(context).bagUseAction,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildBagItemDetailGlassPanel(_BagItem item) {
    final isTicket = item.category == 'ticket';
    final showUseInPanel = isTicket && _effectiveRandomTicketCountForBag() > 0;
    final nameStyle = TextStyle(
      fontSize: _isEnglishLocale ? 10.5 : 11,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF000000),
      height: 1.2,
    );
    final descStyle = TextStyle(
      fontSize: _isEnglishLocale ? 10 : 11,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF4A4A4A),
      height: 1.35,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: _kBagItemDetailW,
            height: _kBagItemDetailH,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: _buildBagDetailPreviewIcon(item),
                  ),
                  const SizedBox(height: 8),
                  // 영어 "Random Adoption Ticket" 같은 긴 이름이 detail 패널 폭을
                  // 넘기지 않도록 FittedBox 로 한 단계 축소 허용.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      _localizedBagItemName(item),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Text(
                        _localizedBagItemDescription(item),
                        textAlign: TextAlign.left,
                        style: descStyle,
                      ),
                    ),
                  ),
                  if (showUseInPanel) ...[
                    const SizedBox(height: 8),
                    _buildBagTicketGradientUseButton(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<_BagItem> _defaultToyBagItems() {
    // name/description 슬롯에는 안정적인 code 만 들어가고, 화면 표시 시점에만
    // [_localizedBagItemName] / [_localizedBagItemDescription] 으로 변환한다.
    return const [
      _BagItem(
        category: 'toy',
        name: 'bone_doll',
        description: '',
        quantity: 1,
        icon: Icons.cruelty_free_outlined,
        usable: false,
        targetPetFamily: 'dog',
      ),
      _BagItem(
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

  // 도감 BottomSheet 열기 (레거시). 마당 게임 메뉴에서는 [_openPokedexPanelFromGameMenu] 사용.
  //
  // 시트 안에서 추가로 showDialog 를 띄우거나 DB 호출을 일으키면 모달 트리
  // 정리 타이밍이 다시 꼬일 수 있다. 그래서:
  //   1) 시트 열기 전에 _fetchPokedexEntries 로 데이터를 미리 받아 두고
  //   2) 시트 안에서는 로컬 selectedEntry 상태만 다루며
  //   3) 펫 정보 표시창도 별도 Dialog 가 아니라 같은 시트 안의 Stack overlay 로
  //      구현한다 (overlay 어디든 탭하면 닫힘).
  // ignore: unused_element
  Future<void> _openPokedexSheet() async {
    _dismissFocus();

    _safeSetState(() => _isLoadingPokedex = true);
    try {
      await _fetchPokedexEntries();
    } finally {
      if (mounted) {
        _safeSetState(() => _isLoadingPokedex = false);
      }
    }

    if (!mounted) return;

    debugPrint('pokedex entries loaded in sheet: ${_pokedexEntries.length}');

    await _waitForUiSettle();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        Map<String, dynamic>? selectedEntry;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return _buildPokedexSheetContent(
              entries: _pokedexEntries,
              selectedEntry: selectedEntry,
              onSelectEntry: (entry) {
                setSheetState(() => selectedEntry = entry);
              },
              onCloseInfo: () {
                setSheetState(() => selectedEntry = null);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPokedexSheetContent({
    required List<Map<String, dynamic>> entries,
    required Map<String, dynamic>? selectedEntry,
    required ValueChanged<Map<String, dynamic>> onSelectEntry,
    required VoidCallback onCloseInfo,
  }) {
    final theme = Theme.of(context);

    final unique = _dedupePokedexEntriesBySpecies(entries);
    final cats = unique
        .where((e) => _pokedexFamilyOf(e) == 'cat')
        .toList(growable: false);
    final dogs = unique
        .where((e) => _pokedexFamilyOf(e) == 'dog')
        .toList(growable: false);
    // family 가 'cat'/'dog' 로 정규화되지 않는 row 들도 화면에서 사라지지
    // 않도록 '기타' 섹션으로 묶어 노출한다.
    final others = unique
        .where((e) {
          final family = _pokedexFamilyOf(e);
          return family != 'cat' && family != 'dog';
        })
        .toList(growable: false);

    // BottomSheet 본문은 Stack 으로 감싸 selectedEntry 가 있을 때 같은 시트
    // 위에 정보 카드 overlay 를 띄운다. AlertDialog 를 추가로 띄우지 않으므로
    // 모달 라우트 전환 충돌 가능성이 줄어든다.
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.menu_book_outlined, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          '도감',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '성숙기까지 육성 완료한 베지펫을 확인할 수 있어요.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (unique.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '아직 도감에 등록된 베지펫이 없어요.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else ...[
                      _buildPokedexSection(
                        title: '고양이',
                        emptyText: '등록된 고양이 베지펫이 없어요.',
                        entries: cats,
                        onSelectEntry: onSelectEntry,
                      ),
                      const SizedBox(height: 16),
                      _buildPokedexSection(
                        title: '강아지',
                        emptyText: '등록된 강아지 베지펫이 없어요.',
                        entries: dogs,
                        onSelectEntry: onSelectEntry,
                      ),
                      if (others.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _buildPokedexSection(
                          title: '기타',
                          emptyText: '',
                          entries: others,
                          onSelectEntry: onSelectEntry,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            if (selectedEntry != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onCloseInfo,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.35),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: _buildPokedexInfoCard(selectedEntry),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPokedexSection({
    required String title,
    required String emptyText,
    required List<Map<String, dynamic>> entries,
    required ValueChanged<Map<String, dynamic>> onSelectEntry,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              emptyText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: entries
                .map(
                  (entry) => _buildPokedexTile(
                    entry: entry,
                    onTap: () => onSelectEntry(entry),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildPokedexTile({
    required Map<String, dynamic> entry,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final family = _pokedexFamilyOf(entry);
    final speciesName = _pokedexSpeciesNameOf(entry);
    final iconData = family == 'cat'
        ? Icons.pets
        : family == 'dog'
        ? Icons.cruelty_free_outlined
        : Icons.eco_outlined;

    return SizedBox(
      width: 76,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.secondaryContainer
                    .withValues(alpha: 0.7),
                child: Icon(
                  iconData,
                  size: 28,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                speciesName,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 도감 BottomSheet 위에 띄우는 정보 카드.
  // 카드 자체를 GestureDetector 로 감싸지 않아도, overlay 전체를 감싼 외곽
  // GestureDetector 가 모든 탭을 가로채 onCloseInfo 를 호출한다.
  Widget _buildPokedexInfoCard(Map<String, dynamic> entry) {
    final theme = Theme.of(context);
    final family = _pokedexFamilyOf(entry);
    final speciesName = _pokedexSpeciesNameOf(entry);
    final nickname = _pokedexNicknameOf(entry);
    final iconData = family == 'cat'
        ? Icons.pets
        : family == 'dog'
        ? Icons.cruelty_free_outlined
        : Icons.eco_outlined;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: theme.colorScheme.primaryContainer.withValues(
                alpha: 0.8,
              ),
              child: Icon(
                iconData,
                size: 36,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '베지펫 정보',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '종류: ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(speciesName),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '이름: ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(nickname),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '아무 곳이나 터치하면 닫혀요',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 랜덤 분양권 사용 확인 (마당 공통 알림창). 사용 → true, 취소/바깥 터치 → false.
  Future<bool> _confirmUseRandomTicket() async {
    if (!mounted) return false;
    if (_isRandomTicketUseConfirmOpen) {
      return _randomTicketUseConfirmCompleter?.future ?? Future.value(false);
    }
    _dismissFocus();
    _instantCloseYardConfirmOverlays();
    final completer = Completer<bool>();
    _randomTicketUseConfirmCompleter = completer;
    _safeSetState(() => _isRandomTicketUseConfirmOpen = true);
    _playYardConfirmOverlayEnter();
    return completer.future;
  }

  void _cancelRandomTicketUseConfirmPending() {
    final completer = _randomTicketUseConfirmCompleter;
    _randomTicketUseConfirmCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
  }

  Future<void> _resolveRandomTicketUseConfirm(bool confirmed) async {
    if (!_isRandomTicketUseConfirmOpen) return;
    final completer = _randomTicketUseConfirmCompleter;
    _randomTicketUseConfirmCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(confirmed);
    }
    await _dismissYardConfirmOverlayAnimated(
      () => _isRandomTicketUseConfirmOpen = false,
    );
  }

  void _closeRandomTicketUseConfirmOverlay() {
    if (!_isRandomTicketUseConfirmOpen) return;
    unawaited(_resolveRandomTicketUseConfirm(false));
  }

  /// 가방에서 랜덤 분양권을 실제로 사용해 새 베지펫을 분양받는다.
  ///
  /// 흐름:
  ///   1) 보유 수량 / activePet 상태 가드
  ///   2) `use_random_adoption_ticket` RPC 호출 → pet_species_id 획득
  ///   3) 도감 중복 방어 체크(pokedex_entries)
  ///   4) 졸업 완료된 기존 activePet 은 is_active=false 로만 비활성화
  ///      (is_resident / graduated_at 은 유지 → 마당 거주 펫으로 남음)
  ///   5) 새 user_pets insert (stage=baby, affection=0, is_active=true)
  ///   6) 상태 재조회 + setState
  ///   7) 기존 분양 직후와 동일한 _showNicknameDialog() 재사용
  Future<void> _useRandomAdoptionTicketFromBag() async {
    if (_isUsingRandomTicket) return;

    final user = supabase.auth.currentUser;
    final l10n = AppLocalizations.of(context);
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return;
    }
    if (_effectiveRandomTicketCountForBag() <= 0) {
      _showSnack(l10n.snackTicketEmpty);
      return;
    }

    // 현재 활성 펫이 아직 성숙기 졸업 처리가 끝나지 않은 상태라면 사용 불가.
    // 성숙기 + is_resident=true + graduated_at!=null 셋이 모두 갖춰진 경우에만
    // 새 펫을 분양받을 수 있다.
    final currentPet = _activePet;
    final isCurrentGraduated =
        currentPet != null &&
        currentPet['stage']?.toString() == 'adult' &&
        currentPet['is_resident'] == true &&
        currentPet['graduated_at'] != null;
    if (currentPet != null && !isCurrentGraduated) {
      _showSnack(l10n.snackTicketBlockedDuringGrowth);
      return;
    }

    setState(() => _isUsingRandomTicket = true);

    try {
      // 1) RPC 호출
      dynamic rpcResult;
      try {
        rpcResult = await supabase.rpc(
          'use_random_adoption_ticket',
          params: {'p_user_id': user.id},
        );
      } catch (e) {
        if (!mounted) return;
        _showSnack(l10n.snackTicketUseFailed(e.toString()));
        return;
      }

      Map<String, dynamic>? payload;
      if (rpcResult is Map) {
        payload = Map<String, dynamic>.from(rpcResult);
      } else if (rpcResult is List && rpcResult.isNotEmpty) {
        final first = rpcResult.first;
        if (first is Map) payload = Map<String, dynamic>.from(first);
      }

      final speciesIdRaw = payload?['pet_species_id'];
      final speciesId = speciesIdRaw is int
          ? speciesIdRaw
          : int.tryParse(speciesIdRaw?.toString() ?? '');
      if (speciesId == null) {
        if (!mounted) return;
        _showSnack(l10n.snackAdoptError);
        return;
      }

      // 2) Flutter 측 방어 체크 — 도감 중복 분양 차단
      try {
        final existingPokedex = await supabase
            .from('pokedex_entries')
            .select('id')
            .eq('user_id', user.id)
            .eq('pet_species_id', speciesId)
            .maybeSingle();
        if (existingPokedex != null) {
          if (!mounted) return;
          _showSnack(l10n.snackTicketDuplicatePokedex);
          // 분양권 수량은 RPC 단계에서 이미 차감됐을 수 있으므로 재조회만 해둔다.
          await _fetchRandomTicketCount();
          if (mounted) setState(() {});
          return;
        }
      } catch (e) {
        debugPrint('pokedex precheck failed: $e');
        // precheck 자체에 실패한 경우는 RPC 인터락이 살아있다고 가정하고 진행.
      }

      // 3) 졸업한 기존 펫은 is_active=false 로만 비활성화 (마당 거주 유지)
      if (isCurrentGraduated) {
        try {
          await supabase
              .from('user_pets')
              .update({'is_active': false})
              .eq('id', currentPet['id']);
        } catch (e) {
          if (!mounted) return;
          _showSnack(l10n.snackOldPetDeactivateFailed(e.toString()));
          return;
        }
      }

      // 4) 새 user_pets insert
      try {
        await supabase.from('user_pets').insert({
          'user_id': user.id,
          'pet_species_id': speciesId,
          'nickname': null,
          'stage': 'baby',
          'affection': 0,
          'is_active': true,
          'is_resident': false,
          'graduated_at': null,
        });
      } catch (e) {
        if (!mounted) return;
        _showSnack(l10n.snackNewPetAdoptSaveFailed(e.toString()));
        return;
      }

      // 5) 상태 재조회
      try {
        await Future.wait([
          _fetchActivePet(),
          _fetchResidentPets(),
          _fetchRandomTicketCount(),
          _fetchTodayMealLogs(),
        ]);
      } catch (e) {
        debugPrint('post-adopt refetch failed: $e');
      }

      if (!mounted) return;
      _safeSetState(() {});

      _showSnack(l10n.snackNewPetAdopted);

      // 성공 분기만: 게임메뉴 바깥 탭 가방 닫기와 동일하게 중앙 페이드 → 마당
      await _dismissBagPanelAfterTicketAdoptSuccessLikeBackdrop();
      if (!mounted) return;

      await _showNicknameDialog();
    } finally {
      if (mounted) {
        _safeSetState(() => _isUsingRandomTicket = false);
      } else {
        _isUsingRandomTicket = false;
      }
    }
  }

  // ScaffoldMessenger.of(context) 를 직접 사용하면 화면 전환과 setState 가 겹칠 때
  // dispose 타이밍 오류가 날 수 있다. 전역 scaffoldMessengerKey 를 통해
  // post frame 에 띄우고, 이전 SnackBar 가 쌓여 있으면 즉시 제거한다.
  void _showSnack(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = _rootScaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  // ----- 화면 전환 안정화용 helper -----

  void _dismissFocus() {
    _dismissKeyboardOnly();
  }

  bool _isKeyboardSessionActive(BuildContext context) {
    return MediaQuery.viewInsetsOf(context).bottom > 0 &&
        _activeKeyboardController != null;
  }

  bool _hasActiveTextInput() {
    if (_keyboardAccessoryFocusNode.hasFocus) return true;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || !focus.hasFocus) return false;
    final focusContext = focus.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<TextField>() != null ||
        focusContext.findAncestorWidgetOfExactType<TextFormField>() != null;
  }

  void _onEmailLinkControllerChangedForOtpSession() {
    if (!_emailLinkOtpSent) return;
    final cur = _emailLinkController.text.trim();
    if (cur != _emailLinkOtpSentForEmail.trim()) {
      _safeSetState(_clearEmailLinkOtpSession);
    }
  }

  void _dismissKeyboardOnly() {
    _keyboardAccessoryFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearActiveKeyboardInput() {
    _activeKeyboardInputKey = null;
    _activeKeyboardController = null;
    _activeKeyboardFocusNode = null;
  }

  /// 키보드 세션(상단 입력칸)이 활성일 때 키보드만 닫고 true.
  bool _dismissKeyboardIfVisibleOnly() {
    if (!_isKeyboardSessionActive(context)) return false;
    _dismissKeyboardOnly();
    _clearActiveKeyboardInput();
    if (mounted) {
      _safeSetState(() {});
    }
    return true;
  }

  void _dismissKeyboardSessionOnly() {
    _dismissKeyboardOnly();
    _clearActiveKeyboardInput();
    if (mounted) {
      _safeSetState(() {});
    }
  }

  void _registerActiveKeyboardInput({
    required String key,
    required TextEditingController controller,
    required FocusNode focusNode,
    TextInputType keyboardType = TextInputType.text,
  }) {
    _activeKeyboardInputKey = key;
    _activeKeyboardController = controller;
    _activeKeyboardFocusNode = focusNode;
    _activeKeyboardInputType = keyboardType;
    _safeSetState(() {});
  }

  void _clearActiveKeyboardInputIfNeeded(FocusNode focusNode) {
    if (_activeKeyboardFocusNode != focusNode) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return;
    if (_keyboardAccessoryFocusNode.hasFocus) return;
    _clearActiveKeyboardInput();
    _safeSetState(() {});
  }

  void _openKeyboardAccessoryForInput({
    required String key,
    required TextEditingController controller,
    required FocusNode sourceFocusNode,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter> inputFormatters = const [],
  }) {
    if (!mounted) return;
    _keyboardAccessoryFormattersByKey[key] = inputFormatters;
    final alreadyActive =
        _activeKeyboardController == controller &&
        _activeKeyboardInputKey == key &&
        _keyboardAccessoryFocusNode.hasFocus;
    _registerActiveKeyboardInput(
      key: key,
      controller: controller,
      focusNode: sourceFocusNode,
      keyboardType: keyboardType,
    );
    if (alreadyActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardAccessoryFocusNode.hasFocus) {
        _keyboardAccessoryFocusNode.requestFocus();
      }
    });
  }

  void _handleKeyboardAccessorySubmitted() {
    switch (_activeKeyboardInputKey) {
      case 'profile_nickname':
        _enforceProfileNicknameMaxLength();
        if (_isProfilePanelOpen) {
          unawaited(_submitGameMenuProfileNickname());
        }
        break;
      case 'pet_naming':
        unawaited(_submitPetNaming());
        return;
      default:
        break;
    }
    _dismissKeyboardSessionOnly();
  }

  void _ensureKeyboardFocusBinding({
    required String key,
    required TextEditingController controller,
    required FocusNode focusNode,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter> inputFormatters = const [],
    ValueChanged<String>? onChanged,
  }) {
    if (_keyboardBoundInputKeys.contains(key)) return;
    _keyboardBoundInputKeys.add(key);
    _keyboardAccessoryFormattersByKey[key] = inputFormatters;
    void onTextChanged() {
      if (!mounted) return;
      onChanged?.call(controller.text);
      if (_activeKeyboardController == controller) {
        _safeSetState(() {});
      }
    }

    controller.addListener(onTextChanged);
  }

  Widget _buildKeyboardAccessoryTriggerField({
    required String key,
    required TextEditingController controller,
    required FocusNode sourceFocusNode,
    required TextInputType keyboardType,
    List<TextInputFormatter> inputFormatters = const [],
    bool enabled = true,
    required TextStyle style,
    TextStyle? hintStyle,
    int maxLines = 1,
    String hintText = '',
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 10),
    Alignment alignment = Alignment.centerLeft,
    BoxDecoration? decoration,
    double? height,
  }) {
    final shellDecoration =
        decoration ??
        BoxDecoration(
          color: enabled
              ? Colors.white.withValues(alpha: 0.92)
              : const Color(0xFFEFEFEF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? const Color(0xFFE6E6E6)
                : const Color(0xFFDADADA),
            width: 1,
          ),
        );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled
            ? () {
                _openKeyboardAccessoryForInput(
                  key: key,
                  controller: controller,
                  sourceFocusNode: sourceFocusNode,
                  keyboardType: keyboardType,
                  inputFormatters: inputFormatters,
                );
              }
            : null,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          height: height,
          padding: padding,
          decoration: shellDecoration,
          child: Align(
            alignment: alignment,
            child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final text = value.text;
              final isEmpty = text.isEmpty;
              final displayText = isEmpty && hintText.isNotEmpty
                  ? hintText
                  : text;
              return Text(
                displayText,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: isEmpty && hintText.isNotEmpty
                    ? (hintStyle ?? style.copyWith(color: const Color(0xFFB0B0B0)))
                    : style,
              );
            },
            ),
          ),
        ),
      ),
    );
  }

  static const double _kKeyboardAccessoryHorizontalInset = 54;

  Widget _buildKeyboardDismissBarrier(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    if (bottomInset <= 0 || _activeKeyboardController == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      bottom: bottomInset + _kKeyboardAccessoryBarHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismissKeyboardSessionOnly,
        child: const ColoredBox(color: Colors.transparent),
      ),
    );
  }

  Widget _buildKeyboardAccessoryOverlay(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final controller = _activeKeyboardController;
    final inputKey = _activeKeyboardInputKey;
    if (bottomInset <= 0 || controller == null || inputKey == null) {
      return const SizedBox.shrink();
    }
    final isDietNote = inputKey == 'diet_note';
    final maxLines = isDietNote ? 2 : 1;
    final formatters =
        _keyboardAccessoryFormattersByKey[inputKey] ?? const <TextInputFormatter>[];
    const fieldStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.2,
    );

    return Positioned(
      left: _kKeyboardAccessoryHorizontalInset,
      right: _kKeyboardAccessoryHorizontalInset,
      bottom: bottomInset,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: Colors.transparent,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE6E6E6), width: 1),
            ),
            alignment: isDietNote ? Alignment.topLeft : Alignment.centerLeft,
            child: TextField(
              controller: controller,
              focusNode: _keyboardAccessoryFocusNode,
              keyboardType: _activeKeyboardInputType,
              enableInteractiveSelection: true,
              readOnly: false,
              autocorrect: false,
              enableSuggestions: false,
              maxLines: maxLines,
              minLines: 1,
              inputFormatters: formatters,
              style: fieldStyle,
              textAlignVertical: isDietNote
                  ? TextAlignVertical.top
                  : TextAlignVertical.center,
              scrollPadding: EdgeInsets.zero,
              textInputAction: isDietNote
                  ? TextInputAction.newline
                  : TextInputAction.done,
              onSubmitted: (_) => _handleKeyboardAccessorySubmitted(),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// BottomSheet/Dialog dispose 가 끝나고 다음 화면/시트가 안전하게 빌드되도록
  /// 한 frame 양보한다. async 직후 setState/route 전환과 겹쳐서 트리 정리
  /// 타이밍 오류가 나는 케이스를 줄이는 용도.
  Future<void> _waitForUiSettle() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  // --------------------------------------------------------------------------
  // VegePet 공통 확인창 (240×116 · Glassmorphism · 844×390 좌표계)
  // TODO(vegepet): 동일 양식의 1버튼(확인만) 알림창 — 필요 시 primary 전용 래퍼 추가.
  // --------------------------------------------------------------------------

  Widget _buildVegePetPastelRedGradientButtonText(
    String text, {
    double fontSize = 11,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFF6B6B), Color(0xFFFFD0D0)],
      ).createShader(bounds),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: Colors.white,
          height: 1.0,
        ),
      ),
    );
  }

  void _playYardConfirmOverlayEnter() {
    if (!mounted) return;
    _yardConfirmOverlayFadeController.stop();
    _yardConfirmOverlayFadeController.value = 0;
    unawaited(_yardConfirmOverlayFadeController.forward());
  }

  void _instantCloseYardConfirmOverlays() {
    _yardConfirmOverlayFadeController.stop();
    _yardConfirmOverlayFadeController.value = 0;
    _isShopNoticeOpen = false;
    _isWithdrawConfirmOpen = false;
    _isWithdrawFinalConfirmOpen = false;
    _isNameInterlockNoticeOpen = false;
    _isEmailLinkInviteNoticeOpen = false;
    _isEmailLinkSuccessNoticeOpen = false;
    _isEmailFormatErrorNoticeOpen = false;
    _isEmailDuplicateNoticeOpen = false;
    _isDuplicatePetNameNoticeOpen = false;
    if (_isRandomTicketUseConfirmOpen) {
      _cancelRandomTicketUseConfirmPending();
    }
    _isRandomTicketUseConfirmOpen = false;
  }

  bool _isYardConfirmOverlayFadeVisible(bool isOpen) {
    return isOpen;
  }

  Future<void> _dismissYardConfirmOverlayAnimated(
    void Function() setClosed,
  ) async {
    if (_yardConfirmOverlayFadeController.value <= 0) {
      if (mounted) {
        _safeSetState(setClosed);
      } else {
        setClosed();
      }
      return;
    }
    if (_yardConfirmOverlayFadeController.status == AnimationStatus.reverse) {
      return;
    }
    await _yardConfirmOverlayFadeController.reverse();
    if (!mounted) return;
    _safeSetState(setClosed);
  }

  void _closeShopNoticeOverlay() {
    if (!_isShopNoticeOpen) return;
    unawaited(
      _dismissYardConfirmOverlayAnimated(() => _isShopNoticeOpen = false),
    );
  }

  void _closeWithdrawConfirmOverlay() {
    if (!_isWithdrawConfirmOpen) return;
    unawaited(
      _dismissYardConfirmOverlayAnimated(() => _isWithdrawConfirmOpen = false),
    );
  }

  void _closeWithdrawFinalConfirmOverlay() {
    if (!_isWithdrawFinalConfirmOpen) return;
    unawaited(
      _dismissYardConfirmOverlayAnimated(
        () => _isWithdrawFinalConfirmOpen = false,
      ),
    );
  }

  void _openWithdrawFinalConfirmFromFirst() {
    _safeSetState(() {
      _isShopNoticeOpen = false;
      _isWithdrawConfirmOpen = false;
      _isWithdrawFinalConfirmOpen = true;
      _isNameInterlockNoticeOpen = false;
    });
    _yardConfirmOverlayFadeController.stop();
    _yardConfirmOverlayFadeController.value = 1;
  }

  Widget _buildVegePetYardConfirmOverlayFade({required Widget child}) {
    return AnimatedBuilder(
      animation: _yardConfirmOverlayFadeCurve,
      builder: (context, fadedChild) {
        return Opacity(
          opacity: _yardConfirmOverlayFadeCurve.value.clamp(0.0, 1.0),
          child: fadedChild,
        );
      },
      child: child,
    );
  }

  Widget _buildVegePetConfirmDialogShell({
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

  /// [primaryLabel] = A(하늘빛 그라데이션) → `true`, [secondaryLabel] = B(빨강 그라데이션) → `false`.
  /// [dimBarrier] 가 false 이면 배경 어둡게 처리 없음(분양권 확인 등).
  Future<bool> _showVegePetConfirmDialog({
    required String message,
    String? description,
    required String primaryLabel,
    required String secondaryLabel,
    bool barrierDismissible = true,
    bool dimBarrier = true,
  }) async {
    if (!mounted) return false;
    final desc = description?.trim();
    final hasDesc = desc != null && desc.isNotEmpty;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (dialogCtx) {
        final mq = MediaQuery.of(dialogCtx);
        final sw = mq.size.width;
        final sh = mq.size.height;
        final scale = min(sw / _kGameCanvasWidth, sh / _kGameCanvasHeight);
        final ox = (sw - _kGameCanvasWidth * scale) / 2;
        final oy = (sh - _kGameCanvasHeight * scale) / 2;
        final dlgLeft = ox + _kVegePetConfirmDialogLeft * scale;
        final dlgTop = oy + _kVegePetConfirmDialogTop * scale;
        final dlgW = _kVegePetConfirmDialogW * scale;
        final dlgH = _kVegePetConfirmDialogH * scale;

        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: SizedBox(
            width: sw,
            height: sh,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: barrierDismissible
                        ? () => Navigator.of(dialogCtx).pop(false)
                        : null,
                    child: ColoredBox(
                      color: dimBarrier
                          ? Colors.black.withValues(alpha: 0.30)
                          : Colors.transparent,
                    ),
                  ),
                ),
                Positioned(
                  left: dlgLeft,
                  top: dlgTop,
                  width: dlgW,
                  height: dlgH,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: FittedBox(
                      fit: BoxFit.fill,
                      child: SizedBox(
                        width: _kVegePetConfirmDialogW,
                        height: _kVegePetConfirmDialogH,
                        child: _buildVegePetConfirmDialogShell(
                          width: _kVegePetConfirmDialogW,
                          height: _kVegePetConfirmDialogH,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    16,
                                    16,
                                    0,
                                  ),
                                  child: SingleChildScrollView(
                                    physics: const BouncingScrollPhysics(),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          message,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF000000),
                                            height: 1.25,
                                          ),
                                        ),
                                        if (hasDesc) ...[
                                          const SizedBox(height: 5),
                                          Text(
                                            desc!,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF4A4A4A),
                                              height: 1.25,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Material(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(14),
                                        child: InkWell(
                                          onTap: () =>
                                              Navigator.of(dialogCtx).pop(true),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          child: Ink(
                                            height: 30,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: const Color(0xFFF1F1F1),
                                                width: 0.8,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.03),
                                                  blurRadius: 4,
                                                  offset: const Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child:
                                                  _buildPastelBlueGradientButtonText(
                                                    primaryLabel,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Material(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(14),
                                        child: InkWell(
                                          onTap: () => Navigator.of(
                                            dialogCtx,
                                          ).pop(false),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          child: Ink(
                                            height: 30,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: const Color(0xFFF1F1F1),
                                                width: 0.8,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.03),
                                                  blurRadius: 4,
                                                  offset: const Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child:
                                                  _buildVegePetPastelRedGradientButtonText(
                                                    secondaryLabel,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xFFEFF5EF),
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: _kGameCanvasWidth,
                  height: _kGameCanvasHeight,
                  child: _buildGameCanvas(),
                ),
              ),
            ),
          ),
          _buildKeyboardDismissBarrier(context),
          _buildKeyboardAccessoryOverlay(context),
        ],
      ),
    );
  }

  Widget _buildGameCanvas() {
    final profileComplete = _isProfileComplete();
    final hasActivePet = _activePet != null;
    final showProfileSetup = _status == _ViewStatus.ready && !profileComplete;
    final shouldMountProfileSetup = showProfileSetup || _isProfileSetupClosing;
    final showInitialAdoption =
        _status == _ViewStatus.ready && profileComplete && !hasActivePet;
    final shouldMountInitialAdoption =
        showInitialAdoption &&
        (_isInitialAdoptionPanelVisible || _isInitialAdoptionPanelClosing);
    final profileSelectOwnerActive =
        showProfileSetup ||
        _isProfilePanelOpen ||
        _profilePanelSwapInProgress ||
        _isSettingsPanelOpen ||
        _settingsPanelSwapInProgress;
    if (!profileSelectOwnerActive && _openProfileSelectKey != null) {
      unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    }
    if (showProfileSetup &&
        !_isProfileSetupClosing &&
        !_isProfileSetupPanelVisible &&
        !_isInitialAdoptionPanelVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final canShow =
            _status == _ViewStatus.ready &&
            !_isProfileComplete() &&
            !_isInitialAdoptionPanelVisible;
        if (!canShow || _isProfileSetupClosing) return;
        setState(() {
          _isProfileSetupPanelVisible = true;
        });
      });
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _buildYardBaseLayer(),
        _buildYardPetLayer(),
        _buildInYardDebugPanel(),
        _buildTopHudLayer(),
        if (_status == _ViewStatus.loading) _buildInYardLoadingOverlay(),
        if (_status == _ViewStatus.error)
          _buildInYardErrorOverlay(message: _errorMessage, onRetry: _bootstrap),
        if (shouldMountProfileSetup)
          _buildInYardProfileSetupPanel(visible: _isProfileSetupPanelVisible),
        if (shouldMountInitialAdoption) _buildInYardAdoptionPanel(),
        if (_isNamingDialogOpen || _isPetNamingPanelClosing)
          _buildInYardPetNamingPanel(),
        _buildBagItemDetailGlobalOverlay(),
        _buildPokedexMaturePetDetailGlobalOverlay(),
        _buildEmailLinkPanelGlobalOverlay(),
        _buildCustomerCenterPanelGlobalOverlay(),
        _buildShopNoticeGlobalOverlay(),
        _buildRandomTicketUseConfirmGlobalOverlay(),
        _buildWithdrawConfirmGlobalOverlay(),
        _buildWithdrawFinalConfirmGlobalOverlay(),
        _buildEmailLinkInviteNoticeGlobalOverlay(),
        _buildEmailLinkSuccessNoticeGlobalOverlay(),
        _buildEmailFormatErrorNoticeGlobalOverlay(),
        _buildEmailDuplicateNoticeGlobalOverlay(),
        _buildDuplicatePetNameNoticeGlobalOverlay(),
        _buildNameInterlockNoticeGlobalOverlay(),
      ],
    );
  }

  Widget _buildNameInterlockNoticeDialog() {
    final l10n = AppLocalizations.of(context);
    final isEn = _isEnglishLocale;
    return _buildVegePetConfirmDialogShell(
      width: _kVegePetConfirmDialogW,
      height: _kVegePetConfirmDialogH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.nameInterlockMain,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF000000),
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    l10n.nameInterlockSub,
                    textAlign: TextAlign.left,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: isEn ? 9 : 10,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFB92020),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: () => unawaited(_hideNameInterlockNotice()),
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
                    child: _buildPastelBlueGradientButtonText(
                      l10n.confirmLabel,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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

  Widget _buildNameInterlockNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isNameInterlockNoticeOpen)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => unawaited(_hideNameInterlockNotice()),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildNameInterlockNoticeDialog(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShopNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isShopNoticeOpen)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeShopNoticeOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildVegePetConfirmDialogShell(
                  width: _kVegePetConfirmDialogW,
                  height: _kVegePetConfirmDialogH,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.shopNoticeTitle,
                                textAlign: TextAlign.left,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF000000),
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                l10n.shopNoticeDescription,
                                textAlign: TextAlign.left,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF4A4A4A),
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            onTap: _closeShopNoticeOverlay,
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
                                child: _buildPastelBlueGradientButtonText(
                                  l10n.confirmLabel,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailLinkInviteNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isEmailLinkInviteNoticeOpen)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final isEn = _isEnglishLocale;

    final titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF000000),
      height: isEn ? 1.0 : 1.2,
    );
    final emailInviteTitleTop = isEn ? 15.0 : 16.0;
    final bodyStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: isEn ? 9 : 10,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF4A4A4A),
      height: 1.2,
    );

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: _buildVegePetConfirmDialogShell(
                width: _kVegePetConfirmDialogW,
                height: _kVegePetConfirmDialogH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: emailInviteTitleTop),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  l10n.emailLinkInviteTitle,
                                  textAlign: TextAlign.left,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle,
                                ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.emailLinkInviteBodyLine1,
                                    textAlign: TextAlign.left,
                                    maxLines: 2,
                                    overflow: TextOverflow.visible,
                                    style: bodyStyle,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    l10n.emailLinkInviteBodyLine2,
                                    textAlign: TextAlign.left,
                                    maxLines: 2,
                                    overflow: TextOverflow.visible,
                                    style: bodyStyle,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  onTap: () =>
                                      unawaited(_onEmailLinkInviteLinkTap()),
                                  borderRadius: BorderRadius.circular(14),
                                  child: Ink(
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFF1F1F1),
                                        width: 0.8,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.03,
                                          ),
                                          blurRadius: 4,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: _buildPastelBlueGradientButtonText(
                                        l10n.emailLinkInviteNow,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  onTap: _closeEmailLinkInviteNoticeOverlay,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Ink(
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFF1F1F1),
                                        width: 0.8,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.03,
                                          ),
                                          blurRadius: 4,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        l10n.emailLinkInviteLater,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFFB92020),
                                          height: 1.0,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailLinkSuccessNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isEmailLinkSuccessNoticeOpen)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: _buildVegePetConfirmDialogShell(
                width: _kVegePetConfirmDialogW,
                height: _kVegePetConfirmDialogH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.emailLinkSuccessTitle,
                              textAlign: TextAlign.left,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF000000),
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              l10n.emailLinkSuccessBody,
                              textAlign: TextAlign.left,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF4A4A4A),
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: _closeEmailLinkSuccessNoticeOverlay,
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
                              child: _buildPastelBlueGradientButtonText(
                                l10n.emailLinkSuccessConfirm,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailFormatErrorNoticeDialog() {
    final l10n = AppLocalizations.of(context);
    return _buildVegePetConfirmDialogShell(
      width: _kVegePetConfirmDialogW,
      height: _kVegePetConfirmDialogH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.emailFormatErrorTitle,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF000000),
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    l10n.emailFormatErrorBody,
                    textAlign: TextAlign.left,
                    softWrap: true,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB92020),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: _closeEmailFormatErrorNoticeOverlay,
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
                    child: _buildPastelBlueGradientButtonText(
                      l10n.emailFormatErrorConfirm,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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

  Widget _buildEmailFormatErrorNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isEmailFormatErrorNoticeOpen)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => unawaited(_hideEmailFormatErrorNotice()),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildEmailFormatErrorNoticeDialog(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailDuplicateNoticeDialog() {
    final l10n = AppLocalizations.of(context);
    return _buildVegePetConfirmDialogShell(
      width: _kVegePetConfirmDialogW,
      height: _kVegePetConfirmDialogH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.emailDuplicateNoticeTitle,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF000000),
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    l10n.emailDuplicateNoticeBody,
                    textAlign: TextAlign.left,
                    softWrap: true,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB92020),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: _closeEmailDuplicateNoticeOverlay,
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
                    child: _buildPastelBlueGradientButtonText(
                      l10n.emailDuplicateNoticeConfirm,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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

  Widget _buildEmailDuplicateNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isEmailDuplicateNoticeOpen)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeEmailDuplicateNoticeOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildEmailDuplicateNoticeDialog(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDuplicatePetNameNoticeDialog() {
    final l10n = AppLocalizations.of(context);
    return _buildVegePetConfirmDialogShell(
      width: _kVegePetConfirmDialogW,
      height: _kVegePetConfirmDialogH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.duplicatePetNameNoticeTitle,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF000000),
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    l10n.duplicatePetNameNoticeBody,
                    textAlign: TextAlign.left,
                    softWrap: true,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB92020),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: _closeDuplicatePetNameNoticeOverlay,
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
                    child: _buildPastelBlueGradientButtonText(
                      l10n.duplicatePetNameNoticeConfirm,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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

  Widget _buildDuplicatePetNameNoticeGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isDuplicatePetNameNoticeOpen)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeDuplicatePetNameNoticeOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildDuplicatePetNameNoticeDialog(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openWithdrawConfirmPanel() {
    _dismissFocus();
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    _safeSetState(() {
      _resetEmailLinkPanelOtpFlow();
      _isEmailLinkPanelOpen = false;
      _isCustomerCenterPanelOpen = false;
      _isShopNoticeOpen = false;
      _isNameInterlockNoticeOpen = false;
      _isEmailLinkInviteNoticeOpen = false;
      _isEmailLinkSuccessNoticeOpen = false;
      _isEmailFormatErrorNoticeOpen = false;
      _isEmailDuplicateNoticeOpen = false;
      _isDuplicatePetNameNoticeOpen = false;
      if (_isRandomTicketUseConfirmOpen) {
        _cancelRandomTicketUseConfirmPending();
      }
      _isRandomTicketUseConfirmOpen = false;
      _activeSettingsSupportDoc = null;
      _renderingSettingsSupportDoc = null;
      _settingsSupportDocSwapInProgress = false;
      _settingsSupportDocScrollbarReady = false;
      _isWithdrawFinalConfirmOpen = false;
      _isWithdrawConfirmOpen = true;
    });
    _playYardConfirmOverlayEnter();
  }

  Future<void> _onWithdrawFinalConfirmDeleteTap() async {
    if (_isDeletingAccount) return;
    _safeSetState(() => _isDeletingAccount = true);
    await _dismissYardConfirmOverlayAnimated(() {
      _isWithdrawFinalConfirmOpen = false;
      _isWithdrawConfirmOpen = false;
    });
    if (!mounted) return;
    try {
      await _withdrawAccount();
    } finally {
      if (mounted) {
        _safeSetState(() => _isDeletingAccount = false);
      } else {
        _isDeletingAccount = false;
      }
    }
  }

  Widget _buildRandomTicketUseConfirmGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isRandomTicketUseConfirmOpen)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeRandomTicketUseConfirmOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildRandomTicketUseConfirmDialog(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRandomTicketUseConfirmDialog() {
    final l10n = AppLocalizations.of(context);
    const titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.25,
    );
    const descStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.25,
    );

    return _buildVegePetConfirmDialogShell(
      width: _kVegePetConfirmDialogW,
      height: _kVegePetConfirmDialogH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.randomTicketUseConfirmMessage,
                      style: titleStyle,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      l10n.randomTicketUseConfirmDesc,
                      style: descStyle,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      onTap: () =>
                          unawaited(_resolveRandomTicketUseConfirm(true)),
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
                          child: _buildPastelBlueGradientButtonText(
                            l10n.useLabel,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      onTap: _closeRandomTicketUseConfirmOverlay,
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
                          child: _buildVegePetPastelRedGradientButtonText(
                            l10n.cancelLabel,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWithdrawConfirmGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isWithdrawConfirmOpen)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final isEn = _isEnglishLocale;

    const titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.2,
    );
    final descStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: isEn ? 9 : 10,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF4A4A4A),
      height: 1.2,
    );

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _isDeletingAccount ? null : _closeWithdrawConfirmOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildVegePetConfirmDialogShell(
                  width: _kVegePetConfirmDialogW,
                  height: _kVegePetConfirmDialogH,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    l10n.withdrawConfirmTitle,
                                    textAlign: TextAlign.left,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.withdrawConfirmDescription,
                                    textAlign: TextAlign.left,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: descStyle,
                                  ),
                                ],
                              ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                onTap: _isDeletingAccount
                                    ? null
                                    : _closeWithdrawConfirmOverlay,
                                borderRadius: BorderRadius.circular(14),
                                child: Ink(
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: const Color(0xFFF1F1F1),
                                      width: 0.8,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.03,
                                        ),
                                        blurRadius: 4,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: _buildPastelBlueGradientButtonText(
                                      l10n.cancelLabel,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                onTap: _isDeletingAccount
                                    ? null
                                    : _openWithdrawFinalConfirmFromFirst,
                                borderRadius: BorderRadius.circular(14),
                                child: Ink(
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: const Color(0xFFF1F1F1),
                                      width: 0.8,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.03,
                                        ),
                                        blurRadius: 4,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.center,
                                      child: Text(
                                        l10n.withdrawConfirmDeleteButton,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFFB92020),
                                          height: 1.0,
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
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildWithdrawFinalConfirmGlobalOverlay() {
    if (!_isYardConfirmOverlayFadeVisible(_isWithdrawFinalConfirmOpen)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final isEn = _isEnglishLocale;

    const titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.2,
    );
    final descStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: isEn ? 9 : 10,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF4A4A4A),
      height: 1.2,
    );

    return Positioned.fill(
      child: _buildVegePetYardConfirmOverlayFade(
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _isDeletingAccount
                    ? null
                    : _closeWithdrawFinalConfirmOverlay,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: _kVegePetConfirmDialogLeft,
              top: _kVegePetConfirmDialogTop,
              width: _kVegePetConfirmDialogW,
              height: _kVegePetConfirmDialogH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildVegePetConfirmDialogShell(
                  width: _kVegePetConfirmDialogW,
                  height: _kVegePetConfirmDialogH,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    l10n.withdrawFinalTitle,
                                    textAlign: TextAlign.left,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.withdrawFinalDescription,
                                    textAlign: TextAlign.left,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: descStyle,
                                  ),
                                ],
                              ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: _isDeletingAccount
                              ? null
                              : () {
                                  unawaited(_onWithdrawFinalConfirmDeleteTap());
                                },
                          borderRadius: BorderRadius.circular(14),
                          child: Ink(
                            height: 28,
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
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: Text(
                                  l10n.withdrawFinalDeleteButton,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFB92020),
                                    height: 1.0,
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
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// 도감 등록 완료 펫 상세(176×222): 가방 아이템 설명창과 동일 좌표·페이드·바깥 탭 dismiss.
  Widget _buildPokedexMaturePetDetailGlobalOverlay() {
    final entry = _pokedexPanelSelectedEntry;
    if (entry == null || !_isPokedexPanelOpen) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _gameMenuPanelController,
          _gamePokedexSwapController,
        ]),
        builder: (context, _) {
          final slide = _gameMenuPanelSlideLeft;
          final dexSwapT = _gamePokedexSwapCurve.value.clamp(0.0, 1.0);
          final showDexLayer =
              _isPokedexPanelOpen || _pokedexPanelSwapInProgress;
          final dexOpacity = showDexLayer ? dexSwapT : 0.0;
          final o = dexOpacity.clamp(0.0, 1.0);

          return Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: o < 0.05,
                  child: Opacity(
                    opacity: o,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _safeSetState(
                        () => _pokedexPanelSelectedEntry = null,
                      ),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: slide + _kBagItemDetailLeft,
                top: _kGameMenuPanelTop + _kBagItemDetailTop,
                width: _kBagItemDetailW,
                height: _kBagItemDetailH,
                child: IgnorePointer(
                  ignoring: o < 0.05,
                  child: Opacity(
                    opacity: o,
                    child: _buildPokedexMaturePetDetailGlassPanel(entry),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmailLinkPanelGlobalOverlay() {
    if (!_isEmailLinkPanelOpen) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_dismissKeyboardIfVisibleOnly()) return;
                _safeSetState(_closeEmailLinkPanel);
              },
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: _kEmailLinkPanelLeft,
            top: _kEmailLinkPanelTop,
            width: _kEmailLinkPanelW,
            height: _kEmailLinkPanelH,
            child: _buildEmailLinkGlassPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerCenterPanelGlobalOverlay() {
    if (!_isCustomerCenterPanelOpen) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_dismissKeyboardIfVisibleOnly()) return;
                _safeSetState(() => _isCustomerCenterPanelOpen = false);
              },
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: _kCustomerCenterPanelLeft,
            top: _kCustomerCenterPanelTop,
            width: _kCustomerCenterPanelW,
            height: _kCustomerCenterPanelH,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _buildCustomerCenterGlassPanel(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerCenterGlassPanel() {
    final l10n = AppLocalizations.of(context);
    const titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const labelStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.15,
    );
    const emailStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );

    Widget gradientIcon(IconData icon, {double size = 14}) {
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
        ).createShader(bounds),
        child: Icon(icon, size: size, color: Colors.white),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kCustomerCenterPanelW,
          height: _kCustomerCenterPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    l10n.supportCenter,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    onTap: () async {
                      await Clipboard.setData(
                        const ClipboardData(text: _kCustomerCenterEmail),
                      );
                      if (!mounted) return;
                      _showSnack(AppLocalizations.of(context).emailCopied);
                    },
                    borderRadius: BorderRadius.circular(16),
                    child: Ink(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
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
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          gradientIcon(Icons.copy_rounded),
                          const SizedBox(width: 4),
                          _buildPastelBlueGradientButtonText(
                            l10n.copyEmail,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16 + 13,
                left: 16,
                right: 16,
                bottom: 8 + 28,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '• ${l10n.contactAndFeedback}',
                        textAlign: TextAlign.left,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                    Container(
                      height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFEFEF),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _kCustomerCenterEmail,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: emailStyle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onEmailLinkPanelPrimaryTap() async {
    if (_emailLinkPanelSendBusy || _emailLinkPanelVerifyBusy) return;

    if (!_emailLinkOtpSent) {
      if (_isEmailOtpCooldownActive()) return;
      final raw = _emailLinkController.text.trim();
      final l10n = AppLocalizations.of(context);
      if (raw.isEmpty) {
        _showSnack(l10n.snackEmailRequired);
        return;
      }
      if (await _promptEmailFormatErrorIfNeeded(raw)) return;
      _safeSetState(() => _emailLinkPanelSendBusy = true);
      final ok = await _sendEmailLinkOtp(raw);
      if (!mounted) return;
      _safeSetState(() {
        _emailLinkPanelSendBusy = false;
        if (ok) {
          _markEmailLinkOtpSessionActive(raw);
        }
      });
      if (ok) {
        _startEmailOtpCooldown();
      }
    } else {
      final l10n = AppLocalizations.of(context);
      if (_hasEffectiveEmailLink()) {
        _showSnack(l10n.snackEmailAlreadyLinked);
        return;
      }
      final raw = _emailLinkController.text.trim();
      if (raw.isEmpty) {
        _showSnack(l10n.snackEmailRequired);
        return;
      }
      if (await _promptEmailFormatErrorIfNeeded(raw)) return;
      final code = _emailLinkOtpController.text.trim();
      if (code.isEmpty) {
        _showSnack(l10n.snackOtpRequired);
        return;
      }
      _safeSetState(() => _emailLinkPanelVerifyBusy = true);
      final ok = await _verifyEmailLinkOtp(email: raw, token: code);
      if (!mounted) return;
      _safeSetState(() => _emailLinkPanelVerifyBusy = false);
      if (ok) {
        if (!mounted) return;
        _dismissFocus();
        _safeSetState(() {
          _resetEmailLinkPanelOtpFlow();
          _isEmailLinkPanelOpen = false;
        });
        await _showEmailLinkSuccessNotice();
      }
    }
  }

  Future<void> _onEmailLinkPanelResendOtp() async {
    if (_emailLinkPanelResendBusy || _isEmailOtpCooldownActive()) return;
    final raw = _emailLinkController.text.trim();
    if (raw.isEmpty) {
      _showSnack(AppLocalizations.of(context).snackEmailRequired);
      return;
    }
    if (await _promptEmailFormatErrorIfNeeded(raw)) return;
    _safeSetState(() => _emailLinkPanelResendBusy = true);
    final ok = await _sendEmailLinkOtp(raw);
    if (!mounted) return;
    _safeSetState(() {
      _emailLinkPanelResendBusy = false;
      if (ok) {
        _markEmailLinkOtpSessionActive(raw);
      }
    });
    if (ok) {
      _startEmailOtpCooldown();
    }
  }

  Widget _buildEmailLinkGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final cooldownActive = _emailOtpCooldownSeconds > 0;
    final otpEnabled = _emailLinkOtpSent;
    final fieldTextStyle = _settingsPanelTextStyle(
      11,
      FontWeight.w600,
      const Color(0xFF4A4A4A),
      height: 1.1,
    );
    const labelStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.15,
    );

    Widget labeledSection({
      required String label,
      required Widget field,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: labelStyle,
              ),
            ),
            const SizedBox(height: 4),
            field,
          ],
        ),
      );
    }

    Widget shellTextField({
      required String key,
      required TextEditingController controller,
      required FocusNode focusNode,
      required bool enabled,
      required TextInputType keyboardType,
      required List<TextInputFormatter> formatters,
    }) {
      return _buildKeyboardAccessoryTriggerField(
        key: key,
        controller: controller,
        sourceFocusNode: focusNode,
        keyboardType: keyboardType,
        inputFormatters: formatters,
        enabled: enabled,
        style: fieldTextStyle,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      );
    }

    final primaryDisabled = !_emailLinkOtpSent
        ? (_emailLinkPanelSendBusy || cooldownActive)
        : _emailLinkPanelVerifyBusy;
    final primaryLabel = !_emailLinkOtpSent
        ? l10n.emailLinkSendOtpButton
        : l10n.emailLinkVerifyCompleteButton;
    final primaryBusy = !_emailLinkOtpSent
        ? _emailLinkPanelSendBusy
        : _emailLinkPanelVerifyBusy;
    final resendEnabled =
        _emailLinkOtpSent && !cooldownActive && !_emailLinkPanelResendBusy;
    const actionButtonDecoration = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.all(Radius.circular(18)),
      border: Border.fromBorderSide(
        BorderSide(color: Color(0xFFF1F1F1), width: 0.8),
      ),
      boxShadow: [
        BoxShadow(
          color: Color(0x08000000),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    );
    final middleSections = <Widget>[
      labeledSection(
        label: l10n.emailLinkEmailRowLabel,
        field: shellTextField(
          key: 'email_link',
          controller: _emailLinkController,
          focusNode: _emailLinkFocusNode,
          enabled: true,
          keyboardType: TextInputType.emailAddress,
          formatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9@.]')),
          ],
        ),
      ),
      labeledSection(
        label: l10n.emailLinkOtpRowLabel,
        field: shellTextField(
          key: 'email_link_otp',
          controller: _emailLinkOtpController,
          focusNode: _emailLinkOtpFocusNode,
          enabled: otpEnabled,
          keyboardType: TextInputType.number,
          formatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(8),
          ],
        ),
      ),
      if (cooldownActive && !_emailLinkOtpSent)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.emailOtpRetryAfterSeconds(_emailOtpCooldownSeconds),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _settingsPanelTextStyle(
              10,
              FontWeight.w600,
              const Color(0xFFB92020),
              height: 1.0,
            ),
          ),
        ),
      if (_emailLinkOtpSent)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: 22,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: (cooldownActive || _emailLinkPanelResendBusy)
                    ? null
                    : () => unawaited(_onEmailLinkPanelResendOtp()),
                borderRadius: BorderRadius.circular(18),
                child: Ink(
                  decoration: resendEnabled
                      ? actionButtonDecoration
                      : const BoxDecoration(color: Colors.transparent),
                  child: Center(
                    child: _emailLinkPanelResendBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF6B6B6B),
                            ),
                          )
                        : cooldownActive
                            ? Text(
                                l10n.emailOtpRetryAfterSeconds(
                                  _emailOtpCooldownSeconds,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _settingsPanelTextStyle(
                                  11,
                                  FontWeight.w600,
                                  const Color(0xFFB92020),
                                  height: 1.0,
                                ),
                              )
                            : _buildPastelBlueGradientButtonText(
                                l10n.emailLinkResendCodeButton,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: _kEmailLinkPanelW,
            height: _kEmailLinkPanelH,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      l10n.emailAccountLink,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _settingsPanelTextStyle(
                        13,
                        FontWeight.w600,
                        const Color(0xFF000000),
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  height: 28,
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      onTap: primaryDisabled
                          ? null
                          : () => unawaited(_onEmailLinkPanelPrimaryTap()),
                      borderRadius: BorderRadius.circular(18),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
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
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: primaryBusy ? 0.35 : 1,
                              child: _buildPastelBlueGradientButtonText(
                                primaryLabel,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (primaryBusy)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF6B6B6B),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 16 + 13,
                  left: 0,
                  right: 0,
                  bottom: 8 + 28,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: middleSections,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYardBaseLayer() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_dismissKeyboardIfVisibleOnly()) return;
          unawaited(_closeProfileSelectOverlay());
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFDAF3DD), Color(0xFFA9DEB0)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYardPetLayer() {
    if (_isNamingDialogOpen && !_canShowActivePetDuringNaming) {
      return const SizedBox.shrink();
    }
    if (_activePet == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: _buildCenterPetVisual(),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _buildResidentPetRow(),
          ),
        ],
      ),
    );
  }

  bool _isAnyGameMenuSubPanelOpenOrSwapping() {
    return _isProfilePanelOpen ||
        _profilePanelSwapInProgress ||
        _isDietDiaryPanelOpen ||
        _dietDiaryPanelSwapInProgress ||
        _isBagPanelOpen ||
        _bagPanelSwapInProgress ||
        _isPokedexPanelOpen ||
        _pokedexPanelSwapInProgress ||
        _isStoryPanelOpen ||
        _storyPanelSwapInProgress ||
        _isSettingsPanelOpen ||
        _settingsPanelSwapInProgress ||
        _settingsSupportDocSwapInProgress ||
        _activeSettingsSupportDoc != null ||
        _renderingSettingsSupportDoc != null ||
        _isHelpPanelOpen ||
        _helpPanelSwapInProgress;
  }

  bool _isAnyGameMenuSurfaceActiveOrTransitioning() {
    return _gameMenuPanelOpen ||
        _gameMenuPanelRetracting ||
        _isAnyGameMenuSubPanelOpenOrSwapping() ||
        _gameMenuSubOutsideDismissController.isAnimating ||
        _gameMenuSubOutsideDismissKind != _GameMenuSubOutsideDismissKind.none ||
        _gameProfileSwapController.isAnimating ||
        _gameDietDiarySwapController.isAnimating ||
        _gameBagSwapController.isAnimating ||
        _gamePokedexSwapController.isAnimating ||
        _gameStorySwapController.isAnimating ||
        _gameSettingsSwapController.isAnimating ||
        _gameHelpSwapController.isAnimating ||
        _isShopNoticeOpen ||
        _isRandomTicketUseConfirmOpen ||
        _isWithdrawConfirmOpen ||
        _isWithdrawFinalConfirmOpen ||
        _isEmailLinkInviteNoticeOpen ||
        _isEmailLinkSuccessNoticeOpen;
  }

  /// 우측 메뉴 아이콘: 패널이 닫히는 동안(슬라이드/마당 페이드) 배경에 유지.
  bool get _hidePetInfoHudIcon {
    if (_petChildPanelDismissingToYard) {
      return false;
    }
    return _isPetInfoBannerOpen ||
        _isToyMenuOpen ||
        _petToySwapInProgress ||
        _isMealPanelOpen ||
        _petMealSwapInProgress;
  }

  /// 좌측 베지펫 정보 아이콘과 동일: 패널이 닫히는 동안(슬라이드/마당 페이드) 아이콘은 배경에 유지.
  bool get _hideGameMenuHudIcon {
    if (_gameMenuSubOutsideDismissKind != _GameMenuSubOutsideDismissKind.none) {
      return false;
    }
    return _gameMenuPanelOpen ||
        _isAnyGameMenuSubPanelOpenOrSwapping() ||
        _isShopNoticeOpen ||
        _isRandomTicketUseConfirmOpen ||
        _isWithdrawConfirmOpen ||
        _isWithdrawFinalConfirmOpen ||
        _isEmailLinkInviteNoticeOpen ||
        _isEmailLinkSuccessNoticeOpen;
  }

  double get _gameMenuYardExitFadeMultiplier {
    if (_gameMenuSubOutsideDismissKind == _GameMenuSubOutsideDismissKind.none) {
      return 1.0;
    }
    return (1.0 - _gameMenuSubOutsideDismissCurve.value).clamp(0.0, 1.0);
  }

  bool get _gameMenuPanelAtSlideOpen {
    return _gameMenuPanelOpen || _isAnyGameMenuSubPanelOpenOrSwapping();
  }

  double get _gameMenuPanelSlideLeft {
    return _gameMenuPanelAtSlideOpen
        ? _kGameMenuPanelLeft
        : _kGameMenuPanelOffLeft;
  }

  bool get _shouldMountGameMenuSlidePanel {
    return _gameMenuPanelOpen ||
        _gameMenuPanelRetracting ||
        _gameMenuSubOutsideDismissKind != _GameMenuSubOutsideDismissKind.none;
  }

  double _gameMenuGridCrossfadeOpacity() {
    var opacity = 1.0;
    if (_isProfilePanelOpen || _profilePanelSwapInProgress) {
      opacity *= 1.0 - _gameProfileSwapCurve.value;
    }
    if (_isDietDiaryPanelOpen || _dietDiaryPanelSwapInProgress) {
      opacity *= 1.0 - _gameDietDiarySwapCurve.value;
    }
    if (_isBagPanelOpen || _bagPanelSwapInProgress) {
      opacity *= 1.0 - _gameBagSwapCurve.value;
    }
    if (_isPokedexPanelOpen || _pokedexPanelSwapInProgress) {
      opacity *= 1.0 - _gamePokedexSwapCurve.value;
    }
    if (_isSettingsPanelOpen || _settingsPanelSwapInProgress) {
      opacity *= 1.0 - _gameSettingsSwapCurve.value;
    }
    if (_isStoryPanelOpen || _storyPanelSwapInProgress) {
      opacity *= 1.0 - _gameStorySwapCurve.value;
    }
    if (_isHelpPanelOpen || _helpPanelSwapInProgress) {
      opacity *= 1.0 - _gameHelpSwapCurve.value;
    }
    return opacity.clamp(0.0, 1.0);
  }

  Widget _buildTopHudLayer() {
    final l10n = AppLocalizations.of(context);
    final hidePetInfoCornerIcon = _hidePetInfoHudIcon;
    final hideGameMenuHudIcon = _hideGameMenuHudIcon;
    final blockHudByInitialOnboarding = _isInitialOnboardingHudBlocked();
    final isPetInfoCornerTouchBlocked =
        hidePetInfoCornerIcon || blockHudByInitialOnboarding;
    final isGameMenuCornerTouchBlocked =
        hideGameMenuHudIcon || blockHudByInitialOnboarding;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isPetInfoBannerOpen,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: (_petToySwapInProgress || _petMealSwapInProgress)
                    ? null
                    : _closePetInfoBanner,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          _buildPetInfoSlideBanner(),
          Positioned(
            left: 40,
            top: 40,
            width: 64,
            height: 64,
            child: IgnorePointer(
              ignoring: isPetInfoCornerTouchBlocked,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                opacity: hidePetInfoCornerIcon ? 0 : 1,
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: _cornerIconButton(
                    icon: Icons.pets,
                    tooltip: l10n.petInfoTooltip,
                    iconSize: 28,
                    padding: 18,
                    onTap: _togglePetInfoBanner,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 740,
            top: 40,
            width: 64,
            height: 64,
            child: IgnorePointer(
              ignoring: isGameMenuCornerTouchBlocked,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                opacity: hideGameMenuHudIcon ? 0 : 1,
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: _cornerIconButton(
                    icon: Icons.apps_rounded,
                    tooltip: l10n.gameMenuTooltip,
                    iconSize: 28,
                    padding: 18,
                    onTap: _onGameMenuHudIconTap,
                    suppressInkSplash: _isPetInfoBannerOpen,
                  ),
                ),
              ),
            ),
          ),
          if (_isToyMenuOpen || _petToySwapInProgress)
            Positioned.fill(child: _buildToyDropTargetOverlay()),
          _buildToyMenuLayer(),
          _buildMealPanelLayer(),
          _buildGameMenuOverlayLayer(),
          _buildStoryPanelLayer(),
        ],
      ),
    );
  }

  /// 가방 아이템 설명창 오픈 시: 844×390 전역 터치로 설명만 닫음.
  /// 가방 패널과 동일한 페이드로 동기화(닫을 때 설명창이 함께 사라짐).
  Widget _buildBagItemDetailGlobalOverlay() {
    final detail = _bagPanelDetailItem;
    if (detail == null || !_isBagPanelOpen) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _gameMenuPanelController,
          _gameBagSwapController,
        ]),
        builder: (context, _) {
          final slide = _gameMenuPanelSlideLeft;
          final bagSwapT = _gameBagSwapCurve.value.clamp(0.0, 1.0);
          final showBagLayer = _isBagPanelOpen || _bagPanelSwapInProgress;
          final bagOpacity = showBagLayer ? bagSwapT : 0.0;
          final o = bagOpacity.clamp(0.0, 1.0);

          return Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: o < 0.05,
                  child: Opacity(
                    opacity: o,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          _safeSetState(() => _bagPanelDetailItem = null),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: slide + _kBagItemDetailLeft,
                top: _kGameMenuPanelTop + _kBagItemDetailTop,
                width: _kBagItemDetailW,
                height: _kBagItemDetailH,
                child: IgnorePointer(
                  ignoring: o < 0.05,
                  child: Opacity(
                    opacity: o,
                    child: _buildBagItemDetailGlassPanel(detail),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInYardLoadingOverlay() {
    final l10n = AppLocalizations.of(context);
    return _buildCenteredOverlayCard(
      width: 280,
      height: 140,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(l10n.inYardLoading),
        ],
      ),
    );
  }

  Widget _buildInYardErrorOverlay({
    required String? message,
    required VoidCallback onRetry,
  }) {
    final l10n = AppLocalizations.of(context);
    return _buildCenteredOverlayCard(
      width: 380,
      height: 220,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 44, color: Colors.redAccent),
          const SizedBox(height: 10),
          Text(
            l10n.inYardErrorTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retry),
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInYardProfileSetupPanel({required bool visible}) {
    return Positioned(
      left: 286,
      top: 83,
      width: 272,
      height: 224,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          opacity: visible ? 1 : 0,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            scale: visible ? 1 : 0.98,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBF5).withValues(alpha: 0.60),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFF6F0E6).withValues(alpha: 0.85),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.09),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    child: _buildProfileFormContent(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _petIconDataForNaming() {
    final species = _activePet?['pet_species'];
    final family = species is Map
        ? species['family']?.toString().toLowerCase().trim()
        : null;
    if (family != null && family.contains('dog')) return Icons.pets;
    if (family != null && family.contains('cat')) return Icons.cruelty_free;
    return Icons.pets;
  }

  Future<void> _closePetNamingPanel({required String? result}) async {
    if (_isPetNamingPanelClosing) return;
    _dismissFocus();
    _safeSetState(() => _isPetNamingPanelClosing = true);
    if (_petNamingPanelEnterController.value > 0) {
      await _petNamingPanelEnterController.reverse();
    }
    if (!mounted) return;
    _safeSetState(() {
      _isNamingDialogOpen = false;
      _canShowActivePetDuringNaming = false;
      _isPetNamingPanelClosing = false;
    });
    final completer = _petNamingCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  Future<void> _submitPetNaming() async {
    if (_isPetNamingPanelClosing || _isNameInterlockNoticeOpen) return;
    final text = _petNamingController.text.trim();
    final l10n = AppLocalizations.of(context);
    if (text.isEmpty) {
      _showSnack(l10n.petNamingEnterNameError);
      return;
    }
    if (!_isValidNicknameOrPetName(text)) {
      if (text.length < 2 || text.length > 8) {
        _showSnack(l10n.petNamingLengthError);
      } else {
        _showSnack(l10n.petNamingSpecialCharError);
      }
      return;
    }

    final duplicated = await _hasDuplicatePokedexPetName(text);
    if (!mounted) return;
    if (duplicated) {
      await _showDuplicatePetNameNotice();
      return;
    }

    await _closePetNamingPanel(result: text);
  }

  Widget _buildInYardPetNamingPanel() {
    final l10n = AppLocalizations.of(context);
    final titleStyle = TextStyle(
      fontSize: _isEnglishLocale ? 15 : 16,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF000000),
      height: 1.0,
    );
    const subtitleStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );
    const labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const fieldTextStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );
    const fieldHintStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
    );

    final panelInteractive =
        _isNamingDialogOpen && !_isPetNamingPanelClosing;

    return Positioned(
      left: _kPetNicknameDialogLeft,
      top: _kPetNicknameDialogTop,
      width: _kPetNicknameDialogW,
      height: _kPetNicknameDialogH,
      child: IgnorePointer(
        ignoring: !panelInteractive,
        child: AnimatedBuilder(
          animation: _petNamingPanelEnterCurve,
          builder: (context, child) {
            final t = _petNamingPanelEnterCurve.value.clamp(0.0, 1.0);
            return Opacity(
              opacity: t,
              child: Transform.scale(
                scale: 0.985 + (0.015 * t),
                child: child,
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBF5).withValues(alpha: 0.60),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFF6F0E6).withValues(alpha: 0.85),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 14,
                      top: 14,
                      right: 14,
                      child: Text(
                        l10n.petNamingTitle,
                        textAlign: TextAlign.left,
                        style: titleStyle,
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 40,
                      right: 14,
                      child: Text(
                        l10n.petNamingSubtitle,
                        textAlign: TextAlign.left,
                        style: subtitleStyle,
                      ),
                    ),
                    Positioned(
                      left: 112,
                      top: 60,
                      width: 48,
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: const Color(0xFFB8B8B8),
                            width: 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          _petIconDataForNaming(),
                          size: 24,
                          color: const Color(0xFF3A3A3A),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 120,
                      width: 244,
                      height: 26,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 36,
                            child: Text(
                              l10n.petInfoNameLabel,
                              textAlign: TextAlign.left,
                              style: labelStyle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Container(
                              height: 26,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFE6E6E6),
                                  width: 1,
                                ),
                              ),
                              alignment: Alignment.centerLeft,
                              child: _buildKeyboardAccessoryTriggerField(
                                key: 'pet_naming',
                                controller: _petNamingController,
                                sourceFocusNode: _petNamingFocusNode,
                                keyboardType: TextInputType.text,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(
                                    8,
                                    maxLengthEnforcement:
                                        MaxLengthEnforcement.enforced,
                                  ),
                                ],
                                style: fieldTextStyle,
                                hintStyle: fieldHintStyle,
                                hintText: l10n.petNamingHint,
                                height: 26,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(10),
                                  ),
                                  border: Border.fromBorderSide(
                                    BorderSide(
                                      color: Color(0xFFE6E6E6),
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 160,
                      width: 244,
                      height: 34,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
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
                        child: TextButton(
                          onPressed:
                              (_isPetNamingPanelClosing ||
                                  _isNameInterlockNoticeOpen)
                              ? null
                              : () {
                                  unawaited(_submitPetNaming());
                                },
                          style: TextButton.styleFrom(
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            backgroundColor: Colors.transparent,
                            disabledBackgroundColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          child: ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFFA9C9FF),
                                Color(0xFFBFD9FF),
                              ],
                            ).createShader(bounds),
                            blendMode: BlendMode.srcIn,
                            child: Text(
                              l10n.petNamingSave,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFAFCFFF),
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInYardInitialAdoptionPanel() {
    final visible = _isInitialAdoptionPanelVisible;
    final panelChild = ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBF5).withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFF6F0E6).withValues(alpha: 0.85),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: _buildInitialAdoptionPanelContent(),
          ),
        ),
      ),
    );

    // 등장: visible=true 와 동시에 즉시 표시(페이드 인 생략). 퇴장만 AnimatedOpacity 유지.
    final Widget panelBody;
    if (_isInitialAdoptionPanelClosing || !visible) {
      panelBody = AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        opacity: visible ? 1 : 0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          scale: visible ? 1 : 0.98,
          child: panelChild,
        ),
      );
    } else {
      panelBody = panelChild;
    }

    return Positioned(
      left: _kInitialAdoptionPanelLeft,
      top: _kInitialAdoptionPanelTop,
      width: _kInitialAdoptionPanelWidth,
      height: _kInitialAdoptionPanelHeight,
      child: IgnorePointer(
        ignoring: !visible && !_isInitialAdoptionPanelClosing,
        child: panelBody,
      ),
    );
  }

  List<Map<String, dynamic>> _initialAdoptionSpeciesByFamily(
    List<String> familyHints,
  ) {
    final hints = familyHints.map((e) => e.toLowerCase()).toList();
    final filtered = _petSpecies.where((species) {
      final family = species['family']?.toString().toLowerCase().trim() ?? '';
      if (family.isEmpty) return false;
      return hints.any(family.contains);
    }).toList();
    return filtered.take(3).toList();
  }

  Widget _buildInitialAdoptionSpeciesCell({
    required Map<String, dynamic>? species,
    required bool isDogFamily,
  }) {
    if (species == null) return const SizedBox(width: 76);
    final id = species['id']?.toString();
    final localizedSpeciesName = _localizedPetSpeciesNameFromRaw(
      nameKo: species['name_ko']?.toString(),
      family: species['family']?.toString(),
      code: species['code']?.toString(),
    );
    final speciesName = localizedSpeciesName.trim().isNotEmpty
        ? localizedSpeciesName
        : species['code']?.toString().trim().isNotEmpty == true
        ? species['code']?.toString().trim() ?? '-'
        : '-';
    final isSelected = id != null && id == _selectedSpeciesId;
    final iconData = isDogFamily ? Icons.pets : Icons.cruelty_free;
    final backgroundColor = isDogFamily
        ? const Color(0xFFE8F2FF)
        : const Color(0xFFF4ECFF);

    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: id == null
            ? null
            : () {
                _safeSetState(() {
                  _selectedSpeciesId = isSelected ? null : id;
                });
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              scale: isSelected ? 1.03 : 1,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFFDCEAFF) : backgroundColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFFA9C9FF)
                        : const Color(0xFFE6E6E6),
                    width: isSelected ? 1.4 : 1,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: const Color(
                              0xFFA9C9FF,
                            ).withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: Icon(iconData, size: 28, color: const Color(0xFF3A3A3A)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              speciesName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4A4A4A),
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInitialAdoptionSpeciesRow({
    required List<Map<String, dynamic>> species,
    required bool isDogFamily,
  }) {
    return SizedBox(
      height: 70,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ...List<Widget>.generate(3, (index) {
            final item = index < species.length ? species[index] : null;
            return _buildInitialAdoptionSpeciesCell(
              species: item,
              isDogFamily: isDogFamily,
            );
          }),
        ],
      ),
    );
  }

  Widget _buildInitialAdoptionReceiveButton() {
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: TextButton(
          onPressed: (_isAdopting || _selectedSpeciesId == null)
              ? null
              : _adoptSelectedPet,
          style: TextButton.styleFrom(
            elevation: 0,
            shadowColor: Colors.transparent,
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            padding: EdgeInsets.zero,
          ),
          child: _isAdopting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFA8C9FF),
                  ),
                )
              : ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
                  ).createShader(bounds),
                  blendMode: BlendMode.srcIn,
                  child: Text(
                    AppLocalizations.of(context).adoptionReceiveButtonExclaim,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _isEnglishLocale ? 14 : 16,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFAFCFFF),
                      height: 1.15,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildInitialAdoptionPanelContent() {
    final l10n = AppLocalizations.of(context);
    final dogSpecies = _initialAdoptionSpeciesByFamily(['dog', '강아지', '댕']);
    final catSpecies = _initialAdoptionSpeciesByFamily(['cat', '고양이', '냥']);
    final titleText = _isEnglishLocale
        ? l10n.initialAdoptionTitle
        : l10n.adoptionTitleAlt;
    const titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: Color(0xFF000000),
      height: 1.0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(titleText, textAlign: TextAlign.left, style: titleStyle),
        const SizedBox(height: 12),
        _buildInitialAdoptionSpeciesRow(species: dogSpecies, isDogFamily: true),
        const SizedBox(height: 10),
        _buildInitialAdoptionSpeciesRow(
          species: catSpecies,
          isDogFamily: false,
        ),
        const Spacer(),
        _buildInitialAdoptionReceiveButton(),
      ],
    );
  }

  Widget _buildInYardAdoptionPanel() {
    return _buildInYardInitialAdoptionPanel();
  }

  Widget _buildInYardDebugPanel() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: _status != _ViewStatus.ready,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_isDebugPanelOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _safeSetState(() => _isDebugPanelOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.14)),
                ),
              ),
            if (_isDebugPanelOpen)
              Positioned(
                left: 96,
                top: 40,
                width: 700,
                height: 310,
                child: _buildDebugFloatingWindow(),
              ),
            Positioned(
              left: 40,
              top: 114,
              width: 48,
              height: 48,
              child: _buildDebugFloatingButton(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugFloatingButton() {
    final theme = Theme.of(context);
    return Tooltip(
      message: '개발 확인용 디버그',
      child: Material(
        color: Colors.white.withValues(alpha: 0.95),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () =>
              _safeSetState(() => _isDebugPanelOpen = !_isDebugPanelOpen),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(
                Icons.bug_report_outlined,
                size: 24,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDebugFloatingWindow() {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      elevation: 6,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBF5).withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: const Color(0xFFF0EBE3).withValues(alpha: 0.95),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 4, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '개발 확인용 디버그',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '닫기',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close,
                      size: 22,
                      color: theme.colorScheme.onSurface,
                    ),
                    onPressed: () =>
                        _safeSetState(() => _isDebugPanelOpen = false),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 14, right: 14, bottom: 6),
              child: Text(
                '앱 사용자에게는 보이지 않을 영역',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                child: _buildDebugSection(
                  useOuterCard: false,
                  hideExpansionHeader: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlayPanel({
    required double width,
    required double height,
    required Widget child,
    double? left,
    double? top,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  Widget _buildCenteredOverlayCard({
    required double width,
    required double height,
    required Widget child,
  }) {
    return Center(
      child: _buildOverlayPanel(
        width: width,
        height: height,
        left: (_kGameCanvasWidth - width) / 2,
        top: (_kGameCanvasHeight - height) / 2,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Future<void> _openPetInfoBannerClosingGameMenu() async {
    if (_isProfilePanelOpen) {
      final canClose = await _saveProfilePanelIfDirtyBeforeClose();
      if (!canClose) return;
    }
    if (!mounted) return;
    _safeSetState(() {
      _isPetInfoBannerOpen = true;
      _gameMenuPanelOpen = false;
      _gameMenuPanelRetracting = true;
      _resetGameProfilePanelStateForMenuClose();
    });
    unawaited(_finishGameMenuPanelRetract());
  }

  void _togglePetInfoBanner() {
    if (_activePet == null || _isInteracting) return;
    if (_isToyMenuOpen ||
        _petToySwapInProgress ||
        _isMealPanelOpen ||
        _petMealSwapInProgress) {
      return;
    }

    final opening = !_isPetInfoBannerOpen;

    // 게임 메뉴 열림 ↔ 베지펫 정보창 상호 배타: 펫창을 켤 때 메뉴는 즉시 닫고 슬라이드 아웃과 동시 진행.
    if (opening &&
        (_gameMenuPanelOpen ||
            _gameMenuPanelRetracting ||
            _isAnyGameMenuSubPanelOpenOrSwapping())) {
      unawaited(_openPetInfoBannerClosingGameMenu());
      return;
    }

    _safeSetState(() {
      _isPetInfoBannerOpen = !_isPetInfoBannerOpen;
    });
  }

  void _closePetInfoBanner() {
    if (!_isPetInfoBannerOpen) return;
    _safeSetState(() {
      _isPetInfoBannerOpen = false;
    });
  }

  /// 베지펫 정보창이 열려 있으면 메뉴는 열지 않고 정보창만 닫는다(ripple 없음).
  void _onGameMenuHudIconTap() {
    if (_isPetInfoBannerOpen) {
      _closePetInfoBanner();
      return;
    }
    unawaited(_openMenuSheet());
  }

  String? _validateToyPlayEligibility() {
    final l10n = AppLocalizations.of(context);
    if (_activePet == null) return l10n.snackAdoptFirst;
    final today = _todayDateStr();
    if (_activePet!['last_played_on']?.toString() == today) {
      return l10n.snackPlayedToday;
    }
    final family = _activePetFamily();
    if (family != 'dog' && family != 'cat') {
      return l10n.snackPetActionInvalid;
    }
    return null;
  }

  Future<void> _onPetInfoBannerAction(String action) async {
    if (action == 'play') {
      final err = _validateToyPlayEligibility();
      if (err != null) {
        _showSnack(err);
        return;
      }
      await _openToyPlaySheet(fromPetBanner: true);
      return;
    }
    if (action == 'meal') {
      await _openMealSheet(fromPetBanner: true);
      return;
    }

    _closePetInfoBanner();
    await _waitForUiSettle();
    if (!mounted) return;

    if (action == 'pet') {
      await _interactPet('pet');
    }
  }

  Widget _buildPetInfoSlideBanner() {
    const panelW = 246.0;
    const panelH = 310.0;
    const openLeft = 40.0;
    final closedLeft = -panelW - 12;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _petToySwapController,
        _petMealSwapController,
      ]),
      builder: (context, _) {
        final showToySwap = _petToySwapInProgress && _toyOpenedFromPetBanner;
        final showMealSwap = _petMealSwapInProgress && _mealOpenedFromPetBanner;
        final tToy = _petToySwapCurve.value;
        final tMeal = _petMealSwapCurve.value;
        final t = showToySwap ? tToy : (showMealSwap ? tMeal : 0.0);

        final showPetInSwap = showToySwap || showMealSwap;
        final slideOutOpen = _isPetInfoBannerOpen && _activePet != null;
        final atOpen = slideOutOpen || showPetInSwap;
        final targetLeft = atOpen ? openLeft : closedLeft;

        final Widget inner;
        if (showPetInSwap) {
          inner = Opacity(
            opacity: (1.0 - t).clamp(0.0, 1.0),
            child: _buildPetInfoBannerContent(),
          );
        } else {
          inner = AnimatedOpacity(
            duration: _kYardSidePanelSlideDuration,
            curve: _kYardSidePanelSlideCurve,
            opacity: slideOutOpen ? 1 : 0,
            child: _buildPetInfoBannerContent(),
          );
        }

        return AnimatedPositioned(
          duration: showPetInSwap
              ? Duration.zero
              : _kYardSidePanelSlideDuration,
          curve: _kYardSidePanelSlideCurve,
          left: targetLeft,
          top: 40,
          width: panelW,
          height: panelH,
          child: IgnorePointer(
            ignoring:
                _petToySwapInProgress ||
                _petMealSwapInProgress ||
                !slideOutOpen,
            child: inner,
          ),
        );
      },
    );
  }

  String _petInfoMealButtonShortLabel() {
    return AppLocalizations.of(context).petInfoFeedShort;
  }

  Widget _buildPetInfoBannerContent() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final pet = _activePet;
    if (pet == null) return const SizedBox.shrink();

    final species = _speciesForPet(pet) ?? <String, dynamic>{};
    final family = species['family']?.toString().toLowerCase() ?? '';
    final speciesNameKo = species['name_ko']?.toString() ?? '펫';
    final typeDisplay = _localizedPetSpeciesNameFromRaw(
      nameKo: species['name_ko']?.toString(),
      family: species['family']?.toString(),
      code: species['code']?.toString(),
    );
    final nickname = pet['nickname']?.toString();
    final speciesDisplayName = _localizedPetSpeciesNameFromRaw(
      nameKo: species['name_ko']?.toString(),
      family: species['family']?.toString(),
      code: species['code']?.toString(),
    );
    final displayName = (nickname == null || nickname.isEmpty)
        ? (_isEnglishLocale && speciesDisplayName.isNotEmpty
              ? speciesDisplayName
              : speciesNameKo)
        : nickname;
    final stage = pet['stage']?.toString() ?? 'baby';
    final stageKo = _stageToKorean(stage);
    final affectionValue = (pet['affection'] as num?)?.toInt() ?? 0;
    final today = _todayDateStr();
    final playedToday = pet['last_played_on']?.toString() == today;
    final affectionInfo = _affectionProgressInfo(affectionValue, l10n);
    final petIcon = family.contains('cat')
        ? Icons.pets
        : Icons.cruelty_free_outlined;

    // 이름·종류·단계 행과 동일한 가로 기준 (단계 라벨 좌변 ~ 우측 정보창 우변).
    const petInfoPanelInnerW = 246.0;
    const petInfoMetaRowLeft = 14.0;
    const petInfoMetaRowRightInset = 18.0;
    const petInfoContentLeft = petInfoMetaRowLeft;
    const petInfoContentWidth =
        petInfoPanelInnerW - petInfoMetaRowLeft - petInfoMetaRowRightInset;

    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const valueStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );

    final isEn = _isEnglishLocale;

    Widget metaValueBox(String text, {bool scaleDownForEn = false}) {
      final textWidget = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: valueStyle.copyWith(fontSize: isEn && scaleDownForEn ? 10.5 : 12),
      );
      return Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.45),
            width: 0.8,
          ),
        ),
        child: isEn && scaleDownForEn
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: textWidget,
              )
            : textWidget,
      );
    }

    Widget pillButton({required String label, required VoidCallback? onTap}) {
      final disabled = onTap == null;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: disabled ? 0.45 : 1,
                  // 영어 "Feed" / "Play" 는 descender 가 있어 fontSize 13 으로
                  // 살짝 줄이면 클리핑 없이 1줄 표시된다. 한국어는 기존 14 유지.
                  child: _buildPastelBlueGradientButtonText(
                    label,
                    fontSize: isEn ? 13 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 246,
            height: 310,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: 14,
                  top: 14,
                  right: 14,
                  child: Text(
                    l10n.petInfoTitle,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF000000),
                      height: 1.0,
                    ),
                  ),
                ),
                // 더미 아이콘: 패널 상단 가로 중앙 (246-48)/2 = 99
                Positioned(
                  left: 99,
                  top: 37,
                  width: 48,
                  height: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFD8D8D8),
                        width: 0.8,
                      ),
                    ),
                    child: Icon(
                      petIcon,
                      size: 26,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                // 이름 / 종류 / 단계: 아이콘 아래 세로 정렬 (좌우 동일 여백 14 / 18)
                Positioned(
                  left: petInfoMetaRowLeft,
                  right: petInfoMetaRowRightInset,
                  top: 94,
                  height: 24,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 38,
                        child: Text(l10n.petInfoNameLabel, style: labelStyle),
                      ),
                      Expanded(child: metaValueBox(displayName)),
                    ],
                  ),
                ),
                Positioned(
                  left: petInfoMetaRowLeft,
                  right: petInfoMetaRowRightInset,
                  top: 122,
                  height: 24,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 38,
                        child: Text(
                          l10n.petInfoSpeciesLabel,
                          style: labelStyle,
                        ),
                      ),
                      Expanded(child: metaValueBox(typeDisplay, scaleDownForEn: true)),
                    ],
                  ),
                ),
                Positioned(
                  left: petInfoMetaRowLeft,
                  right: petInfoMetaRowRightInset,
                  top: 150,
                  height: 24,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 38,
                        child: Text(l10n.petInfoStageLabel, style: labelStyle),
                      ),
                      Expanded(child: metaValueBox(stageKo)),
                    ],
                  ),
                ),
                Positioned(
                  left: petInfoContentLeft,
                  top: 182,
                  width: petInfoContentWidth,
                  height: 10,
                  child: _buildPetInfoPanelAffectionBar(affectionInfo),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  top: 195,
                  child: Text(
                    '💕 ${affectionInfo.label}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A4A4A),
                      height: 1.15,
                    ),
                  ),
                ),
                // 먹이주기 / 놀아주기: 이름·종류·단계 행과 동일 가로 폭. 놀아주기 top = 310-14-34.
                Positioned(
                  left: petInfoContentLeft,
                  top: 217,
                  width: petInfoContentWidth,
                  height: 34,
                  child: pillButton(
                    label: _petInfoMealButtonShortLabel(),
                    onTap: _isInteracting
                        ? null
                        : () => _onPetInfoBannerAction('meal'),
                  ),
                ),
                Positioned(
                  left: 172,
                  top: 211,
                  child: IgnorePointer(child: _buildPetInfoDietBubble()),
                ),
                Positioned(
                  left: petInfoContentLeft,
                  top: 262,
                  width: petInfoContentWidth,
                  height: 34,
                  child: pillButton(
                    label: l10n.petInfoPlayAction,
                    onTap: (_isInteracting || playedToday)
                        ? null
                        : () => _onPetInfoBannerAction('play'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPetInfoDietBubble() {
    final l10n = AppLocalizations.of(context);
    final isEn = _isEnglishLocale;
    return SizedBox(
      width: 68,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          Container(
            width: 68,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: const Color(0xFFFFFFD0),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 0.6,
              ),
            ),
            // 영어 "Meal Check" 는 폭이 좁아 잘릴 수 있어 FittedBox 로 자동 축소.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  l10n.petInfoMealCheckBubble,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isEn ? 9.5 : 10,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF4A4A4A),
                    height: 1.1,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 2,
            bottom: -1,
            child: Transform.rotate(
              angle: -0.35,
              child: Container(
                width: 7,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFFD0),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPetInfoPanelAffectionBar(_AffectionProgressInfo info) {
    final p = info.progress.clamp(0.0, 1.0);
    return Container(
      height: 10,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.55),
          width: 0.8,
        ),
        color: Colors.white.withValues(alpha: 0.28),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: p,
            heightFactor: 1,
            alignment: Alignment.centerLeft,
            child: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFFFFD7FA)),
            ),
          ),
        ),
      ),
    );
  }

  // 마당에 함께 거주하는 성숙기 펫들을 가로로 작게 나열한다.
  // - activePet 과 같은 id 의 resident 는 중복 표시하지 않는다
  //   (activePet 이 아직 is_active=true 인 adult 단계에서는 중앙 비주얼로
  //    이미 보여지고 있기 때문)
  // - 표시 대상이 없으면 아무것도 그리지 않는다
  // - 너무 많아져도 화면이 깨지지 않도록 가로 스크롤 + 최대 6마리까지만 표시
  Widget _buildResidentPetRow() {
    final activeId = _activePet?['id']?.toString();
    final residents = _residentPets
        .where((p) => p['id']?.toString() != activeId)
        .toList();

    if (residents.isEmpty) return const SizedBox.shrink();

    final visible = residents.length > 6 ? residents.sublist(0, 6) : residents;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [for (final pet in visible) _buildResidentPetChip(pet)],
      ),
    );
  }

  // 거주 펫 한 마리를 표현하는 작은 칩.
  // 상호작용 대상이 아니라 "함께 사는 펫" 의 시각적 표현이라 클릭 핸들러는 없다.
  Widget _buildResidentPetChip(Map<String, dynamic> pet) {
    final theme = Theme.of(context);
    final species = pet['pet_species'] is Map
        ? Map<String, dynamic>.from(pet['pet_species'] as Map)
        : <String, dynamic>{};
    final family = species['family']?.toString() ?? '';
    final speciesName = species['name_ko']?.toString() ?? '펫';
    final nickname = pet['nickname']?.toString();
    final displayName = (nickname == null || nickname.isEmpty)
        ? speciesName
        : nickname;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Icon(
              family == 'cat' ? Icons.pets : Icons.cruelty_free_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            constraints: const BoxConstraints(maxWidth: 64),
            child: Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToyDropTargetOverlay() {
    return DragTarget<_BagItem>(
      onWillAcceptWithDetails: (details) {
        final item = details.data;
        return item.category == 'toy' &&
            item.targetPetFamily == _activePetFamily() &&
            !_isCompletingToyPlay;
      },
      onMove: (_) {
        if (!_isToyDropHovering) {
          _safeSetState(() => _isToyDropHovering = true);
        }
      },
      onLeave: (_) {
        if (_isToyDropHovering) {
          _safeSetState(() => _isToyDropHovering = false);
        }
      },
      onAcceptWithDetails: (details) {
        _completeToyMenuDrop(details.data);
      },
      builder: (context, candidateData, rejectedData) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => unawaited(_closePetChildPanelByOutsideTap()),
          child: const SizedBox.expand(
            child: ColoredBox(color: Colors.transparent),
          ),
        );
      },
    );
  }

  /// DRAG AND DROP 고정 레이아웃; 애니메이션은 부모 [Opacity]만 사용.
  Widget _buildDragAndDropHintFixedSize() {
    return SizedBox(
      width: 112,
      height: 44,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(
              3,
              (i) => Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 1),
                child: const Icon(
                  Icons.keyboard_double_arrow_right,
                  size: 14,
                  color: Color(0xFF4A4A4A),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'DRAG AND DROP',
            textAlign: TextAlign.left,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4A4A4A),
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  /// 844×390 마당 기준 (40,40) 놀아주기 패널 + 우측 DRAG AND DROP 힌트.
  Widget _buildToyMenuLayer() {
    final shouldMountToyUi = _isToyMenuOpen || _petToySwapInProgress;
    if (!shouldMountToyUi) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _petToySwapController,
        _dragHintPulseController,
      ]),
      builder: (context, _) {
        final t = _petToySwapCurve.value.clamp(0.0, 1.0);
        final effectiveT = _petToySwapInProgress ? t : 1.0;

        final toyChild = Opacity(
          opacity: effectiveT.clamp(0.0, 1.0),
          child: _buildToyPlayGlassPanel(),
        );

        final transitionOpacity = effectiveT.clamp(0.0, 1.0);

        /// 창 등장/퇴장 중에도 pulse가 계속 돌아가는 것처럼 보이도록 봉투(transitionOpacity) × pulse.
        final pulse = _dragHintOpacityAnim.value.clamp(0.0, 1.0);
        final hintOpacity = (transitionOpacity * pulse).clamp(0.0, 1.0);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 40,
              top: 40,
              width: 120,
              height: 310,
              child: toyChild,
            ),
            Positioned(
              left: 166,
              top: 37,
              width: 112,
              height: 310,
              child: IgnorePointer(
                child: Opacity(
                  opacity: hintOpacity.clamp(0.0, 1.0),
                  child: Align(
                    alignment: Alignment.center,
                    child: _buildDragAndDropHintFixedSize(),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 먹이주기(feed) 패널의 기본 높이 (한국어 기준). 영어 locale 에서는 문구가 길어
  /// 하단 안내가 잘릴 수 있어 +9px 만 늘리고 top 은 그대로 유지한다.
  static const double _kMealPanelBaseH = 212;
  double get _mealPanelHeight => _isEnglishLocale ? _kMealPanelBaseH + 9 : _kMealPanelBaseH;

  Widget _buildMealPanelFootnote(String text, bool isEn) {
    final style = TextStyle(
      fontSize: isEn ? 8 : 9,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF4A4A4A),
      height: 1.3,
    );
    if (isEn) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      );
    }
    return Text(text, style: style);
  }

  Widget _buildMealPanelLayer() {
    final shouldMount = _isMealPanelOpen || _petMealSwapInProgress;
    if (!shouldMount) {
      return const SizedBox.shrink();
    }

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => unawaited(_closePetChildPanelByOutsideTap()),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 40,
          top: 40,
          width: 246,
          height: _mealPanelHeight,
          child: AnimatedBuilder(
            animation: _petMealSwapController,
            builder: (context, _) {
              final t = _petMealSwapCurve.value.clamp(0.0, 1.0);
              final effectiveT = _petMealSwapInProgress ? t : 1.0;
              final o = effectiveT.clamp(0.0, 1.0);
              return Opacity(opacity: o, child: _buildMealGlassPanel());
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMealPanelSlotButton({
    required String label,
    required bool done,
    required bool uploading,
    required bool disabled,
    required VoidCallback onTap,
  }) {
    final l10n = AppLocalizations.of(context);
    if (done) {
      return Opacity(
        opacity: 0.6,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
          ),
          child: Center(
            child: Transform.translate(
              offset: const Offset(-13, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$label · ${l10n.petInfoStatusDone}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (uploading) {
      return Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.mealPanelUploading,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4A4A4A),
              ),
            ),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          height: 34,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Transform.translate(
                offset: const Offset(-13, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, 1),
                      child: const Icon(
                        Icons.camera_alt_outlined,
                        size: 18,
                        color: Color(0xFFA9C9FF),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildPastelBlueGradientButtonText(
                      label,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMealGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final brunchDone = _todayMealLogs.any((m) => m['meal_slot'] == 'brunch');
    final dinnerDone = _todayMealLogs.any((m) => m['meal_slot'] == 'dinner');
    final uploading = _isUploadingMeal;
    final uploadingBrunch = uploading && _uploadingSlot == 'brunch';
    final uploadingDinner = uploading && _uploadingSlot == 'dinner';
    final isEn = _isEnglishLocale;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: 246,
          height: _mealPanelHeight,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => unawaited(_cancelMealPanel()),
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
              Positioned(
                left: 37,
                top: 14,
                right: 8,
                child: Text(
                  l10n.mealPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                top: 42,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 1),
                      child: Text(
                        l10n.mealPanelTodayCertLabel,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF000000),
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildMealPanelSlotButton(
                      label: l10n.mealPanelBrunchButton,
                      done: brunchDone,
                      uploading: uploadingBrunch,
                      disabled: uploading,
                      onTap: () =>
                          unawaited(_uploadMealPhotoAndEvaluate('brunch')),
                    ),
                    const SizedBox(height: 9),
                    _buildMealPanelSlotButton(
                      label: l10n.mealPanelDinnerButton,
                      done: dinnerDone,
                      uploading: uploadingDinner,
                      disabled: uploading,
                      onTap: () =>
                          unawaited(_uploadMealPhotoAndEvaluate('dinner')),
                    ),
                    const Spacer(),
                    Transform.translate(
                      offset: const Offset(0, -2),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 1),
                        // 영어 문구는 길어 fontSize 8 로 줄이고 1줄 표시(scaleDown).
                        // 한국어는 기존 fontSize 9 / 자연스러운 줄바뀜 유지.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildMealPanelFootnote(l10n.mealPanelFootnote1, isEn),
                            const SizedBox(height: 4),
                            _buildMealPanelFootnote(l10n.mealPanelFootnote2, isEn),
                            const SizedBox(height: 4),
                            _buildMealPanelFootnote(l10n.mealPanelFootnote3, isEn),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToyPlayGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final activeFamily = _activePetFamily();
    final toys = _defaultToyBagItems();

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: 120,
          height: 310,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => unawaited(_cancelToyMenu()),
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
              Positioned(
                left: 37,
                top: 14,
                right: 8,
                child: Text(
                  l10n.petInfoPlayAction,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 48,
                bottom: 10,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < toys.length; i++) ...[
                          if (i > 0) const SizedBox(height: 18),
                          Center(
                            child: _buildToyMenuDraggableItem(
                              toys[i],
                              toys[i].targetPetFamily == activeFamily,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToyMenuDraggableItem(_BagItem toy, bool canUse) {
    final iconVisual = _buildToyMenuIconVisual(toy, canUse);
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconVisual,
        const SizedBox(height: 4),
        SizedBox(
          width: 112,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text(
              _localizedBagItemName(toy),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isEnglishLocale ? 10 : 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF4A4A4A),
                height: 1.15,
              ),
            ),
          ),
        ),
      ],
    );

    if (!canUse) {
      return Opacity(opacity: 0.35, child: IgnorePointer(child: child));
    }

    return LongPressDraggable<_BagItem>(
      data: toy,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        child: Transform.translate(
          offset: const Offset(0, -20),
          child: SizedBox(
            width: 48,
            height: 48,
            child: _buildToyMenuIconVisual(toy, true),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );
  }

  Widget _buildToyMenuIconVisual(_BagItem toy, bool canUse) {
    final theme = Theme.of(context);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: canUse
              ? theme.colorScheme.primary.withValues(alpha: 0.65)
              : theme.colorScheme.outlineVariant,
          width: 0.8,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        toy.icon,
        size: 26,
        color: canUse
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _cornerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double iconSize = 22,
    double padding = 10,
    bool suppressInkSplash = false,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        splashFactory: suppressInkSplash ? NoSplash.splashFactory : null,
        highlightColor:
            suppressInkSplash ? Colors.transparent : null,
        hoverColor: suppressInkSplash ? Colors.transparent : null,
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: iconSize, color: theme.colorScheme.primary),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterPetVisual() {
    final theme = Theme.of(context);
    final pet = _activePet!;
    final species = pet['pet_species'] is Map
        ? Map<String, dynamic>.from(pet['pet_species'] as Map)
        : <String, dynamic>{};
    final family = species['family']?.toString() ?? '';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_onYardPetTapped()),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          family == 'cat' ? Icons.pets : Icons.cruelty_free_outlined,
          size: 40,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  // 좌측 상단 펫정보 아이콘 버튼을 누르면 열리는 펫 상호작용 상태창.
  //
  // BottomSheet 내부에서는 어떤 액션이 선택됐는지만 String 으로 pop 해서 반환하고,
  // 실제 후속 동작(_openMealSheet / _interactPet)은 시트가 완전히 닫히고
  // 한 frame 양보된 뒤 HomePage 의 context 에서 실행한다. await 이후 sheetCtx 를
  // 사용하지 않으므로 dispose 타이밍 오류가 나지 않는다.
  // ignore: unused_element
  Future<void> _openPetStatusSheet() async {
    if (_activePet == null) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return _buildPetStatusSheetContent(
          onMeal: () => Navigator.of(sheetCtx).pop('meal'),
          onPlay: () => Navigator.of(sheetCtx).pop('play'),
          onPet: () => Navigator.of(sheetCtx).pop('pet'),
        );
      },
    );

    if (!mounted || action == null) return;

    await _waitForUiSettle();
    if (!mounted) return;

    switch (action) {
      case 'meal':
        await _openMealSheet();
        break;
      case 'play':
        await _openToyPlaySheet();
        break;
      case 'pet':
        await _interactPet('pet');
        break;
    }
  }

  Future<void> _openToyPlaySheet({bool fromPetBanner = false}) async {
    final err = _validateToyPlayEligibility();
    if (err != null) {
      _showSnack(err);
      return;
    }

    await _waitForUiSettle();
    if (!mounted) return;

    final openedFromPetBanner = fromPetBanner && _isPetInfoBannerOpen;

    _petToySwapController.value = 0;
    _safeSetState(() {
      _petToySwapInProgress = true;
      _isToyMenuOpen = true;
      _toyOpenedFromPetBanner = openedFromPetBanner;
      _isToyDropHovering = false;
    });

    await _petToySwapController.forward(from: 0.0);
    if (!mounted) return;

    _safeSetState(() {
      _isPetInfoBannerOpen = false;
      _petToySwapInProgress = false;
    });
  }

  Future<void> _completeToyMenuDrop(_BagItem toy) async {
    if (_isCompletingToyPlay) return;

    final l10n = AppLocalizations.of(context);
    final family = _activePetFamily();
    if (toy.targetPetFamily != family) {
      _showSnack(l10n.snackToyNotUsable);
      return;
    }

    final today = _todayDateStr();
    if (_activePet?['last_played_on']?.toString() == today) {
      _closeToyMenuInstant();
      _showSnack(l10n.snackPlayedTodayAlready);
      return;
    }

    _petToySwapController.value = 0;
    _safeSetState(() {
      _isCompletingToyPlay = true;
      _isToyMenuOpen = false;
      _isToyDropHovering = false;
      _petToySwapInProgress = false;
      _toyOpenedFromPetBanner = false;
    });

    try {
      await _interactPet('play');
    } finally {
      if (mounted) {
        _safeSetState(() => _isCompletingToyPlay = false);
      }
    }
  }

  void _closeToyMenuInstant() {
    if (!mounted) return;
    _petToySwapController.value = 0;
    _safeSetState(() {
      _isToyMenuOpen = false;
      _isToyDropHovering = false;
      _isCompletingToyPlay = false;
      _petToySwapInProgress = false;
      _toyOpenedFromPetBanner = false;
    });
  }

  Future<void> _cancelToyMenu() async {
    if (_petToySwapInProgress) return;
    if (!_isToyMenuOpen) return;

    _petToySwapController.value = 1.0;
    _safeSetState(() {
      _petToySwapInProgress = true;
      _isToyDropHovering = false;
    });

    await _petToySwapController.reverse(from: 1.0);
    if (!mounted) return;

    final reopenPet = _toyOpenedFromPetBanner;
    _safeSetState(() {
      _isToyMenuOpen = false;
      _isCompletingToyPlay = false;
      if (reopenPet) {
        _isPetInfoBannerOpen = true;
      }
      _petToySwapInProgress = false;
      _toyOpenedFromPetBanner = false;
    });
  }

  Widget _buildPetStatusSheetContent({
    required VoidCallback onMeal,
    required VoidCallback onPlay,
    required VoidCallback onPet,
  }) {
    final theme = Theme.of(context);
    final pet = _activePet!;
    final species = pet['pet_species'] is Map
        ? Map<String, dynamic>.from(pet['pet_species'] as Map)
        : <String, dynamic>{};

    final family = species['family']?.toString() ?? '';
    final familyKo = _familyToKorean(family);
    final speciesName = species['name_ko']?.toString() ?? '펫';
    final nickname = pet['nickname']?.toString();
    final displayName = (nickname == null || nickname.isEmpty)
        ? speciesName
        : nickname;
    final stage = pet['stage']?.toString() ?? 'baby';
    final stageKo = _stageToKorean(stage);
    final affectionValue = (pet['affection'] as num?)?.toInt() ?? 0;

    final today = _todayDateStr();
    final playedToday = pet['last_played_on']?.toString() == today;
    final pettedToday = pet['last_petted_on']?.toString() == today;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    family == 'cat' ? Icons.pets : Icons.cruelty_free_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '$familyKo · $speciesName',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 성장 단계 칩만 단독으로 유지하고, 애정도는 아래 경험치 바 카드로 통합 표현.
            // 칩 한 개만 가로 전체에 두면 너무 길어 보이므로 왼쪽 정렬 영역을 한정한다.
            Row(
              children: [
                Expanded(
                  child: _sheetStatChip(
                    Icons.child_care_outlined,
                    '성장 단계',
                    stageKo,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
            const SizedBox(height: 12),
            _buildAffectionProgressCard(affectionValue),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _sheetActionTile(
                    label: '먹이주기',
                    icon: Icons.restaurant,
                    onTap: _isInteracting ? null : onMeal,
                    subtitle: Text(
                      '아점 : 06시 ~ 14시\n저녁 : 17시 ~ 22시',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onPrimaryContainer.withValues(
                          alpha: 0.75,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _sheetActionTile(
                    label: '놀아주기',
                    icon: Icons.toys_outlined,
                    onTap: (_isInteracting || playedToday) ? null : onPlay,
                    loading: _isInteracting,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _sheetActionTile(
                    label: '쓰다듬기',
                    icon: Icons.back_hand_outlined,
                    onTap: (_isInteracting || pettedToday) ? null : onPet,
                    loading: _isInteracting,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _interactionStatusChip('놀아주기', playedToday),
                const SizedBox(width: 8),
                _interactionStatusChip('쓰다듬기', pettedToday),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _interactionStatusChip(String label, bool doneToday) {
    final l10n = AppLocalizations.of(context);
    final color = doneToday ? Colors.orange : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: ${doneToday ? l10n.petInfoStatusDone : l10n.petInfoStatusAvailable}',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // 애정도를 게임 경험치 바처럼 표현하는 카드.
  //
  // - 상단: LinearProgressIndicator (현재 단계 진행도)
  // - 중단: "성장기까지 19/40" 같은 다음 단계 라벨 (adult 일 때는 "성숙기 달성 완료")
  // - 하단: "현재 애정도 49" 작은 보조 텍스트
  //
  // 계산 자체는 [_affectionProgressInfo] 가 책임지고, 여기서는 시각화만 한다.
  Widget _buildAffectionProgressCard(int affection) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final info = _affectionProgressInfo(affection, l10n);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: info.progress.clamp(0.0, 1.0),
              minHeight: 12,
              backgroundColor: Colors.white,
              valueColor: AlwaysStoppedAnimation<Color>(
                info.isComplete ? Colors.amber : theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                info.isComplete
                    ? Icons.emoji_events_outlined
                    : Icons.favorite_outline,
                size: 16,
                color: info.isComplete
                    ? Colors.amber[800]
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  info.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${l10n.petInfoCurrentAffection} $affection',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // 애정도 → 다음 성장 단계까지의 진행도 정보로 변환.
  //
  // 성장 단계 기준 (다른 곳에서도 참조하는 _stageFromAffection 과 동일):
  //   baby:  0  ~ 29   → 다음 "유년기" 까지 (max 30)
  //   child: 30 ~ 69   → 다음 "성장기" 까지 (max 40)
  //   grown: 70 ~ 109  → 다음 "성숙기" 까지 (max 40)
  //   adult: 110 ~     → 더 이상 성장 단계 없음 (육성 완료)
  _AffectionProgressInfo _affectionProgressInfo(
    int affection,
    AppLocalizations l10n,
  ) {
    if (affection >= 110) {
      return _AffectionProgressInfo(
        current: 40,
        max: 40,
        progress: 1,
        label: l10n.petInfoStageComplete,
        isComplete: true,
      );
    }
    if (affection >= 70) {
      const max = 40;
      final raw = affection - 70;
      final current = raw < 0 ? 0 : (raw > max ? max : raw);
      return _AffectionProgressInfo(
        current: current,
        max: max,
        progress: current / max,
        label: '${l10n.petInfoUntilAdult} $current/$max',
        isComplete: false,
      );
    }
    if (affection >= 30) {
      const max = 40;
      final raw = affection - 30;
      final current = raw < 0 ? 0 : (raw > max ? max : raw);
      return _AffectionProgressInfo(
        current: current,
        max: max,
        progress: current / max,
        label: '${l10n.petInfoUntilGrown} $current/$max',
        isComplete: false,
      );
    }
    const max = 30;
    final raw = affection;
    final current = raw < 0 ? 0 : (raw > max ? max : raw);
    return _AffectionProgressInfo(
      current: current,
      max: max,
      progress: current / max,
      label: '${l10n.petInfoUntilChild} $current/$max',
      isComplete: false,
    );
  }

  Widget _sheetStatChip(IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetActionTile({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool loading = false,
    Widget? subtitle,
  }) {
    final theme = Theme.of(context);
    final disabled = onTap == null;

    return Opacity(
      opacity: disabled && !loading ? 0.5 : 1,
      child: Material(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                loading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      )
                    : Icon(
                        icon,
                        size: 22,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                if (subtitle != null) ...[const SizedBox(height: 4), subtitle],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 식단 사진 업로드 + AI 판정 실제 연결
  //
  // 전체 흐름:
  //   1) _pickMealPhoto               : image_picker로 실시간 카메라 촬영
  //   2) _uploadPhotoToStorage        : Supabase Storage `meal-photos` 업로드
  //   3) _invokeMealEvaluateFunction  : Supabase Edge Function `meal-evaluate` 호출
  //   4) 응답에서 result_type/feedback_text/affection_gain/next_affection 파싱
  //   5) _applyMealEvaluationResult   : meal_logs/active pet 재조회 + 감성 메시지 생성
  //
  // Flutter는 OpenAI를 직접 호출하지 않는다. 키는 Edge Function 환경변수에만 존재.
  // --------------------------------------------------------------------------

  /// 먹이주기 시트에서 "아점/저녁 식단 사진 올리기" 버튼을 눌렀을 때의 메인 엔트리.
  Future<void> _uploadMealPhotoAndEvaluate(String slot) async {
    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return;
    }
    if (_activePet == null) {
      _showSnack(l10n.snackAdoptFirst);
      return;
    }
    if (_isUploadingMeal) return;

    if (_todayMealLogs.any((m) => m['meal_slot'] == slot)) {
      _showSnack(l10n.snackMealAlreadyCertified);
      return;
    }

    // 첫 식단 성공 후 이메일 연동 팝업을 띄우기 위해 업로드 전에 상태를 미리 본다.
    bool wasFirstEver = false;
    try {
      final existing = await supabase
          .from('meal_logs')
          .select('id')
          .eq('user_id', user.id)
          .limit(1);
      wasFirstEver = (existing as List).isEmpty;
    } catch (_) {
      // 선제 조회가 실패해도 업로드 흐름 자체는 계속 진행한다.
      wasFirstEver = false;
    }

    setState(() {
      _isUploadingMeal = true;
      _uploadingSlot = slot;
    });

    try {
      // 1) 실시간 카메라 촬영 (사진첩 업로드는 허용하지 않는다)
      final photo = await _pickMealPhoto();
      if (photo == null) {
        if (!mounted) return;
        setState(() {
          _isUploadingMeal = false;
          _uploadingSlot = null;
        });
        return;
      }

      // 2) Supabase Storage 업로드
      final imagePath = await _uploadPhotoToStorage(slot: slot, file: photo);
      if (imagePath == null) {
        if (!mounted) return;
        setState(() {
          _isUploadingMeal = false;
          _uploadingSlot = null;
        });
        _showSnack(l10n.snackMealUploadFailed);
        return;
      }

      if (mounted) {
        setState(() {
          _lastImagePath = imagePath;
        });
      }

      // 3) Edge Function 호출
      final result = await _invokeMealEvaluateFunction(
        slot: slot,
        imagePath: imagePath,
      );
      if (result == null) {
        if (!mounted) return;
        setState(() {
          _isUploadingMeal = false;
          _uploadingSlot = null;
        });
        _showSnack(l10n.snackMealAiFailed);
        return;
      }

      // 4~5) 응답 반영 + meal_logs / active pet 재조회 + 상태메세지 생성
      await _applyMealEvaluationResult(result);

      if (!mounted) return;
      setState(() {
        _isUploadingMeal = false;
        _uploadingSlot = null;
      });

      // 첫 식단 성공 시(단, uncertain은 보통 meal_logs에 기록되지 않으므로 제외) 이메일 유도 팝업.
      final resultType = result['ok'] == true
          ? result['result_type']?.toString()
          : null;
      final wasLogged = resultType != null && resultType != 'uncertain';
      if (wasFirstEver && wasLogged) {
        await _maybeShowEmailLinkInviteAfterFirstMeal();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isUploadingMeal = false;
        _uploadingSlot = null;
      });
      _showSnack(l10n.snackMealUnknownError(e.toString()));
    }
  }

  Future<void> _lockLandscapeOrientation() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// 실시간 카메라로 식단 사진 1장을 촬영한다.
  /// 사진첩(갤러리) 선택은 허용하지 않는다.
  ///
  /// 앱은 [main]에서 이미 가로 고정이므로 카메라 열기 전 lock 은 하지 않는다.
  /// 네이티브 카메라 종료 후 [finally]에서 가로 lock 을 1회만 재적용해
  /// 중복 호출로 인한 추가 회전 애니메이션을 줄인다.
  Future<XFile?> _pickMealPhoto() async {
    XFile? xfile;
    try {
      final picker = ImagePicker();
      xfile = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 85,
        maxWidth: 1600,
      );
    } catch (e) {
      if (!mounted) return null;
      _showSnack(
        AppLocalizations.of(context).snackCameraUnavailable(e.toString()),
      );
      xfile = null;
    } finally {
      await _lockLandscapeOrientation();
    }

    return xfile;
  }

  /// 촬영한 사진을 Supabase Storage(`meal-photos`) 버킷에 업로드한다.
  ///
  /// 경로 규약: `{user.id}/{timestamp}_{slot}.jpg`
  /// 성공 시 업로드된 storage path 를 반환한다. 실패 시 null.
  Future<String?> _uploadPhotoToStorage({
    required String slot,
    required XFile file,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final imagePath = '${user.id}/${ts}_$slot.jpg';

    try {
      final bytes = await File(file.path).readAsBytes();
      await supabase.storage
          .from(_kMealPhotoBucket)
          .uploadBinary(
            imagePath,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: false,
            ),
          );
      return imagePath;
    } catch (e) {
      debugPrint('meal-photos upload failed: $e');
      return null;
    }
  }

  /// Supabase Edge Function `meal-evaluate` 를 호출한다.
  ///
  /// 요청 바디:
  /// ```json
  /// {
  ///   "slot": "brunch|dinner",
  ///   "imagePath": "<storage path>",
  ///   "locale_code": "ko|en"
  /// }
  /// ```
  ///
  /// 응답(성공 시) 예시:
  /// ```json
  /// {
  ///   "ok": true,
  ///   "meal_date": "2026-04-19",
  ///   "meal_slot": "brunch",
  ///   "result_type": "good|supplement_needed|bad|uncertain",
  ///   "feedback_text": "문자열 또는 null",
  ///   "affection_gain": 5,
  ///   "next_affection": 23
  /// }
  /// ```
  Future<Map<String, dynamic>?> _invokeMealEvaluateFunction({
    required String slot,
    required String imagePath,
  }) async {
    try {
      final res = await supabase.functions.invoke(
        _kMealEvaluateFunction,
        body: {
          'slot': slot,
          'imagePath': imagePath,
          'locale_code': _currentLocaleCodeForAi(),
        },
      );
      final data = res.data;
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      debugPrint('meal-evaluate unexpected response: $data');
      return null;
    } catch (e) {
      debugPrint('meal-evaluate invoke failed: $e');
      return null;
    }
  }

  /// Edge Function 응답을 UI에 반영한다.
  /// - meal_logs insert / user_pets.affection update 는 서버에서 처리됐다고 가정한다.
  /// - 여기서는 로컬 데이터를 재조회하고 감성 메시지만 만들어 보여준다.
  Future<void> _applyMealEvaluationResult(Map<String, dynamic> result) async {
    final ok = result['ok'] == true;
    final resultType = result['result_type']?.toString();
    final feedbackText = result['feedback_text']?.toString();
    final gain =
        (result['affection_gain'] as num?)?.toInt() ??
        _kMealAffectionGainByResult[resultType] ??
        0;

    final localeCode = _isEnglishLocale ? 'en' : 'ko';
    final statusMessage = ok
        ? _buildAiStatusMessage(
            resultType,
            feedbackText,
            localeCode: localeCode,
          )
        : (_isEnglishLocale
              ? "We couldn't load the meal result. Please try again later."
              : '판정 결과를 가져오지 못했어요. 잠시 후 다시 시도해주세요.');

    // 서버에서 affection 이 갱신되기 전의 단계를 기억해 둔다.
    final beforeStage = _activePet?['stage']?.toString();

    await Future.wait([_fetchTodayMealLogs(), _fetchActivePet()]);

    if (!mounted) return;
    setState(() {
      _lastResultType = resultType;
      _lastFeedbackText = feedbackText;
      _lastAffectionGain = gain;
      _lastStatusMessage = statusMessage;
    });

    _showSnack(statusMessage);

    // 서버(Edge Function)가 affection 만 올리고 stage 는 갱신하지 않을 수 있으므로,
    // 클라이언트에서 affection 기준으로 stage 를 동기화한다.
    if (ok && gain > 0) {
      await _syncStageAfterAffectionChange(beforeStage: beforeStage);
    }
  }

  Future<void> _openMealSheet({bool fromPetBanner = false}) async {
    if (_activePet == null) return;

    await _waitForUiSettle();
    if (!mounted) return;

    final openedFromPetBanner = fromPetBanner && _isPetInfoBannerOpen;

    _petMealSwapController.value = 0;
    _safeSetState(() {
      _petMealSwapInProgress = true;
      _isMealPanelOpen = true;
      _mealOpenedFromPetBanner = openedFromPetBanner;
    });

    await _petMealSwapController.forward(from: 0.0);
    if (!mounted) return;

    _safeSetState(() {
      _isPetInfoBannerOpen = false;
      _petMealSwapInProgress = false;
    });
  }

  Future<void> _cancelMealPanel() async {
    if (_petMealSwapInProgress) return;
    if (!_isMealPanelOpen) return;

    _petMealSwapController.value = 1.0;
    _safeSetState(() {
      _petMealSwapInProgress = true;
    });

    await _petMealSwapController.reverse(from: 1.0);
    if (!mounted) return;

    final reopenPet = _mealOpenedFromPetBanner;
    _safeSetState(() {
      _isMealPanelOpen = false;
      if (reopenPet) {
        _isPetInfoBannerOpen = true;
      }
      _petMealSwapInProgress = false;
      _mealOpenedFromPetBanner = false;
    });
  }

  /// 베지펫 정보창에서 연 놀아주기/먹이주기만 닫고 일반 마당으로 복귀한다.
  /// (뒤로가기 버튼의 정보창 복귀 경로와 구분)
  Future<void> _closePetChildPanelByOutsideTap() async {
    if (_petToySwapInProgress || _petMealSwapInProgress) return;
    if (_isCompletingToyPlay || _isUploadingMeal) return;

    final closingToy = _isToyMenuOpen;
    final closingMeal = _isMealPanelOpen;
    if (!closingToy && !closingMeal) return;

    if (_dismissKeyboardIfVisibleOnly()) return;
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);

    _safeSetState(() => _petChildPanelDismissingToYard = true);

    if (closingToy) {
      _petToySwapController.value = 1.0;
      _safeSetState(() {
        _petToySwapInProgress = true;
        _isToyDropHovering = false;
        _toyOpenedFromPetBanner = false;
        _isPetInfoBannerOpen = false;
      });

      await _petToySwapController.reverse(from: 1.0);
      if (!mounted) return;
      _safeSetState(() {
        _isToyMenuOpen = false;
        _isCompletingToyPlay = false;
        _petToySwapInProgress = false;
        _toyOpenedFromPetBanner = false;
        _isPetInfoBannerOpen = false;
        _petChildPanelDismissingToYard = false;
      });
    } else if (closingMeal) {
      _petMealSwapController.value = 1.0;
      _safeSetState(() {
        _petMealSwapInProgress = true;
        _mealOpenedFromPetBanner = false;
        _isPetInfoBannerOpen = false;
      });

      await _petMealSwapController.reverse(from: 1.0);
      if (!mounted) return;
      _safeSetState(() {
        _isMealPanelOpen = false;
        _petMealSwapInProgress = false;
        _mealOpenedFromPetBanner = false;
        _isPetInfoBannerOpen = false;
        _petChildPanelDismissingToYard = false;
      });
    } else if (mounted) {
      _safeSetState(() => _petChildPanelDismissingToYard = false);
    }
  }

  // --------------------------------------------------------------------------
  // 우측 상단 게임 메뉴 (844×390 기준 (558,40) · 246×310 글래스 패널, 슬라이드+페이드)
  // --------------------------------------------------------------------------

  Widget _buildGameMenuOverlayLayer() {
    final mountSubs = _isAnyGameMenuSubPanelOpenOrSwapping();
    final yardExitFade =
        _gameMenuSubOutsideDismissKind != _GameMenuSubOutsideDismissKind.none;
    if (!_shouldMountGameMenuSlidePanel && !mountSubs && !yardExitFade) {
      return const SizedBox.shrink();
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_handleGameMenuBackdropTap()),
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        if (_shouldMountGameMenuSlidePanel || mountSubs)
          _buildGameMenuPanelSlideHost(),
      ],
    );
  }

  /// [AnimatedPositioned]는 [Stack] 직계 자식이어야 슬라이드가 동작한다.
  Widget _buildGameMenuPanelSlideHost() {
    final yardExit = _gameMenuYardExitFadeMultiplier;
    final subSwapInProgress =
        _profilePanelSwapInProgress ||
        _dietDiaryPanelSwapInProgress ||
        _bagPanelSwapInProgress ||
        _pokedexPanelSwapInProgress ||
        _settingsPanelSwapInProgress ||
        _helpPanelSwapInProgress;
    final atSlideOpen = _gameMenuPanelAtSlideOpen;
    final targetLeft = yardExit < 0.999
        ? _kGameMenuPanelLeft
        : (atSlideOpen ? _kGameMenuPanelLeft : _kGameMenuPanelOffLeft);
    final slideDuration = subSwapInProgress
        ? Duration.zero
        : _kYardSidePanelSlideDuration;

    final slideMenuPanelOpen = _gameMenuPanelOpen;
    final panelShellOpen =
        slideMenuPanelOpen || _isAnyGameMenuSubPanelOpenOrSwapping();

    return AnimatedPositioned(
      duration: slideDuration,
      curve: _kYardSidePanelSlideCurve,
      left: targetLeft,
      top: _kGameMenuPanelTop,
      width: _kGameMenuPanelW,
      height: _kGameMenuPanelH,
      child: yardExit < 0.999
          ? _buildGameMenuPanelCrossfadeStack()
          : AnimatedOpacity(
              duration: slideDuration,
              curve: _kYardSidePanelSlideCurve,
              opacity: panelShellOpen ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !panelShellOpen,
                child: _buildGameMenuPanelCrossfadeStack(),
              ),
            ),
    );
  }

  Future<void> _finishGameMenuPanelRetract() async {
    await Future<void>.delayed(_kYardSidePanelSlideDuration);
    if (!mounted) return;
    _safeSetState(() {
      _gameMenuPanelRetracting = false;
      _gameMenuPanelController.value = 0;
    });
  }

  /// 메뉴 그리드 ↔ 하위 패널: 같은 좌표·같은 스택에서 동시 크로스페이드 (베지펫 정보창 ↔ 먹이·놀이).
  Widget _buildGameMenuPanelCrossfadeStack() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _gameProfileSwapController,
        _gameDietDiarySwapController,
        _gameBagSwapController,
        _gamePokedexSwapController,
        _gameStorySwapController,
        _gameSettingsSwapController,
        _gameHelpSwapController,
        _gameMenuSubOutsideDismissController,
      ]),
      builder: (context, _) {
        final yardExit = _gameMenuYardExitFadeMultiplier;
        final slideMenuOpen = _gameMenuPanelOpen;
        final anySubPanel = _isAnyGameMenuSubPanelOpenOrSwapping();
        final menuGridSlidingOut =
            _gameMenuPanelRetracting && !anySubPanel;

        final menuFade = _gameMenuGridCrossfadeOpacity();
        final showMenuGrid = slideMenuOpen || menuGridSlidingOut;
        final menuOpacity =
            (showMenuGrid ? (slideMenuOpen ? menuFade : 1.0) : 0.0) * yardExit;
        final profileOpacity =
            ((_isProfilePanelOpen || _profilePanelSwapInProgress)
                ? _gameProfileSwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;
        final dietOpacity =
            ((_isDietDiaryPanelOpen || _dietDiaryPanelSwapInProgress)
                ? _gameDietDiarySwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;
        final bagOpacity =
            ((_isBagPanelOpen || _bagPanelSwapInProgress)
                ? _gameBagSwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;
        final pokedexOpacity =
            ((_isPokedexPanelOpen || _pokedexPanelSwapInProgress)
                ? _gamePokedexSwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;
        final settingsOpacity =
            ((_isSettingsPanelOpen || _settingsPanelSwapInProgress)
                ? _gameSettingsSwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;
        final helpOpacity =
            ((_isHelpPanelOpen || _helpPanelSwapInProgress)
                ? _gameHelpSwapCurve.value.clamp(0.0, 1.0)
                : 0.0) *
            yardExit;

        return IgnorePointer(
          ignoring: !slideMenuOpen && !anySubPanel && !menuGridSlidingOut,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              if (menuOpacity > 0.01)
                IgnorePointer(
                  ignoring: menuOpacity < 0.05,
                  child: Opacity(
                    opacity: menuOpacity.clamp(0.0, 1.0),
                    child: _buildYardGameMenuGlassPanel(),
                  ),
                ),
              if (_isProfilePanelOpen || _profilePanelSwapInProgress)
                IgnorePointer(
                  ignoring: profileOpacity < 0.05,
                  child: Opacity(
                    opacity: profileOpacity,
                    child: _buildGameMenuProfileGlassPanel(),
                  ),
                ),
              if (_isDietDiaryPanelOpen || _dietDiaryPanelSwapInProgress)
                IgnorePointer(
                  ignoring: dietOpacity < 0.05,
                  child: Opacity(
                    opacity: dietOpacity,
                    child: _buildDietDiaryGameMenuGlassPanel(),
                  ),
                ),
              if (_isBagPanelOpen || _bagPanelSwapInProgress)
                IgnorePointer(
                  ignoring: bagOpacity < 0.05,
                  child: Opacity(
                    opacity: bagOpacity,
                    child: _buildBagGameMenuGlassPanel(),
                  ),
                ),
              if (_isPokedexPanelOpen || _pokedexPanelSwapInProgress)
                IgnorePointer(
                  ignoring: pokedexOpacity < 0.05,
                  child: Opacity(
                    opacity: pokedexOpacity,
                    child: _buildPokedexGameMenuGlassPanel(),
                  ),
                ),
              if (_isSettingsPanelOpen || _settingsPanelSwapInProgress)
                IgnorePointer(
                  ignoring: settingsOpacity < 0.05,
                  child: Opacity(
                    opacity: settingsOpacity,
                    child: _buildSettingsGameMenuGlassPanel(),
                  ),
                ),
              if (_isHelpPanelOpen || _helpPanelSwapInProgress)
                IgnorePointer(
                  ignoring: helpOpacity < 0.05,
                  child: Opacity(
                    opacity: helpOpacity,
                    child: _buildHelpGameMenuGlassPanel(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static const double _kGameMenuProfileFieldW = 172;
  static const double _kGameMenuProfileLabelW = 50;
  static const double _kGameMenuProfileRowGap = 4;

  Widget _buildGameMenuProfileAvatarDummy(String? gender) {
    final isFemale = gender == '여자';
    final isMale = gender == '남자';
    final IconData icon;
    if (isFemale) {
      icon = Icons.face_3_rounded;
    } else if (isMale) {
      icon = Icons.face_rounded;
    } else {
      icon = Icons.person_outline_rounded;
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
          width: 0.9,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 28, color: const Color(0xFF5C5C5C)),
    );
  }

  Widget _buildGameMenuProfileGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final genderForAvatar = _selectedGender ?? _profile?['gender']?.toString();
    final fieldsEnabled = !_isSavingProfile && !_isSavingProfilePanel;

    final isEn = _isEnglishLocale;
    Widget rowForWidth(
      double fieldW,
      String label,
      Widget field, {
      double? labelFontSize,
    }) {
      final useW = fieldW.clamp(100.0, _kGameMenuProfileFieldW);
      final resolvedLabelSize =
          labelFontSize ?? (isEn ? 10 : 11);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _kGameMenuProfileLabelW,
            // 영어 "Age Range" / "Diet Goal" 등은 길어서 ellipsis 가 발생.
            // 50px 라벨 폭은 유지하고 fontSize 만 영어에서 10 으로 줄여 1줄 표시.
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: resolvedLabelSize,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF000000),
                height: 1.15,
              ),
            ),
          ),
          const SizedBox(width: _kGameMenuProfileRowGap),
          SizedBox(width: useW, child: field),
        ],
      );
    }

    Widget fieldShell(Widget child) {
      return Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE6E6E6), width: 1),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => unawaited(_closeProfilePanelToGameMenu()),
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
              Positioned(
                left: 9,
                top: _gameMenuSubPanelTitleTop,
                right: 8,
                child: Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: Text(
                    l10n.profilePanelTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF000000),
                      height: 1.0,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 48,
                bottom: 8,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(9, 0, 8, 0),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: _buildGameMenuProfileAvatarDummy(
                            genderForAvatar,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final fieldW =
                                  constraints.maxWidth -
                                  _kGameMenuProfileLabelW -
                                  _kGameMenuProfileRowGap;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  rowForWidth(
                                    fieldW,
                                    l10n.nickname,
                                    fieldShell(
                                      _buildKeyboardAccessoryTriggerField(
                                        key: 'profile_nickname',
                                        controller: _nicknameController,
                                        sourceFocusNode: _nicknameFocusNode,
                                        enabled: fieldsEnabled,
                                        keyboardType: TextInputType.text,
                                        inputFormatters: [
                                          LengthLimitingTextInputFormatter(
                                            _kProfileNicknameMaxLength,
                                            maxLengthEnforcement:
                                                MaxLengthEnforcement.enforced,
                                          ),
                                        ],
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF4A4A4A),
                                          height: 1.1,
                                        ),
                                        maxLines: 1,
                                        padding: EdgeInsets.zero,
                                        decoration: const BoxDecoration(
                                          color: Colors.transparent,
                                        ),
                                      ),
                                    ),
                                    labelFontSize: isEn ? 9 : null,
                                  ),
                                  const SizedBox(height: 8),
                                  rowForWidth(
                                    fieldW,
                                    l10n.gender,
                                    _buildCompactProfileSelect(
                                      selectKey: 'gm_gender',
                                      value: _selectedGender,
                                      options: _genderOptions,
                                      enabled: fieldsEnabled,
                                      optionLabelBuilder: (v) =>
                                          _localizedGenderValue(v, l10n),
                                      fieldWidth: fieldW.clamp(
                                        100.0,
                                        _kGameMenuProfileFieldW,
                                      ),
                                      onChanged: (value) {
                                        setState(() => _selectedGender = value);
                                        unawaited(
                                          _persistGameMenuProfilePatch({
                                            'gender': value,
                                          }),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  rowForWidth(
                                    fieldW,
                                    l10n.ageRange,
                                    _buildCompactProfileSelect(
                                      selectKey: 'gm_ageRange',
                                      value: _selectedAgeRange,
                                      options: _ageRangeOptions,
                                      enabled: fieldsEnabled,
                                      optionLabelBuilder: (v) =>
                                          _localizedAgeRangeValue(v, l10n),
                                      fieldWidth: fieldW.clamp(
                                        100.0,
                                        _kGameMenuProfileFieldW,
                                      ),
                                      onChanged: (value) {
                                        setState(
                                          () => _selectedAgeRange = value,
                                        );
                                        unawaited(
                                          _persistGameMenuProfilePatch({
                                            'age_range': value,
                                          }),
                                        );
                                      },
                                    ),
                                    labelFontSize: isEn ? 8 : null,
                                  ),
                                  const SizedBox(height: 8),
                                  rowForWidth(
                                    fieldW,
                                    l10n.dietGoal,
                                    _buildCompactProfileSelect(
                                      selectKey: 'gm_dietGoal',
                                      value: _selectedDietGoal,
                                      options: _dietGoalOptions,
                                      enabled: fieldsEnabled,
                                      optionLabelBuilder: (v) =>
                                          _localizedDietGoalValue(v, l10n),
                                      fieldWidth: fieldW.clamp(
                                        100.0,
                                        _kGameMenuProfileFieldW,
                                      ),
                                      onChanged: (value) {
                                        setState(
                                          () => _selectedDietGoal = value,
                                        );
                                        unawaited(
                                          _persistGameMenuProfilePatch({
                                            'diet_goal': value,
                                          }),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    l10n.profilePanelFootnoteAi,
                                    softWrap: true,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF4A4A4A),
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.profileAutoSaveHint,
                                    softWrap: true,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF4A4A4A),
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildYardGameMenuGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final items = _menuSheetItems;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.gameMenuPanelTitle,
                  style: _yardGameMenuTitleTextStyle(),
                ),
                const SizedBox(height: _kYardGameMenuTitleBelowGap),
                const SizedBox(height: 4),
                SizedBox(
                  height: _kYardGameMenuRowCellH,
                  child: _yardGameMenuIconRow(items.sublist(0, 3)),
                ),
                const SizedBox(height: _kYardGameMenuRowGap),
                SizedBox(
                  height: _kYardGameMenuRowCellH,
                  child: _yardGameMenuIconRow(items.sublist(3, 6)),
                ),
                const SizedBox(height: _kYardGameMenuRowGap),
                SizedBox(
                  height: _kYardGameMenuRowCellH,
                  child: _yardGameMenuIconRowTwo(items.sublist(6, 8)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// TODO(vegepet): Pretendard 폰트 asset 등록 후 fontFamily 연결.
  TextStyle _yardGameMenuTitleTextStyle() {
    return const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: Color(0xFF000000),
      height: 1.0,
    );
  }

  Widget _yardGameMenuIconRow(List<(IconData, String)> rowItems) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final item in rowItems)
          Expanded(
            child: Center(
              child: _yardGameMenuItem(
                icon: item.$1,
                label: _menuLabelForKey(item.$2),
                onTap: () => unawaited(_onYardGameMenuItemTap(item.$2)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _yardGameMenuIconRowTwo(List<(IconData, String)> rowItems) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Center(
            child: _yardGameMenuItem(
              icon: rowItems[0].$1,
              label: _menuLabelForKey(rowItems[0].$2),
              onTap: () => unawaited(_onYardGameMenuItemTap(rowItems[0].$2)),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _yardGameMenuItem(
              icon: rowItems[1].$1,
              label: _menuLabelForKey(rowItems[1].$2),
              onTap: () => unawaited(_onYardGameMenuItemTap(rowItems[1].$2)),
            ),
          ),
        ),
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }

  /// 단일 메뉴 셀: 48×48 타일 + 라벨(고정 높이), 전체 `_kYardGameMenuRowCellH`.
  /// onTap 은 [_buildVegePetDummyIconInkWell] 로 **아이콘 사각형에만** 연결 (라벨/여백 비반응).
  Widget _yardGameMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: _kYardGameMenuItemW,
      height: _kYardGameMenuRowCellH,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _kYardGameMenuItemW,
            height: _kYardGameMenuIconTile,
            child: Center(
              child: Semantics(
                button: true,
                label: label,
                child: _buildVegePetDummyIconInkWell(
                  onTap: onTap,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFE5E5E5).withValues(alpha: 0.75),
                        width: 0.9,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 22, color: const Color(0xFF5C5C5C)),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: _kYardGameMenuIconLabelGap),
          SizedBox(
            height: _kYardGameMenuLabelAreaH,
            width: _kYardGameMenuItemW,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _isEnglishLocale ? 9.5 : 10,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF4A4A4A),
                  height: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onYardGameMenuItemTap(String key) async {
    if (key == 'profile') {
      await _openProfilePanelFromGameMenu();
      return;
    }
    if (key == 'dietDiary') {
      await _openDietDiaryFromGameMenu();
      return;
    }
    if (key == 'bag') {
      await _openBagPanelFromGameMenu();
      return;
    }
    if (key == 'pokedex') {
      await _openPokedexPanelFromGameMenu();
      return;
    }
    if (key == 'story') {
      await _openStoryPanelFromGameMenu();
      return;
    }
    if (key == 'settings') {
      await _openSettingsFromGameMenu();
      return;
    }
    if (key == 'help') {
      await _openHelpPanelFromGameMenu();
      return;
    }
    if (key == 'shop') {
      if (_isShopNoticeOpen) return;
      _isNameInterlockNoticeOpen = false;
      _safeSetState(() => _isShopNoticeOpen = true);
      _playYardConfirmOverlayEnter();
      return;
    }
    await _closeGameMenuPanel();
    if (!mounted) return;
    await _onMenuTap(_menuLabelForKey(key));
  }

  Future<void> _persistGameMenuProfilePatch(Map<String, dynamic> patch) async {
    if (_isSavingProfilePanel) return;
    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return;
    }
    _safeSetState(() => _isSavingProfilePanel = true);
    try {
      await supabase
          .from('profiles')
          .update({...patch, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', user.id);
      await _fetchProfile();
      if (!mounted) return;
      _syncProfileFormFromFetched();
      _safeSetState(() {});
    } catch (e) {
      if (!mounted) return;
      _showSnack(l10n.snackProfileSaveFailed(e.toString()));
      try {
        await _fetchProfile();
      } catch (_) {}
      if (mounted) {
        _syncProfileFormFromFetched();
        _safeSetState(() {});
      }
    } finally {
      if (mounted) {
        _safeSetState(() => _isSavingProfilePanel = false);
      }
    }
  }

  Future<void> _submitGameMenuProfileNickname() async {
    if (_isSavingProfilePanel || _isNameInterlockNoticeOpen) return;
    _enforceProfileNicknameMaxLength();
    final nickname = _nicknameController.text.trim();
    if (!_isValidNicknameOrPetName(nickname)) {
      await _showNameInterlockNotice();
      return;
    }
    await _persistGameMenuProfilePatch({'nickname': nickname});
  }

  void _captureProfilePanelInitialValues() {
    _profilePanelInitialNickname = _nicknameController.text.trim();
    _profilePanelInitialGender = _selectedGender;
    _profilePanelInitialAgeRange = _selectedAgeRange;
    _profilePanelInitialDietGoal = _selectedDietGoal;
  }

  bool _isProfilePanelDirty() {
    final nickname = _nicknameController.text.trim();
    return nickname != _profilePanelInitialNickname ||
        _selectedGender != _profilePanelInitialGender ||
        _selectedAgeRange != _profilePanelInitialAgeRange ||
        _selectedDietGoal != _profilePanelInitialDietGoal;
  }

  Future<bool> _saveProfilePanelIfDirtyBeforeClose() async {
    if (!_isProfilePanelDirty()) return true;
    if (_isSavingProfilePanel) return false;

    _dismissFocus();
    await _closeProfileSelectOverlay(animated: true);

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(AppLocalizations.of(context).snackLoginRequired);
      return false;
    }

    _enforceProfileNicknameMaxLength();
    final nickname = _nicknameController.text.trim();

    if (!_isValidNicknameOrPetName(nickname)) {
      await _showNameInterlockNotice();
      return false;
    }

    final l10n = AppLocalizations.of(context);
    if (_selectedGender == null) {
      _showSnack(l10n.snackSelectGender);
      return false;
    }
    if (_selectedAgeRange == null) {
      _showSnack(l10n.snackSelectAgeRange);
      return false;
    }
    if (_selectedDietGoal == null) {
      _showSnack(l10n.snackSelectDietGoal);
      return false;
    }

    _safeSetState(() => _isSavingProfilePanel = true);

    try {
      final nowIso = DateTime.now().toIso8601String();
      final profilePayload = <String, dynamic>{
        'id': user.id,
        'nickname': nickname,
        'gender': _selectedGender,
        'age_range': _selectedAgeRange,
        'diet_goal': _selectedDietGoal,
        'updated_at': nowIso,
      };

      final savedRows = await supabase
          .from('profiles')
          .upsert(profilePayload, onConflict: 'id')
          .select();

      Map<String, dynamic>? savedProfile;
      if (savedRows.isNotEmpty) {
        savedProfile = Map<String, dynamic>.from(savedRows.first);
      }

      _profile = {
        ...?_profile,
        ...profilePayload,
        if (savedProfile != null) ...savedProfile,
      };

      _captureProfilePanelInitialValues();

      if (mounted) {
        _safeSetState(() => _isSavingProfilePanel = false);
      } else {
        _isSavingProfilePanel = false;
      }

      return true;
    } catch (e, st) {
      debugPrint('profile panel autosave failed: $e\n$st');
      if (mounted) {
        _safeSetState(() => _isSavingProfilePanel = false);
        _showSnack(l10n.snackProfileSaveFailed(e.toString()));
      } else {
        _isSavingProfilePanel = false;
      }
      return false;
    }
  }

  Future<bool> _closeGameMenuProfilePanelForMenuSwitch() async {
    if (!_isProfilePanelOpen) return true;
    if (_profilePanelSwapInProgress) return false;
    final canClose = await _saveProfilePanelIfDirtyBeforeClose();
    if (!canClose) return false;
    _gameProfileSwapController.stop();
    _gameProfileSwapController.value = 0.0;
    _safeSetState(() {
      _isProfilePanelOpen = false;
      _profilePanelSwapInProgress = false;
      _profileOpenedFromGameMenu = false;
    });
    return true;
  }

  Future<void> _openProfilePanelFromGameMenu() async {
    if (_profilePanelSwapInProgress) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    final user = supabase.auth.currentUser;
    if (user == null || _profile == null) {
      _showSnack(AppLocalizations.of(context).snackProfileLoadFailed);
      return;
    }
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (_isDietDiaryPanelOpen) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (_isBagPanelOpen) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (_isPokedexPanelOpen) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    _syncProfileFormFromFetched();
    _captureProfilePanelInitialValues();
    _gameProfileSwapController.stop();
    _gameProfileSwapController.value = 0.0;
    _safeSetState(() {
      _profilePanelSwapInProgress = true;
      _profileOpenedFromGameMenu = true;
      _isProfilePanelOpen = true;
    });
    await _gameProfileSwapController.forward(from: 0.0);
    if (!mounted) return;
    _safeSetState(() {
      _profilePanelSwapInProgress = false;
    });
  }

  Future<void> _closeProfilePanelToGameMenu() async {
    if (_profilePanelSwapInProgress || _isSavingProfilePanel) return;
    final canClose = await _saveProfilePanelIfDirtyBeforeClose();
    if (!canClose) return;
    _dismissFocus();
    await _closeProfileSelectOverlay(animated: true);
    _gameProfileSwapController.value = 1.0;
    _safeSetState(() {
      _profilePanelSwapInProgress = true;
    });
    await _gameProfileSwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _profilePanelSwapInProgress = false;
      _isProfilePanelOpen = false;
      _profileOpenedFromGameMenu = false;
    });
  }

  void _resetGameProfilePanelStateForMenuClose() {
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    _gameProfileSwapController.stop();
    _gameProfileSwapController.value = 0;
    _isProfilePanelOpen = false;
    _profilePanelSwapInProgress = false;
    _profileOpenedFromGameMenu = false;
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0;
    _isDietDiaryPanelOpen = false;
    _dietDiaryPanelSwapInProgress = false;
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0;
    _isBagPanelOpen = false;
    _bagPanelSwapInProgress = false;
    _bagPanelDetailItem = null;
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0;
    _isPokedexPanelOpen = false;
    _pokedexPanelSwapInProgress = false;
    _pokedexPanelSelectedEntry = null;
    _gameSettingsSwapController.stop();
    _gameSettingsSwapController.value = 0;
    _isSettingsPanelOpen = false;
    _settingsPanelSwapInProgress = false;
    _gameHelpSwapController.stop();
    _gameHelpSwapController.value = 0;
    _isHelpPanelOpen = false;
    _helpPanelSwapInProgress = false;
    _isEmailLinkPanelOpen = false;
    _isCustomerCenterPanelOpen = false;
    _instantCloseYardConfirmOverlays();
    _isStoryPanelOpen = false;
    _storyPanelSwapInProgress = false;
    _activeSettingsSupportDoc = null;
    _renderingSettingsSupportDoc = null;
    _settingsSupportDocSwapInProgress = false;
    _settingsSupportDocScrollbarReady = false;
    _resetEmailLinkPanelOtpFlow();
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
  }

  void _instantResetSettingsPanelIfOpen() {
    _gameSettingsSwapController.stop();
    _gameSettingsSwapController.value = 0.0;
    if (!_isSettingsPanelOpen && !_settingsPanelSwapInProgress) return;
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    _resetSettingsPanelScrollOffset();
    _safeSetState(() {
      _isSettingsPanelOpen = false;
      _settingsPanelSwapInProgress = false;
      _isEmailLinkPanelOpen = false;
      _isCustomerCenterPanelOpen = false;
      _instantCloseYardConfirmOverlays();
      _activeSettingsSupportDoc = null;
      _renderingSettingsSupportDoc = null;
      _settingsSupportDocSwapInProgress = false;
      _settingsSupportDocScrollbarReady = false;
      _resetEmailLinkPanelOtpFlow();
    });
  }

  /// 게임 메뉴 **하위 기능창** 외부 탭: 슬라이드 없이 현재 화면을 그대로 두고 마당으로 페이드 아웃.
  Future<void> _dismissGameSubPanelWithCenterExit(
    _GameMenuSubOutsideDismissKind kind,
  ) async {
    if (!mounted) return;
    if (_gameMenuSubOutsideDismissController.isAnimating) return;
    if (kind == _GameMenuSubOutsideDismissKind.none) return;

    switch (kind) {
      case _GameMenuSubOutsideDismissKind.profile:
        if (_profilePanelSwapInProgress) return;
        if (_isProfilePanelOpen) {
          final canClose = await _saveProfilePanelIfDirtyBeforeClose();
          if (!canClose) return;
        }
      case _GameMenuSubOutsideDismissKind.dietDiary:
        if (_dietDiaryPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.bag:
        if (_bagPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.pokedex:
        if (_pokedexPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.story:
        if (_storyPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.settings:
        if (_settingsPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.help:
        if (_helpPanelSwapInProgress) return;
      case _GameMenuSubOutsideDismissKind.none:
        return;
    }

    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    if (!mounted) return;

    _safeSetState(() {
      _gameMenuSubOutsideDismissKind = kind;
      _gameMenuPanelOpen = false;
      _gameMenuPanelRetracting = false;
    });

    await _gameMenuSubOutsideDismissController.forward(from: 0.0);
    if (!mounted) return;

    _safeSetState(() {
      _resetGameProfilePanelStateForMenuClose();
      _gameMenuPanelOpen = false;
      _gameMenuPanelRetracting = false;
      _gameMenuPanelController.value = 0;
      _gameMenuSubOutsideDismissKind = _GameMenuSubOutsideDismissKind.none;
    });
    _gameMenuSubOutsideDismissController.value = 0.0;
  }

  /// 게임 메뉴 슬라이드 패널 전체를 닫는다. (베지펫 정보창 닫기와 동일: open=false → 우측 슬라이드)
  Future<void> _closeGameMenuPanel() async {
    if (!_gameMenuPanelOpen || _gameMenuPanelRetracting) return;
    if (_isProfilePanelOpen) {
      final canClose = await _saveProfilePanelIfDirtyBeforeClose();
      if (!canClose) return;
    }
    await _closeProfileSelectOverlay(notify: false, animated: false);
    _safeSetState(() {
      _gameMenuPanelOpen = false;
      _gameMenuPanelRetracting = true;
    });
    await _finishGameMenuPanelRetract();
    if (!mounted) return;
    _safeSetState(() => _resetGameProfilePanelStateForMenuClose());
  }

  /// 기능창(프로필/식단/가방)이 포함된 우측 슬라브 바깥(마당 영역) 터치.
  /// 식단일지 내 상세(day) 패널이 열려 있으면 먼저 달력으로만 복귀한다.
  /// 가방 설명창 오버레이가 터치를 못 받는 경우에 한해 여기서 설명창만 닫는다.
  /// 하위 기능창이 열려 있으면 [_dismissGameSubPanelWithCenterExit] 로 마당까지 닫는다.
  Future<void> _closeActiveGameMenuFromOutsideBackdropTap() async {
    if (_dismissKeyboardIfVisibleOnly()) return;
    if (_isDietDiaryPanelOpen) {
      final handled =
          await _dietDiarySheetPanelKey.currentState?.handleOutsideDismiss() ??
          false;
      if (handled) return;
    }
    if (_bagPanelDetailItem != null && _isBagPanelOpen) {
      _safeSetState(() => _bagPanelDetailItem = null);
      return;
    }

    if (_isShopNoticeOpen) {
      _closeShopNoticeOverlay();
      return;
    }

    if (_isRandomTicketUseConfirmOpen) {
      _closeRandomTicketUseConfirmOverlay();
      return;
    }

    if (_isEmailLinkInviteNoticeOpen) {
      return;
    }

    if (_isEmailFormatErrorNoticeOpen) {
      unawaited(_hideEmailFormatErrorNotice());
      return;
    }

    if (_isEmailDuplicateNoticeOpen) {
      _closeEmailDuplicateNoticeOverlay();
      return;
    }

    if (_isDuplicatePetNameNoticeOpen) {
      _closeDuplicatePetNameNoticeOverlay();
      return;
    }

    if (_isEmailLinkSuccessNoticeOpen) {
      return;
    }

    if (_isWithdrawFinalConfirmOpen) {
      _closeWithdrawFinalConfirmOverlay();
      return;
    }

    if (_isWithdrawConfirmOpen) {
      _closeWithdrawConfirmOverlay();
      return;
    }

    if (_isStoryPanelOpen && !_storyPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.story,
      );
      return;
    }

    if (_isCustomerCenterPanelOpen) {
      _safeSetState(() => _isCustomerCenterPanelOpen = false);
      return;
    }

    if (_activeSettingsSupportDoc != null ||
        _renderingSettingsSupportDoc != null) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.settings,
      );
      return;
    }

    if (_isEmailLinkPanelOpen) {
      _dismissFocus();
      _safeSetState(_closeEmailLinkPanel);
      return;
    }

    if (_isSettingsPanelOpen && !_settingsPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.settings,
      );
      return;
    }

    if (_isProfilePanelOpen && !_profilePanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.profile,
      );
      return;
    }
    if (_isDietDiaryPanelOpen && !_dietDiaryPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.dietDiary,
      );
      return;
    }
    if (_isBagPanelOpen && !_bagPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.bag,
      );
      return;
    }
    if (_isPokedexPanelOpen && !_pokedexPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.pokedex,
      );
      return;
    }
    if (_isHelpPanelOpen && !_helpPanelSwapInProgress) {
      await _dismissGameSubPanelWithCenterExit(
        _GameMenuSubOutsideDismissKind.help,
      );
      return;
    }

    await _closeGameMenuPanel();
  }

  Future<void> _handleGameMenuBackdropTap() async {
    await _closeActiveGameMenuFromOutsideBackdropTap();
  }

  /// 식단일지 상단 우측 "May. 26" 형식 (MVP 와이어 기준, 월 약어 + 연도 2자리).
  String _formatDietDiaryMonthYearCaption(DateTime m) {
    final raw = DateFormat('MMM', 'en_US').format(m);
    final mon = raw.endsWith('.') ? raw : '$raw.';
    final yy = (m.year % 100).toString().padLeft(2, '0');
    return '$mon $yy';
  }

  Widget _buildDietDiaryGameMenuGlassPanel() {
    final initialMonth = _clampDiaryMonth(_diaryVisibleMonth);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        // 식단일지/설정 글래스만 blur 완화(10→6). 다른 패널은 기존 값 유지.
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: RepaintBoundary(
            child: _DietDiarySheetPanel(
              key: _dietDiarySheetPanelKey,
              embeddedInGameMenuPanel: true,
              onEmbeddedBack: () => unawaited(_closeDietDiaryPanelToGameMenu()),
              monthYearCaptionBuilder: _formatDietDiaryMonthYearCaption,
              initialMonth: initialMonth,
              clampMonth: _clampDiaryMonth,
              isMonthInRange: _isDiaryMonthInRange,
              fetchMonthLogs: _fetchDiaryMonthLogs,
              logsByDateProvider: () => _diaryLogsByDate,
              dateKey: _dateKey,
              onMonthChanged: (m) {
                _safeSetState(() => _diaryVisibleMonth = m);
              },
              onSavedSuccess: () {
                _showSnack(AppLocalizations.of(context).dietDiarySavedSnackbar);
              },
              signedUrlBuilder: _signedMealPhotoUrl,
              onPhotoTap: _showMealPhotoPreview,
              fetchNote: _fetchMealDiaryNote,
              saveNote: _saveMealDiaryNote,
              bindKeyboardInput: _ensureKeyboardFocusBinding,
              buildKeyboardTriggerField: _buildKeyboardAccessoryTriggerField,
              calendarBuilder:
                  (
                    BuildContext sheetCtx,
                    DateTime visibleMonth,
                    Map<String, List<Map<String, dynamic>>> logsByDate,
                    Future<void> Function() onPrevMonth,
                    Future<void> Function() onNextMonth,
                    ValueChanged<DateTime> onTapDate,
                  ) {
                    return _buildDietDiaryCalendar(
                      sheetContext: sheetCtx,
                      diaryLogsByDate: logsByDate,
                      visibleMonth: visibleMonth,
                      onPrevMonth: onPrevMonth,
                      onNextMonth: onNextMonth,
                      onTapDate: onTapDate,
                    );
                  },
              monthPickerBuilder:
                  (
                    BuildContext sheetCtx,
                    int visibleYear,
                    int highlightYear,
                    int highlightMonth,
                    Future<void> Function(int year, int month) onPickMonth,
                    ValueChanged<int> onChangeYear,
                    VoidCallback onBack,
                    bool compact,
                  ) {
                    return _buildDietDiaryMonthPicker(
                      sheetContext: sheetCtx,
                      visibleYear: visibleYear,
                      highlightYear: highlightYear,
                      highlightMonth: highlightMonth,
                      onPickMonth: onPickMonth,
                      onChangeYear: onChangeYear,
                      onBack: onBack,
                      compact: compact,
                    );
                  },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _preloadCurrentDiaryMonthIfNeeded() async {
    if (_isPreloadingDiaryMonth) return;
    final month = _clampDiaryMonth(_todayDiaryMonth());
    final mk = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    if (_diaryLogsCachedMonthKey == mk) return;
    _isPreloadingDiaryMonth = true;
    try {
      await _fetchDiaryMonthLogs(month);
      if (mounted) _safeSetState(() {});
    } catch (e) {
      debugPrint('preload diary month failed: $e');
    } finally {
      _isPreloadingDiaryMonth = false;
    }
  }

  /// 설정 패널을 띄우기 전에 프로필·토글 상태를 맞춘다.
  /// 패널 표시 뒤 setState 로 스크롤 메트릭이 바뀌면 Scrollbar 가 깜빡일 수 있어
  /// 열기 전에 await 한다.
  Future<void> _prepareSettingsPanelData() async {
    try {
      await Future.wait([
        _fetchProfile(),
        _loadPushSettings(),
        _loadSoundSettings(),
      ]);
      await _syncAuthEmailToProfileIfNeeded();
    } catch (e) {
      debugPrint('prepare settings panel data failed: $e');
    }
  }

  /// 메뉴↔설정 페이드 전환·외부 닫기 페이드 중에는 Scrollbar thumb 를 숨긴다.
  /// (전환 직후 jumpTo/setState 로 스크롤 메트릭이 바뀌면 thumb 가 깜빡인다.)
  bool get _settingsScrollbarThumbVisible {
    if (!_isSettingsPanelOpen) return false;
    if (_settingsPanelSwapInProgress) return false;
    if (_settingsSupportDocSwapInProgress) return false;
    if (_gameSettingsSwapController.isAnimating) return false;
    if (_gameMenuSubOutsideDismissKind !=
        _GameMenuSubOutsideDismissKind.none) {
      return false;
    }
    final docForRender =
        _activeSettingsSupportDoc ?? _renderingSettingsSupportDoc;
    if (docForRender != null) return false;
    return _gameSettingsSwapCurve.value >= 1.0;
  }

  /// 설정 고객지원 문서창 스크롤 thumb (본문 스크롤바와 분리).
  bool get _settingsSupportDocScrollbarThumbVisible {
    final docForRender =
        _activeSettingsSupportDoc ?? _renderingSettingsSupportDoc;

    if (!_isSettingsPanelOpen) return false;
    if (docForRender == null) return false;
    if (!_settingsSupportDocScrollbarReady) return false;
    if (_settingsSupportDocSwapInProgress) return false;
    if (_settingsPanelSwapInProgress) return false;
    if (_gameSettingsSwapController.isAnimating) return false;
    if (_gameMenuSubOutsideDismissKind !=
        _GameMenuSubOutsideDismissKind.none) {
      return false;
    }
    if (!_settingsSupportDocScrollController.hasClients) return false;

    final position = _settingsSupportDocScrollController.position;
    if (!position.hasContentDimensions) return false;

    final viewportHeight = position.viewportDimension;
    final maxScroll = position.maxScrollExtent;
    if (!viewportHeight.isFinite || viewportHeight <= 0) return false;
    if (!maxScroll.isFinite || maxScroll <= 0) return false;

    return true;
  }

  /// 설정 패널 스크롤: content는 left/right 8, thumb는 패널 내부 right 8 고정.
  Widget _buildSettingsPanelManualScrollbar({
    required ScrollController controller,
    required bool thumbVisible,
  }) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        try {
          if (!thumbVisible) return const SizedBox.shrink();
          if (!controller.hasClients) return const SizedBox.shrink();

          final position = controller.position;
          if (!position.hasContentDimensions) return const SizedBox.shrink();

          final viewportHeight = position.viewportDimension;
          final maxScroll = position.maxScrollExtent;
          if (!viewportHeight.isFinite || viewportHeight <= 0) {
            return const SizedBox.shrink();
          }
          if (!maxScroll.isFinite || maxScroll <= 0) {
            return const SizedBox.shrink();
          }

          final contentHeight = viewportHeight + maxScroll;
          if (!contentHeight.isFinite || contentHeight <= 0) {
            return const SizedBox.shrink();
          }

          final rawThumbHeight =
              viewportHeight * (viewportHeight / contentHeight);
          if (!rawThumbHeight.isFinite) return const SizedBox.shrink();

          final thumbHeight = rawThumbHeight.clamp(24.0, viewportHeight);
          final maxThumbTop = viewportHeight - thumbHeight;
          if (!maxThumbTop.isFinite || maxThumbTop < 0) {
            return const SizedBox.shrink();
          }

          final offset = controller.offset;
          if (!offset.isFinite) return const SizedBox.shrink();

          final fraction = (offset / maxScroll).clamp(0.0, 1.0);
          final thumbTop = fraction * maxThumbTop;
          if (!thumbTop.isFinite) return const SizedBox.shrink();

          return Stack(
            clipBehavior: Clip.none,
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
        } catch (e, st) {
          debugPrint('settings manual scrollbar skipped: $e\n$st');
          return const SizedBox.shrink();
        }
      },
    );
  }

  Widget _buildSettingsPanelScrollArea({
    required ScrollController controller,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.fromLTRB(8, 0, 8, 14),
    bool forSupportDoc = false,
  }) {
    final thumbVisible = forSupportDoc
        ? _settingsSupportDocScrollbarThumbVisible
        : _settingsScrollbarThumbVisible;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: 8,
          right: 8,
          top: 0,
          bottom: 0,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: controller,
              padding: padding,
              physics: const ClampingScrollPhysics(),
              child: child,
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 0,
          bottom: 0,
          width: 3,
          child: _buildSettingsPanelManualScrollbar(
            controller: controller,
            thumbVisible: thumbVisible,
          ),
        ),
      ],
    );
  }

  void _resetSettingsPanelScrollOffset() {
    if (_settingsScrollController.hasClients &&
        _settingsScrollController.offset != 0) {
      _settingsScrollController.jumpTo(0);
    }
    if (_settingsSupportDocScrollController.hasClients &&
        _settingsSupportDocScrollController.offset != 0) {
      _settingsSupportDocScrollController.jumpTo(0);
    }
  }

  Future<void> _openDietDiaryFromGameMenu() async {
    if (_dietDiaryPanelSwapInProgress) return;
    if (_gameDietDiarySwapController.isAnimating) return;
    _instantResetSettingsPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    if (!await _closeGameMenuProfilePanelForMenuSwitch()) return;
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }

    final initialMonth = _clampDiaryMonth(_todayDiaryMonth());

    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    _safeSetState(() {
      _diaryVisibleMonth = initialMonth;
      _dietDiaryPanelSwapInProgress = true;
      _isDietDiaryPanelOpen = true;
    });

    unawaited(
      _gameDietDiarySwapController.forward(from: 0.0).whenComplete(() {
        if (!mounted) return;
        _safeSetState(() {
          _dietDiaryPanelSwapInProgress = false;
        });
      }),
    );

    final openMonthKey =
        '${initialMonth.year}-${initialMonth.month.toString().padLeft(2, '0')}';
    if (_diaryLogsCachedMonthKey != openMonthKey) {
      unawaited(
        _fetchDiaryMonthLogs(initialMonth)
            .then((_) {
              if (!mounted) return;
              _safeSetState(() {});
            })
            .catchError((Object e) {
              debugPrint('fetch diary month logs after open failed: $e');
            }),
      );
    }
  }

  Future<void> _closeDietDiaryPanelToGameMenu() async {
    if (_dietDiaryPanelSwapInProgress) return;
    _dismissFocus();
    _gameDietDiarySwapController.value = 1.0;
    _safeSetState(() {
      _dietDiaryPanelSwapInProgress = true;
    });
    await _gameDietDiarySwapController.reverse(from: 1.0);
    if (!mounted) return;
    _safeSetState(() {
      _diaryVisibleMonth = _todayDiaryMonth();
      _dietDiaryPanelSwapInProgress = false;
      _isDietDiaryPanelOpen = false;
    });
  }

  Future<void> _openMenuSheet() async {
    if (_gameMenuPanelRetracting) return;

    if (_gameMenuPanelOpen) {
      await _closeGameMenuPanel();
      return;
    }

    if (_isPetInfoBannerOpen) {
      _closePetInfoBanner();
      return;
    }

    if (_isProfilePanelOpen) {
      final canClose = await _saveProfilePanelIfDirtyBeforeClose();
      if (!canClose) return;
    }

    _safeSetState(() {
      _isPetInfoBannerOpen = false;
      _gameMenuPanelOpen = false;
      _gameMenuPanelRetracting = true;
      _resetGameProfilePanelStateForMenuClose();
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    _safeSetState(() {
      _gameMenuPanelOpen = true;
      _gameMenuPanelRetracting = false;
    });
    unawaited(_preloadCurrentDiaryMonthIfNeeded());
  }

  Future<void> _onMenuTap(String label) async {
    if (label == '식단일지') {
      await _openDietDiaryFromGameMenu();
    } else {
      _showSnack(AppLocalizations.of(context).snackComingLater(label));
    }
  }

  Future<void> _fetchProfileAndRefreshSettingsUi() async {
    await _fetchProfile();
    if (!mounted) return;
    _safeSetState(() {});
  }

  Future<void> _openSettingsFromGameMenu() async {
    if (_settingsPanelSwapInProgress) return;
    if (_gameSettingsSwapController.isAnimating) return;
    _instantResetStoryPanelIfOpen();
    _instantResetHelpPanelIfOpen();
    if (!await _closeGameMenuProfilePanelForMenuSwitch()) return;
    _gameDietDiarySwapController.stop();
    _gameDietDiarySwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
      });
    }
    _gameBagSwapController.stop();
    _gameBagSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
      });
    }
    _gamePokedexSwapController.stop();
    _gamePokedexSwapController.value = 0.0;
    if (mounted) {
      _safeSetState(() {
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
      });
    }
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    await _prepareSettingsPanelData();
    if (!mounted) return;

    _resetSettingsPanelScrollOffset();

    _gameSettingsSwapController.stop();
    _gameSettingsSwapController.value = 0.0;
    _safeSetState(() {
      _settingsNoticePushBusy = false;
      _settingsMealPushBusy = false;
      _settingsBgmBusy = false;
      _settingsSfxBusy = false;
      _settingsPanelSwapInProgress = true;
      _isSettingsPanelOpen = true;
      _activeSettingsSupportDoc = null;
      _renderingSettingsSupportDoc = null;
      _settingsSupportDocSwapInProgress = false;
      _settingsSupportDocScrollbarReady = false;
    });

    unawaited(
      _gameSettingsSwapController.forward(from: 0.0).whenComplete(() {
        if (!mounted) return;
        _safeSetState(() {
          _settingsPanelSwapInProgress = false;
        });
      }),
    );
  }

  Future<void> _closeSettingsPanelToGameMenu() async {
    if (_settingsPanelSwapInProgress) return;
    _dismissFocus();
    await _closeProfileSelectOverlay(notify: false, animated: false);
    _gameSettingsSwapController.value = 1.0;
    _safeSetState(() {
      _settingsPanelSwapInProgress = true;
    });
    await _gameSettingsSwapController.reverse(from: 1.0);
    if (!mounted) return;
    _resetSettingsPanelScrollOffset();
    _safeSetState(() {
      _settingsPanelSwapInProgress = false;
      _isSettingsPanelOpen = false;
      _isEmailLinkPanelOpen = false;
      _isCustomerCenterPanelOpen = false;
      _instantCloseYardConfirmOverlays();
      _activeSettingsSupportDoc = null;
      _renderingSettingsSupportDoc = null;
      _settingsSupportDocSwapInProgress = false;
      _settingsSupportDocScrollbarReady = false;
      _resetEmailLinkPanelOtpFlow();
    });
  }

  void _scheduleSettingsSupportDocScrollbarReady(_SupportDocType type) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (!mounted) return;
        final stillSameDoc =
            (_activeSettingsSupportDoc ?? _renderingSettingsSupportDoc) ==
            type;
        if (!stillSameDoc) return;
        _safeSetState(() => _settingsSupportDocScrollbarReady = true);
      });
    });
  }

  void _openSettingsSupportDocPanel(_SupportDocType type) {
    _dismissFocus();
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    debugPrint('open support doc: active=$type rendering=$type');
    _safeSetState(() {
      _isCustomerCenterPanelOpen = false;
      _isEmailLinkPanelOpen = false;
      _resetEmailLinkPanelOtpFlow();
      _activeSettingsSupportDoc = type;
      _renderingSettingsSupportDoc = type;
      _settingsSupportDocSwapInProgress = true;
      _settingsSupportDocScrollbarReady = false;
    });
    _scheduleSettingsSupportDocScrollbarReady(type);
    Future<void>.delayed(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      _safeSetState(() => _settingsSupportDocSwapInProgress = false);
    });
  }

  void _closeSettingsSupportDocToSettings() {
    final docForRender =
        _activeSettingsSupportDoc ?? _renderingSettingsSupportDoc;
    if (docForRender == null) return;
    debugPrint(
      'close support doc: active=$_activeSettingsSupportDoc '
      'rendering=$_renderingSettingsSupportDoc',
    );
    _safeSetState(() {
      _settingsSupportDocSwapInProgress = true;
      _settingsSupportDocScrollbarReady = false;
      _activeSettingsSupportDoc = null;
      _renderingSettingsSupportDoc = docForRender;
    });
    Future<void>.delayed(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      _safeSetState(() {
        _settingsSupportDocSwapInProgress = false;
        _renderingSettingsSupportDoc = null;
        _settingsSupportDocScrollbarReady = false;
      });
    });
  }

  Future<void> _closeSettingsSupportDocFromOutsideTap() async {
    _safeSetState(() => _settingsSupportDocScrollbarReady = false);
    await _dismissGameSubPanelWithCenterExit(
      _GameMenuSubOutsideDismissKind.settings,
    );
  }

  Widget _buildSettingsSupportDocAnimatedLayer({
    required _SupportDocType docType,
    required AppLocalizations l10n,
    required bool layerVisible,
  }) {
    final safeLocaleCode = _safeLocaleCodeForBuild(context);
    final document = _buildSupportDocument(docType, safeLocaleCode, l10n);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      opacity: layerVisible ? 1 : 0,
      child: RepaintBoundary(
        key: ValueKey('settings-support-doc-${docType.name}'),
        child: _buildSettingsSupportDocScrollBody(document),
      ),
    );
  }

  Widget _buildSettingsSupportDocScrollBody(_SupportDocument doc) {
    const sectionTitleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.35,
    );
    const bodyStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: Color(0xFF4A4A4A),
      height: 1.4,
    );

    return RepaintBoundary(
      child: _buildSettingsPanelScrollArea(
        controller: _settingsSupportDocScrollController,
        forSupportDoc: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              doc.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF000000),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              for (final section in doc.sections) ...[
                Text(
                  section.title,
                  textAlign: TextAlign.left,
                  style: sectionTitleStyle,
                ),
                const SizedBox(height: 4),
                Text(
                  section.body,
                  textAlign: TextAlign.left,
                  style: bodyStyle,
                ),
                const SizedBox(height: 10),
              ],
            ],
        ),
      ),
    );
  }

  TextStyle _settingsPanelTextStyle(
    double fontSize,
    FontWeight weight,
    Color color, {
    double height = 1.0,
  }) {
    return TextStyle(
      fontFamily: 'Pretendard',
      fontSize: fontSize,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  Widget _buildSettingsLanguageSelectRow() {
    const selectKey = 'settings_language';
    final link = _profileSelectLinks.putIfAbsent(selectKey, LayerLink.new);
    final isOpen = _openProfileSelectKey == selectKey;
    final currentLabel = _currentLanguageDisplayLabel();
    const rowTextStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );

    return Center(
      child: CompositedTransformTarget(
        link: link,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              _dismissFocus();
              if (isOpen) {
                unawaited(_closeProfileSelectOverlay());
                return;
              }
              _openProfileSelectOverlay(
                selectKey: selectKey,
                link: link,
                options: _languageDisplayOptions,
                selectedValue: currentLabel,
                onChanged: (label) {
                  unawaited(_onSettingsLanguageSelected(label));
                },
                dropdownWidth: _kSettingsGrayRowW,
                dropdownVerticalOffset: _kSettingsGrayRowH,
                menuBackgroundColor: const Color(0xFFEFEFEF),
                selectedBackgroundColor: const Color(0xFFE6E6E6),
                menuBorderEnabled: false,
                splashColor: const Color(0xFFE6E6E6),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: _kSettingsGrayRowW,
                height: _kSettingsGrayRowH,
                color: const Color(0xFFEFEFEF),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        currentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: rowTextStyle,
                      ),
                    ),
                    Icon(
                      isOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: const Color(0xFF4A4A4A).withValues(alpha: 0.65),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsGrayRow({required Widget child, VoidCallback? onTap}) {
    final core = ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: _kSettingsGrayRowW,
        height: _kSettingsGrayRowH,
        color: const Color(0xFFEFEFEF),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        child: child,
      ),
    );
    if (onTap == null) {
      return Center(child: core);
    }
    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: core,
        ),
      ),
    );
  }

  Future<void> _onSettingsNoticeToggle(bool enabled) async {
    if (_settingsNoticePushBusy) return;
    final l10n = AppLocalizations.of(context);
    _safeSetState(() => _settingsNoticePushBusy = true);
    await _toggleNoticeEventPush(
      enabled,
      enabledMessage: l10n.noticeEventEnabled,
      disabledMessage: l10n.noticeEventDisabled,
    );
    if (!mounted) return;
    _safeSetState(() {
      _settingsNoticePushBusy = false;
    });
  }

  Future<void> _onSettingsMealToggle(bool enabled) async {
    if (_settingsMealPushBusy) return;
    final l10n = AppLocalizations.of(context);
    _safeSetState(() => _settingsMealPushBusy = true);
    await _toggleMealReminderPush(
      enabled,
      notificationTitle: l10n.mealNotificationTitle,
      notificationMessages: [
        l10n.mealNotificationMessage1,
        l10n.mealNotificationMessage2,
      ],
      permissionDeniedMessage: l10n.notificationPermissionDenied,
      enabledMessage: l10n.mealReminderEnabled,
      disabledMessage: l10n.mealReminderDisabled,
    );
    if (!mounted) return;
    _safeSetState(() {
      _settingsMealPushBusy = false;
    });
  }

  Future<void> _onSettingsBgmToggle(bool enabled) async {
    if (_settingsBgmBusy) return;
    final l10n = AppLocalizations.of(context);
    _safeSetState(() => _settingsBgmBusy = true);
    await _toggleBackgroundMusic(
      enabled,
      enabledMessage: l10n.backgroundMusicEnabled,
      disabledMessage: l10n.backgroundMusicDisabled,
    );
    if (!mounted) return;
    _safeSetState(() {
      _settingsBgmBusy = false;
    });
  }

  Future<void> _onSettingsSfxToggle(bool enabled) async {
    if (_settingsSfxBusy) return;
    final l10n = AppLocalizations.of(context);
    _safeSetState(() => _settingsSfxBusy = true);
    await _toggleSoundEffects(
      enabled,
      enabledMessage: l10n.soundEffectsEnabled,
      disabledMessage: l10n.soundEffectsDisabled,
    );
    if (!mounted) return;
    _safeSetState(() {
      _settingsSfxBusy = false;
    });
  }

  String _settingsAccountPrimaryLine(AppLocalizations l10n) {
    if (_hasEffectiveEmailLink()) {
      final auth = _currentAuthEmail()?.trim();
      if (auth != null && auth.isNotEmpty) return auth;
      final pe = _profile?['email']?.toString().trim() ?? '';
      if (pe.isNotEmpty) return pe;
      return _resolvedDisplayEmailLine(l10n);
    }
    final uid = supabase.auth.currentUser?.id ?? '';
    final prefix = uid.length <= 18 ? uid : uid.substring(0, 18);
    return l10n.settingsGuestUserIdLine(prefix);
  }

  Widget _buildSettingsGameMenuGlassPanel() {
    final l10n = AppLocalizations.of(context);
    final linked = _hasEffectiveEmailLink();
    final accountPrimary = _settingsAccountPrimaryLine(l10n);

    final rowLabelStyle = _settingsPanelTextStyle(
      11,
      FontWeight.w600,
      const Color(0xFF4A4A4A),
      height: 1.0,
    );

    Widget sectionTitle(String text) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: _settingsPanelTextStyle(
            13,
            FontWeight.w600,
            const Color(0xFF000000),
            height: 1.0,
          ),
        ),
      );
    }

    Widget pushSwitchRow(
      String label,
      bool value,
      bool busy,
      ValueChanged<bool> onChanged,
    ) {
      return _buildSettingsGrayRow(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rowLabelStyle,
              ),
            ),
            SizedBox(
              height: _kSettingsGrayRowH,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: value,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: busy ? null : onChanged,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget supportNavRow(String label, VoidCallback onTap) {
      return _buildSettingsGrayRow(
        onTap: onTap,
        child: Row(
          children: [
            // 영어 "Account & Data Deletion" / "Privacy Policy" 등 긴 항목이
            // ellipsis 로 잘리지 않도록 FittedBox(scaleDown) 으로 1줄 표시.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: rowLabelStyle,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: const Color(0xFF4A4A4A).withValues(alpha: 0.65),
            ),
          ],
        ),
      );
    }

    final supportDocForRender =
        _activeSettingsSupportDoc ?? _renderingSettingsSupportDoc;
    final supportDocBlur = supportDocForRender != null ? 10.0 : 6.0;
    Widget? supportDocLayer;
    if (supportDocForRender != null) {
      debugPrint(
        'render support doc: '
        'active=$_activeSettingsSupportDoc '
        'rendering=$_renderingSettingsSupportDoc '
        'supportDocForRender=$supportDocForRender',
      );
      supportDocLayer = _buildSettingsSupportDocAnimatedLayer(
        docType: supportDocForRender,
        l10n: l10n,
        layerVisible: _activeSettingsSupportDoc != null,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: supportDocBlur,
          sigmaY: supportDocBlur,
        ),
        child: Container(
          width: _kGameMenuPanelW,
          height: _kGameMenuPanelH,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.60),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      if (supportDocForRender != null) {
                        _closeSettingsSupportDocToSettings();
                        return;
                      }
                      unawaited(_closeSettingsPanelToGameMenu());
                    },
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
              Positioned(
                left: 37,
                top: _gameMenuSubPanelTitleTop,
                right: 8,
                child: Text(
                  l10n.settings,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _settingsPanelTextStyle(
                      16,
                      FontWeight.w700,
                      const Color(0xFF000000),
                      height: 1.0,
                    ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 48,
                bottom: 8,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Offstage(
                      offstage: supportDocForRender != null,
                      child: IgnorePointer(
                        ignoring: supportDocForRender != null,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          opacity: supportDocForRender == null ? 1 : 0,
                          child: RepaintBoundary(
                            key: const ValueKey('settings-panel-main'),
                            child: _buildSettingsPanelScrollArea(
                              controller: _settingsScrollController,
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                          const SizedBox(height: 4),
                          sectionTitle(l10n.settingsSectionAccountBullet),
                          const SizedBox(height: 6),
                          _buildSettingsGrayRow(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                accountPrimary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: rowLabelStyle,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (linked)
                            _buildSettingsGrayRow(
                              onTap: () {
                                _showSnack(
                                  AppLocalizations.of(
                                    context,
                                  ).snackEmailAlreadyLinked,
                                );
                              },
                              child: Row(
                                children: [
                                  ShaderMask(
                                    blendMode: BlendMode.srcIn,
                                    shaderCallback: (bounds) =>
                                        const LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Color(0xFFA9C9FF),
                                            Color(0xFFBFD9FF),
                                          ],
                                        ).createShader(bounds),
                                    child: const Icon(
                                      Icons.check_circle_outline,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _buildPastelBlueGradientButtonText(
                                      l10n.emailLinkCompleted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      textAlign: TextAlign.start,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            _buildSettingsGrayRow(
                              onTap: () {
                                if (_hasEffectiveEmailLink()) return;
                                _dismissFocus();
                                _safeSetState(() {
                                  _prepareEmailLinkPanelForOpen();
                                  _isCustomerCenterPanelOpen = false;
                                  _isEmailLinkPanelOpen = true;
                                });
                              },
                              child: Row(
                                children: [
                                  ShaderMask(
                                    blendMode: BlendMode.srcIn,
                                    shaderCallback: (bounds) =>
                                        const LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Color(0xFFA9C9FF),
                                            Color(0xFFBFD9FF),
                                          ],
                                        ).createShader(bounds),
                                    child: const Icon(
                                      Icons.link_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _buildPastelBlueGradientButtonText(
                                      l10n.emailAccountLink,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      textAlign: TextAlign.start,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 6),
                          _buildSettingsGrayRow(
                            onTap: _isDeletingAccount
                                ? null
                                : _openWithdrawConfirmPanel,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.logout_rounded,
                                  size: 14,
                                  color: const Color(0xFFB92020),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    l10n.withdrawAccount,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: rowLabelStyle.copyWith(
                                      color: const Color(0xFFB92020),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          sectionTitle(l10n.settingsSectionLanguageBullet),
                          const SizedBox(height: 6),
                          _buildSettingsLanguageSelectRow(),
                          const SizedBox(height: 10),
                          sectionTitle(l10n.settingsSectionPushBullet),
                          const SizedBox(height: 6),
                          pushSwitchRow(
                            l10n.pushNoticeEvent,
                            _noticeEventPushEnabled,
                            _settingsNoticePushBusy,
                            (v) => unawaited(_onSettingsNoticeToggle(v)),
                          ),
                          const SizedBox(height: 6),
                          pushSwitchRow(
                            l10n.pushMealReminder,
                            _mealReminderPushEnabled,
                            _settingsMealPushBusy,
                            (v) => unawaited(_onSettingsMealToggle(v)),
                          ),
                          const SizedBox(height: 10),
                          sectionTitle(l10n.settingsSectionSoundBullet),
                          const SizedBox(height: 6),
                          pushSwitchRow(
                            l10n.backgroundMusic,
                            _backgroundMusicEnabled,
                            _settingsBgmBusy,
                            (v) => unawaited(_onSettingsBgmToggle(v)),
                          ),
                          const SizedBox(height: 6),
                          pushSwitchRow(
                            l10n.soundEffects,
                            _soundEffectsEnabled,
                            _settingsSfxBusy,
                            (v) => unawaited(_onSettingsSfxToggle(v)),
                          ),
                          const SizedBox(height: 10),
                          sectionTitle(l10n.settingsSectionSupportBullet),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.supportCenter,
                            () {
                              _safeSetState(
                                () => _isCustomerCenterPanelOpen = true,
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.termsOfService,
                            () => _openSettingsSupportDocPanel(
                              _SupportDocType.terms,
                            ),
                          ),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.privacyPolicy,
                            () => _openSettingsSupportDocPanel(
                              _SupportDocType.privacy,
                            ),
                          ),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.operationPolicy,
                            () => _openSettingsSupportDocPanel(
                              _SupportDocType.operation,
                            ),
                          ),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.guardianGuide,
                            () => _openSettingsSupportDocPanel(
                              _SupportDocType.guardian,
                            ),
                          ),
                          const SizedBox(height: 6),
                          supportNavRow(
                            l10n.accountDataDeletionGuide,
                            () => _openSettingsSupportDocPanel(
                              _SupportDocType.dataDeletion,
                            ),
                          ),
                          const SizedBox(height: 14),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ?supportDocLayer,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _SupportDocument _buildSupportDocument(
    _SupportDocType type,
    String localeCode,
    AppLocalizations l10n,
  ) {
    final isEn = localeCode == 'en';

    switch (type) {
      case _SupportDocType.terms:
        return _SupportDocument(
          title: l10n.termsOfService,
          sections: [
            _SupportDocumentSection(
              title: isEn ? '1. Purpose' : '1. 목적',
              body: isEn
                  ? 'This document explains the basic rules and terms for using VegePet.'
                  : '베지펫 서비스 이용 조건과 기본 규칙을 안내합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '2. What VegePet Provides' : '2. 서비스 내용',
              body: isEn
                  ? 'VegePet provides meal photo verification, AI-based meal feedback, pet growth, and features such as the diary, bag, collection, and settings. Some features may be limited during the MVP phase or added later.'
                  : '식단 사진 인증, AI 기반 식단 평가, 펫 육성, 도감/가방/식단일지/설정 기능을 제공합니다. 일부 기능은 MVP 단계 또는 추후 업데이트 대상일 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '3. Account & Email Linking' : '3. 계정 및 이메일 연동',
              body: isEn
                  ? 'Users can start as a guest and optionally link an email account via OTP. Users are responsible for entering their own valid email address.'
                  : '게스트 체험 계정으로 시작할 수 있으며 OTP로 이메일 연동이 가능합니다. 사용자는 본인 이메일을 정확히 입력해야 합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '4. User Responsibilities' : '4. 사용자 책임',
              body: isEn
                  ? 'Users must not enter false information, use another person’s email, or attempt abnormal/system-abusive access.'
                  : '허위 정보 입력, 타인 이메일 사용, 비정상 접근 및 시스템 악용을 금지합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. Health Notice' : '5. 식단 평가와 건강 관련 고지',
              body: isEn
                  ? 'AI meal feedback is for reference only and is not medical diagnosis or treatment. Consult professionals for health conditions or dietary restrictions.'
                  : 'AI 식단 평가는 참고용이며 의료/진단/치료 목적이 아닙니다. 건강 상태나 식단 제한이 있으면 전문가 상담이 필요합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '6. Game Items/Data' : '6. 아이템/분양권/게임 데이터',
              body: isEn
                  ? 'In-app items and tickets are for gameplay only, not cash-equivalent assets. Shop/payment features may be limited in MVP.'
                  : '아이템과 분양권은 게임 내 기능이며 현금성 자산이 아닙니다. 상점/결제 기능은 MVP 단계에서 제한되거나 2차 오픈 예정일 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '7. Service Changes' : '7. 서비스 변경 및 중단',
              body: isEn
                  ? 'Features may be changed, improved, or suspended for operations, maintenance, and updates.'
                  : '기능 개선, 오류 수정, 운영상 필요에 따라 서비스 내용이 변경되거나 중단될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '8. Use Restrictions' : '8. 이용 제한',
              body: isEn
                  ? 'VegePet may restrict service use for abuse, policy violations, or infringement of others’ rights.'
                  : '비정상 이용, 시스템 악용, 타인 권리 침해 시 서비스 이용이 제한될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '9. Limitation of Liability' : '9. 책임 제한',
              body: isEn
                  ? 'Some features may be limited by network/device environments. VegePet does not guarantee health outcomes.'
                  : '네트워크/기기 환경에 따라 일부 기능이 제한될 수 있으며, 앱은 건강 결과를 보장하지 않습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '10. Contact' : '10. 문의',
              body: 'acoustic.jwg@gmail.com',
            ),
          ],
        );
      case _SupportDocType.privacy:
        return _SupportDocument(
          title: l10n.privacyPolicy,
          sections: [
            _SupportDocumentSection(
              title: isEn ? '1. Data We Collect' : '1. 수집하는 정보',
              body: isEn
                  ? 'Account info (anonymous user id, linked email), profile info (nickname, gender, age range, diet goal), pet/game data, meal photos/logs, settings and technical logs may be collected.'
                  : '계정 정보(익명 사용자 ID, 이메일 연동 시 이메일), 프로필 정보, 펫/게임 데이터, 식단 사진/기록, 설정 정보, 기술 로그 등이 수집될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '2. Collection Methods' : '2. 수집 방법',
              body: isEn
                  ? 'Data is collected via user input, meal photo uploads, and automatic records generated during app use through Supabase services.'
                  : '사용자 직접 입력, 식단 사진 업로드, 앱 이용 과정에서 자동 생성되는 기록을 통해 수집하며 Supabase 서비스를 통해 저장됩니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '3. Purposes of Use' : '3. 이용 목적',
              body: isEn
                  ? 'Data is used for account identification, data continuity, meal evaluation, gameplay features, notifications, support responses, and service improvement.'
                  : '계정 식별, 데이터 유지, 식단 인증/평가, 게임 기능 제공, 알림 제공, 고객 문의 대응, 오류 수정 및 서비스 개선에 사용됩니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '4. Third-party Processing' : '4. 제3자 처리/외부 서비스',
              body: isEn
                  ? 'VegePet may use Supabase (auth/database/storage/functions), OpenAI (meal analysis), and platform services from Apple/Google. Remote push providers may be added later.'
                  : 'Supabase(인증/DB/스토리지/함수), OpenAI(식단 분석), Apple/Google 플랫폼 기능을 사용하며, 원격 푸시는 추후 FCM 등 외부 서비스를 사용할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. Meal Photo Caution' : '5. 식단 사진 및 민감 정보 주의',
              body: isEn
                  ? 'Users should avoid including personal identifiers in meal photos and avoid entering sensitive health details in notes.'
                  : '식단 사진에 개인 식별 정보가 노출되지 않도록 촬영하고, 민감한 건강 정보를 기록에 입력하지 않도록 권장합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '6. Retention' : '6. 보관 기간',
              body: isEn
                  ? 'Data is deleted upon account deletion request unless legal retention requirements apply. Backup/log records may be retained for a limited period.'
                  : '회원 탈퇴 또는 삭제 요청 시 데이터를 삭제하며, 법령상 보관 의무가 있는 경우 예외가 있을 수 있습니다. 백업/로그는 일정 기간 보관될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '7. Account & Data Deletion' : '7. 계정 및 데이터 삭제',
              body: isEn
                  ? 'Users can delete data in Settings > Account > Delete Account. External deletion requests can be sent to acoustic.jwg@gmail.com.'
                  : '설정 > 계정 > 회원 탈퇴에서 계정 및 관련 데이터 삭제가 가능합니다. 앱 접근이 어려우면 acoustic.jwg@gmail.com으로 삭제 요청할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '8. User Rights' : '8. 사용자 권리',
              body: isEn
                  ? 'Users may request access, correction, linkage updates, or deletion of their data.'
                  : '사용자는 열람, 수정, 삭제, 계정 연동 관련 요청을 할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '9. Children & Guardians' : '9. 아동 및 보호자',
              body: isEn
                  ? 'Minor users should use VegePet under guardian guidance. Guardian verification may be required under local laws.'
                  : '미성년자는 보호자 지도하에 사용을 권장하며, 관련 법령에 따라 보호자 동의가 필요할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '10. Security' : '10. 보안',
              body: isEn
                  ? 'Reasonable protection measures are applied, but complete security cannot be guaranteed in all internet/mobile environments.'
                  : '합리적인 보호 조치를 적용하지만 인터넷/모바일 환경 특성상 완전한 보안을 보장할 수는 없습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '11. Policy Updates' : '11. 변경 고지',
              body: isEn
                  ? 'Policy updates may be announced in-app or via update notices.'
                  : '정책 변경 시 앱 내 공지 또는 업데이트 안내를 통해 고지할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '12. Contact' : '12. 문의',
              body: 'acoustic.jwg@gmail.com',
            ),
          ],
        );
      case _SupportDocType.operation:
        return _SupportDocument(
          title: l10n.operationPolicy,
          sections: [
            _SupportDocumentSection(
              title: isEn ? '1. Purpose' : '1. 운영 목적',
              body: isEn
                  ? 'Provide a stable meal-recording and VegePet growth experience.'
                  : '안정적인 식단 기록 및 베지펫 육성 경험 제공을 목적으로 운영합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '2. Service Principles' : '2. 서비스 운영 원칙',
              body: isEn
                  ? 'We prioritize reliability, bug fixes, and feature improvements while distinguishing MVP and future features.'
                  : '오류 수정, 기능 개선, 데이터 안정성을 우선하며 MVP 기능과 향후 기능을 구분해 운영합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '3. Prohibited Activities' : '3. 금지 행위',
              body: isEn
                  ? 'Using others’ accounts/emails, tampering with data, abnormal requests, and repeated false certification are prohibited.'
                  : '타인 계정/이메일 사용, 데이터 변조, 비정상 요청, 허위 인증 반복 등은 금지됩니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '4. Data Management' : '4. 데이터 및 기록 관리',
              body: isEn
                  ? 'Meal photos, diary entries, and pet data are managed per user account; logs may be used for error analysis.'
                  : '식단 사진/일지/펫 데이터는 계정 기준으로 관리되며, 오류 분석을 위해 일부 로그를 활용할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. AI Evaluation Operations' : '5. AI 식단 평가 운영 기준',
              body: isEn
                  ? 'AI meal feedback is for reference only and may vary depending on photo quality or the surrounding environment. Re-capture guidance may be shown for uncertain results.'
                  : 'AI 결과는 참고용이며 사진 품질/조명 등에 따라 달라질 수 있습니다. 불확실 판정 시 재촬영 안내가 제공될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '6. Notifications' : '6. 알림 운영',
              body: isEn
                  ? 'Meal reminders can be toggled by users. Announcement/event notifications may be sent in later updates.'
                  : '먹이 알림은 사용자가 ON/OFF할 수 있으며, 공지/이벤트 알림은 추후 운영자가 발송할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '7. Item/Reward Operations' : '7. 아이템/보상 운영',
              body: isEn
                  ? 'In-app items are gameplay elements. Shop/payment may be limited or deferred in MVP.'
                  : '분양권/아이템은 게임 진행용 요소이며 상점/결제는 MVP에서 제한되거나 2차 오픈 예정일 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '8. Restrictions & Actions' : '8. 이용 제한 및 조치',
              body: isEn
                  ? 'Service use may be restricted for serious abuse, security threats, or rights infringement.'
                  : '심각한 악용, 보안 위협, 권리 침해 행위에 대해 이용 제한 조치가 이뤄질 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '9. Policy Updates' : '9. 정책 변경',
              body: isEn
                  ? 'Operational policies may change as needed for service sustainability.'
                  : '서비스 운영상 필요에 따라 운영정책이 변경될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '10. Contact' : '10. 문의',
              body: 'acoustic.jwg@gmail.com',
            ),
          ],
        );
      case _SupportDocType.guardian:
        return _SupportDocument(
          title: l10n.guardianGuide,
          sections: [
            _SupportDocumentSection(
              title: isEn ? '1. About VegePet' : '1. 베지펫 소개',
              body: isEn
                  ? 'VegePet is a gamified diet management app that combines meal verification with raising a virtual pet.'
                  : '베지펫은 식단 인증과 펫 육성을 결합한 게임형 식단관리 앱입니다.',
            ),
            _SupportDocumentSection(
              title: isEn
                  ? '2. Why Guardian Guidance Matters'
                  : '2. 보호자 확인이 필요한 이유',
              body: isEn
                  ? 'The app may handle profile and meal-related information, so guardian guidance is recommended for minors.'
                  : '앱은 프로필/식단 관련 정보를 다룰 수 있어 미성년자는 보호자 지도하에 사용하는 것을 권장합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '3. Meal Photo Safety' : '3. 식단 사진 촬영 주의',
              body: isEn
                  ? 'Avoid capturing personal identifiers such as faces, addresses, school names, or contact details.'
                  : '얼굴, 주소, 학교명, 연락처 등 개인 식별 정보가 노출되지 않도록 음식 중심으로 촬영해주세요.',
            ),
            _SupportDocumentSection(
              title: isEn ? '4. Health Caution' : '4. 건강 관련 주의',
              body: isEn
                  ? 'AI meal feedback does not replace professional medical or nutrition advice.'
                  : 'AI 식단 평가는 참고용이며 의료 조언을 대체하지 않습니다. 필요한 경우 전문가 상담이 필요합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. Payments & Shop' : '5. 결제 및 상점',
              body: isEn
                  ? 'In MVP, payment/shop features may be limited or unavailable. Future paid features should include guardian-friendly notices.'
                  : 'MVP에서는 상점/결제가 제한 또는 2차 오픈 예정이며, 유료 기능 추가 시 보호자 확인 고지가 강화되어야 합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '6. Notification Control' : '6. 알림 관리',
              body: isEn
                  ? 'Meal and announcement notifications can be turned on or off in Settings.'
                  : '먹이 알림과 공지 알림은 설정에서 ON/OFF할 수 있어 보호자가 이용 상태를 확인할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '7. Account & Data Deletion' : '7. 계정 및 데이터 삭제',
              body: isEn
                  ? 'Data can be deleted from Settings > Account > Delete Account. Guardians may request deletion via email.'
                  : '설정 > 계정 > 회원 탈퇴로 데이터 삭제가 가능하며, 보호자는 이메일로 삭제를 요청할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '8. Healthy Use Habits' : '8. 안전한 이용 습관',
              body: isEn
                  ? 'Avoid excessive use and review meal habits together. Prioritize real health status and professional guidance.'
                  : '과도한 사용을 피하고 보호자와 함께 식단을 점검하세요. 앱 결과보다 실제 건강 상태를 우선하세요.',
            ),
          ],
        );
      case _SupportDocType.dataDeletion:
        return _SupportDocument(
          title: l10n.accountDataDeletionGuide,
          sections: [
            _SupportDocumentSection(
              title: isEn ? '1. In-app Deletion Path' : '1. 앱 내 삭제 경로',
              body: isEn
                  ? 'Go to Settings > Account > Delete Account to remove your account and related data.'
                  : '설정 > 계정 > 회원 탈퇴에서 계정 및 관련 데이터 삭제가 가능합니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '2. Data That Will Be Deleted' : '2. 삭제되는 데이터',
              body: isEn
                  ? 'Profile data, linked email info, pet/collection/bag/ticket records, meal photos/logs, and diary entries are deleted.'
                  : '프로필, 이메일 연동 정보, 펫/도감/가방/분양권 데이터, 식단 사진/인증 기록, 식단일지 입력값 등이 삭제됩니다.',
            ),
            _SupportDocumentSection(
              title: isEn
                  ? '3. Data That May Be Retained'
                  : '3. 삭제되지 않거나 별도 보관될 수 있는 정보',
              body: isEn
                  ? 'Legally required records may be retained for required periods. Non-identifying logs/backups may be deleted after retention windows.'
                  : '법령상 보관 의무가 있는 정보는 필요한 기간 보관될 수 있으며, 비식별 로그/백업은 일정 기간 후 삭제될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '4. External Deletion Request' : '4. 앱 외부 삭제 요청',
              body: isEn
                  ? 'If app access is unavailable, send a request to acoustic.jwg@gmail.com. A web deletion-request URL may be required for Google Play.'
                  : '앱 접근이 어려운 경우 acoustic.jwg@gmail.com 으로 삭제 요청이 가능합니다. Google Play 제출 시 웹 삭제 요청 URL이 필요할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. Processing Timeline' : '5. 처리 기간',
              body: isEn
                  ? 'Requests are processed within a reasonable period after confirmation. Additional identity verification may be required.'
                  : '요청 확인 후 합리적인 기간 내 처리되며, 본인 확인을 위해 추가 정보 요청이 있을 수 있습니다.',
            ),
          ],
        );
    }
  }

  /// 회원 탈퇴: 사용자 데이터 삭제 후 익명 세션으로 재시작.
  /// auth.users 행 완전 삭제는 클라이언트 단독으로 불가 → Edge Function `delete-auth-user` 필요.
  Future<void> _deleteCurrentAuthUserByEdgeFunction() async {
    try {
      final response = await supabase.functions.invoke(
        'delete-auth-user',
        method: HttpMethod.post,
      );

      final data = response.data;
      debugPrint('delete-auth-user: status=${response.status} data=$data');
      if (data is Map) {
        if (data['ok'] == false) {
          debugPrint(
            'delete auth user failed: ok=false error=${data['error']} '
            'details=${data['details']}',
          );
        }
      } else if (data != null) {
        debugPrint(
          'delete auth user: unexpected response type ${data.runtimeType}',
        );
      }
    } catch (e, st) {
      debugPrint('delete auth user edge function failed: $e\n$st');
    }
  }

  Future<void> _withdrawAccount() async {
    _dismissFocus();
    await _waitForUiSettle();
    if (!mounted) return;

    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    }

    await _waitForUiSettle();
    if (!mounted) return;

    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackWithdrawCannotLogin);
      return;
    }

    final uid = user.id;

    try {
      await supabase.from('meal_logs').delete().eq('user_id', uid);
      try {
        await supabase.from('meal_diary_notes').delete().eq('user_id', uid);
      } catch (e) {
        debugPrint('meal_diary_notes delete skipped: $e');
      }
      await supabase.from('pokedex_entries').delete().eq('user_id', uid);
      await supabase.from('user_items').delete().eq('user_id', uid);
      await supabase.from('user_pets').delete().eq('user_id', uid);

      try {
        final remains = await supabase
            .from('pokedex_entries')
            .select('id')
            .eq('user_id', uid);
        final remainList = remains as List;
        if (remainList.isNotEmpty) {
          debugPrint(
            'withdraw warning: pokedex_entries still remain after delete (${remainList.length})',
          );
          await supabase.from('pokedex_entries').delete().eq('user_id', uid);
        }
      } catch (e) {
        debugPrint('withdraw pokedex verify skipped/failed: $e');
      }

      await supabase
          .from('profiles')
          .update({
            'nickname': null,
            'gender': null,
            'age_range': null,
            'diet_goal': null,
            // profiles 만 guest 로 초기화해도 auth.users 이메일은 남을 수 있다.
            // 같은 이메일 재사용까지 보장하려면 Edge Function 삭제가 성공해야 한다.
            'email': null,
            'account_type': 'guest',
            'linked_at': null,
            'gold_balance': 1000,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', uid);

      await _deleteCurrentAuthUserByEdgeFunction();
      await supabase.auth.signOut();

      if (!mounted) return;
      _safeSetState(() {
        _emailOtpCooldownTimer?.cancel();
        _emailOtpCooldownTimer = null;
        _emailOtpCooldownSeconds = 0;
        _profile = null;
        _petSpecies = [];
        _activePet = null;
        _residentPets = [];
        _selectedSpeciesId = null;
        _todayMealLogs = [];
        _firstMealPopupShownThisSession = false;
        _randomTicketCount = 0;
        _pokedexEntries = [];
        _isLoadingPokedex = false;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};
        _isUploadingMeal = false;
        _uploadingSlot = null;
        _isInteracting = false;
        _isUsingRandomTicket = false;
        _isInitialAdoptionPanelVisible = false;
        _isInitialAdoptionPanelClosing = false;
        _isInitialAdoptionInFlight = false;
        _isNamingDialogOpen = false;
        _canShowActivePetDuringNaming = false;
        _isPetNamingPanelClosing = false;
        _petNamingController.clear();
        if (_petNamingCompleter != null && !_petNamingCompleter!.isCompleted) {
          _petNamingCompleter!.complete(null);
        }
        _petNamingCompleter = null;
        _petNamingPanelEnterController.stop();
        _petNamingPanelEnterController.value = 0;
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;
        _petToySwapInProgress = false;
        _toyOpenedFromPetBanner = false;
        _isMealPanelOpen = false;
        _petMealSwapInProgress = false;
        _mealOpenedFromPetBanner = false;
        _petChildPanelDismissingToYard = false;
        _gameMenuPanelOpen = false;
        _gameMenuPanelRetracting = false;
        _isProfilePanelOpen = false;
        _profilePanelSwapInProgress = false;
        _profileOpenedFromGameMenu = false;
        _isDietDiaryPanelOpen = false;
        _dietDiaryPanelSwapInProgress = false;
        _isBagPanelOpen = false;
        _bagPanelSwapInProgress = false;
        _bagPanelDetailItem = null;
        _isPokedexPanelOpen = false;
        _pokedexPanelSwapInProgress = false;
        _pokedexPanelSelectedEntry = null;
        _isSettingsPanelOpen = false;
        _settingsPanelSwapInProgress = false;
        _activeSettingsSupportDoc = null;
        _renderingSettingsSupportDoc = null;
        _settingsSupportDocSwapInProgress = false;
        _settingsSupportDocScrollbarReady = false;
        _isEmailLinkPanelOpen = false;
        _isCustomerCenterPanelOpen = false;
        _instantCloseYardConfirmOverlays();
        _isStoryPanelOpen = false;
        _storyPanelSwapInProgress = false;
        _isHelpPanelOpen = false;
        _helpPanelSwapInProgress = false;
        _resetEmailLinkPanelOtpFlow();
        _gameMenuSubOutsideDismissKind = _GameMenuSubOutsideDismissKind.none;
        _nicknameController.clear();
        _selectedGender = null;
        _selectedAgeRange = null;
        _selectedDietGoal = null;
        _isProfileSetupPanelVisible = true;
        _isProfileSetupClosing = false;

        _lastResultType = null;
        _lastFeedbackText = null;
        _lastStatusMessage = null;
        _lastAffectionGain = null;
        _lastImagePath = null;
        _isAdopting = false;
        _isSavingProfile = false;
        _isLoggingMeal = false;
      });
      _petToySwapController.value = 0;
      _petMealSwapController.value = 0;
      _gameMenuPanelController.value = 0;
      _gameProfileSwapController.value = 0;
      _gameDietDiarySwapController.value = 0;
      _gameBagSwapController.value = 0;
      _gamePokedexSwapController.value = 0;
      _gameSettingsSwapController.value = 0;
      _gameHelpSwapController.value = 0;
      _gameMenuSubOutsideDismissController.value = 0;

      await _waitForUiSettle();
      if (!mounted) return;
      await _bootstrap();

      if (!mounted) return;
      _showSnack(l10n.snackWithdrawCompleted);
    } catch (e) {
      if (!mounted) return;
      _showSnack(l10n.snackWithdrawError(e.toString()));
    }
  }

  // 게임 메뉴 > "프로필" 진입 시 열리는 BottomSheet.
  //
  // 초기 프로필 입력 화면(_buildProfileFormContent)과는 별개로,
  // 마당 화면 위에 가벼운 프로필 카드 형태로 떠서 nickname/gender/diet_goal/resolution
  // 을 다시 확인/수정할 수 있게 해준다. (resolution = "다짐" 라벨로 노출)
  //
  // 안정화 포인트 (다른 모달들과 동일한 정책):
  //   - controller 는 여기 _openProfileSheet 스코프에서 만들고, finally 에서 dispose
  //   - sheetCtx 는 await 이후로는 사용하지 않는다 (저장/검증 후처리는 HomePage 의
  //     context 에서 수행). 시트 안에서 또 다른 showDialog 를 띄우지 않는다.
  //   - 저장 중 isSaving 로컬 락으로 연타/중복 update 방지
  //
  // 다짐(resolution) 컬럼 관련:
  //   - profiles.resolution (text) 컬럼이 있어야 한다.
  //   - 컬럼이 없으면 update 시 PostgREST 에서 에러가 나므로,
  //     필요시 Supabase SQL 에서 아래를 한 번 실행해야 한다.
  //       alter table public.profiles add column if not exists resolution text;
  // ignore: unused_element — 게임 메뉴 프로필 패널로 대체되었으나, 동일 폼 참고용으로 유지.
  Future<void> _openProfileSheet() async {
    _dismissFocus();

    final user = supabase.auth.currentUser;
    final currentProfile = _profile;
    if (user == null || currentProfile == null) {
      _showSnack('프로필 정보를 불러올 수 없어요.');
      return;
    }

    final nicknameController = TextEditingController(
      text: currentProfile['nickname']?.toString() ?? '',
    );
    final resolutionController = TextEditingController(
      text: currentProfile['resolution']?.toString() ?? '',
    );

    // 드롭다운 초기값. profiles 에 들어 있는 값이 옵션 리스트에 없을 수도 있으므로
    // 그때는 null 로 보정해서 DropdownButtonFormField 가 assertion error 를 내지 않게 한다.
    final initialGenderRaw = currentProfile['gender']?.toString();
    final initialDietGoalRaw = currentProfile['diet_goal']?.toString();
    String? selectedGender = _genderOptions.contains(initialGenderRaw)
        ? initialGenderRaw
        : null;
    String? selectedDietGoal = _dietGoalOptions.contains(initialDietGoalRaw)
        ? initialDietGoalRaw
        : null;

    bool isSaving = false;

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetCtx) {
          return StatefulBuilder(
            builder: (innerCtx, setSheetState) {
              final theme = Theme.of(innerCtx);
              final viewInsets = MediaQuery.of(innerCtx).viewInsets.bottom;

              Future<void> handleSave() async {
                if (isSaving) return;

                final nickname = nicknameController.text.trim();
                final resolutionText = resolutionController.text.trim();

                if (nickname.isEmpty) {
                  _showSnack('이름을 입력해주세요.');
                  return;
                }
                if (selectedGender == null) {
                  _showSnack('성별을 선택해주세요.');
                  return;
                }
                if (selectedDietGoal == null) {
                  _showSnack('식단 목적을 선택해주세요.');
                  return;
                }

                setSheetState(() => isSaving = true);

                try {
                  await supabase
                      .from('profiles')
                      .update({
                        'nickname': nickname,
                        'gender': selectedGender,
                        'diet_goal': selectedDietGoal,
                        'resolution': resolutionText.isEmpty
                            ? null
                            : resolutionText,
                        'updated_at': DateTime.now().toIso8601String(),
                      })
                      .eq('id', user.id);

                  await _fetchProfile();

                  if (!mounted) return;
                  // 시트 컨텍스트를 await 이후에 직접 사용하지 않고, sheetCtx 로
                  // 닫기만 수행한다. dispose 타이밍 안정화를 위해 한 frame 양보 후 SnackBar.
                  if (Navigator.of(sheetCtx).canPop()) {
                    Navigator.of(sheetCtx).pop();
                  }
                  _safeSetState(() {});
                  await _waitForUiSettle();
                  if (!mounted) return;
                  _showSnack('프로필이 저장되었어요!');
                } catch (e) {
                  if (!mounted) return;
                  setSheetState(() => isSaving = false);
                  _showSnack('프로필 저장 실패: $e');
                }
              }

              return SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + viewInsets),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Text(
                          '프로필',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(child: _buildProfileDummyAvatar(selectedGender)),
                      const SizedBox(height: 20),
                      TextField(
                        controller: nicknameController,
                        enabled: !isSaving,
                        maxLength: 16,
                        decoration: const InputDecoration(
                          labelText: '이름',
                          prefixIcon: Icon(Icons.edit_outlined),
                          border: OutlineInputBorder(),
                          isDense: true,
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: selectedGender,
                        decoration: const InputDecoration(
                          labelText: '성별',
                          prefixIcon: Icon(Icons.arrow_drop_down),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: _genderOptions
                            .map(
                              (v) => DropdownMenuItem<String>(
                                value: v,
                                child: Text(v),
                              ),
                            )
                            .toList(),
                        onChanged: isSaving
                            ? null
                            : (v) {
                                setSheetState(() => selectedGender = v);
                              },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: selectedDietGoal,
                        decoration: const InputDecoration(
                          labelText: '식단 목적',
                          prefixIcon: Icon(Icons.arrow_drop_down),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: _dietGoalOptions
                            .map(
                              (v) => DropdownMenuItem<String>(
                                value: v,
                                child: Text(v),
                              ),
                            )
                            .toList(),
                        onChanged: isSaving
                            ? null
                            : (v) {
                                setSheetState(() => selectedDietGoal = v);
                              },
                      ),
                      const SizedBox(height: 12),
                      // 다짐(resolution): 멀티라인 TextField + Stack 으로 우측 하단 연필 아이콘.
                      // suffixIcon 은 멀티라인에서 우측 중앙에 떠서 의도와 어긋나므로
                      // Stack 으로 직접 우측 하단에 고정한다.
                      Stack(
                        children: [
                          TextField(
                            controller: resolutionController,
                            enabled: !isSaving,
                            minLines: 4,
                            maxLines: 6,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              labelText: '다짐',
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(),
                              // 우측 하단 연필 아이콘과 본문이 겹치지 않도록
                              // 오른쪽/아래쪽 padding 을 약간 더 준다.
                              contentPadding: EdgeInsets.fromLTRB(
                                12,
                                12,
                                32,
                                28,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: isSaving ? null : handleSave,
                          child: isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('저장'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      // BottomSheet 가 닫힌 뒤 controller 정리.
      // 시트 내부에서 dispose 하면 setSheetState 도중 controller 가 사라져
      // 키보드 정리/포커스 해제와 충돌할 수 있어 외부 finally 에서만 정리한다.
      nicknameController.dispose();
      resolutionController.dispose();
    }
  }

  // 프로필 창 상단의 동그란 더미 프로필 아이콘.
  // 실제 사진 업로드 기능은 MVP 범위 밖이고, 성별에 따라 이모지 같은 기본 아이콘만 보여준다.
  Widget _buildProfileDummyAvatar(String? gender) {
    final theme = Theme.of(context);
    final isFemale = gender == '여자';
    final isMale = gender == '남자';

    final IconData icon;
    if (isFemale) {
      icon = Icons.face_3_outlined;
    } else if (isMale) {
      icon = Icons.face_outlined;
    } else {
      icon = Icons.person_outline;
    }

    return CircleAvatar(
      radius: 44,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 54, color: theme.colorScheme.onSurfaceVariant),
    );
  }

  // ==========================================================================
  // 식단일지 (diet diary)
  // --------------------------------------------------------------------------
  // 게임 메뉴 > "식단일지" 진입 시 BottomSheet 형태로 열린다.
  //
  // 시트 안에서 3가지 모드가 토글된다:
  //   - calendar    : 월 달력 + 식단 인증 도장
  //   - monthPicker : 같은 연도의 1~12월 그리드에서 월 선택
  //   - detail      : 특정 날짜의 아점/저녁 사진 + 체중/노트 입력
  //
  // 상세 화면(detail)은 TextEditingController 두 개를 들고 있어야 해서
  // StatefulBuilder 안에서 만들면 dispose 가 어렵다. 그래서 별도의 private
  // StatefulWidget [_DietDiaryDetailPanel] 으로 분리해 controller 수명을 거기서 관리한다.
  // ==========================================================================

  // 사용자에게 보여줄 yyyy-MM-dd 문자열 (KST 기준 _todayDateStr 와 같은 포맷).
  // diary_date / meal_date 모두 이 포맷을 사용한다.
  String _dateKey(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  DateTime _monthStart(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _monthEnd(DateTime d) => DateTime(d.year, d.month + 1, 0);
  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  bool _isDiaryMonthInRange(DateTime month) {
    final ym = month.year * 12 + month.month;
    final minYm = _diaryMinMonth.year * 12 + _diaryMinMonth.month;
    final maxYm = _diaryMaxMonth.year * 12 + _diaryMaxMonth.month;
    return ym >= minYm && ym <= maxYm;
  }

  DateTime _clampDiaryMonth(DateTime month) {
    if (month.isBefore(_diaryMinMonth)) return _diaryMinMonth;
    if (month.year > _diaryMaxMonth.year ||
        (month.year == _diaryMaxMonth.year &&
            month.month > _diaryMaxMonth.month)) {
      return _diaryMaxMonth;
    }
    return DateTime(month.year, month.month, 1);
  }

  // 보이는 월의 meal_logs 를 가져와 [_diaryLogsByDate] 캐시를 갱신한다.
  // 도장 표시는 "아점/저녁 중 하나라도 있으면" 으로 판단하므로 키만 있으면 충분하다.
  Future<void> _fetchDiaryMonthLogs(DateTime month) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _diaryLogsByDate = {};
      _diaryLogsCachedMonthKey = null;
      return;
    }
    final start = _dateKey(_monthStart(month));
    final end = _dateKey(_monthEnd(month));
    try {
      final data = await supabase
          .from('meal_logs')
          .select(
            'id, user_id, user_pet_id, meal_date, meal_slot, result_type, affection_gain, image_path, memo, captured_at, created_at',
          )
          .eq('user_id', user.id)
          .gte('meal_date', start)
          .lte('meal_date', end);

      final rows = (data as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final byDate = <String, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final key = row['meal_date']?.toString();
        if (key == null || key.isEmpty) continue;
        byDate.putIfAbsent(key, () => []).add(row);
      }
      _diaryLogsByDate = byDate;
      _diaryLogsCachedMonthKey =
          '${month.year}-${month.month.toString().padLeft(2, '0')}';
    } catch (e) {
      debugPrint('fetch diary month logs failed: $e');
      _diaryLogsByDate = {};
      _diaryLogsCachedMonthKey = null;
    }
  }

  // Supabase Storage 의 image_path 를 10분짜리 signed URL 로 변환.
  // image_path 가 비어 있거나 signed URL 생성에 실패하면 null 반환.
  Future<String?> _signedMealPhotoUrl(String? imagePath) async {
    if (imagePath == null || imagePath.trim().isEmpty) return null;
    try {
      final url = await supabase.storage
          .from(_kMealPhotoBucket)
          .createSignedUrl(imagePath, 60 * 10);
      return url;
    } catch (e) {
      debugPrint('signed meal photo url failed: $e');
      return null;
    }
  }

  // 특정 날짜의 체중/식후 감정(노트)을 meal_diary_notes 에서 조회.
  // row 가 없으면 null.
  //
  // ※ 사전 DB 전제: meal_diary_notes 테이블이 존재해야 한다.
  //   없으면 select 자체가 에러를 던지므로, 이번 메뉴를 본격적으로 사용하기 전에
  //   Supabase SQL 에서 한 번만 아래 비슷한 SQL 을 실행해두는 것이 필요하다.
  //     create table if not exists public.meal_diary_notes (
  //       id uuid primary key default gen_random_uuid(),
  //       user_id uuid not null references auth.users(id) on delete cascade,
  //       diary_date date not null,
  //       weight_kg numeric,
  //       note_text text,
  //       created_at timestamptz default now(),
  //       updated_at timestamptz default now(),
  //       unique(user_id, diary_date)
  //     );
  Future<Map<String, dynamic>?> _fetchMealDiaryNote(String dateKey) async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    try {
      final data = await supabase
          .from('meal_diary_notes')
          .select('id, user_id, diary_date, weight_kg, note_text')
          .eq('user_id', user.id)
          .eq('diary_date', dateKey)
          .maybeSingle();
      return data == null ? null : Map<String, dynamic>.from(data);
    } catch (e) {
      debugPrint('fetch meal diary note failed: $e');
      return null;
    }
  }

  // meal_diary_notes upsert.
  // 체중은 빈 문자열이면 null 저장, 숫자 파싱 실패 시 false 반환.
  // note_text 는 trim 후 빈 문자열이면 null 저장.
  Future<bool> _saveMealDiaryNote({
    required DateTime date,
    required String? weightText,
    required String noteText,
  }) async {
    final l10n = AppLocalizations.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack(l10n.snackLoginRequired);
      return false;
    }

    double? weight;
    final wRaw = (weightText ?? '').trim();
    if (wRaw.isNotEmpty) {
      final parsed = double.tryParse(wRaw.replaceAll(',', '.'));
      if (parsed == null) {
        _showSnack(l10n.snackWeightNumberOnly);
        return false;
      }
      weight = parsed;
    }

    final dateKey = _dateKey(date);
    final note = noteText.trim();

    try {
      await supabase.from('meal_diary_notes').upsert({
        'user_id': user.id,
        'diary_date': dateKey,
        'weight_kg': weight,
        'note_text': note.isEmpty ? null : note,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,diary_date');
      return true;
    } catch (e) {
      _showSnack(l10n.snackDiarySaveFailed(e.toString()));
      return false;
    }
  }

  // 식단 사진을 Dialog 위에 크게 띄워서 보여준다.
  // - InteractiveViewer 로 핀치/드래그 확대 가능
  // - 바깥 터치 또는 우상단 X 로 닫기
  Future<void> _showMealPhotoPreview(String imageUrl) async {
    if (!mounted) return;
    await showDialog<void>(
      context: _rootNavigatorKey.currentContext ?? context,
      barrierDismissible: true,
      useRootNavigator: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Text(
                        '사진을 불러올 수 없어요.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 식단일지 달력 모드 (게임 메뉴 와이어프레임) ----------
  Widget _buildDietDiaryCalendar({
    required BuildContext sheetContext,
    required Map<String, List<Map<String, dynamic>>> diaryLogsByDate,
    required DateTime visibleMonth,
    required Future<void> Function() onPrevMonth,
    required Future<void> Function() onNextMonth,
    required ValueChanged<DateTime> onTapDate,
  }) {
    const kBlack = Color(0xFF000000);
    const kMuted = Color(0xFF6A6A6A);
    const kSunday = Color(0xFF7E7E7E);
    const kDot = Color(0xFFFF0000);
    const diaryFontFallback = <String>['Courier New', 'Courier', 'monospace'];
    final mono = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: kBlack,
      fontFamily: 'Courier Prime',
      fontFamilyFallback: diaryFontFallback,
      height: 1.05,
    );
    final monoSunday = mono.copyWith(color: kSunday);

    final canPrev = _isDiaryMonthInRange(
      DateTime(visibleMonth.year, visibleMonth.month - 1, 1),
    );
    final canNext = _isDiaryMonthInRange(
      DateTime(visibleMonth.year, visibleMonth.month + 1, 1),
    );

    final daysInMonth = _daysInMonth(visibleMonth.year, visibleMonth.month);
    final firstWeekday =
        DateTime(visibleMonth.year, visibleMonth.month, 1).weekday % 7;

    final today = _todayDateStr();
    const weekdays = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    Widget cellAt(int r, int c) {
      final index = r * 7 + c;
      if (index < firstWeekday || index >= firstWeekday + daysInMonth) {
        return const SizedBox.expand();
      }
      final day = index - firstWeekday + 1;
      final date = DateTime(visibleMonth.year, visibleMonth.month, day);
      final dateKey = _dateKey(date);
      final hasMeal = (diaryLogsByDate[dateKey] ?? const []).isNotEmpty;
      final isToday = dateKey == today;
      final isSundayCol = c == 0;

      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onTapDate(date),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: isToday
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
                    )
                  : null,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$day',
                      style: isSundayCol ? monoSunday : mono,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: hasMeal ? 3 : 5),
                    if (hasMeal)
                      Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: kDot,
                          shape: BoxShape.circle,
                        ),
                      )
                    else
                      const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget bottomArrow({
      required IconData icon,
      required VoidCallback? onTap,
      required bool enabled,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              icon,
              size: 22,
              color: enabled ? kBlack : kMuted.withValues(alpha: 0.35),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var c = 0; c < 7; c++)
              Expanded(
                child: Center(
                  child: Text(
                    weekdays[c],
                    style: c == 0 ? monoSunday : mono,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Column(
            children: [
              for (var r = 0; r < 6; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var c = 0; c < 7; c++) Expanded(child: cellAt(r, c)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Transform.translate(
          offset: const Offset(0, -2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              bottomArrow(
                icon: Icons.chevron_left,
                enabled: canPrev,
                onTap: () => unawaited(onPrevMonth()),
              ),
              Transform.translate(
                offset: const Offset(2, 0),
                child: bottomArrow(
                  icon: Icons.chevron_right,
                  enabled: canNext,
                  onTap: () => unawaited(onNextMonth()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- 식단일지 월 선택 모드 ----------
  Widget _buildDietDiaryMonthPicker({
    required BuildContext sheetContext,
    required int visibleYear,
    required int highlightYear,
    required int highlightMonth,
    required Future<void> Function(int year, int month) onPickMonth,
    required ValueChanged<int> onChangeYear,
    required VoidCallback onBack,
    bool compact = false,
  }) {
    final l10n = AppLocalizations.of(sheetContext);
    const kBlack = Color(0xFF000000);
    final canPrevYear = visibleYear > _diaryMinMonth.year;
    final canNextYear = visibleYear < _diaryMaxMonth.year;
    const monthLabels = <String>[
      'Jan.',
      'Feb.',
      'Mar.',
      'Apr.',
      'May.',
      'Jun.',
      'Jul.',
      'Aug.',
      'Sep.',
      'Oct.',
      'Nov.',
      'Dec.',
    ];

    Widget monthCell(int month) {
      final isSelected =
          visibleYear == highlightYear && month == highlightMonth;
      final enabled = _isDiaryMonthInRange(DateTime(visibleYear, month, 1));

      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled
              ? () => unawaited(onPickMonth(visibleYear, month))
              : null,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              padding: const EdgeInsets.fromLTRB(9, 4, 9, 6),
              decoration: BoxDecoration(
                gradient: isSelected
                    ? const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
                      )
                    : null,
                color: isSelected ? null : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                monthLabels[month - 1],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: enabled ? kBlack : kBlack.withValues(alpha: 0.25),
                  fontFamily: 'Pretendard',
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget yearArrow({
      required IconData icon,
      required bool enabled,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              icon,
              size: 22,
              color: enabled ? kBlack : kBlack.withValues(alpha: 0.35),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: Stack(
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onBack,
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
              Positioned(
                left: 37,
                top:
                    _kGameMenuSubPanelTitleTop +
                    (Localizations.localeOf(sheetContext).languageCode == 'en'
                        ? _kGameMenuSubPanelTitleTopEnOffset
                        : 0.0),
                right: 8,
                child: Text(
                  l10n.dietDiaryPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF000000),
                    height: 1.0,
                    fontFamily: 'Pretendard',
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 2),
                Text(
                  '$visibleYear',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: kBlack,
                    height: 1.0,
                    fontFamily: 'Pretendard',
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Column(
                    children: [
                      for (var r = 0; r < 4; r++)
                        Expanded(
                          child: Row(
                            children: [
                              for (var c = 0; c < 3; c++)
                                Expanded(child: monthCell(r * 3 + c + 1)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Transform.translate(
                  offset: const Offset(0, -2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      yearArrow(
                        icon: Icons.chevron_left,
                        enabled: canPrevYear,
                        onTap: () => onChangeYear(visibleYear - 1),
                      ),
                      Transform.translate(
                        offset: const Offset(2, 0),
                        child: yearArrow(
                          icon: Icons.chevron_right,
                          enabled: canNextYear,
                          onTap: () => onChangeYear(visibleYear + 1),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildMealButton({
    required String label,
    required bool done,
    required VoidCallback? onPressed,
  }) {
    if (done) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: Text('$label · 완료'),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: _isLoggingMeal
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.restaurant, size: 18),
      label: Text(label),
    );
  }

  // ---------- 프로필 입력 (미완성 상태) ----------

  Widget _buildProfileFormContent() {
    final l10n = AppLocalizations.of(context);
    // TODO(vegepet): Pretendard 폰트 asset 등록 후 fontFamily를 명시적으로 연결.
    const titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const fieldTextStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      height: 1.0,
    );

    Widget iosFieldShell({required Widget child}) {
      return Container(
        width: 176,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE6E6E6), width: 1),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      );
    }

    Widget row({
      required double top,
      required String label,
      required Widget field,
      double? labelFontSize,
    }) {
      final rowLabelStyle = labelFontSize == null
          ? labelStyle
          : labelStyle.copyWith(fontSize: labelFontSize);
      return Positioned(
        top: top,
        left: 0,
        width: 244,
        height: 26,
        child: Row(
          children: [
            SizedBox(
              width: 60,
              child: Text(
                label,
                textAlign: TextAlign.left,
                style: rowLabelStyle,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 176, height: 26, child: field),
          ],
        ),
      );
    }

    return SizedBox(
      width: 244,
      height: 196,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Text(
              l10n.profileSetupTitle,
              textAlign: TextAlign.left,
              style: titleStyle,
            ),
          ),
          row(
            top: 30,
            label: l10n.nickname,
            field: iosFieldShell(
              child: _buildKeyboardAccessoryTriggerField(
                key: 'profile_nickname',
                controller: _nicknameController,
                sourceFocusNode: _nicknameFocusNode,
                keyboardType: TextInputType.text,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(
                    _kProfileNicknameMaxLength,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  ),
                ],
                style: fieldTextStyle,
                maxLines: 1,
                padding: EdgeInsets.zero,
                decoration: const BoxDecoration(color: Colors.transparent),
              ),
            ),
          ),
          row(
            top: 60,
            label: l10n.gender,
            field: _buildCompactProfileSelect(
              selectKey: 'gender',
              value: _selectedGender,
              options: _genderOptions,
              enabled: !_isSavingProfile,
              optionLabelBuilder: (v) => _localizedGenderValue(v, l10n),
              onChanged: (value) => setState(() => _selectedGender = value),
            ),
          ),
          row(
            top: 90,
            label: l10n.ageRange,
            labelFontSize: _isEnglishLocale ? 10 : null,
            field: _buildCompactProfileSelect(
              selectKey: 'ageRange',
              value: _selectedAgeRange,
              options: _ageRangeOptions,
              enabled: !_isSavingProfile,
              optionLabelBuilder: (v) => _localizedAgeRangeValue(v, l10n),
              onChanged: (value) => setState(() => _selectedAgeRange = value),
              englishFieldFontSize: _isEnglishLocale ? 9 : null,
            ),
          ),
          row(
            top: 120,
            label: l10n.dietGoal,
            field: _buildCompactProfileSelect(
              selectKey: 'dietGoal',
              value: _selectedDietGoal,
              options: _dietGoalOptions,
              enabled: !_isSavingProfile,
              optionLabelBuilder: (v) => _localizedDietGoalValue(v, l10n),
              onChanged: (value) => setState(() => _selectedDietGoal = value),
            ),
          ),
          Positioned(
            top: 158,
            left: 0,
            width: 244,
            height: 36,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFF1F1F1), width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: TextButton(
                onPressed: _isSavingProfile ? null : _saveProfile,
                style: TextButton.styleFrom(
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: EdgeInsets.zero,
                ),
                child: _isSavingProfile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFA8C9FF),
                        ),
                      )
                    : _buildPastelBlueGradientButtonText(
                        '${l10n.start}!',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 디버그 섹션 ----------

  List<Widget> _debugExpansionTileChildren() {
    final user = supabase.auth.currentUser;

    return [
      _debugBlock(
        title: 'Auth',
        children: [
          _kv('user id', user?.id ?? '-'),
          _kv('email', user?.email ?? '(없음)'),
        ],
      ),
      const SizedBox(height: 12),
      _debugBlock(title: 'profiles', children: _buildProfileRows()),
      const SizedBox(height: 12),
      _debugBlock(title: 'active user_pet', children: _buildActivePetRows()),
      const SizedBox(height: 12),
      _debugBlock(
        title: 'today meal_logs (${_todayMealLogs.length}개)',
        children: _buildTodayMealRows(),
      ),
      const SizedBox(height: 12),
      _debugBlock(
        title: 'last AI meal evaluation',
        children: _buildLastAiResultRows(),
      ),
      const SizedBox(height: 12),
      _debugBlock(
        title: 'pet_species',
        children: [
          _kv('count', '${_petSpecies.length}종'),
          _kv(
            'cat',
            '${_petSpecies.where((s) => s['family'] == 'cat').length}종',
          ),
          _kv(
            'dog',
            '${_petSpecies.where((s) => s['family'] == 'dog').length}종',
          ),
        ],
      ),
      const SizedBox(height: 12),
      _debugBlock(
        title: 'user_items',
        children: [
          _kv('random_adoption_ticket (DB)', '$_randomTicketCount장'),
          _kv(
            'random_adoption_ticket (가방 UI)',
            '${_effectiveRandomTicketCountForBag()}장',
          ),
        ],
      ),
      const SizedBox(height: 12),
      _debugBlock(
        title: 'pokedex',
        children: [_kv('loaded entries', '${_pokedexEntries.length}개')],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _refreshProfile,
            icon: const Icon(Icons.person_outline, size: 18),
            label: const Text('프로필 다시 조회'),
          ),
          OutlinedButton.icon(
            onPressed: _refreshActivePet,
            icon: const Icon(Icons.pets, size: 18),
            label: const Text('펫 정보 다시 조회'),
          ),
          OutlinedButton.icon(
            onPressed: _refreshSpecies,
            icon: const Icon(Icons.pets_outlined, size: 18),
            label: const Text('펫 목록 다시 조회'),
          ),
          OutlinedButton.icon(
            onPressed: _refreshAll,
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('전체 새로고침'),
          ),
          OutlinedButton.icon(
            onPressed: _signOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('로그아웃'),
          ),
          OutlinedButton.icon(
            onPressed: _resetForTesting,
            icon: const Icon(Icons.delete_forever, size: 18),
            label: const Text('개발용 전체 초기화'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        '성장 단계 테스트',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.grey,
        ),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _activePet == null
                ? null
                : () => _debugAdjustAffection(10),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('애정도 +10'),
          ),
          OutlinedButton.icon(
            onPressed: _activePet == null
                ? null
                : () => _debugAdjustAffection(50),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('애정도 +50'),
          ),
          OutlinedButton.icon(
            onPressed: _activePet == null ? null : _debugSetJustBeforeAdult,
            icon: const Icon(Icons.hourglass_bottom, size: 18),
            label: const Text('성숙기 직전 세팅(aff 109 / grown)'),
          ),
          OutlinedButton.icon(
            onPressed: _activePet == null ? null : _debugTriggerAdult,
            icon: const Icon(Icons.emoji_events_outlined, size: 18),
            label: const Text('성숙기 테스트 실행 (+1)'),
          ),
          OutlinedButton.icon(
            onPressed: _debugRefreshRandomTicket,
            icon: const Icon(Icons.confirmation_number_outlined, size: 18),
            label: const Text('랜덤 분양권 다시 조회'),
          ),
          OutlinedButton.icon(
            onPressed: _randomTicketCount > 0
                ? _debugUseRandomAdoptionTicket
                : null,
            icon: const Icon(Icons.card_giftcard_outlined, size: 18),
            label: const Text('랜덤 분양권 사용 테스트'),
          ),
        ],
      ),
    ];
  }

  Widget _buildDebugSection({
    bool useOuterCard = true,
    bool hideExpansionHeader = false,
  }) {
    final inner = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: _debugExpanded,
        onExpansionChanged: (v) => setState(() => _debugExpanded = v),
        leading: hideExpansionHeader
            ? null
            : const Icon(Icons.bug_report_outlined),
        title: hideExpansionHeader
            ? const SizedBox.shrink()
            : const Text(
                '개발 확인용 디버그',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
        subtitle: hideExpansionHeader
            ? null
            : const Text('앱 사용자에게는 보이지 않을 영역', style: TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: _debugExpansionTileChildren(),
      ),
    );
    if (!useOuterCard) return inner;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: inner,
    );
  }

  List<Widget> _buildProfileRows() {
    if (_profile == null) {
      return [const Text('프로필이 아직 없어요.', style: TextStyle(color: Colors.grey))];
    }

    final p = _profile!;
    final accountType = p['account_type']?.toString() ?? '-';
    final rows = <Widget>[
      _kv('id', p['id']?.toString() ?? '-'),
      _kv('email', p['email']?.toString() ?? '(없음)'),
      _kv('nickname', p['nickname']?.toString() ?? '(없음)'),
      _kv('gender', p['gender']?.toString() ?? '(없음)'),
      _kv('age_range', p['age_range']?.toString() ?? '(없음)'),
      _kv('diet_goal', p['diet_goal']?.toString() ?? '(없음)'),
      _kv('account_type', accountType),
      _kv('gold_balance', p['gold_balance']?.toString() ?? '-'),
      _kv('linked_at', p['linked_at']?.toString() ?? '(null)'),
      _kv('created_at', p['created_at']?.toString() ?? '-'),
      _kv('updated_at', p['updated_at']?.toString() ?? '-'),
      _kv('profile_complete', _isProfileComplete() ? 'true' : 'false'),
    ];

    if (accountType == 'guest') {
      rows.add(const SizedBox(height: 8));
      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '게스트 체험 계정 확인 완료',
            style: TextStyle(
              fontSize: 12,
              color: Colors.green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return rows;
  }

  List<Widget> _buildActivePetRows() {
    if (_activePet == null) {
      return [
        const Text(
          '아직 active user_pet이 없어요.',
          style: TextStyle(color: Colors.grey),
        ),
      ];
    }

    final pet = _activePet!;
    final species = pet['pet_species'] is Map
        ? Map<String, dynamic>.from(pet['pet_species'] as Map)
        : const <String, dynamic>{};

    return [
      _kv('id', pet['id']?.toString() ?? '-'),
      _kv('pet_species_id', pet['pet_species_id']?.toString() ?? '-'),
      _kv('species.name_ko', species['name_ko']?.toString() ?? '-'),
      _kv('species.family', species['family']?.toString() ?? '-'),
      _kv('nickname', pet['nickname']?.toString() ?? '(없음)'),
      _kv('stage', pet['stage']?.toString() ?? '-'),
      _kv('affection', pet['affection']?.toString() ?? '-'),
      _kv('is_active', pet['is_active']?.toString() ?? '-'),
      _kv('is_resident', pet['is_resident']?.toString() ?? '-'),
      _kv('last_played_on', pet['last_played_on']?.toString() ?? '(null)'),
      _kv('last_petted_on', pet['last_petted_on']?.toString() ?? '(null)'),
      _kv('graduated_at', pet['graduated_at']?.toString() ?? '(null)'),
      _kv('created_at', pet['created_at']?.toString() ?? '-'),
    ];
  }

  List<Widget> _buildTodayMealRows() {
    final today = _todayDateStr();
    final brunch = _todayMealLogs.where((m) => m['meal_slot'] == 'brunch');
    final dinner = _todayMealLogs.where((m) => m['meal_slot'] == 'dinner');

    return [
      _kv('meal_date', today),
      _kv('brunch', brunch.isEmpty ? '대기중' : '완료'),
      _kv('dinner', dinner.isEmpty ? '대기중' : '완료'),
      _kv(
        'first_popup_shown',
        _firstMealPopupShownThisSession ? 'true (이번 세션)' : 'false',
      ),
    ];
  }

  List<Widget> _buildLastAiResultRows() {
    if (_lastResultType == null && _lastStatusMessage == null) {
      return const [
        Text('아직 AI 판정 기록이 없어요.', style: TextStyle(color: Colors.grey)),
      ];
    }

    return [
      _kv('result_type', _lastResultType ?? '(null)'),
      _kv(
        'feedback_text',
        (_lastFeedbackText == null || _lastFeedbackText!.isEmpty)
            ? '(null)'
            : _lastFeedbackText!,
      ),
      _kv('affection_gain', _lastAffectionGain?.toString() ?? '-'),
      _kv('status_message', _lastStatusMessage ?? '-'),
      _kv('image_path', _lastImagePath ?? '-'),
    ];
  }

  // ---------- 공통 유틸 ----------

  /// 현재 적용된 앱 locale 이 영어인지 확인. fontSize/창 높이/문구 분기에 사용한다.
  /// 한국어 UI는 기존 동작을 그대로 유지하고, 영어 UI 만 보정한다.
  bool get _isEnglishLocale {
    return Localizations.localeOf(context).languageCode == 'en';
  }

  double get _gameMenuSubPanelTitleTop =>
      _kGameMenuSubPanelTitleTop +
      (_isEnglishLocale ? _kGameMenuSubPanelTitleTopEnOffset : 0.0);

  /// DB/내부 raw 값 → 화면 표시용. 저장·AI context에는 raw 를 그대로 쓴다.
  String _localizedGenderValue(String? raw, AppLocalizations l10n) {
    final value = raw?.trim() ?? '';
    if (!_isEnglishLocale) return value;

    switch (value) {
      case '여자':
        return 'Female';
      case '남자':
        return 'Male';
      default:
        return value;
    }
  }

  String _localizedAgeRangeValue(String? raw, AppLocalizations l10n) {
    final value = raw?.trim() ?? '';
    if (!_isEnglishLocale) return value;

    switch (value) {
      case '10대':
        return 'Teens';
      case '20대':
        return '20s';
      case '30대':
        return '30s';
      case '40대':
        return '40s';
      case '50대':
        return '50s';
      default:
        return value;
    }
  }

  String _localizedDietGoalValue(String? raw, AppLocalizations l10n) {
    final value = raw?.trim() ?? '';
    if (!_isEnglishLocale) return value;

    switch (value) {
      case '다이어트':
        return 'Weight Loss';
      case '근력향상':
        return 'Muscle Gain';
      case '혈당조정':
        return 'Blood Sugar Control';
      default:
        return value;
    }
  }

  /// pet_species.name_ko 기반 종류명 표시. 정보창 Type·도감 종 이름에 사용.
  /// family(강아지/고양이) 분류는 [_normalizePetFamily] · [_familyToKorean] 등에 사용.
  /// 추후 name_en 컬럼이 생기면 여기서 우선 적용하도록 확장 가능.
  String _localizedPetSpeciesNameFromRaw({
    required String? nameKo,
    String? family,
    String? code,
  }) {
    final rawName = nameKo?.trim() ?? '';
    if (!_isEnglishLocale) return rawName;

    final lowerFamily = family?.trim().toLowerCase() ?? '';
    final lowerCode = code?.trim().toLowerCase() ?? '';

    int? number;
    final numberMatch = RegExp(r'(\d+)$').firstMatch(rawName);
    if (numberMatch != null) {
      number = int.tryParse(numberMatch.group(1)!);
    }

    String familyLabel;
    if (rawName.contains('고양이') ||
        rawName.contains('냥') ||
        lowerFamily == 'cat' ||
        lowerCode.contains('cat')) {
      familyLabel = 'Cat';
    } else if (rawName.contains('강아지') ||
        rawName.contains('댕') ||
        lowerFamily == 'dog' ||
        lowerCode.contains('dog')) {
      familyLabel = 'Dog';
    } else {
      familyLabel = 'VegePet';
    }

    if (number != null) {
      return '$familyLabel $number';
    }

    if (rawName.isNotEmpty) {
      return familyLabel == 'VegePet' ? rawName : familyLabel;
    }

    return familyLabel;
  }

  String _familyToKorean(String family) {
    final l10n = AppLocalizations.of(context);
    switch (family) {
      case 'cat':
        return l10n.familyCat;
      case 'dog':
        return l10n.familyDog;
      default:
        return family;
    }
  }

  String _stageToKorean(String stage) {
    final l10n = AppLocalizations.of(context);
    switch (stage) {
      case 'baby':
        return l10n.stageBaby;
      case 'child':
        return l10n.stageChild;
      case 'grown':
        return l10n.stageGrown;
      case 'adult':
        return l10n.stageAdult;
      default:
        return stage;
    }
  }

  /// 메뉴 라벨 key → 현재 locale 표시 문자열.
  /// `_menuSheetItems` 의 String 슬롯은 안정적인 key 만 들고 다니며, 실제 표시는
  /// 이 함수에서 l10n 으로 매핑한다. onTap 분기도 key 기준으로 한다.
  String _menuLabelForKey(String key) {
    final l10n = AppLocalizations.of(context);
    switch (key) {
      case 'profile':
        return l10n.menuLabelProfile;
      case 'dietDiary':
        return l10n.menuLabelDietDiary;
      case 'bag':
        return l10n.menuLabelBag;
      case 'shop':
        return l10n.menuLabelShop;
      case 'pokedex':
        return l10n.menuLabelPokedex;
      case 'story':
        return l10n.menuLabelStory;
      case 'help':
        return l10n.menuLabelHelp;
      case 'settings':
        return l10n.menuLabelSettings;
      default:
        return key;
    }
  }

  /// 가방/놀아주기 아이템 표시명. _BagItem 의 name 슬롯에는 안정적인 code 가
  /// 들어가고, 실제 화면 표시 시점에만 l10n 으로 변환한다.
  String _localizedBagItemName(_BagItem item) {
    final l10n = AppLocalizations.of(context);
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

  String _localizedBagItemDescription(_BagItem item) {
    final l10n = AppLocalizations.of(context);
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

  Widget _debugBlock({required String title, required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              k,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _buildVegePetPastelBlueGradientButtonTextShared(
  String text, {
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.w600,
}) {
  // 영어 locale 의 descender (y/g/p) 가 그라데이션 클리핑으로 흰색이 되는 문제를
  // 막기 위해 height 를 1.15 로 키운다. 한국어는 descender 가 없어 시각 영향이 없다.
  return ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
    ).createShader(bounds),
    child: Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: Colors.white,
        height: 1.15,
      ),
    ),
  );
}

Widget _buildVegePetConfirmDialogShellShared({
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

// 게임 메뉴 가방 패널 / 놀아주기 드래그 등에서 쓰는 아이템 정보 모델.
//
// category 는 'ticket' | 'furniture' | 'toy' 중 하나.
class _BagItem {
  final String category;
  final String name;
  final String description;
  final int quantity;
  final IconData icon;
  // 사용하기 버튼 노출 여부. 분양권만 true 가 들어오고, 가구/장난감 등은 false.
  final bool usable;
  // toy 아이템의 종족 제한. 'dog' | 'cat' | null
  final String? targetPetFamily;

  const _BagItem({
    required this.category,
    required this.name,
    required this.description,
    required this.quantity,
    required this.icon,
    this.usable = false,
    this.targetPetFamily,
  });
}

// 펫 정보 BottomSheet 안의 애정도 경험치 바에서 사용하는 표시 정보.
//
// 다음 성장 단계까지의 진행도(progress: 0.0~1.0), 그 단계까지 남은 수치
// 표시용 라벨, 그리고 성숙기(adult) 도달 여부 플래그(isComplete) 를 함께 들고 다닌다.
//
// MVP 단계라 main.dart 한 파일 안에서만 쓰이므로 private 으로 둔다.
class _AffectionProgressInfo {
  const _AffectionProgressInfo({
    required this.current,
    required this.max,
    required this.progress,
    required this.label,
    required this.isComplete,
  });

  final int current;
  final int max;
  final double progress;
  final String label;
  final bool isComplete;
}

// ============================================================================
// 식단일지 본문 (달력 / 월·연도 선택 / 상세 모드)
// ----------------------------------------------------------------------------
// mode / visibleMonth / selectedDate 는 이 State 에서만 관리한다.
// 게임 메뉴 글래스 패널에 embed 할 때는 [embeddedInGameMenuPanel] 로 레이아웃만 분기한다.
// ============================================================================
class _DietDiarySheetPanel extends StatefulWidget {
  const _DietDiarySheetPanel({
    super.key,
    required this.initialMonth,
    required this.clampMonth,
    required this.isMonthInRange,
    required this.fetchMonthLogs,
    required this.logsByDateProvider,
    required this.dateKey,
    required this.onMonthChanged,
    required this.onSavedSuccess,
    required this.signedUrlBuilder,
    required this.onPhotoTap,
    required this.fetchNote,
    required this.saveNote,
    required this.calendarBuilder,
    required this.monthPickerBuilder,
    this.bindKeyboardInput,
    this.buildKeyboardTriggerField,
    this.embeddedInGameMenuPanel = false,
    this.onEmbeddedBack,
    this.monthYearCaptionBuilder,
  });

  final bool embeddedInGameMenuPanel;
  final VoidCallback? onEmbeddedBack;
  final String Function(DateTime month)? monthYearCaptionBuilder;

  final DateTime initialMonth;
  final DateTime Function(DateTime month) clampMonth;
  final bool Function(DateTime month) isMonthInRange;
  final Future<void> Function(DateTime month) fetchMonthLogs;
  final Map<String, List<Map<String, dynamic>>> Function() logsByDateProvider;
  final String Function(DateTime date) dateKey;
  final ValueChanged<DateTime> onMonthChanged;
  final VoidCallback onSavedSuccess;
  final Future<String?> Function(String? imagePath) signedUrlBuilder;
  final Future<void> Function(String imageUrl) onPhotoTap;
  final Future<Map<String, dynamic>?> Function(String dateKey) fetchNote;
  final Future<bool> Function({
    required DateTime date,
    required String? weightText,
    required String noteText,
  })
  saveNote;
  final void Function({
    required String key,
    required TextEditingController controller,
    required FocusNode focusNode,
    TextInputType keyboardType,
    List<TextInputFormatter> inputFormatters,
  })?
  bindKeyboardInput;
  final Widget Function({
    required String key,
    required TextEditingController controller,
    required FocusNode sourceFocusNode,
    required TextInputType keyboardType,
    List<TextInputFormatter> inputFormatters,
    bool enabled,
    required TextStyle style,
    int maxLines,
    String hintText,
    EdgeInsets padding,
    Alignment alignment,
  })?
  buildKeyboardTriggerField;
  final Widget Function(
    BuildContext sheetCtx,
    DateTime visibleMonth,
    Map<String, List<Map<String, dynamic>>> logsByDate,
    Future<void> Function() onPrevMonth,
    Future<void> Function() onNextMonth,
    ValueChanged<DateTime> onTapDate,
  )
  calendarBuilder;
  final Widget Function(
    BuildContext sheetCtx,
    int visibleYear,
    int highlightYear,
    int highlightMonth,
    Future<void> Function(int year, int month) onPickMonth,
    ValueChanged<int> onChangeYear,
    VoidCallback onBack,
    bool compact,
  )
  monthPickerBuilder;

  @override
  State<_DietDiarySheetPanel> createState() => _DietDiarySheetPanelState();
}

class _DietDiarySheetPanelState extends State<_DietDiarySheetPanel> {
  late DateTime visibleMonth;
  String mode = 'calendar'; // 'calendar' | 'monthPicker' | 'detail'
  DateTime? selectedDate;
  bool sheetLoading = false;
  final GlobalKey<_DietDiaryDetailPanelState> _detailPanelKey =
      GlobalKey<_DietDiaryDetailPanelState>();

  @override
  void initState() {
    super.initState();
    visibleMonth = widget.initialMonth;
  }

  Future<void> reloadMonth(
    DateTime newMonth, {
    bool showHeaderLoading = true,
  }) async {
    final clamped = widget.clampMonth(newMonth);
    setState(() {
      visibleMonth = clamped;
      if (showHeaderLoading) sheetLoading = true;
    });
    await widget.fetchMonthLogs(clamped);
    widget.onMonthChanged(clamped);
    if (!mounted) return;
    if (showHeaderLoading) {
      setState(() {
        sheetLoading = false;
      });
    }
  }

  Future<void> _moveDetailDate(int deltaDays) async {
    final current = selectedDate;
    if (current == null) return;
    final nextDate = current.add(Duration(days: deltaDays));
    final nextMonth = DateTime(nextDate.year, nextDate.month, 1);
    final isMonthChanged =
        visibleMonth.year != nextMonth.year ||
        visibleMonth.month != nextMonth.month;
    if (isMonthChanged) {
      await reloadMonth(nextMonth, showHeaderLoading: false);
      if (!mounted) return;
    }
    setState(() {
      selectedDate = nextDate;
    });
  }

  Future<bool> handleOutsideDismiss() async {
    if (mode != 'detail' || selectedDate == null) return false;
    final ok = await _detailPanelKey.currentState?.saveForPanelExit() ?? true;
    if (!mounted) return true;
    if (ok) {
      setState(() {
        mode = 'calendar';
        selectedDate = null;
      });
    }
    return true;
  }

  Widget _detailBottomArrow({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 22, color: const Color(0xFF000000)),
        ),
      ),
    );
  }

  Future<void> _handleDetailBackToCalendar() async {
    if (mode != 'detail' || selectedDate == null) {
      widget.onEmbeddedBack?.call();
      return;
    }
    final ok = await _detailPanelKey.currentState?.saveForPanelExit() ?? true;
    if (!mounted || !ok) return;
    setState(() {
      mode = 'calendar';
      selectedDate = null;
    });
  }

  String _formatDetailHeaderCaption(DateTime d) {
    final raw = DateFormat('MMM', 'en_US').format(d);
    final mon = raw.endsWith('.') ? raw : '$raw.';
    final yy = (d.year % 100).toString().padLeft(2, '0');
    return '${d.day}. $mon $yy';
  }

  @override
  Widget build(BuildContext context) {
    final logs = widget.logsByDateProvider();

    Widget body;
    if (mode == 'monthPicker') {
      body = widget.monthPickerBuilder(
        context,
        visibleMonth.year,
        visibleMonth.year,
        visibleMonth.month,
        (year, month) async {
          setState(() => mode = 'calendar');
          await reloadMonth(DateTime(year, month, 1), showHeaderLoading: false);
        },
        (newYear) {
          setState(() {
            visibleMonth = DateTime(newYear, visibleMonth.month, 1);
          });
        },
        () => setState(() => mode = 'calendar'),
        widget.embeddedInGameMenuPanel,
      );
    } else if (mode == 'detail' && selectedDate != null) {
      final dk = widget.dateKey(selectedDate!);
      final dayLogs = List<Map<String, dynamic>>.from(logs[dk] ?? const []);
      body = _DietDiaryDetailPanel(
        key: _detailPanelKey,
        date: selectedDate!,
        logs: dayLogs,
        bindKeyboardInput: widget.bindKeyboardInput,
        buildKeyboardTriggerField: widget.buildKeyboardTriggerField,
        signedUrlBuilder: widget.signedUrlBuilder,
        onPhotoTap: widget.onPhotoTap,
        fetchNote: widget.fetchNote,
        saveNote: widget.saveNote,
        onMoveDate: _moveDetailDate,
        onSavedSuccess: widget.onSavedSuccess,
      );
    } else {
      body = widget.calendarBuilder(
        context,
        visibleMonth,
        logs,
        () async {
          final prev = DateTime(visibleMonth.year, visibleMonth.month - 1, 1);
          if (!widget.isMonthInRange(prev)) return;
          await reloadMonth(prev, showHeaderLoading: false);
        },
        () async {
          final next = DateTime(visibleMonth.year, visibleMonth.month + 1, 1);
          if (!widget.isMonthInRange(next)) return;
          await reloadMonth(next, showHeaderLoading: false);
        },
        (date) {
          setState(() {
            selectedDate = date;
            mode = 'detail';
          });
        },
      );
    }

    if (widget.embeddedInGameMenuPanel) {
      final l10n = AppLocalizations.of(context);
      final isEnglish =
          Localizations.localeOf(context).languageCode == 'en';
      final embeddedTitleTop =
          _kGameMenuSubPanelTitleTop +
          (isEnglish ? _kGameMenuSubPanelTitleTopEnOffset : 0.0);
      final caption = widget.monthYearCaptionBuilder!(visibleMonth);
      Widget embeddedHeader({
        required String rightCaption,
        required VoidCallback? onCaptionTap,
        VoidCallback? onBackTap,
        bool showLoading = false,
      }) {
        return SizedBox(
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 9,
                top: 9,
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onBackTap ?? widget.onEmbeddedBack,
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
              Positioned(
                left: 37,
                top: embeddedTitleTop,
                right: 8,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        l10n.dietDiaryPanelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF000000),
                          height: 1.0,
                        ),
                      ),
                    ),
                    if (showLoading)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 11, top: 7),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: onCaptionTap,
                          child: Text(
                            rightCaption,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF000000),
                              fontFamily: 'Courier Prime',
                              fontFamilyFallback: [
                                'Courier New',
                                'Courier',
                                'monospace',
                              ],
                              height: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      Widget embeddedContent;
      if (mode == 'calendar') {
        embeddedContent = Column(
          key: const ValueKey('diet-diary-calendar'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            embeddedHeader(
              rightCaption: caption,
              onCaptionTap: () => setState(() => mode = 'monthPicker'),
              onBackTap: widget.onEmbeddedBack,
              showLoading: sheetLoading,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                child: body,
              ),
            ),
          ],
        );
      } else if (mode == 'monthPicker') {
        embeddedContent = KeyedSubtree(
          key: const ValueKey('diet-diary-month-picker'),
          child: body,
        );
      } else {
        embeddedContent = Column(
          key: const ValueKey('diet-diary-detail'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            embeddedHeader(
              rightCaption: _formatDetailHeaderCaption(selectedDate!),
              onCaptionTap: null,
              onBackTap: () => unawaited(_handleDetailBackToCalendar()),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: body,
              ),
            ),
            const SizedBox(height: 2),
            Transform.translate(
              offset: const Offset(0, -2),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _detailBottomArrow(
                      icon: Icons.chevron_left,
                      onTap: () => unawaited(
                        _detailPanelKey.currentState?.movePrevDay() ??
                            Future<void>.value(),
                      ),
                    ),
                    Transform.translate(
                      offset: const Offset(2, 0),
                      child: _detailBottomArrow(
                        icon: Icons.chevron_right,
                        onTap: () => unawaited(
                          _detailPanelKey.currentState?.moveNextDay() ??
                              Future<void>.value(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      body = AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final offsetTween = Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          );
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: animation.drive(offsetTween),
              child: child,
            ),
          );
        },
        child: embeddedContent,
      );

      return SizedBox(
        width: 246,
        height: 310,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          removeTop: true,
          child: body,
        ),
      );
    }

    return SafeArea(
      top: false,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: body,
        ),
      ),
    );
  }
}

// ============================================================================
// 식단일지 상세 패널 (특정 날짜의 아점/저녁 사진 + 체중/노트 입력)
// ----------------------------------------------------------------------------
// 책임:
//   - 체중/노트 TextEditingController 의 수명 관리 (initState/dispose)
//   - props 로 받은 fetchNote 로 초기값 로딩, saveNote 로 저장
//   - 사진 클릭 시 onPhotoTap 으로 미리보기 위임 (signed URL 변환은 props)
//
// 비책임:
//   - HomePage 의 _diaryLogsByDate 자체를 직접 수정하지 않는다 (logs 는 snapshot)
//   - showDialog 직접 호출은 미리보기 한 곳뿐이고 모두 props 로 위임
// ============================================================================
class _DietDiaryDetailPanel extends StatefulWidget {
  const _DietDiaryDetailPanel({
    super.key,
    required this.date,
    required this.logs,
    this.bindKeyboardInput,
    required this.signedUrlBuilder,
    required this.onPhotoTap,
    required this.fetchNote,
    required this.saveNote,
    required this.onMoveDate,
    required this.onSavedSuccess,
    this.buildKeyboardTriggerField,
  });

  final DateTime date;
  final List<Map<String, dynamic>> logs;
  final void Function({
    required String key,
    required TextEditingController controller,
    required FocusNode focusNode,
    TextInputType keyboardType,
    List<TextInputFormatter> inputFormatters,
  })?
  bindKeyboardInput;
  final Widget Function({
    required String key,
    required TextEditingController controller,
    required FocusNode sourceFocusNode,
    required TextInputType keyboardType,
    List<TextInputFormatter> inputFormatters,
    bool enabled,
    required TextStyle style,
    int maxLines,
    String hintText,
    EdgeInsets padding,
    Alignment alignment,
  })?
  buildKeyboardTriggerField;
  final Future<String?> Function(String? imagePath) signedUrlBuilder;
  final Future<void> Function(String imageUrl) onPhotoTap;
  final Future<Map<String, dynamic>?> Function(String dateKey) fetchNote;
  final Future<bool> Function({
    required DateTime date,
    required String? weightText,
    required String noteText,
  })
  saveNote;
  final Future<void> Function(int deltaDays) onMoveDate;
  final VoidCallback onSavedSuccess;

  @override
  State<_DietDiaryDetailPanel> createState() => _DietDiaryDetailPanelState();
}

class _DietDiaryDetailPanelState extends State<_DietDiaryDetailPanel> {
  static const String _diaryFontFamily = 'Pretendard';
  static const List<String> _diaryFontFallback = <String>['sans-serif'];
  static final TextInputFormatter _weightFormatter =
      TextInputFormatter.withFunction((oldValue, newValue) {
        final text = newValue.text;
        if (text.isEmpty) return newValue;
        if (text.length > 6) return oldValue;
        if (!RegExp(r'^[0-9.]+$').hasMatch(text)) return oldValue;
        if ('.'.allMatches(text).length > 1) return oldValue;
        return newValue;
      });

  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _weightFocusNode = FocusNode();
  final FocusNode _noteFocusNode = FocusNode();

  bool _isLoadingNote = true;
  bool _isSaving = false;
  bool _isMovingDay = false;
  String? _brunchUrl;
  String? _dinnerUrl;
  String _lastSavedWeightText = '';
  String _lastSavedNoteText = '';

  @override
  void initState() {
    super.initState();
    _weightFocusNode.canRequestFocus = false;
    _noteFocusNode.canRequestFocus = false;
    widget.bindKeyboardInput?.call(
      key: 'diet_weight',
      controller: _weightController,
      focusNode: _weightFocusNode,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_weightFormatter],
    );
    widget.bindKeyboardInput?.call(
      key: 'diet_note',
      controller: _noteController,
      focusNode: _noteFocusNode,
      keyboardType: TextInputType.multiline,
      inputFormatters: [
        LengthLimitingTextInputFormatter(
          64,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
        ),
      ],
    );
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant _DietDiaryDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    _weightFocusNode.dispose();
    _noteFocusNode.dispose();
    _weightController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  String _dateKey(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Map<String, dynamic>? _logForSlot(String slot) {
    for (final row in widget.logs) {
      if (row['meal_slot']?.toString() == slot) return row;
    }
    return null;
  }

  Future<void> _bootstrap() async {
    setState(() {
      _isLoadingNote = true;
      _brunchUrl = null;
      _dinnerUrl = null;
    });
    final brunch = _logForSlot('brunch');
    final dinner = _logForSlot('dinner');

    final results = await Future.wait([
      widget.signedUrlBuilder(brunch?['image_path']?.toString()),
      widget.signedUrlBuilder(dinner?['image_path']?.toString()),
      widget.fetchNote(_dateKey(widget.date)),
    ]);

    if (!mounted) return;
    final brunchUrl = results[0] as String?;
    final dinnerUrl = results[1] as String?;
    final note = results[2] as Map<String, dynamic>?;

    if (note != null) {
      final w = note['weight_kg'];
      _weightController.text = w == null ? '' : w.toString();
      _noteController.text = note['note_text']?.toString() ?? '';
    } else {
      _weightController.clear();
      _noteController.clear();
    }

    _lastSavedWeightText = _weightController.text.trim();
    _lastSavedNoteText = _noteController.text.trim();

    setState(() {
      _brunchUrl = brunchUrl;
      _dinnerUrl = dinnerUrl;
      _isLoadingNote = false;
    });
  }

  bool get _hasUnsavedChanges {
    return _weightController.text.trim() != _lastSavedWeightText ||
        _noteController.text.trim() != _lastSavedNoteText;
  }

  Future<bool> saveForPanelExit({bool showSavingIndicator = true}) async {
    if (_isLoadingNote || _isSaving || !_hasUnsavedChanges) return true;
    if (showSavingIndicator) {
      setState(() => _isSaving = true);
    }
    final ok = await widget.saveNote(
      date: widget.date,
      weightText: _weightController.text,
      noteText: _noteController.text,
    );
    if (!mounted) return false;
    if (showSavingIndicator) {
      setState(() => _isSaving = false);
    }
    if (ok) {
      _lastSavedWeightText = _weightController.text.trim();
      _lastSavedNoteText = _noteController.text.trim();
      widget.onSavedSuccess();
    }
    return ok;
  }

  Future<void> _moveDay(int deltaDays) async {
    if (_isMovingDay || _isLoadingNote) return;
    _isMovingDay = true;
    try {
      final ok = await saveForPanelExit(showSavingIndicator: false);
      if (!mounted || !ok) return;
      await widget.onMoveDate(deltaDays);
    } finally {
      _isMovingDay = false;
    }
  }

  Future<void> movePrevDay() => _moveDay(-1);
  Future<void> moveNextDay() => _moveDay(1);

  Widget _diaryFieldShell({
    required Widget child,
    double height = 26,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 10),
    AlignmentGeometry alignment = Alignment.centerLeft,
  }) {
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6E6E6), width: 1),
      ),
      alignment: alignment,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    const labelBaseSize = 11.0;
    const labelStyle = TextStyle(
      fontSize: labelBaseSize,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      fontFamily: _diaryFontFamily,
      fontFamilyFallback: _diaryFontFallback,
      height: 1.0,
    );
    final isEnglish = Localizations.localeOf(context).languageCode == 'en';
    const fieldStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF4A4A4A),
      fontFamily: _diaryFontFamily,
      fontFamilyFallback: _diaryFontFallback,
      height: 1.2,
    );

    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _photoSlot(
                  label: AppLocalizations.of(context).diaryPhotoBrunchLabel,
                url: _brunchUrl,
              ),
              _photoSlot(
                label: AppLocalizations.of(context).diaryPhotoDinnerLabel,
                url: _dinnerUrl,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: isEnglish ? 76 : 62,
                child: Text(
                  AppLocalizations.of(context).diaryWeightLabel,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _diaryFieldShell(
                  child:
                      widget.buildKeyboardTriggerField?.call(
                        key: 'diet_weight',
                        controller: _weightController,
                        sourceFocusNode: _weightFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [_weightFormatter],
                        enabled: !_isSaving && !_isLoadingNote,
                        style: fieldStyle,
                        maxLines: 1,
                        hintText: '',
                        padding: EdgeInsets.zero,
                        alignment: Alignment.centerLeft,
                      ) ??
                      const SizedBox.shrink(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            AppLocalizations.of(context).diaryNoteLabel,
            style: labelStyle,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _diaryFieldShell(
              height: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              alignment: Alignment.topLeft,
              child:
                  widget.buildKeyboardTriggerField?.call(
                    key: 'diet_note',
                    controller: _noteController,
                    sourceFocusNode: _noteFocusNode,
                    keyboardType: TextInputType.multiline,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(
                        64,
                        maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      ),
                    ],
                    enabled: !_isSaving && !_isLoadingNote,
                    style: fieldStyle,
                    maxLines: 4,
                    hintText: '',
                    padding: EdgeInsets.zero,
                    alignment: Alignment.topLeft,
                  ) ??
                  const SizedBox.shrink(),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _photoSlot({required String label, required String? url}) {
    final hasPhoto = url != null && url.isNotEmpty;

    return SizedBox(
      width: 96,
      height: 96,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: hasPhoto ? () => widget.onPhotoTap(url) : null,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.40),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFD8D8D8), width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: hasPhoto
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Center(
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4A4A4A),
                            fontFamily: _diaryFontFamily,
                            fontFamilyFallback: _diaryFontFallback,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A4A4A),
                      fontFamily: _diaryFontFamily,
                      fontFamilyFallback: _diaryFontFallback,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
