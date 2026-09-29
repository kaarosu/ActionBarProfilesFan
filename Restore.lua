local addonName, addon = ...

local L = LibStub("AceLocale-3.0"):GetLocale(addonName)
local DEBUG = ABP_DEBUG_PREFIX

-- Localize globals for performance
local _G = _G
local pairs, ipairs, select, unpack = pairs, ipairs, select, unpack
local tonumber, tostring, type, pcall = tonumber, tostring, type, pcall
local strsplit, format = strsplit, format
local bit = bit
local UnitClass, UnitLevel, UnitFactionGroup = UnitClass, UnitLevel, UnitFactionGroup
local GetSpecialization, GetSpecializationInfo = GetSpecialization, GetSpecializationInfo
local IsResting, IsSpellKnown, PlayerHasToy = IsResting, IsSpellKnown, PlayerHasToy
local GetNumMacros, GetMacroInfo, CreateMacro, DeleteMacro = GetNumMacros, GetMacroInfo, CreateMacro, DeleteMacro
local GetBinding, SetBinding, GetNumBindings, SetBindingClick = GetBinding, SetBinding, GetNumBindings, SetBindingClick
local GetCurrentBindingSet, SaveBindings = GetCurrentBindingSet, SaveBindings
local GetProfessions, GetProfessionInfo = GetProfessions, GetProfessionInfo
local GetFlyoutInfo, GetFlyoutSlotInfo = GetFlyoutInfo, GetFlyoutSlotInfo
local GetTalentTierInfo, GetTalentInfo = GetTalentTierInfo, GetTalentInfo
local GetPvpTalentInfoByID = GetPvpTalentInfoByID

local addonName, addon = ...
ABP = _G.ABP or addon or ABP or {}

local C_Timer = C_Timer
local C_Spell = ABP.Compat.C_Spell
local C_SpellBook = ABP.Compat.C_SpellBook
local C_Item = ABP.Compat.C_Item
local C_Container = ABP.Compat.C_Container
local C_ClassTalents = C_ClassTalents
local C_Traits = C_Traits
local C_MountJournal = C_MountJournal
local C_ToyBox = C_ToyBox
local C_EquipmentSet = C_EquipmentSet
local C_PetJournal = C_PetJournal
local C_Garrison = C_Garrison
local C_SpecializationInfo = C_SpecializationInfo
local C_TransmogOutfitInfo = C_TransmogOutfitInfo
local C_AssistedCombat = C_AssistedCombat
local C_ActionBar = C_ActionBar
local Enum = Enum
local MAX_ACCOUNT_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_ACCOUNT_MACROS) or _G.MAX_ACCOUNT_MACROS or ABP_MAX_ACCOUNT_MACROS or 120
local MAX_CHARACTER_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS) or _G.MAX_CHARACTER_MACROS or ABP_MAX_CHARACTER_MACROS or 30

_G.ActionBarProfilesDBv3 = _G.ActionBarProfilesDBv3 or {}

-- Function to retrieve and optionally filter a list of profiles
function addon:GetProfiles(filter, case)
    -- Retrieve the list of profiles from the database
    local list = self.db and self.db.profile and self.db.profile.list
    if not list then return end
    -- Create a new table to store sorted profiles
    local sorted = {}

    -- Iterate through each profile in the list
    local name, profile
    for name, profile in pairs(list) do
        -- If no filter is provided or the profile name matches the filter (considering case sensitivity if 'case' is true)
        if not filter or name == filter or (case and name:lower() == filter:lower()) then
            -- Assign the profile name to the 'name' field of the profile
            profile.name = name
            -- Insert the profile into the sorted table
            table.insert(sorted, profile)
        end
    end

    -- If more than one profile is found, sort them
    if #sorted > 1 then
        -- Get the player's class (e.g., "MAGE", "WARRIOR")
        local class = select(2, UnitClass("player"))

        -- Sort the profiles: profiles of the player's class come first, then alphabetically by name
        table.sort(sorted, function(a, b)
            if a.class == b.class then
                -- If the classes are the same, sort by name
                return a.name < b.name
            else
                -- Otherwise, prioritize profiles that match the player's class
                return a.class == class
            end
        end)
    end

    -- Return the sorted profiles, unpacked to separate variables
    return unpack(sorted)
end


local ABP_TempTalentString = ""

