param(
    # Relative or absolute URL to the source HLS playlist (.m3u8).
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("Url")]
    [string]$PlaylistUrl,

    # Optional explicit output path for the resulting .mp3 file.
    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    # Maximum allowed output size in megabytes (decimal MB).
    [Parameter(Mandatory = $false)]
    [double]$MaxSizeMB = 25.0,

    # Technical lower bitrate bound for iterative recompression.
    [Parameter(Mandatory = $false)]
    [int]$MinBitrateKbps = 8
)

$ErrorActionPreference = "Stop"
$audioProgressId = 7201

function Write-AudioLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[Audio] {0}" -f $Message)
}

function Set-AudioProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$PercentComplete
    )

    Write-Progress -Id $audioProgressId -Activity "Prepare audio" -Status $Status -PercentComplete $PercentComplete
}

function Complete-AudioProgress {
    Write-Progress -Id $audioProgressId -Activity "Prepare audio" -Completed
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

function Get-PlaylistDurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $ffprobePath = Get-RequiredCommand -Name "ffprobe"
    $probeArgs = @(
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $Url
    )

    $durationRaw = & $ffprobePath @probeArgs
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($durationRaw)) {
        throw "Failed to detect playlist duration via ffprobe"
    }

    $duration = 0.0
    if (-not [double]::TryParse($durationRaw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        throw "ffprobe returned an invalid duration: '$durationRaw'"
    }

    if ($duration -le 0) {
        throw "Playlist duration must be greater than zero"
    }

    return $duration
}

function Get-SafeFileNameBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [System.Uri]::new($Url)
        $segments = $uri.AbsolutePath.Split("/", [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    catch {
        throw "PlaylistUrl must be a valid absolute http(s) URL"
    }

    [array]::Reverse($segments)
    foreach ($segment in $segments) {
        $candidate = [System.Uri]::UnescapeDataString($segment)
        $candidate = $candidate -replace "\.m3u8$", ""
        $candidate = $candidate -replace "\.(mp4|mp3|aac|m4a|ts)$", ""
        $candidate = $candidate.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $candidate = $candidate -replace '[<>:"/\\|?*\x00-\x1F]', "_"
        $candidate = $candidate -replace '\s+', "_"
        $candidate = $candidate -replace '_{2,}', "_"
        $candidate = $candidate.Trim(" ", ".", "_")

        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return "playlist_audio"
}

function Get-DefaultOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$CurrentDirectory
    )

    $baseName = Get-SafeFileNameBase -Url $Url
    $suffix = [System.Guid]::NewGuid().ToString("N").Substring(0, 4)
    $fileName = "{0}_{1}.mp3" -f $baseName, $suffix
    return Join-Path $CurrentDirectory $fileName
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
    if (-not $allowed -or $allowed.Count -eq 0) {
        throw "No valid MP3 bitrates remain at or above MinBitrateKbps=$MinimumKbps"
    }

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

    $reserveBytes = [math]::Max(32768, [math]::Floor($TargetBytes * 0.01))
    $usableBytes = [math]::Max(1, $TargetBytes - $reserveBytes)
    $rawBitrate = [math]::Floor((($usableBytes * 8.0) / $DurationSeconds) / 1000.0)
    $clamped = [math]::Min(320, [math]::Max($MinimumKbps, [int]$rawBitrate))
    return Get-NearestAllowedBitrateAtOrBelow -BitrateKbps $clamped -MinimumKbps $MinimumKbps
}

function Format-SizeMB {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N2}", ($Bytes / 1000000.0)))
}

function Format-DurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Seconds
    )

    $ts = [System.TimeSpan]::FromSeconds($Seconds)
    return $ts.ToString("hh\:mm\:ss")
}

function Invoke-Mp3Encode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlaylistUrl,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [int]$BitrateKbps
    )

    $ffmpegPath = Get-RequiredCommand -Name "ffmpeg"
    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", $PlaylistUrl,
        "-vn",
        "-ac", "2",
        "-c:a", "libmp3lame",
        "-b:a", ("{0}k" -f $BitrateKbps),
        "-write_xing", "0",
        $OutputPath
    )

    & $ffmpegPath @ffmpegArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed to encode audio from the playlist"
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "ffmpeg finished without creating the output file"
    }

    $item = Get-Item -LiteralPath $OutputPath
    if ($item.Length -le 0) {
        throw "Encoded output file is empty"
    }
}

