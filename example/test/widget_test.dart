// Smoke test: the example app builds and renders its shell (API key field,
// tab bar, and the four feature tabs) without any network activity.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deepgram_example/main.dart';

void main() {
  testWidgets('demo app renders all four feature tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DeepgramDemoApp());

    expect(find.text('flutter_deepgram demo'), findsOneWidget);
    expect(find.text('Prerecorded'), findsOneWidget);
    expect(find.text('Live STT'), findsOneWidget);
    expect(find.text('Text to Speech'), findsOneWidget);
    expect(find.text('Voice Agent'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
  });
}
