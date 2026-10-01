# Workday lockdown whitelist

`LOCKDOWN_WHITELIST` in `config_whitelist.sh`, exported as
`lockdown_allowed_packages`. Applied while wake-alarm's missed-workday lockdown
is in force (`LOCKDOWN_UNTIL_EOD` with an inclusive `until` date; lifted by
`LIFT_LOCKDOWN`), at home or away, inside the curfew window or not. Contract:
`~/src/wake-alarm/DOCS-wake-enforcement.md`, "Phone stick".

- **Exact names only.** The `com.kuhy` / `dev.kuhy` / tachiyomi prefixes do
  not apply in this tier, or every kuhy app would survive a lockdown that
  exists to take them away. `SYSTEM_NEVER_DISABLE` and the launcher still do.
- **Subset of `WHITELIST`, not of `NIGHT_WHITELIST`.** Maps is day-only but is
  what a lockdown spent away from home needs; music and the workout/punchme
  sandbox flavours are night-allowed but dropped here. `focus_policy/model.py` enforces the subset.
- **Unconfigured is not empty.** Deleting the variable omits the key, and the
  enforcer falls back to the night list. An empty list would hide the dialer.
- **Categories:** calls/contacts/SMS (fossify), Signal, Google Maps, banking
  (mBank, Revolut, infakt) plus mObywatel, KeePassDX (holds the TOTP seeds; no
  dedicated authenticator app is installed), wake-alarm, todo, the launcher and
  the enforcer. No transit/ticket app is installed, so none is listed.
- **Obligations stay.** The lockdown targets distractions, not duties:
  RunnerUp (`org.runnerup`, `org.runnerup.free`) exports the TCX files
  screen-locker's workout verification reads, and punchme
  (`com.kuhy.punchme`) is the work-hours tracker, needed on exactly the
  workdays a lockdown hits. `com.kuhy.punchme.sandbox` is the test-punch
  flavour and stays hidden.
- **Length is capped.** One signal can lock through today + 4 days at most
  (5 calendar days, `MAX_LOCKDOWN_DAYS` in `WorkdayLockdown.kt`, matching
  `STICK_LOCKDOWN_MAX_DAYS` in wake-alarm). A later `until` is clamped, so a
  sender bug cannot lock the phone indefinitely. A shorter signal never
  shortens an existing lockdown; `LIFT_LOCKDOWN` ends one immediately.
