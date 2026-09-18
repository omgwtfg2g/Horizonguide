#HorizonGuide — created by valzar

Work in progress. Features, guide content, and the interface are being updated as development continues. Bugs and incomplete information may remain.

HorizonXI server approval has not yet been granted. Public availability does not mean server approval.

Please report bugs or incorrect guide information through this repository’s Issues tab.

HorizonGuide is an Ashita addon that provides an in-game quest and mission guide for HorizonXI using content imported from the HorizonXI wiki.

Features include searchable guides, a job-quest filter, manual step tracking, and a movable on-screen tracker. Clicking the tracked quest opens its full guide. Each guide includes a direct link to its wiki page.

Players can manually mark quests completed and hide those entries. The addon currently tracks one quest at a time. It does not automatically detect completed quests or quest progress, and it does not automate gameplay or movement.

This is a work in progress submitted for review. I am continuing to fix bugs, improve the interface, and update the guide content. Imported walkthroughs may need corrections, and not every quest’s availability on HorizonXI has been verified.


##HorizonGuide - Developer Review / Cumulative Update
Created by valzar
Updated: 2026-09-18

INSTALL / UPDATE
1. In game, run /addon unload horizonguide.
2. Back up your existing Game\addons\horizonguide folder.
3. Copy the four Lua files from this archive's horizonguide folder into
   Game\addons\horizonguide, replacing the old files. Keep your saved settings.
4. Run /addon load horizonguide.
5. Use /hg or /horizonguide to reopen the menu.

Only the horizonguide folder belongs in the addon directory. The source,
tools, tests, audits and documentation are included for review/reproducibility.

CURRENT SCOPE
- 488 quests
- 162 missions
- 60 reference guides
- 3 Getting Started nation paths
- Jobs hub for jobs available through the current HorizonXI ToAU era
- Professions hub for all nine professions
- 3,225 crafting recipe entries across eight crafts
- 86 fishing catches
- 90 populated profession skill brackets (0-10 through 91-100)

MAJOR CHANGES SINCE v0.2.8
- Added nation-specific Getting Started paths, recommended next steps and linked walkthroughs.
- Reworked quest/mission progress display so headings, notes, fight strategy and player testimony do not become fake required steps.
- Added a dedicated reference-guide view and expanded the imported HorizonXI guide catalog.
- Audited the complete wiki-backed quest/mission/guide catalog against the 2026-09-18 HorizonXI Wiki export and repaired stale/reordered/missing walkthrough content.
- Added Jobs and Professions hubs.
- Added complete structured 0-100 profession tables, including recipe/fish details, ingredients, crystals, requirements, HQ information and item/source links.
- Updated ToAU job quest/AF/limit-break coverage for Blue Mage, Corsair and Puppetmaster.
- Preserved manual per-character progress and saved-profile compatibility.
- Fixed Ashita/Lua 5.1 renderer upvalue limits and several UI/import regressions.
- v0.4.8 adds a complete cumulative changelog/developer handoff and fixes the main window title so it always displays addon.version instead of a stale hard-coded version.

IMPORTANT LIMITS
- Quest completion and eligibility are not read from game state; tracking is manual.
- Current-zone filtering is navigation assistance, not proof that a character can start or complete an entry.
- Wiki-derived content is a reference snapshot and is not automatically verified in game.
- Retail-only guide content is intentionally not imported as Horizon guidance; questionable or out-of-era sections are warned where known.
- Profession recipe data excludes known later-expansion/above-100 requirements and desynthesis content where documented by the import audit.

SOURCE / REBUILD
HorizonXI Wiki: https://horizonffxi.wiki/
