local addonName, addon = ...
_G.ABP = addon
LibStub("AceAddon-3.0"):NewAddon(addon, addonName, "AceConsole-3.0", "AceTimer-3.0", "AceEvent-3.0")

local L = LibStub("AceLocale-3.0"):GetLocale(addonName)
_G.ABP_DEBUG = false -- Global toggle for debug prints
local DEBUG = ABP_DEBUG_PREFIX

local qtip = LibStub("LibQTip-1.0")

-- Localize globals for performance
local _G = _G
local pairs, select, unpack, type = pairs, select, unpack, type
local strjoin, format = strjoin, format
local UnitName, GetRealmName, UnitClass = UnitName, GetRealmName, UnitClass
local GetSpecialization, GetSpecializationInfo = GetSpecialization, GetSpecializationInfo
local InCombatLockdown, ToggleCharacter = InCombatLockdown, ToggleCharacter
local C_Timer, C_UnitAuras = C_Timer, C_UnitAuras
local AuraUtil = AuraUtil

-- Fallback dummy frame: guarantees that Blizzard loops (Collapse, UpdateSidebarTabs, SetSidebar)
-- will NEVER encounter a nil frame or crash with 'attempt to index a nil value'
local ABPDummySideBarFrame = CreateFrame("Frame", "ABPDummySideBarFrame", UIParent)
ABPDummySideBarFrame:Hide()

PaperDollActionBarProfilesPane = PaperDollActionBarProfilesPane or nil

local ABP_tabNum

local CopyAttempts = 0

-- Removed ABP_GetPaperDollSideBarFrame to prevent UI taint

function addon:EnsureSidebarInjected()

    -- Allow injection via either:
    --  (a) Modern/Beta builds: CharacterFrame.ModeTabs (right-side vertical tabs)
    --  (b) Classic/PaperDoll builds: PAPERDOLL_SIDEBARS + PaperDollSidebarTabs
    local hasModeTabs = CharacterFrame and (CharacterFrame.ModeTabs or CharacterFrame.UpdateTabLayout)
    local hasClassicSidebar = PAPERDOLL_SIDEBARS and PaperDollSidebarTabs

    if not hasModeTabs and not hasClassicSidebar then return end

    local pane = PaperDollActionBarProfilesPane or _G["PaperDollActionBarProfilesPane"]
    if not pane then return end

    if not self.sidebarTabInjected then
        self:InjectPaperDollSidebarTab(
            (L and L.charframe_tab) or "Action Bar Profiles",
            "PaperDollActionBarProfilesPane",
            "Interface\\AddOns\\ActionBarProfiles\\textures\\CharDollBtn",
            { 0, 0.515625, 0, 0.13671875 }
        )
    end

    if pane.OnInitialize and not pane.abpInitialized then
        pane.abpInitialized = true
        pane:OnInitialize()
        if PaperDollActionBarProfilesSaveDialog and PaperDollActionBarProfilesSaveDialog.OnInitialize then
            PaperDollActionBarProfilesSaveDialog:OnInitialize()
        end
    end
end


-- Clears the action slots on the second action bar (slots 13 to 24).
-- This function iterates through the specified action bar slots and clears each one.
function ClearBarTwo()
    if InCombatLockdown() then
        if UIErrorsFrame then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        end
        return
    end
    for i = 13, 24 do
        addon:ClearSlot(i)  -- Clear each slot on the second action bar.
    end
end
addon.ClearBarTwo = ClearBarTwo



-- Conditional Print Function with Formatting
-- This function prints a formatted string to the chat window if the condition is true.
-- It acts as a wrapper around the Printf method, allowing conditional output.
function addon:cPrintf(cond, ...)
    if cond then 
        self:Printf(...)  -- Call the Printf method if the condition is met.
    end
end


function addon:cPrint(cond, ...)
    if cond then 
        self:Print(...)  -- Call the Print method if the condition is met.
    end
end


-- Opens the addon options panel safely outside of combat lockdown.
function addon:OpenOptions()
    if InCombatLockdown() then
        if UIErrorsFrame and ERR_NOT_IN_COMBAT then
            UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1.0, 0.1, 0.1, 1.0)
        end
        return
    end

    if Settings and Settings.OpenToCategory then
        if self.settingsCategory then
            local categoryID = (self.settingsCategory.GetID and self.settingsCategory:GetID()) or self.settingsCategory.ID
            if categoryID then
                Settings.OpenToCategory(categoryID)
                return
            end
        end

        local category = Settings.GetCategory and Settings.GetCategory(addonName)
        if category then
            local categoryID = (category.GetID and category:GetID()) or category.ID or addonName
            Settings.OpenToCategory(categoryID)
            return
        end
    end

    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(addonName)
    end
end

-- Invalidates the current cache, forcing a rebuild on the next GUI update.
function addon:InvalidateCache()
    self.cacheDirty = true
end


