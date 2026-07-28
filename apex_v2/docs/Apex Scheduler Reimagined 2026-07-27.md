---
title: Apex Scheduler Reimagined — Product Vision
tags: [business, product, apex, reimagined, vision, restaurant, strategy]
aliases: [Apex Reimagined, Apex 2.0, New Apex]
date: 2026-07-27
status: vision-active
---

# Apex Scheduler Reimagined

> Not a feature list. A product reimagining. What would make Apex the app a restaurant owner installs on day one and never uninstalls?

Related: [[Apex Scheduler]], [[business/Restaurant OS Unified Build Plan 2026-07-27]], [[business/WiSense Restaurant OS Master Plan 2026-07-27]], [[business/Restaurant OS Build Strategy 2026-07-27]], [[NOW]]

---

## The Core Insight

The competitor research found one truth: no app is both affordable AND restaurant-specific AND reliable. The #1 complaint across ALL competitors (7shifts, Homebase, Deputy, When I Work, Sling, ZoomShift) is unreliable notifications. The #2 is cost and paywalls.

Most scheduling apps are built for the manager. The employee experience is an afterthought. But employees are the ones who open the app every day. If they hate it, the manager switches.

**Reimagined Apex: employee-first, owner-obsessed, restaurant-native.**

---

## 1. ONBOARDING — 5 Minutes to First Schedule

### Current: Standard setup, manual entry
### Reimagined: Photo import + voice setup

**The owner takes a photo of their current paper schedule or whiteboard.** AI reads it and creates the shifts automatically. The owner reviews, taps confirm, done. First schedule published in 5 minutes.

If no paper schedule: the owner speaks. "I have 5 staff. Mike works Tuesday and Thursday 4 to 10. Sarah works Friday and Saturday 5 to 11..." AI parses the voice input and builds the schedule.

**Why this matters:** Every competitor makes you manually enter staff, roles, and shifts. That's 30-60 minutes of data entry before the app is useful. Most owners give up. Photo import removes the barrier.

**Technical:** Claude/Gemini vision API for photo parsing. Already proven in the Apex feature plan (Feature A — photo-to-schedule). Voice input via Flutter's speech_to_text plugin. Server-side parsing with Claude API.

---

## 2. THE EMPLOYEE EXPERIENCE — "My Work" First

### Current: Manager view is primary, employee sees their shifts
### Reimagined: Employee opens to a personal dashboard

When an employee opens Apex, they see ONE screen — everything about them:

```
┌─────────────────────────┐
│  Hey Mike               │
│  You work in 3 hours    │
│  Today: 4:00 PM - 10:00 │
│  [Clock In] button      │
│                         │
│  This week: 28 hours    │
│  This week's pay: ~$420 │
│  Tips this week: $185   │
│                         │
│  Next shift: Thu 4-10   │
│  [Swap] [Request off]   │
│                         │
│  Shift notes from last: │
│  "Walk-in fridge down,  │
│   called repair"        │
│                         │
│  Team chat: 2 new       │
└─────────────────────────┘
```

One screen. No tabs, no menus, no hunting. The employee sees: when do I work, how much am I making, what do I need to know, can I change my shift.

**Why this matters:** Employees open the app 2-3 times per day. If the first thing they see is useful, they keep opening it. If they have to navigate to find their schedule, they stop checking.

**Technical:** Reuse existing Apex data (shifts, time_entries, tips). New Flutter widget: `EmployeeHomeDashboard`. Pulls from same Supabase tables, just a different view.

---

## 3. NOTIFICATIONS — The #1 Complaint Solved

### Current: Firebase push notifications
### Reimagined: Smart notification routing + employee control

**The problem:** Every competitor has unreliable push notifications. Firebase push can be delayed, suppressed by battery optimization, or missed entirely. Restaurant staff aren't sitting at desks checking phones — they're cooking, serving, driving.

**The solution: Three-channel notification system:**

1. **Push notification** (Firebase) — primary channel, instant
2. **SMS fallback** (Twilio, ~$0.007/message) — if push isn't delivered within 60 seconds, send SMS
3. **WhatsApp** (optional, via Twilio WhatsApp API) — many restaurant teams already use WhatsApp groups. Meet them where they are.

