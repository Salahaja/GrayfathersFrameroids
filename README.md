# Grayfather's Frameroids (v1.0.1)

For tanks and healers: pull a specific party/raid member's **real** unit frame out of whatever raid-frame addon draws it, and pin it anywhere on screen. It's the actual frame - not a copy - so everything about it (health/mana bars, debuffs, click-to-target, right-click menu) works exactly as it always did. Once pinned, it keeps tracking that person by name even if the raid reshuffles them into a different subgroup.

## Why this is harder than "just move a frame"

None of the raid-frame addons this hooks into know or care that their frame got moved. [ShaguTweaks-extras](https://github.com/shagu/ShaguTweaks-extras)' raid frames and [pfUI](https://github.com/shagu/pfUI)'s both re-assert their own grid position every roster update - a plain one-time reposition would just get snapped straight back on the next update. The fix: this addon replaces the frame's own `SetPoint` method with a wrapper that redirects any position change back to the pinned spot, unless *you're* the one dragging it, in which case it passes through untouched so it still follows your mouse normally. That override only ever applies to that one specific frame object - nothing else is affected.

Because the frame is tracked by the person's **name**, not their raid slot, a reshuffle that moves them to a different subgroup (and therefore a different physical frame object) gets detected and the pin silently transfers to whichever frame now represents them - the old one goes back to normal grid behavior.

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
```

## Known limitations

- If the person you pulled out isn't currently visible in any supported raid-frame addon (not in your group, or you have none of the supported addons installed), the pin just waits - it'll pick them back up automatically the moment a matching frame appears for them again.
- Shift-right-click is the only way to pull someone out right now - there's no roster-list picker.
- Pins are per-character (`SavedVariablesPerCharacter`), since a tank and a healer on the same account will likely want different setups.

## Author

Built for [Salahaja](https://github.com/Salahaja).
