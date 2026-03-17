param(
    # Relative or absolute path to the source audio file that should be transcribed.
    # The script currently validates that this file uses the .mp3 extension.
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile,

    # Optional switch: send audio to a diarization-capable model.
    # Useful for meetings/interviews where speaker separation is needed.
    [Parameter(Mandatory = $false)]
    [Alias("Diarization", "SpeakerDiarization", "wd")]
    [switch]$WithDiarization,

    # Backward/CLI compatibility: allow extra trailing args and interpret
    # common diarization flags manually (e.g. when users pass them as plain args).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs
)

# Fail fast on any non-terminating error so that we do not silently continue
# after partial failures (for example, network issues or malformed JSON).
$ErrorActionPreference = "Stop"

function Get-AudioDurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if (-not $ffprobe) {
        throw "ffprobe (part of ffmpeg) is required to validate duration in diarization mode, but it was not found in PATH"
    }

    $probeArgs = @(
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $FilePath
    )

    $durationRaw = & $ffprobe.Source @probeArgs
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($durationRaw)) {
        throw "Failed to detect audio duration via ffprobe"
    }

    $duration = 0.0
    if (-not [double]::TryParse($durationRaw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        throw "ffprobe returned an invalid duration: '$durationRaw'"
    }

    return $duration
}

function Split-AudioIntoChunks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$MaxChunkDuration,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to split long audio in diarization mode, but it was not found in PATH"
    }

    $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $outputPattern = Join-Path $TempDirectory ("{0}_part_%03d.mp3" -f $inputBaseName)

    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-i", $InputPath,
        "-f", "segment",
        "-segment_time", ([string]$MaxChunkDuration),
        "-c", "copy",
        $outputPattern
    )

    & $ffmpeg.Source @ffmpegArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to split audio into chunks via ffmpeg"
    }

    $chunks = Get-ChildItem -LiteralPath $TempDirectory -File | Sort-Object Name
    if (-not $chunks -or $chunks.Count -eq 0) {
        throw "ffmpeg did not produce any audio chunks"
    }

    return $chunks
}

function Invoke-Transcription {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient]$HttpClient,

        [Parameter(Mandatory = $true)]
        [string]$AudioPath,

        [Parameter(Mandatory = $true)]
        [string]$Model,

        [Parameter(Mandatory = $true)]
        [bool]$WithDiarization,

        [Parameter(Mandatory = $false)]
        [string]$ChunkLabel
    )

    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    $fileStream = $null

    try {
        $fileStream = [System.IO.File]::OpenRead($AudioPath)
        $fileName = [System.IO.Path]::GetFileName($AudioPath)

        $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("audio/mpeg")

        $multipart.Add($fileContent, "file", $fileName)
        $multipart.Add([System.Net.Http.StringContent]::new($Model), "model")
        $multipart.Add([System.Net.Http.StringContent]::new("ru"), "language")
        $multipart.Add([System.Net.Http.StringContent]::new("auto"), "chunking_strategy")

        if ($WithDiarization) {
            $multipart.Add([System.Net.Http.StringContent]::new("true"), "diarization")
        }

        $response = $HttpClient.PostAsync("https://api.openai.com/v1/audio/transcriptions", $multipart).GetAwaiter().GetResult()
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $chunkInfo = if ([string]::IsNullOrWhiteSpace($ChunkLabel)) { "" } else { " ($ChunkLabel)" }
            throw "API error${chunkInfo}: HTTP $([int]$response.StatusCode)`n$responseBody"
        }

        $json = $responseBody | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($json.text)) {
            throw "API response does not contain 'text'`n$responseBody"
        }

        return $json.text
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($multipart) { $multipart.Dispose() }
    }
}

