-- Honor Bar
-- Version: 1.4.3
-- Classic Era 11505

local addonName = ...

local function HB_DeepCopyTable(src, seen)
  if type(src) ~= "table" then return src end
  seen = seen or {}
  if seen[src] then return seen[src] end
  local dst = {}
  seen[src] = dst
  for k, v in pairs(src) do
    dst[HB_DeepCopyTable(k, seen)] = HB_DeepCopyTable(v, seen)
  end
  return dst
end

HonorBarDB = (type(HonorBarDB) == "table") and HonorBarDB or {}

-- replyEnabled defaults to ON unless checked
HonorBarDB.replyEnabled = (HonorBarDB.replyEnabled ~= false)

local function HB_Print(...)
  print("|cff00aaffHonor Bar|r:", ...)
end

local function HB_Clamp(v, lo, hi, default)
  v = tonumber(v)
  if v == nil then v = default end
  if v == nil then v = lo end
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end

local function HB_Round1(v)
  return math.floor((v or 0) * 10 + 0.5) / 10
end

local function HB_GetRefreshInterval()
  local v = (HonorBarDB and HonorBarDB.statsRefresh) or 1.0
  v = HB_Clamp(v, 0.2, 2.0, 1.0)
  return HB_Round1(v)
end

function HB_PrintMemory()
  if not UpdateAddOnMemoryUsage or not GetAddOnMemoryUsage then
    HB_Print("Memory API not available")
    return
  end
  UpdateAddOnMemoryUsage()
  local name = addonName or "HonorBar"
  local kb = GetAddOnMemoryUsage(name)
  if type(kb) == "number" then
    HB_Print(string.format("Memory: %.1f KB", kb))
  else
    HB_Print("Memory: unknown (addon not found)")
  end
end

-- Per char helper name and realm
local function HB_GetCharKey()
  if not UnitName then return nil end
  local name, realm = UnitName("player")
  if not name or name == "" then return nil end
  if not realm or realm == "" then
    if GetRealmName then
      realm = GetRealmName()
    else
      realm = ""
    end
  end
  if realm ~= "" then
    return name .. "-" .. realm
  else
    return name
  end
end

-- Defaults
local function ApplyDefaults()
  if HonorBarDB and HonorBarDB.barLabels == nil and HonorBarDB.customMilestonesShowLabels ~= nil then
    HonorBarDB.barLabels = (HonorBarDB.customMilestonesShowLabels ~= false)
  end
  -- Defaults
  local defaultsNil = {
    honorCap = 500000,
    autoOn = true,

    -- Audio & layering
    soundEnabled = true,
    sendBack = false,

    -- Ticks & milestones
    showTicks = true,
    tickOpacity = 0.25,
    statsRefresh = 1.0,
    tickWidth = 1,
    hideTicks = false,
    tickCount = 19,
    milestoneLabelsBottom = false,

    -- Visibility & text
    hiddenBar = false,
    visible = true,
    hideBarText = false,
    onlyNumbers = false,
    showText = true,

    -- Stats/session
    detachStats = false,
    currentGameHonor = 0,
    currentGameHK = 0,
    currentGameKB = 0,
    lastGameHonor = 0,
    lastGameHK = 0,
    lastGameKB = 0,
    currentGameTime = 0,
    lastGameTime = 0,

    -- Auto cap
    autoCapFromRank = true,

    -- Layout
    width = 500,
    height = 22,

    -- Custom milestones
    customMilestonesEnabled = false,
    customMilestonesText = "",
    customMilestonesShowLabels = true,
    barLabels = true,

    -- Pace to cap
    showGoalPace = true,
}

  for k, v in pairs(defaultsNil) do
    if HonorBarDB[k] == nil then
      HonorBarDB[k] = v
    end
  end

  -- Custom label
  HonorBarDB.customMilestonesShowLabels = (HonorBarDB.barLabels ~= false)

  -- Stats line visibility defaults
  local statsLineDefaults = {
    header     = true,
    time       = true,
    honor      = true,
    hph        = true,
    weekly     = true,
    remaining  = true,
    milestones = true,
    hks        = true,
    eta        = true,
    marks      = true,
    currentgame= true,
    lastgame   = true,
  }
  if type(HonorBarDB.statsLinesShown) ~= "table" then
    HonorBarDB.statsLinesShown = {}
  end
  for k, v in pairs(statsLineDefaults) do
    if HonorBarDB.statsLinesShown[k] == nil then
      HonorBarDB.statsLinesShown[k] = v
    end
  end


  -- Stats title
  HonorBarDB.statsLinesShown.header = true
  local defaultsNot = {
    barColor = { r = 0.15, g = 0.55, b = 0.95, a = 1 },
    barBgColor = { r = 0, g = 0, b = 0, a = 0.45 },
    tickRGB = { r = 1, g = 1, b = 1 },
    milestoneRGB = { r = 1, g = 0.82, b = 0 },
  }

  for k, v in pairs(defaultsNot) do
    if not HonorBarDB[k] then
      HonorBarDB[k] = HB_DeepCopyTable(v)
    end
  end

  -- Defaulted fields
  if HonorBarDB.milestoneOpacity == nil then
    HonorBarDB.milestoneOpacity = HonorBarDB.tickOpacity or 0.25
  end
  if HonorBarDB.finalCongratsByChar == nil then
    HonorBarDB.finalCongratsByChar = {}
  end

  -- Goal
  HonorBarDB.weeklyGoalUseCap = nil
  HonorBarDB.weeklyGoal = nil
end
ApplyDefaults()

local honorCap = HonorBarDB.honorCap
local autoOn   = HonorBarDB.autoOn
local congratsRankChecksRemaining = 5
local barColor = HonorBarDB.barColor

-- Automatic honor cap & rank milestones

local tinsert = table.insert

local HB_lookupData = { defaults = {
  useCurrentHonorWhenModeling = true,
  allowDecayPreventionHop     = true,
  rankObjective               = 14,
  rankLimit                   = 500000,
  rankObjectiveScenario       = 14,
  rankLimitScenario           = 500000,
},
 rankChangeFactor = { 1, 1, 1, 0.8, 0.8, 0.8, 0.7, 0.7, 0.6, 0.5, 0.5, 0.4, 0.4, 0.34, 0.34 }, contributionPointsFloor = { 0, 2000, 5000, 10000, 15000, 20000, 25000, 30000, 35000, 40000, 45000, 50000, 55000, 60000 }, contributionPointsCeiling = { 2000, 5000, 10000, 15000, 20000, 25000, 30000, 35000, 40000, 45000, 50000, 55000, 60000, 65000 }, honorToContributionPointsRatio = { 45000 / 20000, 45000 / 20000, 45000 / 20000, 45000 / 20000, 45000 / 20000, 45000 / 20000, (175000 - 45000) / (40000 - 20000), (175000 - 45000) / (40000 - 20000), (175000 - 45000) / (40000 - 20000), (175000 - 45000) / (40000 - 20000), (500000 - 175000) / (60000 - 40000), (500000 - 175000) / (60000 - 40000), (500000 - 175000) / (60000 - 40000), (500000 - 175000) / (60000 - 40000) }, honorIncrements = { 0, 4500, 11250, 22500, 33750, 45000, 77500, 110000, 142500, 175000, 256250, 337500, 418750, 500000 }, contributionPointsVariances = {
  ["3_4"] = { min = 10, max = 10 },
  ["4_3"] = { min = 10 },
  ["5_2"] = { min = 10 },
  ["6_1"] = { min = 10, max = 10 },
  ["6_2"] = { min = 10, max = 0 },
  ["6_3"] = { min = 10, max = 0 },
  ["6_4"] = { min = 10, max = 0 },
  ["7_1"] = { min = 10, max = 10 },
  ["7_2"] = { min = 10, max = 10 },
  ["7_3"] = { min = 10, max = 10 },
  ["7_4"] = { min = 10, max = 0 },
  ["8_3"] = { min = 10, max = 10 },
  ["9_2"] = { min = 10, max = 10 },
  ["10_1"] = { min = 10, max = 10 },
  ["10_2"] = { min = 10, max = 0 },
  ["10_3"] = { min = 10, max = 0 },
  ["10_4"] = { min = 14, max = 6 },
  ["11_1"] = { min = 10, max = 10 },
  ["11_2"] = { min = 10, max = 10 },
  ["11_3"] = { min = 4, max = 16 },
  ["12_2"] = { min = 14, max = 6 },
  ["13_1"] = { min = 14, max = 6 },
}, contributionPointsVariancesException = {
  ["10_4"] = { min = 4 },
  ["11_3"] = { min = 14 },
}, contributionPointsVariancesReplace = {
  ["8_3"] = { max = 10, progressFloor = 0.29800, progressCeil = 0.29899 },
  ["10_1"] = { max = 10, progressFloor = 0.49795, progressCeil = 0.49805 },
  ["11_1"] = { max = 10, progressFloor = 0.49795, progressCeil = 0.49805 },
  ["11_2"] = { max = 10, progressFloor = 0.49795, progressCeil = 0.49805 },
}, }

local maxObtainableRank = 14
local maxObtainableRankScenario = maxObtainableRank
local rankObjective = HB_lookupData.defaults.rankObjective or 14
local rankLimit = HB_lookupData.defaults.rankLimit or 500000
local rankObjectiveScenario = HB_lookupData.defaults.rankObjectiveScenario or rankObjective
local rankLimitScenario = HB_lookupData.defaults.rankLimitScenario or rankLimit
local whatIfScenario = false

local HB_Rank = {}

function HB_Rank:OutputToChat(message, debug)
  if debug == true then
    message = message or ""
    print("|cffe6cc80Rank|r: " .. message)
  end
end

function HB_Rank:CalculateContributionPoints(rank, rankProgress)
  if rank <= 1 then return 0 end
  local contributionPointsFloor = HB_lookupData.contributionPointsFloor
  local contributionPointsCeiling = HB_lookupData.contributionPointsCeiling
  return ((contributionPointsCeiling[rank] - contributionPointsFloor[rank]) * (rankProgress or 1)) + contributionPointsFloor[rank]
end

function HB_Rank:CalculatePredictedRank(inputRank, inputCP)
  local l_maxObtainableRank = maxObtainableRank
  if whatIfScenario then
    l_maxObtainableRank = rankObjectiveScenario
  end
  if inputRank == nil then return end
  local contributionPointsFloor = HB_lookupData.contributionPointsFloor
  local contributionPointsCeiling = HB_lookupData.contributionPointsCeiling
  local rank, rankProgress
  for key = 1, #contributionPointsCeiling do
    if inputCP >= contributionPointsFloor[key] and key <= inputRank then
      rank = key
      rankProgress = ((inputCP - contributionPointsFloor[key]) / (contributionPointsCeiling[key] - contributionPointsFloor[key]))
      if key >= l_maxObtainableRank then
        rank = l_maxObtainableRank
        rankProgress = 0
      end
    else
      return rank, rankProgress
    end
  end
  return rank, rankProgress
end

function HB_Rank:CalculateMaxHonorNeeded(rank, honor)
  if rank == nil then return end
  if rank == 0 then rank = 1 end
  local contributionPointsFloor = HB_lookupData.contributionPointsFloor
  local contributionPointsCeiling = HB_lookupData.contributionPointsCeiling
  local honorToContributionPointsRatio = HB_lookupData.honorToContributionPointsRatio
  local maxRequiredCP
  local maxNeededHonor
  for key = 1, #contributionPointsCeiling do
    if key <= rank then
      maxRequiredCP = contributionPointsFloor[key]
    end
  end
  if rank <= 6 then
    maxNeededHonor = contributionPointsFloor[rank] * honorToContributionPointsRatio[rank]
  elseif rank <= 10 then
    maxNeededHonor = 45000 + (contributionPointsFloor[rank] - 20000) * honorToContributionPointsRatio[rank]
  else
    maxNeededHonor = 175000 + (contributionPointsFloor[rank] - 40000) * honorToContributionPointsRatio[rank]
  end
  return maxRequiredCP, maxNeededHonor, maxNeededHonor - (honor or 0)
end

function HB_Rank:CalculateCPGain(rank, objectiveRank, predictedCP, currentCP)
  if objectiveRank == nil then return end
  if rank == 0 then rank = 1 end
  local contributionPointsFloor = HB_lookupData.contributionPointsFloor
  local rankChangeFactor = HB_lookupData.rankChangeFactor
  local objectiveCP, newCP, gainedCP, bonusCP, gainedCPwithCeiling, buckets = 0, 0, 0, 0, 0, 0
  for key = rank + 1, objectiveRank do
    buckets = objectiveRank - rank
    if key ~= 1 then
      -- Each step between rank floors is a "bucket"; bucket CP = bucket span * rankChangeFactor.
      gainedCP = ((contributionPointsFloor[key] - contributionPointsFloor[key - 1]) * rankChangeFactor[key])
    end
    if key == rank + 1 then
      -- Some ranks use fixed first bucket awards
      if rank == 9 then
        gainedCP = 3000
      elseif rank == 11 then
        gainedCP = 2500
      end
      -- First bucket award is capped by remaining room in the current rank band (high progress => smaller first bucket).
      gainedCPwithCeiling = ((contributionPointsFloor[key] - contributionPointsFloor[key - 1]) * (1 - ((currentCP - contributionPointsFloor[key - 1]) / (contributionPointsFloor[key] - contributionPointsFloor[key - 1]))))
      if gainedCPwithCeiling < gainedCP then gainedCP = gainedCPwithCeiling end
      -- Certain multi-rank hop patterns add a small bonus CP
      if (rank == 6 and buckets == 4) or
          (rank == 7 and buckets >= 3) or
          (rank == 8 and (buckets == 2 or buckets == 3)) or
          (rank == 9 and buckets >= 3) or
          (rank == 10 and buckets >= 2) then
        bonusCP = 500
      elseif rank == 8 and buckets == 4 then
        bonusCP = 1000
      end
    end
    objectiveCP = objectiveCP + gainedCP
  end
  if objectiveCP == 0 then
    objectiveCP = predictedCP
    newCP = predictedCP
  else
    newCP = currentCP + objectiveCP
  end
  return objectiveCP, newCP, bonusCP
end

