local addonName, addon = ...
ABP = ABP or {}
local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

-- Localize globals for performance
local ipairs, select, unpack = ipairs, select, unpack
local UnitClass, UnitName, GetRealmName, GetSpecialization, GetSpecializationInfo = UnitClass, UnitName, GetRealmName, GetSpecialization, GetSpecializationInfo
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame
local CharacterFrameInsetRight = CharacterFrameInsetRight
local HybridScrollFrame_OnLoad, HybridScrollFrame_CreateButtons, HybridScrollFrame_Update, HybridScrollFrame_GetOffset = HybridScrollFrame_OnLoad, HybridScrollFrame_CreateButtons, HybridScrollFrame_Update, HybridScrollFrame_GetOffset
local UIErrorsFrame = UIErrorsFrame
local ERR_CLIENT_LOCKED_OUT = ERR_CLIENT_LOCKED_OUT
local GREEN_FONT_COLOR, NORMAL_FONT_COLOR, GRAY_FONT_COLOR, RED_FONT_COLOR = GREEN_FONT_COLOR, NORMAL_FONT_COLOR, GRAY_FONT_COLOR, RED_FONT_COLOR
local CLASS_ICON_TCOORDS = CLASS_ICON_TCOORDS

---@class frame
local frame = PaperDollActionBarProfilesPane

-- Initialize the scrollBar field if it's expected to be part of frame
frame.scrollBar = frame.scrollBar or CreateFrame("ScrollFrame", nil, frame)

local ACTION_BAR_PROFILE_BUTTON_HEIGHT = 44

-- This function initializes the main frame for the GUI, setting up the scroll bar, frame levels, and buttons.
function frame:OnInitialize()
    -- Prevent the scrollbar from hiding when there are fewer items than it can display
    self.scrollBar.doNotHide = 1

    -- Set the frame level to be above the Character Frame Inset Right
    self:SetFrameLevel(CharacterFrameInsetRight:GetFrameLevel() + 1)

    -- Ensure the "Use Profile" and "Save Profile" buttons are displayed above the main frame
    self.UseProfile:SetFrameLevel(self:GetFrameLevel() + 3)
    self.SaveProfile:SetFrameLevel(self:GetFrameLevel() + 3)

    -- Initialize the scroll frame with hybrid scrolling capabilities
    HybridScrollFrame_OnLoad(self)
    self.update = function() self:Update() end

    -- Create buttons for the scroll frame using the "ActionBarProfileButtonTemplate"
    -- The buttons are offset by the height of the Search Box and Action buttons plus margins
    HybridScrollFrame_CreateButtons(self, "ActionBarProfileButtonTemplate", 2, -(self.SearchBox:GetHeight() + self.UseProfile:GetHeight() + 8))
end


-- This function is called when the frame is shown, triggering an update to refresh the display.
-- GUI function that gets called when the "Action Bars" tab is shown
function frame:OnShow()
    -- Refresh the list of profiles
    self:Update()

    -- -- Attempt to use the currently selected profile -- THIS IS BEING COMMENTED OUT AS PROFILE WOULD BE USED PREMATURELY WHEN IT MAY NOT HAVE BEEN WARRANTED!
    -- local selectedProfile = self.selectedProfile
    -- if selectedProfile then
        -- addon:UseProfile(selectedProfile)
    -- else
        -- print("No profile selected")
    -- end
end


-- This function is called when the frame is hidden, ensuring the "Save Dialog" is also hidden.
function frame:OnHide()
    PaperDollActionBarProfilesSaveDialog:Hide()
end


-- This function is called to update the frame's content, particularly the state of the buttons.
function frame:OnUpdate()
    local class = select(2, UnitClass("player"))  -- Get the player's class

    -- Ensure that self.buttons is initialized
    self.buttons = self.buttons or {}

    -- Iterate over each button in the scroll frame
    local button
    for button in table.s2k_values(self.buttons) do
        -- Check if the button is currently being hovered over by the mouse
        if button:IsMouseOver() then
            -- Show or hide the favorite, delete, and edit buttons based on the button's state
            if button.name then
                if button.UnfavButton:IsShown() or button.class ~= class then
                    button.FavButton:Hide()
                else
                    button.FavButton:Show()
                end

                button.DeleteButton:Show()
                button.EditButton:Show()
            else
                button.FavButton:Hide()
                button.DeleteButton:Hide()
                button.EditButton:Hide()
            end

            -- Show the highlight bar to indicate the button is being hovered over
            button.HighlightBar:Show()
        else
            -- Hide all action buttons and the highlight bar when the mouse is not over the button
            button.FavButton:Hide()
            button.DeleteButton:Hide()
            button.EditButton:Hide()

            button.HighlightBar:Hide()
        end
    end
end


