-- HonorProgress
-- Version: v2.11i
-- Classic Era 11505
-- Hotfix: removed lingering Python 'elif' in slash handler; Lua now uses 'elseif' everywhere.

local addonName = ...

-- ===== Database selection / migration =====
-- We keep backward compatibility with HonorProgressDB (old addon),
-- but if it doesn't exist we fall back to a new HonorBarDB table.
if type(HonorProgressDB) ~= "table" and type(HonorBarDB) == "table" then
  -- No old DB, but new-style DB exists (HonorBarDB): reuse it.
  HonorProgressDB = HonorBarDB
elseif type(HonorProgressDB) == "table" and type(HonorBarDB) ~= "table" then
  -- Old DB exists, no new-style DB yet: mirror it for HonorBarDB.
  HonorBarDB = HonorProgressDB
elseif type(HonorProgressDB) ~= "table" and type(HonorBarDB) ~= "table" then
  -- First-time install: create a new DB and alias both names to it.
  HonorBarDB = {}
  HonorProgressDB = HonorBarDB
end

-- Safety net: ensure we always have a table to work with.
if type(HonorProgressDB) ~= "table" then
  HonorProgressDB = {}
  HonorBarDB = HonorProgressDB
end

-- replyEnabled defaults to ON unless explicitly set to false.
HonorProgressDB.replyEnabled = (HonorProgressDB.replyEnabled ~= false)


local function HP_Print(...)
  print("|cff00aaffHonor Bar|r:", ...)
end


function HP_PrintMemory()
  if not UpdateAddOnMemoryUsage or not GetAddOnMemoryUsage then
    HP_Print("Memory API not available")
    return
  end
  UpdateAddOnMemoryUsage()
  local name = addonName or "HonorBar"
  local kb = GetAddOnMemoryUsage(name)
  if type(kb) == "number" then
    HP_Print(string.format("Memory: %.1f KB", kb))
  else
    HP_Print("Memory: unknown (addon not found)")
  end
end




-- Per-character key helper ("Name-Realm")
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

-- ===== Defaults & state =====
local function ApplyDefaults()
  if HonorProgressDB.honorCap == nil then HonorProgressDB.honorCap = 500000 end
  if HonorProgressDB.autoOn == nil then HonorProgressDB.autoOn = true end
  if HonorProgressDB.showTicks == nil then HonorProgressDB.showTicks = true end
  if HonorProgressDB.tickOpacity == nil then HonorProgressDB.tickOpacity = 0.25 end
  if HonorProgressDB.milestoneOpacity == nil then HonorProgressDB.milestoneOpacity = HonorProgressDB.tickOpacity or 0.25 end
  if HonorProgressDB.statsRefresh == nil then HonorProgressDB.statsRefresh = 1.0 end
  if HonorProgressDB.tickWidth == nil then HonorProgressDB.tickWidth = 1 end
  if HonorProgressDB.hideTicks == nil then HonorProgressDB.hideTicks = false end
  if HonorProgressDB.hiddenBar == nil then HonorProgressDB.hiddenBar = false end
  if not HonorProgressDB.barColor then HonorProgressDB.barColor = { r = 0.15, g = 0.55, b = 0.95, a = 1 } end
  if HonorProgressDB.hideBarText == nil then HonorProgressDB.hideBarText = false end
  if HonorProgressDB.onlyNumbers == nil then HonorProgressDB.onlyNumbers = false end
  if not HonorProgressDB.tickRGB then HonorProgressDB.tickRGB = { r = 1, g = 1, b = 1 } end
  if not HonorProgressDB.milestoneRGB then HonorProgressDB.milestoneRGB = { r = 1, g = 0.82, b = 0 } end
  if HonorProgressDB.milestoneLabelsBottom == nil then HonorProgressDB.milestoneLabelsBottom = false end

  if HonorProgressDB.tickCount == nil then HonorProgressDB.tickCount = 19 end
  if HonorProgressDB.showText == nil then HonorProgressDB.showText = true end
  if HonorProgressDB.visible == nil then HonorProgressDB.visible = true end
  if HonorProgressDB.detachStats == nil then HonorProgressDB.detachStats = false end
  if HonorProgressDB.currentGameHonor == nil then HonorProgressDB.currentGameHonor = 0 end
  if HonorProgressDB.currentGameHK == nil then HonorProgressDB.currentGameHK = 0 end
  if HonorProgressDB.currentGameKB == nil then HonorProgressDB.currentGameKB = 0 end
  if HonorProgressDB.lastGameHonor == nil then HonorProgressDB.lastGameHonor = 0 end
  if HonorProgressDB.lastGameHK == nil then HonorProgressDB.lastGameHK = 0 end
  if HonorProgressDB.lastGameKB == nil then HonorProgressDB.lastGameKB = 0 end


  -- Auto honor cap and milestone settings
  if HonorProgressDB.autoCapFromRank == nil then HonorProgressDB.autoCapFromRank = false end
  if HonorProgressDB.autoCapSteps == nil then HonorProgressDB.autoCapSteps = 4 end

  -- Per-character final congrats flags (by "Name-Realm")
  if HonorProgressDB.finalCongratsByChar == nil then HonorProgressDB.finalCongratsByChar = {} end

  if not HonorProgressDB.width then HonorProgressDB.width = 300 end
  if not HonorProgressDB.height then HonorProgressDB.height = 30 end
end
ApplyDefaults()

local honorCap = HonorProgressDB.honorCap
local autoOn   = HonorProgressDB.autoOn
local congratsRankChecksRemaining = 5
local color    = HonorProgressDB.barColor

-- ===== Automatic honor cap & rank milestones =====
-- ===== Embedded Rank math for accurate weekly projections =====
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

local dataBrokerMilestones = {}

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
      -- The CP awarded for each bucket is calculated by multiplying the available CP with a change factor
      gainedCP = ((contributionPointsFloor[key] - contributionPointsFloor[key - 1]) * rankChangeFactor[key])
    end
    if key == rank + 1 then
      -- Two ranks ignore the change factor and this new ceiling since the changes introduced as of September 12 (to prevent gaming the system through DKs)
      if rank == 9 then
        gainedCP = 3000
      elseif rank == 11 then
        gainedCP = 2500
      end
      -- The CP awarded in the first bucket is now the minimum of 3000 (for rank 9), 2500 (for rank 11), the gainedCP in the bucket multiplied with the change factor (original Blizzard post), or the gainedCPwithCeiling based on current rank progress to prevent gaming the system through DKs
      gainedCPwithCeiling = ((contributionPointsFloor[key] - contributionPointsFloor[key - 1]) * (1 - ((currentCP - contributionPointsFloor[key - 1]) / (contributionPointsFloor[key] - contributionPointsFloor[key - 1]))))
      if gainedCPwithCeiling < gainedCP then gainedCP = gainedCPwithCeiling end
      -- Bonus CP is awarded in certain cases, if the current rank is between 6 and 10, with the September 12 changes (to prevent gaming the system through DKs)
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

  -- If auto-cap is disabled, respect the manually set honorCap.
  if not HonorProgressDB.autoCapFromRank then
    honorCap = HonorProgressDB.honorCap or honorCap or 500000
    return
  end

  -- Mirror Rank's own prediction inputs: weekly honor, rank, and rank progress.
  local honor = weeklyHonor or 0

  -- Optionally ignore current weekly honor when modeling, if the user prefers.
  if HonorProgressDB.useCurrentHonorWhenModeling == false then
    honor = 0
  end

  -- Current rank progress (0.0–1.0), floored to Rank's precision.
  local progress = 0
  if GetPVPRankProgress then
    local ok, val = pcall(GetPVPRankProgress)
    if ok and type(val) == "number" then
      progress = math.floor(val * 10000000000) / 10000000000
    end
  end

  -- Current rank number
  local rank = 0
  if UnitPVPRank and GetPVPRankInfo then
    local pvpRank = UnitPVPRank("player")
    if pvpRank then
      local _, r = GetPVPRankInfo(pvpRank)
      rank = r or 0
    end
  end

  -- If we have no visible PvP rank yet (fresh character), treat it as Rank 1 with 0% progress
  -- so that Rank can still provide useful milestones and an auto honor cap.
  if rank <= 0 then
    rank     = 1
    progress = 0
  end

  -- Ask the embedded Rank logic for all candidate scenarios from our current state.
  local options = HB_Rank:RankVariance(rank, honor or 0, progress or 0)
  if not options or #options == 0 then
    honorCap = HonorProgressDB.honorCap or honorCap or 500000
    return
  end

  -- Replicate Rank's tooltip milestone filtering:
  --   * Only milestones with honorNeed > current honor
  --   * Only milestones up to the configured objective rank
  --   * Skip "+1" situations (Rank treats these differently)
  --   * Stop listing milestones once maxObtainableRank is reached
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

  -- If Rank's milestone filter yields nothing (e.g. already at/above objective),
  -- fall back to a simple "max honorNeed" cap using all options.
  if #filtered == 0 then
    local maxHonor = 0
    for _, opt in ipairs(options) do
      if opt.honorNeed and opt.honorNeed > maxHonor then
        maxHonor = opt.honorNeed
      end
    end

    if maxHonor <= 0 then
      honorCap = HonorProgressDB.honorCap or honorCap or 500000
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
    -- Use only the filtered milestones when setting cap and drawing ticks.
    local maxHonor = 0
    for _, line in ipairs(filtered) do
      if line.honorNeed and line.honorNeed > maxHonor then
        maxHonor = line.honorNeed
      end
    end

    if maxHonor <= 0 then
      honorCap = HonorProgressDB.honorCap or honorCap or 500000
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

  -- Sort milestones by honor so ticks appear left-to-right in increasing order.
  table.sort(rankMilestones, function(a, b)
    return (a.honor or 0) < (b.honor or 0)
  end)