StaticPopupDialogs["ABP_TALENT_IMPORT"] = {
    text = "Talent string mismatch detected!\nPlease copy the string below (Ctrl+C), import it in WoW, apply it, and restore again.\n\nAlternatively, if you are leveling and cannot distribute all points yet, click 'Skip Talents' to force Action Bars to restore anyway.",
    button1 = "Skip Talents (Force Restore)",
    button2 = "Close",
    hasEditBox = 1,
    editBoxWidth = 260,
    OnShow = function(self)
        local editBox = _G[self:GetName().."EditBox"]
        if editBox then
            editBox:SetText(ABP_TempTalentString or "")
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        if data and type(data.continueRestore) == "function" then
            data.continueRestore()
        end
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Function to use a given profile, restoring various game elements based on the profile's settings.
-- This is now sequential: Talents (via Import String) -> Macros -> Actions -> Pet Actions.
function addon:UseProfile(profile, check, cache)
    if InCombatLockdown() then
        if not check then
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
            end
            self:Printf(ERR_CLIENT_LOCKED_OUT)
        end
        return 0, 0
    end

    -- If the profile parameter is not a table, assume it's a profile name and retrieve the corresponding profile from the database
    if type(profile) ~= "table" then
        local list = self.db.profile.list
        profile = list[profile]
        if not profile then return 0, 0 end
    end

    cache = cache or self:MakeCache()
    local res = { fail = 0, total = 0 }

    -- Define the final steps of restoration
    local function FinishRestoration()
        if not profile.skipActions then
            self:RestoreActions(profile, check, cache, res)
        end
        if not profile.skipPetActions then
            self:RestorePetActions(profile, check, cache, res)
        end
        if not profile.skipBindings and profile.bindings then
            self:RestoreBindings(profile, check, cache, res)
        end
        if not check then
            self:UpdateGUI()
        end
    end

    -- If in check mode and talents need to change, bypass missing spell check
    -- because new spells from the restored talents aren't in the spellbook yet!
    if check and not profile.skipTalents and not self:AreTalentsMatching(profile) then
        return 0, 0
    end

    local function ProceedWithRestoration()
        if not profile.skipMacros then
            self:RestoreMacros(profile, check, cache, res)
        end

        if not check then
            C_Timer.After(0.2, FinishRestoration)
        else
            FinishRestoration()
        end
    end

    -- If talents are enabled and not already matching, restore talents first
    if not check and not profile.skipTalents and not self:AreTalentsMatching(profile) then
        self:RestoreTalents(profile, function()
            ProceedWithRestoration()
        end)
    else
        ProceedWithRestoration()
    end

    return res.fail, res.total
end


-- Function to restore macros based on a given profile, with an option to check without actually applying the changes
function addon:RestoreMacros(profile, check, cache, res)
    if InCombatLockdown() and not check then
        return 0, 0
    end
    local fail, total = 0, 0  -- Initialize failure and total counters

    -- Get the number of macros available to the player
    local all, char = GetNumMacros()
    local macros

    -- If the profile is set to replace macros, clear the current macros
    if self.db.profile.replace_macros then
        macros = { id = {}, name = {} }  -- Initialize a new macros table

        -- If not in check mode, delete all existing macros
        if not check then
            local index
            for index = 1, all do
                DeleteMacro(1)  -- Delete each global macro
            end

            for index = 1, char do
                DeleteMacro(MAX_ACCOUNT_MACROS + 1)  -- Delete each character-specific macro
            end
        end

        -- Reset macro counters
        all, char = 0, 0
    else
        -- If not replacing macros, copy the current macros from the cache
        macros = table.s2k_copy(cache.macros)
    end

    -- Iterate through each action slot to restore macros
    local slot
    for slot = 1, ABP_MAX_ACTION_BUTTONS do
        local link = profile.actions[slot]
        if link then
            -- If an action is assigned to the slot, process it
            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            link = link:gsub("|Habp:.+|h(%[.+%])|h", "%1")

            if data then
                -- Parse the macro data from the link
                local type, sub, icon, body, global = strsplit(":", data)

                if type == "abp" and sub == "macro" then
                    local ok
                    total = total + 1  -- Increment total actions processed

                    body = self:DecodeLink(body)  -- Decode the macro body

                    -- Check if the macro already exists in the cache
                    if self:GetFromCache(macros, self:PackMacro(body)) then
                        ok = true
                    -- If the macro doesn't exist, create it if possible
                    elseif (global and all < MAX_ACCOUNT_MACROS) or (not global and char < MAX_CHARACTER_MACROS) then
                        if check or CreateMacro(name, icon, body, not global) then
                            ok = true
                            self:UpdateCache(macros, -1, self:PackMacro(body), name)  -- Add the macro to the cache
                        end

                        -- Update macro counters based on whether it's global or character-specific
                        if ok then
                            all = all + ((global and 1) or 0)
                            char = char + ((global and 0) or 1)
                        end
                    end

                    -- Handle the case where the macro couldn't be created
                    if not ok then
                        fail = fail + 1  -- Increment failure count
                        self:cPrintf(not check, L.msg_cant_create_macro, link)  -- Print a failure message if not in check mode
                    end
                end
            else
                -- Print a bad link message if the link is invalid and actions are not skipped
                self:cPrintf(profile.skipActions and not check, L.msg_bad_link, link)
            end
        end
    end

    -- If replacing macros, process additional macros from the profile
    if self.db.profile.replace_macros and profile.macros then
        for slot = 1, #profile.macros do
            local link = profile.macros[slot]

            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            link = link:gsub("|Habp:.+|h(%[.+%])|h", "%1")

            if data then
                -- Parse and process the macro data similarly to the above loop
                local type, sub, icon, body, global = strsplit(":", data)

                if type == "abp" and sub == "macro" then
                    local ok
                    total = total + 1

                    body = self:DecodeLink(body)

                    if self:GetFromCache(macros, self:PackMacro(body)) then
                        ok = true
                    elseif (global and all < MAX_ACCOUNT_MACROS) or (not global and char < MAX_CHARACTER_MACROS) then
                        if check or CreateMacro(name, icon, body, not global) then
                            ok = true
                            self:UpdateCache(macros, -1, self:PackMacro(body), name)
                        end

                        if ok then
                            all = all + ((global and 1) or 0)
                            char = char + ((global and 0) or 1)
                        end
                    end

                    if not ok then
                        fail = fail + 1
                        self:cPrintf(not check, L.msg_cant_create_macro, link)
                    end
                else
                    self:cPrintf(not check, L.msg_bad_link, link)
                end
            else
                self:cPrintf(not check, L.msg_bad_link, link)
            end
        end
    end

    if not check then
        -- Correct macro IDs if not in check mode by preloading macros
        self:PreloadMacros(macros)
    end

    -- Update the cache with the modified macros
    cache.macros = macros

    -- Update the result table with the number of failures and total attempts
    if res then
        res.fail = res.fail + fail
        res.total = res.total + total
    end

    -- Return the number of failed and total attempts
    return fail, total
end


-- Function to debug and print talents from a specified class and list profile
function ABP:DebugPrintTalents(classProfile, listProfile)
    -- Retrieve the class profiles from the database
    local classProfiles = self.db and self.db.profiles[classProfile]
    if not classProfiles then
        -- If the class profile is not found, print an error message and exit
        if ABP_DEBUG then print("Class profile not found: " .. tostring(classProfile)) end
        return
    end

    -- Retrieve the list profile within the specified class profile
    local profile = classProfiles.list and classProfiles.list[listProfile]
    if not profile or not profile.talents then
        -- If the list profile or its talents are not found, print an error message and exit
        if ABP_DEBUG then print("List profile not found in class profile: " .. tostring(listProfile)) end
        return
    end

    -- Print the header message indicating the start of talent listing
    if ABP_DEBUG then print("Talents in profile: " .. listProfile) end

    -- Iterate through each talent in the profile's talents list and print its details
    for i, talentInfo in ipairs(profile.talents) do
        if ABP_DEBUG then print("Talent " .. i .. ": " .. talentInfo.spellName .. " (ID: " .. talentInfo.spellID .. ")") end
    end
end


-- Define a function to get the player's specialization and configuration
function addon:GetMySpecAndConfig()
    -- Get the player's current specialization index (e.g., 1 for the first spec)
    local specIndex = type(GetSpecialization) == "function" and GetSpecialization() or nil
    ABP.specIndex = specIndex  -- Store the specialization index in the global ABP table

    -- Map specialization IDs to class names
    local specToClassMap = {
        [250] = "Death Knight", [251] = "Death Knight", [252] = "Death Knight", [1455] = "Death Knight",
        [577] = "Demon Hunter", [581] = "Demon Hunter", [1456] = "Demon Hunter",
        [102] = "Druid", [103] = "Druid", [104] = "Druid", [105] = "Druid", [1447] = "Druid",
        [1467] = "Evoker", [1468] = "Evoker", [1473] = "Evoker", [1465] = "Evoker",
        [253] = "Hunter", [254] = "Hunter", [255] = "Hunter", [1448] = "Hunter",
        [62] = "Mage", [63] = "Mage", [64] = "Mage", [1449] = "Mage",
        [268] = "Monk", [270] = "Monk", [269] = "Monk", [1450] = "Monk",
        [65] = "Paladin", [66] = "Paladin", [70] = "Paladin", [1451] = "Paladin",
        [256] = "Priest", [257] = "Priest", [258] = "Priest", [1452] = "Priest",
        [259] = "Rogue", [260] = "Rogue", [261] = "Rogue", [1453] = "Rogue",
        [262] = "Shaman", [263] = "Shaman", [264] = "Shaman", [1444] = "Shaman",
        [265] = "Warlock", [266] = "Warlock", [267] = "Warlock", [1454] = "Warlock",
        [71] = "Warrior", [72] = "Warrior", [73] = "Warrior", [1446] = "Warrior"
    }

    -- If a specialization is selected
    if specIndex then
        -- Get the specialization ID, trait tree ID, and active config ID
        local specID = (type(GetSpecializationInfo) == "function" and type(GetSpecialization) == "function" and GetSpecialization() and GetSpecializationInfo(GetSpecialization())) or 0 --select(1, GetSpecializationInfo(specIndex))
        local treeID = C_ClassTalents.GetTraitTreeForSpec(specID)
        local configID = C_ClassTalents.GetActiveConfigID()
        local currentClassProfile = specToClassMap[specID] or "Unknown Class"

        -- Store the gathered information in the global ABP table
        ABP.specID = specID
        ABP.treeID = treeID
        ABP.configID = configID
        ABP.currentClassProfile = currentClassProfile

        if ABP_DEBUG then
            print("Your current specialization index is: " .. ABP.specIndex)
            print("Your current specialization ID is: " .. ABP.specID)
            print("Your current trait tree ID is: " .. (ABP.treeID or "nil"))
            print("Your active configuration ID is: " .. (ABP.configID or "nil"))
            print("Current class profile in use: " .. ABP.currentClassProfile)
        end
    else
        if ABP_DEBUG then
            print("You have no specialization selected.")
        end
    end
end


-- Function to compare the current talent configuration with the saved profile
function addon:AreTalentsMatching(profile)
    if not (C_ClassTalents and C_Traits and C_ClassTalents.GetActiveConfigID) then
        return true
    end

    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    if not activeConfigID then
        return true
    end

    -- If talentString is saved and available, check if import string matches
    if profile.talentString and profile.talentString ~= "" and C_Traits.GenerateImportString then
        local currentString = C_Traits.GenerateImportString(activeConfigID)
        if currentString and currentString ~= "" then
            return (currentString == profile.talentString)
        end
    end

    -- If talentLoadoutID or talentLoadoutName is saved, check if active loadout matches
    if profile.talentLoadoutID and profile.talentLoadoutID == activeConfigID then
        return true
    end

    if profile.talentLoadoutName and profile.talentLoadoutName ~= "" then
        local configInfo = C_Traits.GetConfigInfo(activeConfigID)
        if configInfo and configInfo.name == profile.talentLoadoutName then
            return true
        end
    end

    return false
end


-- Function to restore talents based on a saved profile
-- 1. Checks if current talent build already matches
-- 2. Tries native Blizzard Loadout switch (Instant, server-authoritative, zero errors)
-- 3. Falls back to iterative multi-pass staging if no native loadout matches
function addon:RestoreTalents(profile, onComplete)
    local function Done()
        if onComplete then onComplete() end
    end

    if profile.skipTalents then
        Done()
        return
    end

    local activeSpecID = (type(GetSpecialization) == "function" and GetSpecialization() and type(GetSpecializationInfo) == "function" and GetSpecializationInfo(GetSpecialization())) or 0
    if profile.specID and profile.specID > 0 and activeSpecID and activeSpecID ~= profile.specID then
        if ABP_DEBUG then print("Spec mismatch: expected " .. tostring(profile.specID) .. ", current " .. tostring(activeSpecID)) end
        Done()
        return
    end

    if not (C_ClassTalents and C_Traits and C_ClassTalents.GetActiveConfigID) then
        Done()
        return
    end

    local activeConfigID = C_ClassTalents.GetActiveConfigID()

    -- 1. Check if talents already match current active build
    if self:AreTalentsMatching(profile) then
        if ABP_DEBUG then print("Talents already match current configuration.") end
        Done()
        return
    end

    -- 2. Try native Blizzard Loadout switch (Instant, server-authoritative, zero prerequisite errors)
    local targetConfigID = nil
    local configIDs = (activeSpecID and C_ClassTalents.GetConfigIDsBySpecID(activeSpecID)) or {}

    -- Prioritize matching by loadout name
    if profile.talentLoadoutName and profile.talentLoadoutName ~= "" then
        for _, cfgID in ipairs(configIDs) do
            local info = C_Traits.GetConfigInfo(cfgID)
            if info and info.name == profile.talentLoadoutName then
                targetConfigID = cfgID
                break
            end
        end
    end

    -- If not found by name, check by exact configID if present in this spec's list
    if not targetConfigID and profile.talentLoadoutID then
        for _, cfgID in ipairs(configIDs) do
            if cfgID == profile.talentLoadoutID then
                targetConfigID = cfgID
                break
            end
        end
    end

    if targetConfigID then
        if targetConfigID == activeConfigID then
            Done()
            return
        end

        local loadSuccess = C_ClassTalents.LoadConfig(targetConfigID, true)
        if ABP_DEBUG then print("Loading native loadout ID " .. tostring(targetConfigID) .. " Success: " .. tostring(loadSuccess)) end

        -- Give the game engine a brief moment to update active spells in the spellbook
        C_Timer.After(0.4, Done)
        return
    end

    -- 3. Fallback: Iterative multi-pass restoration for custom/cross-character profiles
    if profile.talents and #profile.talents > 0 then
        self:ApplyTalentsIterative(profile, Done)
    else
        -- No loadout match and no saved node list; if talentString is present, show dialog as last resort
        if profile.talentString and profile.talentString ~= "" then
            ABP_TempTalentString = profile.talentString
            local popupData = {
                continueRestore = Done
            }
            StaticPopup_Show("ABP_TALENT_IMPORT", nil, nil, popupData)
        else
            Done()
        end
    end
end


-- Function to restore talents using an iterative dependency queue (avoids posY prerequisite and gate errors)
function addon:ApplyTalentsIterative(profile, onComplete)
    local function Done()
        if onComplete then onComplete() end
    end

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID or not profile.talents or #profile.talents == 0 then
        Done()
        return
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    if not configInfo or not configInfo.treeIDs then
        Done()
        return
    end

    -- Reset trees for this config
    for _, treeID in ipairs(configInfo.treeIDs) do
        C_Traits.ResetTree(configID, treeID)
    end

    -- Build queue of nodes to learn
    local queue = {}
    for _, t in ipairs(profile.talents) do
        if not t.isFreeTalent and (t.ranksPurchased or 0) > 0 then
            table.insert(queue, {
                nodeID = t.nodeID,
                entryID = t.entryID,
                targetRank = t.ranksPurchased,
                isSelectionNode = t.isSelectionNode,
            })
        end
    end

    -- Iteratively stage available nodes in dependency passes
    local maxPasses = 50
    local changed = true

    while changed and #queue > 0 and maxPasses > 0 do
        changed = false
        maxPasses = maxPasses - 1

        for i = #queue, 1, -1 do
            local item = queue[i]
            local nodeInfo = C_Traits.GetNodeInfo(configID, item.nodeID)

            if nodeInfo and nodeInfo.isVisible and nodeInfo.meetsEdgeRequirements then
                if item.isSelectionNode then
                    if item.entryID then
                        if C_Traits.SetSelection(configID, item.nodeID, item.entryID) then
                            table.remove(queue, i)
                            changed = true
                        end
                    else
                        table.remove(queue, i)
                    end
                elseif nodeInfo.canPurchaseRank then
                    if C_Traits.PurchaseRank(configID, item.nodeID) then
                        item.targetRank = item.targetRank - 1
                        changed = true
                        if item.targetRank <= 0 then
                            table.remove(queue, i)
                        end
                    end
                end
            end
        end
    end

    -- Commit all staged talent changes atomically
    local commitSuccess = C_ClassTalents.CommitConfig(configID)
    if ABP_DEBUG then
        print("Iterative talent commit result:", tostring(commitSuccess), "Remaining queue:", #queue)
    end

    if PlayerSpellsFrame and PlayerSpellsFrame:IsShown() then
        HideUIPanel(PlayerSpellsFrame)
        ShowUIPanel(PlayerSpellsFrame)
    end

    C_Timer.After(0.4, Done)
end


-- Function to restore PvP talents from a profile
function addon:RestorePvpTalents(profile, check, cache, res)
    -- If the profile does not contain PvP talents, exit the function
    if not profile.pvpTalents then
        return 0, 0
    end

    -- Initialize counters for failed and total attempts
    local fail, total = 0, 0

    -- Initialize a table to keep track of PvP talents by ID and name
    local pvpTalents = { id = {}, name = {} }

    -- Determine if the player is in a resting state or has a specific aura
    local rest = self.auraState or IsResting()

    -- Loop through the 3 PvP talent tiers
    for tier = 1, 3 do
        local link = profile.pvpTalents[tier]
        if link then
            -- Increment the total counter for each PvP talent
            local ok
            total = total + 1

            -- Extract data and name from the PvP talent link
            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            link = link:gsub("|Habp:.+|h(%[.+%])|h", "%1")

            if data then
                -- Split the data to determine the type and ID of the PvP talent
                local type, sub = strsplit(":", data)
                local id = tonumber(sub)

                -- Correctly unpacking the values from GetPvpTalentInfoByID
                if id then
                    local talentID, name, icon, selected, available, spellID, unlocked, row, column, known, grantedByAura = GetPvpTalentInfoByID(id, 1)

                    -- Proceed with your logic using these variables
                    if type == "pvptal" then
                        local found = self:GetFromCache(cache.allPvpTalents[tier], id, name, not check and link)
                        if found then
                            if self:GetFromCache(cache.pvpTalents, id) or rest or available then
                                ok = true
                                self:UpdateCache(pvpTalents, found, id, available)
                                if not check then
                                    -- Learn the PvP talent if it meets the criteria
                                    ---@diagnostic disable-next-line
                                    LearnPvpTalent(found, tier)
                                end
                            else
                                -- If the PvP talent can't be learned, print an error message
                                self:cPrintf(not check, L.msg_cant_learn_talent, link)
                            end
                        else
                            -- If the PvP talent doesn't exist in the cache, print an error message
                            self:cPrintf(not check, L.msg_talent_not_exists, link)
                        end
                    else
                        -- If the link type is incorrect, print a bad link message
                        self:cPrintf(not check, L.msg_bad_link, link)
                    end
                else
                    -- If the link data is missing, print a bad link message
                    self:cPrintf(not check, L.msg_bad_link, link)
                end

                -- If the PvP talent wasn't learned successfully, increment the fail counter
                if not ok then
                    fail = fail + 1
                end
            end
        end
    end

    -- Update the cache with the newly restored PvP talents
    cache.pvpTalents = pvpTalents

    -- Update the result table with the fail and total counters
    if res then
        res.fail = res.fail + fail
        res.total = res.total + total
    end

    -- Return the number of failed and total restoration attempts
    return fail, total
end


-- Restores action bar slots from the provided profile, performing checks and cache operations as necessary.
function addon:RestoreActions(profile, check, cache, res)
    if InCombatLockdown() and not check then
        return 0, 0
    end
    local fail, total = 0, 0  -- Initialize counters for failures and total actions.

    -- Iterate through all action bar slots.
    for slot = 1, ABP_MAX_ACTION_BUTTONS do
        local link = profile.actions[slot]

        -- If the slot is in the range 145-156, try to map it from slot 13-24 if not found.
        if (slot >= 145 and slot <= 156) then
            if not link then
                link = profile.actions[slot - 132]
            end
        end

        if link then
            local ok  -- Flag to indicate if the action was successfully restored.
            total = total + 1  -- Increment the total actions counter.

            -- Extract data and name from the link format.
            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            link = link:gsub("|Habp:.+|h(%[.+%])|h", "%1")

            if data then
                local type, sub, p1, p2, _, _, _, p6 = strsplit(":", data)
                local id = tonumber(sub)

                if type == "spell" or type == "talent" then
                    local isKnown = id and (IsPlayerSpell(id) or IsSpellKnown(id) or ABP_SPECIAL_SPELLS[id])
                    if not isKnown and id then
                        if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(id, Enum.SpellBookSpellBank.Pet) then
                            isKnown = true
                        elseif IsSpellKnown(id, true) then
                            isKnown = true
                        elseif cache.petSpells and (cache.petSpells.id[id] or (name and cache.petSpells.name and cache.petSpells.name[name])) then
                            isKnown = true
                        elseif cache.spells and (cache.spells.id[id] or (name and cache.spells.name and cache.spells.name[name])) then
                            isKnown = true
                        end
                    end

                    if not isKnown then
                        fail = fail + 1
                        ok = false
                    else
                        -- Restore known spells or talents
                        if id == ABP_RANDOM_MOUNT_SPELL_ID then
                            ok = true
                            if not check then
                                self:PlaceMount(slot, 0, link)  -- Place a random mount in the slot.
                            end
                        else
                            local found = self:FindSpellInCache(cache.spells, id, name, not check and link)
                            if found then
                                ok = true
                                if not check then
                                    self:PlaceSpell(slot, found, link)  -- Place the spell in the slot.
                                end
                            else
                                -- Check if it is a pet spell placed on the player's action bar
                                local petSlot = cache.petSpells and self:GetFromCache(cache.petSpells, id, name, not check and link)
                                if petSlot and petSlot > 0 then
                                    ok = true
                                    if not check then
                                        self:PlacePetSpellOnActionBar(slot, petSlot, id, link)
                                    end
                                else
                                    found = self:GetFromCache(cache.talents, id, name, not check and link)
                                    if found then
                                        ok = true
                                        if not check then
                                            self:PlaceTalent(slot, found, link)  -- Place the talent in the slot.
                                        end
                                    end
                                end
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)
                    end

                elseif type == "pvptal" then
                    local found = self:GetFromCache(cache.pvpTalents, id, name, not check and link)
                    if found then
                        ok = true
                        if not check then
                            self:PlacePvpTalent(slot, found, link)  -- Place the PvP talent in the slot.
                        end
                    end
                    self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)

                elseif type == "item" then
                    if id and PlayerHasToy(id) then
                        ok = true
                        if not check then
                            self:PlaceToy(slot, id, link)  -- Place the toy in the slot using ToyBox API.
                        end
                    else
                        local found = self:FindItemInCache(cache.equip, id, name, not check and link)
                        if found then
                            ok = true
                            if not check then
                                self:PlaceInventoryItem(slot, found, link)  -- Place the inventory item in the slot.
                            end
                        else
                            found = self:FindItemInCache(cache.bags, id, name, not check and link)
                            if found then
                                ok = true
                                if not check then
                                    self:PlaceContainerItem(slot, found[1], found[2], link)  -- Place the container item in the slot.
                                end
                            end
                        end
                    end
                    if not ok and not check then
                        self:PlaceItem(slot, id, link)
                    end
                    ok = true

                elseif type == "battlepet" then
                    local found = self:GetFromCache(cache.pets, p6, id, not check and link)
                    if found then
                        ok = true
                        if not check then
                            self:PlacePet(slot, found, link)  -- Place the pet in the slot.
                        end
                    end
                    self:cPrintf(not ok and not check, L.msg_pet_not_exists, link)

                elseif type == "abp" then
                    id = tonumber(p1)
                    if sub == "flyout" then
                        local found = self:FindFlyoutInCache(cache.flyouts, id, name, not check and link)
                        if found then
                            ok = true
                            if not check then
                                self:PlaceFlyout(slot, found, Enum.SpellBookSpellBank.Player, link)  -- Place the flyout in the slot.
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)

                    elseif sub == "macro" then
                        local found = self:GetFromCache(cache.macros, self:PackMacro(self:DecodeLink(p2)), name, not check and link)
                        if found then
                            ok = true
                            if not check then
                                self:PlaceMacro(slot, found, link)  -- Place the macro in the slot.
                            end
                        end

                        if profile.skipMacros then
                            self:cPrintf(not ok and not check, L.msg_macro_not_exists, link)
                        else
                            total = total - 1
                            if not ok then
                                fail = fail - 1
                            end
                        end

                    elseif sub == "equip" then
                        local equipmentSetID
                        local equipmentSetIDs = C_EquipmentSet.GetEquipmentSetIDs()

                        for _, setID in ipairs(equipmentSetIDs) do
                            local setName = C_EquipmentSet.GetEquipmentSetInfo(setID)
                            if setName == name then
                                equipmentSetID = setID
                                break
                            end
                        end

                        if equipmentSetID then
                            ok = true

                            if not check then
                                self:PlaceEquipment(slot, equipmentSetID, link)  -- Place the equipment set in the slot by its numeric ID.
                            end
                        end

                        self:cPrintf(not ok and not check, L.msg_equip_not_exists, link)
                    elseif sub == "summonmount" then
                        -- For the abp:summonmount type, id is the mountID or random mount spellID
                        if id == ABP_RANDOM_MOUNT_SPELL_ID then
                            ok = true
                            if not check then
                                self:PlaceMount(slot, 0, link)
                            end
                        else
                            -- Find the mount in the journal by mountID (which was saved as id)
                            -- Actually, the abp:summonmount link was being saved with mountID in p1
                            local name, spellID = C_MountJournal.GetMountInfoByID(id)
                            if spellID then
                                local found = self:FindSpellInCache(cache.spells, spellID, name, not check and link)
                                if found then
                                    ok = true
                                    if not check then
                                        self:PlaceSpell(slot, found, link)
                                    end
                                end
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)
                    elseif sub == "companion" then
                        -- Handle generic companion types
                        if id and id > 0 then
                            local found = self:FindSpellInCache(cache.spells, id, name, not check and link)
                            if found then
                                ok = true
                                if not check then
                                    self:PlaceSpell(slot, found, link)
                                end
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)
                    elseif sub == "action" then
                        -- Handle generic Blizzard action types (Special UI buttons)
                        ok = true
                        if not check then
                            ClearCursor()
                            PickupAction(id)
                            self:PlaceToSlot(slot)
                        end
                    elseif sub == "outfit" then
                        -- Handle Transmog Outfit actions
                        local outfitID = id
                        if outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetOutfitInfo then
                            local info = C_TransmogOutfitInfo.GetOutfitInfo(outfitID)
                            if not info and C_TransmogOutfitInfo.GetOutfitsInfo then
                                -- If outfitID changed, try finding by name
                                local outfits = C_TransmogOutfitInfo.GetOutfitsInfo()
                                if outfits then
                                    for _, entry in ipairs(outfits) do
                                        if entry.name == name then
                                            outfitID = entry.outfitID
                                            info = entry
                                            break
                                        end
                                    end
                                end
                            end
                            if info then
                                ok = true
                                if not check then
                                    self:PlaceOutfit(slot, outfitID, link)
                                end
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_outfit_not_exists or "Transmog outfit not found: %s", link)
                    elseif sub == "assistedcombat" then
                        -- Handle Single-Button Assistant (Assisted Combat Rotation)
                        local assistantSpellID = (C_AssistedCombat and C_AssistedCombat.GetActionSpell and C_AssistedCombat.GetActionSpell())
                        if not assistantSpellID or assistantSpellID == 0 then
                            assistantSpellID = id
                        end

                        if assistantSpellID and assistantSpellID > 0 then
                            ok = true
                            if not check then
                                self:PlaceAssistedCombat(slot, assistantSpellID, link)
                            end
                        end
                        self:cPrintf(not ok and not check, L.msg_spell_not_exists, link)
                    else
                        self:cPrintf(not check, L.msg_bad_link, link)
                    end
                else
                    self:Printf("Unrecognized action type: [%s]", type)
                    fail = fail + 1
                end
            else
                self:Printf("Bad link format: [%s]", link)
                fail = fail + 1
            end

            if not ok and not check then
                self:ClearSlot(slot)
            end
        else
            if not profile.skipEmptySlots and not check then
                self:ClearSlot(slot)
            end
        end
    end

    if res then
        res.fail = res.fail + fail
        res.total = res.total + total
    end

    -- Extract the profileKey and profileName from the passed profile
    local profileKey = profile.class or "Unknown" -- Assuming class is used as the key
    local profileName = profile.name

    -- Call ActionButtonOverride ONLY when NOT in check mode and NOT in combat
    if not check and not InCombatLockdown() then
        ABP:ActionButtonOverride(profileKey, profileName)
    end

    return fail, total  -- Return the number of failures and total actions.
