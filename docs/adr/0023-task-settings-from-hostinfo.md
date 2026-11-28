# FOS reads its task settings from the server, not only from the kernel line

FOS gets every task setting from the kernel command line. Examples are the
image, the storage node, the OS, the multicast port and `winuser=`. `boot.php`
writes that line for any caller that sends the host's MAC. The values are
fixed when the machine PXE boots. A registration that deploys in the same boot
(FOS 1.6.1) must ask the server again. It asks through `status/hostgetkey.php`
and `service/hostinfo.php`.

We decided that **`service/hostinfo.php` becomes the source of a task's
settings, in two phases.** This ADR covers both and ships phase 1.

## What moves, and what stays on the kernel line

| Stays on the kernel line | Why |
|---|---|
| `web=`, `fogpin=` | FOS needs them to reach the server at all (ADR-0011, ADR-0020) |
| `ramdisk_size`, `loglevel`, `keymap`, `consoleblank`, `setmacto`, `ipv6boot`, `root`, `initrd` | the kernel or the boot scripts read them before any network call |
| `mode=` of a menu entry (registration, debug, Secure Boot enrollment), `fogtoken=` | there is no task, so `hostinfo.php` cannot answer (`Invalid tasking!`) |
| kernel flags with no `=` (`debug`, `nomodeset`) | they are for the kernel, not variables |

Everything else is task data and moves: `type`, `img`, `imgid`, `imgFormat`,
`imgType`, `imgPartitionType`, `osid`, `osfamily`, `storage`, `storageip`,
`ftp`, `mac`, `hostname`, `chkdsk`, `PIGZ_COMP`, `mcastrdv`, `port`,
`mcastMaxWait`, `pct`, `ignorepg`, `winuser`, `isdebug`, `shutdown`,
`hostearly`, `seconds`, `bitlockerbypass`, `fdrive`, and the task type's own
arguments.

## Phase 1 (this change): FOS prefers the server, the server still sends all

- The server adds `taskinfo=1` to the kernel line of a FOS task boot for a
  registered host. It never adds it to a menu boot or to a hostless
  (unregistered) task.
- `hostinfo.php` sends the same task values as the kernel line, because one
  function builds both. `BootMenuBase::taskKernelArgs()` returns the task
  arguments, and `flattenKernelArgs()` orders and de-duplicates them.
  `boot.php` prints the result, and `hostinfo.php` sends it. The node is the
  one the task recorded at boot. `loadTaskInfo()` posts `taskinfo=1`, so
  `hostinfo.php` does not ask a plugin such as Location to choose again. A
  registration that continues in the same boot does not post it. Its task
  never went through the boot menu, so the plugin's choice still applies.
- For a multicast task, both paths use the session's image when it differs
  from the task's image. Before this change, the kernel line named the task's
  image while the stream carried the session's. So the precedence is the same too. The task
  type's arguments come first, then `FOG_KERNEL_ARGS`, then the host's own
  kernel arguments. The last one wins.
- `hostinfo.php` sends a task variable only when the kernel line carries it.
  One input reaches only the kernel line: the `extraargs` of the iPXE chain,
  which can set `shutdown=1`. `hostinfo.php` then sends no `shutdown`, so the
  kernel's value stands.
- `S99fog` calls `loadTaskInfo()` once per boot, before it reads `isdebug` and
  `shutdown`. It acts only when `taskinfo=1` and `web=` are set and the boot
  is not from USB. It then gets the host key and the `hostinfo.php` reply. `writeHostInfoOverride()` writes
  the reply's values to `/tmp/hinfo.continue`. `S99fog` sources that file, and
  `funcs.sh` sources it in every script after the kernel arguments. So the
  server's values win everywhere, debug tasks included.
- **Any failure keeps the kernel line.** FOS prints one line and runs on the
  kernel arguments, as it always did. A failure is a refused key, an error
  body, a transfer that curl reports as failed, or an old server. A key is
  refused, for example, for a caller outside `FOG_HOSTKEY_ALLOWED_SOURCES`.
- An old init ignores `taskinfo=1`. A new init on an old server never sees it.
  Only a new init on a new server changes: it takes its values from
  `hostinfo.php`.

## The reply is filtered, not sourced

`writeHostInfoOverride()` splits the reply into shell statements, with the
shell's own quoting rules, so a value can span lines. It keeps a statement
only when it has the form `[[ -z $NAME ]] && export NAME='...'`, which is what
`hostinfo.php` prints. The value must be exactly one `escapeshellarg()` token.
It strips the `[[ -z $NAME ]] && ` guard, so the server's value wins. It drops
every other statement, so an error body or extra shell never runs.

It also drops `hostadpass` and `hostproductkey`. FOS does not hold the Active
Directory join password or the product key. A post-download script that needs
them asks the server itself (fog-docs `kb/how-tos/post-download-scripts.md`).
`hostinfo.php` unlocks and rotates the host token after it answers, so that
script can still get its own token. `continueIntoTask()` uses the same writer,
so it no longer carries the two values either.

Every task boot now asks for a host key, so the key must not stay locked
after a failure. Before this change, only a successful `hostinfo.php` answer
unlocked it. A host that lost power between the two requests stayed locked
until its task ended. Its next boot, and any post-download script, got "Host
token is currently in use". The server now treats the key as a one-time
token:

- `hostinfo.php` consumes the key as soon as it matches, before it builds
  the reply. A failure after that point cannot leave it locked.
- A key is valid for 120 seconds. After that, `hostgetkey.php` treats the
  lock as abandoned and issues a new key, and the old one stops working.
- The database stores only a hash of the key, and `hostgetkey.php` never
  hands out a stored key again.

## Phase 2 (later): the server stops sending the task data

Phase 2 starts when every supported init has `loadTaskInfo()`. The server
then drops the task data from the kernel line. It keeps only the "stays" set
above. That is a separate
change with its own floor. Two things change then:

- A refused key stops the task instead of falling back, because there is
  nothing to fall back to. FOS must then say which setting refused it
  (`FOG_HOSTKEY_ALLOWED_SOURCES`), per ADR-0003.
- `winuser=` and the rest no longer appear in the `boot.php` output that any
  MAC can fetch. They sit behind the one-time host token instead.

## Why not move it all at once

The server and the init ship separately, and stable installs keep a pinned
init. Removing the kernel variables first would leave every pinned init with
no task data. Phase 1 makes the new path real, and the kernel line keeps every
old init working while the new one takes over.

## Consequences

- Each FOS task boot makes two more requests (`hostgetkey.php`,
  `hostinfo.php`).
- A parity gap between `hostinfo.php` and the kernel line now changes what FOS
  does. Before this change, `hostinfo.php` computed the values a second time.
  Six of them differed: `mac`, `storage` for a task that does not image,
  `storageip`, the imaging-only fields, `shutdown`, and the de-duplication.
  One builder removes that class of bug. A fogproject parity test compares
  the two outputs.
- The USB boot and `continueIntoTask()` read the same reply, so they now get
  the kernel line's values too.
- The kernel line is still the fallback in phase 1, so a broken `hostinfo.php`
  costs nothing worse than today's behavior.

## References

- ADR-0011 (boot-time config channel), ADR-0020 (`fogpin=`), ADR-0003 (fail loud).
- `usr/share/fog/lib/funcs.sh`: `loadTaskInfo()`, `writeHostInfoOverride()`,
  `fetchHostInfo()`, `continueIntoTask()`.
- fogproject `packages/web/service/hostinfo.php`, `src/Boot/BootMenuBase.php`.
