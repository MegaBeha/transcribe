param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Source,

    [Parameter(Mandatory = $false)]
    [Alias("Diarization", "SpeakerDiarization", "wd")]
    [switch]$WithDiarization,

    [Parameter(Mandatory = $false)]
    [switch]$Save,

    [Parameter(Mandatory = $false)]
    [switch]$DebugNative
)

$ErrorActionPreference = "Stop"
$pipelineProgressId = 7001

function Write-PipelineLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[Pipeline] {0}" -f $Message)
}

function Set-PipelineProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$PercentComplete
    )

    Write-Progress -Id $pipelineProgressId -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function Complete-PipelineProgress {
    Write-Progress -Id $pipelineProgressId -Activity "Pipeline" -Completed
}

function Exit-WithError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [Console]::Error.WriteLine($Message)
    exit 1
}

function Get-ScriptPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $path = Join-Path $scriptDirectory $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required script not found: $FileName"
    }

    return $path
}

function Get-SupportedVideoExtensions {
    return @(".webm", ".mp4", ".mkv", ".mov", ".avi", ".m4v", ".wmv")
}

function Get-SupportedLocalFileDescription {
    $videoExtensions = (Get-SupportedVideoExtensions) -join ", "
    return ".mp3 or video file ($videoExtensions)"
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

function Get-InputKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (Test-Path -LiteralPath $Value) {
        $resolvedPath = (Resolve-Path -LiteralPath $Value).Path
        $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
        if ($extension -eq ".mp3") {
            return @{
                Kind = "mp3"
                Value = $resolvedPath
            }
        }

        if ((Get-SupportedVideoExtensions) -contains $extension) {
            return @{
                Kind = "video"
                Value = $resolvedPath
            }
        }

        throw "Unsupported local file type: expected $(Get-SupportedLocalFileDescription), got '$extension'"
    }

    $uri = $null
    if ([System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
            throw "Unsupported URL scheme: $($uri.Scheme). Expected http or https"
        }

        $candidate = $Value.ToLowerInvariant()
        $looksLikePlaylist =
            $candidate.EndsWith(".m3u8") -or
            $candidate.Contains(".m3u8?") -or
            $candidate.Contains("master.m3u8") -or
            $candidate.Contains("playlist.m3u8") -or
            $candidate.Contains("mpegurl")

        return @{
            Kind = $(if ($looksLikePlaylist) { "playlist" } else { "page" })
            Value = $uri.AbsoluteUri
        }
    }

    $looksLikeLocalPath = $Value.Contains("\") -or $Value.Contains("/") -or $Value.Contains(":")
    if ($looksLikeLocalPath) {
        throw "Local file not found: $Value"
    }

    throw "Unsupported input. Expected an absolute http(s) URL or a local $(Get-SupportedLocalFileDescription) path"
}

function Get-SafeNameFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $rawValue = $Source
    $uri = $null
    if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri)) {
        $segments = $uri.AbsolutePath.Split("/", [System.StringSplitOptions]::RemoveEmptyEntries)
        [array]::Reverse($segments)
        foreach ($segment in $segments) {
            $candidate = [System.Uri]::UnescapeDataString($segment)
            $candidate = $candidate -replace "\.m3u8$", ""
            $candidate = $candidate -replace "\.(mp3|mp4|aac|m4a|ts)$", ""
            $candidate = $candidate.Trim()
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $rawValue = $candidate
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            $rawValue = $uri.Host
        }
    }

    $safeValue = $rawValue -replace '[<>:"/\\|?*\x00-\x1F]', "_"
    $safeValue = $safeValue -replace '\s+', "_"
    $safeValue = $safeValue -replace '_{2,}', "_"
    $safeValue = $safeValue.Trim(" ", ".", "_")

    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return "transcript"
    }

    return $safeValue
}

function New-ManagedMp3Path {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $baseName = Get-SafeNameFromSource -Source $Source
    $suffix = [System.Guid]::NewGuid().ToString("N").Substring(0, 6)
    $fileName = "{0}_{1}.mp3" -f $baseName, $suffix
    return Join-Path (Get-Location).Path $fileName
}

function New-ManagedMp3PathForLocalMedia {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaPath
    )

    $directory = [System.IO.Path]::GetDirectoryName($MediaPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($MediaPath)
    $suffix = [System.Guid]::NewGuid().ToString("N").Substring(0, 6)
    $fileName = "{0}_{1}.mp3" -f $baseName, $suffix
    return Join-Path $directory $fileName
}