**Employee notification control:**
- "Notify me about: my shifts [on], shift changes [on], swap opportunities [on], team messages [off], schedule published [on]"
- "Quiet hours: 11 PM - 7 AM (except emergencies)"
- "Delivery method: push + SMS [on], WhatsApp [off]"

**Owner notification control:**
- "Alert me when: someone clocks in late [5 min grace], someone doesn't show up [15 min grace], a swap needs approval [instant], labor exceeds 30% [daily summary]"
- "Critical alerts bypass quiet hours: yes"

**Why this matters:** This is the #1 complaint across every single competitor. If Apex's notifications actually arrive, word of mouth spreads. "My old app missed half my alerts. Apex sends SMS if the push doesn't land."

**Technical:** Firebase Messaging (already integrated) + Twilio for SMS/WhatsApp + Supabase Edge Function for delivery tracking and fallback logic. Notification preferences stored in a new `notification_preferences` table.

---

## 4. THE SCHEDULE — Smart, Visual, Safe

### Current: Drag-and-drop scheduling with conflict detection
### Reimagined: Smart scheduling with guardrails and predictions

**Smart guardrails:**
- Minor labor laws: "Mike is 17 — he can't work past 10 PM on a school night. Warning."
- Overtime alerts: "Sarah is at 38 hours. One more shift puts her in overtime. Want to assign someone else?"
- Break compliance: "This shift is 6 hours — PA law requires a 30-minute break. Added automatically."
- Consecutive days: "This is Mike's 7th day in a row. PA labor law recommends a rest day. Continue?"

**Visual improvements:**
- Color-coded by role (red = cook, blue = server, green = bartender)
- Tap a shift to see: who, what role, what hours, what labor cost
- Drag to copy a shift to next week
- Template weeks: "This is a typical Friday. Save as template?"

**Predictive hints (data-driven, not AI-guessed):**
- "Last 4 Tuesdays: avg 18 customers, 2 servers was enough. You scheduled 3. Consider reducing."
- "Last 4 Fridays: avg 47 customers, needed 4 staff. You scheduled 3. You'll be short."
- Based on actual order data (from the OS connection) or time clock data (orders/hour correlation)

**Why this matters:** 7shifts charges $69.99/mo for labor law compliance and auto-scheduling. You include it free. And the predictions aren't AI guessing — they're based on the restaurant's own data.

**Technical:** Labor law rules as a configurable JSON per state (start with PA). Predictions from `time_entries` + `orders` correlation. Templates as a `schedule_templates` table.

---

## 5. TIME CLOCK — Frictionless and Honest

### Current: Manual clock in/out in the app
### Reimagined: QR clock-in + geofencing + photo verification

**QR code on the wall:**
- Employee walks in, scans the QR code on the kitchen wall with their phone
- Clock-in is instant — no app interaction beyond camera
- QR code rotates daily (printed or on a tablet display) to prevent "I clocked in from my car"