end



-- This function iterates through each action bar slot, checks if the slot is empty, and places the correct macro or spell based on the profile's actions.
function ABP:ActionButtonOverride(profileKey, profileName)
    if InCombatLockdown() then return end

    -- Retrieve the profile from database using active profile list or profileKey
    local profile = (self.db and self.db.profile and self.db.profile.list and self.db.profile.list[profileName])
        or (self.db and self.db.profiles and self.db.profiles[profileKey] and self.db.profiles[profileKey].list and self.db.profiles[profileKey].list[profileName])
    if not profile then
        if ABP_DEBUG then print("Profile not found:", profileName) end
        return
    end

    -- Iterate over all potential action bar slots
    for slot = 1, ABP_MAX_ACTION_BUTTONS do
        -- Retrieve the action from the profile
        local link = profile.actions[slot]

        -- If the slot is within the range 145-156, map it from slot 13-24 if not found.
        if (slot >= 145 and slot <= 156) and not link then
            link = profile.actions[slot - 132]
        end

        -- Check if the slot is currently occupied but shouldn't be
        if not link and HasAction(slot) then
            -- If no action is found and empty slots should not be skipped, clear the slot
            addon:ClearSlot(slot)
        end

        -- Proceed only if there's an action associated with the current slot
        if link then
            -- Extract the type and name of the action
            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            local type, sub, p1 = strsplit(":", data)

            -- Check if the action is a macro
            if type == "abp" and sub == "macro" then
                -- Extract the macro name and place it in the current slot
                local macroName = name
                PickupMacro(macroName)
                PlaceAction(slot)
                ClearCursor()

            -- Check if the action is a spell
            elseif type == "spell" then
                -- Extract the spell ID and place it in the current slot
                local spellID = tonumber(sub)
                if spellID then
                    -- Place the spell in the current slot
                    C_Spell.PickupSpell(spellID)
                    PlaceAction(slot)
                    ClearCursor()
                else
                    -- Handle the case where the spellID is nil (optional)
                    --print(string.format("Invalid spell ID for slot %d: %s", slot, name))
                end
            else
                -- Skipping non-macro, non-spell actions
                --print(string.format("Skipping non-macro/non-spell action in slot %d: %s", slot, name))
            end
        end
    end
