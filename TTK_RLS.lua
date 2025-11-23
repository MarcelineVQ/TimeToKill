-- TTK_RLS.lua - Recursive Least Squares with Forgetting Factor
-- O(1) updates, adapts to changing DPS rates
-- Forgetting factor controls how quickly old data is discounted

local RLS = {}
RLS.name = "RLS"
RLS.fullName = "RLS Forgetting"

-- Configuration
RLS.lambda = 0.95           -- Forgetting factor (0.9-0.99 typical)
RLS.lambdaFast = 0.85       -- Faster adaptation after detected change
RLS.initialP = 1000000      -- Initial covariance (large = uncertain)
RLS.minSamples = 3
RLS.changeThreshold = 3.0   -- Std devs for change detection

-- State
RLS.theta = 0               -- DPS estimate
RLS.P = 1000000             -- Covariance (uncertainty)
RLS.lastHP = nil
RLS.lastTime = nil
RLS.sampleCount = 0
RLS.currentLambda = 0.95    -- Current forgetting factor
RLS.residualMA = 0          -- Moving average of residuals
RLS.residualVar = 1000      -- Variance of residuals
RLS.adaptCountdown = 0      -- Countdown for fast adaptation mode

function RLS:init()
    self.theta = 0
    self.P = self.initialP
    self.lastHP = nil
    self.lastTime = nil
    self.sampleCount = 0
    self.currentLambda = self.lambda
    self.residualMA = 0
    self.residualVar = 1000
    self.adaptCountdown = 0
end

function RLS:addSample(hp, maxHp, t)
    self.sampleCount = self.sampleCount + 1

    if not self.lastHP or not self.lastTime then
        self.lastHP = hp
        self.lastTime = t
        return
    end

    local dt = t - self.lastTime
    if dt < 0.01 then return end  -- Skip tiny intervals

    -- Compute observed DPS for this interval
    local dhp = self.lastHP - hp  -- Positive when HP decreasing
    local observedDPS = dhp / dt

    -- Skip if no damage (potential intermission)
    -- But allow small healing/regen through
    if dhp < -100 then  -- Significant healing, skip
        self.lastHP = hp
        self.lastTime = t
        return
    end

    -- Change detection: large residual indicates regime change
    local residual = observedDPS - self.theta
    local stdResidual = math.abs(residual) / math.sqrt(math.max(1, self.residualVar))

    if stdResidual > self.changeThreshold and self.sampleCount > 5 then
        -- Detected significant change - increase adaptation
        self.adaptCountdown = 10
        self.P = self.P * 10  -- Increase uncertainty
    end

    -- Use faster lambda during adaptation period
    local effectiveLambda = self.currentLambda
    if self.adaptCountdown > 0 then
        effectiveLambda = self.lambdaFast
        self.adaptCountdown = self.adaptCountdown - 1
    end

    -- RLS update equations
    local K = self.P / (effectiveLambda + self.P)
    self.theta = self.theta + K * residual
    self.P = (1 / effectiveLambda) * (self.P - K * self.P)

    -- Prevent numerical issues
    if self.P > self.initialP then self.P = self.initialP end
    if self.P < 0.001 then self.P = 0.001 end

    -- Update residual statistics (for change detection)
    local alpha = 0.1
    self.residualMA = (1 - alpha) * self.residualMA + alpha * residual
    self.residualVar = (1 - alpha) * self.residualVar + alpha * residual * residual

    -- Ensure DPS stays non-negative for TTK calculation
    if self.theta < 0 then self.theta = 0 end

    self.lastHP = hp
    self.lastTime = t
end

function RLS:getDPS()
    if self.sampleCount < self.minSamples then return 0 end
    return math.max(0, self.theta)
end

function RLS:getTTK()
    if self.sampleCount < self.minSamples then return -1 end
    if not self.lastHP then return -1 end

    local dps = self:getDPS()
    if dps <= 0 then return -1 end

    return self.lastHP / dps
end

function RLS:getName()
    return self.name
end

function RLS:getFullName()
    return self.fullName
end

function RLS:getConfidence()
    if self.sampleCount < self.minSamples then return 0 end

    -- Confidence based on covariance (lower = more confident)
    local dps = math.max(1, self.theta)
    local cv = math.sqrt(self.P) / dps  -- Coefficient of variation

    -- Also factor in adaptation state
    local adaptPenalty = self.adaptCountdown > 0 and 0.3 or 0

    local conf = 1 / (1 + cv) - adaptPenalty
    return math.max(0, math.min(1, conf))
end

function RLS:getDebugInfo()
    return string.format("DPS=%.1f P=%.0f lam=%.2f adapt=%d",
        self.theta, self.P, self.currentLambda, self.adaptCountdown)
end

-- Configuration functions
function RLS:setForgettingFactor(lambda)
    self.lambda = math.max(0.8, math.min(0.99, lambda))
    self.currentLambda = self.lambda
end

-- Register with TTK system
TTK.registerEstimator("RLS", RLS)
