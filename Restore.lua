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

local C_Timer = C_Timer
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_Item = C_Item
local C_Container = C_Container
local C_ClassTalents = C_ClassTalents
local C_Traits = C_Traits
local C_MountJournal = C_MountJournal
local C_ToyBox = C_ToyBox
local C_EquipmentSet = C_EquipmentSet
local C_PetJournal = C_PetJournal
local C_Garrison = C_Garrison
local C_SpecializationInfo = C_SpecializationInfo
local Enum = Enum

_G.ActionBarProfilesDBv3 = _G.ActionBarProfilesDBv3 or {}

ABP = ABP or {}

-- Function to retrieve and optionally filter a list of profiles
function addon:GetProfiles(filter, case)
    -- Retrieve the list of profiles from the database
    local list = self.db.profile.list
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
        if not check then
            self:UpdateGUI()
        end
    end

    -- Check Talents via Import String first
    if not profile.skipTalents and profile.talentString then
        local currentConfigID = C_ClassTalents.GetActiveConfigID()
        local currentString = currentConfigID and C_Traits.GenerateImportString(currentConfigID) or ""
        
        -- If the import strings do not match, we prompt the user to manually import it and abort the action bar restore.
        if currentString ~= profile.talentString then
            if check then
                return 0, 0  -- Bypass the missing spells verification dialog since we need to swap talents first anyway!
            end

            ABP_TempTalentString = profile.talentString
            local popupData = {
                continueRestore = function()
                    if not profile.skipMacros then self:RestoreMacros(profile, check, cache, res) end
                    C_Timer.After(0.2, function()
                        if not profile.skipActions then self:RestoreActions(profile, check, cache, res) end
                        if not profile.skipPetActions then self:RestorePetActions(profile, check, cache, res) end
                        self:UpdateGUI()
                    end)
                end
            }
            StaticPopup_Show("ABP_TALENT_IMPORT", nil, nil, popupData)
            return res.fail, res.total
        end
    end

    if not profile.skipMacros then
        self:RestoreMacros(profile, check, cache, res)
    end
    
    -- Give the game a moment to register new spells in the spellbook
    if not check then
        C_Timer.After(0.2, FinishRestoration)
    else
        FinishRestoration()
    end

    return res.fail, res.total
end


-- Function to restore macros based on a given profile, with an option to check without actually applying the changes
function addon:RestoreMacros(profile, check, cache, res)
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


-- Function to handle the "ADDON_LOADED" event, specifically for the ActionBarProfiles addon
local function OnAddonLoaded(self, event, arg1)
    -- Check if the loaded addon is "ActionBarProfiles" (Replace with the actual name of your addon)
    if arg1 == "ActionBarProfiles" then
        -- Check if the global database 'ActionBarProfilesDBv3' is available
        if ActionBarProfilesDBv3 then
            -- Assign the global database to the addon's database variable
            ABP.db = ActionBarProfilesDBv3

            -- Ensure that the 'talentsByProfile' table exists in the database
            ActionBarProfilesDBv3.talentsByProfile = ActionBarProfilesDBv3.talentsByProfile or {}

            -- If the addon has an UpdateTalentsTable function, call it to update the talents table
            if addon.UpdateTalentsTable then
                addon:UpdateTalentsTable()
            end
        end
    end
end


-- Create a new frame to listen for events
local eventFrame = CreateFrame("Frame")


-- Register the frame to listen for the "ADDON_LOADED" event
eventFrame:RegisterEvent("ADDON_LOADED")


-- Set the script to run when the "ADDON_LOADED" event fires, linking it to the OnAddonLoaded function
eventFrame:SetScript("OnEvent", OnAddonLoaded)


