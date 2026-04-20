param(
    # Relative or absolute URL to the source web page that contains a video player.
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("PageUrl")]
    [string]$Url
)

$ErrorActionPreference = "Stop"
$extractProgressId = 7101

function Write-ExtractLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[Extract] {0}" -f $Message)
}

function Set-ExtractProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$PercentComplete
    )

    Write-Progress -Id $extractProgressId -Activity "Extract playlist" -Status $Status -PercentComplete $PercentComplete
}

function Complete-ExtractProgress {
    Write-Progress -Id $extractProgressId -Activity "Extract playlist" -Completed
}

function Exit-WithError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [Console]::Error.WriteLine($Message)
    exit 1
}

function Get-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$Name is required, but it was not found in PATH"
    }

    return $command.Source
}

function Get-SystemBrowserPath {
    $candidates = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $browserCommands = @("chrome", "chrome.exe", "msedge", "msedge.exe")
    foreach ($browserCommand in $browserCommands) {
        $command = Get-Command $browserCommand -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

try {
    Write-ExtractLog ("Validating input URL: {0}" -f $Url)
    Set-ExtractProgress -Status "Validating input URL" -PercentComplete 5
    $null = [System.Uri]::new($Url)
}
catch {
    Complete-ExtractProgress
    Exit-WithError "Url must be a valid absolute URL"
}

try {
    Write-ExtractLog "Checking Python runtime"
    Set-ExtractProgress -Status "Checking Python runtime" -PercentComplete 10
    $pythonPath = Get-RequiredCommand -Name "python"
}
catch {
    Complete-ExtractProgress
    Exit-WithError $_.Exception.Message
}

try {
    Write-ExtractLog "Checking Playwright module"
    Set-ExtractProgress -Status "Checking Playwright module" -PercentComplete 15
    $playwrightCheck = & $pythonPath -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('playwright') else 1)"
    if ($LASTEXITCODE -ne 0) {
        throw "playwright module not installed. Install it with: python -m pip install playwright"
    }
}
catch {
    Exit-WithError $_.Exception.Message
}

Write-ExtractLog "Searching for an installed browser runtime"
Set-ExtractProgress -Status "Searching for browser runtime" -PercentComplete 20
$browserPath = Get-SystemBrowserPath
if ([string]::IsNullOrWhiteSpace($browserPath)) {
    Complete-ExtractProgress
    Exit-WithError "browser runtime not available. Install Google Chrome or Microsoft Edge"
}
Write-ExtractLog ("Using browser: {0}" -f $browserPath)

$pythonScript = @'
import sys
from urllib.parse import urlparse, parse_qsl

from playwright.sync_api import sync_playwright


PAGE_URL = sys.argv[1]
BROWSER_PATH = sys.argv[2]


def emit_status(message: str) -> None:
    print(message, flush=True)


def emit_error(message: str, code: int = 1) -> None:
    print(message, flush=True)
    raise SystemExit(code)


def canonicalize_url(url: str) -> str:
    parsed = urlparse(url)
    query_pairs = parse_qsl(parsed.query, keep_blank_values=True)
    query = "&".join(f"{k}={v}" for k, v in sorted(query_pairs))
    return parsed._replace(query=query, fragment="").geturl()


def looks_like_hls(url: str, content_type: str) -> bool:
    low_url = url.lower()
    low_type = (content_type or "").lower()
    return ".m3u8" in low_url or "mpegurl" in low_type or "application/x-mpegurl" in low_type


def classify_manifest(body: str, url: str) -> tuple[str, int]:
    text = (body or "").strip()
    upper = text.upper()
    if "#EXT-X-STREAM-INF" in upper:
        return "master", upper.count("#EXT-X-STREAM-INF")

    low_url = url.lower()
    if any(marker in low_url for marker in ["guids=", "scheme=https", "playlist.m3u8", "master.m3u8"]):
        return "master", 1

    if "#EXTINF" in upper or "#EXT-X-TARGETDURATION" in upper:
        return "variant", 0

    return "unknown", 0


def manifest_quality_penalty(url: str) -> int:
    low = url.lower()
    penalties = [
        "144", "160", "180", "232", "240", "256", "270",
        "360", "426", "432", "480", "540", "640", "720"
    ]
    return sum(1 for marker in penalties if marker in low)


with sync_playwright() as playwright:
    emit_status("[Extract] Launching browser")
    browser = playwright.chromium.launch(
        executable_path=BROWSER_PATH,
        headless=True,
        args=["--autoplay-policy=no-user-gesture-required"],
    )
    context = browser.new_context(viewport={"width": 1600, "height": 900})
    page = context.new_page()
    candidates = []
    candidate_by_key = {}

    def remember_response(response) -> None:
        try:
            url = response.url
            content_type = response.headers.get("content-type", "")
            if not looks_like_hls(url, content_type):
                return

            status = response.status
            if status < 200 or status >= 400:
                return

            body = ""
            try:
                body = response.text()
            except Exception:
                body = ""

            manifest_type, variant_count = classify_manifest(body, url)
            frame_url = ""
            try:
                frame_url = response.request.frame.url or ""
            except Exception:
                frame_url = ""

            key = canonicalize_url(url)
            existing = candidate_by_key.get(key)
            if existing is None:
                candidate = {
                    "url": url,
                    "canonical_url": key,
                    "content_type": content_type,
                    "status": status,
                    "frame_url": frame_url,
                    "manifest_type": manifest_type,
                    "variant_count": variant_count,
                    "quality_penalty": manifest_quality_penalty(url),
                }
                candidate_by_key[key] = candidate
                candidates.append(candidate)
                return

            if existing["manifest_type"] != "master" and manifest_type == "master":
                existing["manifest_type"] = "master"
            existing["variant_count"] = max(existing["variant_count"], variant_count)
            if not existing["frame_url"] and frame_url:
                existing["frame_url"] = frame_url
            existing["quality_penalty"] = min(existing["quality_penalty"], manifest_quality_penalty(url))
        except Exception:
            return

    page.on("response", remember_response)

    try:
        emit_status("[Extract] Opening target page")
        page.goto(PAGE_URL, wait_until="domcontentloaded", timeout=90000)
        try:
            emit_status("[Extract] Waiting for network to settle")
            page.wait_for_load_state("networkidle", timeout=15000)
        except Exception:
            pass
        emit_status("[Extract] Observing player traffic")
        page.wait_for_timeout(8000)
    except Exception as exc:
        browser.close()
        emit_error(f"page load failed: {exc}")

    try:
        emit_status("[Extract] Inspecting player candidates")
        player_contexts = page.evaluate(
            """
() => {
  const selectors = ['video', 'iframe', '[class*=player]', '[id*=player]'];
  const elements = [];
  const seen = new Set();
  for (const selector of selectors) {
    for (const element of document.querySelectorAll(selector)) {
      if (seen.has(element)) {
        continue;
      }
      seen.add(element);
      const rect = element.getBoundingClientRect();
      const area = Math.max(0, rect.width) * Math.max(0, rect.height);
      if (area <= 0) {
        continue;
      }

      const styles = window.getComputedStyle(element);
      if (styles.visibility === 'hidden' || styles.display === 'none') {
        continue;
      }

      let contextUrl = null;
      if (element.tagName === 'IFRAME') {
        contextUrl = element.src || element.getAttribute('src') || null;
      } else if (element.tagName === 'VIDEO') {
        contextUrl = window.location.href;
      } else {
        contextUrl = window.location.href;
      }

      elements.push({
        tag: element.tagName,
        area,
        width: rect.width,
        height: rect.height,
        context_url: contextUrl,
      });
    }
  }

  elements.sort((left, right) => right.area - left.area);
  return elements.slice(0, 20);
}
"""
        )
    except Exception:
        player_contexts = []

    browser.close()

emit_status(f"[Extract] HLS candidates found: {len(candidates)}")
if not candidates:
    emit_error("no hls playlist found")

master_candidates = [candidate for candidate in candidates if candidate["manifest_type"] == "master"]
variant_candidates = [candidate for candidate in candidates if candidate["manifest_type"] == "variant"]

if not master_candidates:
    if variant_candidates:
        emit_error("only variant playlist found but no master")
    emit_error("no hls playlist found")

dominant_context = None
if player_contexts:
    dominant_context = player_contexts[0].get("context_url")

def candidate_sort_key(candidate: dict) -> tuple:
    context_match = 0
    if dominant_context:
        if candidate.get("frame_url") == dominant_context:
            context_match = 2
        elif dominant_context == PAGE_URL and (candidate.get("frame_url") in ("", PAGE_URL)):
            context_match = 2
        elif candidate.get("frame_url") and dominant_context in candidate["frame_url"]:
            context_match = 1

    master_strength = candidate.get("variant_count", 0)
    return (
        context_match,
        master_strength,
        -candidate.get("quality_penalty", 0),
        -len(candidate.get("url", "")),
        candidate.get("canonical_url", ""),
    )

best = sorted(master_candidates, key=candidate_sort_key, reverse=True)[0]
emit_status("[Extract] Best master playlist selected")
print(best["url"])
'@

$tempPythonFile = Join-Path ([System.IO.Path]::GetTempPath()) ("extract_playlist_{0}.py" -f ([System.Guid]::NewGuid().ToString("N")))
$tempStdOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("extract_playlist_stdout_{0}.log" -f ([System.Guid]::NewGuid().ToString("N")))
$tempStdErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("extract_playlist_stderr_{0}.log" -f ([System.Guid]::NewGuid().ToString("N")))

try {
    Write-ExtractLog "Preparing temporary Python helper"
    Set-ExtractProgress -Status "Preparing helper script" -PercentComplete 30
    [System.IO.File]::WriteAllText($tempPythonFile, $pythonScript, [System.Text.Encoding]::UTF8)

    Write-ExtractLog "Starting browser-based playlist discovery"
    Set-ExtractProgress -Status "Running browser discovery" -PercentComplete 45
    $previousNativeErrorPreference = $null
    $hadNativeErrorPreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    if ($hadNativeErrorPreference) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        & $pythonPath $tempPythonFile $Url $browserPath 1> $tempStdOutFile 2> $tempStdErrFile
    }
    finally {
        if ($hadNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }

    $stdoutLines = @()
    $stderrLines = @()
    if (Test-Path -LiteralPath $tempStdOutFile) {
        $stdoutLines = Get-Content -LiteralPath $tempStdOutFile
    }
    if (Test-Path -LiteralPath $tempStdErrFile) {
        $stderrLines = Get-Content -LiteralPath $tempStdErrFile
    }

    foreach ($line in $stderrLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host $line
        }
    }

    if ($LASTEXITCODE -ne 0) {
        Complete-ExtractProgress
        if ($stderrLines) {
            [Console]::Error.WriteLine(($stderrLines -join [Environment]::NewLine))
        }
        elseif ($stdoutLines) {
            [Console]::Error.WriteLine(($stdoutLines -join [Environment]::NewLine))
        }
        else {
            [Console]::Error.WriteLine("extract-playlist failed")
        }
        exit 1
    }

    $finalOutput = ($stdoutLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)

    if ([string]::IsNullOrWhiteSpace($finalOutput)) {
        Complete-ExtractProgress
        [Console]::Error.WriteLine("no hls playlist found")
        exit 1
    }

    Write-ExtractLog "Playlist discovery completed"
    Set-ExtractProgress -Status "Playlist found" -PercentComplete 100
    Write-Output $finalOutput.Trim()
}
catch {
    Complete-ExtractProgress
    Exit-WithError $_.Exception.Message
}
finally {
    Complete-ExtractProgress
    foreach ($temporaryPath in @($tempPythonFile, $tempStdOutFile, $tempStdErrFile)) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
