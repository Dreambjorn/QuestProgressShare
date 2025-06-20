-- Reference to main addon table
local QPS = QuestProgressShare
-- Core.lua - Main logic for QuestProgressShare

-- State variables for quest progress tracking
local lastProgress = {} -- Table storing the most recent progress for each quest objective
local completedQuestTitle = nil -- Title of the quest currently being turned in (used for completion detection)
local sentCompleted = {} -- Tracks which quests have already had a completion message sent this session to prevent duplicates

-- Local aliases for Blizzard quest log API
local QPSGet_QuestLogTitle = GetQuestLogTitle
local QPSGet_NumQuestLogEntries = GetNumQuestLogEntries
local QPSGet_QuestLogLeaderBoard = GetQuestLogLeaderBoard
local QPSSelect_QuestLogEntry = SelectQuestLogEntry
local QPSGet_QuestLogQuestText = GetQuestLogQuestText
local QPSGet_NumQuestLeaderBoards = GetNumQuestLeaderBoards

-- pfQuest integration (if available)
local getQuestIDs = pfDatabase and pfDatabase.GetQuestIDs -- Reference to pfQuest's GetQuestIDs function if available
local pfDB = pfDB -- Reference to pfQuest's global database table if available

-- Returns a clickable quest link for chat, using pfQuest data if available
local function GetClickableQuestLink(questID, title)
    local qid = tostring(questID)
    local qid_num = tonumber(questID)
    local locale = GetLocale and GetLocale() or "enUS"
    local pfquests = pfDB and pfDB["quests"]
    local pfdbs = {
        { data = pfquests and pfquests["data"], loc = pfquests and pfquests["loc"] }, -- pfQuest legacy
        { data = pfquests and pfquests["data-turtle"], loc = pfquests and pfquests[locale.."-turtle"] }, -- pfQuest-turtle
        { data = pfquests and pfquests["data"], loc = pfquests and pfquests[locale] } -- pfQuest with locale
    }
    local foundData, foundLoc, foundType
    for i, db in ipairs(pfdbs) do
        if db.data and db.loc then
            local data = db.data[qid] or (qid_num and db.data[qid_num])
            local loc = db.loc[qid] or (qid_num and db.loc[qid_num])
            if data or loc then
                foundData, foundLoc = data, loc
                foundType = (i == 1 and "pfQuest-loc") or (i == 2 and "pfQuest-turtle") or (i == 3 and "pfQuest-locale")
                break
            end
        end
    end
    local link
    if foundData or foundLoc then
        local level = foundData and foundData["lvl"] or 0
        local name = foundLoc and foundLoc["T"] or (foundData and foundData["T"] or ("Quest "..qid))
        local hex = "|cffffff00"
        if pfUI and pfUI.api and pfUI.api.rgbhex and pfQuestCompat and pfQuestCompat.GetDifficultyColor then
            hex = pfUI.api.rgbhex(pfQuestCompat.GetDifficultyColor(level))
        end
        link = hex .. "|Hquest:"..qid..":"..level.."|h["..name.."]|h|r"
    elseif questID and tonumber(questID) then
        local safeTitle = (type(title) == "string" and title) or ("Quest "..tostring(questID))
        local cleanTitle = StringLib.Gsub(safeTitle, "|", "")
        local hex = "|cffffff00"
        if pfUI and pfUI.api and pfUI.api.rgbhex and pfQuestCompat and pfQuestCompat.GetDifficultyColor then
            hex = pfUI.api.rgbhex(pfQuestCompat.GetDifficultyColor(0))
        end
        link = hex .. "|Hquest:"..tostring(questID)..":0|h["..cleanTitle.."]|h|r"
    elseif type(title) == "string" and StringLib.Sub(title, 1, 8) == "|Hquest:" then
        if StringLib.Sub(title, 1, 10) ~= "|cffffff00" then
            link = "|cffffff00" .. title .. "|r"
        else
            link = title
        end
    elseif type(title) == "string" then
        local safeTitle = StringLib.Gsub(title, "|", "")
        link = "[" .. safeTitle .. "]"
    else
        link = qid
    end
    if type(link) == "string" and StringLib.Sub(link, 1, 8) == "|Hquest:" then
        if StringLib.Sub(link, 1, 10) ~= "|cffffff00" then
            link = "|cffffff00" .. link .. "|r"
        end
    end
    return link