-- Define a global function to get the player's specialization and configuration
function GetMySpecAndConfig()
    -- Get the player's current specialization index (e.g., 1 for the first spec)
    local specIndex = GetSpecialization()
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
        local specID = GetSpecializationInfo(GetSpecialization())--select(1, GetSpecializationInfo(specIndex))
        local treeID = C_ClassTalents.GetTraitTreeForSpec(specID)
        local configID = C_ClassTalents.GetActiveConfigID()
        local currentClassProfile = specToClassMap[specID] or "Unknown Class"

        -- Store the gathered information in the global ABP table
        ABP.specID = specID
        ABP.treeID = treeID
        ABP.configID = configID
        ABP.currentClassProfile = currentClassProfile

        -- Uncomment the following lines for debugging purposes:
        if ABP_DEBUG then
            print("Your current specialization index is: " .. ABP.specIndex)
            print("Your current specialization ID is: " .. ABP.specID)
            print("Your current trait tree ID is: " .. (ABP.treeID or "nil"))
            print("Your active configuration ID is: " .. (ABP.configID or "nil"))
            print("Current class profile in use: " .. ABP.currentClassProfile)
        end
    else
        --Uncomment the following line to notify when no specialization is selected
        print("You have no specialization selected.")
    end
end


-- Make the function globally accessible so it can be called from anywhere
_G["GetMySpecAndConfig"] = GetMySpecAndConfig


