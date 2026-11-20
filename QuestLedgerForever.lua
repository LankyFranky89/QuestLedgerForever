-- Quest Ledger Forever: a standalone, extended quest log window for WoW Forever.
local ADDON = ...

-- Replacing the old "QuestLogForever" folder: if it's still installed and on, turn it off,
-- copy its settings over once, and ask for a /reload. This session the old copy keeps running alone,
-- so the two never fight over the L key, the map or the arrow.
do
  local OLD = "QuestLogForever"
  local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  local Disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
  local ok, _, _, _, loadable, reason = pcall(GetInfo, OLD)
  if ok and loadable and reason ~= "MISSING" then
    pcall(Disable, OLD)
    local w = CreateFrame("Frame")
    w:RegisterEvent("PLAYER_LOGIN")
    w:SetScript("OnEvent", function()
      if not QuestLedgerForeverDB and type(QuestLogForeverDB) == "table" then
        local copy = {}
        for k, v in pairs(QuestLogForeverDB) do copy[k] = v end
        QuestLedgerForeverDB = copy
      end
      print("|cffffd200Quest Ledger Forever:|r replaced the old Quest Log Forever (now turned off). Type |cffffd200/reload|r to finish. You can delete the old QuestLogForever folder.")
      StaticPopupDialogs["QUESTLEDGER_RELOAD"] = {
        text = "Quest Ledger Forever replaced the old Quest Log Forever.\nReload now to finish?",
        button1 = RELOADUI or "Reload UI", button2 = LATER or "Later",
        OnAccept = function() ReloadUI() end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
      }
      StaticPopup_Show("QUESTLEDGER_RELOAD")
    end)
    return
  end
end
local DB
local MODERN = C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries
-- item API differs per client build: use whichever exists
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetDetailedItemLevelInfo = GetDetailedItemLevelInfo or (C_Item and C_Item.GetDetailedItemLevelInfo)
local GetItemQualityColor = GetItemQualityColor or (C_Item and C_Item.GetItemQualityColor)

local ROW_H, NUM_ROWS = 18, 24
local entries, collapsed, selectedID = {}, {}, nil
local mode = "mine" -- "mine" or "party"

local function Mates() return QuestMatesAPI end

-- Waypoints: the game's own in-world marker (showInGameNavigation) and/or the 3D arrow
function QuestLedgerForever_ArrowOff() return QuestLedgerForeverDB and QuestLedgerForeverDB.arrow == false end
local function MarkerOn() return not (QuestLedgerForeverDB and QuestLedgerForeverDB.gameMarker == false) end
local function SetGameMarker(on)
  if not SetCVar then return end
  local want = on and "1" or "0"
  local cur = GetCVar and GetCVar("showInGameNavigation")
  if cur ~= want then pcall(SetCVar, "showInGameNavigation", want) end
end
-- Color the game's marker (diamond + distance text) by distance: red far -> yellow -> green close.
-- Gold when the quest is ready to hand in.
local FAR_YARDS = 500 -- red at this distance or more
local function MarkerDistance(stf)
  if C_Navigation and C_Navigation.GetDistance then
    local ok, d = pcall(C_Navigation.GetDistance)
    if ok and type(d) == "number" and d > 0 then return d end
  end
  -- fallback: read the number from the marker's own distance text ("188 yds")
  local t = stf.DistanceText and stf.DistanceText.GetText and stf.DistanceText:GetText()
  local n = t and tonumber((t:gsub(",", "")):match("([%d%.]+)"))
  if n and t:lower():find("m") and not t:lower():find("yd") then n = n / 0.9144 end
  return n
end
local markerHooked
function QLF_ColorMarker()
  local stf = SuperTrackedFrame
  if not stf then return end
  local db = QuestLedgerForeverDB or {}
  local r, g, b = 1, 1, 1
  local custom = false
  local qid = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
  local done = qid and qid > 0 and C_QuestLog and C_QuestLog.IsComplete and C_QuestLog.IsComplete(qid)
  if done then
    r, g, b = 1, 0.82, 0; custom = true
  elseif db.markerDistColor ~= false then
    local d = MarkerDistance(stf)
    if d then
      local t = math.min(1, d / FAR_YARDS) -- 0 = here, 1 = far
      if t > 0.5 then r, g = 1, 2 * (1 - t) else r, g = 2 * t, 1 end
      b = 0.15; custom = true
    end
  end
  -- the diamond (and arrow, when the target is off-screen)
  for _, key in ipairs({ "Icon", "Arrow" }) do
    local t = stf[key]
    if t and t.SetVertexColor then
      if custom then t:SetVertexColor(r, g, b) else t:SetVertexColor(1, 1, 1) end
    end
  end
  local dt = stf.DistanceText
  if dt and dt.SetTextColor then
    if custom then dt:SetTextColor(r, g, b) else dt:SetTextColor(1, 0.82, 0) end
  end
  if not markerHooked then
    markerHooked = true
    -- Blizzard may reset the look when it updates the marker: re-apply after it
    for _, fn in ipairs({ "UpdateIcon", "UpdateStateFor", "UpdateDistanceText" }) do
      if type(stf[fn]) == "function" then hooksecurefunc(stf, fn, function() QLF_ColorMarker() end) end
    end
    stf:HookScript("OnShow", function() QLF_ColorMarker() end)
    -- keep the distance color moving while you walk (4 times a second)
    local acc = 0
    stf:HookScript("OnUpdate", function(_, dt)
      acc = acc + (dt or 0)
      if acc >= 0.25 then acc = 0; QLF_ColorMarker() end
    end)
  end
end

local function PointArrow(qid)
  if not qid then return end
  -- game marker: follows the "super tracked" quest
  if MarkerOn() and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
    SetGameMarker(true)
    local cur = C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if cur ~= qid then pcall(C_SuperTrack.SetSuperTrackedQuestID, qid) end
  end
  -- 3D arrow
  if not QuestLedgerForever_ArrowOff() then
    if RallyPoint_FollowQuest then pcall(RallyPoint_FollowQuest, qid)   -- Rally Point has hand-in data too
    elseif QLF_OwnArrow then QLF_OwnArrow(qid) end                      -- built-in arrow
  end
end
-- distance units, shared with Rally Point when it's installed
local function Units() return ((RallyPointDB and RallyPointDB.units) or (QuestLedgerForeverDB and QuestLedgerForeverDB.units)) == "m" and "m" or "yd" end
local function SetUnits(u)
  if RallyPointDB then RallyPointDB.units = u end
  if QuestLedgerForeverDB then QuestLedgerForeverDB.units = u end
end

---------------------------------------------------------------- API helpers
local function NumEntries()
  if MODERN then return C_QuestLog.GetNumQuestLogEntries() or 0 end
  return (GetNumQuestLogEntries and GetNumQuestLogEntries()) or 0
end

local function EntryInfo(i)
  if MODERN then
    local info = C_QuestLog.GetInfo(i)
    if not info then return end
    local complete = info.questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
    local failed = info.questID and C_QuestLog.IsFailed and C_QuestLog.IsFailed(info.questID)
    local elite = info.isElite
    if not elite and info.questID and not info.isHeader and C_QuestLog.GetQuestTagInfo then
      local ok, t = pcall(C_QuestLog.GetQuestTagInfo, info.questID)
      if ok and t then elite = t.isElite or t.tagID == 1 or t.tagName == (ELITE or "Elite") end
    end
    return info.title, info.level, info.isHeader, complete, failed, info.questID, info.suggestedGroup, elite
  end
  local title, level, tag, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
  if not title then return end
  local group = (type(tag) == "number" and tag > 0) and tag or nil
  local elite = tag == (ELITE or "Elite") or tag == "Elite"
  return title, level, isHeader, isComplete == 1 or isComplete == true, isComplete == -1, qid, group, elite
end

local function IndexForQuest(qid)
  if MODERN and C_QuestLog.GetLogIndexForQuestID then return C_QuestLog.GetLogIndexForQuestID(qid) end
  for i = 1, NumEntries() do
    local _, _, h, _, _, id = EntryInfo(i)
    if not h and id == qid then return i end
  end
end

local function HeaderForQuest(qid)
  local header
  for i = 1, NumEntries() do
    local title, _, h, _, _, id = EntryInfo(i)
    if h then header = title elseif id == qid then return header end
  end
end

local function Select(qid)
  local idx = IndexForQuest(qid)
  if not idx then return end
  if MODERN and C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(qid) end
  if SelectQuestLogEntry then SelectQuestLogEntry(idx) end
  return idx
end

local function IsWatched(qid, idx)
  idx = idx or (qid and IndexForQuest(qid))
  if C_QuestLog and C_QuestLog.GetQuestWatchType and qid then
    local ok, t = pcall(C_QuestLog.GetQuestWatchType, qid)
    if ok and t ~= nil then return true end
  end
  if C_QuestLog and C_QuestLog.IsQuestWatched and qid then
    local ok, v = pcall(C_QuestLog.IsQuestWatched, qid); if ok and v then return true end
  end
  if IsQuestWatched and idx then return IsQuestWatched(idx) and true or false end
  return false
end

local tempWatch -- quest tracked only so "Show on Map" can draw its icon
local function ToggleWatch(qid, idx, temp)
  idx = idx or (qid and IndexForQuest(qid))
  if not temp and qid and qid == tempWatch then tempWatch = nil end -- the player's own choice wins
  local watched = IsWatched(qid, idx)
  local function try(fn, ...) if fn then return pcall(fn, ...) end end
  if watched then
    if not (C_QuestLog and C_QuestLog.RemoveQuestWatch and try(C_QuestLog.RemoveQuestWatch, qid)) then
      try(RemoveQuestWatch, idx)
    end
  else
    local manual = Enum and Enum.QuestWatchType and Enum.QuestWatchType.Manual
    if not (C_QuestLog and C_QuestLog.AddQuestWatch and try(C_QuestLog.AddQuestWatch, qid, manual)) then
      try(AddQuestWatch, idx)
    end
  end
  if QuestWatch_Update then pcall(QuestWatch_Update) end
  if IsWatched(qid, idx) == watched then
    print("|cffffd200Quest Ledger:|r couldn't change tracking for this quest.")
  end
end

local function DiffColor(level)
  if GetQuestDifficultyColor then return GetQuestDifficultyColor(level or UnitLevel("player")) end
  return { r = 1, g = 0.82, b = 0 }
end

-- money with gold/silver/copper icons, like the default UI
local function Coins(c)
  c = math.floor(c or 0)
  local g, s, cu = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local GI = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t"
  local SI = "|TInterface\\MoneyFrame\\UI-SilverIcon:14:14:2:0|t"
  local CI = "|TInterface\\MoneyFrame\\UI-CopperIcon:14:14:2:0|t"
  local out = {}
  if g > 0 then out[#out + 1] = g .. GI end
  if s > 0 then out[#out + 1] = s .. SI end
  if cu > 0 or #out == 0 then out[#out + 1] = cu .. CI end
  return table.concat(out, " ")
end

local function Friends(qid)
  local api = Mates()
  if not (api and qid) or (QuestLedgerForeverDB and QuestLedgerForeverDB.partyInfo == false) then return {} end
  local ok, res = pcall(api.FriendsOnQuest, qid)
  return ok and res or {}
end

---------------------------------------------------------------- main frame
-- Same window art as the Map (ButtonFrameTemplate = gold border, red close button, dark inset)
local NATIVE = true
local okTpl, f = pcall(CreateFrame, "Frame", "QuestLedgerForeverFrame", UIParent, "ButtonFrameTemplate")
if not okTpl or not f then
  NATIVE = false
  f = CreateFrame("Frame", "QuestLedgerForeverFrame2", UIParent, "BasicFrameTemplateWithInset")
end
if NATIVE then
  if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f)
  elseif f.PortraitContainer then f.PortraitContainer:Hide() end
  if f.Inset then
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -26)
    f.Inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 330, 32)
  end
end
f:SetSize(720, 540)
f:SetPoint("CENTER")
f:SetFrameStrata("HIGH")
f:SetToplevel(true)
f:EnableMouse(true)
f:SetMovable(true)
f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
local docked = false
f:SetScript("OnDragStart", function(s) if not docked then s:StartMoving() end end)
f:SetScript("OnDragStop", function(s)
  if docked then return end
  s:StopMovingOrSizing()
  local p, _, rp, x, y = s:GetPoint()
  DB.pos = { p, rp, x, y }
end)

local function PlaceFree()
  docked = false
  f:SetFrameStrata("HIGH")
  f:ClearAllPoints()
  if DB and DB.pos then f:SetPoint(DB.pos[1], UIParent, DB.pos[2], DB.pos[3], DB.pos[4])
  else f:SetPoint("CENTER") end
end

-- Attach to map: sit beside the map (right side, or left if there's no room).
local function MapEdge() return WorldMapFrame end
local function Dock()
  if not (DB and DB.attach and WorldMapFrame and WorldMapFrame:IsShown()) then
    if docked then PlaceFree() end
    return
  end
  local edge = MapEdge()
  local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local mr, ml = edge:GetRight(), edge:GetLeft()
  local ms = edge:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local w = f:GetWidth() * scale
  f:ClearAllPoints()
  if mr and mr * ms + w <= UIParent:GetRight() then
    f:SetPoint("TOPLEFT", edge, "TOPRIGHT", 2, 0)
    f:SetFrameStrata("DIALOG")
  elseif ml and ml * ms - w >= 0 then
    f:SetPoint("TOPRIGHT", edge, "TOPLEFT", -2, 0)
    f:SetFrameStrata("DIALOG")
  else
    PlaceFree() -- map is too wide: float instead
    return
  end
  docked = true
end
f:Hide()
tinsert(UISpecialFrames, f:GetName())

if NATIVE and f.SetTitle then
  f:SetTitle("Quest Ledger")
elseif NATIVE and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) then
  (f.TitleText or f.TitleContainer.TitleText):SetText("Quest Ledger")