function Get-TranscriptPathForLocalMedia {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaPath
    )

    return [System.IO.Path]::ChangeExtension($MediaPath, ".txt")
}

function Invoke-ExtractPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PageUrl
    )

    $scriptPath = Get-ScriptPath -FileName "extract-playlist.ps1"
    Write-PipelineLog ("Starting playlist extraction from page: {0}" -f $PageUrl)
    $output = & $scriptPath $PageUrl 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ""
        if ($output) {
            $details = ($output | ForEach-Object { $_.ToString() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }

        if ([string]::IsNullOrWhiteSpace($details)) {
            throw "extract-playlist.ps1 failed"
        }

        throw ("extract-playlist.ps1 failed:`n{0}" -f $details)
    }

    $playlistUrl = if ($output -is [System.Array]) { [string]$output[-1] } else { [string]$output }
    $playlistUrl = $playlistUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($playlistUrl)) {
        throw "extract-playlist.ps1 did not return a playlist URL"
    }

    Write-PipelineLog ("Playlist extracted: {0}" -f $playlistUrl)
    return $playlistUrl
}

function Invoke-PrepareAudio {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlaylistUrl,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $scriptPath = Get-ScriptPath -FileName "prepare-audio.ps1"
    Write-PipelineLog ("Starting audio preparation from playlist: {0}" -f $PlaylistUrl)
    Write-PipelineLog ("Temporary MP3 path: {0}" -f $OutputFile)
    & $scriptPath $PlaylistUrl -OutputFile $OutputFile
    if ($LASTEXITCODE -ne 0) {
        throw "prepare-audio.ps1 failed"
    }

    if (-not (Test-Path -LiteralPath $OutputFile)) {
        throw "prepare-audio.ps1 finished but did not create the MP3 file"
    }

    Write-PipelineLog ("Audio prepared: {0}" -f $OutputFile)
}

function Invoke-PrepareAudioFromVideo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $ffmpegPath = Get-RequiredCommand -Name "ffmpeg"
    Write-PipelineLog ("Starting audio extraction from video: {0}" -f $VideoFile)
    Write-PipelineLog ("Temporary MP3 path: {0}" -f $OutputFile)

    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", $VideoFile,
        "-vn",
        "-ac", "2",
        "-c:a", "libmp3lame",
        "-b:a", "48k",
        "-write_xing", "0",
        $OutputFile
    )

    & $ffmpegPath @ffmpegArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed to extract MP3 audio from the video file"
    }

    if (-not (Test-Path -LiteralPath $OutputFile)) {
        throw "ffmpeg finished but did not create the MP3 file"
    }

    $item = Get-Item -LiteralPath $OutputFile
    if ($item.Length -le 0) {
        throw "Extracted MP3 file is empty"
    }

    Write-PipelineLog ("Audio extracted: {0}" -f $OutputFile)
}

function Invoke-Transcribe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mp3Path,

        [Parameter(Mandatory = $false)]
        [bool]$WithDiarization = $false,

        [Parameter(Mandatory = $false)]
        [bool]$Save = $false,

        [Parameter(Mandatory = $false)]
        [bool]$DebugNative = $false
    )

    $scriptPath = Get-ScriptPath -FileName "transcribe.ps1"
    Write-PipelineLog ("Starting transcription for MP3: {0}" -f $Mp3Path)
    $transcribeArgs = @($Mp3Path)
    if ($WithDiarization) {
        $transcribeArgs += "-WithDiarization"
    }

    if ($Save) {
        $transcribeArgs += "-Save"
    }

    if ($DebugNative) {
        $transcribeArgs += "-DebugNative"
    }

    & $scriptPath @transcribeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "transcribe.ps1 failed"
    }

    $txtPath = [System.IO.Path]::ChangeExtension($Mp3Path, ".txt")
    if (-not (Test-Path -LiteralPath $txtPath)) {
        throw "transcribe.ps1 finished but did not create the text file"
    }

    Write-PipelineLog ("Text transcript created: {0}" -f $txtPath)
    return $txtPath
}

