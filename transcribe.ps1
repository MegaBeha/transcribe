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

    # Optional switch: keep intermediate upload/compression/chunk files on disk.
    [Parameter(Mandatory = $false)]
    [switch]$Save,

    # Optional switch: print and keep detailed diagnostics for native commands.
    [Parameter(Mandatory = $false)]
    [switch]$DebugNative,

    # Backward/CLI compatibility: allow extra trailing args and interpret
    # common diarization flags manually (e.g. when users pass them as plain args).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs
)

# Fail fast on any non-terminating error so that we do not silently continue
# after partial failures (for example, network issues or malformed JSON).
$ErrorActionPreference = "Stop"
$transcribeProgressId = 7301
$script:DebugNativeEnabled = $false
$script:NativeLogDirectory = $null
$script:NativeCommandCounter = 0
$script:CurrentNativeDebugLogPath = $null
$script:LastNativeDebugLogPath = $null
$script:ApiLogDirectory = $null
$script:ApiCommandCounter = 0
$script:CurrentApiDebugLogPath = $null
$script:LastApiDebugLogPath = $null

function Write-TranscribeLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[Transcribe] {0}" -f $Message)
}

function Write-NativeDebugLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[NativeDebug] {0}" -f $Message
    if ($script:DebugNativeEnabled) {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CurrentNativeDebugLogPath)) {
        try {
            [System.IO.File]::AppendAllText($script:CurrentNativeDebugLogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        }
        catch {
            if ($script:DebugNativeEnabled) {
                Write-Host ("[NativeDebug] Failed to write debug log: {0}" -f $_.Exception.Message)
            }
        }
    }
}

function Write-ApiDebugLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[ApiDebug] {0}" -f $Message
    if ($script:DebugNativeEnabled) {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CurrentApiDebugLogPath)) {
        try {
            [System.IO.File]::AppendAllText($script:CurrentApiDebugLogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        }
        catch {
            if ($script:DebugNativeEnabled) {
                Write-Host ("[ApiDebug] Failed to write API debug log: {0}" -f $_.Exception.Message)
            }
        }
    }
}

function New-ApiDebugLogPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $script:ApiCommandCounter++
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]+', "_"
    if ([string]::IsNullOrWhiteSpace($safeLabel)) {
        $safeLabel = "request"
    }

    $logDirectory = if ($script:ApiLogDirectory -and (Test-Path -LiteralPath $script:ApiLogDirectory)) {
        $script:ApiLogDirectory
    }
    elseif ($script:NativeLogDirectory -and (Test-Path -LiteralPath $script:NativeLogDirectory)) {
        $script:NativeLogDirectory
    }
    else {
        [System.IO.Path]::GetTempPath()
    }

    $debugPath = Join-Path $logDirectory ("api_{0:000}_{1}_{2}.debug.log" -f $script:ApiCommandCounter, $safeLabel, [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
    [System.IO.File]::WriteAllText($debugPath, "", [System.Text.Encoding]::UTF8)
    $script:LastApiDebugLogPath = $debugPath
    return $debugPath
}

function Set-TranscribeProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$PercentComplete
    )

    Write-Progress -Id $transcribeProgressId -Activity "Transcribe audio" -Status $Status -PercentComplete $PercentComplete
}

function Complete-TranscribeProgress {
    Write-Progress -Id $transcribeProgressId -Activity "Transcribe audio" -Completed
}

function New-UniqueDirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        return $DirectoryPath
    }

    $parent = [System.IO.Path]::GetDirectoryName($DirectoryPath)
    $name = [System.IO.Path]::GetFileName($DirectoryPath)
    for ($i = 1; $i -lt 10000; $i++) {
        $candidate = Join-Path $parent ("{0}_{1}" -f $name, $i)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Failed to find a unique intermediate directory path for: $DirectoryPath"
}

function New-TranscribeWorkDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter(Mandatory = $true)]
        [bool]$Save
    )

    if ($Save) {
        $outputDirectory = [System.IO.Path]::GetDirectoryName($OutputFile)
        if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
            $outputDirectory = (Get-Location).Path
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
        $directoryPath = New-UniqueDirectoryPath -DirectoryPath (Join-Path $outputDirectory ("{0}_intermediate" -f $baseName))
        [System.IO.Directory]::CreateDirectory($directoryPath) | Out-Null
        Write-TranscribeLog ("Saving intermediate files in: {0}" -f $directoryPath)
        return $directoryPath
    }

    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
    return $tempDirectory
}