function Test-Mp3File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $ffprobePath = Get-RequiredCommand -Name "ffprobe"
    $probeArgs = @(
        "-v", "error",
        "-show_entries", "format=format_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $Path
    )

    $formatName = & $ffprobePath @probeArgs
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($formatName)) {
        throw "Failed to validate the encoded MP3 via ffprobe"
    }

    if ($formatName.Trim() -notmatch "(^|,)mp3(,|$)") {
        throw "Encoded output is not recognized as MP3"
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($PlaylistUrl)) {
        throw "PlaylistUrl must not be empty"
    }

    $playlistUri = $null
    if (-not [System.Uri]::TryCreate($PlaylistUrl, [System.UriKind]::Absolute, [ref]$playlistUri)) {
        throw "PlaylistUrl must be a valid absolute http(s) URL"
    }

    if ($playlistUri.Scheme -ne "http" -and $playlistUri.Scheme -ne "https") {
        throw "PlaylistUrl must use http or https"
    }

    if ($MaxSizeMB -le 0) {
        throw "MaxSizeMB must be greater than zero"
    }

    if ($MinBitrateKbps -lt 8) {
        throw "MinBitrateKbps must be at least 8"
    }

    $allowedAtOrAboveMin = Get-AllowedMp3BitrateKbps | Where-Object { $_ -ge $MinBitrateKbps }
    if (-not $allowedAtOrAboveMin -or $allowedAtOrAboveMin.Count -eq 0) {
        throw "MinBitrateKbps is above the maximum supported MP3 bitrate"
    }

    Write-AudioLog ("Preparing audio from playlist: {0}" -f $PlaylistUrl)
    Set-AudioProgress -Status "Validating input and dependencies" -PercentComplete 5
    $ffmpegPath = Get-RequiredCommand -Name "ffmpeg"
    $ffprobePath = Get-RequiredCommand -Name "ffprobe"

    Write-AudioLog "Detecting playlist duration"
    Set-AudioProgress -Status "Detecting playlist duration" -PercentComplete 10
    $durationSeconds = Get-PlaylistDurationSeconds -Url $PlaylistUrl
    $targetBytes = [long][math]::Floor($MaxSizeMB * 1000000.0)
    Write-AudioLog "Calculating initial bitrate"
    Set-AudioProgress -Status "Calculating target bitrate" -PercentComplete 15
    $initialBitrateKbps = Get-InitialBitrateKbps -DurationSeconds $durationSeconds -TargetBytes $targetBytes -MinimumKbps $MinBitrateKbps

    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputFile)) {
        Get-DefaultOutputPath -Url $PlaylistUrl -CurrentDirectory (Get-Location).Path
    }
    else {
        $OutputFile
    }

    $resolvedOutputPath = [System.IO.Path]::GetFullPath($resolvedOutputPath)
    $outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw "Failed to resolve the output directory"
    }

    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    }

    Write-AudioLog ("Final MP3 will be written to: {0}" -f $resolvedOutputPath)
    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

    try {
        $attempt = 1
        $currentBitrateKbps = $initialBitrateKbps
        $successPath = $null

        Write-AudioLog ("Duration: {0} ({1:N3} sec)" -f (Format-DurationSeconds -Seconds $durationSeconds), $durationSeconds)
        Write-AudioLog ("Target size: {0} MB ({1} bytes)" -f ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N2}", $MaxSizeMB)), $targetBytes)
        Write-AudioLog ("Initial bitrate: {0} kbps" -f $currentBitrateKbps)

        while ($true) {
            $attemptPath = Join-Path $tempDirectory ("attempt_{0:000}_{1}k.mp3" -f $attempt, $currentBitrateKbps)
            if (Test-Path -LiteralPath $attemptPath) {
                Remove-Item -LiteralPath $attemptPath -Force
            }

            $attemptPercent = [math]::Min(90, 20 + ($attempt * 3))
            Set-AudioProgress -Status ("Encoding attempt #{0}" -f $attempt) -PercentComplete $attemptPercent
            Write-AudioLog ("Encoding attempt #{0}: {1} kbps" -f $attempt, $currentBitrateKbps)
            Invoke-Mp3Encode -PlaylistUrl $PlaylistUrl -OutputPath $attemptPath -BitrateKbps $currentBitrateKbps
            Set-AudioProgress -Status ("Validating encoded MP3 after attempt #{0}" -f $attempt) -PercentComplete ([math]::Min(94, $attemptPercent + 1))
            Write-AudioLog ("Validating encoded MP3 after attempt #{0}" -f $attempt)
            Test-Mp3File -Path $attemptPath

            $attemptSize = (Get-Item -LiteralPath $attemptPath).Length
            Write-AudioLog ("Encoded size: {0} MB ({1} bytes)" -f (Format-SizeMB -Bytes $attemptSize), $attemptSize)

            if ($attemptSize -le $targetBytes) {
                $successPath = $attemptPath
                break
            }

            $ratio = $targetBytes / [double]$attemptSize
            $rawNextBitrate = [int][math]::Floor($currentBitrateKbps * $ratio * 0.98)
            $candidateBitrate = Get-NearestAllowedBitrateAtOrBelow -BitrateKbps $rawNextBitrate -MinimumKbps $MinBitrateKbps

            if ($candidateBitrate -ge $currentBitrateKbps) {
                $candidateBitrate = Get-NextLowerAllowedBitrate -CurrentKbps $currentBitrateKbps -MinimumKbps $MinBitrateKbps
            }

            if ($candidateBitrate -eq $currentBitrateKbps) {
                Write-AudioLog ("Bitrate floor reached at {0} kbps; retrying once at the minimum allowed bitrate." -f $currentBitrateKbps)
            }
            else {
                Write-AudioLog ("Retrying with lower bitrate: {0} kbps" -f $candidateBitrate)
            }

            if ($attempt -ge 25) {
                throw "Exceeded the maximum number of encoding attempts"
            }

            $currentBitrateKbps = $candidateBitrate
            $attempt++
        }

        if (-not $successPath) {
            throw "Failed to produce an MP3 within the target size"
        }

        if (Test-Path -LiteralPath $resolvedOutputPath) {
            Remove-Item -LiteralPath $resolvedOutputPath -Force
        }

        Write-AudioLog "Moving final MP3 into place"
        Set-AudioProgress -Status "Moving final MP3 into place" -PercentComplete 97
        Move-Item -LiteralPath $successPath -Destination $resolvedOutputPath
        $finalItem = Get-Item -LiteralPath $resolvedOutputPath
        Write-AudioLog ("Done: {0}" -f $resolvedOutputPath)
        Write-AudioLog ("Final bitrate: {0} kbps" -f $currentBitrateKbps)
        Write-AudioLog ("Final size: {0} MB ({1} bytes)" -f (Format-SizeMB -Bytes $finalItem.Length), $finalItem.Length)
        Set-AudioProgress -Status "Audio preparation completed" -PercentComplete 100
    }
    finally {
        Complete-AudioProgress
        if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Complete-AudioProgress
    Write-Error $_.Exception.Message
    exit 1
}
