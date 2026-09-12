--[[
    test_ordering.lua - runs the addon's stack layout logic against a mock
    party and checks who ends up where.

    Usage (from the repo root):
        lua tools/test_ordering.lua [path/to/addon.lua]

    The optional path exists so a deliberately-mutated copy can be tested
    without touching the real file - which is how this suite gets checked for
    teeth (break something on purpose, confirm a test actually fails).

    These cover the behaviours that were expensive to verify by hand, because
    each one previously took a /reloadui, a group, and a screenshot to see:
    gaps closing behind a pulled-out member, fixed stack positions, contested
    positions, and handing the stack back to its owner afterwards. Every
    failure in this file was a real bug at some point.
--]]

local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "GrayfathersFrameroids.lua"

local failures, checks = 0, 0

local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

-- Blizzard's real party layout: frame 1 anchors to the screen, and 2/3/4 each
-- hang off the frame above them. Reproducing that chain (rather than giving
-- all four independent positions) is deliberate - the chain is what used to
-- drag the whole stack along when one frame moved.
local PARTY_TOP, PARTY_HEIGHT, PARTY_GAP = 700, 49, 11
local SLOT = { PARTY_TOP, PARTY_TOP - 60, PARTY_TOP - 120, PARTY_TOP - 180 }

local function buildWorld(names)
    Stub.Reset()
    Stub.SetRoster({ player = "Me", party = names })

    for i = 1, 4 do
        local f = Stub.CreateFrame("Button", "PartyMemberFrame" .. i)
        f._w, f._h = 120, PARTY_HEIGHT
        if names[i] then f:Show() else f:Hide() end
        if i == 1 then
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 20, PARTY_TOP)
        else
            f:SetPoint("TOPLEFT", _G["PartyMemberFrame" .. (i - 1)], "BOTTOMLEFT", 0, -PARTY_GAP)
        end
    end

    dofile(ADDON_PATH)
    GF.pins, GF.order = {}, {}
    GF.RefreshPins() -- snapshots original positions, as a real tick would
end

-- pfUI anchors its frames by BOTTOMLEFT, where Blizzard's party frames use
-- TOPLEFT. That difference is not cosmetic: SetPoint only REPLACES an anchor
-- with the same point name and otherwise ADDS a second one, so restacking a
-- BOTTOMLEFT-anchored frame with a TOPLEFT point without clearing first
-- leaves two conflicting anchors and the frame silently refuses to move.
-- That shipped once (v1.0.6), so it gets its own world.
local function buildPfUIWorld(names)
    Stub.Reset()
    Stub.SetRoster({ player = "Me", party = names })

    -- Blizzard's party frames still EXIST here, hidden - pfUI and ShaguTweaks
    -- hide them and draw their own rather than deleting them. Leaving them out
    -- of this world would make it unfaithful in the one way that matters:
    -- resolving a name has to pick the visible frame, and a world with no
    -- competing hidden frame can't tell whether it does.
    for i = 1, 4 do
        local f = Stub.CreateFrame("Button", "PartyMemberFrame" .. i)
        f._w, f._h = 120, PARTY_HEIGHT
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 20, SLOT[i])
        f:Hide()
    end

    for i = 1, 4 do
        local f = Stub.CreateFrame("Button", "pfGroup" .. i)
        f._w, f._h = 120, PARTY_HEIGHT
        f.label, f.id = "party", i
        if names[i] then f:Show() else f:Hide() end
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, SLOT[i] - PARTY_HEIGHT)
    end

    dofile(ADDON_PATH)
    GF.pins, GF.order = {}, {}
    GF.RefreshPins()
end

local function pfStackOrder()
    local rows = {}
    for i = 1, 4 do
        local f = _G["pfGroup" .. i]
        if f and f:IsShown() and not f.gfPinnedFor then
            table.insert(rows, { name = Stub.roster.party[i], top = f:GetTop() })
        end
    end
    table.sort(rows, function(a, b) return a.top > b.top end)
    local names = {}
    for _, r in ipairs(rows) do table.insert(names, r.name) end
    return table.concat(names, ",")
end

-- Which party member's frame is sitting in each slot, top to bottom.
local function stackOrder()
    local rows = {}
    for i = 1, 4 do
        local f = _G["PartyMemberFrame" .. i]
        if f and f:IsShown() and not f.gfPinnedFor then
            table.insert(rows, { name = Stub.roster.party[i], top = f:GetTop() })
        end
    end
    table.sort(rows, function(a, b) return a.top > b.top end)
    local names = {}
    for _, r in ipairs(rows) do table.insert(names, r.name) end
    return table.concat(names, ","), rows