function Invoke-NativeCommandCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $script:NativeCommandCounter++
    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        $commandName = "native"
    }

    $safeCommandName = $commandName -replace '[^A-Za-z0-9_.-]+', "_"
    $logDirectory = if ($script:NativeLogDirectory -and (Test-Path -LiteralPath $script:NativeLogDirectory)) {
        $script:NativeLogDirectory
    }
    else {
        [System.IO.Path]::GetTempPath()
    }

    $tempBase = Join-Path $logDirectory ("native_{0:000}_{1}_{2}" -f $script:NativeCommandCounter, $safeCommandName, [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
    $stdoutPath = "{0}.stdout.log" -f $tempBase
    $stderrPath = "{0}.stderr.log" -f $tempBase
    $debugPath = "{0}.debug.log" -f $tempBase
    $shouldKeepLogs = $script:DebugNativeEnabled -or ($script:NativeLogDirectory -and (Test-Path -LiteralPath $script:NativeLogDirectory))
    if ($shouldKeepLogs) {
        [System.IO.File]::WriteAllText($debugPath, "", [System.Text.Encoding]::UTF8)
        $script:LastNativeDebugLogPath = $debugPath
    }

    $previousDebugLogPath = $script:CurrentNativeDebugLogPath
    $script:CurrentNativeDebugLogPath = if ($shouldKeepLogs) { $debugPath } else { $previousDebugLogPath }
    $previousErrorActionPreference = $ErrorActionPreference
    $previousNativeErrorPreference = $null
    $hadNativeErrorPreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    $nativePreferenceForLog = if ($hadNativeErrorPreference) { [string]$PSNativeCommandUseErrorActionPreference } else { "<not available>" }

    if ($hadNativeErrorPreference) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        Write-NativeDebugLog ("Starting command #{0}: {1}" -f $script:NativeCommandCounter, $FilePath)
        Write-NativeDebugLog ("Arguments: {0}" -f ($Arguments -join " "))
        Write-NativeDebugLog ("stdout log: {0}" -f $stdoutPath)
        Write-NativeDebugLog ("stderr log: {0}" -f $stderrPath)
        Write-NativeDebugLog ("debug log: {0}" -f $debugPath)
        Write-NativeDebugLog ("ErrorActionPreference before native invoke: {0}" -f $previousErrorActionPreference)
        Write-NativeDebugLog ("PSNativeCommandUseErrorActionPreference before native invoke: {0}" -f $nativePreferenceForLog)
        $ErrorActionPreference = "Continue"
        Write-NativeDebugLog ("ErrorActionPreference during native invoke: {0}" -f $ErrorActionPreference)
        if ($hadNativeErrorPreference) {
            Write-NativeDebugLog ("PSNativeCommandUseErrorActionPreference during native invoke: {0}" -f $PSNativeCommandUseErrorActionPreference)
        }

        Write-NativeDebugLog "before native invoke"
        & $FilePath @Arguments 1> $stdoutPath 2> $stderrPath
        Write-NativeDebugLog "after native invoke"
        $exitCode = $LASTEXITCODE
        Write-NativeDebugLog ("Native command returned; LASTEXITCODE={0}" -f $exitCode)
        $stdoutLines = @()
        $stderrLines = @()
        if (Test-Path -LiteralPath $stdoutPath) {
            $stdoutLines = @(Get-Content -LiteralPath $stdoutPath)
        }

        if (Test-Path -LiteralPath $stderrPath) {
            $stderrLines = @(Get-Content -LiteralPath $stderrPath)
        }

        Write-NativeDebugLog ("stdout lines: {0}; stderr lines: {1}" -f $stdoutLines.Count, $stderrLines.Count)
        $previewLines = @($stderrLines | Select-Object -First 50)
        for ($i = 0; $i -lt $previewLines.Count; $i++) {
            Write-NativeDebugLog ("stderr[{0}]: {1}" -f $i, $previewLines[$i])
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOutLines = $stdoutLines
            StdErrLines = $stderrLines
            StdOutPath = $stdoutPath
            StdErrPath = $stderrPath
            DebugPath = $debugPath
        }
    }
    catch {
        Write-NativeDebugLog ("Native command threw PowerShell exception: {0}" -f $_.Exception.GetType().FullName)
        Write-NativeDebugLog ("Exception message: {0}" -f $_.Exception.Message)
        Write-NativeDebugLog ("FullyQualifiedErrorId: {0}" -f $_.FullyQualifiedErrorId)
        throw
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Write-NativeDebugLog ("Restored ErrorActionPreference: {0}" -f $ErrorActionPreference)
        if ($hadNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
            Write-NativeDebugLog ("Restored PSNativeCommandUseErrorActionPreference: {0}" -f $PSNativeCommandUseErrorActionPreference)
        }
        else {
            Write-NativeDebugLog "PSNativeCommandUseErrorActionPreference was not available"
        }

        if ($shouldKeepLogs) {
            Write-NativeDebugLog ("Keeping native logs: {0}; {1}; {2}" -f $stdoutPath, $stderrPath, $debugPath)
        }
        else {
            foreach ($path in @($stdoutPath, $stderrPath, $debugPath)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $script:CurrentNativeDebugLogPath = $previousDebugLogPath
    }
}

function Get-NativeCommandErrorText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $details = @()
    if ($Result.StdErrLines) {
        $details += $Result.StdErrLines
    }

    if ($Result.StdOutLines) {
        $details += $Result.StdOutLines
    }

    $text = ($details | ForEach-Object { $_.ToString() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "exit code $($Result.ExitCode)"
    }

    return $text
}

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

    $probeResult = Invoke-NativeCommandCapture -FilePath $ffprobe.Source -Arguments $probeArgs
    $durationRaw = ($probeResult.StdOutLines -join [Environment]::NewLine)
    if ($probeResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($durationRaw)) {
        throw ("Failed to detect audio duration via ffprobe:`n{0}" -f (Get-NativeCommandErrorText -Result $probeResult))
    }

    $duration = 0.0
    if (-not [double]::TryParse($durationRaw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        throw "ffprobe returned an invalid duration: '$durationRaw'"
    }

    return $duration
}

function Get-AudioBitrateKbps {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if (-not $ffprobe) {
        throw "ffprobe (part of ffmpeg) is required to detect audio bitrate, but it was not found in PATH"
    }

    $probeArgs = @(
        "-v", "error",
        "-show_entries", "format=bit_rate",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $FilePath
    )

    $probeResult = Invoke-NativeCommandCapture -FilePath $ffprobe.Source -Arguments $probeArgs
    $bitrateRaw = ($probeResult.StdOutLines -join [Environment]::NewLine).Trim()
    if ($probeResult.ExitCode -ne 0) {
        throw ("Failed to detect audio bitrate via ffprobe:`n{0}" -f (Get-NativeCommandErrorText -Result $probeResult))
    }

    if ([string]::IsNullOrWhiteSpace($bitrateRaw) -or $bitrateRaw -eq "N/A") {
        return $null
    }

    $bitrateBitsPerSecond = 0.0
    if (-not [double]::TryParse($bitrateRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$bitrateBitsPerSecond)) {
        return $null
    }

    if ($bitrateBitsPerSecond -le 0) {
        return $null
    }

    return [int][math]::Floor($bitrateBitsPerSecond / 1000.0)
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

    $splitResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
    if ($splitResult.ExitCode -ne 0) {
        throw ("Failed to split audio into chunks via ffmpeg:`n{0}" -f (Get-NativeCommandErrorText -Result $splitResult))
    }

    $chunks = Get-ChildItem -LiteralPath $TempDirectory -File | Sort-Object Name
    if (-not $chunks -or $chunks.Count -eq 0) {
        throw "ffmpeg did not produce any audio chunks"
    }

    return $chunks
}

function Format-DurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Seconds
    )

    $ts = [System.TimeSpan]::FromSeconds($Seconds)
    return $ts.ToString("hh\:mm\:ss")
}

function Get-AllowedMp3BitrateKbps {
    return @(320, 256, 224, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32, 24, 16, 8)
}

function Get-NearestAllowedBitrateAtOrBelow {
    param(
        [Parameter(Mandatory = $true)]
        [int]$BitrateKbps,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps
    )

    $allowed = Get-AllowedMp3BitrateKbps | Where-Object { $_ -ge $MinimumKbps } | Sort-Object -Descending
    foreach ($value in $allowed) {
        if ($value -le $BitrateKbps) {
            return $value
        }
    }

    return ($allowed | Measure-Object -Minimum).Minimum
}

function Get-NextLowerAllowedBitrate {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentKbps,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps
    )

    $allowed = Get-AllowedMp3BitrateKbps | Where-Object { $_ -ge $MinimumKbps } | Sort-Object -Descending
    for ($i = 0; $i -lt $allowed.Count; $i++) {
        if ($allowed[$i] -eq $CurrentKbps) {
            if ($i -eq ($allowed.Count - 1)) {
                return $allowed[$i]
            }

            return $allowed[$i + 1]
        }
    }

    return ($allowed | Measure-Object -Minimum).Minimum
}

function Get-InitialBitrateKbps {
    param(
        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [long]$TargetBytes,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps
    )

    $reserveBytes = [math]::Max(32768, [math]::Floor($TargetBytes * 0.02))
    $usableBytes = [math]::Max(1, $TargetBytes - $reserveBytes)
    $rawBitrate = [math]::Floor((($usableBytes * 8.0) / $DurationSeconds) / 1000.0)
    $clamped = [math]::Min(320, [math]::Max($MinimumKbps, [int]$rawBitrate))
    return Get-NearestAllowedBitrateAtOrBelow -BitrateKbps $clamped -MinimumKbps $MinimumKbps
}

