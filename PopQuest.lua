-- Quest Ledger Forever: PopQuest module
-- A popup when you loot an item that starts a quest, with a "View Quest" button.
-- (Merged from the standalone PopQuest addon. Fixed: it no longer tries to use the item by itself,
-- which WoW blocks with "Interface action failed because of an AddOn".)

-- If the old standalone PopQuest is still on: turn it off for next time and let it run alone this session.
do
  local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  local Disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
  local ok, _, _, _, loadable, reason = pcall(GetInfo, "PopQuest")
  if ok and loadable and reason ~= "MISSING" then
    pcall(Disable, "PopQuest")
    QuestLedgerForever_Replaced = QuestLedgerForever_Replaced or {}
    table.insert(QuestLedgerForever_Replaced, "PopQuest")
    return
  end
end

local function Enabled() return not (QuestLedgerForeverDB and QuestLedgerForeverDB.popQuest == false) end

local C = C_Container
local GetNumSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
local GetItemID   = (C and C.GetContainerItemID) or GetContainerItemID
local NUM_BAGS = NUM_BAG_SLOTS or 4
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local STARTS = ITEM_STARTS_QUEST or "This Item Begins a Quest"

local known, queue, ready = {}, {}, false

local scan = CreateFrame("GameTooltip", "QuestLedgerPopScanTip", nil, "GameTooltipTemplate")

-- true = starts a quest (not active yet), false = no, nil = item data not loaded yet
local function StartsQuest(bag, slot)
  if C and C.GetContainerItemQuestInfo then
    local ok, info = pcall(C.GetContainerItemQuestInfo, bag, slot)
    if ok and type(info) == "table" and info.questID then return not info.isActive end
  end
  if GetContainerItemQuestInfo then
    local ok, _, qid, active = pcall(GetContainerItemQuestInfo, bag, slot)
    if ok and qid then return not active end
  end
  scan:SetOwner(WorldFrame, "ANCHOR_NONE")
  scan:ClearLines()
  scan:SetBagItem(bag, slot)
  local n = scan:NumLines()
  if n == 0 then return nil end
  for i = 1, n do
    local fs = _G["QuestLedgerPopScanTipTextLeft" .. i]
    local t = fs and fs:GetText()
    if t and t:find(STARTS, 1, true) then return true end
  end
  local first = QuestLedgerPopScanTipTextLeft1 and QuestLedgerPopScanTipTextLeft1:GetText()
  if not first or first == "" or first == RETRIEVING_ITEM_INFO then return nil end
  return false
end

-- ===== popup =====
local f = CreateFrame("Frame", "QuestLedgerPopFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
f:SetSize(320, 110)
f:SetPoint("TOP", 0, -160)
f:SetFrameStrata("DIALOG")
if f.SetBackdrop then
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
end
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:Hide()

local icon = f:CreateTexture(nil, "ARTWORK")
icon:SetSize(36, 36); icon:SetPoint("TOPLEFT", 20, -20)
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, 0); title:SetPoint("RIGHT", -20, 0)
title:SetJustifyH("LEFT"); title:SetText("New quest available")
local name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
name:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4); name:SetPoint("RIGHT", -20, 0)
name:SetJustifyH("LEFT")

-- "View Quest" uses the item through a secure button: a real click, which WoW allows
local view = CreateFrame("Button", "QuestLedgerPopViewButton", f, "SecureActionButtonTemplate,UIPanelButtonTemplate")
view:SetSize(120, 24); view:SetPoint("BOTTOMLEFT", 30, 16)
view:SetText("View Quest")
view:RegisterForClicks("AnyUp", "AnyDown")
view:SetAttribute("type", "item")
local later = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
later:SetSize(120, 24); later:SetPoint("BOTTOMRIGHT", -30, 16)
later:SetText("Later")

local ShowNext
view:HookScript("OnClick", function()
  if not InCombatLockdown() then f:Hide(); C_Timer.After(0.3, function() ShowNext() end) end
end)
later:SetScript("OnClick", function() f:Hide(); ShowNext() end)

local function FindItem(itemID)
  for bag = 0, NUM_BAGS do
    for slot = 1, GetNumSlots(bag) or 0 do
      if GetItemID(bag, slot) == itemID then return bag, slot end
    end
  end
end

function ShowNext()
  if not Enabled() then wipe(queue); return end
  -- secure button attributes can't change in combat; we try again when combat ends
  if InCombatLockdown() or f:IsShown() then return end
  if QuestFrame and QuestFrame:IsShown() then return end
  local itemID = table.remove(queue, 1)
  if not itemID then return end
  local bag, slot = FindItem(itemID)
  if not bag then return ShowNext() end
  local nm, link, _, _, _, _, _, _, _, tex = GetInfo(itemID)
  icon:SetTexture(tex or GetIcon and GetIcon(itemID))
  name:SetText(link or nm or ("item " .. itemID))
  view:SetAttribute("item", bag .. " " .. slot)
  f:Show()
  PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN or 875)
end

-- ===== scanning =====
local pending = false
local function Scan()
  local now, unresolved = {}, false
  for bag = 0, NUM_BAGS do
    for slot = 1, GetNumSlots(bag) or 0 do
      local id = GetItemID(bag, slot)
      if id and now[id] == nil then
        local r = StartsQuest(bag, slot)
        if r == nil then unresolved = true; if known[id] ~= nil then now[id] = known[id] end
        else now[id] = r end
      end
    end
  end
  if ready and Enabled() then
    for id, yes in pairs(now) do
      if yes and not known[id] then table.insert(queue, id) end
    end
  end
  known = now
  ready = true
  if unresolved and not pending then
    pending = true
    C_Timer.After(1, function() pending = false; Scan() end)
  end
  ShowNext()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("QUEST_FINISHED")
ev:SetScript("OnEvent", function(_, e)
  if e == "PLAYER_ENTERING_WORLD" then
    if not ready then C_Timer.After(3, Scan) end -- remember what's already in your bags, silently
  elseif e == "QUEST_FINISHED" then
    C_Timer.After(0.3, ShowNext) -- next starter, if several were looted
  elseif e == "PLAYER_REGEN_ENABLED" then
    ShowNext()
  elseif ready then
    C_Timer.After(0.2, Scan)
  end
end)