function HB_Rank:RankVariance(rank, honor, progress)
  local l_maxObtainableRank = maxObtainableRank
  local l_rankLimit = rankLimit
  local l_rankObjective = rankObjective
  if whatIfScenario then
    l_maxObtainableRank = rankObjectiveScenario
    l_rankLimit = rankLimitScenario
    l_rankObjective = rankObjectiveScenario
  end
  HB_Rank:OutputToChat("RankVariance: rank " .. rank .. " and " .. progress .. " (" .. honor .. ")", debug)
  local currentCP = HB_Rank:CalculateContributionPoints(rank, ceil(progress * 1000) / 1000)
  local currentRank = rank
  local situations = { "0", "+1", "+2", "+3", "+4" }
  local options = {}
  local situation, CP, honorNeed, honorRemains, totalNewCP, bonusCP, predictedNewRank, predictedNewProgress
  for num = 1, 5 do
    if rank + num - 1 <= min(l_maxObtainableRank + 4, 14) then
      situation = situations[num]
      CP, honorNeed, honorRemains = HB_Rank:CalculateMaxHonorNeeded(rank + num - 1, honor)
      _, totalNewCP, bonusCP = HB_Rank:CalculateCPGain(rank, rank + num - 1, CP, currentCP)
      totalNewCP = totalNewCP + bonusCP
      predictedNewRank, predictedNewProgress = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP)
      if (predictedNewRank <= l_rankObjective and (honorNeed <= l_rankLimit)) or (honor >= honorNeed) and (honorNeed <= honor or honorNeed <= l_rankLimit) then
        if num == 1 and rank + num <= l_rankObjective then
          CP = HB_Rank:CalculateMaxHonorNeeded(rank + num, honorNeed)
          _, totalNewCP = HB_Rank:CalculateCPGain(rank, rank + num, CP, currentCP)
          predictedNewRank, predictedNewProgress = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP)
          situation = "!!"
        end
        local lookup, lookupTable, varianceType, predictedNewRankMin, predictedNewProgressMin, predictedNewRankMax, predictedNewProgressMax
        local varianceMin, varianceMax = 0, 0
        if situation == "!!" then lookup = rank .. "_1" else lookup = rank .. "_" .. (situation * 1) end
        if HB_lookupData.contributionPointsVariances[lookup] then
          lookupTable = HB_lookupData.contributionPointsVariances[lookup]
          varianceType = "Regular"
        end
        if HB_lookupData.contributionPointsVariancesException[lookup] and progress >= 0.50 then
          lookupTable = HB_lookupData.contributionPointsVariancesException[lookup]
          varianceType = "Exception"
        end
        if HB_lookupData.contributionPointsVariancesReplace[lookup] and (progress <= HB_lookupData.contributionPointsVariancesReplace[lookup].progressCeil and progress >= HB_lookupData.contributionPointsVariancesReplace[lookup].progressFloor) then
          lookupTable = HB_lookupData.contributionPointsVariancesReplace[lookup]
          varianceType = "Replace"
        end
        if lookupTable then
          varianceMin = lookupTable.min
          varianceMax = lookupTable.max
          if varianceType == "Replace" then
            if varianceMin and varianceMin ~= 0 then
              predictedNewRank, predictedNewProgress = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP - lookupTable.min)
            end
            if varianceMax and varianceMax ~= 0 then
              predictedNewRank, predictedNewProgress = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP + lookupTable.max)
            end
          else
            if varianceMin and varianceMin ~= 0 then
              predictedNewRankMin, predictedNewProgressMin = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP - varianceMin)
              if not varianceMax then predictedNewRankMax, predictedNewProgressMax = predictedNewRankMin, predictedNewProgressMin end
            end
            if varianceMax and varianceMax ~= 0 then
              predictedNewRankMax, predictedNewProgressMax = HB_Rank:CalculatePredictedRank(rank + 4, totalNewCP + varianceMax)
            end
          end
        end
        if (HB_lookupData.defaults.allowDecayPreventionHop == true or (HB_lookupData.defaults.allowDecayPreventionHop ~= true and situation ~= "!!")) and predictedNewRank <= l_maxObtainableRank then
          tinsert(options, { ["number"] = num, ["situation"] = situation, ["rank"] = predictedNewRank, ["rankProgress"] = predictedNewProgress, ["honorNeed"] = honorNeed, ["honorRemains"] = honorRemains, ["rankMin"] = predictedNewRankMin, ["rankProgressMin"] = predictedNewProgressMin, ["rankMax"] = predictedNewRankMax, ["rankProgressMax"] = predictedNewProgressMax })
          HB_Rank:OutputToChat("  RankVariance option: " .. num .. " (" .. situation .. ") need " .. honorNeed .. " honor (" .. honorRemains .. " more) for rank " .. (predictedNewRankMin or "nil") .. " and " .. (predictedNewProgressMin or "nil") .. ", or rank " .. predictedNewRank .. " and " .. predictedNewProgress .. ", or rank " .. (predictedNewRankMax or "nil") .. " and " .. (predictedNewProgressMax or "nil") .. ".", ddebug)
        end
      end
    end
  end
  return options
end

-- Milestones used by the Honor Bar visual ticks
local rankMilestones = {}

local function UpdateAutoCapFromRank()
  wipe(rankMilestones)

  -- If auto is disabled, use the manually set cap.
  if not HonorBarDB.autoCapFromRank then
    honorCap = HonorBarDB.honorCap or honorCap or 500000
    return
  end

  -- Mirror inputs (weekly honor, rank, rank prog)
  local honor = weeklyHonor or 0

  -- Ignore current weekly honor if preferred.
  if HonorBarDB.useCurrentHonorWhenModeling == false then
    honor = 0
  end

  -- Current rank progress (0.0-1.0).
  local progress = 0
  if GetPVPRankProgress then
    local ok, val = pcall(GetPVPRankProgress)
    if ok and type(val) == "number" then
      progress = math.floor(val * 10000000000) / 10000000000
    end
  end

  -- Current rank
  local rank = 0
  if UnitPVPRank and GetPVPRankInfo then
    local pvpRank = UnitPVPRank("player")
    if pvpRank then
      local _, r = GetPVPRankInfo(pvpRank)
      rank = r or 0
    end
  end

  -- If no rank yet or its a fresh character, treated as Rank 1 with 0% prog
   if rank <= 0 then
    rank     = 1
    progress = 0
  end

  -- Logic for all scenarios from current state.
  local options = HB_Rank:RankVariance(rank, honor or 0, progress or 0)
  if not options or #options == 0 then
    honorCap = HonorBarDB.honorCap or honorCap or 500000
    return
  end

  -- Milestones for ticks/tooltips, honorNeed above current honor rank at/under the objective rank skip "+1" outcomes stop after maxObtainableRank
  local dataBrokerCurrentHonor = honor or 0
  local l_rankObjective      = rankObjective or 14
  local l_maxObtainableRank    = maxObtainableRank or 14

  local filtered = {}
  local stop = false

  for key, line in ipairs(options) do
    if not stop
       and line.honorNeed
       and line.honorNeed > dataBrokerCurrentHonor
       and line.rank
       and line.rank <= l_rankObjective
       and line.situation ~= "+1"
    then
      table.insert(filtered, line)
      if line.rank == l_maxObtainableRank then
        stop = true
      end
    end
  end

  -- If nothing at or above then fall back to max honorNeed cap
  if #filtered == 0 then
    local maxHonor = 0
    for _, opt in ipairs(options) do
      if opt.honorNeed and opt.honorNeed > maxHonor then
        maxHonor = opt.honorNeed
      end
    end

    if maxHonor <= 0 then
      honorCap = HonorBarDB.honorCap or honorCap or 500000
      return
    end

    honorCap = maxHonor

    for _, opt in ipairs(options) do
      if opt.honorNeed and opt.honorNeed > 0 and opt.honorNeed <= honorCap then
        table.insert(rankMilestones, {
          rank            = opt.rank,
          honor           = opt.honorNeed,
          situation       = opt.situation,
          rankMin         = opt.rankMin,
          rankProgressMin = opt.rankProgressMin,
          rankMax         = opt.rankMax,
          rankProgressMax = opt.rankProgressMax,
          rankProgress    = opt.rankProgress,
        })
      end
    end
  else
    -- Use milestones when setting cap and ticks.
    local maxHonor = 0
    for _, line in ipairs(filtered) do
      if line.honorNeed and line.honorNeed > maxHonor then
        maxHonor = line.honorNeed
      end
    end

    if maxHonor <= 0 then
      honorCap = HonorBarDB.honorCap or honorCap or 500000
      return
    end

    honorCap = maxHonor

    for _, line in ipairs(filtered) do
      if line.honorNeed and line.honorNeed > 0 and line.honorNeed <= honorCap then
        table.insert(rankMilestones, {
          rank            = line.rank,
          honor           = line.honorNeed,
          situation       = line.situation,
          rankMin         = line.rankMin,
          rankProgressMin = line.rankProgressMin,
          rankMax         = line.rankMax,
          rankProgressMax = line.rankProgressMax,
          rankProgress    = line.rankProgress,
        })
      end
    end
  end

  -- Sort milestones by honor so ticks appear left to right in order.
  table.sort(rankMilestones, function(a, b)
    return (a.honor or 0) < (b.honor or 0)
  end)
end

-- Layering dec
local Frame
local UpdateBar
local TickOverlay
local TextOverlay

-- Frame layering, Send Back is checked
local function HB_GetBarStrata()
  if HonorBarDB and HonorBarDB.sendBack then return "BACKGROUND" end
  return "HIGH"
end

local function HB_ApplyBarStrata()
  local strata = HB_GetBarStrata()
  if Frame and Frame.SetFrameStrata then Frame:SetFrameStrata(strata) end
  if TickOverlay and TickOverlay.SetFrameStrata then TickOverlay:SetFrameStrata(strata) end
  if TextOverlay and TextOverlay.SetFrameStrata then TextOverlay:SetFrameStrata(strata) end
end
Frame = CreateFrame("Frame", "HonorBarFrame", UIParent)
Frame:SetSize(HonorBarDB.width or 300, HonorBarDB.height or 30)
if HonorBarDB and HonorBarDB.hiddenBar then Frame:Hide() end
Frame:SetFrameStrata(HB_GetBarStrata())
Frame:SetMovable(true)
Frame:EnableMouse(true)
Frame:SetClampedToScreen(true)

-- Restore saved position
if HonorBarDB.point and HonorBarDB.relativePoint and HonorBarDB.xOfs and HonorBarDB.yOfs then
  Frame:ClearAllPoints()
  Frame:SetPoint(HonorBarDB.point, UIParent, HonorBarDB.relativePoint, HonorBarDB.xOfs, HonorBarDB.yOfs)
else
  Frame:SetPoint("CENTER")
end

-- Background
local bg = Frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(true)
do
  local c = (HonorBarDB and HonorBarDB.barBgColor) or { r = 0, g = 0, b = 0, a = 0.45 }
  bg:SetColorTexture(c.r or 0, c.g or 0, c.b or 0, c.a or 0.45)
end
Frame.bg = bg

-- Status bar
local bar = CreateFrame("StatusBar", nil, Frame)
bar:SetPoint("TOPLEFT")
bar:SetPoint("BOTTOMRIGHT")
bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
bar:GetStatusBarTexture():SetHorizTile(false)
bar:SetStatusBarColor(barColor.r, barColor.g, barColor.b, barColor.a)
bar:SetFrameLevel(Frame:GetFrameLevel() + 1)

-- Tick overlay
TickOverlay = CreateFrame("Frame", nil, Frame)
TickOverlay:SetAllPoints(Frame)
TickOverlay:SetFrameStrata(HB_GetBarStrata())
TickOverlay:SetFrameLevel(Frame:GetFrameLevel() + 50)
-- Celebratory sound for milestones and weekly honor cap

-- Prevent milestone/cap sounds from firing on initial sync
local HB_SoundSessionInitialized = false

local function HB_PlaySound(path)
  if not PlaySoundFile then return end
  if not path or path == "" then return end
  if HonorBarDB and HonorBarDB.soundEnabled == false then return end
  -- Uses the Master channel
  PlaySoundFile(path, "Master")
end

-- Custom milestone
local HB_ParseMilestoneText
local HB_FormatCompact

-- Check if crossed a milestone or set cap between two honor values.
local function HB_CheckHonorSounds(oldHonor, newHonor)
  if not HonorBarDB then return end
  if type(newHonor) ~= "number" then return end

  -- If no sounds keep baseline so no bad comparison
  if HonorBarDB.soundEnabled == false then
    HonorBarDB.lastHonorForSounds = newHonor
    HB_SoundSessionInitialized = true
    return
  end

  local prev = HonorBarDB.lastHonorForSounds

  -- Start baseline on honor value this session
  if (not HB_SoundSessionInitialized) or (prev == nil) then
    HonorBarDB.lastHonorForSounds = newHonor
    HB_SoundSessionInitialized = true
    return
  end

  -- If honor did not increase since last baseline update baseline and exit.
  if newHonor <= prev then
    HonorBarDB.lastHonorForSounds = newHonor
    return
  end

  local old = prev
  local cap = honorCap or HonorBarDB.honorCap
  local milestoneSoundPath = "Interface\\AddOns\\HonorBar\\Milestone.mp3"
  local capSoundPath       = "Interface\\AddOns\\HonorBar\\WeeklyHonorCap.mp3"

  -- 1) Weekly honor cap reached: play once when crossing to/over cap.
  if cap and cap > 0 and old < cap and newHonor >= cap then
    HB_PlaySound(capSoundPath)
  end

  local playedMilestone = false

  -- 2) Milestone reached (auto cap mode only).
  if HonorBarDB.autoCapFromRank and rankMilestones and type(rankMilestones) == "table" and #rankMilestones > 0 then
    for _, m in ipairs(rankMilestones) do
      local mh = m and m.honor
      if mh and mh > 0 and old < mh and newHonor >= mh then
        HB_PlaySound(milestoneSoundPath)
        playedMilestone = true
        break -- Only play once per refresh.
      end
    end
  end

  -- 3) Custom milestone reached
  if (not playedMilestone) and HonorBarDB.customMilestonesEnabled and HB_ParseMilestoneText and HonorBarDB.customMilestonesText and HonorBarDB.customMilestonesText ~= "" then
    local list = HB_ParseMilestoneText(HonorBarDB.customMilestonesText)
    if list and type(list) == "table" and #list > 0 then
      local capLimit = cap
      if type(capLimit) ~= "number" or capLimit <= 0 then capLimit = nil end
      for _, mh in ipairs(list) do
        if mh and mh > 0 and (not capLimit or mh <= capLimit) and old < mh and newHonor >= mh then
          HB_PlaySound(milestoneSoundPath)
          break
        end
      end
    end
  end

  HonorBarDB.lastHonorForSounds = newHonor
end

-- Milestone ticks drawn on a separate layer

local milestoneTicks = {}
local customMilestoneTicks = {}

local function HB_HideTickList(list, fromIndex)
  if not list then return end
  for i = fromIndex or 1, #list do
    local t = list[i]
    if t then
      t:Hide()
      if t.label then t.label:Hide() end
    end
  end
end

local function HB_BarLabelsEnabled()
  if not HonorBarDB then return true end
  if HonorBarDB.barLabels ~= nil then
    return HonorBarDB.barLabels ~= false
  end
  return HonorBarDB.customMilestonesShowLabels ~= false
end

