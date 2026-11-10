# Branch on an OS class, not on osid lists

FOS branched on lists of osids, such as `[5-7]|9|10|11`, at 20 sites outside `determineOS()`.
`determineOS()` also aborted on any osid it did not know. So every new OS row
in FOG needed a FOS release.

We decided **FOS resolves one global, `osClass`, once, and every site
branches on `osClass`.** `determineOS "$osid" "$family"` sets it.

## The rule

| osid | osClass | Rule |
|---|---|---|
| 1 | `xp` | frozen id; the family is ignored |
| 2 | `vista` | frozen id |
| 3 | `win98` | frozen id |
| 4 | `winother` | frozen id |
| 5, 6, 7 | `win7` | frozen ids |
| any other id | from the family | `windows` gives `winmodern`, `linux` gives `linux`, `macos` gives `mac`, `other` gives `other` |

- Ids 1-7 stay keyed on the osid. They are historical, no new id joins them,
  and a family cannot tell XP from Windows 11.
- Every other set is open-ended, so it is keyed on the family. A new Windows id
  maps to `winmodern`, the newest Windows behavior.
- The family is optional. The server sends it as `osfamily=` on the kernel
  command line. When it is empty, FOS uses a built-in fallback for the ids it
  knows: 8 is `macos`, 9/10/11 are `windows`, 50/51 are `linux`, 99 is `other`.
  So an init works against a server that sends no `osfamily=`.
- A non-empty family wins over the fallback. `osid=9` with family `linux`
  gives `linux`. The server is authoritative.
- An empty family with an unknown osid calls `handleError`. A family outside
  the four values, for a non-frozen id, also calls `handleError` (ADR-0003).
- For an unknown osid, `osname` is `Windows (osid N)`, `Linux (osid N)`,
  `macOS (osid N)` or `Other OS (osid N)`, and `mbrfile` is empty.

## Why the family is an argument

`fog.checkin` and `fog.debug` pass `"$osfamily"`. `fog.capone` passes the
family from the eighth field of the chosen Capone line, because its image comes
from the Capone listing and not from the kernel command line. A plugin that
sends seven fields leaves `osfamily` empty, which `determineOS()` treats as
"not sent". `fog.capone` exports `osfamily`, because `fog` runs `fog.download`
and `fog.checkin` next, and they read `$osfamily` again. A global read inside
`determineOS()` would let a Capone image inherit a family meant for another
image. A new osid in a Capone listing resolves from its family when the plugin
sends the eighth field (fog-plugins v1.6.29 or later, on a core with
`Image::getOSFamily()`). From an older plugin the field is empty, and an
unknown osid still aborts (ADR-0003). See FOGProject/fog-plugins#43.

## Consequences

- Each site keeps the same branch for every existing osid, with the family
  empty or equal to the seeded family. This includes the differences between
  sites: `fog.upload` still uses `[4-7]` where other sites use `[5-7]`, which
  is `winother|win7|winmodern` there.
- One site did not keep its branch. `completeTasking()` tested
  `[[ $osid == +([1-2]|4|[5-7]|9|10|11) ]]`. The `+( )` repeats the group, so
  it also matched 51 and 99 by accident. Osid 50 did not match. The site now
  includes `other` only to keep the base's branch for osid 99. `changeHostname()`
  has no `99` or `other` arm, so for osid 99 `regfile` stays empty and no
  registry is written, on the base and now. What 99 keeps is the NTFS mount:
  `changeHostname` mounts each NTFS partition with `ntfs-3g -o
  remove_hiberfile,rw`, which removes `hiberfil.sys`. A failed mount aborts
  through `checkStatus` and `handleError`. 50 and 51 share a class, so a class
  test cannot keep 51. For osid 51 (Chromium OS), `changeHostname` no longer
  runs after a deploy, so the NTFS mount and the hiberfile removal are lost.
  It never wrote a registry.
- A function that takes `osid` as an argument (`savePartitionTablesAndBootLoaders`,
  `restorePartitionTablesAndBootLoaders`) now reads the global `osClass`. Its
  `osid` argument is still checked, and no longer decides a branch. Every
  caller passes the global `osid`, so the two agree.
- A test that calls a site function must call `determineOS "$osid"` first.

## Guard

`tests/checks/os-class.sh` holds the osid lists the sites had before the
change. It runs them against the `osClass` patterns in the real source for
every known osid, with the family empty and seeded. It also covers new ids,
the conflict, every error, the callers, and the absence of any osid
comparison outside `determineOS()`.
