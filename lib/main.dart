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

final Random _mealMessageRandom = Random();

/// AI 판정 결과 + 피드백 문장 → 앱에 표시할 최종 감성 메시지 1개를 만든다.
///
/// feedback_text가 비어 있거나 null 이면 fallback 메시지 세트에서 선택한다.
String _buildAiStatusMessage(String? resultType, String? feedbackText) {
  final feedback = feedbackText?.trim() ?? '';
  final hasFeedback = feedback.isNotEmpty;

  List<String> pickList;
  switch (resultType) {
    case 'good':
      pickList = _kGoodMessages;
      break;
    case 'supplement_needed':
      pickList = hasFeedback
          ? _kSupplementMessagesWithFeedback
          : _kSupplementMessagesFallback;
      break;
    case 'bad':
      pickList = hasFeedback ? _kBadMessagesWithFeedback : _kBadMessagesFallback;
      break;
    case 'uncertain':
    default:
      return _kUncertainMessage;
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

  await Supabase.initialize(
    url: _supabaseUrl,
    anonKey: _supabaseAnonKey,
  );

  runApp(const VegePetApp());
}

final supabase = Supabase.instance.client;

// 전역 Navigator / ScaffoldMessenger key.
//
// HomePage 의 일시적인 BuildContext 변화(프로필 입력 → 첫 분양 → 마당 화면 전환,
// BottomSheet/Dialog 트리 dispose 등) 와 SnackBar/Dialog 호출 타이밍이 겹치면
// `_dependents.isEmpty is not true` assertion 이 발생할 수 있다. 전역 key 를
// 통해 SnackBar 를 띄워서 화면 전환 타이밍과의 충돌을 줄인다.
final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>();
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
        supportedLocales: const [
          Locale('ko'),
          Locale('en'),
        ],
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
    final scope =
        context.dependOnInheritedWidgetOfExactType<_LocaleControllerScope>();
    assert(scope != null, 'LocaleControllerScope not found');
    return scope!;
  }

  @override
  bool updateShouldNotify(_LocaleControllerScope oldWidget) {
    return locale != oldWidget.locale;
  }
}

class _MealNotificationTexts {
  const _MealNotificationTexts({
    required this.title,
    required this.messages,
  });

  final String title;
  final List<String> messages;
}

enum _SupportDocType { terms, privacy, operation, guardian, dataDeletion }

class _SupportDocumentSection {
  const _SupportDocumentSection({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}

class _SupportDocument {
  const _SupportDocument({
    required this.title,
    required this.sections,
  });

  final String title;
  final List<_SupportDocumentSection> sections;
}

enum _ViewStatus { loading, error, ready }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const double _kGameCanvasWidth = 844;
  static const double _kGameCanvasHeight = 390;
  static const int _kProfileNicknameMaxLength = 8;

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
  // HomePage 쪽 [_diaryVisibleMonth] / [_diaryLogsByDate] 는 "마지막으로 본 월"과
  // 해당 월 meal_logs 캐시를 기억해, 시트를 닫았다가 다시 열 때 동일 월로
  // 복귀하기 위한 용도다. 앱 최초 식단일지 진입 시에만 오늘(KST)이 속한 월로
  // 시작한다 ([_hasOpenedDietDiary] 플래그).
  //
  // 범위: 2026-01 ~ 2035-12 (10년치)
  static final DateTime _diaryMinMonth = DateTime(2026, 1);
  static final DateTime _diaryMaxMonth = DateTime(2035, 12);

  DateTime _diaryVisibleMonth = DateTime(2026, 1);
  // 현재 _diaryVisibleMonth 의 meal_logs 캐시. 도장 표시용.
  // key: yyyy-MM-dd, value: 그 날짜의 meal_logs row 들.
  Map<String, List<Map<String, dynamic>>> _diaryLogsByDate = {};
  bool _isLoadingDiary = false;
  bool _hasOpenedDietDiary = false;
  bool _isToyMenuOpen = false;
  bool _isToyDropHovering = false;
  bool _isCompletingToyPlay = false;
  bool _isPetInfoBannerOpen = false;
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
  static const List<(IconData, String)> _menuSheetItems = [
    (Icons.person_outline, '프로필'),
    (Icons.event_note_outlined, '식단일지'),
    (Icons.backpack_outlined, '가방'),
    (Icons.storefront_outlined, '상점'),
    (Icons.menu_book_outlined, '도감'),
    (Icons.auto_stories_outlined, '스토리'),
    (Icons.help_outline, '도움말'),
    (Icons.settings_outlined, '설정'),
  ];

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(_enforceProfileNicknameMaxLength);
    _bootstrap();
  }