-- This function is called when the addon is initialized. It sets up the database, registers events, and configures the UI elements.
function addon:OnInitialize()
    -- Initialize the addon database with default settings and profile management.
    self.db = LibStub("AceDB-3.0"):New(addonName .. "DB" .. ABP_DB_VERSION, {
        profile = {
            minimap = {
                hide = true, -- Default setting for the minimap icon is hidden.
            },
            list = {}, -- Placeholder for profiles list.
            migrated = {}, -- Tracks migrated profiles to prevent redundant operations.
            replace_macros = false, -- Option to control macro replacement behavior.
        },
    }, ({ UnitClass("player") })[2]) -- Use the player's class for the default profile.
    
    self.isProcessing = false
    self.cacheDirty = true

    -- Register callbacks to update the GUI when the profile is reset, changed, or copied.
    self.db.RegisterCallback(self, "OnProfileReset", "UpdateGUI")
    self.db.RegisterCallback(self, "OnProfileChanged", "UpdateGUI")
    self.db.RegisterCallback(self, "OnProfileCopied", "UpdateGUI")

    -- Register a chat command '/abp' that triggers the OnChatCommand function.
    self:RegisterChatCommand("abp", "OnChatCommand")

    -- Register the addon settings in the Blizzard options panel.
    self:RegisterSettings()

    -- Create and register a minimap icon using LibDataBroker and LibDBIcon.
    self.ldb = LibStub("LibDataBroker-1.1"):NewDataObject(addonName, {
        type = "launcher",
        icon = "Interface\\ICONS\\INV_Misc_Book_09", -- Icon displayed on the minimap.
        label = addonName,
        OnEnter = function(...)
            self:ShowTooltip(...) -- Show tooltip when hovering over the minimap icon.
        end,
        OnLeave = function() end,
        OnClick = function(obj, button)
            if button == "RightButton" then
                self:OpenOptions()
            else
                if InCombatLockdown() then
                    if UIErrorsFrame and ERR_NOT_IN_COMBAT then
                        UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1.0, 0.1, 0.1, 1.0)
                    end
                    return
                end
                ToggleCharacter("PaperDollFrame") -- Toggle character frame on left-click.
            end
        end,
    })

    -- Register the minimap icon with the database settings.
    self.icon = LibStub("LibDBIcon-1.0")
    self.icon:Register(addonName, self.ldb, self.db.profile.minimap)

    -- Check and update existing profiles to include specID if missing
    if self.db and self.db.profile and self.db.profile.list then
        local currentSpecID = (type(GetSpecialization) == "function" and GetSpecialization() and type(GetSpecializationInfo) == "function" and GetSpecializationInfo(GetSpecialization())) or 0
        for profileName, profile in pairs(self.db.profile.list) do
            if not profile.specID then
                profile.specID = currentSpecID
            end
        end
    end

    self:EnsureSidebarInjected()

    -- Watch for Blizzard_UIPanels_Game and ensure hooks are applied whenever character frames load or show
    local sidebarWatcher = CreateFrame("Frame")
    sidebarWatcher:RegisterEvent("ADDON_LOADED")
    sidebarWatcher:RegisterEvent("PLAYER_LOGIN")
    sidebarWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    sidebarWatcher:SetScript("OnEvent", function(watcherSelf, event, loadedAddon)
        if (event == "ADDON_LOADED" and loadedAddon == "Blizzard_UIPanels_Game") or (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_UIPanels_Game")) then
            addon:EnsureSidebarInjected()
        end
        -- On PLAYER_ENTERING_WORLD every addon has finished its OnInitialize,
        -- so all custom sidebar tabs (e.g. Outfitter's OutfitterSidebarTab) are
        -- already injected.  Re-run the lineup so no two custom tabs overlap.
        if event == "PLAYER_ENTERING_WORLD" and addon.sidebarTabInjected then
            C_Timer.After(0, function()
                addon:LineUpPaperDollSidebarTabs()
            end)
        end
    end)

    if type(ToggleCharacter) == "function" and hooksecurefunc then
        hooksecurefunc("ToggleCharacter", function()
            addon:EnsureSidebarInjected()
        end)
    end

    if CharacterFrameMixin and hooksecurefunc then
        if type(CharacterFrameMixin.Collapse) == "function" then
            hooksecurefunc(CharacterFrameMixin, "Collapse", function()
            end)
        end
        if type(CharacterFrameMixin.Expand) == "function" then
            hooksecurefunc(CharacterFrameMixin, "Expand", function()
                addon:EnsureSidebarInjected()
            end)
        end
    end

    -- Re-run tab lineup every time the native sidebar tabs are updated.
    -- This securely handles re-layout for legacy tabs without tainting CharacterFrame:OnShow.
    if type(PaperDollFrame_UpdateSidebarTabs) == "function" and hooksecurefunc then
        hooksecurefunc("PaperDollFrame_UpdateSidebarTabs", function()
            if addon.sidebarTabInjected then
                C_Timer.After(0, function()
                    addon:LineUpPaperDollSidebarTabs()
                end)
            end
        end)
    end

    -- Register events to update the GUI during combat, resting, or when the talent group changes.
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function(...)
        self:UpdateGUI() -- Update GUI when entering combat.
    end)

    self:RegisterEvent("PLAYER_REGEN_ENABLED", function(...)
        self:UpdateGUI() -- Update GUI when leaving combat.

        -- Process combat deferred profile restoration
        if self.pendingSpecRestore then
            local profile = self.pendingSpecRestore
            self.pendingSpecRestore = nil
            self:UseProfile(profile)
        end
    end)

    self:RegisterEvent("PLAYER_UPDATE_RESTING", function(...)
        self:UpdateGUI() -- Update GUI when resting state changes.
    end)

    -- Register an event to handle changes in the player's active talent group (spec).
    self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", function(...)
        -- Cancel any existing timer for spec changes.
        if self.specTimer then
            self:CancelTimer(self.specTimer)
        end

        -- Schedule a new timer to handle spec changes.
        self.specTimer = self:ScheduleTimer(function()
            self.specTimer = nil

            -- Create a unique identifier for the player using their name, realm, and current spec.
            local player = UnitName("player") .. "-" .. GetRealmName()
            local spec = (type(GetSpecialization) == "function" and GetSpecialization() and type(GetSpecializationInfo) == "function" and GetSpecializationInfo(GetSpecialization())) or 0

            -- If the spec has changed or is new, update the previous spec and load the favorite profile for the current spec.
            if not self.prevSpec or self.prevSpec ~= spec then
                self.prevSpec = spec

                -- Guard: only iterate profiles when AceDB is fully initialized.
                local list = self.db and self.db.profile and self.db.profile.list
                if list then
                    for _, profile in pairs(list) do
                        if profile.fav and profile.fav[player .. "-" .. spec] then
                            if InCombatLockdown() then
                                self.pendingSpecRestore = profile
                            else
                                self:UseProfile(profile)
                            end
                            break
                        end
                    end
                end
            end
        end, 0.1)

        self:UpdateGUI() -- Update GUI after handling the spec change.
    end)

    -- Register events to track when the player's spells, equipment, or talents change.
    self:RegisterEvent("SPELLS_CHANGED", "InvalidateCache")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "InvalidateCache")
    self:RegisterEvent("TRAIT_CONFIG_UPDATED", "InvalidateCache")
    self:RegisterEvent("BAG_UPDATE", "InvalidateCache")
    self:RegisterEvent("PET_JOURNAL_LIST_UPDATE", "InvalidateCache")

    -- Register an event to handle aura changes on the player.
    self:RegisterEvent("UNIT_AURA", function(event, target)
        if target == "player" then
            -- Cancel any existing timer for aura updates.
            if self.auraTimer then
                self:CancelTimer(self.auraTimer)
            end

            -- Schedule a new timer to check auras.
            self.auraTimer = self:ScheduleTimer(function()
                self.auraTimer = nil

                -- Check all auras on the player to see if any match the specified spell IDs.
                local checkAura = {
                    ABP_TOME_OF_CLEAR_MIND_SPELL_ID,
                    ABP_TOME_OF_TRANQUIL_MIND_SPELL_ID,
                    ABP_DUNGEON_PREPARE_SPELL_ID,
                }

                local state = false
                if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    -- Modern Retail/Classic API
                    if C_UnitAuras.GetPlayerAuraBySpellID(checkAura[1]) or 
                       C_UnitAuras.GetPlayerAuraBySpellID(checkAura[2]) or 
                       C_UnitAuras.GetPlayerAuraBySpellID(checkAura[3]) then
                        state = true
                    end
                elseif AuraUtil and AuraUtil.ForEachAura then
                    -- Safe iteration via AuraUtil without deprecated UnitAura
                    AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
                        if aura and (aura.spellId == checkAura[1] or aura.spellId == checkAura[2] or aura.spellId == checkAura[3]) then
                            state = true
                            return true -- Stop iteration
                        end
                    end, true)
                end

                -- If the aura state has changed, update the stored state and refresh the GUI.
                if state ~= self.auraState then
                    self.auraState = state
                    self:UpdateGUI()
                end
            end, 0.1)
        end
    end)