local function CreateOrUpdateCustomMilestoneTicks()
  if not HonorBarDB then return end

  -- Hide if ticks if off
  if HonorBarDB.hideTicks or not HonorBarDB.showTicks or not HonorBarDB.customMilestonesEnabled then
    HB_HideTickList(customMilestoneTicks)
    return
  end

  local list = HB_ParseMilestoneText(HonorBarDB.customMilestonesText)
  if not list or #list == 0 then
    HB_HideTickList(customMilestoneTicks)
    return
  end

  local w     = Frame:GetWidth() or 300
  local alpha = tonumber(HonorBarDB.milestoneOpacity or HonorBarDB.tickOpacity) or 0.25
  local width = tonumber(HonorBarDB.tickWidth) or 1
  if width < 1 then width = 1 elseif width > 3 then width = 3 end
  if alpha < 0.05 then alpha = 0.05 elseif alpha > 0.8 then alpha = 0.8 end

  local cap = (honorCap and honorCap > 0) and honorCap or (HonorBarDB.honorCap or 1)
  if cap <= 0 then cap = 1 end

  local mc = HonorBarDB.milestoneRGB or { r = 1, g = 0.82, b = 0 }

  local drawn = 0
  for _, v in ipairs(list) do
    if v and v > 0 and v <= cap then
      drawn = drawn + 1
      local t = customMilestoneTicks[drawn]
      if not t then
        t = TickOverlay:CreateTexture(nil, "OVERLAY")
        customMilestoneTicks[drawn] = t
      end

      t:ClearAllPoints()
      t:SetColorTexture(mc.r or 1, mc.g or 0.82, mc.b or 0, alpha)

      local frac = v / cap
      if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
      local x = w * frac
      if width < 1 then x = math.floor(x) + 0.5 else x = math.floor(x + 0.5) end
      t:SetPoint("TOPLEFT", Frame, "TOPLEFT", x, -2)
      t:SetPoint("BOTTOMLEFT", Frame, "BOTTOMLEFT", x, 2)
      t:SetWidth(width)
      t:Show()

      local lbl = t.label
      if HB_BarLabelsEnabled() then
        if not lbl then
          lbl = TickOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          t.label = lbl
        end
        lbl:ClearAllPoints()
        if HonorBarDB.milestoneLabelsBottom then
          lbl:SetPoint("TOP", t, "BOTTOM", 0, -2)
        else
          lbl:SetPoint("BOTTOM", t, "TOP", 0, 2)
        end
        lbl:SetText(HB_FormatCompact(v))
        lbl:Show()
      else
        if lbl then lbl:Hide() end
      end
    end
  end

  -- Hide leftover custom milestone ticks
  HB_HideTickList(customMilestoneTicks, drawn + 1)
end

