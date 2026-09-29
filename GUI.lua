local addonName, addon = ...
ABP = _G.ABP or addon or ABP or {}
local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

-- Localize globals for performance
local ipairs, select, unpack = ipairs, select, unpack
local UnitClass, UnitName, GetRealmName, GetSpecialization, GetSpecializationInfo = UnitClass, UnitName, GetRealmName, GetSpecialization, GetSpecializationInfo
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame
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

local function GetCurrentSpecID()
    if type(GetSpecialization) == "function" then
        local specIndex = GetSpecialization()
        if specIndex and type(GetSpecializationInfo) == "function" then
            local specID = GetSpecializationInfo(specIndex)
            if specID then
                return specID
            end
        end
    end
    return 0
end

-- This function initializes the main frame for the GUI, setting up the scroll bar, frame levels, and buttons.
function frame:OnInitialize()
    -- Ensure proper parenting to PaperDollFrame if available
    if PaperDollFrame and self:GetParent() ~= PaperDollFrame then
        self:SetParent(PaperDollFrame)
    end

    local insetRight = CharacterFrameInsetRight or _G["CharacterFrameInsetRight"]
    if insetRight and insetRight.GetFrameLevel then
        self:SetFrameLevel(insetRight:GetFrameLevel() + 1)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", insetRight, "TOPLEFT", 4, -4)
        self:SetPoint("BOTTOMRIGHT", insetRight, "BOTTOMRIGHT", -4, 4)
    else
        self:SetFrameLevel(2)
    end

    -- Prevent the scrollbar from hiding when there are fewer items than it can display
    if self.scrollBar then
        self.scrollBar.doNotHide = 1
    end

    -- Ensure the "Use Profile" and "Save Profile" buttons are displayed above the main frame
    if self.UseProfile then
        self.UseProfile:SetFrameLevel(self:GetFrameLevel() + 3)
    end
    if self.SaveProfile then
        self.SaveProfile:SetFrameLevel(self:GetFrameLevel() + 3)
    end

    -- Initialize the scroll frame with hybrid scrolling capabilities
    HybridScrollFrame_OnLoad(self)
    self.update = function() self:Update() end

    -- Create buttons for the scroll frame using the "ActionBarProfileButtonTemplate"
    local searchH = (self.SearchBox and self.SearchBox:GetHeight()) or 20
    local useH = (self.UseProfile and self.UseProfile:GetHeight()) or 22
    HybridScrollFrame_CreateButtons(self, "ActionBarProfileButtonTemplate", 2, -(searchH + useH + 8))
end


-- This function is called when the frame is shown, triggering an update to refresh the display.
-- GUI function that gets called when the "Action Bars" tab is shown
function frame:OnShow()
    -- Refresh the list of profiles
    self:Update()
end


-- This function is called when the frame is hidden, ensuring the "Save Dialog" is also hidden.
function frame:OnHide()
    if PaperDollActionBarProfilesSaveDialog then
        PaperDollActionBarProfilesSaveDialog:Hide()
    end
end


local playerClass
local updateThrottle = 0

-- This function is called to update the frame's content, particularly the state of the buttons.
function frame:OnUpdate(elapsed)
    updateThrottle = updateThrottle + (elapsed or 0.05)
    if updateThrottle < 0.05 then return end
    updateThrottle = 0

    if not playerClass then
        playerClass = select(2, UnitClass("player"))
    end

    local buttons = self.buttons
    if not buttons then return end

    -- Resize the ScrollChild dynamically so the buttons can stretch to fill the pane's full width.
    if self.scrollChild then
        self.scrollChild:SetWidth(self:GetWidth())
    end

    -- Iterate over each button using indexed access to avoid allocating closure objects
    for i = 1, #buttons do
        local button = buttons[i]
        
        -- Also force the button to stretch if HybridScrollFrame ignored our XML anchors
        button:SetWidth(self:GetWidth())
        
        -- Check if the button is currently being hovered over by the mouse
        if button:IsMouseOver() then
            -- Show or hide the favorite, delete, and edit buttons based on the button's state
            if button.name then
                if button.UnfavButton:IsShown() or button.class ~= playerClass then
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
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        return
    end

    if button.name then
        -- When a profile is double-clicked, first handle it as a single click
        self:OnProfileClick(button)
        -- Then immediately try to use the selected profile
        self:OnUseClick()
    end
end


-- This function attempts to use the currently selected profile.
function frame:OnUseClick()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        return
    end

    if not self.selected then return end

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
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        return
    end

    if not self.selected then
        -- If no profile is selected, open the save dialog to create a new profile
        PaperDollActionBarProfilesSaveDialog:SetProfile(nil)
        PaperDollActionBarProfilesSaveDialog:Show()
        return
    end

    -- Show a confirmation popup before saving the profile.
    -- Confirmation is handled in Dialogs.lua OnSaveConfirm.
    if not addon:ShowPopup("CONFIRM_SAVE_ACTION_BAR_PROFILE", self.selected, nil, { name = self.selected }) then
        UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
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
    local player = UnitName("player") .. "-" .. (GetRealmName() or "")
    -- Get the current specialization of the player.
    local spec = GetCurrentSpecID()

    -- Set the clicked profile as the default for the player's current spec.
    addon:SetDefault(button.name, player .. "-" .. spec)
end


-- This function handles the logic when the "unfavorite" button is clicked on a profile.
function frame:OnUnfavClick(button)
    -- Get the current player's name and realm to create a unique identifier.
    local player = UnitName("player") .. "-" .. (GetRealmName() or "")
    -- Get the current specialization of the player.
    local spec = GetCurrentSpecID()

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
        if profile and profile.name and (searchText == "" or profile.name:lower():find(searchText, 1, true)) then
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
    local player = UnitName("player") .. "-" .. (GetRealmName() or "")
    local class = select(2, UnitClass("player"))
    local spec = GetCurrentSpecID()

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