end


-- This function restores the player's pet action bar from the provided profile.
function addon:RestorePetActions(profile, check, cache, res)
    if InCombatLockdown() and not check then
        return 0, 0
    end
    -- Check if the player has pet spells and if the profile contains pet actions
    local numPetSpells, petToken = C_SpellBook.HasPetSpells()
    if not numPetSpells or not profile.petActions then
        return 0, 0
    end

    local fail, total = 0, 0

    -- Iterate through each pet action slot
    for slot = 1, NUM_PET_ACTION_SLOTS do
        local link = profile.petActions[slot]
        if link then
            -- Action exists in this slot
            local ok
            total = total + 1

            -- Extract the data and name from the link
            local data, name = link:match("^|c.-|H(.-)|h%[(.-)%]|h|r$")
            link = link:gsub("|Habp:.+|h(%[.+%])|h", "%1")

            if data then
                local type, sub, p1 = strsplit(":", data)
                local id = tonumber(sub)

                if type == "spell" or (type == "abp" and sub == "pet") then
                    if type == "spell" then
                        local spellInfo = id and C_Spell.GetSpellInfo(id)
                        if spellInfo then
                            name = spellInfo.name or name
                        else
                            -- Handle the case where spellInfo is nil (optional)
                            print(string.format("Invalid spell ID for slot %d: %s", slot, name))
                        end
                    else
                        id = -2
                        name = _G[name] or name
                    end

                    -- Check if the spell is in the cache
                    local found = self:GetFromCache(cache.petSpells, id, name, not check and type == "spell" and link)
                    if found then
                        ok = true

                        if not check then
                            self:PlacePetSpell(slot, found, link)
                        end
                    end
                else
                    -- Handle invalid links
                    self:cPrintf(not check, L.msg_bad_link, link)
                end
            else
                -- Handle invalid links
                self:cPrintf(not check, L.msg_bad_link, link)
            end

            if not ok then
                -- Failed to restore the action
                fail = fail + 1

                if not check then
                    self:ClearPetSlot(slot)
                end
            end
        else
            -- Empty slot
            if not check then
                self:ClearPetSlot(slot)
            end
        end
    end

    -- Update the result object with the number of failures and total actions
    if res then
        res.fail = res.fail + fail
        res.total = res.total + total
    end

    return fail, total