  @override
  void dispose() {
    _nicknameController.removeListener(_enforceProfileNicknameMaxLength);
    _profileSelectScrollController?.dispose();
    _closeProfileSelectOverlay(notify: false, animated: false);
    _emailOtpCooldownTimer?.cancel();
    _bgmPlayer.dispose();
    _sfxPlayer.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  bool _isProfileComplete() {
    final p = _profile;
    if (p == null) return false;
    bool nonEmpty(dynamic v) =>
        v != null && v.toString().trim().isNotEmpty;
    return nonEmpty(p['nickname']) &&
        nonEmpty(p['gender']) &&
        nonEmpty(p['age_range']) &&
        nonEmpty(p['diet_goal']);
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

    final truncated =
        text.characters.take(_kProfileNicknameMaxLength).toString();
    _nicknameController.value = TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _saveProfile() async {
    // 저장 시점에 키보드/입력 포커스가 살아 있으면 직후 화면 전환과 겹쳐
    // dispose 타이밍 오류가 날 수 있다. 먼저 포커스를 정리한다.
    _dismissFocus();
    await _closeProfileSelectOverlay(animated: true);

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }

    _enforceProfileNicknameMaxLength();
    final nickname = _nicknameController.text.trim();

    if (nickname.characters.length > _kProfileNicknameMaxLength) {
      final fixed =
          nickname.characters.take(_kProfileNicknameMaxLength).toString();
      _nicknameController.value = TextEditingValue(
        text: fixed,
        selection: TextSelection.collapsed(offset: fixed.length),
        composing: TextRange.empty,
      );
      _showSnack('닉네임은 8자까지만 입력할 수 있어요.');
      return;
    }

    if (nickname.isEmpty) {
      _showSnack('닉네임을 입력해주세요.');
      return;
    }
    if (_selectedGender == null) {
      _showSnack('성별을 선택해주세요.');
      return;
    }
    if (_selectedAgeRange == null) {
      _showSnack('나이대를 선택해주세요.');
      return;
    }
    if (_selectedDietGoal == null) {
      _showSnack('식단 목적을 선택해주세요.');
      return;
    }

    _safeSetState(() => _isSavingProfile = true);
    try {
      await supabase.from('profiles').update({
        'nickname': nickname,
        'gender': _selectedGender,
        'age_range': _selectedAgeRange,
        'diet_goal': _selectedDietGoal,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);

      if (!mounted) return;
      _safeSetState(() {
        _isProfileSetupClosing = true;
        _isProfileSetupPanelVisible = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 230));
      if (!mounted) return;

      await _fetchProfile();
      if (!mounted) return;
      _safeSetState(() {
        _isSavingProfile = false;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = true;
      });
      await _waitForUiSettle();
    } catch (e) {
      if (!mounted) return;
      _safeSetState(() {
        _isSavingProfile = false;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = true;
      });
      _showSnack('프로필 저장 실패: $e');
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

  void _openProfileSelectOverlay({
    required String selectKey,
    required LayerLink link,
    required List<String> options,
    required String? selectedValue,
    required ValueChanged<String> onChanged,
  }) {
    unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    _openProfileSelectKey = selectKey;
    _profileSelectOverlayVisible = false;

    final overlay = Overlay.of(context, rootOverlay: true);
    _profileSelectScrollController?.dispose();
    _profileSelectScrollController = ScrollController();
    final menuHeight = (options.length > 3 ? 3 : options.length) * 30.0;
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
                offset: const Offset(0, 30),
                child: Material(
                  color: Colors.transparent,
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
                          child: SizedBox(
                            width: 176,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFEAEAEA)),
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
                                child: SizedBox(
                                  height: menuHeight,
                                  child: _buildProfileSelectOptionsList(
                                    options: options,
                                    selectedValue: selectedValue,
                                    onChanged: onChanged,
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
  }) {
    final link = _profileSelectLinks.putIfAbsent(selectKey, LayerLink.new);
    final isOpen = _openProfileSelectKey == selectKey;
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
                );
              },
        child: Container(
          width: 176,
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
                child: Text(
                  value ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF4A4A4A),
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
        ),
      ),
    );
  }

  Widget _buildProfileSelectOptionsList({
    required List<String> options,
    required String? selectedValue,
    required ValueChanged<String> onChanged,
  }) {
    return ListView.builder(
      controller: _profileSelectScrollController,
      padding: EdgeInsets.zero,
      itemExtent: 30,
      itemCount: options.length,
      itemBuilder: (context, index) {
        final option = options[index];
        final isSelected = option == selectedValue;
        final isFirst = index == 0;
        final isLast = index == options.length - 1;
        return InkWell(
          splashColor: const Color(0xFFF4F8FF).withValues(alpha: 0.45),
          highlightColor: const Color(0xFFF4F8FF).withValues(alpha: 0.35),
          hoverColor: const Color(0xFFF4F8FF).withValues(alpha: 0.25),
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
              color: isSelected ? const Color(0xFFEFF6FF) : Colors.transparent,
              borderRadius: BorderRadius.vertical(
                top: isFirst ? const Radius.circular(12) : Radius.zero,
                bottom: isLast ? const Radius.circular(12) : Radius.zero,
              ),
            ),
            child: Text(
              option,
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4A4A4A),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _bootstrap() async {
    setState(() {
      _status = _ViewStatus.loading;
      _errorMessage = null;
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
        _status = _ViewStatus.ready;
        _isProfileSetupClosing = false;
        _isProfileSetupPanelVisible = profileComplete ? true : false;
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

    final data = await supabase
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();

    _profile = data == null ? null : Map<String, dynamic>.from(data);
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
    final auth = _currentAuthEmail()?.trim();
    if (auth != null && auth.isNotEmpty) return '연결된 이메일: $auth';
    final pe = _profile?['email']?.toString().trim() ?? '';
    if (pe.isNotEmpty) return '연결된 이메일: $pe';
    return l10n?.noLinkedEmail ?? '연동된 이메일 없음';
  }

  bool _looksLikeEmail(String raw) =>
      raw.contains('@') && raw.contains('.');

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

  Future<void> _showEmailAlreadyUsedDialog() async {
    final ctx = _rootNavigatorKey.currentContext ?? context;
    if (!mounted) return;

    await showDialog<void>(
      context: ctx,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('이메일 연동 불가'),
          content: const Text(
            '이미 사용된 이메일입니다.\n다른 이메일을 입력해주세요.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
  }

  void _startEmailOtpCooldown() {
    _emailOtpCooldownTimer?.cancel();

    _safeSetState(() {
      _emailOtpCooldownSeconds = 60;
    });

    _emailOtpCooldownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) {
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

  String _emailOtpCooldownLabel({
    required String normalLabel,
  }) {
    if (_emailOtpCooldownSeconds <= 0) return normalLabel;
    return '$_emailOtpCooldownSeconds초 후 다시 시도';
  }

  _MealNotificationTexts _mealNotificationTextsForLocaleCode(String localeCode) {
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
      messages: [
        '베지펫이 배가 고플 시간이에요!',
        '베지펫에게 건강한 음식을 줄 시간이에요!',
      ],
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

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
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

    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final enabled = await androidPlugin.areNotificationsEnabled();
      if (enabled != true) {
        final requested = await androidPlugin.requestNotificationsPermission();
        if (requested != true) granted = false;
      }
    }

    final iosPlugin = _notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
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
    _mealReminderPushEnabled = prefs.getBool(_kMealReminderPushPrefKey) ?? false;
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
    for (var dayIndex = 0; dayIndex < _kMealReminderDaysToSchedule; dayIndex++) {
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
          debugPrint('meal reminder schedule skipped: notification permission denied');
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

      for (var dayIndex = 0;
          dayIndex < _kMealReminderDaysToSchedule;
          dayIndex++) {
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
          final id = _kMealReminderNotificationIdBase + dayIndex * 10 + slotIndex;
          final message =
              notificationMessages[Random().nextInt(notificationMessages.length)];
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
      await supabase.from('profiles').update({
        'email': authEmail,
        'account_type': 'email',
        'linked_at':
            _profile?['linked_at'] ?? DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);

      await _fetchProfile();
    } catch (e) {
      debugPrint('sync auth email to profile failed: $e');
    }
  }

  Future<bool> _sendEmailLinkOtp(String email) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return false;
    }
    final trimmed = email.trim();
    if (trimmed.isEmpty || !_looksLikeEmail(trimmed)) {
      _showSnack('올바른 이메일 형식으로 입력해주세요.');
      return false;
    }
    try {
      await supabase.auth.updateUser(
        UserAttributes(email: trimmed),
      );
      _showSnack('인증 코드가 이메일로 발송되었어요.');
      return true;
    } catch (e) {
      if (_isEmailAlreadyUsedError(e)) {
        await _showEmailAlreadyUsedDialog();
        return false;
      }
      _showSnack('인증 코드 발송에 실패했어요: ${_formatAuthError(e)}');
      return false;
    }
  }

  Future<bool> _verifyEmailLinkOtp({
    required String email,
    required String token,
  }) async {
    final trimmedEmail = email.trim();
    final trimmedToken = token.trim();
    if (trimmedEmail.isEmpty || trimmedToken.isEmpty) {
      _showSnack('이메일과 인증 코드를 입력해주세요.');
      return false;
    }
    try {
      await supabase.auth.verifyOTP(
        email: trimmedEmail,
        token: trimmedToken,
        type: OtpType.emailChange,
      );
    } catch (e) {
      if (_isEmailAlreadyUsedError(e)) {
        await _showEmailAlreadyUsedDialog();
        return false;
      }
      _showSnack('인증 코드 확인에 실패했어요: ${_formatAuthError(e)}');
      return false;
    }

    try {
      await _syncAuthEmailToProfileIfNeeded();
      await _fetchProfile();
      if (mounted) {
        _safeSetState(() {});
      }
      return true;
    } catch (e) {
      _showSnack('이메일 인증은 완료됐지만 프로필 상태 저장에 실패했어요. 설정을 다시 열어주세요.');
      debugPrint('verify email otp profile sync failed: $e');
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
      return;
    }

    debugPrint('pokedex current user id: ${user.id}');

    // 1) pokedex_entries 기본 row 만 먼저 조회.
    List<Map<String, dynamic>> entries = [];
    try {
      final rawEntries = await supabase
          .from('pokedex_entries')
          .select('id, user_id, pet_species_id, source_user_pet_id, registered_at')
          .eq('user_id', user.id);
      entries = (rawEntries as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      debugPrint('fetch pokedex base entries failed: $e');
      _pokedexEntries = [];
      rethrow;
    }

    debugPrint('pokedex base entries count: ${entries.length}');

    if (entries.isEmpty) {
      _pokedexEntries = [];
      return;
    }

    // 2) pet_species_id 모음 → pet_species 별도 조회.
    final speciesIds = entries
        .map((e) {
          final raw = e['pet_species_id'];
          return raw is int
              ? raw
              : int.tryParse(raw?.toString() ?? '');
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
          final id = raw is int
              ? raw
              : int.tryParse(raw?.toString() ?? '');
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
        final quoted =
            sourcePetIds.map((id) => '"$id"').join(',');
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
    //    pokedex_entries 테이블에는 created_at 이 없고 registered_at 컬럼이
    //    실제 등록 시각을 담고 있으므로 그 값을 보조 정렬 키로 사용한다.
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
      return DateTime.tryParse(raw) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }

    entries.sort((a, b) {
      final c = sortOrderOf(a).compareTo(sortOrderOf(b));
      if (c != 0) return c;
      return registeredAtOf(a).compareTo(registeredAtOf(b));
    });

    debugPrint('pokedex merged entries count: ${entries.length}');
    _pokedexEntries = entries;
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
    final species = _activePet?['pet_species'];
    if (species is Map) {
      return _normalizePetFamily(species['family']?.toString() ?? '');
    }
    return '';
  }

  // 도감 entry 에서 종 이름(name_ko)을 안전하게 꺼낸다.
  String _pokedexSpeciesNameOf(Map<String, dynamic> entry) {
    final species = entry['pet_species'];
    if (species is Map) {
      final n = species['name_ko']?.toString().trim();
      if (n != null && n.isNotEmpty) return n;
    }
    return '베지펫';
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

  // 같은 pet_species_id 가 여러 건 등록되어 있어도 도감 화면에는 종당 1마리만
  // 노출한다. 정렬은 호출 측에서 끝내고 들어오므로 처음 만난 행을 그대로 채택.
  List<Map<String, dynamic>> _dedupePokedexEntriesBySpecies(
    List<Map<String, dynamic>> entries,
  ) {
    final seen = <int>{};
    final result = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final raw = entry['pet_species_id'];
      final speciesId = raw is int
          ? raw
          : int.tryParse(raw?.toString() ?? '');
      if (speciesId == null) continue;
      if (seen.contains(speciesId)) continue;
      seen.add(speciesId);
      result.add(entry);
    }
    return result;
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
      final currentAffection =
          (_activePet!['affection'] as num?)?.toInt() ?? 0;

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
          .update({'affection': currentAffection + 5}).eq('id', petId);

      await Future.wait([
        _fetchTodayMealLogs(),
        _fetchActivePet(),
      ]);

      if (!mounted) return;
      setState(() => _isLoggingMeal = false);

      _showSnack(slot == 'brunch' ? '아점 인증 완료 (+5)' : '저녁 인증 완료 (+5)');

      if (isFirstEver && !_firstMealPopupShownThisSession) {
        _firstMealPopupShownThisSession = true;
        await _showEmailLinkDialog();
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
    switch (afterStage) {
      case 'child':
        return '베지펫이 유년기로 성장했어요!';
      case 'grown':
        return '베지펫이 성장기로 자랐어요!';
      case 'adult':
        return '베지펫이 성숙기에 도달했어요! 육성이 완료되었어요!';
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
            .update({'stage': targetStage}).eq('id', _activePet!['id']);
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
      if (mounted) _showSnack('성숙기 전환 처리 실패: $e');
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

    if (alreadyGraduatedFlag) {
      _showSnack('이미 졸업 처리된 베지펫이에요.');
      return;
    }

    _showSnack('베지펫이 성숙기에 도달했어요! 육성이 완료되었어요!');
    if (ticketGranted) {
      _showSnack('랜덤 분양권을 획득했어요!');
    }
  }

  // 간단 MVP 상호작용: user_pets.affection을 +1 올리고 마지막 사용 날짜를 저장한다.
  // 하루 1회 제한은 user_pets.last_played_on / last_petted_on 값을
  // 오늘 날짜(yyyy-mm-dd)와 비교해서 강제한다.
  // action: 'play' | 'pet'
  Future<void> _interactPet(String action) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }
    if (_activePet == null) {
      _showSnack('먼저 펫을 분양받아주세요.');
      return;
    }
    if (_isInteracting) return;

    final isPlay = action == 'play';
    final label = isPlay ? '놀아주기' : '쓰다듬기';
    final dateColumn = isPlay ? 'last_played_on' : 'last_petted_on';

    final today = _todayDateStr();
    final lastUsedOn = _activePet![dateColumn]?.toString();
    if (lastUsedOn == today) {
      _showSnack(isPlay ? '오늘은 이미 놀아줬어요.' : '오늘은 이미 쓰다듬었어요.');
      return;
    }

    setState(() => _isInteracting = true);

    try {
      final petId = _activePet!['id'];
      final currentAffection =
          (_activePet!['affection'] as num?)?.toInt() ?? 0;
      final beforeStage = _activePet!['stage']?.toString() ?? 'baby';

      final nextAffection = currentAffection + 1;
      final nextStage = _stageFromAffection(nextAffection);

      await supabase.from('user_pets').update({
        'affection': nextAffection,
        'stage': nextStage,
        dateColumn: today,
      }).eq('id', petId);

      await _fetchActivePet();

      if (!mounted) return;
      setState(() => _isInteracting = false);
      _showSnack('$label 성공! 애정도 +1');

      await _syncStageAfterAffectionChange(beforeStage: beforeStage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isInteracting = false);
      _showSnack('$label 실패: $e');
    }
  }

  Future<void> _showEmailLinkDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('베지펫을 지켜주세요'),
          content: const Text(
            '헉! 폰을 바꾸거나 앱이 지워지면 귀여운 베지펫이 사라져요! 😢 지금 설정에서 이메일 연동을 진행할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('나중에 할게요'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _showSnack('나중에 설정 > 이메일 연동 화면으로 연결될 예정입니다.');
              },
              child: const Text('지금 연동하기'),
            ),
          ],
        );
      },
    );
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
    if (_isInitialAdoptionPanelClosing || !_isInitialAdoptionPanelVisible) return;
    _safeSetState(() {
      _isInitialAdoptionPanelClosing = true;
      _isInitialAdoptionPanelVisible = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 230));
    if (!mounted) return;
    _safeSetState(() {
      _isInitialAdoptionPanelClosing = false;
    });
  }

  Future<void> _adoptSelectedPet() async {
    _dismissFocus();

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }
    if (_selectedSpeciesId == null) return;
    if (_activePet != null) {
      _showSnack('이미 육성 중인 펫이 있어요.');
      return;
    }

    final selectedSpeciesId = int.tryParse(_selectedSpeciesId!);
    if (selectedSpeciesId == null) {
      _showSnack('펫 선택값이 올바르지 않아요.');
      return;
    }

    _safeSetState(() => _isAdopting = true);
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
      });

      // 첫 분양 화면 → 마당 화면 으로 큰 전환이 발생한 직후에 곧바로
      // Dialog 를 띄우면 element 트리 정리가 끝나기 전에 새 route 가 push 되어
      // dispose 타이밍 오류가 날 수 있다. 한 frame 양보 후 띄운다.
      await _waitForUiSettle();
      if (!mounted) return;
      await _showNicknameDialog();
    } catch (e) {
      if (!mounted) return;
      _safeSetState(() {
        _isAdopting = false;
        _isInitialAdoptionPanelClosing = false;
        _isInitialAdoptionPanelVisible = true;
      });
      _showSnack('분양 저장에 실패했어요: $e');
    }
  }