end

-- Checks if a quest log index is valid and points to a real quest (not a header)
local function IsValidQuestLogIndex(index)
    if type(index) ~= "number" or index < 1 or index > QPSGet_NumQuestLogEntries() then return false end
    local title, _, _, isHeader = QPSGet_QuestLogTitle(index)
    return (not isHeader) and title and title ~= ""
end

-- Cache for SafeGetQuestIDs results per scan
local questIDCache = {} -- Maps quest log index to a list of quest IDs

-- Safely retrieves quest IDs using pfQuest, with fallback and caching
local function SafeGetQuestIDs(index, title)
    if questIDCache[index] ~= nil then
        return questIDCache[index]
    end
    if not IsValidQuestLogIndex(index) then
        questIDCache[index] = nil
        return nil
    end
    if getQuestIDs then
        local ok, ids = pcall(getQuestIDs, index)
        if ok and ids and ids[1] then
            questIDCache[index] = ids
            return ids
        else
            local logTitle = GetQuestLogTitle(index)
            if title and logTitle and logTitle == title and pfDB and pfDB["quests"] and pfDB["quests"]["loc"] then
                for id, data in pairs(pfDB["quests"]["loc"]) do
                    if data.T == title then
                        questIDCache[index] = { tonumber(id) }
                        return questIDCache[index]
                    end
                end
            end
        end
    end
    questIDCache[index] = nil
    return nil
end

-- Scans the quest log and updates lastProgress without sending messages
local function DummyQuestProgressScan()
    for questIndex = 1, QPSGet_NumQuestLogEntries() do
        local title, _, _, isHeader, _, _, isComplete = QPSGet_QuestLogTitle(questIndex)
        if not isHeader and title and IsValidQuestLogIndex(questIndex) then
            if pfDB then
                local ids = SafeGetQuestIDs(questIndex, title)
                local questID = ids and ids[1] and tonumber(ids[1])
                if questID then
                    QPSSelect_QuestLogEntry(questIndex)
                end
            else
                QPSSelect_QuestLogEntry(questIndex)
            end
            local objectives = QPSGet_NumQuestLeaderBoards()
            -- Handle turn-in only quests (no objectives)
            if objectives == 0 and isComplete then
                local questKey = title .. "-COMPLETE"
                lastProgress[questKey] = "Quest completed"
            end
            for i = 1, objectives do
                local text = QPSGet_QuestLogLeaderBoard(i)
                local questKey = title .. "-" .. i
                lastProgress[questKey] = text
            end
            if objectives > 0 then
                local questKey = title .. "-COMPLETE"
                if isComplete then
                    lastProgress[questKey] = "Quest completed"
                end
            end
        end
    end
end

-- Finds a quest ID by its title using pfQuest DB
local function FindQuestIDByTitle(title)
    if pfDB and pfDB.quests and pfDB.quests.loc then
        for id, data in pairs(pfDB.quests.loc) do
            if data.T == title then
                return tonumber(id)
            end
        end
    end
    return nil
end