end

local function topOfPartyIndex(i)
    return _G["PartyMemberFrame" .. i]:GetTop()
end

local FOUR = { "Alice", "Bob", "Cara", "Tank" }

-- ---------------------------------------------------------------------------
print("untouched stack is left alone")
do
    buildWorld(FOUR)
    check("order", (stackOrder()), "Alice,Bob,Cara,Tank")
    for i = 1, 4 do
        check("frame " .. i .. " top", topOfPartyIndex(i), SLOT[i])
    end
    -- Nothing pinned and no fixed positions: the addon must not have taken
    -- the set over at all.
    check("set not managed", GF.FRAME_SETS[1].managed, nil)
end

-- ---------------------------------------------------------------------------
print("a fixed position moves one person to the top, everyone else shifts down")
do
    buildWorld(FOUR)
    GF.SetOrder("Tank", 1)
    check("order", (stackOrder()), "Tank,Alice,Bob,Cara")
    check("tank is in the top slot", topOfPartyIndex(4), SLOT[1])
    check("set managed", GF.FRAME_SETS[1].managed, true)
end

-- ---------------------------------------------------------------------------
print("a fixed position in the middle of the stack")
do
    buildWorld(FOUR)
    GF.SetOrder("Tank", 2)
    check("order", (stackOrder()), "Alice,Tank,Bob,Cara")
    check("tank is in the second slot", topOfPartyIndex(4), SLOT[2])
end

-- ---------------------------------------------------------------------------
print("two people wanting the same position: most recent wins, other lands below")
do
    buildWorld(FOUR)
    GF.SetOrder("Alice", 1)
    GF.SetOrder("Tank", 1)
    check("order", (stackOrder()), "Tank,Alice,Bob,Cara")
end

-- ---------------------------------------------------------------------------
print("a position past the end of the stack falls back to the top")
do
    buildWorld(FOUR)
    GF.SetOrder("Tank", 10) -- ranked for a 40-man, currently in a 5-man
    check("order", (stackOrder()), "Tank,Alice,Bob,Cara")
end

-- ---------------------------------------------------------------------------
print("pulling someone out closes the gap behind them")
do
    buildWorld(FOUR)
    GF.TogglePin("Bob")
    check("bob is pinned", GF.heldFrames["Bob"] ~= nil, true)
    check("order", (stackOrder()), "Alice,Cara,Tank")
    check("cara moved up into bob's slot", topOfPartyIndex(3), SLOT[2])
    check("tank moved up one", topOfPartyIndex(4), SLOT[3])
    -- The top slot must be used - this was the v1.1.1 bug.
    check("alice still in the top slot", topOfPartyIndex(1), SLOT[1])
end

-- ---------------------------------------------------------------------------
print("a fixed position and a pulled-out member at the same time")
do
    buildWorld(FOUR)
    GF.TogglePin("Bob")
    GF.SetOrder("Tank", 1)
    check("order", (stackOrder()), "Tank,Alice,Cara")
    check("tank is in the top slot", topOfPartyIndex(4), SLOT[1])
end

-- ---------------------------------------------------------------------------
print("a missing snapshot still produces a full slot list (v1.1.1 regression)")
do
    buildWorld(FOUR)
    -- Simulates a frame that was hidden when snapshots were taken, so nothing
    -- was recorded for it - which used to shorten the slot list and silently
    -- leave the top slot empty.
    GF.knownOriginalPositions["PartyMemberFrame1"] = nil
    GF.SetOrder("Tank", 1)
    check("order", (stackOrder()), "Tank,Alice,Bob,Cara")
    check("top slot is used", topOfPartyIndex(4), SLOT[1])
end

-- ---------------------------------------------------------------------------
print("clearing the last fixed position hands the stack back to its owner")
do
    buildWorld(FOUR)
    GF.SetOrder("Tank", 1)
    check("managed while ordered", GF.FRAME_SETS[1].managed, true)

    GF.ClearOrder("Tank")
    check("no longer managed", GF.FRAME_SETS[1].managed, nil)
    check("order", (stackOrder()), "Alice,Bob,Cara,Tank")
    for i = 1, 4 do
        check("frame " .. i .. " back at its original top", topOfPartyIndex(i), SLOT[i])
    end
    -- Restored via the real anchor chain, not frozen absolute coordinates:
    -- frame 2 must once again hang off frame 1.
    local _, relativeTo = _G.PartyMemberFrame2:GetPoint()
    check("frame 2 re-anchored to frame 1", relativeTo, _G.PartyMemberFrame1)