end


-- Function to restore key bindings from a profile
function addon:RestoreBindings(profile, check, cache, res)
    -- If 'check' is true, in combat, or no bindings saved in profile, exit early
    if check or InCombatLockdown() or not profile.bindings then
        return 0, 0
    end

    -- Clear existing bindings
    for index = 1, GetNumBindings() do
        local bind = { GetBinding(index) }
        if bind[3] then
            for i = 3, #bind do
                SetBinding(bind[i])
            end
        end
    end

    -- Restore bindings from the profile
    for cmd, keys in pairs(profile.bindings) do
        if type(keys) == "table" then
            for _, key in ipairs(keys) do
                SetBinding(key, cmd)
            end
        end
    end

    -- Additional support for Dominos addon bindings
    if LibStub("AceAddon-3.0"):GetAddon("Dominos", true) and profile.bindingsDominos then
        for index = 13, 60 do
            local key1, key2 = GetBindingKey(string.format("CLICK DominosActionButton%d:LeftButton", index))
            if key1 then SetBinding(key1) end
            if key2 then SetBinding(key2) end

            if profile.bindingsDominos[index] then
                for _, key in ipairs(profile.bindingsDominos[index]) do
                    SetBindingClick(key, string.format("DominosActionButton%d", index), "LeftButton")
                end
            end
        end
    end

    -- Save the bindings to the current binding set (character or account)
    SaveBindings(GetCurrentBindingSet())

    return 0, 0
end


-- Updates the cache with a value, associating it with an ID and optionally a name.
function addon:UpdateCache(cache, value, id, name)
    -- Store the value in the cache by its ID.
    cache.id[id] = value

    -- If the cache supports names and a name is provided, store the value by name as well.
    if cache.name and name then
        cache.name[name] = value
    end
end


-- Retrieves a value from the cache based on ID or name, and optionally prints debug information.
function addon:GetFromCache(cache, id, name, link)
    -- Check if the value is cached by ID.
    if cache.id[id] then
        return cache.id[id]
    end

    -- If the cache supports names and the name is provided, check by name.
    if cache.name and name and cache.name[name] then
        -- Print debug information if a link is provided.
        self:cPrintf(link, DEBUG .. L.msg_found_by_name, link)
        return cache.name[name]
    end
end


-- Attempts to find a spell in the cache using its ID, name, or similar spells.
function addon:FindSpellInCache(cache, id, name, link)
    --print("Looking for spell ID:", id, "Name:", name, "in cache")  -- Corrected variable name

    -- Retrieve the spell name using the new API.
    local spellInfo = C_Spell.GetSpellInfo(id)
    name = (spellInfo and spellInfo.name) or name

    -- First, try to get the spell from the cache.
    local found = self:GetFromCache(cache, id, name, link)
    if found then
        if ABP_DEBUG then print("Spell found in cache:", id) end
        return found
    end

    -- If not found, check for similar spells that might match.
    local similar = ABP_SIMILAR_SPELLS[id]
    if similar then
        for _, alt in ipairs(similar) do
            found = self:GetFromCache(cache, alt)
            if found then
                if ABP_DEBUG then print("Similar spell found in cache:", alt) end
                return found
            end
        end
    end

    --print("Spell not found in cache:", id)
    return nil
end


-- Attempts to find a flyout in the cache using its ID or name.
function addon:FindFlyoutInCache(cache, id, name, link)
    -- Safely attempt to retrieve the flyout name using the flyout ID.
    local ok, info_name = pcall(GetFlyoutInfo, id)
    if ok then
        name = info_name
    end

    -- Try to get the flyout from the cache by ID or name.
    local found = self:GetFromCache(cache, id, name, link)
    if found then
        return found
    end
end


-- Attempts to find an item in the cache using its ID, name, or similar items.
function addon:FindItemInCache(cache, id, name, link)
    -- First, try to get the item from the cache by ID or name.
    local found = self:GetFromCache(cache, id, name, link)
    if found then
        return found
    end

    -- If not found, check for alternative item IDs (converted item ID).
    local alt = nil -- S2KFI:GetConvertedItemId(id) removed
    if alt then
        found = self:GetFromCache(cache, alt)
        if found then
            return found
        end
    end

    -- If still not found, check for similar items that might match.
    local similar = ABP_SIMILAR_ITEMS[id]
    if similar then
        for alt in table.s2k_values(similar) do
            found = self:GetFromCache(cache, alt)
            if found then
                return found
            end
        end
    end
end


-- Creates a cache table to store various game data like talents, spells, items, etc., and preloads it with relevant data.
function addon:MakeCache()
    -- Initialize the cache table with sub-tables for different categories of data.
    local cache = {
        talents = { id = {}, name = {} },  -- Caches talent information by ID and name.
        allTalents = {},  -- Stores all talent data.

        pvpTalents = { id = {}, name = {} },  -- Caches PvP talent information by ID and name.
        allPvpTalents = {},  -- Stores all PvP talent data.

        spells = { id = {}, name = {} },  -- Caches spell information by ID and name.
        flyouts = { id = {}, name = {} },  -- Caches flyout information by ID and name.

        equip = { id = {}, name = {} },  -- Caches equipped item information by ID and name.
        bags = { id = {}, name = {} },  -- Caches bag item information by ID and name.

        pets = { id = {}, name = {} },  -- Caches pet information by ID and name.

        macros = { id = {}, name = {} },  -- Caches macro information by ID and name.

        petSpells = { id = {}, name = {} },  -- Caches pet spell information by ID and name.
    }

    -- Preload talents and PvP talents into the cache.
    self:PreloadTalents(cache.talents, cache.allTalents, cache.spells)
    self:PreloadPvpTalents(cache.pvpTalents, cache.allPvpTalents, cache.spells)
    --self:PreloadPvpTalentSpells(cache.spells)  -- This line is commented out, but could be used to preload PvP talent spells.

    -- Preload various types of spells into the cache.
    self:PreloadSpecialSpells(cache.spells)
    self:PreloadSpellbook(cache.spells, cache.flyouts)
    self:PreloadMountjournal(cache.spells)
    self:PreloadCombatAllySpells(cache.spells)

    -- Preload equipment and bag items into the cache.
    self:PreloadEquip(cache.equip)
    self:PreloadBags(cache.bags)

    -- Preload pet data and pet spells into the cache.
    self:PreloadPetJournal(cache.pets)
    self:PreloadMacros(cache.macros)
    self:PreloadPetSpells(cache.petSpells)

    -- Return the fully populated cache.
    return cache
end


-- Preloads special spells into the cache based on certain conditions such as player level, class, faction, and specialization.
function addon:PreloadSpecialSpells(spells)
    -- Get player details: level, class, faction, and specialization.
    local level = UnitLevel("player")
    local class = select(2, UnitClass("player"))
    local faction = UnitFactionGroup("player")
    local spec = (type(GetSpecializationInfo) == "function" and type(GetSpecialization) == "function" and GetSpecialization() and GetSpecializationInfo(GetSpecialization())) or 0

    -- Iterate through the special spells defined in ABP_SPECIAL_SPELLS.
    for id, info in pairs(ABP_SPECIAL_SPELLS) do
        -- Check if the spell meets the criteria based on level, class, faction, and specialization.
        if (not info.level or level >= info.level) and
            (not info.class or class == info.class) and
            (not info.faction or faction == info.faction) and
            (not info.spec or spec == info.spec)
        then
            -- If the spell meets the criteria, update the cache with the spell ID.
            self:UpdateCache(spells, id, id)

            -- If the spell has alternative spell IDs, cache those as well.
            if info.altSpellIds then
                for _, alt in ipairs(info.altSpellIds) do
                    self:UpdateCache(spells, id, alt)
                end
            end
        end
    end
