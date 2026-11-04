.pragma library

// Inactivity alone does not establish peer failure. Warn about old handshakes
// only when keepalives are expected, and describe every peer independently.
var STALE_AFTER = 180

var ICON_CONNECTED = "󰦝"   // md-shield_lock
var ICON_STALE = "󰻌"       // md-shield_alert
var ICON_DOWN = "󰦞"        // md-shield_off
var ICON_BUSY = "󰔟"        // md-timer_sand
var ICON_RX = "󰁅"          // md-arrow_down
var ICON_TX = "󰁝"          // md-arrow_up
var ICON_COPY = "󰆏"
var ICON_RESTART = "󰜉"
var ICON_REFRESH = "󰑐"
var ICON_KEY = "󰌆"
var ICON_ENDPOINT = "󱇢"    // md-router
var ICON_CLOCK = "󰥔"
var ICON_PULSE = "󰐰"
var ICON_DNS = "󰇧"         // md-earth
var ICON_ROUTE = "󰌘"       // md-lan_connect
var ICON_LISTEN = "󰓡"      // md-swap_horizontal
var ICON_BOOT = "󰐥"        // md-power

// Array.isArray fails on lists that have been through a QML model (a Repeater
// hands its delegates QVariantList, not a JS Array), so check for the shape.
function isList(value) {
  return value !== null && value !== undefined && typeof value === "object"
    && typeof value.length === "number"
}

function parse(text) {
  try {
    var parsed = JSON.parse(String(text || "").trim())
    if (!parsed || parsed.ok !== true || !isList(parsed.tunnels) || !Number.isFinite(parsed.now)) return null
    for (var i = 0; i < parsed.tunnels.length; i++) {
      var tunnel = parsed.tunnels[i]
      if (!tunnel || !/^[A-Za-z0-9_=+][A-Za-z0-9_=+.-]{0,14}$/.test(tunnel.name)
          || typeof tunnel.up !== "boolean" || !Number.isFinite(tunnel.rx) || tunnel.rx < 0
          || !Number.isFinite(tunnel.tx) || tunnel.tx < 0) return null
    }
    return parsed
  } catch (e) {
    return null
  }
}

function lastHandshake(tunnel) {
  var latest = 0
  var peers = tunnel && isList(tunnel.peers) ? tunnel.peers : []
  for (var i = 0; i < peers.length; i++) latest = Math.max(latest, peers[i].handshake || 0)
  return latest
}

// "down" · "connecting" (up, never handshaked) · "stale" · "connected" ·
// "up" (interface up but peers unreadable without root)
function peerState(peer, now) {
  var handshake = Number(peer.handshake || 0)
  if (handshake <= 0) return "connecting"
  var age = now - handshake
  if (age < 0) return "unknown"
  if (age <= STALE_AFTER) return "connected"
  var keepalive = Number(peer.keepalive || 0)
  return keepalive > 0 && age > Math.max(STALE_AFTER, keepalive * 2 + 120) ? "stale" : "idle"
}

function fresh(loaded, failed, lastSuccess, now, interval) {
  var age = now - lastSuccess
  return loaded && !failed && age >= 0 && age <= Math.max(15, interval * 3)
}

function state(tunnel, now) {
  if (!tunnel || !tunnel.up) return "down"
  if (!isList(tunnel.peers)) return "up"
  if (!tunnel.peers.length) return "connecting"
  var recent = 0, waiting = false
  for (var i = 0; i < tunnel.peers.length; i++) {
    var value = peerState(tunnel.peers[i], now)
    if (value === "stale" || value === "unknown") return value
    if (value === "connected") recent++
    if (value === "connecting") waiting = true
  }
  if (recent === tunnel.peers.length) return "connected"
  if (recent > 0) return "partial"
  return waiting ? "connecting" : "idle"
}

function icon(st) {
  if (["connected", "up", "idle", "partial"].indexOf(st) >= 0) return ICON_CONNECTED
  if (st === "stale" || st === "connecting" || st === "unknown") return ICON_STALE
  return ICON_DOWN
}

function stateLabel(st) {
  return {
    connected: "Recent peer handshakes",
    up: "Interface up · peers unavailable",
    partial: "Some peers recently active",
    idle: "Interface up · no recent handshake",
    unknown: "Status unavailable",
    connecting: "Waiting for handshake",
    stale: "No recent handshake",
    down: "Disconnected"
  }[st] || st
}

// The bar shows one icon for every tunnel: healthy if any is connected,
// warning if one is up but not passing traffic, off when none is up.
function overall(tunnels, now) {
  var best = "none"
  var rank = { none: 0, down: 1, stale: 2, connecting: 2, idle: 3, partial: 3, up: 3, connected: 4 }
  for (var i = 0; i < (tunnels || []).length; i++) {
    var st = state(tunnels[i], now)
    // A stale tunnel outranks a connected one: something needs attention.
    if (st === "stale" || st === "connecting" || st === "unknown") return st
    if (rank[st] > rank[best]) best = st
  }
  return best
}

