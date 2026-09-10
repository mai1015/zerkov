extends RefCounted

const ZONES := [
    {"name": "SAWMILL YARD", "risk": "LOW", "risk_color": "green", "summary": "Abandoned timber yard. Dense tree line, one road in.", "duration": "35:00", "squad": "1 – 4", "extracts": "3 · Road gate · Creek · Tree line (squad only)", "threats": "Scavs · Wolves", "loot": "Tools · Food · Parts", "tasks": ["supply_run", "ledger_recovery"], "position": Vector2(0.30, 0.42)},
    {"name": "RAIL BRIDGE", "risk": "MED", "risk_color": "yellow", "summary": "Freight line over a frozen cut. Long sight lines, two exits.", "duration": "40:00", "squad": "1 – 4", "extracts": "2 · Underpass · Signal hut", "threats": "Scavs · Snipers", "loot": "Parts · Ammo · Cards", "tasks": ["spare_parts"], "position": Vector2(0.58, 0.30)},
    {"name": "ZERKOV TOWN", "risk": "HIGH", "risk_color": "red", "summary": "Tight streets around the old square. Every door can be watched.", "duration": "45:00", "squad": "2 – 4", "extracts": "4 · Market · North road · Courtyard · Tunnel", "threats": "Scavs · Raiders", "loot": "Cash · Tech · Weapons", "tasks": [], "position": Vector2(0.70, 0.62)},
    {"name": "RESERVOIR", "risk": "MED", "risk_color": "yellow", "summary": "A quiet spillway with a flooded maintenance route.", "duration": "30:00", "squad": "1 – 4", "extracts": "2 · Pump house · Waterline", "threats": "Wolves · Scavs", "loot": "Food · Meds · Parts", "tasks": ["wolf_cull"], "position": Vector2(0.22, 0.74)},
    {"name": "MILL OFFICE", "risk": "LVL 20", "risk_color": "muted", "summary": "Locked records office above the mill floor.", "duration": "50:00", "squad": "2 – 4", "extracts": "1 · Service lift", "threats": "Raiders · Turret", "loot": "Ledgers · Keys · Cash", "tasks": [], "position": Vector2(0.86, 0.18)}
]

const TASKS := [
    {"id": "supply_run", "status": "active", "trader": "FENCE", "rep": "2.1", "zone": "SAWMILL YARD", "title": "SUPPLY RUN", "list_title": "Supply run", "tag": "TRACKED", "tag_color": "accent", "description": "The yard's still got crates nobody's opened. Bring me three and I'll stop charging you like a stranger.", "objectives": [{"text": "Search a wooden crate in the Sawmill yard", "target": 1, "current": 1}, {"text": "Search a second crate", "target": 1, "current": 1}, {"text": "Search a third crate", "target": 1, "current": 0}, {"text": "Extract with the ledger", "target": 1, "current": 0}], "xp": "2,400", "cash": "$ 3,000", "item": "Dried fish ×2", "reward_rep": "Fence +0.05"},
    {"id": "field_dressing", "status": "active", "trader": "MEDIC", "rep": "1.4", "zone": "ANY ZONE", "title": "FIELD DRESSING", "list_title": "Field dressing", "tag": "EXPIRES 02:14:00", "tag_color": "yellow", "description": "A clean field kit makes the difference between walking home and becoming a landmark.", "objectives": [{"text": "Use a bandage in a raid", "target": 5, "current": 0}], "xp": "1,200", "cash": "$ 900", "item": "Splint ×3", "reward_rep": "Medic +0.10"},
    {"id": "ledger_recovery", "status": "active", "trader": "FENCE", "rep": "2.1", "zone": "SAWMILL YARD · MILL OFFICE", "title": "LEDGER RECOVERY", "list_title": "Ledger recovery", "tag": "KEY NEEDED", "tag_color": "muted", "description": "The mill office still has the books. Find the key, then bring the ledger back intact.", "objectives": [{"text": "Find the mill office key", "target": 1, "current": 0}], "xp": "3,800", "cash": "$ 6,500", "item": "Fence rep +0.2", "reward_rep": "Fence +0.20"},
    {"id": "wolf_cull", "status": "available", "trader": "RANGER", "rep": "0.3", "zone": "RESERVOIR", "title": "WOLF CULL", "list_title": "Wolf cull", "tag": "NEW", "tag_color": "accent", "description": "The reservoir trail is not safe after dusk. Thin the pack before it learns the route.", "objectives": [{"text": "Eliminate wolves near the reservoir", "target": 3, "current": 0}], "xp": "1,600", "cash": "$ 1,200", "item": "Ranger rep +0.10", "reward_rep": "Ranger +0.10"},
    {"id": "spare_parts", "status": "available", "trader": "MECHANIC", "rep": "0.8", "zone": "ZERKOV TOWN", "title": "SPARE PARTS", "list_title": "Spare parts", "tag": "", "tag_color": "muted", "description": "The old receiver needs one clean magazine before it can go back on the line.", "objectives": [{"text": "Recover an AK 40-rd magazine", "target": 1, "current": 0}], "xp": "2,000", "cash": "—", "item": "AK 40-rd mag", "reward_rep": "Mechanic +0.10"},
    {"id": "first_contact", "status": "completed", "trader": "FENCE", "rep": "2.1", "zone": "SAWMILL YARD", "title": "FIRST CONTACT", "list_title": "First contact", "tag": "COMPLETE", "tag_color": "green", "description": "The yard is mapped and the route is open.", "objectives": [{"text": "Reach the Sawmill yard", "target": 1, "current": 1}], "xp": "800", "cash": "$ 500", "item": "Fence rep +0.05", "reward_rep": "Fence +0.05"},
    {"id": "lost_cache", "status": "completed", "trader": "MEDIC", "rep": "1.4", "zone": "RESERVOIR", "title": "LOST CACHE", "list_title": "Lost cache", "tag": "COMPLETE", "tag_color": "green", "description": "The field kit made it back to the bunker.", "objectives": [{"text": "Recover the marked cache", "target": 1, "current": 1}], "xp": "700", "cash": "$ 650", "item": "Bandage ×2", "reward_rep": "Medic +0.05"}
]

