import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'slide_page_data.dart';
import 'slide_render_view.dart';

class PresentationWindowApp extends StatefulWidget {
  const PresentationWindowApp({super.key, required this.initialJson});
  final String initialJson;

  @override
  State<PresentationWindowApp> createState() => _PresentationWindowAppState();
}

class _PresentationWindowAppState extends State<PresentationWindowApp> {
  static const _receiverChannel = MethodChannel(
    'worship_slides/presentation_receiver',
  );

  SlidePageData? _currentPage;

  @override
  void initState() {
    super.initState();
    if (widget.initialJson.isNotEmpty) {
      try {
        final json = jsonDecode(widget.initialJson) as Map<String, dynamic>;
        _currentPage = SlidePageData.fromJson(json);
      } catch (_) {}
    }
    _receiverChannel.setMethodCallHandler(_handleCall);
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method == 'updatePage') {
      try {
        final json =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
        if (mounted) setState(() => _currentPage = SlidePageData.fromJson(json));
      } catch (_) {}
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bg = _currentPage?.style.backgroundColor ?? Colors.black;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: bg,
        body: _currentPage == null
            ? const Center(
                child: Text(
                  '슬라이드를 준비하는 중입니다…',
                  style: TextStyle(color: Colors.white54, fontSize: 18),
                ),
              )
            : SlideRenderView(data: _currentPage!),
      ),
    );
  }
}