  // 분양 직후에 뜨는 닉네임 입력 다이얼로그.
  // 허용 문자: 한글/영문 대소문자/숫자, 길이 2~8자, 공백·특수문자 금지.
  //
  // Dialog 위젯 자체(_PetNicknameDialog)는 "이름 입력 / 검증 / 문자열 반환" 만
  // 책임지고, Supabase user_pets.nickname update / _fetchActivePet /
  // HomePage setState / SnackBar 같은 후처리는 Dialog 가 완전히 닫히고
  // 한 frame 양보된 뒤 여기에서 수행한다. 이렇게 분리해야 TextField/Focus/
  // TextEditingController dispose 와 HomePage 상태 갱신이 겹쳐서 발생하던
  // `_dependents.isEmpty is not true` assertion 오류가 재발하지 않는다.
  Future<void> _showNicknameDialog() async {
    final pet = _activePet;
    if (pet == null || !mounted) return;

    // Dialog 가 닫힌 사이 _activePet 이 재조회로 잠시 비거나 바뀌더라도
    // 잘못된 row 를 업데이트하지 않도록 petId 를 미리 확보해 둔다.
    final petId = pet['id']?.toString();
    if (petId == null || petId.isEmpty) return;

    _dismissFocus();

    final nickname = await showDialog<String>(
      context: _rootNavigatorKey.currentContext ?? context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => const _PetNicknameDialog(),
    );

    if (!mounted || nickname == null) return;

    // Dialog dispose(특히 TextEditingController dispose)가 끝난 뒤 DB 작업/상태
    // 갱신이 일어나도록 한 frame 양보.
    await _waitForUiSettle();
    if (!mounted) return;

    try {
      await supabase
          .from('user_pets')
          .update({'nickname': nickname}).eq('id', petId);

      await _fetchActivePet();

      if (!mounted) return;
      _safeSetState(() {});

      await _waitForUiSettle();
      if (!mounted) return;
      _showSnack('이름이 저장되었어요!');
    } catch (e) {
      if (!mounted) return;
      _showSnack('이름 저장 실패: $e');

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
        _hasOpenedDietDiary = false;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};
        _isLoadingDiary = false;

        _isUploadingMeal = false;
        _uploadingSlot = null;
        _isInteracting = false;
        _isUsingRandomTicket = false;
        _isInitialAdoptionPanelVisible = false;
        _isInitialAdoptionPanelClosing = false;
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;

        _nicknameController.clear();
        _selectedGender = null;
        _selectedAgeRange = null;
        _selectedDietGoal = null;
        _isProfileSetupPanelVisible = true;
        _isProfileSetupClosing = false;
      });
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
  // 동작 순서:
  //   1) meal_logs 삭제 (user_pets 보다 먼저 — FK 참조 회피)
  //   2) pokedex_entries 삭제 (source_user_pet_id 등으로 user_pets 참조 가능)
  //   3) user_items 삭제 (랜덤 분양권 등 보유 아이템 전부)
  //   4) user_pets 삭제
  //   5) profiles 초기화 (nickname/gender/age_range/diet_goal = null)
  //   6) 로컬 상태/폼/진행중 플래그 싹 정리
  //   7) _bootstrap() 재호출
  //
  // Storage bucket(meal-photos) 의 사진 파일 삭제는 이번 단계에서 다루지 않는다.
  // 오직 디버그 섹션에서만 노출하며, 실제 서비스 기능이 아님에 주의.
  // --------------------------------------------------------------------------

  Future<bool> _confirmResetForTesting() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('개발용 전체 초기화'),
          content: const Text(
            '개발용 전체 초기화를 진행할까요?\n'
            '현재 계정의 펫, 식단 기록, 도감 기록, 보유 아이템/분양권, 프로필 입력값이 모두 초기화됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('초기화 실행'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
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
      // 삭제 순서 주의:
      //   meal_logs / pokedex_entries 가 user_pets 를 FK 로 참조할 수 있으므로
      //   user_pets 보다 먼저 비워야 한다. user_items 는 user_pets 와 무관하지만
      //   "전체 초기화" 의 의미상 같은 사이클에서 함께 정리한다.
      await supabase.from('meal_logs').delete().eq('user_id', user.id);
      await supabase.from('pokedex_entries').delete().eq('user_id', user.id);
      await supabase.from('user_items').delete().eq('user_id', user.id);
      await supabase.from('user_pets').delete().eq('user_id', user.id);
      await supabase.from('profiles').update({
        'nickname': null,
        'gender': null,
        'age_range': null,
        'diet_goal': null,
        'gold_balance': 1000,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);

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
        _isAdopting = false;
        _isSavingProfile = false;
        _isLoggingMeal = false;
        _firstMealPopupShownThisSession = false;
        _randomTicketCount = 0;
        _pokedexEntries = [];
        _isLoadingPokedex = false;
        _residentPets = [];
        _hasOpenedDietDiary = false;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};
        _isLoadingDiary = false;
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;

        _selectedSpeciesId = null;
        _nicknameController.clear();
        _selectedGender = null;
        _selectedAgeRange = null;
        _selectedDietGoal = null;
        _isProfileSetupPanelVisible = true;
        _isProfileSetupClosing = false;
      });

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
      await supabase.from('user_pets').update({
        'affection': next,
        'stage': nextStage,
      }).eq('id', petId);

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
      await supabase.from('user_pets').update({
        'affection': affection,
        'stage': stage,
      }).eq('id', petId);

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
      await supabase.from('user_pets').update({
        'affection': 109,
        'stage': 'grown',
        'is_resident': false,
        'graduated_at': null,
      }).eq('id', petId);

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
  // 우측 상단 게임 메뉴 > 가방 진입 시 열리는 BottomSheet.
  // 이번 단계에서는 분양권 카테고리만 노출하고, 가구/장난감은 후속 단계에서 추가한다.
  // 분양권 카드 탭 → 사용 확인 AlertDialog → 실제 분양 흐름은
  // _useRandomAdoptionTicketFromBag() 가 담당한다.
  // --------------------------------------------------------------------------

  // 가방 BottomSheet.
  //
  // 도감 시트와 동일한 패턴:
  //   - 시트 내부에서 추가 showDialog 를 띄우지 않는다.
  //   - 아이콘 탭 → 같은 시트 안의 Stack overlay 로 설명창 표시.
  //   - 분양권 "사용하기" 버튼은 카드 안에 별도 버튼으로 분리해서, 아이콘 탭(설명
  //     보기) 과 사용 트리거가 충돌하지 않게 한다.
  //   - "사용하기" 버튼이 눌리면 시트는 bool(true) 만 pop 하고, 확인 다이얼로그/
  //     실제 분양 흐름은 시트가 완전히 닫힌 뒤 HomePage context 에서 실행한다.
  Future<void> _openBagSheet() async {
    await _fetchRandomTicketCount();
    if (!mounted) return;
    await _waitForUiSettle();
    if (!mounted) return;

    final shouldUseTicket = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        _BagItem? selectedItem;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return _buildBagSheetContent(
              selectedItem: selectedItem,
              onSelectItem: (item) {
                setSheetState(() => selectedItem = item);
              },
              onCloseInfo: () {
                setSheetState(() => selectedItem = null);
              },
              onUseTicket: () {
                Navigator.of(sheetCtx).pop(true);
              },
            );
          },
        );
      },
    );

    if (!mounted || shouldUseTicket != true) return;

    // 시트 dispose 가 끝난 뒤 다이얼로그를 띄우도록 한 frame 양보.
    await _waitForUiSettle();
    if (!mounted) return;

    final confirmed = await _confirmUseRandomTicket();
    if (!mounted || !confirmed) return;

    await _useRandomAdoptionTicketFromBag();
  }

  Widget _buildBagSheetContent({
    required _BagItem? selectedItem,
    required ValueChanged<_BagItem> onSelectItem,
    required VoidCallback onCloseInfo,
    required VoidCallback onUseTicket,
  }) {
    final theme = Theme.of(context);
    final hasTicket = _randomTicketCount > 0;
    final useDisabled = !hasTicket || _isUsingRandomTicket;

    // 분양권은 _randomTicketCount 가 1 이상일 때만 더미 티켓 카드로 노출한다.
    // MVP에서는 상점/가구 시스템을 제외하고, 장난감 2종은 기본 지급 아이템으로 고정 표시한다.
    final ticketItems = <_BagItem>[
      if (hasTicket)
        _BagItem(
          category: 'ticket',
          name: '분양권(랜덤)',
          description:
              '성숙기를 달성하면 주는 베지펫 분양권 랜덤 티켓. 사용 시 귀여운 베지펫 1마리를 랜덤으로 분양받을 수 있다! '
              '(단, 보유중인 펫은 제외)',
          quantity: _randomTicketCount,
          icon: Icons.confirmation_number_outlined,
          usable: !_isUsingRandomTicket,
        ),
    ];
    final toyItems = _defaultToyBagItems();

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
                        const Icon(Icons.backpack_outlined, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          '가방',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '보유한 아이템을 확인할 수 있어요.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildBagSection(
                      title: '분양권',
                      emptyText: '보유 중인 분양권이 없어요.',
                      items: ticketItems,
                      onSelectItem: onSelectItem,
                      onUseTicket: useDisabled ? null : onUseTicket,
                      isUsing: _isUsingRandomTicket,
                    ),
                    const SizedBox(height: 16),
                    _buildBagSection(
                      title: '장난감',
                      emptyText: '보유 중인 장난감이 없어요.',
                      items: toyItems,
                      onSelectItem: onSelectItem,
                    ),
                  ],
                ),
              ),
            ),
            if (selectedItem != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onCloseInfo,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.35),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: _buildBagInfoCard(selectedItem),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBagSection({
    required String title,
    required String emptyText,
    required List<_BagItem> items,
    required ValueChanged<_BagItem> onSelectItem,
    VoidCallback? onUseTicket,
    bool isUsing = false,
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
        if (items.isEmpty)
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
            children: items
                .map(
                  (it) => _buildBagItemTile(
                    item: it,
                    onTap: () => onSelectItem(it),
                    onUse: it.category == 'ticket' ? onUseTicket : null,
                    isUsing: isUsing && it.category == 'ticket',
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildBagItemTile({
    required _BagItem item,
    required VoidCallback onTap,
    VoidCallback? onUse,
    bool isUsing = false,
  }) {
    final theme = Theme.of(context);
    // 분양권만 "사용하기" 버튼을 카드 하단에 노출한다. 가구/장난감 등은
    // 아이콘 탭(설명 보기) 만 동작한다.
    final showUseButton = item.category == 'ticket' && item.usable;

    return SizedBox(
      width: 156,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.7),
                        child: Icon(
                          item.icon,
                          size: 28,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'x${item.quantity}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showUseButton) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: isUsing ? null : onUse,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: isUsing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            '사용하기',
                            style: TextStyle(fontSize: 12),
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 가방 BottomSheet 위에 띄우는 설명 카드.
  //
  // 요구사항: "이름:", "설명:" 같은 라벨은 노출하지 않고 값만 보여준다.
  // 카드 자체는 GestureDetector 로 감싸지 않아도 외곽 overlay 의
  // GestureDetector 가 모든 탭을 받아 onCloseInfo 를 호출한다.
  Widget _buildBagInfoCard(_BagItem item) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor:
                  theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
              child: Icon(
                item.icon,
                size: 36,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              item.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              item.description,
              textAlign: TextAlign.center,
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

  List<_BagItem> _defaultToyBagItems() {
    return const [
      _BagItem(
        category: 'toy',
        name: '뼈다귀 인형',
        description: '강아지 베지펫이 좋아할 것 같은 기본 장난감입니다. 추후 놀이 기능과 연결될 예정입니다.',
        quantity: 1,
        icon: Icons.cruelty_free_outlined,
        usable: false,
        targetPetFamily: 'dog',
      ),
      _BagItem(
        category: 'toy',
        name: '실뭉치',
        description: '고양이 베지펫이 좋아할 것 같은 기본 장난감입니다. 추후 놀이 기능과 연결될 예정입니다.',
        quantity: 1,
        icon: Icons.sports_baseball_outlined,
        usable: false,
        targetPetFamily: 'cat',
      ),
    ];
  }

  // 도감 BottomSheet 열기.
  //
  // 시트 안에서 추가로 showDialog 를 띄우거나 DB 호출을 일으키면 모달 트리
  // 정리 타이밍이 다시 꼬일 수 있다. 그래서:
  //   1) 시트 열기 전에 _fetchPokedexEntries 로 데이터를 미리 받아 두고
  //   2) 시트 안에서는 로컬 selectedEntry 상태만 다루며
  //   3) 펫 정보 표시창도 별도 Dialog 가 아니라 같은 시트 안의 Stack overlay 로
  //      구현한다 (overlay 어디든 탭하면 닫힘).
  Future<void> _openPokedexSheet() async {
    _dismissFocus();

    _safeSetState(() => _isLoadingPokedex = true);
    try {
      await _fetchPokedexEntries();
    } catch (e) {
      if (!mounted) return;
      _safeSetState(() => _isLoadingPokedex = false);
      _showSnack('도감 조회 실패: $e');
      return;
    }

    if (!mounted) return;
    _safeSetState(() => _isLoadingPokedex = false);

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
                .map((entry) => _buildPokedexTile(
                      entry: entry,
                      onTap: () => onSelectEntry(entry),
                    ))
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
                backgroundColor:
                    theme.colorScheme.secondaryContainer.withValues(alpha: 0.7),
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
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor:
                  theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
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
                const Text('종류: ',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Text(speciesName),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('이름: ',
                    style: TextStyle(fontWeight: FontWeight.w600)),
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

  /// "분양권(랜덤)을 사용할까요?" 확인 다이얼로그.
  /// 확인을 누르면 true, 취소/dismiss 면 false.
  Future<bool> _confirmUseRandomTicket() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('분양권(랜덤)을 사용할까요?'),
          content: const Text('도감에 등록되지 않은 베지펫 중 1마리가 랜덤으로 분양돼요.'),
          actions: [
            TextButton(
              onPressed: _isUsingRandomTicket
                  ? null
                  : () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: _isUsingRandomTicket
                  ? null
                  : () => Navigator.of(ctx).pop(true),
              child: const Text('사용하기'),
            ),
          ],
        );
      },
    );
    return result == true;
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
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }
    if (_randomTicketCount <= 0) {
      _showSnack('보유 중인 랜덤 분양권이 없어요.');
      return;
    }

    // 현재 활성 펫이 아직 성숙기 졸업 처리가 끝나지 않은 상태라면 사용 불가.
    // 성숙기 + is_resident=true + graduated_at!=null 셋이 모두 갖춰진 경우에만
    // 새 펫을 분양받을 수 있다.
    final currentPet = _activePet;
    final isCurrentGraduated = currentPet != null &&
        currentPet['stage']?.toString() == 'adult' &&
        currentPet['is_resident'] == true &&
        currentPet['graduated_at'] != null;
    if (currentPet != null && !isCurrentGraduated) {
      _showSnack('현재 육성 중인 베지펫이 있어요. 성숙기 달성 후 사용할 수 있어요.');
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
        _showSnack('분양권 사용 실패: $e');
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
        _showSnack('분양 결과를 해석할 수 없어요. 잠시 후 다시 시도해주세요.');
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
          _showSnack('이미 도감에 등록된 베지펫이 반환되었어요. 분양 로직을 확인해주세요.');
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
              .update({'is_active': false}).eq('id', currentPet['id']);
        } catch (e) {
          if (!mounted) return;
          _showSnack('기존 펫 비활성화 실패: $e');
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
        _showSnack('새 베지펫 분양 저장 실패: $e');
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

      _showSnack('새 베지펫이 분양되었어요!');

      // 6) 새 펫이 마당 화면에 자리잡은 뒤(한 frame 양보) 이름 짓기 다이얼로그 표시.
      await _waitForUiSettle();
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
      messenger.showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  // ----- 화면 전환 안정화용 helper -----

  void _dismissFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: ColoredBox(
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
        showInitialAdoption || _isInitialAdoptionPanelClosing;
    if (!showProfileSetup && _openProfileSelectKey != null) {
      unawaited(_closeProfileSelectOverlay(notify: false, animated: false));
    }
    if (showProfileSetup &&
        !_isProfileSetupClosing &&
        !_isProfileSetupPanelVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final canShow = _status == _ViewStatus.ready && !_isProfileComplete();
        if (!canShow || _isProfileSetupClosing) return;
        setState(() {
          _isProfileSetupPanelVisible = true;
        });
      });
    }
    if (showInitialAdoption &&
        !_isInitialAdoptionPanelClosing &&
        !_isInitialAdoptionPanelVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final canShow =
            _status == _ViewStatus.ready && _isProfileComplete() && _activePet == null;
        if (!canShow || _isInitialAdoptionPanelClosing) return;
        setState(() {
          _isInitialAdoptionPanelVisible = true;
        });
      });
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _buildYardBaseLayer(),
        _buildYardPetLayer(),
        _buildTopHudLayer(),
        if (_status == _ViewStatus.loading) _buildInYardLoadingOverlay(),
        if (_status == _ViewStatus.error)
          _buildInYardErrorOverlay(
            message: _errorMessage,
            onRetry: _bootstrap,
          ),
        if (shouldMountProfileSetup)
          _buildInYardProfileSetupPanel(visible: _isProfileSetupPanelVisible),
        if (shouldMountInitialAdoption) _buildInYardAdoptionPanel(),
        _buildInYardDebugPanel(),
      ],
    );
  }

  Widget _buildYardBaseLayer() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _dismissFocus();
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

  Widget _buildTopHudLayer() {
    final l10n = AppLocalizations.of(context);
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isPetInfoBannerOpen,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                opacity: _isPetInfoBannerOpen ? 1 : 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closePetInfoBanner,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          ),
          _buildPetInfoSlideBanner(),
          Positioned(
            top: 16,
            left: 16,
            child: IgnorePointer(
              ignoring: _isPetInfoBannerOpen,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                opacity: _isPetInfoBannerOpen ? 0 : 1,
                child: _cornerIconButton(
                  icon: Icons.pets,
                  tooltip: l10n.petInfoTooltip,
                  iconSize: 26,
                  padding: 11,
                  onTap: _togglePetInfoBanner,
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: _cornerIconButton(
              icon: Icons.apps_rounded,
              tooltip: l10n.gameMenuTooltip,
              iconSize: 26,
              padding: 11,
              onTap: _openMenuSheet,
            ),
          ),
          if (_isToyMenuOpen)
            Positioned.fill(
              child: _buildToyDropTargetOverlay(),
            ),
          if (_isToyMenuOpen)
            Positioned(
              left: 16,
              top: 48,
              bottom: 16,
              width: 92,
              child: _buildToyMenuWindow(),
            ),
        ],
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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

  Widget _buildInYardInitialAdoptionPanel() {
    final visible = _isInitialAdoptionPanelVisible;
    return Positioned(
      left: _kInitialAdoptionPanelLeft,
      top: _kInitialAdoptionPanelTop,
      width: _kInitialAdoptionPanelWidth,
      height: _kInitialAdoptionPanelHeight,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 230),
          curve: Curves.easeOutCubic,
          opacity: visible ? 1 : 0,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 230),
            curve: Curves.easeOutCubic,
            scale: visible ? 1 : 0.985,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 230),
              curve: Curves.easeOutCubic,
              offset: visible ? Offset.zero : const Offset(0, 0.02),
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
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: _buildInitialAdoptionPanelContent(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
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
    final speciesName =
        species['name_ko']?.toString().trim().isNotEmpty == true
            ? species['name_ko']?.toString().trim() ?? '-'
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
                  color: isSelected
                      ? const Color(0xFFDCEAFF)
                      : backgroundColor,
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
                            color: const Color(0xFFA9C9FF).withValues(alpha: 0.3),
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
                    '분양받기!',
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
    );
  }

  Widget _buildInitialAdoptionPanelContent() {
    final l10n = AppLocalizations.of(context);
    final dogSpecies = _initialAdoptionSpeciesByFamily(['dog', '강아지', '댕']);
    final catSpecies = _initialAdoptionSpeciesByFamily(['cat', '고양이', '냥']);
    final titleText = Localizations.localeOf(context).languageCode == 'ko'
        ? '베지펫을 분양 받을 차례에요!'
        : l10n.initialAdoptionTitle;
    const titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: Color(0xFF000000),
      height: 1.0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          titleText,
          textAlign: TextAlign.left,
          style: titleStyle,
        ),
        const SizedBox(height: 12),
        _buildInitialAdoptionSpeciesRow(
          species: dogSpecies,
          isDogFamily: true,
        ),
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
    return Positioned(
      left: 16,
      right: 16,
      bottom: 10,
      child: IgnorePointer(
        ignoring: _status != _ViewStatus.ready,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _status == _ViewStatus.ready ? 1 : 0,
          child: SizedBox(
            height: 58,
            child: SingleChildScrollView(
              child: _buildDebugSection(),
            ),
          ),
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
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }

  void _togglePetInfoBanner() {
    if (_activePet == null || _isInteracting) return;
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

  Future<void> _onPetInfoBannerAction(String action) async {
    _closePetInfoBanner();
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

  Widget _buildPetInfoSlideBanner() {
    final isOpen = _isPetInfoBannerOpen && _activePet != null;
    const topInset = 10.0;
    const bottomInset = 12.0;
    const sideInset = 10.0;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final panelWidth = (constraints.maxWidth * 0.36).clamp(240.0, 360.0);
        final closedLeft = -panelWidth - 24;
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          top: topInset,
          bottom: bottomInset,
          left: isOpen ? sideInset : closedLeft,
          width: panelWidth,
          child: IgnorePointer(
            ignoring: !isOpen,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              opacity: isOpen ? 1 : 0,
              child: _buildPetInfoBannerContent(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPetInfoBannerContent() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final pet = _activePet;
    if (pet == null) return const SizedBox.shrink();

    final species = pet['pet_species'] is Map
        ? Map<String, dynamic>.from(pet['pet_species'] as Map)
        : <String, dynamic>{};
    final family = species['family']?.toString() ?? '';
    final speciesName = species['name_ko']?.toString() ?? '펫';
    final nickname = pet['nickname']?.toString();
    final displayName =
        (nickname == null || nickname.isEmpty) ? speciesName : nickname;
    final stage = pet['stage']?.toString() ?? 'baby';
    final stageKo = _stageToKorean(stage);
    final affectionValue = (pet['affection'] as num?)?.toInt() ?? 0;
    final today = _todayDateStr();
    final playedToday = pet['last_played_on']?.toString() == today;
    final pettedToday = pet['last_petted_on']?.toString() == today;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.84),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.chevron_left_rounded,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          l10n.petInfoTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: _closePetInfoBanner,
                        borderRadius: BorderRadius.circular(99),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.08),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  family == 'cat'
                                      ? Icons.pets
                                      : Icons.cruelty_free_outlined,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _petInfoMetaChip(
                                      label: l10n.petInfoNameLabel,
                                      value: displayName,
                                    ),
                                    const SizedBox(height: 5),
                                    _petInfoMetaChip(
                                      label: l10n.petInfoSpeciesLabel,
                                      value: speciesName,
                                    ),
                                    const SizedBox(height: 5),
                                    _petInfoMetaChip(
                                      label: l10n.petInfoStageLabel,
                                      value: stageKo,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _buildAffectionProgressCard(affectionValue),
                          const SizedBox(height: 8),
                          _bannerActionButton(
                            label: l10n.petInfoFeedAction,
                            icon: Icons.restaurant_rounded,
                            onTap: _isInteracting
                                ? null
                                : () => _onPetInfoBannerAction('meal'),
                          ),
                          const SizedBox(height: 7),
                          _bannerActionButton(
                            label: l10n.petInfoPlayAction,
                            icon: Icons.toys_outlined,
                            onTap: (_isInteracting || playedToday)
                                ? null
                                : () => _onPetInfoBannerAction('play'),
                          ),
                          const SizedBox(height: 7),
                          _bannerActionButton(
                            label: l10n.petInfoPetAction,
                            icon: Icons.back_hand_outlined,
                            onTap: (_isInteracting || pettedToday)
                                ? null
                                : () => _onPetInfoBannerAction('pet'),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            l10n.petInfoMealTimeGuide,
                            textAlign: TextAlign.center,
                            softWrap: true,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10.5,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            alignment: WrapAlignment.center,
                            children: [
                              _interactionStatusChip(
                                l10n.petInfoPlayAction,
                                playedToday,
                              ),
                              _interactionStatusChip(
                                l10n.petInfoPetAction,
                                pettedToday,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _petInfoMetaChip({
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label  $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _bannerActionButton({
    required String label,
    required IconData icon,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return _SoftActionButton(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 18),
        ],
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
        children: [
          for (final pet in visible) _buildResidentPetChip(pet),
        ],
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
    final displayName =
        (nickname == null || nickname.isEmpty) ? speciesName : nickname;

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
    final theme = Theme.of(context);

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
        final hovering = _isToyDropHovering || candidateData.isNotEmpty;
        return Container(
          color: Colors.black.withValues(alpha: hovering ? 0.14 : 0.04),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: hovering
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: hovering ? 2 : 1,
              ),
            ),
            child: Text(
              hovering ? '여기에 놓으면 베지펫이 놀아요!' : '장난감을 마당에 놓아주세요',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToyMenuWindow() {
    final theme = Theme.of(context);
    final activeFamily = _activePetFamily();
    final toys = _defaultToyBagItems();

    return Material(
      elevation: 8,
      color: Colors.white.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          children: [
            const Text(
              '장난감',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            for (final toy in toys) ...[
              _buildToyMenuDraggableItem(
                toy,
                toy.targetPetFamily == activeFamily,
              ),
              const SizedBox(height: 10),
            ],
            const Spacer(),
            Icon(
              Icons.keyboard_double_arrow_right,
              size: 22,
              color: theme.colorScheme.primary,
            ),
            const Text(
              'DRAG\nAND DROP',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: _cancelToyMenu,
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToyMenuDraggableItem(_BagItem toy, bool canUse) {
    final child = _buildToyMenuIconVisual(toy, canUse);

    if (!canUse) {
      return Opacity(
        opacity: 0.35,
        child: IgnorePointer(child: child),
      );
    }

    return LongPressDraggable<_BagItem>(
      data: toy,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: _buildToyDragFeedback(toy),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );
  }

  Widget _buildToyMenuIconVisual(_BagItem toy, bool canUse) {
    final theme = Theme.of(context);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: canUse
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        toy.icon,
        size: 28,
        color: canUse
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildToyDragFeedback(_BagItem toy) {
    return Container(
      width: 110,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(toy.icon, size: 22, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              toy.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cornerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double iconSize = 22,
    double padding = 10,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
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
    final speciesName = species['name_ko']?.toString() ?? '펫';
    final nickname = pet['nickname']?.toString();
    final displayName =
        (nickname == null || nickname.isEmpty) ? speciesName : nickname;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
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
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            '$displayName이(가) 마당에서 기다리고 있어요',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
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

  Future<void> _openToyPlaySheet() async {
    if (_activePet == null) {
      _showSnack('먼저 펫을 분양받아주세요.');
      return;
    }

    final today = _todayDateStr();
    if (_activePet!['last_played_on']?.toString() == today) {
      _showSnack('오늘은 이미 놀아줬어요.');
      return;
    }

    final family = _activePetFamily();
    if (family != 'dog' && family != 'cat') {
      _showSnack('펫 정보를 확인할 수 없어요.');
      return;
    }

    await _waitForUiSettle();
    if (!mounted) return;

    _safeSetState(() {
      _isPetInfoBannerOpen = false;
      _isToyMenuOpen = true;
      _isToyDropHovering = false;
    });
    _showSnack('장난감을 길게 눌러 마당에 놓아주세요.');
  }

  Future<void> _completeToyMenuDrop(_BagItem toy) async {
    if (_isCompletingToyPlay) return;

    final family = _activePetFamily();
    if (toy.targetPetFamily != family) {
      _showSnack('이 장난감은 이 베지펫에게 사용할 수 없어요.');
      return;
    }

    final today = _todayDateStr();
    if (_activePet?['last_played_on']?.toString() == today) {
      _cancelToyMenu();
      _showSnack('오늘은 이미 놀아줬어요.');
      return;
    }

    _safeSetState(() {
      _isCompletingToyPlay = true;
      _isToyMenuOpen = false;
      _isToyDropHovering = false;
    });

    try {
      await _interactPet('play');
    } finally {
      if (mounted) {
        _safeSetState(() => _isCompletingToyPlay = false);
      }
    }
  }

  void _cancelToyMenu() {
    _safeSetState(() {
      _isToyMenuOpen = false;
      _isToyDropHovering = false;
      _isCompletingToyPlay = false;
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
    final displayName =
        (nickname == null || nickname.isEmpty) ? speciesName : nickname;
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
                        color: theme.colorScheme.onPrimaryContainer
                            .withValues(alpha: 0.75),
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
                info.isComplete
                    ? Colors.amber
                    : theme.colorScheme.primary,
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
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  subtitle,
                ],
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
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }
    if (_activePet == null) {
      _showSnack('먼저 펫을 분양받아주세요.');
      return;
    }
    if (_isUploadingMeal) return;

    if (_todayMealLogs.any((m) => m['meal_slot'] == slot)) {
      _showSnack('이미 해당 식단 인증을 완료했어요.');
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
      final imagePath =
          await _uploadPhotoToStorage(slot: slot, file: photo);
      if (imagePath == null) {
        if (!mounted) return;
        setState(() {
          _isUploadingMeal = false;
          _uploadingSlot = null;
        });
        _showSnack('사진 업로드에 실패했어요. 잠시 후 다시 시도해주세요.');
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
        _showSnack('AI 판정에 실패했어요. 잠시 후 다시 시도해주세요.');
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
      if (wasFirstEver && wasLogged && !_firstMealPopupShownThisSession) {
        _firstMealPopupShownThisSession = true;
        await _showEmailLinkDialog();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isUploadingMeal = false;
        _uploadingSlot = null;
      });
      _showSnack('식단 인증 중 오류가 발생했어요: $e');
    }
  }

  /// 실시간 카메라로 식단 사진 1장을 촬영한다.
  /// 사진첩(갤러리) 선택은 허용하지 않는다.
  Future<XFile?> _pickMealPhoto() async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1600,
      );
      return xfile;
    } catch (e) {
      _showSnack('카메라를 사용할 수 없어요: $e');
      return null;
    }
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
      await supabase.storage.from(_kMealPhotoBucket).uploadBinary(
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
  /// { "slot": "brunch|dinner", "imagePath": "<storage path>" }
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
    final gain = (result['affection_gain'] as num?)?.toInt() ??
        _kMealAffectionGainByResult[resultType] ??
        0;

    final statusMessage = ok
        ? _buildAiStatusMessage(resultType, feedbackText)
        : '판정 결과를 가져오지 못했어요. 잠시 후 다시 시도해주세요.';

    // 서버에서 affection 이 갱신되기 전의 단계를 기억해 둔다.
    final beforeStage = _activePet?['stage']?.toString();

    await Future.wait([
      _fetchTodayMealLogs(),
      _fetchActivePet(),
    ]);

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

  String _resultTypeToKorean(String? type) {
    switch (type) {
      case 'good':
        return '좋아요';
      case 'supplement_needed':
        return '보충 필요';
      case 'bad':
        return '아쉬워요';
      case 'uncertain':
        return '판단 어려움';
      default:
        return '-';
    }
  }

  // 펫 상태창 > 먹이주기에서 호출되는 식단 인증 전용 BottomSheet.
  // 아점/저녁 사진 업로드 버튼, 오늘 완료 여부, 최근 AI 판정 결과까지 보여준다.
  //
  // BottomSheet 내부에서는 어떤 slot 을 선택했는지만 String 으로 pop 해서 반환하고,
  // 실제 카메라 촬영 / 업로드 / AI 판정 등 긴 async 작업은 시트가 완전히 닫힌 뒤
  // HomePage 의 context 에서 실행한다. StatefulBuilder/setSheetState 와 await 가
  // 겹쳐서 dispose 타이밍 오류가 나는 경로를 차단한다.
  Future<void> _openMealSheet() async {
    if (_activePet == null) return;

    final slot = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isDismissible: !_isUploadingMeal,
      enableDrag: !_isUploadingMeal,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return _buildMealSheetContent(
          onUpload: (slot) {
            Navigator.of(sheetCtx).pop(slot);
          },
        );
      },
    );

    if (!mounted || slot == null) return;

    await _waitForUiSettle();
    if (!mounted) return;

    await _uploadMealPhotoAndEvaluate(slot);
  }

  Widget _buildMealSheetContent({
    required void Function(String slot) onUpload,
  }) {
    final theme = Theme.of(context);
    final brunchDone = _todayMealLogs.any((m) => m['meal_slot'] == 'brunch');
    final dinnerDone = _todayMealLogs.any((m) => m['meal_slot'] == 'dinner');

    final uploading = _isUploadingMeal;
    final uploadingBrunch = uploading && _uploadingSlot == 'brunch';
    final uploadingDinner = uploading && _uploadingSlot == 'dinner';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.restaurant_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  '오늘의 식단 인증',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _buildPhotoMealButton(
                    slot: 'brunch',
                    label: '아점 식단 사진 올리기',
                    done: brunchDone,
                    uploading: uploadingBrunch,
                    disabled: uploading,
                    onTap: () => onUpload('brunch'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildPhotoMealButton(
                    slot: 'dinner',
                    label: '저녁 식단 사진 올리기',
                    done: dinnerDone,
                    uploading: uploadingDinner,
                    disabled: uploading,
                    onTap: () => onUpload('dinner'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _mealStatusChip('아점', brunchDone),
                const SizedBox(width: 6),
                _mealStatusChip('저녁', dinnerDone),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '실시간 카메라로 촬영한 사진만 AI 판정에 사용돼요.\n아점 06~14시 / 저녁 17~22시 사이에 올려주세요.',
              style: TextStyle(
                fontSize: 10,
                height: 1.4,
                color: Colors.grey[600],
              ),
            ),
            if (_lastStatusMessage != null) ...[
              const SizedBox(height: 14),
              _buildAiResultCard(),
            ],
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _mealSheetSectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey[700],
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildPhotoMealButton({
    required String slot,
    required String label,
    required bool done,
    required bool uploading,
    required bool disabled,
    required VoidCallback onTap,
  }) {
    if (done) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: Text('$label · 완료'),
      );
    }
    if (uploading) {
      return FilledButton.tonalIcon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('판정 중...'),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: disabled ? null : onTap,
      icon: const Icon(Icons.camera_alt_outlined, size: 18),
      label: Text(label),
    );
  }

  // 최근 AI 판정 결과를 보여주는 결과 카드 (먹이주기 시트 하단).
  Widget _buildAiResultCard() {
    final theme = Theme.of(context);
    final resultType = _lastResultType;
    final message = _lastStatusMessage ?? '';
    final gain = _lastAffectionGain ?? 0;

    Color chipColor;
    switch (resultType) {
      case 'good':
        chipColor = Colors.green;
        break;
      case 'supplement_needed':
        chipColor = Colors.orange;
        break;
      case 'bad':
        chipColor = Colors.redAccent;
        break;
      case 'uncertain':
      default:
        chipColor = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: chipColor.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _resultTypeToKorean(resultType),
                  style: TextStyle(
                    fontSize: 11,
                    color: chipColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '애정도 +$gain',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  // 우측 상단 게임 메뉴 아이콘 버튼을 누르면 열리는 8개 메뉴 허브.
  //
  // BottomSheet 내부 builder의 BuildContext를 await 이후에 사용하면
  // `_dependents.isEmpty is not true` 같은 위젯 트리 정리 타이밍 오류가 날 수 있다.
  // 그래서 sheetCtx 에서는 라벨만 pop 으로 반환하고, 후속 동작(_onMenuTap)은
  // BottomSheet 가 완전히 닫힌 뒤 HomePage 의 context 에서 실행한다.
  Future<void> _openMenuSheet() async {
    _closePetInfoBanner();
    final selectedLabel = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return _buildMenuSheetContent(
          onTap: (label) {
            Navigator.of(sheetCtx).pop(label);
          },
        );
      },
    );

    if (!mounted || selectedLabel == null) return;

    // 다음 frame 까지 한 frame 양보해서 BottomSheet 트리가 dispose 된 뒤
    // 다음 화면/시트가 열리도록 한다.
    await _waitForUiSettle();
    if (!mounted) return;

    await _onMenuTap(selectedLabel);
  }

  Widget _buildMenuSheetContent({required ValueChanged<String> onTap}) {
    final items = _menuSheetItems;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '게임 메뉴',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.95,
              children: items
                  .map((item) => _sheetMenuTile(
                        icon: item.$1,
                        label: item.$2,
                        onTap: () => onTap(item.$2),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetMenuTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 26,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onMenuTap(String label) async {
    if (label == '설정') {
      await _openSettingsSheet();
    } else if (label == '가방') {
      await _openBagSheet();
    } else if (label == '도감') {
      await _openPokedexSheet();
    } else if (label == '프로필') {
      await _openProfileSheet();
    } else if (label == '식단일지') {
      await _openDietDiarySheet();
    } else if (label == '상점') {
      _showSnack('오픈 준비중');
    } else {
      _showSnack('나중에 구현 예정: $label');
    }
  }

  Future<void> _openSettingsSheet() async {
    _dismissFocus();
    await _fetchProfile();
    await _syncAuthEmailToProfileIfNeeded();

    await _loadPushSettings();
    await _loadSoundSettings();

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
        var localNoticeEnabled = _noticeEventPushEnabled;
        var localMealEnabled = _mealReminderPushEnabled;
        var localBgmEnabled = _backgroundMusicEnabled;
        var localSfxEnabled = _soundEffectsEnabled;
        var noticeBusy = false;
        var mealBusy = false;
        var bgmBusy = false;
        var sfxBusy = false;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final l10n = AppLocalizations.of(ctx);
            final mealTitle = l10n.mealNotificationTitle;
            final mealMessages = <String>[
              l10n.mealNotificationMessage1,
              l10n.mealNotificationMessage2,
            ];
            return _buildSettingsSheetContent(
              sheetCtx,
              onProfileUpdated: () async {
                await _fetchProfile();
                if (mounted) setSheetState(() {});
              },
              noticePushEnabled: localNoticeEnabled,
              mealPushEnabled: localMealEnabled,
              backgroundMusicEnabled: localBgmEnabled,
              soundEffectsEnabled: localSfxEnabled,
              noticePushBusy: noticeBusy,
              mealPushBusy: mealBusy,
              backgroundMusicBusy: bgmBusy,
              soundEffectsBusy: sfxBusy,
              onNoticePushChanged: (enabled) async {
                setSheetState(() {
                  localNoticeEnabled = enabled;
                  noticeBusy = true;
                });
                final ok = await _toggleNoticeEventPush(
                  enabled,
                  enabledMessage: l10n.noticeEventEnabled,
                  disabledMessage: l10n.noticeEventDisabled,
                );
                if (!mounted || !ctx.mounted) return;
                setSheetState(() {
                  localNoticeEnabled = ok ? _noticeEventPushEnabled : !enabled;
                  noticeBusy = false;
                });
              },
              onMealPushChanged: (enabled) async {
                setSheetState(() {
                  localMealEnabled = enabled;
                  mealBusy = true;
                });
                final ok = await _toggleMealReminderPush(
                  enabled,
                  notificationTitle: mealTitle,
                  notificationMessages: mealMessages,
                  permissionDeniedMessage: l10n.notificationPermissionDenied,
                  enabledMessage: l10n.mealReminderEnabled,
                  disabledMessage: l10n.mealReminderDisabled,
                );
                if (!mounted || !ctx.mounted) return;
                setSheetState(() {
                  localMealEnabled = ok ? _mealReminderPushEnabled : !enabled;
                  mealBusy = false;
                });
              },
              onBackgroundMusicChanged: (enabled) async {
                setSheetState(() {
                  localBgmEnabled = enabled;
                  bgmBusy = true;
                });
                final ok = await _toggleBackgroundMusic(
                  enabled,
                  enabledMessage: l10n.backgroundMusicEnabled,
                  disabledMessage: l10n.backgroundMusicDisabled,
                );
                if (!mounted || !ctx.mounted) return;
                setSheetState(() {
                  localBgmEnabled = ok ? _backgroundMusicEnabled : !enabled;
                  bgmBusy = false;
                });
              },
              onSoundEffectsChanged: (enabled) async {
                setSheetState(() {
                  localSfxEnabled = enabled;
                  sfxBusy = true;
                });
                final ok = await _toggleSoundEffects(
                  enabled,
                  enabledMessage: l10n.soundEffectsEnabled,
                  disabledMessage: l10n.soundEffectsDisabled,
                );
                if (!mounted || !ctx.mounted) return;
                setSheetState(() {
                  localSfxEnabled = ok ? _soundEffectsEnabled : !enabled;
                  sfxBusy = false;
                });
              },
            );
          },
        );
      },
    );
  }

  Future<void> _openLanguageSelectorSheet(BuildContext sheetCtx) async {
    final l10n = AppLocalizations.of(sheetCtx);
    final scope = _LocaleControllerScope.of(sheetCtx);
    final currentCode = scope.locale.languageCode == 'en' ? 'en' : 'ko';

    final selectedCode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        Widget item({
          required String code,
          required String label,
        }) {
          final selected = currentCode == code;
          return ListTile(
            title: Text(label),
            trailing: selected
                ? Icon(
                    Icons.check,
                    color: Theme.of(ctx).colorScheme.primary,
                  )
                : null,
            onTap: () => Navigator.of(ctx).pop(code),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.selectLanguage,
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.languageDescription,
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                item(code: 'ko', label: l10n.languageKorean),
                item(code: 'en', label: l10n.languageEnglish),
              ],
            ),
          ),
        );
      },
    );

    if (selectedCode == null) return;
    final targetCode = selectedCode == 'en' ? 'en' : 'ko';
    final notificationTexts = _mealNotificationTextsForLocaleCode(targetCode);
    final changedMessage =
        targetCode == 'en' ? 'Language has been changed.' : '언어가 변경되었어요.';
    await scope.setLocale(Locale(targetCode));
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

  Future<void> _openSupportCenterSheet(BuildContext sheetCtx) async {
    final l10n = AppLocalizations.of(sheetCtx);
    final localeCode = _LocaleControllerScope.of(sheetCtx).locale.languageCode;
    final isEn = localeCode == 'en';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.supportCenter,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isEn
                      ? 'If you have questions, bug reports, or feedback about VegePet, please contact us at the email below.'
                      : '베지펫 이용 중 문의, 오류 신고, 건의사항이 있다면 아래 이메일로 연락해주세요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.supportEmail,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: 'acoustic.jwg@gmail.com'),
                    );
                    _showSnack(l10n.emailCopied);
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.copyEmail),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.close),
                ),
              ],
            ),
          ),
        );
      },
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
              title: isEn ? '2. Service Scope' : '2. 서비스 내용',
              body: isEn
                  ? 'VegePet provides meal photo verification, AI-based meal feedback, pet growth, and features such as the diary, bag, collection, and settings. Some features may be MVP-limited or added later.'
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
              title: isEn ? '8. Restriction of Use' : '8. 이용 제한',
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
              title: isEn ? '4. Data Operations' : '4. 데이터 및 기록 관리',
              body: isEn
                  ? 'Meal photos, diary entries, and pet data are managed per user account; logs may be used for error analysis.'
                  : '식단 사진/일지/펫 데이터는 계정 기준으로 관리되며, 오류 분석을 위해 일부 로그를 활용할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '5. AI Evaluation Operations' : '5. AI 식단 평가 운영 기준',
              body: isEn
                  ? 'AI feedback is reference-only and may vary by photo quality or environment. Re-capture guidance may be shown for uncertain results.'
                  : 'AI 결과는 참고용이며 사진 품질/조명 등에 따라 달라질 수 있습니다. 불확실 판정 시 재촬영 안내가 제공될 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '6. Notification Operations' : '6. 알림 운영',
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
              title: isEn ? '9. Policy Changes' : '9. 정책 변경',
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
              title: isEn ? '2. Why Guardian Guidance Matters' : '2. 보호자 확인이 필요한 이유',
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
                  ? 'Meal and announcement notifications can be turned on/off in settings.'
                  : '먹이 알림과 공지 알림은 설정에서 ON/OFF할 수 있어 보호자가 이용 상태를 확인할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '7. Account & Data Deletion' : '7. 계정 및 데이터 삭제',
              body: isEn
                  ? 'Data can be deleted from Settings > Account > Delete Account. Guardians may request deletion via email.'
                  : '설정 > 계정 > 회원 탈퇴로 데이터 삭제가 가능하며, 보호자는 이메일로 삭제를 요청할 수 있습니다.',
            ),
            _SupportDocumentSection(
              title: isEn ? '8. Healthy Usage Habits' : '8. 안전한 이용 습관',
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
              title: isEn ? '3. Data That May Be Retained' : '3. 삭제되지 않거나 별도 보관될 수 있는 정보',
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

  Future<void> _openPolicyDocumentSheet({
    required _SupportDocType type,
    required BuildContext sheetCtx,
  }) async {
    final l10n = AppLocalizations.of(sheetCtx);
    final localeCode = _LocaleControllerScope.of(sheetCtx).locale.languageCode;
    final doc = _buildSupportDocument(type, localeCode, l10n);
    final isEn = localeCode == 'en';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.9,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    doc.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${l10n.lastUpdated}: 2026-04-27',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '${l10n.effectiveDate}: 2026-04-27',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      l10n.legalNoticeDraft,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final section in doc.sections) ...[
                    Text(
                      section.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      section.body,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                    const SizedBox(height: 14),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    isEn
                        ? 'TODO: Before release, prepare public web URLs for privacy policy and account/data deletion requests. Also complete App Store Connect App Privacy and Google Play Data Safety.'
                        : 'TODO: 출시 전 개인정보처리방침 웹 URL, 계정/데이터 삭제 요청 웹 URL 준비가 필요합니다. App Store Connect App Privacy 및 Google Play Data Safety Form도 반드시 작성해야 합니다.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(l10n.close),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsSheetContent(
    BuildContext sheetCtx, {
    required Future<void> Function() onProfileUpdated,
    required bool noticePushEnabled,
    required bool mealPushEnabled,
    required bool backgroundMusicEnabled,
    required bool soundEffectsEnabled,
    required bool noticePushBusy,
    required bool mealPushBusy,
    required bool backgroundMusicBusy,
    required bool soundEffectsBusy,
    required ValueChanged<bool>? onNoticePushChanged,
    required ValueChanged<bool>? onMealPushChanged,
    required ValueChanged<bool>? onBackgroundMusicChanged,
    required ValueChanged<bool>? onSoundEffectsChanged,
  }) {
    final l10n = AppLocalizations.of(sheetCtx);
    final localeScope = _LocaleControllerScope.of(sheetCtx);
    final theme = Theme.of(sheetCtx);
    final linked = _hasEffectiveEmailLink();

    final accountTypeLabel =
        linked ? l10n.emailLinkedAccount : l10n.guestAccount;

    final emailLine = linked
        ? _resolvedDisplayEmailLine(l10n)
        : l10n.noLinkedEmail;
    final currentLanguageLabel = localeScope.locale.languageCode == 'en'
        ? l10n.languageEnglish
        : l10n.languageKorean;

    Widget sectionTitle(String title, IconData icon) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    Widget roundedTile({
      required Widget child,
      VoidCallback? onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: child,
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.settings,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // ----- 계정 -----
            sectionTitle(l10n.account, Icons.person_outline),

            roundedTile(
              onTap: null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    accountTypeLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    emailLine,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            if (linked)
              roundedTile(
                onTap: () {
                  _showSnack('이미 이메일 계정으로 연동되어 있어요.');
                },
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.emailLinkCompleted,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              roundedTile(
                onTap: () async {
                  await _openEmailOtpLinkSheet(
                    onLinked: onProfileUpdated,
                  );
                },
                child: Row(
                  children: [
                    Icon(Icons.link, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.emailAccountLink,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),

            roundedTile(
              onTap: () async {
                final ok = await _confirmWithdrawAccount();
                if (ok && mounted) {
                  await _withdrawAccount();
                }
              },
              child: Row(
                children: [
                  Icon(Icons.logout, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.withdrawAccount,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      color: theme.colorScheme.outline),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ----- 언어 -----
            sectionTitle(l10n.languageSettingsTitle, Icons.language_outlined),
            roundedTile(
              onTap: () async => _openLanguageSelectorSheet(sheetCtx),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      currentLanguageLabel,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more, color: theme.colorScheme.outline),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ----- 푸쉬 알림 -----
            sectionTitle(l10n.pushNotifications, Icons.notifications_outlined),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.85),
              title: Text(l10n.pushNoticeEvent),
              subtitle: Text(l10n.pushNoticeEventDescription),
              value: noticePushEnabled,
              onChanged: noticePushBusy ? null : onNoticePushChanged,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.85),
              title: Text(l10n.pushMealReminder),
              subtitle: Text(l10n.pushMealReminderDescription),
              value: mealPushEnabled,
              onChanged: mealPushBusy ? null : onMealPushChanged,
            ),

            const SizedBox(height: 8),

            // ----- 사운드 -----
            sectionTitle(l10n.sound, Icons.music_note_outlined),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.85),
              title: Text(l10n.backgroundMusic),
              subtitle: Text(l10n.backgroundMusicDescription),
              value: backgroundMusicEnabled,
              onChanged:
                  backgroundMusicBusy ? null : onBackgroundMusicChanged,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.85),
              title: Text(l10n.soundEffects),
              subtitle: Text(l10n.soundEffectsDescription),
              value: soundEffectsEnabled,
              onChanged: soundEffectsBusy ? null : onSoundEffectsChanged,
            ),

            const SizedBox(height: 8),

            // ----- 고객지원 -----
            sectionTitle(l10n.customerSupport, Icons.support_agent_outlined),
            roundedTile(
              onTap: () async => _openSupportCenterSheet(sheetCtx),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.supportCenter,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
            roundedTile(
              onTap: () async => _openPolicyDocumentSheet(
                type: _SupportDocType.terms,
                sheetCtx: sheetCtx,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.termsOfService,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
            roundedTile(
              onTap: () async => _openPolicyDocumentSheet(
                type: _SupportDocType.privacy,
                sheetCtx: sheetCtx,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.privacyPolicy,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
            roundedTile(
              onTap: () async => _openPolicyDocumentSheet(
                type: _SupportDocType.operation,
                sheetCtx: sheetCtx,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.operationPolicy,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
            roundedTile(
              onTap: () async => _openPolicyDocumentSheet(
                type: _SupportDocType.guardian,
                sheetCtx: sheetCtx,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.guardianGuide,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
            roundedTile(
              onTap: () async => _openPolicyDocumentSheet(
                type: _SupportDocType.dataDeletion,
                sheetCtx: sheetCtx,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.accountDataDeletionGuide,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEmailOtpLinkSheet({
    required Future<void> Function() onLinked,
  }) async {
    if (_hasEffectiveEmailLink()) {
      _showSnack('이미 이메일 계정으로 연동되어 있어요.');
      return;
    }

    _dismissFocus();
    await _waitForUiSettle();
    if (!mounted) return;

    final emailCtrl = TextEditingController();
    final otpCtrl = TextEditingController();
    Timer? sheetCooldownUiTimer;

    var otpSent = false;
    var isSending = false;
    var isVerifying = false;

    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (modalCtx) {
          final inset = MediaQuery.of(modalCtx).viewInsets.bottom;
          final theme = Theme.of(modalCtx);

          return StatefulBuilder(
            builder: (ctx, setModal) {
              sheetCooldownUiTimer ??=
                  Timer.periodic(const Duration(seconds: 1), (_) {
                if (!modalCtx.mounted) return;
                setModal(() {});
              });

              Future<void> sendOtp() async {
                final isCooldown = _isEmailOtpCooldownActive();
                if (isSending || isVerifying || isCooldown) return;
                final raw = emailCtrl.text.trim();
                if (raw.isEmpty) {
                  _showSnack('이메일을 입력해주세요.');
                  return;
                }
                if (!_looksLikeEmail(raw)) {
                  _showSnack('올바른 이메일 형식으로 입력해주세요.');
                  return;
                }

                setModal(() => isSending = true);
                _startEmailOtpCooldown();
                final ok = await _sendEmailLinkOtp(raw);
                if (!modalCtx.mounted) return;
                setModal(() {
                  isSending = false;
                  if (ok) otpSent = true;
                });
              }

              Future<void> verify() async {
                if (isVerifying) return;
                final em = emailCtrl.text.trim();
                final code = otpCtrl.text.trim();
                if (em.isEmpty) {
                  _showSnack('이메일을 입력해주세요.');
                  return;
                }
                if (code.isEmpty) {
                  _showSnack('인증 코드를 입력해주세요.');
                  return;
                }

                setModal(() => isVerifying = true);
                final ok = await _verifyEmailLinkOtp(email: em, token: code);
                if (!modalCtx.mounted) return;
                setModal(() => isVerifying = false);

                if (ok) {
                  await _fetchProfile();
                  await _syncAuthEmailToProfileIfNeeded();
                  if (mounted) {
                    _safeSetState(() {});
                  }
                  await onLinked();
                  if (modalCtx.mounted) {
                    Navigator.of(modalCtx).pop();
                  }
                  _showSnack('이메일 계정 연동이 완료되었어요.');
                }
              }

              final busy = isSending || isVerifying;
              final isCooldown = _isEmailOtpCooldownActive();

              return Padding(
                padding: EdgeInsets.only(bottom: inset),
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '이메일 계정 연동',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '이메일을 연동하면 기기를 바꾸거나 앱을 다시 설치해도 베지펫 데이터를 이어갈 수 있어요.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: emailCtrl,
                          enabled: !busy,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: '이메일',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: (busy || otpSent || isCooldown)
                              ? null
                              : sendOtp,
                          child: Text(
                            isCooldown
                                ? _emailOtpCooldownLabel(normalLabel: '인증 코드 받기')
                                : isSending
                                    ? '발송 중...'
                                    : '인증 코드 받기',
                          ),
                        ),
                        if (otpSent) ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: otpCtrl,
                            enabled: !busy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '인증 코드',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: (busy || isCooldown) ? null : sendOtp,
                            child: Text(
                              isCooldown
                                  ? _emailOtpCooldownLabel(
                                      normalLabel: '인증 코드 다시 받기',
                                    )
                                  : isSending
                                      ? '발송 중...'
                                      : '인증 코드 다시 받기',
                            ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: busy ? null : verify,
                            child: const Text('인증 완료'),
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed:
                              busy ? null : () => Navigator.of(modalCtx).pop(),
                          child: const Text('취소'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      sheetCooldownUiTimer?.cancel();
      emailCtrl.dispose();
      otpCtrl.dispose();
    }
  }

  Future<bool> _confirmWithdrawAccount() async {
    final ctx = _rootNavigatorKey.currentContext ?? context;
    final confirmed = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('회원 탈퇴'),
          content: const Text(
            '회원 탈퇴를 진행하면 현재 계정의 펫, 식단 기록, 도감 기록, 보유 분양권, 프로필 정보가 모두 초기화됩니다.\n'
            '이 작업은 되돌릴 수 없어요.\n'
            '정말 탈퇴할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('탈퇴하기'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  /// 회원 탈퇴: 사용자 데이터 삭제 후 익명 세션으로 재시작.
  /// auth.users 행 완전 삭제는 클라이언트 권한으로 불가할 수 있음 →
  /// TODO(vegepet): 추후 Edge Function / Admin API로 사용자 계정 정리.
  Future<void> _deleteCurrentAuthUserByEdgeFunction() async {
    try {
      final response = await supabase.functions.invoke(
        'delete-auth-user',
        method: HttpMethod.post,
      );

      final data = response.data;
      if (data is Map && data['ok'] == false) {
        debugPrint('delete auth user failed: ${data['error']}');
      }
    } catch (e) {
      debugPrint('delete auth user edge function failed: $e');
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

    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인 상태가 아니어서 탈퇴를 진행할 수 없어요.');
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

      await supabase.from('profiles').update({
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
      }).eq('id', uid);

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
        _hasOpenedDietDiary = false;
        _diaryVisibleMonth = _todayDiaryMonth();
        _diaryLogsByDate = {};
        _isLoadingDiary = false;
        _isUploadingMeal = false;
        _uploadingSlot = null;
        _isInteracting = false;
        _isUsingRandomTicket = false;
        _isInitialAdoptionPanelVisible = false;
        _isInitialAdoptionPanelClosing = false;
        _isToyMenuOpen = false;
        _isToyDropHovering = false;
        _isCompletingToyPlay = false;
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

      await _waitForUiSettle();
      if (!mounted) return;
      await _bootstrap();

      if (!mounted) return;
      _showSnack('회원 탈퇴가 완료되었어요.');
    } catch (e) {
      if (!mounted) return;
      _showSnack('회원 탈퇴 처리 중 오류가 발생했어요: $e');
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
    String? selectedGender =
        _genderOptions.contains(initialGenderRaw) ? initialGenderRaw : null;
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
                  await supabase.from('profiles').update({
                    'nickname': nickname,
                    'gender': selectedGender,
                    'diet_goal': selectedDietGoal,
                    'resolution':
                        resolutionText.isEmpty ? null : resolutionText,
                    'updated_at': DateTime.now().toIso8601String(),
                  }).eq('id', user.id);

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
                      Center(
                        child: _buildProfileDummyAvatar(selectedGender),
                      ),
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
      child: Icon(
        icon,
        size: 54,
        color: theme.colorScheme.onSurfaceVariant,
      ),
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
    } catch (e) {
      debugPrint('fetch diary month logs failed: $e');
      _diaryLogsByDate = {};
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
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return false;
    }

    double? weight;
    final wRaw = (weightText ?? '').trim();
    if (wRaw.isNotEmpty) {
      final parsed = double.tryParse(wRaw.replaceAll(',', '.'));
      if (parsed == null) {
        _showSnack('체중은 숫자로 입력해주세요.');
        return false;
      }
      weight = parsed;
    }

    final dateKey = _dateKey(date);
    final note = noteText.trim();

    try {
      await supabase.from('meal_diary_notes').upsert(
        {
          'user_id': user.id,
          'diary_date': dateKey,
          'weight_kg': weight,
          'note_text': note.isEmpty ? null : note,
          'updated_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id,diary_date',
      );
      return true;
    } catch (e) {
      _showSnack('식단일지 저장 실패: $e');
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

  // 식단일지 BottomSheet 진입점.
  //
  // 시트 본문은 [_DietDiarySheetPanel] StatefulWidget 으로 분리해,
  // iPhone 에서 키보드가 올라와 BottomSheet 가 다시 build 될 때도
  // calendar/monthPicker/detail 모드가 로컬 변수로 초기화되지 않게 한다.
  Future<void> _openDietDiarySheet() async {
    _dismissFocus();

    if (!_hasOpenedDietDiary) {
      _diaryVisibleMonth = _todayDiaryMonth();
      _hasOpenedDietDiary = true;
    }

    final initialMonth = _clampDiaryMonth(_diaryVisibleMonth);

    _safeSetState(() => _isLoadingDiary = true);
    await _fetchDiaryMonthLogs(initialMonth);
    if (mounted) {
      _safeSetState(() => _isLoadingDiary = false);
    }

    if (!mounted) return;
    await _waitForUiSettle();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return _DietDiarySheetPanel(
          initialMonth: initialMonth,
          clampMonth: _clampDiaryMonth,
          isMonthInRange: _isDiaryMonthInRange,
          fetchMonthLogs: _fetchDiaryMonthLogs,
          logsByDateProvider: () => _diaryLogsByDate,
          dateKey: _dateKey,
          onMonthChanged: (month) {
            _safeSetState(() => _diaryVisibleMonth = month);
          },
          onSavedSuccess: () {
            _showSnack('식단일지가 저장되었어요.');
          },
          signedUrlBuilder: _signedMealPhotoUrl,
          onPhotoTap: _showMealPhotoPreview,
          fetchNote: _fetchMealDiaryNote,
          saveNote: _saveMealDiaryNote,
          calendarBuilder: (
            BuildContext sheetCtx,
            DateTime visibleMonth,
            bool isLoading,
            Map<String, List<Map<String, dynamic>>> logsByDate,
            Future<void> Function() onPrevMonth,
            Future<void> Function() onNextMonth,
            VoidCallback onTapTitle,
            ValueChanged<DateTime> onTapDate,
          ) {
            return _buildDietDiaryCalendar(
              sheetContext: sheetCtx,
              diaryLogsByDate: logsByDate,
              visibleMonth: visibleMonth,
              isLoading: isLoading,
              onPrevMonth: onPrevMonth,
              onNextMonth: onNextMonth,
              onTapTitle: onTapTitle,
              onTapDate: onTapDate,
            );
          },
          monthPickerBuilder: (
            BuildContext sheetCtx,
            int visibleYear,
            int highlightYear,
            int highlightMonth,
            Future<void> Function(int year, int month) onPickMonth,
            ValueChanged<int> onChangeYear,
            VoidCallback onBack,
          ) {
            return _buildDietDiaryMonthPicker(
              sheetContext: sheetCtx,
              visibleYear: visibleYear,
              highlightYear: highlightYear,
              highlightMonth: highlightMonth,
              onPickMonth: onPickMonth,
              onChangeYear: onChangeYear,
              onBack: onBack,
            );
          },
        );
      },
    );

    if (mounted) setState(() {});
  }

  // ---------- 식단일지 달력 모드 ----------
  Widget _buildDietDiaryCalendar({
    required BuildContext sheetContext,
    required Map<String, List<Map<String, dynamic>>> diaryLogsByDate,
    required DateTime visibleMonth,
    required bool isLoading,
    required Future<void> Function() onPrevMonth,
    required Future<void> Function() onNextMonth,
    required VoidCallback onTapTitle,
    required ValueChanged<DateTime> onTapDate,
  }) {
    final theme = Theme.of(sheetContext);
    final canPrev = _isDiaryMonthInRange(
      DateTime(visibleMonth.year, visibleMonth.month - 1, 1),
    );
    final canNext = _isDiaryMonthInRange(
      DateTime(visibleMonth.year, visibleMonth.month + 1, 1),
    );

    final daysInMonth = _daysInMonth(visibleMonth.year, visibleMonth.month);
    // weekday: Mon=1..Sun=7. 일요일 시작 그리드를 위해 0~6 으로 변환.
    final firstWeekday = DateTime(
          visibleMonth.year,
          visibleMonth.month,
          1,
        ).weekday %
        7;

    final today = _todayDateStr();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 8),
            Text(
              '식단일지',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              onPressed: canPrev ? onPrevMonth : null,
              icon: const Icon(Icons.chevron_left),
              tooltip: '이전 달',
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTapTitle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${visibleMonth.year}년 ${visibleMonth.month}월',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_drop_down, size: 22),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: canNext ? onNextMonth : null,
              icon: const Icon(Icons.chevron_right),
              tooltip: '다음 달',
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 요일 헤더
        Row(
          children: [
            for (final w in const ['일', '월', '화', '수', '목', '금', '토'])
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: w == '일'
                          ? Colors.red[600]
                          : w == '토'
                              ? Colors.blue[600]
                              : Colors.grey[700],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        // 날짜 그리드: 7열, 필요한 행 수만큼
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            childAspectRatio: 0.85,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: firstWeekday + daysInMonth,
          itemBuilder: (ctx, index) {
            if (index < firstWeekday) {
              return const SizedBox.shrink();
            }
            final day = index - firstWeekday + 1;
            final date = DateTime(visibleMonth.year, visibleMonth.month, day);
            final dateKey = _dateKey(date);
            final hasMeal =
                (diaryLogsByDate[dateKey] ?? const []).isNotEmpty;
            final isToday = dateKey == today;
            final weekdayCol = index % 7;

            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onTapDate(date),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isToday
                      ? Border.all(
                          color: theme.colorScheme.primary,
                          width: 1.4,
                        )
                      : null,
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$day',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: weekdayCol == 0
                            ? Colors.red[700]
                            : weekdayCol == 6
                                ? Colors.blue[700]
                                : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (hasMeal)
                      Icon(
                        Icons.verified_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      )
                    else
                      const SizedBox(height: 18),
                  ],
                ),
              ),
            );
          },
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
  }) {
    final theme = Theme.of(sheetContext);
    final canPrevYear = visibleYear > _diaryMinMonth.year;
    final canNextYear = visibleYear < _diaryMaxMonth.year;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              tooltip: '달력으로',
            ),
            Text(
              '월 선택',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton(
              onPressed: canPrevYear ? () => onChangeYear(visibleYear - 1) : null,
              icon: const Icon(Icons.chevron_left),
              tooltip: '이전 연도',
            ),
            Expanded(
              child: Center(
                child: Text(
                  '$visibleYear년',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: canNextYear ? () => onChangeYear(visibleYear + 1) : null,
              icon: const Icon(Icons.chevron_right),
              tooltip: '다음 연도',
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 1.6,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: 12,
          itemBuilder: (ctx, idx) {
            final m = idx + 1;
            final isSelected =
                visibleYear == highlightYear && m == highlightMonth;
            // 선택 가능 범위 체크 (예: 2026년이면 1월부터, 2035년이면 12월까지 모두 OK)
            final candidate = DateTime(visibleYear, m, 1);
            final enabled = _isDiaryMonthInRange(candidate);

            return Material(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.18)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: enabled
                    ? () {
                        onPickMonth(visibleYear, m);
                      }
                    : null,
                child: Center(
                  child: Text(
                    '$m월',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: !enabled
                          ? Colors.grey
                          : isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            );
          },
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

  Widget _mealStatusChip(String label, bool done) {
    final color = done ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        done ? '$label 완료' : '$label 대기중',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
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
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF000000),
      height: 1.0,
    );
    const fieldTextStyle = TextStyle(
      fontSize: 13,
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
    }) {
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
                style: labelStyle,
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
              child: TextField(
                controller: _nicknameController,
                onChanged: (_) {
                  _enforceProfileNicknameMaxLength();
                  setState(() {});
                },
                onTapOutside: (_) => _dismissFocus(),
                textAlign: TextAlign.left,
                style: fieldTextStyle,
                maxLines: 1,
                maxLength: _kProfileNicknameMaxLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(
                    _kProfileNicknameMaxLength,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  ),
                ],
                buildCounter: (
                  BuildContext context, {
                  required int currentLength,
                  required bool isFocused,
                  required int? maxLength,
                }) {
                  return null;
                },
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
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
              onChanged: (value) => setState(() => _selectedGender = value),
            ),
          ),
          row(
            top: 90,
            label: l10n.ageRange,
            field: _buildCompactProfileSelect(
              selectKey: 'ageRange',
              value: _selectedAgeRange,
              options: _ageRangeOptions,
              enabled: !_isSavingProfile,
              onChanged: (value) => setState(() => _selectedAgeRange = value),
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
                    : ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFFA9C9FF), Color(0xFFBFD9FF)],
                        ).createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: Text(
                          '${l10n.start}!',
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
    );
  }

  // ---------- 디버그 섹션 ----------

  Widget _buildDebugSection() {
    final user = supabase.auth.currentUser;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _debugExpanded,
          onExpansionChanged: (v) => setState(() => _debugExpanded = v),
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text(
            '개발 확인용 디버그',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            '앱 사용자에게는 보이지 않을 영역',
            style: TextStyle(fontSize: 12),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            _debugBlock(
              title: 'Auth',
              children: [
                _kv('user id', user?.id ?? '-'),
                _kv('email', user?.email ?? '(없음)'),
              ],
            ),
            const SizedBox(height: 12),
            _debugBlock(
              title: 'profiles',
              children: _buildProfileRows(),
            ),
            const SizedBox(height: 12),
            _debugBlock(
              title: 'active user_pet',
              children: _buildActivePetRows(),
            ),
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
                _kv('random_adoption_ticket', '$_randomTicketCount장'),
              ],
            ),
            const SizedBox(height: 12),
            _debugBlock(
              title: 'pokedex',
              children: [
                _kv('loaded entries', '${_pokedexEntries.length}개'),
              ],
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
                  onPressed:
                      _activePet == null ? null : _debugSetJustBeforeAdult,
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
                  icon: const Icon(Icons.confirmation_number_outlined,
                      size: 18),
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
          ],
        ),
      ),
    );
  }

  List<Widget> _buildProfileRows() {
    if (_profile == null) {
      return [
        const Text('프로필이 아직 없어요.',
            style: TextStyle(color: Colors.grey)),
      ];
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
        const Text('아직 active user_pet이 없어요.',
            style: TextStyle(color: Colors.grey)),
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
        Text(
          '아직 AI 판정 기록이 없어요.',
          style: TextStyle(color: Colors.grey),
        ),
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

  String _familyToKorean(String family) {
    switch (family) {
      case 'cat':
        return '고양이';
      case 'dog':
        return '강아지';
      default:
        return family;
    }
  }

  String _stageToKorean(String stage) {
    switch (stage) {
      case 'baby':
        return '유아기';
      case 'child':
        return '유년기';
      case 'grown':
        return '성장기';
      case 'adult':
        return '성숙기';
      default:
        return stage;
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
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 이름 입력 전용 Dialog.
//
// 책임:
//   - TextEditingController / 검증 / 에러 메시지 상태 소유 및 관리
//   - 저장 버튼/엔터 입력 시 검증 통과한 nickname 문자열을 Navigator.pop 으로 반환
//
// 비책임 (절대 하지 말 것):
//   - Supabase 호출
//   - HomePage 의 _fetchActivePet / _safeSetState / _showSnack 호출
//
// 이 분리 덕분에 Dialog dispose(TextField/Focus/TextEditingController)와
// HomePage 의 DB 재조회/상태 갱신/SnackBar 가 같은 프레임에 겹치지 않는다.
// 가방 BottomSheet 안에서 카드/오버레이로 표시할 아이템 정보를 담는 작은 모델.
//
// 가방 UX 는 현재 BottomSheet 내부에서만 다뤄지므로 외부 노출이 필요 없어
// private 클래스로 둔다. category 는 'ticket' | 'furniture' | 'toy' 중 하나.
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

class _PetNicknameDialog extends StatefulWidget {
  const _PetNicknameDialog();

  @override
  State<_PetNicknameDialog> createState() => _PetNicknameDialogState();
}

class _PetNicknameDialogState extends State<_PetNicknameDialog> {
  final TextEditingController _controller = TextEditingController();
  final RegExp _pattern = RegExp(r'^[가-힣a-zA-Z0-9]{2,8}$');
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();

    if (text.isEmpty) {
      setState(() => _errorText = '이름을 입력해주세요.');
      return;
    }
    if (text.length < 2 || text.length > 8) {
      setState(() => _errorText = '이름은 2~8자로 입력해주세요.');
      return;
    }
    if (!_pattern.hasMatch(text)) {
      setState(() => _errorText = '특수문자는 사용할 수 없어요.');
      return;
    }

    // pop 직전 포커스 정리: TextField 가 살아 있는 채로 pop 되어
    // 트리 dispose 와 focus 정리 타이밍이 겹치는 것을 방지한다.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: const Text('아기 베지펫이 분양 되었어요🥹 건강하게 키워주세요~!'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('귀여운 이름을 지어주세요!'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            // autofocus 는 일부러 false. Dialog open 직후 focus 요청과
            // 화면 전환 frame 이 겹쳐 dispose 타이밍 오류가 났던 케이스를 회피.
            autofocus: false,
            maxLength: 8,
            decoration: InputDecoration(
              hintText: '예: 구름이',
              border: const OutlineInputBorder(),
              errorText: _errorText,
              helperText: '한글·영문·숫자 2~8자 (공백/특수문자 불가)',
              counterText: '',
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _submit,
          child: const Text('저장'),
        ),
      ],
    );
  }
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

class _SoftActionButton extends StatefulWidget {
  const _SoftActionButton({
    required this.child,
    this.onTap,
  });

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_SoftActionButton> createState() => _SoftActionButtonState();
}

class _SoftActionButtonState extends State<_SoftActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = widget.onTap == null;
    final bgColor = disabled
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45)
        : theme.colorScheme.primaryContainer.withValues(alpha: 0.86);
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
      onTapCancel: disabled ? null : () => setState(() => _pressed = false),
      onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        tween: Tween<double>(begin: 1, end: _pressed ? 0.97 : 1),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
            ),
          ),
          child: Opacity(
            opacity: disabled ? 0.55 : 1,
            child: widget.child,
          ),
        ),
        builder: (context, scale, child) {
          return Transform.scale(
            scale: scale,
            alignment: Alignment.centerLeft,
            child: child,
          );
        },
      ),
    );
  }
}

// ============================================================================
// 식단일지 BottomSheet 본문 (달력 / 월 선택 / 상세 모드)
// ----------------------------------------------------------------------------
// mode / visibleMonth / selectedDate 를 이 State 에서만 관리한다.
// showModalBottomSheet 의 builder 가 키보드 등장으로 재실행되어도
// StatefulWidget State 객체는 유지되므로 detail 모드가 calendar 로
// 리셋되지 않는다.
// ============================================================================
class _DietDiarySheetPanel extends StatefulWidget {
  const _DietDiarySheetPanel({
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
  });

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
  }) saveNote;
  final Widget Function(
    BuildContext sheetCtx,
    DateTime visibleMonth,
    bool isLoading,
    Map<String, List<Map<String, dynamic>>> logsByDate,
    Future<void> Function() onPrevMonth,
    Future<void> Function() onNextMonth,
    VoidCallback onTapTitle,
    ValueChanged<DateTime> onTapDate,
  ) calendarBuilder;
  final Widget Function(
    BuildContext sheetCtx,
    int visibleYear,
    int highlightYear,
    int highlightMonth,
    Future<void> Function(int year, int month) onPickMonth,
    ValueChanged<int> onChangeYear,
    VoidCallback onBack,
  ) monthPickerBuilder;

  @override
  State<_DietDiarySheetPanel> createState() => _DietDiarySheetPanelState();
}

class _DietDiarySheetPanelState extends State<_DietDiarySheetPanel> {
  late DateTime visibleMonth;
  String mode = 'calendar'; // 'calendar' | 'monthPicker' | 'detail'
  DateTime? selectedDate;
  bool sheetLoading = false;

  @override
  void initState() {
    super.initState();
    visibleMonth = widget.initialMonth;
  }

  Future<void> reloadMonth(DateTime newMonth) async {
    final clamped = widget.clampMonth(newMonth);
    setState(() {
      visibleMonth = clamped;
      sheetLoading = true;
    });
    await widget.fetchMonthLogs(clamped);
    widget.onMonthChanged(clamped);
    if (!mounted) return;
    setState(() {
      sheetLoading = false;
    });
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
          await reloadMonth(DateTime(year, month, 1));
        },
        (newYear) {
          setState(() {
            visibleMonth = DateTime(newYear, visibleMonth.month, 1);
          });
        },
        () => setState(() => mode = 'calendar'),
      );
    } else if (mode == 'detail' && selectedDate != null) {
      final dk = widget.dateKey(selectedDate!);
      final dayLogs = List<Map<String, dynamic>>.from(logs[dk] ?? const []);
      body = _DietDiaryDetailPanel(
        key: ValueKey('diary-detail-$dk'),
        date: selectedDate!,
        logs: dayLogs,
        signedUrlBuilder: widget.signedUrlBuilder,
        onPhotoTap: widget.onPhotoTap,
        fetchNote: widget.fetchNote,
        saveNote: widget.saveNote,
        onBack: () {
          setState(() {
            mode = 'calendar';
            selectedDate = null;
          });
        },
        onSavedSuccess: widget.onSavedSuccess,
      );
    } else {
      body = widget.calendarBuilder(
        context,
        visibleMonth,
        sheetLoading,
        logs,
        () async {
          final prev = DateTime(visibleMonth.year, visibleMonth.month - 1, 1);
          if (!widget.isMonthInRange(prev)) return;
          await reloadMonth(prev);
        },
        () async {
          final next = DateTime(visibleMonth.year, visibleMonth.month + 1, 1);
          if (!widget.isMonthInRange(next)) return;
          await reloadMonth(next);
        },
        () => setState(() => mode = 'monthPicker'),
        (date) {
          setState(() {
            selectedDate = date;
            mode = 'detail';
          });
        },
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
    required this.signedUrlBuilder,
    required this.onPhotoTap,
    required this.fetchNote,
    required this.saveNote,
    required this.onBack,
    required this.onSavedSuccess,
  });

  final DateTime date;
  final List<Map<String, dynamic>> logs;
  final Future<String?> Function(String? imagePath) signedUrlBuilder;
  final Future<void> Function(String imageUrl) onPhotoTap;
  final Future<Map<String, dynamic>?> Function(String dateKey) fetchNote;
  final Future<bool> Function({
    required DateTime date,
    required String? weightText,
    required String noteText,
  }) saveNote;
  final VoidCallback onBack;
  final VoidCallback onSavedSuccess;

  @override
  State<_DietDiaryDetailPanel> createState() => _DietDiaryDetailPanelState();
}

class _DietDiaryDetailPanelState extends State<_DietDiaryDetailPanel> {
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  bool _isLoadingNote = true;
  bool _isSaving = false;
  String? _brunchUrl;
  String? _dinnerUrl;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
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
    }

    setState(() {
      _brunchUrl = brunchUrl;
      _dinnerUrl = dinnerUrl;
      _isLoadingNote = false;
    });
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final ok = await widget.saveNote(
      date: widget.date,
      weightText: _weightController.text,
      noteText: _noteController.text,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      widget.onSavedSuccess();
    }
  }

  String _displayDate(DateTime d) {
    final yy = (d.year % 100).toString();
    return '$yy. ${d.month}. ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: '달력으로',
              ),
              Text(
                '식단일지',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '일자: ${_displayDate(widget.date)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _photoSlot(
                  context: context,
                  label: '아점 사진',
                  url: _brunchUrl,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _photoSlot(
                  context: context,
                  label: '저녁 사진',
                  url: _dinnerUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isLoadingNote)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          TextField(
            controller: _weightController,
            enabled: !_isSaving && !_isLoadingNote,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '체중 (kg)',
              prefixIcon: Icon(Icons.monitor_weight_outlined),
              border: OutlineInputBorder(),
              isDense: true,
              hintText: '예: 62.5',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            enabled: !_isSaving && !_isLoadingNote,
            minLines: 3,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: '식후 감정 OR 실패 요인',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.fromLTRB(12, 12, 32, 28),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: (_isSaving || _isLoadingNote) ? null : _handleSave,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ),
        ],
      ),
    );
  }

  // 사진 슬롯 한 개. url 이 있으면 Image.network + 탭하면 큰 미리보기로 위임.
  // url 이 없으면 placeholder 사각형 + 라벨만 표시.
  Widget _photoSlot({
    required BuildContext context,
    required String label,
    required String? url,
  }) {
    final theme = Theme.of(context);
    final hasPhoto = url != null && url.isNotEmpty;

    return AspectRatio(
      aspectRatio: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: hasPhoto ? () => widget.onPhotoTap(url) : null,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ),
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
                          '$label\n(불러오기 실패)',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.photo_camera_outlined,
                      size: 28,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
