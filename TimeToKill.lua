-- TimeToKill.lua - Compact TTK display with dual RLS tracking
-- Shows HP bar with TTK, time to execute (20%), and 35s warning

local EXECUTE_THRESHOLD = 0.20  -- 20% HP
local WARNING_THRESHOLD = 40    -- Seconds

local function printo(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TTK]|r " .. tostring(msg))
end

-- ============================================================================
-- MAIN FRAME SETUP - Minimal HP Bar Design
-- ============================================================================

local mainFrame = CreateFrame("Frame", "TTKMainFrame", UIParent)
mainFrame:SetWidth(250)
mainFrame:SetHeight(38)
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
-- registering after, might mitigate the weird 1.12 client frame crashes, might not
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")

-- Background with border (border changes color for warning)
mainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
mainFrame:SetBackdropColor(0, 0, 0, 0.9)
mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

-- Target name (top left)
local targetName = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
targetName:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 8, -6)
targetName:SetText("No Target")
targetName:SetTextColor(1, 1, 1)

-- DPS text (center of bar - fixed position)
local dpsLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
dpsLabel:SetPoint("TOP", mainFrame, "TOP", 0, -6)
dpsLabel:SetText("")
dpsLabel:SetTextColor(1, 1, 1)

-- HP display (top right) - current / max
local hpLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hpLabel:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -8, -6)
hpLabel:SetText("--")
hpLabel:SetTextColor(1, 1, 1)

-- Bar dimensions
local BAR_WIDTH = 234
local BAR_HEIGHT = 14
local EXEC_WIDTH = BAR_WIDTH * EXECUTE_THRESHOLD  -- 20% of bar

-- Container frame for the HP bar components
local barFrame = CreateFrame("Frame", nil, mainFrame)
barFrame:SetWidth(BAR_WIDTH)
barFrame:SetHeight(BAR_HEIGHT)
barFrame:SetPoint("TOP", mainFrame, "TOP", 0, -18)

-- Background (dark, always full width)
local hpBarBg = barFrame:CreateTexture(nil, "BACKGROUND")
hpBarBg:SetAllPoints()
hpBarBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
hpBarBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)

-- Main HP texture - anchored RIGHT, shrinks toward the right
local hpTex = barFrame:CreateTexture(nil, "ARTWORK")
hpTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
hpTex:SetVertexColor(0.2, 0.8, 0.2)
hpTex:SetHeight(BAR_HEIGHT)
hpTex:SetPoint("RIGHT", barFrame, "RIGHT", 0, 0)
hpTex:SetWidth(BAR_WIDTH)

-- Execute zone (solid red bar on the right, 20% of total width) - visual indicator only
local execZone = barFrame:CreateTexture(nil, "ARTWORK")
execZone:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
execZone:SetVertexColor(0.8, 0.25, 0.25)
execZone:SetHeight(BAR_HEIGHT)
execZone:SetPoint("RIGHT", barFrame, "RIGHT", 0, 0)
execZone:SetWidth(EXEC_WIDTH)

-- TTK text (left side of bar)
local ttkBarLabel = barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
ttkBarLabel:SetPoint("LEFT", barFrame, "LEFT", 4, 0)
ttkBarLabel:SetText("--")
ttkBarLabel:SetTextColor(1, 1, 1)

-- Time to Execute text (right side, in exec zone)
local execLabel = barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
execLabel:SetPoint("RIGHT", barFrame, "RIGHT", -4, 0)
execLabel:SetText("")
execLabel:SetTextColor(1, 0.9, 0.9)

-- ============================================================================
-- TRACKING STATE
-- ============================================================================

local trackedMobs = {}
local currentTargetGUID = nil
local bossInCombat = false

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

-- Create mob tracker with dual RLS (TTK and TTE)
local function CreateMobTracker(guid, name)
    local mob = {
        guid = guid,
        name = name,
        maxHp = 0,
        lastHP = nil,
        lastHPPercent = 100,
        lastSampleTime = 0,
        fightStartTime = nil,
        -- Dual RLS estimators
        rlsTTK = CloneEstimator(TTK.estimators.RLS),  -- Time to Kill (HP -> 0)
        rlsTTE = CloneEstimator(TTK.estimators.RLS),  -- Time to Execute (HP -> 20%)
        -- Smoothed display values
        smoothTTK = nil,
        smoothTTE = nil
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

local function UpdateDisplay(mob, hp, maxHp, hpPercent)
    local execThresholdPct = EXECUTE_THRESHOLD * 100  -- 20

    -- Update HP display (top right) - current / max
    hpLabel:SetText(string.format("%s / %s", FormatHP(hp), FormatHP(maxHp)))

    -- Update bar width - simple linear scaling from 0-100%
    local barWidth = math.max(1, BAR_WIDTH * (hpPercent / 100))
    hpTex:SetWidth(barWidth)

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
        hpTex:SetVertexColor(0.8, 0.25, 0.25)  -- Red (in execute range)
        execZone:Hide()
    elseif mob.smoothTTK and mob.smoothTTK <= WARNING_THRESHOLD then
        hpTex:SetVertexColor(0.8, 0.8, 0.2)  -- Yellow (35s warning)
        execZone:Show()
    else
        hpTex:SetVertexColor(0.2, 0.8, 0.2)  -- Green
        execZone:Show()
    end

    -- Update TTK display (left side of bar)
    local displayTTK = mob.smoothTTK
    if displayTTK and displayTTK > 0 then
        ttkBarLabel:SetText(TTK.formatTime(displayTTK))

        -- 35-second warning: change border and text color
        if displayTTK <= WARNING_THRESHOLD then
            ttkBarLabel:SetTextColor(1, 0.8, 0.2)  -- Yellow text
            mainFrame:SetBackdropBorderColor(1, 0.6, 0.2, 1)  -- Orange border
        else
            ttkBarLabel:SetTextColor(1, 1, 1)  -- White text
            mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)  -- Normal border
        end

        -- Compute and show DPS (center of bar)
        local dps = hp / displayTTK
        if dps >= 1000 then
            dpsLabel:SetText(string.format("%.1fKdps", dps / 1000))
        else
            dpsLabel:SetText(string.format("%.0fdps", dps))
        end
    else
        ttkBarLabel:SetText("--")
        dpsLabel:SetText("")
        mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    -- Update Execute timer (only show if above 20%)
    if hpPercent > execThresholdPct then
        local displayTTE = mob.smoothTTE
        if displayTTE and displayTTE > 0 then
            execLabel:SetText(string.format("ex%s", TTK.formatTime(displayTTE)))
        else
            execLabel:SetText("")
        end
    else
        execLabel:SetText("")
    end
