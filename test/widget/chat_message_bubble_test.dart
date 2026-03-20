import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/theme.dart';
import 'package:iris_chat/config/providers/hashtree_attachment_provider.dart';
import 'package:iris_chat/core/services/hashtree_attachment_service.dart';
import 'package:iris_chat/core/utils/hashtree_attachments.dart';
import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:iris_chat/features/chat/presentation/widgets/chat_message_bubble.dart';
import 'package:mocktail/mocktail.dart';

import '../test_helpers.dart';

class MockHashtreeAttachmentService extends Mock
    implements HashtreeAttachmentService {}

TextStyle? effectiveStyleForLinkedText(
  InlineSpan span,
  String text, {
  TextStyle? inheritedStyle,
}) {
  if (span is! TextSpan) return null;

  final effectiveStyle = inheritedStyle?.merge(span.style) ?? span.style;
  if (span.toPlainText() == text && span.recognizer != null) {
    return effectiveStyle;
  }

  for (final child in span.children ?? const <InlineSpan>[]) {
    final childStyle = effectiveStyleForLinkedText(
      child,
      text,
      inheritedStyle: effectiveStyle,
    );
    if (childStyle != null) {
      return childStyle;
    }
  }

  return null;
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const HashtreeFileLink(
        nhash: 'nhash1abc123',
        filename: 'file.png',
        filenameEncoded: 'file.png',
      ),
    );
  });

  ChatMessage buildMessage({
    required MessageDirection direction,
    String text = 'hello world',
  }) {
    return ChatMessage(
      id: 'm1',
      sessionId: 's1',
      text: text,
      timestamp: DateTime(2026, 2, 1, 12, 0, 0),
      direction: direction,
      status: MessageStatus.delivered,
    );
  }

  Widget wrap(
    Widget child, {
    double width = 600,
    double height = 600,
    List<Override> overrides = const [],
    ThemeData? theme,
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: theme ?? createTestTheme(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  Future<void> longPressBubble(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(ChatMessageBubble));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
  }

  BoxDecoration bubbleDecoration(WidgetTester tester, String messageId) {
    final container = tester.widget<Container>(
      find.byKey(ValueKey('chat_message_bubble_body_$messageId')),
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('ChatMessageBubble: hover shows action dock', (tester) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(direction: MessageDirection.incoming),
          onReact: (_) async {},
          onDeleteLocal: () async {},
          onReply: () {},
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(Offset.zero);
    await tester.pump();

    expect(find.byTooltip('Reply'), findsNothing);
    expect(find.byTooltip('React'), findsNothing);
    expect(find.byTooltip('More'), findsNothing);

    await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
    await tester.pump();

    expect(find.byTooltip('Reply'), findsOneWidget);
    expect(find.byTooltip('React'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 140));

    expect(find.byTooltip('Reply'), findsNothing);
  });

  testWidgets('ChatMessageBubble: standalone bubble is fully rounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(direction: MessageDirection.outgoing),
          onReact: (_) async {},
          onDeleteLocal: () async {},
          onReply: () {},
          isFirstInGroup: true,
          isLastInGroup: true,
        ),
      ),
    );

    expect(
      bubbleDecoration(tester, 'm1').borderRadius,
      BorderRadius.circular(16),
    );
  });

  testWidgets(
    'ChatMessageBubble: grouped non-leading incoming bubble hides sender label',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(direction: MessageDirection.incoming),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
            senderLabel: 'Alice',
            isFirstInGroup: false,
            isLastInGroup: true,
          ),
        ),
      );

      expect(find.text('Alice'), findsNothing);
      expect(
        bubbleDecoration(tester, 'm1').borderRadius,
        const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      );
    },
  );

  testWidgets('ChatMessageBubble: hover does not overflow on narrow layouts', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(
            direction: MessageDirection.outgoing,
            text: 'message to trigger hover dock layout',
          ),
          onReact: (_) async {},
          onDeleteLocal: () async {},
          onReply: () {},
        ),
        width: 180,
        height: 1000,
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));

    // Pump through the hover animation frames where the dock width changes.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ChatMessageBubble: hover dock stays on the side of the message bubble',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);

      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async => onePixelPng);

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.outgoing,
              text: 'photo\nnhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
          ),
          width: 520,
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));

      final bubbleRect = tester.getRect(
        find.byKey(const ValueKey('chat_message_bubble_body_m1')),
      );
      final replyIconRect = tester.getRect(find.byTooltip('Reply'));
      expect(
        replyIconRect.right <= bubbleRect.left,
        isTrue,
        reason:
            'Outgoing hover actions should be beside the bubble, not on top.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatMessageBubble: hover toggles do not re-download image attachment',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
      var downloadCalls = 0;
      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async {
        downloadCalls++;
        return onePixelPng;
      });

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'image\nnhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
          ),
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(downloadCalls, 1);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      final bubbleCenter = tester.getCenter(find.byType(ChatMessageBubble));
      await mouse.moveTo(bubbleCenter);
      await tester.pump(const Duration(milliseconds: 40));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 180));
      await mouse.moveTo(bubbleCenter);
      await tester.pump(const Duration(milliseconds: 40));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 180));

      expect(downloadCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatMessageBubble: hover toggles keep cached image visible without loading flash',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async => onePixelPng);

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'image\nnhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
          ),
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();

      final bubbleCenter = tester.getCenter(find.byType(ChatMessageBubble));
      await mouse.moveTo(bubbleCenter);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await mouse.moveTo(bubbleCenter);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatMessageBubble: media layout callback fires once when image resolves',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async => onePixelPng);

      var callbackCount = 0;
      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'image\nnhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
            onMediaLayoutChanged: () => callbackCount++,
          ),
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(callbackCount, 1);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 180));
      expect(callbackCount, 1);
    },
  );

  testWidgets(
    'ChatMessageBubble: rapid hover toggles do not throw duplicate key exceptions',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChatMessageBubble(
                  message: buildMessage(
                    direction: MessageDirection.incoming,
                    text: 'incoming one',
                  ),
                  onReact: (_) async {},
                  onDeleteLocal: () async {},
                  onReply: () {},
                ),
                ChatMessageBubble(
                  message: buildMessage(
                    direction: MessageDirection.outgoing,
                    text: 'outgoing two',
                  ),
                  onReact: (_) async {},
                  onDeleteLocal: () async {},
                  onReply: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();

      final bubbles = find.byType(ChatMessageBubble);
      await mouse.moveTo(tester.getCenter(bubbles.at(0)));
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveTo(tester.getCenter(bubbles.at(1)));
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveTo(tester.getCenter(bubbles.at(0)));
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatMessageBubble: long press shows emoji picker and context menu',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(direction: MessageDirection.incoming),
            onReact: (_) async {},
            onDeleteLocal: () async {},
            onReply: () {},
          ),
        ),
      );

      await longPressBubble(tester);
      await tester.pumpAndSettle();

      expect(find.text('❤️'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Delete locally'), findsOneWidget);
    },
  );

  testWidgets('ChatMessageBubble: Copy copies message text', (tester) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>?;
            copiedText = args?['text']?.toString();
            return null;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(direction: MessageDirection.incoming),
          onReact: (_) async {},
          onDeleteLocal: () async {},
        ),
      ),
    );

    await longPressBubble(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(copiedText, 'hello world');
  });

  testWidgets('ChatMessageBubble: Delete locally calls callback', (
    tester,
  ) async {
    var deleteCount = 0;
    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(direction: MessageDirection.incoming),
          onReact: (_) async {},
          onDeleteLocal: () async {
            deleteCount++;
          },
        ),
      ),
    );

    await longPressBubble(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete locally'));
    await tester.pump(const Duration(milliseconds: 900));

    expect(deleteCount, 1);
  });

  testWidgets(
    'ChatMessageBubble: tapping https link launches external browser',
    (tester) async {
      MethodCall? launchCall;
      const urlLauncherChannel = MethodChannel(
        'plugins.flutter.io/url_launcher',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(urlLauncherChannel, (call) async {
            if (call.method == 'launch') {
              launchCall = call;
              return true;
            }
            if (call.method == 'canLaunch') {
              return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(urlLauncherChannel, null);
      });

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'https://example.com',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
          ),
        ),
      );

      await tester.tap(find.text('https://example.com', findRichText: true));
      await tester.pumpAndSettle();

      expect(launchCall, isNotNull);
      final args = launchCall!.arguments as Map<dynamic, dynamic>;
      expect(args['url'], 'https://example.com');
      expect(args['useSafariVC'], isFalse);
      expect(args['useWebView'], isFalse);
    },
  );

  testWidgets(
    'ChatMessageBubble: tapping www link launches external browser using https',
    (tester) async {
      MethodCall? launchCall;
      const urlLauncherChannel = MethodChannel(
        'plugins.flutter.io/url_launcher',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(urlLauncherChannel, (call) async {
            if (call.method == 'launch') {
              launchCall = call;
              return true;
            }
            if (call.method == 'canLaunch') {
              return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(urlLauncherChannel, null);
      });

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'www.example.com',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
          ),
        ),
      );

      await tester.tap(find.text('www.example.com', findRichText: true));
      await tester.pumpAndSettle();

      expect(launchCall, isNotNull);
      final args = launchCall!.arguments as Map<dynamic, dynamic>;
      expect(args['url'], 'https://www.example.com');
      expect(args['useSafariVC'], isFalse);
      expect(args['useWebView'], isFalse);
    },
  );

  testWidgets(
    'ChatMessageBubble: outgoing links use a readable bubble contrast color',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.outgoing,
              text: 'https://example.com',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
          ),
          theme: AppTheme.dark,
        ),
      );

      final richText = tester.widget<RichText>(
        find.text('https://example.com', findRichText: true),
      );
      final linkStyle = effectiveStyleForLinkedText(
        richText.text,
        'https://example.com',
      );

      expect(linkStyle?.color, AppTheme.dark.colorScheme.onPrimaryContainer);
      expect(linkStyle?.decoration, TextDecoration.underline);
      expect(linkStyle?.fontWeight, FontWeight.w600);
    },
  );

  testWidgets(
    'ChatMessageBubble: hover action dock buttons work (reply/react/more)',
    (tester) async {
      var replyCount = 0;
      var reactValue = '';
      var deleteCount = 0;

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(direction: MessageDirection.incoming),
            onReact: (emoji) async {
              reactValue = emoji;
            },
            onDeleteLocal: () async {
              deleteCount++;
            },
            onReply: () {
              replyCount++;
            },
          ),
        ),
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byTooltip('Reply'));
      await tester.pump();
      expect(replyCount, 1);

      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('❤️').first);
      await tester.pumpAndSettle();
      expect(reactValue, '❤️');

      await mouse.moveTo(tester.getCenter(find.byType(ChatMessageBubble)));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete locally'));
      await tester.pump(const Duration(milliseconds: 900));
      expect(deleteCount, 1);
    },
  );

  testWidgets('ChatMessageBubble strips raw hashtree links from body text', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(
            direction: MessageDirection.incoming,
            text: 'hello\nnhash1abc123/file.pdf',
          ),
          onReact: (_) async {},
          onDeleteLocal: () async {},
        ),
      ),
    );

    expect(find.text('hello'), findsOneWidget);
    expect(find.text('file.pdf'), findsOneWidget);
    expect(find.textContaining('nhash1abc123/file.pdf'), findsNothing);
  });

  testWidgets(
    'ChatMessageBubble renders inline image preview for image links',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);

      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async => onePixelPng);

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'hello\nnhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
          ),
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final attachmentKey = find.byKey(
        const ValueKey('chat_message_attachment_file.png'),
      );
      expect(attachmentKey, findsOneWidget);
      final inlineImageFinder = find.descendant(
        of: attachmentKey,
        matching: find.byType(Image),
      );
      expect(inlineImageFinder, findsOneWidget);
      final inlineImage = tester.widget<Image>(inlineImageFinder);
      expect(inlineImage.fit, BoxFit.contain);
      expect(find.text('file.png'), findsNothing);
    },
  );

  testWidgets('ChatMessageBubble renders image attachment above body text', (
    tester,
  ) async {
    final mockAttachmentService = MockHashtreeAttachmentService();
    final onePixelPng = Uint8List.fromList(const <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x44,
      0x41,
      0x54,
      0x08,
      0x99,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    when(
      () => mockAttachmentService.downloadFile(link: any(named: 'link')),
    ).thenAnswer((_) async => onePixelPng);

    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(
            direction: MessageDirection.incoming,
            text: 'caption text\nnhash1abc123/file.png',
          ),
          onReact: (_) async {},
          onDeleteLocal: () async {},
        ),
        overrides: [
          hashtreeAttachmentServiceProvider.overrideWithValue(
            mockAttachmentService,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final attachmentFinder = find.byKey(
      const ValueKey('chat_message_attachment_file.png'),
    );
    final textFinder = find.text('caption text');
    expect(attachmentFinder, findsOneWidget);
    expect(textFinder, findsOneWidget);

    final attachmentRect = tester.getRect(attachmentFinder);
    final textRect = tester.getRect(textFinder);
    expect(attachmentRect.top, lessThan(textRect.top));
  });

  testWidgets(
    'ChatMessageBubble opens fullscreen image viewer when image attachment is tapped',
    (tester) async {
      final mockAttachmentService = MockHashtreeAttachmentService();
      final onePixelPng = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x08,
        0x99,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);

      when(
        () => mockAttachmentService.downloadFile(link: any(named: 'link')),
      ).thenAnswer((_) async => onePixelPng);

      await tester.pumpWidget(
        wrap(
          ChatMessageBubble(
            message: buildMessage(
              direction: MessageDirection.incoming,
              text: 'nhash1abc123/file.png',
            ),
            onReact: (_) async {},
            onDeleteLocal: () async {},
          ),
          overrides: [
            hashtreeAttachmentServiceProvider.overrideWithValue(
              mockAttachmentService,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('chat_message_attachment_file.png')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('chat_attachment_image_viewer')),
        findsOneWidget,
      );
    },
  );

  testWidgets('ChatMessageBubble image viewer closes on Escape', (
    tester,
  ) async {
    final mockAttachmentService = MockHashtreeAttachmentService();
    final onePixelPng = Uint8List.fromList(const <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x44,
      0x41,
      0x54,
      0x08,
      0x99,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    when(
      () => mockAttachmentService.downloadFile(link: any(named: 'link')),
    ).thenAnswer((_) async => onePixelPng);

    await tester.pumpWidget(
      wrap(
        ChatMessageBubble(
          message: buildMessage(
            direction: MessageDirection.incoming,
            text: 'nhash1abc123/file.png',
          ),
          onReact: (_) async {},
          onDeleteLocal: () async {},
        ),
        overrides: [
          hashtreeAttachmentServiceProvider.overrideWithValue(
            mockAttachmentService,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('chat_message_attachment_file.png')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat_attachment_image_viewer')),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('chat_attachment_image_viewer')),
      findsNothing,
    );
  });
}