-- This function handles what happens when a profile button is clicked.
function frame:OnProfileClick(button)
    if button.name then
        -- If the button has a profile name associated with it, set it as the selected profile
        self.selected = button.name
        -- Update the UI to reflect the selected profile
        self:Update()

        -- Hide the save dialog if a profile is selected
        PaperDollActionBarProfilesSaveDialog:Hide()
    else
        -- If the button has no profile name, clear the selection
        self.selected = nil
        -- Update the UI to reflect no profile being selected
        self:Update()

        -- Open the save dialog with no profile pre-selected, allowing the user to create a new profile
        PaperDollActionBarProfilesSaveDialog:SetProfile(nil)
        PaperDollActionBarProfilesSaveDialog:Show()
    end
end


-- This function handles what happens when a profile button is double-clicked.
function frame:OnProfileDoubleClick(button)
    if button.name then
        -- When a profile is double-clicked, first handle it as a single click
        self:OnProfileClick(button)
        -- Then immediately try to use the selected profile
        self:OnUseClick()
    end
end


-- This function attempts to use the currently selected profile.
function frame:OnUseClick()
    -- Create a cache of the current state for efficiency
    local cache = addon:MakeCache()

    -- Perform a check to see if there will be any issues applying the profile
    local fail, total = addon:UseProfile(self.selected, true, cache)

    if fail > 0 then
        -- If there are mismatches or issues, show a confirmation popup
        if not addon:ShowPopup("CONFIRM_USE_ACTION_BAR_PROFILE", fail, total, { name = self.selected }) then
            -- Display an error message if the client is locked out (e.g., in combat)
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        end
    else
        -- If no issues, apply the profile directly
        addon:UseProfile(self.selected, false, cache)
    end
end


-- This function handles the logic when the delete button is clicked on a profile.
function frame:OnDeleteClick(button)
    -- Show a confirmation popup before deleting the profile.
    -- If the client is locked out (e.g., during combat), display an error message instead.
    if not addon:ShowPopup("CONFIRM_DELETE_ACTION_BAR_PROFILE", button.name, nil, { name = button.name }) then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
    end
end


-- This function handles the logic when the save button is clicked.
function frame:OnSaveClick()
    -- Show a confirmation popup before saving the profile.
    -- If the client is locked out (e.g., during combat), display an error message instead.
    if not addon:ShowPopup("CONFIRM_SAVE_ACTION_BAR_PROFILE", self.selected, nil, { name = self.selected }) then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
    else
        -- Assuming `self.selected` is the profile name, we save the profile
        addon:SaveProfile(self.selected)
    end
end


-- This function handles the logic when the edit button is clicked on a profile.
function frame:OnEditClick(button)
    -- First, treat the edit click as a profile click to ensure the profile is selected.
    self:OnProfileClick(button)

    -- Set the save dialog to the profile being edited and display the dialog.
    PaperDollActionBarProfilesSaveDialog:SetProfile(button.name)
    PaperDollActionBarProfilesSaveDialog:Show()
end


-- This function handles the logic when the "favorite" button is clicked on a profile.
function frame:OnFavClick(button)
    -- Get the current player's name and realm to create a unique identifier.
    local player = UnitName("player") .. "-" .. GetRealmName()
    -- Get the current specialization of the player.
    local spec = GetSpecializationInfo(GetSpecialization())

    -- Set the clicked profile as the default for the player's current spec.
    addon:SetDefault(button.name, player .. "-" .. spec)
end


-- This function handles the logic when the "unfavorite" button is clicked on a profile.
function frame:OnUnfavClick(button)
    -- Get the current player's name and realm to create a unique identifier.
    local player = UnitName("player") .. "-" .. GetRealmName()
    -- Get the current specialization of the player.
    local spec = GetSpecializationInfo(GetSpecialization())

    -- Unset the clicked profile as the default for the player's current spec.
    addon:UnsetDefault(button.name, player .. "-" .. spec)
end


