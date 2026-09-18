# Tasks

- [ ] G1 [SOL] Trace real input, inventory-to-weapon mapping, committed shooting and rendered actor behavior. Evidence: concrete source gaps and a failing or missing-coverage baseline.
- [ ] G2 [SOL] Connect equipped world weapon and confirmed shot presentation without gameplay mutation in the presenter. Evidence: native presentation contract including empty/dead/stale/duplicate/rejected cases.
- [ ] G3 [SOL] Exercise normal UI -> deployment -> aim/fire/reload -> real enemy damage -> unequip/re-equip. Evidence: actual-input native application test, ammunition/identity/damage assertions, no direct test gameplay mutation.
- [ ] G4 [ASTRA] Record the gameplay flow and inspect native 1920x1080 frames. Evidence: raw logs, source identity, movie and clear remaining art/acceptance limits.