end

local function ResetDisplay()
    hpLabel:SetText("--")
    ttkBarLabel:SetText("--")
    ttkBarLabel:SetTextColor(1, 1, 1)
    dpsLabel:SetText("")
    execLabel:SetText("")
    -- Reset bar to full width and green
    hpTex:SetWidth(BAR_WIDTH)
    hpTex:SetVertexColor(0.2, 0.8, 0.2)
    execZone:Show()
    targetName:SetText("No Target")
    mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
end

-- ============================================================================
-- HEALTH EVENT PROCESSING
-- ============================================================================

local function ProcessHealthEvent(unitID)
    if not (UnitAffectingCombat(unitID) and UnitIsEnemy(unitID,"player") and string.sub(unitID,3,3) == "F") then return end

    local hp = UnitHealth(unitID)
    local maxHp = UnitHealthMax(unitID)
    local t = GetTime()
    local unitName = UnitName(unitID)

    -- Check for boss
    local unitLevel = UnitLevel(unitID)
    if unitLevel == 63 or unitLevel == -1 then
        bossInCombat = true
    end

    -- Handle death
    if UnitIsDead(unitID) then
        trackedMobs[unitID] = nil
        return
    end

    -- Get or create tracker
    local mob = trackedMobs[unitID]
    if not mob then
        mob = CreateMobTracker(unitID, unitName)
        mob.maxHp = maxHp
        trackedMobs[unitID] = mob
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
        -- effectiveHP = currentHP - executeHP, so TTE predicts when this reaches 0
        local executeHP = maxHp * EXECUTE_THRESHOLD
        local effectiveHP = hp - executeHP
        if effectiveHP > 0 then
            mob.rlsTTE:addSample(effectiveHP, maxHp - executeHP, t)
        end
    end

    -- Update display if this is current target
    if unitID == currentTargetGUID then
        UpdateDisplay(mob, hp, maxHp, hpPercent)
    end
end

local function ClearAllMobs()
    trackedMobs = {}
    currentTargetGUID = nil
    bossInCombat = false
    ResetDisplay()
end

local function RefreshTargetDisplay()
    local exists, guid = UnitExists("target")
    if exists and guid and trackedMobs[guid] then
        local mob = trackedMobs[guid]
        local hp = UnitHealth("target")
        local maxHp = UnitHealthMax("target")
        local hpPercent = (hp / maxHp) * 100
        UpdateDisplay(mob, hp, maxHp, hpPercent)
    end
end

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

mainFrame:SetScript("OnEvent", function()
    if event == "PLAYER_TARGET_CHANGED" then
        local exists, guid = UnitExists("target")
        if exists and guid and not UnitIsFriend("player", "target") then
            currentTargetGUID = guid
            targetName:SetText(UnitName("target"))
            RefreshTargetDisplay()
        else
            currentTargetGUID = nil
            targetName:SetText("No Target")
        end

    elseif event == "UNIT_HEALTH" then
        ProcessHealthEvent(arg1)

    elseif event == "PLAYER_REGEN_ENABLED" then
        ClearAllMobs()
    end
end)

mainFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
mainFrame:RegisterEvent("UNIT_HEALTH")
mainFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_TTK1 = "/ttk"
SlashCmdList["TTK"] = function(msg)
    local cmd = string.lower(msg or "")
    if cmd == "show" then
        mainFrame:Show()
        printo("Frame shown")
    elseif cmd == "hide" then
        mainFrame:Hide()
        printo("Frame hidden")
    elseif cmd == "reset" then
        ClearAllMobs()
        printo("Tracking reset")
    else
        printo("Commands: /ttk show | hide | reset")
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

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("VARIABLES_LOADED")
initFrame:SetScript("OnEvent", function()
    RestoreFramePosition()
    printo("TimeToKill loaded. /ttk for commands.")
end)