end


-- Parses a command string to extract the first argument and the remaining message.
-- This function is used to split a message into the command (arg) and the remaining text.
-- It returns the first argument and the rest of the message if available.
function addon:ParseArgs(message)
    -- Extract the first argument and the position where it ends in the message string.
    local arg, pos = self:GetArgs(message, 1, 1)

    if arg then  -- If an argument is found
        if pos <= #message then  -- Check if there is remaining text after the first argument
            return arg, message:sub(pos)  -- Return the first argument and the remaining message.
        else
            return arg  -- Return only the first argument if there is no remaining text.
        end
    end
end


-- This function handles chat commands related to the addon.
-- It supports commands to list, save, delete, and use profiles.
function addon:OnChatCommand(message)
    -- Parse the command and parameter from the message.
    local cmd, param = self:ParseArgs(message)

    -- If no command is provided, print usage or open config.
    if not cmd or cmd == "" or cmd == "help" then
        self:Printf("Usage: /abp [list | save <name> | load <name> | delete <name> | config | gui]")
        return
    end

    -- Open settings panel or toggle UI
    if cmd == "config" or cmd == "options" or cmd == "opt" then
        self:OpenOptions()
        return
    elseif cmd == "gui" or cmd == "ui" then
        if not InCombatLockdown() then
            ToggleCharacter("PaperDollFrame")
        end
        return
    end

    -- Handle the "list" or "ls" command, which lists all saved profiles.
    if cmd == "list" or cmd == "ls" then
        local list = {} -- Initialize an empty list to store profile names.

        -- Retrieve and format each profile's name and class color for display.
        local profiles = { self:GetProfiles() }
        for _, profile in ipairs(profiles) do
            local colorStr = (profile.class and RAID_CLASS_COLORS[profile.class] and RAID_CLASS_COLORS[profile.class].colorStr) or "ffffffff"
            table.insert(list, string.format("|c%s%s|r", colorStr, profile.name))
        end

        -- If there are profiles, print them; otherwise, print a message saying the list is empty.
        if #list > 0 then
            self:Printf(L.msg_profile_list, strjoin(", ", unpack(list)))
        else
            self:Printf(L.msg_profile_list_empty)
        end

    -- Handle the "save" or "sv" command, which saves the current state to a profile.
    elseif cmd == "save" or cmd == "sv" then
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
            self:Printf(ERR_CLIENT_LOCKED_OUT)
            return
        end
        if param then
            -- Check if the profile already exists.
            local profile = self:GetProfiles(param, true)

            if profile then
                -- If the profile exists, update it.
                self:UpdateProfile(profile)
            else
                -- If the profile doesn't exist, create a new one.
                self:SaveProfile(param)
            end
        end

    -- Handle the "delete", "del", "remove", or "rm" command, which deletes a profile.
    elseif cmd == "delete" or cmd == "del" or cmd == "remove" or cmd == "rm" then
        if param then
            -- Check if the profile exists.
            local profile = self:GetProfiles(param, true)

            if profile then
                -- If the profile exists, delete it.
                self:DeleteProfile(profile.name)
            else
                -- If the profile doesn't exist, print a message.
                self:Printf(L.msg_profile_not_exists, param)
            end
        end

    -- Handle the "use", "load", or "ld" command, which loads and uses a profile.
    elseif cmd == "use" or cmd == "load" or cmd == "ld" then
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
            self:Printf(ERR_CLIENT_LOCKED_OUT)
            return
        end
        if param then
            -- Check if the profile exists.
            local profile = self:GetProfiles(param, true)

            if profile then
                -- If the profile exists, use it.
                self:UseProfile(profile)
            else
                -- If the profile doesn't exist, print a message.
                self:Printf(L.msg_profile_not_exists, param)
            end
        end
    end