function Get-UploadBitrateKbps {
    param(
        [Parameter(Mandatory = $true)]
        [int]$SizeLimitBitrateKbps,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps,

        [Parameter(Mandatory = $false)]
        [Nullable[int]]$SourceBitrateKbps
    )

    $sizeLimitBitrate = Get-NearestAllowedBitrateAtOrBelow -BitrateKbps $SizeLimitBitrateKbps -MinimumKbps $MinimumKbps
    if ($null -eq $SourceBitrateKbps) {
        Write-TranscribeLog ("WARNING: Source audio bitrate is unknown; using size-limit bitrate {0} kbps" -f $sizeLimitBitrate)
        return $sizeLimitBitrate
    }

    $sourceCeilingKbps = Get-NearestAllowedBitrateAtOrBelow -BitrateKbps ([math]::Max($MinimumKbps, [int]$SourceBitrateKbps)) -MinimumKbps $MinimumKbps
    $selected = [math]::Min($sizeLimitBitrate, $sourceCeilingKbps)
    return Get-NearestAllowedBitrateAtOrBelow -BitrateKbps ([int]$selected) -MinimumKbps $MinimumKbps
}

function Invoke-Mp3EncodeFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [int]$BitrateKbps
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to prepare audio uploads, but it was not found in PATH"
    }

    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", $InputPath,
        "-vn",
        "-ac", "1",
        "-c:a", "libmp3lame",
        "-b:a", ("{0}k" -f $BitrateKbps),
        "-write_xing", "0",
        $OutputPath
    )

    $encodeResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
    if ($encodeResult.ExitCode -ne 0) {
        throw ("ffmpeg failed to prepare MP3 upload audio:`n{0}" -f (Get-NativeCommandErrorText -Result $encodeResult))
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "ffmpeg finished without creating the MP3 upload file"
    }

    $item = Get-Item -LiteralPath $OutputPath
    if ($item.Length -le 0) {
        throw "Prepared MP3 upload file is empty"
    }
}

function Split-AndEncodeMp3IntoUploadChunks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [long]$TargetBytes,

        [Parameter(Mandatory = $true)]
        [int]$BitrateKbps,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to split audio uploads, but it was not found in PATH"
    }

    $chunkDuration = [math]::Floor((($TargetBytes * 8.0) / ($BitrateKbps * 1000.0)) * 0.90)
    $chunkDuration = [math]::Max(30, [math]::Min($DurationSeconds, $chunkDuration))
    $outputPattern = Join-Path $TempDirectory "diarize_upload_part_%03d.mp3"

    Write-TranscribeLog ("Splitting audio into upload chunks at {0} kbps with max duration {1:N0} sec" -f $BitrateKbps, $chunkDuration)
    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", $InputPath,
        "-vn",
        "-ac", "1",
        "-c:a", "libmp3lame",
        "-b:a", ("{0}k" -f $BitrateKbps),
        "-write_xing", "0",
        "-f", "segment",
        "-segment_time", ([string][int]$chunkDuration),
        "-reset_timestamps", "1",
        $outputPattern
    )

    $splitResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
    if ($splitResult.ExitCode -ne 0) {
        throw ("ffmpeg failed to split MP3 upload chunks:`n{0}" -f (Get-NativeCommandErrorText -Result $splitResult))
    }

    $chunks = @(Get-ChildItem -LiteralPath $TempDirectory -Filter "diarize_upload_part_*.mp3" -File | Sort-Object Name)
    if (-not $chunks -or $chunks.Count -eq 0) {
        throw "ffmpeg did not produce any MP3 upload chunks"
    }

    foreach ($chunk in $chunks) {
        if ($chunk.Length -le 0) {
            throw "Prepared MP3 upload chunk is empty: $($chunk.FullName)"
        }

        if ($chunk.Length -gt $TargetBytes) {
            throw "Prepared MP3 upload chunk exceeds the target upload size: $($chunk.FullName)"
        }
    }

    return $chunks.FullName
}

