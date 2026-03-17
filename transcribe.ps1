param(
    # Relative or absolute path to the source audio file that should be transcribed.
    # The script currently validates that this file uses the .mp3 extension.
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile
)

# Fail fast on any non-terminating error so that we do not silently continue
# after partial failures (for example, network issues or malformed JSON).
$ErrorActionPreference = "Stop"

try {
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
    $fileName = [System.IO.Path]::GetFileName($fullInputPath)

    # Ensure System.Net.Http types are available in the current PowerShell session.
    Add-Type -AssemblyName System.Net.Http

    # Configure an HTTP client once and attach Bearer authentication for the API.
    # The client is disposed in the finally block to free network resources.
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)

    # Build a multipart/form-data request body expected by
    # /v1/audio/transcriptions: audio file + model/options fields.
    $multipart = [System.Net.Http.MultipartFormDataContent]::new()

    # Open the file as a stream to avoid loading the entire MP3 into memory.
    # This is especially important for larger recordings.
    $fileStream = [System.IO.File]::OpenRead($fullInputPath)

    try {
        # Wrap the stream in HTTP content and explicitly set media type so
        # the server can correctly interpret the uploaded binary payload.
        $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("audio/mpeg")

        # Add the required file part and additional transcription parameters.
        $multipart.Add($fileContent, "file", $fileName)
        $multipart.Add([System.Net.Http.StringContent]::new("gpt-4o-mini-transcribe"), "model")
        $multipart.Add([System.Net.Http.StringContent]::new("ru"), "language")
        $multipart.Add([System.Net.Http.StringContent]::new("auto"), "chunking_strategy")

        # Execute the request synchronously for script simplicity.
        # GetAwaiter().GetResult() bridges async .NET APIs into PowerShell script flow.
        $response = $httpClient.PostAsync("https://api.openai.com/v1/audio/transcriptions", $multipart).GetAwaiter().GetResult()
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        # Provide the raw response body in error cases to simplify debugging
        # (e.g., invalid API key, unsupported file, rate limiting).
        if (-not $response.IsSuccessStatusCode) {
            throw "API error: HTTP $([int]$response.StatusCode)`n$responseBody"
        }

        # Parse JSON response and extract the transcript text field.
        $json = $responseBody | ConvertFrom-Json

        # Fail explicitly if API contract changes or text is unexpectedly absent.
        if ([string]::IsNullOrWhiteSpace($json.text)) {
            throw "API response does not contain 'text'`n$responseBody"
        }

        # Save transcript using UTF-8 encoding so Cyrillic and other Unicode
        # characters are preserved in the resulting .txt file.
        [System.IO.File]::WriteAllText($outputFile, $json.text, [System.Text.Encoding]::UTF8)
        Write-Host "Done: $outputFile"
    }
    finally {
        # Always release disposable resources, even if request/parsing fails.
        # This prevents file locks and socket/resource leaks in repeated runs.
        if ($fileStream) { $fileStream.Dispose() }
        if ($multipart) { $multipart.Dispose() }
        if ($httpClient) { $httpClient.Dispose() }
    }
}
catch {
    # Surface only the core exception message for cleaner CLI output.
    Write-Error $_.Exception.Message
    exit 1
}
