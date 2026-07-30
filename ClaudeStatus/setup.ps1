#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Claude Code LCD status system on this PC.

.DESCRIPTION
    Walks through a browser-based setup wizard that lets the user:
      - Connect the device: the wizard opens on a "Connect your device" page
        and polls for it, so the installer can be run on a brand-new machine
        before the device has ever been plugged in — it doesn't have to be
        connected up front, only by the time this first page finishes
      - Pick their city on a live map (weather + air raid alerts for Ukraine)
      - Adjust the display brightness with live preview on the hardware
      - Toggle preferences (weather, alert sounds, all-clear chime)

    The installer also:
      - Ensures Python 3 and pyserial are present (installs via winget if missing)
      - Ensures the CH340 USB-serial driver is v3.4 (newer WCH drivers fail to
        open the port on many clone chips) — installs the bundled v3.4 if needed
      - Auto-detects the Arduino by USB VID:PID and flashes claude_status.hex
        with bundled avrdude (tries both bootloader baud rates) — this and the
        driver check happen once the wizard's Connect page detects the device
      - Copies daemon / hook scripts to %LOCALAPPDATA%\ClaudeStatus\app\
      - Patches ~/.claude/settings.json to register the six Claude Code hooks
      - Registers a Task Scheduler entry so the daemon starts at logon

.PARAMETER Port
    Override Arduino COM port (e.g. COM3). Default: auto-detect.

.PARAMETER City
    City name for non-interactive installs (e.g. "Kyiv"). Skips the wizard and
    resolves coordinates via the Open-Meteo geocoding API.

.PARAMETER NoWeather
    Disable weather and air raid alerts entirely.

.PARAMETER NoAutostart
    Skip the Task Scheduler logon entry.
#>
[CmdletBinding()]
param(
    [string]$Port,
    [string]$City,
    [switch]$NoWeather,
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = Join-Path $env:LOCALAPPDATA 'ClaudeStatus'
$appDir     = Join-Path $installDir 'app'
$avrdude    = Join-Path $here 'tools\avrdude.exe'
$avrconf    = Join-Path $here 'tools\avrdude.conf'
$hexFile    = Join-Path $here 'hex\claude_status.hex'
$driverDir  = Join-Path $here 'driver'

# USB IDs the daemon and installer recognise (keep in sync with lcd_daemon.py)
$USB_ID_UNO   = 'VID_2341&PID_0043'   # genuine Arduino Uno
$USB_ID_CH340 = 'VID_1A86&PID_7523'   # CH340 (Nano clones)
$script:IsCH340 = $false

function Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Info($msg)  { Write-Host "    $msg" }
function Done($msg)  { Write-Host "    OK: $msg" -ForegroundColor Green }
function Warn2($msg) { Write-Warning $msg }

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Has-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Ensure-Python {
    Step "Checking Python"
    if (Has-Command python) {
        $v = (& python --version) 2>&1
        Done "$v already installed"
        return
    }
    Info "Python not found; installing via winget (Python.Python.3.11)..."
    winget install --id=Python.Python.3.11 -e `
        --accept-package-agreements --accept-source-agreements --silent | Out-Null
    Refresh-Path
    if (-not (Has-Command python)) {
        throw "Python install failed. Please install Python 3 manually and re-run."
    }
    Done "Python installed"
}

function Ensure-PySerial {
    Step "Ensuring pyserial"
    # Check-first so re-runs don't hit the network (or fail offline) and an
    # already-working install never gets silently upgraded.
    & python -c "import serial" 2>$null
    if ($LASTEXITCODE -eq 0) { Done "pyserial already installed"; return }
    & python -m pip install --quiet --disable-pip-version-check pyserial
    if ($LASTEXITCODE -ne 0) { throw "pip install pyserial failed." }
    Done "pyserial installed"
}

function Get-BoundCH340Driver {
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -match $USB_ID_CH340 } |
        Select-Object -First 1
}

function Ensure-CH340Driver {
    Step "Checking CH340 USB-serial driver"
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceID -match $USB_ID_CH340 } |
           Select-Object -First 1
    if (-not $dev) {
        Info "No CH340 device attached - nothing to do (genuine Uno needs no driver fix)"
        return
    }

    $drv = Get-BoundCH340Driver
    $ver = if ($drv) { [string]$drv.DriverVersion } else { '' }
    if ($ver.StartsWith('3.4.')) { Done "CH340 driver v$ver (good)"; return }

    if ($ver) {
        Warn2 "CH340 driver v$ver bound. WCH drivers newer than v3.4 enumerate fine but fail every port open ('device not functioning') on many clone chips."
    } else {
        Info "CH340 device present but no driver bound yet."
    }
    Info "Installing bundled v3.4 driver (needs administrator approval)..."

    $inf = Join-Path $driverDir 'CH341SER.INF'
    if (-not (Test-Path $inf)) { throw "Bundled driver missing: $inf" }
    $cmds = @()
    if ($drv -and $drv.InfName -like 'oem*.inf') {
        # Remove the newer package first, or Windows re-picks it (highest
        # version wins) the next time the device shows up on another USB port.
        $cmds += "pnputil /delete-driver $($drv.InfName) /uninstall /force"
    }
    $cmds += "pnputil /add-driver `"$inf`" /install"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        foreach ($c in $cmds) { cmd /c $c | Out-Null }
    } else {
        # -EncodedCommand survives the quote-stripping that a plain -Command
        # argument suffers through Start-Process.
        $enc = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(($cmds -join '; ')))
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList @('-NoProfile', '-EncodedCommand', $enc)
    }
    Start-Sleep -Seconds 3

    $drv2 = Get-BoundCH340Driver
    if ($drv2 -and ([string]$drv2.DriverVersion).StartsWith('3.4.')) {
        Done "CH340 driver v$($drv2.DriverVersion) active"
    } else {
        Warn2 "Driver installed but not rebound yet - unplug and replug the device, then re-run setup if flashing fails."
    }
}

function Try-DetectPort {
    # Non-throwing scan, safe to call repeatedly from a polling loop --
    # returns @{Port=...; IsCH340=...} or $null. See Detect-Port below for
    # the throwing wrapper used by the non-interactive install path.
    if ($Port) { return @{ Port = $Port; IsCH340 = $false } }
    $devs = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\(COM\d+\)' }
    # Known USB IDs first — immune to localised/renamed friendly names.
    foreach ($id in @($USB_ID_UNO, $USB_ID_CH340)) {
        foreach ($d in $devs) {
            if ($d.DeviceID -match $id -and $d.Name -match '\((COM\d+)\)') {
                return @{ Port = $matches[1]; IsCH340 = ($id -eq $USB_ID_CH340); Name = $d.Name }
            }
        }
    }
    # Fallback heuristics for other USB-serial adapters (FTDI, CP210x, ...).
    $hits = $devs | Where-Object {
        $_.Name -match "Arduino|CH340|CH341|USB Serial|FTDI|Silicon Labs|wch.cn"
    }
    foreach ($d in $hits) {
        if ($d.Name -match '\((COM\d+)\)') {
            return @{ Port = $matches[1]; IsCH340 = $false; Name = $d.Name }
        }
    }
    return $null
}

function Detect-Port {
    Step "Detecting Arduino COM port"
    $found = Try-DetectPort
    if (-not $found) {
        throw "Could not auto-detect an Arduino COM port. Plug it in and re-run, or pass -Port COMx."
    }
    $script:IsCH340 = $found.IsCH340
    if ($found.Name) { Done "Found '$($found.Name)'" } else { Done "Using override: $($found.Port)" }
    return $found.Port
}