function Move-TranscriptToFinalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentPath,

        [Parameter(Mandatory = $true)]
        [string]$FinalPath
    )

    if ([System.IO.Path]::GetFullPath($CurrentPath) -eq [System.IO.Path]::GetFullPath($FinalPath)) {
        return $CurrentPath
    }

    if (Test-Path -LiteralPath $FinalPath) {
        Remove-Item -LiteralPath $FinalPath -Force
    }

    Move-Item -LiteralPath $CurrentPath -Destination $FinalPath
    Write-PipelineLog ("Text transcript moved to final path: {0}" -f $FinalPath)
    return $FinalPath
}

$managedMp3Path = $null
try {
    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "Input must not be empty"
    }

    Write-PipelineLog ("Received input: {0}" -f $Source)
    Set-PipelineProgress -Activity "Pipeline" -Status "Detecting input type" -PercentComplete 5
    $inputInfo = Get-InputKind -Value $Source
    $mp3Path = $null

    Write-PipelineLog ("Detected input type: {0}" -f $inputInfo.Kind)
    switch ($inputInfo.Kind) {
        "mp3" {
            Write-PipelineLog "Selected short pipeline: MP3 -> transcription"
            Set-PipelineProgress -Activity "Pipeline" -Status "Using provided MP3 file" -PercentComplete 25
            $mp3Path = $inputInfo.Value
        }
        "video" {
            Write-PipelineLog "Selected local media pipeline: video -> audio -> transcription"
            $managedMp3Path = New-ManagedMp3PathForLocalMedia -MediaPath $inputInfo.Value
            Set-PipelineProgress -Activity "Pipeline" -Status "Extracting audio from video" -PercentComplete 35
            Invoke-PrepareAudioFromVideo -VideoFile $inputInfo.Value -OutputFile $managedMp3Path
            $mp3Path = $managedMp3Path
        }
        "playlist" {
            Write-PipelineLog "Selected short pipeline: playlist -> audio -> transcription"
            $managedMp3Path = New-ManagedMp3Path -Source $inputInfo.Value
            Set-PipelineProgress -Activity "Pipeline" -Status "Preparing audio from playlist" -PercentComplete 35
            Invoke-PrepareAudio -PlaylistUrl $inputInfo.Value -OutputFile $managedMp3Path
            $mp3Path = $managedMp3Path
        }
        "page" {
            Write-PipelineLog "Selected full pipeline: page -> playlist -> audio -> transcription"
            Set-PipelineProgress -Activity "Pipeline" -Status "Extracting playlist from page" -PercentComplete 20
            $playlistUrl = Invoke-ExtractPlaylist -PageUrl $inputInfo.Value
            $managedMp3Path = New-ManagedMp3Path -Source $playlistUrl
            Set-PipelineProgress -Activity "Pipeline" -Status "Preparing audio from extracted playlist" -PercentComplete 50
            Invoke-PrepareAudio -PlaylistUrl $playlistUrl -OutputFile $managedMp3Path
            $mp3Path = $managedMp3Path
        }
        default {
            throw "Unsupported input kind: $($inputInfo.Kind)"
        }
    }

    Set-PipelineProgress -Activity "Pipeline" -Status "Transcribing audio" -PercentComplete 80
    $txtPath = Invoke-Transcribe -Mp3Path $mp3Path -WithDiarization $WithDiarization.IsPresent -Save $Save.IsPresent -DebugNative $DebugNative.IsPresent
    if ($inputInfo.Kind -eq "video") {
        $finalTxtPath = Get-TranscriptPathForLocalMedia -MediaPath $inputInfo.Value
        $txtPath = Move-TranscriptToFinalPath -CurrentPath $txtPath -FinalPath $finalTxtPath
    }

    Set-PipelineProgress -Activity "Pipeline" -Status "Finishing" -PercentComplete 100
    Write-PipelineLog ("Pipeline completed successfully. Result: {0}" -f $txtPath)
    Write-Output $txtPath
}
catch {
    Complete-PipelineProgress
    Exit-WithError $_.Exception.Message
}
finally {
    Complete-PipelineProgress
    if ($managedMp3Path -and (Test-Path -LiteralPath $managedMp3Path)) {
        if ($Save) {
            Write-PipelineLog ("Keeping intermediate MP3: {0}" -f $managedMp3Path)
        }
        else {
            Write-PipelineLog ("Removing temporary MP3: {0}" -f $managedMp3Path)
            Remove-Item -LiteralPath $managedMp3Path -Force -ErrorAction SilentlyContinue
        }
    }
}
