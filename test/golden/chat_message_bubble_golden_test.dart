import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:iris_chat/features/chat/presentation/widgets/chat_message_bubble.dart';

import '../test_helpers.dart';

const double _kGoldenMaxDiffRate = 0.009;

class _ToleranceGoldenComparator extends LocalFileComparator {
  _ToleranceGoldenComparator(super.testFile, {required this.maxDiffRate});

  final double maxDiffRate;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );

    if (result.passed || result.diffPercent <= maxDiffRate) {
      result.dispose();
      return true;
    }

    final String error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

void main() {
  setUp(() {
    final GoldenFileComparator previousComparator = goldenFileComparator;
    final Uri testFile = Uri.file(
      '${Directory.current.path}/test/golden/chat_message_bubble_golden_test.dart',
    );
    goldenFileComparator = _ToleranceGoldenComparator(
      testFile,
      maxDiffRate: _kGoldenMaxDiffRate,
    );
    addTearDown(() => goldenFileComparator = previousComparator);
  });

  ChatMessage buildMessage({
    required MessageDirection direction,
    String text = 'hello world',
  }) {
    return ChatMessage(
      id: '${direction.name}_$text',
      sessionId: 's1',
      text: text,
      timestamp: DateTime(2026, 2, 1, 12, 0, 0),
      direction: direction,
      status: MessageStatus.delivered,
    );
  }

  Widget wrap(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: createTestTheme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const Key('golden'),
              child: SizedBox(
                width: 420,
                height: 320,
                child: Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Align(alignment: Alignment.topCenter, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('golden: ChatMessageBubble idle', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatMessageBubble(
                message: buildMessage(
                  direction: MessageDirection.incoming,
                  text: 'first incoming',
                ),
                onReact: (_) async {},
                onDeleteLocal: () async {},
                onReply: () {},
                senderLabel: 'Alice',
                isFirstInGroup: true,
                isLastInGroup: false,
              ),
              ChatMessageBubble(
                message: buildMessage(
                  direction: MessageDirection.incoming,
                  text: 'second incoming',
                ),
                onReact: (_) async {},
                onDeleteLocal: () async {},
                onReply: () {},
                senderLabel: 'Alice',
                isFirstInGroup: false,
                isLastInGroup: true,
              ),
              ChatMessageBubble(
                message: buildMessage(
                  direction: MessageDirection.outgoing,
                  text: 'standalone outgoing',
                ),
                onReact: (_) async {},
                onDeleteLocal: () async {},
                onReply: () {},
                isFirstInGroup: true,
                isLastInGroup: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/chat_message_bubble_idle.png'),
    );
  });

  testWidgets('golden: ChatMessageBubble hover actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(
            direction: MessageDirection.outgoing,
            text: 'hover',
          ),
          onReact: (_) async {},
          onDeleteLocal: () async {},
          onReply: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
    await tester.pump();

    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/chat_message_bubble_hover.png'),
    );
  });
}
