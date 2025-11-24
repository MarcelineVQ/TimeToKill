-- TimeToKill.lua - Multi-target TTK display with RLS tracking
-- Shows HP bars for bosses and important adds with TTK estimation

local EXECUTE_THRESHOLD = 0.20  -- 20% HP
local WARNING_THRESHOLD = 40    -- Seconds
local MAX_BARS = 5              -- Maximum tracked targets

-- Frame state (will be loaded from SavedVariables)
local isLocked = false
local clickToTargetEnabled = true
local testMode = true  -- Track any targeted enemy, not just bosses (default: on)

local function printo(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TTK]|r " .. tostring(msg))
end

-- ============================================================================
-- ZONE-BASED MOB TRACKING TABLE
-- ============================================================================

local TTK_ZONE_MOBS = {
    ["Molten Core"] = {
        ["Lava Spawn"] = true,
        ["Flamewaker Protector"] = true,
        -- ["Flamewaker Priest"] = true, -- probably just noise
    },
    -- ["Blackwing Lair"] = {
        -- ["Death Talon Captain"] = true, ["Death Talon Flamescale"] = true,
        -- ["Death Talon Seether"] = true, ["Death Talon Wyrmkin"] = true,
        -- ["Blackwing Mage"] = true, ["Blackwing Warlock"] = true,
        -- ["Corrupted Red Whelp"] = true, ["Chromatic Drakonid"] = true,
    -- },
    ["Temple of Ahn'Qiraj"] = {
        ["Anubisath Sentinel"] = true,
    },
    ["Naxxramas"] = {
        ["Crypt Guard"] = true,
        ["Naxxramas Follower"] = true,
        ["Naxxramas Worshipper"] = true,
    },
    ["Zul'Gurub"] = {
        ["Zealot Zath"] = true,
        ["Zealot Lor'Khan"] = true,
        ["Ohgan"] = true,
    },
    ["Tower of Karazhan"] = {
        ["Red Owl"] = true,
        ["Blue Owl"] = true,
        ["Living Stone"] = true,
        ["Living Fragment"] = true,
        ["Draenei Netherwalker"] = true,
    },
    -- Add more zones as needed
}

-- Mobs to never track (even if they're bosses)
local TTK_IGNORED_MOBS = {
    ["Majordomo Executus"] = true,
    ["Emperor Vek'lor"] = true,
    -- Add more ignored mobs as needed
}

local currentZoneAdds = nil  -- Points to current zone's add list

-- ============================================================================
-- MAIN FRAME SETUP
-- ============================================================================

local BAR_WIDTH = 234
local BAR_HEIGHT = 14
local BAR_SPACING = 2
local EXEC_WIDTH = BAR_WIDTH * EXECUTE_THRESHOLD  -- 20% of bar
local BASE_HEIGHT = 8  -- Padding for mainFrame

local mainFrame = CreateFrame("Frame", "TTKMainFrame", UIParent)
mainFrame:SetFrameStrata("LOW")  -- Below UIParent (MEDIUM) -- hopefully reduce frame crash issues
mainFrame:SetWidth(250)
mainFrame:SetHeight(BASE_HEIGHT)
mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
mainFrame:SetScript("OnDragStart", function() mainFrame:StartMoving() end)
mainFrame:SetScript("OnDragStop", function()
    mainFrame:StopMovingOrSizing()
    local point, _, relPoint, x, y = mainFrame:GetPoint()
    TTK_Config = TTK_Config or {}
    TTK_Config.point = point
    TTK_Config.relPoint = relPoint
    TTK_Config.x = x
    TTK_Config.y = y
end)
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)  -- Default: unlocked
mainFrame:RegisterForDrag("LeftButton")

mainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
mainFrame:SetBackdropColor(0, 0, 0, 0.9)
mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

-- Placeholder label for unlocked state with no bars
local placeholderLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
placeholderLabel:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)
placeholderLabel:SetText("[TTK] Unlocked")
placeholderLabel:Hide()

-- Unlocked placeholder uses max size so users can position properly
local PLACEHOLDER_WIDTH = 250
local PLACEHOLDER_HEIGHT = BASE_HEIGHT + (MAX_BARS * (BAR_HEIGHT + 12 + BAR_SPACING))

-- ============================================================================
-- BAR POOL SYSTEM
-- ============================================================================

local barPool = {}      -- Available bars
local activeBars = {}   -- Bars currently in use, keyed by unitID