function frame:Update()
    -- Retrieve the list of profiles from the add-on.
	local allProfiles = { addon:GetProfiles() }
    local profiles = {}
    local searchText = self.SearchBox:GetText():lower()

    -- Filter profiles based on the search text
    for _, profile in ipairs(allProfiles) do
        if searchText == "" or profile.name:lower():find(searchText, 1, true) then
            table.insert(profiles, profile)
        end
    end

    local rows = #profiles + 1  -- The total number of rows, including the "New Profile" button.

    -- Update the scroll frame to accommodate the number of rows.
    -- Adjusting total height for the SearchBox and Buttons at the top.
    HybridScrollFrame_Update(self, rows * ACTION_BAR_PROFILE_BUTTON_HEIGHT + self.SearchBox:GetHeight() + self.UseProfile:GetHeight() + 20, self:GetHeight())

    -- Get the current scroll offset.
    local offset = HybridScrollFrame_GetOffset(self)

    -- Get the current player information.
    local player = UnitName("player") .. "-" .. GetRealmName()
    local class = select(2, UnitClass("player"))
    local spec = GetSpecializationInfo(GetSpecialization())

    -- Rebuild the cache only if it's marked as dirty (e.g., after an event update) or if it doesn't exist yet.
    if addon.cacheDirty or not self.cachedData then
        self.cachedData = addon:MakeCache()
        addon.cacheDirty = false
    end
    local cache = self.cachedData

    -- Save the currently selected profile, then reset the selected profile.
    local selected = self.selected
    self.selected = nil

    -- Loop through each button in the scroll frame.
    for i = 1, #self.buttons do
        local button = self.buttons[i]

        -- Check if the button corresponds to a profile or the "New Profile" button.
        if i + offset <= rows then
            if i + offset == 1 then
                -- This is the "New Profile" button.
                button.name = nil

                -- Set the button text and appearance for creating a new profile.
                button.text:SetText(L.gui_new_profile)
                button.text:SetTextColor(GREEN_FONT_COLOR.r, GREEN_FONT_COLOR.g, GREEN_FONT_COLOR.b)

                button.icon:SetTexture("Interface\\PaperDollInfoFrame\\Character-Plus")
                button.icon:SetTexCoord(0, 1, 0, 1)

                button.icon:SetSize(30, 30)
                button.icon:SetPoint("LEFT", 7, 0)

                button.SelectedBar:Hide()
                button.UnfavButton:Hide()
            else
                -- This is a regular profile button.
                local profile = profiles[i + offset - 1]

                -- Set the button's profile name and class.
                button.name = profile.name
                button.class = profile.class

                local text = profile.name
                local color = NORMAL_FONT_COLOR

                -- Adjust the text color based on whether the profile belongs to the current class.
                if profile.class ~= class then
                    color = GRAY_FONT_COLOR
                -- else
                    -- -- Simulate using the profile to check for any issues [if addon:UseProfile(profile, true, cache) is used, may result in the addon actually loading the Profile].
                    -- local fail, total = addon:CheckProfile(profile, cache)
                    -- if fail > 0 then
                        -- color = RED_FONT_COLOR
                        -- text = text .. string.format(" (%d/%d)", fail, total)
                    -- end
                end

                button.text:SetText(text)
                button.text:SetTextColor(color.r, color.g, color.b)

                -- Set the profile icon, using a class icon if none is specified.
                if profile.icon then
                    button.icon:SetTexture(profile.icon)
                    button.icon:SetTexCoord(0, 1, 0, 1)
                else
                    button.icon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
                    button.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[profile.class]))
                end

                button.icon:SetSize(36, 36)
                button.icon:SetPoint("LEFT", 4, 0)

                -- Highlight the currently selected profile.
                if selected and selected == profile.name then
                    button.SelectedBar:Show()
                    self.selected = profile.name
                else
                    button.SelectedBar:Hide()
                end

                -- Show the "Unfavorite" button if the profile is the default for the current spec.
                if addon:IsDefault(profile, player .. "-" .. spec) then
                    button.UnfavButton:Show()
                else
                    button.UnfavButton:Hide()
                end
            end

            -- Adjust background elements based on the button's position.
            if (i + offset) == 1 then
                button.BgTop:Show()
                button.BgMiddle:SetPoint("TOP", button.BgTop, "BOTTOM")
            else
                button.BgTop:Hide()
                button.BgMiddle:SetPoint("TOP")
            end

            if (i + offset) == rows then
                button.BgBottom:Show()
                button.BgMiddle:SetPoint("BOTTOM", button.BgBottom, "TOP")
            else
                button.BgBottom:Hide()
                button.BgMiddle:SetPoint("BOTTOM")
            end

            -- Apply a stripe texture to alternating rows for better visibility.
            if (i + offset) % 2 == 0 then
                button.Stripe:SetColorTexture(0.2, 0, 0.4)
                button.Stripe:SetAlpha(0.2)

                button.Stripe:Show()
            else
                button.Stripe:Hide()
            end

            -- Show and enable the button.
            button:Show()
            button:Enable()
        else
            -- Hide the button if it doesn't correspond to a profile or the "New Profile" button.
            button:Hide()
        end
    end

    -- Enable or disable the "Use Profile" and "Save Profile" buttons based on whether a profile is selected.
    if self.selected then
        if InCombatLockdown() then
            self.UseProfile:Disable()
        else
            self.UseProfile:Enable()
        end

        self.SaveProfile:Enable()
    else
        PaperDollActionBarProfilesSaveDialog:Hide()

        self.UseProfile:Disable()
        self.SaveProfile:Disable()
    end
end
