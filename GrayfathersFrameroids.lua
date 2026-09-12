--[[
    Addon:       GrayfathersFrameroids (folder/internal name - matches folder/
                 .toc/.lua names; displays in-game as "Grayfather's Frameroids")
    Description: Lets a tank or healer "pull out" a specific party/raid
                 member's REAL unit frame - whichever addon drew it
                 (Blizzard's own PartyMemberFrame1-4, ShaguTweaks-extras'
                 raid frames, or pfUI's party/raid frames) - and pin it
                 anywhere on screen, fully interactive (it's the actual
                 frame, not a copy), tracked by NAME rather than by raid
                 slot so it keeps showing the right person even if the
                 raid reshuffles them into a different subgroup.

    Why this is trickier than it sounds: none of those three raid-frame
    systems know or care that we've moved their frame, and they're not
    consistent about when (or whether) they'd naturally put it back.
    Shagu's raid frames only reposition in response to a real roster-change
    event; Blizzard's default party frames barely reposition via Lua at
    all after their initial XML layout. So both taking over the position
    AND releasing it need to be things this addon does explicitly, not
    something it can just wait on the host addon to eventually handle.

    The fix (see PinFrame) is to replace the frame's own SetPoint method
    with a wrapper that redirects any position change back to our saved
    spot. This is a per-frame-instance override (only shadows SetPoint on
    that one Lua table), so it can't affect any other frame. Our own
    positioning goes through the captured real SetPoint (GF.ApplyPin), so
    it bypasses the wrapper rather than fighting it.

    Dragging is done by hand from cursor deltas (see GF.dragDriver) rather
    than with StartMoving()/StopMovingOrSizing(), specifically so this
    addon never causes the client to mark someone else's frame as "user
    placed" - that flag outlives the addon entirely. The note above
    dragDriver has the full story.

    "Original position" (what UnpinFrame restores) is captured TWO ways
    (see CaptureOriginalPoint): the frame's REAL current anchor (point,
    relativeTo, relativePoint, offsets - exactly as GetPoint() reports it),
    which is what actually matters for Blizzard's default party frames,
    since 2/3/4 are anchored relative to the frame ABOVE them rather than
    independently - that relationship is what keeps them tightly and
    evenly stacked, and only restoring a frozen absolute screen position
    throws it away entirely (this broke the stack's spacing in practice).
    A plain-numbers absolute-to-UIParent fallback is captured alongside it
    for frames where replaying the real anchor isn't safe (wrapped in
    pcall on restore, in case some relativeTo isn't valid to replay
    directly). The real anchor is always tried first.

    It's captured PROACTIVELY for every candidate frame
    at the earliest opportunity (SnapshotAllFramePositions, called from
    RefreshPins before any pin is ever (re-)applied) rather than lazily
    the first time a frame happens to get pinned. Since a saved pin
    re-applies itself automatically after every reload, capturing lazily
    meant the "original" could end up being read AFTER this addon (or an
    earlier bug) had already moved the frame once this session - silently
    turning "restore to original" into "restore to wherever it happened to
    be last," which is exactly what looked like reset "not working."

    Selection: shift-right-click any of those frames to pull that person
    out (or put them back if already pulled out). Every candidate frame
    gets this hook lazily (see HookAllFrames) without disturbing its
    normal single-click targeting or plain right-click menu - it wraps
    whatever OnClick handler was already there rather than replacing it.

    Slash Commands (both equivalent - /gf, /frameroids):
        /gf                 lists everyone currently pulled out
        /gf clear <name>    puts a specific person back
        /gf reset           puts everyone back at once
        /gf probe           diagnostic: how many frames of each type exist vs.
                             how many this addon has actually hooked
        /gf debug           toggles printing every click seen on a hooked
                             frame (button + shift state) - for tracking down
                             why shift-right-click isn't doing anything
--]]

GF = {}
GF.ADDON_NAME = "GrayfathersFrameroids"

GF.pins        = {} -- [name] = { point, relPoint, x, y } - saved screen position, relative to UIParent
GF.heldFrames  = {} -- [name] = the real frame object currently pinned for them (see RefreshPins)

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function GF.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF66CCFFGrayfather's Frameroids|r: " .. msg)
end