end


local Frame = CreateFrame("Frame", "HonorProgressFrame", UIParent)
Frame:SetSize(HonorProgressDB.width or 300, HonorProgressDB.height or 30)
if HonorProgressDB and HonorProgressDB.hiddenBar then Frame:Hide() end
Frame:SetFrameStrata("HIGH")
Frame:SetMovable(true)
Frame:EnableMouse(true)
Frame:SetClampedToScreen(true)

-- Restore saved position (or center)
if HonorProgressDB.point and HonorProgressDB.relativePoint and HonorProgressDB.xOfs and HonorProgressDB.yOfs then
  Frame:ClearAllPoints()
  Frame:SetPoint(HonorProgressDB.point, UIParent, HonorProgressDB.relativePoint, HonorProgressDB.xOfs, HonorProgressDB.yOfs)
else
  Frame:SetPoint("CENTER")
end


-- Background
local bg = Frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(true)
bg:SetColorTexture(0, 0, 0, 0.45)

-- Status bar
local bar = CreateFrame("StatusBar", nil, Frame)
bar:SetPoint("TOPLEFT")
bar:SetPoint("BOTTOMRIGHT")
bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
bar:GetStatusBarTexture():SetHorizTile(false)
bar:SetStatusBarColor(color.r, color.g, color.b, color.a)
bar:SetFrameLevel(Frame:GetFrameLevel() + 1)

-- Tick overlay (5% markers)
local TickOverlay = CreateFrame("Frame", nil, Frame)
TickOverlay:SetAllPoints(Frame)
TickOverlay:SetFrameStrata("HIGH")
TickOverlay:SetFrameLevel(Frame:GetFrameLevel() + 50)

-- Milestone ticks (rank-based) drawn on a separate layer



local milestoneTicks = {}