function Get-SilenceIntervals {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to detect silence, but it was not found in PATH"
    }

    $ffmpegArgs = @(
        "-hide_banner",
        "-nostats",
        "-i", $InputPath,
        "-af", "silencedetect=noise=-35dB:d=0.35",
        "-f", "null",
        "-"
    )

    Write-TranscribeLog "Starting silencedetect"
    $silenceResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
    Write-TranscribeLog "Silencedetect native command completed"
    if ($silenceResult.ExitCode -ne 0) {
        throw ("ffmpeg failed to detect silence:`n{0}" -f (Get-NativeCommandErrorText -Result $silenceResult))
    }

    $intervals = [System.Collections.Generic.List[object]]::new()
    $currentStart = $null
    foreach ($line in $silenceResult.StdErrLines) {
        $text = [string]$line
        $startMatch = [regex]::Match($text, "silence_start:\s*(?<start>[0-9.]+)")
        if ($startMatch.Success) {
            $currentStart = [double]::Parse($startMatch.Groups["start"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            continue
        }

        $endMatch = [regex]::Match($text, "silence_end:\s*(?<end>[0-9.]+)\s*\|\s*silence_duration:\s*(?<duration>[0-9.]+)")
        if ($endMatch.Success -and $null -ne $currentStart) {
            $end = [double]::Parse($endMatch.Groups["end"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $silenceDuration = [double]::Parse($endMatch.Groups["duration"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($end -gt $currentStart -and $silenceDuration -gt 0) {
                $intervals.Add([pscustomobject]@{
                    Start = $currentStart
                    End = $end
                    Duration = $silenceDuration
                    Mid = ($currentStart + $end) / 2.0
                })
            }

            $currentStart = $null
        }
    }

    if ($null -ne $currentStart -and $DurationSeconds -gt $currentStart) {
        $intervals.Add([pscustomobject]@{
            Start = $currentStart
            End = $DurationSeconds
            Duration = $DurationSeconds - $currentStart
            Mid = ($currentStart + $DurationSeconds) / 2.0
        })
    }

    Write-TranscribeLog ("Silence intervals detected: {0}" -f $intervals.Count)
    return $intervals.ToArray()
}

function Select-DiarizationCutPoints {
    param(
        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [double]$SafeChunkDurationSeconds,

        [Parameter(Mandatory = $false)]
        [object[]]$SilenceIntervals = @()
    )

    if ($DurationSeconds -le $SafeChunkDurationSeconds) {
        return @()
    }

    $partCount = [int][math]::Ceiling($DurationSeconds / $SafeChunkDurationSeconds)
    $idealChunkDuration = $DurationSeconds / [double]$partCount
    $cuts = [System.Collections.Generic.List[double]]::new()
    $previousCut = 0.0

    for ($cutIndex = 1; $cutIndex -lt $partCount; $cutIndex++) {
        $idealCut = $idealChunkDuration * $cutIndex
        $remainingParts = $partCount - $cutIndex
        $earliestFeasible = [math]::Max($previousCut + 1.0, $DurationSeconds - ($SafeChunkDurationSeconds * $remainingParts))
        $latestFeasible = [math]::Min($previousCut + $SafeChunkDurationSeconds, $DurationSeconds - 1.0)

        if ($earliestFeasible -gt $latestFeasible) {
            throw "Failed to find a feasible diarization cut range near $idealCut seconds"
        }

        $bestCut = $null
        $bestScore = [double]::PositiveInfinity
        foreach ($silence in $SilenceIntervals) {
            $cut = [double]$silence.Mid
            if ($cut -lt $earliestFeasible -or $cut -gt $latestFeasible) {
                continue
            }

            $currentLength = $cut - $previousCut
            $targetLength = $idealChunkDuration
            $distancePenalty = [math]::Abs($cut - $idealCut)
            $imbalancePenalty = [math]::Abs($currentLength - $targetLength) * 0.25
            $silenceBonus = [math]::Min([double]$silence.Duration, 3.0) * 2.0
            $score = $distancePenalty + $imbalancePenalty - $silenceBonus

            if ($score -lt $bestScore) {
                $bestScore = $score
                $bestCut = $cut
            }
        }

        if ($null -eq $bestCut) {
            $fallback = [math]::Max($earliestFeasible, [math]::Min($idealCut, $latestFeasible))
            Write-TranscribeLog ("WARNING: No suitable silence found near {0:N1} sec; using time cut at {1:N1} sec" -f $idealCut, $fallback)
            $bestCut = $fallback
        }
        else {
            Write-TranscribeLog ("Selected silence cut near {0:N1} sec: {1:N1} sec" -f $idealCut, $bestCut)
        }

        $cuts.Add([double]$bestCut)
        $previousCut = [double]$bestCut
    }

    return $cuts.ToArray()
}

function New-DiarizationChunkSpecs {
    param(
        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $false)]
        [double[]]$CutPoints = @()
    )

    $boundaries = @()
    $boundaries += 0.0
    $boundaries += ($CutPoints | Sort-Object)
    $boundaries += $DurationSeconds

    $chunks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt ($boundaries.Count - 1); $i++) {
        $start = [double]$boundaries[$i]
        $end = [double]$boundaries[$i + 1]
        if ($end -le $start) {
            continue
        }

        $chunks.Add([pscustomobject]@{
            Index = $i + 1
            Start = $start
            End = $end
            Duration = $end - $start
        })
    }

    return $chunks.ToArray()
}

function Get-BitrateForChunkSet {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ChunkSpecs,

        [Parameter(Mandatory = $true)]
        [long]$TargetBytes,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps,

        [Parameter(Mandatory = $false)]
        [Nullable[int]]$SourceBitrateKbps
    )

    $maxDuration = ($ChunkSpecs | Measure-Object -Property Duration -Maximum).Maximum
    if ($maxDuration -le 0) {
        throw "Diarization chunk duration must be greater than zero"
    }

    $sizeLimitBitrateKbps = Get-InitialBitrateKbps -DurationSeconds $maxDuration -TargetBytes $TargetBytes -MinimumKbps $MinimumKbps
    $selectedBitrateKbps = Get-UploadBitrateKbps -SizeLimitBitrateKbps $sizeLimitBitrateKbps -MinimumKbps $MinimumKbps -SourceBitrateKbps $SourceBitrateKbps
    $sourceLabel = if ($null -eq $SourceBitrateKbps) { "unknown" } else { "{0} kbps" -f $SourceBitrateKbps }
    Write-TranscribeLog ("Diarization bitrate selection: source={0}; size-limit={1} kbps; selected={2} kbps" -f $sourceLabel, $sizeLimitBitrateKbps, $selectedBitrateKbps)
    return $selectedBitrateKbps
}

function Export-DiarizationChunks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [object[]]$ChunkSpecs,

        [Parameter(Mandatory = $true)]
        [int]$BitrateKbps,

        [Parameter(Mandatory = $true)]
        [long]$TargetBytes,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to export diarization chunks, but it was not found in PATH"
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in $ChunkSpecs) {
        $outputPath = Join-Path $TempDirectory ("diarize_chunk_{0:000}.mp3" -f [int]$chunk.Index)
        $ffmpegArgs = @(
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F3}", [double]$chunk.Start)),
            "-t", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F3}", [double]$chunk.Duration)),
            "-i", $InputPath,
            "-vn",
            "-ac", "1",
            "-c:a", "libmp3lame",
            "-b:a", ("{0}k" -f $BitrateKbps),
            "-write_xing", "0",
            $outputPath
        )

        $exportResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
        if ($exportResult.ExitCode -ne 0) {
            throw ("ffmpeg failed to export diarization chunk #{0}:`n{1}" -f $chunk.Index, (Get-NativeCommandErrorText -Result $exportResult))
        }

        $item = Get-Item -LiteralPath $outputPath
        if ($item.Length -le 0) {
            throw "Diarization chunk is empty: $outputPath"
        }

        if ($item.Length -gt $TargetBytes) {
            throw "Diarization chunk exceeds target upload size: $outputPath"
        }

        $paths.Add($outputPath)
    }

    return $paths.ToArray()
}

function Get-TranscriptionUploadAudioPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [long]$TargetBytes,

        [Parameter(Mandatory = $true)]
        [int]$MinimumKbps,

        [Parameter(Mandatory = $false)]
        [Nullable[int]]$SourceBitrateKbps,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $inputItem = Get-Item -LiteralPath $InputPath
    if ($inputItem.Length -le $TargetBytes) {
        Write-TranscribeLog ("Upload audio fits the target size without recompression: {0} bytes" -f $inputItem.Length)
        return @($InputPath)
    }

    $sizeLimitBitrateKbps = Get-InitialBitrateKbps -DurationSeconds $DurationSeconds -TargetBytes $TargetBytes -MinimumKbps $MinimumKbps
    $currentBitrateKbps = Get-UploadBitrateKbps -SizeLimitBitrateKbps $sizeLimitBitrateKbps -MinimumKbps $MinimumKbps -SourceBitrateKbps $SourceBitrateKbps
    $sourceLabel = if ($null -eq $SourceBitrateKbps) { "unknown" } else { "{0} kbps" -f $SourceBitrateKbps }
    Write-TranscribeLog ("Upload bitrate selection: source={0}; size-limit={1} kbps; selected={2} kbps" -f $sourceLabel, $sizeLimitBitrateKbps, $currentBitrateKbps)
    $attempt = 1
    while ($true) {
        $attemptPath = Join-Path $TempDirectory ("upload_attempt_{0:000}_{1}k.mp3" -f $attempt, $currentBitrateKbps)
        Write-TranscribeLog ("Compressing upload audio attempt #{0}: {1} kbps" -f $attempt, $currentBitrateKbps)
        Invoke-Mp3EncodeFromFile -InputPath $InputPath -OutputPath $attemptPath -BitrateKbps $currentBitrateKbps

        $attemptSize = (Get-Item -LiteralPath $attemptPath).Length
        Write-TranscribeLog ("Compressed upload size: {0} bytes" -f $attemptSize)
        if ($attemptSize -le $TargetBytes) {
            return @($attemptPath)
        }

        if ($currentBitrateKbps -le $MinimumKbps) {
            Write-TranscribeLog ("Minimum bitrate reached at {0} kbps; falling back to independent upload chunks. Speaker numbering may differ between chunks." -f $MinimumKbps)
            return @(Split-AndEncodeMp3IntoUploadChunks -InputPath $InputPath -DurationSeconds $DurationSeconds -TargetBytes $TargetBytes -BitrateKbps $MinimumKbps -TempDirectory $TempDirectory)
        }

        $currentBitrateKbps = Get-NextLowerAllowedBitrate -CurrentKbps $currentBitrateKbps -MinimumKbps $MinimumKbps
        $attempt++
        if ($attempt -gt 25) {
            throw "Exceeded the maximum number of upload compression attempts"
        }
    }
}