function Stop-Daemon {
    # Ask a running daemon to exit via its exit-file (it closes the COM port
    # in a finally block). Force-killing it instead can wedge the CH340's
    # open handle so badly that every later port open fails until the device
    # is physically replugged — so the hard kill is strictly a last resort.
    $pidFile  = Join-Path $env:TEMP 'claude_lcd_daemon.pid'
    $exitFile = Join-Path $env:TEMP 'claude_lcd_daemon.exit'
    if (-not (Test-Path $pidFile)) { return }
    $dpid = 0
    try { $dpid = [int](Get-Content $pidFile -Raw).Trim() } catch { return }
    if (-not (Get-Process -Id $dpid -ErrorAction SilentlyContinue)) { return }
    Step "Stopping running LCD daemon (pid $dpid)"
    New-Item -ItemType File -Path $exitFile -Force | Out-Null
    foreach ($i in 1..25) {   # up to 5 s; the daemon polls every 0.1 s
        Start-Sleep -Milliseconds 200
        if (-not (Get-Process -Id $dpid -ErrorAction SilentlyContinue)) {
            Done "Daemon exited cleanly"
            Remove-Item $exitFile -ErrorAction SilentlyContinue
            return
        }
    }
    Stop-Process -Id $dpid -Force -ErrorAction SilentlyContinue
    Remove-Item $exitFile -ErrorAction SilentlyContinue
    Warn2 "Daemon had to be force-killed. If flashing now fails with 'device not functioning', unplug and replug the device, then re-run setup."
}

function Flash-Arduino($port) {
    Step "Flashing firmware onto $port"
    # CH340 Nano clones almost always ship the old bootloader (57600 baud);
    # genuine Unos and Optiboot Nanos talk 115200. Try the likely rate first,
    # then fall back to the other.
    $bauds = if ($script:IsCH340) { @(57600, 115200) } else { @(115200, 57600) }
    foreach ($b in $bauds) {
        Info "Trying $b baud..."
        & $avrdude -C $avrconf -p atmega328p -c arduino -P $port -b $b -D `
          -U "flash:w:$hexFile`:i"
        if ($LASTEXITCODE -eq 0) { Done "Sketch flashed ($b baud)"; return }
        Info "No response at $b baud"
    }
    throw "avrdude failed at both baud rates. Check the USB connection and driver, then re-run."
}

function Copy-AppFiles {
    Step "Installing files to $appDir"
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    Copy-Item (Join-Path $here 'app\*.py') $appDir -Force
    Done "App files copied"
}

# ---------------------------------------------------------------------------
# Browser wizard — Welcome / Location / Brightness / Preferences / Done
# ---------------------------------------------------------------------------

$WIZARD_HTML = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claudius I — Setup</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
/* Design tokens. Previously colors/spacing were hand-picked per rule (and a
   contrast fix landed as one-off overrides) -- centralizing them here keeps
   new rules consistent and makes future palette/contrast tweaks one-line
   changes instead of a file-wide hunt. */
:root{
  --bg:#0d0d0d; --panel:#131315; --panel-2:#191a1c; --panel-3:#232326;
  --border:#28282b; --border-soft:#1c1c1f;
  --text:#f4f5f7; --text-dim:#c7cad0; --text-mute:#9aa0a8;
  --accent:#2ecc71; --accent-hover:#3ee787; --accent-dim:#1a5c3a; --accent-ink:#06210f;
  --accent-glow:rgba(46,204,113,.35); --accent-glow-soft:rgba(46,204,113,.14);
  --danger:#ff8a80; --warn:#e8a33d;
  --radius-sm:6px; --radius-md:10px; --radius-lg:14px;
  --shadow-sm:0 2px 10px rgba(0,0,0,.3); --shadow-md:0 8px 24px rgba(0,0,0,.4);
  --font:system-ui,-apple-system,'Segoe UI',sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
html{height:100%}
body{height:100%;overflow:hidden;display:flex;flex-direction:column;
  background:var(--bg);color:var(--text-dim);font-family:var(--font);
  font-size:16px;-webkit-font-smoothing:antialiased}
::selection{background:var(--accent-glow-soft);color:var(--text)}

/* Step indicator -- connected dots with a filled track behind completed
   steps, instead of isolated dots with no sense of overall progress. */
#stepdots{flex:0 0 auto;display:flex;align-items:center;gap:0;padding:14px 22px;
  background:var(--panel);border-bottom:1px solid var(--border-soft)}
.dot{position:relative;width:9px;height:9px;border-radius:50%;background:var(--panel-3);
  margin-right:15px;flex-shrink:0;transition:background .25s,box-shadow .25s}
.dot:last-of-type{margin-right:0}
.dot::after{content:'';position:absolute;top:50%;left:100%;width:15px;height:2px;
  background:var(--panel-3);transform:translateY(-50%);transition:background .25s}
.dot:last-of-type::after{display:none}
.dot.done{background:var(--accent)}
.dot.done::after{background:var(--accent)}
.dot.active{background:var(--accent);box-shadow:0 0 0 4px var(--accent-glow-soft)}
#step-label{margin-left:auto;font-size:11px;font-weight:700;color:var(--text-mute);
  letter-spacing:1.4px;text-transform:uppercase}

/* Page container -- flex:1 fills whatever space is left between the header
   and nav bar, so their actual rendered height no longer has to match a
   hardcoded calc() (a prior version guessed 49px/56px, which would clip
   content the moment either bar's real height drifted). */
#pages{position:relative;flex:1 1 auto;min-height:0;overflow:hidden}
.page{position:absolute;inset:0;display:flex;flex-direction:column;
  opacity:0;transform:translateY(6px);pointer-events:none;
  transition:opacity .28s ease,transform .28s ease}
.page.active{opacity:1;transform:translateY(0);pointer-events:all}

/* Nav bar */
#nav{flex:0 0 auto;height:64px;background:var(--panel);border-top:1px solid var(--border-soft);
  display:flex;align-items:center;justify-content:space-between;padding:0 22px;gap:12px}
.btn{padding:11px 28px;border:none;border-radius:var(--radius-md);font-size:15px;
  font-weight:600;cursor:pointer;font-family:inherit;
  transition:background .15s,opacity .15s,transform .08s,box-shadow .15s}
.btn:active{transform:scale(.97)}
.btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
#btn-back{background:var(--panel-2);color:var(--text-mute)}
#btn-back:hover{background:var(--panel-3);color:var(--text-dim)}
#btn-skip{background:none;color:var(--text-mute);font-size:14px;padding:10px 14px;
  border-radius:var(--radius-sm)}
#btn-skip:hover{color:var(--text-dim);background:var(--panel-2)}
#btn-next{background:var(--accent);color:var(--accent-ink);min-width:140px;
  box-shadow:0 2px 12px var(--accent-glow-soft)}
#btn-next:hover:not(:disabled){background:var(--accent-hover);
  box-shadow:0 4px 16px rgba(46,204,113,.3)}
#btn-next:disabled{background:var(--accent-dim);color:#3f7a56;cursor:default;box-shadow:none}

/* ── Connect ── */
#p-connect{justify-content:center;align-items:center;gap:24px;text-align:center;padding:40px}
.connect-spinner{width:42px;height:42px;border:3px solid var(--panel-3);
  border-top-color:var(--accent);border-radius:50%;animation:spin 1s linear infinite}
.connect-status{font-size:19px;color:var(--text);font-weight:600;max-width:440px;line-height:1.5}
.connect-status.error{color:var(--danger)}

/* ── Welcome ── */
#p-welcome{justify-content:center;align-items:center;gap:28px;text-align:center;padding:40px}
.logo{font-size:40px;font-weight:300;letter-spacing:5px;color:var(--text)}
.logo b{color:var(--accent);font-weight:800}
.tagline{color:var(--text-dim);font-size:16px;max-width:420px;line-height:1.7}
.device-hint{display:inline-flex;align-items:center;gap:8px;background:var(--panel-2);
  border:1px solid var(--border);border-radius:var(--radius-md);padding:11px 20px;
  font-size:13px;color:var(--text-mute);margin-top:4px;box-shadow:var(--shadow-sm)}
.device-hint code{color:var(--accent);font-family:Consolas,monospace}

