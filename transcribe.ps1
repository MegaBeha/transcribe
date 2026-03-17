param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile
)

$ErrorActionPreference = "Stop"

try {
    if (-not (Test-Path -LiteralPath $InputFile)) {
        throw "Input file not found: $InputFile"
    }

    $fullInputPath = (Resolve-Path -LiteralPath $InputFile).Path
    $extension = [System.IO.Path]::GetExtension($fullInputPath).ToLowerInvariant()

    if ($extension -ne ".mp3") {
        throw "Expected .mp3 file, got: $extension"
    }

    $apiKey = $env:OPENAI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Environment variable OPENAI_API_KEY is not set"
    }

    $outputFile = [System.IO.Path]::ChangeExtension($fullInputPath, ".txt")
    $fileName = [System.IO.Path]::GetFileName($fullInputPath)

    Add-Type -AssemblyName System.Net.Http

    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)

    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    $fileStream = [System.IO.File]::OpenRead($fullInputPath)

    try {
        $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("audio/mpeg")

        $multipart.Add($fileContent, "file", $fileName)
        $multipart.Add([System.Net.Http.StringContent]::new("gpt-4o-mini-transcribe"), "model")
        $multipart.Add([System.Net.Http.StringContent]::new("ru"), "language")
        $multipart.Add([System.Net.Http.StringContent]::new("auto"), "chunking_strategy")

        $response = $httpClient.PostAsync("https://api.openai.com/v1/audio/transcriptions", $multipart).GetAwaiter().GetResult()
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "API error: HTTP $([int]$response.StatusCode)`n$responseBody"
        }

        $json = $responseBody | ConvertFrom-Json

        if ([string]::IsNullOrWhiteSpace($json.text)) {
            throw "API response does not contain 'text'`n$responseBody"
        }

        [System.IO.File]::WriteAllText($outputFile, $json.text, [System.Text.Encoding]::UTF8)
        Write-Host "Done: $outputFile"
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($multipart) { $multipart.Dispose() }
        if ($httpClient) { $httpClient.Dispose() }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}