-- Scans every unit-frame system this addon knows how to read, in the same
-- order every time, and returns whichever real frame currently represents
-- `name` - or nil if none of them do right now (they're not in your group,
-- or you don't have a raid-frame addon showing them at all).
function GF.FindFrameFor(name)
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and UnitName(unit) == name then
            return getglobal("PartyMemberFrame" .. i)
        end
    end

    for i = 1, 40 do
        local frame = getglobal("ShaguTweaksRaidUnitFrame" .. i)
        if frame and frame.unitstr and UnitExists(frame.unitstr) and UnitName(frame.unitstr) == name then
            return frame
        end
    end

    for i = 0, 4 do
        local frame = getglobal("pfGroup" .. i)
        if frame and frame.label and frame.id then
            local unit = frame.label .. frame.id
            if UnitExists(unit) and UnitName(unit) == name then
                return frame
            end
        end
    end

    for i = 1, 40 do
        local frame = getglobal("pfRaid" .. i)
        if frame and frame.label and frame.id then
            local unit = frame.label .. frame.id
            if UnitExists(unit) and UnitName(unit) == name then
                return frame
            end
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Pinning
-- ---------------------------------------------------------------------------------------------

-- Applies a pin's saved position, going straight through the captured real
-- SetPoint so it bypasses our own override.
--
-- ClearAllPoints first is load-bearing: SetPoint ADDS an anchor, and only
-- replaces an existing one when it's the same point name. The host frame
-- still carries its own anchor (TOPLEFT for Blizzard/Shagu, BOTTOMLEFT for
-- pfUI), so pinning to CENTER without clearing leaves two conflicting
-- anchors and the frame simply refuses to move - which also makes dragging
-- look completely dead, since every drag update just loses that same fight.
function GF.ApplyPin(frame)
    local name = frame.gfPinnedFor
    local p = name and GF.pins[name]
    if not p or not frame.gfRealSetPoint then return end
    frame:ClearAllPoints()
    frame.gfRealSetPoint(frame, p.point, UIParent, p.relPoint, p.x, p.y)
end

-- Dragging is driven manually from cursor deltas by this one frame that WE
-- own, rather than by the built-in StartMoving()/StopMovingOrSizing().
--
-- That matters a lot: those built-ins make the client mark the frame as
-- "user placed," and the client then persists that frame's position into
-- WTF/Account/<acct>/<realm>/<char>/layout-cache.txt and restores it on
-- every subsequent login - FOREVER, and completely outside this addon's
-- control. It survives disabling the addon, deleting the addon, everything,
-- because it's the client's own bookkeeping, not ours. Evidence that this
-- is real: on this author's own install, PartyMemberFrame1-4 only ever
-- appeared in layout-cache.txt on the characters where this addon had
-- pinned party frames - never on characters that had merely been in a
-- party. (PlayerFrame/TargetFrame appear on all of them, because
-- ShaguTweaks' move-unitframes module deliberately calls SetUserPlaced on
-- exactly those two.)
--
-- An addon has no business leaving permanent marks on frames it doesn't
-- own, so this never calls SetMovable/StartMoving/StopMovingOrSizing at
-- all. RegisterForDrag still gives us OnDragStart/OnDragStop (those work
-- independently of movability); from there we just track the cursor
-- ourselves and move the frame through our own positioning path.
GF.dragDriver = CreateFrame("Frame")
GF.dragDriver:Hide()
GF.dragDriver:SetScript("OnUpdate", function()
    local frame = GF.draggingFrame
    local name = frame and frame.gfPinnedFor
    local p = name and GF.pins[name]
    if not p then this:Hide() return end

    local px, py = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    p.x = GF.dragStartPinX + (px / scale - GF.dragStartCursorX)
    p.y = GF.dragStartPinY + (py / scale - GF.dragStartCursorY)
    GF.ApplyPin(frame)
end)

local function EnableDragging(frame)
    if frame.gfDragSetup then return end
    frame.gfDragSetup = true

    frame:RegisterForDrag("LeftButton")

    local origDragStart = frame:GetScript("OnDragStart")
    local origDragStop = frame:GetScript("OnDragStop")

    frame:SetScript("OnDragStart", function()
        if GF.debugClicks then GF.Say("OnDragStart fired on " .. (this:GetName() or "?")) end
        if origDragStart then pcall(origDragStart) end

        local name = this.gfPinnedFor
        local p = name and GF.pins[name]
        if not p then return end

        local px, py = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        GF.draggingFrame = this
        GF.dragStartCursorX, GF.dragStartCursorY = px / scale, py / scale
        GF.dragStartPinX, GF.dragStartPinY = p.x, p.y
        GF.dragDriver:Show()
    end)
    frame:SetScript("OnDragStop", function()
        if GF.debugClicks then GF.Say("OnDragStop fired on " .. (this:GetName() or "?")) end
        GF.dragDriver:Hide()
        GF.draggingFrame = nil
        if origDragStop then pcall(origDragStop) end

        local name = this.gfPinnedFor
        if name and GF.pins[name] then
            GF_Pins = GF.pins
        end
    end)
end

-- Reads a frame's CURRENT position two ways: the REAL anchor (whatever
-- point/relativeTo/relativePoint/offset it actually has right now - for
-- Blizzard's default party frames, 2/3/4 are anchored relative to the
-- frame ABOVE them, not independently, which is what keeps them tightly
-- and evenly stacked regardless of anything else going on) as the
-- preferred restore target, plus a plain-numbers absolute-to-UIParent
-- fallback (via GetLeft/GetTop) for frames where the real anchor can't be
-- safely replayed. Only using the absolute fallback (the previous
-- approach) throws away that relative relationship entirely, which is
-- exactly what broke the party frame stack's spacing/gap.
local function CaptureOriginalPoint(frame)
    local point, relativeTo, relPoint, x, y = frame:GetPoint()
    local raw = point and { point = point, relativeTo = relativeTo, relPoint = relPoint, x = x, y = y }

    local absolute
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        local scale = frame:GetEffectiveScale()
        local uiScale = UIParent:GetEffectiveScale()
        absolute = {
            point = "TOPLEFT",
            relPoint = "BOTTOMLEFT",
            x = left * scale / uiScale,
            y = top * scale / uiScale,
        }
    end

    if GF.debugClicks then
        local relName = raw and raw.relativeTo and raw.relativeTo.GetName and raw.relativeTo:GetName() or "UIParent/nil"
        GF.Say("captured " .. (frame:GetName() or "?") ..
            " - raw: " .. tostring(raw and raw.point) .. " rel-to " .. tostring(relName) ..
            " " .. tostring(raw and raw.relPoint) .. " (" .. tostring(raw and raw.x) .. "," .. tostring(raw and raw.y) .. ")" ..
            " | absolute: " .. tostring(absolute and absolute.x) .. "," .. tostring(absolute and absolute.y))
    end

    if not raw and not absolute then return nil end
    return { raw = raw, absolute = absolute }
