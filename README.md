# Grayfather's Frameroids (v1.1.1)

For tanks and healers: pull a specific party/raid member's **real** unit frame out of whatever raid-frame addon draws it, and pin it anywhere on screen. It's the actual frame - not a copy - so everything about it (health/mana bars, debuffs, click-to-target, right-click menu) works exactly as it always did. Once pinned, it keeps tracking that person by name even if the raid reshuffles them into a different subgroup.

## Why this is harder than "just move a frame"

None of the raid-frame addons this hooks into know or care that their frame got moved. [ShaguTweaks-extras](https://github.com/shagu/ShaguTweaks-extras)' raid frames and [pfUI](https://github.com/shagu/pfUI)'s both re-assert their own grid position every roster update - a plain one-time reposition would just get snapped straight back on the next update. The fix: this addon replaces the frame's own `SetPoint` method with a wrapper that redirects any position change back to the pinned spot. That override only ever applies to that one specific frame object - nothing else is affected.

Dragging is handled by tracking the cursor manually rather than with WoW's built-in `StartMoving()`/`StopMovingOrSizing()`, deliberately - see the cleanup note below for why that distinction matters.

Because the frame is tracked by the person's **name**, not their raid slot, a reshuffle that moves them to a different subgroup (and therefore a different physical frame object) gets detected and the pin silently transfers to whichever frame now represents them - the old one goes back to normal grid behavior.

There's one more wrinkle with Blizzard's default party frames specifically: they hang off each other (frame 2 is anchored to frame 1, 3 to 2, and so on), so moving one would normally drag every frame below it along too - pull out one person and the whole stack follows.

So while anyone in a group of frames is pulled out, this addon takes over that group's layout: the frames still in the stack get placed into the stack's original slot positions, in order, skipping whoever's been pulled out. That kills two birds - the chain can't drag anyone along (nobody's anchored to a moving frame any more), and **the gap closes up** instead of leaving a hole where the pulled-out member used to be. The moment the last pin in that group is released, the addon hands the whole thing back to whichever addon owns it and stops touching it entirely.

## Supported raid-frame addons

- Blizzard's own default party frames (`PartyMemberFrame1`-`4`)
- ShaguTweaks-extras' raid frames (`ShaguTweaksRaidUnitFrame1`-`40`)
- pfUI's party and raid frames (`pfGroup0`-`4`, `pfRaid1`-`40`)

If you're not running either ShaguTweaks-extras or pfUI, only party members (via Blizzard's default frames) can be pulled out - vanilla's own UI has no per-member raid frames at all to pull from.

## Usage

**Shift-right-click** any supported frame to pull that person out. Shift-right-click their frame again (wherever it currently is) to release them back to the grid. Drag a pulled-out frame anywhere - its new position is saved automatically.

```
/gf                 lists everyone currently pulled out
/gf clear <name>    puts a specific person back
/gf reset           puts everyone back at once
/gf probe           diagnostic: frames found vs. frames actually hooked,
                    per frame type - useful if shift-right-click isn't
                    doing anything on a frame it should work on
/gf debug           toggles printing every click seen on a hooked frame
                    (button + shift state), for tracking down why
                    shift-right-click isn't registering
/gf cleanup         clears the "user placed" flag off every supported frame
                    - only needed if you used v1.0.4 or earlier, see below
```

## If you used v1.0.4 or earlier: run `/gf cleanup` once

Versions up to 1.0.4 moved frames using WoW's built-in `StartMoving()`/`StopMovingOrSizing()`. That turned out to have a side effect worth knowing about: those calls make the **client** mark the frame as "user placed," and the client then saves that frame's position into `WTF/Account/<account>/<realm>/<character>/layout-cache.txt` and restores it on every login afterward.

That's the client's own bookkeeping, not this addon's — which means it **outlives the addon**. Disabling Frameroids doesn't undo it. Deleting Frameroids doesn't undo it. Deleting the cache entries by hand doesn't stick either, because the client just rewrites them on the next logout. An addon has no business leaving a mark like that on frames it doesn't own.

**1.0.5 and later never set that flag at all** — dragging is now done by tracking the cursor manually and moving the frame through this addon's own positioning path, so nothing ever reaches the client's user-placed tracking.

If you ran an earlier version, the flag may still be stuck on your party/raid frames. To clear it:

1. `/gf cleanup`
2. **Log out** (a full logout, not just `/reloadui`) so the client rewrites `layout-cache.txt` without those entries.

You can confirm it worked by checking that file — there should be no `PartyMemberFrame` entries left in it (unless another addon deliberately placed them; ShaguTweaks, for instance, intentionally does this for `PlayerFrame`/`TargetFrame`, which is normal and not related to this).

## Known limitations

- If the person you pulled out isn't currently visible in any supported raid-frame addon (not in your group, or you have none of the supported addons installed), the pin just waits - it'll pick them back up automatically the moment a matching frame appears for them again.
- Shift-right-click is the only way to pull someone out right now - there's no roster-list picker.
- Pins are per-character (`SavedVariablesPerCharacter`), since a tank and a healer on the same account will likely want different setups.

## Author

Built for [Salahaja](https://github.com/Salahaja).
