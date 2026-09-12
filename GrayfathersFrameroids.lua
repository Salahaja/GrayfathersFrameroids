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
    systems know or care that we've moved their frame. Each one re-asserts
    its own grid position on every roster update (Shagu's raid.lua and
    pfUI's raid.lua/group.lua both do this), so a plain one-time
    reposition would just get snapped back on the next update. The fix
    (see PinFrame) is to replace the frame's own SetPoint method with a
    wrapper that redirects any position change back to our saved spot -
    unless WE are the ones dragging it (frame.gfDragging), in which case
    it passes through untouched so native StartMoving() tracking still
    works. This is a per-frame-instance override (only shadows SetPoint on
    that one Lua table), so it can't affect any other frame.

    Selection: shift-right-click any of those frames to pull that person
    out (or put them back if already pulled out). Every candidate frame
    gets this hook lazily (see HookAllFrames) without disturbing its
    normal single-click targeting or plain right-click menu - it wraps
    whatever OnClick handler was already there rather than replacing it.

    Slash Commands (both equivalent - /gf, /frameroids):
        /gf                 lists everyone currently pulled out
        /gf clear <name>    puts a specific person back
        /gf clear all       puts everyone back
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

-- One-time per frame: lets it be dragged, and saves the new position when
-- you drop it. Doesn't touch existing scripts other than SetPoint (handled
-- separately in PinFrame) - dragging is a separate registration from
-- clicking, so normal targeting/menu behavior is unaffected.
local function EnableDragging(frame)
    if frame.gfDragSetup then return end
    frame.gfDragSetup = true

    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    local origDragStart = frame:GetScript("OnDragStart")
    local origDragStop = frame:GetScript("OnDragStop")

    frame:SetScript("OnDragStart", function()
        if origDragStart then origDragStart() end
        this.gfDragging = true
        this:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        this.gfDragging = false
        this:StopMovingOrSizing()
        if origDragStop then origDragStop() end

        local name = this.gfPinnedFor
        if name then
            local point, _, relPoint, x, y = this:GetPoint()
            GF.pins[name] = { point = point, relPoint = relPoint, x = x, y = y }
            GF_Pins = GF.pins
        end
    end)
end

-- Takes over `frame`'s positioning so the host raid-frame addon's own
-- layout code can no longer move it - see the header note for why this is
-- necessary. Safe to call again for the same frame (e.g. re-applying after
-- a reload); only captures the real SetPoint once, ever, per frame.
function GF.PinFrame(frame, name)
    if not frame.gfRealSetPoint then
        frame.gfRealSetPoint = frame.SetPoint
    end
    frame.gfPinnedFor = name

    frame.SetPoint = function(self, ...)
        if self.gfDragging then
            self.gfRealSetPoint(self, ...)
            return
        end
        local p = GF.pins[self.gfPinnedFor]
        if p then
            self.gfRealSetPoint(self, p.point, UIParent, p.relPoint, p.x, p.y)
        else
            self.gfRealSetPoint(self, ...)
        end
    end

    local p = GF.pins[name]
    if p then
        frame.gfRealSetPoint(frame, p.point, UIParent, p.relPoint, p.x, p.y)
    end

    EnableDragging(frame)
end

-- Hands the frame back - the NEXT time its host addon's layout code runs
-- (its own next roster-update pass), it'll reposition normally again.
function GF.UnpinFrame(frame)
    if frame.gfRealSetPoint then
        frame.SetPoint = frame.gfRealSetPoint
    end
    frame.gfPinnedFor = nil
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
        local count = 0
        for _ in pairs(GF.pins) do count = count + 1 end
        GF.pins[name] = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 20, y = -20 - (count * 40) }
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
        if orig then orig() end
        if arg1 == "RightButton" and IsShiftKeyDown() then
            local unit = getUnit()
            if unit and UnitExists(unit) then
                GF.TogglePin(UnitName(unit))
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

    if cmd == "clear" and arg2 == "all" then
        for name, _ in pairs(GF.pins) do
            local frame = GF.heldFrames[name]
            if frame then GF.UnpinFrame(frame) end
        end
        GF.pins = {}
        GF.heldFrames = {}
        GF_Pins = GF.pins
        GF.Say("all pins cleared.")
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
    else
        GF.Say("usage: /gf, /gf clear <name>, /gf clear all")
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