local function CreateOrUpdateMilestoneTicks()
  if not HonorProgressDB then return end

  -- Hide milestone ticks if ticks are hidden or not shown
  if HonorProgressDB.hideTicks or not HonorProgressDB.showTicks then
    for i = 1, #milestoneTicks do
      local t = milestoneTicks[i]
      if t then
        t:Hide()
        if t.label then t.label:Hide() end
      end
    end
    return
  end

  -- Only draw milestones in auto-cap mode when we have milestone data
  if not (HonorProgressDB.autoCapFromRank and rankMilestones and #rankMilestones > 0) then
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
  local alpha = tonumber(HonorProgressDB.milestoneOpacity or HonorProgressDB.tickOpacity) or 0.25
  local width = tonumber(HonorProgressDB.tickWidth) or 1
  if width < 1 then width = 1 elseif width > 3 then width = 3 end
  if alpha < 0.05 then alpha = 0.05 elseif alpha > 0.8 then alpha = 0.8 end

  local cap = (honorCap and honorCap > 0) and honorCap or 1

  for i, m in ipairs(rankMilestones) do
    local t = milestoneTicks[i]
    if not t then
      t = TickOverlay:CreateTexture(nil, "OVERLAY")
      milestoneTicks[i] = t
    end

    t:ClearAllPoints()
    local mc = HonorProgressDB.milestoneRGB or { r = 1, g = 0.82, b = 0 }

    -- Milestone ticks: use a dedicated milestone color (configurable in Bar Config)

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
    if not lbl then
      lbl = TickOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      t.label = lbl
    end
    lbl:ClearAllPoints()
    if HonorProgressDB.milestoneLabelsBottom then
      lbl:SetPoint("TOP", t, "BOTTOM", 0, -2)
    else
      lbl:SetPoint("BOTTOM", t, "TOP", 0, 2)
    end

    -- Show rank and percent toward the next rank, e.g. "R13-68"
    local pct = m.rankProgressMax or m.rankProgressMin or m.rankProgress

    if type(pct) == "number" and pct > 0 then
      pct = math.floor(pct * 100 + 0.5)
      lbl:SetText(string.format("R%d-%d", m.rank or 0, pct))
    else
      lbl:SetText(string.format("R%d", m.rank or 0))
    end

    lbl:Show()
  end

  -- Hide any leftover milestone ticks
  for i = #rankMilestones + 1, #milestoneTicks do
    local t = milestoneTicks[i]
    if t then
      t:Hide()
      if t.label then t.label:Hide() end
    end
  end
end

local ticks = {}

local function CreateOrUpdateTicks()
  if HonorProgressDB and HonorProgressDB.hideTicks then
    if ticks then
      for i = 1, #ticks do
        if ticks[i] then ticks[i]:Hide() end
      end
    end
    -- Also hide milestone ticks
    CreateOrUpdateMilestoneTicks()
    return
  end
  if not HonorProgressDB.showTicks then
    for i = 1, #ticks do
      if ticks[i] then ticks[i]:Hide() end
    end
    CreateOrUpdateMilestoneTicks()
    return
  end

  local w = Frame:GetWidth() or 300
  local alpha = tonumber(HonorProgressDB.tickOpacity) or 0.25
  local width = tonumber(HonorProgressDB.tickWidth) or 1
  if width < 1 then width = 1 elseif width > 3 then width = 3 end
  if alpha < 0.05 then alpha = 0.05 elseif alpha > 0.8 then alpha = 0.8 end
  local count = tonumber(HonorProgressDB.tickCount) or 19
  if count < 0 then count = 0 elseif count > 60 then count = 60 end

  for i = 1, count do
    local t = ticks[i]
    if not t then
      t = TickOverlay:CreateTexture(nil, "OVERLAY")
      ticks[i] = t
    end
    t:ClearAllPoints()
    local tc = HonorProgressDB.tickRGB or { r = 1, g = 1, b = 1 }
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

  -- Also draw milestone ticks if any
  CreateOrUpdateMilestoneTicks()
end

-- ===== Adjust Bar dialog =====
local HP_AdjustDlg
local function HP_SetSizeAndSave(w, h)
  w = math.max(100, math.min(1000, math.floor((w or Frame:GetWidth() or 300)+0.5)))
  h = math.max(10,  math.min(100,  math.floor((h or Frame:GetHeight() or 22)+0.5)))
  HonorProgressDB.width, HonorProgressDB.height = w, h
  Frame:SetSize(w, h)
  CreateOrUpdateTicks()
end

local function HP_UpdateTickCountLabel()
  local c = tonumber(HonorProgressDB.tickCount) or 19
  if c < 1 then c = 1 end
  local pct = 100 / (c + 1)
  if HP_Adjust_TCountText then HP_Adjust_TCountText:SetText(string.format("Tick Amount: %d (%.2f%% per tick)", c, pct)) end
end

local function HP_OpenAdjustDialog()
  if HP_AdjustDlg and HP_AdjustDlg:IsShown() then return end
  if not HP_AdjustDlg then
    HP_AdjustDlg = CreateFrame("Frame", "HonorProgressAdjustDlg", UIParent, "BackdropTemplate")
    if UISpecialFrames then table.insert(UISpecialFrames, "HonorProgressAdjustDlg") end
    HP_AdjustDlg:SetSize(380, 300)
    HP_AdjustDlg:SetPoint("CENTER")
    HP_AdjustDlg:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                               edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                               tile = true, tileSize = 32, edgeSize = 32,
                               insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    HP_AdjustDlg:EnableMouse(true)
    HP_AdjustDlg:SetMovable(true)
    HP_AdjustDlg:RegisterForDrag("LeftButton")
    HP_AdjustDlg:SetScript("OnDragStart", function(self) self:StartMoving() end)
    HP_AdjustDlg:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = HP_AdjustDlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Bar Config")

    -- Detach Stats checkbox aligned with the Bar Config title (left side)
    local detachStatsCB = CreateFrame("CheckButton", "HP_Adjust_DetachStats", HP_AdjustDlg, "UICheckButtonTemplate")
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
    detachStatsCB:SetChecked(HonorProgressDB.detachStats == true)
    detachStatsCB:SetScript("OnClick", function(self)
      HonorProgressDB.detachStats = self:GetChecked() and true or false
      if HonorProgressDB.detachStats then
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

    -- Help button aligned with the Bar Config title
    local helpBtn = CreateFrame("Button", "HP_Adjust_HelpButton", HP_AdjustDlg, "UIPanelButtonTemplate")
    helpBtn:SetSize(60, 20)
    helpBtn:SetText("Help")
    helpBtn:SetPoint("LEFT", title, "RIGHT", 12, 0)
    helpBtn:SetScript("OnClick", function()
      if type(HP_ToggleHelpDialog) == "function" then
        HP_ToggleHelpDialog()
      elseif type(HP_ShowHelpPopup) == "function" then
        HP_ShowHelpPopup()
      elseif type(PrintHelp) == "function" then
        PrintHelp()
      end
    end)

    -- Center: Hide Bar Text
    local hideTextCB = CreateFrame("CheckButton", "HP_Adjust_HideText", HP_AdjustDlg, "UICheckButtonTemplate")
    hideTextCB:SetSize(18, 18)
    hideTextCB:SetPoint("TOP", HP_AdjustDlg, "TOP", 0, -270)
    _G[hideTextCB:GetName().."Text"]:SetText("Hide Bar Text")
    
    local hideTextLabel = _G[hideTextCB:GetName().."Text"]
    hideTextLabel:ClearAllPoints()
    hideTextLabel:SetPoint("BOTTOM", hideTextCB, "TOP", 0, 0)
    hideTextLabel:SetJustifyH("CENTER")
hideTextCB:SetChecked(HonorProgressDB.hideBarText or false)
    hideTextCB:SetScript("OnClick", function(self)
      HonorProgressDB.hideBarText = self:GetChecked() and true or false
      if UpdateBar then UpdateBar() end
    end)

-- New: "Only Numbers" checkbox (between Hide Bar Text and Hide Bar)
local onlyNumbersCB = CreateFrame("CheckButton", "HP_Adjust_OnlyNumbers", HP_AdjustDlg, "UICheckButtonTemplate")
    onlyNumbersCB:SetSize(18, 18)
onlyNumbersCB:SetPoint("TOP", HP_AdjustDlg, "TOP", -100, -302)
_G[onlyNumbersCB:GetName().."Text"]:SetText("Only Numbers")

local onlyNumbersLabel = _G[onlyNumbersCB:GetName().."Text"]
if onlyNumbersLabel then
  onlyNumbersLabel:ClearAllPoints()
  onlyNumbersLabel:SetPoint("BOTTOM", onlyNumbersCB, "TOP", 0, 0)
  onlyNumbersLabel:SetJustifyH("CENTER")
end
onlyNumbersCB:SetChecked(HonorProgressDB.onlyNumbers or false)
onlyNumbersCB:SetScript("OnClick", function(self)
  HonorProgressDB.onlyNumbers = self:GetChecked() and true or false
  if UpdateBar then UpdateBar() end
end)

-- New: "Bar Labels Bottom" checkbox (center second row)
local labelsBottomCB = CreateFrame("CheckButton", "HP_Adjust_LabelsBottom", HP_AdjustDlg, "UICheckButtonTemplate")
labelsBottomCB:SetSize(18, 18)
labelsBottomCB:SetPoint("TOP", HP_AdjustDlg, "TOP", 0, -302)
_G[labelsBottomCB:GetName().."Text"]:SetText("Bar Labels Bottom")

local labelsBottomLabel = _G[labelsBottomCB:GetName().."Text"]
if labelsBottomLabel then
  labelsBottomLabel:ClearAllPoints()
  labelsBottomLabel:SetPoint("BOTTOM", labelsBottomCB, "TOP", 0, 0)
  labelsBottomLabel:SetJustifyH("CENTER")
end
labelsBottomCB:SetChecked(HonorProgressDB.milestoneLabelsBottom or false)
labelsBottomCB:SetScript("OnClick", function(self)
  HonorProgressDB.milestoneLabelsBottom = self:GetChecked() and true or false
  CreateOrUpdateMilestoneTicks()
end)

-- Top-left: Hide Bar
    local hideBarCB = CreateFrame("CheckButton", "HP_Adjust_HideBar", HP_AdjustDlg, "UICheckButtonTemplate")
    hideBarCB:SetSize(18, 18)
    hideBarCB:SetPoint("TOP", HP_AdjustDlg, "TOP", -100, -270)
    _G[hideBarCB:GetName().."Text"]:SetText("Hide Bar")
    local hideBarLabel = _G[hideBarCB:GetName().."Text"]
    if hideBarLabel then
      hideBarLabel:ClearAllPoints()
      hideBarLabel:SetPoint("BOTTOM", hideBarCB, "TOP", 0, 0)
      hideBarLabel:SetJustifyH("CENTER")
    end
    hideBarCB:SetChecked(HonorProgressDB.hiddenBar or false)
    hideBarCB:SetScript("OnClick", function(self)
      HonorProgressDB.hiddenBar = self:GetChecked() and true or false
      ApplyVisibility()
    end)

    -- Top-right: Hide Ticks (+ label to the left of the box)
    local hideTicksCB = CreateFrame("CheckButton", "HP_Adjust_HideTicks", HP_AdjustDlg, "UICheckButtonTemplate")
    hideTicksCB:SetSize(18, 18)
    hideTicksCB:SetPoint("TOP", HP_AdjustDlg, "TOP", 100, -270)
    _G[hideTicksCB:GetName().."Text"]:SetText("Hide Ticks")
    local hideTicksText = _G[hideTicksCB:GetName().."Text"]
    if hideTicksText then
      hideTicksText:ClearAllPoints()
      hideTicksText:SetPoint("BOTTOM", hideTicksCB, "TOP", 0, 0)
      hideTicksText:SetJustifyH("CENTER")
    end
    hideTicksCB:SetChecked(HonorProgressDB.hideTicks or false)
    hideTicksCB:SetScript("OnClick", function(self)
      HonorProgressDB.hideTicks = self:GetChecked() and true or false
      CreateOrUpdateTicks()
    end)

    
-- Normalize checkbox sizes to match the !honor checkbox
local function HP_MatchCheckboxSizes()
  local function apply(cb)
    if not cb then return end
    -- Match Honor Cap label style: no downscale, small UI font
    if cb.SetScale then cb:SetScale(1.0) end
    local label = (_G[cb:GetName().."Text"] or cb.Text)
    if label and label.SetFontObject then
      label:SetFontObject(GameFontNormalSmall)
    end
  end
  apply(HP_Adjust_HideBar)
  apply(HP_Adjust_HideText)
  if _G.HP_Adjust_OnlyNumbers then apply(_G.HP_Adjust_OnlyNumbers) end
  if _G.HP_Adjust_LabelsBottom then apply(_G.HP_Adjust_LabelsBottom) end
  apply(HP_Adjust_HideTicks)
  if _G.HP_Adjust_EnableHonor then apply(_G.HP_Adjust_EnableHonor) end
  if _G.HP_Adjust_DetachStats then apply(_G.HP_Adjust_DetachStats) end
end
HP_MatchCheckboxSizes()
-- Middle-top: Enable !honor replies
    local honorReplyCB = CreateFrame("CheckButton", "HP_Adjust_EnableHonor", HP_AdjustDlg, "UICheckButtonTemplate")
    honorReplyCB:SetSize(18, 18)
    honorReplyCB:SetScale(1.0)
    honorReplyCB:SetPoint("TOP", HP_AdjustDlg, "TOP", 100, -302)
    _G[honorReplyCB:GetName().."Text"]:SetText("Enable !honor")
    do
      local honorLabel = _G[honorReplyCB:GetName().."Text"] or honorReplyCB.Text
      if honorLabel then
        honorLabel:ClearAllPoints()
        honorLabel:SetPoint("BOTTOM", honorReplyCB, "TOP", 0, 0)
        honorLabel:SetJustifyH("CENTER")
        if honorLabel.SetFontObject then
          honorLabel:SetFontObject(GameFontNormalSmall)
        end
      end
    end
    honorReplyCB:SetChecked(HonorProgressDB.replyEnabled ~= false)
    honorReplyCB:SetScript("OnClick", function(self)
      HonorProgressDB.replyEnabled = self:GetChecked() and true or false
    end)
    


-- Re-anchor checkboxes into a single horizontal row (replaced by two-row layout)

    -- Helpers
    local function MakeSlider(name, label, minV, maxV, step, getter, setter, x, y)
      local s = CreateFrame("Slider", name, HP_AdjustDlg, "OptionsSliderTemplate")
      s:SetWidth(120); s:SetMinMaxValues(minV, maxV); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
      s:SetPoint("TOP", HP_AdjustDlg, "TOP", x, y)
      _G[name.."Low"]:SetText(tostring(minV)); _G[name.."High"]:SetText(tostring(maxV)); _G[name.."Text"]:SetText(label)
      -- Make the slider label slightly smaller than default
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
      s:SetScript("OnValueChanged", function(self, v) setter(v); if name == "HP_Adjust_TCount" then HP_UpdateTickCountLabel() end end)
      s:SetValue(getter())
      return s
    end

    local function MakeEditBox(name, x, y, getV, setV, linkSlider)
      local e = CreateFrame("EditBox", name, HP_AdjustDlg, "InputBoxTemplate")
      e:SetSize(60, 20); e:SetAutoFocus(false); e:SetPoint("TOP", HP_AdjustDlg, "TOP", x, y); e:SetNumeric(true)
      e:SetScript("OnEnterPressed", function(self) local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end; self:ClearFocus() end)
      e:SetScript("OnEditFocusLost", function(self) local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end end)
      e:SetScript("OnTextChanged", function(self) if not self:HasFocus() then return end; local v = tonumber(self:GetText() or ""); if v then setV(v); if linkSlider then linkSlider:SetValue(v) end end end)
      e:SetText(tostring(getV()))
      return e
    end

    -- Shared color picker helpers so bar and tick swatches don't step on each other
    local HP_CP_CurrentSetter = nil
    local HP_CP_RefreshFunc   = nil

    local function HP_ColorPicker_OnColorChanged()
      if not HP_CP_CurrentSetter then return end
      local r, g, b = ColorPickerFrame:GetColorRGB()
      local a = 1
      if ColorPickerFrame.hasOpacity and OpacitySliderFrame then
        a = 1 - (OpacitySliderFrame:GetValue() or 0)
      end
      HP_CP_CurrentSetter({ r = r or 1, g = g or 1, b = b or 1, a = a or 1 })
      if HP_CP_RefreshFunc then HP_CP_RefreshFunc() end
    end

    local function HP_ColorPicker_OnColorCanceled(prev)
      if not HP_CP_CurrentSetter or not prev then return end
      local r, g, b, a = prev[1], prev[2], prev[3], prev[4]
      HP_CP_CurrentSetter({ r = r or 1, g = g or 1, b = b or 1, a = a or 1 })
      if HP_CP_RefreshFunc then HP_CP_RefreshFunc() end
    end

    local function MakeColorSwatch(name, label, x, y, getter, setter)
      local btn = CreateFrame("Button", name, HP_AdjustDlg, "UIPanelButtonTemplate")
      btn:SetSize(100, 20)
      btn:SetPoint("TOP", HP_AdjustDlg, "TOP", x, y)
      btn:SetText(label)
      -- Hide UIPanelButtonTemplate pieces so only our color fill shows
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
        -- Wrap the provided setter so it also refreshes this swatch
        HP_CP_CurrentSetter = function(tbl)
          setter(tbl)
        end
        HP_CP_RefreshFunc = refresh

        CloseMenus()
        local r = base.r or 1
        local g = base.g or 1
        local b = base.b or 1
        local a = base.a or 1
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame.hasOpacity = true
        ColorPickerFrame.opacity = 1 - a
        ColorPickerFrame.previousValues = { r, g, b, a }
        -- Classic-era frames may call swatchFunc instead of func; wire all.
        ColorPickerFrame.func        = HP_ColorPicker_OnColorChanged
        ColorPickerFrame.opacityFunc = HP_ColorPicker_OnColorChanged
        ColorPickerFrame.swatchFunc  = HP_ColorPicker_OnColorChanged
        ColorPickerFrame.cancelFunc  = HP_ColorPicker_OnColorCanceled
        ColorPickerFrame:Hide(); ColorPickerFrame:Show()
      end)

      return btn
    end
    local function setCap(v) v = math.floor(tonumber(v) or 0); if v < 0 then v = 0 end; HonorProgressDB.honorCap = v; honorCap = v; if UpdateBar then UpdateBar() end end

    -- Two-column controls
    -- Getters/Setters for controls
    local function getW() return HonorProgressDB.width or (Frame and Frame:GetWidth() or 300) end
    local function setW(v) HP_SetSizeAndSave(v, HonorProgressDB.height or (Frame and Frame:GetHeight() or 22)) end
    local function getH() return HonorProgressDB.height or (Frame and Frame:GetHeight() or 22) end
    local function setH(v) HP_SetSizeAndSave(HonorProgressDB.width or (Frame and Frame:GetWidth() or 300), v) end
    
    local function getRefresh()
      return HonorProgressDB.statsRefresh or 1.0
    end
    local function setRefresh(v)
      v = tonumber(v) or 1.0
      if v < 0.2 then
        v = 0.2
      elseif v > 2.0 then
        v = 2.0
      end
      HonorProgressDB.statsRefresh = tonumber(string.format("%.1f", v))
      if autoOn then
        if StopAuto then StopAuto() end
        if StartAuto then StartAuto() end
      end
    end
    local function getTW() return HonorProgressDB.tickWidth or 1 end
    local function setTW(v) HonorProgressDB.tickWidth = tonumber(string.format("%.1f", v or 0)); CreateOrUpdateTicks() end
    local function getTCount() return HonorProgressDB.tickCount or 19 end
    local function setTCount(v) HonorProgressDB.tickCount = math.floor((tonumber(v) or 0)+0.5); CreateOrUpdateTicks() end
    local function getCap() return HonorProgressDB.honorCap or honorCap or 500000 end
    local function setCap(v) v = math.floor(tonumber(v) or 0); if v < 0 then v = 0 end; HonorProgressDB.honorCap = v; honorCap = v; if UpdateBar then UpdateBar() end end

    local widthSlider  = MakeSlider("HP_Adjust_Width",  "Width",        100, 1000, 10, getW,  setW,  -90, -46)
    local heightSlider = MakeSlider("HP_Adjust_Height", "Height",        10,  100,  1, getH,  setH,  -90, -106)
    MakeSlider("HP_Adjust_TOp",    "Stats Refresh (s)", 0.2, 2.0, 0.2, getRefresh, setRefresh,  90, -46)
    MakeSlider("HP_Adjust_TW",     "Tick Width",     0.5,   3,  0.1, getTW, setTW,   90, -106)
    MakeSlider("HP_Adjust_TCount", "Tick Amount",     0,    60,  1,  getTCount, setTCount, 90, -166)
    HP_UpdateTickCountLabel()

    local widthBox  = MakeEditBox("HP_Adjust_WidthBox",  -90, -64,  getW, setW, widthSlider)
    local heightBox = MakeEditBox("HP_Adjust_HeightBox", -90, -124, getH, setH, heightSlider)
    local capLabel = HP_AdjustDlg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    capLabel:SetPoint("TOP", HP_AdjustDlg, "TOP", -90, -166); capLabel:SetText("Honor Cap")
    local capBox   = MakeEditBox("HP_Adjust_CapBox", -90, -184, getCap, setCap, nil); capBox:SetNumeric(true)

    -- Auto honor cap checkbox next to Honor Cap
    local autoCapCB = CreateFrame("CheckButton", "HP_Adjust_AutoCap", HP_AdjustDlg, "UICheckButtonTemplate")
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
      if HonorProgressDB.autoCapFromRank then
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
      HonorProgressDB.autoCapFromRank = self:GetChecked() and true or false
      if HonorProgressDB.autoCapFromRank then
        UpdateAutoCapFromRank()
      else
        honorCap = HonorProgressDB.honorCap or honorCap or 500000
      end
      RefreshCapControls()
      if UpdateBar then UpdateBar() end
    end)

    RefreshCapControls()

    local tcountBox = MakeEditBox("HP_Adjust_TCountBox",  90, -184, getTCount, setTCount, HP_Adjust_TCount); tcountBox:SetNumeric(true)

    -- Slider -> box sync
    if HP_Adjust_Width and widthBox then HP_Adjust_Width:HookScript("OnValueChanged", function(self, v) if not widthBox:HasFocus() then widthBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end
    if HP_Adjust_Height and heightBox then HP_Adjust_Height:HookScript("OnValueChanged", function(self, v) if not heightBox:HasFocus() then heightBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end
    if HP_Adjust_TCount and tcountBox then HP_Adjust_TCount:HookScript("OnValueChanged", function(self, v) if not tcountBox:HasFocus() then tcountBox:SetText(tostring(math.floor((v or 0)+0.5))) end end) end

    -- Color swatches bottom left/right
    local function getBarColor()
      return HonorProgressDB.barColor or { r = 0.15, g = 0.55, b = 0.95, a = 1 }
    end
    local function setBarColor(tbl)
      if not tbl then return end
      HonorProgressDB.barColor = tbl
      color = tbl
      if UpdateBar then
        UpdateBar()
      end
    end
    local function getTickRGB()
      local c = HonorProgressDB.tickRGB or { r = 1, g = 1, b = 1, a = HonorProgressDB.tickOpacity or 0.25 }
      local a = HonorProgressDB.tickOpacity
      if not a or a <= 0 then
        a = c.a or 0.25
      end
      return { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = a }
    end
    local function setTickRGB(tbl)
      if not tbl then return end
      local a = tbl.a
      if not a or a <= 0 then
        a = HonorProgressDB.tickOpacity or 0.25
      end
      HonorProgressDB.tickOpacity = a
      HonorProgressDB.tickRGB = { r = tbl.r or 1, g = tbl.g or 1, b = tbl.b or 1, a = a }
      CreateOrUpdateTicks()
    end
    local function getMilestoneRGB()
      local c = HonorProgressDB.milestoneRGB or { r = 1, g = 0.82, b = 0, a = HonorProgressDB.milestoneOpacity or 0.25 }
      local a = HonorProgressDB.milestoneOpacity
      if not a or a <= 0 then
        a = c.a or 0.25
      end
      return { r = c.r or 1, g = c.g or 0.82, b = c.b or 0, a = a }
    end
    local function setMilestoneRGB(tbl)
      if not tbl then return end
      local a = tbl.a
      if not a or a <= 0 then
        a = HonorProgressDB.milestoneOpacity or 0.25
      end
      HonorProgressDB.milestoneOpacity = a
      HonorProgressDB.milestoneRGB = { r = tbl.r or 1, g = tbl.g or 0.82, b = tbl.b or 0, a = a }
      CreateOrUpdateMilestoneTicks()
    end

    MakeColorSwatch("HP_Adjust_BarColor",    "Bar Fill Color",     -100, -230, getBarColor,     setBarColor)
    MakeColorSwatch("HP_Adjust_TickColor",   "Tick Color",           0,   -230, getTickRGB,      setTickRGB)
    MakeColorSwatch("HP_Adjust_MilestoneColor", "Milestone Color", 100,  -230, getMilestoneRGB, setMilestoneRGB)



    -- Close
    local closeBtn = CreateFrame("Button", nil, HP_AdjustDlg, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 22); closeBtn:SetPoint("BOTTOMRIGHT", -18, 16); closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() HP_AdjustDlg:Hide() end)
  end
  HP_AdjustDlg:Show()
end

-- Text overlay (always on top)
local TextOverlay = CreateFrame("Frame", nil, Frame)
TextOverlay:SetAllPoints(Frame)
TextOverlay:SetFrameStrata("HIGH")
TextOverlay:SetFrameLevel(Frame:GetFrameLevel() + 100)

barText = TextOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
barText:SetShown(not (HonorProgressDB and HonorProgressDB.hideBarText))
barText:SetPoint("CENTER", TextOverlay, "CENTER", 0, 0)
barText:SetTextColor(1, 1, 1, 1)
barText:SetShadowColor(0, 0, 0, 1)
barText:SetShadowOffset(1, -1)
if HonorProgressDB.onlyNumbers then
barText:SetText("0 / 0 (0%)")
else
barText:SetText("Weekly Honor: 0 / 0 (0%)")
end

-- ===== State =====
local weeklyHonor = 0
local lastAPI = "none"
local sessionStartTime, sessionStartWeekly
local sessionStartHK

-- ===== Helpers =====
local function fmtnum(n)
  local s = tostring(math.floor((n or 0) + 0.5))
  local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
  return left .. (num:reverse():gsub('(%d%d%d)','%1,'):reverse()) .. right
end
local function secsToHM(secs)
  if not secs or secs < 0 then return "N/A" end
  local h = math.floor(secs/3600)
  local m = math.floor((secs%3600)/60)
  return string.format("%dh %dm", h, m)
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

-- ===== Per-battleground current/last game tracking =====
local inBG = false
local matchHonorBaseline = nil
local matchHKBaseline = nil
local matchInstanceID = nil
local matchActive = false

local function HB_IsInBattleground()
  if not IsInInstance then return false end
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "pvp"
end

local function HB_UpdateCurrentGameFromAPIs(deltaHonor)
  if not HonorProgressDB then return end
  -- Extra safety: never touch per-game stats unless we are truly in a battleground *and* a match is active
  if not HB_IsInBattleground() or not matchActive then
    return
  end

  -- Ensure fields exist
  if HonorProgressDB.currentGameHonor == nil then HonorProgressDB.currentGameHonor = 0 end
  if HonorProgressDB.currentGameHK == nil then HonorProgressDB.currentGameHK = 0 end
  if HonorProgressDB.currentGameKB == nil then HonorProgressDB.currentGameKB = 0 end

  -- Honor: compute per-match honor using a baseline captured on first update in the battleground
  if weeklyHonor ~= nil then
    if matchHonorBaseline == nil then
      -- First time updating in this match: capture baseline, do not count previous honor
      matchHonorBaseline = weeklyHonor or 0
      HonorProgressDB.currentGameHonor = 0
    else
      local diff = (weeklyHonor or 0) - (matchHonorBaseline or 0)
      if diff < 0 then diff = 0 end
      HonorProgressDB.currentGameHonor = diff
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
    HonorProgressDB.currentGameHK = diff
  end
end


local function HB_StartNewMatch()
  if not HonorProgressDB then return end

  -- Hard guard: never reset match stats unless we're actually in a battleground instance
  if not HB_IsInBattleground() then
    return
  end

  -- Make sure we have sane defaults
  if HonorProgressDB.currentGameHonor == nil then HonorProgressDB.currentGameHonor = 0 end
  if HonorProgressDB.currentGameHK == nil then HonorProgressDB.currentGameHK = 0 end
  if HonorProgressDB.currentGameKB == nil then HonorProgressDB.currentGameKB = 0 end
  if HonorProgressDB.lastGameHonor == nil then HonorProgressDB.lastGameHonor = 0 end
  if HonorProgressDB.lastGameHK == nil then HonorProgressDB.lastGameHK = 0 end
  if HonorProgressDB.lastGameKB == nil then HonorProgressDB.lastGameKB = 0 end

  -- Promote previous current game to last game
  HonorProgressDB.lastGameHonor = HonorProgressDB.currentGameHonor or HonorProgressDB.lastGameHonor or 0
  HonorProgressDB.lastGameHK    = HonorProgressDB.currentGameHK or HonorProgressDB.lastGameHK or 0
  HonorProgressDB.lastGameKB    = HonorProgressDB.currentGameKB or HonorProgressDB.lastGameKB or 0

  -- Reset current game for the new match
  matchActive = true
  HonorProgressDB.currentGameHonor = 0
  HonorProgressDB.currentGameHK    = 0
  HonorProgressDB.currentGameKB    = 0

  -- Clear honor baseline so it will be captured on first RefreshHonor() in this match
  matchHonorBaseline = nil

  -- Baseline for HKs in this match
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
  local inInstance, instanceType = IsInInstance and IsInInstance() or nil, nil
  local nowInBG = false
  local instanceID = nil

  if inInstance and type(inInstance) == "boolean" then
    -- Classic-style IsInInstance() returns (inInstance, instanceType)
    inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "pvp" then
      nowInBG = true
      if GetInstanceInfo then
        local _, _, _, _, _, _, _, instID = GetInstanceInfo()
        instanceID = instID
      end
    end
  else
    -- Fallback to old logic if API behaves unexpectedly
    nowInBG = HB_IsInBattleground()
  end

  -- Update global inBG flag
  inBG = nowInBG

  -- Only start a new match when we detect a *new* battleground instance
  if nowInBG then
    if instanceID and instanceID ~= matchInstanceID then
      matchInstanceID = instanceID
      HB_StartNewMatch()
    elseif not instanceID and not matchInstanceID then
      -- No instance ID available (for some reason), but we weren't in a match yet: start one
      matchInstanceID = -1
      HB_StartNewMatch()
    end
  else
    -- Left any instance / world; do not touch current/last game values, just clear instance tracking
    matchInstanceID = nil
    matchActive = false
  end
end


local function HB_OnCombatLogEvent()
  if not inBG or not HonorProgressDB then return end
  if not CombatLogGetCurrentEventInfo or not UnitGUID then return end
  local _, eventType, _, srcGUID, _, _, _, _, _, destFlags = CombatLogGetCurrentEventInfo()
  if eventType ~= "PARTY_KILL" then return end
  if srcGUID ~= UnitGUID("player") then return end

  if COMBATLOG_OBJECT_TYPE_PLAYER and bit and destFlags then
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then
      return
    end
  end

  HonorProgressDB.currentGameKB = (HonorProgressDB.currentGameKB or 0) + 1
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



local function HP_BuildHonorStatusString()
  -- Use the active cap: auto-cap from rank if enabled, otherwise the manual cap.
  local cap = (honorCap and honorCap > 0) and honorCap or (HonorProgressDB.honorCap or 500000)
  local earned = weeklyHonor or 0
  local pct = 0
  if cap > 0 then
    pct = (earned * 100) / cap
  end
  return string.format("Weekly Honor: %s of %s (%.2f%%)", fmtnum(earned), fmtnum(cap), pct)
end

local function HP_SendHonorToCurrentChat()
  local text = HP_BuildHonorStatusString()
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

local function UpdateBar()
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

  local showText    = HonorProgressDB.showText ~= false
  local hideBarText = HonorProgressDB.hideBarText == true


  -- Determine if this week's auto honor cap has been reached.
  local goalReached = HonorProgressDB and HonorProgressDB.autoCapFromRank
    and honorCap and honorCap > 0
    and weeklyHonor and weeklyHonor >= honorCap or false

  -- Per-character final congrats flag
  local charKey = HB_GetCharKey and HB_GetCharKey() or nil
  local charCongrats = false
  if charKey and HonorProgressDB.finalCongratsByChar then
    charCongrats = HonorProgressDB.finalCongratsByChar[charKey] and true or false
  end

  -- Fallback for migrated / per-character DBs:
  -- If this character is already Rank 14 or higher, treat them as having
  -- completed the final push and persist that to the per-character table.
  -- To avoid repeated rank API calls on every bar refresh, we only check a
  -- small, fixed number of times after login (congratsRankChecksRemaining).
  if not charCongrats and congratsRankChecksRemaining and congratsRankChecksRemaining > 0
     and UnitPVPRank and GetPVPRankInfo then
    congratsRankChecksRemaining = congratsRankChecksRemaining - 1
    local pvpRank = UnitPVPRank("player")
    if pvpRank and pvpRank > 0 then
      local _, r = GetPVPRankInfo(pvpRank)
      if r and r >= 14 then
        charCongrats = true
        if charKey then
          HonorProgressDB.finalCongratsByChar = HonorProgressDB.finalCongratsByChar or {}
          HonorProgressDB.finalCongratsByChar[charKey] = true
        end
      end
    end
  end

  if barText then
    if showText and not hideBarText then
      barText:Show()

      if HonorProgressDB.autoCapFromRank then
        -- 1. Character has already completed the final Rank 14 push on some prior week.
        if charCongrats then
          barText:SetText("Congratulations!")

        -- 2. Weekly auto honor cap reached this week.
        elseif goalReached then
          -- Strict final-week check: only treat it as the final Rank 13 -> 14 push if
          --   (a) the weekly cap matches the known final cap (~418750), AND
          --   (b) the player is Rank 13 at ~67.84% progress.
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
              HonorProgressDB.finalCongratsByChar = HonorProgressDB.finalCongratsByChar or {}
              HonorProgressDB.finalCongratsByChar[charKey] = true
            end
            barText:SetText("Congratulations!")
          else
            barText:SetText("Weekly Honor Goal Achieved!")
          end

        -- 3. Auto-cap is enabled, but this week's goal is not yet reached: show numeric text.
        else
          if HonorProgressDB.onlyNumbers then
            barText:SetText(string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
          else
            barText:SetText(string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct))
          end
        end

      -- Manual mode: always show numeric text.
      else
        if HonorProgressDB.onlyNumbers then
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

  if Frame and HonorProgressDB and HonorProgressDB.barColor then
    local c = HonorProgressDB.barColor
    if bar and bar.SetStatusBarColor then
      bar:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    end
    if Frame.SetBackdropColor then
      Frame:SetBackdropColor(c.r or 1, c.g or 1, c.b or 1, (c.a or 1) * 0.25)
    end
  end
end

-- ===== Weekly honor getters (Classic Era safe) =====
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

local function RefreshHonor(verbose)
  local new = GetWeeklyHonor()
  local oldWeekly = weeklyHonor or 0
  if type(new) == "number" then
    if not sessionStartTime then
      sessionStartTime = GetTime() and math.floor(GetTime()) or 0
      sessionStartWeekly = new
      if GetPVPSessionStats then
        local ok, a, b = pcall(GetPVPSessionStats)
        if ok then
          sessionStartHK = a or 0
        else
          local h1 = GetPVPSessionStats()
          sessionStartHK = h1 or 0
        end
      end
    end
    weeklyHonor = new
  end


  -- Update current-game stats (honor/HK) while in a battleground
  HB_UpdateCurrentGameFromAPIs()

  -- Update auto cap & milestones if enabled and weekly honor changed
  if HonorProgressDB.autoCapFromRank and (weeklyHonor or 0) ~= oldWeekly then
    UpdateAutoCapFromRank()
  end

  UpdateBar()
  if verbose then
    HP_Print("Weekly =", weeklyHonor, "API =", lastAPI)
  end
end

-- ===== Auto refresh (uses Stats Refresh slider) =====
local ticker
local function StartAuto()
  if not C_Timer or not C_Timer.NewTicker then return end
  if ticker and ticker.Cancel then
    ticker:Cancel()
  end
  local interval = 1.0
  if HonorProgressDB and HonorProgressDB.statsRefresh then
    interval = HonorProgressDB.statsRefresh
  end
  if interval < 0.2 then
    interval = 0.2
  elseif interval > 2.0 then
    interval = 2.0
  end
  ticker = C_Timer.NewTicker(interval, function() RefreshHonor(false) end)
end
local function StopAuto()
  if ticker and ticker.Cancel then ticker:Cancel() end
  ticker = nil
end
if autoOn then StartAuto() end

-- ===== Show/Hide control =====
function ApplyVisibility()
  local shouldShow = HonorProgressDB.visible and not HonorProgressDB.hiddenBar
  if shouldShow then
    Frame:Show()
  else
    Frame:Hide()
  end
end
local function ShowBar()
  HonorProgressDB.hiddenBar = false
  HonorProgressDB.visible = true
  ApplyVisibility()
  local cb = _G["HP_Adjust_HideBar"]
  if cb and cb.SetChecked then
    cb:SetChecked(false)
  end
  HP_Print("bar shown")
end
local function HideBar()
  HonorProgressDB.hiddenBar = true
  HonorProgressDB.visible = false
  ApplyVisibility()
  local cb = _G["HP_Adjust_HideBar"]
  if cb and cb.SetChecked then
    cb:SetChecked(true)
  end
  HP_Print("bar hidden (use /honor show to display)")
end
local function ToggleBar()
  if HonorProgressDB.hiddenBar or not HonorProgressDB.visible then
    ShowBar()
  else
    HideBar()
  end
end

-- ===== Apply settings / save =====
local function ApplyAllSettings()
  Frame:ClearAllPoints()
  if HonorProgressDB.point and HonorProgressDB.relativePoint and HonorProgressDB.xOfs and HonorProgressDB.yOfs then
    Frame:SetPoint(HonorProgressDB.point, UIParent, HonorProgressDB.relativePoint, HonorProgressDB.xOfs, HonorProgressDB.yOfs)
  else
    Frame:SetPoint("CENTER")
  end
  local w = HonorProgressDB.width or 300
  local h = HonorProgressDB.height or 30
  Frame:SetSize(w, h)
  local c = HonorProgressDB.barColor or { r=0.15, g=0.55, b=0.95, a=1 }
  color = c
  bar:SetStatusBarColor(c.r or 0.2, c.g or 0.6, c.b or 1.0, c.a or 0.9)
  honorCap = HonorProgressDB.honorCap or 500000
  autoOn   = HonorProgressDB.autoOn ~= false

  -- Recompute auto cap & milestones on login if enabled
  if HonorProgressDB.autoCapFromRank then
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
    HP_Print("loaded. Commands: /honor, /hb.")
  elseif event == "PLAYER_LOGOUT" then
    if not HonorProgressDB.autoCapFromRank then
      HonorProgressDB.honorCap = honorCap
    end
      HonorProgressDB.autoOn   = autoOn
    -- HonorProgressDB.barColor persisted via live updates; no override here
    HonorProgressDB.width, HonorProgressDB.height = math.floor(Frame:GetWidth()+0.5), math.floor(Frame:GetHeight()+0.5)
    local point, _, relativePoint, xOfs, yOfs = Frame:GetPoint()
    HonorProgressDB.point, HonorProgressDB.relativePoint = point, relativePoint
    HonorProgressDB.xOfs, HonorProgressDB.yOfs = xOfs, yOfs
    HonorProgressDB.visible = HonorProgressDB.visible and true or false
  end
end)