else
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", 0, -5)
  f.title:SetText("Quest Ledger")
end

f.attach = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
f.attach:SetSize(24, 24)
f.attach:SetFrameLevel(f:GetFrameLevel() + 20) -- placed in the bottom bar further down
f.attach.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
f.attach.label:SetPoint("LEFT", f.attach, "RIGHT", 0, 1)
f.attach.label:SetText("Attach to map")
f.attach:SetScript("OnClick", function(b)
  DB.attach = b:GetChecked() and true or false
  Dock()
end)
f.attach:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Attach to map")
  GameTooltip:AddLine("The quest log sits beside the map and opens and closes with it.", 1, 1, 1, true)
  GameTooltip:Show()
end)
f.attach:SetScript("OnLeave", GameTooltip_Hide)

f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
f.count:SetPoint("TOPLEFT", 14, -34)

-- left: quest list (24 rows end above the bottom buttons)
local list = CreateFrame("Frame", nil, f)
list:SetPoint("TOPLEFT", 10, -50)
list:SetSize(290, ROW_H * NUM_ROWS)

local scroll = CreateFrame("Slider", nil, f, "UIPanelScrollBarTemplate")
-- the template's own handler expects a scroll frame parent (and crashes without one):
-- replace it right away; the real handler is set further down
scroll:SetScript("OnValueChanged", nil)
scroll:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, -16)
scroll:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 16)
scroll:SetMinMaxValues(0, 0)
scroll:SetValueStep(1)
scroll:SetObeyStepOnDrag(true)
scroll:SetValue(0)

local Refresh, ShowDetails

-- My quests / Party tabs (party tab only when QuestMates is loaded)
local function Tab(text, w, m)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(w, 18)
  b:SetText(text)
  b:SetScript("OnClick", function() mode = m; scroll:SetValue(0); Refresh() end)
  return b
end
local partyTab = Tab("Party", 76, "party")
partyTab:SetPoint("TOPRIGHT", list, "TOPRIGHT", 22, 20)
local mineTab = Tab("My Quests", 84, "mine")
mineTab:SetPoint("RIGHT", partyTab, "LEFT", -2, 0)