/* ── Location ── */
#p-location{flex-direction:column}
#map{flex:1}
#loc-bar{padding:14px 22px;background:var(--panel);border-top:1px solid var(--border-soft);
  display:flex;align-items:center;gap:14px;min-height:60px;box-shadow:0 -6px 20px rgba(0,0,0,.25)}
#loc-city{font-size:16px;color:var(--text);font-weight:600;line-height:1.3}
#loc-note{font-size:13px;margin-top:2px}
.note-ua{color:var(--accent)}
.note-other{color:var(--warn)}
.note-idle{color:var(--text-mute)}
#loc-spinner{width:15px;height:15px;border:2px solid var(--accent);
  border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite;
  flex-shrink:0;display:none}
@keyframes spin{to{transform:rotate(360deg)}}

/* ── Brightness ── */
#p-brightness{justify-content:center;align-items:center;gap:28px;padding:32px 24px}
.lcd{width:100%;max-width:440px;line-height:0;border-radius:var(--radius-md);
  box-shadow:0 0 36px rgba(30,100,220,.22),var(--shadow-md);transition:filter .08s}
.lcd svg{width:100%;height:auto;display:block}
.bl-wrap{width:100%;max-width:440px}
.bl-label{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:12px;
  font-size:14px;color:var(--text-dim)}
.bl-label span{color:var(--text);font-size:19px;font-weight:700}
#bl-num{font-variant-numeric:tabular-nums}
input[type=range]{width:100%;appearance:none;height:5px;background:var(--panel-3);
  border-radius:3px;outline:none;cursor:pointer}
input[type=range]::-webkit-slider-thumb{appearance:none;width:19px;height:19px;
  background:var(--accent);border-radius:50%;cursor:pointer;
  box-shadow:0 2px 8px rgba(46,204,113,.5);transition:transform .12s}
input[type=range]::-webkit-slider-thumb:hover{transform:scale(1.15)}
input[type=range]:focus-visible::-webkit-slider-thumb{outline:2px solid var(--accent);outline-offset:3px}
input[type=range]::-moz-range-thumb{width:19px;height:19px;background:var(--accent);
  border:none;border-radius:50%;cursor:pointer;box-shadow:0 2px 8px rgba(46,204,113,.5)}
.bl-note{font-size:13px;color:var(--text-mute);text-align:center;max-width:400px;line-height:1.6}

/* ── Preferences ── */
#p-prefs{justify-content:center;align-items:center;padding:32px 24px;gap:8px}
.pref-section{width:100%;max-width:440px;background:var(--panel);
  border:1px solid var(--border-soft);border-radius:var(--radius-md);padding:4px 18px}
.pref-heading{font-size:11px;color:var(--text-mute);text-transform:uppercase;
  letter-spacing:1.4px;font-weight:700;margin:14px 0 4px;padding-left:2px}
.pref-item{display:flex;justify-content:space-between;align-items:center;
  padding:14px 0;border-bottom:1px solid var(--border-soft)}
.pref-item:last-child{border:none}
.pref-name{font-size:15px;color:var(--text)}
.pref-desc{font-size:13px;color:var(--text-mute);margin-top:2px}
/* toggle */
.toggle{position:relative;width:42px;height:24px;flex-shrink:0}
.toggle input{position:absolute;inset:0;opacity:0;width:100%;height:100%;cursor:pointer}
.tslider{position:absolute;inset:0;background:var(--panel-3);border-radius:12px;
  transition:background .2s;pointer-events:none}
.tslider::before{content:'';position:absolute;width:18px;height:18px;
  left:3px;top:3px;background:#8a8d94;border-radius:50%;transition:.2s;box-shadow:var(--shadow-sm)}
.toggle input:checked+.tslider{background:var(--accent)}
.toggle input:checked+.tslider::before{transform:translateX(18px);background:#fff}
.toggle input:focus-visible+.tslider{outline:2px solid var(--accent);outline-offset:2px}

/* ── Done ── */
#p-done{justify-content:center;align-items:center;gap:22px;padding:40px;text-align:center}
.done-check{width:76px;height:76px;border-radius:50%;background:var(--accent-glow-soft);
  color:var(--accent);display:flex;align-items:center;justify-content:center;
  font-size:36px;font-weight:700;box-shadow:0 0 0 1px var(--accent-dim)}
.done-title{font-size:28px;color:var(--text);font-weight:600}
.done-card{background:var(--panel);border:1px solid var(--border-soft);border-radius:var(--radius-md);
  padding:20px 26px;width:100%;max-width:440px;text-align:left;box-shadow:var(--shadow-sm)}
.done-row{display:flex;justify-content:space-between;padding:9px 0;
  border-bottom:1px solid var(--border-soft);font-size:14px}
.done-row:last-child{border:none}
.done-key{color:var(--text-mute)}
.done-val{color:var(--text)}
.done-val.green{color:var(--accent-hover)}
.done-hint{font-size:14px;color:var(--text-mute);max-width:400px;line-height:1.6}
.done-hint code{color:var(--accent-hover);background:rgba(46,204,113,.1);
  padding:2px 6px;border-radius:4px;font-family:Consolas,monospace}
</style>
</head>
<body>

<div id="stepdots">
  <div class="dot active" data-i="0"></div>
  <div class="dot" data-i="1"></div>
  <div class="dot" data-i="2"></div>
  <div class="dot" data-i="3"></div>
  <div class="dot" data-i="4"></div>
  <div class="dot" data-i="5"></div>
  <span id="step-label">CONNECT</span>
</div>

<div id="pages">

  <!-- 0: Connect -->
  <div class="page active" id="p-connect">
    <div class="logo">Claudius <b>I</b> Setup</div>
    <div class="connect-spinner" id="connect-spinner"></div>
    <p class="connect-status" id="connect-status">Looking for your device…</p>
    <p class="tagline">Plug the display into a USB-C port. This page updates on its own once it's found — no need to click anything.</p>
  </div>

  <!-- 1: Welcome -->
  <div class="page" id="p-welcome">
    <div class="logo">Claudius <b>I</b> Setup</div>
    <p class="tagline">Your Arduino LCD display is connected and ready. This wizard configures location, display brightness, and alert preferences — takes about 2 minutes.</p>
    <div class="device-hint">Device detected &amp; flashed &nbsp;·&nbsp; <code>claude_status.hex</code></div>
  </div>

  <!-- 2: Location -->
  <div class="page" id="p-location">
    <div id="map"></div>
    <div id="loc-bar">
      <div id="loc-spinner"></div>
      <div style="flex:1;min-width:0">
        <div id="loc-city">Click anywhere on the map to select your city</div>
        <div id="loc-note" class="note-idle">Weather and air raid alerts are configured from your location</div>
      </div>
    </div>
  </div>

  <!-- 3: Brightness -->
  <div class="page" id="p-brightness">
    <div class="lcd" id="lcd-sim"></div>
    <div class="bl-wrap">
      <div class="bl-label">
        <span>Display brightness</span>
        <span id="bl-num">20</span><span style="color:var(--text-mute)">%</span>
      </div>
      <input type="range" id="bl-slider" min="0" max="100" value="20">
    </div>
    <p class="bl-note">Adjust until the display is comfortable. The value is saved to the device and restored on every power-up.</p>
  </div>

  <!-- 4: Preferences -->
  <div class="page" id="p-prefs">
    <div class="pref-section">
      <div class="pref-heading">Display</div>
      <div class="pref-item">
        <div class="pref-text">
          <div class="pref-name">Show weather</div>
          <div class="pref-desc">Temperature on the idle screen and screensaver</div>
        </div>
        <label class="toggle"><input type="checkbox" id="pf-weather" checked><span class="tslider"></span></label>
      </div>
    </div>
    <div class="pref-section" style="margin-top:20px">
      <div class="pref-heading">Alerts</div>
      <div class="pref-item">
        <div class="pref-text">
          <div class="pref-name">Alert siren</div>
          <div class="pref-desc">Buzzer plays when an air raid alert starts</div>
        </div>
        <label class="toggle"><input type="checkbox" id="pf-sound" checked><span class="tslider"></span></label>
      </div>
      <div class="pref-item">
        <div class="pref-text">
          <div class="pref-name">All-clear chime</div>
          <div class="pref-desc">Arpeggio melody when the alert ends</div>
        </div>
        <label class="toggle"><input type="checkbox" id="pf-allclear" checked><span class="tslider"></span></label>
      </div>
    </div>
  </div>

  <!-- 5: Done -->
  <div class="page" id="p-done">
    <div class="done-check">✓</div>
    <div class="done-title">All set!</div>
    <div class="done-card" id="done-card"></div>
    <p class="done-hint">Close this window and open a terminal. Run <code>claude</code> — the LCD will update on the first response.</p>
    <p class="done-hint" style="margin-top:10px">Adjust brightness later: <code>python bl.py</code> in the app folder (arrow keys or pass a value 0–100).</p>
  </div>

</div>

<div id="nav">
  <button class="btn" id="btn-back" style="visibility:hidden">← Back</button>
  <button class="btn" id="btn-skip" style="display:none">Skip for now</button>
  <button class="btn" id="btn-next" style="display:none">Get started →</button>
</div>

<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
'use strict';
const PORT = %%PORT%%;
// Proves a request actually came from this page: the listener only accepts
// this exact value on its state-changing endpoints, and (with no CORS
// headers on the response) a page from another origin can't read this file
// to learn it either. See setup.ps1's request loop for the server side.
const TOKEN = '%%TOKEN%%';
const STEP_LABELS = ['CONNECT','WELCOME','LOCATION','BRIGHTNESS','PREFERENCES','DONE'];

// Surface any uncaught error on-screen instead of leaving a button that
// silently "does nothing" -- this wizard has no dev console open in the
// normal case, so a swallowed exception is otherwise invisible.
window.addEventListener('error', e => showFatalError(e.message));
window.addEventListener('unhandledrejection', e => showFatalError(String(e.reason)));
function showFatalError(msg) {
  let box = document.getElementById('fatal-error');
  if (!box) {
    box = document.createElement('div');
    box.id = 'fatal-error';
    box.style.cssText = 'position:fixed;left:12px;right:12px;bottom:64px;'
      + 'background:#3a1414;border:1px solid #6b1f1f;color:#ffb3b3;'
      + 'padding:10px 14px;border-radius:6px;font-size:12px;z-index:9999;'
      + 'white-space:pre-wrap';
    document.body.appendChild(box);
  }
  box.textContent = 'Setup wizard hit an error: ' + msg
    + '\nYou can close this window -- the device already has the latest firmware. '
    + 'Re-run setup.ps1 to try the wizard again.';
}

let step = 0;
let locPayload = null;
let brightness = 20;
let prefs = { weather: true, sound: true, allclear: true };
let map, marker;
let blDebounce;

// ── Routing ──────────────────────────────────────────────────────────────────
async function api(path, body) {
  // A hard timeout so a slow/stuck local listener can never leave the UI
  // waiting forever (observed: closing the setup.ps1 terminal -- which
  // tears down the listener's socket -- was what finally unstuck the
  // "Finish setup" button, meaning the fetch below was hanging rather
  // than erroring). 5 s is generous for a same-machine loopback call.
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 5000);
  try {
    await fetch('http://localhost:' + PORT + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Wizard-Token': TOKEN },
      body: JSON.stringify(body),
      signal: ctrl.signal
    });
  } catch (_) {
    // Swallowed deliberately: the wizard's own local install continues
    // regardless of whether this round-trip completes, and the /config
    // POST is a one-shot best-effort call, not something worth blocking
    // setup completion over.
  } finally {
    clearTimeout(timer);
  }
}

