import 'package:flutter/widgets.dart';

const double kChatsWideLayoutBreakpoint = 960;

bool useChatsWideLayout(BuildContext context) {
  final mediaQuery = MediaQuery.maybeOf(context);
  if (mediaQuery == null) return false;
  return mediaQuery.size.width >= kChatsWideLayoutBreakpoint;
}