end


-- This function displays a tooltip anchored to a specified UI element.
-- The tooltip is only shown if the player is not in combat and if the tooltip is not already visible.
function addon:ShowTooltip(anchor)
    -- Check if the player is in combat or if the tooltip is already shown.
    -- Tooltips cannot be shown during combat lockdown.
    if not (InCombatLockdown() or (self.tooltip and self.tooltip:IsShown())) then
        -- Check if the tooltip is already acquired; if not, acquire a new tooltip instance.
        if not (qtip:IsAcquired(addonName) and self.tooltip) then
            -- Acquire a new tooltip with the addon name and set the number of columns to 2, with the first column left-aligned.
            ---@class CustomTooltip : LibQTip.Tooltip
            ---@field OnRelease fun(self: CustomTooltip)
            self.tooltip = qtip:Acquire(addonName, 2, "LEFT") ---@type CustomTooltip

            -- Set a function to clear the tooltip reference when it is released.
            self.tooltip.OnRelease = function()
                self.tooltip = nil
            end
        end

        -- If an anchor is provided, attach the tooltip to the anchor and set an auto-hide delay.
        if anchor then
            self.tooltip:SmartAnchorTo(anchor) -- Anchor the tooltip to the specified UI element.
            self.tooltip:SetAutoHideDelay(0.05, anchor) -- Set a slight delay before hiding the tooltip when the cursor leaves the anchor.
        end

        -- Update the contents of the tooltip with the relevant information.
        self:UpdateTooltip(self.tooltip)
    end
end