// ── Navigation ────────────────────────────────────────────────────────────────
const PAGES = ['p-connect','p-welcome','p-location','p-brightness','p-prefs','p-done'];
function goTo(n) {
  document.querySelectorAll('.page').forEach((p,i) => p.classList.toggle('active', i===n));
  document.querySelectorAll('.dot').forEach((d,i) => {
    d.classList.toggle('active', i===n);
    d.classList.toggle('done', i<n);
  });
  document.getElementById('step-label').textContent = STEP_LABELS[n];
  document.getElementById('btn-back').style.visibility = (n>1 && n<5) ? 'visible' : 'hidden';
  document.getElementById('btn-skip').style.display = (n===2) ? 'inline-block' : 'none';

  const nxt = document.getElementById('btn-next');
  nxt.style.display = 'inline-block';
  if      (n===0) { nxt.style.display='none'; }  // fully automatic -- no button at all
  else if (n===1) { nxt.textContent='Get started →'; nxt.disabled=false; }
  else if (n===2) { nxt.textContent='Next →';        nxt.disabled=!locPayload; }
  else if (n===3) { nxt.textContent='Next →';        nxt.disabled=false; }
  else if (n===4) { nxt.textContent='Finish setup';  nxt.disabled=false; }
  else            { nxt.style.display='none'; document.getElementById('btn-back').style.visibility='hidden'; }

  if (n===2 && !map) initMap();
  if (n===2 && map) setTimeout(()=>map.invalidateSize(),50);
  if (n===0) startConnectPoll();
  step = n;
}

document.getElementById('btn-back').addEventListener('click', ()=>goTo(step-1));
document.getElementById('btn-skip').addEventListener('click', ()=>{ locPayload=null; goTo(3); });
document.getElementById('btn-next').addEventListener('click', async ()=>{
  if (step===4) { await finish(); return; }
  goTo(step+1);
});

// ── Connect (step 0) ─────────────────────────────────────────────────────────
let connectPollTimer = null;
let connectPolling = false;
function startConnectPoll() {
  if (connectPolling) return;
  connectPolling = true;
  pollConnect();
}
async function pollConnect() {
  const statusEl = document.getElementById('connect-status');
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 4000);
    const r = await fetch('http://localhost:' + PORT + '/portcheck', {
      headers: { 'X-Wizard-Token': TOKEN },
      signal: ctrl.signal
    });
    clearTimeout(timer);
    const data = await r.json();
    if (data.status === 'ready') {
      statusEl.classList.remove('error');
      statusEl.textContent = 'Device found — starting setup…';
      document.getElementById('connect-spinner').style.display = 'none';
      connectPolling = false;
      setTimeout(() => goTo(1), 500);
      return;
    } else if (data.status === 'error') {
      statusEl.classList.add('error');
      statusEl.textContent = "Couldn't finish setting up the device: " + data.message
        + ' — unplug and replug it to try again.';
    } else {
      statusEl.classList.remove('error');
      statusEl.textContent = 'Waiting for your device — plug it in via USB-C…';
    }
  } catch (_) {
    // Local server not answering yet/right now -- keep it low-key and
    // just keep polling rather than treating this as a fatal error.
    statusEl.classList.remove('error');
    statusEl.textContent = 'Waiting for your device — plug it in via USB-C…';
  }
  connectPollTimer = setTimeout(pollConnect, 1500);
}

// ── Location ─────────────────────────────────────────────────────────────────
function initMap() {
  map = L.map('map').setView([20,10],2);
  L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>',
    subdomains: 'abcd', maxZoom: 19
  }).addTo(map);
  map.on('click', onMapClick);
}

async function revgeo(lat,lng,lang) {
  const r = await fetch(
    `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lng}&format=json&accept-language=${lang}`,
    {headers:{'Accept':'application/json'}}
  );
  if (!r.ok) throw new Error('HTTP '+r.status);
  return r.json();
}

