import 'package:vegepet/l10n/app_localizations.dart';

enum SupportDocType { terms, privacy, operation, guardian, dataDeletion }

class SupportDocumentSection {
  const SupportDocumentSection({required this.title, required this.body});

  final String title;
  final String body;
}

class SupportDocument {
  const SupportDocument({required this.title, required this.sections});

  final String title;
  final List<SupportDocumentSection> sections;
}

SupportDocument buildSupportDocument(
  SupportDocType type,
  String localeCode,
  AppLocalizations l10n,
) {
  final isEn = localeCode == 'en';

  switch (type) {
    case SupportDocType.terms:
      return SupportDocument(
        title: l10n.termsOfService,
        sections: [
          SupportDocumentSection(
            title: isEn ? '1. Purpose' : '1. 목적',
            body: isEn
                ? 'This document explains the basic rules and terms for using VegePet.'
                : '베지펫 서비스 이용 조건과 기본 규칙을 안내합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '2. What VegePet Provides' : '2. 서비스 내용',
            body: isEn
                ? 'VegePet provides meal photo verification, AI-based meal feedback, pet growth, and features such as the diary, bag, collection, and settings. Some features may be limited during the MVP phase or added later.'
                : '식단 사진 인증, AI 기반 식단 평가, 펫 육성, 도감/가방/식단일지/설정 기능을 제공합니다. 일부 기능은 MVP 단계 또는 추후 업데이트 대상일 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '3. Account & Email Linking' : '3. 계정 및 이메일 연동',
            body: isEn
                ? 'Users can start as a guest and optionally link an email account via OTP. Users are responsible for entering their own valid email address.'
                : '게스트 체험 계정으로 시작할 수 있으며 OTP로 이메일 연동이 가능합니다. 사용자는 본인 이메일을 정확히 입력해야 합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '4. User Responsibilities' : '4. 사용자 책임',
            body: isEn
                ? 'Users must not enter false information, use another person’s email, or attempt abnormal/system-abusive access.'
                : '허위 정보 입력, 타인 이메일 사용, 비정상 접근 및 시스템 악용을 금지합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '5. Health Notice' : '5. 식단 평가와 건강 관련 고지',
            body: isEn
                ? 'AI meal feedback is for reference only and is not medical diagnosis or treatment. Consult professionals for health conditions or dietary restrictions.'
                : 'AI 식단 평가는 참고용이며 의료/진단/치료 목적이 아닙니다. 건강 상태나 식단 제한이 있으면 전문가 상담이 필요합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '6. Game Items/Data' : '6. 아이템/분양권/게임 데이터',
            body: isEn
                ? 'In-app items and tickets are for gameplay only, not cash-equivalent assets. Shop/payment features may be limited in MVP.'
                : '아이템과 분양권은 게임 내 기능이며 현금성 자산이 아닙니다. 상점/결제 기능은 MVP 단계에서 제한되거나 2차 오픈 예정일 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '7. Service Changes' : '7. 서비스 변경 및 중단',
            body: isEn
                ? 'Features may be changed, improved, or suspended for operations, maintenance, and updates.'
                : '기능 개선, 오류 수정, 운영상 필요에 따라 서비스 내용이 변경되거나 중단될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '8. Use Restrictions' : '8. 이용 제한',
            body: isEn
                ? 'VegePet may restrict service use for abuse, policy violations, or infringement of others’ rights.'
                : '비정상 이용, 시스템 악용, 타인 권리 침해 시 서비스 이용이 제한될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '9. Limitation of Liability' : '9. 책임 제한',
            body: isEn
                ? 'Some features may be limited by network/device environments. VegePet does not guarantee health outcomes.'
                : '네트워크/기기 환경에 따라 일부 기능이 제한될 수 있으며, 앱은 건강 결과를 보장하지 않습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '10. Contact' : '10. 문의',
            body: 'acoustic.jwg@gmail.com',
          ),
        ],
      );
    case SupportDocType.privacy:
      return SupportDocument(
        title: l10n.privacyPolicy,
        sections: [
          SupportDocumentSection(
            title: isEn ? '1. Data We Collect' : '1. 수집하는 정보',
            body: isEn
                ? 'Account info (anonymous user id, linked email), profile info (nickname, gender, age range, diet goal), pet/game data, meal photos/logs, settings and technical logs may be collected.'
                : '계정 정보(익명 사용자 ID, 이메일 연동 시 이메일), 프로필 정보, 펫/게임 데이터, 식단 사진/기록, 설정 정보, 기술 로그 등이 수집될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '2. Collection Methods' : '2. 수집 방법',
            body: isEn
                ? 'Data is collected via user input, meal photo uploads, and automatic records generated during app use through Supabase services.'
                : '사용자 직접 입력, 식단 사진 업로드, 앱 이용 과정에서 자동 생성되는 기록을 통해 수집하며 Supabase 서비스를 통해 저장됩니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '3. Purposes of Use' : '3. 이용 목적',
            body: isEn
                ? 'Data is used for account identification, data continuity, meal evaluation, gameplay features, notifications, support responses, and service improvement.'
                : '계정 식별, 데이터 유지, 식단 인증/평가, 게임 기능 제공, 알림 제공, 고객 문의 대응, 오류 수정 및 서비스 개선에 사용됩니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '4. Third-party Processing' : '4. 제3자 처리/외부 서비스',
            body: isEn
                ? 'VegePet may use Supabase (auth/database/storage/functions), OpenAI (meal analysis), and platform services from Apple/Google. Remote push providers may be added later.'
                : 'Supabase(인증/DB/스토리지/함수), OpenAI(식단 분석), Apple/Google 플랫폼 기능을 사용하며, 원격 푸시는 추후 FCM 등 외부 서비스를 사용할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '5. Meal Photo Caution' : '5. 식단 사진 및 민감 정보 주의',
            body: isEn
                ? 'Users should avoid including personal identifiers in meal photos and avoid entering sensitive health details in notes.'
                : '식단 사진에 개인 식별 정보가 노출되지 않도록 촬영하고, 민감한 건강 정보를 기록에 입력하지 않도록 권장합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '6. Retention' : '6. 보관 기간',
            body: isEn
                ? 'Data is deleted upon account deletion request unless legal retention requirements apply. Backup/log records may be retained for a limited period.'
                : '회원 탈퇴 또는 삭제 요청 시 데이터를 삭제하며, 법령상 보관 의무가 있는 경우 예외가 있을 수 있습니다. 백업/로그는 일정 기간 보관될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '7. Account & Data Deletion' : '7. 계정 및 데이터 삭제',
            body: isEn
                ? 'Users can delete data in Settings > Account > Delete Account. External deletion requests can be sent to acoustic.jwg@gmail.com.'
                : '설정 > 계정 > 회원 탈퇴에서 계정 및 관련 데이터 삭제가 가능합니다. 앱 접근이 어려우면 acoustic.jwg@gmail.com으로 삭제 요청할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '8. User Rights' : '8. 사용자 권리',
            body: isEn
                ? 'Users may request access, correction, linkage updates, or deletion of their data.'
                : '사용자는 열람, 수정, 삭제, 계정 연동 관련 요청을 할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '9. Children & Guardians' : '9. 아동 및 보호자',
            body: isEn
                ? 'Minor users should use VegePet under guardian guidance. Guardian verification may be required under local laws.'
                : '미성년자는 보호자 지도하에 사용을 권장하며, 관련 법령에 따라 보호자 동의가 필요할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '10. Security' : '10. 보안',
            body: isEn
                ? 'Reasonable protection measures are applied, but complete security cannot be guaranteed in all internet/mobile environments.'
                : '합리적인 보호 조치를 적용하지만 인터넷/모바일 환경 특성상 완전한 보안을 보장할 수는 없습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '11. Policy Updates' : '11. 변경 고지',
            body: isEn
                ? 'Policy updates may be announced in-app or via update notices.'
                : '정책 변경 시 앱 내 공지 또는 업데이트 안내를 통해 고지할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '12. Contact' : '12. 문의',
            body: 'acoustic.jwg@gmail.com',
          ),
        ],
      );
    case SupportDocType.operation:
      return SupportDocument(
        title: l10n.operationPolicy,
        sections: [
          SupportDocumentSection(
            title: isEn ? '1. Purpose' : '1. 운영 목적',
            body: isEn
                ? 'Provide a stable meal-recording and VegePet growth experience.'
                : '안정적인 식단 기록 및 베지펫 육성 경험 제공을 목적으로 운영합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '2. Service Principles' : '2. 서비스 운영 원칙',
            body: isEn
                ? 'We prioritize reliability, bug fixes, and feature improvements while distinguishing MVP and future features.'
                : '오류 수정, 기능 개선, 데이터 안정성을 우선하며 MVP 기능과 향후 기능을 구분해 운영합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '3. Prohibited Activities' : '3. 금지 행위',
            body: isEn
                ? 'Using others’ accounts/emails, tampering with data, abnormal requests, and repeated false certification are prohibited.'
                : '타인 계정/이메일 사용, 데이터 변조, 비정상 요청, 허위 인증 반복 등은 금지됩니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '4. Data Management' : '4. 데이터 및 기록 관리',
            body: isEn
                ? 'Meal photos, diary entries, and pet data are managed per user account; logs may be used for error analysis.'
                : '식단 사진/일지/펫 데이터는 계정 기준으로 관리되며, 오류 분석을 위해 일부 로그를 활용할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '5. AI Evaluation Operations' : '5. AI 식단 평가 운영 기준',
            body: isEn
                ? 'AI meal feedback is for reference only and may vary depending on photo quality or the surrounding environment. Re-capture guidance may be shown for uncertain results.'
                : 'AI 결과는 참고용이며 사진 품질/조명 등에 따라 달라질 수 있습니다. 불확실 판정 시 재촬영 안내가 제공될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '6. Notifications' : '6. 알림 운영',
            body: isEn
                ? 'Meal reminders can be toggled by users. Announcement/event notifications may be sent in later updates.'
                : '먹이 알림은 사용자가 ON/OFF할 수 있으며, 공지/이벤트 알림은 추후 운영자가 발송할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '7. Item/Reward Operations' : '7. 아이템/보상 운영',
            body: isEn
                ? 'In-app items are gameplay elements. Shop/payment may be limited or deferred in MVP.'
                : '분양권/아이템은 게임 진행용 요소이며 상점/결제는 MVP에서 제한되거나 2차 오픈 예정일 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '8. Restrictions & Actions' : '8. 이용 제한 및 조치',
            body: isEn
                ? 'Service use may be restricted for serious abuse, security threats, or rights infringement.'
                : '심각한 악용, 보안 위협, 권리 침해 행위에 대해 이용 제한 조치가 이뤄질 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '9. Policy Updates' : '9. 정책 변경',
            body: isEn
                ? 'Operational policies may change as needed for service sustainability.'
                : '서비스 운영상 필요에 따라 운영정책이 변경될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '10. Contact' : '10. 문의',
            body: 'acoustic.jwg@gmail.com',
          ),
        ],
      );
    case SupportDocType.guardian:
      return SupportDocument(
        title: l10n.guardianGuide,
        sections: [
          SupportDocumentSection(
            title: isEn ? '1. About VegePet' : '1. 베지펫 소개',
            body: isEn
                ? 'VegePet is a gamified diet management app that combines meal verification with raising a virtual pet.'
                : '베지펫은 식단 인증과 펫 육성을 결합한 게임형 식단관리 앱입니다.',
          ),
          SupportDocumentSection(
            title: isEn
                ? '2. Why Guardian Guidance Matters'
                : '2. 보호자 확인이 필요한 이유',
            body: isEn
                ? 'The app may handle profile and meal-related information, so guardian guidance is recommended for minors.'
                : '앱은 프로필/식단 관련 정보를 다룰 수 있어 미성년자는 보호자 지도하에 사용하는 것을 권장합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '3. Meal Photo Safety' : '3. 식단 사진 촬영 주의',
            body: isEn
                ? 'Avoid capturing personal identifiers such as faces, addresses, school names, or contact details.'
                : '얼굴, 주소, 학교명, 연락처 등 개인 식별 정보가 노출되지 않도록 음식 중심으로 촬영해주세요.',
          ),
          SupportDocumentSection(
            title: isEn ? '4. Health Caution' : '4. 건강 관련 주의',
            body: isEn
                ? 'AI meal feedback does not replace professional medical or nutrition advice.'
                : 'AI 식단 평가는 참고용이며 의료 조언을 대체하지 않습니다. 필요한 경우 전문가 상담이 필요합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '5. Payments & Shop' : '5. 결제 및 상점',
            body: isEn
                ? 'In MVP, payment/shop features may be limited or unavailable. Future paid features should include guardian-friendly notices.'
                : 'MVP에서는 상점/결제가 제한 또는 2차 오픈 예정이며, 유료 기능 추가 시 보호자 확인 고지가 강화되어야 합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '6. Notification Control' : '6. 알림 관리',
            body: isEn
                ? 'Meal and announcement notifications can be turned on or off in Settings.'
                : '먹이 알림과 공지 알림은 설정에서 ON/OFF할 수 있어 보호자가 이용 상태를 확인할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '7. Account & Data Deletion' : '7. 계정 및 데이터 삭제',
            body: isEn
                ? 'Data can be deleted from Settings > Account > Delete Account. Guardians may request deletion via email.'
                : '설정 > 계정 > 회원 탈퇴로 데이터 삭제가 가능하며, 보호자는 이메일로 삭제를 요청할 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '8. Healthy Use Habits' : '8. 안전한 이용 습관',
            body: isEn
                ? 'Avoid excessive use and review meal habits together. Prioritize real health status and professional guidance.'
                : '과도한 사용을 피하고 보호자와 함께 식단을 점검하세요. 앱 결과보다 실제 건강 상태를 우선하세요.',
          ),
        ],
      );
    case SupportDocType.dataDeletion:
      return SupportDocument(
        title: l10n.accountDataDeletionGuide,
        sections: [
          SupportDocumentSection(
            title: isEn ? '1. In-app Deletion Path' : '1. 앱 내 삭제 경로',
            body: isEn
                ? 'Go to Settings > Account > Delete Account to remove your account and related data.'
                : '설정 > 계정 > 회원 탈퇴에서 계정 및 관련 데이터 삭제가 가능합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '2. Data That Will Be Deleted' : '2. 삭제되는 데이터',
            body: isEn
                ? 'Profile data, linked email info, pet/collection/bag/ticket records, meal photos/logs, and diary entries are deleted.'
                : '프로필, 이메일 연동 정보, 펫/도감/가방/분양권 데이터, 식단 사진/인증 기록, 식단일지 입력값 등이 삭제됩니다.',
          ),
          SupportDocumentSection(
            title: isEn
                ? '3. Data That May Be Retained'
                : '3. 삭제되지 않거나 별도 보관될 수 있는 정보',
            body: isEn
                ? 'Legally required records may be retained for required periods. Non-identifying logs/backups may be deleted after retention windows.'
                : '법령상 보관 의무가 있는 정보는 필요한 기간 보관될 수 있으며, 비식별 로그/백업은 일정 기간 후 삭제될 수 있습니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '4. External Deletion Request' : '4. 앱 외부 삭제 요청',
            body: isEn
                ? 'If app access is unavailable, send a request to acoustic.jwg@gmail.com.'
                : '앱 접근이 어려운 경우 acoustic.jwg@gmail.com 으로 삭제 요청이 가능합니다.',
          ),
          SupportDocumentSection(
            title: isEn ? '5. Processing Timeline' : '5. 처리 기간',
            body: isEn
                ? 'Requests are processed within a reasonable period after confirmation. Additional identity verification may be required.'
                : '요청 확인 후 합리적인 기간 내 처리되며, 본인 확인을 위해 추가 정보 요청이 있을 수 있습니다.',
          ),
        ],
      );
  }
}