end


-- Preloads the player's spellbook and profession spells into the cache.
function addon:PreloadSpellbook(spells, flyouts)
    local tabs = {}

    -- Retrieve the number of skill lines in the player's spellbook using the new API.
    for skillLineIndex = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        -- Get detailed information about each spellbook skill line.
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
        local offset = skillLineInfo.itemIndexOffset
        local count = skillLineInfo.numSpellBookItems
        local spec = skillLineInfo.specID or 0 -- specID is nil if the skill line isn't tied to a specific spec.

        -- Scan all spellbook skill lines to ensure spec-specific spells are captured.
        table.insert(tabs, { type = Enum.SpellBookSpellBank.Player, offset = offset, count = count })
    end

    -- Add profession spells to the tabs list by iterating through all known professions.
    for _, prof in ipairs({ GetProfessions() }) do
        if prof then
            local count, offset = select(5, GetProfessionInfo(prof))
            table.insert(tabs, { type = Enum.SpellBookSpellBank.Player, offset = offset, count = count })
        end
    end

    -- Iterate through all tabs to cache the spells and flyouts.
    for _, tab in ipairs(tabs) do
        for index = tab.offset + 1, tab.offset + tab.count do
            -- Retrieve the type and ID of the spellbook item.
            local type, id = C_SpellBook.GetSpellBookItemType(index, tab.type)
            local name = C_SpellBook.GetSpellBookItemName(index, tab.type)

            if type == Enum.SpellBookItemType.Flyout or type == "FLYOUT" then
                -- Cache the flyout information.
                self:UpdateCache(flyouts, index, id, name)

                -- Cache the spells contained within the flyout.
                local flyoutName, description, numSlots = GetFlyoutInfo(id)
                if numSlots then
                    for idx = 1, numSlots do
                        local flyoutid, _, isKnown, spellName = GetFlyoutSlotInfo(id, idx)
                        if flyoutid then
                            self:UpdateCache(spells, flyoutid, flyoutid, spellName)
                        end
                    end
                end

            elseif type == Enum.SpellBookItemType.Spell or type == "SPELL" then
                -- Cache the spell information.
                self:UpdateCache(spells, id, id, name)
            end
        end
    end
end


-- Preloads the player's collected mounts into the cache, filtering by faction if necessary.
-- Highly optimized: 0 table allocations per mount check (down from 3,000+ tables).
function addon:PreloadMountjournal(mounts)
    local all = C_MountJournal.GetMountIDs()
    if not all then return end

    local faction = (UnitFactionGroup("player") == "Alliance" and 1) or 0

    for _, mount in ipairs(all) do
        local name, id, _, _, _, _, _, _, required, _, collected = C_MountJournal.GetMountInfoByID(mount)
        if collected and (not required or required == faction) then
            self:UpdateCache(mounts, id, id, name)
        end
    end
end


-- Preloads the player's combat ally spells into the cache.
function addon:PreloadCombatAllySpells(spells)
    if not (C_Garrison and C_Garrison.GetFollowers) then return end
    local followers = C_Garrison.GetFollowers()
    if not followers then return end

    for _, follower in ipairs(followers) do
        if follower.garrFollowerID and C_Garrison.GetFollowerZoneSupportAbilities then
            local abilities = C_Garrison.GetFollowerZoneSupportAbilities(follower.garrFollowerID)
            if type(abilities) == "table" then
                for _, id in ipairs(abilities) do
                    local spellInfo = C_Spell.GetSpellInfo(id)
                    local name = (spellInfo and spellInfo.name) or "Unknown Spell"
                    self:UpdateCache(spells, 211390, id, name)
                end
            end
        end
    end
end


-- Preloads the player's selected talents and all available talents into the cache.
function addon:PreloadTalents(talents, all, spells)
    -- Modern Talent System (Retail 10.0+)
    if C_Traits and C_ClassTalents then
        local configID = C_ClassTalents.GetActiveConfigID()
        if configID then
            local configInfo = C_Traits.GetConfigInfo(configID)
            if configInfo then
                for _, treeID in ipairs(configInfo.treeIDs) do
                    local nodes = C_Traits.GetTreeNodes(treeID)
                    for _, nodeID in ipairs(nodes) do
                        local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                        if nodeInfo and nodeInfo.ranksPurchased > 0 then
                            local entryID = nodeInfo.activeEntry and nodeInfo.activeEntry.entryID
                            if entryID then
                                local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                                if entryInfo and entryInfo.definitionID then
                                    local definitionInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                    if definitionInfo and definitionInfo.spellID then
                                        local spellID = definitionInfo.spellID
                                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                                        local name = spellInfo and spellInfo.name or "Unknown Talent"
                                        
                                        -- Update both talents and spells cache for modern lookups
                                        self:UpdateCache(talents, spellID, spellID, name)
                                        if spells then
                                            self:UpdateCache(spells, spellID, spellID, name)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Legacy Talent System Fallback (Classic/Cata)
    if _G.MAX_TALENT_TIERS and _G.GetTalentTierInfo then
        local MAX_TALENT_TIERS = _G.MAX_TALENT_TIERS
        local NUM_TALENT_COLUMNS = _G.NUM_TALENT_COLUMNS or 3
        
        -- Iterate through all talent tiers (rows).
        for tier = 1, MAX_TALENT_TIERS do
            -- Initialize the cache for each tier if it doesn't already exist.
            all[tier] = all[tier] or { id = {}, name = {} }
    
            -- Check if there are talents available in this tier.
            if GetTalentTierInfo(tier, 1) then
                -- Iterate through all talent columns (choices in each tier).
                for column = 1, NUM_TALENT_COLUMNS do
                    -- Retrieve information about the talent in this tier and column.
                    local id, name, _, selected = GetTalentInfo(tier, column, 1)
    
                    -- If the talent is selected, update the cache for selected talents.
                    if selected then
                        self:UpdateCache(talents, id, id, name)
                    end
    
                    -- Update the cache for all talents in this tier.
                    self:UpdateCache(all[tier], id, id, name)
                end
            end
        end
    end
end


-- Preloads the player's selected PvP talents and all available PvP talents into the cache.
function addon:PreloadPvpTalents(pvpTalents, allPvpTalents, spells)
    -- Get the player's currently selected PvP talent IDs.
    local pvpTalentIDs = C_SpecializationInfo.GetAllSelectedPvpTalentIDs()

    -- Iterate through the three PvP talent tiers (rows).
    for tier = 1, 3 do
        -- Initialize the cache for each tier if it doesn't already exist.
        allPvpTalents[tier] = allPvpTalents[tier] or { id = {}, name = {} }

        -- If a PvP talent is selected in this tier, retrieve its information.
        if pvpTalentIDs[tier] then
            local id, name, _, _, available, spellID, unlocked, _, _, known = GetPvpTalentInfoByID(pvpTalentIDs[tier])

            -- If the talent is available, unlocked, and known, update the cache for selected PvP talents.
            if available and unlocked and known then
                self:UpdateCache(pvpTalents, id, id, name)
                if spells and spellID then
                    self:UpdateCache(spells, spellID, spellID, name)
                end
            end
        end

        -- Retrieve all available PvP talent IDs for this tier.
        local pvpAvailableTalentIDs = C_SpecializationInfo.GetPvpTalentSlotInfo(tier).availableTalentIDs

        -- Iterate through all available PvP talents in this tier.
        for row = 1, #pvpAvailableTalentIDs do
            local id, name, _, _, available, spellID, unlocked, _, _, known = GetPvpTalentInfoByID(pvpAvailableTalentIDs[row])

            -- Update the cache for all available PvP talents in this tier.
            self:UpdateCache(allPvpTalents[tier], id, id, name)
        end
    end
end



-- Preloads equipped items from the player's character into the cache.
function addon:PreloadEquip(equip)
    -- Iterate through all equipped inventory slots.
    for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
        -- Get the item ID of the equipped item in the slot.
        local id = GetInventoryItemID("player", slot)
        if id then
            -- Use the new API to retrieve item information.
            local itemName, itemLink = C_Item.GetItemInfo(id)
            if itemLink then
                -- If the item is cached, update the cache with the item link.
                self:UpdateCache(equip, slot, id, itemLink)
            else
                -- Handle cases where the item is not yet cached by storing a placeholder.
                self:UpdateCache(equip, slot, id, "Unknown Item")
            end
        end
    end
end


-- Preloads item information from the player's bags into the cache.
function addon:PreloadBags(bags)
    local maxBags = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or (NUM_BAG_SLOTS + (NUM_REAGENTBAG_SLOTS or 1))) or NUM_BAG_SLOTS

    for bag = BACKPACK_CONTAINER, maxBags do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for index = 1, (numSlots or 0) do
            local id = C_Container.GetContainerItemID(bag, index)
            if id then
                local itemName, itemLink = C_Item.GetItemInfo(id)
                self:UpdateCache(bags, { bag, index }, id, itemLink or itemName or "Unknown Item")
            end
        end
    end
end