-- Create a single bar with all components
local function CreateBar()
    local bar = CreateFrame("Frame", nil, mainFrame)
    bar:SetWidth(BAR_WIDTH)
    bar:SetHeight(BAR_HEIGHT + 12)  -- Bar + text row
    bar:Hide()

    -- Top row: Name (left), DPS (center), HP (right)
    bar.nameLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.nameLabel:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    bar.nameLabel:SetTextColor(1, 1, 1)

    bar.dpsLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.dpsLabel:SetPoint("TOP", bar, "TOP", 0, 0)
    bar.dpsLabel:SetTextColor(1, 1, 1)

    bar.hpLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.hpLabel:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    bar.hpLabel:SetTextColor(1, 1, 1)

    -- HP bar container
    bar.barFrame = CreateFrame("Frame", nil, bar)
    bar.barFrame:SetWidth(BAR_WIDTH)
    bar.barFrame:SetHeight(BAR_HEIGHT)
    bar.barFrame:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)

    -- Background (layer 0)
    bar.hpBarBg = bar.barFrame:CreateTexture(nil, "BACKGROUND")
    bar.hpBarBg:SetAllPoints()
    bar.hpBarBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.hpBarBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)

    -- Main HP texture (layer 1)
    bar.hpTex = bar.barFrame:CreateTexture(nil, "BORDER")
    bar.hpTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.hpTex:SetVertexColor(0.2, 0.8, 0.2)
    bar.hpTex:SetHeight(BAR_HEIGHT)
    bar.hpTex:SetPoint("RIGHT", bar.barFrame, "RIGHT", 0, 0)
    bar.hpTex:SetWidth(BAR_WIDTH)

    -- Execute zone (layer 2, on top of hpTex)
    bar.execZone = bar.barFrame:CreateTexture(nil, "ARTWORK")
    bar.execZone:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.execZone:SetVertexColor(0.8, 0.25, 0.25)
    bar.execZone:SetHeight(BAR_HEIGHT)
    bar.execZone:SetPoint("RIGHT", bar.barFrame, "RIGHT", 0, 0)
    bar.execZone:SetWidth(EXEC_WIDTH)

    -- TTK text (left side of bar)
    bar.ttkLabel = bar.barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.ttkLabel:SetPoint("LEFT", bar.barFrame, "LEFT", 4, 0)
    bar.ttkLabel:SetTextColor(1, 1, 1)

    -- Time to Execute text (right side)
    bar.execLabel = bar.barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.execLabel:SetPoint("RIGHT", bar.barFrame, "RIGHT", -4, 0)
    bar.execLabel:SetTextColor(1, 0.9, 0.9)

    -- Raid target icon (center of bar)
    bar.raidIcon = bar.barFrame:CreateTexture(nil, "OVERLAY")
    bar.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    bar.raidIcon:SetWidth(BAR_HEIGHT - 2)
    bar.raidIcon:SetHeight(BAR_HEIGHT - 2)
    bar.raidIcon:SetPoint("CENTER", bar.barFrame, "CENTER", 0, 0)
    bar.raidIcon:Hide()

    -- Metadata
    bar.unitID = nil
    bar.isBoss = false
    bar.creationOrder = 0

    -- Click to target (enabled state set by UpdateBarClickState)
    bar:EnableMouse(isLocked and clickToTargetEnabled)
    bar:SetScript("OnMouseUp", function()
        if this.unitID then
            TargetUnit(this.unitID)
        end
    end)

    return bar
end

-- Update click-to-target state for all bars
local function UpdateBarClickState()
    local shouldEnable = isLocked and clickToTargetEnabled
    for i = 1, table.getn(barPool) do
        barPool[i]:EnableMouse(shouldEnable)
    end
    for unitID, bar in pairs(activeBars) do
        bar:EnableMouse(shouldEnable)
    end
end

-- Initialize bar pool
for i = 1, MAX_BARS do
    table.insert(barPool, CreateBar())
end

-- Get a bar from pool
local function AcquireBar()
    if table.getn(barPool) > 0 then
        return table.remove(barPool)
    end
    return nil  -- No bars available
end

-- Return bar to pool
local function ReleaseBar(bar)
    bar:Hide()
    bar.unitID = nil
    bar.isBoss = false
    table.insert(barPool, bar)
end

