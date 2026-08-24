/// The app's palette, re-exported from the shared design system.
///
/// This file used to define its own colours — a cool blue accent (`#5B9DD9`)
/// on a `#1B1D21` field — while its doc comment claimed to match the other
/// `com.kuhy.*` apps. It did not: every other app is on the frozen gold
/// (`#B8862E`) palette. The same six constants were also duplicated verbatim
/// in `main.dart`, which the old comment said had been "lifted out" but never
/// deleted.
///
/// Both copies are gone. These names remain as aliases so the ~80 existing
/// call sites keep reading, but the values now come from `design_system` and
/// cannot drift again.
library;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// Page background.
const Color kField = AppPalette.ink;

/// Raised surface (cards, sheets).
const Color kSurface = AppPalette.inkRaised1;

/// The single accent hue.
const Color kAccent = AppPalette.accent;

/// Primary text.
const Color kText = AppPalette.textOnDark;

/// Secondary/caption text, and the "AWAY" status.
const Color kMuted = AppPalette.mutedOnDark;

/// Failure states: a missing home location, an unknown location, an
/// enforcement pass that threw.
const Color kDanger = AppPalette.danger;

/// Used for states that are working as intended but restrictive — i.e. the
/// night curfew.
const Color kWarn = AppPalette.warning;

/// Base spacing unit. Call sites use `kGap`, `kGap / 2` and `kGap * 2`,
/// which land on the shared scale's `md`, `sm` and `xl`.
const double kGap = AppSpacing.md;