-- Preloads pet information from the player's Pet Journal into the cache.
function addon:PreloadPetJournal(pets)
    -- Save the current Pet Journal filters so they can be restored later.
    local saved = self:SavePetJournalFilters()

    -- Clear the Pet Journal search filter and set new filters to include all collected pets.
    C_PetJournal.ClearSearchFilter()
    C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
    C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, false)
    C_PetJournal.SetAllPetSourcesChecked(true)
    C_PetJournal.SetAllPetTypesChecked(true)

    -- Iterate through all pets in the Pet Journal.
    for index = 1, C_PetJournal.GetNumPets() do
        -- Get the pet's ID and species.
        local id, species = C_PetJournal.GetPetInfoByIndex(index)
        -- Update the cache with the pet's information.
        self:UpdateCache(pets, id, id, species)
    end

    -- Restore the original Pet Journal filters.
    self:RestorePetJournalFilters(saved)
end


-- Preloads macro information into the cache.
function addon:PreloadMacros(macros)
    -- MAX_ACCOUNT_MACROS was removed in Retail WoW; derive the character-macro start
    -- index directly from GetNumMacros(), which already returns account-wide and
    -- character counts separately.  We keep a local fallback cap for documentation.
    local ABP_MAX_ACCOUNT_MACROS = 136  -- Blizzard hard cap for account-wide macros.

    -- Get the total number of account-wide and character-specific macros.
    local all, char = GetNumMacros()
    all  = all  or 0
    char = char or 0

    -- Iterate through all account-wide macros.
    for index = 1, all do
        -- Get macro information (name, icon, body) for each macro.
        local name, _, body = GetMacroInfo(index)
        if body then
            -- Update the cache with the packed macro body and name.
            self:UpdateCache(macros, index, addon:PackMacro(body), name)
        end
    end

    -- Character-specific macros start immediately after account-wide ones.
    -- GetNumMacros() returns them offset from the account-wide block, so we
    -- use `all` (not MAX_ACCOUNT_MACROS) as the base to avoid any gap.
    for index = all + 1, all + char do
        -- Get macro information (name, icon, body) for each macro.
        local name, _, body = GetMacroInfo(index)
        if body then
            -- Update the cache with the packed macro body and name.
            self:UpdateCache(macros, index, addon:PackMacro(body), name)
        end
    end
end


-- This function preloads the player's pet spells into the cache for quick access.
function addon:PreloadPetSpells(spells)
    -- Check if the player has pet spells available.
    local numPetSpells, petToken = C_SpellBook.HasPetSpells()

    -- If the player has pet spells, proceed to cache them.
    if numPetSpells then
        -- Iterate through all available pet spells.
        for index = 1, numPetSpells do
            local itemType, actionID, spellID = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Pet)
            local name, subName = C_SpellBook.GetSpellBookItemName(index, Enum.SpellBookSpellBank.Pet)
            local id = spellID or actionID

            if itemType == Enum.SpellBookItemType.PetAction then
                -- Token action (Attack, Follow, Stay, etc.)
                self:UpdateCache(spells, index, -1, name)
            else
                -- Real spell (Axe Toss, Threatening Presence, etc.)
                if id then
                    id = bit.band(id, 0xFFFFFF)
                    self:UpdateCache(spells, index, id, name)
                elseif name then
                    self:UpdateCache(spells, index, -1, name)
                end
            end
        end
    end
end


-- Clears the action at the specified slot by picking it up and clearing the cursor, unless it's a mount, flyout, or a toy named "hearthstone" when Random Hearthstone addon is loaded.
function addon:ClearSlot(slot)
    if InCombatLockdown() then return end
    ClearCursor()  -- Ensure the cursor is cleared before starting
    local actionType, id, subType = GetActionInfo(slot)

    -- Check if the action is a mount
    if actionType == "spell" and id then  -- Ensure 'id' is not nil before proceeding
        local spellInfo = C_Spell.GetSpellInfo(id)
        local spellName = spellInfo and spellInfo.name or tostring(id)
        if C_Spell.IsSpellUsable(id) and IsSpellKnown(id) then
            -- Check if the spell is a mount
            local mountID = C_MountJournal.GetMountFromSpell(id)
            if mountID then
                if ABP_DEBUG then print(string.format("Skipping clear for mount %s in slot %d", spellName, slot)) end
                return -- Skip clearing this slot since it's a mount
            end

            -- Check if the spell is a hearthstone toy
            local toyName = C_ToyBox.GetToyInfo(id)
            local _, isRandomHearthstoneLoaded = C_AddOns.IsAddOnLoaded("RandomHearth") -- Replace with the correct folder name

            if toyName and string.lower(toyName):find("hearthstone") then
                if isRandomHearthstoneLoaded then
                    return -- Skip clearing this slot since it's a hearthstone toy and Random Hearthstone addon is loaded
                end
            end
        end

    elseif actionType == "flyout" then
        -- For flyout spells, skip clearing the slot
        if ABP_DEBUG then print(string.format("Skipping clear for flyout in slot %d", slot)) end
        return

    elseif actionType == "summonmount" then
        -- Skip clearing the slot if it contains a "summonmount" action
        if ABP_DEBUG then print(string.format("Skipping clear for summonmount in slot %d", slot)) end
        return

    elseif actionType == nil then
        -- For empty slots, no action is needed
        return
    end

    -- If not a mount, flyout, or specified toy, pick up and clear the action
    PickupAction(slot) -- Pick up the action from the specified slot to clear it.
    ClearCursor()      -- Clear cursor so action is not left attached to cursor
end


-- Places the currently held action or item into the specified slot and clears the cursor.
function addon:PlaceToSlot(slot)
    if InCombatLockdown() then return end
    PlaceAction(slot)  -- Place the action or item into the specified slot.
    ClearCursor()      -- Clear the cursor after placing the action.
end


-- Clears the action from the specified pet action slot.
function addon:ClearPetSlot(slot)
    if InCombatLockdown() then return end
    ClearCursor()        -- Ensure the cursor is cleared before starting.
    PickupPetAction(slot) -- Pick up the pet action from the specified slot.
    ClearCursor()        -- Clear the cursor after picking up the action.
end


-- Places the currently held pet action into the specified slot and clears the cursor.
function addon:PlaceToPetSlot(slot)
    if InCombatLockdown() then return end
    PickupPetAction(slot) -- Pick up the pet action for placement.
    ClearCursor()         -- Clear the cursor after placing the action.
end


