# Equipped weapon gameplay

Status: implementation requested by the user after reviewing PR #28's equipment footage. The user approved that UI direction and explicitly requested connecting equipment to the character's actual weapon and firing/shooting. This is the approved follow-up scope, not performance work.

The previous equipment tests established inventory identity, persistence, weapon-context and ability reconciliation, but never fired a shot or checked the in-world weapon. LocalActorPresenter currently renders body layers only and ignores frame.weapon and committed shot feedback.

Connect the authored AKM/machete visuals to confirmed equipped state. Present aim, shot/reload feedback and authoritative hit results without moving gameplay ownership into presentation. Exercise the normal application with real input, ammunition changes, target damage, unequip/re-equip and persistence. Retain the existing inventory UI, local saves, native addons and 60 Hz simulation. Do not introduce unsupported equipment, a second combat simulation, automatic fire rules, new balance or multiplayer. Source art limitations must be stated rather than claiming bespoke weapon animations exist.
