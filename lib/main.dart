import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = 'https://rzsioxnqljywhfyxccuh.supabase.co';
const _supabaseAnonKey = 'sb_publishable_y9uJosVyntByD4xBPr4AUA_q1i0Dlci';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: _supabaseUrl,
    anonKey: _supabaseAnonKey,
  );

  runApp(const VegePetApp());
}

final supabase = Supabase.instance.client;

class VegePetApp extends StatelessWidget {
  const VegePetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VegePet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

enum _ViewStatus { loading, error, ready }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _ViewStatus _status = _ViewStatus.loading;
  String? _errorMessage;

  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _petSpecies = [];
  Map<String, dynamic>? _activePet;

  String? _selectedSpeciesId;
  bool _isAdopting = false;

  List<Map<String, dynamic>> _todayMealLogs = [];
  bool _isLoggingMeal = false;
  bool _firstMealPopupShownThisSession = false;

  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _resolutionController = TextEditingController();
  String? _selectedGender;
  String? _selectedDietGoal;
  bool _isSavingProfile = false;

  static const List<String> _genderOptions = ['여자', '남자'];
  static const List<String> _dietGoalOptions = ['다이어트', '근력향상', '혈당조정'];

  bool _debugExpanded = false;
  bool _isInteracting = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _resolutionController.dispose();
    super.dispose();
  }

  bool _isProfileComplete() {
    final p = _profile;
    if (p == null) return false;
    bool nonEmpty(dynamic v) =>
        v != null && v.toString().trim().isNotEmpty;
    return nonEmpty(p['nickname']) &&
        nonEmpty(p['gender']) &&
        nonEmpty(p['diet_goal']) &&
        nonEmpty(p['resolution_text']);
  }

  void _syncProfileFormFromFetched() {
    final p = _profile;
    if (p == null) return;
    if (_nicknameController.text.isEmpty && p['nickname'] != null) {
      _nicknameController.text = p['nickname'].toString();
    }
    if (_resolutionController.text.isEmpty && p['resolution_text'] != null) {
      _resolutionController.text = p['resolution_text'].toString();
    }
    _selectedGender ??= p['gender']?.toString();
    _selectedDietGoal ??= p['diet_goal']?.toString();
  }

  Future<void> _saveProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      _showSnack('로그인이 필요해요.');
      return;
    }

    final nickname = _nicknameController.text.trim();
    final resolution = _resolutionController.text.trim();

    if (nickname.isEmpty) {
      _showSnack('닉네임을 입력해주세요.');
      return;
    }
    if (_selectedGender == null) {
      _showSnack('성별을 선택해주세요.');
      return;
    }
    if (_selectedDietGoal == null) {
      _showSnack('식단 목적을 선택해주세요.');
      return;
    }
    if (resolution.isEmpty) {
      _showSnack('다짐 한마디를 입력해주세요.');
      return;
    }

    setState(() => _isSavingProfile = true);
    try {
      await supabase.from('profiles').update({
        'nickname': nickname,
        'gender': _selectedGender,
        'diet_goal': _selectedDietGoal,
        'resolution_text': resolution,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);

      await _fetchProfile();

      if (!mounted) return;
      setState(() => _isSavingProfile = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingProfile = false);
      _showSnack('프로필 저장 실패: $e');
    }
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
        _fetchTodayMealLogs(),
      ]);

      _syncProfileFormFromFetched();

      if (!mounted) return;
      setState(() {
        _status = _ViewStatus.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _ViewStatus.error;
        _errorMessage = e.toString();
      });
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

      await supabase.from('user_pets').update({
        'affection': currentAffection + 1,
        dateColumn: today,
      }).eq('id', petId);

      await _fetchActivePet();

      if (!mounted) return;
      setState(() => _isInteracting = false);
      _showSnack('$label 성공! 애정도 +1');
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

  String _todayDateStr() {
    final d = DateTime.now();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Future<void> _adoptSelectedPet() async {
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

    setState(() => _isAdopting = true);

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
      setState(() {
        _selectedSpeciesId = null;
        _isAdopting = false;
      });

      // 분양 완료 직후, 닉네임이 아직 null인 상태에서 바로 마당이 노출되지 않도록
      // 이름 짓기 다이얼로그를 띄운다.
      await _showNicknameDialog();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAdopting = false);
      _showSnack('분양 저장에 실패했어요: $e');
    }
  }

  // 분양 직후에 뜨는 닉네임 입력 다이얼로그.
  // 허용 문자: 한글/영문 대소문자/숫자, 길이 2~8자, 공백·특수문자 금지.
  Future<void> _showNicknameDialog() async {
    final pet = _activePet;
    if (pet == null || !mounted) return;

    final controller = TextEditingController();
    final pattern = RegExp(r'^[가-힣a-zA-Z0-9]{2,8}$');
    String? errorText;
    bool saving = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              Future<void> save() async {
                final text = controller.text.trim();
                if (text.isEmpty) {
                  setDialogState(() => errorText = '이름을 입력해주세요.');
                  return;
                }
                if (text.length < 2 || text.length > 8) {
                  setDialogState(() => errorText = '이름은 2~8자로 입력해주세요.');
                  return;
                }
                if (!pattern.hasMatch(text)) {
                  setDialogState(
                      () => errorText = '특수문자는 사용할 수 없어요.');
                  return;
                }

                setDialogState(() {
                  saving = true;
                  errorText = null;
                });

                try {
                  await supabase
                      .from('user_pets')
                      .update({'nickname': text}).eq('id', pet['id']);

                  await _fetchActivePet();

                  if (!mounted) return;
                  setState(() {});

                  if (ctx.mounted) Navigator.of(ctx).pop();
                  _showSnack('이름이 저장되었어요!');
                } catch (e) {
                  if (!ctx.mounted) return;
                  setDialogState(() {
                    saving = false;
                    errorText = '저장 실패: $e';
                  });
                }
              }

              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                title: const Text('아기 베지펫이 분양 되었어요🥹'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('귀여운 이름을 지어주세요!'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLength: 8,
                      enabled: !saving,
                      decoration: InputDecoration(
                        hintText: '예: 초록이',
                        border: const OutlineInputBorder(),
                        errorText: errorText,
                        helperText: '한글·영문·숫자 2~8자 (공백/특수문자 불가)',
                        counterText: '',
                        isDense: true,
                      ),
                      onSubmitted: (_) {
                        if (!saving) save();
                      },
                    ),
                  ],
                ),
                actions: [
                  FilledButton(
                    onPressed: saving ? null : save,
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('저장'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
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
        _fetchTodayMealLogs(),
      ]);
      if (mounted) setState(() {});
    } catch (e) {
      _showSnack('펫 정보 조회 실패: $e');
    }
  }

  Future<void> _signOut() async {
    try {
      await supabase.auth.signOut();
      if (!mounted) return;
      setState(() {
        _profile = null;
        _petSpecies = [];
        _activePet = null;
        _selectedSpeciesId = null;
        _todayMealLogs = [];
        _firstMealPopupShownThisSession = false;
        _nicknameController.clear();
        _resolutionController.clear();
        _selectedGender = null;
        _selectedDietGoal = null;
      });
      await _bootstrap();
    } catch (e) {
      _showSnack('로그아웃 실패: $e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _ViewStatus.loading:
        return const _LoadingView();
      case _ViewStatus.error:
        return _ErrorView(
          message: _errorMessage,
          onRetry: _bootstrap,
        );
      case _ViewStatus.ready:
        return _buildReadyScaffold();
    }
  }

  Widget _buildReadyScaffold() {
    final profileComplete = _isProfileComplete();
    final hasActivePet = _activePet != null;

    final List<Widget> mainChildren;
    if (!profileComplete) {
      mainChildren = _buildProfileFormContent();
    } else if (!hasActivePet) {
      mainChildren = _buildAdoptContent();
    } else {
      mainChildren = _buildYardContent();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('VegePet'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...mainChildren,
              const SizedBox(height: 24),
              _buildDebugSection(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 마당 (active pet 있음) ----------

  List<Widget> _buildYardContent() {
    return [
      _buildYardHeader(),
      const SizedBox(height: 16),
      _buildYardActions(),
    ];
  }

  // 가로형 마당 느낌의 홈 헤더.
  // 상단에는 좌측 펫정보 아이콘 버튼 1개 / 우측 게임 메뉴 아이콘 버튼 1개만 보인다.
  // 각각 눌러야 패널이 열리도록 BottomSheet로 전환했다.
  Widget _buildYardHeader() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 320,
        child: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFDAF3DD), Color(0xFF8ECB94)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 80,
              child: Container(color: const Color(0xFF62A86B)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 18,
              child: _buildCenterPetVisual(),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: _cornerIconButton(
                icon: Icons.pets,
                tooltip: '펫 정보',
                onTap: _openPetStatusSheet,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: _cornerIconButton(
                icon: Icons.apps_rounded,
                tooltip: '메뉴',
                onTap: _openMenuSheet,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cornerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
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
          padding: const EdgeInsets.all(10),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: 22, color: theme.colorScheme.primary),
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
  void _openPetStatusSheet() {
    if (_activePet == null) return;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> runInteraction(String action) async {
              await _interactPet(action);
              if (sheetCtx.mounted) setSheetState(() {});
            }

            return _buildPetStatusSheetContent(
              onMeal: () {
                Navigator.of(sheetCtx).pop();
                _openMealSheet();
              },
              onPlay: () => runInteraction('play'),
              onPet: () => runInteraction('pet'),
            );
          },
        );
      },
    );
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
    final affection = pet['affection']?.toString() ?? '0';

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
                Expanded(
                  child: _sheetStatChip(
                    Icons.favorite_outline,
                    '애정도',
                    affection,
                  ),
                ),
              ],
            ),
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
    final color = doneToday ? Colors.orange : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: ${doneToday ? '완료' : '가능'}',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
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

  // 펫 상태창 > 먹이주기에서 호출되는 식단 인증 전용 BottomSheet.
  // 아점/저녁 선택 UI와 오늘 완료 여부를 이 시트 안에서 한 번에 처리한다.
  void _openMealSheet() {
    if (_activePet == null) return;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> runLog(String slot) async {
              await _logMeal(slot);
              if (sheetCtx.mounted) setSheetState(() {});
            }

            return _buildMealSheetContent(onLog: runLog);
          },
        );
      },
    );
  }

  Widget _buildMealSheetContent({
    required Future<void> Function(String slot) onLog,
  }) {
    final theme = Theme.of(context);
    final brunchDone = _todayMealLogs.any((m) => m['meal_slot'] == 'brunch');
    final dinnerDone = _todayMealLogs.any((m) => m['meal_slot'] == 'dinner');

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
                  '오늘의 식단 인증 (테스트)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildMealButton(
                    label: '아점 먹이주기 테스트',
                    done: brunchDone,
                    onPressed: (brunchDone || _isLoggingMeal)
                        ? null
                        : () => onLog('brunch'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMealButton(
                    label: '저녁 먹이주기 테스트',
                    done: dinnerDone,
                    onPressed: (dinnerDone || _isLoggingMeal)
                        ? null
                        : () => onLog('dinner'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _mealStatusChip('아점', brunchDone),
                const SizedBox(width: 6),
                _mealStatusChip('저녁', dinnerDone),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 우측 상단 게임 메뉴 아이콘 버튼을 누르면 열리는 8개 메뉴 허브.
  void _openMenuSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return _buildMenuSheetContent(
          onTap: (label) {
            Navigator.of(sheetCtx).pop();
            _onMenuTap(label);
          },
        );
      },
    );
  }

  Widget _buildMenuSheetContent({required ValueChanged<String> onTap}) {
    final items = <(IconData, String)>[
      (Icons.person_outline, '프로필'),
      (Icons.event_note_outlined, '식단일지'),
      (Icons.backpack_outlined, '가방'),
      (Icons.storefront_outlined, '상점'),
      (Icons.menu_book_outlined, '도감'),
      (Icons.auto_stories_outlined, '스토리'),
      (Icons.help_outline, '도움말'),
      (Icons.settings_outlined, '설정'),
    ];

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

  void _onMenuTap(String label) {
    if (label == '설정') {
      _showSnack('나중에 이메일 연동 메뉴가 여기에 들어올 예정입니다.');
    } else {
      _showSnack('나중에 구현 예정: $label');
    }
  }

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

  Widget _buildYardActions() {
    return OutlinedButton.icon(
      onPressed: _refreshAll,
      icon: const Icon(Icons.refresh),
      label: const Text('마당 새로고침'),
    );
  }

  // ---------- 프로필 입력 (미완성 상태) ----------

  List<Widget> _buildProfileFormContent() {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '프로필을 입력해주세요',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '베지펫이 더 잘 도와드릴 수 있도록 기본 정보를 입력해주세요.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _profileFormCard(
        label: '닉네임',
        child: TextField(
          controller: _nicknameController,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '예: 초록이',
            border: OutlineInputBorder(),
            counterText: '',
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(height: 12),
      _profileFormCard(
        label: '성별',
        child: Wrap(
          spacing: 8,
          children: _genderOptions.map((g) {
            final selected = _selectedGender == g;
            return ChoiceChip(
              label: Text(g),
              selected: selected,
              onSelected: (v) {
                setState(() => _selectedGender = v ? g : null);
              },
            );
          }).toList(),
        ),
      ),
      const SizedBox(height: 12),
      _profileFormCard(
        label: '식단 목적',
        child: Wrap(
          spacing: 8,
          children: _dietGoalOptions.map((g) {
            final selected = _selectedDietGoal == g;
            return ChoiceChip(
              label: Text(g),
              selected: selected,
              onSelected: (v) {
                setState(() => _selectedDietGoal = v ? g : null);
              },
            );
          }).toList(),
        ),
      ),
      const SizedBox(height: 12),
      _profileFormCard(
        label: '다짐 한마디',
        child: TextField(
          controller: _resolutionController,
          maxLines: 3,
          maxLength: 100,
          decoration: const InputDecoration(
            hintText: '예: 매일 채소 한 끼는 꼭 지킬게요!',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: _isSavingProfile ? null : _saveProfile,
          icon: _isSavingProfile
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.check),
          label: Text(_isSavingProfile ? '저장 중...' : '시작하기'),
        ),
      ),
    ];
  }

  Widget _profileFormCard({required String label, required Widget child}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  // ---------- 첫 펫 분양 (active pet 없음) ----------

  List<Widget> _buildAdoptContent() {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '첫 펫을 선택해주세요',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '함께할 첫 베지펫을 분양받아보세요.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (_petSpecies.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('표시할 펫이 없어요.')),
        )
      else
        _buildSpeciesGrid(),
      const SizedBox(height: 16),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: (_selectedSpeciesId != null && !_isAdopting)
              ? _adoptSelectedPet
              : null,
          icon: _isAdopting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.favorite),
          label: Text(_isAdopting ? '분양 중...' : '이 펫과 시작하기'),
        ),
      ),
    ];
  }

  Widget _buildSpeciesGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _petSpecies.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemBuilder: (context, index) {
        final species = _petSpecies[index];
        final id = species['id']?.toString();
        final name = species['name_ko']?.toString() ?? '-';
        final family = species['family']?.toString() ?? '';
        final familyKo = _familyToKorean(family);
        final isSelected = id != null && id == _selectedSpeciesId;

        return _SpeciesCard(
          name: name,
          familyKo: familyKo,
          family: family,
          selected: isSelected,
          onTap: id == null
              ? null
              : () {
                  setState(() {
                    _selectedSpeciesId = isSelected ? null : id;
                  });
                },
        );
      },
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
      _kv('diet_goal', p['diet_goal']?.toString() ?? '(없음)'),
      _kv('resolution_text', p['resolution_text']?.toString() ?? '(없음)'),
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

class _SpeciesCard extends StatelessWidget {
  final String name;
  final String familyKo;
  final String family;
  final bool selected;
  final VoidCallback? onTap;

  const _SpeciesCard({
    required this.name,
    required this.familyKo,
    required this.family,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surface;
    final borderColor = selected
        ? theme.colorScheme.primary
        : Colors.grey.withValues(alpha: 0.3);
    final icon = family == 'cat' ? Icons.pets : Icons.cruelty_free_outlined;
    final tagColor = family == 'cat'
        ? Colors.orange.withValues(alpha: 0.15)
        : Colors.blue.withValues(alpha: 0.15);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: borderColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: tagColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      familyKo,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const Spacer(),
                  if (selected)
                    Icon(Icons.check_circle,
                        size: 20, color: theme.colorScheme.primary),
                ],
              ),
              const Spacer(),
              Center(
                child: Icon(icon,
                    size: 48, color: theme.colorScheme.onSurface),
              ),
              const Spacer(),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text(
              '베지펫을 준비 중이에요...',
              style: TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 56, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text(
                '앱 준비 중 문제가 발생했어요',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
              const SizedBox(height: 24),
              if (message != null)
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