-- Sends a quest progress or completion message, using clickable links if possible
local function SendQuestMessage(title, text, finished, questIndex)
    if finished and sentCompleted[title] then return end
    if finished then sentCompleted[title] = true end
    local questID = nil
    if pfDB then
        if questIndex then
            local ids = SafeGetQuestIDs(questIndex, title)
            if ids and ids[1] then
                questID = ids[1]
                -- Double-check: only send if the quest title for this questIndex matches pfQuest DB for this questID
                local pfTitle = nil
                if pfDB.quests and pfDB.quests.loc and pfDB.quests.loc[tostring(questID)] then
                    pfTitle = pfDB.quests.loc[tostring(questID)].T
                end
                local logTitle = GetQuestLogTitle(questIndex)
                if pfTitle and logTitle and pfTitle ~= logTitle then
                    -- Mismatch: do not send
                    return
                end
            else
                questID = FindQuestIDByTitle(title)
            end
        else
            questID = FindQuestIDByTitle(title)
        end
    elseif getQuestIDs then
        local ids = getQuestIDs(title)
        if ids and ids[1] then questID = ids[1] end
    end
    if pfDB and questID then
        local link = GetClickableQuestLink(questID, title)
        -- Accept any link containing |Hquest: as a clickable quest link
        if link and type(link) == "string" and StringLib.Find(link, "|Hquest:") then
            QPS.chatMessage.SendLink(link, text, finished)
            return
        end
    end
    QPS.chatMessage.Send(title, text, finished)
end

-- Returns true if this is the first time the addon has ever loaded for this character (based on load count)
local function IsFirstLoadEver()
    return QPS_SavedLoadCount == 1
end

-- In-memory cache of last known quest log state (used for diffing quest changes)
local questLogCache = {}

-- Quest hash function for robust quest identification (uses name and level)
local function QPS_GetQuestHash(name, level)
    -- Use only name and level for the hash to ensure progress changes are detected
    local hash = tostring(name or "") .. "|" .. tostring(level or "")
    return hash
end

-- Helper: Normalize objective text for stable comparison (removes color codes and trims whitespace)
local function NormalizeObjectiveText(text)
    if not text then return "" end
    -- Remove WoW color codes
    text = StringLib.Gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = StringLib.Gsub(text, "|r", "")
    -- Trim whitespace
    text = StringLib.Gsub(text, "^%s+", "")
    text = StringLib.Gsub(text, "%s+$", "")
    return text
end

-- Helper: Sort objectives by normalized text for stable comparison (bubble sort for compatibility)
local function SortObjectives(objectives)
    -- Simple bubble sort for compatibility
    local n = 0
    for _ in pairs(objectives) do n = n + 1 end
    for i = 1, n - 1 do
        for j = i + 1, n do
            if objectives[i] and objectives[j] and objectives[i].text > objectives[j].text then
                local tmp = objectives[i]
                objectives[i] = objectives[j]
                objectives[j] = tmp
            end
        end
    end
end

-- Helper: Build a snapshot of the current quest log state (for diffing and cache)
local function BuildQuestLogSnapshot()
    local snapshot = {}
    local numEntries = QPSGet_NumQuestLogEntries()
    for questIndex = 1, numEntries do
        local title, level, _, isHeader, _, _, isComplete = QPSGet_QuestLogTitle(questIndex)
        if not isHeader and title then
            -- Always select the quest to ensure objectives are up-to-date (matches Questie logic)
            QPSSelect_QuestLogEntry(questIndex)
            local objectives = {}
            local numObjectives = QPSGet_NumQuestLeaderBoards()
            for i = 1, numObjectives do
                local text, objType, finished = QPSGet_QuestLogLeaderBoard(i)
                text = NormalizeObjectiveText(text)
                objectives[i] = { text = text, finished = finished }
            end
            SortObjectives(objectives)
            local hash = QPS_GetQuestHash(title, level)
            snapshot[hash] = {
                title = title,
                level = level,
                isComplete = isComplete,
                objectives = objectives,
            }
        end
    end
    return snapshot
end

-- Helper: Returns true if any quest log headers are collapsed (prevents accurate scanning)
local function AnyQuestLogHeadersCollapsed()
    local numEntries = QPSGet_NumQuestLogEntries()
    for i = 1, numEntries do
        local _, _, _, isHeader, isCollapsed = QPSGet_QuestLogTitle(i)
        if isHeader and isCollapsed then
            return true
        end
    end
    return false
end

-- Global debug log table
QPS_DebugLog = {}