async function onMapClick(e) {
  const {lat,lng} = e.latlng;
  if (marker) marker.setLatLng([lat,lng]);
  else marker = L.marker([lat,lng]).addTo(map);

  locPayload = null;
  document.getElementById('btn-next').disabled = true;
  document.getElementById('loc-city').textContent = 'Looking up…';
  document.getElementById('loc-note').className = 'note-idle';
  document.getElementById('loc-note').textContent = '';
  document.getElementById('loc-spinner').style.display = 'block';

  try {
    const en = await revgeo(lat, lng, 'en');
    const a  = en.address || {};
    const city    = a.city||a.town||a.village||a.municipality||a.county||en.name||'Unknown';
    const country = a.country || '';
    const cc      = (a.country_code||'').toLowerCase();

    let alertRegion = '';
    if (cc==='ua') {
      await new Promise(r=>setTimeout(r,1100)); // Nominatim rate limit
      const uk = await revgeo(lat, lng, 'uk');
      alertRegion = (uk.address||{}).state || '';
    }

    document.getElementById('loc-city').textContent = city + (country ? ', '+country : '');
    const noteEl = document.getElementById('loc-note');
    if (cc==='ua') {
      noteEl.className = 'note-ua';
      noteEl.textContent = '✓ Air raid alerts enabled' + (alertRegion ? ' — '+alertRegion : '');
    } else {
      noteEl.className = 'note-other';
      noteEl.textContent = 'Weather enabled · air raid alerts: Ukraine only';
    }

    locPayload = { city, country, country_code:cc, latitude:lat, longitude:lng, alert_region:alertRegion };
    document.getElementById('btn-next').disabled = false;
  } catch (err) {
    document.getElementById('loc-city').textContent = 'Geocoding failed — click again to retry';
  } finally {
    document.getElementById('loc-spinner').style.display = 'none';
  }
}

// ── Brightness ────────────────────────────────────────────────────────────────
// HD44780 5x8 dot-matrix font + SVG renderer, mirrored from docs/guide_common.py
// so the preview here matches the user guide's screen figures exactly -- keep
// both in sync if the firmware ever prints a glyph not yet in this table.
const LCD_FONT = {
  ' ': [0x00,0x00,0x00,0x00,0x00], '!': [0x00,0x00,0x5F,0x00,0x00],
  '%': [0x23,0x13,0x08,0x64,0x62], ',': [0x00,0x50,0x30,0x00,0x00],
  '-': [0x08,0x08,0x08,0x08,0x08], '.': [0x00,0x60,0x60,0x00,0x00],
  ':': [0x00,0x36,0x36,0x00,0x00], '=': [0x14,0x14,0x14,0x14,0x14],
  '?': [0x02,0x01,0x51,0x09,0x06],
  '0': [0x3E,0x51,0x49,0x45,0x3E], '1': [0x00,0x42,0x7F,0x40,0x00],
  '2': [0x42,0x61,0x51,0x49,0x46], '3': [0x21,0x41,0x45,0x4B,0x31],
  '4': [0x18,0x14,0x12,0x7F,0x10], '5': [0x27,0x45,0x45,0x45,0x39],
  '6': [0x3C,0x4A,0x49,0x49,0x30], '7': [0x01,0x71,0x09,0x05,0x03],
  '8': [0x36,0x49,0x49,0x49,0x36], '9': [0x06,0x49,0x49,0x29,0x1E],
  'A': [0x7E,0x11,0x11,0x11,0x7E], 'B': [0x7F,0x49,0x49,0x49,0x36],
  'C': [0x3E,0x41,0x41,0x41,0x22], 'D': [0x7F,0x41,0x41,0x22,0x1C],
  'E': [0x7F,0x49,0x49,0x49,0x41], 'F': [0x7F,0x09,0x09,0x09,0x01],
  'G': [0x3E,0x41,0x49,0x49,0x7A], 'H': [0x7F,0x08,0x08,0x08,0x7F],
  'I': [0x00,0x41,0x7F,0x41,0x00], 'J': [0x20,0x40,0x41,0x3F,0x01],
  'K': [0x7F,0x08,0x14,0x22,0x41], 'L': [0x7F,0x40,0x40,0x40,0x40],
  'M': [0x7F,0x02,0x0C,0x02,0x7F], 'N': [0x7F,0x04,0x08,0x10,0x7F],
  'O': [0x3E,0x41,0x41,0x41,0x3E], 'P': [0x7F,0x09,0x09,0x09,0x06],
  'Q': [0x3E,0x41,0x51,0x21,0x5E], 'R': [0x7F,0x09,0x19,0x29,0x46],
  'S': [0x46,0x49,0x49,0x49,0x31], 'T': [0x01,0x01,0x7F,0x01,0x01],
  'U': [0x3F,0x40,0x40,0x40,0x3F], 'V': [0x1F,0x20,0x40,0x20,0x1F],
  'W': [0x3F,0x40,0x38,0x40,0x3F], 'X': [0x63,0x14,0x08,0x14,0x63],
  'Y': [0x07,0x08,0x70,0x08,0x07], 'Z': [0x61,0x51,0x49,0x45,0x43],
  'a': [0x20,0x54,0x54,0x54,0x78], 'b': [0x7F,0x48,0x44,0x44,0x38],
  'c': [0x38,0x44,0x44,0x44,0x20], 'd': [0x38,0x44,0x44,0x48,0x7F],
  'e': [0x38,0x54,0x54,0x54,0x18], 'f': [0x08,0x7E,0x09,0x01,0x02],
  'g': [0x0C,0x52,0x52,0x52,0x3E], 'h': [0x7F,0x08,0x04,0x04,0x78],
  'i': [0x00,0x44,0x7D,0x40,0x00], 'j': [0x20,0x40,0x44,0x3D,0x00],
  'k': [0x7F,0x10,0x28,0x44,0x00], 'l': [0x00,0x41,0x7F,0x40,0x00],
  'm': [0x7C,0x04,0x18,0x04,0x78], 'n': [0x7C,0x08,0x04,0x04,0x78],
  'o': [0x38,0x44,0x44,0x44,0x38], 'p': [0x7C,0x14,0x14,0x14,0x08],
  'q': [0x08,0x14,0x14,0x18,0x7C], 'r': [0x7C,0x08,0x04,0x04,0x08],
  's': [0x48,0x54,0x54,0x54,0x20], 't': [0x04,0x3F,0x44,0x40,0x20],
  'u': [0x3C,0x40,0x40,0x20,0x7C], 'v': [0x1C,0x20,0x40,0x20,0x1C],
  'w': [0x3C,0x40,0x30,0x40,0x3C], 'x': [0x44,0x28,0x10,0x28,0x44],
  'y': [0x0C,0x50,0x50,0x50,0x3C], 'z': [0x44,0x64,0x54,0x4C,0x44],
  '°': [0x06,0x09,0x09,0x06,0x00],
};
const LCD_PX = 3.2, LCD_GAP = 0.8, LCD_CHG = 2.4, LCD_ROWG = 3.4, LCD_PAD = 13, LCD_BEZEL = 9;
const LCD_CW = 5 * (LCD_PX + LCD_GAP) - LCD_GAP;
const LCD_CH = 8 * (LCD_PX + LCD_GAP) - LCD_GAP;
const LCD_W  = 20 * (LCD_CW + LCD_CHG) - LCD_CHG + 2 * LCD_PAD;
const LCD_H  = 4 * (LCD_CH + LCD_ROWG) - LCD_ROWG + 2 * LCD_PAD;
const LCD_BG = '#1a2fbe', LCD_UNLIT = '#2742cf', LCD_LIT = '#eaf3ff';

function lcdCentered(s) {
  s = s.slice(0, 20);
  return ' '.repeat(Math.floor((20 - s.length) / 2)) + s;
}