function human(bytes) {
  var b = Math.max(0, Number(bytes) || 0)
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var i = 0
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++ }
  return (i === 0 || b >= 100 ? Math.round(b) : b.toFixed(1)) + " " + units[i]
}

function rate(bytesPerSecond) {
  var b = Math.max(0, Number(bytesPerSecond) || 0)
  if (b < 1) return "0 B/s"
  return human(b) + "/s"
}

function duration(seconds) {
  var d = Math.max(0, Math.round(seconds))
  if (d < 60) return d + "s"
  if (d < 3600) return Math.floor(d / 60) + "m " + (d % 60) + "s"
  if (d < 86400) return Math.floor(d / 3600) + "h " + Math.floor(d % 3600 / 60) + "m"
  return Math.floor(d / 86400) + "d " + Math.floor(d % 86400 / 3600) + "h"
}

function handshakeText(tunnel, now) {
  var hs = lastHandshake(tunnel)
  if (!tunnel || !tunnel.up) return "—"
  if (!isList(tunnel.peers)) return "needs sudo"
  if (hs === 0) return "never"
  return duration(now - hs) + " ago"
}

function label(tunnel, labels) {
  if (!tunnel) return ""
  var custom = labels && typeof labels === "object" && Object.prototype.hasOwnProperty.call(labels, tunnel.name) ? labels[tunnel.name] : ""
  return custom ? String(custom) : tunnel.name
}

function shortKey(key) {
  var k = String(key || "")
  return k.length > 12 ? k.slice(0, 10) + "…" : k
}

// The configured endpoint, hostname and all, when the config has one.
function endpoint(peer) {
  if (!peer) return ""
  return peer.endpointHost || peer.endpoint || "no endpoint"
}

// The IP the kernel is actually sending to, when the config names a host.
// Empty when there is nothing beyond endpoint() to show.
function resolvedEndpoint(peer) {
  if (!peer || !peer.endpointHost || !peer.endpoint) return ""
  var ip = String(peer.endpoint).replace(/:\d+$/, "")
  var host = String(peer.endpointHost).replace(/:\d+$/, "")
  return ip === host ? "" : ip
}

function addresses(tunnel) {
  if (!tunnel) return []
  if (tunnel.up && tunnel.addresses && tunnel.addresses.length) return tunnel.addresses
  return tunnel.config && tunnel.config.addresses ? tunnel.config.addresses : []
}

function primaryAddress(tunnel) {
  var list = addresses(tunnel)
  return list.length ? String(list[0]).replace(/\/\d+$/, "") : ""
}

function routes(tunnel) {
  var peers = tunnel && isList(tunnel.peers) ? tunnel.peers
            : (tunnel && tunnel.config ? tunnel.config.peers : [])
  var out = []
  for (var i = 0; i < (peers || []).length; i++) {
    var ips = peers[i].allowedIps || []
    for (var j = 0; j < ips.length; j++) if (out.indexOf(ips[j]) === -1) out.push(ips[j])
  }
  return out
}

function dnsServers(tunnel) {
  if (!tunnel) return []
  if (tunnel.up && tunnel.dns && tunnel.dns.length) return tunnel.dns
  return tunnel.config && tunnel.config.dns ? tunnel.config.dns : []
}

// Latency target: an explicit per-tunnel host from settings.probe, else the
// tunnel's DNS server (inside the tunnel and always answering), else nothing.
// An empty string in settings.probe turns probing off for that tunnel.
function probeHost(tunnel, probeSettings) {
  if (!tunnel) return ""
  if (probeSettings && typeof probeSettings === "object" && Object.prototype.hasOwnProperty.call(probeSettings, tunnel.name))
    return String(probeSettings[tunnel.name] || "")
  var dns = dnsServers(tunnel)
  return dns.length ? String(dns[0]) : ""
}

// Without the root helper an empty list means "nothing is up", not "nothing is
// configured": /etc/wireguard is unreadable, so a config down there is invisible.
function tooltip(tunnels, now, labels, rates, privileged, available, demo) {
  if (available === false) return "WireGuard — status unavailable; readings are stale or incomplete"
  if (!tunnels || tunnels.length === 0)
    return privileged === false ? "WireGuard — no tunnel up; configs need the root helper"
                                : "WireGuard — no tunnels configured"
  var lines = []
  for (var i = 0; i < tunnels.length; i++) {
    var t = tunnels[i]
    var st = state(t, now)
    var line = label(t, labels) + " — " + stateLabel(st)
    if (t.up) {
      var addr = primaryAddress(t)
      if (addr) line += "  ·  " + addr
      var r = rates ? rates[t.name] : null
      if (r) line += "\n  " + ICON_RX + " " + rate(r.rx) + "   " + ICON_TX + " " + rate(r.tx)
      if (isList(t.peers)) {
        for (var p = 0; p < t.peers.length; p++)
          line += "\n  " + shortKey(t.peers[p].publicKey || "peer") + ": " + stateLabel(peerState(t.peers[p], now))
      }
    }
    lines.push(line)
  }
  return (demo ? "DEMO — simulated tunnel data\n" : "") + lines.join("\n")
}
