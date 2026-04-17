import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  // 1. 플러터 프레임워크가 완전히 준비될 때까지 기다립니다.
  WidgetsFlutterBinding.ensureInitialized();

  // 2. 수파베이스를 초기화합니다.
  await Supabase.initialize(
    url: 'https://rzsioxnqljywhfyxccuh.supabase.co',
    anonKey: 'sb_publishable_y9uJosVyntByD4xBPr4AUA_q1i0Dlci',
  );

  runApp(const VegePetApp());
}

class VegePetApp extends StatelessWidget {
  const VegePetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '베지펫',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text('수파베이스 연결 완료!'),
        ),
      ),
    );
  }
}