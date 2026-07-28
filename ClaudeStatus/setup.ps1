#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Claude Code LCD status system on this PC.

.DESCRIPTION
    Walks through a browser-based setup wizard that lets the user:
      - Pick their city on a live map (weather + air raid alerts for Ukraine)
      - Adjust the display brightness with live preview on the hardware
      - Toggle preferences (weather, alert sounds, all-clear chime)

    The installer also:
      - Ensures Python 3 and pyserial are present (installs via winget if missing)
      - Ensures the CH340 USB-serial driver is v3.4 (newer WCH drivers fail to
        open the port on many clone chips) — installs the bundled v3.4 if needed
      - Auto-detects the Arduino by USB VID:PID and flashes claude_status.hex
        with bundled avrdude (tries both bootloader baud rates)
      - Copies daemon / hook scripts to %LOCALAPPDATA%\ClaudeStatus\app\
      - Patches ~/.claude/settings.json to register the five Claude Code hooks
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

function Detect-Port {
    Step "Detecting Arduino COM port"
    if ($Port) { Done "Using override: $Port"; return $Port }
    $devs = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\(COM\d+\)' }
    # Known USB IDs first — immune to localised/renamed friendly names.
    foreach ($id in @($USB_ID_UNO, $USB_ID_CH340)) {
        foreach ($d in $devs) {
            if ($d.DeviceID -match $id -and $d.Name -match '\((COM\d+)\)') {
                $script:IsCH340 = ($id -eq $USB_ID_CH340)
                Done "Found '$($d.Name)'"
                return $matches[1]
            }
        }
    }
    # Fallback heuristics for other USB-serial adapters (FTDI, CP210x, ...).
    $hits = $devs | Where-Object {
        $_.Name -match "Arduino|CH340|CH341|USB Serial|FTDI|Silicon Labs|wch.cn"
    }
    foreach ($d in $hits) {
        if ($d.Name -match '\((COM\d+)\)') {
            Done "Found '$($d.Name)'"
            return $matches[1]
        }
    }
    throw "Could not auto-detect an Arduino COM port. Plug it in and re-run, or pass -Port COMx."
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
<title>ClaudeStatus — Setup</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden;background:#0d0d0d;color:#bbb;
  font-family:system-ui,-apple-system,'Segoe UI',sans-serif;font-size:14px}

/* Step dots */
#stepdots{display:flex;align-items:center;gap:6px;padding:14px 20px;
  background:#111;border-bottom:1px solid #1e1e1e}
.dot{width:8px;height:8px;border-radius:50%;background:#2a2a2a;
  transition:background .25s}
.dot.done{background:#1a5c3a}
.dot.active{background:#2ecc71;box-shadow:0 0 6px #2ecc7155}
#step-label{margin-left:auto;font-size:11px;color:#444;letter-spacing:.5px}

/* Page container */
#pages{position:relative;height:calc(100vh - 49px - 56px);overflow:hidden}
.page{position:absolute;inset:0;display:flex;flex-direction:column;
  opacity:0;pointer-events:none;transition:opacity .25s}
.page.active{opacity:1;pointer-events:all}

/* Nav bar */
#nav{height:56px;background:#111;border-top:1px solid #1e1e1e;
  display:flex;align-items:center;justify-content:space-between;padding:0 20px;gap:12px}
.btn{padding:9px 24px;border:none;border-radius:5px;font-size:13px;
  font-weight:600;cursor:pointer;transition:background .15s,opacity .15s}
#btn-back{background:#1a1a1a;color:#555}
#btn-back:hover{background:#222;color:#888}
#btn-skip{background:none;border:none;color:#444;font-size:12px;cursor:pointer;
  padding:8px 12px}
#btn-skip:hover{color:#888}
#btn-next{background:#2ecc71;color:#fff;min-width:120px}
#btn-next:hover:not(:disabled){background:#27ae60}
#btn-next:disabled{background:#1a3a28;color:#2a6642;cursor:default}