Frame:SetScript("OnSizeChanged", function(self) CreateOrUpdateTicks() end)

-- Alt+Left-Click dragging
Frame:EnableMouse(true)
Frame:SetMovable(true)
Frame:SetScript("OnMouseDown", function(self, button)
  if button == "RightButton" then
    if IsShiftKeyDown() then
      HP_SendHonorToCurrentChat()
    else
      HP_OpenAdjustDialog()
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
    -- Persist position immediately
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    HonorProgressDB.point, HonorProgressDB.relativePoint = point, relativePoint
    HonorProgressDB.xOfs, HonorProgressDB.yOfs = xOfs, yOfs
  end
end)


-- Helpers for size/color
-- ===== Live tooltip @ 0.2s =====
local tooltipVisible, tooltipAccum = false, 0
local statsFrame, statsAccum = nil, 0
local statsLines = {}
local markSegments = {}


-- BG Mark of Honor item IDs (Classic)
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


-- Detached session stats floating frame (transparent)
local function EnsureStatsFrame()
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
      if not HonorProgressDB then return end
      local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
      HonorProgressDB.statsPoint = point
      HonorProgressDB.statsRelativePoint = relativePoint
      HonorProgressDB.statsXOfs = xOfs
      HonorProgressDB.statsYOfs = yOfs
    end
  end)

  -- Restore saved position if available
  if HonorProgressDB and HonorProgressDB.statsPoint then
    f:ClearAllPoints()
    f:SetPoint(HonorProgressDB.statsPoint, UIParent, HonorProgressDB.statsRelativePoint or "CENTER",
      HonorProgressDB.statsXOfs or 0, HonorProgressDB.statsYOfs or 0)
  else
    f:SetPoint("TOP", UIParent, "TOP", 0, -200)
  end

  -- Transparent background (no backdrop); just text
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