local rows = {}
local MAX_DOTS = 4
local MAX_ROWS = 60 -- enough for the tallest window
for i = 1, MAX_ROWS do
  local b = CreateFrame("Button", nil, list)
  b:SetSize(290, ROW_H)
  b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.sel = b:CreateTexture(nil, "BACKGROUND")
  b.sel:SetAllPoints()
  b.sel:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  b.sel:SetBlendMode("ADD")
  b.sel:Hide()
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(14, 14)
  b.icon:SetPoint("LEFT", 2, 0)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.text:SetJustifyH("LEFT")
  b.text:SetWordWrap(false)
  b.tag = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.tag:SetPoint("RIGHT", -4, 0)
  b.check = b:CreateTexture(nil, "OVERLAY")
  b.check:SetSize(12, 12)
  b.check:SetPoint("RIGHT", -64, 0)
  b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  b.dots = {}
  for d = 1, MAX_DOTS do
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetSize(8, 8)
    b.dots[d] = t
  end
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(s, btn)
    local e = s.entry
    if not e then return end
    if e.party then
      local api = Mates()
      if not api then return end
      if e.header then api.ToggleCollapsed(e.who) Refresh()
      elseif e.q then api.OpenQuest(e.q, e.who) end
      return
    end
    if e.header and IsShiftKeyDown() and btn ~= "RightButton" then
      -- Shift-click a zone: track all its quests (or untrack all if they're all tracked)
      local list, header = {}, nil
      for i = 1, NumEntries() do
        local title, _, isHeader, _, _, qid = EntryInfo(i)
        if title then
          if isHeader then header = title
          elseif header == e.title then list[#list + 1] = { qid, i } end
        end
      end
      local allOn = #list > 0
      for _, q in ipairs(list) do if not IsWatched(q[1], q[2]) then allOn = false; break end end
      for _, q in ipairs(list) do
        if IsWatched(q[1], q[2]) == allOn then ToggleWatch(q[1], q[2]) end
      end
      Refresh()
    elseif e.header then
      collapsed[e.title] = not collapsed[e.title]
      Refresh()
    elseif btn == "RightButton" then
      if QLF_ShowQuestMenu then QLF_ShowQuestMenu(s, e.qid) end
    elseif IsShiftKeyDown() then
      -- like the classic quest log: chat box open = link the quest, otherwise track / untrack it
      local chatOpen = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
      local link = chatOpen and GetQuestLink and GetQuestLink(MODERN and e.qid or e.index)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      else
        ToggleWatch(e.qid, e.index)
        Refresh()
      end
    else
      selectedID = e.qid
      Refresh()
      PointArrow(e.qid)
    end
  end)
  b:SetScript("OnEnter", function(s)
    local e = s.entry
    if not e then return end
    if e.party then
      if e.q and Mates() then Mates().QuestTooltip(s, e.q, e.who) end
      return
    end
    local hasFriends = e.friends and #e.friends > 0
    if e.header or (not hasFriends and not e.inst) then return end
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    if e.inst then
      GameTooltip:AddLine((e.inst == "raid" and "Raid" or "Dungeon") .. (e.instName and (": " .. e.instName) or ""),
        e.inst == "raid" and 1 or 0.7, e.inst == "raid" and 0.5 or 0.55, e.inst == "raid" and 0.3 or 1)
    end
    if hasFriends then
      GameTooltip:AddLine("Also on this quest:", 1, 0.82, 0)
      for _, fr in ipairs(e.friends) do
        GameTooltip:AddLine(fr.who .. (fr.complete and "  |cff4dff4d(done)|r" or ""), fr.color[1], fr.color[2], fr.color[3])
      end
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  rows[i] = b
  if i > NUM_ROWS then b:Hide() end
end

list:EnableMouseWheel(true)
list:SetScript("OnMouseWheel", function(_, d) scroll:SetValue(scroll:GetValue() - d * 3) end)
scroll:SetScript("OnValueChanged", function() Refresh() end)

-- right: details
local detail = CreateFrame("ScrollFrame", "QuestLedgerForeverDetail", f, "UIPanelScrollFrameTemplate")
detail:SetPoint("TOPLEFT", 340, -32)
detail:SetPoint("BOTTOMRIGHT", -30, NATIVE and 36 or 44)
local dc = CreateFrame("Frame", nil, detail)
dc:SetSize(340, 10)
detail:SetScrollChild(dc)

local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
bg:SetPoint("TOPLEFT", detail, -4, 4)
bg:SetPoint("BOTTOMRIGHT", detail, 4, -4)
bg:SetTexture("Interface\\QuestFrame\\QuestBG")
bg:SetTexCoord(0, 0.586, 0.02, 0.655)
bg:SetVertexColor(1, 1, 1, 0.9)

local INK = { 0.18, 0.12, 0.06 }
local DW = 330 -- text width on the quest page (grows with the window)
local fsList = {}
local function FS(template)
  local s = dc:CreateFontString(nil, "OVERLAY", template)
  s:SetWidth(DW)
  fsList[#fsList + 1] = s
  s:SetJustifyH("LEFT")
  s:SetTextColor(INK[1], INK[2], INK[3])
  return s
end
local dTitle = FS("QuestTitleFont")
local dObj = FS("QuestFont")
local dObjList = FS("QuestFont")
local dPartyH = FS("QuestTitleFont")
local dParty = FS("QuestFont")
local dDescH = FS("QuestTitleFont")
local dDesc = FS("QuestFont")
local dRewH = FS("QuestTitleFont")
-- dark tooltip-style box behind the rewards
local rewardBox = CreateFrame("Frame", nil, dc, BackdropTemplateMixin and "BackdropTemplate" or nil)
if rewardBox.SetBackdrop then
  rewardBox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  rewardBox:SetBackdropColor(0, 0, 0, 0)
  rewardBox:SetBackdropBorderColor(0, 0, 0, 0)
end
rewardBox:SetFrameLevel(dc:GetFrameLevel() + 1)
rewardBox:Hide()
local rewardTop = CreateFrame("Frame", nil, dc)
rewardTop:SetSize(1, 1)
local dMoney = rewardBox:CreateFontString(nil, "OVERLAY", "QuestFont")
dMoney:SetJustifyH("LEFT")
dMoney:SetWidth(320)
local dChooseL = FS("QuestFont")
-- experience: big purple number + a level bar (now / this quest adds)
local dXP = dc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dXP:SetTextColor(0.35, 0.16, 0.54)
dXP:SetJustifyH("LEFT")
dXP:Hide()
local xpBar = CreateFrame("Frame", nil, dc)
xpBar:SetSize(300, 10)
xpBar.bg = xpBar:CreateTexture(nil, "BACKGROUND"); xpBar.bg:SetAllPoints(); xpBar.bg:SetColorTexture(0.23, 0.16, 0.06, 1)
xpBar.now = xpBar:CreateTexture(nil, "ARTWORK"); xpBar.now:SetPoint("TOPLEFT"); xpBar.now:SetPoint("BOTTOMLEFT")
xpBar.now:SetColorTexture(0.48, 0.25, 0.69, 1)
xpBar.gain = xpBar:CreateTexture(nil, "ARTWORK"); xpBar.gain:SetPoint("TOPLEFT", xpBar.now, "TOPRIGHT"); xpBar.gain:SetPoint("BOTTOMLEFT", xpBar.now, "BOTTOMRIGHT")
xpBar.gain:SetColorTexture(0.78, 0.61, 0.94, 1)
xpBar.edge = xpBar:CreateTexture(nil, "OVERLAY")
xpBar.edge:SetPoint("TOPLEFT", -1, 1); xpBar.edge:SetPoint("BOTTOMRIGHT", 1, -1)
xpBar.edge:SetColorTexture(0.1, 0.07, 0.03, 0.9); xpBar.edge:SetDrawLayer("BACKGROUND", -1)
xpBar:Hide()
local dXPNote = FS("GameFontNormalSmall")
dXPNote:SetTextColor(0.35, 0.27, 0.19)
dXPNote:Hide()
local function HideXP() dXP:Hide(); xpBar:Hide(); dXPNote:Hide() end
local dGetL = FS("QuestFont")
dMoney:SetTextColor(INK[1], INK[2], INK[3])
dMoney:SetShadowOffset(0, 0)
dTitle:SetPoint("TOPLEFT", 6, -6)
dPartyH:SetText("Party")
dDescH:SetText("Description")
dRewH:SetText("Rewards")

local rewardBtns = {}
local function RewardButton(i)
  if rewardBtns[i] then return rewardBtns[i] end
  local b = CreateFrame("Button", nil, dc)
  b:SetSize(158, 41)
  b:SetFrameLevel(dc:GetFrameLevel() + 5)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(37, 37)
  b.icon:SetPoint("LEFT")
  -- the original Blizzard item name plate
  b.plate = b:CreateTexture(nil, "BACKGROUND")
  b.plate:SetTexture("Interface\\QuestFrame\\UI-QuestItemNameFrame")
  b.plate:SetSize(128, 64)
  b.plate:SetPoint("LEFT", b.icon, "RIGHT", -10, 0)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("BOTTOMRIGHT", b.icon, -1, 2)
  -- best vendor value (bag) and upgrade (green arrow) markers
  b.bag = b:CreateTexture(nil, "OVERLAY", nil, 2)
  b.bag:SetSize(16, 16)
  b.bag:SetPoint("TOPLEFT", b.icon, -4, 4)
  if not (b.bag.SetAtlas and b.bag:SetAtlas("bags-junkcoin")) then b.bag:SetTexture("Interface\\Icons\\INV_Misc_Bag_10") end
  b.bag:Hide()
  b.up = b:CreateTexture(nil, "OVERLAY", nil, 2)
  b.up:SetSize(16, 16)
  b.up:SetPoint("TOPRIGHT", b.icon, 4, 4)
  if not (b.up.SetAtlas and b.up:SetAtlas("bags-greenarrow")) then
    b.up:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"); b.up:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    b.up:SetVertexColor(0.2, 1, 0.2)
  end
  b.up:Hide()
  b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
  b.name:SetWidth(98)
  b.name:SetHeight(36)
  b.name:SetJustifyV("MIDDLE")
  b.name:SetJustifyH("LEFT")
  b.name:SetShadowColor(0, 0, 0, 1)
  b.name:SetShadowOffset(1, -1)
  b:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    GameTooltip:SetQuestLogItem(s.kind, s.idx)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  -- act on mouse DOWN: the log redraws often, and a redraw between press and release cancels OnClick
  b:SetScript("OnMouseDown", function(s, btn)
    if btn ~= "LeftButton" then return end
    if selectedID then Select(selectedID) end
    local link = GetQuestLogItemLink and GetQuestLogItemLink(s.kind, s.idx)
    if not link then -- fallback: read the link from a hidden tooltip
      QLF_ScanTip = QLF_ScanTip or CreateFrame("GameTooltip", "QLF_ScanTip", UIParent, "GameTooltipTemplate")
      QLF_ScanTip:SetOwner(UIParent, "ANCHOR_NONE")
      QLF_ScanTip:SetQuestLogItem(s.kind, s.idx)
      local _, l = QLF_ScanTip:GetItem()
      QLF_ScanTip:Hide()
      link = l
    end
    if not link then
      if IsControlKeyDown() then print("|cffffd200Quest Ledger:|r couldn't read this reward's item link.") end
      return
    end
    if IsControlKeyDown() then          -- Ctrl-click: dressing room
      QLF_KeepOpenUntil = GetTime() + 1 -- the game may close the map to make room; keep the log open
      local ok
      if DressUpItemLink then ok = pcall(DressUpItemLink, link)
      elseif DressUpLink then ok = pcall(DressUpLink, link) end
      if not ok then
        print("|cffffd200Quest Ledger:|r dressing room failed (DressUpItemLink=" .. tostring(DressUpItemLink ~= nil)
          .. ", DressUpLink=" .. tostring(DressUpLink ~= nil) .. ") for " .. link)
      elseif DressUpFrame and not DressUpFrame:IsShown() and ShowUIPanel then
        ShowUIPanel(DressUpFrame)
      end
      -- put the dressing room in front of the quest log and the map
      local function Front()
        if DressUpFrame then
          DressUpFrame:SetFrameStrata("FULLSCREEN_DIALOG")
          DressUpFrame:Raise()
        end
      end
      Front()
      C_Timer.After(0, Front)
    elseif IsShiftKeyDown() then        -- Shift-click: link in chat (opens the chat box if needed)
      local done = ChatEdit_InsertLink and ChatEdit_InsertLink(link)
      if not done and ChatFrame_OpenChat then ChatFrame_OpenChat(link) end
    elseif HandleModifiedItemClick then
      HandleModifiedItemClick(link)
    end
  end)
  rewardBtns[i] = b
  return b
end

local function Hex(c) return string.format("|cff%02x%02x%02x", c[1] * 200, c[2] * 200, c[3] * 200) end


-- reward helpers: vendor value and "is this an upgrade for me?"
local SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
  INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
  INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
  INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
  INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
  INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
local function ItemLevel(link)
  if not link then return 0 end
  if GetDetailedItemLevelInfo then local l = GetDetailedItemLevelInfo(link); if l then return l end end
  return (GetItemInfo and select(4, GetItemInfo(link))) or 0
end
-- red text in the tooltip = your class/skills can't use it
local function CanUse(kind, idx, questFrame)
  QLF_ScanTip = QLF_ScanTip or CreateFrame("GameTooltip", "QLF_ScanTip", UIParent, "GameTooltipTemplate")
  QLF_ScanTip:SetOwner(UIParent, "ANCHOR_NONE")
  if questFrame then QLF_ScanTip:SetQuestItem(kind, idx) else QLF_ScanTip:SetQuestLogItem(kind, idx) end
  for i = 2, QLF_ScanTip:NumLines() do
    for _, side in ipairs({ "Left", "Right" }) do
      local fs = _G["QLF_ScanTipText" .. side .. i]
      if fs and fs:IsShown() and (fs:GetText() or "") ~= "" then
        local r, g, b = fs:GetTextColor()
        if r > 0.9 and g < 0.2 and b < 0.2 then QLF_ScanTip:Hide(); return false end
      end
    end
  end
  QLF_ScanTip:Hide()
  return true
end
-- What your class/spec wants: stat weights per talent tree (most points spent; default when no talents)
local W = {
  STR = "ITEM_MOD_STRENGTH_SHORT", AGI = "ITEM_MOD_AGILITY_SHORT", STA = "ITEM_MOD_STAMINA_SHORT",
  INT = "ITEM_MOD_INTELLECT_SHORT", SPI = "ITEM_MOD_SPIRIT_SHORT", AP = "ITEM_MOD_ATTACK_POWER_SHORT",
  SP = "ITEM_MOD_SPELL_POWER_SHORT", CRIT = "ITEM_MOD_CRIT_RATING_SHORT", HIT = "ITEM_MOD_HIT_RATING_SHORT",
  ARMOR = "RESISTANCE0_NAME",
}
local MELEE = { STR = 1, AGI = 0.6, STA = 0.5, AP = 0.5, CRIT = 0.8, HIT = 0.8, ARMOR = 0.02 }
local CASTER = { INT = 1, SP = 1, SPI = 0.3, STA = 0.4, CRIT = 0.6, HIT = 0.6, ARMOR = 0.01 }
local HEALER = { INT = 1, SP = 0.9, SPI = 0.6, STA = 0.3, ARMOR = 0.01 }
local WEIGHTS = {
  WARRIOR = { MELEE, MELEE, { STA = 1, STR = 0.6, AGI = 0.5, ARMOR = 0.05 }, default = 1 },
  PALADIN = { HEALER, { STA = 1, STR = 0.6, AGI = 0.4, INT = 0.2, ARMOR = 0.05 }, { STR = 1, AGI = 0.5, STA = 0.4, AP = 0.5, CRIT = 0.8, INT = 0.2, ARMOR = 0.02 }, default = 3 },
  HUNTER  = { { AGI = 1, AP = 0.5, INT = 0.3, STA = 0.4, CRIT = 0.8, HIT = 0.8, ARMOR = 0.01 }, default = 1 },
  ROGUE   = { { AGI = 1, STR = 0.5, AP = 0.5, STA = 0.3, CRIT = 0.8, HIT = 0.8, ARMOR = 0.01 }, default = 1 },
  PRIEST  = { HEALER, HEALER, CASTER, default = 3 },
  SHAMAN  = { CASTER, { STR = 1, AGI = 0.8, AP = 0.5, STA = 0.4, CRIT = 0.8, HIT = 0.8, INT = 0.2, ARMOR = 0.02 }, HEALER, default = 2 },
  MAGE    = { CASTER, default = 1 },
  WARLOCK = { CASTER, default = 1 },
  DRUID   = { CASTER, { AGI = 1, STR = 0.8, STA = 0.6, AP = 0.5, CRIT = 0.8, ARMOR = 0.03 }, HEALER, default = 2 },
}
local function SpecWeights()
  local _, class = UnitClass("player")
  local set = WEIGHTS[class] or { MELEE, default = 1 }
  local best, bestPts = set.default, 0
  if GetNumTalentTabs and GetTalentTabInfo then
    for t = 1, GetNumTalentTabs() do
      local r = { GetTalentTabInfo(t) }
      local pts = (type(r[3]) == "number" and r[3]) or (type(r[5]) == "number" and r[5]) or 0
      if pts > bestPts then best, bestPts = t, pts end
    end
  end
  return set[best] or set[1]
end
-- best armor type your class can wear right now (1 cloth, 2 leather, 3 mail, 4 plate)
local function BestArmor()
  local _, class = UnitClass("player")
  local lvl = UnitLevel("player")
  if class == "WARRIOR" or class == "PALADIN" then return lvl >= 40 and 4 or 3 end
  if class == "HUNTER" or class == "SHAMAN" then return lvl >= 40 and 3 or 2 end
  if class == "ROGUE" or class == "DRUID" then return 2 end
  return 1
end
local GetItemStatsF = GetItemStats or (C_Item and C_Item.GetItemStats)
local function Score(link, weights)
  if not GetItemStatsF then return nil end
  local ok, stats = pcall(GetItemStatsF, link)
  if not ok or type(stats) ~= "table" then return nil end
  local total = 0
  for key, w in pairs(weights) do total = total + (stats[W[key]] or 0) * w end
  return total
end
local function IsUpgrade(link, kind, idx, questFrame)
  if not link or not GetItemInfo then return false end
  local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subID = GetItemInfo(link)
  local slots = equipLoc and SLOTS[equipLoc]
  if not slots or not CanUse(kind, idx, questFrame) then return false end
  -- armor below your class's best type is never an upgrade (cloaks are always cloth: exempt)
  if classID == 4 and subID and subID >= 1 and subID <= 4 and equipLoc ~= "INVTYPE_CLOAK" and subID < BestArmor() then
    return false
  end
  local weights = SpecWeights()
  local mine = Score(link, weights)
  local lowest, lowestIsScore
  for _, slot in ipairs(slots) do
    local eq = GetInventoryItemLink("player", slot)
    if not eq then
      if slot ~= 17 or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
        return true -- empty slot
      end
    else
      local v = mine and Score(eq, weights)
      if v then lowestIsScore = true else v = ItemLevel(eq) end
      if not lowest or v < lowest then lowest = v end
    end
  end
  if not lowest then return false end
  if mine and lowestIsScore then return mine > lowest + 0.5 end -- small margin: no arrow for a near-tie
  return ItemLevel(link) > lowest
end


-- Same markers on the game's own quest window (quest offered / handing in)
local npcMarks = {}
local function NPCRewardButton(i)
  local rf = QuestInfoRewardsFrame
  return (rf and rf.RewardButtons and rf.RewardButtons[i]) or _G["QuestInfoRewardsFrameQuestInfoItem" .. i] or _G["QuestInfoItem" .. i]
end
local function MarkFor(btn)
  local m = npcMarks[btn]
  if m then return m end
  local icon = btn.Icon or (btn:GetName() and _G[btn:GetName() .. "IconTexture"]) or btn
  m = {}
  m.bag = btn:CreateTexture(nil, "OVERLAY", nil, 7)
  m.bag:SetSize(16, 16); m.bag:SetPoint("TOPLEFT", icon, -4, 4)
  if not (m.bag.SetAtlas and m.bag:SetAtlas("bags-junkcoin")) then m.bag:SetTexture("Interface\\Icons\\INV_Misc_Bag_10") end
  m.up = btn:CreateTexture(nil, "OVERLAY", nil, 7)
  m.up:SetSize(16, 16); m.up:SetPoint("TOPRIGHT", icon, 4, 4)
  if not (m.up.SetAtlas and m.up:SetAtlas("bags-greenarrow")) then
    m.up:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"); m.up:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    m.up:SetVertexColor(0.2, 1, 0.2)
  end
  npcMarks[btn] = m
  return m
end
function QLF_MarkQuestFrame()
  if not (QuestFrame and QuestFrame:IsShown()) or (DB and DB.rewardMarks == false) then return end
  local bestM, bestPrice, nChoices = nil, 0, 0
  for i = 1, 12 do
    local b = NPCRewardButton(i)
    if b and b:IsShown() and b.type and b.type ~= "spell" then
      local m = MarkFor(b)
      local kind, id = b.type, b:GetID()
      local link = GetQuestItemLink and GetQuestItemLink(kind, id)
      m.bag:Hide()
      m.up:SetShown(IsUpgrade(link, kind, id, true))
      if kind == "choice" and link then
        nChoices = nChoices + 1
        local price = (GetItemInfo and select(11, GetItemInfo(link))) or 0
        local _, _, cnt = GetQuestItemInfo(kind, id)
        price = price * math.max(1, cnt or 1)
        if price > bestPrice then bestM, bestPrice = m, price end
      end
    elseif b and npcMarks[b] then
      npcMarks[b].bag:Hide(); npcMarks[b].up:Hide()
    end
  end
  if bestM and nChoices > 1 then bestM.bag:Show() end
end
local function MarkSoon() C_Timer.After(0.05, QLF_MarkQuestFrame); C_Timer.After(0.5, QLF_MarkQuestFrame) end
local qfev = CreateFrame("Frame")
qfev:RegisterEvent("QUEST_COMPLETE"); qfev:RegisterEvent("QUEST_DETAIL")
qfev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
qfev:SetScript("OnEvent", MarkSoon)
if QuestInfo_Display then hooksecurefunc("QuestInfo_Display", MarkSoon) end


---------------------------------------------------------------- quest chain icon (data: Chains.lua)
local function QuestDone(id)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompleted, id); if ok then return v end
  end
  if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(id) end
  return false
end
local function BuildChain(qid)
  local data = QuestLedgerForever_Chains
  if not (data and data[qid]) then return end
  local me = (UnitFactionGroup("player") == "Horde") and 2 or 1
  local function ok(id) local d = data[id]; return d and (d[3] == 0 or d[3] == me) end
  local dist, order = { [qid] = 0 }, { qid }
  local function walk(field, sign)
    local queue, head = { qid }, 1
    while queue[head] and #order < 40 do
      local cur = queue[head]; head = head + 1
      for _, nid in ipairs(data[cur][field] or {}) do
        if ok(nid) and dist[nid] == nil then
          dist[nid] = dist[cur] + sign
          order[#order + 1] = nid
          queue[#queue + 1] = nid
        end
      end
    end
  end
  walk(4, -1) -- earlier steps
  walk(5, 1)  -- later steps
  if #order < 2 then return end
  table.sort(order, function(a, b)
    if dist[a] ~= dist[b] then return dist[a] < dist[b] end
    return (data[a][2] or 0) < (data[b][2] or 0)
  end)
  local steps, pos = {}, 1
  for i, id in ipairs(order) do
    local status = (id == qid and "current") or (IndexForQuest(id) and "active") or (QuestDone(id) and "done") or "todo"
    steps[i] = { id = id, name = data[id][1], level = data[id][2], status = status }
    if id == qid then pos = i end
  end
  return steps, pos
end

local chainBtn = CreateFrame("Button", nil, dc)
chainBtn:SetSize(22, 22)
chainBtn:SetFrameLevel(dc:GetFrameLevel() + 6)
chainBtn.icon = chainBtn:CreateTexture(nil, "ARTWORK")
chainBtn.icon:SetAllPoints()
-- quest-book icon (exists in every client)
chainBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")

chainBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
chainBtn.step = chainBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
chainBtn.step:SetPoint("RIGHT", chainBtn, "LEFT", -3, 0)
chainBtn.step:SetTextColor(INK[1], INK[2], INK[3])
chainBtn:Hide()
chainBtn:SetScript("OnEnter", function(b)
  if not b.steps then return end
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Quest chain", 1, 0.82, 0)
  for _, st in ipairs(b.steps) do
    local mark, r, g, bl
    if st.status == "current" then mark, r, g, bl = "> ", 1, 0.82, 0
    elseif st.status == "active" then mark, r, g, bl = "* ", 1, 1, 1
    elseif st.status == "done" then mark, r, g, bl = "|TInterface\\Buttons\\UI-CheckBox-Check:12:12|t ", 0.45, 0.75, 0.45
    else mark, r, g, bl = "   ", 0.6, 0.6, 0.6 end
    GameTooltip:AddDoubleLine(mark .. st.name, st.level and st.level > 0 and ("[" .. st.level .. "]") or "", r, g, bl, r, g, bl)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("> this quest   * in your log   check = done", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end)
chainBtn:SetScript("OnLeave", GameTooltip_Hide)

local function UpdateChainIcon(qid)
  local steps, pos
  if qid then steps, pos = BuildChain(qid) end
  chainBtn.steps = steps
  if not steps or (DB and DB.chains == false) then chainBtn:Hide(); return end
  chainBtn:ClearAllPoints()
  chainBtn:SetPoint("TOPRIGHT", dc, "TOPRIGHT", -6, -4)
  chainBtn.step:SetText(("Step %d/%d"):format(pos or 1, #steps))
  chainBtn:Show()
end

ShowDetails = function()
  for _, b in ipairs(rewardBtns) do b:Hide() end
  local idx = selectedID and Select(selectedID)
  if not idx then
    dTitle:SetText("No quest selected")
    chainBtn:Hide()
    for _, s in ipairs({ dObj, dObjList, dPartyH, dParty, dDescH, dDesc, dRewH, dMoney }) do s:Hide() end
    HideXP()
    rewardBox:Hide()
    return
  end
  for _, s in ipairs({ dObj, dObjList, dDescH, dDesc }) do s:Show() end
  local title, level = EntryInfo(idx)
  dTitle:SetText((level and level > 0 and ("[" .. level .. "] ") or "") .. (title or ""))
  UpdateChainIcon(selectedID)
  dTitle:SetWidth(chainBtn:IsShown() and DW - 50 or DW)
  local desc, objText = GetQuestLogQuestText()
  dObj:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -8)
  dObj:SetText(objText or "")

  local lines = {}
  local n = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(idx) or 0
  for j = 1, n do
    local text, _, done = GetQuestLogLeaderBoard(j, idx)
    if text then
      lines[#lines + 1] = (done and "|cff2a7a2a" or "|cff4a3a20") .. "- " .. text .. "|r"
    end
  end
  dObjList:SetPoint("TOPLEFT", dObj, "BOTTOMLEFT", 0, -6)
  dObjList:SetText(table.concat(lines, "\n"))
  local last = dObjList

  -- QuestMates: party members' progress on this quest
  local fr = Friends(selectedID)
  if #fr > 0 then
    local pl = {}
    for _, p in ipairs(fr) do
      pl[#pl + 1] = Hex(p.color) .. p.who .. "|r" .. (p.complete and "  |cff2a7a2aready to turn in|r" or "")
      if not p.complete then
        for _, o in ipairs(p.objs) do
          pl[#pl + 1] = (o.done and "|cff2a7a2a" or "|cff4a3a20") .. "   - " .. (o.text or "") .. "|r"
        end
      end
    end
    dPartyH:Show(); dParty:Show()
    dPartyH:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    dParty:SetPoint("TOPLEFT", dPartyH, "BOTTOMLEFT", 0, -6)
    dParty:SetText(table.concat(pl, "\n"))
    last = dParty
  else
    dPartyH:Hide(); dParty:Hide()
  end

  dDescH:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
  dDesc:SetPoint("TOPLEFT", dDescH, "BOTTOMLEFT", 0, -6)
  dDesc:SetText(desc or "")
  last = dDesc

  local nChoice = GetNumQuestLogChoices and (MODERN and GetNumQuestLogChoices(selectedID) or GetNumQuestLogChoices()) or 0
  local nRew = GetNumQuestLogRewards and GetNumQuestLogRewards() or 0
  local money = GetQuestLogRewardMoney and GetQuestLogRewardMoney() or 0
  local xp = GetQuestLogRewardXP and GetQuestLogRewardXP() or 0
  if nChoice + nRew > 0 or money > 0 or xp > 0 then
    dRewH:Show()
    dRewH:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    dChooseL:Hide(); dGetL:Hide()
    last = dRewH
    local bi = 0
    local function color(b, quality, kind, i)
      if (not quality or quality < 0) and GetQuestLogItemLink and GetItemInfo then
        local link = GetQuestLogItemLink(kind, i)
        if link then quality = select(3, GetItemInfo(link)) end
      end
      local r, g, bl = 1, 1, 1
      if quality and quality >= 0 then
        if GetItemQualityColor then r, g, bl = GetItemQualityColor(quality)
        elseif ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
          local c = ITEM_QUALITY_COLORS[quality]; r, g, bl = c.r, c.g, c.b
        end
      end
      b.name:SetTextColor(r, g, bl)
    end
    local function grid(kind, n, getInfo, label, labelText)
      if n == 0 then return end
      label:SetText(labelText)
      label:ClearAllPoints()
      label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -6)
      label:Show()
      last = label
      local rowStart
      for i = 1, n do
        local name, tex, count, quality = getInfo(i)
        bi = bi + 1
        local b = RewardButton(bi)
        b.kind, b.idx = kind, i
        b.icon:SetTexture(tex)
        b.name:SetText(name or "")
        color(b, quality, kind, i)
        b.count:SetText((count and count > 1) and count or "")
        b:ClearAllPoints()
        if (i - 1) % 2 == 0 then
          b:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -4)
          rowStart = b
        else
          b:SetPoint("LEFT", rowStart, "RIGHT", 8, 0)
          last = rowStart
        end
        b:Show()
      end
      if n % 2 == 1 then last = rowStart end
    end
    grid("choice", nChoice, GetQuestLogChoiceInfo, dChooseL, REWARD_CHOICES or "You will be able to choose one of these rewards:")
    grid("reward", nRew, GetQuestLogRewardInfo, dGetL,
      nChoice > 0 and (REWARD_ITEMS or "You will also receive:") or (REWARD_ITEMS_ONLY or "You will receive:"))
    -- markers: bag = best vendor price among the choices, arrow = upgrade for you
    local bestBtn, bestPrice = nil, 0
    for n = 1, bi do
      local b = rewardBtns[n]
      local link = GetQuestLogItemLink and GetQuestLogItemLink(b.kind, b.idx)
      b.bag:Hide()
      b.up:SetShown(DB.rewardMarks ~= false and IsUpgrade(link, b.kind, b.idx))
      if b.kind == "choice" and nChoice > 1 and link then
        local price = (GetItemInfo and select(11, GetItemInfo(link))) or 0
        local _, _, cnt = GetQuestLogChoiceInfo(b.idx)
        price = price * math.max(1, cnt or 1)
        if price > bestPrice then bestBtn, bestPrice = b, price end
      end
    end
    if bestBtn and DB.rewardMarks ~= false then bestBtn.bag:Show() end
    local m = {}
    if money > 0 then m[#m + 1] = Coins(money) end
    if (#m > 0 or xp > 0) and nChoice + nRew == 0 then
      dGetL:SetText(REWARD_ITEMS_ONLY or "You will receive:")
      dGetL:ClearAllPoints(); dGetL:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -6); dGetL:Show()
      last = dGetL
    end
    dMoney:SetShown(#m > 0)
    dMoney:ClearAllPoints()
    dMoney:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -8)
    dMoney:SetText(table.concat(m, "     "))
    if #m > 0 then last = dMoney end
    -- experience with a level bar
    HideXP()
    local maxXP = UnitXPMax and UnitXPMax("player") or 0
    if xp > 0 then
      local function fmt(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end
      dXP:SetText("+" .. fmt(xp) .. " XP")
      dXP:ClearAllPoints(); dXP:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -8); dXP:Show()
      last = dXP
      if maxXP and maxXP > 0 and UnitLevel("player") < (GetMaxPlayerLevel and GetMaxPlayerLevel() or 60) then
        local cur, lvl = UnitXP("player") or 0, UnitLevel("player")
        local w = xpBar:GetWidth()
        local nowW = math.max(0.001, w * cur / maxXP)
        local gainW = math.max(0.001, math.min(w - nowW, w * xp / maxXP))
        xpBar.now:SetWidth(nowW); xpBar.gain:SetWidth(gainW)
        xpBar:ClearAllPoints(); xpBar:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 1, -4); xpBar:Show()
        local pct = math.floor(xp / maxXP * 100 + 0.5)
        if cur + xp >= maxXP then
          dXPNote:SetText(("+%d%% of level %d  -  |cffa06a00enough to reach level %d!|r"):format(pct, lvl, lvl + 1))
        else
          dXPNote:SetText(("+%d%% of level %d"):format(pct, lvl))
        end
        dXPNote:ClearAllPoints(); dXPNote:SetPoint("TOPLEFT", xpBar, "BOTTOMLEFT", -1, -3); dXPNote:Show()
        last = dXPNote
      end
    end
    rewardBox:ClearAllPoints()
    rewardBox:SetPoint("TOPLEFT", dRewH, "BOTTOMLEFT", 0, 0)
    rewardBox:SetSize(1, 1)
    rewardBox:Show()
  else
    dRewH:Hide()
    dMoney:Hide()
    dChooseL:Hide(); dGetL:Hide()
    HideXP()
    rewardBox:Hide()
  end
  -- size the page to its content so it can't scroll past the end
  local function FitPage()
    local top = dc:GetTop()
    if not top then return end
    local low = top
    local function consider(r) if r and r:IsShown() then local bt = r:GetBottom(); if bt and bt < low then low = bt end end end
    for _, r in ipairs({ dTitle, dObj, dObjList, dPartyH, dParty, dDescH, dDesc, dRewH, dChooseL, dGetL, dMoney, dXP, xpBar, dXPNote }) do consider(r) end
    for _, rb in ipairs(rewardBtns) do consider(rb) end
    local h = math.max(detail:GetHeight() or 0, (top - low) + 16)
    dc:SetHeight(h)
    local maxScroll = math.max(0, h - (detail:GetHeight() or 0))
    if detail:GetVerticalScroll() > maxScroll then detail:SetVerticalScroll(maxScroll) end
    if detail.UpdateScrollChildRect then detail:UpdateScrollChildRect() end
  end
  dc:SetHeight(math.max(dc:GetHeight() or 10, 10))
  FitPage()
  C_Timer.After(0, FitPage) -- text sizes settle one frame later
end

---------------------------------------------------------------- buttons
local function Btn(text, w, onClick)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local abandon = Btn("Abandon", 90, function()
  local idx = selectedID and Select(selectedID)
  if not idx then return end
  local title = EntryInfo(idx)
  if MODERN and C_QuestLog.SetAbandonQuest then C_QuestLog.SetAbandonQuest() elseif SetAbandonQuest then SetAbandonQuest() end
  StaticPopup_Show("ABANDON_QUEST", title)
end)
abandon:SetPoint("BOTTOMLEFT", NATIVE and 12 or 16, NATIVE and 5 or 12)

local share = Btn("Share", 80, function()
  if selectedID and Select(selectedID) and QuestLogPushQuest then QuestLogPushQuest() end
end)
share:SetPoint("LEFT", abandon, "RIGHT", 4, 0)

local track = Btn("Track", 80, function()
  local idx = selectedID and IndexForQuest(selectedID)
  if idx then ToggleWatch(selectedID, idx); Refresh() end
end)
track:SetPoint("LEFT", share, "RIGHT", 4, 0)

-- zone name -> map ID (built once from the game's map list)
local zoneMaps
local function MapIDForZoneName(name)
  if not (name and C_Map and C_Map.GetMapInfo) then return end
  if not zoneMaps then
    zoneMaps = {}
    for id = 1, 3000 do
      local info = C_Map.GetMapInfo(id)
      if info and info.name and info.name ~= "" then
        local t = info.mapType
        -- prefer zones (3) / dungeons (4) / continents (2); keep the first good match
        local rank = (t == 3 and 1) or (t == 4 and 2) or (t == 2 and 3) or 4
        local cur = zoneMaps[info.name]
        if not cur or rank < cur.rank then zoneMaps[info.name] = { id = id, rank = rank } end
      end
    end
  end
  local hit = zoneMaps[name]
  return hit and hit.id
end

local function OpenMapToQuest(qid)
  local mapID = qid and GetQuestUiMapID and GetQuestUiMapID(qid)
  if (not mapID or mapID == 0) and qid then mapID = MapIDForZoneName(HeaderForQuest(qid)) end
  if (not mapID or mapID == 0) and C_Map and C_Map.GetBestMapForUnit then mapID = C_Map.GetBestMapForUnit("player") end
  if WorldMapFrame and not WorldMapFrame:IsShown() then
    if ToggleWorldMap then ToggleWorldMap() else ShowUIPanel(WorldMapFrame) end
  end
  -- the map only draws icons for tracked quests: track it while the map is open, then untrack again
  if tempWatch and tempWatch ~= qid then
    local old = tempWatch; tempWatch = nil
    if IsWatched(old) then ToggleWatch(old, nil, true) end
  end
  if qid and not tempWatch and not IsWatched(qid) then
    ToggleWatch(qid, nil, true)
    if IsWatched(qid) then
      tempWatch = qid
      local function MapOpen()
        if WorldMapFrame and WorldMapFrame:IsShown() then return true end
      end
      local t; t = C_Timer.NewTicker(0.5, function()
        if tempWatch ~= qid then t:Cancel(); return end
        if not MapOpen() then
          t:Cancel(); tempWatch = nil
          if IsWatched(qid) then ToggleWatch(qid, nil, true) end
          if Refresh then Refresh() end
        end
      end)
    end
  end
  if mapID and mapID > 0 and WorldMapFrame and WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(mapID) end
  if qid and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then pcall(C_SuperTrack.SetSuperTrackedQuestID, qid) end
end

local mapBtn = Btn("Show on Map", 110, function()
  if true then OpenMapToQuest(selectedID)
  elseif selectedID and QuestMapFrame_OpenToQuestDetails then QuestMapFrame_OpenToQuestDetails(selectedID) -- routed only when pure
  else OpenMapToQuest(selectedID) end
end)
mapBtn:SetPoint("BOTTOMRIGHT", NATIVE and -22 or -26, NATIVE and 5 or 12)
-- "Attach to map" is gone: the ledger is always its own window
f.attach:Hide(); f.attach.label:Hide()
abandon:ClearAllPoints()
abandon:SetPoint("BOTTOMLEFT", NATIVE and 12 or 16, NATIVE and 5 or 12)

f.arrow = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
f.arrow:SetSize(24, 24)
f.arrow:SetFrameLevel(f:GetFrameLevel() + 20)
f.arrow:SetPoint("LEFT", track, "RIGHT", 6, 1)
f.arrow.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
f.arrow.label:SetPoint("LEFT", f.arrow, "RIGHT", 0, 1)
f.arrow.label:SetText("Arrow")
f.arrow:SetScript("OnClick", function(b)
  DB.arrow = b:GetChecked() and true or false
  if DB.arrow then PointArrow(selectedID) elseif QLF_HideArrow then QLF_HideArrow() end
end)
f.arrow:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_TOP")
  GameTooltip:AddLine("3D waypoint arrow")
  GameTooltip:AddLine("Point the 3D arrow at the quest you select. Right-click the arrow to hide it.", 1, 1, 1, true)
  GameTooltip:Show()
end)
f.arrow:SetScript("OnLeave", GameTooltip_Hide)

-- yards / meters for the arrow's distance (stored in Rally Point's settings)
f.units = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
f.units:SetSize(34, 20)
f.units:SetPoint("LEFT", f.arrow.label, "RIGHT", 4, 0)
f.units:SetScript("OnClick", function(b)
  SetUnits(Units() == "m" and "yd" or "m")
  b:SetText(Units())
end)
f.units:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_TOP")
  GameTooltip:AddLine("Distance units")
  GameTooltip:AddLine("Show the arrow's distance in yards or meters.", 1, 1, 1, true)
  GameTooltip:Show()
end)
f.units:SetScript("OnLeave", GameTooltip_Hide)
-- these live in the options window now (gear button / /qlf options); keep the bottom bar clean
f.arrow:Hide(); f.arrow.label:Hide(); f.units:Hide()

---------------------------------------------------------------- list build
-- Is this a dungeon or raid quest? (quest tag first, then: is its zone heading a dungeon map?)
local instCache = {}
local function InstanceKind(qid, header)
  if qid then
    local tagID
    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
      local ok, info = pcall(C_QuestLog.GetQuestTagInfo, qid)
      if ok and type(info) == "table" then tagID = info.tagID end
    elseif GetQuestTagInfo then
      local ok, id = pcall(GetQuestTagInfo, qid)
      if ok then tagID = id end
    end
    if tagID == 62 or tagID == 88 or tagID == 89 then return "raid" end
    if tagID == 81 or tagID == 85 then return "dungeon" end
  end
  if not header then return end
  if instCache[header] == nil then
    instCache[header] = false
    local id = MapIDForZoneName(header)
    local info = id and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    if info and info.mapType == ((Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4) then instCache[header] = "dungeon" end
  end
  return instCache[header] or nil
end

local function BuildMine()
  wipe(entries)
  if ExpandQuestHeader then pcall(ExpandQuestHeader, 0) end
  local header, quests = nil, 0
  local firstQuest
  for i = 1, NumEntries() do
    local title, level, isHeader, complete, failed, qid, group, elite = EntryInfo(i)
    if title then
      if isHeader then
        header = title
        entries[#entries + 1] = { header = true, title = title }
      else
        quests = quests + 1
        firstQuest = firstQuest or qid
        if not (header and collapsed[header]) then
          local inst = (not DB or DB.instIcons ~= false) and InstanceKind(qid, header) or nil
          entries[#entries + 1] = { title = title, level = level, complete = complete, failed = failed,
            qid = qid, index = i, group = group, elite = elite or (group and group > 1) or nil, friends = Friends(qid), inst = inst, instName = inst and header }
        end
      end
    end
  end
  local max = (C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept())
    or MAX_QUESTLOG_QUESTS or 20
  f.count:SetText(("Quests: %d/%d"):format(quests, max))
  if not selectedID or not IndexForQuest(selectedID) then selectedID = firstQuest end
end

local function BuildParty()
  wipe(entries)
  local api = Mates()
  local ok, prow, n = false, nil, 0
  if api then ok, prow, n = pcall(api.Rows) end
  prow = ok and prow or {}
  f.count:SetText(("Party members: %d"):format(n or 0))
  if #prow == 0 then
    entries[1] = { party = true, note = true,
      text = (IsInGroup and IsInGroup()) and "No one in your group has QuestMates yet." or "Join a group to see their quests." }
    return
  end
  for _, d in ipairs(prow) do
    if d.kind == "header" then
      entries[#entries + 1] = { party = true, header = true, who = d.who, count = d.count }
    elseif d.kind == "quest" then
      entries[#entries + 1] = { party = true, q = d.q, who = d.who, text = d.text }
    else
      entries[#entries + 1] = { party = true, note = true, text = d.text }
    end
  end
end

local function DrawMineRow(b, e)
  if e.header then
    b.icon:SetTexture(collapsed[e.title] and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    b.icon:SetTexCoord(0, 1, 0, 1)
    b.icon:SetVertexColor(1, 1, 1)
    b.icon:Show()
    b.text:SetPoint("LEFT", 20, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetText(e.title)
    b.text:SetTextColor(1, 0.82, 0)
    return
  end
  local textLeft = 14
  if e.inst then
    -- portal icon: purple = dungeon, red = raid
    local atlas = e.inst == "raid" and "Raid" or "Dungeon"
    if not (b.icon.SetAtlas and b.icon:SetAtlas(atlas)) then
      b.icon:SetTexture(e.inst == "raid" and "Interface\\Icons\\INV_Misc_Head_Dragon_01" or "Interface\\Icons\\INV_Misc_Key_14")
      b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    b.icon:SetVertexColor(1, 1, 1)
    b.icon:Show()
    textLeft = 20
  else
    b.icon:Hide()
  end
  local c = DiffColor(e.level)
  local elite = e.elite and DB and DB.eliteMark ~= false
  b.text:SetText(("[%s%s] %s"):format(e.level or "?", elite and "+" or "", e.title))
  b.text:SetTextColor(c.r, c.g, c.b)
  if e.failed then b.tag:SetText("|cffff3030Failed|r")
  elseif e.complete then b.tag:SetText("|cff40ff40Complete|r")
  elseif elite then b.tag:SetText("|cffffb400Elite|r" .. ((e.group and e.group > 1) and (" |cffaaaaaa(" .. e.group .. ")|r") or ""))
  elseif e.group and e.group > 1 then b.tag:SetText("|cffaaaaaaGroup " .. e.group .. "|r") end
  local right = 66
  if IsWatched(e.qid, e.index) then b.check:Show(); right = right + 14 end
  local api = Mates()
  local nd = math.min(#(e.friends or {}), MAX_DOTS)
  for d = 1, nd do
    local t, fr = b.dots[d], e.friends[d]
    t:SetTexture(api and api.Disc or "Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(fr.color[1], fr.color[2], fr.color[3])
    t:ClearAllPoints()
    t:SetPoint("RIGHT", -(right + (d - 1) * 9), 0)
    t:Show()
  end
  if nd > 0 then right = right + nd * 9 + 2 end
  b.text:SetPoint("LEFT", textLeft, 0)
  b.text:SetPoint("RIGHT", -right, 0)
  if e.qid == selectedID then b.sel:Show() end
end

local function DrawPartyRow(b, e)
  local api = Mates()
  b.text:SetPoint("RIGHT", -4, 0)
  if e.header then
    local c = api and api.Color(e.who) or { 1, 1, 1 }
    b.icon:SetTexture(api and api.Disc or "Interface\\Buttons\\WHITE8X8")
    b.icon:SetVertexColor(c[1], c[2], c[3])
    b.icon:Show()
    b.text:SetPoint("LEFT", 20, 0)
    b.text:SetText(e.who .. " |cffaaaaaa(" .. (e.count or 0) .. ")|r")
    b.text:SetTextColor(c[1], c[2], c[3])
    b.tag:SetText(api and api.IsCollapsed(e.who) and "|cffffd100+|r" or "|cffffd100-|r")
  else
    b.icon:Hide()
    b.text:SetPoint("LEFT", 14, 0)
    b.text:SetText(e.text or "")
    if e.note then b.text:SetTextColor(0.6, 0.6, 0.6) else b.text:SetTextColor(1, 1, 1) end
  end
end

local IsGrey, cp -- defined further down (grey quest cleanup)
Refresh = function()
  if not f:IsShown() then return end
  local hasMates = Mates() ~= nil
  if not hasMates then mode = "mine" end
  partyTab:SetShown(hasMates)
  mineTab:SetShown(hasMates)
  if hasMates then
    partyTab:SetEnabled(mode ~= "party")
    mineTab:SetEnabled(mode ~= "mine")
    local ok, _, cnt = pcall(Mates().Rows)
    partyTab:SetText((ok and cnt and cnt > 0) and ("Party (" .. cnt .. ")") or "Party")
  end

  if mode == "party" then BuildParty() else BuildMine() end
  local maxOff = math.max(0, #entries - NUM_ROWS)
  scroll:SetMinMaxValues(0, maxOff)
  if scroll:GetValue() > maxOff then scroll:SetValue(maxOff) end
  local off = math.floor(scroll:GetValue() + 0.5)
  for i = 1, NUM_ROWS do
    local b, e = rows[i], entries[i + off]
    b.entry = e
    b.sel:Hide()
    b.check:Hide()
    b.tag:SetText("")
    for _, t in ipairs(b.dots) do t:Hide() end
    b.text:ClearAllPoints()
    if not e then b:Hide() else
      b:Show()
      if e.party then DrawPartyRow(b, e) else DrawMineRow(b, e) end
    end
  end
  local idx = selectedID and IndexForQuest(selectedID)
  track:SetText(idx and IsWatched(selectedID, idx) and "Untrack" or "Track")
  ShowDetails()
  local greys = 0
  if mode ~= "party" then
    for _, e in ipairs(entries) do if not e.header and IsGrey and IsGrey(e.level) then greys = greys + 1 end end
  end
  if f.greyBtn then
    f.greyBtn:SetShown(greys > 0 or (cp and cp:IsShown()))
    f.greyBtn:SetText(("Grey (%d)"):format(greys))
  end
end




---------------------------------------------------------------- built-in 3D arrow (used when Rally Point isn't installed)
local function WorldPos(uiMap, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMap, CreateVector2D(x, y))
  if ok and cont and pos then return cont, pos.x, pos.y end
end
local function PlayerWorldPos()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local p = m and C_Map.GetPlayerMapPosition(m, "player")
  if not p then return end
  local px, py = p:GetXY()
  return WorldPos(m, px, py)
end

-- where is this quest? (game data: next waypoint, or the quest's marker on its zone map)
local function QuestLocation(qid)
  if C_QuestLog and C_QuestLog.GetNextWaypoint then
    local ok, m, x, y = pcall(C_QuestLog.GetNextWaypoint, qid)
    if ok and m and x and (x > 0 or y > 0) then return m, x, y end
  end
  local maps, seen = {}, {}
  local function add(m) if m and m > 0 and not seen[m] then seen[m] = true; maps[#maps + 1] = m end end
  add(GetQuestUiMapID and GetQuestUiMapID(qid))
  add(MapIDForZoneName(HeaderForQuest(qid)))
  add(C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
  if C_QuestLog and C_QuestLog.GetQuestsOnMap then
    for _, m in ipairs(maps) do
      local ok, list = pcall(C_QuestLog.GetQuestsOnMap, m)
      if ok and list then
        for _, q in ipairs(list) do
          if q.questID == qid and q.x and q.y then return m, q.x, q.y end
        end
      end
    end
  end
  if QuestPOIGetIconInfo then -- older clients
    local ok, _, x, y = pcall(QuestPOIGetIconInfo, qid)
    if ok and x and y and maps[1] then return maps[1], x, y end
  end
end

local FRAMES, COLS, CELL = 144, 12, 42 / 512
local function SetArrowAngle(tex, angle)
  local twoPi = 2 * math.pi
  angle = angle % twoPi
  local i = math.floor(angle / twoPi * FRAMES + 0.5) % FRAMES
  local col, row = i % COLS, math.floor(i / COLS)
  tex:SetTexCoord(col * CELL, (col + 1) * CELL, row * CELL, (row + 1) * CELL)
  local off = angle > math.pi and (twoPi - angle) or angle
  local perc = off / math.pi
  if perc < 0.5 then tex:SetVertexColor(perc * 2, 1, 0.2) else tex:SetVertexColor(1, (1 - perc) * 2, 0.2) end
end

local arrowTarget -- { qid, title, cont, wx, wy }
local af = CreateFrame("Button", "QuestLedgerForeverArrow", UIParent)
af:SetSize(180, 80)
af:SetPoint("TOP", UIParent, "TOP", 0, -140)
af:SetMovable(true); af:EnableMouse(true); af:SetClampedToScreen(true)
af:RegisterForDrag("LeftButton"); af:RegisterForClicks("RightButtonUp")
af:SetScript("OnDragStart", af.StartMoving)
af:SetScript("OnDragStop", function(s)
  s:StopMovingOrSizing()
  local p, _, rp, x, y = s:GetPoint(); DB.arrowPos = { p, rp, x, y }
end)
af:SetScript("OnClick", function() arrowTarget = nil; af:Hide() end)
af:SetScript("OnEnter", function(s)
  GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
  GameTooltip:AddLine(arrowTarget and arrowTarget.title or "Quest", 1, 0.82, 0)
  GameTooltip:AddLine("Drag to move, right-click to hide", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
af:SetScript("OnLeave", GameTooltip_Hide)
af.arrow = af:CreateTexture(nil, "ARTWORK")
af.arrow:SetSize(56, 56)
af.arrow:SetPoint("TOP", 0, 8)
af.arrow:SetTexture("Interface\\AddOns\\QuestLedgerForever\\Arrow")
af.title = af:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
af.title:SetPoint("TOP", af.arrow, "BOTTOM", 0, 0)
af.title:SetWidth(180); af.title:SetWordWrap(false)
af.dist = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
af.dist:SetPoint("TOP", af.title, "BOTTOM", 0, -1)
af:Hide()

local function Locate(t)
  local m, x, y = QuestLocation(t.qid)
  if m then t.cont, t.wx, t.wy = WorldPos(m, x, y) else t.cont = nil end
end

local tick, relocate = 0, 0
af:SetScript("OnUpdate", function(s, dt)
  tick = tick + dt; relocate = relocate + dt
  if tick < 0.05 then return end
  tick = 0
  local t = arrowTarget
  if not t or not IndexForQuest(t.qid) then arrowTarget = nil; s:Hide(); return end
  if relocate > 2 then relocate = 0; Locate(t) end -- objectives move as you progress
  local cont, px, py = PlayerWorldPos()
  if not t.cont then s.arrow:Hide(); s.dist:SetText("|cff999999No location for this quest|r"); return end
  if not cont then s.arrow:Hide(); s.dist:SetText("|cff999999No position here|r"); return end
  if cont ~= t.cont then s.arrow:Hide(); s.dist:SetText("|cff999999On another continent|r"); return end
  local dx, dy = t.wx - px, t.wy - py
  local yards = math.sqrt(dx * dx + dy * dy)
  if yards <= 8 then s.arrow:Hide(); s.dist:SetText("|cff40ff40You're here|r"); return end
  local facing = GetPlayerFacing and GetPlayerFacing()
  if facing then SetArrowAngle(s.arrow, math.atan2(dy, dx) - facing); s.arrow:Show() else s.arrow:Hide() end
  if Units() == "m" then s.dist:SetText(("%d m"):format(yards * 0.9144)) else s.dist:SetText(("%d yd"):format(yards)) end
end)

function QLF_OwnArrow(qid, announce)
  local idx = qid and IndexForQuest(qid)
  if not idx then return end
  local title = EntryInfo(idx)
  arrowTarget = { qid = qid, title = title }
  Locate(arrowTarget)
  if not arrowTarget.cont and announce then
    print("|cffffd200Quest Ledger:|r no map location known for " .. (title or "this quest") .. ".")
  end
  if DB.arrowPos then af:ClearAllPoints(); af:SetPoint(DB.arrowPos[1], UIParent, DB.arrowPos[2], DB.arrowPos[3], DB.arrowPos[4]) end
  af.title:SetText(title or "")
  relocate = 0
  af:Show()
end
function QLF_HideArrow() arrowTarget = nil; af:Hide() end

---------------------------------------------------------------- right-click menu
local qm = CreateFrame("Frame", "QuestLedgerForeverMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
qm:SetFrameStrata("FULLSCREEN_DIALOG")
qm:SetClampedToScreen(true)
qm:EnableMouse(true)
qm:Hide()
if qm.SetBackdrop then
  qm:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  qm:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
end
qm.items = {}
local function MenuItem(i)
  if qm.items[i] then return qm.items[i] end
  local b = CreateFrame("Button", nil, qm)
  b:SetHeight(18)
  b:SetPoint("LEFT", 8, 0); b:SetPoint("RIGHT", -8, 0)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 4, 0)
  b:SetScript("OnClick", function(s) qm:Hide(); if s.fn then s.fn() end end)
  qm.items[i] = b
  return b
end
local qmClose = CreateFrame("Frame", nil, qm)
qmClose:SetScript("OnUpdate", function()
  if qm:IsShown() and not qm:IsMouseOver(20, -20, -20, 20) and IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
    if not qm.justOpened then qm:Hide() end
  end
  qm.justOpened = false
end)

function QLF_ShowQuestMenu(owner, qid)
  local idx = qid and IndexForQuest(qid)
  if not idx then return end
  local title = EntryInfo(idx)
  local opts = {
    { title, nil, true },
    { IsWatched(qid, idx) and "Untrack" or "Track", function() ToggleWatch(qid, idx); Refresh() end },
    { "Share with party", function() if Select(qid) and QuestLogPushQuest then QuestLogPushQuest() end end },
    { "Link in chat", function()
        local link = GetQuestLink and GetQuestLink(MODERN and qid or idx)
        if link then local d = ChatEdit_InsertLink and ChatEdit_InsertLink(link); if not d and ChatFrame_OpenChat then ChatFrame_OpenChat(link) end end
      end },
    { "Show on map", function() selectedID = qid; Refresh(); OpenMapToQuest(qid) end },
  }
  opts[#opts + 1] = { "Point arrow here", function()
    if RallyPoint_FollowQuest then pcall(RallyPoint_FollowQuest, qid) elseif QLF_OwnArrow then QLF_OwnArrow(qid, true) end
  end }
  opts[#opts + 1] = { "|cffff5050Abandon|r", function()
    selectedID = qid; Refresh()
    if MODERN and C_QuestLog.SetAbandonQuest then Select(qid); C_QuestLog.SetAbandonQuest() elseif SetAbandonQuest then Select(qid); SetAbandonQuest() end
    StaticPopup_Show("ABANDON_QUEST", title)
  end }
  for _, b in ipairs(qm.items) do b:Hide() end
  local width = 120
  for i, o in ipairs(opts) do
    local b = MenuItem(i)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 8, -6 - (i - 1) * 18); b:SetPoint("RIGHT", -8, 0)
    b.text:SetText(o[3] and ("|cffffd200" .. (o[1] or "") .. "|r") or o[1])
    b.fn = o[2]
    b:EnableMouse(not o[3])
    b:Show()
    width = math.max(width, b.text:GetStringWidth() + 24)
  end
  qm:SetSize(math.min(width, 260), #opts * 18 + 12)
  local x, y = GetCursorPosition()
  local sc = UIParent:GetEffectiveScale()
  qm:ClearAllPoints()
  qm:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / sc, y / sc)
  qm.justOpened = true
  qm:Show()
end

---------------------------------------------------------------- grey quest cleanup
IsGrey = function(level)
  if not level or level <= 0 then return false end
  local me = UnitLevel("player")
  local range = (GetQuestGreenRange and GetQuestGreenRange()) or 8
  return level < me - range
end

local function GreyQuests()
  local out = {}
  for i = 1, NumEntries() do
    local title, level, isHeader, complete, failed, qid = EntryInfo(i)
    if title and not isHeader and qid then
      local grey = IsGrey(level)
      if MODERN and C_QuestLog.IsQuestTrivial then
        local ok, v = pcall(C_QuestLog.IsQuestTrivial, qid); if ok and v ~= nil then grey = v or grey end
      end
      if grey then out[#out + 1] = { qid = qid, title = title, level = level, complete = complete } end
    end
  end
  -- read each quest's XP reward
  local keep = selectedID
  for _, q in ipairs(out) do
    if MODERN and GetQuestLogRewardXP then
      local ok, xp = pcall(GetQuestLogRewardXP, q.qid); q.xp = ok and xp or nil
    end
    if not q.xp then Select(q.qid); q.xp = GetQuestLogRewardXP and GetQuestLogRewardXP() or 0 end
  end
  if keep then Select(keep) end
  table.sort(out, function(a, b) return (a.xp or 0) < (b.xp or 0) end) -- least XP first
  return out
end

cp = CreateFrame("Frame", "QuestLedgerForeverCleanup", f, BackdropTemplateMixin and "BackdropTemplate" or nil)
cp:SetPoint("TOPLEFT", detail, -4, 4)
cp:SetPoint("BOTTOMRIGHT", detail, 26, -4)
cp:SetFrameLevel(f:GetFrameLevel() + 30)
cp:EnableMouse(true)
if cp.SetBackdrop then
  cp:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  cp:SetBackdropBorderColor(0.75, 0.6, 0.3, 1)
end
cp:Hide()
cp.title = cp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cp.title:SetPoint("TOPLEFT", 12, -10)
cp.title:SetText("Grey quests")
cp.note = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cp.note:SetPoint("TOPLEFT", cp.title, "BOTTOMLEFT", 0, -4)
cp.note:SetPoint("RIGHT", -12, 0)
cp.note:SetJustifyH("LEFT")
cp.note:SetText("These are below your level but may still give good XP. Tick the ones you want to drop.")
cp.rows = {}
local CP_ROWS = 17
for i = 1, CP_ROWS do
  local r = CreateFrame("CheckButton", nil, cp, "UICheckButtonTemplate")
  r:SetSize(20, 20)
  r:SetPoint("TOPLEFT", 10, -48 - (i - 1) * 21)
  r.text = cp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.text:SetPoint("LEFT", r, "RIGHT", 2, 0)
  r.text:SetWidth(210); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
  r.xp = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.xp:SetPoint("RIGHT", cp, "LEFT", 330, 0)
  r.xp:SetPoint("TOP", r, "TOP", 0, -4)
  r:SetScript("OnClick", function(b) if b.q then b.q.pick = b:GetChecked() and true or false end; cp:Count() end)
  cp.rows[i] = r
end
cp.more = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
cp.more:SetPoint("BOTTOMLEFT", 14, 40)

local cpAbandon = CreateFrame("Button", nil, cp, "UIPanelButtonTemplate")
cpAbandon:SetSize(150, 22); cpAbandon:SetPoint("BOTTOMLEFT", 10, 10)
local cpClose = CreateFrame("Button", nil, cp, "UIPanelButtonTemplate")
cpClose:SetSize(80, 22); cpClose:SetPoint("BOTTOMRIGHT", -10, 10); cpClose:SetText(CLOSE or "Close")
cpClose:SetScript("OnClick", function() cp:Hide() end)

function cp:Count()
  local n = 0
  for _, q in ipairs(self.list or {}) do if q.pick then n = n + 1 end end
  cpAbandon:SetText(("Abandon selected (%d)"):format(n))
  cpAbandon:SetEnabled(n > 0)
  return n
end

function cp:Fill()
  self.list = GreyQuests()
  for i, r in ipairs(self.rows) do
    local q = self.list[i]
    r.q = q
    if q then
      r:Show(); r.text:Show(); r.xp:Show()
      r:SetChecked(q.pick and true or false)
      r.text:SetText(("|cff9d9d9d[%d]|r %s"):format(q.level or 0, q.title) .. (q.complete and " |cff40ff40(done)|r" or ""))
      r.xp:SetText((q.xp and q.xp > 0) and (q.xp .. " XP") or "|cff777777no XP|r")
    else
      r:Hide(); r.text:Hide(); r.xp:Hide()
    end
  end
  local extra = #self.list - CP_ROWS
  self.more:SetText(extra > 0 and ("+" .. extra .. " more (abandon some to see them)") or "")
  if #self.list == 0 then self.note:SetText("No grey quests in your log.") else
    self.note:SetText("These are below your level but may still give good XP. Tick the ones you want to drop.") end
  self:Count()
end

StaticPopupDialogs["QLF_ABANDON_MULTI"] = {
  text = "Abandon %d quests? This can't be undone.",
  button1 = YES or "Yes", button2 = NO or "No",
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnAccept = function()
    local todo = {}
    for _, q in ipairs(cp.list or {}) do if q.pick then todo[#todo + 1] = q.qid end end
    local i = 0
    local function step()
      i = i + 1
      local qid = todo[i]
      if not qid then C_Timer.After(0.3, function() if cp:IsShown() then cp:Fill() end; Refresh() end) return end
      if Select(qid) then
        if MODERN and C_QuestLog.SetAbandonQuest then C_QuestLog.SetAbandonQuest(); C_QuestLog.AbandonQuest()
        elseif SetAbandonQuest then SetAbandonQuest(); AbandonQuest() end
      end
      C_Timer.After(0.3, step)
    end
    step()
  end,
}
cpAbandon:SetScript("OnClick", function()
  local n = cp:Count()
  if n > 0 then StaticPopup_Show("QLF_ABANDON_MULTI", n) end
end)

f.greyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
f.greyBtn:SetSize(80, 22)
f.greyBtn:SetPoint("RIGHT", mapBtn, "LEFT", -4, 0)
f.greyBtn:SetScript("OnClick", function()
  if cp:IsShown() then cp:Hide() else cp:Fill(); cp:Show() end
end)
f.greyBtn:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Grey quests")
  GameTooltip:AddLine("Review quests below your level, with their XP, and abandon the ones you don't want.", 1, 1, 1, true)
  GameTooltip:Show()
end)
f.greyBtn:SetScript("OnLeave", GameTooltip_Hide)

-- resize grip (bottom-right corner): changes width and height, text keeps its size
local MIN_W, MIN_H, MAX_W, MAX_H = 720, 540, 1400, 1150
if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
elseif f.SetMinResize then f:SetMinResize(MIN_W, MIN_H); f:SetMaxResize(MAX_W, MAX_H) end
f:SetResizable(true)
local function Relayout()
  local w, h = f:GetWidth(), f:GetHeight()
  -- taller: more rows in the list
  local n = math.max(5, math.min(MAX_ROWS, math.floor((h - 108) / ROW_H)))
  if n ~= NUM_ROWS then
    NUM_ROWS = n
    list:SetHeight(ROW_H * NUM_ROWS)
    for i = NUM_ROWS + 1, MAX_ROWS do rows[i]:Hide() end
  end
  -- wider: more room for the quest page text
  local dw = math.max(330, math.floor(w - 390))
  if dw ~= DW then
    DW = dw
    dc:SetWidth(DW + 10)
    for _, fs in ipairs(fsList) do fs:SetWidth(DW) end
  end
end
local function ApplySize()
  if not DB then return end
  f:SetScale(1); DB.scale = nil -- older "scale" setting is gone
  local sz = DB.size
  f:SetSize(sz and sz[1] or MIN_W, sz and sz[2] or MIN_H)
  Relayout()
end
f:HookScript("OnSizeChanged", function()
  Relayout()
  if f:IsShown() and Refresh then Refresh() end
end)
local grip = CreateFrame("Button", nil, f)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -4, 6)
grip:SetFrameLevel(f:GetFrameLevel() + 20)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
local function UpdateGrip()
  if DB and DB.resizable ~= false then grip:Show() else grip:Hide() end
end
grip:SetScript("OnMouseDown", function(s, btn)
  if btn ~= "LeftButton" then return end
  s.sizing = true
  f:StartSizing("BOTTOMRIGHT")
end)
grip:SetScript("OnMouseUp", function(s)
  if not s.sizing then return end
  s.sizing = nil
  f:StopMovingOrSizing()
  if not DB then return end
  DB.size = { math.floor(f:GetWidth() + 0.5), math.floor(f:GetHeight() + 0.5) }
  if docked then Dock()
  else
    local p, _, rp, x, y = f:GetPoint()
    DB.pos = { p, rp, x, y }
  end
end)
grip:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Resize")
  GameTooltip:AddLine("Drag to change the width and height. Right-click: normal size.", 1, 1, 1, true)
  GameTooltip:Show()
end)
grip:SetScript("OnLeave", GameTooltip_Hide)
grip:RegisterForClicks("RightButtonUp")
grip:SetScript("OnClick", function()
  if not DB then return end
  DB.size = nil
  ApplySize()
  if docked then Dock() else PlaceFree() end
end)

f:SetScript("OnShow", function()
  if DB then f.attach:SetChecked(DB.attach and true or false) end
  ApplySize(); UpdateGrip()
  -- the arrow option only exists when Rally Point is loaded
  f.units:SetText(Units())
  if DB then f.arrow:SetChecked(DB.arrow ~= false) end
  Dock()
  PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN or 844)
  Refresh()
end)
f:SetScript("OnHide", function() PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_CLOSE or 845) end)

local function Toggle()
  if f:IsShown() then f:Hide() else f:Show() end
end
QuestLedgerForever_Toggle = Toggle
BINDING_HEADER_QUESTLEDGERFOREVER = "Quest Ledger Forever"
BINDING_NAME_QUESTLEDGERFOREVER_TOGGLE = "Toggle Quest Ledger"

-- Used by QuestMates: show / leave the party quest list.
function QuestLedgerForever_ToggleParty()
  if f:IsShown() and mode == "party" then
    mode = "mine"
    if DB and DB.attach then Refresh() else f:Hide() end
  else
    mode = "party"
    f:Show()
    Refresh()
  end
  Dock()
  return mode == "party"
end
function QuestLedgerForever_IsPartyShown() return f:IsShown() and mode == "party" end

-- Used by QuestMates: open one of my quests in this window. Returns true if handled.
function QuestLedgerForever_OpenQuest(qid)
  if not qid or not IndexForQuest(qid) then return false end
  local h = HeaderForQuest(qid)
  if h then collapsed[h] = nil end
  mode = "mine"
  selectedID = qid
  f:Show()
  f:Raise()
  if detail.SetVerticalScroll then detail:SetVerticalScroll(0) end
  BuildMine()
  for i, e in ipairs(entries) do
    if e.qid == qid then
      local maxOff = math.max(0, #entries - NUM_ROWS)
      scroll:SetMinMaxValues(0, maxOff)
      local off = math.floor(scroll:GetValue() + 0.5)
      if i <= off or i > off + NUM_ROWS then -- only scroll if the quest isn't already in view
        scroll:SetValue(math.max(0, math.min(maxOff, i - math.floor(NUM_ROWS / 2))))
      end
      break
    end
  end
  Refresh()
  PointArrow(qid)
  return true
end

-- Called by QuestMates when party data changes
local matesPending
function QuestLedgerForever_OnMatesUpdate()
  if not f:IsShown() or matesPending then return end
  matesPending = true
  C_Timer.After(0.1, function() matesPending = nil; Refresh() end)
end

---------------------------------------------------------------- map

-- Quest tracker / other UI "open this quest" calls: show it in our quest log, not the map panel.
local origOpen = {}
local function RouteQuestOpens()
  for _, name in ipairs({ "QuestMapFrame_OpenToQuestDetails", "QuestLog_OpenToQuest", "QuestLog_OpenToQuestIndex" }) do
    local fn = _G[name]
    if fn and not origOpen[name] then
      origOpen[name] = fn
      _G[name] = function(arg, ...)
        if DB and DB.routeOpens ~= false then
          local qid = arg
          if name == "QuestLog_OpenToQuestIndex" then
            local _, _, _, _, _, id = EntryInfo(arg); qid = id
          end
          if qid and QuestLedgerForever_OpenQuest(qid) then return end
        end
        return origOpen[name](arg, ...)
      end
    end
  end
end

function QuestLedgerForever_IsPureMap() return DB ~= nil end -- QuestMates' party list lives in Quest Ledger Forever

-- Clicking a quest icon on the map opens that quest in this log.
-- only real icon pins: big area pins (quest blobs) sit over the whole zone and must keep normal map clicks
local PIN_TEMPLATES = { "QuestPinTemplate", "BonusObjectivePinTemplate" }
local function IsIconPin(p)
  local w, h = p:GetSize()
  return w and h and w > 0 and w <= 64 and h <= 64
end
local function PinQuestID(p)
  local q = p.questID or (p.GetQuestID and p:GetQuestID())
  if type(q) == "number" and q > 0 then return q end
end
local function HookPin(p)
  if p.qlfHooked or not p.HookScript or not IsIconPin(p) then return end
  p.qlfHooked = true
  -- react on mouse DOWN: the map swallows some mouse-ups (it checks for map dragging)
  p:HookScript("OnMouseDown", function(pin, btn)
    if btn ~= "LeftButton" or (DB and DB.mapClicks == false) then return end
    local qid = PinQuestID(pin)
    if qid and IndexForQuest(qid) then
      QuestLedgerForever_OpenQuest(qid)
      -- the pin's own click (on release) can reset the selection; re-apply it after, so the icon lights up
      C_Timer.After(0.05, function()
        if selectedID ~= qid then return end
        Select(qid)
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then pcall(C_SuperTrack.SetSuperTrackedQuestID, qid) end
      end)
    end
  end)
end
local function HookMapPins()
  if not WorldMapFrame then return end
  if WorldMapFrame.EnumeratePinsByTemplate then
    for _, t in ipairs(PIN_TEMPLATES) do
      local ok, iter = pcall(WorldMapFrame.EnumeratePinsByTemplate, WorldMapFrame, t)
      if ok and iter then for p in iter do HookPin(p) end end
    end
  end
  if WorldMapFrame.pinPools then -- catch any other pin type that carries a quest
    for _, pool in pairs(WorldMapFrame.pinPools) do
      if pool.EnumerateActive then for p in pool:EnumerateActive() do
        local tpl = p.pinTemplate or ""
        if PinQuestID(p) and not tostring(tpl):find("Blob") then HookPin(p) end
      end end
    end
  end
end

local function HookMapWindow()
  if not WorldMapFrame then return end
  WorldMapFrame:HookScript("OnShow", function()
    if DB.attach then f:Show() end
    C_Timer.After(0, Dock)
  end)
  WorldMapFrame:HookScript("OnHide", function()
    if DB.attach and docked and not (QLF_KeepOpenUntil and GetTime() < QLF_KeepOpenUntil) then f:Hide() end
    Dock()
  end)
  WorldMapFrame:HookScript("OnSizeChanged", function() C_Timer.After(0, Dock) end)
  WorldMapFrame:HookScript("OnShow", function() HookMapPins(); C_Timer.After(0.05, HookMapPins) end)
  if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", function() C_Timer.After(0.05, HookMapPins) end) end
  local pinPending
  if WorldMapFrame.AcquirePin then hooksecurefunc(WorldMapFrame, "AcquirePin", function()
    if pinPending then return end
    pinPending = true
    C_Timer.After(0, function() pinPending = nil; HookMapPins() end)
  end) end
end

---------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
ev:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("SUPER_TRACKING_CHANGED")
local pending
ev:SetScript("OnEvent", function(_, event)
  if event == "SUPER_TRACKING_CHANGED" then
    -- clicking a quest's ? / ... icon in the objective tracker: point the 3D arrow at it
    local qid = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if qid and qid > 0 and IndexForQuest(qid) then PointArrow(qid) end
    QLF_ColorMarker()
    return
  end
  if event == "PLAYER_REGEN_ENABLED" then
    return
  end
  if event == "PLAYER_LOGIN" then
    QuestLedgerForeverDB = QuestLedgerForeverDB or {}
    DB = QuestLedgerForeverDB
    if DB.hookKey == nil then DB.hookKey = true end
    DB.attach = nil -- attach-to-map feature removed
    ApplySize(); UpdateGrip()
    PlaceFree()
    QLF_OrigToggleQuestLog = QLF_OrigToggleQuestLog or ToggleQuestLog
    if DB.hookKey then
      -- Make the normal quest log key (L) open this window instead of the combined map.
      ToggleQuestLog = Toggle
    end
    -- 2.7: the game's own waypoint marker becomes the default; the 3D arrow is optional
    if not DB.markerDefaults then
      DB.markerDefaults = true
      if DB.gameMarker == nil then DB.gameMarker = true end
      DB.arrow = false
    end
    if DB.gameMarker ~= false then SetGameMarker(true) end
    C_Timer.After(1, function() if QLF_ColorMarker then QLF_ColorMarker() end end)
    RouteQuestOpens()
    HookMapWindow()
    -- PopQuest / LevelTag are now part of Quest Ledger: their old addons were turned off, a reload finishes it
    if QuestLedgerForever_Replaced and #QuestLedgerForever_Replaced > 0 then
      local names = table.concat(QuestLedgerForever_Replaced, " and ")
      print("|cffffd200Quest Ledger:|r " .. names .. " are now built into Quest Ledger Forever. The old addon(s) are turned off; type |cffffd200/reload|r to finish. You can delete their old folders.")
      StaticPopupDialogs["QUESTLEDGER_MERGE_RELOAD"] = {
        text = names .. " are now built into Quest Ledger Forever.\nReload now to finish?",
        button1 = RELOADUI or "Reload UI", button2 = LATER or "Later",
        OnAccept = function() ReloadUI() end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
      }
      StaticPopup_Show("QUESTLEDGER_MERGE_RELOAD")
    end
    return
  end
  if event == "QUEST_LOG_UPDATE" then QLF_ColorMarker() end -- gold as soon as the quest is ready to hand in
  if f:IsShown() and not pending then
    pending = true
    C_Timer.After(0.1, function() pending = nil; Refresh() end)
  end
end)


---------------------------------------------------------------- options window
-- { header } or { label, get, set, available?, tooltip, indent?, enabledWhen? }
local OPTIONS = {
  { header = "Quest Ledger" },
  { "L key opens the Quest Ledger", function() return DB.hookKey ~= false end,
    function(v)
      DB.hookKey = v
      if v then ToggleQuestLog = Toggle elseif QLF_OrigToggleQuestLog then ToggleQuestLog = QLF_OrigToggleQuestLog end
    end, nil, "Off: L opens the game's own Map & Quest Log again." },
  { "Resizable (drag the bottom-right corner)", function() return DB.resizable ~= false end,
    function(v) DB.resizable = v; UpdateGrip() end, nil,
    "Drag the corner to change the width and height. The text stays the same size. Right-click the corner for normal size." },
  { "Open quests here (map icons and tracker)", function() return DB.mapClicks ~= false and DB.routeOpens ~= false end,
    function(v) DB.mapClicks = v; DB.routeOpens = v end, nil,
    "Clicking a quest icon on the map or a quest in the tracker opens it in the Quest Ledger." },
  { header = "Extras" },
  { "Quest chain icon", function() return DB.chains ~= false end,
    function(v) DB.chains = v; Refresh() end, nil,
    "Book icon on the quest page that lists the whole quest chain." },
  { "Mark elite quests", function() return DB.eliteMark ~= false end,
    function(v) DB.eliteMark = v; Refresh() end, nil,
    "Elite quests get a + after the level, like [26+], and a gold \"Elite\" tag." },
  { "Dungeon and raid icons", function() return DB.instIcons ~= false end,
    function(v) DB.instIcons = v; Refresh() end, nil,
    "A portal icon in front of quests for a dungeon (purple) or raid (red)." },
  { "Quest levels at quest givers (LevelTag)", function() return DB.levelTags ~= false end,
    function(v) DB.levelTags = v end, nil,
    "Shows [level] after quest names when you talk to a quest giver and on the Accept window." },
  { "Popup for items that start a quest (PopQuest)", function() return DB.popQuest ~= false end,
    function(v) DB.popQuest = v end, nil,
    "When you loot an item that starts a quest, a popup with a View Quest button appears." },
  { "Reward markers (best price, upgrades)", function() return DB.rewardMarks ~= false end,
    function(v) DB.rewardMarks = v; Refresh(); if QLF_MarkQuestFrame then QLF_MarkQuestFrame() end end, nil,
    "Bag = sells for the most. Green arrow = an upgrade for your spec." },
  { "Party info from QuestMates", function() return DB.partyInfo ~= false end,
    function(v) DB.partyInfo = v; Refresh() end, function() return QuestMatesAPI ~= nil end,
    "Party dots in the list and friends' progress on the quest page." },
  { "Game's waypoint marker for the selected quest", function() return DB.gameMarker ~= false end,
    function(v) DB.gameMarker = v; SetGameMarker(v); if v then PointArrow(selectedID) end end, nil,
    "The game's own marker in the world, with the distance, over where the selected quest goes." },
  { "Color by distance (red far, green close)", function() return DB.markerDistColor ~= false end,
    function(v) DB.markerDistColor = v; QLF_ColorMarker() end, nil,
    "The marker goes from red (far away) through yellow to green as you get close. Gold when the quest is ready to hand in. Off: the game's normal look.",
    true, function() return DB.gameMarker ~= false end },
  { "3D arrow to the selected quest", function() return DB.arrow ~= false end,
    function(v) DB.arrow = v; f.arrow:SetChecked(v); if v then PointArrow(selectedID) elseif QLF_HideArrow then QLF_HideArrow() end end, nil,
    "Points to the quest's objective, or where to hand it in. Right-click the arrow to hide it." },
  { "Distance in meters", function() return Units() == "m" end,
    function(v) SetUnits(v and "m" or "yd"); f.units:SetText(Units()) end, nil,
    "Off: yards.", true, function() return DB.arrow ~= false end },
}

local optionLists = {}
local function SyncAll()
  if not DB then return end
  for _, list in ipairs(optionLists) do
    local y = list.top
    for _, row in ipairs(list) do
      local o = row.opt
      local avail = o.header or not o[4] or o[4]()
      if not avail then
        row:Hide(); if row.label then row.label:Hide() end
        if row.def then row.def:Hide() end
      else
        row:ClearAllPoints()
        if o.header then
          y = y - (y == list.top and 0 or 8)
          row:SetPoint("TOPLEFT", list.left, y)
          row:Show(); row.line:Show()
          y = y - 22
        elseif o.color then
          row:SetPoint("TOPLEFT", list.left + (o.indent and 24 or 4), y - 2)
          row:Show(); row.label:Show()
          row.swatch:SetColorTexture(o.get())
          local on = not o.enabledWhen or o.enabledWhen()
          row:SetEnabled(on); row:SetAlpha(on and 1 or 0.4)
          if row.def then row.def:Show(); row.def:SetEnabled(on and DB.markerColor ~= nil) end
          row.label:SetFontObject(on and "GameFontHighlight" or "GameFontDisable")
          y = y - 26
        elseif o.slider then
          row:SetPoint("TOPLEFT", list.left + 8, y - 22)
          row:Show(); row.label:Show()
          row.syncing = true; row:SetValue(o.get()); row.syncing = false
          row.value:SetText(("%d%%"):format(o.get()))
          y = y - 50
        else
          row:SetPoint("TOPLEFT", list.left + (o[6] and 20 or 0), y)
          row:Show(); row.label:Show()
          row:SetChecked(o[2]() and true or false)
          local on = not o[7] or o[7]()
          row:SetEnabled(on)
          row.label:SetFontObject(on and "GameFontHighlight" or "GameFontDisable")
          y = y - 26
        end
      end
    end
  end
end
local function BuildOptionList(parent, left, top)
  local list = { left = left, top = top }
  for i, o in ipairs(OPTIONS) do
    local row
    if o.color then
      -- color swatch: click opens the game's color picker, right-click resets
      row = CreateFrame("Button", nil, parent)
      row:SetSize(18, 18)
      row.border = row:CreateTexture(nil, "BACKGROUND"); row.border:SetAllPoints(); row.border:SetColorTexture(0.8, 0.7, 0.4, 1)
      row.swatch = row:CreateTexture(nil, "ARTWORK")
      row.swatch:SetPoint("TOPLEFT", 2, -2); row.swatch:SetPoint("BOTTOMRIGHT", -2, 2)
      row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.label:SetPoint("LEFT", row, "RIGHT", 8, 0)
      row.label:SetText(o.label)
      -- "Default" button: back to the game's normal marker look
      row.def = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
      row.def:SetSize(70, 20)
      row.def:SetPoint("LEFT", row.label, "RIGHT", 10, 0)
      row.def:SetText(DEFAULT or "Default")
      row.def:SetScript("OnClick", function() if DB then o.reset(); SyncAll() end end)
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row:SetScript("OnClick", function(b, btn)
        if not DB then return end
        if btn == "RightButton" then o.reset(); SyncAll(); return end
        local r0, g0, b0 = o.get()
        local function apply(r, g, bl) o.set(r, g, bl); b.swatch:SetColorTexture(r, g, bl) end
        local function fromPicker()
          local r, g, bl = ColorPickerFrame:GetColorRGB(); apply(r, g, bl)
        end
        local function cancel() apply(r0, g0, b0) end
        if ColorPickerFrame.SetupColorPickerAndShow then
          ColorPickerFrame:SetupColorPickerAndShow({ r = r0, g = g0, b = b0, hasOpacity = false,
            swatchFunc = fromPicker, cancelFunc = cancel })
        else
          ColorPickerFrame.hasOpacity = false
          ColorPickerFrame.previousValues = { r0, g0, b0 }
          ColorPickerFrame.func = fromPicker
          ColorPickerFrame.cancelFunc = cancel
          ColorPickerFrame:SetColorRGB(r0, g0, b0)
          ColorPickerFrame:Hide(); ShowUIPanel(ColorPickerFrame)
        end
      end)
      row:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT"); GameTooltip:AddLine(o.label); GameTooltip:AddLine(o.tip, 1, 1, 1, true); GameTooltip:Show()
      end)
      row:SetScript("OnLeave", GameTooltip_Hide)
      row.SetChecked = function() end
    elseif o.slider then
      row = CreateFrame("Slider", nil, parent)
      row:SetOrientation("HORIZONTAL")
      row:SetSize(220, 16)
      row:SetMinMaxValues(o.min, o.max)
      row:SetValueStep(o.step)
      if row.SetObeyStepOnDrag then row:SetObeyStepOnDrag(true) end
      row.bg = row:CreateTexture(nil, "BACKGROUND")
      row.bg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
      row.bg:SetPoint("TOPLEFT", 0, -3); row.bg:SetPoint("BOTTOMRIGHT", 0, 3)
      row:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
      row:EnableMouseWheel(true)
      row:SetScript("OnMouseWheel", function(b, d) b:SetValue(b:GetValue() + d * o.step) end)
      row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.label:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 4)
      row.label:SetText(o.label)
      row.value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      row.value:SetPoint("LEFT", row, "RIGHT", 10, 0)
      row:SetScript("OnValueChanged", function(b, v)
        v = math.floor(v / o.step + 0.5) * o.step
        b.value:SetText(("%d%%"):format(v))
        if DB and not b.syncing then o.set(v) end
      end)
      row:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT"); GameTooltip:AddLine(o.label); GameTooltip:AddLine(o.tip, 1, 1, 1, true); GameTooltip:Show()
      end)
      row:SetScript("OnLeave", GameTooltip_Hide)
      row.SetChecked, row.SetEnabled = function() end, function() end
    elseif o.header then
      row = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      row:SetText(o.header)
      row.line = parent:CreateTexture(nil, "ARTWORK")
      row.line:SetColorTexture(0.75, 0.6, 0.3, 0.6)
      row.line:SetHeight(1)
      row.line:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -3)
      row.line:SetWidth(320)
      row.IsHeader = true
      row.SetChecked, row.SetEnabled = function() end, function() end
      row.label = nil
    else
      row = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
      row:SetSize(24, 24)
      row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.label:SetPoint("LEFT", row, "RIGHT", 4, 1)
      row.label:SetText(o[1])
      row:SetScript("OnClick", function(b) if DB then o[3](b:GetChecked() and true or false) end; SyncAll() end)
      row:SetScript("OnEnter", function(b)
        if not o[5] then return end
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:AddLine(o[1])
        GameTooltip:AddLine(o[5], 1, 1, 1, true)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", GameTooltip_Hide)
    end
    row.opt = o
    list[i] = row
  end
  optionLists[#optionLists + 1] = list
  parent:HookScript("OnShow", SyncAll)
  return list
end
local settingsPanel, settingsCategory
-- the gear button and /ledger options open the game's own Options > AddOns page
local function ToggleOptions()
  if settingsCategory and Settings and Settings.OpenToCategory then
    local id = settingsCategory.GetID and settingsCategory:GetID() or settingsCategory.ID
    pcall(Settings.OpenToCategory, id)
  elseif settingsPanel and InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(settingsPanel)
    InterfaceOptionsFrame_OpenToCategory(settingsPanel) -- called twice: old clients need it to scroll to the page
  end
end

-- gear button next to the quest counter
f.gear = CreateFrame("Button", nil, f)
f.gear:SetSize(18, 18)
f.gear:SetPoint("LEFT", f.count, "RIGHT", 6, 0)
f.gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
f.gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
f.gear:SetScript("OnClick", ToggleOptions)
f.gear:SetScript("OnEnter", function(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT"); GameTooltip:AddLine("Options"); GameTooltip:Show()
end)
f.gear:SetScript("OnLeave", GameTooltip_Hide)

-- also list it under the game's AddOns settings
local function RegisterSettings()
  local panel = CreateFrame("Frame")
  panel.name = "Quest Ledger Forever"
  local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  t:SetPoint("TOPLEFT", 16, -16); t:SetText("Quest Ledger Forever")
  local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -6)
  sub:SetText("The classic separate quest log, with modern features. Open this page with the gear in the Quest Ledger or /ledger options.")
  BuildOptionList(panel, 16, -64)
  settingsPanel = panel
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    settingsCategory = cat
    pcall(Settings.RegisterAddOnCategory, cat)
  elseif InterfaceOptions_AddCategory then
    pcall(InterfaceOptions_AddCategory, panel)
  end
end
-- report problems instead of hiding them (CopyCat / error frame will show them)
do local ok, err = pcall(RegisterSettings); if not ok then geterrorhandler()("Quest Ledger settings page: " .. tostring(err)) end end

SLASH_QUESTLEDGERFOREVER1 = "/ledger"
SLASH_QUESTLEDGERFOREVER2 = "/qlf"
SlashCmdList.QUESTLEDGERFOREVER = function(msg)
  msg = (msg or ""):lower()
  if msg == "key" then
    DB.hookKey = not DB.hookKey
    print("|cffffd200Quest Ledger:|r L key " .. (DB.hookKey and "opens this quest log" or "uses the default Map & Quest Log") .. " (/reload to apply).")
  elseif msg == "reset" then
    DB.pos = nil
    DB.size = nil; ApplySize()
    if not docked then PlaceFree() end
  elseif msg == "options" or msg == "config" or msg == "settings" then
    ToggleOptions()
  elseif msg == "arrow" then
    DB.arrow = DB.arrow == false
    f.arrow:SetChecked(DB.arrow ~= false)
    print("|cffffd200Quest Ledger:|r 3D arrow " .. (DB.arrow ~= false and "follows the selected quest" or "off") .. ".")
  elseif msg == "units" then
    SetUnits(Units() == "m" and "yd" or "m")
    f.units:SetText(Units())
    print("|cffffd200Quest Ledger:|r arrow distance in " .. (Units() == "m" and "meters" or "yards") .. ".")
  elseif msg == "mapclick" then
    DB.mapClicks = DB.mapClicks == false
    print("|cffffd200Quest Ledger:|r Clicking quest icons on the map " .. (DB.mapClicks ~= false and "opens the quest log" or "does the default action") .. ".")
  elseif msg == "party" then
    mode = "party"
    f:Show()
    Refresh()
  else
    Toggle()
  end
end
