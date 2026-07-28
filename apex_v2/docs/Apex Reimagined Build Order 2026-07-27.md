---
title: Apex Reimagined Build Order — Planning Notes
tags: [business, product, apex, build-order, planning, ux-principles]
date: 2026-07-27
status: planning
---

# Apex Reimagined — Build Order and Planning Notes

> Nicholas wants to plan the full layout before building. Claude is on quota for 1 hour. This note captures decisions made so far so any agent can pick up the build.

Related: [[business/Apex Scheduler Reimagined 2026-07-27]], [[business/Restaurant OS Unified Build Plan 2026-07-27]], [[Apex Scheduler]], [[NOW]]

---

## The New Rule

Every restaurant feature gets built on the Apex Supabase database with org_id scoping from day one. No separate databases. No "connect later." If it's restaurant-related, it lives in Supabase.

## UX Principle

If you can't do it in 3 taps or less, it's too complicated. One screen, one number, one action. No nested menus, no 15-option settings, no hunting.

## Build Priority (Weekend 1)

1. Employee dashboard redesign — fixes the "hard to use" problem. One screen, everything the employee needs.
2. Manager log book — 1 table + CRUD. Competitors charge $15/mo.
3. Tip management — 2 tables + split math. Competitors charge $50/mo.
4. Labor cost one-number dashboard — extends existing labor_cost_panel.dart.

## What's Already Built (16 features, pull directly)

- Shift scheduling (drag-and-drop, templates)
- Shift swaps (claim/cover/approve)
- Time clock (clock in/out)
- Availability/time-off (requests + realtime)
- Sidework assignments
- Push notifications (Firebase)
- Conflict detection
- Smart suggestions (staff ranker)
- Labor cost panel (basic — extend it)
- Multi-tenant (org_id, RLS migration written)
- CSV export (time card)
- Admin publish panel
- Notification bell
- Org invite/onboarding
- Theme/colors
- Tutorial overlay

## What to Pull from the Existing Ordering Platform

- Staff console UI (accept/reject/pause)
- Order state machine
- Kitchen ticket printing (80mm)
- Customer notifications (chime + browser)
- Repeating alerts (30s re-alert)
- Screen Wake Lock
- No-show marking
- Monthly totals rollup

## Planning TODO (when Claude quota resets)

- [ ] Full UI layout for employee dashboard (wireframe)
- [ ] Full UI layout for owner dashboard (one number + drill-down)
- [ ] Supabase schema for all new tables (log book, tips, chat, notifications, prep_time_snapshots)
- [ ] Ordering platform port plan (D1 → Supabase migration)
- [ ] QR clock-in flow design
- [ ] Offline mode architecture
- [ ] Notification routing logic (push → SMS → WhatsApp fallback)

## Key Decisions Made

- Employee-first design (not manager-first)
- One-number owner dashboard (labor cost %)
- 3-tap max for any action
- Supabase as single backend for all restaurant features
- OS connection = same app + more data, not a separate product
- Ship current Apex Friday, then build reimagined features on weekends
- 3 weekends to full reimagined Apex, then connect ordering for OS