-- Reposition all active bars and resize mainFrame
local function RepositionBars()
    -- Sort: bosses first (by name), then adds (by creation order)
    local sorted = {}
    for unitID, bar in pairs(activeBars) do
        table.insert(sorted, bar)
    end

    table.sort(sorted, function(a, b)
        if a.isBoss and not b.isBoss then return true end
        if not a.isBoss and b.isBoss then return false end
        if a.isBoss and b.isBoss then
            return (a.nameLabel:GetText() or "") < (b.nameLabel:GetText() or "")
        end
        return a.creationOrder < b.creationOrder
    end)

    -- Position bars
    local yOffset = -4
    for i, bar in ipairs(sorted) do
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 8, yOffset)
        bar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -8, yOffset)
        yOffset = yOffset - (BAR_HEIGHT + 12 + BAR_SPACING)
    end

    -- Resize mainFrame
    local numBars = table.getn(sorted)
    if numBars > 0 then
        local totalHeight = BASE_HEIGHT + (numBars * (BAR_HEIGHT + 12 + BAR_SPACING))
        mainFrame:SetWidth(250)
        mainFrame:SetHeight(totalHeight)
        mainFrame:Show()
        placeholderLabel:Hide()
    else
        -- No bars - behavior depends on lock state
        if isLocked then
            mainFrame:Hide()
            placeholderLabel:Hide()
        else
            -- Unlocked: show placeholder with test mode status
            mainFrame:SetWidth(PLACEHOLDER_WIDTH)
            mainFrame:SetHeight(PLACEHOLDER_HEIGHT)
            mainFrame:Show()
            if testMode then
                placeholderLabel:SetText("[TTK] Test Mode")
            else
                placeholderLabel:SetText("[TTK] Unlocked")
            end
            placeholderLabel:Show()
        end
    end
end

-- ============================================================================
-- TRACKING STATE
-- ============================================================================

local trackedMobs = {}      -- Mob data keyed by unitID
local creationCounter = 0   -- For ordering adds

local SAMPLE_INTERVAL = 1.0
local DISPLAY_SMOOTHING = 0.15

-- Clone estimator with fresh state
local function CloneEstimator(template)
    local clone = {}
    for k, v in pairs(template) do
        clone[k] = v
    end
    clone:init()
    return clone
end

-- Check if a name is in the current zone's add list
local function IsTrackedAdd(name)
    return currentZoneAdds and currentZoneAdds[name]
end

-- Create mob tracker with dual RLS (TTK and TTE)
local function CreateMobTracker(unitID, name, isBoss)
    creationCounter = creationCounter + 1
    local mob = {
        unitID = unitID,
        name = name,
        isBoss = isBoss,
        maxHp = 0,
        lastHP = nil,
        lastHPPercent = 100,
        lastSampleTime = 0,
        fightStartTime = nil,
        creationOrder = creationCounter,
        -- Dual RLS estimators
        rlsTTK = CloneEstimator(TTK.estimators.RLS),  -- Time to Kill (HP -> 0)
        rlsTTE = CloneEstimator(TTK.estimators.RLS),  -- Time to Execute (HP -> 20%)
        -- Smoothed display values
        smoothTTK = nil,
        smoothTTE = nil,
        -- Associated bar
        bar = nil
    }
    return mob
end

-- ============================================================================
-- DISPLAY UPDATE
-- ============================================================================

local function SmoothValue(current, target, factor)
    if not current or current < 0 then return target end
    if not target or target < 0 then return current end
    return current + (target - current) * factor
end

local function FormatHP(hp)
    if hp >= 1000000 then
        return string.format("%.1fM", hp / 1000000)
    elseif hp >= 1000 then
        return string.format("%.0fK", hp / 1000)
    else
        return string.format("%.0f", hp)
    end
end

local function TruncateName(name, maxLen)
    if string.len(name) > maxLen then
        return string.sub(name, 1, maxLen) .. "..."
    end
    return name
end

