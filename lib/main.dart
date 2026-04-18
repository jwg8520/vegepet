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

  bool _debugExpanded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
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
      ]);

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
          'id, user_id, pet_species_id, nickname, stage, affection, is_active, is_resident, graduated_at, created_at, pet_species:pet_species_id(id, code, name_ko, family, sort_order)',
        )
        .eq('user_id', user.id)
        .eq('is_active', true)
        .maybeSingle();

    _activePet = data == null ? null : Map<String, dynamic>.from(data);
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

    setState(() => _isAdopting = true);
    try {
      await supabase.from('user_pets').insert({
        'user_id': user.id,
        'pet_species_id': _selectedSpeciesId,
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAdopting = false);
      _showSnack('분양 저장에 실패했어요: $e');
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
      await _fetchActivePet();
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
    final hasActivePet = _activePet != null;

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
              if (hasActivePet) ..._buildYardContent() else ..._buildAdoptContent(),
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
      _buildYardCard(),
      const SizedBox(height: 16),
      _buildYardActions(),
    ];
  }

  Widget _buildYardCard() {
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

    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          children: [
            Icon(
              family == 'cat' ? Icons.pets : Icons.cruelty_free_outlined,
              size: 64,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(height: 16),
            Text(
              '마당에 입장했어요',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$familyKo · $speciesName',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _statItem(Icons.child_care_outlined, '성장', stageKo),
                      _statItem(
                          Icons.favorite_outline, '애정도', affection.toString()),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '이제 식단 인증과 상호작용으로\n베지펫을 키워보세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(value,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildYardActions() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _refreshAll,
            icon: const Icon(Icons.refresh),
            label: const Text('체험 새로고침'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _refreshSpecies,
            icon: const Icon(Icons.pets_outlined),
            label: const Text('분양 데이터 다시 조회'),
          ),
        ),
      ],
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
      _kv('account_type', accountType),
      _kv('gold_balance', p['gold_balance']?.toString() ?? '-'),
      _kv('created_at', p['created_at']?.toString() ?? '-'),
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
      _kv('graduated_at', pet['graduated_at']?.toString() ?? '(null)'),
      _kv('created_at', pet['created_at']?.toString() ?? '-'),
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
      case 'growth':
        return '성장기';
      case 'mature':
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