end

-- ---------------------------------------------------------------------------
print("ctrl-right-click toggles someone to the top")
do
    buildWorld(FOUR)
    Stub.ctrlDown = true
    Stub.FireScript(_G.PartyMemberFrame4, "OnClick", nil, "RightButton")
    check("tank ordered to the top", GF.order["Tank"], 1)
    check("order", (stackOrder()), "Tank,Alice,Bob,Cara")

    Stub.FireScript(_G.PartyMemberFrame4, "OnClick", nil, "RightButton")
    check("second ctrl-right-click clears it", GF.order["Tank"], nil)
    check("order", (stackOrder()), "Alice,Bob,Cara,Tank")
    Stub.ctrlDown = false
end

-- ---------------------------------------------------------------------------
print("shift-right-click pulls someone out")
do
    buildWorld(FOUR)
    Stub.shiftDown = true
    Stub.FireScript(_G.PartyMemberFrame2, "OnClick", nil, "RightButton")
    check("bob pulled out", GF.pins["Bob"] ~= nil, true)
    check("order", (stackOrder()), "Alice,Cara,Tank")
    Stub.shiftDown = false
end

-- ---------------------------------------------------------------------------
print("slash commands accept names however they're typed")
do
    buildWorld(FOUR)
    Stub.RunSlash("GRAYFATHERSFRAMEROIDS", "top tank")
    check("lowercase name resolved", GF.order["Tank"], 1)

    Stub.RunSlash("GRAYFATHERSFRAMEROIDS", "order TANK 3")
    check("uppercase name resolved", GF.order["Tank"], 3)

    Stub.RunSlash("GRAYFATHERSFRAMEROIDS", "order clear TaNk")
    check("mixed case name resolved", GF.order["Tank"], nil)

    GF.TogglePin("Bob")
    Stub.RunSlash("GRAYFATHERSFRAMEROIDS", "clear bob")
    check("clear <name> released the pin", GF.pins["Bob"], nil)
end

-- ---------------------------------------------------------------------------
print("reset clears both pins and fixed positions")
do
    buildWorld(FOUR)
    GF.TogglePin("Bob")
    GF.SetOrder("Tank", 1)
    Stub.RunSlash("GRAYFATHERSFRAMEROIDS", "reset")
    check("pins cleared", next(GF.pins), nil)
    check("positions cleared", next(GF.order), nil)
    check("order", (stackOrder()), "Alice,Bob,Cara,Tank")
end

-- ---------------------------------------------------------------------------
print("a three-person party (fewer frames than slots)")
do
    buildWorld({ "Alice", "Bob", "Tank" })
    GF.SetOrder("Tank", 1)
    check("order", (stackOrder()), "Tank,Alice,Bob")
    check("tank in the top slot", topOfPartyIndex(3), SLOT[1])
end

-- ---------------------------------------------------------------------------
print("frames anchored by BOTTOMLEFT (pfUI-style) still move")
do
    buildPfUIWorld(FOUR)
    check("untouched order", pfStackOrder(), "Alice,Bob,Cara,Tank")

    GF.SetOrder("Tank", 1)
    check("order", pfStackOrder(), "Tank,Alice,Bob,Cara")
    check("tank actually reached the top slot", _G.pfGroup4:GetTop(), SLOT[1])
    -- If the old anchor was left in place, the frame would carry two
    -- conflicting anchors instead of one.
    check("single anchor after restack", _G.pfGroup4:GetNumPoints(), 1)
end

-- ---------------------------------------------------------------------------
print("pulling out a BOTTOMLEFT-anchored frame closes the gap")
do
    buildPfUIWorld(FOUR)
    GF.TogglePin("Bob")
    check("order", pfStackOrder(), "Alice,Cara,Tank")
    check("cara moved up into bob's slot", _G.pfGroup3:GetTop(), SLOT[2])

    GF.TogglePin("Bob")
    check("released", GF.pins["Bob"], nil)
    check("order", pfStackOrder(), "Alice,Bob,Cara,Tank")
    check("cara back where she started", _G.pfGroup3:GetTop(), SLOT[3])
end

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print("all " .. checks .. " checks passed")
    os.exit(0)
else
    print(failures .. " of " .. checks .. " checks FAILED")
    os.exit(1)
end
