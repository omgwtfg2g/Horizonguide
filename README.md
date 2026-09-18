#HorizonGuide — created by valzar

Work in progress. Features, guide content, and the interface are being updated as development continues. Bugs and incomplete information may remain.

HorizonXI server approval has not yet been granted. Public availability does not mean server approval.

Please report bugs or incorrect guide information through this repository’s Issues tab.

HorizonGuide is an Ashita addon that provides an in-game quest and mission guide for HorizonXI using content imported from the HorizonXI wiki.

Features include searchable guides, a job-quest filter, manual step tracking, and a movable on-screen tracker. Clicking the tracked quest opens its full guide. Each guide includes a direct link to its wiki page.

Players can manually mark quests completed and hide those entries. The addon currently tracks one quest at a time. It does not automatically detect completed quests or quest progress, and it does not automate gameplay or movement.

This is a work in progress submitted for review. I am continuing to fix bugs, improve the interface, and update the guide content. Imported walkthroughs may need corrections, and not every quest’s availability on HorizonXI has been verified.


Updated 0.2.8

- Cleaned up the interface with smaller buttons and tighter spacing.
- Moved quest and zone filters into a Filters / Zone popup, giving the quest list more space.
- Added Compact, Standard, and Large window-size presets.
- Made the side tracker optional and hidden by default.
- Removed the visible creator credit; valzar remains credited in the Lua.
- Removed the nested scrolling box from quest details.
- Selecting a different quest now scrolls its guide to the top.
- Added automatic current-zone filtering and manual zone selection.
- Added Starts here and Has steps here filters.
- Restricted zone choices to the original game through Treasures of Aht Urhgan.
- Completed quests marked manually remain hidden by default.
- Still a work in progress: zone matches do not verify character eligibility, and quest completion remains manual.