local function UpdateStatsFrame()
  if not HonorProgressDB or not HonorProgressDB.detachStats then
    if statsFrame then statsFrame:Hide() end
    return
  end

  local f = EnsureStatsFrame()
  if not f then return end
  f:Show()

  local now = GetTime() and math.floor(GetTime()) or 0
  local elapsed = (sessionStartTime and (now - sessionStartTime)) or 0
  local gained = (sessionStartWeekly and (weeklyHonor - sessionStartWeekly)) or 0
  if gained < 0 then gained = 0 end
  local hph = (elapsed > 0) and (gained * 3600 / elapsed) or 0
  local remaining = (honorCap and honorCap > 0) and (honorCap - (weeklyHonor or 0)) or 0
  if remaining < 0 then remaining = 0 end
  local sessionHK = GetSessionHK()
  local etaSecs = (hph > 0) and (remaining / hph * 3600) or nil

  local lines = statsLines
  wipe(lines)
  table.insert(lines, "|cff3399ffSession Stats|r")
  table.insert(lines, string.format("Time: %s", secsToHM(elapsed)))
  table.insert(lines, string.format("Honor: %s", fmtnum(gained)))
  table.insert(lines, string.format("Honor / hour: %s", fmtnum(hph)))

  -- If bar text is hidden, show the same bar text string here between Honor/hour and Remaining.
  if HonorProgressDB and HonorProgressDB.hideBarText then
    local cap = (honorCap and honorCap > 0) and honorCap or 1
    local pct = math.min(((weeklyHonor or 0) / cap) * 100, 100)
    local barLine
    if HonorProgressDB.showText then
      if HonorProgressDB.onlyNumbers then
        barLine = string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      else
        barLine = string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      end
    end
    if barLine then
      table.insert(lines, barLine)
    end
  end

  table.insert(lines, string.format("Remaining: %s", fmtnum(remaining)))

  -- Milestones line (same logic as tooltip, but plain text)
  do
    local parts = {}
    -- Only show milestones in auto-cap mode when we have milestone data
    if HonorProgressDB and HonorProgressDB.autoCapFromRank and rankMilestones and type(rankMilestones) == "table" and #rankMilestones > 1 then
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

  table.insert(lines, string.format("HKs: %d", sessionHK))
  table.insert(lines, string.format("ETA to %s: %s", fmtnum(honorCap or 0), etaSecs and secsToHM(etaSecs) or "N/A"))

  -- Marks of Honor (last line)
  local marksLine = HB_GetMarkLine()
  if marksLine and marksLine ~= "" then
    table.insert(lines, "Marks: " .. marksLine)
  end

  -- Current / Last game stats (per battleground)
  if HonorProgressDB then
    local curHonor = HonorProgressDB.currentGameHonor or 0
    local curHK    = HonorProgressDB.currentGameHK or 0
    local curKB    = HonorProgressDB.currentGameKB or 0
    local lastHonor = HonorProgressDB.lastGameHonor or 0
    local lastHK    = HonorProgressDB.lastGameHK or 0
    local lastKB    = HonorProgressDB.lastGameKB or 0

    table.insert(lines, string.format("Current Game: Honor %s HKs %d KBs %d", fmtnum(curHonor), curHK, curKB))
    table.insert(lines, string.format("Last Game: Honor %s HKs %d KBs %d", fmtnum(lastHonor), lastHK, lastKB))
  end


  local text = f.text
  text:SetText(table.concat(lines, "\n"))

  local h = text:GetStringHeight() + 4
  local w = text:GetStringWidth() + 10
  f:SetHeight(h)
  f:SetWidth(math.max(220, w))