local function CreateOrUpdateMilestoneTicks()
  if not HonorBarDB then return end

  -- Hide milestone ticks if ticks are hidden or not shown
  if HonorBarDB.hideTicks or not HonorBarDB.showTicks then
    HB_HideTickList(milestoneTicks)
    return
  end

  -- Only draw rank milestones in auto when there is milestone data
  if not (HonorBarDB.autoCapFromRank and rankMilestones and #rankMilestones > 0) then
    for i = 1, #milestoneTicks do
      local t = milestoneTicks[i]
      if t then
        t:Hide()
        if t.label then t.label:Hide() end
      end
    end
    return
  end

  local w     = Frame:GetWidth() or 300
  local alpha = tonumber(HonorBarDB.milestoneOpacity or HonorBarDB.tickOpacity) or 0.25
  local width = tonumber(HonorBarDB.tickWidth) or 1
  if width < 1 then width = 1 elseif width > 3 then width = 3 end
  if alpha < 0.05 then alpha = 0.05 elseif alpha > 0.8 then alpha = 0.8 end

  local cap = (honorCap and honorCap > 0) and honorCap or 1
  local showLabels = HB_BarLabelsEnabled()

  for i, m in ipairs(rankMilestones) do
    local t = milestoneTicks[i]
    if not t then
      t = TickOverlay:CreateTexture(nil, "OVERLAY")
      milestoneTicks[i] = t
    end

    t:ClearAllPoints()
    local mc = HonorBarDB.milestoneRGB or { r = 1, g = 0.82, b = 0 }

    -- Milestone ticks dedicated color

    t:SetColorTexture(mc.r or 1, mc.g or 0.82, mc.b or 0, alpha)

    local frac = (m.honor or 0) / cap
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    local x = w * frac
    if width < 1 then x = math.floor(x) + 0.5 else x = math.floor(x + 0.5) end
    t:SetPoint("TOPLEFT", Frame, "TOPLEFT", x, -2)
    t:SetPoint("BOTTOMLEFT", Frame, "BOTTOMLEFT", x, 2)
    t:SetWidth(width)
    t:Show()

    local lbl = t.label
    if showLabels then
      if not lbl then
        lbl = TickOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t.label = lbl
      end
      lbl:ClearAllPoints()
      if HonorBarDB.milestoneLabelsBottom then
        lbl:SetPoint("TOP", t, "BOTTOM", 0, -2)
      else
        lbl:SetPoint("BOTTOM", t, "TOP", 0, 2)
      end

      -- Show rank and percentage toward the next rank, "R13-68"
      local pct = m.rankProgressMax or m.rankProgressMin or m.rankProgress

      if type(pct) == "number" and pct > 0 then
        pct = math.floor(pct * 100 + 0.5)
        lbl:SetText(string.format("R%d-%d", m.rank or 0, pct))
      else
        lbl:SetText(string.format("R%d", m.rank or 0))
      end

      lbl:Show()
    else
      if lbl then lbl:Hide() end
    end
  end

  -- Hide any leftover milestone ticks
  HB_HideTickList(milestoneTicks, #rankMilestones + 1)
end

local ticks = {}

local function CreateOrUpdateTicks()
  if HonorBarDB and HonorBarDB.hideTicks then
    HB_HideTickList(ticks)
    -- Also hide milestone ticks
    CreateOrUpdateMilestoneTicks()
    CreateOrUpdateCustomMilestoneTicks()
    return
  end
  if not HonorBarDB.showTicks then
    HB_HideTickList(ticks)
    CreateOrUpdateMilestoneTicks()
    CreateOrUpdateCustomMilestoneTicks()
    return
  end

  local w = Frame:GetWidth() or 300
  local alpha = tonumber(HonorBarDB.tickOpacity) or 0.25
  local width = tonumber(HonorBarDB.tickWidth) or 1
  if width < 1 then width = 1 elseif width > 3 then width = 3 end
  if alpha < 0.05 then alpha = 0.05 elseif alpha > 0.8 then alpha = 0.8 end
  local count = tonumber(HonorBarDB.tickCount) or 19
  if count < 0 then count = 0 elseif count > 60 then count = 60 end

  for i = 1, count do
    local t = ticks[i]
    if not t then
      t = TickOverlay:CreateTexture(nil, "OVERLAY")
      ticks[i] = t
    end
    t:ClearAllPoints()
    local tc = HonorBarDB.tickRGB or { r = 1, g = 1, b = 1 }
    t:SetColorTexture(tc.r or 1, tc.g or 1, tc.b or 1, alpha)
    local x = w * (i / (count + 1))
    if width < 1 then x = math.floor(x) + 0.5 else x = math.floor(x + 0.5) end
    t:SetPoint("TOPLEFT", Frame, "TOPLEFT", x, -2)
    t:SetPoint("BOTTOMLEFT", Frame, "BOTTOMLEFT", x, 2)
    t:SetWidth(width)
    t:Show()
  end

  for i = count + 1, #ticks do
    if ticks[i] then ticks[i]:Hide() end
  end

  -- Draw milestone ticks if any
  CreateOrUpdateMilestoneTicks()
  CreateOrUpdateCustomMilestoneTicks()
end

-- Adjust Bar dialog
local HB_AdjustDlg
local function HB_SetSizeAndSave(w, h)
  w = math.max(100, math.min(1000, math.floor((w or Frame:GetWidth() or 300)+0.5)))
  h = math.max(10,  math.min(100,  math.floor((h or Frame:GetHeight() or 22)+0.5)))
  HonorBarDB.width, HonorBarDB.height = w, h
  Frame:SetSize(w, h)
  if HB_ApplyBarStrata then HB_ApplyBarStrata() end
  CreateOrUpdateTicks()
end

local function HB_UpdateTickCountLabel()
  local c = tonumber(HonorBarDB.tickCount) or 19
  if c < 1 then c = 1 end
  local pct = 100 / (c + 1)
  if HB_Adjust_TCountText then HB_Adjust_TCountText:SetText(string.format("Tick Amount: %d (%.2f%% per tick)", c, pct)) end
end

-- Configuration dialog (bar, checkboxes, sliders, colors)
local EnsureStatsFrame, UpdateStatsFrame


-- Dropdown option
local HB_UIOptions = {
  hideBar = {
    label = "Hide Bar",
    get = function() return (HonorBarDB and HonorBarDB.hiddenBar) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.hiddenBar = v and true or false; ApplyVisibility() end,
  },
  hideBarText = {
    label = "Hide Bar Text",
    get = function() return (HonorBarDB and HonorBarDB.hideBarText) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.hideBarText = v and true or false; if UpdateBar then UpdateBar() end end,
  },
  hideTicks = {
    label = "Hide Ticks",
    get = function() return (HonorBarDB and HonorBarDB.hideTicks) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.hideTicks = v and true or false; CreateOrUpdateTicks() end,
  },
  sound = {
    label = "Sound",
    get = function() return (HonorBarDB and HonorBarDB.soundEnabled ~= false) end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.soundEnabled = v and true or false end,
  },
  onlyNumbers = {
    label = "Only Numbers",
    get = function() return (HonorBarDB and HonorBarDB.onlyNumbers) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.onlyNumbers = v and true or false; if UpdateBar then UpdateBar() end end,
  },
  barLabels = {
    label = "Bar Labels",
    get = function() return (HonorBarDB and HonorBarDB.barLabels ~= false) end,
    set = function(v)
      if not HonorBarDB then return end
      HonorBarDB.barLabels = v and true or false
      HonorBarDB.customMilestonesShowLabels = HonorBarDB.barLabels
      CreateOrUpdateMilestoneTicks()
      CreateOrUpdateCustomMilestoneTicks()
    end,
  },
  labelsBottom = {
    label = "Bar Labels Bottom",
    get = function() return (HonorBarDB and HonorBarDB.milestoneLabelsBottom) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.milestoneLabelsBottom = v and true or false; CreateOrUpdateMilestoneTicks() end,
  },
  enableHonor = {
    label = "Enable !honor",
    get = function() return (HonorBarDB and HonorBarDB.replyEnabled ~= false) end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.replyEnabled = v and true or false end,
  },
  sendBack = {
    label = "Send Back",
    get = function() return (HonorBarDB and HonorBarDB.sendBack) or false end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.sendBack = v and true or false; if HB_ApplyBarStrata then HB_ApplyBarStrata() end end,
  },
  showGoalPace = {
    label = "Daily Pace",
    get = function() return (HonorBarDB and HonorBarDB.showGoalPace ~= false) end,
    set = function(v) if not HonorBarDB then return end HonorBarDB.showGoalPace = v and true or false; if UpdateStatsFrame then UpdateStatsFrame() end end,
  },
}

local HB_BAR_OPTIONS_DD_ITEMS = {
  { id = "hideBar",      label = "Hide Bar",           desc = "Hide the bar frame." },
  { id = "hideBarText",  label = "Hide Bar Text",      desc = "Hide the numbers/text on the bar." },
  { id = "hideTicks",    label = "Hide Ticks",         desc = "Hide tick marks on the bar." },
  { id = "sound",        label = "Sound",              desc = "Enable/disable milestone + weekly honor cap sounds." },
  { id = "onlyNumbers",  label = "Only Numbers",       desc = "Show compact numeric text only." },
  { id = "barLabels",    label = "Bar Labels",         desc = "Show/hide milestone labels (includes auto-cap labels)." },
  { id = "labelsBottom", label = "Bar Labels Bottom",  desc = "Place milestone labels below the bar." },
  { id = "enableHonor",  label = "Enable !honor",      desc = "Allow the addon to reply to !honor." },
  { id = "sendBack",     label = "Send Back",          desc = "Push the bar behind other UI elements." },
}

local HB_STATS_OPTIONS_DD_ITEMS = {
  { key = "time",        label = "Time",         desc = "Session time." },
  { key = "honor",       label = "Honor",        desc = "Current session honor." },
  { key = "hph",         label = "Honor / hour", desc = "Session rate." },
  { key = "weekly",      label = "Weekly Honor", desc = "Your current weekly honor." },
  { key = "remaining",   label = "Remaining",    desc = "Honor remaining to your weekly cap." },
  { key = "milestones",  label = "Milestones",   desc = "Milestone status line." },
  { key = "hks",         label = "HKs",          desc = "Honorable kills line." },
  { key = "eta",         label = "ETA",          desc = "Time estimate to cap (based on current rate)." },
  { opt = "showGoalPace",label = "Daily Pace",   desc = "Show pace-to-cap line (based on current gain rate)." },
  { key = "marks",       label = "Marks",        desc = "Battleground marks line (if applicable)." },
  { key = "currentgame", label = "Current Game", desc = "Current BG summary." },
  { key = "lastgame",    label = "Last Game",    desc = "Previous BG summary." },
}

local function HB_DD_AddToggle(level, text, checkedFn, toggleFn)
  local info = UIDropDownMenu_CreateInfo()
  info.text = text
  info.isNotRadio = true
  info.keepShownOnClick = true
  info.checked = checkedFn
  info.func = toggleFn
  UIDropDownMenu_AddButton(info, level)
end

local function HB_DD_AddOpt(level, dd, ddText, optId, labelOverride)
  local opt = HB_UIOptions and HB_UIOptions[optId]
  if not opt then return end
  HB_DD_AddToggle(level, labelOverride or opt.label,
    function() return opt.get() end,
    function()
      opt.set(not opt.get())
      UIDropDownMenu_SetText(dd, ddText)
    end)
end

local function HB_ToggleStatsLine(key)
  if not HonorBarDB then return end
  if type(HonorBarDB.statsLinesShown) ~= "table" then HonorBarDB.statsLinesShown = {} end
  if key == "header" then
    HonorBarDB.statsLinesShown.header = true
    if UpdateStatsFrame then UpdateStatsFrame() end
    return
  end
  HonorBarDB.statsLinesShown[key] = not (HonorBarDB.statsLinesShown[key] ~= false)
  if UpdateStatsFrame then UpdateStatsFrame() end
end

local function HB_StatsLineIsChecked(key)
  if not HonorBarDB or type(HonorBarDB.statsLinesShown) ~= "table" then return true end
  return (HonorBarDB.statsLinesShown[key] ~= false)
end

local function HB_OpenAdjustDialog()
  if HB_AdjustDlg and HB_AdjustDlg:IsShown() then return end
  if not HB_AdjustDlg then
    HB_AdjustDlg = CreateFrame("Frame", "HonorBarAdjustDlg", UIParent, "BackdropTemplate")
    if UISpecialFrames then table.insert(UISpecialFrames, "HonorBarAdjustDlg") end
    HB_AdjustDlg:SetSize(380, 430)
    HB_AdjustDlg:SetPoint("CENTER")
    HB_AdjustDlg:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                               edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                               tile = true, tileSize = 32, edgeSize = 32,
                               insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    HB_AdjustDlg:EnableMouse(true)
    HB_AdjustDlg:SetMovable(true)
    HB_AdjustDlg:RegisterForDrag("LeftButton")
    HB_AdjustDlg:SetScript("OnDragStart", function(self) self:StartMoving() end)
    HB_AdjustDlg:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = HB_AdjustDlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Bar Config")

    -- Detach Stats checkbox
    local detachStatsCB = CreateFrame("CheckButton", "HB_Adjust_DetachStats", HB_AdjustDlg, "UICheckButtonTemplate")
    detachStatsCB:SetSize(18, 18)
    detachStatsCB:SetScale(1.0)
    detachStatsCB:SetPoint("TOPRIGHT", title, "TOPLEFT", -12, 0)
    _G[detachStatsCB:GetName().."Text"]:SetText("Detach Stats")
    do
      local label = _G[detachStatsCB:GetName().."Text"] or detachStatsCB.Text
      if label then
        label:ClearAllPoints()
        label:SetPoint("RIGHT", detachStatsCB, "LEFT", -2, 0)
        label:SetJustifyH("RIGHT")
        if label.SetFontObject then
          label:SetFontObject(GameFontNormalSmall)
        end
      end
    end
    detachStatsCB:SetChecked(HonorBarDB.detachStats == true)
    detachStatsCB:SetScript("OnClick", function(self)
      HonorBarDB.detachStats = self:GetChecked() and true or false
      if HonorBarDB.detachStats then
        if EnsureStatsFrame then
          EnsureStatsFrame():Show()
          UpdateStatsFrame()
        end
      else
        if _G.HonorBarSessionStatsFrame then
          _G.HonorBarSessionStatsFrame:Hide()
        end
      end
    end)

    -- Help button
    local helpBtn = CreateFrame("Button", "HB_Adjust_HelpButton", HB_AdjustDlg, "UIPanelButtonTemplate")
    helpBtn:SetSize(60, 20)
    helpBtn:SetText("Help")
    helpBtn:SetPoint("LEFT", title, "RIGHT", 12, 0)
    helpBtn:SetScript("OnClick", function()
      if type(HB_ToggleHelpDialog) == "function" then
        HB_ToggleHelpDialog()
      elseif type(HB_ShowHelpPopup) == "function" then
        HB_ShowHelpPopup()
      else
        HB_Print("Type /honor config for options. Type /honor help for the help window.")
      end
    end)

        -- Create dropdown frames
	    if not HB_AdjustDlg.BarOptionsDD then
      local dd = CreateFrame("Frame", "HB_Adjust_BarOptionsDD", HB_AdjustDlg, "UIDropDownMenuTemplate")
	      dd:SetPoint("TOP", HB_AdjustDlg, "TOP", -95, -345)

      UIDropDownMenu_SetWidth(dd, 73)
      UIDropDownMenu_SetText(dd, "Bar")
      HB_AdjustDlg.BarOptionsDD = dd

            UIDropDownMenu_Initialize(dd, function(self, level)
        if level ~= 1 then return end
        for _, it in ipairs(HB_BAR_OPTIONS_DD_ITEMS) do
          HB_DD_AddOpt(level, dd, "Bar", it.id, it.label)
        end
      end)
    else
      UIDropDownMenu_SetText(HB_AdjustDlg.BarOptionsDD, "Bar")
    end

	    if not HB_AdjustDlg.StatsOptionsDD then
      local dd = CreateFrame("Frame", "HB_Adjust_StatsOptionsDD", HB_AdjustDlg, "UIDropDownMenuTemplate")
	      dd:SetPoint("TOP", HB_AdjustDlg, "TOP", 95, -345)
  
      UIDropDownMenu_SetWidth(dd, 73)
      UIDropDownMenu_SetText(dd, "Stats")
      HB_AdjustDlg.StatsOptionsDD = dd

            UIDropDownMenu_Initialize(dd, function(self, level)
        if level ~= 1 then return end
        for _, it in ipairs(HB_STATS_OPTIONS_DD_ITEMS) do
          if it.opt then
            HB_DD_AddOpt(level, dd, "Stats", it.opt, it.label)
          else
            HB_DD_AddToggle(level, it.label,
              function() return HB_StatsLineIsChecked(it.key) end,
              function() HB_ToggleStatsLine(it.key); UIDropDownMenu_SetText(dd, "Stats") end)
          end
        end
      end)
    else
      UIDropDownMenu_SetText(HB_AdjustDlg.StatsOptionsDD, "Stats")
    end

    -- Set sliders
    local function MakeSlider(name, label, minV, maxV, step, getter, setter, x, y)
      local s = CreateFrame("Slider", name, HB_AdjustDlg, "OptionsSliderTemplate")
      s:SetWidth(120); s:SetMinMaxValues(minV, maxV); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
      s:SetPoint("TOP", HB_AdjustDlg, "TOP", x, y)
      _G[name.."Low"]:SetText(tostring(minV)); _G[name.."High"]:SetText(tostring(maxV)); _G[name.."Text"]:SetText(label)
      -- Slider label
      do
        local labelFS = _G[name.."Text"]
        if labelFS and labelFS.SetFont and not labelFS._hpSmaller then
          local f, s, fl = labelFS:GetFont()
          if s and s > 4 then
            labelFS:SetFont(f, s - 2, fl)
          end
          labelFS._hpSmaller = true
        end
      end
      s:SetScript("OnValueChanged", function(self, v) setter(v); if name == "HB_Adjust_TCount" then HB_UpdateTickCountLabel() end end)
      s:SetValue(getter())
      return s
    end

    local function MakeEditBox(name, x, y, getV, setV, linkSlider)
      local e = CreateFrame("EditBox", name, HB_AdjustDlg, "InputBoxTemplate")
      e:SetSize(60, 20); e:SetAutoFocus(false); e:SetPoint("TOP", HB_AdjustDlg, "TOP", x, y); e:SetNumeric(true)
      e:SetScript("OnEnterPressed", function(self) local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end; self:ClearFocus() end)
      e:SetScript("OnEditFocusLost", function(self) local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end end)
      e:SetScript("OnTextChanged", function(self) if not self:HasFocus() then return end; local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end end)
      e:SetText(tostring(getV()))
      return e
    end

    -- Shared color picker
    local HB_CP_CurrentSetter = nil
    local HB_CP_RefreshFunc   = nil

    local function HB_ColorPicker_OnColorChanged()
      if not HB_CP_CurrentSetter then return end
      local r, g, b = ColorPickerFrame:GetColorRGB()
      local a = 1
      if ColorPickerFrame.hasOpacity and OpacitySliderFrame then
        a = 1 - (OpacitySliderFrame:GetValue() or 0)
      end
      HB_CP_CurrentSetter({ r = r or 1, g = g or 1, b = b or 1, a = a or 1 })
      if HB_CP_RefreshFunc then HB_CP_RefreshFunc() end
    end

    local function HB_ColorPicker_OnColorCanceled(prev)
      if not HB_CP_CurrentSetter or not prev then return end
      local r, g, b, a = prev[1], prev[2], prev[3], prev[4]
      HB_CP_CurrentSetter({ r = r or 1, g = g or 1, b = b or 1, a = a or 1 })
      if HB_CP_RefreshFunc then HB_CP_RefreshFunc() end
    end

    local function MakeColorSwatch(name, label, x, y, getter, setter)
      local btn = CreateFrame("Button", name, HB_AdjustDlg, "UIPanelButtonTemplate")
      btn:SetSize(80, 18)
      btn:SetPoint("TOP", HB_AdjustDlg, "TOP", x, y)
      btn:SetText(label)
      -- Hide UI Panel Button Template so only color fill shows
      local bn = btn.GetName and btn:GetName() or name
      local l = btn.Left or (bn and _G[bn.."Left"]) or nil
      local m = btn.Middle or (bn and _G[bn.."Middle"]) or nil
      local r = btn.Right or (bn and _G[bn.."Right"]) or nil
      if l and l.SetAlpha then l:SetAlpha(0) end
      if m and m.SetAlpha then m:SetAlpha(0) end
      if r and r.SetAlpha then r:SetAlpha(0) end
      local nt = btn.GetNormalTexture and btn:GetNormalTexture() or nil
      if nt and nt.SetAlpha then nt:SetAlpha(0) end
      local ht = btn.GetHighlightTexture and btn:GetHighlightTexture() or nil
      if ht and ht.SetAlpha then ht:SetAlpha(0) end
      local pt = btn.GetPushedTexture and btn:GetPushedTexture() or nil
      if pt and pt.SetAlpha then pt:SetAlpha(0) end

      local tex = btn:CreateTexture(nil, "BACKGROUND")
      tex:SetAllPoints(btn)

      local function refresh()
        local c = getter() or {}
        tex:SetColorTexture(c.r or 1, c.g or 1, c.b or 1, (c.a or 1))
      end
      refresh()

      btn:SetScript("OnClick", function(self)
        local base = getter() or {}
        -- refreshes swatch
        HB_CP_CurrentSetter = function(tbl)
          setter(tbl)
        end
        HB_CP_RefreshFunc = refresh

        CloseMenus()
        local r = base.r or 1
        local g = base.g or 1
        local b = base.b or 1
        local a = base.a or 1
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame.hasOpacity = true
        ColorPickerFrame.opacity = 1 - a
        ColorPickerFrame.previousValues = { r, g, b, a }
        -- Call swatchFunc instead of func.
        ColorPickerFrame.func        = HB_ColorPicker_OnColorChanged
        ColorPickerFrame.opacityFunc = HB_ColorPicker_OnColorChanged
        ColorPickerFrame.swatchFunc  = HB_ColorPicker_OnColorChanged
        ColorPickerFrame.cancelFunc  = HB_ColorPicker_OnColorCanceled
        ColorPickerFrame:Hide(); ColorPickerFrame:Show()
      end)

      return btn
    end

    -- Controls
    local function getW() return HonorBarDB.width or (Frame and Frame:GetWidth() or 300) end
    local function setW(v) HB_SetSizeAndSave(v, HonorBarDB.height or (Frame and Frame:GetHeight() or 22)) end
    local function getH() return HonorBarDB.height or (Frame and Frame:GetHeight() or 22) end
    local function setH(v) HB_SetSizeAndSave(HonorBarDB.width or (Frame and Frame:GetWidth() or 300), v) end

    local function getRefresh()
      return HB_GetRefreshInterval()
    end
    local function setRefresh(v)
      v = HB_Clamp(v, 0.2, 2.0, 1.0)
      HonorBarDB.statsRefresh = HB_Round1(v)
      if autoOn then
        if StopAuto then StopAuto() end
        if StartAuto then StartAuto() end
      end
    end
    local function getTW() return HonorBarDB.tickWidth or 1 end
    local function setTW(v) HonorBarDB.tickWidth = tonumber(string.format("%.1f", v or 0)); CreateOrUpdateTicks() end
    local function getTCount() return HonorBarDB.tickCount or 19 end
    local function setTCount(v) HonorBarDB.tickCount = math.floor((tonumber(v) or 0)+0.5); CreateOrUpdateTicks() end
    local function getCap() return HonorBarDB.honorCap or honorCap or 500000 end
    local function setCap(v) v = math.floor(tonumber(v) or 0); if v < 0 then v = 0 end; HonorBarDB.honorCap = v; honorCap = v; if UpdateBar then UpdateBar() end end

    local widthSlider  = MakeSlider("HB_Adjust_Width",  "Width",        100, 1000, 1, getW,  setW,  -90, -46)
    local heightSlider = MakeSlider("HB_Adjust_Height", "Height",        10,  100,  1, getH,  setH,  -90, -106)
    MakeSlider("HB_Adjust_TOp",    "Stats Refresh (s)", 0.2, 2.0, 0.2, getRefresh, setRefresh,  90, -46)
    MakeSlider("HB_Adjust_TW",     "Tick Width",     0.5,   3,  0.1, getTW, setTW,   90, -106)
    MakeSlider("HB_Adjust_TCount", "Tick Amount",     0,    60,  1,  getTCount, setTCount, 90, -166)
    HB_UpdateTickCountLabel()

    local widthBox  = MakeEditBox("HB_Adjust_WidthBox",  -90, -64,  getW, setW, widthSlider)
    local heightBox = MakeEditBox("HB_Adjust_HeightBox", -90, -124, getH, setH, heightSlider)
    local capLabel = HB_AdjustDlg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    capLabel:SetPoint("TOP", HB_AdjustDlg, "TOP", -90, -166); capLabel:SetText("Honor Cap")
    local capBox   = MakeEditBox("HB_Adjust_CapBox", -90, -184, getCap, setCap, nil); capBox:SetNumeric(true)

    -- Auto honor cap checkbox next to Honor Cap
    local autoCapCB = CreateFrame("CheckButton", "HB_Adjust_AutoCap", HB_AdjustDlg, "UICheckButtonTemplate")
    autoCapCB:SetSize(18, 18)
    autoCapCB:SetPoint("LEFT", capLabel, "RIGHT", 4, 0)
    _G[autoCapCB:GetName().."Text"]:SetText("Auto")
    do
      local autoLabel = _G[autoCapCB:GetName().."Text"] or autoCapCB.Text
      if autoLabel and autoLabel.SetFontObject then
        autoLabel:SetFontObject(GameFontNormalSmall)
      end
    end
    autoCapCB:SetScale(1.0)

    local function RefreshCapControls()
      if HonorBarDB.autoCapFromRank then
        autoCapCB:SetChecked(true)
        capBox:Disable()
        capBox:SetAlpha(0.5)
      else
        autoCapCB:SetChecked(false)
        capBox:Enable()
        capBox:SetAlpha(1.0)
      end
    end

    autoCapCB:SetScript("OnClick", function(self)
      HonorBarDB.autoCapFromRank = self:GetChecked() and true or false
      if HonorBarDB.autoCapFromRank then
        UpdateAutoCapFromRank()
      else
        honorCap = HonorBarDB.honorCap or honorCap or 500000
      end
      RefreshCapControls()
      if UpdateBar then UpdateBar() end
    end)

    -- Custom milestones
    local cmLabel = HB_AdjustDlg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	    cmLabel:SetPoint("TOP", HB_AdjustDlg, "TOP", 0, -226)
    cmLabel:SetText("Custom Milestones")

    local cmEnableCB = CreateFrame("CheckButton", "HB_Adjust_CustomMilestones", HB_AdjustDlg, "UICheckButtonTemplate")
    cmEnableCB:SetSize(18, 18)
    cmEnableCB:SetPoint("LEFT", cmLabel, "RIGHT", 4, 0)
    _G[cmEnableCB:GetName().."Text"]:SetText("On")
    do
      local lab = _G[cmEnableCB:GetName().."Text"] or cmEnableCB.Text
      if lab and lab.SetFontObject then
        lab:SetFontObject(GameFontNormalSmall)
      end
    end

    local function MakeTextBox(name, x, y, w, getV, setV)
      local e = CreateFrame("EditBox", name, HB_AdjustDlg, "InputBoxTemplate")
      e:SetSize(w, 20)
      e:SetAutoFocus(false)
      e:SetPoint("TOP", HB_AdjustDlg, "TOP", x, y)
      e:SetScript("OnEnterPressed", function(self)
        setV(self:GetText() or "")
        self:ClearFocus()
      end)
      e:SetScript("OnEditFocusLost", function(self)
        setV(self:GetText() or "")
      end)
      e:SetText(tostring(getV() or ""))
      return e
    end

    local function getCMText() return HonorBarDB.customMilestonesText or "" end
    local function setCMText(v)
      HonorBarDB.customMilestonesText = tostring(v or "")
      CreateOrUpdateCustomMilestoneTicks()
    end

	    local cmBox = MakeTextBox("HB_Adjust_CustomMilestonesBox", 0, -244, 170, getCMText, setCMText)

    local function RefreshCMControls()
      local on = HonorBarDB.customMilestonesEnabled == true
      cmEnableCB:SetChecked(on)
      cmBox:SetEnabled(on)
      cmBox:SetAlpha(on and 1.0 or 0.5)
    end

    cmEnableCB:SetChecked(HonorBarDB.customMilestonesEnabled == true)
    cmEnableCB:SetScript("OnClick", function(self)
      HonorBarDB.customMilestonesEnabled = self:GetChecked() and true or false
      RefreshCMControls()
      CreateOrUpdateCustomMilestoneTicks()
    end)

    RefreshCMControls()

    RefreshCapControls()

    local tcountBox = MakeEditBox("HB_Adjust_TCountBox",  90, -184, getTCount, setTCount, HB_Adjust_TCount); tcountBox:SetNumeric(true)

    -- Slider box sync
    if HB_Adjust_Width and widthBox then HB_Adjust_Width:HookScript("OnValueChanged", function(self, v) if not widthBox:HasFocus() then widthBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end
    if HB_Adjust_Height and heightBox then HB_Adjust_Height:HookScript("OnValueChanged", function(self, v) if not heightBox:HasFocus() then heightBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end
    if HB_Adjust_TCount and tcountBox then HB_Adjust_TCount:HookScript("OnValueChanged", function(self, v) if not tcountBox:HasFocus() then tcountBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end

    -- Color swatches
    local function getBarColor()
      return HonorBarDB.barColor or { r = 0.15, g = 0.55, b = 0.95, a = 1 }
    end
    local function setBarColor(tbl)
      if not tbl then return end
      HonorBarDB.barColor = tbl
      barColor = tbl
      if UpdateBar then
        UpdateBar()
      end
    end

    local function getBarBgColor()
      return HonorBarDB.barBgColor or { r = 0, g = 0, b = 0, a = 0.45 }
    end
    local function setBarBgColor(tbl)
      if not tbl then return end
      HonorBarDB.barBgColor = tbl
      if Frame and Frame.bg and Frame.bg.SetColorTexture then
        Frame.bg:SetColorTexture(tbl.r or 0, tbl.g or 0, tbl.b or 0, tbl.a or 0.45)
      end
    end
    local function getTickRGB()
      local c = HonorBarDB.tickRGB or { r = 1, g = 1, b = 1, a = HonorBarDB.tickOpacity or 0.25 }
      local a = HonorBarDB.tickOpacity
      if not a or a <= 0 then
        a = c.a or 0.25
      end
      return { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = a }
    end
    local function setTickRGB(tbl)
      if not tbl then return end
      local a = tbl.a
      if not a or a <= 0 then
        a = HonorBarDB.tickOpacity or 0.25
      end
      HonorBarDB.tickOpacity = a
      HonorBarDB.tickRGB = { r = tbl.r or 1, g = tbl.g or 1, b = tbl.b or 1, a = a }
      CreateOrUpdateTicks()
    end
    local function getMilestoneRGB()
      local c = HonorBarDB.milestoneRGB or { r = 1, g = 0.82, b = 0, a = HonorBarDB.milestoneOpacity or 0.25 }
      local a = HonorBarDB.milestoneOpacity
      if not a or a <= 0 then
        a = c.a or 0.25
      end
      return { r = c.r or 1, g = c.g or 0.82, b = c.b or 0, a = a }
    end
    local function setMilestoneRGB(tbl)
      if not tbl then return end
      local a = tbl.a
      if not a or a <= 0 then
        a = HonorBarDB.milestoneOpacity or 0.25
      end
      HonorBarDB.milestoneOpacity = a
      HonorBarDB.milestoneRGB = { r = tbl.r or 1, g = tbl.g or 0.82, b = tbl.b or 0, a = a }
      CreateOrUpdateMilestoneTicks()
    end

	    MakeColorSwatch("HB_Adjust_BarColor",       "Fill",        -120, -295, getBarColor,     setBarColor)
	    MakeColorSwatch("HB_Adjust_BarBgColor",    "Background",     -40,  -295, getBarBgColor,  setBarBgColor)
	    MakeColorSwatch("HB_Adjust_TickColor",     "Tick",          40,  -295, getTickRGB,      setTickRGB)
	    MakeColorSwatch("HB_Adjust_MilestoneColor","Milestone",    120,  -295, getMilestoneRGB, setMilestoneRGB)

    -- Close
    local closeBtn = CreateFrame("Button", nil, HB_AdjustDlg, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 22)
    closeBtn:SetPoint("BOTTOM", HB_AdjustDlg, "BOTTOM", 0, 16)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() HB_AdjustDlg:Hide() end)
  end
  HB_AdjustDlg:Show()
end

-- Text overlay
TextOverlay = CreateFrame("Frame", nil, Frame)
TextOverlay:SetAllPoints(Frame)
TextOverlay:SetFrameStrata(HB_GetBarStrata())
TextOverlay:SetFrameLevel(Frame:GetFrameLevel() + 100)
HB_ApplyBarStrata()

barText = TextOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
barText:SetShown(not (HonorBarDB and HonorBarDB.hideBarText))
barText:SetPoint("CENTER", TextOverlay, "CENTER", 0, 0)
barText:SetTextColor(1, 1, 1, 1)
barText:SetShadowColor(0, 0, 0, 1)
barText:SetShadowOffset(1, -1)
if HonorBarDB.onlyNumbers then
barText:SetText("0 / 0 (0%)")
else
barText:SetText("Weekly Honor: 0 / 0 (0%)")
end

-- State
local weeklyHonor = 0
-- Stable honor sync state
local HB_HonorSynced = false

-- Hold weekly honor from last known
if HonorBarDB and type(HonorBarDB.lastStableWeeklyHonor) == "number" then
  weeklyHonor = HonorBarDB.lastStableWeeklyHonor
end

local lastAPI = "none"
local sessionStartTime, sessionStartWeekly
local sessionStartHK

-- Maff
local function fmtnum(n)
  local s = tostring(math.floor((n or 0) + 0.5))
  local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
  return left .. (num:reverse():gsub('(%d%d%d)','%1,'):reverse()) .. right
end

HB_FormatCompact = function(n)
  n = tonumber(n) or 0
  local abs = math.abs(n)
  if abs >= 1000000 then
    local v = n / 1000000
    local out = string.format("%.1fm", v)
    out = out:gsub("%.0m$", "m")
    return out
  elseif abs >= 1000 then
    local v = n / 1000
    local fmt = (abs >= 100000) and "%.0fk" or "%.1fk"
    local out = string.format(fmt, v)
    out = out:gsub("%.0k$", "k")
    return out
  end
  return tostring(math.floor(n + 0.5))
end

local function HB_ParseNumberToken(tok)
  tok = tostring(tok or "")
  tok = tok:gsub("%s+", "")
  if tok == "" then return nil end
  local t = tok:lower()
  local mult = 1
  if t:sub(-1) == "k" then
    mult = 1000
    t = t:sub(1, -2)
  elseif t:sub(-1) == "m" then
    mult = 1000000
    t = t:sub(1, -2)
  end
  local v = tonumber(t)
  if not v then return nil end
  v = v * mult
  if v <= 0 then return nil end
  return math.floor(v + 0.5)
end

HB_ParseMilestoneText = function(text)
  local out = {}
  local seen = {}
  for tok in tostring(text or ""):gmatch("[^,%s;]+") do
    local v = HB_ParseNumberToken(tok)
    if v and not seen[v] then
      seen[v] = true
      out[#out+1] = v
    end
  end
  table.sort(out)
  return out
end

local function HB_GetSecondsUntilWeeklyReset()
  local s
  if C_DateAndTime and type(C_DateAndTime.GetSecondsUntilWeeklyReset) == "function" then
    s = C_DateAndTime.GetSecondsUntilWeeklyReset()
    if type(s) == "number" and s > 0 then return s end
  end

  if type(GetNextWeeklyResetTime) == "function" then
    s = GetNextWeeklyResetTime()
    if type(s) == "number" and s > 0 then
      if s > (30 * 86400) and type(GetServerTime) == "function" then
        local now = GetServerTime()
        if type(now) == "number" and s > now then
          local diff = s - now
          if diff > 0 and diff < (30 * 86400) then
            return diff
          end
        end
      end
      if s < (30 * 86400) then
        return s
      end
    end
  end

  return nil
end

local function secsToHM(secs)
  if not secs or secs < 0 then return "N/A" end
  local h = math.floor(secs/3600)
  local m = math.floor((secs%3600)/60)
  return string.format("%dh %dm", h, m)
end

local function secsToHMS(secs)
  if not secs or secs < 0 then return "N/A" end
  local h = math.floor(secs/3600)
  local m = math.floor((secs%3600)/60)
  local s = math.floor(secs % 60)
  if h > 0 then
    return string.format("%dh %dm %ds", h, m, s)
  else
    return string.format("%dm %ds", m, s)
  end
end

local function GetSessionHK()
  if not GetPVPSessionStats then
    return 0
  end
  local hk = 0
  local a = GetPVPSessionStats()
  hk = a or 0
  if not sessionStartHK or sessionStartHK < 0 then
    sessionStartHK = hk
  end
  local diff = hk - (sessionStartHK or 0)
  if diff < 0 then diff = 0 end
  return diff
end

-- current/last game tracking
local inBG = false
local matchHonorBaseline = nil
local matchHKBaseline = nil
local matchInstanceID = nil
local matchActive = false
local matchStartTime = nil

local function HB_IsInBattleground()
  if not IsInInstance then return false end
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "pvp"
end

local function HB_UpdateCurrentGameFromAPIs(deltaHonor)
  if not HonorBarDB then return end
  -- Never touch stats unless in a BG and match is active
  if not HB_IsInBattleground() or not matchActive then
    return
  end

  -- Fields
  if HonorBarDB.currentGameHonor == nil then HonorBarDB.currentGameHonor = 0 end
  if HonorBarDB.currentGameHK == nil then HonorBarDB.currentGameHK = 0 end
  if HonorBarDB.currentGameKB == nil then HonorBarDB.currentGameKB = 0 end

  -- Calculate honor from first update in BG
  if HB_HonorSynced and weeklyHonor ~= nil then
    if matchHonorBaseline == nil then
      -- First synced update inside BG: grab baseline, don't count prior honor
      matchHonorBaseline = weeklyHonor or 0
      HonorBarDB.currentGameHonor = 0
    else
      local diff = (weeklyHonor or 0) - (matchHonorBaseline or 0)
      if diff < 0 then diff = 0 end
      HonorBarDB.currentGameHonor = diff
    end
  end

  -- HKs: use GetPVPSessionStats minus baseline while in BG
  if GetPVPSessionStats and matchHKBaseline then
    local ok, hk = pcall(GetPVPSessionStats)
    if ok then
      hk = hk or 0
    else
      hk = GetPVPSessionStats() or 0
    end
    local diff = (hk or 0) - (matchHKBaseline or 0)
    if diff < 0 then diff = 0 end
    HonorBarDB.currentGameHK = diff
  end
end

local function HB_SnapshotCurrentToLast()
  if not HonorBarDB then return end

  local cgHonor = HonorBarDB.currentGameHonor or 0
  local cgHK    = HonorBarDB.currentGameHK or 0
  local cgKB    = HonorBarDB.currentGameKB or 0
  local cgTime  = HonorBarDB.currentGameTime or 0

  -- Avoid 0ing
  if (cgHonor > 0) or (cgHK > 0) or (cgKB > 0) or (cgTime > 0) then
    HonorBarDB.lastGameHonor = cgHonor
    HonorBarDB.lastGameHK    = cgHK
    HonorBarDB.lastGameKB    = cgKB
    HonorBarDB.lastGameTime  = cgTime
  end
end

local function HB_StartNewMatch()
  if not HonorBarDB then return end

  -- Never reset match stats unless actually in a BG
  if not HB_IsInBattleground() then
    return
  end

  -- Defaults
  if HonorBarDB.currentGameHonor == nil then HonorBarDB.currentGameHonor = 0 end
  if HonorBarDB.currentGameHK == nil then HonorBarDB.currentGameHK = 0 end
  if HonorBarDB.currentGameKB == nil then HonorBarDB.currentGameKB = 0 end
  if HonorBarDB.lastGameHonor == nil then HonorBarDB.lastGameHonor = 0 end
  if HonorBarDB.lastGameHK == nil then HonorBarDB.lastGameHK = 0 end
  if HonorBarDB.lastGameKB == nil then HonorBarDB.lastGameKB = 0 end
  if HonorBarDB.currentGameTime == nil then HonorBarDB.currentGameTime = 0 end
  if HonorBarDB.lastGameTime == nil then HonorBarDB.lastGameTime = 0 end

  -- Current Game 0s only on ENTRY into BG
  -- Last Game snapshots whatever Current Game was immediately BEFORE that 0
  HB_SnapshotCurrentToLast()

  -- Reset for new match
  matchActive = true
  matchStartTime = GetTime and GetTime() or nil
  HonorBarDB.currentGameHonor = 0
  HonorBarDB.currentGameHK    = 0
  HonorBarDB.currentGameKB    = 0
  HonorBarDB.currentGameTime  = 0

  -- Honor baseline:
  -- If weekly honor is already synced,then snapshot
  matchHonorBaseline = (HB_HonorSynced and (weeklyHonor or 0)) or nil
  -- Base for HKs
  if GetPVPSessionStats then
    local ok, hk = pcall(GetPVPSessionStats)
    if ok then
      matchHKBaseline = hk or 0
    else
      local h1 = GetPVPSessionStats()
      matchHKBaseline = h1 or 0
    end
  else
    matchHKBaseline = nil
  end
end

local function HB_CheckBG()
  local nowInBG = HB_IsInBattleground()
  inBG = nowInBG

  if nowInBG then
    -- Start a new match on BG entry
    if not matchActive then
      matchInstanceID = nil
      if GetInstanceInfo then
        local _, _, _, _, _, _, _, instID = GetInstanceInfo()
        matchInstanceID = instID
      end
      if matchInstanceID == nil then
        matchInstanceID = -1
      end

      HB_StartNewMatch()
    else
      if (matchInstanceID == -1) and GetInstanceInfo then
        local _, _, _, _, _, _, _, instID = GetInstanceInfo()
        if instID then
          matchInstanceID = instID
        end
      end
    end
  else
    -- Leaving BG stops updating stats, but no 0 and Current Game remains visible until the next BG entry
    if matchActive and HonorBarDB and matchStartTime and GetTime then
      local now = GetTime()
      if now and now > matchStartTime then
        HonorBarDB.currentGameTime = math.max(0, math.floor(now - matchStartTime))
      end
    end

    matchStartTime = nil
    matchInstanceID = nil
    matchHonorBaseline = nil
    matchHKBaseline = nil
    matchActive = false
  end
end

local function HB_OnCombatLogEvent()
  if not inBG or not HonorBarDB then return end
  if not CombatLogGetCurrentEventInfo or not UnitGUID then return end
  local _, eventType, _, srcGUID, _, _, _, _, _, destFlags = CombatLogGetCurrentEventInfo()
  if eventType ~= "PARTY_KILL" then return end
  if srcGUID ~= UnitGUID("player") then return end

  if COMBATLOG_OBJECT_TYPE_PLAYER and bit and destFlags then
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then
      return
    end
  end

  HonorBarDB.currentGameKB = (HonorBarDB.currentGameKB or 0) + 1
end

local BGTracker = CreateFrame("Frame", "HonorBar_BGTracker", UIParent)
BGTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
BGTracker:RegisterEvent("ZONE_CHANGED_NEW_AREA")
BGTracker:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
BGTracker:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    HB_CheckBG()
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    HB_OnCombatLogEvent()
  end
end)

local function HB_BuildHonorStatusString()
  -- Use the active cap: auto if enabled, if not use manual cap.
  local cap = (honorCap and honorCap > 0) and honorCap or (HonorBarDB.honorCap or 500000)
  local earned = weeklyHonor or 0
  local pct = 0
  if cap > 0 then
    pct = (earned * 100) / cap
  end
  return string.format("Weekly Honor: %s of %s (%.2f%%)", fmtnum(earned), fmtnum(cap), pct)
end

local function HB_SendHonorToCurrentChat()
  local text = HB_BuildHonorStatusString()
  if not text or text == "" then return end

  local editBox
  if ChatEdit_GetActiveWindow then
    editBox = ChatEdit_GetActiveWindow()
  end
  if not editBox and ChatEdit_ChooseBoxForSend then
    editBox = ChatEdit_ChooseBoxForSend()
  end

  if not editBox or not editBox.GetAttribute then
    SendChatMessage(text, "SAY")
    return
  end

  local chatType = editBox:GetAttribute("chatType") or "SAY"

  if chatType == "WHISPER" or chatType == "BN_WHISPER" then
    local tellTarget = editBox:GetAttribute("tellTarget")
    if tellTarget then
      SendChatMessage(text, chatType, nil, tellTarget)
    else
      SendChatMessage(text, "SAY")
    end
  elseif chatType == "CHANNEL" then
    local channelTarget = editBox:GetAttribute("channelTarget")
    if channelTarget then
      SendChatMessage(text, "CHANNEL", nil, channelTarget)
    else
      SendChatMessage(text, "SAY")
    end
  else
    SendChatMessage(text, chatType)
  end
end

UpdateBar = function()
  local cap = (honorCap and honorCap > 0) and honorCap or 1
  bar:SetMinMaxValues(0, cap)
  bar:SetValue(weeklyHonor or 0)
  local pct = math.min(((weeklyHonor or 0) / cap) * 100, 100)

  if not barText and Frame and Frame.GetChildren then
    for i = 1, select("#", Frame:GetChildren()) do
      local child = select(i, Frame:GetChildren())
      if child and child.GetObjectType and child:GetObjectType() == "FontString" then
        barText = child
        break
      end
    end
  end

  local showText    = HonorBarDB.showText ~= false
  local hideBarText = HonorBarDB.hideBarText == true

  -- Check if honor cap has been reached.
  local goalReached = HonorBarDB and HonorBarDB.autoCapFromRank
    and honorCap and honorCap > 0
    and weeklyHonor and weeklyHonor >= honorCap or false

  -- Final congrats flag
  local charKey = HB_GetCharKey and HB_GetCharKey() or nil
  local charCongrats = false
  if charKey and HonorBarDB.finalCongratsByChar then
    charCongrats = HonorBarDB.finalCongratsByChar[charKey] and true or false
  end

  if not charCongrats and congratsRankChecksRemaining and congratsRankChecksRemaining > 0
     and UnitPVPRank and GetPVPRankInfo then
    congratsRankChecksRemaining = congratsRankChecksRemaining - 1
    local pvpRank = UnitPVPRank("player")
    if pvpRank and pvpRank > 0 then
      local _, r = GetPVPRankInfo(pvpRank)
      if r and r >= 14 then
        charCongrats = true
        if charKey then
          HonorBarDB.finalCongratsByChar = HonorBarDB.finalCongratsByChar or {}
          HonorBarDB.finalCongratsByChar[charKey] = true
        end
      end
    end
  end

  if barText then
    if showText and not hideBarText then
      barText:Show()

      if HonorBarDB.autoCapFromRank then
        -- 1. Already completed the final Rank 14 push prior week.
        if charCongrats then
          barText:SetText("Congratulations!")

        -- 2. Weekly honor cap reached this week.
        elseif goalReached then
          -- Final-week check: only treat it as the final Rank 13 -> 14 push if the weekly cap matches the known final cap (~418750), AND the player is Rank 13 at ~67.84% progress.
          local isFinalWeek = false
          if honorCap and math.floor((honorCap or 0) + 0.5) == 418750 then
            local rank = 0
            local progress = 0

            if UnitPVPRank and GetPVPRankInfo then
              local pvpRank = UnitPVPRank("player")
              if pvpRank and pvpRank > 0 then
                local _, r = GetPVPRankInfo(pvpRank)
                rank = r or 0
              end
            end

            if GetPVPRankProgress then
              local ok, val = pcall(GetPVPRankProgress)
              if ok and type(val) == "number" then
                progress = val
              end
            end

            local progress4 = math.floor(progress * 10000 + 0.5) / 10000
            if rank == 13 and progress4 == 0.6784 then
              isFinalWeek = true
            end
          end

          if isFinalWeek then
            if charKey then
              HonorBarDB.finalCongratsByChar = HonorBarDB.finalCongratsByChar or {}
              HonorBarDB.finalCongratsByChar[charKey] = true
            end
            barText:SetText("Congratulations!")
          else
            barText:SetText("Weekly Honor Cap Reached!")
          end

        -- 3. Auto enabled, goal not met, show text.
        else
          if HonorBarDB.onlyNumbers then
            barText:SetText(string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
          else
            barText:SetText(string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
          end
        end

      -- Manual mode: always show text.
      else
        if HonorBarDB.onlyNumbers then
          barText:SetText(string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
        else
          barText:SetText(string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
        end
      end
    else
      barText:Hide()
    end
  end

  CreateOrUpdateTicks()

  if Frame and HonorBarDB and HonorBarDB.barColor then
    local c = HonorBarDB.barColor
    if bar and bar.SetStatusBarColor then
      bar:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    end
    if Frame.SetBackdropColor then
      Frame:SetBackdropColor(c.r or 1, c.g or 1, c.b or 1, (c.a or 1) * 0.25)
    end
  end
end

-- Weekly honor garbs
local function GetWeeklyHonor()
  if GetPVPThisWeekStats then
    local hk, weekly = GetPVPThisWeekStats()
    if type(weekly) == "number" then lastAPI = "GetPVPThisWeekStats()"; return weekly end
  end
  if GetPVPHonorStats then
    local _, _, _, thisWeek = GetPVPHonorStats()
    if type(thisWeek) == "number" then lastAPI = "GetPVPHonorStats()"; return thisWeek end
  end
  if GetHonorStats then
    local _, _, _, thisWeek = GetHonorStats()
    if type(thisWeek) == "number" then lastAPI = "GetHonorStats()"; return thisWeek end
  end
  if GetPVPLifetimeStats then
    local hk, dk, lifetime = GetPVPLifetimeStats()
    if type(lifetime) == "number" then lastAPI = "GetPVPLifetimeStats()"; return lifetime end
  end
  lastAPI = "none"
  return weeklyHonor or 0
end

-- Weekly honor filtering
local HB_WeeklyPendingDropStart = nil
local HB_WeeklyPendingDropPrev  = nil
local HB_WeeklyPendingZeroStart = nil
local HB_WeeklyDropConfirmSeconds = 3.0
local HB_WeeklyZeroConfirmSeconds = 2.0

local function HB_GetStableWeeklyHonor(rawVal, fromAPI)
  local now = (GetTime and GetTime()) or 0
  local oldVal = tonumber(weeklyHonor) or 0

  -- If no read, then not marked as synced.
  if not fromAPI then
    return oldVal, true, false
  end

  local newVal = tonumber(rawVal)
  if newVal == nil then
    return oldVal, true, false
  end

  -- If decrease confirm/cancel
  if HB_WeeklyPendingDropStart then
    if newVal >= (HB_WeeklyPendingDropPrev or 0) then
      HB_WeeklyPendingDropStart = nil
      HB_WeeklyPendingDropPrev  = nil
      HB_WeeklyPendingZeroStart = nil
      return newVal, false, true
    end
    if (now - HB_WeeklyPendingDropStart) < (HB_WeeklyDropConfirmSeconds or 3.0) then
      return oldVal, true, false
    end
    HB_WeeklyPendingDropStart = nil
    HB_WeeklyPendingDropPrev  = nil
    HB_WeeklyPendingZeroStart = nil
    return newVal, false, true
  end

  -- 0 reads keep happening, try again before syncing to 0.
  if oldVal == 0 and newVal == 0 then
    if not HB_WeeklyPendingZeroStart then
      HB_WeeklyPendingZeroStart = now
      return oldVal, true, false
    end
    if (now - HB_WeeklyPendingZeroStart) < (HB_WeeklyZeroConfirmSeconds or 2.0) then
      return oldVal, true, false
    end
    HB_WeeklyPendingZeroStart = nil
    return 0, false, true
  end

  -- Any non 0 value clears the 0 timer.
  HB_WeeklyPendingZeroStart = nil

  -- Show previous value briefly until confirmed.
  if oldVal > 0 and newVal < oldVal then
    HB_WeeklyPendingDropStart = now
    HB_WeeklyPendingDropPrev  = oldVal
    return oldVal, true, false
  end

  return newVal, false, true
end

local function RefreshHonor(verbose)
  local oldWeekly = tonumber(weeklyHonor) or 0
  local newRaw = GetWeeklyHonor()

  -- Consider an update "synced" only when there is a solid API read.
  local fromAPI = (lastAPI ~= "none") and (type(newRaw) == "number")

  local newVal, provisional, synced = HB_GetStableWeeklyHonor(newRaw, fromAPI)

  -- Update stable honor
  weeklyHonor = newVal
  HB_HonorSynced = synced

  -- Weekly reset handling
  if synced and (tonumber(weeklyHonor) or 0) < (oldWeekly or 0) then
    sessionStartTime   = nil
    sessionStartWeekly = nil
    sessionStartHK     = nil
    matchHonorBaseline = nil
    matchHKBaseline    = nil
  end

  -- Keep value only when synced
  if synced and HonorBarDB then
    HonorBarDB.lastStableWeeklyHonor = newVal
  end

  -- Start session baselines once synced honor
  if synced and not sessionStartTime then
    sessionStartTime = GetTime() and math.floor(GetTime()) or 0
    sessionStartWeekly = newVal

    if GetPVPSessionStats then
      local ok, a = pcall(GetPVPSessionStats)
      if ok then
        sessionStartHK = a or 0
      else
        local h1 = GetPVPSessionStats()
        sessionStartHK = h1 or 0
      end
    end
  end

  -- Sound notifications, only on synced values
  if synced then
    HB_CheckHonorSounds(oldWeekly, weeklyHonor)
  end

  -- Update current game stats (honor/HK) while in BG
  HB_UpdateCurrentGameFromAPIs()

  -- Update auto & milestones if enabled and weekly honor changed
  if HonorBarDB and HonorBarDB.autoCapFromRank and (weeklyHonor or 0) ~= oldWeekly then
    UpdateAutoCapFromRank()
  end

  UpdateBar()
  if verbose then
    HB_Print("Weekly =", weeklyHonor, "API =", lastAPI, "Synced =", HB_HonorSynced and "Y" or "N")
  end
end

-- Auto refresh slider
local ticker
local function StartAuto()
  if not C_Timer or not C_Timer.NewTicker then return end
  if ticker and ticker.Cancel then
    ticker:Cancel()
  end
  local interval = HB_GetRefreshInterval()
  ticker = C_Timer.NewTicker(interval, function() RefreshHonor(false) end)
end
local function StopAuto()
  if ticker and ticker.Cancel then ticker:Cancel() end
  ticker = nil
end
if autoOn then StartAuto() end

-- Show/Hide control
function ApplyVisibility()
  local shouldShow = HonorBarDB.visible and not HonorBarDB.hiddenBar
  if shouldShow then
    Frame:Show()
  else
    Frame:Hide()
  end
end
local function ShowBar()
  HonorBarDB.hiddenBar = false
  HonorBarDB.visible = true
  ApplyVisibility()
  HB_Print("bar shown")
end
local function HideBar()
  HonorBarDB.hiddenBar = true
  HonorBarDB.visible = false
  ApplyVisibility()
  HB_Print("bar hidden (use /honor show to display)")
end
local function ToggleBar()
  if HonorBarDB.hiddenBar or not HonorBarDB.visible then
    ShowBar()
  else
    HideBar()
  end
end

-- Apply settings/save
local function ApplyAllSettings()
  Frame:ClearAllPoints()
  if HonorBarDB.point and HonorBarDB.relativePoint and HonorBarDB.xOfs and HonorBarDB.yOfs then
    Frame:SetPoint(HonorBarDB.point, UIParent, HonorBarDB.relativePoint, HonorBarDB.xOfs, HonorBarDB.yOfs)
  else
    Frame:SetPoint("CENTER")
  end
  local w = HonorBarDB.width or 300
  local h = HonorBarDB.height or 30
  Frame:SetSize(w, h)
  -- Ensure Send Back (frame strata) is applied after SavedVariables load
  if HB_ApplyBarStrata then HB_ApplyBarStrata() end
  local c = HonorBarDB.barColor or { r=0.15, g=0.55, b=0.95, a=1 }
  barColor = c
  bar:SetStatusBarColor(c.r or 0.2, c.g or 0.6, c.b or 1.0, c.a or 0.9)

  -- Apply background color
  if Frame and Frame.bg and Frame.bg.SetColorTexture and HonorBarDB and HonorBarDB.barBgColor then
    local bgc = HonorBarDB.barBgColor
    Frame.bg:SetColorTexture(bgc.r or 0, bgc.g or 0, bgc.b or 0, bgc.a or 0.45)
  end

  honorCap = HonorBarDB.honorCap or 500000
  autoOn   = HonorBarDB.autoOn ~= false

  -- Check auto & milestones on login if on
  if HonorBarDB.autoCapFromRank then
    UpdateAutoCapFromRank()
  end
  if autoOn then StartAuto() else StopAuto() end
  ApplyVisibility()
  UpdateBar()
end

local Loader = CreateFrame("Frame")
Loader:RegisterEvent("ADDON_LOADED")
Loader:RegisterEvent("PLAYER_LOGOUT")
Loader:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    ApplyDefaults()
    ApplyAllSettings()
    HB_Print("loaded. Commands: /honor, /hb.")
  elseif event == "PLAYER_LOGOUT" then
    if not HonorBarDB.autoCapFromRank then
      HonorBarDB.honorCap = honorCap
    end
      HonorBarDB.autoOn   = autoOn
    -- HonorBarDB.barColor persist
    HonorBarDB.width, HonorBarDB.height = math.floor(Frame:GetWidth()+0.5), math.floor(Frame:GetHeight()+0.5)
    local point, _, relativePoint, xOfs, yOfs = Frame:GetPoint()
    HonorBarDB.point, HonorBarDB.relativePoint = point, relativePoint
    HonorBarDB.xOfs, HonorBarDB.yOfs = xOfs, yOfs
    HonorBarDB.visible = HonorBarDB.visible and true or false
  end
end)

Frame:SetScript("OnSizeChanged", function(self) CreateOrUpdateTicks() end)

-- Alt+Left-Click dragging
Frame:EnableMouse(true)
Frame:SetMovable(true)
Frame:SetScript("OnMouseDown", function(self, button)
  if button == "RightButton" then
    if IsShiftKeyDown() then
      HB_SendHonorToCurrentChat()
    else
      HB_OpenAdjustDialog()
    end
    return
  end
  if button == "LeftButton" and IsAltKeyDown() then
    self:StartMoving()
  end
end)
Frame:SetScript("OnMouseUp", function(self, button)
  if self:IsMovable() then
    self:StopMovingOrSizing()
    -- Persist position
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    HonorBarDB.point, HonorBarDB.relativePoint = point, relativePoint
    HonorBarDB.xOfs, HonorBarDB.yOfs = xOfs, yOfs
  end
end)

-- Live tooltip @ 0.2s
local tooltipVisible, tooltipAccum = false, 0
-- Session stats & tooltip (detached + mouseover)
local tooltipCurrentGameLineIndex = nil
local statsFrame, statsAccum = nil, 0
local statsTimerAccum = 0
local tooltipTimerAccum = 0
local statsLines = {}

local tooltipLines = {}

local markSegments = {}

-- BG Mark of Honor item IDs
local MARK_WSG  = 20558 -- Warsong Gulch Mark of Honor
local MARK_AB   = 20559 -- Arathi Basin Mark of Honor
local MARK_AV   = 20560 -- Alterac Valley Mark of Honor

local function HB_GetMarkCounts()
  local av = GetItemCount and GetItemCount(MARK_AV) or 0
  local ab = GetItemCount and GetItemCount(MARK_AB) or 0
  local wsg = GetItemCount and GetItemCount(MARK_WSG) or 0
  return av, ab, wsg
end

local function HB_GetMarkLine()
  local av, ab, wsg = HB_GetMarkCounts()

  wipe(markSegments)

  local avIcon = GetItemIcon and GetItemIcon(MARK_AV) or "Interface\\Icons\\INV_Misc_QuestionMark"
  local abIcon = GetItemIcon and GetItemIcon(MARK_AB) or "Interface\\Icons\\INV_Misc_QuestionMark"
  local wsgIcon = GetItemIcon and GetItemIcon(MARK_WSG) or "Interface\\Icons\\INV_Misc_QuestionMark"

  markSegments[1] = string.format("|T%s:16:16:0:0|t %d %s", avIcon, av or 0, "AV")
  markSegments[2] = string.format("|T%s:16:16:0:0|t %d %s", abIcon, ab or 0, "AB")
  markSegments[3] = string.format("|T%s:16:16:0:0|t %d %s", wsgIcon, wsg or 0, "WSG")

  return table.concat(markSegments, "   ")
end
local function HB_BuildSessionStatsLines(lines, opts)
  if not lines then return nil end
  opts = opts or {}
  local context = opts.context or "statsframe" -- "statsframe" | "tooltip"
  local includeHeader = (opts.includeHeader ~= false)
  local includeBarLine = (opts.includeBarLine == true)
  local gameTimeMode = opts.gameTimeMode or "live" -- "live" | "placeholder"

  wipe(lines)

  local _vis = (HonorBarDB and HonorBarDB.statsLinesShown) or nil
  local function _show(key)
    if key == "header" then return true end
    if not _vis then return true end
    return _vis[key] ~= false
  end

  local now = GetTime() and math.floor(GetTime()) or 0
  local elapsed = (sessionStartTime and (now - sessionStartTime)) or 0
  local gained = (sessionStartWeekly and (weeklyHonor - sessionStartWeekly)) or 0
  if gained < 0 then gained = 0 end
  local hph = (elapsed > 0) and (gained * 3600 / elapsed) or 0
  local remaining = (honorCap and honorCap > 0) and (honorCap - (weeklyHonor or 0)) or 0
  if remaining < 0 then remaining = 0 end
  local sessionHK = GetSessionHK()
  local etaSecs = (hph > 0) and (remaining / hph * 3600) or nil

  if includeHeader then
    if context == "statsframe" then
      if _show("header") then table.insert(lines, "|cff3399ffSession Stats|r") end
    else
      if _show("header") then table.insert(lines, "Session Stats") end
    end
    if _show("time") then table.insert(lines, string.format("Time: %s", secsToHM(elapsed))) end
    if _show("honor") then table.insert(lines, string.format("Honor: %s", fmtnum(gained))) end
    if _show("hph") then table.insert(lines, string.format("Honor / hour: %s", fmtnum(hph))) end

    if includeBarLine and HonorBarDB and HonorBarDB.showText then
      local cap = (honorCap and honorCap > 0) and honorCap or 1
      local pct = math.min(((weeklyHonor or 0) / cap) * 100, 100)
      local barLine
      if HonorBarDB.onlyNumbers then
        barLine = string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      else
        barLine = string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      end
      if _show("weekly") then table.insert(lines, barLine) end
    end
  end

  if _show("remaining") then table.insert(lines, string.format("Remaining: %s", fmtnum(remaining))) end

  -- Recommended pace to hit weekly cap before reset
  if HonorBarDB and HonorBarDB.showGoalPace ~= false then
    local cur = weeklyHonor or 0
    local toCap = remaining or 0
    if toCap < 0 then toCap = 0 end

    local secsLeft = HB_GetSecondsUntilWeeklyReset()
    if secsLeft and secsLeft > 0 then
      local daysLeft = secsLeft / 86400
      local needPerDay = (daysLeft > 0) and (toCap / daysLeft) or 0
      needPerDay = math.floor(needPerDay + 0.5)

      -- Show current pace only when enough time has passed
      local weekSecs = 7 * 86400
      local daysElapsed = (weekSecs - secsLeft) / 86400
      if daysElapsed and daysElapsed >= 0.5 then
        local curPerDay = math.floor((cur / daysElapsed) + 0.5)
        table.insert(lines, string.format("Pace: %s/day  Need: %s/day", fmtnum(curPerDay), fmtnum(needPerDay)))
      else
        table.insert(lines, string.format("Need: %s honor/day", fmtnum(needPerDay)))
      end
    else
    end
  end

  -- Milestones line (auto mode only)
  if _show("milestones") then
  do
    local parts = {}
    if HonorBarDB and HonorBarDB.autoCapFromRank and rankMilestones and type(rankMilestones) == "table" and #rankMilestones > 1 then
      local currentHonor = weeklyHonor or 0
      for i = 1, #rankMilestones - 1 do
        local m = rankMilestones[i]
        if m and m.honor and m.honor > currentHonor then
          local delta = m.honor - currentHonor
          if delta > 0 then
            local label
            local pct = m.rankProgress
            if type(pct) == "number" and pct > 0 then
              local pctInt = math.floor(pct * 100 + 0.5)
              label = string.format("R%d-%d", m.rank or 0, pctInt)
            else
              label = string.format("R%d", m.rank or 0)
            end
            table.insert(parts, string.format("%s (%s)", label, fmtnum(delta)))
          end
        end
      end
    end
    if #parts > 0 then
      table.insert(lines, "Milestones: " .. table.concat(parts, "   "))
    end
  end

  end

  if _show("hks") then table.insert(lines, string.format("HKs: %d", sessionHK)) end
  if _show("eta") then table.insert(lines, string.format("ETA to %s: %s", fmtnum(honorCap or 0), etaSecs and secsToHM(etaSecs) or "N/A")) end

  local marksLine = HB_GetMarkLine()
  if marksLine and marksLine ~= "" then
    if _show("marks") then table.insert(lines, "Marks: " .. marksLine) end
  end

  local currentGameLineIndex
  if HonorBarDB then
    local curHonor = HonorBarDB.currentGameHonor or 0
    local curHK    = HonorBarDB.currentGameHK or 0
    local curKB    = HonorBarDB.currentGameKB or 0
    local lastHonor = HonorBarDB.lastGameHonor or 0
    local lastHK    = HonorBarDB.lastGameHK or 0
    local lastKB    = HonorBarDB.lastGameKB or 0

    local curTimeStr, lastTimeStr = "--", "--"
    if gameTimeMode == "live" then
      local curTime   = HonorBarDB.currentGameTime or 0
      local lastTime  = HonorBarDB.lastGameTime or 0

      if matchActive and matchStartTime then
        local tnow = GetTime and GetTime() or nil
        if tnow and tnow > matchStartTime then
          curTime = math.max(0, math.floor(tnow - matchStartTime))
        end
      end

      curTimeStr  = secsToHMS(curTime)
      lastTimeStr = secsToHMS(lastTime)
    end

    if _show("currentgame") then
      currentGameLineIndex = #lines + 1
      table.insert(lines, string.format("Current Game: Honor %s HKs %d KBs %d Time %s", fmtnum(curHonor), curHK, curKB, curTimeStr))
    end
    if _show("lastgame") then
      table.insert(lines, string.format("Last Game: Honor %s HKs %d KBs %d Time %s", fmtnum(lastHonor), lastHK, lastKB, lastTimeStr))
    end
  end

  return {
    currentGameLineIndex = currentGameLineIndex,
  }
end

-- Detached stats
EnsureStatsFrame = function()
  if statsFrame and statsFrame:IsObjectType("Frame") then
    return statsFrame
  end

  local f = CreateFrame("Frame", "HonorBarSessionStatsFrame", UIParent)
  f:SetFrameStrata("MEDIUM")
  f:SetSize(220, 120)
  f:SetMovable(true)
  f:EnableMouse(true)
  -- Alt+Left-Click dragging for detached stats
  f:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsAltKeyDown() then
      self:StartMoving()
    end
  end)
  f:SetScript("OnMouseUp", function(self, button)
    if self:IsMovable() then
      self:StopMovingOrSizing()
      if not HonorBarDB then return end
      local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
      HonorBarDB.statsPoint = point
      HonorBarDB.statsRelativePoint = relativePoint
      HonorBarDB.statsXOfs = xOfs
      HonorBarDB.statsYOfs = yOfs
    end
  end)

  -- Restore saved points if available
  if HonorBarDB and HonorBarDB.statsPoint then
    f:ClearAllPoints()
    f:SetPoint(HonorBarDB.statsPoint, UIParent, HonorBarDB.statsRelativePoint or "CENTER",
      HonorBarDB.statsXOfs or 0, HonorBarDB.statsYOfs or 0)
  else
    f:SetPoint("TOP", UIParent, "TOP", 0, -200)
  end

  -- Detatched Text only
  local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetWidth(260)
  do
    local font, size, flags = text:GetFont()
    if size then
      text:SetFont(font, size + 2, flags)
    end
  end
  f.text = text

  f:Hide()
  statsFrame = f
  return f
end

UpdateStatsFrame = function()
  if not HonorBarDB or not HonorBarDB.detachStats then
    if statsFrame then statsFrame:Hide() end
    return
  end

  local f = EnsureStatsFrame()
  if not f then return end
  f:Show()

  local lines = statsLines
  HB_BuildSessionStatsLines(lines, {
    context = "statsframe",
    includeHeader = true,
    includeBarLine = (HonorBarDB and HonorBarDB.hideBarText) or false,
    gameTimeMode = "live",
  })

  local text = f.text
  text:SetText(table.concat(lines, "\n"))

  local h = text:GetStringHeight() + 4
  local w = text:GetStringWidth() + 10
  f:SetHeight(h)
  f:SetWidth(math.max(220, w))
end

local function UpdateGameTimersOnly()
  if not HonorBarDB or not HonorBarDB.detachStats then return end
  if not statsFrame or not statsFrame.text or not statsFrame:IsShown() then return end

  local text = statsFrame.text:GetText()
  if not text or text == "" then return end
  if not string.find(text, "Current Game: Honor", 1, true) then
    return
  end

  -- Only update the Current Game timer leave everythign else
  local curTime = HonorBarDB.currentGameTime or 0

  if matchActive and matchStartTime and GetTime then
    local tnow = GetTime()
    if tnow and tnow > matchStartTime then
      curTime = math.max(0, math.floor(tnow - matchStartTime))
    end
  end

  local curTimeStr = secsToHMS(curTime)

  -- Replace only the Time portion of the Current Game keep Honor/HK/KB.
  text = string.gsub(text, "(Current Game: Honor[^\n]-Time )[^ \n]*[^\n]*", "%1" .. curTimeStr, 1)

  statsFrame.text:SetText(text)
end

local function UpdateTooltipGameTimersOnly()
  if not tooltipVisible then return end
  if not HonorBarDB then return end
  if not tooltipCurrentGameLineIndex then return end

  local curTime = HonorBarDB.currentGameTime or 0

  if matchActive and matchStartTime and GetTime then
    local tnow = GetTime()
    if tnow and tnow > matchStartTime then
      curTime = math.max(0, math.floor(tnow - matchStartTime))
    end
  end

  local curTimeStr = secsToHMS(curTime)

  local fs = _G["GameTooltipTextLeft" .. tooltipCurrentGameLineIndex]
  if fs then
    local text = fs:GetText()
    if text and text ~= "" then
      text = string.gsub(text, "(Time ).*$", "%1" .. curTimeStr, 1)
      fs:SetText(text)
      GameTooltip:Show()
    end
  end
end

local function UpdateTooltip()
  if not tooltipVisible then return end

  GameTooltip:ClearLines()

  local function AddDimLine(text)
    GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true)
    local n = GameTooltip:NumLines()
    local fs = _G["GameTooltipTextLeft"..n]
    if fs then fs:SetTextColor(0.7, 0.7, 0.7, 0.5) end
  end

  -- When session stats are detached bar tooltip only shows hints
  if HonorBarDB and HonorBarDB.detachStats then
    tooltipCurrentGameLineIndex = nil

    AddDimLine("Hold Alt + Left-Click to drag")
    AddDimLine("Right-Click to adjust bar")
    AddDimLine("Shift + Right-Click to broadcast honor to chat")
    AddDimLine("/honor for help")

    GameTooltip:Show()
    return
  end

  local includeHeader = not (HonorBarDB and HonorBarDB.detachStats)
  local lines = tooltipLines
  local meta = HB_BuildSessionStatsLines(lines, {
    context = "tooltip",
    includeHeader = includeHeader,
    includeBarLine = true,
    -- Show last-game time in the tooltip. Current-game time is still updated live via UpdateTooltipGameTimersOnly().
    gameTimeMode = "live",
  })

  tooltipCurrentGameLineIndex = meta and meta.currentGameLineIndex or nil

  for i = 1, #lines do
    local line = lines[i]
    if i == 1 and includeHeader then
      GameTooltip:AddLine(line, 0.2, 0.6, 1.0, true)
    else
      GameTooltip:AddLine(line, 1, 1, 1, true)
    end
  end

  AddDimLine("Hold Alt + Left-Click to drag")
  AddDimLine("Right-Click to adjust bar")
  AddDimLine("Shift + Right-Click to broadcast honor to chat")
  AddDimLine("/honor for help")

  GameTooltip:Show()
  UpdateTooltipGameTimersOnly()
end

Frame:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  tooltipVisible = true
  tooltipAccum = 0
  UpdateTooltip()
end)
Frame:SetScript("OnLeave", function(self)
  tooltipVisible = false
  if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end)
Frame:SetScript("OnUpdate", function(self, elapsed)
  elapsed = elapsed or 0

  local refresh = HB_GetRefreshInterval()

  if HonorBarDB and HonorBarDB.detachStats then
    -- Heavy stats refresh uses the configurable interval
    statsAccum = statsAccum + elapsed
    if statsAccum >= refresh then
      statsAccum = 0
      UpdateStatsFrame()
    end

    -- Detached stats game timer refresh once per second
    statsTimerAccum = statsTimerAccum + elapsed
    if statsTimerAccum >= 1.0 then
      statsTimerAccum = 0
      UpdateGameTimersOnly()
    end
  end

  if not tooltipVisible then return end

  -- Tooltip uses the slider
  tooltipAccum = tooltipAccum + elapsed
  if tooltipAccum >= refresh then
    tooltipAccum = 0
    UpdateTooltip()
    -- Refresh tooltip timers after a reload
    UpdateTooltipGameTimersOnly()
  end

  -- Tooltip timer refresh once per second
  tooltipTimerAccum = tooltipTimerAccum + elapsed
  if tooltipTimerAccum >= 1.0 then
    tooltipTimerAccum = 0
    UpdateTooltipGameTimersOnly()
  end

end)

local function Trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function SplitTwo(s)
  if not s then return "", "" end
  local a,b = s:match("^(%S+)%s*(.-)$")
  return a or "", b or ""
end

local function HB_SuggestCommand(input)
  local cmds = { "config", "debug", "cap", "auto", "milestones", "resetpos", "show", "hide", "toggle" }
  if not input or input == "" then return nil end
  input = string.lower(input)
  for _,c in ipairs(cmds) do if c == input then return c end end
  -- Prefix/substring matches
  local matches = {}
  for _,c in ipairs(cmds) do
    if string.sub(c,1,#input) == input or string.find(c, input, 1, true) then
      table.insert(matches, c)
    end
  end
  if #matches > 0 then return table.concat(matches, ", ") end
  -- show all
  return table.concat(cmds, ", ")
end

function RootSlashHandler(msg)
  msg = Trim(string.lower(msg or ""))
  local cmd, rest = SplitTwo(msg)
  if cmd == "" or cmd == "help" then
    if type(HB_ToggleHelpDialog) == "function" then
      HB_ToggleHelpDialog()
    elseif type(HB_ShowHelpPopup) == "function" then
      HB_ShowHelpPopup()
    else
      HB_Print("Commands: config, debug, cap <n>, auto on|off, resetsounds, resetpos, show, hide, toggle")
    end
  elseif cmd == "debug" then
    RefreshHonor(true)
  elseif cmd == "mem" or cmd == "memory" then
    HB_PrintMemory()
  elseif cmd == "cap" then
    if HonorBarDB.autoCapFromRank then
      HB_Print("Auto cap is enabled; uncheck 'Auto' next to Honor Cap in /honor to set a manual cap.")
    else
      local v = tonumber(rest)
      if v and v > 0 then
        honorCap = math.floor(v + 0.5); HonorBarDB.honorCap = honorCap; UpdateBar()
        HB_Print("cap set to", honorCap)
      else
        HB_Print("usage: /honor cap <number>")
      end
    end
  elseif cmd == "auto" then
    if rest == "on" then
      autoOn = true; HonorBarDB.autoOn = true; StartAuto(); HB_Print("auto ON")
    elseif rest == "off" then
      autoOn = false; HonorBarDB.autoOn = false; StopAuto(); HB_Print("auto OFF")
    else
      HB_Print("usage: /honor auto on|off")
    end
  elseif cmd == "milestones" then
    rest = Trim(rest)
    if rest == "" then
      HB_Print("Custom milestones:", (HonorBarDB.customMilestonesEnabled and "ON" or "OFF"), "List =", HonorBarDB.customMilestonesText or "")
    elseif rest == "on" then
      HonorBarDB.customMilestonesEnabled = true
      HB_Print("Custom milestones ON")
      CreateOrUpdateCustomMilestoneTicks()
    elseif rest == "off" then
      HonorBarDB.customMilestonesEnabled = false
      HB_Print("Custom milestones OFF")
      CreateOrUpdateCustomMilestoneTicks()
    else
      HonorBarDB.customMilestonesEnabled = true
      HonorBarDB.customMilestonesText = rest
      HB_Print("Custom milestones set:", rest)
      CreateOrUpdateCustomMilestoneTicks()
    end

  elseif cmd == "resetsounds" then
    if not HonorBarDB then
      HB_Print("HonorBar: no saved variables yet; try again after the bar loads.")
    else
      local cur = (GetWeeklyHonor and GetWeeklyHonor()) or 0
      HonorBarDB.lastHonorForSounds = cur
      HB_SoundSessionInitialized = true
      HB_Print("HonorBar: sound baseline reset to current weekly honor (".. tostring(cur) ..").")
    end
  elseif cmd == "resetpos" then
    Frame:ClearAllPoints(); Frame:SetPoint("CENTER")
    HonorBarDB.point, HonorBarDB.relativePoint = "CENTER", "CENTER"
    HonorBarDB.xOfs, HonorBarDB.yOfs = 0, 0
    HB_Print("position reset")
  elseif cmd == "show" then
    ShowBar()
  elseif cmd == "hide" then
    HideBar()
  elseif cmd == "toggle" then
    ToggleBar()
  elseif cmd == "config" then
    if HB_OpenAdjustDialog then HB_OpenAdjustDialog() end

  else
    local s = HB_SuggestCommand(cmd)
    if s then
      HB_Print(string.format('Unknown subcommand "%s". Try: %s', cmd, s))
    else
      if type(HB_ToggleHelpDialog) == "function" then
        HB_ToggleHelpDialog()
      elseif type(HB_ShowHelpPopup) == "function" then
        HB_ShowHelpPopup()
      else
        HB_Print("Commands: config, debug, cap <n>, auto on|off, resetsounds, resetpos, show, hide, toggle")
      end
    end
  end
end

SLASH_HBROOT1 = "/honor"
SLASH_HBROOT2 = "/hb"
SlashCmdList["HBROOT"] = RootSlashHandler
SLASH_HBMEM1 = "/hbmem"
SlashCmdList.HBMEM = function(msg)
  msg = string.lower(msg or "")
  if msg == "" or msg == "mem" or msg == "memory" then
    HB_PrintMemory()
  else
    RootSlashHandler(msg)
  end
end

-- Initial draw
ApplyVisibility()
UpdateBar()
CreateOrUpdateTicks()

-- !honor auto-reply
local HB_ChatFrame = CreateFrame("Frame")
local HB_CHAT_EVENTS = {
  "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER",
  "CHAT_MSG_RAID", "CHAT_MSG_PARTY", "CHAT_MSG_GUILD", "CHAT_MSG_CHANNEL",
  "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}
for i=1,#HB_CHAT_EVENTS do HB_ChatFrame:RegisterEvent(HB_CHAT_EVENTS[i]) end

HB_ChatFrame:SetScript("OnEvent", function(self, event, msg, author, ...)
  if not (HonorBarDB and HonorBarDB.replyEnabled) then return end
  if type(msg) ~= "string" then return end
  local m = msg:match("^%s*!honor%s*$")
  if not m then return end

  local text = HB_BuildHonorStatusString()
  if not text or text == "" then return end

  if event == "CHAT_MSG_WHISPER" then
    SendChatMessage(text, "WHISPER", nil, author)
  elseif event == "CHAT_MSG_RAID" then
    SendChatMessage(text, "RAID")
  elseif event == "CHAT_MSG_PARTY" then
    SendChatMessage(text, "PARTY")
  elseif event == "CHAT_MSG_GUILD" then
    SendChatMessage(text, "GUILD")
  elseif event == "CHAT_MSG_SAY" then
    SendChatMessage(text, "SAY")
  elseif event == "CHAT_MSG_YELL" then
    SendChatMessage(text, "YELL")
  elseif event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER" then
    SendChatMessage(text, "INSTANCE_CHAT")
  elseif event == "CHAT_MSG_CHANNEL" then
    local _, _, _, channelName, _, _, _, _, channelNumber = ...
    if channelNumber then SendChatMessage(text, "CHANNEL", nil, channelNumber) end
  end
end)

SLASH_HONORBARREPLY1 = "/hbreply"
SlashCmdList["HONORBARREPLY"] = function(arg)
  arg = arg and arg:lower() or ""
  if arg == "on" or arg == "1" then
    HonorBarDB.replyEnabled = true
    HB_Print("!honor replies |cff00ff00ENABLED|r")
  elseif arg == "off" or arg == "0" then
    HonorBarDB.replyEnabled = false
    HB_Print("!honor replies |cffff0000DISABLED|r")
  else
    HB_Print("/hbreply on | off")
  end
end

-- Help dialog (/honor or /hb) 
local function HB_Colorize(c, s) return "|cff"..c..tostring(s).."|r" end
local hdr = function(s) return HB_Colorize("ffd200", s) end      -- gold
local cmd = function(s) return HB_Colorize("00c0ff", s) end      -- cyan
local dim = function(s) return HB_Colorize("aaaaaa", s) end      -- gray

local helpFrame

local function BuildHelpText()
  local lines = {}

  local function add(s) lines[#lines+1] = s end

  add(hdr("Slash commands:"))
  add("  " .. cmd("/honor") .. " or " .. cmd("/hb") .. "  - open this help window")
  add("  " .. cmd("/honor config") .. "        - open the Bar Config window")
  add("  " .. cmd("/honor debug") .. "         - force honor refresh & print debug info")
  add("  " .. cmd("/honor cap <number>") .. "  - set weekly honor cap (e.g. /honor cap 750000)")
  add("  " .. cmd("/honor auto on|off") .. "   - toggle 1s auto-refresh")
  add("  " .. cmd("/honor resetsounds") .. "     - reset sound baseline to current weekly honor")
  add("  " .. cmd("/honor resetpos") .. "      - reset bar position to screen center")
  add("  " .. cmd("/honor show||hide||toggle") .. " - show, hide, or toggle the bar")
  add("")

  add(hdr("!honor auto-reply:"))
  add("  " .. cmd("/hbreply on|off") .. "      - enable or disable replying to '!honor'")
  add("  When enabled, typing " .. cmd("!honor") .. " in chat replies with your weekly honor status.")
  add("")

  add(hdr("Pull timer:"))
  add("  " .. cmd("/honorpull [sec]") .. " or " .. cmd("/hbpull [sec]") .. " - start pull countdown (default 10s, range 2-30)")
  add("  " .. cmd("/cpull") .. "               - cancel the active pull timer")
  add("")

  add(hdr("Config dropdowns (in /honor config):"))
  add("  " .. cmd("Bar") .. " - bar display & behavior toggles (menu stays open):")
  for _, it in ipairs(HB_BAR_OPTIONS_DD_ITEMS) do
    add("    - " .. it.label .. ": " .. (it.desc or ""))
  end
  add("")
  add("  " .. cmd("Stats") .. " - choose what shows in the session/detached stats display:")
  for _, it in ipairs(HB_STATS_OPTIONS_DD_ITEMS) do
    add("    - " .. it.label .. ": " .. (it.desc or ""))
  end
  add("")

  add(hdr("Auto Cap / Detached Stats:"))
  add("  " .. cmd("Auto (Honor Cap)") .. "     - auto-set weekly cap from your current rank (disables manual cap)")
  add("  " .. cmd("Detach Stats") .. "         - show stats in a movable transparent detached frame")
  add("")

  add(hdr("Custom Milestones:"))
  add("  Add milestone values to draw extra milestone ticks (and optional labels/sounds).")
  add("  Separate values with commas, spaces, or semicolons. Suffix " .. cmd("K") .. " / " .. cmd("M") .. " is supported.")
  add("  Example: " .. cmd("25k, 50k, 100k, 200k, 300k") .. "  (or)  " .. cmd("75000 150000 225000"))
  add("  Custom milestones play the same notification sound protections as auto milestones when " .. cmd("Sound") .. " is enabled.")
  add("")

  add(hdr("Config sliders / numeric inputs:"))
  add("  " .. cmd("Width") .. "                - bar width in pixels")
  add("  " .. cmd("Height") .. "               - bar height in pixels")
  add("  " .. cmd("Stats Refresh (s)") .. "    - seconds between honor/stats updates")
  add("  " .. cmd("Tick Width") .. "           - thickness of tick marks")
  add("  " .. cmd("Tick Amount") .. "          - number of tick marks on the bar (0-60)")
  add("  " .. cmd("Honor Cap") .. "            - manual weekly honor cap (disabled if Auto is on)")
  add("")

  add(hdr("Config color swatches:"))
  add("  " .. cmd("Fill") .. "              - color of the bar fill")
  add("  " .. cmd("Background") .. "        - background color behind the bar")
  add("  " .. cmd("Tick") .. "              - color for normal tick marks")
  add("  " .. cmd("Milestone") .. "         - color for milestone tick marks")

  return table.concat(lines, "\n")
end

local function EnsureHelpFrame()
  if helpFrame and helpFrame:IsObjectType("Frame") then
    return helpFrame
  end

  local f = CreateFrame("Frame", "HonorBarHelpDialog", UIParent, "BasicFrameTemplateWithInset")
  helpFrame = f

  f:SetSize(520, 420)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)

  if UISpecialFrames then
    table.insert(UISpecialFrames, f:GetName())
  end

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("LEFT", f.TitleBg or f, "LEFT", 10, 0)
  title:SetText("Honor Bar Help")

  -- Scroll frame
  local scroll = CreateFrame("ScrollFrame", "HonorBarHelpScrollFrame", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 10)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)

  local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT")
  text:SetWidth(480)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")

  local helpText = BuildHelpText()
  text:SetText(helpText)

  content:SetHeight(text:GetStringHeight() + 20)

  f.scroll = scroll
  f.content = content
  f.text = text

  f:Hide()

  return f
end

function HB_ShowHelpPopup()
  local f = EnsureHelpFrame()
  if f then
    f:Show()
    if f.scroll then
      f.scroll:SetVerticalScroll(0)
    end
  end
end

function HB_ToggleHelpDialog()
  local f = EnsureHelpFrame()
  if not f then return end
  if f:IsShown() then
    f:Hide()
  else
    HB_ShowHelpPopup()
  end
end

-- Pull timer (/honorpull, /hbpull, /cpull)
local pullTicker

-- Fallback for LE_PARTY_CATEGORY_INSTANCE
local LE_PARTY_CATEGORY_INSTANCE_SAFE = _G.LE_PARTY_CATEGORY_INSTANCE or 2 -- 2 is instance in retail; nil is OK too
local remaining = 0

local function IsRaidOfficer()
  return IsInRaid() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
end

local function OutChannel()
  if IsRaidOfficer() then
    return "RAID_WARNING"
  end
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE_SAFE) then
    return "INSTANCE_CHAT"
  end
  return "YELL"
end

local function Announce(msg)
  local chan = OutChannel()
  SendChatMessage(msg, chan)
end

local function CancelPull(silent)
  if pullTicker then
    pullTicker:Cancel()
    pullTicker = nil
  end
  remaining = 0
  if not silent then
    Announce("Pull cancelled.")
  end
end

local function StartPull(seconds)
  seconds = tonumber(seconds) or 10
  if seconds < 2 then seconds = 2 end
  if seconds > 30 then seconds = 30 end

  remaining = math.floor(seconds)
  Announce(string.format("Pull in %d…", remaining))

  if pullTicker then pullTicker:Cancel() end
  pullTicker = C_Timer.NewTicker(1, function()
    remaining = remaining - 1
    if remaining > 0 then
      if remaining <= 5 or remaining % 5 == 0 then
        Announce(tostring(remaining) .. "…")
      end
    else
      Announce("PULL!")
      CancelPull(true)
    end
  end, seconds)
end

-- Slash commands: /honorpull and /hbpull
SLASH_HONORPULL1 = "/honorpull"
SLASH_HONORPULL2 = "/hbpull"

SlashCmdList["HONORPULL"] = function(msg)
  msg = msg and msg:match("^(%d+)$")
  if msg == "0" then
    CancelPull(false)
    return
  end
  if pullTicker then
    CancelPull(true)
  end
  StartPull(msg)
end

-- Cancel command
SLASH_PULLCANCEL1 = "/cpull"
SlashCmdList["PULLCANCEL"] = function()
  CancelPull(false)
end