-- Function to compare the current talent configuration with the saved profile and unlearn mismatched talents
function addon:AreTalentsMatching(profile)
    -- Retrieve the current talent configuration
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        -- Return false if no active configuration is found
        return false, {}, {}
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    if not configInfo then
        if ABP_DEBUG then print("No config info found for ID: " .. configID) end
        return false, {}, {}
    end

    -- Initialize tables to track talents to learn and unlearn
    local talentsToLearn = {}
    local talentsToUnlearn = {}

    -- Create a lookup table for quick comparison
    local profileTalentLookup = {}
    if profile.talents and type(profile.talents) == "table" then
        for _, talent in ipairs(profile.talents) do
            profileTalentLookup[talent.nodeID] = talent
        end
    end

    -- Iterate over each node in the active talent tree
    for _, treeID in ipairs(configInfo.treeIDs) do
        local nodes = C_Traits.GetTreeNodes(treeID)
        for _, nodeID in ipairs(nodes) do
            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            local profileTalent = profileTalentLookup[nodeID]

            -- Skip free talents, as they should not be unlearned or learned
            if nodeInfo and not (nodeInfo.currentRank > 0 and nodeInfo.ranksPurchased == 0 and not nodeInfo.canPurchaseRank) then
                if profileTalent then
                    -- Compare entryIDs if it's a selection node
                    if profileTalent.isSelectionNode and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID ~= profileTalent.entryID then
                        -- Mismatch found: Active selection differs from profile
                        table.insert(talentsToUnlearn, {
                            nodeInfo = nodeInfo,
                            rank = nodeInfo.currentRank,
                            spellID = nodeInfo.activeEntry and nodeInfo.activeEntry.spellID,
                            treeType = (nodeInfo.posX < 10000) and "Class" or "Spec"
                        })

                        table.insert(talentsToLearn, {
                            nodeID = nodeID,
                            entryID = profileTalent.entryID,
                            isSelectionNode = true,
                            posX = profileTalent.posX,
                            posY = profileTalent.posY,
                            rank = profileTalent.ranksPurchased,
                            spellID = profileTalent.spellID
                        })

                        -- Log mismatch for debugging
                        if ABP_DEBUG then print(string.format("Mismatch detected: NodeID %d - Active EntryID %d, Expected EntryID %d", nodeID, nodeInfo.activeEntry.entryID, profileTalent.entryID)) end
                    elseif nodeInfo.currentRank < profileTalent.ranksPurchased then
                        -- Handle normal nodes where ranks don't match
                        table.insert(talentsToLearn, {
                            nodeID = nodeID,
                            entryID = profileTalent.entryID,
                            isSelectionNode = false,
                            posX = profileTalent.posX,
                            posY = profileTalent.posY,
                            rank = profileTalent.ranksPurchased,
                            spellID = profileTalent.spellID
                        })
                    end
                elseif nodeInfo.currentRank > 0 then
                    -- Talent is active but not in the profile
                    table.insert(talentsToUnlearn, {
                        nodeInfo = nodeInfo,
                        rank = nodeInfo.currentRank,
                        spellID = nodeInfo.activeEntry and nodeInfo.activeEntry.spellID,
                        treeType = (nodeInfo.posX < 10000) and "Class" or "Spec"
                    })
                end
            end
        end
    end

    -- Return whether talents match and the list of talents to learn/unlearn
    local talentsMatch = (#talentsToUnlearn == 0 and #talentsToLearn == 0)
    return talentsMatch, talentsToLearn, talentsToUnlearn
end


-- Function to restore talents based on a saved profile
function addon:RestoreTalents(profile, check, cache, res, onComplete)
    --print("RestoreTalents called for profile: " .. (profile.name or "Unknown"))

    if not profile.specID then
        print("Error: The profile specID is missing or invalid. Profile name: " .. profile.name)
        return
    end

    local activeSpecID = GetSpecializationInfo(GetSpecialization())

    if activeSpecID ~= profile.specID then
        --print("Spec mismatch: Expected " .. profile.specID .. ", but got " .. activeSpecID)
        return
    end

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        --print("No active config ID found.")
        return
    end

    local talentsMatch, talentsToLearn, talentsToUnlearn = self:AreTalentsMatching(profile)

    if talentsMatch then
        if ABP_DEBUG then print("Talents already match the saved profile. Skipping restore.") end
        return
    end

    -- Check if the number of talents to unlearn is 5 or greater
    if #talentsToUnlearn >= 5 then
        self:FixRestoreTalents(profile, onComplete)
        return
    end

    -- Function to verify that a talent node has been successfully unlearned
    local function VerifyTalentUnlearned(nodeID)
        local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
        return nodeInfo and nodeInfo.currentRank == 0
    end

    -- Function to process learning talents with delay
    local function LearnTalentWithDelay(index)
        if index > #talentsToLearn then
            local commitSuccess = C_ClassTalents.CommitConfig(configID)
            if not commitSuccess then
            end

            if PlayerSpellsFrame then
                HideUIPanel(PlayerSpellsFrame)
                ShowUIPanel(PlayerSpellsFrame)
            end
            return
        end

        local nodeData = talentsToLearn[index]
        local success = false

        if nodeData.isSelectionNode then
            success = C_Traits.SetSelection(configID, nodeData.nodeID, nodeData.entryID)
            --print("Setting selection for node: " .. nodeData.nodeID .. " EntryID: " .. nodeData.entryID)
        else
            success = C_Traits.PurchaseRank(configID, nodeData.nodeID)
            --print("Purchasing rank for node: " .. nodeData.nodeID .. " Success: " .. tostring(success))
        end

        if not success then
            --print("Unable to learn talent for node: " .. nodeData.nodeID)
        end

        C_Timer.After(0.1, function()
            LearnTalentWithDelay(index + 1)
        end)
    end

    -- Unlearn talents with verification and delay
    local function UnlearnTalentsWithDelay(index)
        if index > #talentsToUnlearn then
            -- All unlearn operations completed, proceed to learn talents
            C_Timer.After(0.5, function() -- Small delay before starting to learn talents
                LearnTalentWithDelay(1)
            end)
            return
        end

        local nodeData = talentsToUnlearn[index]

        -- Check if it's a free talent; if so, skip it
        if nodeData.nodeInfo.isFree then
            --print("Skipping unlearning free talent node: " .. nodeData.nodeInfo.ID)
            UnlearnTalentsWithDelay(index + 1)
            return
        end

        if ABP_DEBUG then print("Unlearning talent node: " .. nodeData.nodeInfo.ID) end
        local success = C_Traits.RefundRank(configID, nodeData.nodeInfo.ID, true)

        -- Verify the unlearn operation
        C_Timer.After(0.1, function()
            if not VerifyTalentUnlearned(nodeData.nodeInfo.ID) then
                --print("Failed to unlearn talent for node: " .. nodeData.nodeInfo.ID .. ". Attempting again...")
                success = C_Traits.RefundRank(configID, nodeData.nodeInfo.ID, true)
                C_Timer.After(0.1, function()
                    if VerifyTalentUnlearned(nodeData.nodeInfo.ID) then
                        --print("Successfully unlearned talent for node: " .. nodeData.nodeInfo.ID)
                        UnlearnTalentsWithDelay(index + 1)
                    else
                        --print("Failed again to unlearn talent for node: " .. nodeData.nodeInfo.ID)
                        self:FixRestoreTalents(profile)
                        return
                    end
                end)
            else
                if ABP_DEBUG then print("Successfully unlearned talent for node: " .. nodeData.nodeInfo.ID) end
                UnlearnTalentsWithDelay(index + 1)
            end
        end)
    end

    -- Start unlearning talents that should be removed
    UnlearnTalentsWithDelay(1)
end


-- Function to restore talents based on a saved profile with a complete reset
function addon:FixRestoreTalents(profile, onComplete)
    --print("FixRestoreTalents called for profile: " .. (profile.name or "Unknown"))

    if not profile.specID then
        --print("Error: The profile specID is missing or invalid. Profile name: " .. profile.name)
        return
    end

    local activeSpecID = GetSpecializationInfo(GetSpecialization())

    if activeSpecID ~= profile.specID then
        --print("Spec mismatch: Expected " .. profile.specID .. ", but got " .. activeSpecID)
        return
    end

    -- Flag the addon as processing to prevent overlapping or invalid operations
    if self.isProcessing then
        self:Printf("Error: Addon is already processing another request.")
        return
    end
    self.isProcessing = true

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        self.isProcessing = false
        --print("No active config ID found.")
        if onComplete then onComplete() end
        return
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    if not configInfo then
        self.isProcessing = false
        --print("No config info found for ID: " .. configID)
        if onComplete then onComplete() end
        return
    end

    -- Reset the talent trees associated with the profile
    for _, treeID in ipairs(configInfo.treeIDs) do
        local treeReset = C_Traits.ResetTree(configID, treeID)
        if not treeReset then
            --print("Warning: Unable to reset tree ID: " .. treeID)
        end
    end

    -- Sort the talents by their position in the tree (posY and posX)
    table.sort(profile.talents, function(a, b)
        return a.posY < b.posY or (a.posY == b.posY and a.posX < b.posX)
    end)

    -- Iterate through the talents in the profile and restore them with a delay
    local function LearnTalentWithDelay(index)
        if index > #profile.talents then
            local commitSuccess = C_ClassTalents.CommitConfig(configID)
            self.isProcessing = false
            if not commitSuccess then
                self:Printf("There was an error committing the talent configuration.")
            else
                self:Printf("Talent configuration committed successfully.")
            end

            if PlayerSpellsFrame then
                HideUIPanel(PlayerSpellsFrame)
                ShowUIPanel(PlayerSpellsFrame)
            end
            if onComplete then onComplete() end
            return
        end

        local talent = profile.talents[index]
        local nodeInfo = C_Traits.GetNodeInfo(configID, talent.nodeID)

        -- Check if it's a free talent in the profile; if so, skip it as it's auto-learned
        if talent.isFreeTalent then
            --print("Skipping free talent node: " .. talent.nodeID)
            C_Timer.After(0.1, function()
                LearnTalentWithDelay(index + 1)
            end)
            return
        end

        if nodeInfo then
            --print("Processing node: " .. talent.nodeID .. " Current Rank: " .. nodeInfo.currentRank .. " Max Ranks: " .. nodeInfo.maxRanks)

            if nodeInfo.isAvailable and nodeInfo.isVisible and nodeInfo.meetsEdgeRequirements then
                local ranksPurchased = 0
                while ranksPurchased < talent.ranksPurchased do
                    local success = false

                    if talent.isSelectionNode then
                        -- Check if the selected entry is different from the profile's entry
                        if nodeInfo.activeEntry and nodeInfo.activeEntry.entryID ~= talent.entryID then
                            -- Change to the desired selection in the profile
                            success = C_Traits.SetSelection(configID, talent.nodeID, talent.entryID)
                            -- Debug output
                            if ABP_DEBUG then print(string.format("Switching choice node to entryID %d for nodeID %d", talent.entryID, talent.nodeID)) end
                        else
                            -- If already selected, consider it successful
                            success = true
                        end
                    else
                        success = C_Traits.PurchaseRank(configID, talent.nodeID)
                    end

                    if not success then
                        if ABP_DEBUG then print("Unable to learn talent for node: " .. talent.nodeID) end
                        break
                    else
                        ranksPurchased = ranksPurchased + 1
                    end
                end
            else
                if ABP_DEBUG then print("Prerequisites not met for talent or node not available: " .. talent.nodeID) end
            end
        else
            --print("No node information found for node: " .. talent.nodeID)
        end

        -- Schedule the next talent to be learned after a short delay
        C_Timer.After(0.1, function()
            LearnTalentWithDelay(index + 1)
        end)
    end

    -- Start learning talents with a delay
    LearnTalentWithDelay(1)
end


-- Function to learn talents from a stored profile in the database
function addon:LearnTalentsFromDB(profileName)
    -- Retrieve the profile from the database using the provided profile name
    local profile = self.db.profile.list[profileName]
    -- If the profile or its talents data is not available, exit the function
    if not profile or not profile.talents then return end

    -- Iterate through the talents stored in the profile
    for _, talentData in ipairs(profile.talents) do
        -- Ensure that the talent data is valid, with a valid nodeID and ranksPurchased > 0
        if talentData and talentData.nodeID and talentData.ranksPurchased > 0 then
            local talentID = talentData.nodeID  -- Assign the nodeID to talentID for processing

            -- Check if the talent is already learned by querying talent information
            local _, _, _, isSelected = GetTalentInfoByID(talentID, 1)
            if not isSelected then
                -- If the talent is not already learned, proceed to learn it
                LearnTalent(talentID)
            else
                -- If the talent is already learned, print a message indicating this
                if ABP_DEBUG then print("Talent already learned:", talentData.spellName, "ID:", talentID) end
            end
        end
    end
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
                    --if not IsSpellKnown(id) then
                    if id and not (IsPlayerSpell(id) or IsSpellKnown(id) or ABP_SPECIAL_SPELLS[id]) then
                        --self:Printf("Spell not found: [%s]", name)
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
                                found = self:GetFromCache(cache.talents, id, name, not check and link)
                                if found then
                                    ok = true
                                    if not check then
                                        self:PlaceTalent(slot, found, link)  -- Place the talent in the slot.
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
                            self:PlaceItem(slot, id, link)  -- Place the toy in the slot.
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
                                self:PlaceEquipment(slot, name, link)  -- Place the equipment set in the slot.
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

    -- Call ActionButtonOverride after the restore actions are completed
    ABP:ActionButtonOverride(profileKey, profileName)

    return fail, total  -- Return the number of failures and total actions.
end



-- This function iterates through each action bar slot, checks if the slot is empty, and places the correct macro or spell based on the profile's actions.
function ABP:ActionButtonOverride(profileKey, profileName)
    -- Retrieve the profile from your database using the provided profileKey and profileName
    local profile = self.db.profiles[profileKey] and self.db.profiles[profileKey].list[profileName]
    if not profile then
        print("Profile not found:", profileName)
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

            -- Check if the action is a spell
            elseif type == "spell" then
                -- Extract the spell ID and place it in the current slot
                local spellID = tonumber(sub)
                if spellID then
                    -- Place the spell in the current slot
                    C_Spell.PickupSpell(spellID)
                    PlaceAction(slot)
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
                    local found = self:GetFromCache(cache.petSpells, id, name, type == "spell" and link)
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
    -- If 'check' is true, exit the function early (indicating a dry run or validation)
    if check then
        return 0, 0
    end

    -- Clear existing bindings
    for index = 1, GetNumBindings() do
        -- Get the binding details at the specified index
        local bind = { GetBinding(index) }

        -- If there are keys bound to the command, clear them
        if bind[3] then
            for key in table.s2k_values({ select(3, unpack(bind)) }) do
                -- Unbind the key
                SetBinding(key)
            end
        end
    end

    -- Restore bindings from the profile
    for cmd, keys in pairs(profile.bindings) do
        for key in table.s2k_values(keys) do
            -- Bind the key to the command
            SetBinding(key, cmd)
        end
    end

    -- Additional support for Dominos addon bindings
    if LibStub("AceAddon-3.0"):GetAddon("Dominos", true) and profile.bindingsDominos then
        -- Loop through Dominos action buttons (13 to 60)
        for index = 13, 60 do
            -- Clear existing Dominos bindings
            for key in table.s2k_values({ GetBindingKey(string.format("CLICK DominosActionButton%d:LeftButton", index)) }) do
                SetBinding(key)
            end

            -- Restore Dominos bindings from the profile
            if profile.bindingsDominos[index] then
                for key in table.s2k_values(profile.bindingsDominos[index]) do
                    -- Bind the key to the Dominos action button
                    SetBindingClick(key, string.format("DominosActionButton%d", index), "LeftButton")
                end
            end
        end
    end

    -- Save the bindings to the current binding set (character or account)
    SaveBindings(GetCurrentBindingSet())

    -- Return success with no failures or totals (0, 0)
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
    local spec = GetSpecializationInfo(GetSpecialization())

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
                for idx = 1, numSlots do
                    local flyoutid, _, isKnown, spellName = GetFlyoutSlotInfo(id, idx)
                    self:UpdateCache(spells, flyoutid, flyoutid, spellName)
                end

            elseif type == Enum.SpellBookItemType.Spell or type == "SPELL" then
                -- Cache the spell information.
                self:UpdateCache(spells, id, id, name)
            end
        end
    end
end


-- Preloads the player's collected mounts into the cache, filtering by faction if necessary.
function addon:PreloadMountjournal(mounts)
    -- Get a list of all mount IDs available to the player.
    local all = C_MountJournal.GetMountIDs()

    -- Determine the player's faction (1 for Alliance, 0 for Horde).
    local faction = (UnitFactionGroup("player") == "Alliance" and 1) or 0

    -- Iterate through each mount ID.
    for mount in table.s2k_values(all) do
        -- Retrieve specific information about the mount:
        -- - name: The name of the mount.
        -- - id: The spell ID associated with the mount.
        -- - required: The faction required to use the mount (if any).
        -- - collected: Whether the player has collected the mount.
        local name, id, required, collected = table.s2k_select({ C_MountJournal.GetMountInfoByID(mount) }, 1, 2, 9, 11)

        -- If the mount is collected and either has no faction requirement or matches the player's faction, cache the mount.
        if collected and (not required or required == faction) then
            self:UpdateCache(mounts, id, id, name)
        end
    end
end


-- Preloads the player's combat ally spells into the cache.
function addon:PreloadCombatAllySpells(spells)
    -- Iterate through all followers from the player's Garrison (or an empty table if none exist).
    for follower in table.s2k_values(C_Garrison.GetFollowers() or {}) do
        -- Check if the follower has a valid garrFollowerID.
        if follower.garrFollowerID then
            -- Iterate through the follower's zone support abilities (spells).
            for id in table.s2k_values({ C_Garrison.GetFollowerZoneSupportAbilities(follower.garrFollowerID) }) do
                -- Retrieve spell information for the ability.
                local spellInfo = C_Spell.GetSpellInfo(id)
                -- Use the spell's name if available; otherwise, default to "Unknown Spell".
                local name = spellInfo and spellInfo.name or "Unknown Spell"
                -- Update the cache with the spell information.
                self:UpdateCache(spells, 211390, id, name)
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
                                        self:UpdateCache(talents, nodeID, nodeID, name)
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
    -- Iterate through all bags (backpack and additional bag slots).
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        -- Iterate through all slots in each bag.
        for index = 1, C_Container.GetContainerNumSlots(bag) do
            -- Get the item ID in the current bag slot.
            local id = C_Container.GetContainerItemID(bag, index)
            if id then
                -- Use the new API to retrieve item information.
                local itemName, itemLink = C_Item.GetItemInfo(id)
                if itemLink then
                    -- If the item is cached, update the cache with the item link.
                    self:UpdateCache(bags, { bag, index }, id, itemLink)
                else
                    -- Handle cases where the item is not yet cached by storing a placeholder.
                    self:UpdateCache(bags, { bag, index }, id, "Unknown Item")
                end
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
    for index = 1, C_PetJournal:GetNumPets() do
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
    -- Get the total number of account-wide and character-specific macros.
    local all, char = GetNumMacros()

    -- Iterate through all account-wide macros.
    for index = 1, all do
        -- Get macro information (name, icon, body) for each macro.
        local name, _, body = GetMacroInfo(index)
        if body then
            -- Update the cache with the packed macro body and name.
            self:UpdateCache(macros, index, addon:PackMacro(body), name)
        end
    end

    -- Iterate through all character-specific macros.
    for index = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + char do
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
            -- Get the spell type and ID for the pet spell at the given index.
            local id = select(2, C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Pet))
            -- Retrieve the name and sub-name of the spell.
            local name, subName = C_SpellBook.GetSpellBookItemName(index, Enum.SpellBookSpellBank.Pet)
            -- Check if the spell ID is a valid pet spell (not a token).
            local token = bit.band(id, 0x80000000) == 0 and bit.rshift(id, 24) ~= 1

            -- Normalize the spell ID to handle only the relevant bits.
            id = bit.band(id, 0xFFFFFF)

            if token then
                -- If the spell is a token, cache it with an invalid ID (-1).
                self:UpdateCache(spells, index, -1, name)
            else
                -- Otherwise, cache the spell with its actual ID.
                self:UpdateCache(spells, index, id, name)
            end
        end
    end