end

local function UpdateTooltip()
  if not tooltipVisible then return end
  GameTooltip:ClearLines()
  local now = GetTime() and math.floor(GetTime()) or 0
  local elapsed = (sessionStartTime and (now - sessionStartTime)) or 0
  local gained = (sessionStartWeekly and (weeklyHonor - sessionStartWeekly)) or 0
  if gained < 0 then gained = 0 end
  local hph = (elapsed > 0) and (gained * 3600 / elapsed) or 0
  local remaining = (honorCap and honorCap > 0) and (honorCap - (weeklyHonor or 0)) or 0
  if remaining < 0 then remaining = 0 end
  local sessionHK = GetSessionHK()
  local etaSecs = (hph > 0) and (remaining / hph * 3600) or nil
  local detachStats = HonorProgressDB and HonorProgressDB.detachStats
  if not detachStats then
  GameTooltip:AddLine("Session Stats", 0.2, 0.6, 1.0, true)
  GameTooltip:AddLine(string.format("Time: %s", secsToHM(elapsed)), 1,1,1, true)
  GameTooltip:AddLine(string.format("Honor: %s", fmtnum(gained)), 1,1,1, true)
  GameTooltip:AddLine(string.format("Honor / hour: %s", fmtnum(hph)), 1,1,1, true)

  -- If bar text is hidden, show the same bar text string here between Honor/hour and Remaining.
  if HonorProgressDB and HonorProgressDB.hideBarText then
    local cap = (honorCap and honorCap > 0) and honorCap or 1
    local pct = math.min(((weeklyHonor or 0) / cap) * 100, 100)
    local barLine
    if HonorProgressDB.showText then
      if HonorProgressDB.onlyNumbers then
        barLine = string.format("%s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      else
        barLine = string.format("Weekly Honor: %s / %s (%.1f%%)", fmtnum(weeklyHonor or 0), fmtnum(cap), pct)
      end
    end
    if barLine then
      GameTooltip:AddLine(barLine, 1,1,1, true)
    end
  end

  GameTooltip:AddLine(string.format("Remaining: %s", fmtnum(remaining)), 1,1,1, true)

  -- Show honor remaining to each upcoming milestone (except the last),
  -- on a single line, so long as we have milestone data.
  do
    local parts = {}
    -- Only show milestones in auto-cap mode when we have milestone data
    if HonorProgressDB and HonorProgressDB.autoCapFromRank and rankMilestones and type(rankMilestones) == "table" and #rankMilestones > 1 then
      local currentHonor = weeklyHonor or 0
      local capForMilestones = honorCap or 0

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
      GameTooltip:AddLine("Milestones: " .. table.concat(parts, "   "), 1,1,1, true)
    end
  end

  GameTooltip:AddLine(string.format("HKs: %d", sessionHK), 1,1,1, true)
  GameTooltip:AddLine(string.format("ETA to %s: %s", fmtnum(honorCap or 0), etaSecs and secsToHM(etaSecs) or "N/A"), 1,1,1, true)

  -- Marks of Honor (last stats line)
  local marksLine = HB_GetMarkLine()
  if marksLine and marksLine ~= "" then
    GameTooltip:AddLine("Marks: " .. marksLine, 1,1,1, true)
  end

  -- Current / Last game stats (per battleground)
  if HonorProgressDB then
    local curHonor = HonorProgressDB.currentGameHonor or 0
    local curHK    = HonorProgressDB.currentGameHK or 0
    local curKB    = HonorProgressDB.currentGameKB or 0
    local lastHonor = HonorProgressDB.lastGameHonor or 0
    local lastHK    = HonorProgressDB.lastGameHK or 0
    local lastKB    = HonorProgressDB.lastGameKB or 0

    GameTooltip:AddLine(string.format("Current Game: Honor %s HKs %d KBs %d", fmtnum(curHonor), curHK, curKB), 1,1,1, true)
    GameTooltip:AddLine(string.format("Last Game: Honor %s HKs %d KBs %d", fmtnum(lastHonor), lastHK, lastKB), 1,1,1, true)
  end


  end

  GameTooltip:AddLine("Hold Alt + Left-Click to drag", 0.8, 0.8, 0.8, true)


  local __n = GameTooltip:NumLines()
  local __fs = _G["GameTooltipTextLeft"..__n]
  if __fs then __fs:SetTextColor(0.7, 0.7, 0.7, 0.5) end
  GameTooltip:AddLine("Right-Click to adjust bar", 0.8, 0.8, 0.8, true)
  __n = GameTooltip:NumLines()
  __fs = _G["GameTooltipTextLeft"..__n]
  if __fs then __fs:SetTextColor(0.7, 0.7, 0.7, 0.5) end
  GameTooltip:AddLine("Shift + Right-Click to broadcast honor to chat", 0.8, 0.8, 0.8, true)
  __n = GameTooltip:NumLines()
  __fs = _G["GameTooltipTextLeft"..__n]
  if __fs then __fs:SetTextColor(0.7, 0.7, 0.7, 0.5) end

  GameTooltip:AddLine("/honor for help", 0.8, 0.8, 0.8, true)
  __n = GameTooltip:NumLines()
  __fs = _G["GameTooltipTextLeft"..__n]
  if __fs then __fs:SetTextColor(0.7, 0.7, 0.7, 0.5) end
GameTooltip:Show()
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

  local refresh = 1.0
  if HonorProgressDB and HonorProgressDB.statsRefresh then
    refresh = HonorProgressDB.statsRefresh
  end
  if refresh < 0.2 then
    refresh = 0.2
  elseif refresh > 2.0 then
    refresh = 2.0
  end

  -- Detached stats frame update
  if HonorProgressDB and HonorProgressDB.detachStats then
    statsAccum = statsAccum + elapsed
    if statsAccum >= refresh then
      statsAccum = 0
      UpdateStatsFrame()
    end
  end

  -- Tooltip update (shares the same refresh interval)
  if not tooltipVisible then return end
  tooltipAccum = tooltipAccum + elapsed
  if tooltipAccum >= refresh then
    tooltipAccum = 0
    UpdateTooltip()
  end
end)


