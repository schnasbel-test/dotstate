function defaultStatus() {
  return { ok: true, dirty: false, error: "", lastRun: "", known: false }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    return {
      ok: parsed.ok !== false,
      dirty: parsed.dirty === true,
      error: String(parsed.error || ""),
      lastRun: String(parsed.lastRun || ""),
      known: true
    }
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    failed.error = "Failed to parse status.json"
    failed.known = true
    return failed
  }
}

function relativeTime(isoString, nowMs) {
  var ts = Date.parse(String(isoString || ""))
  if (!isFinite(ts)) return "never"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts) / 1000))
  if (diff < 60) return "just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  return days + "d ago"
}

if (typeof module !== "undefined") {
  module.exports = { defaultStatus: defaultStatus, parseStatus: parseStatus, relativeTime: relativeTime }
}
