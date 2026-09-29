local addonName, addon = ...

local L = LibStub("AceLocale-3.0"):GetLocale(addonName)
local DEBUG = ABP_DEBUG_PREFIX

-- Localize globals for performance
local pairs = pairs
local StaticPopup_Show = StaticPopup_Show
local YES, NO = YES, NO
local StaticPopupDialogs = StaticPopupDialogs
local InCombatLockdown = InCombatLockdown
local UIErrorsFrame = UIErrorsFrame
local ERR_CLIENT_LOCKED_OUT = ERR_CLIENT_LOCKED_OUT

-- Static Popup Dialog Definitions for Action Bar Profile Management
-- These dialogs handle user confirmation for various actions related to action bar profiles.
-- Each dialog has customizable buttons, behavior for accept, hide, and cancel events, and other options.

-- Confirmation Dialog for Using an Action Bar Profile
StaticPopupDialogs.CONFIRM_USE_ACTION_BAR_PROFILE = {
    text = L.confirm_use,  -- The text displayed in the dialog

    button1 = YES,  -- Text for the first button (typically "Yes")
    button2 = NO,   -- Text for the second button (typically "No")

    OnAccept = function(popup, data) addon:OnUseConfirm(popup, data) end,  -- Function called when the "Yes" button is clicked
    OnHide = function(popup) end,  -- Function called when the dialog is hidden (no special handling needed here)
    OnCancel = function(popup) end,  -- Function called when the "No" button is clicked (no special handling needed here)

    hideOnEscape = 1,  -- Allow the dialog to be closed with the Escape key
    timeout = 0,       -- No timeout; the dialog will stay open until the user interacts with it
    exclusive = 1,     -- Prevent other popups from being shown at the same time
    whileDead = 1,     -- Allow the dialog to be shown even when the player character is dead
}


-- Confirmation Dialog for Deleting an Action Bar Profile
StaticPopupDialogs.CONFIRM_DELETE_ACTION_BAR_PROFILE = {
    text = L.confirm_delete,  -- The text displayed in the dialog

    button1 = YES,
    button2 = NO,

    OnAccept = function(popup, data) addon:OnDeleteConfirm(popup, data) end,  -- Function called when the "Yes" button is clicked
    OnHide = function(popup) end,
    OnCancel = function(popup) end,

    hideOnEscape = 1,
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
}


-- Confirmation Dialog for Saving an Action Bar Profile
StaticPopupDialogs.CONFIRM_SAVE_ACTION_BAR_PROFILE = {
    text = L.confirm_save,  -- The text displayed in the dialog

    button1 = YES,
    button2 = NO,

    OnAccept = function(popup, data) addon:OnSaveConfirm(popup, data) end,  -- Function called when the "Yes" button is clicked
    OnHide = function(popup) end,
    OnCancel = function(popup) end,

    hideOnEscape = 1,
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
}


-- Confirmation Dialog for Overwriting an Existing Action Bar Profile
StaticPopupDialogs.CONFIRM_OVERWRITE_ACTION_BAR_PROFILE = {
    text = L.confirm_overwrite,  -- The text displayed in the dialog

    button1 = YES,
    button2 = NO,

    OnAccept = function(popup, data) addon:OnOverwriteConfirm(popup, data) end,  -- Function called when the "Yes" button is clicked
    OnHide = function(popup) end,
    OnCancel = function(popup) end,

    hideOnEscape = 1,
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
}


-- Confirmation Dialog for Receiving an Action Bar Profile
StaticPopupDialogs.CONFIRM_RECEIVE_ACTION_BAR_PROFILE = {
    text = L.confirm_receive,  -- The text displayed in the dialog

    button1 = YES,
    button2 = NO,

    OnAccept = function(popup, data) addon:OnReceiveConfirm(popup, data) end,  -- Function called when the "Yes" button is clicked
    OnHide = function(popup) end,
    OnCancel = function(popup) end,

    hideOnEscape = 1,
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
}


-- Function to show a static popup dialog with optional custom settings
function addon:ShowPopup(id, p1, p2, options)
    -- Show the popup dialog identified by 'id' with parameters 'p1', 'p2', and data 'options'
    local popup = StaticPopup_Show(id, p1, p2, options)
    if popup then
        -- If additional options are provided, assign to .data and copy keys for backwards compatibility
        if options then
            popup.data = options
            for k, v in pairs(options) do
                popup[k] = v
            end
        end

        -- Return the modified popup dialog
        return popup
    end
end


-- Handler for confirming the use of an action bar profile
function addon:OnUseConfirm(popup, data)
    if InCombatLockdown() then
        if UIErrorsFrame and ERR_CLIENT_LOCKED_OUT then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        end
        return
    end

    local d = data or (popup and popup.data) or popup
    if not d or not d.name then return end

    -- Use the profile specified in the popup dialog
    local cache = addon:MakeCache() -- Create a cache here
    addon:UseProfile(d.name, false, cache) -- Apply the profile with the confirmed name
end


-- Handler for confirming the deletion of an action bar profile
function addon:OnDeleteConfirm(popup, data)
    local d = data or (popup and popup.data) or popup
    if not d or not d.name then return end

    -- Delete the profile specified in the popup dialog
    addon:DeleteProfile(d.name)
end


-- Handler for confirming the saving of an action bar profile
function addon:OnSaveConfirm(popup, data)
    if InCombatLockdown() then
        if UIErrorsFrame and ERR_CLIENT_LOCKED_OUT then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        end
        return
    end

    local d = data or (popup and popup.data) or popup
    if not d or not d.name then return end

    -- Update the profile specified in the popup dialog
    addon:UpdateProfile(d.name)
end


-- Handler for confirming the overwriting of an existing action bar profile
function addon:OnOverwriteConfirm(popup, data)
    if InCombatLockdown() then
        if UIErrorsFrame and ERR_CLIENT_LOCKED_OUT then
            UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT, 1.0, 0.1, 0.1, 1.0)
        end
        return
    end

    local d = data or (popup and popup.data) or popup
    if not d or not d.name then return end

    -- Save the profile specified in the popup dialog with the given options
    addon:SaveProfile(d.name, d.options)

    -- Hide the popup dialog if a 'hide' parameter is provided
    if d.hide then
        d.hide:Hide()
    end
end


-- Handler for confirming the receipt of an action bar profile from another source
function addon:OnReceiveConfirm(popup, data)
    local d = data or (popup and popup.data) or popup
    if not d or not d.name then return end

    -- Attempt to guess a name for the profile being received
    local name = self:GuessName(d.name)
    if name then
        local list = self.db and self.db.profile and self.db.profile.list
        if list then
            -- Save the received profile to the list
            list[name] = d.profile

            -- Update the GUI and notify the user that the profile has been saved
            self:UpdateGUI()
            self:Printf(L.msg_profile_saved, name)
        end
    end
end
