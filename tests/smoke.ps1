$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$popupScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'notify-done.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($popupScriptPath, [ref]$tokens, [ref]$parseErrors)
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

    $payloadToken = Write-PopupPayload '{"example":"synthetic"}'
    if ((Read-PopupPayload $payloadToken) -ne '{"example":"synthetic"}') { throw 'Payload round trip failed' }
    if (Test-Path (Join-Path (Get-PayloadDirectory) ($payloadToken + '.json'))) { throw 'Consumed payload was not removed' }
    $stalePayload = Write-PopupPayload '{}'
    $stalePath = Join-Path (Get-PayloadDirectory) ($stalePayload + '.json')
    [IO.File]::SetLastWriteTimeUtc($stalePath, [DateTime]::UtcNow.AddMinutes(-10))
    Remove-ExpiredCompletions
    if (Test-Path $stalePath) { throw 'Stale payload was not removed' }

    # Execute the real parent hook in a child PowerShell, mocking only its GUI
    # launch. Long UTF-8 stdin must become a short token-only command line.
    $runner = @'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Start-Process {
    param($FilePath, $WindowStyle, $ArgumentList)
    $encoded=$ArgumentList[$ArgumentList.Count-1]
    $command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    if($command.Length -gt 2048 -or $command -notmatch "-PayloadToken '([0-9a-f-]{36})'"){throw 'Unbounded popup command'}
    $token=$Matches[1]
    $file=Join-Path $env:CODEX_NOTIFY_STATE_DIR ('payloads\'+$token+'.json')
    $data=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
    if($data.last_assistant_message.Length -ne 5000){throw 'Long Unicode payload was truncated'}
    if('__FAIL__' -eq '1'){throw 'synthetic launch failure'}
    [Console]::WriteLine((@{token=$token;command_length=$command.Length}|ConvertTo-Json -Compress))
}
& '__SOURCE__' '__MODE__'
'@
    $longText = ([string][char]0x6D4B) * 5000
    $json = @{session_id='synthetic-session';last_assistant_message=$longText;notification_message=('Question: '+$longText)} | ConvertTo-Json -Compress
    foreach ($case in @(@{mode='codex';fail='0'}, @{mode='codex-ask';fail='0'}, @{mode='codex';fail='1'})) {
        $program = $runner.Replace('__SOURCE__', $popupScriptPath.Replace("'", "''")).Replace('__MODE__', $case.mode).Replace('__FAIL__', $case.fail)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $child = New-Object Diagnostics.Process
        $child.StartInfo = $start
        [void]$child.Start()
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $child.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $child.StandardInput.Close()
        $output = $child.StandardOutput.ReadToEnd()
        $errors = $child.StandardError.ReadToEnd()
        if (-not $child.WaitForExit(15000)) { throw 'Hook regression test timed out' }
        if ($case.fail -eq '0') {
            if ($child.ExitCode -ne 0) { throw ('Hook regression failed: ' + $errors) }
            $result = $output | ConvertFrom-Json
            $payloadData = (Read-PopupPayload $result.token) | ConvertFrom-Json
            if ($payloadData.last_assistant_message -ne $longText) { throw 'Payload text mismatch' }
            Remove-CompletionFiles ([string]$payloadData.completion_token)
        }
        elseif ($child.ExitCode -eq 0) { throw 'Synthetic launch failure did not propagate' }
        $child.Dispose()
    }
    if (@(Get-ChildItem -LiteralPath (Get-PayloadDirectory) -File).Count -ne 0) { throw 'Launch failure leaked a payload file' }
    if (@(Get-ChildItem -LiteralPath (Get-CompletionDirectory) -Filter '*.json' | Where-Object {$_.Name -ne 'unrelated.json' -and $_.Name -ne ($token + '.route.json')}).Count -ne 0) { throw 'Launch failure leaked completion records' }
    'PASS: helpers, privacy, routes, long Unicode hook payloads, bounded commands and launch-failure cleanup (no GUI).'
}
finally {
    $env:CODEX_NOTIFY_STATE_DIR = $originalState
    $env:CODEX_NOTIFY_DEBUG = $originalDebug
    $env:CODEX_NOTIFY_PREVIEW = $originalPreview
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