end

-- [name] = { point, relPoint, x, y }, keyed by frame NAME (not object - a
-- string survives just fine as a table key and this only ever needs to
-- match against getglobal() results). Captured proactively for EVERY
-- candidate frame, whether or not it's ever pinned, as early and as often
-- as possible - so "original position" always means "however it looked
-- before this addon ever touched it," never something read mid-session
-- after a pin (or an earlier bug) might have already moved it. PinFrame
-- prefers this over capturing fresh at pin-time for exactly that reason.
GF.knownOriginalPositions = {}

GF.FRAME_SETS = {
    { prefix = "PartyMemberFrame",        lo = 1, hi = 4 },
    { prefix = "ShaguTweaksRaidUnitFrame", lo = 1, hi = 40 },
    { prefix = "pfGroup",                 lo = 0, hi = 4 },
    { prefix = "pfRaid",                  lo = 1, hi = 40 },
}

function GF.ForEachCandidateFrame(fn)
    for _, set in ipairs(GF.FRAME_SETS) do
        for i = set.lo, set.hi do
            local name = set.prefix .. i
            local frame = getglobal(name)
            if frame then fn(frame, name) end
        end
    end
end

function GF.SnapshotAllFramePositions()
    GF.ForEachCandidateFrame(function(frame, name)
        if GF.knownOriginalPositions[name] then return end
        local p = CaptureOriginalPoint(frame)
        if p then GF.knownOriginalPositions[name] = p end
    end)
end

-- [pinnedFrame] = { frames that were anchored to it and had to be cut loose }
GF.detachedBy = {}