-- ===== Slash commands =====
local function PrintHelp()
  -- Prefer the dedicated help popup if available
  if type(HP_ToggleHelpDialog) == "function" then
    HP_ToggleHelpDialog()
    return
  elseif type(HP_ShowHelpPopup) == "function" then
    HP_ShowHelpPopup()
    return
  end

  -- Fallback: simple chat output if the help UI is not available
  HP_Print("commands:")
  print(" /honor config or /hb config - open Bar Config dialog")
  print(" /honor debug            - force update & print info")
  print(" /honor cap <number>     - set cap (e.g., /honor cap 750000)")
  print(" /honor auto on|off      - toggle 1s auto-refresh")
  print(" /honor resetpos         - reset bar to screen center")
  print(" /honor show||hide||toggle - show/hide the bar")
end

local function Trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function SplitTwo(s)
  if not s then return "", "" end
  local a,b = s:match("^(%S+)%s*(.-)$")
  return a or "", b or ""
end

local 
function HP_SuggestCommand(input)
  local cmds = { "config","debug","cap","auto","resetpos","show","hide","toggle" }
  if not input or input == "" then return nil end
  input = string.lower(input)
  -- Exact/alias short-circuits
  for _,c in ipairs(cmds) do if c == input then return c end end
  -- Prefix / substring matches
  local matches = {}
  for _,c in ipairs(cmds) do
    if string.sub(c,1,#input) == input or string.find(c, input, 1, true) then
      table.insert(matches, c)
    end
  end
  if #matches > 0 then return table.concat(matches, ", ") end
  -- Fallback: show all
  return table.concat(cmds, ", ")
end

function RootSlashHandler(msg)
  msg = Trim(string.lower(msg or ""))
  local cmd, rest = SplitTwo(msg)
  if cmd == "" or cmd == "help" then
    PrintHelp()
  elseif cmd == "debug" then
    RefreshHonor(true)
  elseif cmd == "mem" or cmd == "memory" then
    HP_PrintMemory()
  elseif cmd == "cap" then
    if HonorProgressDB.autoCapFromRank then
      HP_Print("Auto cap is enabled; uncheck 'Auto' next to Honor Cap in /honor to set a manual cap.")
    else
      local v = tonumber(rest)
      if v and v > 0 then
        honorCap = math.floor(v + 0.5); HonorProgressDB.honorCap = honorCap; UpdateBar()
        HP_Print("cap set to", honorCap)
      else
        HP_Print("usage: /honor cap <number>")
      end
    end
  elseif cmd == "auto" then
    if rest == "on" then
      autoOn = true; HonorProgressDB.autoOn = true; StartAuto(); HP_Print("auto ON")
    elseif rest == "off" then
      autoOn = false; HonorProgressDB.autoOn = false; StopAuto(); HP_Print("auto OFF")
    else
      HP_Print("usage: /honor auto on|off")
    end
  elseif cmd == "resetpos" then
    Frame:ClearAllPoints(); Frame:SetPoint("CENTER")
    HonorProgressDB.point, HonorProgressDB.relativePoint = "CENTER", "CENTER"
    HonorProgressDB.xOfs, HonorProgressDB.yOfs = 0, 0
    HP_Print("position reset")
  elseif cmd == "show" then
    ShowBar()
  elseif cmd == "hide" then
    HideBar()
  elseif cmd == "toggle" then
    ToggleBar()
  elseif cmd == "config" then
    if HP_OpenAdjustDialog then HP_OpenAdjustDialog() end

  else
    local s = HP_SuggestCommand(cmd)
    if s then
      HP_Print(string.format('Unknown subcommand "%s". Try: %s', cmd, s))
    else
      PrintHelp()
    end
  end
end

SLASH_HPROOT1 = "/honor"
SLASH_HPROOT2 = "/hb"
SlashCmdList["HPROOT"] = RootSlashHandler
SLASH_HPMEM1 = "/hp"
SlashCmdList.HPMEM = function(msg)
  msg = string.lower(msg or "")
  if msg == "" or msg == "mem" or msg == "memory" then
    HP_PrintMemory()
  else
    RootSlashHandler(msg)
  end
end


-- Legacy aliases
SLASH_HPROG_DEBUG1 = "/honordebug"
SlashCmdList.HPROG_DEBUG = function() RootSlashHandler("debug") end
SLASH_HPROG_CAP1 = "/honorcap"
SlashCmdList.HPROG_CAP = function(msg) RootSlashHandler("cap "..(msg or "")) end
SLASH_HPROG_AUTO1 = "/honorauto"
SlashCmdList.HPROG_AUTO = function(msg) RootSlashHandler("auto "..(string.lower(msg or ""))) end
SLASH_HPROG_RESETPOS1 = "/honorresetpos"
SlashCmdList.HPROG_RESETPOS = function() RootSlashHandler("resetpos") end

-- Initial draw
ApplyVisibility()
UpdateBar()
CreateOrUpdateTicks()

-- Persist on logout
local Saver = CreateFrame("Frame")
Saver:RegisterEvent("PLAYER_LOGOUT")
Saver:SetScript("OnEvent", function()
  if not HonorProgressDB.autoCapFromRank then
    HonorProgressDB.honorCap = honorCap
  end
  HonorProgressDB.autoOn   = autoOn
  -- HonorProgressDB.barColor persisted via live updates; no override here
  HonorProgressDB.width, HonorProgressDB.height = math.floor(Frame:GetWidth()+0.5), math.floor(Frame:GetHeight()+0.5)
  local point, _, relativePoint, xOfs, yOfs = Frame:GetPoint()
  HonorProgressDB.point, HonorProgressDB.relativePoint = point, relativePoint
  HonorProgressDB.xOfs, HonorProgressDB.yOfs = xOfs, yOfs
  HonorProgressDB.visible = HonorProgressDB.visible and true or false
end)

-- =================== HonorProgress: Simple !honor auto-reply ===================
local HP_ChatFrame = CreateFrame("Frame")
local HP_CHAT_EVENTS = {
  "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER",
  "CHAT_MSG_RAID", "CHAT_MSG_PARTY", "CHAT_MSG_GUILD", "CHAT_MSG_CHANNEL",
  "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}
for i=1,#HP_CHAT_EVENTS do HP_ChatFrame:RegisterEvent(HP_CHAT_EVENTS[i]) end


HP_ChatFrame:SetScript("OnEvent", function(self, event, msg, author, ...)
  if not (HonorProgressDB and HonorProgressDB.replyEnabled) then return end
  if type(msg) ~= "string" then return end
  local m = msg:match("^%s*!honor%s*$")
  if not m then return end

  local text = HP_BuildHonorStatusString()
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

SLASH_HONORPROGRESSREPLY1 = "/hbreply"
SlashCmdList["HONORPROGRESSREPLY"] = function(arg)
  arg = arg and arg:lower() or ""
  if arg == "on" or arg == "1" then
    HonorProgressDB.replyEnabled = true
    HP_Print("!honor replies |cff00ff00ENABLED|r")
  elseif arg == "off" or arg == "0" then
    HonorProgressDB.replyEnabled = false
    HP_Print("!honor replies |cffff0000DISABLED|r")
  else
    HP_Print("/hbreply on | off")
  end
end
-- =================== End Simple !honor auto-reply ===================

-- === HP: Force Bar Config dialog taller (+60 px), even if size is reset elsewhere ===
do
  local function HP_ApplyTaller(f)
    if not (f and (f.SetHeight or f.SetSize) and f.GetHeight) then return end
    if not f._hp_orig_h then f._hp_orig_h = f:GetHeight() or 0 end
    local target = (f._hp_orig_h or 0) + 60
    local cur = f:GetHeight() or 0
    if f.SetHeight then
      if cur < target - 0.5 then f:SetHeight(target) end
    elseif f.SetSize and f.GetWidth then
      local w = f:GetWidth() or 0
      if cur < target - 0.5 then f:SetSize(w, target) end
    end
    f._hp_taller_applied = true
  end

  local function HP_FindAdjustDlg()
    return _G.HP_AdjustDlg or _G.HonorProgressAdjustDlg
  end

  local function HP_Taller_OnShow(self)
    if C_Timer and C_Timer.After then
      C_Timer.After(0, function() HP_ApplyTaller(self) end) -- run after initial layout
    else
      HP_ApplyTaller(self)
    end
  end

  -- Hook existing dialog (if already created)
  local dlg = HP_FindAdjustDlg()
  if dlg and not dlg._hp_taller_hooked2 then
    dlg:HookScript("OnShow", HP_Taller_OnShow)
    dlg._hp_taller_hooked2 = true
  end

  -- Wrap the dialog open function so we reapply every time it opens
  if type(HP_OpenAdjustDialog) == "function" and not _G._hp_wrap_open_adjust then
    local _old = HP_OpenAdjustDialog
    _G._hp_wrap_open_adjust = true
    HP_OpenAdjustDialog = function(...)
      local r1,r2,r3 = _old(...)
      local f = HP_FindAdjustDlg()
      if f then HP_Taller_OnShow(f) end
      return r1,r2,r3
    end
  end

  -- Retry a few times in case dialog is created late
  if C_Timer and C_Timer.NewTicker then
    local tries = 0
    C_Timer.NewTicker(0.3, function(t)
      tries = tries + 1
      local f = HP_FindAdjustDlg()
      if f and not f._hp_taller_hooked2 then
        f:HookScript("OnShow", HP_Taller_OnShow)
        f._hp_taller_hooked2 = true
      end
      if f then HP_Taller_OnShow(f) end
      if tries >= 12 then t:Cancel() end
    end)
  elseif C_Timer and C_Timer.After then
    for i=1,12 do
      C_Timer.After(0.3*i, function()
        local f = HP_FindAdjustDlg()
        if f and not f._hp_taller_hooked2 then
          f:HookScript("OnShow", HP_Taller_OnShow)
          f._hp_taller_hooked2 = true
        end
        if f then HP_Taller_OnShow(f) end
      end)
    end
  end
end
-- === End force taller patch ===


-- Shared helper to locate the Close button on the Adjust dialog
local function HP_FindCloseButton(dlg)
  if not (dlg and dlg.GetChildren) then return nil end

  local children = { dlg:GetChildren() }
  for i = 1, #children do
    local c = children[i]
    if c and c.GetObjectType and c:GetObjectType() == "Button" then
      local text = c.GetText and c:GetText() or ""
      local name = c.GetName and c:GetName() or ""
      if text == "Close" or text == " Close " or (name and name:lower():find("close")) then
        return c
      end
    end
  end

  return nil
end

-- === HP PATCH: center the Close button horizontally, keep current vertical offset ===
do
  local function HP_CenterCloseButton()
    local dlg = _G.HP_AdjustDlg or _G.HonorProgressAdjustDlg
    if not (dlg and dlg.GetChildren) then return end

    local closeBtn = HP_FindCloseButton(dlg)
    if not closeBtn then return end

    local point, rel, relPoint, x, y = closeBtn:GetPoint(1)
    y = y or 0

    closeBtn:ClearAllPoints()
    closeBtn:SetPoint("BOTTOM", dlg, "BOTTOM", 0, y)
  end

  if type(HP_OpenAdjustDialog) == "function" and not _G.HP_CenterClose_Wrapped then
    local _old = HP_OpenAdjustDialog
    _G.HP_CenterClose_Wrapped = true

    HP_OpenAdjustDialog = function(...)
      local r1, r2 = _old(...)
      HP_CenterCloseButton()
      if C_Timer and C_Timer.After then
        C_Timer.After(0, HP_CenterCloseButton)
        C_Timer.After(0.05, HP_CenterCloseButton)
        C_Timer.After(0.15, HP_CenterCloseButton)
      end
      return r1, r2
    end
  else
    local dlg = _G.HP_AdjustDlg or _G.HonorProgressAdjustDlg
    if dlg and not dlg._hp_center_close_hooked then
      dlg:HookScript("OnShow", function()
        HP_CenterCloseButton()
        if C_Timer and C_Timer.After then
          C_Timer.After(0, HP_CenterCloseButton)
          C_Timer.After(0.05, HP_CenterCloseButton)
          C_Timer.After(0.15, HP_CenterCloseButton)
        end
      end)
      dlg._hp_center_close_hooked = true
    end
  end
end
-- === END HP PATCH ===