end


-- Clears the action at the specified slot by picking it up and clearing the cursor, unless it's a mount, flyout, or a toy named "hearthstone" when Random Hearthstone addon is loaded.
function addon:ClearSlot(slot)
    ClearCursor()  -- Ensure the cursor is cleared before starting
    local actionType, id, subType = GetActionInfo(slot)

    -- Check if the action is a mount
    if actionType == "spell" and id then  -- Ensure 'id' is not nil before proceeding
        local spellName = C_Spell.GetSpellInfo(id)
        if C_Spell.IsSpellUsable(id) and IsSpellKnown(id) then
            -- Check if the spell is a mount
            local mountID = C_MountJournal.GetMountFromSpell(id)
            if mountID then
				print(string.format("Skipping clear for mount %s in slot %d", spellName, slot))
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
		print(string.format("Skipping clear for flyout in slot %d", slot))
        return

    elseif actionType == "summonmount" then
        -- Skip clearing the slot if it contains a "summonmount" action
		print(string.format("Skipping clear for summonmount in slot %d", slot))
        return

    elseif actionType == nil then
        -- For empty slots, no action is needed
        return
    end

    -- If not a mount, flyout, or specified toy, pick up and clear the action
    PickupAction(slot) -- Pick up the action from the specified slot to clear it.