function Format-DiarizedTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    if (-not $Response.segments) {
        if (-not [string]::IsNullOrWhiteSpace($Response.text)) {
            return $Response.text
        }

        throw "Diarized API response does not contain segments"
    }

    $speakerMap = @{}
    $speakerIndex = 0
    $lines = [System.Collections.Generic.List[string]]::new()
    $currentSpeaker = $null
    $currentParts = [System.Collections.Generic.List[string]]::new()

    foreach ($segment in $Response.segments) {
        $rawSpeaker = [string]$segment.speaker
        if ([string]::IsNullOrWhiteSpace($rawSpeaker)) {
            $rawSpeaker = "speaker_unknown"
        }

        if (-not $speakerMap.ContainsKey($rawSpeaker)) {
            $speakerIndex++
            $speakerMap[$rawSpeaker] = "Спикер{0}" -f $speakerIndex
        }

        $speaker = $speakerMap[$rawSpeaker]
        $text = ([string]$segment.text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($currentSpeaker -and $speaker -ne $currentSpeaker) {
            $lines.Add(("{0}: {1}" -f $currentSpeaker, (($currentParts.ToArray()) -join " ")))
            $currentParts.Clear()
        }

        $currentSpeaker = $speaker
        $currentParts.Add($text)
    }

    if ($currentSpeaker -and $currentParts.Count -gt 0) {
        $lines.Add(("{0}: {1}" -f $currentSpeaker, (($currentParts.ToArray()) -join " ")))
    }

    if ($lines.Count -eq 0) {
        throw "Diarized API response contains no printable segments"
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-DataUrlForAudioFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return "data:audio/mpeg;base64,{0}" -f [System.Convert]::ToBase64String($bytes)
}

function Get-ReferenceNameForDisplaySpeaker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplaySpeaker
    )

    $match = [regex]::Match($DisplaySpeaker, "\d+")
    if ($match.Success) {
        return "known_speaker_{0}" -f $match.Value
    }

    return ($DisplaySpeaker -replace '[^A-Za-z0-9_]+', '_').Trim('_').ToLowerInvariant()
}

function Convert-DiarizedResponseToText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [hashtable]$SpeakerMap,

        [Parameter(Mandatory = $true)]
        [ref]$NextSpeakerIndex
    )

    if (-not $Response.segments) {
        if (-not [string]::IsNullOrWhiteSpace($Response.text)) {
            return $Response.text
        }

        throw "Diarized API response does not contain segments"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $currentSpeaker = $null
    $currentParts = [System.Collections.Generic.List[string]]::new()

    foreach ($segment in $Response.segments) {
        $rawSpeaker = [string]$segment.speaker
        if ([string]::IsNullOrWhiteSpace($rawSpeaker)) {
            $rawSpeaker = "speaker_unknown"
        }

        if (-not $SpeakerMap.ContainsKey($rawSpeaker)) {
            $NextSpeakerIndex.Value = [int]$NextSpeakerIndex.Value + 1
            $SpeakerMap[$rawSpeaker] = "Спикер{0}" -f $NextSpeakerIndex.Value
        }

        $speaker = $SpeakerMap[$rawSpeaker]
        $text = ([string]$segment.text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($currentSpeaker -and $speaker -ne $currentSpeaker) {
            $lines.Add(("{0}: {1}" -f $currentSpeaker, (($currentParts.ToArray()) -join " ")))
            $currentParts.Clear()
        }

        $currentSpeaker = $speaker
        $currentParts.Add($text)
    }

    if ($currentSpeaker -and $currentParts.Count -gt 0) {
        $lines.Add(("{0}: {1}" -f $currentSpeaker, (($currentParts.ToArray()) -join " ")))
    }

    if ($lines.Count -eq 0) {
        throw "Diarized API response contains no printable segments"
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Select-ReferenceSegmentForSpeaker {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$RawSpeaker
    )

    $best = $null
    $bestScore = [double]::PositiveInfinity
    foreach ($segment in $Response.segments) {
        if ([string]$segment.speaker -ne $RawSpeaker) {
            continue
        }

        $start = [double]$segment.start
        $end = [double]$segment.end
        $duration = $end - $start
        if ($duration -lt 2.0) {
            continue
        }

        $clipDuration = [math]::Min(10.0, $duration)
        $score = [math]::Abs(10.0 - $clipDuration)
        if ($score -lt $bestScore) {
            $bestScore = $score
            $best = [pscustomobject]@{
                Start = $start
                Duration = $clipDuration
            }
        }
    }

    return $best
}

function Export-SpeakerReferenceClip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChunkAudioPath,

        [Parameter(Mandatory = $true)]
        [double]$Start,

        [Parameter(Mandatory = $true)]
        [double]$Duration,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        throw "ffmpeg is required to export speaker reference clips, but it was not found in PATH"
    }

    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-ss", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $Start)),
        "-t", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $Duration)),
        "-i", $ChunkAudioPath,
        "-vn",
        "-ac", "1",
        "-c:a", "libmp3lame",
        "-b:a", "64k",
        "-write_xing", "0",
        $OutputPath
    )

    $referenceResult = Invoke-NativeCommandCapture -FilePath $ffmpeg.Source -Arguments $ffmpegArgs
    if ($referenceResult.ExitCode -ne 0) {
        throw ("ffmpeg failed to export speaker reference clip:`n{0}" -f (Get-NativeCommandErrorText -Result $referenceResult))
    }

    $item = Get-Item -LiteralPath $OutputPath
    if ($item.Length -le 0) {
        throw "Speaker reference clip is empty: $OutputPath"
    }
}

