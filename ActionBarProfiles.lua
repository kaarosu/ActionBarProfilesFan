local addonName, addon = ...
_G.ABP = ABP
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

PaperDollActionBarProfilesPane = PaperDollActionBarProfilesPane or nil
local origGetPaperDollSideBarFrame
local ABP_tabNum

local CopyAttempts = 0

-- Overrides the default GetPaperDollSideBarFrame function to handle the custom ActionBarProfiles pane.
-- This function returns the custom pane for ActionBarProfiles if the specified index matches ABP_tabNum.
-- Otherwise, it calls the original function to retrieve the standard sidebar frame.
function ABP_GetPaperDollSideBarFrame(index)
    if index == ABP_tabNum then
        return PaperDollActionBarProfilesPane;  -- Return the custom ActionBarProfiles pane.
    else
        return origGetPaperDollSideBarFrame(index);  -- Return the original sidebar frame for other indexes.
    end
end


-- Clears the action slots on the second action bar (slots 13 to 24).
-- This function iterates through the specified action bar slots and clears each one.
function ClearBarTwo()
    for i = 13, 24 do
        addon:ClearSlot(i)  -- Clear each slot on the second action bar.
    end
end



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
    LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, self:GetOptions())
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, nil, nil, "general")
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, self.options.args.profiles.name, addonName, "profiles")

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
                --InterfaceOptionsFrame_OpenToCategory(addonName) -- Open options on right-click.
                Settings.OpenToCategory(addonName) -- Open options on right-click.
            else
                ToggleCharacter("PaperDollFrame") -- Toggle character frame on left-click.
            end
        end,
    })

    -- Register the minimap icon with the database settings.
    self.icon = LibStub("LibDBIcon-1.0")
    self.icon:Register(addonName, self.ldb, self.db.profile.minimap)

    -- Check and update existing profiles to include specID if missing
    for profileName, profile in pairs(self.db.profile.list) do
        if not profile.specID then
            profile.specID = GetSpecializationInfo(GetSpecialization())
            --print("Updated specID for profile: " .. profileName)
        end
    end

    -- Override the default GetPaperDollSideBarFrame function with a custom one.
    origGetPaperDollSideBarFrame = GetPaperDollSideBarFrame
    GetPaperDollSideBarFrame = ABP_GetPaperDollSideBarFrame

    -- If the character frame for ActionBarProfiles is present, inject a new tab and initialize related panes.
    if PaperDollActionBarProfilesPane then
        self:InjectPaperDollSidebarTab(
            L.charframe_tab, -- Localization for the tab label.
            "PaperDollActionBarProfilesPane", -- The frame name.
            "Interface\\AddOns\\ActionBarProfiles\\textures\\CharDollBtn", -- Texture for the tab icon.
            { 0, 0.515625, 0, 0.13671875 } -- Coordinates for the texture.
        )

        -- Initialize the profiles pane and save dialog.
        PaperDollActionBarProfilesPane:OnInitialize()
        PaperDollActionBarProfilesSaveDialog:OnInitialize()
    end

    -- Register events to update the GUI during combat, resting, or when the talent group changes.
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function(...)
        self:UpdateGUI() -- Update GUI when entering combat.
    end)

    self:RegisterEvent("PLAYER_REGEN_ENABLED", function(...)
        self:UpdateGUI() -- Update GUI when leaving combat.
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
            local spec = GetSpecializationInfo(GetSpecialization())

            -- If the spec has changed or is new, update the previous spec and load the favorite profile for the current spec.
            if not self.prevSpec or self.prevSpec ~= spec then
                self.prevSpec = spec

                -- Iterate through the profiles list to find and use the favorite profile for the current spec.
                local list = self.db.profile.list
                local profile

                for profile in table.s2k_values(list) do
                    if profile.fav and profile.fav[player .. "-" .. spec] then
                        self:UseProfile(profile)
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
                else
                    -- Fallback loop (Older clients)
                    local auraName, auraIcon, auraCount, auraType, auraDuration, auraExpiration, auraSource, auraIsStealable, auraNameplateShowPersonal, auraSpellId
                    for index = 1, 40 do
                        auraName, auraIcon, auraCount, auraType, auraDuration, auraExpiration, auraSource, auraIsStealable, auraNameplateShowPersonal, auraSpellId = UnitAura("player", index)
                        if auraSpellId and (auraSpellId == checkAura[1] or auraSpellId == checkAura[2] or auraSpellId == checkAura[3]) then
                            state = true
                            break
                        end
                        if not auraName then break end
                    end
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

    -- If no command is provided, exit the function.
    if not cmd then return end

    -- Handle the "list" or "ls" command, which lists all saved profiles.
    if cmd == "list" or cmd == "ls" then
        local list = {} -- Initialize an empty list to store profile names.

        -- Retrieve and format each profile's name and class color for display.
        local profile
        for profile in table.s2k_values({ self:GetProfiles() }) do
            table.insert(list, string.format("|c%s%s|r",
                RAID_CLASS_COLORS[profile.class].colorStr, profile.name
            ))
        end

        -- If there are profiles, print them; otherwise, print a message saying the list is empty.
        if #list > 0 then
            self:Printf(L.msg_profile_list, strjoin(", ", unpack(list)))
        else
            self:Printf(L.msg_profile_list_empty)
        end

    -- Handle the "save" or "sv" command, which saves the current state to a profile.
    elseif cmd == "save" or cmd == "sv" then
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
                    ABP:UseProfile(profile, false, cache)
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
    saved.text = C_PetJournal.GetSearchFilter()

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
    -- Calculate the next available tab index in the PAPERDOLL_SIDEBARS array.
    local tab = #PAPERDOLL_SIDEBARS + 1
    -- Store the tab number in a global variable for reference.
    ABP_tabNum = tab

    -- Insert the new tab's information (name, icon, texture coordinates) into the PAPERDOLL_SIDEBARS array.
    PAPERDOLL_SIDEBARS[tab] = { 
        name = name, 
        icon = icon, 
        texCoords = texCoords, 
        IsActive = function() return true end -- Function to determine if the tab is active (always true in this case).
    }

    -- Create a new button for the tab and assign it to the PaperDollSidebarTabs frame.
    CreateFrame(
        "Button", "PaperDollSidebarTab" .. tab, PaperDollSidebarTabs,
        "PaperDollSidebarTabTemplate", tab
    )

    -- Align all sidebar tabs, ensuring they are positioned correctly.
    self:LineUpPaperDollSidebarTabs()

    -- Override the PaperDollFrame_SetLevel function to adjust the position of the character level text.
    if not self.prevSetLevel then
        -- Save the original function reference to restore or extend its behavior.
        self.prevSetLevel = PaperDollFrame_SetLevel

        -- Replace the original PaperDollFrame_SetLevel with a custom function.
        PaperDollFrame_SetLevel = function(...)
            -- Call the original function first to maintain existing functionality.
            self.prevSetLevel(...)

            -- Calculate how many additional tabs have been added beyond the default number.
            local extra = #PAPERDOLL_SIDEBARS - ABP_DEFAULT_PAPERDOLL_NUM_TABS

            -- Adjust the position of the character level text if the right inset panel is visible.
            if CharacterFrameInsetRight:IsVisible() then
                local index
                for index = 1, CharacterLevelText:GetNumPoints() do
                    -- Get the current anchor point information of the character level text.
                    local point, relTo, relPoint, x, y = CharacterLevelText:GetPoint(index)

                    -- If the point is anchored to the center, adjust the X position to accommodate the extra tabs.
                    if point == "CENTER" then
                        CharacterLevelText:SetPoint(
                            point, relTo, relPoint,
                            x - (20 + 10 * extra), y
                        )
                    end
                end
            end
        end
    end
end


-- Aligns the PaperDoll sidebar tabs on the character frame.
-- This function repositions the tabs based on how many additional tabs have been added.
function addon:LineUpPaperDollSidebarTabs()
    -- Calculate how many extra tabs have been added beyond the default number.
    local extra = #PAPERDOLL_SIDEBARS - ABP_DEFAULT_PAPERDOLL_NUM_TABS
    local prev  -- Variable to store the previous tab in the loop for positioning.

    -- Iterate through all tabs in the PAPERDOLL_SIDEBARS array.
    local index
    for index = 1, #PAPERDOLL_SIDEBARS do
        -- Get the current tab by its global name.
        local tab = _G["PaperDollSidebarTab" .. index]
        if tab then
            -- Clear the existing anchor points for the tab.
            tab:ClearAllPoints()

            -- Set the position of the current tab based on the number of extra tabs.
            tab:SetPoint("BOTTOMRIGHT", (extra < 2 and -20) or (extra < 3 and -10) or 0, 0)

            -- If there is a previous tab, position it to the left of the current tab.
            if prev then
                prev:ClearAllPoints()
                prev:SetPoint("RIGHT", tab, "LEFT", -4, 0)
            end

            -- Update the prev variable to the current tab for the next iteration.
            prev = tab
        end
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