-- This function updates the content of the provided tooltip with a list of profiles.
-- It displays the profiles associated with the current player, indicating any issues with red text.
function addon:UpdateTooltip(tooltip)
    -- Clear the tooltip to ensure it's ready for new content.
    tooltip:Clear()

    -- Add the addon name as the header of the tooltip.
    local line = tooltip:AddHeader(ABP_ADDON_NAME)

    -- Retrieve the list of profiles associated with the addon.
    local profiles = { addon:GetProfiles() }

    -- Check if there are any profiles to display.
    if #profiles > 0 then
        -- Get the player's class to compare against profile classes.
        local class = select(2, UnitClass("player"))
        -- Create a cache to optimize performance when checking profiles.
        local cache = addon:MakeCache()

        -- Add a line indicating the start of the profile list.
        line = tooltip:AddLine(L.tooltip_list)
        -- Set the color of this line to gray.
        tooltip:SetCellTextColor(line, 1, GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)

        -- Iterate through each profile to add it to the tooltip.
        local profile
        for profile in table.s2k_values(profiles) do
            local line

            -- Initialize the profile name and default color (normal text color).
            local name = profile.name
            local color = NORMAL_FONT_COLOR

            -- -- If the profile's class does not match the player's class, use gray text color.  -- COMMENTED OUT AS THIS RESULTS IN RESTORE TAKING PLACE WHEN MOUSING OVER THE LDB BUTTON
            -- if profile.class ~= class then
                -- color = GRAY_FONT_COLOR
            -- else
                -- -- If the profile's class matches the player's, attempt to use the profile in a test mode.
                -- local fail, total = addon:UseProfile(profile, true, cache)
                -- if fail > 0 then
                    -- -- If there are failures, set the text color to red and append the fail/total count to the name.
                    -- color = RED_FONT_COLOR
                    -- name = name .. string.format(" (%d/%d)", fail, total)
                -- end
            -- end

            -- Add the profile to the tooltip with its icon (if it has one) or class icon.
            if profile.icon then
                line = tooltip:AddLine(string.format(
                    "  |T%s:14:14:0:0:32:32:0:32:0:32|t %s",
                    profile.icon, name
                ))
            else
                -- Use the class icon if no specific icon is provided.
                local coords = CLASS_ICON_TCOORDS[profile.class]
                line = tooltip:AddLine(string.format(
                    "  |TInterface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes:14:14:0:0:256:256:%d:%d:%d:%d|t %s",
                    coords[1] * 256, coords[2] * 256, coords[3] * 256, coords[4] * 256,
                    name
                ))
            end

            -- Set the text color of the current line to the determined color.
            tooltip:SetCellTextColor(line, 1, color.r, color.g, color.b)

            -- Add a click handler to each line to allow profiles to be loaded when clicked.
            tooltip:SetLineScript(line, "OnMouseUp", function()
                local fail, total = addon:UseProfile(profile, true, cache)

                -- If there are failures when applying the profile, show a confirmation popup.
                if fail > 0 then
                    if not self:ShowPopup("CONFIRM_USE_ACTION_BAR_PROFILE", fail, total, { name = profile.name }) then
                        -- If the popup cannot be shown, display an error message.
                        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
                    end
                else
                    -- If there are no failures, apply the profile directly.
                    addon:UseProfile(profile, false, cache)
                end
            end)
        end
    else
        -- If there are no profiles, add a line indicating that the list is empty.
        line = tooltip:AddLine(L.tooltip_list_empty)
        tooltip:SetCellTextColor(line, 1, GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
    end

    -- Add an empty line for spacing.
    tooltip:AddLine("")

    -- Update the tooltip to ensure it scrolls properly and then show it.
    tooltip:UpdateScrolling()
    tooltip:Show()
end


-- This function updates the graphical user interface (GUI) of the addon, ensuring that relevant UI elements are refreshed.
-- It schedules the update to happen after a short delay, allowing for multiple changes to be batched together.
function addon:UpdateGUI()
    -- If an update is already scheduled, cancel the previous timer to prevent multiple updates from overlapping.
    if self.updateTimer then
        self:CancelTimer(self.updateTimer)
    end

    -- Schedule the GUI update to occur after a short delay (0.1 seconds).
    self.updateTimer = self:ScheduleTimer(function()
        -- Once the timer expires, clear the reference to the update timer.
        self.updateTimer = nil

        -- If the PaperDollActionBarProfilesPane is available and visible, update its contents.
        if PaperDollActionBarProfilesPane and PaperDollActionBarProfilesPane:IsShown() then
            PaperDollActionBarProfilesPane:Update()
        end

        -- If the tooltip is currently shown, check if the player is in combat.
        if self.tooltip and self.tooltip:IsShown() then
            if InCombatLockdown() then
                -- Hide the tooltip if the player is in combat lockdown to avoid UI taint.
                self.tooltip:Hide()
            else
                -- Otherwise, refresh the tooltip's contents to ensure it displays the latest information.
                self:UpdateTooltip(self.tooltip)
            end
        end
    end, 0.1)
end


-- Constants defining flags for the Pet Journal filters: collected and not collected pets.
local PET_JOURNAL_FLAGS = { LE_PET_JOURNAL_FILTER_COLLECTED, LE_PET_JOURNAL_FILTER_NOT_COLLECTED }


-- This function saves the current state of the Pet Journal filters.
-- It captures the search text, flags, sources, and types currently set in the Pet Journal.
function addon:SavePetJournalFilters()
    -- Initialize a table to store the saved filter settings.
    local saved = { flag = {}, source = {}, type = {} }

    -- Save the current search filter text.
    saved.text = self:GetPetJournalSearchFilter()

    -- Save the state of the collected and not collected flags.
    local i
    for i in table.s2k_values(PET_JOURNAL_FLAGS) do
        saved.flag[i] = C_PetJournal.IsFilterChecked(i)
    end

    -- Save the state of the pet sources filters (e.g., quest, store, etc.).
    for i = 1, C_PetJournal.GetNumPetSources() do
        saved.source[i] = C_PetJournal.IsPetSourceChecked(i)
    end

    -- Save the state of the pet type filters (e.g., Beast, Humanoid, etc.).
    for i = 1, C_PetJournal.GetNumPetTypes() do
        saved.type[i] = C_PetJournal.IsPetTypeChecked(i)
    end

    -- Return the saved filter settings for later restoration.
    return saved
end


-- This function restores the Pet Journal filters from a previously saved state.
-- It applies the saved search text, flags, sources, and types back to the Pet Journal.
function addon:RestorePetJournalFilters(saved)
    -- Restore the search filter text.
    C_PetJournal.SetSearchFilter(saved.text)

    -- Restore the state of the collected and not collected flags.
    local i
    for i in table.s2k_values(PET_JOURNAL_FLAGS) do
        C_PetJournal.SetFilterChecked(i, saved.flag[i])
    end

    -- Restore the state of the pet sources filters.
    for i = 1, C_PetJournal.GetNumPetSources() do
        C_PetJournal.SetPetSourceChecked(i, saved.source[i])
    end

    -- Restore the state of the pet type filters.
    for i = 1, C_PetJournal.GetNumPetTypes() do
        C_PetJournal.SetPetTypeFilter(i, saved.type[i])
    end
end


-- Injects a custom tab into the PaperDoll sidebar in the character frame.
-- This function allows adding a new tab to the character pane alongside existing ones like "Stats" and "Titles."
function addon:InjectPaperDollSidebarTab(name, frame, icon, texCoords)
    if self.sidebarTabInjected then return end
    self.sidebarTabInjected = true

    local tabName = "ABPSidebarTab"
    local pane = _G[frame]

    if CharacterFrame and (CharacterFrame.ModeTabs or CharacterFrame.UpdateTabLayout) then
        -- WOW 11.0+ / Camelot (12.0) - Main Right Side Tab Injection
        -- Do not parent to CharacterFrame.ModeTabs as it is a ResizeLayoutFrame which
        -- will cause a "secret number value" taint when it tries to sort insecure children
        local parentFrame = CharacterFrame
        local btn = _G[tabName]
        if not btn then
            btn = CreateFrame("Button", tabName, parentFrame, "CharacterFrameModeSideTabTemplate")
        end
        btn.frameName = frame
        btn.tooltipText = name
        -- Do not set btn.iconTexture to a file path; 11.0+ expects an Atlas name and would show a magenta placeholder.
        -- btn.iconTexture = icon

        if btn.Icon then
            btn:SetChecked(false)
            -- Bypass Blizzard's broken atlas template completely by hiding the native icon and overlaying our own
            btn.Icon:Hide()
            btn.Icon:SetAlpha(0)
            
            if not btn.customIcon then
                btn.customIcon = btn:CreateTexture(nil, "OVERLAY")
                btn.customIcon:SetAllPoints(btn.Icon)
            end
            
            btn.customIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_Book_09")
            if texCoords then
                btn.customIcon:SetTexCoord(unpack(texCoords))
            else
                btn.customIcon:SetTexCoord(0, 1, 0, 1)
            end
            btn.customIcon:Show()
        end

        -- Removed table.insert into ModeTabs.Tabs!
        -- Inserting an insecure addon frame into a secure Blizzard table causes execution taint
        -- when Blizzard iterates over it and calls methods on it (e.g. during UpdateTabLayout).
        -- We handle positioning securely via hooksecurefunc("UpdateTabLayout") below instead.

        btn:Show()

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(name, 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        -- Removed nativeTab:HookScript("OnMouseDown") to eliminate taint risks.
        -- ShowSubFrame hook safely handles pane hiding when switching back to native tabs.

        hooksecurefunc(CharacterFrame, "ShowSubFrame", function(self, frameName)
            if frameName == frame then
                for _, subFrameName in pairs(CHARACTERFRAME_SUBFRAMES or {}) do
                    if _G[subFrameName] and subFrameName ~= "PaperDollFrame" then
                        _G[subFrameName]:Hide()
                    end
                end
                
                if PaperDollFrame then PaperDollFrame:Show() end
                if CharacterStatsPane then CharacterStatsPane:Hide() end
                if CharacterStatsPaneScrollBox then CharacterStatsPaneScrollBox:Hide() end
                if CharacterStatsPanePetScrollBox then CharacterStatsPanePetScrollBox:Hide() end
                if PaperDollSidebarTabs then PaperDollSidebarTabs:Hide() end
                if CharacterLevelText then CharacterLevelText:Hide() end
                
                if pane then
                    if CharacterFrameRightPaneHost then
                        pane:ClearAllPoints()
                        pane:SetParent(CharacterFrameRightPaneHost)
                        pane:SetPoint("TOPLEFT", CharacterFrameRightPaneHost, "TOPLEFT", 2, -22)
                        pane:SetPoint("BOTTOMRIGHT", CharacterFrameRightPaneHost, "BOTTOMRIGHT", -25, 2)
                    elseif CharacterFrame and CharacterFrame.InsetRight then
                        pane:ClearAllPoints()
                        pane:SetParent(CharacterFrame.InsetRight)
                        pane:SetPoint("TOPLEFT", CharacterFrame.InsetRight, "TOPLEFT", 2, -22)
                        pane:SetPoint("BOTTOMRIGHT", CharacterFrame.InsetRight, "BOTTOMRIGHT", -25, 2)
                    elseif CharacterStatsPane then
                        pane:ClearAllPoints()
                        pane:SetParent(CharacterStatsPane:GetParent())
                        pane:SetPoint("TOPLEFT", CharacterStatsPane, "TOPLEFT", 0, 0)
                        pane:SetPoint("BOTTOMRIGHT", CharacterStatsPane, "BOTTOMRIGHT", 0, 0)
                    end
                    pane:Show()
                end
            elseif pane and pane:IsShown() then
                pane:Hide()
                if frameName == "PaperDollFrame" then
                    if CharacterStatsPaneScrollBox then CharacterStatsPaneScrollBox:Show()
                    elseif CharacterStatsPane then CharacterStatsPane:Show() end
                    if PaperDollSidebarTabs then PaperDollSidebarTabs:Show() end
                    if CharacterLevelText then CharacterLevelText:Show() end
                end
            end
        end)

        if CharacterFrame.SetSelectedModeTabByFrame then
            hooksecurefunc(CharacterFrame, "SetSelectedModeTabByFrame", function(self, frameName)
                if btn and btn.SetChecked then
                    btn:SetChecked(frameName == frame)
                end
            end)
        end

        hooksecurefunc(CharacterFrame, "UpdateTitle", function(self)
            if self.activeSubframe == frame then
                self:SetTitle(name)
            end
        end)

        -- Deferred re-anchor: after Blizzard's UpdateTabLayout places our btn
        -- (now in ModeTabs.Tabs), wait one frame so Outfitter's hook has also
        -- run, then re-anchor btn below the lowest visible child of ModeTabs
        -- to guarantee we sit below any other addon tabs.
        hooksecurefunc(CharacterFrame, "UpdateTabLayout", function(self)
            if not btn then return end
            C_Timer.After(0, function()
                if not btn or not self.ModeTabs then return end

                local nativeTabsSet = {}
                if self.ModeTabs.Tabs then
                    for _, t in ipairs(self.ModeTabs.Tabs) do
                        nativeTabsSet[t] = true
                    end
                end

                local customTabs = {}
                for _, child in ipairs({ self.ModeTabs:GetChildren() }) do
                    -- Find any Button children that aren't in the native Tabs array and aren't us
                    if child:IsObjectType("Button") and child:IsShown() and not nativeTabsSet[child] and child ~= btn then
                        table.insert(customTabs, child)
                    end
                end

                btn:ClearAllPoints()
                if #customTabs > 0 then
                    -- If there are other custom tabs (like Outfitter), anchor below the last one found
                    btn:SetPoint("TOPLEFT", customTabs[#customTabs], "BOTTOMLEFT", 0, -2)
                elseif self.ModeTabs.Tabs and #self.ModeTabs.Tabs > 0 then
                    -- Otherwise, anchor below the last native tab
                    local lastNativeTab = self.ModeTabs.Tabs[#self.ModeTabs.Tabs]
                    btn:SetPoint("TOPLEFT", lastNativeTab, "BOTTOMLEFT", 0, -2)
                end
            end)
        end)

        -- Do NOT call CharacterFrame:UpdateTabLayout() manually!
        -- Calling it from insecure code taints the ResizeLayoutFrame (ModeTabs) and causes "secret number value" comparisons to fail.
        -- We will manually trigger our layout logic once instead.
        if CharacterFrame.ModeTabs then
            C_Timer.After(0.1, function()
                if not btn then return end
                local nativeTabsSet = {}
                if CharacterFrame.ModeTabs.Tabs then
                    for _, t in ipairs(CharacterFrame.ModeTabs.Tabs) do
                        nativeTabsSet[t] = true
                    end
                end

                local customTabs = {}
                for _, child in ipairs({ CharacterFrame.ModeTabs:GetChildren() }) do
                    if child:IsObjectType("Button") and child:IsShown() and not nativeTabsSet[child] and child ~= btn then
                        table.insert(customTabs, child)
                    end
                end

                btn:ClearAllPoints()
                if #customTabs > 0 then
                    btn:SetPoint("TOPLEFT", customTabs[#customTabs], "BOTTOMLEFT", 0, -2)
                elseif CharacterFrame.ModeTabs.Tabs and #CharacterFrame.ModeTabs.Tabs > 0 then
                    local lastNativeTab = CharacterFrame.ModeTabs.Tabs[#CharacterFrame.ModeTabs.Tabs]
                    btn:SetPoint("TOPLEFT", lastNativeTab, "BOTTOMLEFT", 0, -2)
                end
            end)
        end
        
        local function OnTabClicked()
            if CharacterFrame.SetSelectedModeTabByFrame then
                CharacterFrame:SetSelectedModeTabByFrame(frame)
            elseif CharacterFrame.SelectTab then
                CharacterFrame:SelectTab(btn)
            end
            if CharacterFrame.ShowSubFrame then
                CharacterFrame:ShowSubFrame(frame)
            end
        end

        if type(btn.SetCustomOnMouseUpHandler) == "function" then
            btn:SetCustomOnMouseUpHandler(OnTabClicked)
        else
            btn:SetScript("OnClick", OnTabClicked)
        end

    elseif PAPERDOLL_SIDEBARS and PaperDollSidebarTabs then
        -- Classic / Older Retail (Pre-11.0) Logic
        PAPERDOLL_SIDEBARS[0] = {
            name = name,
            icon = icon,
            texCoords = texCoords
        }

        local btn = _G[tabName]
        if not btn then
            btn = CreateFrame(
                "Button", tabName, PaperDollSidebarTabs,
                "PaperDollSidebarTabTemplate", 0
            )
        end

        PAPERDOLL_SIDEBARS[0] = nil

        if btn.Icon then
            btn.Icon:SetTexture(icon)
            if texCoords then btn.Icon:SetTexCoord(unpack(texCoords)) end
        end
        btn.tooltipText = name

        btn:SetScript("OnClick", function(self)
            if pane and pane:IsShown() then
                pane:Hide()
                if PaperDollSidebarTab1 then PaperDollSidebarTab1:Click() end
            else
                if type(PaperDollFrame_SetSidebar) == "function" and
                   PAPERDOLL_SIDEBARS and PAPERDOLL_SIDEBARS[1] then
                    PaperDollFrame_SetSidebar(PaperDollFrame, 1)
                elseif CharacterFrame and type(CharacterFrame.Expand) == "function" then
                    CharacterFrame:Expand()
                end

                for i = 1, #PAPERDOLL_SIDEBARS do
                    local nativeInfo = PAPERDOLL_SIDEBARS[i]
                    if nativeInfo and nativeInfo.frame then
                        local nativeFrame = type(nativeInfo.frame) == "string" and _G[nativeInfo.frame] or nativeInfo.frame
                        if nativeFrame and nativeFrame.Hide then
                            nativeFrame:Hide()
                        end
                    end
                    local nativeTab = _G["PaperDollSidebarTab"..i]
                    if nativeTab then
                        if nativeTab.Hider then nativeTab.Hider:Show() end
                        if nativeTab.Highlight then nativeTab.Highlight:Show() end
                    end
                end

                if pane and pane.Show then
                    if CharacterFrameInsetRight then
                        pane:ClearAllPoints()
                        pane:SetParent(CharacterFrameInsetRight)
                        pane:SetPoint("TOPLEFT", CharacterFrameInsetRight, "TOPLEFT", 4, -4)
                        pane:SetPoint("BOTTOMRIGHT", CharacterFrameInsetRight, "BOTTOMRIGHT", -4, 4)
                    end
                    
                    if CharacterStatsPane then CharacterStatsPane:Hide() end
                    if PaperDollTitlesPane then PaperDollTitlesPane:Hide() end
                    if PaperDollEquipmentManagerPane then PaperDollEquipmentManagerPane:Hide() end

                    pane:Show()
                end
                if self.Hider then self.Hider:Hide() end
                if self.Highlight then self.Highlight:Hide() end
            end
        end)
        
        for i = 1, #PAPERDOLL_SIDEBARS do
            local nativeTab = _G["PaperDollSidebarTab"..i]
            if nativeTab then
                nativeTab:HookScript("OnClick", function()
                    if pane and pane:IsShown() then
                        pane:Hide()
                    end
                    if btn.Hider then btn.Hider:Show() end
                    if btn.Highlight then btn.Highlight:Show() end
                end)
            end
        end

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(name, 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        self:LineUpPaperDollSidebarTabs()

        if not self.hasHookedSetLevel and type(PaperDollFrame_SetLevel) == "function" and hooksecurefunc then
            self.hasHookedSetLevel = true
            hooksecurefunc("PaperDollFrame_SetLevel", function(...)
                local nativeCount = 0
                local tabIdx = 1
                while _G["PaperDollSidebarTab" .. tabIdx] do
                    nativeCount = nativeCount + 1
                    tabIdx = tabIdx + 1
                end
                local totalChildren = PaperDollSidebarTabs and select("#", PaperDollSidebarTabs:GetChildren()) or 0
                local extra = math.max(0, totalChildren - nativeCount)
                if extra == 0 then extra = 1 end

                if CharacterFrameInsetRight and CharacterFrameInsetRight:IsVisible() and CharacterLevelText then
                    for index = 1, CharacterLevelText:GetNumPoints() do
                        local point, relTo, relPoint, x, y = CharacterLevelText:GetPoint(index)
                        if point == "CENTER" then
                            if not CharacterLevelText.abpOriginalX then
                                CharacterLevelText.abpOriginalX = x
                            end
                            CharacterLevelText:SetPoint(
                                point, relTo, relPoint,
                                CharacterLevelText.abpOriginalX - (20 + 10 * extra), y
                            )
                        end
                    end
                end
            end)
        end
    end
end


-- Aligns the PaperDoll sidebar tabs on the character frame.
-- Collects ALL buttons parented to PaperDollSidebarTabs so that custom tabs
-- from other addons (e.g. Outfitter's OutfitterSidebarTab) are included in
-- the lineup and never overlap with ABPSidebarTab.
function addon:LineUpPaperDollSidebarTabs()
    if not PaperDollSidebarTabs then return end
    
    -- In Camelot/12.0, if we injected into the vertical ModeTabs,
    -- ModeTabs handles its own layout via UpdateTabLayout. We should NOT
    -- try to line up with the horizontal PaperDollSidebarTabs.
    if CharacterFrame and (CharacterFrame.ModeTabs or CharacterFrame.UpdateTabLayout) then return end

    -- Step 1: collect Blizzard native tabs (PaperDollSidebarTab1, Tab2 ...)
    local nativeTabs = {}
    local tabIdx = 1
    while _G["PaperDollSidebarTab" .. tabIdx] do
        table.insert(nativeTabs, _G["PaperDollSidebarTab" .. tabIdx])
        tabIdx = tabIdx + 1
    end
    local nativeCount = #nativeTabs

    -- Step 2: collect every other Button child of PaperDollSidebarTabs that
    -- is NOT a native Blizzard tab.  This catches OutfitterSidebarTab,
    -- ABPSidebarTab and any future addon tab regardless of its name.
    local nativeSet = {}
    for _, t in ipairs(nativeTabs) do nativeSet[t] = true end

    local customTabs = {}
    -- Prefer ABPSidebarTab last so it is always the rightmost custom tab
    local abpTab = _G["ABPSidebarTab"]
    local child = PaperDollSidebarTabs:GetChildren()
    -- GetChildren() may return multiple values; iterate via select
    local children = { PaperDollSidebarTabs:GetChildren() }
    for _, child in ipairs(children) do
        if not nativeSet[child] and child ~= abpTab then
            table.insert(customTabs, child)
        end
    end
    if abpTab then
        table.insert(customTabs, abpTab)
    end

    -- Step 3: merge: natives first, then other addons' custom tabs, ABP last
    local allTabs = {}
    for _, t in ipairs(nativeTabs)  do table.insert(allTabs, t) end
    for _, t in ipairs(customTabs)  do table.insert(allTabs, t) end

    if #allTabs == 0 then return end

    -- Step 4: compute how many "extra" (non-Blizzard) tabs exist
    local extra = #allTabs - nativeCount
    if extra < 0 then extra = 0 end

    -- Step 5: right-to-left anchor chain.
    -- The rightmost tab gets BOTTOMRIGHT; every tab to its left chains off it.
    local prev
    for i = #allTabs, 1, -1 do
        local currentTab = allTabs[i]
        currentTab:ClearAllPoints()
        if not prev then
            -- rightmost tab: shift left of the frame edge based on extra count
            currentTab:SetPoint("BOTTOMRIGHT", PaperDollSidebarTabs, "BOTTOMRIGHT",
                (extra < 2 and -20) or (extra < 3 and -10) or 0, 0)
        else
            currentTab:SetPoint("RIGHT", prev, "LEFT", -4, 0)
        end
        prev = currentTab
    end
end


-- Encodes special characters in a string to make it safe for use in links.
-- This function replaces characters that could break the link format with a hexadecimal representation.
function addon:EncodeLink(data)
    return data:gsub(".", function(x)
        return ((x:byte() < 32 or x:byte() == 127 or x == "|" or x == ":" or x == "[" or x == "]" or x == "~")
            and string.format("~%02x", x:byte())) or x
    end)
end


-- Decodes a previously encoded link string back to its original format.
-- This function reverses the encoding process by converting hexadecimal representations back to characters.
function addon:DecodeLink(data)
    return data:gsub("~[0-9A-Fa-f][0-9A-Fa-f]", function(x)
        return string.char(tonumber(x:sub(2), 16))
    end)
end


-- Prepares a macro string by cleaning up unnecessary whitespace.
-- This function trims leading and trailing spaces and removes excess spaces around line breaks.
function addon:PackMacro(macro)
    return macro:gsub("^%s+", ""):gsub("%s+\n", "\n"):gsub("\n%s+", "\n"):gsub("%s+$", ""):sub(1)
end


-- Ignore List when checking if need to clear a certain slot
addon.ignoreList = {
    --["Hearthstone"] = true,
    -- Add any spell names as needed
}
