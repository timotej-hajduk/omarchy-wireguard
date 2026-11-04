import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: wg
  moduleName: "omarchy-wireguard"
  ipcTarget: "omarchy-wireguard"
  manageIpc: false

  // ---- Configuration ------------------------------------------------------
  // Everything privileged goes through the bundled omarchy-wireguard, resolved
  // relative to this file so the plugin is self-contained (`omarchy plugin add`
  // clones QML, not anything on PATH) and invoked via bash so it works whether
  // or not the exec bit survived the clone.
  readonly property string cli: decodeURIComponent(String(Qt.resolvedUrl("omarchy-wireguard")).replace(/^file:\/\//, ""))
  readonly property int refreshSeconds: Math.max(2, Math.min(300, parseInt(setting("refreshSeconds", 5), 10) || 5))
  readonly property bool notifyChanges: setting("notify", true) !== false
  readonly property var labels: setting("labels", ({}))
  readonly property var probeSettings: setting("probe", ({}))
  readonly property int historyLength: 60

  // ---- State --------------------------------------------------------------
  // Keep the last reading for context, but show unavailable status whenever
  // collection fails or the reading expires.
  property var status: null
  property bool everLoaded: false
  property bool failed: false
  readonly property var tunnels: status ? status.tunnels : []
  property double now: Date.now() / 1000
  property double lastSuccess: 0
  readonly property bool statusFresh: Model.fresh(everLoaded, failed, lastSuccess, now, refreshSeconds)
  readonly property bool privileged: status ? status.privileged === true : false
  readonly property var helper: status && status.helper ? status.helper : null
  readonly property bool helperReady: privileged && helper && helper.version === helper.expected
  readonly property bool helperProblem: everLoaded && helper !== null && helper.installed && !helperReady
  readonly property bool demoMode: status && status.demo === true
  readonly property bool statusAvailable: statusFresh && (!helper || !helper.installed || helperReady)
  readonly property string pluginDir: cli.replace(/\/[^\/]*$/, "").replace(Quickshell.env("HOME"), "~")

  // Why configs, peers and the switches are missing, when they are: the root
  // helper isn't installed, is older than the copy this plugin ships, or
  // isn't answering.
  readonly property string helperMessage: {
    if (!everLoaded) return ""
    var fix = "Run " + pluginDir + "/install-helper to fix."
    if (!helper) return privileged ? "" : "Configs, peers and connect/disconnect need the root helper. " + fix
    if (!helper.installed) return "Configs, peers and connect/disconnect need the root helper. " + fix
    if (helper.error) return "Privileged status unavailable: " + String(helper.error)
    if (helper.expected && helper.version !== helper.expected) return "The root helper is out of date. " + fix
    if (!privileged) return "The root helper isn't answering. " + String(helper.error || "") + " " + fix
    return ""
  }

  property var rates: Object.create(null)
  property var history: Object.create(null)
  property var previous: Object.create(null)
  property var latency: Object.create(null)
  property var latencyErrors: Object.create(null)
  property var lastStates: Object.create(null)
  property var lastTunnels: Object.create(null)

  property string selectedName: ""
  property string busyTunnel: ""
  property string busyVerb: ""
  property string message: ""
  property bool messageIsError: false

  // The hero shows one tunnel: the one picked in the list, else the first
  // that is up, else the first configured.
  readonly property var selected: {
    var list = tunnels || []
    for (var i = 0; i < list.length; i++) if (list[i].name === selectedName) return list[i]
    for (var j = 0; j < list.length; j++) if (list[j].up) return list[j]
    return list.length ? list[0] : null
  }
  readonly property string selectedState: statusAvailable ? Model.state(selected, now) : "unknown"
  readonly property bool selectedUp: statusAvailable && selected !== null && selected.up === true
  readonly property bool selectedStale: selectedState === "stale" || selectedState === "connecting"
  readonly property var selectedRates: selected && rates[selected.name] ? rates[selected.name] : null
  readonly property var selectedRoutes: Model.routes(selected)
  readonly property var selectedDns: Model.dnsServers(selected)
  readonly property string selectedProbeHost: Model.probeHost(selected, probeSettings)
  readonly property var selectedProbeReading: selected ? latency[selected.name] : null
  readonly property var selectedLatency: selectedProbeReading && selectedProbeReading.host === selectedProbeHost
    && selectedProbeReading.ifindex === selected.ifindex && now >= selectedProbeReading.time
    && now - selectedProbeReading.time <= 12 ? selectedProbeReading.ms : undefined
  readonly property var selectedPeer: {
    if (!selected) return null
    if (Array.isArray(selected.peers) && selected.peers.length) return selected.peers[0]
    if (selected.config && selected.config.peers && selected.config.peers.length) return selected.config.peers[0]
    return null
  }
  // Whether wg-quick@NAME.service is enabled; null when the helper can't say
  // (it predates the switch, or systemd can't take the name), which hides it.
  readonly property var selectedAutostart: selected && selected.config && typeof selected.config.autostart === "boolean"
    ? selected.config.autostart : null
  readonly property bool bootBusy: bootProc.running
  readonly property bool canDrive: statusAvailable && helperReady && selected !== null && selected.configured && busyTunnel === ""
  readonly property string overallState: !statusAvailable ? "unknown" : busyTunnel !== "" ? "busy" : Model.overall(tunnels, now)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color healthyColor: "#4ade80"
  readonly property color problemColor: "#f87171"
  readonly property color uncertainColor: "#fb923c"
  readonly property color busyColor: "#60a5fa"
  readonly property color inactiveColor: "#9ca3af"
  readonly property color badgeColor: demoMode ? uncertainColor : stateColor(overallState)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string busyLabel: busyVerb === "up" ? "Connecting…"
    : busyVerb === "down" ? "Disconnecting…" : "Reconnecting…"

  readonly property string heroMeta: {
    if (!everLoaded) return failed ? "Couldn't read status" : "Loading…"
    // Only the helper can see /etc/wireguard; without it, an empty list says
    // nothing is up, not that nothing is configured.
    if (!statusAvailable) return "Status unavailable — refresh to retry"
    if (!selected) return privileged ? "No tunnels in /etc/wireguard" : "No interface detected"
    var parts = [busyTunnel === selected.name ? busyLabel : Model.stateLabel(selectedState)]
    var address = Model.primaryAddress(selected)
    if (address) parts.push(address)
    return parts.join("  ·  ")
  }

  readonly property string latencyText: !selectedUp || selectedProbeHost === "" ? ""
    : selected && latencyErrors[selected.name] ? "Probe unavailable"
    : selectedLatency === undefined ? ""
    : selectedLatency === null ? "no reply" : Math.round(selectedLatency) + " ms"

  readonly property string tooltipText: !everLoaded
    ? (failed ? "WireGuard — couldn't read status" : "WireGuard — loading…")
    : Model.tooltip(tunnels, now, labels, rates, privileged, statusAvailable, demoMode)

  function stateColor(st) {
    if (st === "stale" || (st === "unknown" && helperProblem)) return problemColor
    if (st === "connected") return healthyColor
    if (st === "busy") return busyColor
    if (st === "down" || st === "none") return inactiveColor
    return uncertainColor
  }

  function tunnelNamed(name) {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === name) return tunnels[i]
    return null
  }

  function withKey(obj, key, value) {
    var next = Object.create(null)
    for (var k in obj) next[k] = obj[k]
    next[key] = value
    return next
  }

  function flash(text, isError) {
    message = text
    messageIsError = isError === true
    messageTimer.restart()
  }

  function selectNext() {
    if (tunnels.length < 2 || !selected) return
    for (var i = 0; i < tunnels.length; i++) {
      if (tunnels[i].name === selected.name) {
        selectedName = tunnels[(i + 1) % tunnels.length].name
        return
      }
    }
  }

  function copy(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    flash("Copied " + (text.length > 24 ? Model.shortKey(text) : text), false)
  }

  // Every monitor runs its own copy of this widget and each sees the same
  // change; the helper sends the first and drops repeats within 30s.
  function notify(name, st, summary, body) {
    Quickshell.execDetached(["bash", wg.cli, "notify", name, st, summary, body || ""])
  }

  // ---- Reading ------------------------------------------------------------
  function refresh() {
    if (statusProc.running || statusProc.collecting) return
    statusProc.collecting = true
    statusProc.outputReady = false
    statusProc.exitReady = false
    statusProc.expired = false
    statusProc.output = ""
    statusProc.command = ["bash", "-c", 'set -o pipefail; timeout -k 2 15 bash "$0" json | head -c 131073', wg.cli]
    statusWatchdog.restart()
    statusProc.running = true
  }

  function ingest(parsed) {
    var t = Date.now() / 1000
    var nextRates = Object.create(null), nextPrevious = Object.create(null), nextHistory = Object.create(null)
    for (var i = 0; i < parsed.tunnels.length; i++) {
      var tn = parsed.tunnels[i]
      if (!tn.up) continue
      var p = previous[tn.name]
      var h = (history[tn.name] || []).slice()
      // Counters restart from zero when wg-quick re-creates the interface;
      // start the graph over instead of plotting a huge negative rate.
      if (p && (tn.rx < p.rx || tn.tx < p.tx || p.ifindex !== tn.ifindex
          || t <= p.t || t - p.t > Math.max(15, refreshSeconds * 3))) { p = null; h = [] }
      if (p && t > p.t) {
        var r = { rx: (tn.rx - p.rx) / (t - p.t), tx: (tn.tx - p.tx) / (t - p.t) }
        nextRates[tn.name] = r
        h.push(r)
        while (h.length > historyLength) h.shift()
      } else {
        nextRates[tn.name] = null
      }
      nextPrevious[tn.name] = { rx: tn.rx, tx: tn.tx, t: t, ifindex: tn.ifindex }
      nextHistory[tn.name] = h
    }
    rates = nextRates
    previous = nextPrevious
    history = nextHistory
    announce(parsed)
    status = parsed
    now = t
    lastSuccess = t
    everLoaded = true
    failed = false
  }

  function announce(parsed) {
    var next = Object.create(null), nextTunnels = Object.create(null)
    for (var i = 0; i < parsed.tunnels.length; i++) {
      var tn = parsed.tunnels[i]
      var st = Model.state(tn, parsed.now)
      next[tn.name] = st
      nextTunnels[tn.name] = tn
      var before = lastStates[tn.name]
      if (!everLoaded || before === undefined || before === st) continue
      // Changes made through the helper (this widget on any monitor, or
      // omarchy-wireguard from a terminal) report themselves; notifications
      // are for what happens on its own. drivenAt is the backend's clock, as
      // is parsed.now.
      if (tn.drivenAt && parsed.now - tn.drivenAt < 20) continue
      if (!notifyChanges) continue
      var name = Model.label(tn, labels)
      if (st === "stale") notify(tn.name, st, name + " — handshake warning", "No recent handshake while keepalives are configured.")
      else if (st === "connected" && before === "stale") notify(tn.name, st, name + " — reconnected", "Handshakes are flowing again.")
      else if (st === "connected") notify(tn.name, st, name + " — connected", Model.primaryAddress(tn))
      else if (st === "down") notify(tn.name, st, name + " — disconnected", "The tunnel went down.")
    }
    for (var gone in lastStates) {
      if (next[gone] !== undefined || lastStates[gone] === "down" || !notifyChanges || !everLoaded) continue
      var prior = lastTunnels[gone] || { name: gone }
      var removed = parsed.now - Number(prior.drivenAt || 0) < 20
      if (!removed) notify(gone, "down", Model.label(prior, labels) + " — disconnected", "The WireGuard interface disappeared.")
    }
    lastStates = next
    lastTunnels = nextTunnels
  }

  Process {
    id: statusProc
    property bool collecting: false
    property bool outputReady: false
    property bool exitReady: false
    property bool expired: false
    property int code: -1
    property string output: ""
    function finish() {
      if (!outputReady || !exitReady) return
      collecting = false
      statusWatchdog.stop()
      var parsed = code === 0 && !expired ? Model.parse(output) : null
      if (parsed) wg.ingest(parsed)
      else wg.failed = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        statusProc.output = text
        statusProc.outputReady = true
        statusProc.finish()
      }
    }
    onExited: function(exitCode) {
      code = exitCode
      exitReady = true
      finish()
    }
  }

  Timer {
    id: statusWatchdog
    interval: 18000
    onTriggered: {
      wg.failed = true
      statusProc.expired = true
      if (statusProc.running) statusProc.signal(15)
      else statusProc.collecting = false
    }
  }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: wg.now = Date.now() / 1000 }

  // Poll faster while the panel is open — the rates and the graph are live
  // there; the closed bar icon only needs to notice state changes.
  Timer {
    interval: (wg.opened ? 2 : wg.refreshSeconds) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: wg.refresh()
  }

  // ---- Latency ------------------------------------------------------------
  function probe() {
    if (probeProc.running || !selectedUp || selectedProbeHost === "") return
    probeProc.tunnelName = selected.name
    probeProc.host = selectedProbeHost
    probeProc.interfaceIndex = selected.ifindex || 0
    probeProc.command = ["timeout", "-k", "1", "16", "bash", wg.cli, "probe", selectedProbeHost, selected.name]
    probeWatchdog.restart()
    probeProc.running = true
  }

  Process {
    id: probeProc
    property string tunnelName: ""
    property string host: ""
    property int interfaceIndex: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = null
        try { result = JSON.parse(String(text || "").trim()) } catch (e) {}
        if (!wg.selectedUp || wg.selected.name !== probeProc.tunnelName
            || (wg.selected.ifindex || 0) !== probeProc.interfaceIndex || wg.selectedProbeHost !== probeProc.host) return
        if (result && result.ok !== false && result.host === probeProc.host) {
          wg.latency = wg.withKey(wg.latency, probeProc.tunnelName,
            {ms: result.ms, host: probeProc.host, ifindex: wg.selected.ifindex, time: Date.now() / 1000})
          wg.latencyErrors = wg.withKey(wg.latencyErrors, probeProc.tunnelName, "")
        } else wg.latencyErrors = wg.withKey(wg.latencyErrors, probeProc.tunnelName, result ? result.error : "Probe failed")
      }
    }
    onExited: function(exitCode) {
      probeWatchdog.stop()
      if (exitCode !== 0 && wg.selectedUp && wg.selected.name === tunnelName
          && (wg.selected.ifindex || 0) === interfaceIndex && wg.selectedProbeHost === host)
        wg.latencyErrors = wg.withKey(wg.latencyErrors, tunnelName, "Probe failed or timed out")
    }
  }

  Timer { id: probeWatchdog; interval: 18000; onTriggered: if (probeProc.running) probeProc.signal(15) }

  Timer {
    interval: 4000
    running: wg.opened && wg.selectedUp && wg.selectedProbeHost !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: wg.probe()
  }

  // ---- Driving ------------------------------------------------------------
  function drive(verb, tunnel) {
    if (!statusAvailable || !helperReady || !tunnel || !tunnel.configured || driveProc.running) return
    busyTunnel = tunnel.name
    busyVerb = verb
    message = ""
    messageIsError = false
    driveProc.verb = verb
    driveProc.tunnelName = tunnel.name
    driveProc.command = ["bash", wg.cli, verb, tunnel.name]
    driveProc.running = true
  }

  function toggleTunnel(tunnel) {
    if (!tunnel) return
    drive(tunnel.up ? "down" : "up", tunnel)
  }

  function doneText(verb, name) {
    var label = Model.label(tunnelNamed(name) || { name: name }, labels)
    return label + (verb === "up" ? " connected" : verb === "down" ? " disconnected" : " reconnected")
  }

  // Result and exit can arrive in either order: the stream carries the
  // specific message, the exit only a fallback for when it said nothing.
  Process {
    id: driveProc
    property string verb: ""
    property string tunnelName: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = null
        try { result = JSON.parse(String(text || "").trim()) } catch (e) {}
        if (result && result.ok === false) wg.flash(result.error || (driveProc.verb + " failed"), true)
        else if (result && result.ok === true)
          wg.flash(wg.doneText(driveProc.verb, driveProc.tunnelName) + (result.warning ? "  —  " + result.warning : ""), false)
      }
    }
    onExited: function(exitCode) {
      wg.busyTunnel = ""
      wg.busyVerb = ""
      if (exitCode !== 0 && !wg.messageIsError) wg.flash(driveProc.verb + " " + driveProc.tunnelName + " failed", true)
      wg.refresh()
    }
  }

  // ---- Start at boot ------------------------------------------------------
  // Enables or disables wg-quick@NAME.service. The tunnel stays up or down as
  // it is; that is the power switch's job.
  function setAutostart(tunnel, on) {
    if (!statusAvailable || !helperReady || !tunnel || !tunnel.configured || bootProc.running) return
    bootProc.autostart = on
    bootProc.tunnelName = tunnel.name
    bootProc.command = ["bash", wg.cli, on ? "enable" : "disable", tunnel.name]
    bootProc.running = true
  }

  Process {
    id: bootProc
    property bool autostart: false
    property string tunnelName: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = null
        try { result = JSON.parse(String(text || "").trim()) } catch (e) {}
        var label = Model.label(wg.tunnelNamed(bootProc.tunnelName) || { name: bootProc.tunnelName }, wg.labels)
        if (result && result.ok === true) wg.flash(label + (bootProc.autostart ? " will start at boot" : " won't start at boot"), false)
        else wg.flash(result && result.error ? result.error : "Couldn't change whether " + label + " starts at boot", true)
      }
    }
    onExited: wg.refresh()
  }

  Timer {
    id: messageTimer
    // Long enough to read: errors and warnings linger, "Copied …" doesn't.
    interval: wg.messageIsError ? 8000 : (wg.message.length > 40 ? 6000 : 2500)
    onTriggered: wg.message = ""
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "omarchy-wireguard"

    function open(): void { wg.open() }
    function close(): void { wg.close() }
    function toggle(): void { wg.toggle() }
    function refresh(): void { wg.refresh() }
    function toggleTunnel(): void { wg.toggleTunnel(wg.selected) }
    function up(name: string): void { wg.drive("up", wg.tunnelNamed(name)) }
    function down(name: string): void { wg.drive("down", wg.tunnelNamed(name)) }
    function restart(name: string): void { wg.drive("restart", wg.tunnelNamed(name)) }
    function status(): string { return wg.tooltipText }
  }

  // ---- Bar ----------------------------------------------------------------
  // Match the panel's status colors without the bar theme overriding them.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: wg.bar
    text: wg.overallState === "busy" ? Model.ICON_BUSY : Model.icon(wg.overallState)
    foreground: wg.badgeColor
    useActiveColor: false
    dimmed: wg.overallState === "down" || wg.overallState === "none"
    tooltipText: wg.opened ? "" : wg.tooltipText
    onPressed: function(b) {
      if (b === Qt.RightButton) wg.toggleTunnel(wg.selected)
      else if (b === Qt.MiddleButton) wg.refresh()
      else wg.toggle()
    }
  }

  // ---- Panel --------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: wg
    bar: wg.bar
    open: wg.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: wg.close()
      onTabRequested: function(direction) { wg.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") wg.toggleTunnel(wg.selected)
        else if (t === "r" || t === "R") wg.refresh()
        else if (t === "c" || t === "C") wg.copy(Model.primaryAddress(wg.selected))
        else if (t === "n" || t === "N") wg.selectNext()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ---------- Hero: state · name · address · latency · switch ----------
          PanelHero {
            id: hero
            width: parent.width
            title: wg.selected ? Model.label(wg.selected, wg.labels) : "WireGuard"
            meta: wg.heroMeta
            detail: wg.latencyText
            foreground: wg.fg
            fontFamily: wg.fontFamily
            iconOpacity: wg.selectedUp ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: wg.selected && wg.busyTunnel === wg.selected.name ? Model.ICON_BUSY : Model.icon(wg.selectedState)
                color: wg.stateColor(wg.selected && wg.busyTunnel === wg.selected.name ? "busy" : wg.selectedState)
                font.family: wg.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: wg.selected !== null && wg.selected.configured && wg.privileged
                checked: wg.selectedUp
                busy: wg.selected !== null && wg.busyTunnel === wg.selected.name
                interactive: wg.canDrive
                foreground: wg.fg
                onToggled: wg.toggleTunnel(wg.selected)

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: wg.selectedUp ? "Disconnect  (t)" : "Connect  (t)"
                  fontFamily: wg.fontFamily
                }
              }
            }
          }

          Text {
            visible: wg.demoMode
            width: parent.width
            text: "DEMO MODE — simulated tunnel data"
            textFormat: Text.PlainText
            color: wg.uncertainColor
            font.family: wg.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: wg.message !== ""
            width: parent.width
            text: wg.message
            textFormat: Text.PlainText
            color: wg.messageIsError ? wg.urgent : wg.dim
            font.family: wg.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: wg.helperMessage !== ""
            width: parent.width
            text: wg.helperMessage
            textFormat: Text.PlainText
            color: wg.dim
            font.family: wg.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- Traffic: live rates, graph, totals ----------
          PanelSeparator {
            visible: trafficSection.visible
            foreground: wg.fg
          }

          Column {
            id: trafficSection
            visible: wg.selectedUp
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: trafficHeader.implicitHeight

              PanelSectionHeader {
                id: trafficHeader
                text: "TRAFFIC"
                foreground: wg.fg
                fontFamily: wg.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: wg.selected ? Model.ICON_RX + " " + Model.human(wg.selected.rx) + "   " + Model.ICON_TX + " " + Model.human(wg.selected.tx) + "  total" : ""
                textFormat: Text.PlainText
                color: wg.dim
                font.family: wg.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              spacing: Style.space(22)

              RateLabel {
                icon: Model.ICON_RX
                value: wg.selectedRates ? Model.rate(wg.selectedRates.rx) : "—"
                tint: wg.accent
              }

              RateLabel {
                icon: Model.ICON_TX
                value: wg.selectedRates ? Model.rate(wg.selectedRates.tx) : "—"
                tint: wg.dim
              }
            }

            // Download is the filled accent trace, upload the thin line. The
            // scale follows the busiest sample in view.
            Canvas {
              id: spark
              width: parent.width
              height: Style.space(44)
              readonly property var samples: wg.selected && wg.history[wg.selected.name] ? wg.history[wg.selected.name] : []

              onSamplesChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()

              function rgba(c, a) {
                return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
              }

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = rgba(wg.fg, 0.12)
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(0, height - 0.5)
                ctx.lineTo(width, height - 0.5)
                ctx.stroke()

                var s = samples
                if (s.length < 2) return
                var peak = 1
                for (var i = 0; i < s.length; i++) peak = Math.max(peak, s[i].rx, s[i].tx)
                var step = width / Math.max(1, wg.historyLength - 1)
                var x0 = width - (s.length - 1) * step
                var h = height - 3
                function y(v) { return 1.5 + h - (v / peak) * h }
                function trace(key) {
                  ctx.beginPath()
                  for (var j = 0; j < s.length; j++) {
                    if (j === 0) ctx.moveTo(x0, y(s[j][key]))
                    else ctx.lineTo(x0 + j * step, y(s[j][key]))
                  }
                }

                trace("rx")
                ctx.lineTo(x0 + (s.length - 1) * step, height)
                ctx.lineTo(x0, height)
                ctx.closePath()
                ctx.fillStyle = rgba(wg.accent, 0.16)
                ctx.fill()

                trace("rx")
                ctx.strokeStyle = rgba(wg.accent, 0.9)
                ctx.lineWidth = 1.5
                ctx.stroke()

                trace("tx")
                ctx.strokeStyle = rgba(wg.fg, 0.45)
                ctx.lineWidth = 1
                ctx.stroke()
              }
            }
          }

          // ---------- Connection (or configuration, when down) ----------
          PanelSeparator {
            visible: detailsSection.visible
            foreground: wg.fg
          }

          Column {
            id: detailsSection
            visible: wg.selected !== null
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: wg.selectedUp ? "CONNECTION" : "CONFIGURATION"
              foreground: wg.fg
              fontFamily: wg.fontFamily
            }

            InfoRow {
              visible: wg.selectedPeer !== null
              icon: Model.ICON_ENDPOINT
              label: "Endpoint"
              value: Model.endpoint(wg.selectedPeer)
              copyValue: wg.selectedPeer ? (wg.selectedPeer.endpointHost || wg.selectedPeer.endpoint || "") : ""
            }

            // No icon: it reads as the second line of the endpoint above.
            InfoRow {
              visible: Model.resolvedEndpoint(wg.selectedPeer) !== ""
              label: "Resolves to"
              value: Model.resolvedEndpoint(wg.selectedPeer)
              copyValue: Model.resolvedEndpoint(wg.selectedPeer)
            }

            InfoRow {
              visible: wg.selectedUp && wg.selected && Array.isArray(wg.selected.peers)
              icon: Model.ICON_CLOCK
              label: "Latest HS"
              value: Model.handshakeText(wg.selected, wg.now)
              valueColor: wg.selectedStale ? wg.urgent : wg.fg
            }

            InfoRow {
              visible: wg.selectedUp && wg.selectedProbeHost !== ""
              icon: Model.ICON_PULSE
              label: "Latency"
              value: (wg.latencyText || "measuring…") + "  to " + wg.selectedProbeHost
              valueColor: wg.selectedLatency === null ? wg.urgent : wg.fg
            }

            InfoRow {
              visible: Model.addresses(wg.selected).length > 0
              icon: Model.ICON_ROUTE
              label: "Address"
              value: Model.addresses(wg.selected).join(", ")
              copyValue: Model.primaryAddress(wg.selected)
            }

            InfoRow {
              visible: wg.selectedDns.length > 0
              icon: Model.ICON_DNS
              label: "DNS"
              value: wg.selectedDns.join(", ")
                + (wg.selected && wg.selected.domains && wg.selected.domains.length ? "  ·  " + wg.selected.domains.join(" ") : "")
            }

            InfoRow {
              visible: wg.selectedUp && wg.selected.listenPort !== null
              icon: Model.ICON_LISTEN
              label: "Listen · MTU"
              value: wg.selected ? String(wg.selected.listenPort) + "  ·  " + String(wg.selected.mtu || "—") : ""
            }

            InfoRow {
              visible: wg.selectedPeer !== null
              icon: Model.ICON_KEY
              label: "Peer key"
              value: wg.selectedPeer ? Model.shortKey(wg.selectedPeer.publicKey) : ""
              copyValue: wg.selectedPeer ? wg.selectedPeer.publicKey : ""
            }

            SwitchRow {
              visible: wg.privileged && wg.selected !== null && wg.selected.configured && wg.selectedAutostart !== null
              icon: Model.ICON_BOOT
              label: "Start at boot"
              checked: wg.selectedAutostart === true
              busy: wg.bootBusy
              interactive: wg.statusAvailable && wg.helperReady
              hint: wg.selected ? (wg.selectedAutostart ? "Disable" : "Enable") + " wg-quick@" + wg.selected.name + ".service" : ""
              onToggled: wg.setAutostart(wg.selected, wg.selectedAutostart !== true)
            }
          }

          // ---------- Routes carried by the tunnel ----------
          PanelSeparator {
            visible: routesSection.visible
            foreground: wg.fg
          }

          Column {
            id: routesSection
            visible: wg.selectedRoutes.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ROUTES"
              foreground: wg.fg
              fontFamily: wg.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: wg.selectedRoutes

                Rectangle {
                  id: chip
                  required property string modelData
                  width: chipText.implicitWidth + Style.space(12)
                  height: chipText.implicitHeight + Style.space(6)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(wg.fg, wg.selectedUp ? 0.3 : 0.15)

                  Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: chip.modelData
                    textFormat: Text.PlainText
                    color: wg.selectedUp ? wg.fg : wg.dim
                    font.family: wg.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // ---------- Every tunnel, when there is more than one ----------
          PanelSeparator {
            visible: tunnelsSection.visible
            foreground: wg.fg
          }

          Column {
            id: tunnelsSection
            visible: wg.tunnels.length > 1
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "TUNNELS"
              foreground: wg.fg
              fontFamily: wg.fontFamily
            }

            Repeater {
              model: wg.tunnels
              TunnelRow {
                required property var modelData
                width: tunnelsSection.width
                tunnel: modelData
              }
            }
          }

          // ---------- Actions ----------
          Item {
            visible: wg.selected !== null
            width: parent.width
            implicitHeight: actions.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "t toggle · c copy · r refresh" + (wg.tunnels.length > 1 ? " · n next" : "")
              textFormat: Text.PlainText
              color: wg.dim
              opacity: 0.8
              font.family: wg.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              id: actions
              anchors.right: parent.right
              spacing: Style.space(4)

              PanelActionButton {
                iconText: Model.ICON_COPY
                tooltipText: "Copy address"
                foreground: wg.fg
                fontFamily: wg.fontFamily
                enabled: Model.primaryAddress(wg.selected) !== ""
                onClicked: wg.copy(Model.primaryAddress(wg.selected))
              }

              PanelActionButton {
                iconText: Model.ICON_RESTART
                tooltipText: "Reconnect"
                foreground: wg.fg
                fontFamily: wg.fontFamily
                enabled: wg.canDrive && wg.selectedUp
                opacity: enabled ? 1.0 : 0.4
                onClicked: wg.drive("restart", wg.selected)
              }

              PanelActionButton {
                iconText: Model.ICON_REFRESH
                tooltipText: "Refresh"
                foreground: wg.fg
                fontFamily: wg.fontFamily
                onClicked: wg.refresh()
              }
            }
          }
        }
      }
    }
  }

  // ---- Row components -----------------------------------------------------
  component InfoRow: Item {
    id: row
    property string icon: ""
    property string label: ""
    property string value: ""
    property color valueColor: wg.fg
    property string copyValue: ""

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(valueText.implicitHeight, copyButton.visible ? copyButton.height : 0)

    Text {
      id: iconText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      text: row.icon
      textFormat: Text.PlainText
      color: wg.dim
      font.family: wg.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: labelText
      anchors.left: iconText.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(84)
      text: row.label
      textFormat: Text.PlainText
      color: wg.dim
      font.family: wg.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: valueText
      anchors.left: labelText.right
      anchors.right: copyButton.visible ? copyButton.left : parent.right
      anchors.rightMargin: copyButton.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      text: row.value
      textFormat: Text.PlainText
      color: row.valueColor
      font.family: wg.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    PanelActionButton {
      id: copyButton
      visible: row.copyValue !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.ICON_COPY
      tooltipText: "Copy"
      foreground: wg.fg
      fontFamily: wg.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: wg.copy(row.copyValue)
    }
  }

  // An InfoRow whose value is a switch.
  component SwitchRow: Item {
    id: switchRow
    property string icon: ""
    property string label: ""
    property string hint: ""
    property bool checked: false
    property bool busy: false
    property bool interactive: true
    signal toggled()

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(switchLabel.implicitHeight, rowToggle.implicitHeight)

    Text {
      id: switchIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      text: switchRow.icon
      textFormat: Text.PlainText
      color: wg.dim
      font.family: wg.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: switchLabel
      anchors.left: switchIcon.right
      anchors.right: rowToggle.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: switchRow.label
      textFormat: Text.PlainText
      color: wg.dim
      font.family: wg.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: rowToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      busy: switchRow.busy
      interactive: switchRow.interactive
      foreground: wg.fg
      onToggled: switchRow.toggled()

      PanelToolTip {
        visible: rowToggle.containsMouse && switchRow.hint !== ""
        text: switchRow.hint
        fontFamily: wg.fontFamily
      }
    }
  }

  component RateLabel: Row {
    id: rateLabel
    property string icon: ""
    property string value: ""
    property color tint: wg.fg
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: rateLabel.icon
      textFormat: Text.PlainText
      color: rateLabel.tint
      font.family: wg.fontFamily
      font.pixelSize: Style.font.heading
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: rateLabel.value
      textFormat: Text.PlainText
      color: wg.fg
      font.family: wg.fontFamily
      font.pixelSize: Style.font.heading
    }
  }

  component TunnelRow: Item {
    id: tunnelRow
    property var tunnel: null
    readonly property string st: wg.statusAvailable ? Model.state(tunnel, wg.now) : "unknown"
    readonly property bool isSelected: wg.selected !== null && tunnel !== null && wg.selected.name === tunnel.name

    implicitHeight: Math.max(rowLabels.implicitHeight, rowSwitch.implicitHeight) + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: tunnelRow.isSelected ? Util.alpha(wg.fg, 0.08)
           : rowMouse.containsMouse ? Util.alpha(wg.fg, 0.04) : "transparent"
    }

    // Declared before the switch so the switch stays on top and keeps its
    // own clicks; anywhere else on the row picks the tunnel for the hero.
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: if (tunnelRow.tunnel) wg.selectedName = tunnelRow.tunnel.name
    }

    Text {
      id: rowIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: tunnelRow.tunnel && wg.busyTunnel === tunnelRow.tunnel.name ? Model.ICON_BUSY : Model.icon(tunnelRow.st)
      textFormat: Text.PlainText
      color: wg.stateColor(tunnelRow.tunnel && wg.busyTunnel === tunnelRow.tunnel.name ? "busy" : tunnelRow.st)
      font.family: wg.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: rowLabels
      anchors.left: rowIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: Model.label(tunnelRow.tunnel, wg.labels)
        textFormat: Text.PlainText
        color: wg.fg
        font.family: wg.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: Model.stateLabel(tunnelRow.st)
          + (Model.primaryAddress(tunnelRow.tunnel) ? "  ·  " + Model.primaryAddress(tunnelRow.tunnel) : "")
          + (tunnelRow.tunnel && !tunnelRow.tunnel.configured ? (wg.privileged ? "  ·  not managed by wg-quick" : "  ·  config unavailable") : "")
        textFormat: Text.PlainText
        color: wg.dim
        font.family: wg.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      checked: tunnelRow.tunnel !== null && tunnelRow.tunnel.up === true
      busy: tunnelRow.tunnel !== null && wg.busyTunnel === tunnelRow.tunnel.name
      interactive: wg.statusAvailable && wg.helperReady && tunnelRow.tunnel !== null && tunnelRow.tunnel.configured && wg.busyTunnel === ""
      foreground: wg.fg
      onToggled: wg.toggleTunnel(tunnelRow.tunnel)
    }
  }
}
