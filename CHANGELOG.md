# Changelog

## 1.2.0

- Preserves all v1.1.3 behavior, input paths, native-result suppression, UI semantics, and frame timings.
- Splits the monolithic request update into dedicated Seikret-wait, sheathe, swap, drawn-idle, and final-guard handlers.
- Dispatches request updates through a phase table, making phase transitions explicit and preventing accidental fall-through.
- Extracts judge result handling from hook installation while preserving the existing `1/2/3/4/5` behavior.
- Keeps shared request reset, input consumption, action requests, and ride-block bookkeeping centralized.

## 1.1.3

- Fixes the out-of-range sheathed shortcut falling back to vanilla when its four-frame input marker expired before `CallPorter` entered.
- Starts the optional sheathed waiting flow directly from `judge=CALL (1)` while the dedicated weapon-change input is still marked.
- Keeps ordinary Seikret summons vanilla because they do not arm the dedicated weapon-change input marker.
- Continues suppressing direct judge results that arrive later during an active mod request.

## 1.1.2

- Handles the observed in-range direct judge results: `5` for drawn and `2` for sheathed input.
- Starts the mod's direct ground swap only while the dedicated shortcut intent is active and the hunter is not mounted.
- Replaces an accepted direct native judge result with `NONE (0)`, preventing the original mount-and-swap path from running in parallel.
- Restores optional sheathed/free-state mod handling for the in-range direct path.

## 1.1.1

- Detects whether the Seikret is already in interaction range when the mod request begins.
- In-range requests immediately use the mod's ground swap path and skip the redundant native `CallPorter` chain.
- Out-of-range requests retain the v1.0.7/v1.1.0 summon, wait, ride-intercept, and fallback behavior.
- Already-mounted weapon changes remain fully vanilla.

## 1.1.0

- Keeps the complete v1.0.7 behavior, hook coverage, settings semantics, and frame timings unchanged.
- Consolidates request-state initialization and cleanup into one reset path.
- Consolidates sheathe/ground-idle action requests and ride-block transition bookkeeping.
- Consolidates input-intent consumption, reducing duplicated mutable-state code.
- Keeps detailed runtime data and logging behind the existing disabled-by-default debug option.

## 1.0.7

- Fixes double weapon changes caused by v1.0.6 running its fallback before the normal native ride/change chain arrived.
- Delays fallback to 300 hunter updates and cancels it as soon as native `judge=CALL` or a downstream `CallPorter` transition is observed.
- Normal drawn and sheathed flows again wait for the real ride-start interception.

## 1.0.6

- Fixes a deadlock when the Seikret is already in range and the ride-disable flag prevents `cPorterRideStart.doEnter` from running.
- Uses a deterministic one-hunter-update fallback to ground idle before continuing the weapon swap.
- A late ride-start hook is now skipped without requesting ground idle after the swap, so it cannot overwrite the restored drawn stance.

## 1.0.5

- Fixes drawn weapons flashing between drawn and sheathed states until the request timeout.
- Removes the v1.0.4 per-frame drawn-idle correction loop, which could fight the game's action-state update.
- Retains input-frame stance capture while returning finalization to a quiet fixed 45-frame guard and one final state check.

## 1.0.4

- Captures the hunter's drawn/sheathed state at the accepted weapon-change input instead of after the Seikret response has begun changing action state.
- Requires the requested final stance to remain continuously stable for 45 hunter update frames.
- Reapplies the target idle stance and restarts stabilization whenever a late vanilla action overwrites it.

## 1.0.3

- Fixes ground sheathed shortcut detection on game build 1.42.
- Hooks the dedicated input node's `success()` method instead of searching for a nonexistent Boolean return method.
- Ordinary Seikret summons remain distinguishable and vanilla.

## 1.0.2

- Raises the request timeout to 2000 `HunterCharacter.update` frames.
- Adds `Keep sheathed ground behavior vanilla`, enabled by default.
- When that option is unchecked, the ground sheathed shortcut is handled by the mod and finishes in sheathed ground idle.
- Already-mounted weapon changes remain vanilla in both modes.

## 1.0.1

- Restores an optional detailed logging switch, disabled by default.
- Detailed logs cover input, judge results, CallType, ride cancellation, weapon swapping, and drawn-idle confirmation.
- Debug-only counters and judge history are collected only while the option is enabled and cleared when disabled.
- Keeps the compact REFramework panel and all v1.0 behavior and frame timings.

## 1.0.0

- First stable release.
- Preserves the verified v0.14 ground drawn-weapon swap behavior and frame timings.
- Keeps sheathed, normal summon, and already-mounted paths vanilla.
- Removes development counters, hook scan output, CallType/judge telemetry, and verbose logging.
- Reduces the REFramework panel to the enable switch and concise runtime status.
