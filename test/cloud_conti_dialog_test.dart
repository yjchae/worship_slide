import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/conti_cloud_repository.dart';
import 'package:worship_slides/src/features/praise/data/sync_service.dart';
import 'package:worship_slides/src/features/praise/domain/worship_conti.dart';
import 'package:worship_slides/src/features/praise/presentation/cloud_conti_dialog.dart';

class FakeCloudService extends SyncService {
  final listing =
      Completer<({List<CloudConti> cloud, Map<String, WorshipConti> local})>();
  final downloading = Completer<int>();
  final deleting = Completer<void>();
  final extraListings =
      <
        Completer<({List<CloudConti> cloud, Map<String, WorshipConti> local})>
      >[];
  int listingCalls = 0;
  bool cancelled = false;
  @override
  Future<({List<CloudConti> cloud, Map<String, WorshipConti> local})>
  listCloudContis() {
    final call = listingCalls++;
    return call == 0 ? listing.future : extraListings[call - 1].future;
  }

  @override
  Future<int> downloadConti(CloudConti conti) => downloading.future;
  @override
  Future<void> deleteCloudConti(CloudConti conti) => deleting.future;
  @override
  void cancel() {
    cancelled = true;
  }
}

CloudConti sample() => CloudConti(
  uid: 'a' * 32,
  name: '아주 긴 예배 콘티 이름을 가진 주일 오후 예배와 찬양 순서',
  createdAt: DateTime(2026, 1, 1),
  itemCount: 12,
  uploadedBy: '예배실 컴퓨터',
  uploadedAt: DateTime(2026, 1, 2),
);

void main() {
  Future<void> open(WidgetTester tester, FakeCloudService service) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(body: CloudContiDialog(service: service)),
      ),
    );
    await tester.pump();
  }

  testWidgets('목록 로딩과 긴 이름 및 받기 진행을 작은 창에서 보여 준다', (tester) async {
    final service = FakeCloudService();
    await open(tester, service);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    service.listing.complete((
      cloud: [sample()],
      local: <String, WorshipConti>{},
    ));
    await tester.pumpAndSettle();
    expect(find.text(sample().name), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('내려받기'));
    await tester.pump();
    expect(find.byTooltip('취소'), findsOneWidget);
    expect(find.text('내려받는 중…'), findsOneWidget);
    await tester.tap(find.byTooltip('취소'));
    expect(service.cancelled, isTrue);
    service.downloading.completeError(const FileSystemException('연결 실패'));
    await tester.pumpAndSettle();
    expect(find.textContaining('연결 실패'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('오래된 목록 요청의 오류가 새 결과를 덮어쓰지 않는다', (tester) async {
    final service = FakeCloudService();
    final refreshed =
        Completer<
          ({List<CloudConti> cloud, Map<String, WorshipConti> local})
        >();
    service.extraListings.add(refreshed);
    await open(tester, service);
    await tester.tap(find.text('새로 고침'));
    await tester.pump();
    refreshed.complete((cloud: [sample()], local: <String, WorshipConti>{}));
    await tester.pumpAndSettle();
    service.listing.completeError(const FileSystemException('이전 요청 실패'));
    await tester.pumpAndSettle();
    expect(find.text(sample().name), findsOneWidget);
    expect(find.textContaining('이전 요청 실패'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('삭제 확인 후 진행과 실패를 표시한다', (tester) async {
    final service = FakeCloudService();
    await open(tester, service);
    service.listing.complete((
      cloud: [sample()],
      local: <String, WorshipConti>{},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('클라우드에서 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기').last);
    await tester.pump();
    expect(find.text('클라우드에서 지우는 중…'), findsOneWidget);
    service.deleting.completeError(const FileSystemException('삭제 실패'));
    await tester.pumpAndSettle();
    expect(find.textContaining('삭제 실패'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('목록 읽기 실패는 오류만 간결하게 표시한다', (tester) async {
    final service = FakeCloudService();
    await open(tester, service);
    service.listing.completeError(const FileSystemException('네트워크 연결 실패'));
    await tester.pumpAndSettle();
    expect(find.textContaining('네트워크 연결 실패'), findsOneWidget);
    expect(find.textContaining('FileSystemException'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