try {
    # Tolerate diarization flags passed as free-form arguments.
    # This helps when users copy commands from terminals where line wrapping
    # or shell specifics may alter how a switch is tokenized.
    if (-not $WithDiarization -and $AdditionalArgs) {
        $normalizedArgs = $AdditionalArgs | ForEach-Object { $_.Trim() }
        if ($normalizedArgs -contains "-WithDiarization" -or
            $normalizedArgs -contains "--with-diarization" -or
            $normalizedArgs -contains "-Diarization") {
            $WithDiarization = $true
        }
    }

    # Verify that the user-provided path exists before resolving it.
    # Using -LiteralPath avoids wildcard expansion and treats the string as-is.
    if (-not (Test-Path -LiteralPath $InputFile)) {
        throw "Input file not found: $InputFile"
    }

    # Normalize the path to an absolute path so all follow-up operations
    # (stream opening, output generation) use a consistent file location.
    $fullInputPath = (Resolve-Path -LiteralPath $InputFile).Path
    $extension = [System.IO.Path]::GetExtension($fullInputPath).ToLowerInvariant()

    # Keep validation strict to avoid accidental uploads of unsupported formats.
    # If needed, this block can be extended to support additional audio types.
    if ($extension -ne ".mp3") {
        throw "Expected .mp3 file, got: $extension"
    }

    # Read API credentials from environment variable so we never hardcode secrets
    # in source code, scripts, or command history.
    $apiKey = $env:OPENAI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Environment variable OPENAI_API_KEY is not set"
    }

    # Generate an output text file path in the same directory as the source file.
    # Example: meeting.mp3 -> meeting.txt
    $outputFile = [System.IO.Path]::ChangeExtension($fullInputPath, ".txt")
    # API hard limit for diarization-enabled requests.
    $maxDiarizationDurationSeconds = 1400.0
    # Keep chunk duration slightly below the API limit to avoid boundary/rounding
    # drift (e.g. 1400.004s) when ffmpeg creates segments.
    $safeChunkDurationSeconds = 1390.0

    # Use a default lightweight model, but allow an explicit diarization mode.
    # This keeps default cost/performance behavior unchanged for existing users.
    $model = if ($WithDiarization) { "gpt-4o-transcribe" } else { "gpt-4o-mini-transcribe" }

    # Ensure System.Net.Http types are available in the current PowerShell session.
    Add-Type -AssemblyName System.Net.Http

    # Configure an HTTP client once and attach Bearer authentication for the API.
    # The client is disposed in the finally block to free network resources.
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)

    $tempDir = $null
    try {
        $allTexts = [System.Collections.Generic.List[string]]::new()

        if ($WithDiarization) {
            $duration = Get-AudioDurationSeconds -FilePath $fullInputPath

            if ($duration -gt $maxDiarizationDurationSeconds) {
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
                [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null

                $chunks = Split-AudioIntoChunks -InputPath $fullInputPath -MaxChunkDuration $safeChunkDurationSeconds -TempDirectory $tempDir
                for ($i = 0; $i -lt $chunks.Count; $i++) {
                    $chunk = $chunks[$i]
                    $chunkLabel = "chunk {0}/{1}" -f ($i + 1), $chunks.Count
                    Write-Host "Uploading: $chunkLabel ($($chunk.Name))"
                    $chunkText = Invoke-Transcription -HttpClient $httpClient -AudioPath $chunk.FullName -Model $model -WithDiarization $true -ChunkLabel $chunkLabel
                    $allTexts.Add($chunkText)
                }
            }
            else {
                $singleText = Invoke-Transcription -HttpClient $httpClient -AudioPath $fullInputPath -Model $model -WithDiarization $true
                $allTexts.Add($singleText)
            }
        }
        else {
            $singleText = Invoke-Transcription -HttpClient $httpClient -AudioPath $fullInputPath -Model $model -WithDiarization $false
            $allTexts.Add($singleText)
        }

        $finalText = [string]::Join([Environment]::NewLine + [Environment]::NewLine, $allTexts)
        [System.IO.File]::WriteAllText($outputFile, $finalText, [System.Text.Encoding]::UTF8)
        $modeLabel = if ($WithDiarization) { "diarization mode" } else { "standard mode" }
        Write-Host "Done: $outputFile ($modeLabel, model=$model)"
    }
    finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($httpClient) { $httpClient.Dispose() }
    }
}
catch {
    # Surface only the core exception message for cleaner CLI output.
    Write-Error $_.Exception.Message
    exit 1
}
