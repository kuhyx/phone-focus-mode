import 'package:flutter/material.dart';

/// Shared palette: charcoal field with a single accent, matching the other
/// com.kuhy.* apps.
///
/// Lifted out of `main.dart` so the status card and the log screen use the
/// same values rather than each redeclaring them.
const Color kField = Color(0xFF1B1D21);
const Color kSurface = Color(0xFF24272C);
const Color kAccent = Color(0xFF5B9DD9);
const Color kText = Color(0xFFE8EAED);
const Color kMuted = Color(0xFF9AA0A6);
const Color kDanger = Color(0xFFD9776B);

/// Used for states that are working as intended but restrictive.
const Color kWarn = Color(0xFFD9B26B);

const double kGap = 16;
