# Arena Log Viewer

In-game WCL-style arena timeline viewer for **WoW TBC Classic / Anniversary**.

Records arena matches live via `COMBAT_LOG_EVENT_UNFILTERED` (no file I/O in the Lua sandbox) and stores timelines in SavedVariables. Open with `/alv`.

## Features (0.1)

- Auto-starts recording when you enter an arena; stops and builds a timeline when you leave
- Tracks casts, auras, damage, heals, interrupts, dispels, deaths
- Per-spell rows with cast ticks + aura duration bars (school-colored)
- Match list sidebar + scrollable timeline
- Spell icons from `GetSpellTexture`

## Install

1. Copy the `ArenaLogViewer` folder into `Interface\AddOns\`
2. Enable **Arena Log Viewer** at the character select screen
3. Queue arenas — matches are saved automatically
4. Type `/alv` to open the viewer

## Related

- **ArenaCombatLog** — toggles WoW’s advanced combat log to disk (for the web viewer)
- **tbc-arena-logs** — web app that splits/analyzes `WoWCombatLog*.txt` session files

This addon is the in-game counterpart: same timeline idea, recorded live instead of from a log file.

## Slash commands

| Command | Action |
|---------|--------|
| `/alv` | Toggle the viewer window |

## License

GPL-2.0