function lcdSvg(rows) {
  const w = LCD_W + 2 * LCD_BEZEL, h = LCD_H + 2 * LCD_BEZEL;
  let out = '<svg viewBox="0 0 ' + w.toFixed(1) + ' ' + h.toFixed(1) + '" width="100%" xmlns="http://www.w3.org/2000/svg" role="img">';
  out += '<rect x="0" y="0" width="' + w.toFixed(1) + '" height="' + h.toFixed(1) + '" rx="5" fill="#181a1f"/>';
  out += '<rect x="' + LCD_BEZEL + '" y="' + LCD_BEZEL + '" width="' + LCD_W.toFixed(1) + '" height="' + LCD_H.toFixed(1) + '" rx="2.5" fill="' + LCD_BG + '"/>';
  for (let r = 0; r < 4; r++) {
    const text = (rows[r] || '').padEnd(20).slice(0, 20);
    const y0 = LCD_BEZEL + LCD_PAD + r * (LCD_CH + LCD_ROWG);
    for (let c = 0; c < 20; c++) {
      const glyph = LCD_FONT[text[c]] || LCD_FONT[' '];
      const x0 = LCD_BEZEL + LCD_PAD + c * (LCD_CW + LCD_CHG);
      for (let col = 0; col < 5; col++) {
        const bits = glyph[col];
        for (let row = 0; row < 8; row++) {
          const fill = (bits >> row) & 1 ? LCD_LIT : LCD_UNLIT;
          out += '<rect x="' + (x0 + col * (LCD_PX + LCD_GAP)).toFixed(2) + '" y="' + (y0 + row * (LCD_PX + LCD_GAP)).toFixed(2) + '" width="' + LCD_PX + '" height="' + LCD_PX + '" fill="' + fill + '"/>';
        }
      }
    }
  }
  out += '</svg>';
  return out;
}

document.getElementById('lcd-sim').innerHTML = lcdSvg([
  lcdCentered('== Claude Code =='), '', lcdCentered('IDLE'), lcdCentered('5h:42% in 2h13m')
]);

document.getElementById('bl-slider').addEventListener('input', e => {
  brightness = parseInt(e.target.value);
  document.getElementById('bl-num').textContent = brightness;
  document.getElementById('lcd-sim').style.filter = 'brightness(' + Math.max(5, brightness) + '%)';
  clearTimeout(blDebounce);
  blDebounce = setTimeout(() => api('/brightness', {value: brightness}), 80);
});
// Apply initial filter
document.getElementById('lcd-sim').style.filter = 'brightness(20%)';

// ── Preferences ───────────────────────────────────────────────────────────────
document.getElementById('pf-weather').addEventListener('change',  e=>prefs.weather  = e.target.checked);
document.getElementById('pf-sound').addEventListener('change',    e=>prefs.sound    = e.target.checked);
document.getElementById('pf-allclear').addEventListener('change', e=>prefs.allclear = e.target.checked);

// ── Finish ────────────────────────────────────────────────────────────────────
async function finish() {
  const nxt = document.getElementById('btn-next');
  nxt.disabled = true;
  nxt.textContent = 'Finishing…';
  try {
    const payload = { brightness, location: locPayload, prefs };
    await api('/config', payload);

    // Build done card
    const loc = locPayload;
    const rows = [
      ['Location',      loc ? loc.city+', '+loc.country : 'Not configured'],
      ['Air raid alerts', loc && loc.country_code==='ua' ? 'Enabled' : 'Disabled'],
      ['Brightness',    brightness+'%'],
      ['Weather',       prefs.weather ? 'Enabled' : 'Disabled'],
      ['Alert siren',   prefs.sound   ? 'Enabled' : 'Disabled'],
      ['All-clear chime', prefs.allclear ? 'Enabled' : 'Disabled'],
    ];
    const card = document.getElementById('done-card');
    card.innerHTML = rows.map(([k,v]) =>
      `<div class="done-row"><span class="done-key">${k}</span><span class="done-val ${v.startsWith('En')?'green':''}">${v}</span></div>`
    ).join('');

    goTo(5);
  } catch (err) {
    nxt.disabled = false;
    nxt.textContent = 'Finish setup';
    showFatalError(err && err.message ? err.message : String(err));
  }
}

goTo(0);  // start on the Connect page and kick off its poll
</script>
</body>
</html>
'@

