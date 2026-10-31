param(
    [Parameter(Position = 0)]
    [string]$Mode = 'done',

    [Parameter(Position = 1)]
    [string]$Source,

    [Parameter(Position = 2)]
    [string]$Kind,

    [Parameter(Position = 3)]
    [string]$Payload,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

function Get-NotificationStateDirectory {
    if ($env:CODEX_NOTIFY_STATE_DIR) { return $env:CODEX_NOTIFY_STATE_DIR }
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexDesktopNotify'
}

function Write-PopupFocusLog([string]$Event, $Details) {
    # Diagnostics are opt-in and deliberately exclude message/session/URI data.
    if ($env:CODEX_NOTIFY_DEBUG -ne '1') { return }
    try {
        $logDirectory = Join-Path (Get-NotificationStateDirectory) 'logs'
        [void][IO.Directory]::CreateDirectory($logDirectory)
        $record = @{ time = [DateTime]::UtcNow.ToString('o'); event = $Event; pid = $PID }
        [IO.File]::AppendAllText((Join-Path $logDirectory 'popup.jsonl'),
            ($record | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

function Get-CompletionDirectory {
    return Join-Path (Get-NotificationStateDirectory) 'completion'
}

function Remove-ExpiredCompletions {
    $directory = Get-CompletionDirectory
    if (-not [IO.Directory]::Exists($directory)) { return }
    $cutoff = [DateTime]::UtcNow.AddMinutes(-5)
    foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
        if ([IO.Path]::GetFileName($file) -notmatch '^[0-9a-f-]{36}\.(json|json\.tmp|route\.json)$') { continue }
        try {
            if ([IO.File]::GetLastWriteTimeUtc($file) -lt $cutoff) { [IO.File]::Delete($file) }
        } catch { }
    }
}

function Read-CompletionRoute($Data) {
    if (-not $Data -or [string]$Data.completion_token -notmatch '^[0-9a-f-]{36}$') { return $null }
    $routePath = Join-Path (Get-CompletionDirectory) ($Data.completion_token + '.route.json')
    try {
        $route = [IO.File]::ReadAllText($routePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($route.session_id -ne $Data.session_id -or
            [string]$route.focus_uri -notmatch '^vscode(?:-insiders)?://wenbopan\.vscode-terminal-osc-notifier/focus\?tid=[A-Za-z0-9%_.-]+$') { return $null }
        return $route
    }
    catch { return $null }
}

function Set-CompletionRoute($Data, $Route) {
    if (-not $Route) { return }
    $Data | Add-Member -NotePropertyName focus_uri -NotePropertyValue $Route.focus_uri -Force
    $Data | Add-Member -NotePropertyName terminal_name -NotePropertyValue $Route.terminal_name -Force
}

# Hooks return immediately. A separate hidden PowerShell process owns the
# popup so Codex and Claude Code are never blocked by the UI.
if ($Mode -ne '__show') {
    Remove-ExpiredCompletions
    $payloadBase64 = ''
    switch ($Mode.ToLowerInvariant()) {
        { $_ -in @('codex', 'codex-ask') } {
            $popupSource = 'Codex'
            $popupKind = if ($_ -eq 'codex-ask') { 'ask' } else { 'done' }

            if ([Console]::IsInputRedirected) {
                [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
                $hookInput = [Console]::In.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($hookInput)) {
                    if ($popupKind -eq 'done') {
                        try {
                            $completionData = $hookInput | ConvertFrom-Json
                            if ($completionData.session_id) {
                                $completionDirectory = Get-CompletionDirectory
                                [void][IO.Directory]::CreateDirectory($completionDirectory)
                                $token = [Guid]::NewGuid().ToString()
                                $completionData | Add-Member -NotePropertyName completion_token -NotePropertyValue $token -Force
                                $record = @{
                                    token = $token
                                    session_id = [string]$completionData.session_id
                                    created_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                    response = [string]$completionData.last_assistant_message
                                } | ConvertTo-Json -Compress
                                $pendingPath = Join-Path $completionDirectory ($token + '.json')
                                [IO.File]::WriteAllText($pendingPath + '.tmp', $record, (New-Object Text.UTF8Encoding($false)))
                                [IO.File]::Move($pendingPath + '.tmp', $pendingPath)
                                $hookInput = $completionData | ConvertTo-Json -Compress -Depth 12
                                Write-PopupFocusLog 'completion_registered' @{ token = $token; session_id = $completionData.session_id }
                            }
                        }
                        catch { Write-PopupFocusLog 'completion_register_error' @{ error = $_.Exception.Message } }
                    }
                    $payloadBase64 = [Convert]::ToBase64String(
                        [Text.Encoding]::UTF8.GetBytes($hookInput)
                    )
                }
            }
        }
        'ask' {
            $popupSource = 'Claude Code'
            $popupKind = 'ask'
        }
        default {
            $popupSource = 'Claude Code'
            $popupKind = 'done'
        }
    }

    $escapedPath = $PSCommandPath.Replace("'", "''")
    $command = "& '$escapedPath' '__show' '$popupSource' '$popupKind' '$payloadBase64'"
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand', $encodedCommand
    ) | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class CornerNotificationForm : Form
{
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int cx,
        int cy,
        uint flags
    );

    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return parameters;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        SetWindowPos(
            Handle,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        );
    }
}
'@

$hookData = $null
if ($Payload) {
    try {
        $hookData = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($Payload)
        ) | ConvertFrom-Json
    }
    catch {
        $hookData = $null
    }
}

if ($Source -eq 'Codex' -and $Kind -eq 'done' -and $hookData.completion_token) {
    # The Stop hook publishes the full response before the TUI emits its native
    # completion preview. The terminal extension supplies the return address.
    $routeDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $completionRoute = Read-CompletionRoute $hookData
        if ($completionRoute) { Set-CompletionRoute $hookData $completionRoute; break }
        Start-Sleep -Milliseconds 80
    } while ([DateTime]::UtcNow -lt $routeDeadline)
}

function ConvertTo-PopupText([string]$Text) {
    # Keep several paragraphs, while removing Markdown decoration from labels.
    $Text = $Text -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
    $Text = $Text -replace '\[([^\]\r\n]+)\]\([^\r\n]*?\)', '$1'
    $Text = $Text -replace '(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+)', ''
    $Text = $Text -replace '(?m)^\s*```[^\r\n]*', ''
    $Text = $Text -replace '\*\*|__|`', ''
    $lines = @($Text -split '\r?\n' | ForEach-Object {
        ($_ -replace '[\t ]+', ' ').Trim()
    } | Where-Object { $_ })
    return ($lines -join "`r`n").Trim()
}

function Get-CodexThreadTitle($Data) {
    # Use only explicitly supplied titles; never inspect transcript/title indexes.
    if (-not $Data) { return '' }
    foreach ($field in @('thread_name', 'thread_title', 'conversation_title')) {
        if ($Data.$field) { return [string]$Data.$field }
    }
    return ''
}

$titleText = if ($Kind -eq 'ask') { '等待回答' } else { '本轮完成' }
$bodyText = if ($Kind -eq 'ask' -and $hookData -and $hookData.notification_message) {
    ConvertTo-PopupText ([string]$hookData.notification_message -replace '^Question:\s*', '')
}
elseif ($Kind -eq 'ask') {
    '需要你的操作，请返回查看具体问题。'
}
elseif ($hookData -and $hookData.last_assistant_message) {
    ConvertTo-PopupText ([string]$hookData.last_assistant_message)
}
else {
    '本轮回复已结束，可以返回查看结果。'
}
# Show only the opening one or two sentences/lines; details stay in the terminal.
$bodyText = $bodyText -replace '(?m)^\s*\d+[.)、]\s+', ''
$previewParts = @($bodyText -split '(?<=[。！？!?])\s*|(?<=\.)(?:\s+|$)|\r?\n' |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -First 2)
$bodyText = ($previewParts -join ' ').Trim()
if ($bodyText.Length -gt 120) { $bodyText = $bodyText.Substring(0, 119) + '…' }

$topicText = if ($Source -eq 'Codex') { Get-CodexThreadTitle $hookData } else { '' }
if (-not $topicText -and $hookData -and $hookData.terminal_name -and
    $hookData.terminal_name -notmatch '^(Terminal|终端|bash|pwsh|powershell|cmd|Codex|Ubuntu \(WSL\))$') {
    $topicText = [string]$hookData.terminal_name
}
# Questions may have no session ID or meaningful terminal name. In that case
# give the space to the question, without guessing a title or duplicating text.
$topicText = (ConvertTo-PopupText $topicText) -replace '\r?\n', ' '
if ($topicText.Length -gt 140) { $topicText = $topicText.Substring(0, 139) + '…' }

$footerParts = @($(if ($Source) { $Source } else { 'AI Assistant' }))
if ($hookData -and $hookData.terminal_name) { $footerParts += [string]$hookData.terminal_name }
if ($hookData -and $hookData.cwd) {
    $projectName = Split-Path -Leaf (([string]$hookData.cwd).TrimEnd([char[]]@('/', '\')))
    if ($projectName) { $footerParts += $projectName }
}
$canFocus = $Source -eq 'Codex' -and $hookData -and $hookData.focus_uri -and
    ([string]$hookData.focus_uri -match '^vscode(?:-insiders)?://wenbopan\.vscode-terminal-osc-notifier/focus\?tid=[A-Za-z0-9%_.-]+$')
$footerParts += $(if ($canFocus) { '点击返回终端' } else { '点击关闭' })
$footerText = $footerParts -join ' · '

if ($env:CODEX_NOTIFY_PREVIEW -eq '0') {
    $topicText = ''
    $bodyText = if ($Kind -eq 'ask') { '需要你的操作，请返回终端查看。' } else { '本轮回复已结束，可以返回终端查看。' }
    $footerText = $Source + ' · ' + $(if ($canFocus) { '点击返回终端' } else { '点击关闭' })
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$accentColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$backgroundColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$titleColor = [System.Drawing.Color]::FromArgb(248, 248, 248)
if ($Source -eq 'Codex') {
    if ($Kind -eq 'ask') {
        $accentColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        $backgroundColor = [System.Drawing.Color]::FromArgb(59, 39, 13)
        $titleColor = [System.Drawing.Color]::FromArgb(255, 205, 117)
    }
    else {
        $accentColor = [System.Drawing.Color]::FromArgb(46, 173, 103)
        $backgroundColor = [System.Drawing.Color]::FromArgb(15, 46, 30)
        $titleColor = [System.Drawing.Color]::FromArgb(128, 225, 169)
    }
}

$form = New-Object CornerNotificationForm
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.BackColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
if ($Source -eq 'Codex') { $form.BackColor = $accentColor }
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowIcon = $false
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$margin = 16
$popupWidth = [Math]::Min(480, $workingArea.Width - 2 * $margin)
$textWidth = $popupWidth - 44

$content = New-Object System.Windows.Forms.Panel
$content.BackColor = $backgroundColor
$content.Location = New-Object System.Drawing.Point(1, 1)

$accent = New-Object System.Windows.Forms.Panel
$accent.BackColor = $accentColor
$accent.Dock = [System.Windows.Forms.DockStyle]::Left
$accent.Width = 5

$title = New-Object System.Windows.Forms.Label
$title.AutoEllipsis = $true
$title.UseMnemonic = $false
$title.Font = New-Object System.Drawing.Font(
    'Microsoft YaHei UI',
    9,
    [System.Drawing.FontStyle]::Regular
)
$title.ForeColor = $titleColor
$title.Location = New-Object System.Drawing.Point(20, 12)
$title.Size = New-Object System.Drawing.Size($textWidth, 20)
$title.Text = $titleText

$topic = New-Object System.Windows.Forms.Label
$topic.AutoEllipsis = $true
$topic.UseMnemonic = $false
$topic.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$topic.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$topic.Location = New-Object System.Drawing.Point(20, 36)
$topic.Text = $topicText

$measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor
    [System.Windows.Forms.TextFormatFlags]::TextBoxControl -bor
    [System.Windows.Forms.TextFormatFlags]::NoPrefix
$measureSize = New-Object System.Drawing.Size($textWidth, 10000)
$topicLineHeight = [System.Windows.Forms.TextRenderer]::MeasureText('中文 Ag', $topic.Font).Height
$topicHeight = [System.Windows.Forms.TextRenderer]::MeasureText($topicText, $topic.Font, $measureSize, $measureFlags).Height
$topicHeight = [Math]::Min(2 * $topicLineHeight, [Math]::Max($topicLineHeight, $topicHeight)) + 4
if (-not $topicText) { $topicHeight = 0; $topic.Visible = $false }
$topic.Size = New-Object System.Drawing.Size($textWidth, $topicHeight)

$body = New-Object System.Windows.Forms.Label
$body.AutoEllipsis = $true
$body.UseMnemonic = $false
$body.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
$body.ForeColor = [System.Drawing.Color]::FromArgb(215, 215, 215)
$bodyTop = if ($topicText) { $topic.Bottom + 8 } else { $topic.Top }
$body.Location = New-Object System.Drawing.Point(20, $bodyTop)
$bodyLineHeight = [System.Windows.Forms.TextRenderer]::MeasureText('中文 Ag', $body.Font).Height
$bodyHeight = [System.Windows.Forms.TextRenderer]::MeasureText($bodyText, $body.Font, $measureSize, $measureFlags).Height
$maxBodyHeight = [Math]::Min(4 * $bodyLineHeight, $workingArea.Height - $bodyTop - 100)
$bodyHeight = [Math]::Min($maxBodyHeight, [Math]::Max($bodyLineHeight, $bodyHeight)) + 4
$body.Size = New-Object System.Drawing.Size($textWidth, $bodyHeight)
$body.Text = $bodyText

$footer = New-Object System.Windows.Forms.Label
$footer.AutoEllipsis = $true
$footer.UseMnemonic = $false
$footer.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(165, 175, 170)
$footer.Location = New-Object System.Drawing.Point(20, ($body.Bottom + 8))
$footer.Size = New-Object System.Drawing.Size($textWidth, 18)
$footer.Text = $footerText
$popupHeight = $footer.Bottom + 13
$form.ClientSize = New-Object System.Drawing.Size($popupWidth, $popupHeight)
$content.Size = New-Object System.Drawing.Size(($popupWidth - 2), ($popupHeight - 2))
$form.Location = New-Object System.Drawing.Point(
    ($workingArea.Right - $form.Width - $margin),
    ($workingArea.Bottom - $form.Height - $margin)
)

$dismiss = {
    Write-PopupFocusLog 'click' @{ can_focus = [bool]$canFocus; focus_uri = [string]$hookData.focus_uri }
    try {
        if ($canFocus) {
            # VS Code's extension host exports ELECTRON_RUN_AS_NODE=1. Passing
            # it to the vscode:// handler makes Code.exe reject --open-url.
            # Clear it only while launching the GUI; do not change user settings.
            $savedRunAsNode = $env:ELECTRON_RUN_AS_NODE
            try {
                [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process')
                $launched = Start-Process -FilePath ([string]$hookData.focus_uri) -PassThru
                Write-PopupFocusLog 'uri_launched' @{ process_id = $(if ($launched) { $launched.Id } else { $null }); inherited_run_as_node = $savedRunAsNode; launch_run_as_node = $env:ELECTRON_RUN_AS_NODE }
            }
            finally {
                [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $savedRunAsNode, 'Process')
            }
            # Close immediately after dispatching the focus request; do not wait for VS Code.
        }
    }
    catch {
        Write-PopupFocusLog 'uri_error' @{ error = $_.Exception.Message }
    }
    if (-not $form.IsDisposed) {
        $form.Close()
    }
}
$form.Add_Click($dismiss)
$content.Add_Click($dismiss)
$accent.Add_Click($dismiss)
$title.Add_Click($dismiss)
$topic.Add_Click($dismiss)
$body.Add_Click($dismiss)
$footer.Add_Click($dismiss)

$content.Controls.Add($footer)
$content.Controls.Add($body)
$content.Controls.Add($topic)
$content.Controls.Add($title)
$content.Controls.Add($accent)
$form.Controls.Add($content)

$routeTimer = $null
if ($Source -eq 'Codex' -and $Kind -eq 'done' -and $hookData.completion_token) {
    # Also accept a delayed TUI preview while the already-visible popup lives.
    $routeTimer = New-Object System.Windows.Forms.Timer
    $routeTimer.Interval = 250
    $routeTimer.Add_Tick({
        if ($script:canFocus) { $routeTimer.Stop(); return }
        $lateRoute = Read-CompletionRoute $hookData
        if ($lateRoute) {
            Set-CompletionRoute $hookData $lateRoute
            $script:canFocus = $true
            $footer.Text = if ($env:CODEX_NOTIFY_PREVIEW -eq '0') { 'Codex · 点击返回终端' } else { 'Codex · ' + $lateRoute.terminal_name + ' · 点击返回终端' }
            Write-PopupFocusLog 'completion_route_attached' @{ session_id = $hookData.session_id; focus_uri = $lateRoute.focus_uri }
            $routeTimer.Stop()
        }
    })
    $routeTimer.Start()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.Add_Tick({
    $timer.Stop()
    $form.Close()
})
$form.Add_Shown({
    Write-PopupFocusLog 'shown' @{ source = $Source; kind = $Kind; can_focus = [bool]$canFocus; focus_uri = [string]$hookData.focus_uri; electron_run_as_node = $env:ELECTRON_RUN_AS_NODE }
    [System.Media.SystemSounds]::Asterisk.Play()
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
if ($routeTimer) { $routeTimer.Stop(); $routeTimer.Dispose() }
$timer.Dispose()
$form.Dispose()

if ($hookData -and [string]$hookData.completion_token -match '^[0-9a-f-]{36}$') {
    foreach ($suffix in @('.json', '.route.json')) {
        try { [IO.File]::Delete((Join-Path (Get-CompletionDirectory) ($hookData.completion_token + $suffix))) } catch { }
    }
}