end


-- Places the currently held action or item into the specified slot and clears the cursor.
function addon:PlaceToSlot(slot)
    PlaceAction(slot)  -- Place the action or item into the specified slot.
    ClearCursor()      -- Clear the cursor after placing the action.
end


-- Clears the action from the specified pet action slot.
function addon:ClearPetSlot(slot)
    ClearCursor()        -- Ensure the cursor is cleared before starting.
    PickupPetAction(slot) -- Pick up the pet action from the specified slot.
    ClearCursor()        -- Clear the cursor after picking up the action.
end


-- Places the currently held pet action into the specified slot and clears the cursor.
function addon:PlaceToPetSlot(slot)
    PickupPetAction(slot) -- Pick up the pet action for placement.
    ClearCursor()         -- Clear the cursor after placing the action.
end


-- Places a spell into the specified slot, with retries if the initial attempt fails.
function addon:PlaceSpell(slot, id, link, count)
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
    ClearCursor()              -- Ensure the cursor is cleared before starting.
    C_SpellBook.PickupSpellBookItem(id, tab) -- Pick up the flyout spell from the spellbook using its ID and tab.

    self:PlaceToSlot(slot)     -- Place the flyout spell into the specified slot on the action bar.
end


-- Places a talent into the specified slot on the action bar.
function addon:PlaceTalent(slot, id, link, count)
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Ensure the cursor is cleared before picking up the talent.
    PickupTalent(id)  -- Pick up the talent using its ID.

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
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_MountJournal.Pickup(id)  -- Pick up the mount using the C_MountJournal API.

    self:PlaceToSlot(slot)  -- Place the mount into the specified slot.