function Update-SpeakerReferences {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$ChunkAudioPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$SpeakerMap,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$SpeakerReferences,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    foreach ($segment in $Response.segments) {
        if ($SpeakerReferences.Count -ge 4) {
            return
        }

        $rawSpeaker = [string]$segment.speaker
        if ([string]::IsNullOrWhiteSpace($rawSpeaker) -or -not $SpeakerMap.ContainsKey($rawSpeaker)) {
            continue
        }

        $displaySpeaker = [string]$SpeakerMap[$rawSpeaker]
        $alreadyKnown = $false
        foreach ($reference in $SpeakerReferences) {
            if ($reference.DisplaySpeaker -eq $displaySpeaker) {
                $alreadyKnown = $true
                break
            }
        }

        if ($alreadyKnown) {
            continue
        }

        $referenceSegment = Select-ReferenceSegmentForSpeaker -Response $Response -RawSpeaker $rawSpeaker
        if (-not $referenceSegment) {
            Write-TranscribeLog ("Skipping reference for {0}: no 2-10 sec segment found" -f $displaySpeaker)
            continue
        }

        $referenceName = Get-ReferenceNameForDisplaySpeaker -DisplaySpeaker $displaySpeaker
        $referencePath = Join-Path $TempDirectory ("reference_{0}.mp3" -f $referenceName)
        Export-SpeakerReferenceClip -ChunkAudioPath $ChunkAudioPath -Start $referenceSegment.Start -Duration $referenceSegment.Duration -OutputPath $referencePath
        $dataUrl = Get-DataUrlForAudioFile -Path $referencePath
        $SpeakerReferences.Add([pscustomobject]@{
            Name = $referenceName
            DisplaySpeaker = $displaySpeaker
            Path = $referencePath
            DataUrl = $dataUrl
        })
        $SpeakerMap[$referenceName] = $displaySpeaker
        Write-TranscribeLog ("Created speaker reference: {0} -> {1}" -f $referenceName, $displaySpeaker)
    }
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
        [string]$ChunkLabel,

        [Parameter(Mandatory = $false)]
        [object[]]$SpeakerReferences = @()
    )

    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    $fileStream = $null
    $previousApiDebugLogPath = $script:CurrentApiDebugLogPath
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $responseBody = $null

    try {
        $labelForLog = if ([string]::IsNullOrWhiteSpace($ChunkLabel)) {
            [System.IO.Path]::GetFileName($AudioPath)
        }
        else {
            $ChunkLabel
        }

        $shouldCreateApiLog = $script:DebugNativeEnabled -or ($script:ApiLogDirectory -and (Test-Path -LiteralPath $script:ApiLogDirectory))
        if ($shouldCreateApiLog) {
            $script:CurrentApiDebugLogPath = New-ApiDebugLogPath -Label $labelForLog
        }

        Write-TranscribeLog ("Starting upload: {0}" -f $labelForLog)
        $fileStream = [System.IO.File]::OpenRead($AudioPath)
        $fileName = [System.IO.Path]::GetFileName($AudioPath)
        $audioItem = Get-Item -LiteralPath $AudioPath

        Write-ApiDebugLog ("Starting API request: {0}" -f $labelForLog)
        Write-ApiDebugLog ("Audio path: {0}" -f $AudioPath)
        Write-ApiDebugLog ("Audio size bytes: {0}" -f $audioItem.Length)
        Write-ApiDebugLog ("Model: {0}" -f $Model)
        Write-ApiDebugLog ("With diarization: {0}" -f $WithDiarization)
        Write-ApiDebugLog ("HttpClient timeout: {0}" -f $HttpClient.Timeout)
        Write-ApiDebugLog ("Speaker reference count: {0}" -f $SpeakerReferences.Count)
        if ($SpeakerReferences.Count -gt 0) {
            Write-ApiDebugLog ("Speaker reference names: {0}" -f (($SpeakerReferences | ForEach-Object { [string]$_.Name }) -join ", "))
            Write-ApiDebugLog ("Speaker reference files: {0}" -f (($SpeakerReferences | ForEach-Object { [System.IO.Path]::GetFileName([string]$_.Path) }) -join ", "))
        }
        Write-ApiDebugLog ("Started at UTC: {0:o}" -f [DateTime]::UtcNow)

        $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("audio/mpeg")

        $multipart.Add($fileContent, "file", $fileName)
        $multipart.Add([System.Net.Http.StringContent]::new($Model), "model")
        $multipart.Add([System.Net.Http.StringContent]::new("ru"), "language")
        $multipart.Add([System.Net.Http.StringContent]::new("auto"), "chunking_strategy")

        if ($WithDiarization) {
            $multipart.Add([System.Net.Http.StringContent]::new("diarized_json"), "response_format")
            foreach ($reference in $SpeakerReferences) {
                $multipart.Add([System.Net.Http.StringContent]::new([string]$reference.Name), "known_speaker_names[]")
                $multipart.Add([System.Net.Http.StringContent]::new([string]$reference.DataUrl), "known_speaker_references[]")
            }
        }

        Write-TranscribeLog ("Waiting for API response: {0}" -f $labelForLog)
        try {
            $response = $HttpClient.PostAsync("https://api.openai.com/v1/audio/transcriptions", $multipart).GetAwaiter().GetResult()
            Write-ApiDebugLog ("HTTP response received after {0:N3} sec" -f $stopwatch.Elapsed.TotalSeconds)
            Write-ApiDebugLog ("HTTP status: {0} ({1})" -f ([int]$response.StatusCode), $response.StatusCode)
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Write-ApiDebugLog ("Response body length: {0}" -f $responseBody.Length)
        }
        catch {
            Write-ApiDebugLog ("API request exception after {0:N3} sec" -f $stopwatch.Elapsed.TotalSeconds)
            Write-ApiDebugLog ("Exception type: {0}" -f $_.Exception.GetType().FullName)
            Write-ApiDebugLog ("Exception message: {0}" -f $_.Exception.Message)
            Write-ApiDebugLog ("FullyQualifiedErrorId: {0}" -f $_.FullyQualifiedErrorId)
            if ($_.Exception.InnerException) {
                Write-ApiDebugLog ("Inner exception type: {0}" -f $_.Exception.InnerException.GetType().FullName)
                Write-ApiDebugLog ("Inner exception message: {0}" -f $_.Exception.InnerException.Message)
                if ($_.Exception.InnerException -is [System.Threading.Tasks.TaskCanceledException]) {
                    Write-ApiDebugLog "The API HTTP task was canceled or timed out by the current HttpClient settings."
                }
            }
            elseif ($_.Exception -is [System.Threading.Tasks.TaskCanceledException]) {
                Write-ApiDebugLog "The API HTTP task was canceled or timed out by the current HttpClient settings."
            }

            if ($response) {
                Write-ApiDebugLog ("HTTP status before exception: {0} ({1})" -f ([int]$response.StatusCode), $response.StatusCode)
                if ($responseBody) {
                    Write-ApiDebugLog ("Response body before exception:`n{0}" -f $responseBody)
                }
            }

            throw
        }

        if (-not $response.IsSuccessStatusCode) {
            $chunkInfo = if ([string]::IsNullOrWhiteSpace($ChunkLabel)) { "" } else { " ($ChunkLabel)" }
            Write-ApiDebugLog ("API error status: {0} ({1})" -f ([int]$response.StatusCode), $response.StatusCode)
            Write-ApiDebugLog ("API error body:`n{0}" -f $responseBody)
            throw "API error${chunkInfo}: HTTP $([int]$response.StatusCode)`n$responseBody"
        }

        $json = $responseBody | ConvertFrom-Json
        if ($WithDiarization) {
            if (-not $json.segments) {
                throw "Diarized API response does not contain 'segments'`n$responseBody"
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($json.text)) {
            throw "API response does not contain 'text'`n$responseBody"
        }

        Write-ApiDebugLog ("API request completed successfully after {0:N3} sec" -f $stopwatch.Elapsed.TotalSeconds)
        Write-ApiDebugLog ("Finished at UTC: {0:o}" -f [DateTime]::UtcNow)
        Write-TranscribeLog ("API response received: {0}" -f $labelForLog)
        return $json
    }
    catch {
        Write-ApiDebugLog ("Invoke-Transcription failed after {0:N3} sec" -f $stopwatch.Elapsed.TotalSeconds)
        Write-ApiDebugLog ("Top API exception type: {0}" -f $_.Exception.GetType().FullName)
        Write-ApiDebugLog ("Top API exception message: {0}" -f $_.Exception.Message)
        Write-ApiDebugLog ("Top API FullyQualifiedErrorId: {0}" -f $_.FullyQualifiedErrorId)
        if (-not [string]::IsNullOrWhiteSpace($script:LastApiDebugLogPath)) {
            Write-ApiDebugLog ("API debug log path: {0}" -f $script:LastApiDebugLogPath)
        }

        throw
    }
    finally {
        $stopwatch.Stop()
        if ($fileStream) { $fileStream.Dispose() }
        if ($multipart) { $multipart.Dispose() }
        $script:CurrentApiDebugLogPath = $previousApiDebugLogPath
    }
}