-- Update a single bar's display
local function UpdateBarDisplay(mob, bar, hp, maxHp, hpPercent)
    local execThresholdPct = EXECUTE_THRESHOLD * 100  -- 20

    -- Update name and HP display
    bar.nameLabel:SetText(TruncateName(mob.name, 16))
    bar.hpLabel:SetText(string.format("%s / %s", FormatHP(hp), FormatHP(maxHp)))

    -- Update raid target icon
    local raidIndex = GetRaidTargetIndex(mob.unitID)
    if raidIndex then
        SetRaidTargetIconTexture(bar.raidIcon, raidIndex)
        bar.raidIcon:Show()
    else
        bar.raidIcon:Hide()
    end

    -- Update bar width
    local barWidth = math.max(1, BAR_WIDTH * (hpPercent / 100))
    bar.hpTex:SetWidth(barWidth)

    -- Get TTK from RLS
    local rawTTK = mob.rlsTTK:getTTK()
    if rawTTK and rawTTK > 0 then
        mob.smoothTTK = SmoothValue(mob.smoothTTK, rawTTK, DISPLAY_SMOOTHING)
    end

    -- Get TTE from RLS (only if above execute threshold)
    local rawTTE = mob.rlsTTE:getTTK()
    if rawTTE and rawTTE > 0 and hpPercent > execThresholdPct then
        mob.smoothTTE = SmoothValue(mob.smoothTTE, rawTTE, DISPLAY_SMOOTHING)
    end

    -- Color based on TTK warning and execute threshold
    if hpPercent <= execThresholdPct then
        bar.hpTex:SetVertexColor(0.8, 0.25, 0.25)  -- Red (in execute range)
        bar.execZone:Hide()
    elseif mob.smoothTTK and mob.smoothTTK <= WARNING_THRESHOLD then
        bar.hpTex:SetVertexColor(0.8, 0.8, 0.2)  -- Yellow (warning)
        bar.execZone:Show()
    else
        bar.hpTex:SetVertexColor(0.2, 0.8, 0.2)  -- Green
        bar.execZone:Show()
    end

    -- Update TTK display
    local displayTTK = mob.smoothTTK
    if displayTTK and displayTTK > 0 then
        bar.ttkLabel:SetText(TTK.formatTime(displayTTK))

        -- Warning color for TTK text
        if displayTTK <= WARNING_THRESHOLD then
            bar.ttkLabel:SetTextColor(1, 0.8, 0.2)  -- Yellow
        else
            bar.ttkLabel:SetTextColor(1, 1, 1)  -- White
        end

        -- Compute and show DPS
        local dps = hp / displayTTK
        if dps >= 1000 then
            bar.dpsLabel:SetText(string.format("%.1fKdps", dps / 1000))
        else
            bar.dpsLabel:SetText(string.format("%.0fdps", dps))
        end
    else
        bar.ttkLabel:SetText("")
        bar.dpsLabel:SetText("")
    end

    -- Update Execute timer (only show if above 20%)
    if hpPercent > execThresholdPct then
        local displayTTE = mob.smoothTTE
        if displayTTE and displayTTE > 0 then
            bar.execLabel:SetText(string.format("ex%s", TTK.formatTime(displayTTE)))
        else
            bar.execLabel:SetText("")
        end
    else
        bar.execLabel:SetText("")
    end

    -- Boss highlight (orange border effect via name color)
    if mob.isBoss then
        bar.nameLabel:SetTextColor(1, 0.8, 0.2)  -- Gold for bosses
    else
        bar.nameLabel:SetTextColor(1, 1, 1)  -- White for adds
    end
end

-- Reset a bar to default state
local function ResetBar(bar)
    bar.nameLabel:SetText("")
    bar.hpLabel:SetText("")
    bar.ttkLabel:SetText("")
    bar.ttkLabel:SetTextColor(1, 1, 1)
    bar.dpsLabel:SetText("")
    bar.execLabel:SetText("")
    bar.hpTex:SetWidth(BAR_WIDTH)
    bar.hpTex:SetVertexColor(0.2, 0.8, 0.2)
    bar.execZone:Show()
    bar.raidIcon:Hide()
end

-- ============================================================================
-- HEALTH EVENT PROCESSING
-- ============================================================================

-- Check if unit should be tracked (boss or tracked add)
local function ShouldTrackUnit(unitID)
    if not UnitExists(unitID) then return false, false end
    if not UnitCanAttack("player", unitID) then return false, false end
    if not UnitAffectingCombat(unitID) then return false, false end

    local unitLevel = UnitLevel(unitID)
    local unitName = UnitName(unitID)

    -- Check ignored list first
    if TTK_IGNORED_MOBS[unitName] then return false, false end

    -- Test mode: track any enemy in combat
    if testMode then
        return true, false  -- shouldTrack, treat as add
    end

    -- Boss check (proper bosses show as -1) we can add special cases for others if needed
    if unitLevel == -1 then
        return true, true  -- shouldTrack, isBoss
    end

    -- Tracked add check
    if IsTrackedAdd(unitName) then
        return true, false  -- shouldTrack, not a boss
    end

    return false, false