-- Blizzard's default party frames hang off each other - frame 2 is anchored
-- to frame 1, 3 to 2, and so on - so moving one drags every frame below it
-- along with it. Pull out one person and the whole stack follows them.
--
-- So before moving a frame, anything anchored TO it gets re-anchored to its
-- own current screen position instead, which cuts the chain and leaves it
-- sitting exactly where it already was. Only direct dependents need this:
-- once frame 2 is holding still on its own, frame 3 (anchored to 2) stays
-- put by itself. ReattachDependents puts the chain back on release.
function GF.DetachDependents(frame)
    local detached = {}
    GF.ForEachCandidateFrame(function(other)
        if other == frame or other.gfPinnedFor then return end
        local _, relativeTo = other:GetPoint()
        if relativeTo ~= frame then return end

        local cap = CaptureOriginalPoint(other)
        if not cap or not cap.absolute then return end
        other:ClearAllPoints()
        other:SetPoint(cap.absolute.point, UIParent, cap.absolute.relPoint, cap.absolute.x, cap.absolute.y)
        table.insert(detached, other)
        if GF.debugClicks then
            GF.Say("detached " .. (other:GetName() or "?") .. " so it won't follow " .. (frame:GetName() or "?"))
        end
    end)
    GF.detachedBy[frame] = detached
end

function GF.ReattachDependents(frame)
    local detached = GF.detachedBy[frame]
    if not detached then return end
    for _, other in ipairs(detached) do
        -- Skip any that have since been pinned in their own right - they're
        -- deliberately somewhere else now and shouldn't be yanked back.
        if not other.gfPinnedFor then
            local snap = other:GetName() and GF.knownOriginalPositions[other:GetName()]
            if snap and snap.raw then
                other:ClearAllPoints()
                pcall(other.SetPoint, other, snap.raw.point, snap.raw.relativeTo, snap.raw.relPoint, snap.raw.x, snap.raw.y)
            end
        end
    end
    GF.detachedBy[frame] = nil
end