/* ── Welcome ── */
#p-welcome{justify-content:center;align-items:center;gap:28px;text-align:center;padding:40px}
.logo{font-size:36px;font-weight:200;letter-spacing:6px;color:#fff}
.logo b{color:#2ecc71;font-weight:700}
.tagline{color:#555;font-size:14px;max-width:400px;line-height:1.7}
.device-hint{display:inline-block;background:#141414;border:1px solid #1e1e1e;
  border-radius:6px;padding:10px 18px;font-size:12px;color:#444;margin-top:4px}
.device-hint code{color:#2ecc71}

/* ── Location ── */
#p-location{flex-direction:column}
#map{flex:1}
#loc-bar{padding:12px 20px;background:#111;border-top:1px solid #1e1e1e;
  display:flex;align-items:center;gap:12px;min-height:56px}
#loc-city{font-size:14px;color:#fff;font-weight:600;line-height:1.3}
#loc-note{font-size:11px;margin-top:2px}
.note-ua{color:#2ecc71}
.note-other{color:#e67e22}
.note-idle{color:#444}
#loc-spinner{width:14px;height:14px;border:2px solid #2ecc71;border-top-color:transparent;
  border-radius:50%;animation:spin .6s linear infinite;flex-shrink:0;display:none}
@keyframes spin{to{transform:rotate(360deg)}}

/* ── Brightness ── */
#p-brightness{justify-content:center;align-items:center;gap:28px;padding:32px 24px}
.lcd{background:#001422;border:2px solid #002444;border-radius:4px;
  padding:14px 18px;font-family:'Courier New',Courier,monospace;font-size:15px;
  color:#7ab8e8;letter-spacing:1.5px;line-height:2.1;
  width:100%;max-width:440px;
  box-shadow:0 0 30px rgba(0,80,180,.25),inset 0 0 20px rgba(0,30,80,.5);
  transition:filter .08s}
.lcd-row{white-space:pre}
.bl-wrap{width:100%;max-width:440px}
.bl-label{display:flex;justify-content:space-between;margin-bottom:10px;
  font-size:12px;color:#555}
.bl-label span{color:#fff;font-size:16px;font-weight:600}
input[type=range]{width:100%;appearance:none;height:4px;background:#1e1e1e;
  border-radius:2px;outline:none;cursor:pointer}
input[type=range]::-webkit-slider-thumb{appearance:none;width:18px;height:18px;
  background:#2ecc71;border-radius:50%;cursor:pointer;transition:transform .1s}
input[type=range]::-webkit-slider-thumb:hover{transform:scale(1.2)}
.bl-note{font-size:11px;color:#444;text-align:center;max-width:400px;line-height:1.6}

/* ── Preferences ── */
#p-prefs{justify-content:center;align-items:center;padding:32px 24px;gap:8px}
.pref-section{width:100%;max-width:440px}
.pref-heading{font-size:10px;color:#444;text-transform:uppercase;
  letter-spacing:1.2px;margin-bottom:12px;padding-left:2px}
.pref-item{display:flex;justify-content:space-between;align-items:center;
  padding:13px 0;border-bottom:1px solid #161616}
.pref-item:last-child{border:none}
.pref-text{}
.pref-name{font-size:13px;color:#ccc}
.pref-desc{font-size:11px;color:#444;margin-top:2px}
/* toggle */
.toggle{position:relative;width:40px;height:22px;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.tslider{position:absolute;inset:0;background:#222;border-radius:11px;cursor:pointer;
  transition:background .2s}
.tslider::before{content:'';position:absolute;width:16px;height:16px;
  left:3px;top:3px;background:#444;border-radius:50%;transition:.2s}
.toggle input:checked+.tslider{background:#2ecc71}
.toggle input:checked+.tslider::before{transform:translateX(18px);background:#fff}

/* ── Done ── */
#p-done{justify-content:center;align-items:center;gap:20px;padding:40px;text-align:center}
.done-check{font-size:56px;line-height:1}
.done-title{font-size:22px;color:#fff;font-weight:300}
.done-card{background:#111;border:1px solid #1e1e1e;border-radius:8px;
  padding:18px 24px;width:100%;max-width:420px;text-align:left}
.done-row{display:flex;justify-content:space-between;padding:6px 0;
  border-bottom:1px solid #181818;font-size:12px}
.done-row:last-child{border:none}
.done-key{color:#444}
.done-val{color:#ccc}
.done-val.green{color:#2ecc71}
.done-hint{font-size:12px;color:#444;max-width:380px;line-height:1.6}
.done-hint code{color:#2ecc71;background:#0d1f0d;padding:1px 5px;border-radius:3px}
</style>
</head>
<body>

<div id="stepdots">
  <div class="dot active" data-i="0"></div>
  <div class="dot" data-i="1"></div>
  <div class="dot" data-i="2"></div>
  <div class="dot" data-i="3"></div>
  <div class="dot" data-i="4"></div>
  <span id="step-label">WELCOME</span>
</div>

<div id="pages">

  <!-- 0: Welcome -->
  <div class="page active" id="p-welcome">
    <div class="logo">Claude<b>Status</b></div>
    <p class="tagline">Your Arduino LCD display is connected and ready. This wizard configures location, display brightness, and alert preferences — takes about 2 minutes.</p>
    <div class="device-hint">Device detected &amp; flashed &nbsp;·&nbsp; <code>claude_status.hex</code></div>
  </div>

  <!-- 1: Location -->
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

  <!-- 2: Brightness -->
  <div class="page" id="p-brightness">
    <div class="lcd" id="lcd-sim">
      <div class="lcd-row">== Claude Code ==   </div>
      <div class="lcd-row" id="lcd-row1">        IDLE        </div>
      <div class="lcd-row" id="lcd-row2">                    </div>
      <div class="lcd-row" id="lcd-row3">                    </div>
    </div>
    <div class="bl-wrap">
      <div class="bl-label">
        <span>Display brightness</span>
        <span id="bl-num">20</span><span style="color:#555">%</span>
      </div>
      <input type="range" id="bl-slider" min="0" max="100" value="20">
    </div>
    <p class="bl-note">Adjust until the display is comfortable. The value is saved to the device and restored on every power-up.</p>
  </div>

  <!-- 3: Preferences -->
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

  <!-- 4: Done -->
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
  <button class="btn" id="btn-next">Get started →</button>
</div>

<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
'use strict';
const PORT = %%PORT%%;
const STEP_LABELS = ['WELCOME','LOCATION','BRIGHTNESS','PREFERENCES','DONE'];

let step = 0;
let locPayload = null;
let brightness = 20;
let prefs = { weather: true, sound: true, allclear: true };
let map, marker;
let blDebounce;

// ── Routing ──────────────────────────────────────────────────────────────────
async function api(path, body) {
  try {
    await fetch('http://localhost:' + PORT + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
  } catch (_) {}
}

// ── Navigation ────────────────────────────────────────────────────────────────
const PAGES = ['p-welcome','p-location','p-brightness','p-prefs','p-done'];
function goTo(n) {
  document.querySelectorAll('.page').forEach((p,i) => p.classList.toggle('active', i===n));
  document.querySelectorAll('.dot').forEach((d,i) => {
    d.classList.toggle('active', i===n);
    d.classList.toggle('done', i<n);
  });
  document.getElementById('step-label').textContent = STEP_LABELS[n];
  document.getElementById('btn-back').style.visibility = (n>0 && n<4) ? 'visible' : 'hidden';
  document.getElementById('btn-skip').style.display = (n===1) ? 'inline-block' : 'none';

  const nxt = document.getElementById('btn-next');
  if      (n===0) { nxt.textContent='Get started →'; nxt.disabled=false; }
  else if (n===1) { nxt.textContent='Next →';        nxt.disabled=!locPayload; }
  else if (n===2) { nxt.textContent='Next →';        nxt.disabled=false; }
  else if (n===3) { nxt.textContent='Finish setup';  nxt.disabled=false; }
  else            { nxt.style.display='none'; document.getElementById('btn-back').style.visibility='hidden'; }

  if (n===1 && !map) initMap();
  if (n===1 && map) setTimeout(()=>map.invalidateSize(),50);
  step = n;
}

document.getElementById('btn-back').addEventListener('click', ()=>goTo(step-1));
document.getElementById('btn-skip').addEventListener('click', ()=>{ locPayload=null; goTo(2); });
document.getElementById('btn-next').addEventListener('click', async ()=>{
  if (step===3) { await finish(); return; }
  goTo(step+1);
});

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
document.getElementById('bl-slider').addEventListener('input', e => {
  brightness = parseInt(e.target.value);
  document.getElementById('bl-num').textContent = brightness;
  document.getElementById('lcd-sim').style.filter = 'brightness(' + Math.max(5, brightness) + '%)';
  clearTimeout(blDebounce);
  blDebounce = setTimeout(() => api('/brightness', {value: brightness}), 80);
});
// Apply initial filter
document.getElementById('lcd-sim').style.filter = 'brightness(20%)';

// Live clock in LCD sim (mimics the idle screensaver the device shows)
(function tickClock() {
  const DAYS = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  function pad2(n) { return String(n).padStart(2,'0'); }
  function pad(s, n) { return s.length >= n ? s.substring(0,n) : s + ' '.repeat(n - s.length); }
  const now = new Date();
  const hhmm = pad2(now.getHours()) + ':' + pad2(now.getMinutes());
  const date = DAYS[now.getDay()] + ', ' + MONTHS[now.getMonth()] + ' ' + pad2(now.getDate());
  document.getElementById('lcd-row2').textContent = pad(hhmm, 20);
  document.getElementById('lcd-row3').textContent = pad(date, 20);
  const msToNextMin = (60 - now.getSeconds()) * 1000 - now.getMilliseconds();
  setTimeout(tickClock, msToNextMin);
})();

// ── Preferences ───────────────────────────────────────────────────────────────
document.getElementById('pf-weather').addEventListener('change',  e=>prefs.weather  = e.target.checked);
document.getElementById('pf-sound').addEventListener('change',    e=>prefs.sound    = e.target.checked);
document.getElementById('pf-allclear').addEventListener('change', e=>prefs.allclear = e.target.checked);

// ── Finish ────────────────────────────────────────────────────────────────────
async function finish() {
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

  goTo(4);
}
</script>
</body>
</html>
'@

function Show-SetupWizard([string]$comPort) {
    Step "Launching setup wizard"

    # Try to open serial for live brightness preview.
    $serial = $null
    try {
        $serial = New-Object System.IO.Ports.SerialPort($comPort, 9600)
        $serial.DtrEnable = $false
        $serial.RtsEnable = $false
        $serial.WriteTimeout = 500
        $serial.Open()
        Start-Sleep -Seconds 3  # wait for Arduino post-flash boot
        Info "Serial open — brightness preview active"
    } catch {
        Warn2 "Could not open $comPort for brightness preview: $_"
        $serial = $null
    }

    $httpPort = 18742
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$httpPort/")
    try { $listener.Start() } catch {
        throw "Cannot bind to port $httpPort. Another setup may be running."
    }

    $wizardHtml = $WIZARD_HTML.Replace('%%PORT%%', $httpPort.ToString())
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
        try { $resp.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
        try { $resp.Close() } catch {}
    }

    try {
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $result) {
            $msLeft = [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($msLeft -le 0) { break }

            $async = $listener.BeginGetContext($null, $null)
            $got   = $async.AsyncWaitHandle.WaitOne([Math]::Min($msLeft, 2000))
            if (-not $got) { continue }

            $ctx  = $listener.EndGetContext($async)
            $req  = $ctx.Request
            $resp = $ctx.Response
            $resp.Headers.Add('Access-Control-Allow-Origin',  '*')
            $resp.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $resp.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

            $method = $req.HttpMethod
            $url    = ($req.RawUrl -split '\?')[0]

            if ($method -eq 'OPTIONS') {
                $resp.StatusCode = 200; $resp.Close(); continue
            }

            switch ("$method $url") {
                'GET /' {
                    Write-Response $resp 'text/html; charset=utf-8' $htmlBytes
                }
                'POST /brightness' {
                    try {
                        $reader = New-Object System.IO.StreamReader($req.InputStream,
                            [System.Text.Encoding]::UTF8)
                        $body = $reader.ReadToEnd()
                        $data = $body | ConvertFrom-Json
                        $val  = [int]$data.value
                        if ($serial -and $serial.IsOpen) {
                            $serial.WriteLine("L:$val")
                        }
                    } catch {}
                    Write-Response $resp 'application/json' $okBytes
                }
                'POST /config' {
                    try {
                        $reader = New-Object System.IO.StreamReader($req.InputStream,
                            [System.Text.Encoding]::UTF8)
                        $result = $reader.ReadToEnd() | ConvertFrom-Json
                    } catch { $result = [PSCustomObject]@{} }
                    Write-Response $resp 'application/json' $okBytes
                }
                default {
                    Write-Response $resp 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('Not found')) 404
                }
            }
        }
    } finally {
        try { $listener.Stop() } catch {}
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
Ensure-CH340Driver
$detectedPort = Detect-Port
Stop-Daemon
Flash-Arduino $detectedPort
Copy-AppFiles

if ($City -or $NoWeather) {
    # Non-interactive path: skip wizard, write config directly
    Write-DaemonConfig $null
    Patch-Settings
} else {
    $wizardResult = Show-SetupWizard $detectedPort
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