-- Places a spell into the specified slot, with retries if the initial attempt fails.
function addon:PlaceSpell(slot, id, link, count)
    if InCombatLockdown() then return end
    if ABP_DEBUG then print("Placing spell:", id, "in slot:", slot) end

    -- Retail specific: Try the modern placement API first for special spells
    if C_Spell and C_Spell.PlaceSpellOnActionBar then
        C_Spell.PlaceSpellOnActionBar(id, slot)
        -- Verify if it worked (approximate check by looking at action info)
        local _, placedID = GetActionInfo(slot)
        if placedID == id then
            return
        end
    end

    count = count or ABP_PICKUP_RETRY_COUNT  -- Default to a set number of retry attempts.

    ClearCursor()      -- Ensure the cursor is cleared before starting.
    C_Spell.PickupSpell(id)    -- Attempt to pick up the spell by its ID.

    -- If the cursor doesn't hold the spell, attempt to retry placement.
    if not CursorHasSpell() then
        if count > 0 then
            -- Schedule a retry if attempts remain.
            self:ScheduleTimer(function()
                self:PlaceSpell(slot, id, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else
            -- Log an error if all attempts fail.
            self:cPrintf(link, DEBUG .. L.msg_cant_place_spell, link)
        end
    else
        -- Place the spell into the slot if successfully picked up.
        self:PlaceToSlot(slot)
    end
end


-- Places a spell from the spellbook into the specified slot, with retries if necessary.
function addon:PlaceSpellBookItem(slot, id, tab, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Default to a set number of retry attempts.

    ClearCursor()              -- Ensure the cursor is cleared before starting.
    C_SpellBook.PickupSpellBookItem(id, tab) -- Attempt to pick up the spell from the spellbook.

    -- If the cursor doesn't hold the spell, attempt to retry placement.
    if not CursorHasSpell() then
        if count > 0 then
            -- Schedule a retry if attempts remain.
            self:ScheduleTimer(function()
                self:PlaceSpellBookItem(slot, id, tab, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else
            -- Log an error if all attempts fail.
            self:cPrintf(link, DEBUG .. L.msg_cant_place_spell, link)
        end
    else
        -- Place the spell into the slot if successfully picked up.
        self:PlaceToSlot(slot)
    end
end


-- Places a flyout spell into the specified slot on the action bar.
function addon:PlaceFlyout(slot, id, tab, link, count)
    if InCombatLockdown() then return end
    ClearCursor()              -- Ensure the cursor is cleared before starting.
    C_SpellBook.PickupSpellBookItem(id, tab) -- Pick up the flyout spell from the spellbook using its ID and tab.

    self:PlaceToSlot(slot)     -- Place the flyout spell into the specified slot on the action bar.
end


-- Places a talent into the specified slot on the action bar.
function addon:PlaceTalent(slot, id, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Ensure the cursor is cleared before picking up the talent.
    if C_Spell and C_Spell.PickupSpell then
        C_Spell.PickupSpell(id)
    end
    if not CursorHasSpell() and type(PickupTalent) == "function" then
        PickupTalent(id)
    end

    if not CursorHasSpell() then  -- Check if the cursor successfully picked up the talent.
        if count > 0 then  -- If not, retry placing the talent after a short delay.
            self:ScheduleTimer(function()
                self:PlaceTalent(slot, id, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else  -- If retries are exhausted, print a debug message.
            self:cPrintf(link, DEBUG .. L.msg_cant_place_spell, link)
        end
    else
        self:PlaceToSlot(slot)  -- If the talent is successfully picked up, place it into the slot.
    end
end


-- Places a PvP talent into the specified slot on the action bar.
function addon:PlacePvpTalent(slot, id, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Ensure the cursor is cleared before picking up the PvP talent.
    if type(id) == "number" then  -- Ensure that 'id' is a number.
        ClearCursor()  -- Ensure the cursor is cleared before picking up the PvP talent.
        ---@diagnostic disable-next-line
        PickupPvpTalent(id)  -- Pick up the PvP talent using its ID.

        if not CursorHasSpell() then  -- Check if the cursor successfully picked up the PvP talent.
            if count > 0 then  -- If not, retry placing the PvP talent after a short delay.
                self:ScheduleTimer(function()
                    self:PlacePvpTalent(slot, id, link, count - 1)
                end, ABP_PICKUP_RETRY_INTERVAL)
            else  -- If retries are exhausted, print a debug message.
                self:cPrintf(link, DEBUG .. L.msg_cant_place_spell, link)
            end
        else
            self:PlaceToSlot(slot)  -- If the PvP talent is successfully picked up, place it into the slot.
        end
    else
        self:cPrintf(link, DEBUG .. "Invalid PvP talent ID: " .. tostring(id))
    end
end


-- Places a mount into the specified action bar slot.
function addon:PlaceMount(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_MountJournal.Pickup(id)  -- Pick up the mount using the C_MountJournal API.

    self:PlaceToSlot(slot)  -- Place the mount into the specified slot.
end


-- Places an item in the specified action bar slot.
function addon:PlaceItem(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the item by its ID.
    C_Item.PickupItem(id)

    self:PlaceToSlot(slot)  -- Place the item into the specified slot.
end


-- Places a toy from the ToyBox collection into the specified action bar slot.
function addon:PlaceToy(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    if C_ToyBox and C_ToyBox.PickupToyBoxItem then
        C_ToyBox.PickupToyBoxItem(id)
    elseif C_Item and C_Item.PickupItem then
        C_Item.PickupItem(id)
    end

    self:PlaceToSlot(slot)  -- Place the toy into the specified slot.
end


-- Places an inventory item in the specified action bar slot.
function addon:PlaceInventoryItem(slot, id, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    PickupInventoryItem(id)  -- Pick up the inventory item by its ID.

    if not CursorHasItem() then  -- Check if the cursor successfully picked up the item.
        if count > 0 then  -- If not, retry placing the item after a short delay.
            self:ScheduleTimer(function()
                self:PlaceInventoryItem(slot, id, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else
            self:cPrintf(link, DEBUG .. L.msg_cant_place_item, link)  -- Print a debug message if retries are exhausted.
        end
    else
        self:PlaceToSlot(slot)  -- If the item is successfully picked up, place it into the slot.
    end
end


-- Places a container item in the specified action bar slot.
function addon:PlaceContainerItem(slot, bag, id, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_Container.PickupContainerItem(bag, id)  -- Pick up the container item from the specified bag and slot.

    if not CursorHasItem() then  -- Check if the cursor successfully picked up the item.
        if count > 0 then  -- If not, retry placing the item after a short delay.
            self:ScheduleTimer(function()
                self:PlaceContainerItem(slot, bag, id, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else
            self:cPrintf(link, DEBUG .. L.msg_cant_place_item, link)  -- Print a debug message if retries are exhausted.
        end
    else
        self:PlaceToSlot(slot)  -- If the item is successfully picked up, place it into the slot.
    end
end


-- Places a pet in the specified action bar slot.
function addon:PlacePet(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_PetJournal.PickupPet(id)  -- Pick up the pet using the C_PetJournal API.

    self:PlaceToSlot(slot)  -- Place the pet into the specified slot.
end


-- Places a macro in the specified action bar slot.
function addon:PlaceMacro(slot, id, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    PickupMacro(id)  -- Pick up the macro by its ID.

    if not CursorHasMacro() then  -- Check if the cursor successfully picked up the macro.
        if count > 0 then  -- If not, retry placing the macro after a short delay.
            self:ScheduleTimer(function()
                self:PlaceMacro(slot, id, link, count - 1)
            end, ABP_PICKUP_RETRY_INTERVAL)
        else
            self:cPrintf(link, DEBUG .. L.msg_cant_place_macro, link)  -- Print a debug message if retries are exhausted.
        end
    else
        self:PlaceToSlot(slot)  -- If the macro is successfully picked up, place it into the slot.
    end
end


-- Places an equipment set in the specified action bar slot.
function addon:PlaceEquipment(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the equipment set by its ID.
    C_EquipmentSet.PickupEquipmentSet(id)

    self:PlaceToSlot(slot)  -- Place the equipment set into the specified slot.
end


-- Places a transmog outfit into the specified action bar slot.
function addon:PlaceOutfit(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    if C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
        C_TransmogOutfitInfo.PickupOutfit(id)
    end

    self:PlaceToSlot(slot)  -- Place the outfit into the specified slot.
end


-- Places a pet spell in the specified pet action bar slot.
function addon:PlacePetSpell(slot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the pet spell.
    C_SpellBook.PickupSpellBookItem(id, Enum.SpellBookSpellBank.Pet)

    self:PlaceToPetSlot(slot)  -- Place the pet spell into the specified slot.
end


-- Places a pet spell from the pet spellbook onto a player's action bar slot.
function addon:PlacePetSpellOnActionBar(slot, petSlot, id, link, count)
    if InCombatLockdown() then return end
    ClearCursor()

    if petSlot and petSlot > 0 and C_SpellBook and C_SpellBook.PickupSpellBookItem then
        C_SpellBook.PickupSpellBookItem(petSlot, Enum.SpellBookSpellBank.Pet)
    elseif id and C_Spell and C_Spell.PickupSpell then
        C_Spell.PickupSpell(id)
    end

    self:PlaceToSlot(slot)
end


-- Places the Single-Button Assistant (Assisted Combat Rotation) into the specified action bar slot.
function addon:PlaceAssistedCombat(slot, spellID, link, count)
    if InCombatLockdown() then return end
    count = count or ABP_PICKUP_RETRY_COUNT
    ClearCursor()

    local targetSpellID = (C_AssistedCombat and C_AssistedCombat.GetActionSpell and C_AssistedCombat.GetActionSpell()) or spellID
    if targetSpellID and targetSpellID > 0 then
        if C_Spell and C_Spell.PickupSpell then
            C_Spell.PickupSpell(targetSpellID)
        end

        local hasCursor = CursorHasSpell() or (GetCursorInfo and GetCursorInfo() ~= nil)
        if not hasCursor then
            if count > 0 then
                self:ScheduleTimer(function()
                    self:PlaceAssistedCombat(slot, targetSpellID, link, count - 1)
                end, ABP_PICKUP_RETRY_INTERVAL)
            else
                self:cPrintf(link, DEBUG .. (L.msg_cant_place_spell or "Can't place spell: %s"), link)
            end
        else
            self:PlaceToSlot(slot)
        end
    end
end


-- Function to get the name of the spell or action in the slot
function addon:GetActionName(slot)
    local actionType, id, subType = GetActionInfo(slot)

    if (subType == "assistedcombat") or (C_ActionBar and C_ActionBar.IsAssistedCombatAction and C_ActionBar.IsAssistedCombatAction(slot)) then
        return _G.ASSISTED_COMBAT_ROTATION or "Single-Button Assistant"
    end

    if actionType == "spell" then
        if id then
            local spellInfo = C_Spell.GetSpellInfo(id)
            return spellInfo and spellInfo.name or nil
        end

    elseif actionType == "macro" then
        local macroName = GetActionText(slot)
        return macroName

    elseif actionType == "item" then
        if id then
            local itemName = C_Item.GetItemInfo(id)
            return itemName
        end

    elseif actionType == "flyout" then
        if id then
            local flyoutID = id
            local _, _, numSlots = GetFlyoutInfo(flyoutID)
            if numSlots then
                for i = 1, numSlots do
                    local spellID = GetFlyoutSlotInfo(flyoutID, i)
                    if spellID then
                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                        if spellInfo and spellInfo.name then
                            return spellInfo.name  -- Return the name of the first valid spell in the flyout
                        end
                    end
                end
            end
        end

    elseif actionType == "mount" then
        if id then
            local mountID = id
            local mountName = C_MountJournal.GetMountInfoByID(mountID)
            return mountName
        end

    elseif actionType == "outfit" then
        if id and C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetOutfitInfo then
            local outfitInfo = C_TransmogOutfitInfo.GetOutfitInfo(id)
            return outfitInfo and outfitInfo.name or nil
        end
    end

    return nil
end


-- Checks if a profile is the default for a given key.
function addon:IsDefault(profile, key)
    if type(profile) ~= "table" then
        local list = self.db.profile.list
        profile = list[profile]

        if not profile then return end
    end

    return profile.fav and profile.fav[key] and true or nil  -- Returns true if the profile is marked as a favorite for the given key.
end