-- Takes over `frame`'s positioning so the host raid-frame addon's own
-- layout code can no longer move it - see the header note for why this is
-- necessary. Safe to call again for the same frame (e.g. re-applying after
-- a reload); only captures the real SetPoint - and the frame's original,
-- host-assigned position - once, ever, per frame. That captured original
-- position is what makes UnpinFrame able to put it back explicitly instead
-- of hoping the host addon proactively re-lays it out on its own, which
-- some (Shagu's raid frames in particular, only on a real roster-change
-- event; Blizzard's default party frames, closer to never) simply don't do
-- on any predictable schedule.
function GF.PinFrame(frame, name)
    if not frame.gfRealSetPoint then
        frame.gfRealSetPoint = frame.SetPoint
    end
    if not frame.gfOriginalPoint then
        -- Prefer the early, proactive snapshot (see SnapshotAllFramePositions)
        -- over capturing fresh right now - by the time a frame actually gets
        -- pinned, it may already have been touched by an earlier pin/bug this
        -- session, so a fresh capture here is the less reliable fallback.
        local frameName = frame:GetName()
        frame.gfOriginalPoint = (frameName and GF.knownOriginalPositions[frameName]) or CaptureOriginalPoint(frame)
        if not frame.gfOriginalPoint then
            -- Couldn't read its position yet - probably not laid out by its
            -- host addon this early (e.g. right after a reload, racing
            -- against Shagu/pfUI creating and positioning their own
            -- frames). Bail out WITHOUT applying the pin: if we moved the
            -- frame now, the next retry would just capture the pinned spot
            -- itself as the "original" and we'd lose the real one for good.
            -- RefreshPins calls this again on the next cycle (frame is
            -- still untouched, still in its real position) until this
            -- actually succeeds.
            if GF.debugClicks then
                GF.Say("couldn't capture original position for " .. name .. " yet - will retry.")
            end
            return
        end
    end
    frame.gfPinnedFor = name

    frame.SetPoint = function(self, ...)
        local p = GF.pins[self.gfPinnedFor]
        if p then
            self.gfRealSetPoint(self, p.point, UIParent, p.relPoint, p.x, p.y)
        else
            self.gfRealSetPoint(self, ...)
        end
    end

    -- Cut loose anything anchored to this frame BEFORE moving it, or the
    -- whole stack below it comes along for the ride.
    GF.DetachDependents(frame)

    GF.ApplyPin(frame)
    EnableDragging(frame)
end

-- Hands the frame back AND explicitly restores its captured original
-- position right now, rather than waiting on the host addon's own layout
-- code to eventually do it (see PinFrame).
function GF.UnpinFrame(frame)
    if frame.gfRealSetPoint then
        frame.SetPoint = frame.gfRealSetPoint
        local o = frame.gfOriginalPoint
        if o then
            local restored = false
            -- Prefer the REAL anchor (e.g. "relative to PartyMemberFrame2's
            -- bottom") over the absolute-coordinate fallback - that's what
            -- keeps Blizzard's party frame stack tightly and evenly spaced
            -- exactly like it was, rather than freezing it at a fixed
            -- screen position that ignores the actual relationship between
            -- frames. pcall since replaying an arbitrary relativeTo isn't
            -- guaranteed safe for every frame type.
            -- Same reason as in ApplyPin: the pin's own anchor has to be
            -- cleared off, or restoring the original just adds a second,
            -- conflicting anchor next to it.
            if o.raw then
                if GF.debugClicks then
                    local relName = o.raw.relativeTo and o.raw.relativeTo.GetName and o.raw.relativeTo:GetName() or "nil"
                    GF.Say("restoring " .. (frame:GetName() or "?") .. " via raw anchor: " ..
                        tostring(o.raw.point) .. " rel-to " .. tostring(relName) .. " " .. tostring(o.raw.relPoint))
                end
                frame:ClearAllPoints()
                restored = pcall(frame.gfRealSetPoint, frame, o.raw.point, o.raw.relativeTo, o.raw.relPoint, o.raw.x, o.raw.y)
            end
            if not restored and o.absolute then
                if GF.debugClicks then
                    GF.Say("raw anchor restore failed or unavailable, falling back to absolute x=" ..
                        o.absolute.x .. " y=" .. o.absolute.y)
                end
                frame:ClearAllPoints()
                frame.gfRealSetPoint(frame, o.absolute.point, UIParent, o.absolute.relPoint, o.absolute.x, o.absolute.y)
            end
        elseif GF.debugClicks then
            GF.Say("no captured original position to restore for " .. (frame:GetName() or "?"))
        end
    end
    frame.gfPinnedFor = nil
    GF.ClearUserPlaced(frame)
    -- This frame is back where it belongs, so anything that used to hang off
    -- it can be re-hooked to it again.
    GF.ReattachDependents(frame)
end

-- Un-flags a frame as "user placed" so the client stops persisting its
-- position to layout-cache.txt - see the long note above dragDriver for why
-- that flag is the one piece of damage this addon could leave behind that
-- outlives the addon itself. Newer versions never set it in the first
-- place, but anyone who used an older version still has it stuck on their
-- party frames, so this runs on release and via /gf cleanup to repair it.
-- pcall because not every frame type necessarily implements these.
function GF.ClearUserPlaced(frame)
    if not frame.IsUserPlaced then return end
    local ok, placed = pcall(frame.IsUserPlaced, frame)
    if ok and placed and frame.SetUserPlaced then
        pcall(frame.SetUserPlaced, frame, false)
        if GF.debugClicks then
            GF.Say("cleared user-placed flag on " .. (frame:GetName() or "?"))
        end
    end
end

function GF.TogglePin(name)
    if not name then return end

    if GF.pins[name] then
        GF.pins[name] = nil
        GF_Pins = GF.pins
        local frame = GF.heldFrames[name]
        if frame then
            GF.UnpinFrame(frame)
            GF.heldFrames[name] = nil
        end
        GF.Say(name .. " released back to the grid.")
    else
        -- Drop new pins in the middle of the screen rather than the top-left
        -- corner: that corner is where PlayerFrame lives, so a freshly
        -- pulled-out frame landed underneath it and looked like it had just
        -- vanished. Each additional pin cascades down from center so several
        -- pulled out at once don't sit exactly on top of each other either.
        local count = 0
        for _ in pairs(GF.pins) do count = count + 1 end
        GF.pins[name] = { point = "CENTER", relPoint = "CENTER", x = 0, y = -(count * 50) }
        GF_Pins = GF.pins
        GF.Say(name .. " pulled out - drag to move, shift-right-click their frame again to release.")
        GF.RefreshPins()
    end
end

-- Re-resolves every pin's real frame (in case the raid reshuffled who's in
-- which slot) and re-hooks any frame this addon hasn't seen before, so
-- newly-created slots (e.g. a raid growing past 20 people) become
-- selectable too. Called on every roster change plus a light safety-net
-- timer (see the OnUpdate handler) in case some edge case slips past those
-- events.
function GF.RefreshPins()
    -- Always snapshot BEFORE touching any pins - this is what makes a saved
    -- pin re-applying itself after a reload safe: by the time PinFrame runs
    -- for it below, there's already a clean pre-pin position on record.
    GF.SnapshotAllFramePositions()

    for name, _ in pairs(GF.pins) do
        local newFrame = GF.FindFrameFor(name)
        local oldFrame = GF.heldFrames[name]

        if newFrame ~= oldFrame then
            if oldFrame then
                GF.UnpinFrame(oldFrame)
            end
            if newFrame then
                GF.PinFrame(newFrame, name)
            end
            GF.heldFrames[name] = newFrame
        elseif newFrame and not newFrame.gfOriginalPoint then
            -- Same frame as last cycle, but we still don't have its original
            -- position captured - see the note in PinFrame. Try again.
            GF.PinFrame(newFrame, name)
        end
    end

    GF.HookAllFrames()
end

-- ---------------------------------------------------------------------------------------------
-- Selection (shift-right-click to pull out / release)
-- ---------------------------------------------------------------------------------------------

-- Wraps whatever OnClick handler a frame already has (Blizzard's own party
-- frames, Shagu's UnitFrame_OnClick, or whatever pfUI attaches) so normal
-- clicks keep working exactly as before - this only adds a check for
-- shift-right-click on top.
function GF.HookSelection(frame, getUnit)
    if frame.gfHooked then return end
    frame.gfHooked = true

    local orig = frame:GetScript("OnClick")
    frame:SetScript("OnClick", function()
        -- Read these BEFORE calling the original handler, not after - Shagu's
        -- own OnClick opens the unit dropdown menu on any right-click
        -- (ToggleDropDownMenu), and menu/UI code like that can process other
        -- frames' scripts as a side effect, which can clobber the global
        -- arg1/this by the time control comes back to us. Capturing first
        -- makes this immune to whatever the wrapped handler does internally.
        local button = arg1
        local shiftHeld = IsShiftKeyDown()

        if GF.debugClicks then
            GF.Say("click seen on " .. (this:GetName() or "?") .. " - button=" .. tostring(button) ..
                " shift=" .. tostring(shiftHeld))
        end

        -- pcall so an error inside the original handler (unrelated to this
        -- addon) can't silently eat our own logic below it.
        if orig then pcall(orig) end

        if button == "RightButton" and shiftHeld then
            local unit = getUnit()
            if unit and UnitExists(unit) then
                GF.TogglePin(UnitName(unit))
            else
                GF.Say("|cFFFF3333couldn't find a valid unit on that frame|r - try again after a roster update.")
            end
        end
    end)
end

function GF.HookAllFrames()
    for i = 1, 4 do
        local frame = getglobal("PartyMemberFrame" .. i)
        if frame then
            local unit = "party" .. i
            GF.HookSelection(frame, function() return unit end)
        end
    end

    for i = 1, 40 do
        local frame = getglobal("ShaguTweaksRaidUnitFrame" .. i)
        if frame then
            GF.HookSelection(frame, function() return frame.unitstr end)
        end
    end

    for i = 0, 4 do
        local frame = getglobal("pfGroup" .. i)
        if frame then
            GF.HookSelection(frame, function()
                return frame.label and frame.id and (frame.label .. frame.id) or nil
            end)
        end
    end

    for i = 1, 40 do
        local frame = getglobal("pfRaid" .. i)
        if frame then
            GF.HookSelection(frame, function()
                return frame.label and frame.id and (frame.label .. frame.id) or nil
            end)
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------------------------
SLASH_GRAYFATHERSFRAMEROIDS1 = "/gf"
SLASH_GRAYFATHERSFRAMEROIDS2 = "/frameroids"
SlashCmdList["GRAYFATHERSFRAMEROIDS"] = function(msg)
    msg = string.lower(msg or "")
    local cmd, arg2 = "", ""
    local i = 1
    for word in string.gfind(msg .. " ", "([^ ]+)") do
        if i == 1 then cmd = word elseif i == 2 then arg2 = word end
        i = i + 1
    end

    if cmd == "reset" or (cmd == "clear" and arg2 == "all") then
        for name, _ in pairs(GF.pins) do
            local frame = GF.heldFrames[name]
            if frame then GF.UnpinFrame(frame) end
        end
        GF.pins = {}
        GF.heldFrames = {}
        GF_Pins = GF.pins
        GF.Say("reset - everyone released back to the grid.")
    elseif cmd == "cleanup" then
        -- Repairs the one bit of damage older versions of this addon could
        -- leave behind - see GF.ClearUserPlaced.
        local cleared = 0
        local function sweep(prefix, lo, hi)
            for i = lo, hi do
                local f = getglobal(prefix .. i)
                if f and f.IsUserPlaced then
                    local ok, placed = pcall(f.IsUserPlaced, f)
                    if ok and placed then
                        GF.ClearUserPlaced(f)
                        cleared = cleared + 1
                    end
                end
            end
        end
        sweep("PartyMemberFrame", 1, 4)
        sweep("ShaguTweaksRaidUnitFrame", 1, 40)
        sweep("pfGroup", 0, 4)
        sweep("pfRaid", 1, 40)
        GF.Say("cleared the user-placed flag on " .. cleared .. " frame(s). Log out (not just /reloadui) " ..
            "so the client rewrites layout-cache.txt without them.")
    elseif cmd == "clear" and arg2 ~= "" then
        if GF.pins[arg2] then
            GF.TogglePin(arg2)
        else
            GF.Say("no pin found for \"" .. arg2 .. "\".")
        end
    elseif cmd == "" then
        local any = false
        for name, _ in pairs(GF.pins) do
            any = true
            GF.Say("- " .. name .. (GF.heldFrames[name] and "" or " |cFF888888(not currently visible)|r"))
        end
        if not any then
            GF.Say("nothing pulled out. Shift-right-click a party/raid frame to pull someone out.")
        end
    elseif cmd == "probe" then
        -- Diagnostic: how many of each frame type currently exist, and how
        -- many of those this addon has actually managed to hook for
        -- shift-right-click. If a count is 0/0, that frame type just isn't
        -- there (wrong addon/not loaded). If it's e.g. 40/0, frames exist
        -- but hooking isn't reaching them - a real bug. If it's 40/40 and
        -- shift-right-click still does nothing, the click IS reaching the
        -- handler and the problem is in unit resolution, not hooking.
        local function count(prefix, lo, hi)
            local total, hooked = 0, 0
            for i = lo, hi do
                local f = getglobal(prefix .. i)
                if f then
                    total = total + 1
                    if f.gfHooked then hooked = hooked + 1 end
                end
            end
            return hooked, total
        end
        local ph, pt = count("PartyMemberFrame", 1, 4)
        local sh, st = count("ShaguTweaksRaidUnitFrame", 1, 40)
        local pgh, pgt = count("pfGroup", 0, 4)
        local prh, prt = count("pfRaid", 1, 40)
        GF.Say("hooked/found - Blizzard party: " .. ph .. "/" .. pt ..
            ", Shagu raid: " .. sh .. "/" .. st ..
            ", pfUI party: " .. pgh .. "/" .. pgt ..
            ", pfUI raid: " .. prh .. "/" .. prt)
    elseif cmd == "debug" then
        GF.debugClicks = not GF.debugClicks
        GF.Say("click debugging: " .. (GF.debugClicks and "|cFF00FF7Fon|r - every click on a hooked frame will print here" or "|cFFFF5179off|r"))
    else
        GF.Say("usage: /gf, /gf clear <name>, /gf reset, /gf cleanup, /gf probe, /gf debug")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == GF.ADDON_NAME then
        GF.pins = GF_Pins or {}
    else
        GF.RefreshPins()
    end
end)

-- Light safety net - cheap (a few dozen getglobal/UnitExists checks), and
-- catches the rare case a host addon reflows its frames without firing an
-- event this file is listening for.
GF.safetyTimer = 0
ev:SetScript("OnUpdate", function()
    GF.safetyTimer = GF.safetyTimer + arg1
    if GF.safetyTimer >= 2 then
        GF.safetyTimer = 0
        GF.RefreshPins()
    end
end)