end

-- Add a unit to tracking with a bar
local function StartTrackingUnit(unitID)
    local shouldTrack, isBoss = ShouldTrackUnit(unitID)
    if not shouldTrack then return nil end

    -- Already tracking?
    if trackedMobs[unitID] then
        return trackedMobs[unitID]
    end

    -- Get a bar from pool
    local bar = AcquireBar()
    if not bar then return nil end  -- No bars available

    local unitName = UnitName(unitID)
    local mob = CreateMobTracker(unitID, unitName, isBoss)
    local hp = UnitHealth(unitID)
    local maxHp = UnitHealthMax(unitID)
    mob.maxHp = maxHp
    mob.lastHP = hp
    mob.bar = bar

    -- Setup bar
    bar.unitID = unitID
    bar.isBoss = isBoss
    bar.creationOrder = mob.creationOrder
    bar.nameLabel:SetText(TruncateName(unitName, 16))
    if isBoss then
        bar.nameLabel:SetTextColor(1, 0.8, 0.2)  -- Gold for bosses
    else
        bar.nameLabel:SetTextColor(1, 1, 1)  -- White for adds
    end

    -- Initial HP display
    bar.hpLabel:SetText(string.format("%s / %s", FormatHP(hp), FormatHP(maxHp)))
    local hpPercent = (hp / maxHp) * 100
    bar.hpTex:SetWidth(math.max(1, BAR_WIDTH * (hpPercent / 100)))
    if hpPercent <= EXECUTE_THRESHOLD * 100 then
        bar.hpTex:SetVertexColor(0.8, 0.25, 0.25)
        bar.execZone:Hide()
    else
        bar.hpTex:SetVertexColor(0.2, 0.8, 0.2)
        bar.execZone:Show()
    end

    -- Initial raid icon
    local raidIndex = GetRaidTargetIndex(unitID)
    if raidIndex then
        SetRaidTargetIconTexture(bar.raidIcon, raidIndex)
        bar.raidIcon:Show()
    else
        bar.raidIcon:Hide()
    end

    bar:Show()

    trackedMobs[unitID] = mob
    activeBars[unitID] = bar
    RepositionBars()

    return mob
end

-- Remove a unit from tracking
local function StopTrackingUnit(unitID)
    local mob = trackedMobs[unitID]
    if not mob then return end

    if mob.bar then
        ResetBar(mob.bar)
        ReleaseBar(mob.bar)
        activeBars[unitID] = nil
    end

    trackedMobs[unitID] = nil
    RepositionBars()
end

local function ProcessHealthEvent(unitID)
    local hp = UnitHealth(unitID)
    local maxHp = UnitHealthMax(unitID)
    local t = GetTime()

    -- Handle death
    if UnitIsDead(unitID) or hp <= 0 then
        StopTrackingUnit(unitID)
        return
    end

    -- Get or create tracker
    local mob = trackedMobs[unitID]
    if not mob then
        mob = StartTrackingUnit(unitID)
        if not mob then return end
    end

    if not mob.fightStartTime then
        mob.fightStartTime = t
    end

    -- Only process if HP changed
    if mob.lastHP == hp then return end

    local hpPercent = (hp / maxHp) * 100
    mob.lastHP = hp
    mob.lastHPPercent = hpPercent

    -- Throttle sample rate
    if (t - mob.lastSampleTime) >= SAMPLE_INTERVAL then
        mob.lastSampleTime = t

        -- Feed TTK estimator with actual HP
        mob.rlsTTK:addSample(hp, maxHp, t)

        -- Feed TTE estimator with HP relative to execute threshold
        local executeHP = maxHp * EXECUTE_THRESHOLD
        local effectiveHP = hp - executeHP
        if effectiveHP > 0 then
            mob.rlsTTE:addSample(effectiveHP, maxHp - executeHP, t)
        end
    end

    -- Update bar display
    if mob.bar then
        UpdateBarDisplay(mob, mob.bar, hp, maxHp, hpPercent)
    end
end

local function ClearAllMobs()
    for unitID, mob in pairs(trackedMobs) do
        if mob.bar then
            ResetBar(mob.bar)
            ReleaseBar(mob.bar)
        end
    end
    trackedMobs = {}
    activeBars = {}
    creationCounter = 0
    RepositionBars()