end


-- Places an item in the specified action bar slot.
function addon:PlaceItem(slot, id, link, count)
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the item by its ID.
    C_Item.PickupItem(id)

    self:PlaceToSlot(slot)  -- Place the item into the specified slot.
end


-- Places an inventory item in the specified action bar slot.
function addon:PlaceInventoryItem(slot, id, link, count)
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
    count = count or ABP_PICKUP_RETRY_COUNT  -- Set the retry count if not provided.

    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_Container.PickupContainerItem(bag, id)  -- Pick up the container item from the specified bag and slot.

    if not CursorHasItem() then  -- Check if the cursor successfully picked up the item.
        if count > 0 then  -- If not, retry placing the item after a short delay.
            self:ScheduleTimer(function()
                self:PlaceContainerItem(slot, id, link, count - 1)
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
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.
    C_PetJournal.PickupPet(id)  -- Pick up the pet using the C_PetJournal API.

    self:PlaceToSlot(slot)  -- Place the pet into the specified slot.
end


-- Places a macro in the specified action bar slot.
function addon:PlaceMacro(slot, id, link, count)
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
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the equipment set by its ID.
    C_EquipmentSet.PickupEquipmentSet(id)

    self:PlaceToSlot(slot)  -- Place the equipment set into the specified slot.
end


-- Places a pet spell in the specified pet action bar slot.
function addon:PlacePetSpell(slot, id, link, count)
    ClearCursor()  -- Clear the cursor to ensure no other item is being held.

    -- Use the new API to pick up the pet spell.
    C_SpellBook.PickupSpellBookItem(id, Enum.SpellBookSpellBank.Pet)

    self:PlaceToPetSlot(slot)  -- Place the pet spell into the specified slot.
end


-- Function to get the name of the spell or action in the slot
function GetActionName(slot)
    local actionType, id = GetActionInfo(slot)

    if actionType == "spell" then
        if id then
            local name = C_Spell.GetSpellInfo(id)
            return name
        end

    elseif actionType == "macro" then
        if id then
            local macroName = GetMacroInfo(id)
            return macroName
        end

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
                        local spellName = C_Spell.GetSpellInfo(spellID)
                        if spellName then
                            return spellName  -- Return the name of the first valid spell in the flyout
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
