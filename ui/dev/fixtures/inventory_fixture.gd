extends RefCounted

static func _item(item_id: String, item_name: String, icon: String, x: int, y: int, w: int = 1, h: int = 1, count: int = 0, kind: String = "junk", compatibility: String = "", valuable: bool = false, mid_value: bool = false, category: String = "all") -> Dictionary:
    return {
        "id": item_id,
        "name": item_name,
        "icon": icon,
        "x": x,
        "y": y,
        "w": w,
        "h": h,
        "count": count,
        "kind": kind,
        "compatibility": compatibility,
        "valuable": valuable,
        "mid_value": mid_value,
        "category": category,
        "short": "" if kind in ["junk", "food"] else kind.to_upper(),
    }


static func create() -> Dictionary:
    return {
        "rig_size": [6, 2],
        "backpack_size": [6, 5],
        "pockets": [
            _item("pocket_tape", "Duct tape", "item_tape.png", 0, 0, 1, 1, 0, "junk", "", false, true, "util"),
            _item("pocket_cards", "Cards", "item_cards.png", 3, 0, 1, 1, 0, "junk", "", false, true, "util"),
        ],
        "rig": [
            _item("rig_sanitizer", "Sanitizer", "item_bottle.png", 0, 0, 1, 1, 0, "food", "", true, false, "food"),
            _item("rig_cup", "Tin cup", "item_cup.png", 1, 0, 1, 1, 0, "junk", "", false, true, "util"),
            _item("rig_knife", "Pocket knife", "item_redknife.png", 2, 0, 1, 1, 0, "weapon", "", false, true, "guns"),
            _item("rig_ammo", "7.62×39 PS", "item_box.png", 0, 1, 1, 1, 30, "ammo", "7.62x39", false, false, "ammo"),
            _item("rig_mag_1", "AK 30-rd magazine", "ph_mag.png", 1, 1, 1, 1, 30, "mag", "7.62x39", false, false, "ammo"),
            _item("rig_mag_2", "AK 30-rd magazine", "ph_mag.png", 2, 1, 1, 1, 12, "mag", "7.62x39", false, false, "ammo"),
        ],
        "backpack": [
            _item("pack_calc", "Calculator", "item_calc.png", 0, 0),
            _item("pack_book", "Ledger", "item_book.png", 1, 0, 2, 1, 0, "junk", "", true, false, "util"),
            _item("pack_battery", "Car battery", "item_battery.png", 3, 0, 1, 2, 0, "junk", "", true, false, "util"),
            _item("pack_tomato", "Tomatoes", "item_tomato.png", 4, 0, 1, 1, 3, "food", "", false, true, "food"),
            _item("pack_tape", "Duct tape", "item_tape.png", 0, 1),
            _item("pack_chess", "Chess set", "item_chess.png", 1, 1, 2, 1, 0, "junk", "", false, true, "util"),
            _item("pack_cards", "Cards", "item_cards.png", 4, 1),
            _item("pack_parts", "Gun parts", "item_parts.png", 0, 2, 2, 1, 0, "junk", "", false, true, "util"),
            _item("pack_coal", "Coal", "item_coal.png", 2, 2, 1, 1, 2, "junk", "", false, true, "util"),
        ],
        "stash": [
            _item("stash_cup", "Tin cup", "item_cup.png", 0, 0, 1, 1, 0, "junk", "", false, true, "util"),
            _item("stash_book", "Ledger", "item_book.png", 1, 0, 2, 1, 0, "junk", "", true, false, "util"),
            _item("stash_parts", "Gun parts", "item_parts.png", 3, 0, 2, 1, 0, "junk", "", false, true, "util"),
            _item("stash_battery", "Car battery", "item_battery.png", 5, 0, 1, 2, 0, "junk", "", true, false, "util"),
            _item("stash_tomato", "Tomatoes", "item_tomato.png", 6, 0, 1, 1, 4, "food", "", false, true, "food"),
            _item("stash_tape", "Duct tape", "item_tape.png", 0, 1),
            _item("stash_chess", "Chess set", "item_chess.png", 1, 1, 2, 1, 0, "junk", "", false, true, "util"),
            _item("stash_cards", "Cards", "item_cards.png", 3, 1),
            _item("stash_coal", "Coal", "item_coal.png", 4, 1, 1, 1, 0, "junk", "", false, true, "util"),
            _item("stash_knife", "Pocket knife", "item_redknife.png", 6, 1, 1, 1, 0, "weapon", "", false, true, "guns"),
            _item("stash_bottle", "Sanitizer", "item_bottle.png", 0, 2, 1, 2, 0, "food", "", true, false, "food"),
            _item("stash_ammo", "7.62×39 PS", "item_box.png", 1, 2, 1, 1, 60, "ammo", "7.62x39", false, false, "ammo"),
            _item("stash_potion", "Moonshine", "item_potion.png", 2, 2, 1, 2, 0, "food", "", true, false, "food"),
            _item("stash_fish", "Dried fish", "item_fish.png", 3, 2, 2, 1, 0, "food", "", false, true, "food"),
            _item("stash_mag_1", "AK 30-rd magazine", "ph_mag.png", 5, 2, 1, 1, 30, "mag", "7.62x39", false, false, "ammo"),
            _item("stash_mag_2", "AK 30-rd magazine", "ph_mag.png", 6, 2, 1, 1, 30, "mag", "7.62x39", false, false, "ammo"),
            _item("stash_ammo_2", "7.62×39 PS", "item_box.png", 5, 3, 1, 1, 60, "ammo", "7.62x39", false, false, "ammo"),
            _item("stash_shotgun", "Pump shotgun", "gun_shotgun.png", 0, 4, 2, 1, 0, "weapon", "12ga", false, true, "guns"),
            _item("stash_pistol", "M1911", "wpn_pistol.png", 2, 4, 1, 1, 0, "weapon", ".45", false, true, "guns"),
            _item("stash_machete", "Machete", "gun_machete.png", 3, 4, 2, 1, 0, "weapon", "", false, true, "guns"),
        ],
        "loot": [
            _item("loot_cup", "Tin cup", "item_cup.png", 0, 0),
            _item("loot_book", "Ledger", "item_book.png", 1, 0, 2, 1, 0, "junk", "", true, false, "util"),
            _item("loot_fish", "Dried fish", "item_fish.png", 0, 1, 2, 1, 0, "food", "", false, true, "food"),
        ],
    }
