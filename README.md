# WireGuard for Omarchy

An [Omarchy](https://omarchy.org) shell (Quickshell) bar widget for
**WireGuard** tunnels managed by `wg-quick`.

See tunnel and peer status at a glance, and open a panel
for live throughput, handshake age, latency, routes and DNS, with a switch to
connect or disconnect.

![The WireGuard panel](preview.png)

- **Bar icon** — a shield: green for recent peer handshakes, red for detected
  problems, orange for uncertain status, blue during tunnel actions and gray
  when disconnected. Hovering shows each tunnel's state, address and live rates.
- **Panel**
  - tunnel name, state, address and round-trip latency, with an on/off switch
  - live download/upload rates, a two-minute traffic graph and totals
  - endpoint (hostname *and* the IP it resolved to), last handshake, latency,
    tunnel address, DNS servers and routing domains, listen port and MTU, and
    the peer's key
  - the routes (AllowedIPs) the tunnel carries
  - a *Start at boot* switch, which enables or disables `wg-quick@NAME.service`
    (it changes the next boot only, not whether the tunnel is up now)
  - a list of every tunnel, each with its own switch, when you have more than one
  - reconnect, refresh and copy buttons
- **Notifications** when a tunnel drops, stops handshaking or recovers on its
  own. Changes you make from the widget report in the panel instead.
- A tunnel that is down shows its configuration (endpoint, address, routes,
  DNS), so you can see what connecting would do.

An up interface does not establish connectivity. The widget checks the actual
interface UP flag and evaluates each peer separately. Recent handshakes are
labelled as recent activity. An old handshake without `PersistentKeepalive`
is shown as idle, because inactivity alone does not establish failure. An old
handshake with keepalive configured produces a warning; its threshold is the
greater of three minutes and twice the keepalive interval plus two minutes.
A recent handshake from one peer cannot hide a warning from another. Latency
probes and traffic provide additional evidence, not a guarantee of connectivity.

| Badge color | Meaning |
|---|---|
| Green | All peers on active tunnels have recent handshakes. |
| Red | A peer with keepalive configured has stale handshakes, or an installed root helper has a permission, version or collection problem. |
| Orange | Waiting for a handshake, idle or partially active peers, unavailable readings, or peer information missing without the helper. Demo mode also uses orange. |
| Blue | Connecting, disconnecting or reconnecting through the widget. |
| Gray | No tunnel is up, or no tunnels are configured. |

The panel uses the same status colors. With multiple tunnels, red takes priority
over orange, and orange over green; configured tunnels that are down do not
downgrade an active tunnel's status. Idle tunnels use orange because their old
handshake provides limited evidence of current connectivity, even during normal
inactivity.

This fork retains the original widget's controls and monitoring features and
hardens its privileged helper, installer, state files and network probes.
The original plugin is by [Shane Poppleton](https://github.com/codemonkey76/omarchy-wireguard).

## Requirements

- Omarchy 4 ("Quattro") or newer, i.e. the Quickshell-based shell — not the
  older Waybar bar.
- `wireguard-tools` (`wg`, `wg-quick`), with tunnels defined as `wg-quick`
  configs in `/etc/wireguard/<name>.conf`.
- `jq`, Python 3 (standard library only), `ping`, `notify-send`, `wl-copy`,
  GNU coreutils and util-linux (`flock`). Python runs only as your user; it
  handles private state files, notification deduplication and network probes.
- systemd-resolved for the DNS row (optional) and for hostname probe targets.
  Hostname probes require DNS configured on the selected WireGuard link.
- The bundled root helper, installed once with `install-helper` (below), for
  configs, peers, handshakes and the switches.

## Install

```bash
omarchy plugin add https://github.com/timotej-hajduk/omarchy-wireguard --enable
~/.config/omarchy/plugins/omarchy-wireguard/install-helper
```

Or by hand:

```bash
git clone https://github.com/timotej-hajduk/omarchy-wireguard \
  ~/.config/omarchy/plugins/omarchy-wireguard
omarchy plugin enable omarchy-wireguard
~/.config/omarchy/plugins/omarchy-wireguard/install-helper
```

Either way the widget lands in the bar's right section: `--enable` and
`omarchy plugin enable` both place it. Move it later with
`omarchy bar move omarchy-wireguard --section left`.

`install-helper` asks for your sudo password once. Re-run it after updating
the plugin if the panel says the helper is out of date.
This version requires helper protocol **3**; controls refuse older copies.
Review and publish local changes to your fork before installing by its URL.
Editing this checkout does not install or upload anything by itself.

## The root helper

Reading peers, handshakes and `/etc/wireguard`, and running `wg-quick`, all
need root. The widget itself runs as you. Everything that needs root goes
through one small bundled script, `omarchy-wireguard-root`. `install-helper`
installs it root-owned, together with a sudoers rule that lets you, and only
you, run that one script without a password:

```
/usr/local/libexec/omarchy-wireguard/omarchy-wireguard-root   root:root 0755
/etc/sudoers.d/omarchy-wireguard                               root:root 0440
```

```
Cmnd_Alias OMARCHY_WIREGUARD_READ = /usr/local/libexec/omarchy-wireguard/omarchy-wireguard-root status, /usr/local/libexec/omarchy-wireguard/omarchy-wireguard-root version
Defaults!OMARCHY_WIREGUARD_READ !log_allowed, !pam_session
you ALL=(root) NOPASSWD: /usr/local/libexec/omarchy-wireguard/omarchy-wireguard-root
```

`install-helper` captures the helper in memory and hashes it before invoking
sudo. Root verifies that snapshot against the hash instead of reopening the
checkout. The installer rejects symlinks and non-root-owned or group/other
writable destination paths, serializes concurrent installs with a lock, stages
both files in root-only directories, checks their syntax (`bash -n`, `visudo -c`),
and renames them into place. It restores previous copies if replacement fails,
then verifies the installed version and checksum on success. This protects
the installation handoff; it does not establish that the source is trustworthy.

The helper does six things and nothing else:

| Command | Does |
|---|---|
| `version` | prints the helper's version, so the widget can spot a stale copy |
| `status` | describes every configured and live tunnel as JSON, without secrets |
| `up NAME` | `wg-quick up NAME` |
| `down NAME` | `wg-quick down NAME` |
| `enable NAME` | `systemctl enable wg-quick@NAME`, so the tunnel starts at boot |
| `disable NAME` | `systemctl disable wg-quick@NAME` |

`NAME` must be a bare tunnel name with a config already in `/etc/wireguard`,
never a path. That matters because `wg-quick` runs a config's
`PostUp`/`PostDown` hooks as root: a passwordless rule for `wg-quick` itself
would let anything running as you run any command as root, by pointing it at a
config of its own. The helper checks that `/etc/wireguard`, its ancestors and
the selected config are root-owned, have no group/other write permission and
are not symlinks. Configs must be regular files with no group/other permissions,
so private keys are not exposed through readable configs. A violation fails closed,
including during status collection. Recommended permissions are `root:root 0700`
for `/etc/wireguard` and `root:root 0600` for each config; the installer does not
change existing VPN configs or their permissions. Read permission for other
users is not needed by the widget. The installed helper is root-owned too, so updating the plugin
can't change what runs as root until you re-run `install-helper`.

The rule suppresses successful sudo logging and PAM sessions for the read-only
`status` and `version` calls. Control operations retain the system's normal
sudo logging, making tunnel and boot-setting changes auditable.

Private and preshared keys never leave the root helper. Configs are read
through a whitelist of non-secret keys (`Address`, `DNS`, `MTU`, `ListenPort`,
and each peer's `PublicKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive`).
Of `wg show dump`, only the peer lines are read, minus the preshared-key
column.

Without the root helper the widget still shows which interfaces are up, their
addresses, traffic and DNS, and the panel says what's missing and how to fix it.
If an installed helper fails or has the wrong version, the bar shows unavailable
status and disables controls instead of presenting incomplete readings as healthy.

The sudo rule deliberately permits your user to control existing, trusted VPN
configs without a password. Legitimate `wg-quick` hooks still execute as root.
An application already running as your user can invoke the same permitted
operations. These changes do not sandbox Quickshell plugins or protect against
malicious root-controlled hooks, a compromised account or dependencies.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "omarchy-wireguard",
  "refreshSeconds": 5,
  "notify": true,
  "labels": { "wg0": "Work" },
  "probe": { "wg0": "10.8.0.1" }
}
```

| Key | Default | Meaning |
|---|---|---|
| `refreshSeconds` | `5` | Poll interval while the panel is closed (it polls every 2 s while open). |
| `notify` | `true` | Desktop notifications when a tunnel drops, stops handshaking, or recovers. |
| `labels` | `{}` | Friendly names per interface, shown instead of `wg0`. |
| `probe` | `{}` | Host to ping for latency, per interface. Defaults to the tunnel's DNS server; `""` turns probing off for that tunnel. |

Probes use `ping -I <interface>` with numeric addresses. Hostname targets are
resolved explicitly through that WireGuard link using `resolvectl`, with its
cache disabled and no fallback to the default resolver. If scoped resolution
or interface-bound ping is unavailable, the panel reports a probe error.
No probe runs while the selected tunnel is down or its status is unavailable.

## Using it

| On the bar | |
|---|---|
| Left click | open the panel |
| Right click | connect / disconnect the tunnel |
| Middle click | refresh now |

| In the panel | |
|---|---|
| `t` | connect / disconnect |
| `c` | copy the tunnel address |
| `r` | refresh |
| `n` | next tunnel (with more than one) |
| `Tab` | switch to the neighbouring bar panel |

Click a tunnel in the list to show it in the header.

### From scripts and keybindings

```bash
omarchy-shell omarchy-wireguard toggle        # open/close the panel
omarchy-shell omarchy-wireguard toggleTunnel  # connect/disconnect
omarchy-shell omarchy-wireguard up wg0
omarchy-shell omarchy-wireguard down wg0
omarchy-shell omarchy-wireguard restart wg0
omarchy-shell omarchy-wireguard status
```

The bundled `omarchy-wireguard` script works on its own too:

```bash
omarchy-wireguard json            # every tunnel's state, as JSON
omarchy-wireguard up wg0          # also: down, restart
omarchy-wireguard enable wg0      # start at boot; disable to stop
omarchy-wireguard probe 10.8.0.1 wg0  # interface-bound round-trip time in ms
```

The earlier `probe HOST` form still works when exactly one WireGuard interface
is up. With several tunnels, provide the interface explicitly.

## How it works

`Panel.qml` polls the bundled `omarchy-wireguard` script, which runs as you
and gathers everything in one pass:

- interface state, addresses and MTU from `ip`
- traffic counters from `/sys/class/net`
- DNS servers and routing domains from `resolvectl`
- configs, peers, handshakes and per-peer transfer from a single
  `sudo -n` call to the root helper

Rates come from the difference between two polls. Connecting and disconnecting
go through the root helper's `up` and `down`, and the boot switch through its
`enable` and `disable`.

Failed, malformed, timed-out or expired status collection changes the bar to
an unavailable state. A separate clock ages handshakes even when polling fails.
Rates and graph history reset when an interface is recreated, counters reset
or readings have a long gap. Disappearing interfaces trigger disconnect
notifications, including when running without the root helper.

State markers and notification locks use an owned, private directory under
`$XDG_RUNTIME_DIR` (or `~/.cache` when unset). Symlinks, hardlinked markers,
unsafe ownership and writable paths are rejected. Notification arguments are
passed without a shell and their markup is escaped. Demo mode remains available
through the `demo` marker in that directory and is visibly labelled as simulated.

External commands have deadlines and captured output limits. Tunnel operations
have a two-minute limit, boot-setting changes thirty seconds, and panel status
collection fifteen seconds. A timeout can leave a partially completed operation;
the widget reports an error and refreshes the observed state.

`DNS =` in a config works only when `resolvconf` is installed. On a
systemd-resolved host the usual workaround is
`PostUp = resolvectl dns %i <server>`, and the root helper reads that form too.
Don't pair it with `PostDown = resolvectl revert %i`. PostDown runs after the
interface has been deleted, so the revert fails and `wg-quick down` exits with
an error. Use `PreDown` instead, or leave it out: systemd-resolved drops a
deleted link's DNS on its own. The widget copes either way. When the tunnel
ends up where you asked but a hook complained, it reports success and shows
the complaint as a note.

## Development checks

```bash
bash -n install-helper omarchy-wireguard omarchy-wireguard-root
python3 -m unittest discover -s tests -p 'test_*.py' -v
node tests/model-test.cjs
git diff --check
```

The tests use temporary files and mocked privileged commands, ownership metadata
and probes. They do not run sudo, change live tunnels or send network packets.
Node is only needed for the tests. Qt 6 `qmllint` can additionally validate
`Panel.qml` and `Model.js` when the installed Omarchy QML imports are available.

## Remove

```bash
~/.config/omarchy/plugins/omarchy-wireguard/install-helper --remove
omarchy plugin remove omarchy-wireguard
```

The first command removes the root helper and its sudoers rule, the second the
widget itself.