try {
    Set-TranscribeProgress -Status "Preparing input" -PercentComplete 5
    Write-TranscribeLog "Preparing transcription request"
    $saveIntermediates = $Save.IsPresent
    $debugNativeMode = $DebugNative.IsPresent
    # Tolerate diarization flags passed as free-form arguments.
    # This helps when users copy commands from terminals where line wrapping
    # or shell specifics may alter how a switch is tokenized.
    if ($AdditionalArgs) {
        $normalizedArgs = $AdditionalArgs | ForEach-Object { $_.Trim() }
        if (-not $WithDiarization -and (
            $normalizedArgs -contains "-WithDiarization" -or
            $normalizedArgs -contains "--with-diarization" -or
            $normalizedArgs -contains "-Diarization" -or
            $normalizedArgs -contains "-wd")) {
            $WithDiarization = $true
        }

        if (-not $saveIntermediates -and (
            $normalizedArgs -contains "-Save" -or
            $normalizedArgs -contains "-save" -or
            $normalizedArgs -contains "--save")) {
            $saveIntermediates = $true
        }

        if (-not $debugNativeMode -and (
            $normalizedArgs -contains "-DebugNative" -or
            $normalizedArgs -contains "-debugnative" -or
            $normalizedArgs -contains "--debug-native")) {
            $debugNativeMode = $true
        }
    }

    $script:DebugNativeEnabled = $debugNativeMode
    if ($script:DebugNativeEnabled) {
        Write-NativeDebugLog "Native command diagnostics enabled"
    }

    # Verify that the user-provided path exists before resolving it.
    # Using -LiteralPath avoids wildcard expansion and treats the string as-is.
    if (-not (Test-Path -LiteralPath $InputFile)) {
        Complete-TranscribeProgress
        throw "Input file not found: $InputFile"
    }

    # Normalize the path to an absolute path so all follow-up operations
    # (stream opening, output generation) use a consistent file location.
    $fullInputPath = (Resolve-Path -LiteralPath $InputFile).Path
    $extension = [System.IO.Path]::GetExtension($fullInputPath).ToLowerInvariant()

    # Keep validation strict to avoid accidental uploads of unsupported formats.
    # If needed, this block can be extended to support additional audio types.
    if ($extension -ne ".mp3") {
        Complete-TranscribeProgress
        throw "Expected .mp3 file, got: $extension"
    }

    # Read API credentials from environment variable so we never hardcode secrets
    # in source code, scripts, or command history.
    $apiKey = $env:OPENAI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Complete-TranscribeProgress
        throw "Environment variable OPENAI_API_KEY is not set"
    }

    # Generate an output text file path in the same directory as the source file.
    # Example: meeting.mp3 -> meeting.txt
    $outputFile = [System.IO.Path]::ChangeExtension($fullInputPath, ".txt")
    # OpenAI upload limit is 25 MB; use 24 MB as a safety target.
    $targetUploadBytes = 24000000
    $minUploadBitrateKbps = 8
    $safeDiarizationChunkSeconds = 1300.0
    # Experimental safety threshold for gpt-4o transcribe single-file uploads.
    # Long uploads above this threshold are split locally and uploaded in parts.
    $maxStandardSingleUploadSeconds = 3300.0

    # Use a default lightweight model, but allow an explicit diarization mode.
    # This keeps default cost/performance behavior unchanged for existing users.
    $model = if ($WithDiarization) { "gpt-4o-transcribe-diarize" } else { "gpt-4o-mini-transcribe" }
    Write-TranscribeLog ("Using model: {0}" -f $model)

    # Ensure System.Net.Http types are available in the current PowerShell session.
    Add-Type -AssemblyName System.Net.Http

    # Configure an HTTP client once and attach Bearer authentication for the API.
    # The client is disposed in the finally block to free network resources.
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.Timeout = [TimeSpan]::FromMinutes(15)
    $httpClient.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    Write-TranscribeLog ("API timeout: {0}" -f $httpClient.Timeout)

    $tempDir = $null
    try {
        $allTexts = [System.Collections.Generic.List[string]]::new()
        Set-TranscribeProgress -Status "Detecting audio duration" -PercentComplete 15
        Write-TranscribeLog ("Resolving input file: {0}" -f $fullInputPath)
        $duration = Get-AudioDurationSeconds -FilePath $fullInputPath
        if ($duration -le 0) {
            throw "Audio duration must be greater than zero"
        }

        Write-TranscribeLog ("Audio duration: {0} ({1:N3} sec)" -f (Format-DurationSeconds -Seconds $duration), $duration)
        $sourceBitrateKbps = Get-AudioBitrateKbps -FilePath $fullInputPath
        if ($null -eq $sourceBitrateKbps) {
            Write-TranscribeLog "WARNING: Source audio bitrate could not be detected; upload bitrate will be based on size limit only"
        }
        else {
            Write-TranscribeLog ("Source audio bitrate: {0} kbps" -f $sourceBitrateKbps)
        }

        if (($saveIntermediates -or $script:DebugNativeEnabled) -and -not $tempDir) {
            $tempDir = New-TranscribeWorkDirectory -OutputFile $outputFile -Save $saveIntermediates
            $script:NativeLogDirectory = $tempDir
            $script:ApiLogDirectory = $tempDir
        }

        if ($WithDiarization) {
            if (-not $tempDir) {
                $tempDir = New-TranscribeWorkDirectory -OutputFile $outputFile -Save $saveIntermediates
                $script:NativeLogDirectory = $tempDir
                $script:ApiLogDirectory = $tempDir
            }

            Set-TranscribeProgress -Status "Preparing diarization upload audio" -PercentComplete 25
            Write-TranscribeLog ("Preparing diarization chunks with target size {0} bytes and max duration {1:N0} sec" -f $targetUploadBytes, $safeDiarizationChunkSeconds)

            if ($duration -gt $safeDiarizationChunkSeconds) {
                $silenceIntervals = @(Get-SilenceIntervals -InputPath $fullInputPath -DurationSeconds $duration)
                $cutPoints = @(Select-DiarizationCutPoints -DurationSeconds $duration -SafeChunkDurationSeconds $safeDiarizationChunkSeconds -SilenceIntervals $silenceIntervals)
            }
            else {
                $cutPoints = @()
            }

            $chunkSpecs = @(New-DiarizationChunkSpecs -DurationSeconds $duration -CutPoints $cutPoints)
            $chunkBitrateKbps = Get-BitrateForChunkSet -ChunkSpecs $chunkSpecs -TargetBytes $targetUploadBytes -MinimumKbps $minUploadBitrateKbps -SourceBitrateKbps $sourceBitrateKbps
            Write-TranscribeLog ("Diarization chunk count: {0}; upload bitrate: {1} kbps" -f $chunkSpecs.Count, $chunkBitrateKbps)
            $uploadPaths = @(Export-DiarizationChunks -InputPath $fullInputPath -ChunkSpecs $chunkSpecs -BitrateKbps $chunkBitrateKbps -TargetBytes $targetUploadBytes -TempDirectory $tempDir)

            $speakerMap = @{}
            $nextSpeakerIndex = 0
            $speakerReferences = [System.Collections.Generic.List[object]]::new()

            for ($i = 0; $i -lt $uploadPaths.Count; $i++) {
                $uploadPath = $uploadPaths[$i]
                $chunkLabel = if ($uploadPaths.Count -gt 1) { "chunk {0}/{1}" -f ($i + 1), $uploadPaths.Count } else { $null }
                $chunkPercent = [math]::Min(90, 35 + [math]::Floor((($i + 1) / [double]$uploadPaths.Count) * 50))
                Set-TranscribeProgress -Status ("Uploading diarization audio {0}/{1}" -f ($i + 1), $uploadPaths.Count) -PercentComplete $chunkPercent
                Write-TranscribeLog ("Uploading diarization audio: {0}" -f $uploadPath)
                if ($speakerReferences.Count -gt 0) {
                    Write-TranscribeLog ("Using speaker references: {0}" -f (($speakerReferences | ForEach-Object { $_.Name }) -join ", "))
                }

                $diarizedResponse = Invoke-Transcription -HttpClient $httpClient -AudioPath $uploadPath -Model $model -WithDiarization $true -ChunkLabel $chunkLabel -SpeakerReferences $speakerReferences.ToArray()
                $allTexts.Add((Convert-DiarizedResponseToText -Response $diarizedResponse -SpeakerMap $speakerMap -NextSpeakerIndex ([ref]$nextSpeakerIndex)))
                Update-SpeakerReferences -Response $diarizedResponse -ChunkAudioPath $uploadPath -SpeakerMap $speakerMap -SpeakerReferences $speakerReferences -TempDirectory $tempDir
            }
        }
        else {
            if ($duration -gt $maxStandardSingleUploadSeconds) {
                if (-not $tempDir) {
                    $tempDir = New-TranscribeWorkDirectory -OutputFile $outputFile -Save $saveIntermediates
                    $script:NativeLogDirectory = $tempDir
                    $script:ApiLogDirectory = $tempDir
                }

                Set-TranscribeProgress -Status "Splitting audio for standard transcription" -PercentComplete 25
                Write-TranscribeLog "Audio is too long for a single request; splitting into chunks"
                $chunks = Split-AudioIntoChunks -InputPath $fullInputPath -MaxChunkDuration $maxStandardSingleUploadSeconds -TempDirectory $tempDir
                Write-TranscribeLog ("Splitting audio for standard transcription: {0} part(s) with max duration {1:N0} sec" -f $chunks.Count, $maxStandardSingleUploadSeconds)
                for ($i = 0; $i -lt $chunks.Count; $i++) {
                    $chunk = $chunks[$i]
                    $chunkLabel = "chunk {0}/{1}" -f ($i + 1), $chunks.Count
                    $chunkPercent = [math]::Min(90, 35 + [math]::Floor((($i + 1) / [double]$chunks.Count) * 50))
                    Set-TranscribeProgress -Status ("Uploading {0}" -f $chunkLabel) -PercentComplete $chunkPercent
                    Write-TranscribeLog ("Uploading: {0} ({1})" -f $chunkLabel, $chunk.Name)
                    $chunkResponse = Invoke-Transcription -HttpClient $httpClient -AudioPath $chunk.FullName -Model $model -WithDiarization $false -ChunkLabel $chunkLabel
                    $allTexts.Add($chunkResponse.text)
                }
            }
            else {
                Set-TranscribeProgress -Status "Uploading audio for transcription" -PercentComplete 45
                Write-TranscribeLog "Sending single transcription request"
                $singleResponse = Invoke-Transcription -HttpClient $httpClient -AudioPath $fullInputPath -Model $model -WithDiarization $false
                $allTexts.Add($singleResponse.text)
            }
        }

        Set-TranscribeProgress -Status "Writing transcript to disk" -PercentComplete 95
        Write-TranscribeLog ("Writing transcript to: {0}" -f $outputFile)
        $finalText = [string]::Join([Environment]::NewLine + [Environment]::NewLine, $allTexts)
        [System.IO.File]::WriteAllText($outputFile, $finalText, [System.Text.Encoding]::UTF8)
        $modeLabel = if ($WithDiarization) { "diarization mode" } else { "standard mode" }
        Write-TranscribeLog "Done: $outputFile ($modeLabel, model=$model)"
        Set-TranscribeProgress -Status "Transcription completed" -PercentComplete 100
    }
    finally {
        Complete-TranscribeProgress
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            if ($saveIntermediates -or $script:DebugNativeEnabled) {
                Write-TranscribeLog ("Keeping intermediate directory: {0}" -f $tempDir)
            }
            else {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($httpClient) { $httpClient.Dispose() }
    }
}
catch {
    Complete-TranscribeProgress
    if (-not [string]::IsNullOrWhiteSpace($script:LastApiDebugLogPath)) {
        $previousApiDebugLogPath = $script:CurrentApiDebugLogPath
        $script:CurrentApiDebugLogPath = $script:LastApiDebugLogPath
        Write-ApiDebugLog ("Top-level exception type: {0}" -f $_.Exception.GetType().FullName)
        Write-ApiDebugLog ("Top-level exception message: {0}" -f $_.Exception.Message)
        Write-ApiDebugLog ("Top-level FullyQualifiedErrorId: {0}" -f $_.FullyQualifiedErrorId)
        Write-ApiDebugLog ("Last API debug log path: {0}" -f $script:LastApiDebugLogPath)
        Write-TranscribeLog ("Last API debug log: {0}" -f $script:LastApiDebugLogPath)
        $script:CurrentApiDebugLogPath = $previousApiDebugLogPath
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LastNativeDebugLogPath)) {
        $previousDebugLogPath = $script:CurrentNativeDebugLogPath
        $script:CurrentNativeDebugLogPath = $script:LastNativeDebugLogPath
        Write-NativeDebugLog ("Top-level exception type: {0}" -f $_.Exception.GetType().FullName)
        Write-NativeDebugLog ("Top-level exception message: {0}" -f $_.Exception.Message)
        Write-NativeDebugLog ("Top-level FullyQualifiedErrorId: {0}" -f $_.FullyQualifiedErrorId)
        Write-NativeDebugLog ("Last native debug log path: {0}" -f $script:LastNativeDebugLogPath)
        Write-TranscribeLog ("Last native debug log: {0}" -f $script:LastNativeDebugLogPath)
        $script:CurrentNativeDebugLogPath = $previousDebugLogPath
    }

    Write-Error $_.Exception.Message
    exit 1
}