local function LogDebugMessage(msg)
    if not (QuestProgressShareConfig and QuestProgressShareConfig.debugEnabled) then return end
    if not msg then return end
    local timestamp = date("%Y-%m-%d %H:%M")
    local logMsg = "[" .. timestamp .. "] " .. tostring(msg)
    table.insert(QPS_DebugLog, logMsg)
end

-- Helper: Load questLogCache from QPS_SavedProgress (for silent cache refresh)
local function LoadCacheFromSavedProgress()
    for k in pairs(questLogCache) do questLogCache[k] = nil end
    if QPS_SavedProgress then
        for k, v in pairs(QPS_SavedProgress) do
            questLogCache[k] = v
        end
    end
end

-- Helper: Table length for associative or array tables (Vanilla WoW compatible)
local function GetTableLength(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

-- Removes all lastProgress entries for a given quest (by title or questKey)
local function RemoveQuestProgressForQuest(questKeyOrTitle)
    if not questKeyOrTitle then return end
    -- If it's a questKey (contains a dash and a number or COMPLETE), extract the title
    local title = questKeyOrTitle
    local dash = StringLib.Find(questKeyOrTitle, "-%d+$") or StringLib.Find(questKeyOrTitle, "-COMPLETE$")
    if dash then
        title = StringLib.Sub(questKeyOrTitle, 1, dash - 1)
    end
    local titleLen = StringLib.Len(title)
    for k in pairs(lastProgress) do
        if StringLib.Sub(k, 1, titleLen + 1) == (title .. "-") or k == (title .. "-COMPLETE") then
            lastProgress[k] = nil
        end
    end
end

-- Helper: Quest log update logic, called from both QUEST_LOG_UPDATE and QUEST_ITEM_UPDATE
local function HandleQuestLogUpdate()
    if AnyQuestLogHeadersCollapsed() then
        LogDebugMessage("Quest log headers are collapsed; progress tracking paused.")
        if not QPS._notifiedCollapsed then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffb48affQuestProgressShare:|r Quest tracking paused. " ..
                "Please expand all quest log headers for accurate progress sharing!"
            )
            QPS._notifiedCollapsed = true
        end
        QPS._pendingSilentRefresh = true
        return
    else
        QPS._notifiedCollapsed = false
    end
    -- If a silent refresh is pending, update cache and check for new quests
    local foundNewQuest = false
    if QPS._pendingSilentRefresh then
        LogDebugMessage("Silent refresh triggered due to collapsed headers or entering world.")
        local currentSnapshot = BuildQuestLogSnapshot()
        -- Compare current snapshot to QPS_SavedKnownQuests (from before headers were expanded)
        if QPS_SavedKnownQuests then
            for hash, data in pairs(currentSnapshot) do
                local debugMsg = "QPS Debug (SilentRefresh): Checking quest for 'accepted': "..(data.title or hash)
                if not QPS_SavedKnownQuests[data.title] then
                    LogDebugMessage(debugMsg.." | Not in saved known quests: SENDING 'Quest accepted'")
                    SendQuestMessage(data.title, "Quest accepted", false)
                    foundNewQuest = true
                else
                    LogDebugMessage(debugMsg.." | In saved known quests: SKIP")
                end
            end
        end
        -- If a new quest was found, force update QPS_SavedKnownQuests
        if foundNewQuest then
            if QPS_SavedKnownQuests then
                for k in pairs(QPS_SavedKnownQuests) do QPS_SavedKnownQuests[k] = nil end
            else
                QPS_SavedKnownQuests = {}
            end
            for hash, data in pairs(currentSnapshot) do
                QPS_SavedKnownQuests[data.title] = true
            end
            LogDebugMessage("QPS Debug: QPS_SavedKnownQuests force-updated after new quest detected.")
        end
        -- Update the cache as usual
        for k in pairs(questLogCache) do questLogCache[k] = nil end
        for k, v in pairs(currentSnapshot) do questLogCache[k] = v end
        QPS._pendingSilentRefresh = false
        LogDebugMessage("QPS Debug: Silent cache refresh after headers expanded (with new quest detection).")
        return
    end
    if not QPS.ready then return end
    if not QPS.knownQuests then QPS.knownQuests = {} end

    local currentSnapshot = BuildQuestLogSnapshot()
    -- Diff with previous cache (Questie style)
    local changes = {}
    -- Detect new quests (accepted)
    for hash, newData in pairs(currentSnapshot) do
        local debugMsg = "QPS Debug: Checking quest for 'accepted': "..(newData.title or hash)
        if not questLogCache[hash] and (not QPS_SavedKnownQuests or not QPS_SavedKnownQuests[newData.title]) then
            LogDebugMessage("Quest accepted: " .. tostring(newData.title))
            table.insert(changes, { type = "added", hash = hash, data = newData })
            foundNewQuest = true
            if QPS_SavedKnownQuests then
                QPS_SavedKnownQuests[newData.title] = true
            else
                QPS_SavedKnownQuests = { [newData.title] = true }
            end
        elseif not questLogCache[hash] then
            LogDebugMessage(debugMsg.." | Not in cache but IS in saved known quests: SKIP")
        elseif not QPS_SavedKnownQuests or not QPS_SavedKnownQuests[newData.title] then
            LogDebugMessage(debugMsg.." | In cache but NOT in saved known quests: SKIP")
        else
            LogDebugMessage(debugMsg.." | In both cache and saved known quests: SKIP")
        end
    end
    -- Detect removed quests (abandoned or completed and instantly removed)
    for hash, oldData in pairs(questLogCache) do
        if not currentSnapshot[hash] then
            LogDebugMessage("Quest removed: " .. tostring(oldData.title))
            table.insert(changes, { type = "removed", hash = hash, data = oldData })
        end
    end
    -- Detect progress/completion
    for hash, newData in pairs(currentSnapshot) do
        local oldData = questLogCache[hash]
        LogDebugMessage(
            "QPS Debug: Diff loop - hash: " .. tostring(hash) ..
            ", newData.title: " .. tostring(newData.title) ..
            ", oldData: " .. (oldData and oldData.title or "nil")
        )
        if oldData then
            -- Completion (only if QUEST_COMPLETE event matches)
            LogDebugMessage("QPS Debug: Checking completion for newData.title='" .. tostring(newData.title) ..
                ", completedQuestTitle='" .. tostring(completedQuestTitle) .. "'")
            -- The 'completed' handler is left as a fallback for rare edge cases or future compatibility.
            if completedQuestTitle and newData.title == completedQuestTitle then
                LogDebugMessage("Quest completed: " .. tostring(newData.title))
                table.insert(changes, { type = "completed", hash = hash, data = newData })
            else
                -- Progress: compare objectives and send messages like ScanQuestEntry
                local numObjectives = GetTableLength(newData.objectives)
                for i = 1, numObjectives do
                    local obj = newData.objectives[i]
                    local oldObj = oldData.objectives and oldData.objectives[i] or nil
                    local questKey = (newData.title or "") .. "-" .. i
                    local isMeaningless = false
                    if type(obj.text) ~= "string" then
                        isMeaningless = true
                    else
                        local current = StringLib.SafeExtractNumbers(obj.text, LogDebugMessage)
                        if not current or tonumber(current) == 0 then
                            isMeaningless = true
                        end
                    end
                    if obj.finished then
                        if lastProgress[questKey] ~= obj.text and lastProgress[questKey] ~= "Quest completed" then
                            LogDebugMessage("Objective progress: " .. questKey .. " changed from '" .. tostring(lastProgress[questKey]) .. "' to '" .. tostring(obj.text) .. "'")
                            SendQuestMessage(newData.title, obj.text, obj.finished)
                            lastProgress[questKey] = obj.text -- Prevent repeated sending of final progress
                        end
                        if lastProgress[questKey] ~= "Quest completed" then
                            LogDebugMessage("Objective completed: " .. questKey)
                            lastProgress[questKey] = "Quest completed"
                        end
                    else
                        -- Check if this is the first time seeing this objective or if the progress is empty
                        if (lastProgress[questKey] == nil or lastProgress[questKey] == "") then
                            if not isMeaningless
                                and (
                                    QuestProgressShareConfig.sendStartingQuests or
                                    (type(obj.text) == "string" and StringLib.Sub(obj.text, 1, 3) ~= " : ")
                                )
                                and (
                                    obj.finished or not QuestProgressShareConfig.sendOnlyFinished
                                )
                                and (
                                    not completedQuestTitle or completedQuestTitle ~= newData.title
                                )
                            then
                                LogDebugMessage(
                                    "Objective progress: " .. questKey .. " changed from '" .. tostring(lastProgress[questKey]) .. "' to '" .. tostring(obj.text) .. "'")
                                LogDebugMessage(
                                    "QPS Debug: Progress change will be reported for " ..
                                    (newData.title or "<nil>") ..
                                    " obj: " .. tostring(obj.text)
                                )
                                SendQuestMessage(newData.title, obj.text, obj.finished)
                            end
                        elseif lastProgress[questKey] ~= obj.text then
                            LogDebugMessage(
                                "Objective progress: " .. questKey .. " changed from '" .. tostring(lastProgress[questKey]) .. "' to '" .. tostring(obj.text) .. "'")
                            lastProgress[questKey] = obj.text
                            if not isMeaningless
                                and (
                                    obj.finished or not QuestProgressShareConfig.sendOnlyFinished
                                )
                                and (
                                    not completedQuestTitle or completedQuestTitle ~= newData.title
                                )
                            then
                                LogDebugMessage(
                                    "QPS Debug: Progress change will be reported for " ..
                                    (newData.title or "<nil>") ..
                                    " obj: " .. tostring(obj.text)
                                )
                                SendQuestMessage(newData.title, obj.text, obj.finished)
                            end
                        end
                    end
                end
            end
        end
    end
    -- Only process if there are real changes
    if GetTableLength(changes) > 0 then
        LogDebugMessage("QPS Debug: Changes detected: " .. GetTableLength(changes))
        for _, change in ipairs(changes) do
            local data = change.data or {}
            LogDebugMessage("QPS Debug: Processing change type: "..tostring(change.type)..", data.title: "..tostring(data.title))
            if change.type == "added" then
                -- Only send 'Quest accepted' if sendStartingQuests is enabled
                if QuestProgressShareConfig.sendStartingQuests then
                    SendQuestMessage(data.title, "Quest accepted", false)
                end
            elseif change.type == "completed" then
                SendQuestMessage(data.title, "Quest completed", true)
                RemoveQuestProgressForQuest(data.title)
            elseif change.type == "progress" then
                LogDebugMessage("QPS Debug: Progress detected for "..(data.title or "<nil>").." text: "..tostring(change.text))
                SendQuestMessage(data.title, change.text, false)
            elseif change.type == "removed" then
                if completedQuestTitle and data.title == completedQuestTitle then
                    SendQuestMessage(data.title, "Quest completed", true)
                else
                    -- Send abandoned message if not completed
                    SendQuestMessage(data.title, "Quest abandoned", false)
                    -- Remove from known quests so re-accepting triggers 'Quest accepted'
                    if QPS_SavedKnownQuests then QPS_SavedKnownQuests[data.title] = nil end
                    if QPS.knownQuests then QPS.knownQuests[data.title] = nil end
                end
                RemoveQuestProgressForQuest(data.title)
            end
        end
    end

    -- Update questLogCache in place to preserve reference
    for k in pairs(questLogCache) do
        if not currentSnapshot[k] then questLogCache[k] = nil end
    end
    for k, v in pairs(currentSnapshot) do
        questLogCache[k] = v
    end
    -- Detailed objective progress diff logging
    for hash, newData in pairs(currentSnapshot) do
        local oldData = questLogCache[hash]
        if oldData then
            local numObjectives = GetTableLength(newData.objectives)
            for i = 1, numObjectives do
                local obj = newData.objectives[i]
                local oldObj = oldData.objectives and oldData.objectives[i] or nil
                LogDebugMessage("QPS Debug: Objective diff for " .. (newData.title or hash) .. " [" .. i .. "]: old='" .. tostring(oldObj and oldObj.text or "<nil>") .. "', new='" .. tostring(obj and obj.text or "<nil>") .. "', finished=" .. tostring(obj and obj.finished))
            end
        end
    end
