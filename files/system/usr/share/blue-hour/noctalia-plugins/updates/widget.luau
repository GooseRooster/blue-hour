-- blue-hour update-status bar widget.
--
-- Reads the world-readable status file written by
-- blue-hour-update-status.service and shows a dot when an update is available
-- or staged, with a version tooltip. Left-click opens topgrade in a terminal.
--
-- The status file is refreshed every 15 min by the system service, so this
-- widget only needs to poll locally. Notification of a staged update is
-- handled separately by blue-hour-update-notify.service (so it works even in a
-- session without the Noctalia plugin). See docs/port-plan.md phase 6.

local STATUS_FILE = "/run/blue-hour/update-status.json"

local function empty_state()
  return { staged = false, available = false, version = "" }
end

local function read_status()
  local raw = noctalia.readFile(STATUS_FILE)
  if not raw then
    return empty_state()
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return empty_state()
  end
  return {
    staged = data.staged == true,
    available = data.updateAvailable == true,
    version = data.stagedVersion or data.bootedVersion or "",
  }
end

function update()
  noctalia.setUpdateInterval(5000)

  local state = read_status()
  barWidget.setGlyph("download")

  if state.staged then
    barWidget.setText("●")
    barWidget.setColor("error")
    barWidget.setGlyphColor("error")
    barWidget.setTooltip("blue-hour update staged — restart to apply")
  elseif state.available then
    barWidget.setText("●")
    barWidget.setColor("primary")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip("blue-hour update available — click to run topgrade")
  else
    barWidget.setText("")
    barWidget.setColor("on_surface")
    barWidget.setGlyphColor("on_surface")
    barWidget.setTooltip("blue-hour is up to date")
  end
end

function onClick()
  noctalia.runInTerminal("blue-hour-topgrade")
end
