-- Quest Ledger Forever: LevelTag module
-- Shows [level] after quest names at quest givers and on the Accept window.
-- (Merged from the standalone LevelTag addon.)

-- If the old standalone LevelTag is still on: turn it off for next time and let it run alone this session.
do
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local Disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
    local ok, _, _, _, loadable, reason = pcall(GetInfo, "LevelTag")
    if ok and loadable and reason ~= "MISSING" then
        pcall(Disable, "LevelTag")
        QuestLedgerForever_Replaced = QuestLedgerForever_Replaced or {}
        table.insert(QuestLedgerForever_Replaced, "LevelTag")
        return
    end
end

local function Enabled() return not (QuestLedgerForeverDB and QuestLedgerForeverDB.levelTags == false) end

local TAG_PATTERN = " |c%x%x%x%x%x%x%x%x%[%d+%+?%]|r$"  -- inline fallback tag

-- Returns the colored tag text (e.g. "|cff40bf40[17]|r") or nil
local function BuildTag(questID)
    if not questID or questID == 0 then return nil end
    local ok, level = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
    if not ok or type(level) ~= "number" or level <= 0 then return nil end

    local elite = ""
    if C_QuestLog.IsEliteQuest then
        local okE, isElite = pcall(C_QuestLog.IsEliteQuest, questID)
        if okE and isElite then elite = "+" end
    end

    local color
    if C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer and GetDifficultyColor then
        local okC, diff = pcall(C_PlayerInfo.GetContentDifficultyQuestForPlayer, questID)
        if okC and diff then color = GetDifficultyColor(diff) end
    end
    if not color and GetQuestDifficultyColor then color = GetQuestDifficultyColor(level) end
    color = color or { r = 1, g = 0.82, b = 0 }

    return string.format("|cff%02x%02x%02x[%d%s]|r",
        math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5),
        level, elite)
end

local GAP = 4
local Measure = UIParent:CreateFontString(nil, "OVERLAY")
Measure:Hide()

local function HideTag(obj)
    if obj and obj.LevelTagFS then obj.LevelTagFS:Hide() end
end

-- Puts an outlined level tag right after the text of a button or font string.
-- Works for titles that wrap onto several lines too.
local function ApplyTag(obj, questID)
    if not obj then return false end
    local fs = obj.GetFontString and obj:GetFontString() or obj
    if not fs or not fs.GetText then return false end

    local text = fs:GetText()
    if not text or text == "" then HideTag(obj) return false end
    local clean = text:gsub(TAG_PATTERN, "")
    if clean ~= text then fs:SetText(clean) end

    local tag = Enabled() and BuildTag(questID)
    if not tag then HideTag(obj) return false end

    local tagFS = obj.LevelTagFS
    if not tagFS then
        local parent = fs.GetParent and fs:GetParent() or obj
        tagFS = parent:CreateFontString(nil, "OVERLAY")
        obj.LevelTagFS = tagFS
    end
    local font, size, flags = fs:GetFont()
    if font then tagFS:SetFont(font, size, "OUTLINE") end
    tagFS:SetText(tag)

    local boxW = fs:GetWidth()
    local tagW = tagFS:GetStringWidth()
    local numLines = fs.GetNumLines and fs:GetNumLines() or 1
    local x, y

    if numLines <= 1 then
        x = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) + GAP
        y = 0
    elseif font and boxW and boxW > 0 then
        -- Title wraps: work out how wide its last line is by wrapping the words ourselves
        Measure:SetFont(font, size, flags or "")
        local line, lastW = "", 0
        for word in clean:gmatch("%S+") do
            local try = (line == "") and word or (line .. " " .. word)
            Measure:SetText(try)
            if Measure:GetStringWidth() > boxW and line ~= "" then
                line = word
            else
                line = try
            end
        end
        Measure:SetText(line)
        lastW = Measure:GetStringWidth()
        local lineH = fs:GetStringHeight() / numLines
        x = lastW + GAP
        y = -(numLines - 1) * lineH
    end

    if x and boxW and boxW > 0 and (x + tagW) <= boxW then
        tagFS:ClearAllPoints()
        if numLines <= 1 then
            tagFS:SetPoint("LEFT", fs, "LEFT", x, 0)
        else
            tagFS:SetPoint("TOPLEFT", fs, "TOPLEFT", x, y)
        end
        tagFS:Show()
    else
        tagFS:Hide()
        fs:SetText(clean .. " " .. tag)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- 1) Gossip window (NPCs with chat text + quests)
---------------------------------------------------------------------------
local function TagGossipButton(button, questInfo)
    if questInfo and ApplyTag(button, questInfo.questID) and button.Resize then button:Resize() end
end

for _, mixinName in ipairs({ "GossipAvailableQuestButtonMixin", "GossipActiveQuestButtonMixin" }) do
    local mixin = _G[mixinName]
    if mixin and mixin.Setup then hooksecurefunc(mixin, "Setup", TagGossipButton) end
end

-- Backup: walk the visible gossip buttons after GOSSIP_SHOW
local function TagGossipVisible()
    local box = GossipFrame and GossipFrame.GreetingPanel and GossipFrame.GreetingPanel.ScrollBox
    if not box or not box.ForEachFrame then return end
    box:ForEachFrame(function(button, elementData)
        local t = elementData and elementData.buttonType
        if t == GOSSIP_BUTTON_TYPE_AVAILABLE_QUEST or t == GOSSIP_BUTTON_TYPE_ACTIVE_QUEST then
            TagGossipButton(button, elementData.info)
        end
    end)
end

---------------------------------------------------------------------------
-- 2) Quest greeting window (NPCs that only list quests)
---------------------------------------------------------------------------
local function TagGreeting()
    local panel = QuestFrameGreetingPanel
    if not panel or not panel:IsShown() or not panel.titleButtonPool then return end
    for button in panel.titleButtonPool:EnumerateActive() do
        local questID
        if button.isActive == 1 then
            questID = GetActiveQuestID and GetActiveQuestID(button:GetID())
        elseif GetAvailableQuestInfo then
            questID = select(5, GetAvailableQuestInfo(button:GetID()))
        end
        if ApplyTag(button, questID) then
            local icon = button.Icon
            button:SetHeight(math.max(button:GetTextHeight() + 2, icon and icon:GetHeight() or 16))
        end
    end
end

if QuestFrameGreetingPanel then
    QuestFrameGreetingPanel:HookScript("OnShow", TagGreeting)
end

---------------------------------------------------------------------------
-- 3) Quest detail window (the one with the Accept button)
---------------------------------------------------------------------------
if QuestInfo_Display then
    hooksecurefunc("QuestInfo_Display", function(template)
        if template ~= QUEST_TEMPLATE_DETAIL then HideTag(QuestInfoTitleHeader) return end
        ApplyTag(QuestInfoTitleHeader, GetQuestID and GetQuestID())
    end)
end

-- Safety net: re-check one frame after the events, in case Blizzard redraws.
local f = CreateFrame("Frame")
f:RegisterEvent("GOSSIP_SHOW")
f:RegisterEvent("QUEST_GREETING")
f:RegisterEvent("QUEST_DETAIL")
f:SetScript("OnEvent", function(_, event)
    C_Timer.After(0, function()
        if event == "GOSSIP_SHOW" then
            TagGossipVisible()
        elseif event == "QUEST_GREETING" then
            TagGreeting()
        elseif QuestFrameDetailPanel and QuestFrameDetailPanel:IsShown() then
            ApplyTag(QuestInfoTitleHeader, GetQuestID and GetQuestID())
        end
    end)
end)
