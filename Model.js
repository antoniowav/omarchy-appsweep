// App Sweep model: pure parsing/formatting helpers. No QML dependencies so
// the whole file is node-testable via the module.exports guard at the bottom.

// Lines of "name\tversion\tinstalledBytes" (expac) or "name\tversion\t" when
// expac is unavailable. Anything malformed is skipped, never thrown on.
function parsePackages(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i]) continue
    var parts = lines[i].split("\t")
    if (!parts[0]) continue
    out.push({
      name: parts[0],
      version: parts.length > 1 ? parts[1] : "",
      bytes: parts.length > 2 ? (parseInt(parts[2], 10) || 0) : 0
    })
  }
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return out
}

// One launcher basename per line, pre-sorted by the shell pipeline.
function parseWebapps(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i]) out.push({ name: lines[i], version: "", bytes: 0 })
  }
  return out
}

function formatSize(bytes) {
  if (!bytes || bytes <= 0) return ""
  if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + " GB"
  if (bytes >= 1048576) return Math.round(bytes / 1048576) + " MB"
  if (bytes >= 1024) return Math.round(bytes / 1024) + " kB"
  return bytes + " B"
}

function matchesFilter(name, filter) {
  if (!filter) return true
  return name.toLowerCase().indexOf(filter.toLowerCase()) !== -1
}

function filterItems(items, filter) {
  if (!filter) return items
  var out = []
  for (var i = 0; i < items.length; i++) {
    if (matchesFilter(items[i].name, filter)) out.push(items[i])
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parsePackages: parsePackages,
    parseWebapps: parseWebapps,
    formatSize: formatSize,
    matchesFilter: matchesFilter,
    filterItems: filterItems
  }
}
