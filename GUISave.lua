local addonName, addon = ...

local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

-- Ensure PaperDollActionBarProfilesSaveDialog is defined, or create a dummy frame to avoid errors
if not PaperDollActionBarProfilesSaveDialog then
    PaperDollActionBarProfilesSaveDialog = CreateFrame("Frame", "PaperDollActionBarProfilesSaveDialog", UIParent)
end

local frame = PaperDollActionBarProfilesSaveDialog

-- This function returns a table of available options in the save dialog.
-- Each option consists of a display name and its corresponding internal key.
function frame:SaveDialogOptions()
    return table.s2k_values({
        { "Actions", "actions" },          -- Option for saving the player's action bar setup
        { "EmptySlots", "empty_slots" },   -- Option for saving empty action bar slots
        { "Talents", "talents" },          -- Option for saving the player's talents
        { "Macros", "macros" },            -- Option for saving the player's macros
        { "PetActions", "pet_actions" },   -- Option for saving the player's pet action bar setup
        { "Bindings", "bindings" },        -- Option for saving the player's key bindings
    }, true)
end


-- This function initializes the save dialog, setting up the UI elements with localized text.
function frame:OnInitialize()
    -- Set the text for the profile name and profile options sections in the save dialog
    self.ProfileNameText:SetText(L.gui_profile_name)
    self.ProfileOptionsText:SetText(L.gui_profile_options)

    -- Iterate over each option returned by SaveDialogOptions to set their corresponding UI text
    local option, lang
    for option, lang in self:SaveDialogOptions() do
        -- Update the text of each option checkbox in the save dialog
        _G[self:GetName() .. "Option" .. option .. "Text"]:SetText(" " .. L["option_" .. lang])
    end
end


-- This function is triggered when the "Okay" button is clicked in the save dialog.
function frame:OnOkayClick()
    -- Get the trimmed name from the EditBox
    local name = strtrim(self.EditBox:GetText())
    -- Prepare a table to hold the options
    local options = {}

    -- Iterate over the options available in the save dialog
    local option
    for option in self:SaveDialogOptions() do
        -- Save each option as a key in the options table with the value being either true or nil
        -- Options are prefixed with "skip" to indicate that those actions should be skipped
        options["skip" .. option] = not self["Option" .. option]:GetChecked() or nil
    end

    -- If a profile name already exists in the dialog
    if self.name then
        -- If the new name differs from the current one, handle renaming
        if name ~= self.name then
            -- Check if a profile with the new name already exists
            if addon:GetProfiles(name) then
                -- Display an error if the name already exists
                UIErrorsFrame:AddMessage(L.error_exists, 1.0, 0.1, 0.1, 1.0)
                return
            end

            -- Rename the existing profile
            addon:RenameProfile(self.name, name, true)

            -- Hack: Update the selection in the profile pane to the new name
            if PaperDollActionBarProfilesPane then
                PaperDollActionBarProfilesPane.selected = name
            end
        end

        -- Update the profile options with the new settings
        addon:UpdateProfileOptions(name, options)
    else
        -- If no profile name is set, check if the new name already exists
        if addon:GetProfiles(name) then
            -- Show a confirmation popup if the name exists, asking to overwrite the existing profile
            if not addon:ShowPopup("CONFIRM_OVERWRITE_ACTION_BAR_PROFILE", name, nil, { name = name, options = options, hide = self }) then
                -- Display an error if the user is locked out of this action
                UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
            end

            return
        end

        -- Save the profile with the specified name and options if it doesn't already exist
        addon:SaveProfile(name, options)
    end

    -- Hide the dialog after processing
    self:Hide()
end


-- This function is triggered when the "Cancel" button is clicked in the save dialog.
function frame:OnCancelClick()
    -- Simply hides the dialog without making any changes
    self:Hide()
end


-- This function updates the state of the "Okay" button based on the content of the EditBox.
function frame:Update()
    -- If the EditBox is not empty, enable the "Okay" button
    if strtrim(self.EditBox:GetText()) ~= "" then
        self.Okay:Enable()
    else
        -- Otherwise, disable the "Okay" button
        self.Okay:Disable()
    end
end


-- This function sets up the dialog for saving a profile, either creating a new one or modifying an existing one.
function frame:SetProfile(name)
    -- Reset the current profile name to nil and clear the EditBox
    self.name = nil
    self.EditBox:SetText("")

    -- Iterate over each option in the save dialog and reset them to default values
    local option
    for option in self:SaveDialogOptions() do
        -- Enable and check each option by default
        self["Option" .. option]:SetChecked(true)
        self["Option" .. option]:Enable()

        -- Set the text color for the option to the normal font color
        _G[self:GetName() .. "Option" .. option .. "Text"]:SetTextColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
    end

    -- If no profile name is provided, handle the creation of a new profile
    if not name then
        -- Disable the pet actions option if the player doesn't have any pet spells
        if not C_SpellBook.HasPetSpells() then
            self.OptionPetActions:Disable()
            _G[self:GetName() .. "OptionPetActionsText"]:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
        end
    else
        -- If a profile name is provided, set it as the current name
        self.name = name

        -- Set the EditBox text to the profile name and highlight it
        self.EditBox:SetText(name)
        self.EditBox:HighlightText(0)

        -- Retrieve the profile data based on the name
        local profile = addon:GetProfiles(name)
        if profile then
            -- Set each option's checkbox to match the profile's settings
            for option in self:SaveDialogOptions() do
                self["Option" .. option]:SetChecked(not profile["skip" .. option])
            end

            -- Disable the pet actions option if the profile doesn't have any pet actions saved
            if not profile.petActions then
                self.OptionPetActions:Disable()
                _G[self:GetName() .. "OptionPetActionsText"]:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
            end
        end
    end

    -- Call the Update function to ensure the "Okay" button is correctly enabled or disabled
    self:Update()
end
