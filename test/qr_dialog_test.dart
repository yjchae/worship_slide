import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

// 휴대폰 싱어 다이얼로그(praise_home_page.dart _showMobileSinger)와 같은 구조.
// QrImageView 는 AlertDialog 의 크기 재기에서 터지므로 QrPainter 를 직접 쓴다 — 그걸 지킨다.
void main() {
  testWidgets('AlertDialog + Wrap 안의 QR 이 레이아웃 오류 없이 그려진다', (t) async {
    await t.pumpWidget(MaterialApp(
      home: AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(children: [
            Column(mainAxisSize: MainAxisSize.min, children: [
              const SelectableText('http://192.168.0.2:8765'),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: CustomPaint(
                  size: const Size.square(180),
                  painter: QrPainter(
                    data: 'http://192.168.0.2:8765',
                    version: QrVersions.auto,
                  ),
                ),
              ),
            ]),
          ]),
        ]),
      ),
    ));
    expect(t.takeException(), isNull);
  });
}
