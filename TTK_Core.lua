-- TTK_Core.lua - Shared utilities and base functionality for TTK estimators

TTK = TTK or {}
TTK.estimators = {}

-- Debug printing
function TTK.print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TTK]|r " .. tostring(msg))
end

-- Format time as mm:ss or ss.d
function TTK.formatTime(seconds)
    if not seconds or seconds < 0 then return "N/A" end
    if seconds > 3600 then return ">1hr" end
    if seconds > 60 then
        local mins = math.floor(seconds / 60)
        local secs = math.floor(math.mod(seconds, 60))
        return string.format("%d:%02d", mins, secs)
    end
    return string.format("%.1fs", seconds)
end

-- Format DPS with K/M suffixes
function TTK.formatDPS(dps)
    if not dps or dps <= 0 then return "0" end
    if dps >= 1000000 then
        return string.format("%.2fM", dps / 1000000)
    elseif dps >= 1000 then
        return string.format("%.1fK", dps / 1000)
    end
    return string.format("%.0f", dps)
end

-- Register an estimator
function TTK.registerEstimator(name, estimator)
    TTK.estimators[name] = estimator
    TTK.print("Registered estimator: " .. name)
end

-- Base estimator interface (for documentation)
--[[
Estimator interface:
    :init()                    - Reset/initialize the estimator
    :addSample(hp, maxHp, t)   - Add a new HP sample at time t
    :getDPS()                  - Get current estimated DPS
    :getTTK()                  - Get estimated time to kill
    :getName()                 - Get estimator name
    :getConfidence()           - Optional: confidence in estimate (0-1)
]]
