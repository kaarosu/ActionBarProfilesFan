# Action Bar Profiles (ABP)

**Author:** Kaarosu  
**Version:** 12.1.0.1  
**Compatibility:** World of Warcraft Classic Beta (Camelot 16001), Classic Era (1.15.x), Cataclysm Classic (4.4.x), Retail / Modern WoW (11.x, 12.x)

---

## Overview

**Action Bar Profiles (ABP)** allows you to seamlessly save, restore, manage, and transfer action bar setups, macros, talents, and pet bars across specs, characters, and game versions.

### Key Improvements & Modernization:
- **Universal Multi-Client Architecture**: Native support for Classic Beta (Camelot Engine / 16001), Classic Era, Cataclysm Classic, and Retail.
- **Advanced Talent & Macro Synchronization**: Fully integrates with modern talent APIs (`C_Traits`, `C_ClassTalents`) while remaining backward-compatible with Classic spellbook layouts.
- **Enhanced Spellbook Scanning**: Scans all specialization tabs and profession spellbooks, eliminating "Spell not found" errors for core abilities.
- **Special UI Button Handling**: Saves and restores favorite mounts, toys, zone ability buttons, and quest items.
- **Deterministic Action Placement**: Employs modern placement engines with automated fallback to cursor-based pickup/drop for Classic environments.
- **Zero-Hang Performance**: Optimized table caching and localized globals prevent frame drops during profile loading.

---

## Features
- Save unlimited action bar layouts per character or account-wide.
- Auto-switch layouts when changing specializations.
- Character Frame sidebar integration and Minimap quick-launcher icon.