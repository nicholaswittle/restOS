# Apex v2 — Restaurant OS

Reimagined Apex Scheduler: employee-first, 3-tap max, dark Material 3,
restaurant-native. Flutter + Supabase.

> **Multiple AI tools write to this repo.** Read *Working agreements* below
> before generating code — a file was lost to a concurrent-write race on
> 2026-07-27, which is why this repo now exists.

## Layout

```
lib/
  core/shift_time.dart              shared date / hours / money helpers
  features/dashboard/               employee_dashboard.dart   (the pattern)
  features/log_book/                manager_log_book.dart     (shift_notes write side)
  features/tips/                    tip_management.dart       (pools + hour splits)
docs/                               build plan, product vision, build order
```

No Flutter scaffold yet — `lib/` only. Supabase config comes from
`--dart-define` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `ORG_ID`); never commit keys.

## Working agreements

1. **Commit before you build.** `git status` should be clean before a session
   starts, so a bad generation is one `git checkout` away.
2. **Read `lib/features/dashboard/employee_dashboard.dart` first.** It is the
   reference pattern: `StatefulWidget`, typed models, parallel `Future.wait`,
   realtime streams scoped by `organization_id`, in-flight guards
   (`_clocking` / `_posting` / `_saving`), `SnackBar` feedback,
   `withValues(alpha:)`, callback nav with route fallbacks.
3. **Never overwrite a file you have not read.** If it already exists, review
   it and extend — assume another tool wrote it minutes ago.
4. **`flutter analyze lib/` must be clean** before you call a feature done.

## Known duplication (deliberate, for now)

`_LoadingView`, `_ErrorView`, `_SkeletonBox`, `_EmptyCard`, `_formatDayLabel`
and `_relativeTime` exist in each feature file. This is display code, and
consolidating it would mean editing three verified files while other tools are
writing to them — not worth the regression risk today.

**The money math is not duplicated.** `_hoursBetweenTimestamps` (tip and
payroll hours) lives only in `tip_management.dart`. Keep it that way: clock
punches are full timestamps and must not be parsed as `HH:MM` clock-face
strings, which would silently discard the date and mis-price a punch left open
across days.

`lib/core/shift_time.dart` holds shared versions of these helpers. It is
currently **unused** — wire the next feature (labor cost dashboard) to it
rather than making a fourth private copy.

## Next up

Labor cost dashboard — scheduled hours × rate vs actual clocked hours × rate,
daily/weekly/monthly, alert past 30% of projected sales. See
`docs/Restaurant OS Unified Build Plan 2026-07-27.md`.