end

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

-- Update zone-specific add list
local function UpdateZoneAdds()
    local zone = GetRealZoneText()
    currentZoneAdds = TTK_ZONE_MOBS[zone]
    if currentZoneAdds then
        printo("Zone tracking active: " .. zone)
    end
end

mainFrame:SetScript("OnEvent", function()
    if event == "UNIT_HEALTH" then
        if arg1 and not (UnitAffectingCombat(arg1) and UnitCanAttack("player", arg1) and string.sub(arg1,3,3) == "F") then return end
        ProcessHealthEvent(arg1)

    elseif event == "UNIT_FLAGS" then
        if arg1 and not (UnitAffectingCombat(arg1) and UnitCanAttack("player", arg1) and string.sub(arg1,3,3) == "F") then return end
        -- Unit flags changed - if entering combat and trackable, show bar immediately
        local shouldTrack, isBoss = ShouldTrackUnit(arg1)
        if shouldTrack and not trackedMobs[arg1] then
            StartTrackingUnit(arg1)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended
        ClearAllMobs()

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        UpdateZoneAdds()
    end
end)

mainFrame:RegisterEvent("UNIT_HEALTH")
mainFrame:RegisterEvent("UNIT_FLAGS")
mainFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
mainFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
mainFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_TTK1 = "/ttk"
SlashCmdList["TTK"] = function(msg)
    local cmd = string.lower(msg or "")
    if cmd == "reset" then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        TTK_Config = TTK_Config or {}
        TTK_Config.point = "CENTER"
        TTK_Config.relPoint = "CENTER"
        TTK_Config.x = 0
        TTK_Config.y = 200
        printo("Frame position reset")
    elseif cmd == "scan" then
        ScanForTargets()
        printo("Scanning for targets...")
    elseif cmd == "lock" then
        isLocked = not isLocked
        TTK_Config = TTK_Config or {}
        TTK_Config.locked = isLocked
        mainFrame:SetMovable(not isLocked)
        if isLocked then
            mainFrame:RegisterForDrag(nil)
        else
            mainFrame:RegisterForDrag("LeftButton")
        end
        UpdateBarClickState()
        RepositionBars()
        if isLocked then
            printo("Frame locked")
        else
            printo("Frame unlocked - drag to move")
        end
    elseif cmd == "click" then
        clickToTargetEnabled = not clickToTargetEnabled
        TTK_Config = TTK_Config or {}
        TTK_Config.clickToTarget = clickToTargetEnabled
        UpdateBarClickState()
        if clickToTargetEnabled then
            printo("Click-to-target enabled")
        else
            printo("Click-to-target disabled")
        end
    elseif cmd == "test" then
        testMode = not testMode
        TTK_Config = TTK_Config or {}
        TTK_Config.testMode = testMode
        RepositionBars()  -- Update placeholder text
        if testMode then
            printo("Test mode ON - tracking any enemy in combat")
        else
            printo("Test mode OFF - tracking bosses only")
            ClearAllMobs()
        end
    else
        printo("Commands: /ttk lock | click | reset | test")
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function RestoreFramePosition()
    if TTK_Config and TTK_Config.point then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(TTK_Config.point, UIParent, TTK_Config.relPoint, TTK_Config.x, TTK_Config.y)
    end
end

local function RestoreSettings()
    if TTK_Config then
        -- Restore lock state (default: unlocked)
        if TTK_Config.locked ~= nil then
            isLocked = TTK_Config.locked
        end
        -- Restore click-to-target (default: enabled)
        if TTK_Config.clickToTarget ~= nil then
            clickToTargetEnabled = TTK_Config.clickToTarget
        end
        -- Restore test mode (default: enabled)
        if TTK_Config.testMode ~= nil then
            testMode = TTK_Config.testMode
        end
    end
    -- Apply settings
    mainFrame:SetMovable(not isLocked)
    if isLocked then
        mainFrame:RegisterForDrag(nil)
    else
        mainFrame:RegisterForDrag("LeftButton")
    end
    UpdateBarClickState()
    RepositionBars()
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("VARIABLES_LOADED")
initFrame:SetScript("OnEvent", function()
    RestoreFramePosition()
    RestoreSettings()
    UpdateZoneAdds()
    printo("TimeToKill loaded. /ttk for commands.")
end)
