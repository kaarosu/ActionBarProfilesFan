local addonName, addon = ...

local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

function addon:RegisterSettings()
    if Settings and Settings.RegisterVerticalLayoutCategory then
        local category, layout = Settings.RegisterVerticalLayoutCategory(addonName)
        self.settingsCategory = category

        -- Setting 1: Minimap Icon Checkbox
        local function GetMinimap()
            return not (self.db and self.db.profile and self.db.profile.minimap and self.db.profile.minimap.hide)
        end

        local function SetMinimap(value)
            if self.db and self.db.profile and self.db.profile.minimap then
                self.db.profile.minimap.hide = not value
            end
            if self.icon then
                if value then
                    self.icon:Show(addonName)
                else
                    self.icon:Hide(addonName)
                end
            end
        end

        local minimapSetting = Settings.RegisterProxySetting(
            category,
            "ABP_SETTING_MINIMAP",
            Settings.VarType.Boolean,
            L.cfg_minimap_icon or "Show minimap icon",
            false,
            GetMinimap,
            SetMinimap
        )
        Settings.CreateCheckbox(category, minimapSetting, L.cfg_minimap_icon or "Show minimap icon")

        -- Setting 2: Replace Macros Checkbox
        local function GetReplaceMacros()
            return (self.db and self.db.profile and self.db.profile.replace_macros) or false
        end

        local function SetReplaceMacros(value)
            if self.db and self.db.profile then
                self.db.profile.replace_macros = value
            end
        end

        local replaceMacrosSetting = Settings.RegisterProxySetting(
            category,
            "ABP_SETTING_REPLACE_MACROS",
            Settings.VarType.Boolean,
            L.cfg_replace_macros or "Replace macros",
            false,
            GetReplaceMacros,
            SetReplaceMacros
        )
        Settings.CreateCheckbox(category, replaceMacrosSetting, L.cfg_replace_macros or "Replace macros")

        Settings.RegisterAddOnCategory(category)
    end
end