end

-- Main event handler for all registered events
function OnEvent()
    -- Debug: Log every event received
    LogDebugMessage("QPS Debug: Event received: " .. tostring(event) .. (arg1 and (", arg1: " .. tostring(arg1)) or ""))
    -- Handles quest completion (when quest turn-in window is opened)
    if event == "QUEST_COMPLETE" then
        if GetTitleText then
            completedQuestTitle = GetTitleText()
        end
        return

    -- Handles player login: initializes known quests and prints loaded message
    elseif event == "PLAYER_LOGIN" then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffb48affQuestProgressShare|r loaded.")
        end
        if pfDB then
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffb48affQuestProgressShare: pfQuest integration enabled!|r")
            end
        end

        -- Clear debug log at the start of every session
        QPS_DebugLog = {}

        -- Initialize known quests from SavedVariables
        if not QPS_SavedKnownQuests then QPS_SavedKnownQuests = {} end
        QPS.knownQuests = {}
        for k, v in pairs(QPS_SavedKnownQuests) do QPS.knownQuests[k] = v end

        -- Loads last progress from SavedVariables
        if not QPS_SavedProgress then QPS_SavedProgress = {} end
        for k, v in pairs(QPS_SavedProgress) do lastProgress[k] = v end

        -- Robust load count increment: only increment after login
        if QPS_SavedLoadCount == nil then QPS_SavedLoadCount = 0 end
        QPS_SavedLoadCount = QPS_SavedLoadCount + 1

        -- If headers are collapsed at login, load cache from saved progress
        if AnyQuestLogHeadersCollapsed() then
            LoadCacheFromSavedProgress()
            QPS._pendingSilentRefresh = true
        else
            QPS._pendingSilentRefresh = false
        end
        -- If first load ever, do a dummy scan and update saved variables, but do not send messages
        QPS._didFirstLoadInit = false
        if IsFirstLoadEver() then
            QPS._didFirstLoadInit = true
        end
        sentCompleted = {}
        return

    -- Handles addon load: sets default config and updates config UI
    elseif event == "ADDON_LOADED" and arg1 == "QuestProgressShare" then
        QPS.config.SetDefaultConfigValues()
        UpdateConfigFrame()
        return

    -- Handles entering world: delays quest log scanning until fully loaded
    elseif event == "PLAYER_ENTERING_WORLD" then
        QPS.ready = false
        if not QPS.delayFrame then
            QPS.delayFrame = CreateFrame("Frame")
        end
        QPS.delayFrame.elapsed = 0
        QPS.delayFrame.startTime = time()
        QPS.delayFrame:SetScript("OnUpdate", function()
            local now = time()
            if (now - QPS.delayFrame.startTime) >= 3 then
                QPS.ready = true
                QPS.delayFrame:SetScript("OnUpdate", nil)

                -- If headers are collapsed at entering world,
                -- set pending silent refresh to true so cache will be updated after headers are expanded
                if AnyQuestLogHeadersCollapsed() then
                    QPS._pendingSilentRefresh = true
                else
                    QPS._pendingSilentRefresh = false
                end

                -- Questie-style: Take initial snapshot for cache
                local initialSnapshot = BuildQuestLogSnapshot()
                for k in pairs(questLogCache) do questLogCache[k] = nil end
                for k, v in pairs(initialSnapshot) do questLogCache[k] = v end

                -- If first load ever, do a dummy scan and update saved variables, but do not send messages
                if QPS._didFirstLoadInit then
                    DummyQuestProgressScan()

                    -- Save lastProgress to SavedVariables (clear old data first)
                    if QPS_SavedProgress then
                        for k in pairs(QPS_SavedProgress) do QPS_SavedProgress[k] = nil end
                    else
                        QPS_SavedProgress = {}
                    end
                    for k, v in pairs(lastProgress) do
                        QPS_SavedProgress[k] = v
                    end

                    -- Also update known quests
                    for questIndex = 1, QPSGet_NumQuestLogEntries() do
                        local title, _, _, isHeader = QPSGet_QuestLogTitle(questIndex)
                        if not isHeader and title then
                            QPS.knownQuests[title] = true
                        end
                    end

                    if QPS_SavedKnownQuests then
                        for k in pairs(QPS_SavedKnownQuests) do QPS_SavedKnownQuests[k] = nil end
                    else
                        QPS_SavedKnownQuests = {}
                    end
                    for k, v in pairs(QPS.knownQuests) do
                        QPS_SavedKnownQuests[k] = v
                    end

                    -- Mark first-load initialization as complete
                    QPS._didFirstLoadInit = false
                else
                    DummyQuestProgressScan() -- Populates lastProgress for any new quests
                end
            end
        end)
        return

    -- Handles quest item updates: triggers quest log update logic for quest item changes
    elseif event == "QUEST_ITEM_UPDATE" then
        LogDebugMessage("QPS Debug: HandleQuestLogUpdate triggered by QUEST_ITEM_UPDATE")
        HandleQuestLogUpdate()
        return

    -- Handles quest log updates: detects quest accept, completion, and progress
    elseif event == "QUEST_LOG_UPDATE" and QuestProgressShareConfig.enabled then
        LogDebugMessage("QPS Debug: HandleQuestLogUpdate triggered by QUEST_LOG_UPDATE")
        HandleQuestLogUpdate()

    -- Handles player logout: saves progress and known quests
    elseif event == "PLAYER_LOGOUT" then
        -- Only update and save known quests if all headers are expanded
        if not AnyQuestLogHeadersCollapsed() then
            local snapshot = BuildQuestLogSnapshot()
            if QPS_SavedKnownQuests then
                for k in pairs(QPS_SavedKnownQuests) do QPS_SavedKnownQuests[k] = nil end
            else
                QPS_SavedKnownQuests = {}
            end
            for _, data in pairs(snapshot) do
                QPS_SavedKnownQuests[data.title] = true
            end
        end

        -- Save lastProgress to QPS_SavedProgress on logout only
        if QPS_SavedProgress then
            for k in pairs(QPS_SavedProgress) do QPS_SavedProgress[k] = nil end
        else
            QPS_SavedProgress = {}
        end
        for k, v in pairs(lastProgress) do QPS_SavedProgress[k] = v end
        
        -- Remove progress for quests that are no longer in known quests before saving
        if QPS_SavedKnownQuests then
            for k in pairs(lastProgress) do
                -- Extract the quest title: remove the last dash and everything after it
                local questTitle = k
                local lastDash = nil
                for i = StringLib.Len(k), 1, -1 do
                    if StringLib.Sub(k, i, i) == "-" then
                        lastDash = i
                        break
                    end
                end
                if lastDash then
                    questTitle = StringLib.Sub(k, 1, lastDash - 1)
                end
                if not QPS_SavedKnownQuests[questTitle] then
                    lastProgress[k] = nil
                end
            end
        end

        return
    end
end

-- Registers for all relevant quest and addon events
QPS:RegisterEvent("QUEST_LOG_UPDATE")
QPS:RegisterEvent("PLAYER_LOGIN")
QPS:RegisterEvent("ADDON_LOADED")
QPS:RegisterEvent("PLAYER_ENTERING_WORLD")
QPS:RegisterEvent("QUEST_COMPLETE")
QPS:RegisterEvent("PLAYER_LOGOUT")
QPS:RegisterEvent("QUEST_ITEM_UPDATE")
QPS:SetScript("OnEvent", OnEvent)