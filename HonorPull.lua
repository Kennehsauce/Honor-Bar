-- HonorPull.lua
-- Adds /honorpull and /hbpull commands to announce pull countdowns.
-- Channel order: RAID_WARNING (if raid lead/assist) -> INSTANCE_CHAT -> YELL

local pullTicker

-- Fallback if LE_PARTY_CATEGORY_INSTANCE is undefined in Classic
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

-- Optional cancel command: /cpull
SLASH_PULLCANCEL1 = "/cpull"
SlashCmdList["PULLCANCEL"] = function()
  CancelPull(false)
end

-- On-load banner
C_Timer.After(0, function() if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff00c0ffHonor Bar|r: Pull Timer loaded. Use |cffffd200/honorpull|r or |cffffd200/hbpull|r.") end end)
