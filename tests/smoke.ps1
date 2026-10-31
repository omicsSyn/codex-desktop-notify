$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'notify-done.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }

# Load only pure helper functions. No popup, sound, focus action or user config.
foreach ($function in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) { Invoke-Expression $function.Extent.Text }

$originalState = $env:CODEX_NOTIFY_STATE_DIR
$originalDebug = $env:CODEX_NOTIFY_DEBUG
$originalPreview = $env:CODEX_NOTIFY_PREVIEW
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('notify-test-' + [Guid]::NewGuid().ToString())
$env:CODEX_NOTIFY_STATE_DIR = $temporary
try {
    $env:CODEX_NOTIFY_DEBUG = $null
    Write-PopupFocusLog 'example' @{ response = 'synthetic-private-text' }
    if (Test-Path $temporary) { throw 'Debug must be disabled by default' }
    $env:CODEX_NOTIFY_DEBUG = '1'
    Write-PopupFocusLog 'example' @{ session_id = 'synthetic-private-text'; focus_uri = 'synthetic-private-text' }
    $text = [IO.File]::ReadAllText((Join-Path $temporary 'logs\popup.jsonl'))
    if ($text.Contains('synthetic-private-text')) { throw 'Debug disclosed payload data' }
    $record = $text | ConvertFrom-Json
    if (@($record.PSObject.Properties.Name).Count -ne 3) { throw 'Unexpected debug fields' }

    $data = @{ thread_name = 'supplied title'; session_id = 'synthetic-session' }
    if ((Get-CodexThreadTitle $data) -ne 'supplied title') { throw 'Supplied title missing' }
    if (Get-CodexThreadTitle @{session_id = 'synthetic-session'}) { throw 'Must not read title indexes' }
    if ((ConvertTo-PopupText '**example** [link](https://example.invalid)') -ne 'example link') { throw 'Text cleanup failed' }

    $completion = Get-CompletionDirectory
    [void][IO.Directory]::CreateDirectory($completion)
    $token = [Guid]::NewGuid().ToString()
    $old = Join-Path $completion ($token + '.json')
    $unrelated = Join-Path $completion 'unrelated.json'
    [IO.File]::WriteAllText($old, '{}')
    [IO.File]::WriteAllText($unrelated, '{}')
    [IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddMinutes(-10))
    [IO.File]::SetLastWriteTimeUtc($unrelated, [DateTime]::UtcNow.AddMinutes(-10))
    Remove-ExpiredCompletions
    if ((Test-Path $old) -or -not (Test-Path $unrelated)) { throw 'Expired-record cleanup scope is wrong' }

    $routePath = Join-Path $completion ($token + '.route.json')
    $data = @{completion_token = $token; session_id = 'synthetic-session'}
    $route = @{session_id = 'synthetic-session'; focus_uri = 'vscode://wenbopan.vscode-terminal-osc-notifier/focus?tid=example'}
    $route | ConvertTo-Json | Set-Content -LiteralPath $routePath -Encoding UTF8
    if (-not (Read-CompletionRoute $data)) { throw 'Valid completion route rejected' }
    $route.session_id = 'another-session'
    $route | ConvertTo-Json | Set-Content -LiteralPath $routePath -Encoding UTF8
    if (Read-CompletionRoute $data) { throw 'Mismatched session route accepted' }
    $route.session_id = 'synthetic-session'
    $route.focus_uri = 'https://example.invalid'
    $route | ConvertTo-Json | Set-Content -LiteralPath $routePath -Encoding UTF8
    if (Read-CompletionRoute $data) { throw 'Untrusted URI accepted' }

    $preview = $ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ($env:CODEX_NOTIFY_PREVIEW')
    }, $true) | Select-Object -First 1
    if (-not $preview) { throw 'Screen privacy branch missing' }
    $env:CODEX_NOTIFY_PREVIEW = '0'
    $Source = 'Codex'
    $Kind = 'ask'
    $canFocus = $true
    $bodyText = 'synthetic-private-text'
    $topicText = 'synthetic-private-text'
    $footerText = 'synthetic-private-text'
    Invoke-Expression $preview.Extent.Text
    if ($topicText -or ($bodyText + $footerText).Contains('synthetic-private-text')) { throw 'Screen privacy failed' }
    'PASS: PowerShell syntax, helper functions, debug privacy, title handling, cleanup scope, URI/session validation and screen privacy.'
}
finally {
    $env:CODEX_NOTIFY_STATE_DIR = $originalState
    $env:CODEX_NOTIFY_DEBUG = $originalDebug
    $env:CODEX_NOTIFY_PREVIEW = $originalPreview
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