function Show-SetupWizard {
    Step "Launching setup wizard"

    # The device may not be plugged in yet -- a brand-new machine that has
    # never seen this device before shouldn't require the user to have
    # already connected it before running the installer. Everything
    # hardware-related (driver fix, flashing, opening serial for the
    # brightness preview) is deferred to the wizard's own "Connect your
    # device" page and its /portcheck poll, below, rather than done
    # up-front -- so this starts with nothing plugged in assumed.
    $deviceReady = $false

    # Serial writes happen on a background runspace, never on the HTTP
    # loop's own thread. .NET's SerialPort is notorious for not reliably
    # honouring WriteTimeout on flaky USB-serial hardware (this project has
    # already hit real CH340 driver quirks) -- if a single WriteLine call
    # from a brightness-slider drag ever truly hangs, it must not be able
    # to freeze the single-threaded loop that also has to service the
    # later "Finish setup" POST /config request on that same thread.
    $serial       = $null
    $serialState  = [hashtable]::Synchronized(@{ Pending = $null; Cmd = $null; Stop = $false })
    $serialRunner = $null
    $serialPs     = $null
    $serialHandle = $null

    # Returns @{ Serial=...; Ps=...; Runner=...; Handle=... } on success, or
    # $null if the port couldn't be opened. Takes $state explicitly (rather
    # than closing over the caller's $serialState) so this stays a plain,
    # side-effect-free helper -- the caller assigns the pieces it gets back
    # onto its OWN local variables, which keeps all the serial-preview
    # state scoped to this one Show-SetupWizard invocation instead of
    # leaking onto $script:.
    function Start-BrightnessPreview([string]$port, $state) {
        $s = New-Object System.IO.Ports.SerialPort($port, 9600)
        $s.DtrEnable = $false
        $s.RtsEnable = $false
        $s.WriteTimeout = 300

        # Called right after Flash-Arduino/avrdude just used this same
        # port. avrdude's own post-write verify step already proves the
        # board is alive and responding here, so a failed open isn't the
        # board still resetting -- more likely Windows hasn't fully
        # released avrdude's handle yet. Retry a few times with short
        # delays rather than giving up on the very first attempt (observed
        # in practice: an immediate, un-retried open right after flashing
        # hit "a device attached to the system is not functioning" and
        # never recovered without a physical replug -- the same class of
        # CH340 wedge this project has hit before). This can't fix a
        # genuine hardware wedge, only a brief handle-release race.
        $opened   = $false
        $lastErr  = $null
        for ($i = 1; $i -le 4; $i++) {
            Start-Sleep -Milliseconds 700
            try { $s.Open(); $opened = $true; break } catch { $lastErr = $_ }
        }
        if (-not $opened) {
            Warn2 "Could not open $port for brightness preview: $lastErr"
            return $null
        }
        Start-Sleep -Seconds 2  # wait for Arduino post-flash boot
        Info "Serial open — brightness preview active"
        $runner = [runspacefactory]::CreateRunspace()
        $runner.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runner
        [void]$ps.AddScript({
            param($state, $port)
            while (-not $state.Stop) {
                $val = $state.Pending
                if ($null -ne $val) {
                    $state.Pending = $null   # claim it before writing
                    try { if ($port.IsOpen) { $port.WriteLine("L:$val") } } catch {}
                }
                $cmd = $state.Cmd
                if ($null -ne $cmd) {
                    $state.Cmd = $null       # claim it before writing
                    try { if ($port.IsOpen) { $port.WriteLine($cmd) } } catch {}
                }
                Start-Sleep -Milliseconds 40
            }
        }).AddArgument($state).AddArgument($s)
        $handle = $ps.BeginInvoke()
        return @{ Serial = $s; Ps = $ps; Runner = $runner; Handle = $handle }
    }

    $httpPort = 18742
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$httpPort/")
    try { $listener.Start() } catch {
        throw "Cannot bind to port $httpPort. Another setup may be running."
    }

    # The wizard binds only to loopback, but that still means any other
    # website open in the user's browser during this run can reach it --
    # localhost servers are same-machine, not same-origin. A random per-run
    # token, known only to the page this listener itself serves, is what
    # stops a foreign page from driving /portcheck (re-flashes the device
    # and kills the running daemon), /brightness, or /config blind.
    $wizardToken = [guid]::NewGuid().ToString('N')
    $wizardHtml = $WIZARD_HTML.Replace('%%PORT%%', $httpPort.ToString()).Replace('%%TOKEN%%', $wizardToken)
    $htmlBytes  = [System.Text.Encoding]::UTF8.GetBytes($wizardHtml)
    $okBytes    = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')

    Info "Opening setup wizard in your browser…"
    Start-Process "http://localhost:$httpPort/"
    Info "Complete the wizard, then installation will continue automatically."

    $result   = $null
    $deadline = [DateTime]::UtcNow.AddMinutes(20)

    function Write-Response($resp, $ct, $bytes, $status=200) {
        $resp.StatusCode      = $status
        $resp.ContentType     = $ct
        $resp.ContentLength64 = $bytes.Length
        # The wizard always binds the same fixed port, so without this the
        # browser can serve a stale cached copy of the HTML/JS from an
        # earlier run of the installer -- e.g. an older build that predates
        # a bug fix, making it look like the fix "didn't work".
        $resp.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
        $resp.Headers.Add('Pragma', 'no-cache')
        try { $resp.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
        try { $resp.Close() } catch {}
    }

    try {
        # Exactly one BeginGetContext must be outstanding at a time. Calling
        # it again on every idle timeout (as a naive retry loop would) leaves
        # each prior call pending forever uncompleted -- and HttpListener can
        # satisfy ANY outstanding BeginGetContext when a request arrives, not
        # necessarily the newest one this loop is watching. Over a 20-minute
        # session that idles between wizard steps, that silently swallowed
        # real requests (observed: POSTs timing out against a live listener).
        $async = $listener.BeginGetContext($null, $null)
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $result) {
            $msLeft = [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($msLeft -le 0) { break }

            $got = $async.AsyncWaitHandle.WaitOne([Math]::Min($msLeft, 2000))
            if (-not $got) { continue }

            $ctx  = $listener.EndGetContext($async)
            $async = $listener.BeginGetContext($null, $null)
            $req  = $ctx.Request
            $resp = $ctx.Response
            # No Access-Control-Allow-Origin here on purpose: this listener is
            # loopback-only, but loopback isn't same-origin -- any other site
            # open in the browser during setup could otherwise read responses
            # from it. The wizard page itself never needs CORS (it always
            # calls its own origin), so omitting it costs the real UI nothing
            # while stopping a foreign page from reading answers back.

            $method = $req.HttpMethod
            $url    = ($req.RawUrl -split '\?')[0]

            if ($method -eq 'OPTIONS') {
                $resp.StatusCode = 200; $resp.Close(); continue
            }

            # /portcheck, /brightness, and /config all have side effects
            # (flashing the board, killing the running daemon, writing to the
            # serial port, finishing setup) -- require the per-run token so a
            # page in another tab can't drive them blind. GET / stays open:
            # it's how the page carrying the token loads in the first place.
            if ($url -in @('/portcheck', '/brightness', '/config')) {
                if ($req.Headers['X-Wizard-Token'] -ne $wizardToken) {
                    Write-Response $resp 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('Forbidden')) 403
                    continue
                }
            }

            switch ("$method $url") {
                'GET /' {
                    Write-Response $resp 'text/html; charset=utf-8' $htmlBytes
                }
                'GET /portcheck' {
                    if ($deviceReady) {
                        Write-Response $resp 'application/json' ([System.Text.Encoding]::UTF8.GetBytes('{"status":"ready"}'))
                    } else {
                        $found = Try-DetectPort
                        if (-not $found) {
                            Write-Response $resp 'application/json' ([System.Text.Encoding]::UTF8.GetBytes('{"status":"waiting"}'))
                        } else {
                            # Found it. A single poll response can't carry
                            # two states ("found" then "flashed"), so this
                            # just does the whole driver-check + flash
                            # inline -- this poll cycle takes a few extra
                            # seconds, which is fine for a polling UI with
                            # nothing else for the user to do meanwhile.
                            try {
                                $script:IsCH340 = $found.IsCH340
                                Ensure-CH340Driver
                                Stop-Daemon
                                Flash-Arduino $found.Port
                                $preview = Start-BrightnessPreview $found.Port $serialState
                                if ($preview) {
                                    $serial       = $preview.Serial
                                    $serialPs     = $preview.Ps
                                    $serialRunner = $preview.Runner
                                    $serialHandle = $preview.Handle
                                }
                                $deviceReady = $true
                                Write-Response $resp 'application/json' ([System.Text.Encoding]::UTF8.GetBytes('{"status":"ready"}'))
                            } catch {
                                # ConvertTo-Json handles proper escaping (a
                                # hand-rolled replace of just the quote
                                # character would leave backslashes -- e.g.
                                # from a Windows file path in the exception
                                # message -- unescaped, producing invalid
                                # JSON that JS's JSON.parse would reject).
                                $errJson = @{ status = 'error'; message = $_.Exception.Message } | ConvertTo-Json -Compress
                                Write-Response $resp 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($errJson))
                            }
                        }
                    }
                }
                'POST /brightness' {
                    try {
                        $reader = New-Object System.IO.StreamReader($req.InputStream,
                            [System.Text.Encoding]::UTF8)
                        $body = $reader.ReadToEnd()
                        $data = $body | ConvertFrom-Json
                        # Hand off to the background serial-writer runspace
                        # and return immediately -- never block this HTTP
                        # thread on the actual serial I/O (see notes above).
                        $serialState.Pending = [int]$data.value
                    } catch {}
                    Write-Response $resp 'application/json' $okBytes
                }
                'POST /config' {
                    try {
                        $reader = New-Object System.IO.StreamReader($req.InputStream,
                            [System.Text.Encoding]::UTF8)
                        $result = $reader.ReadToEnd() | ConvertFrom-Json
                    } catch { $result = [PSCustomObject]@{} }
                    # Tell the device setup is done right as the browser shows its
                    # own "All set" page, instead of leaving "Run setup to start" on
                    # screen for however long Copy-AppFiles/Register-AutoStart/
                    # Start-DaemonNow take to run afterward.
                    if ($serial) {
                        $serialState.Cmd = "D"
                        # This is the last request of the wizard loop: setting
                        # $result below makes the outer while exit almost
                        # immediately, and its `finally` tears down the
                        # background writer by setting Stop -- which races
                        # ahead of that writer's 40ms poll interval and was
                        # silently dropping "D" essentially every time. Wait
                        # (bounded, not indefinitely -- this doesn't touch the
                        # serial port itself, just a shared variable) for the
                        # writer to actually pick it up before moving on.
                        $waitUntil = [DateTime]::UtcNow.AddMilliseconds(500)
                        while ($null -ne $serialState.Cmd -and [DateTime]::UtcNow -lt $waitUntil) {
                            Start-Sleep -Milliseconds 20
                        }
                    }
                    Write-Response $resp 'application/json' $okBytes
                }
                default {
                    Write-Response $resp 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('Not found')) 404
                }
            }
        }
    } finally {
        try { $listener.Stop() } catch {}
        if ($serialPs) {
            $serialState.Stop = $true
            try {
                # Give the background writer a moment to notice Stop and
                # finish any in-flight write, but don't wait indefinitely
                # -- that would reintroduce exactly the kind of hang this
                # background thread exists to isolate us from.
                $null = $serialHandle.AsyncWaitHandle.WaitOne(1000)
            } catch {}
            try { $serialPs.Dispose() } catch {}
            try { $serialRunner.Close() } catch {}
        }
        if ($serial -and $serial.IsOpen) {
            try { $serial.Close() } catch {}
        }
    }

    if ($null -eq $result) { Warn2 "Wizard timed out or was closed early. Defaults used." }
    return $result
}