**Geofencing that works:**
- 100-meter radius around the restaurant
- Employee can only clock in within the geofence
- If GPS is inaccurate (the #1 Homebase complaint), fall back to QR scan as proof of presence
- "We couldn't verify your location. Scan the QR code to clock in."

**Photo verification (optional):**
- On clock-in, take a selfie. Owner can review if there's a dispute.
- Prevents buddy punching (someone clocking in for a friend)
- Photos deleted after 30 days — not stored permanently

**Auto clock-out:**
- If someone forgets to clock out, system auto-clocks them at scheduled end time + 30 min
- Owner gets a notification: "Mike didn't clock out. Auto-clocked at 10:30 PM. Adjust if needed."

**Why this matters:** Homebase users report GPS inaccuracies. Deputy users report time tracking errors. Buddy punching costs restaurants 2-3% of payroll. QR + geofence + photo solves all three.

**Technical:** Flutter camera plugin for QR scanning (already exists). Geofencing via `geolocator` plugin. Selfie via camera plugin, stored in Supabase Storage with 30-day auto-delete policy. Auto clock-out as a Supabase cron job.

---

## 6. THE OWNER DASHBOARD — One Number

### Current: Calendar view with shifts
### Reimagined: One number + drill-down

When the owner opens Apex, they see:

```
┌─────────────────────────┐
│  Your Venue             │
│                         │
│  Labor Cost: 22% 🟢     │
│  Good — target is <30%  │
│                         │
│  Today:                 │
│  $1,840 in orders       │
│  $405 in labor          │
│  3 staff on shift       │
│                         │
│  This week:             │
│  $12,400 revenue        │
│  $2,728 labor (22%)     │
│  47 shifts scheduled    │
│  2 swaps approved       │
│  1 no-show (filled)     │
│                         │
│  [Full Schedule →]      │
│  [Staff →]              │
│  [Reports →]            │
└─────────────────────────┘
```

**One number: labor cost percentage.** Green if under 30%, yellow 25-30%, red over 30%. The owner doesn't need charts — they need to know if they're making money or burning it.

Tap any number to drill down:
- Tap "22%" → see how it compares to last week, last month
- Tap "$1,840" → see order breakdown
- Tap "3 staff" → see who's working, what they're doing
- Tap "1 no-show" → see how it was handled

**Why this matters:** Restaurant owners are busy. They don't have time to parse dashboards. One number tells them if the business is healthy. Drill-down gives detail when they want it.

**Technical:** Reuses existing time_entries + orders data. New Flutter widget: `OwnerDashboardWidget`. Labor cost = sum(time_entries hours × hourly_rate) / sum(orders.total). Cached in a `daily_totals` table for instant load.

---

## 7. COMMUNICATION — Kill the Group Text

### Current: Push notifications for schedule changes
### Reimagined: In-app team chat that replaces group texts

Every restaurant runs on group texts. "Who can cover Friday?" "I'm running 10 minutes late." "The walk-in is broken." Group texts are chaotic, unsearchable, and the owner's personal phone is full of work messages.

**Apex Team Chat:**
- One channel per restaurant (not per shift — too fragmented)
- Owner can pin messages: "Saturday prep list: cut 40 wings, make 6 trays of dough"
- Shift-specific threads: tap a shift → "Discuss this shift" → messages scoped to that shift's staff
- Photos: "The mixer is doing this" (photo) → owner sees it in the log book too
- Read receipts: owner can see who read the "schedule is published" message
- Auto-messages: "Mike clocked in at 4:02 PM" (system-generated, not a human message)

**Why this matters:** Replaces the group text. The owner's personal phone stays personal. Everything is searchable. Shift-specific threads keep context. And it's one more reason to never close the app.

**Technical:** Supabase Realtime for live chat (already available). New `messages` table: id, organization_id, user_id, shift_id (optional), text, photo_url, pinned, system_generated, created_at. Flutter chat widget with realtime subscription.

---

## 8. TIP MANAGEMENT — Built In, Not an Add-On

### Current: Not implemented
### Reimagined: Core feature, free

7shifts charges $49.99/mo for tip management. Homebase charges $25/mo. For restaurants, tips are not an add-on — they're the core of employee compensation.

**Apex Tip Management:**
- End of shift: owner enters total tips (cash + card)
- System auto-splits by hours worked (pulls from time_entries)
- Employees see their split in the app: "Tonight: 5 hours, $87 in tips"
- Owner can adjust manually: "Mike worked the bar alone for 2 hours — give him extra"
- Weekly tip summary: "This week: 28 hours, $185 in tips, $420 in wages = $605 total"
- Export for payroll: CSV with hours + tips per employee

**Why this matters:** It's the feature competitors charge the most for. Including it free is the strongest pitch: "7shifts charges $50/mo for tip management. Apex includes it free."

**Technical:** `tip_pools` + `tip_allocations` tables (already in the unified build plan). Split algorithm: `employee_hours / total_hours × tip_pool_total`. Owner override via manual adjustment UI.

---

## 9. OFFLINE MODE — Kitchens Have Bad WiFi

### Current: Requires internet connection
### Reimagined: Works offline, syncs when reconnected

Restaurant kitchens are often metal-walled, basement-level, or in old buildings with terrible WiFi. Staff can't clock in if the app can't reach Supabase.

**Apex Offline Mode:**
- Schedule is cached locally on every app open
- Clock in/out works offline — stored locally, synced when connection returns
- Swap requests work offline — queued, sent when online
- Shift notes work offline — saved locally, synced later
- Team chat: last 50 messages cached, new messages queued
- A small banner: "Offline — changes will sync when reconnected"

**Why this matters:** No competitor does this well. It's the most practical feature for a real kitchen. "My old app wouldn't let me clock in because the WiFi was down. Apex just works."

**Technical:** Flutter local storage (Hive or SQLite via `sqflite`). Sync queue: `pending_sync` table locally. Supabase Realtime reconnect handler triggers sync. Conflict resolution: server wins for schedule, client wins for clock-in timestamp (with server verification on sync).

---

## 10. INTEGRATIONS — Connect What They Already Use

### Current: Supabase + Firebase (push)
### Reimagined: Connect to the tools restaurants already have

**Google Calendar sync:**
- Owner's schedule auto-publishes to their Google Calendar
- "I don't need to check the app — it's on my calendar"
- Employee option: "Add my shifts to my phone calendar"

**Square sales data (via OS connection):**
- Pull daily sales from Square to calculate labor cost percentage
- "You made $2,400 on Square tonight. Labor was $480. That's 20%."
- No manual sales entry needed

**Payroll export:**
- One tap: export hours + tips as CSV
- Formatted for QuickBooks, Gusto, ADP
- "Send to accountant" button: emails the CSV

**Why this matters:** The app doesn't exist in isolation. It connects to the tools the owner already uses. That makes it part of their workflow, not another login to remember.

**Technical:** Google Calendar API (OAuth). Square API (already explored in the OS plan). CSV export is pure Dart. Email via `flutter_email_sender` or Supabase Edge Function with Resend.

---

## What NOT to Build

- **POS replacement** — don't compete with Square/Toast. Connect to them.
- **Payroll processing** — regulated, complex, risky. Export for payroll, don't run payroll.
- **AI chatbot** — restaurants don't need a chatbot. They need reliable alerts and a schedule that works.
- **Social features** — no feed, no profiles, no likes. This is a work tool, not Instagram.
- **Complex reporting** — one number (labor cost %) + drill-down. Not a wall of charts.

---

## The Reimagined Apex in One Sentence

"Apex is the app your staff opens every day to see when they work, how much they're making, and what's happening — and the app you open to see one number: is your labor cost under control."

---

## Build Priority (What to Build First After Shipping)

| Priority | Feature | Weekend | Differentiator |
|---|---|---|---|
| 1 | Manager log book | 1 | 7shifts charges $15/mo — free |
| 2 | Tip management | 1 | 7shifts charges $50/mo — free |
| 3 | Employee dashboard redesign | 1 | Employee-first, nobody does this |
| 4 | Labor cost dashboard (one number) | 1 | One number, not a wall of charts |
| 5 | QR clock-in + offline mode | 2 | Nobody does offline, nobody does QR |
| 6 | Smart notification routing (push + SMS) | 2 | #1 complaint across all competitors |
| 7 | Team chat | 2 | Replaces group texts |
| 8 | Photo-to-schedule import | 2 | 5-minute onboarding |
| 9 | Schedule guardrails (labor laws) | 3 | 7shifts charges $70/mo — free |
| 10 | Google Calendar sync | 3 | Connect to what they already use |

---

## The Pitch (Reimagined Apex)

"I'm not selling you a scheduling app. I'm selling you the app your staff will actually use.

Your staff opens it every day — they see when they work, how much they're making, their tips, and what's happening at the restaurant. They clock in by scanning a QR code on the wall. They swap shifts without calling you. They see shift notes from the last crew.

You open it and see one number: is your labor cost under control. Green means you're making money. Red means you're overstaffed.

Tips are tracked and split automatically. Shift handoff notes pass from day to night. Notifications actually arrive — we SMS them if the push doesn't land. It works in your kitchen even when the WiFi doesn't.

$25/month. No per-user charges. No add-ons. Tip management and log book are included — 7shifts charges $65/month extra for those.

Target: labor cost under 25% of revenue, visible in one number, every day. I'll set you up free and we'll measure it together."