const TRADERS := [
    {"name": "ALL", "initial": "A", "sub": "3 active · 4 available", "count": "3"},
    {"name": "FENCE", "initial": "", "sub": "Rep 2.1 · buys anything", "count": "2"},
    {"name": "MEDIC", "initial": "M", "sub": "Rep 1.4 · meds, splints", "count": "1"},
    {"name": "MECHANIC", "initial": "M", "sub": "Rep 0.8 · parts, mods", "count": ""},
    {"name": "RANGER", "initial": "R", "sub": "Rep 0.3 · food, maps · locked at LVL 15", "count": ""}
]

const CONTROL_GROUPS := [
    {"name": "MOVEMENT", "actions": [{"id": "move", "label": "Move", "controller": "LS"}, {"id": "sprint", "label": "Sprint", "controller": "LS ↓"}, {"id": "crouch", "label": "Crouch / cover", "controller": "B"}, {"id": "interact", "label": "Interact / loot", "controller": "X"}, {"id": "hold_interact", "label": "Hold interact", "controller": "X · HOLD"}]},
    {"name": "COMBAT", "actions": [{"id": "fire", "label": "Fire", "controller": "RT"}, {"id": "aim", "label": "Aim", "controller": "LT"}, {"id": "reload", "label": "Reload", "controller": "X · HOLD"}, {"id": "fire_mode", "label": "Fire mode", "controller": "D-PAD →"}, {"id": "melee", "label": "Melee", "controller": "RS"}, {"id": "grenade", "label": "Grenade", "controller": "RB"}, {"id": "weapon_cycle", "label": "Weapon 1 / 2 / 3", "controller": "Y"}]},
    {"name": "SURVIVAL", "actions": [{"id": "quick_heal", "label": "Quick heal", "controller": "D-PAD ←"}, {"id": "quick_use", "label": "Quick use 5–0", "controller": "D-PAD ↑"}, {"id": "eat_drink", "label": "Eat / drink", "controller": "D-PAD ↘"}]},
    {"name": "INTERFACE", "actions": [{"id": "inventory", "label": "Inventory", "controller": "MENU"}, {"id": "map", "label": "Map", "controller": "VIEW"}, {"id": "push_to_talk", "label": "Push to talk", "controller": "D-PAD ↓"}]}
]

const DEFAULT_BINDINGS := {
    "move": {"primary": "W A S D", "secondary": "—", "controller": "LS"},
    "sprint": {"primary": "SHIFT", "secondary": "—", "controller": "LS ↓"},
    "crouch": {"primary": "C", "secondary": "CTRL", "controller": "B"},
    "interact": {"primary": "E", "secondary": "—", "controller": "X"},
    "hold_interact": {"primary": "E · HOLD", "secondary": "—", "controller": "X · HOLD"},
    "fire": {"primary": "LMB", "secondary": "—", "controller": "RT"},
    "aim": {"primary": "RMB", "secondary": "—", "controller": "LT"},
    "reload": {"primary": "R", "secondary": "—", "controller": "X · HOLD"},
    "fire_mode": {"primary": "B", "secondary": "—", "controller": "D-PAD →"},
    "melee": {"primary": "V", "secondary": "—", "controller": "RS"},
    "grenade": {"primary": "G", "secondary": "—", "controller": "RB"},
    "weapon_cycle": {"primary": "1 · 2 · 3", "secondary": "SCROLL", "controller": "Y"},
    "quick_heal": {"primary": "Y", "secondary": "—", "controller": "D-PAD ←"},
    "quick_use": {"primary": "5 · 0", "secondary": "—", "controller": "D-PAD ↑"},
    "eat_drink": {"primary": "H", "secondary": "—", "controller": "D-PAD ↘"},
    "inventory": {"primary": "TAB", "secondary": "I", "controller": "MENU"},
    "map": {"primary": "M", "secondary": "—", "controller": "VIEW"},
    "push_to_talk": {"primary": "V", "secondary": "—", "controller": "D-PAD ↓"}
}