function Resolve-CityGeocode([string]$name) {
    $url = "https://geocoding-api.open-meteo.com/v1/search?name=$([uri]::EscapeDataString($name))&count=1&language=en&format=json"
    try   { $resp = Invoke-RestMethod -Uri $url -TimeoutSec 10 }
    catch { Warn2 "Geocoding API unreachable: $_"; return $null }
    if (-not $resp.results -or $resp.results.Count -lt 1) { return $null }
    return $resp.results[0]
}

function Write-DaemonConfig([object]$wizardResult) {
    Step "Writing config.json"

    $cfg = [ordered]@{}

    # --- Brightness ---
    $bl = 20
    if ($wizardResult -and $wizardResult.brightness -ne $null) {
        try { $bl = [int]$wizardResult.brightness } catch {}
    }
    $cfg['brightness'] = $bl

    # --- Weather / location ---
    if ($NoWeather) {
        $cfg['weather'] = $null
        Info "Weather disabled (-NoWeather)"
    } elseif ($City) {
        # Non-interactive -City flag
        $hit = Resolve-CityGeocode $City
        if ($hit) {
            $cfg['weather'] = [ordered]@{
                city         = "$($hit.name)"
                country      = "$($hit.country)"
                country_code = "$($hit.country_code)"
                latitude     = [double]$hit.latitude
                longitude    = [double]$hit.longitude
                alert_region = ''
            }
            Done "Location (geocoded): $($hit.name), $($hit.country)"
        } else {
            Warn2 "Could not geocode '$City' — weather disabled"
            $cfg['weather'] = $null
        }
    } elseif ($wizardResult -and $wizardResult.location) {
        $loc = $wizardResult.location
        $cfg['weather'] = [ordered]@{
            city         = "$($loc.city)"
            country      = "$($loc.country)"
            country_code = "$($loc.country_code)"
            latitude     = [double]$loc.latitude
            longitude    = [double]$loc.longitude
            alert_region = "$($loc.alert_region)"
        }
        Done "Location: $($loc.city), $($loc.country)"
    } else {
        $cfg['weather'] = $null
        Info "No location selected — weather disabled"
    }

    # --- Preferences ---
    $prefs = [ordered]@{ weather=$true; sound=$true; allclear=$true }
    if ($wizardResult -and $wizardResult.prefs) {
        $p = $wizardResult.prefs
        if ($p.PSObject.Properties['weather'])  { $prefs['weather']  = [bool]$p.weather  }
        if ($p.PSObject.Properties['sound'])    { $prefs['sound']    = [bool]$p.sound    }
        if ($p.PSObject.Properties['allclear']) { $prefs['allclear'] = [bool]$p.allclear }
    }
    $cfg['prefs'] = $prefs

    $cfgPath = Join-Path $appDir 'config.json'
    ($cfg | ConvertTo-Json -Depth 5) | Set-Content -Path $cfgPath -Encoding UTF8
    Done "Config: $cfgPath"
}

function Build-HookBlock([string]$cmd, $matcher) {
    $h = [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ type='command'; command=$cmd; timeout=5 })
    }
    if ($null -ne $matcher) {
        $h | Add-Member -NotePropertyName 'matcher' -NotePropertyValue $matcher
    }
    return $h
}

function Patch-Settings {
    Step "Patching ~/.claude/settings.json"
    $settingsDir  = Join-Path $env:USERPROFILE '.claude'
    $settingsPath = Join-Path $settingsDir 'settings.json'
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

    if (Test-Path $settingsPath) {
        $backup = "$settingsPath.claudestatus_backup"
        if (-not (Test-Path $backup)) {
            Copy-Item $settingsPath $backup
            Info "Backup: $backup"
        }
        $raw = Get-Content $settingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
        $obj = $raw | ConvertFrom-Json
    } else {
        $obj = [PSCustomObject]@{}
    }

    if (-not ($obj.PSObject.Properties.Match('hooks'))) {
        $obj | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }

    $notify  = (Join-Path $appDir 'notify.py').Replace('\','/')
    $pretool = (Join-Path $appDir 'hook_pretool.py').Replace('\','/')

    $obj.hooks | Add-Member -Force -NotePropertyName 'UserPromptSubmit' -NotePropertyValue @(Build-HookBlock "pythonw `"$notify`" W"  $null)
    $obj.hooks | Add-Member -Force -NotePropertyName 'PreToolUse'       -NotePropertyValue @(Build-HookBlock "pythonw `"$pretool`""   '')
    $obj.hooks | Add-Member -Force -NotePropertyName 'PostToolUse'      -NotePropertyValue @(Build-HookBlock "pythonw `"$notify`" C"  '')
    $obj.hooks | Add-Member -Force -NotePropertyName 'Notification'     -NotePropertyValue @(Build-HookBlock "pythonw `"$notify`" P"  $null)
    $obj.hooks | Add-Member -Force -NotePropertyName 'Stop'             -NotePropertyValue @(Build-HookBlock "pythonw `"$notify`" I"  $null)
    $obj.hooks | Add-Member -Force -NotePropertyName 'PreCompact'       -NotePropertyValue @(Build-HookBlock "pythonw `"$notify`" M"  $null)

    ($obj | ConvertTo-Json -Depth 30) | Set-Content -Path $settingsPath -Encoding UTF8
    Done "Hooks registered"
}

function Register-AutoStart {
    if ($NoAutostart) { Info "Skipping auto-start (-NoAutostart)"; return }
    Step "Registering Task Scheduler entry 'ClaudeStatusDaemon'"
    $pythonw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
    if (-not $pythonw) { Warn2 "pythonw.exe not on PATH — skipping auto-start."; return }
    $daemon  = Join-Path $appDir 'lcd_daemon.py'
    $action  = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$daemon`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
               -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    Register-ScheduledTask -TaskName 'ClaudeStatusDaemon' `
        -Action $action -Trigger $trigger -Settings $set -Force | Out-Null
    Done "Auto-start registered (runs at logon)"
}

function Start-DaemonNow {
    Step "Starting LCD daemon"
    $pythonw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
    if (-not $pythonw) { $pythonw = 'pythonw' }
    $daemon = Join-Path $appDir 'lcd_daemon.py'
    try {
        Start-Process -FilePath $pythonw -ArgumentList "`"$daemon`"" `
            -WindowStyle Hidden -PassThru | Out-Null
        Done "Daemon started — LCD will update momentarily"
    } catch {
        Info "Could not start daemon automatically. It will start on the next claude launch."
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==== ClaudeStatus LCD — Installer ====" -ForegroundColor Yellow
Write-Host "Install path: $installDir"
Write-Host ""

Ensure-Python
Ensure-PySerial

if ($City -or $NoWeather) {
    # Non-interactive path: no browser UI to wait in, so this still needs
    # the device plugged in up front (throws if it isn't).
    Ensure-CH340Driver
    $detectedPort = Detect-Port
    Stop-Daemon
    Flash-Arduino $detectedPort
    Copy-AppFiles
    Write-DaemonConfig $null
    Patch-Settings
} else {
    # Interactive path: Copy-AppFiles doesn't need the device, so it can
    # happen immediately. The wizard's own "Connect your device" page owns
    # detecting, driver-fixing and flashing it from here -- a brand-new
    # machine that has never had the device plugged in doesn't need it
    # connected before running the installer, only before finishing setup.
    Copy-AppFiles
    $wizardResult = Show-SetupWizard
    Write-DaemonConfig $wizardResult
    Patch-Settings
}

Register-AutoStart
Start-DaemonNow

Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host "Run 'claude' in any terminal to start using the LCD."
Write-Host "Brightness: python `"$appDir\bl.py`"           (interactive, arrow keys)"
Write-Host "            python `"$appDir\bl.py`" 50        (set directly, 0-100)"
Write-Host "Uninstall:  .\uninstall.ps1"
Write-Host ""
