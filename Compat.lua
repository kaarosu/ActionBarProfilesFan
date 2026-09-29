local addonName, addon = ...
ABP = _G.ABP or addon or ABP or {}
ABP.Compat = {}

local Compat = ABP.Compat

Compat.C_Spell = {}
setmetatable(Compat.C_Spell, {
    __index = function(t, k)
        if C_Spell and C_Spell[k] then
            return C_Spell[k]
        end
        if k == "GetSpellInfo" then
            return function(id)
                if GetSpellInfo then
                    local name, rank, icon, castTime, minRange, maxRange, spellID, originalIcon = GetSpellInfo(id)
                    if name then
                        return { name = name, iconID = icon, castTime = castTime, minRange = minRange, maxRange = maxRange, spellID = spellID or id }
                    end
                end
            end
        elseif k == "GetSpellLink" then
            return GetSpellLink
        elseif k == "IsSpellUsable" then
            return IsUsableSpell
        elseif k == "PickupSpell" then
            return PickupSpell
        elseif k == "PlaceSpellOnActionBar" then
            return function(id, slot) end 
        end
    end
})

Compat.C_SpellBook = {}
setmetatable(Compat.C_SpellBook, {
    __index = function(t, k)
        if C_SpellBook and C_SpellBook[k] then
            return C_SpellBook[k]
        end
        if k == "GetNumSpellBookSkillLines" then
            return GetNumSpellTabs
        elseif k == "GetSpellBookSkillLineInfo" then
            return function(index)
                if GetSpellTabInfo then
                    local name, texture, offset, numSpells, isGuild, offSpecID, shouldHide, isOffSpec = GetSpellTabInfo(index)
                    if name then
                        return { name = name, itemIndexOffset = offset, numSpellBookItems = numSpells, isGuild = isGuild }
                    end
                end
            end
        elseif k == "GetSpellBookItemType" then
            return function(index, bank)
                if GetSpellBookItemInfo then
                    return GetSpellBookItemInfo(index, bank)
                end
            end
        elseif k == "GetSpellBookItemName" then
            return function(index, bank)
                if GetSpellBookItemName then
                    return GetSpellBookItemName(index, bank)
                end
            end
        elseif k == "HasPetSpells" then
            return HasPetSpells
        elseif k == "PickupSpellBookItem" then
            return function(id, bank)
                if bank == Enum.SpellBookSpellBank.Pet then
                    PickupSpellBookItem(id, "pet")
                else
                    PickupSpellBookItem(id, "spell")
                end
            end
        elseif k == "IsClassTalentSpellBookItem" then
            return function() return false end
        elseif k == "IsPvPTalentSpellBookItem" then
            return function() return false end
        elseif k == "IsSpellKnown" then
            return function(id, bank)
                if bank == Enum.SpellBookSpellBank.Pet then
                    return IsSpellKnown(id, true)
                else
                    return IsSpellKnown(id)
                end
            end
        end
    end
})

Compat.C_Item = {}
setmetatable(Compat.C_Item, {
    __index = function(t, k)
        if C_Item and C_Item[k] then
            return C_Item[k]
        end
        if k == "GetItemInfo" then
            return GetItemInfo
        elseif k == "PickupItem" then
            return PickupItem
        end
    end
})

Compat.C_Container = {}
setmetatable(Compat.C_Container, {
    __index = function(t, k)
        if C_Container and C_Container[k] then
            return C_Container[k]
        end
        if k == "GetContainerNumSlots" then
            return GetContainerNumSlots
        elseif k == "GetContainerItemID" then
            return GetContainerItemID
        elseif k == "PickupContainerItem" then
            return PickupContainerItem
        end
    end
})
