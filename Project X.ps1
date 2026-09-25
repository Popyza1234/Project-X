# =============================================================================
#  PROJECT X   .   FIVEM OPTIMIZER + BOOSTER          (by Freebuff)
#
#  ONE FILE DOES EVERYTHING:
#    . double-click "Project X.bat"  (it asks for Administrator for you)
#    . [1] START  ->  tune Windows for FiveM, then open the booster window
#    . [2] RESET  ->  restore every change back to the baseline
#
#  The booster is this same file running with -Booster, in its own window.
#  It locks the timer resolution, raises the game priority, and restores every
#  original value when you close it.
#
#  English-only UI (no non-ASCII text besides the banner art) so the console
#  menu never breaks on encoding issues.
#
#  Backup file: C:\ProgramData\FreebuffGaming\strike-backup.json
#  Log file   : C:\ProgramData\FreebuffGaming\strike.log
#
#  Usage:  Project X.bat                (recommended - handles UAC for you)
#          powershell -ExecutionPolicy Bypass -File ".\Project X.ps1"
#          powershell -ExecutionPolicy Bypass -File ".\Project X.ps1" -Booster
#
#  CLI switches:
#    -Booster                     run the runtime booster instead of the menu
#    -Priority High|AboveNormal|RealTime    booster priority (default High)
#    -NoAffinity                  booster: leave the CPU affinity alone
#    -Preview                     show menu + machine status only (no changes)
#    -Apply <level>               low|medium|high|net|input|gpedit|fivem|clean
#    -Restore strike|old|all      restore from backup
#    -ResetDefaults               reset to Windows defaults for every touch point
#    -PowerPlan "name or guid"    power plan used by -ResetDefaults
#    -NoNicRestart                never restart the network adapter
#    -Verify                      print the live tuning check (read-only)
#    -Latency                     measure ping / jitter / packet loss (read-only)
#    -NoAnim                      skip the animations
# =============================================================================
[CmdletBinding()]
param(
    [switch]$NoAnim,
    [switch]$Preview,
    [switch]$Verify,
    [switch]$Latency,
    # NOTE: the empty string is listed in every ValidateSet on purpose, because
    # Invoke-Expression (irm <url> | iex) rejects a validated parameter whose
    # default is empty. Real values are still validated exactly as before.
    [ValidateSet('', 'low', 'medium', 'high', 'net', 'input', 'gpedit', 'fivem', 'clean')]
    [string]$Apply,
    [ValidateSet('', 'strike', 'old', 'all')]
    [string]$Restore,
    [switch]$ResetDefaults,
    [string]$PowerPlan = '',
    [switch]$NoNicRestart,
    [switch]$Booster,
    [ValidateSet('', 'High', 'AboveNormal', 'RealTime')]
    [string]$Priority = 'High',
    [switch]$NoAffinity
)

$script:Interactive = (-not $Apply) -and (-not $Booster)

# When the file is piped into iex ( irm <url> | iex ) there is no script file
# behind it. That changes how we can elevate and how the booster window opens,
# so the two cases are tracked here.
$script:SelfPath   = $PSCommandPath
$script:FromMemory = -not $PSCommandPath

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'PROJECT X  .  FIVEM OPTIMIZER' } catch { }

# ------------------------------- elevation -----------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Preview -and -not $Verify -and -not $Latency) {
    if ($script:FromMemory) {
        Write-Host ''
        Write-Host '  [!] Administrator rights are required for the tuning.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '      This copy was piped into iex, so it cannot relaunch itself.' -ForegroundColor Gray
        Write-Host '      Open PowerShell as Administrator (right-click -> Run as administrator)' -ForegroundColor Gray
        Write-Host '      and run the same command again.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '      Read-only modes work without admin:   -Preview   -Verify   -Latency' -ForegroundColor DarkGray
        exit 1
    }
    Write-Host ''
    Write-Host '  [!] Administrator rights are required - relaunching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:SelfPath + '"'))
    if ($Apply)         { $argList += @('-Apply', $Apply) }
    if ($Restore)       { $argList += @('-Restore', $Restore) }
    if ($ResetDefaults) { $argList += '-ResetDefaults' }
    if ($PowerPlan)     { $argList += @('-PowerPlan', ('"' + $PowerPlan + '"')) }
    if ($NoNicRestart)  { $argList += '-NoNicRestart' }
    if ($NoAnim)        { $argList += '-NoAnim' }
    if ($Booster)       { $argList += @('-Booster', '-Priority', $Priority) }
    if ($NoAffinity)    { $argList += '-NoAffinity' }
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs } catch { }
    exit
}

# --------------------------------- paths -------------------------------------
$BackupDir     = Join-Path $env:ProgramData 'FreebuffGaming'
$BackupFile    = Join-Path $BackupDir 'strike-backup.json'
$OldBackupFile = Join-Path $BackupDir 'backup.json'
$LogFile       = Join-Path $BackupDir 'strike.log'
if (-not (Test-Path $BackupDir)) { $null = New-Item -ItemType Directory -Path $BackupDir -Force }

# --------------------------------- state -------------------------------------
$script:RegBackups         = [ordered]@{ }
$script:SvcBackups         = [ordered]@{ }
$script:AdapterSnapshots   = @()
$script:QosPolicies        = @()
$script:DefenderExclusions = @()
$script:AppliedModules     = @()
$script:Power              = $null
$script:TcpGlobal          = $null

# Power settings (GUIDs are authoritative, aliases are a fallback for odd builds)
$script:PowerSettings = @(
    @{ Name = 'Processor max 100%';        GuidSub = '54533251-82be-4824-96c1-47b60b740d00'; GuidSet = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; AliasSub = 'SUB_PROCESSOR'; AliasSet = 'PROCTHROTTLEMAX'; Value = 100 },
    @{ Name = 'Processor min 5%';          GuidSub = '54533251-82be-4824-96c1-47b60b740d00'; GuidSet = '893dee8e-2bef-41e0-89c6-b55d0929964c'; AliasSub = 'SUB_PROCESSOR'; AliasSet = 'PROCTHROTTLEMIN'; Value = 5 },
    @{ Name = 'Boost mode Aggressive';     GuidSub = '54533251-82be-4824-96c1-47b60b740d00'; GuidSet = 'be337238-0d82-4146-a960-4f3749d470c7'; AliasSub = 'SUB_PROCESSOR'; AliasSet = 'PERFBOOSTMODE';  Value = 2 },
    @{ Name = 'Core parking 100%';         GuidSub = '54533251-82be-4824-96c1-47b60b740d00'; GuidSet = '0cc5b647-c1df-4637-891a-dec35c318583'; AliasSub = 'SUB_PROCESSOR'; AliasSet = 'CPMINCORES';     Value = 100 },
    @{ Name = 'USB selective suspend off'; GuidSub = '2a737441-1930-4402-8d77-b2bebba308a3'; GuidSet = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; AliasSub = '';              AliasSet = '';               Value = 0 },
    @{ Name = 'PCIe ASPM off';             GuidSub = '501a4d13-42af-4429-9fd1-a8218c268e20'; GuidSet = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; AliasSub = 'SUB_PCIEXPRESS'; AliasSet = 'ASPM';           Value = 0 },
    @{ Name = 'Disk idle timeout 0';       GuidSub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; GuidSet = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; AliasSub = 'SUB_DISK';       AliasSet = 'DISKIDLE';       Value = 0 }
)

# NIC driver keywords related to power saving / latency
$script:AdapterTargets = @(
    @{ K = 'InterruptModeration';     Num = 0; Str = 'Disabled' },
    @{ K = 'EnergyEfficientEthernet'; Num = 0; Str = 'Disabled' },
    @{ K = 'EEE';                     Num = 0; Str = 'Disabled' },
    @{ K = 'EnableGreenEthernet';     Num = 0; Str = 'Disabled' },
    @{ K = 'GigaLite';                Num = 0; Str = 'Disabled' },
    @{ K = 'PowerSavingMode';         Num = 0; Str = 'Disabled' },
    @{ K = 'AutoDisableGigabit';      Num = 0; Str = 'Disabled' },
    @{ K = 'FlowControl';             Num = 0; Str = 'Disabled' },
    @{ K = 'SelectiveSuspend';        Num = 0; Str = 'Disabled' },
    @{ K = 'UltraLowPowerMode';       Num = 0; Str = 'Disabled' },
    @{ K = 'ReduceSpeedOnPowerDown';  Num = 0; Str = 'Disabled' }
)

$QosRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\QoS'

# ------------------------------- banner art ----------------------------------
# ASCII-shadow style glyphs, all cells exactly 9 characters wide
$script:ArtMap = @{
    ' ' = [char]0x20
    '#' = [char]0x2588
    'F' = [char]0x2554
    'T' = [char]0x2557
    'L' = [char]0x255A
    'J' = [char]0x255D
    '=' = [char]0x2550
    'I' = [char]0x2551
}

# banner art kept as an ASCII palette; Get-ArtLines expands it at run time
$script:GlyphPattern = @{
    'C' = @(' ######T ', '##F====J ', '##I      ', '##I      ', 'L######T ', ' L=====J ')
    'E' = @('#######T ', '##F====J ', '#####T   ', '##F==J   ', '#######T ', 'L======J ')
    'J' = @('     ##T ', '     ##I ', '     ##I ', '##   ##I ', 'L#####FJ ', ' L====J  ')
    'O' = @(' ######T ', '##F===##T', '##I   ##I', '##I   ##I', 'L######FJ', ' L=====J ')
    'P' = @('######T  ', '##F==##T ', '######FJ ', '##F===J  ', '##I      ', 'L=J      ')
    'R' = @('######T  ', '##F==##T ', '######FJ ', '##F==##T ', '##I  ##I ', 'L=J  L=J ')
    'T' = @('########T', 'L==##F==J', '   ##I   ', '   ##I   ', '   ##I   ', '   L=J   ')
    'X' = @('##T  ##T ', 'L##T##FJ ', ' L###FJ  ', ' ##F##T  ', '##FJ ##T ', 'L=J  L=J ')
}

# per-row colour ramps: bright on top, darker at the bottom gives the block
# letters a slight engraved / 3D look
$script:WhiteRamp = @('White', 'White', 'White', 'Gray', 'Gray', 'DarkGray')
$script:RedRamp   = @('Red', 'Red', 'Red', 'DarkRed', 'DarkRed', 'DarkRed')

# block and box characters are referenced by code point so no stray characters
# end up in the middle of the file
$script:FullBlock  = [string][char]0x2588   # full block
$script:LightBlock = [string][char]0x2591   # light shade
$script:BoxRule    = [string][char]0x2500   # horizontal rule

function Test-CanAnimate {
    # the cursor tricks need a real, reasonably wide console; when the window is
    # small or the host has no console handle we print the banner plainly
    try {
        if ([Console]::WindowWidth -lt 84 -or [Console]::BufferWidth -lt 84) { return $false }
        $null = [Console]::CursorTop
        return $true
    } catch { return $false }
}

function Set-WideConsole {
    # the banner is 74 columns wide, so widen a small window once at start-up
    try { if ([Console]::WindowWidth -lt 84) { [Console]::SetWindowSize(100, [Console]::WindowHeight) } } catch { }
}

function Write-Rule {
    param([int]$Width = 58, [string]$Color = 'DarkCyan')
    Write-Host ('  ' + ($script:BoxRule * $Width)) -ForegroundColor $Color
}

function Write-Typed {
    param([string]$Text, [string]$Color = 'DarkGray', [int]$DelayMs = 9)
    foreach ($ch in $Text.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor $Color
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-Host ''
}

function Write-BarSegment {
    param([string]$Label, [int]$Filled, [int]$Width, [switch]$Drain)
    Write-Host ('   ' + $Label.PadRight(9) + ' [') -NoNewline -ForegroundColor DarkGray
    if ($Filled -lt 0) { $Filled = 0 }
    if ($Filled -gt $Width) { $Filled = $Width }
    $body = $Filled - 1
    if ($body -gt 0) { Write-Host ($script:FullBlock * $body) -NoNewline -ForegroundColor Cyan }
    if ($Filled -gt 0) {
        $head = 'White'
        if ($Drain) { $head = 'Yellow' }
        Write-Host $script:FullBlock -NoNewline -ForegroundColor $head
    }
    if ($Filled -lt $Width) { Write-Host ($script:LightBlock * ($Width - $Filled)) -NoNewline -ForegroundColor DarkGray }
    Write-Host ']' -NoNewline -ForegroundColor DarkGray
}

function Get-ArtLines {
    # the art is stored as an ASCII palette in $script:GlyphPattern and expanded
    # to block characters here, so this whole file stays plain ASCII and can be
    # piped straight into iex without any encoding trouble
    param([string]$Text)
    $rows = @('', '', '', '', '', '')
    foreach ($ch in $Text.ToCharArray()) {
        $key = [string]$ch
        if (-not $script:GlyphPattern.ContainsKey($key)) { continue }
        $g = $script:GlyphPattern[$key]
        for ($i = 0; $i -lt 6; $i++) {
            $line = ''
            foreach ($c in $g[$i].ToCharArray()) {
                $sym = [string]$c
                if ($script:ArtMap.ContainsKey($sym)) { $line += $script:ArtMap[$sym] } else { $line += $sym }
            }
            $rows[$i] += $line
        }
    }
    return $rows
}

function Write-BannerRow {
    param([string[]]$Left, [string[]]$Right, [int]$Row, [int]$Indent = 2)
    Write-Host (' ' * $Indent) -NoNewline
    Write-Host $Left[$Row]  -NoNewline -ForegroundColor $script:WhiteRamp[$Row]
    Write-Host $Right[$Row] -ForegroundColor $script:RedRamp[$Row]
}

function Show-Banner {
    param([switch]$Animate, [string]$Mode = 'OPTIMIZER')
    $white = Get-ArtLines 'PROJECT'
    $red   = Get-ArtLines 'X'
    for ($i = 0; $i -lt 6; $i++) {
        Write-BannerRow -Left $white -Right $red -Row $i
        if ($Animate) { Start-Sleep -Milliseconds 55 }
    }
    # brand line: PROJECT in white, the X in red
    Write-Host '   P R O J E C T ' -NoNewline -ForegroundColor White
    Write-Host 'X' -NoNewline -ForegroundColor Red
    Write-Host ('   -   F I V E M   ' + (($Mode.ToUpper().ToCharArray()) -join ' ')) -ForegroundColor DarkGray
    if ($Mode -eq 'BOOSTER') {
        Write-Host '   runtime boost while you play  .  closes cleanly  .  restores everything' -ForegroundColor DarkGray
    } else {
        Write-Host '   lower input lag  .  lower ping  .  smoother frames  .  real effects' -ForegroundColor DarkGray
    }
}

function Show-XGlow {
    # pulses the red X a few times so the logo feels alive
    param([string[]]$Red, [int]$Top, [int]$Left = 65)
    if ($Top -lt 0 -or -not (Test-CanAnimate)) { return }
    try {
        $saveTop  = [Console]::CursorTop
        $saveLeft = [Console]::CursorLeft
        foreach ($c in @('DarkRed', 'Red', 'White', 'Red')) {
            for ($i = 0; $i -lt 6; $i++) {
                [Console]::SetCursorPosition($Left, $Top + $i)
                Write-Host $Red[$i] -NoNewline -ForegroundColor $c
            }
            Start-Sleep -Milliseconds 80
        }
        for ($i = 0; $i -lt 6; $i++) {
            [Console]::SetCursorPosition($Left, $Top + $i)
            Write-Host $Red[$i] -NoNewline -ForegroundColor $script:RedRamp[$i]
        }
        [Console]::SetCursorPosition($saveLeft, $saveTop)
    } catch { return }
}

# ------------------------------- animations ----------------------------------
function Show-GlitchTitle {
    # slams the brand line in with a short horizontal shake
    param([int]$Row = -1)
    if ($Row -lt 0 -or -not (Test-CanAnimate)) { return }
    try {
        $saveTop  = [Console]::CursorTop
        $saveLeft = [Console]::CursorLeft
    } catch { return }
    foreach ($off in @(0, 1, 2, 3, 2, 1, 0, 1, 0, 0)) {
        try {
            [Console]::SetCursorPosition(0, $Row)
            Write-Host ('   P R O J E C T ' + (' ' * $off)) -NoNewline -ForegroundColor White
            Write-Host 'X' -NoNewline -ForegroundColor Red
            Write-Host '   -   F I V E M   O P T I M I Z E R' -NoNewline -ForegroundColor DarkGray
            Write-Host (' ' * 16)
        } catch { return }
        Start-Sleep -Milliseconds 42
    }
    try { [Console]::SetCursorPosition($saveLeft, $saveTop) } catch { }
}

function Show-BootSequence {
    # fast boot log so start-up feels like a real power-up
    param([int]$DelayMs = 45)
    $lines = @(
        @{ T = 'loading kernel power profile';  D = 14 },
        @{ T = 'patching scheduler quantum';    D = 12 },
        @{ T = 'arming network path';           D = 16 },
        @{ T = 'pipelining mouse and keyboard'; D = 14 },
        @{ T = 'locking timer resolution';      D = 15 }
    )
    foreach ($l in $lines) {
        Write-Host ('   > ' + $l.T + ' ') -NoNewline -ForegroundColor Gray
        for ($i = 0; $i -lt $l.D; $i++) {
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Milliseconds ([Math]::Max(2, [int]($DelayMs / 5)))
        }
        Write-Host ' [' -NoNewline -ForegroundColor DarkGray
        Write-Host 'OK' -NoNewline -ForegroundColor Green
        Write-Host ']' -ForegroundColor DarkGray
        Start-Sleep -Milliseconds $DelayMs
    }
}

function Show-Stamp {
    # boxed status slam, optionally flashing red then settling
    param([string]$Text = 'SYSTEM ARMED', [string]$Color = 'Green', [switch]$Flash)
    $spaced = ($Text.ToCharArray()) -join ' '
    $inner = $spaced.Length + 6
    $bar = '  +' + ('=' * $inner) + '+'
    $mid = '  |  ' + $spaced.PadRight($inner - 4) + '  |'
    $frames = @($Color)
    if ($Flash -and (Test-CanAnimate)) { $frames = @('DarkRed', 'Red', 'Yellow', $Color) }
    for ($f = 0; $f -lt $frames.Count; $f++) {
        if ($f -gt 0) { try { [Console]::SetCursorPosition(0, [Console]::CursorTop - 3) } catch { } }
        Write-Host $bar -ForegroundColor $frames[$f]
        Write-Host $mid -ForegroundColor $frames[$f]
        Write-Host $bar -ForegroundColor $frames[$f]
        Start-Sleep -Milliseconds 90
    }
}

function Show-Intro {
    param([switch]$NoGlow)
    Clear-Host
    $red = Get-ArtLines 'X'
    $top = -1
    if (Test-CanAnimate) { try { $top = [Console]::CursorTop } catch { $top = -1 } }
    Show-Banner -Animate
    if (-not $NoGlow -and $top -ge 0) {
        Show-XGlow -Red $red -Top $top
        Show-GlitchTitle -Row ($top + 6)
    }
    Write-Host ''
    $total = 34
    for ($i = 0; $i -le $total; $i++) {
        Write-Host "`r" -NoNewline
        Write-BarSegment -Label 'SCANNING' -Filled $i -Width $total
        $pct = ([int](($i / $total) * 100)).ToString().PadLeft(3)
        Write-Host ('  ' + $pct + '%') -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 18
    }
    Write-Host ''
    Show-BootSequence
    Show-Stamp -Text 'SYSTEM ARMED' -Color 'Green' -Flash
    Write-Typed -Text '   loading your FiveM profile...' -Color 'DarkGray' -DelayMs 6
    Start-Sleep -Milliseconds 140
}

function Show-ProgressBar {
    param([int]$Index, [int]$Total, [string]$Label)
    $width = 28
    $filled = [int](($Index / $Total) * $width)
    $pct = ([int](($Index / $Total) * 100)).ToString().PadLeft(3)
    Write-Host ''
    Write-BarSegment -Label 'STEP' -Filled $filled -Width $width
    Write-Host ('   ' + $pct + '%   step ' + $Index + ' of ' + $Total) -ForegroundColor DarkCyan
    Write-Host ('   >> ' + $Label) -ForegroundColor Yellow
}

function Show-DrainBar {
    param([string]$Label)
    $width = 28
    for ($i = $width; $i -ge 0; $i--) {
        Write-Host "`r" -NoNewline
        Write-BarSegment -Label $Label -Filled $i -Width $width -Drain
        Start-Sleep -Milliseconds 20
    }
    Write-Host "`r" -NoNewline
    Write-BarSegment -Label $Label -Filled 0 -Width $width -Drain
    Write-Host '   done' -ForegroundColor Green
}

# ------------------------------- logging -------------------------------------
function Add-Log {
    param([string]$m)
    try { Add-Content -Path $LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}
function Head { param([string]$m) Write-Host ''; Write-Host ('  >> ' + $m) -ForegroundColor Yellow; Write-Rule 58; Add-Log ('== ' + $m) }
function Ok   { param([string]$m) Write-Host ('   [OK] ' + $m) -ForegroundColor Green;   Add-Log ('[OK] ' + $m) }
function Warn { param([string]$m) Write-Host ('   [!]  ' + $m) -ForegroundColor Yellow;  Add-Log ('[!] ' + $m) }
function Err  { param([string]$m) Write-Host ('   [x]  ' + $m) -ForegroundColor Red;     Add-Log ('[x] ' + $m) }
function Info { param([string]$m) Write-Host ('   -    ' + $m) -ForegroundColor DarkGray; Add-Log ('- ' + $m) }

# ----------------------------- registry helpers ------------------------------
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $val = $item.GetValue($Name)
        if ($null -eq $val) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
        return [pscustomobject]@{ Exists = $true; Value = $val; Kind = $item.GetValueKind($Name).ToString() }
    } catch {
        return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null }
    }
}

function Set-RegWithBackup {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        $bk = Get-RegValue -Path $Path -Name $Name
        $key = "$Path\$Name"
        if (-not $script:RegBackups.Contains($key)) {
            $script:RegBackups[$key] = [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $bk.Exists; Value = $bk.Value; Kind = $bk.Kind }
        }
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force
        Save-Backup      # save immediately so an interrupted run still has the baseline
    } catch { Err ('failed to write ' + $Path + '  ->  ' + $Name) }
}

# raw write / delete (used only by RESET, never captured into the backup)
function Set-RegRaw {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force
    } catch { }
}
function Remove-RegRaw {
    param([string]$Path, [string]$Name)
    try { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue } catch { }
}

function Restore-RegEntry {
    param($Entry)
    if (-not $Entry.Path -or -not $Entry.Name) { return }
    if ($Entry.Exists) {
        if (-not (Test-Path -LiteralPath $Entry.Path)) { $null = New-Item -Path $Entry.Path -Force }
        $null = New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Value $Entry.Value -PropertyType $Entry.Kind -Force
    } else {
        Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
    }
}

# ----------------------------- power helpers ---------------------------------
function Get-ActiveSchemeGuid {
    $out = (& powercfg /getactivescheme 2>$null) | Out-String
    if ($out -match '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
    return $null
}

function Get-PowerIndexes {
    param([string]$Scheme, [string]$Sub, [string]$Setting)
    $ac = $null; $dc = $null
    # visible settings can be read with powercfg
    $out = (& powercfg /query $Scheme $Sub $Setting 2>$null) | Out-String
    $hexes = @([regex]::Matches($out, '(?m)0x[0-9a-fA-F]{1,16}\s*$') | ForEach-Object { [Convert]::ToInt64($_.Value.Substring(2).Trim(), 16) })
    if ($hexes.Count -ge 2) { $ac = $hexes[$hexes.Count - 2]; $dc = $hexes[$hexes.Count - 1] }
    # hidden settings (boost mode / core parking / disk idle) must come from the plan registry
    if ($null -eq $ac) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Scheme\$Sub\$Setting"
        $ac = (Get-ItemProperty -Path $p -Name 'ACSettingIndex' -ErrorAction SilentlyContinue).ACSettingIndex
        $dc = (Get-ItemProperty -Path $p -Name 'DCSettingIndex' -ErrorAction SilentlyContinue).DCSettingIndex
    }
    return [pscustomobject]@{ AC = $ac; DC = $dc }
}

function Get-TcpGlobalSnapshot {
    $out = (& netsh int tcp show global 2>$null) | Out-String
    $map = New-Object System.Management.Automation.PSObject
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') {
            $map | Add-Member -MemberType NoteProperty -Name ($Matches[1].Trim()) -Value ($Matches[2].Trim()) -Force
        }
    }
    return $map
}

function Invoke-NetshOk {
    param([string[]]$NetshArgs, [string]$Label)
    $null = (& netsh @NetshArgs 2>$null) | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok $Label; return $true }
    Warn ($Label + '  (not supported - skipped)')
    return $false
}

# ----------------------------- misc helpers ----------------------------------
function Get-FiveMExePaths {
    $out = @()
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'FiveM%'" -ErrorAction SilentlyContinue)) {
        if ($p.ExecutablePath) { $out += $p.ExecutablePath }
    }
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'FiveM') }
    $roots += @('C:\Program Files\FiveM', 'C:\Program Files (x86)\FiveM')
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $out += @(Get-ChildItem -Path $r -Recurse -Depth 2 -Include 'FiveM.exe', 'FiveM_b*_GTAProcess.exe', 'GTA5.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 8 -ExpandProperty FullName)
    }
    return @($out | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)
}

function Get-AdapterSnapshot {
    param($Adapter, $AllProps)
    $propSnaps = @()
    $seen = @{ }
    foreach ($t in $script:AdapterTargets) {
        foreach ($mp in @($AllProps | Where-Object { $_.RegistryKeyword -eq $t.K -or $_.RegistryKeyword -eq ('*' + $t.K) })) {
            if ($seen.ContainsKey($mp.RegistryKeyword)) { continue }
            $seen[$mp.RegistryKeyword] = $true
            $propSnaps += [pscustomobject]@{ RegistryKeyword = $mp.RegistryKeyword; RegistryValue = $mp.RegistryValue }
        }
    }
    $rss = $null; $rsc4 = $null; $rsc6 = $null; $pm = $null; $mtu = $null; $dns = @()
    try { $rss = (Get-NetAdapterRss -Name $Adapter.Name -ErrorAction Stop).Enabled } catch { }
    try { $r = Get-NetAdapterRsc -Name $Adapter.Name -ErrorAction Stop; $rsc4 = $r.IPv4Enabled; $rsc6 = $r.IPv6Enabled } catch { }
    try {
        $pm = (Get-NetAdapterPowerManagement -Name $Adapter.Name -ErrorAction Stop).AllowComputerToTurnOffDevice
        if ($null -ne $pm) { $pm = $pm.ToString() }
    } catch { }
    try { $mtu = (Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).NlMtu } catch { }
    try { $dns = @((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
    return [pscustomobject]@{
        Name        = $Adapter.Name
        ifIndex     = $Adapter.ifIndex
        Mtu         = $mtu
        RssEnabled  = $rss
        RscIPv4     = $rsc4
        RscIPv6     = $rsc6
        AllowPmeOff = $pm
        Dns         = $dns
        AdvProps    = $propSnaps
    }
}

function Set-AdapterKeywordOptimized {
    param([string]$AdapterName, [string]$Keyword)
    foreach ($v in @(0, 'Disabled')) {
        try {
            Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $Keyword -RegistryValue $v -NoRestart -ErrorAction Stop
            return $true
        } catch { }
    }
    return $false
}

function Set-ServiceStartWithBackup {
    param([string]$Name, [string]$StartupType)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Warn ('service not found: ' + $Name); return }
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $cur = (Get-ItemProperty -Path $regPath -Name 'Start' -ErrorAction SilentlyContinue).Start
    $key = 'SVC:' + $Name
    if ($null -ne $cur -and -not $script:SvcBackups.Contains($key)) {
        $script:SvcBackups[$key] = [pscustomobject]@{ Name = $Name; Start = [int]$cur }
    }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Ok ($Name + '  ->  ' + $StartupType)
    } catch { Warn ($Name + '  ->  could not change') }
    # NOTE: we do not stop services here - some (Ndu) cannot be stopped and
    # would hang the script. They stop after the next reboot.
    Save-Backup
}

# ------------------------------ backup store ---------------------------------
function Save-Backup {
    $backup = [pscustomobject]@{
        Created     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Reg         = @($script:RegBackups.Values)
        Services    = @($script:SvcBackups.Values)
        Power       = $script:Power
        TcpGlobal   = $script:TcpGlobal
        Adapters    = @($script:AdapterSnapshots)
        QosPolicies = @($script:QosPolicies)
        DefExcl     = @($script:DefenderExclusions)
        Modules     = @($script:AppliedModules)
    }
    $backup | ConvertTo-Json -Depth 8 | Set-Content -Path $BackupFile -Encoding UTF8
    Add-Log ('backup saved: ' + $BackupFile)
}

function Load-Backup {
    if (-not (Test-Path $BackupFile)) { return }
    try { $b = Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if ($b.Reg) {
        foreach ($e in @($b.Reg)) {
            if ($e.Path -and $e.Name) {
                $k = "$($e.Path)\$($e.Name)"
                if (-not $script:RegBackups.Contains($k)) { $script:RegBackups[$k] = $e }
            }
        }
    }
    if ($b.Services) {
        foreach ($e in @($b.Services)) {
            $k = 'SVC:' + $e.Name
            if (-not $script:SvcBackups.Contains($k)) { $script:SvcBackups[$k] = $e }
        }
    }
    if ($b.Power -and -not $script:Power)         { $script:Power = $b.Power }
    if ($b.TcpGlobal -and -not $script:TcpGlobal) { $script:TcpGlobal = $b.TcpGlobal }
    if ($b.Adapters) {
        foreach ($a in @($b.Adapters)) {
            if (-not (@($script:AdapterSnapshots | Where-Object { $_.Name -eq $a.Name }).Count)) { $script:AdapterSnapshots += $a }
        }
    }
    if ($b.QosPolicies) {
        foreach ($q in @($b.QosPolicies)) {
            if (-not (@($script:QosPolicies | Where-Object { $_.Name -eq $q.Name }).Count)) { $script:QosPolicies += $q }
        }
    }
    if ($b.DefExcl) {
        foreach ($d in @($b.DefExcl)) { if ($script:DefenderExclusions -notcontains $d) { $script:DefenderExclusions += $d } }
    }
    if ($b.Modules) {
        foreach ($m in @($b.Modules)) { if ($script:AppliedModules -notcontains $m) { $script:AppliedModules += $m } }
    }
}

# =============================================================================
#  TUNING MODULES  (all of them do real, measurable things)
# =============================================================================
function Invoke-PowerTweaks {
    Head 'POWER - remove power saving that causes frame dips'
    $orig = Get-ActiveSchemeGuid
    if (-not $script:Power) {
        $target = $null; $created = $false
        if ($orig) {
            # reuse an existing Ultimate Performance plan instead of adding a new one
            $listOut = ((& powercfg /list 2>$null) | Out-String)
            $existingUltimate = $null
            foreach ($line in ($listOut -split "`r?`n")) {
                if ($line -match '(?i)ultimate') {
                    if ($line -match '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $existingUltimate = $Matches[1]; break }
                }
            }
            if ($existingUltimate) {
                $target = $existingUltimate
                Info ('reusing existing Ultimate Performance plan: ' + $existingUltimate)
            } else {
                $dup = (& powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null) | Out-String
                if ($dup -match '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $target = $Matches[1]; $created = $true }
                else { $target = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
            }
        } else { Warn 'could not read the active power plan - skipping power tweaks' }

        $idx = New-Object System.Management.Automation.PSObject
        if ($target -and -not $created) {
            foreach ($s in $script:PowerSettings) {
                $pi = Get-PowerIndexes -Scheme $target -Sub $s.GuidSub -Setting $s.GuidSet
                $idx | Add-Member -MemberType NoteProperty -Name ($s.GuidSub + '\' + $s.GuidSet) -Value $pi -Force
            }
        }
        $script:Power = [pscustomobject]@{ OriginalScheme = $orig; TargetScheme = $target; CreatedNewScheme = $created; OriginalIndexes = $idx }
    }
    if ($script:Power -and $script:Power.TargetScheme) {
        $null = & powercfg /setactive $script:Power.TargetScheme
        $failed = @()
        foreach ($s in $script:PowerSettings) {
            foreach ($mode in @('AC', 'DC')) {
                if ($mode -eq 'AC') { $null = (& powercfg /setacvalueindex $script:Power.TargetScheme $s.GuidSub $s.GuidSet ([int]$s.Value) 2>$null) }
                else                { $null = (& powercfg /setdcvalueindex $script:Power.TargetScheme $s.GuidSub $s.GuidSet ([int]$s.Value) 2>$null) }
                $okSet = ($LASTEXITCODE -eq 0)
                if (-not $okSet -and $s.AliasSub -and $s.AliasSet) {
                    if ($mode -eq 'AC') { $null = (& powercfg /setacvalueindex $script:Power.TargetScheme $s.AliasSub $s.AliasSet ([int]$s.Value) 2>$null) }
                    else                { $null = (& powercfg /setdcvalueindex $script:Power.TargetScheme $s.AliasSub $s.AliasSet ([int]$s.Value) 2>$null) }
                    $okSet = ($LASTEXITCODE -eq 0)
                }
                if (-not $okSet) { $failed += ($s.Name + ' [' + $mode + ']') }
            }
        }
        $null = & powercfg /setactive $script:Power.TargetScheme
        if ($script:Power.CreatedNewScheme) { Ok 'created and activated Ultimate Performance' } else { Ok 'activated Ultimate Performance' }
        if ($failed.Count -eq 0) { Ok ('all ' + $script:PowerSettings.Count + ' power settings applied (CPU boost / core parking / USB / PCIe / disk)') }
        else { Warn ('unsupported on this machine (skipped): ' + (($failed | Sort-Object -Unique) -join ', ')) }
    }
    Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 'DWord'
    Ok 'Power Throttling disabled (background work cannot throttle the game)'
    Save-Backup
}

function Invoke-InputTweaks {
    param([switch]$Queues)
    Head 'INPUT - mouse and keyboard response'
    Set-RegWithBackup 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-RegWithBackup 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-RegWithBackup 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    try {
        Add-Type -Namespace ProjectX -Name Spi -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint a, uint b, int[] c, uint d);' -ErrorAction Stop
        $null = [ProjectX.Spi]::SystemParametersInfo(0x0004, 0, [int[]]@(0, 0, 0), 3)
        Ok 'mouse acceleration OFF right now (1:1 raw aim)'
    } catch { Warn 'pointer API call failed (applies after sign-out) - registry value is still set' }
    Set-RegWithBackup 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0'  'String'
    Set-RegWithBackup 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
    Ok 'keyboard repeat rate max / delay min'
    Set-RegWithBackup 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
    Ok 'MenuShowDelay = 0 (UI reacts instantly)'
    Set-RegWithBackup 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    Set-RegWithBackup 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Ok 'Filter Keys / Sticky Keys popups OFF (no mid-game interruptions)'
    if ($Queues) {
        Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' 20 'DWord'
        Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' 16 'DWord'
        Ok 'mouse/keyboard driver queues shortened (effective after reboot)'
    }
    Save-Backup
}

function Invoke-GameCoreTweaks {
    Head 'GAME / SYSTEM - kill background recording and stutter sources'
    Set-RegWithBackup 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord'
    Set-RegWithBackup 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 'DWord'
    Ok 'Game DVR / background capture OFF'
    Set-RegWithBackup 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord'
    Set-RegWithBackup 'HKCU:\SOFTWARE\Microsoft\GameBar' 'ShowStartupPanel' 0 'DWord'
    Set-RegWithBackup 'HKCU:\SOFTWARE\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 'DWord'
    Ok 'Game Mode ON / Game Bar overlay OFF'
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegWithBackup $sp 'NetworkThrottlingIndex' ([Int32]-1) 'DWord'
    Set-RegWithBackup $sp 'SystemResponsiveness' 0 'DWord'
    Ok 'SystemResponsiveness = 0 / network throttling disabled'
    $g = $sp + '\Tasks\Games'
    Set-RegWithBackup $g 'GPU Priority' 8 'DWord'
    Set-RegWithBackup $g 'Priority' 6 'DWord'
    Set-RegWithBackup $g 'Scheduling Category' 'High' 'String'
    Set-RegWithBackup $g 'SFIO Priority' 'High' 'String'
    Ok 'MMCSS Games task: GPU Priority 8 / Priority 6 / High'
    Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 'DWord'
    Ok 'Win32PrioritySeparation = 38 (foreground game wins CPU time)'
    Set-RegWithBackup 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 'DWord'
    Ok 'UWP background apps disabled'
    Save-Backup
}

function Invoke-TcpBaseTweaks {
    Head 'NETWORK - TCP base (remove packet waiting / delays)'
    if (-not $script:TcpGlobal) { $script:TcpGlobal = Get-TcpGlobalSnapshot }
    $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal') 'Auto-Tuning = normal'
    $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'timestamps=disabled') 'TCP timestamps = off'
    $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'rss=enabled') 'RSS = on'
    $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'ecncapability=disabled') 'ECN = off'
    $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'rsc=disabled') 'RSC = off (less latency)'
    $ifRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $ifKeys = @(Get-ChildItem -Path $ifRoot -ErrorAction SilentlyContinue)
    foreach ($k in $ifKeys) {
        $p = ($k.Name) -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        Set-RegWithBackup $p 'TcpAckFrequency' 1 'DWord'
        Set-RegWithBackup $p 'TCPNoDelay' 1 'DWord'
    }
    Ok ('Nagle algorithm disabled on ' + $ifKeys.Count + ' interface(s)')
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 'DWord'
    Ok 'QoS: limit reservable bandwidth = 0%'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1 'DWord'
    Ok 'Delivery Optimization = LAN only (stop uploading updates while playing)'
    Save-Backup
}

function Set-AdapterBufferMax {
    # tries descending values and READS BACK to confirm the driver accepted one,
    # so we never report a change that did not actually happen
    param([string]$AdapterName, [string]$Keyword)
    $candidates = @(2048, 1024, 512)
    if ($Keyword -eq '*TransmitBuffers') { $candidates = @(1024, 512, 256) }
    $cur = 0
    try {
        $p = Get-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $Keyword -ErrorAction Stop
        $cur = [int]@($p.RegistryValue)[0]
    } catch { return $false }
    foreach ($c in $candidates) {
        if ($c -le $cur) { break }
        try {
            Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $Keyword -RegistryValue $c -NoRestart -ErrorAction Stop
            $chk = Get-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $Keyword -ErrorAction Stop
            if ([int]@($chk.RegistryValue)[0] -eq $c) { return $true }
        } catch { }
    }
    return $false
}

function Invoke-LatencyHardening {
    Head 'NETWORK - latency hardening (delayed ACK, heuristics, NIC buffers)'
    $ifRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $ifKeys = @(Get-ChildItem -Path $ifRoot -ErrorAction SilentlyContinue)
    foreach ($k in $ifKeys) {
        $p = ($k.Name) -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        Set-RegWithBackup $p 'TcpDelAckTicks' 0 'DWord'
        Set-RegWithBackup $p 'TcpAckFrequency' 1 'DWord'
        Set-RegWithBackup $p 'TCPNoDelay' 1 'DWord'
    }
    Ok ('delayed ACK OFF + Nagle OFF on ' + $ifKeys.Count + ' interface(s)')
    Ok 'small game packets leave the NIC immediately instead of waiting to be batched'
    # read first, only change what is really off-target, and say so honestly
    $hState = ''
    $hOut = ((& netsh int tcp show heuristics 2>$null) | Out-String)
    foreach ($line in ($hOut -split '\r?\n')) {
        if ($line -match ':\s*(enabled|disabled)\s*$') { $hState = $Matches[1] }
    }
    if ($hState -eq 'enabled') { $null = Invoke-NetshOk @('int', 'tcp', 'set', 'heuristics', 'disabled') 'TCP window-scaling heuristics = off' }
    elseif ($hState -eq 'disabled') { Info 'TCP window-scaling heuristics already off - nothing to change' }
    else { Info 'heuristics state not readable on this build - left untouched' }
    $g = Get-TcpGlobalSnapshot
    $auto = ''; $rss = ''
    foreach ($prop in $g.PSObject.Properties) {
        if ($prop.Name -like '*Auto-Tuning*') { $auto = [string]$prop.Value }
        if ($prop.Name -like '*Scaling State*') { $rss = [string]$prop.Value }
    }
    if ($auto.Trim().ToLower() -ne 'normal') { $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal') 'Receive window auto-tuning = normal' }
    else { Info 'receive window auto-tuning already normal - nothing to change' }
    if ($rss.Trim().ToLower() -ne 'enabled') { $null = Invoke-NetshOk @('int', 'tcp', 'set', 'global', 'rss=enabled') 'RSS = on' }
    else { Info 'RSS already on - nothing to change' }
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($ad in $adapters) {
        $n = 0
        if (Set-AdapterBufferMax -AdapterName $ad.Name -Keyword '*ReceiveBuffers') { $n++ }
        if (Set-AdapterBufferMax -AdapterName $ad.Name -Keyword '*TransmitBuffers') { $n++ }
        if ($n -gt 0) { Ok ($ad.Name + ': NIC receive/transmit buffers raised to maximum') }
        else { Info ($ad.Name + ': NIC buffers already at maximum') }
    }
    Info 'NIC buffer changes take effect after the adapter restarts (or a reboot)'
    Save-Backup
}

function Invoke-NicTweaks {
    param([switch]$Dns)
    Head 'NETWORK - adapter tuning (steady ping, fewer spikes)'
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) { Warn 'no connected network adapter found'; return }
    foreach ($ad in $adapters) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue)
        if (-not (@($script:AdapterSnapshots | Where-Object { $_.Name -eq $ad.Name }).Count)) {
            $script:AdapterSnapshots += (Get-AdapterSnapshot -Adapter $ad -AllProps $props)
        }
        try { Set-NetAdapterRss -Name $ad.Name -Enabled $true -ErrorAction Stop } catch { }
        try { Disable-NetAdapterRsc -Name $ad.Name -ErrorAction Stop; Ok ($ad.Name + ': RSC off') } catch { }
        try {
            Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Unsupported -ErrorAction Stop
            Ok ($ad.Name + ': Windows cannot power down the adapter when idle')
        } catch { }
        $n = 0
        foreach ($t in $script:AdapterTargets) {
            foreach ($kp in @($props | Where-Object { $_.RegistryKeyword -eq $t.K -or $_.RegistryKeyword -eq ('*' + $t.K) })) {
                if (Set-AdapterKeywordOptimized -AdapterName $ad.Name -Keyword $kp.RegistryKeyword) { $n++ }
            }
        }
        if ($n -gt 0) { Ok ($ad.Name + ': interrupt moderation / EEE / green ethernet / flow control off (' + $n + ' entries)') }
        try { Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -NlMtuBytes 1500 -ErrorAction Stop; Ok ($ad.Name + ': MTU = 1500') } catch { }
        if ($Dns) {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses @('1.1.1.1', '1.0.0.1') -ErrorAction Stop
                Ok ($ad.Name + ': DNS = 1.1.1.1 / 1.0.0.1')
            } catch { Warn ($ad.Name + ': could not set DNS') }
        }
    }
    Info 'some NIC values only take effect after the adapter restarts or a reboot'
    if ($script:Interactive -and $adapters.Count -gt 0 -and -not $NoNicRestart) {
        if ($env:SESSIONNAME -like 'RDP-Tcp*') {
            Warn 'Remote Desktop session detected - skipping adapter restart'
        } else {
            $ans = Read-Host '   Restart the network adapter now so the values apply? [y/N]'
            if ($ans -match '^(y|Y)') {
                foreach ($ad in $adapters) {
                    try { Restart-NetAdapter -Name $ad.Name -Confirm:$false; Ok ('restarted: ' + $ad.Name) } catch { Warn ('could not restart: ' + $ad.Name) }
                }
            }
        }
    }
    Save-Backup
}

function Invoke-PolicyTweaks {
    Head 'GPEDIT - system policies (applied through registry, works on Home too)'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 'DWord'
    Ok 'QoS Packet Scheduler: limit reservable bandwidth = 0%'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 'DWord'
    Ok 'Windows Game Recording and Broadcasting = Disabled'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1 'DWord'
    Ok 'Delivery Optimization: download mode = LAN only'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 'DWord'
    Ok 'Application Compatibility: PCA / app telemetry / inventory collector OFF'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutoplayfornonVolume' 1 'DWord'
    Ok 'Autoplay / AutoRun OFF (less disk and CPU chatter on plug-in)'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DisableSmartNameResolution' 1 'DWord'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DisableSmartProtocolReordering' 1 'DWord'
    Ok 'DNS Client: LLMNR multicast + smart name resolution OFF'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' 'NoActiveProbe' 1 'DWord'
    Ok 'NCSI active probe OFF (less background traffic)'
    $null = (& netsh int teredo set state disabled 2>$null)
    $null = (& netsh int isatap set state disabled 2>$null)
    Ok 'Teredo / ISATAP tunneling disabled'
    Save-Backup
}

function Invoke-ServiceTweaks {
    Head 'SERVICES - cut background load that causes frame dips'
    Set-ServiceStartWithBackup 'Ndu' 'Disabled'
    Set-ServiceStartWithBackup 'DiagTrack' 'Disabled'
    Set-ServiceStartWithBackup 'SysMain' 'Disabled'
    Set-ServiceStartWithBackup 'WSearch' 'Disabled'
    Warn 'Ndu = Windows network usage counter, DiagTrack = telemetry (safe to disable)'
    Warn 'SysMain / WSearch suit SSD users - RESET brings them back any time'
    Info 'services fully stop after the next reboot (we never stop them mid-run)'
    Save-Backup
}

function Invoke-GraphicsTweaks {
    param([switch]$Full)
    Head 'GRAPHICS - smoother image, no flicker'
    Set-RegWithBackup 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 'DWord'
    Ok 'MPO (Multi-Plane Overlay) off - fixes flicker / odd image on multi-monitor'
    $exes = @(Get-FiveMExePaths)
    if ($exes.Count -gt 0) {
        $layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
        foreach ($e in $exes) { Set-RegWithBackup $layers $e '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' 'String' }
        Ok ('Fullscreen optimizations disabled for ' + $exes.Count + ' game file(s)')
    } else {
        Info 'FiveM files not found yet - the booster sets this automatically while you play'
    }
    Set-RegWithBackup 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;' 'String'
    Ok 'Win11: windowed/borderless optimizations ON, VRR optimize OFF'
    if ($Full) {
        Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord'
        Ok 'HAGS (hardware accelerated GPU scheduling) ON - needs a reboot'
        Set-RegWithBackup 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay' 10 'DWord'
        Ok 'TdrDelay = 10 (no more frozen image from a driver timeout)'
    }
    Save-Backup
}

function Invoke-FiveMQosTweaks {
    Head 'FIVEM - give game packets top priority (QoS / DSCP)'
    $policies = @(
        @{ Name = 'FiveM-GameCore'; App = 'FiveM.exe' },
        @{ Name = 'FiveM-GTAProc';  App = 'FiveM_b3258_GTAProcess.exe' }
    )
    foreach ($pol in $policies) {
        $key = Join-Path $QosRoot $pol.Name
        $created = -not (Test-Path $key)
        if (-not (Test-Path $key)) { $null = New-Item -Path $key -Force }
        if ($created -and -not (@($script:QosPolicies | Where-Object { $_.Name -eq $pol.Name }).Count)) {
            $script:QosPolicies += [pscustomobject]@{ Name = $pol.Name; Created = $true }
        }
        foreach ($v in @(
            @{ N = 'Version';          V = '1.0' },
            @{ N = 'Application Name'; V = $pol.App },
            @{ N = 'Protocol';         V = 'UDP' },
            @{ N = 'Local IP';         V = '*' },
            @{ N = 'Local Port';       V = '*' },
            @{ N = 'Remote IP';        V = '*' },
            @{ N = 'Remote Port';      V = '*' },
            @{ N = 'DSCP Value';       V = '46' }
        )) { $null = New-ItemProperty -Path $key -Name $v.N -Value $v.V -PropertyType String -Force }
        Ok ('QoS: ' + $pol.Name + '  ->  DSCP 46 (Expedited Forwarding)')
    }
    $keySrv = Join-Path $QosRoot 'FiveM-Server-UDP'
    $createdSrv = -not (Test-Path $keySrv)
    if (-not (Test-Path $keySrv)) { $null = New-Item -Path $keySrv -Force }
    if ($createdSrv -and -not (@($script:QosPolicies | Where-Object { $_.Name -eq 'FiveM-Server-UDP' }).Count)) {
        $script:QosPolicies += [pscustomobject]@{ Name = 'FiveM-Server-UDP'; Created = $true }
    }
    foreach ($v in @(
        @{ N = 'Version';     V = '1.0' },
        @{ N = 'Protocol';    V = 'UDP' },
        @{ N = 'Local IP';    V = '*' },
        @{ N = 'Local Port';  V = '*' },
        @{ N = 'Remote IP';   V = '*' },
        @{ N = 'Remote Port'; V = '30120' },
        @{ N = 'DSCP Value';  V = '46' }
    )) { $null = New-ItemProperty -Path $keySrv -Name $v.N -Value $v.V -PropertyType String -Force }
    Ok 'QoS: UDP port 30120 (FiveM server port)  ->  DSCP 46'
    Warn 'DSCP pays off when your router/ISP honours QoS - the marking itself is now set'
    Save-Backup
}

function Add-FiveMDefenderExclusion {
    Head 'FIVEM - Defender scan exclusion'
    Warn 'less stutter while loading assets, but that folder becomes less protected'
    if (-not $script:Interactive) { Info 'non-interactive mode: skipped'; return }
    $ans = Read-Host '   Exclude the FiveM folder from Defender scanning? [y/N]'
    if ($ans -notmatch '^(y|Y)') { Info 'skipped'; return }
    $folders = @()
    if ($env:LOCALAPPDATA) {
        $f1 = Join-Path $env:LOCALAPPDATA 'FiveM'
        if (Test-Path $f1) { $folders += $f1 }
    }
    foreach ($f in $folders) {
        try {
            Add-MpPreference -ExclusionPath $f -ErrorAction Stop
            if ($script:DefenderExclusions -notcontains $f) { $script:DefenderExclusions += $f }
            Ok ('excluded: ' + $f)
        } catch { Warn ('could not exclude: ' + $f) }
    }
    if ($folders.Count -eq 0) { Warn 'FiveM folder not found' }
}

function Invoke-Clean {
    Head 'CLEAN - temp files and caches (safe targets only)'
    $targets = @()
    if ($env:TEMP)   { $targets += $env:TEMP }
    if ($env:WINDIR) { $targets += (Join-Path $env:WINDIR 'Temp') }
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { continue }
        Get-ChildItem -Path $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Ok ('cleared: ' + $t)
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Ok 'DNS cache cleared'
    $null = (& ipconfig /flushdns 2>$null) | Out-Null
    $null = (& netsh interface ip delete arpcache 2>$null) | Out-Null
    Ok 'ARP cache cleared'
    if ($env:LOCALAPPDATA) {
        $fmApp   = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'
        $fmCache = Join-Path $fmApp 'cache'
        $fmCrash = Join-Path $fmApp 'crashes'
        $fmLogs  = Join-Path $fmApp 'logs'
        if (Test-Path $fmCache) {
            $sz = (Get-ChildItem -Path $fmCache -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if (-not $sz) { $sz = 0 }
            Info ('FiveM cache size: ' + [Math]::Round(($sz / 1MB), 1) + ' MB')
            $delFm = $false
            if ($script:Interactive) {
                $ans = Read-Host '   Delete the FiveM cache? (fixes broken assets, first join will be slower) [y/N]'
                if ($ans -match '^(y|Y)') { $delFm = $true }
            } else { Info 'non-interactive mode: FiveM cache kept' }
            if ($delFm) {
                Remove-Item -Path $fmCache -Recurse -Force -ErrorAction SilentlyContinue
                Ok 'FiveM cache deleted'
            }
        }
        foreach ($d in @($fmCrash, $fmLogs)) {
            if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue; Ok ('cleared: ' + $d) }
        }
    }
    $free = 0
    try { $free = (Get-PSDrive -Name C).Free } catch { }
    Info ('free space on C: ' + [Math]::Round(($free / 1GB), 1) + ' GB')
    Warn 'no fake "RAM cleaner" tricks here - Windows manages memory well on its own'
}

# ------------------------------ booster control ------------------------------
# the booster is this same file, so we look for the -Booster switch on the
# command line instead of a second script name
function Test-BoosterRunning {
    return (@(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-Booster*' -and $_.ProcessId -ne $PID }).Count -gt 0)
}

function Start-BoosterWindow {
    # returns $true when a booster window was opened, $false when the caller has
    # to run the booster inside its own window instead (irm | iex mode)
    Head 'BOOSTER - priority boost + 0.5 ms timer'
    if ($script:FromMemory -or -not $script:SelfPath -or -not (Test-Path -LiteralPath $script:SelfPath)) {
        Info 'there is no script file behind this run, so the booster shares this window'
        return $false
    }
    try {
        $bArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:SelfPath + '"'), '-Booster')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $bArgs
        Ok 'booster launched in a separate window - leave it open while playing'
        return $true
    } catch { Err 'could not launch the booster'; return $false }
}

function Stop-Booster {
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-Booster*' -and $_.ProcessId -ne $PID })
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Ok ('booster closed (PID ' + $p.ProcessId + ')') } catch { Warn 'could not close the booster' }
    }
    if ($procs.Count -eq 0) { Info 'booster was not running' }
    # forced close may skip the booster's own cleanup, so restore default priorities here
    foreach ($n in @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'OBS64', 'obs-app', 'Spotify', 'Discord')) {
        foreach ($q in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try { if ($q.PriorityClass.ToString() -ne 'Normal') { $q.PriorityClass = 'Normal'; Info ('priority restored: ' + $q.Name) } } catch { }
        }
    }
}

# =============================================================================
#  BOOSTER MODE      (this same file started as:  Project X.ps1 -Booster)
#
#  Runs in its own window while you play:
#    . locks the Windows timer resolution at 0.5 ms
#    . FiveM.exe / FiveM_b3258_GTAProcess.exe -> High priority
#    . CPU affinity away from core 0
#    . Discord raised to AboveNormal, browsers / OBS / Spotify lowered
#    . Fullscreen Optimizations off for the running game executable
#    . every priority restored when the window is closed
# =============================================================================
$script:GameProcessPatterns = @('FiveM', 'FiveM_b*GTAProcess*', 'GTA5')
$script:VoiceProcesses     = @('Discord')
$script:LowerProcesses     = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'OBS64', 'obs-app', 'Spotify')
$script:BoostRestoreList   = @{ }      # pid -> original priority, restored on exit
$script:FsoDone            = @{ }
$script:FsoKey             = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

function Write-Line {
    param([string]$m, [string]$Color = 'Gray')
    Write-Host ('  [{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor $Color
}

function Get-GameProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $n = $_.Name
        $match = $false
        foreach ($pat in $script:GameProcessPatterns) { if ($n -like $pat) { $match = $true; break } }
        $match
    })
}

function Set-FiveMFullscreenOpt {
    param([string]$ExePath)
    if (-not $ExePath) { return }
    $low = $ExePath.ToLower()
    if ($script:FsoDone.ContainsKey($low)) { return }
    $script:FsoDone[$low] = $true
    try {
        if (-not (Test-Path $script:FsoKey)) { $null = New-Item -Path $script:FsoKey -Force }
        $cur = (Get-ItemProperty -Path $script:FsoKey -Name $ExePath -ErrorAction SilentlyContinue).$ExePath
        if ($cur -notlike '*DISABLEDXMAXIMIZEDWINDOWEDMODE*') {
            $null = New-ItemProperty -Path $script:FsoKey -Name $ExePath -Value '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' -PropertyType String -Force
            Write-Line ('Fullscreen Optimizations disabled: ' + $ExePath) 'DarkGreen'
        }
    } catch { }
}

function Set-ProcPriority {
    param($Proc, [string]$Level, [switch]$Remember)
    try {
        if ($Proc.PriorityClass.ToString() -eq $Level) { return }
        if ($Remember -and -not $script:BoostRestoreList.ContainsKey($Proc.Id)) {
            $script:BoostRestoreList[$Proc.Id] = $Proc.PriorityClass.ToString()
        }
        $Proc.PriorityClass = $Level
        Write-Line ($Proc.Name + ' (PID ' + $Proc.Id + ') -> priority ' + $Level) 'Green'
    } catch { }
}

function Initialize-TimerApi {
    try { $null = [Fbm.Nt] } catch {
        try {
            Add-Type -Namespace Fbm -Name Nt -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern uint NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
'@
        } catch { return $false }
    }
    return $true
}

function Start-BoosterSession {
    param([string]$Priority = 'High', [switch]$NoAffinity)
    $ErrorActionPreference = 'SilentlyContinue'
    $script:BoostRestoreList = @{ }
    $script:FsoDone = @{ }
    try { $Host.UI.RawUI.WindowTitle = 'PROJECT X  .  FIVEM BOOSTER' } catch { }
    Set-WideConsole

    Clear-Host
    $red = Get-ArtLines 'X'
    $top = -1
    if (Test-CanAnimate) { try { $top = [Console]::CursorTop } catch { $top = -1 } }
    Show-Banner -Animate:$(-not $NoAnim) -Mode 'BOOSTER'
    if (-not $NoAnim) { Show-XGlow -Red $red -Top $top }
    Write-Host ''
    Write-Rule 58
    Write-Host '   . Timer Resolution locked at 0.5 ms' -ForegroundColor Gray
    Write-Host '   . FiveM.exe / FiveM_b3258_GTAProcess.exe -> High priority' -ForegroundColor Gray
    Write-Host '   . CPU affinity avoids core 0' -ForegroundColor Gray
    Write-Host '   . Fullscreen Optimizations disabled for the running game exe' -ForegroundColor Gray
    Write-Host '   . every priority restored automatically on exit' -ForegroundColor Gray
    Write-Rule 58
    Write-Host '   leave this window open while you play   .   Ctrl+C to stop' -ForegroundColor Yellow
    Write-Host ''
    if ($Priority -eq 'RealTime') {
        Write-Host '  [!] RealTime can cause audio glitches - High is recommended' -ForegroundColor Yellow
    }

    $timerHeld = $false
    if (Initialize-TimerApi) {
        $cur = [uint32]0
        try {
            $null = [Fbm.Nt]::NtSetTimerResolution(5000, $true, [ref]$cur)
            $timerHeld = $true
            if ($cur -gt 0) { Write-Line ('Timer Resolution = ' + [Math]::Round(($cur / 10000.0), 2) + ' ms (locked)') 'Green' }
        } catch { }
    } else {
        Write-Line 'ntdll timer API unavailable - continuing without it' 'DarkYellow'
    }

    $wasRunning = $false
    try {
        while ($true) {
            if ($timerHeld) {
                $cur = [uint32]0
                try { $null = [Fbm.Nt]::NtSetTimerResolution(5000, $true, [ref]$cur) } catch { }
            }
            $games = @(Get-GameProcesses)
            if ($games.Count -gt 0) {
                if (-not $wasRunning) {
                    Write-Line ('game process found: ' + (($games | ForEach-Object { $_.Name }) -join ', ')) 'Cyan'
                    $wasRunning = $true
                }
                foreach ($g in $games) {
                    Set-ProcPriority -Proc $g -Level $Priority
                    if (-not $NoAffinity) {
                        try {
                            $cores = [Environment]::ProcessorCount
                            if ($cores -ge 4) {
                                $mask = [IntPtr]([math]::Pow(2, $cores) - 2)   # every core except core 0
                                if ($g.ProcessorAffinity -ne $mask) {
                                    $g.ProcessorAffinity = $mask
                                    Write-Line ($g.Name + ' -> affinity avoids core 0 (' + $cores + ' cores)') 'Green'
                                }
                            }
                        } catch { }
                    }
                    try { Set-FiveMFullscreenOpt -ExePath $g.Path } catch { }
                }
                foreach ($v in $script:VoiceProcesses) {
                    foreach ($p in @(Get-Process -Name $v -ErrorAction SilentlyContinue)) {
                        Set-ProcPriority -Proc $p -Level 'AboveNormal'
                    }
                }
                foreach ($n in $script:LowerProcesses) {
                    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                        Set-ProcPriority -Proc $p -Level 'BelowNormal' -Remember
                    }
                }
                Write-Progress -Activity 'PROJECT X BOOSTER' -Status ('boosting - ' + $games.Count + ' game process - ' + (Get-Date -Format 'HH:mm:ss')) -PercentComplete 100
            } else {
                if ($wasRunning) {
                    Write-Line 'FiveM closed - back to waiting (priorities restored)' 'DarkYellow'
                    $wasRunning = $false
                }
                Write-Progress -Activity 'PROJECT X BOOSTER' -Status ('waiting for FiveM... - ' + (Get-Date -Format 'HH:mm:ss')) -PercentComplete 0
            }
            Start-Sleep -Seconds 2
        }
    } finally {
        Write-Progress -Activity 'PROJECT X BOOSTER' -Completed
        foreach ($entry in $script:BoostRestoreList.GetEnumerator()) {
            try {
                $p = Get-Process -Id $entry.Key -ErrorAction Stop
                $p.PriorityClass = $entry.Value
                Write-Line ('priority restored: ' + $p.Name + ' (' + $entry.Value + ')') 'DarkGray'
            } catch { }
        }
        if ($timerHeld) {
            $nullTimer = [uint32]0
            try { $null = [Fbm.Nt]::NtSetTimerResolution(5000, $false, [ref]$nullTimer) } catch { }
            Write-Line 'Timer Resolution released' 'DarkGray'
        }
        Write-Host ''
        Write-Host '  Booster stopped - all original values have been restored.' -ForegroundColor Green
        Write-Host ''
    }
}

# =============================================================================
#  RESET TO WINDOWS DEFAULTS  (safety net when the backup file is gone)
# =============================================================================
function Set-ActivePowerPlan {
    param([string]$Match)
    if (-not $Match) { return }
    $m = $Match.Trim()
    if ($m -match '^[0-9a-fA-F-]{36}$') {
        $null = (& powercfg /setactive $m 2>$null)
        Ok ('power plan activated: ' + $m)
        return
    }
    $list = (& powercfg /list 2>$null) | Out-String
    foreach ($line in ($list -split "`r?`n")) {
        if (($line.ToLower()).Contains($m.ToLower())) {
            if ($line -match '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                $null = (& powercfg /setactive $Matches[1] 2>$null)
                Ok ('power plan activated: ' + $line.Trim())
                return
            }
        }
    }
    Warn ('no power plan matched: ' + $Match)
}

function Reset-ToWindowsDefaults {
    param([string]$PowerPlan = '')
    Head 'RESET TO WINDOWS DEFAULTS - every value this script touches'

    # input
    Set-RegRaw 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '1' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '126' 'String'
    Set-RegRaw 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Remove-RegRaw 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize'
    Remove-RegRaw 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize'
    Ok 'input: mouse / keyboard back to defaults'

    # game / MMCSS
    Set-RegRaw 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1
    Set-RegRaw 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
    Set-RegRaw 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-RegRaw 'HKCU:\SOFTWARE\Microsoft\GameBar' 'ShowStartupPanel' 1
    Set-RegRaw 'HKCU:\SOFTWARE\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1
    Remove-RegRaw 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled'
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Remove-RegRaw $sp 'NetworkThrottlingIndex'
    Remove-RegRaw $sp 'SystemResponsiveness'
    $g = $sp + '\Tasks\Games'
    Set-RegRaw $g 'GPU Priority' 8 'DWord'
    Set-RegRaw $g 'Priority' 2 'DWord'
    Set-RegRaw $g 'Scheduling Category' 'Medium' 'String'
    Set-RegRaw $g 'SFIO Priority' 'Normal' 'String'
    Set-RegRaw 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2 'DWord'
    Remove-RegRaw 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
    Ok 'game / MMCSS: back to Windows defaults'

    # network
    $ifRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($k in @(Get-ChildItem -Path $ifRoot -ErrorAction SilentlyContinue)) {
        $p = ($k.Name) -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        Remove-RegRaw $p 'TcpAckFrequency'
        Remove-RegRaw $p 'TCPNoDelay'
    }
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'
    $null = (& netsh int tcp set global autotuninglevel=normal 2>$null) | Out-Null
    $null = (& netsh int tcp set global rss=enabled 2>$null) | Out-Null
    $null = (& netsh int tcp set global ecncapability=disabled 2>$null) | Out-Null
    $null = (& netsh int tcp set global timestamps=disabled 2>$null) | Out-Null
    $null = (& netsh int tcp set global rsc=enabled 2>$null) | Out-Null
    Ok 'TCP: Nagle / RSC / QoS / Delivery Optimization back to defaults'

    # adapters
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($ad in $adapters) {
        try { Set-NetAdapterRss -Name $ad.Name -Enabled $true -ErrorAction SilentlyContinue } catch { }
        try { Enable-NetAdapterRsc -Name $ad.Name -ErrorAction SilentlyContinue } catch { }
        try { Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Supported -ErrorAction SilentlyContinue } catch { }
        $props = @(Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue)
        foreach ($t in $script:AdapterTargets) {
            foreach ($kp in @($props | Where-Object { $_.RegistryKeyword -eq $t.K -or $_.RegistryKeyword -eq ('*' + $t.K) })) {
                $done = $false
                foreach ($v in @(1, 'Enabled')) {
                    if ($done) { continue }
                    try {
                        Set-NetAdapterAdvancedProperty -Name $ad.Name -RegistryKeyword $kp.RegistryKeyword -RegistryValue $v -NoRestart -ErrorAction Stop
                        $done = $true
                    } catch { }
                }
            }
        }
        try { Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -NlMtuBytes 1500 -ErrorAction SilentlyContinue } catch { }
        try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue } catch { }
        Ok ('adapter back to defaults: ' + $ad.Name)
    }

    # policies
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory'
    Remove-RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'
    Remove-RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutoplayfornonVolume'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DisableSmartNameResolution'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'DisableSmartProtocolReordering'
    Remove-RegRaw 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' 'NoActiveProbe'
    if (Test-Path $QosRoot) {
        foreach ($q in @('FiveM-GameCore', 'FiveM-GTAProc', 'FiveM-Server-UDP')) {
            $k = Join-Path $QosRoot $q
            if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue; Info ('QoS policy removed: ' + $q) }
        }
    }
    $null = (& netsh int teredo set state default 2>$null) | Out-Null
    $null = (& netsh int isatap set state default 2>$null) | Out-Null
    Ok 'system policies (gpedit) back to defaults'

    # graphics
    Remove-RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode'
    Remove-RegRaw 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay'
    Remove-RegRaw 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
    $layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (Test-Path $layers) {
        foreach ($p in (Get-ItemProperty -Path $layers -ErrorAction SilentlyContinue).PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ([string]$p.Value -like '*DISABLEDXMAXIMIZEDWINDOWEDMODE*') {
                Remove-RegRaw $layers $p.Name
                Info ('fullscreen-optimization override removed: ' + $p.Name)
            }
        }
    }
    Ok 'graphics: MPO / fullscreen optimizations / DirectX back to defaults'

    # services
    foreach ($s in @(
        @{ N = 'Ndu';       S = 3 },
        @{ N = 'DiagTrack'; S = 2 },
        @{ N = 'SysMain';   S = 2 },
        @{ N = 'WSearch';   S = 2 }
    )) {
        $rp = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.N
        try {
            Set-ItemProperty -Path $rp -Name 'Start' -Value ([int]$s.S) -ErrorAction Stop
            if ($s.N -eq 'WSearch') { Set-ItemProperty -Path $rp -Name 'DelayedAutostart' -Value 1 -ErrorAction SilentlyContinue }
            Ok ($s.N + '  ->  Windows default')
        } catch { Warn ($s.N + '  ->  could not change') }
    }

    # power plan
    if ($PowerPlan) {
        Set-ActivePowerPlan -Match $PowerPlan
    } else {
        $null = (& powercfg /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' 2>$null)
        Info 'switched to the Balanced plan (use -PowerPlan "name" to pick another)'
    }
    Info 'extra "Ultimate Performance" plans can be removed with: powercfg /list -> powercfg /delete <GUID>'
    Write-Host ''
    Ok 'Windows defaults restored - a reboot is recommended'
}

# =============================================================================
#  RESTORE FROM BACKUP
# =============================================================================
function Restore-Strike {
    param($b)
    Head 'RESTORE 1/6 - registry'
    if ($b.Reg) {
        $n = 0
        foreach ($e in @($b.Reg)) { try { Restore-RegEntry -Entry $e; $n++ } catch { } }
        Ok ('restored ' + $n + ' registry entries')
    }

    Head 'RESTORE 2/6 - system services'
    if ($b.Services) {
        foreach ($s in @($b.Services)) {
            try {
                Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name) -Name 'Start' -Value ([int]$s.Start) -ErrorAction Stop
                Ok ($s.Name + '  ->  original')
            } catch { Warn ($s.Name + '  ->  failed') }
        }
    }

    Head 'RESTORE 3/6 - network (TCP / NIC / DNS / QoS)'
    if ($b.TcpGlobal) {
        foreach ($p in $b.TcpGlobal.PSObject.Properties) {
            $v = ''
            if ($null -ne $p.Value) { $v = (([string]$p.Value) -replace '\(.*$', '').Trim().ToLower() }
            if (-not $v) { continue }
            try {
                switch -Regex ($p.Name) {
                    'Auto-Tuning' { $null = (& netsh int tcp set global autotuninglevel=$v 2>$null) }
                    'ECN'         { $null = (& netsh int tcp set global ecncapability=$v 2>$null) }
                    'Scaling'     { $null = (& netsh int tcp set global rss=$v 2>$null) }
                    'Coalescing'  { $null = (& netsh int tcp set global rsc=$v 2>$null) }
                    'Timestamp'   { $null = (& netsh int tcp set global timestamps=$v 2>$null) }
                }
            } catch { }
        }
        Ok 'TCP globals restored'
    }
    if ($b.Adapters) {
        foreach ($a in @($b.Adapters)) {
            try { if ($a.Mtu) { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -NlMtuBytes ([uint32]$a.Mtu) -ErrorAction SilentlyContinue } } catch { }
            try { if ($null -ne $a.RssEnabled) { Set-NetAdapterRss -Name $a.Name -Enabled ([bool]$a.RssEnabled) -ErrorAction SilentlyContinue } } catch { }
            try { if ($null -ne $a.RscIPv4) { Set-NetAdapterRsc -Name $a.Name -IPv4Enabled ([bool]$a.RscIPv4) -ErrorAction SilentlyContinue } } catch { }
            try { if ($null -ne $a.RscIPv6) { Set-NetAdapterRsc -Name $a.Name -IPv6Enabled ([bool]$a.RscIPv6) -ErrorAction SilentlyContinue } } catch { }
            try { if ($a.AllowPmeOff) { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice ([string]$a.AllowPmeOff) -ErrorAction SilentlyContinue } } catch { }
            foreach ($pr in @($a.AdvProps)) {
                $done = $false
                try {
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $pr.RegistryKeyword -RegistryValue $pr.RegistryValue -NoRestart -ErrorAction Stop
                    $done = $true
                } catch {
                    # JSON gives Int64 back - some drivers want int or string instead
                    $cands = @()
                    if ([string]$pr.RegistryValue -match '^\d+$') { $cands += [int]$pr.RegistryValue }
                    $cands += ([string]$pr.RegistryValue)
                    foreach ($c in $cands) {
                        if ($done) { continue }
                        try { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $pr.RegistryKeyword -RegistryValue $c -NoRestart -ErrorAction Stop; $done = $true } catch { }
                    }
                }
                if (-not $done) { Warn ('could not restore NIC property: ' + $pr.RegistryKeyword) }
            }
            try {
                if ($null -ne $a.Dns -and @($a.Dns).Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($a.Dns) -ErrorAction SilentlyContinue
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                }
            } catch { }
            Ok ('adapter restored: ' + $a.Name)
        }
    }
    if ($b.QosPolicies) {
        foreach ($q in @($b.QosPolicies)) {
            if ($q.Created) {
                try { Remove-Item -Path ((Join-Path $QosRoot $q.Name)) -Recurse -Force -ErrorAction Stop; Ok ('QoS policy removed: ' + $q.Name) } catch { }
            }
        }
    }
    $null = (& netsh int teredo set state default 2>$null)
    $null = (& netsh int isatap set state default 2>$null)
    Ok 'Teredo / ISATAP restored'

    Head 'RESTORE 4/6 - Defender exclusions'
    foreach ($d in @($b.DefExcl)) {
        try { Remove-MpPreference -ExclusionPath $d -ErrorAction Stop; Ok ('exclusion removed: ' + $d) } catch { Warn ('could not remove exclusion: ' + $d) }
    }

    Head 'RESTORE 5/6 - power plan'
    if ($b.Power) {
        try {
            if ($b.Power.OriginalIndexes) {
                foreach ($p in $b.Power.OriginalIndexes.PSObject.Properties) {
                    $parts = ([string]$p.Name) -split '\\', 2
                    if ($parts.Count -ne 2) { continue }
                    if ($null -eq $p.Value.AC -and $null -eq $p.Value.DC) {
                        # nothing was set before -> drop our value so the inherited default returns
                        $rp = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$($b.Power.TargetScheme)\$($parts[0])\$($parts[1])"
                        Remove-RegRaw $rp 'ACSettingIndex'
                        Remove-RegRaw $rp 'DCSettingIndex'
                        continue
                    }
                    if ($null -ne $p.Value.AC) { $null = (& powercfg /setacvalueindex $b.Power.TargetScheme $parts[0] $parts[1] ([int]$p.Value.AC) 2>$null) }
                    if ($null -ne $p.Value.DC) { $null = (& powercfg /setdcvalueindex $b.Power.TargetScheme $parts[0] $parts[1] ([int]$p.Value.DC) 2>$null) }
                }
            }
            # switch back first, then the plan we created can be deleted
            if ($b.Power.OriginalScheme) {
                $null = (& powercfg /setactive $b.Power.OriginalScheme 2>$null)
                if ($LASTEXITCODE -eq 0) { Ok ('original power plan activated: ' + $b.Power.OriginalScheme) }
                else { Warn ('could not activate the original plan: ' + $b.Power.OriginalScheme) }
            }
            if ($b.Power.CreatedNewScheme -and $b.Power.TargetScheme) {
                $null = (& powercfg /delete $b.Power.TargetScheme 2>$null)
                if ($LASTEXITCODE -eq 0) { Ok 'Ultimate Performance plan created by the script deleted' }
                else { Warn ('could not delete the created plan - run: powercfg /delete ' + $b.Power.TargetScheme) }
            }
        } catch { Warn 'power restore failed' }
    }

    Head 'RESTORE 6/6 - network adapter restart'
    if ($b.Adapters) {
        if ($NoNicRestart) {
            Info 'adapter restart skipped (-NoNicRestart) - values apply after reboot'
        } elseif ($env:SESSIONNAME -like 'RDP-Tcp*') {
            Warn 'Remote Desktop detected - adapter restart skipped'
        } else {
            foreach ($a in @($b.Adapters)) { try { Restart-NetAdapter -Name $a.Name -Confirm:$false } catch { } }
            Ok 'network adapter restarted'
        }
    }
    if (Test-Path $BackupFile) {
        $done = Join-Path $BackupDir ('backup.restored.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        try { Move-Item -Path $BackupFile -Destination $done -Force; Info ('backup archived as: ' + $done) } catch { }
    }
    Write-Host ''
    Ok 'everything restored - a reboot is recommended'
    Add-Log 'restore finished'
}

# =============================================================================
#  STATUS PANEL
# =============================================================================
function Get-StatusLines {
    $lines = @()
    $plan = 'unknown'
    try {
        $out = ((& powercfg /getactivescheme 2>$null) | Out-String)
        if ($out -match '\((.*?)\)') { $plan = $Matches[1].Trim() }
    } catch { }
    $lines += [pscustomobject]@{ L = 'Power plan'; V = $plan }

    $dvr = (Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled').Value
    $dvrTxt = 'on'
    if ($dvr -eq 0) { $dvrTxt = 'off' }
    $lines += [pscustomobject]@{ L = 'Game DVR'; V = $dvrTxt }

    $nagle = 'on'
    foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)) {
        $v = (Get-ItemProperty -Path $k.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue).TcpAckFrequency
        if ($v -eq 1) { $nagle = 'off (Nagle disabled)'; break }
    }
    $lines += [pscustomobject]@{ L = 'Nagle'; V = $nagle }

    $qos = 'not installed'
    if (Test-Path (Join-Path $QosRoot 'FiveM-GameCore')) { $qos = 'installed (DSCP 46)' }
    $lines += [pscustomobject]@{ L = 'FiveM QoS'; V = $qos }

    $svc = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Ndu' -Name 'Start' -ErrorAction SilentlyContinue).Start
    $svcTxt = 'running'
    if ($svc -eq 4) { $svcTxt = 'disabled' }
    $lines += [pscustomobject]@{ L = 'Ndu/Telemetry'; V = $svcTxt }

    $fm = @(Get-Process -Name 'FiveM' -ErrorAction SilentlyContinue)
    $fm += @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'FiveM_b*GTAProcess*' })
    $fmTxt = 'not running'
    if ($fm.Count -gt 0) { $fmTxt = ('in game (' + $fm.Count + ' process)') }
    $lines += [pscustomobject]@{ L = 'FiveM'; V = $fmTxt }

    $booster = 'not running'
    if (Test-BoosterRunning) { $booster = 'running' }
    $lines += [pscustomobject]@{ L = 'Booster'; V = $booster }
    return $lines
}

function Write-Status {
    $lines = @(Get-StatusLines)
    Write-Host '  MACHINE STATUS' -ForegroundColor DarkCyan
    foreach ($l in $lines) {
        Write-Host '   . ' -NoNewline -ForegroundColor DarkGray
        Write-Host $l.L.PadRight(14) -NoNewline -ForegroundColor Gray
        Write-Host $l.V -ForegroundColor DarkGray
    }
}

function Pause-Menu {
    Write-Host ''
    Write-Host '  Press Enter to go back to the menu...' -ForegroundColor DarkGray
    while ([Console]::ReadKey($true).Key -ne 'Enter') { }
}

# =============================================================================
#  MEASUREMENT AND VERIFICATION
#  Everything here only READS the machine, so it is always safe to run.
#  It is the proof that the tuning is really in effect and not placebo.
# =============================================================================
function Get-PowerSettingLive {
    param([string]$Scheme, [string]$Sub, [string]$Setting, [string]$Mode = 'AC')
    if (-not $Scheme) { return $null }
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\' + $Scheme + '\' + $Sub + '\' + $Setting
    $name = $Mode + 'SettingIndex'
    return (Get-ItemProperty -Path $p -Name $name -ErrorAction SilentlyContinue).$name
}

function Get-ActivePlanName {
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { return 'unknown' }
    $esc = [regex]::Escape($scheme)
    $out = ((& powercfg /list 2>$null) | Out-String)
    foreach ($line in ($out -split '\r?\n')) {
        if ($line -match $esc) {
            $n = $line -replace '^.*\(', ''
            $n = $n -replace '\)\s*\*?\s*$', ''
            return $n.Trim()
        }
    }
    return 'unknown'
}

function Get-PrimaryInterfaceKey {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $keys = @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)
    $best = $null
    foreach ($k in $keys) {
        $gw = (Get-ItemProperty -Path $k.PSPath -Name 'DefaultGateway' -ErrorAction SilentlyContinue).DefaultGateway
        if ($gw) { $best = $k; break }
    }
    if (-not $best -and $keys.Count -gt 0) { $best = $keys[0] }
    if (-not $best) { return $null }
    return ($best.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM:')
}

function Add-TuneRow {
    param([string]$Name, $Live, [string]$Want, [bool]$Ok)
    $script:TuneRows += [pscustomobject]@{ Name = $Name; Live = [string]$Live; Want = $Want; Pass = $Ok }
}

function Get-TuningReport {
    $script:TuneRows = @()
    $scheme = Get-ActiveSchemeGuid
    $subCpu = '54533251-82be-4824-96c1-47b60b740d00'
    $planName = Get-ActivePlanName
    Add-TuneRow 'Power plan' $planName 'Performance plan' ($planName -match '(?i)performance|ultimate')

    $park = Get-PowerSettingLive -Scheme $scheme -Sub $subCpu -Setting '0cc5b647-c1df-4637-891a-dec35c318583'
    Add-TuneRow 'CPU core parking' (Show-Val $park) '100 (all cores)' ([string]$park -eq '100')
    $boost = Get-PowerSettingLive -Scheme $scheme -Sub $subCpu -Setting 'be337238-0d82-4146-a960-4f3749d470c7'
    Add-TuneRow 'CPU boost mode' (Show-Val $boost) '2 (aggressive)' ([string]$boost -eq '2')
    $pmax = Get-PowerSettingLive -Scheme $scheme -Sub $subCpu -Setting 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    Add-TuneRow 'CPU maximum state' (Show-Val $pmax) '100 (%)' ([string]$pmax -eq '100')
    $pmin = Get-PowerSettingLive -Scheme $scheme -Sub $subCpu -Setting '893dee8e-2bef-41e0-89c6-b55d0929964c'
    Add-TuneRow 'CPU minimum state' (Show-Val $pmin) '5 (%)' ([string]$pmin -eq '5')
    $usb = Get-PowerSettingLive -Scheme $scheme -Sub '2a737441-1930-4402-8d77-b2bebba308a3' -Setting '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    Add-TuneRow 'USB selective suspend' (Show-Val $usb) '0 (off)' ([string]$usb -eq '0')
    $aspm = Get-PowerSettingLive -Scheme $scheme -Sub '501a4d13-42af-4429-9fd1-a8218c268e20' -Setting 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    Add-TuneRow 'PCIe ASPM' (Show-Val $aspm) '0 (off)' ([string]$aspm -eq '0')
    $disk = Get-PowerSettingLive -Scheme $scheme -Sub '0012ee47-9041-4b5d-9b77-535fba8b1442' -Setting '6738e2c4-e8a5-4a42-b16a-e040e769756e'
    Add-TuneRow 'Disk idle timeout' (Show-Val $disk) '0 (never)' ([string]$disk -eq '0')

    $pt = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff').Value
    Add-TuneRow 'Power throttling' (Show-Val $pt) '1 (disabled)' ([string]$pt -eq '1')

    $ms = (Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed').Value
    Add-TuneRow 'Mouse acceleration' (Show-Val $ms) '0 (1:1 raw aim)' ([string]$ms -eq '0')
    $mth = (Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1').Value
    Add-TuneRow 'Mouse threshold' (Show-Val $mth) '0' ([string]$mth -eq '0')
    $mq = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize').Value
    Add-TuneRow 'Mouse driver queue' (Show-Val $mq) '16 (after reboot)' ([string]$mq -eq '16')
    $kq = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize').Value
    Add-TuneRow 'Keyboard driver queue' (Show-Val $kq) '20 (after reboot)' ([string]$kq -eq '20')

    $wps = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation').Value
    Add-TuneRow 'Win32PrioritySeparation' (Show-Val $wps) '38' ([string]$wps -eq '38')
    $games = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    $gp = (Get-RegValue $games 'GPU Priority').Value
    Add-TuneRow 'MMCSS GPU priority' (Show-Val $gp) '8' ([string]$gp -eq '8')
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $nti = (Get-RegValue $sp 'NetworkThrottlingIndex').Value
    Add-TuneRow 'Network throttling' (Show-Val $nti) '-1 (off)' ([string]$nti -eq '-1')
    $sr = (Get-RegValue $sp 'SystemResponsiveness').Value
    Add-TuneRow 'SystemResponsiveness' (Show-Val $sr) '0' ([string]$sr -eq '0')

    $ifk = Get-PrimaryInterfaceKey
    if ($ifk) {
        $ack = (Get-RegValue $ifk 'TcpAckFrequency').Value
        Add-TuneRow 'Nagle: TcpAckFrequency' (Show-Val $ack) '1' ([string]$ack -eq '1')
        $nd = (Get-RegValue $ifk 'TCPNoDelay').Value
        Add-TuneRow 'Nagle: TCPNoDelay' (Show-Val $nd) '1' ([string]$nd -eq '1')
        $da = (Get-RegValue $ifk 'TcpDelAckTicks').Value
        Add-TuneRow 'Delayed ACK' (Show-Val $da) '0 (off)' ([string]$da -eq '0')
    }

    $qos = (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit').Value
    Add-TuneRow 'QoS reserved bandwidth' (Show-Val $qos) '0 (%)' ([string]$qos -eq '0')
    $do = (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode').Value
    Add-TuneRow 'Delivery Optimization' (Show-Val $do) '1 (LAN only)' ([string]$do -eq '1')

    foreach ($svc in @('Ndu', 'DiagTrack', 'SysMain', 'WSearch')) {
        $st = (Get-RegValue ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svc) 'Start').Value
        $txt = Show-Val $st
        if ([string]$st -eq '4') {
            $txt = 'disabled'
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Running') { $txt = 'disabled (needs reboot)' }
        }
        Add-TuneRow ('Service ' + $svc) $txt 'disabled' ([string]$st -eq '4')
    }

    $hags = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode').Value
    Add-TuneRow 'HAGS (GPU scheduling)' (Show-Val $hags) '2 (on)' ([string]$hags -eq '2')
    $tdr = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay').Value
    Add-TuneRow 'TdrDelay' (Show-Val $tdr) '10' ([string]$tdr -eq '10')
    $dvr = (Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled').Value
    Add-TuneRow 'Game DVR' (Show-Val $dvr) '0 (off)' ([string]$dvr -eq '0')

    $n = 0
    foreach ($name in @('FiveM-GameCore', 'FiveM-GTAProc', 'FiveM-Server-UDP')) {
        if (Test-Path ('HKLM:\SOFTWARE\Policies\Microsoft\Windows\QoS\' + $name)) { $n++ }
    }
    Add-TuneRow 'FiveM QoS / DSCP rules' ($n.ToString() + ' of 3') '3' ($n -eq 3)

    return $script:TuneRows
}

function Show-Val {
    param($v)
    if ($null -eq $v) { return 'not set' }
    return [string]$v
}

function Show-TuningReport {
    $rows = @(Get-TuningReport)
    if ($rows.Count -eq 0) { Warn 'could not read the tuning values'; return $false }
    $pass = @($rows | Where-Object { $_.Pass }).Count
    Write-Host ''
    Write-Host '  VERIFYING THE TUNING  (live values read from this machine)' -ForegroundColor DarkCyan
    Write-Rule 70
    foreach ($r in $rows) {
        $tag = 'FAIL'
        $col = 'Red'
        if ($r.Pass) { $tag = ' OK '; $col = 'Green' }
        $live = $r.Live
        if ($live.Length -gt 22) { $live = $live.Substring(0, 22) }
        $want = $r.Want
        if ($want.Length -gt 17) { $want = $want.Substring(0, 17) }
        Write-Host ('   [' + $tag + '] ') -NoNewline -ForegroundColor $col
        Write-Host $r.Name.PadRight(24) -NoNewline -ForegroundColor Gray
        Write-Host ('now ' + $live).PadRight(26) -NoNewline -ForegroundColor DarkGray
        Write-Host ('want ' + $want) -ForegroundColor DarkGray
    }
    Write-Rule 70
    Write-Host ('   SCORE  ' + $pass + ' / ' + $rows.Count) -NoNewline -ForegroundColor Yellow
    if ($pass -eq $rows.Count) { Write-Host '   everything is live' -ForegroundColor Green }
    else { Write-Host '   press START, then reboot once for the rest' -ForegroundColor DarkYellow }
    return ($pass -eq $rows.Count)
}

function Format-Delta {
    param($v)
    if ($null -eq $v) { return 'n/a' }
    $d = [double]$v
    if ([Math]::Abs($d) -lt 0.05) { return 'same' }
    if ($d -gt 0) { return '+' + $d }
    return [string]$d
}

function Measure-NetworkLatency {
    # uses the built-in ping.exe and only reads lines carrying TTL=, so the
    # reply times parse correctly even on a localized Windows
    param([string]$Target, [int]$Count = 20, [int]$TimeoutMs = 1000)
    if (-not $Target) { return $null }
    $rtt = @()
    $out = @()
    try { $out = @(& ping.exe -n $Count -w $TimeoutMs $Target 2>$null) } catch { $out = @() }
    foreach ($line in $out) {
        $s = [string]$line
        if ($s -notmatch 'TTL=') { continue }
        if ($s -match '<\s*1\s*ms') { $rtt += 0; continue }
        if ($s -match '(\d+)\s*ms') { $rtt += [int]$Matches[1] }
    }
    if ($out.Count -eq 0) {
        # ping.exe unavailable - fall back to the WMI based cmdlet
        try {
            foreach ($r in @(Test-Connection -ComputerName $Target -Count $Count -ErrorAction SilentlyContinue)) {
                if ($null -ne $r.ResponseTime) { $rtt += [int]$r.ResponseTime }
            }
        } catch { }
    }
    $recv = $rtt.Count
    $loss = [Math]::Round((($Count - $recv) / $Count) * 100, 1)
    if ($recv -eq 0) {
        return [pscustomobject]@{ Target = $Target; Recv = 0; Loss = 100.0; Min = $null; Avg = $null; Max = $null; Jitter = $null }
    }
    $min = ($rtt | Measure-Object -Minimum).Minimum
    $max = ($rtt | Measure-Object -Maximum).Maximum
    $avg = [Math]::Round((($rtt | Measure-Object -Average).Average), 1)
    $jit = 0
    if ($recv -ge 2) {
        $d = @()
        for ($i = 1; $i -lt $recv; $i++) { $d += [Math]::Abs($rtt[$i] - $rtt[$i - 1]) }
        $jit = [Math]::Round((($d | Measure-Object -Average).Average), 1)
    }
    return [pscustomobject]@{ Target = $Target; Recv = $recv; Loss = $loss; Min = $min; Avg = $avg; Max = $max; Jitter = $jit }
}

function Get-GatewayTarget {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
        if ($r -and $r.NextHop -and $r.NextHop -ne '0.0.0.0') { return [string]$r.NextHop }
    } catch { }
    return $null
}

function Get-FiveMServerTarget {
    try {
        $ids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'FiveM*' }).Id
        if (-not $ids) { return $null }
        $conns = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess })
        foreach ($c in $conns) {
            $ip = [string]$c.RemoteAddress
            if ($ip -and $ip -ne '127.0.0.1' -and $ip -notlike '*:*') { return $ip }
        }
    } catch { }
    return $null
}

function Show-LatencyReport {
    param([int]$Count = 20)
    Write-Host ''
    Write-Host '  NETWORK LATENCY TEST  (real round-trip time, jitter and packet loss)' -ForegroundColor DarkCyan
    Write-Rule 70
    $targets = @()
    $srv = Get-FiveMServerTarget
    if ($srv) { $targets += [pscustomobject]@{ Label = 'FiveM server'; Ip = $srv } }
    $gw = Get-GatewayTarget
    if ($gw) { $targets += [pscustomobject]@{ Label = 'Router (1st hop)'; Ip = $gw } }
    $targets += [pscustomobject]@{ Label = 'Internet 1.1.1.1'; Ip = '1.1.1.1' }
    if (-not $srv) { Info 'FiveM is not running - connect to a server first to measure the real game path' }
    Info ('measuring ' + $targets.Count + ' target(s), one ping per second - this takes about ' + $Count + ' seconds each')
    $out = @()
    foreach ($t in $targets) {
        Write-Host ('   testing ' + $t.Label + ' (' + $t.Ip + ') ...') -ForegroundColor DarkGray
        $m = Measure-NetworkLatency -Target $t.Ip -Count $Count
        if ($m) { $out += [pscustomobject]@{ Label = $t.Label; Ip = $t.Ip; Min = $m.Min; Avg = $m.Avg; Max = $m.Max; Jitter = $m.Jitter; Loss = $m.Loss } }
    }
    Write-Host ''
    Write-Host '   TARGET               AVG       MIN       MAX       JITTER    LOSS' -ForegroundColor DarkCyan
    foreach ($m in $out) {
        if ($null -eq $m.Avg) {
            Write-Host ('   ' + $m.Label.PadRight(21) + 'no reply (host unreachable or ICMP blocked)') -ForegroundColor Red
            continue
        }
        $col = 'Green'
        if ($m.Jitter -gt 8 -or $m.Loss -gt 0) { $col = 'Yellow' }
        if ($m.Jitter -gt 20 -or $m.Loss -gt 5) { $col = 'Red' }
        Write-Host ('   ' + $m.Label.PadRight(21)) -NoNewline -ForegroundColor Gray
        Write-Host ((([string]$m.Avg) + ' ms').PadRight(10)) -NoNewline -ForegroundColor $col
        Write-Host ((([string]$m.Min) + ' ms').PadRight(10)) -NoNewline -ForegroundColor DarkGray
        Write-Host ((([string]$m.Max) + ' ms').PadRight(10)) -NoNewline -ForegroundColor DarkGray
        Write-Host ((([string]$m.Jitter) + ' ms').PadRight(10)) -NoNewline -ForegroundColor $col
        Write-Host (([string]$m.Loss) + ' %') -ForegroundColor $col
    }
    $histFile = Join-Path (Join-Path $env:ProgramData 'FreebuffGaming') 'latency.json'
    $prev = @()
    if (Test-Path $histFile) {
        try {
            # NOTE: @( ... | ConvertFrom-Json ) nests a JSON array into one element,
            # so the array is flattened explicitly here
            $raw = Get-Content -Path $histFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in $raw) { if ($e) { $prev += $e } }
        } catch { $prev = @() }
    }
    if ($prev.Count -gt 0) {
        Write-Host ''
        Write-Host '   CHANGE SINCE THE LAST TEST   (negative ping/jitter = better)' -ForegroundColor DarkCyan
        $shown = 0
        foreach ($m in $out) {
            $p = $prev | Where-Object { $_.Label -eq $m.Label -and $_.Ip -eq $m.Ip } | Select-Object -First 1
            if (-not $p) { continue }
            if ($null -eq $m.Avg -or $null -eq $p.Avg) { continue }
            $dAvg = 0.0; $dJit = 0.0; $dLoss = 0.0
            try {
                $dAvg  = [Math]::Round(([double]$m.Avg - [double]$p.Avg), 1)
                $dJit  = [Math]::Round(([double]$m.Jitter - [double]$p.Jitter), 1)
                $dLoss = [Math]::Round(([double]$m.Loss - [double]$p.Loss), 1)
            } catch { continue }
            Write-Host ('   ' + $m.Label.PadRight(21)) -NoNewline -ForegroundColor Gray
            Write-Host ('ping ' + (Format-Delta $dAvg).PadRight(12) + 'jitter ' + (Format-Delta $dJit).PadRight(12) + 'loss ' + (Format-Delta $dLoss)) -ForegroundColor DarkGray
            $shown++
        }
        if ($shown -eq 0) { Info 'no comparable row (the target changed, or the last test had no reply)' }
    }
    Write-Host ''
    Write-Host '   HOW TO READ THIS' -ForegroundColor DarkCyan
    Write-Host '   . Router row jittery  -> your own cable / router / NIC is the problem' -ForegroundColor Gray
    Write-Host '   . Router fine, server row jittery -> it is the ISP path or the server itself' -ForegroundColor Gray
    Write-Host '   . loss above 0 % -> packets are being dropped; nothing on the PC can fix that' -ForegroundColor Gray
    $stamp = @()
    foreach ($m in $out) { $stamp += [pscustomobject]@{ Label = $m.Label; Ip = $m.Ip; Avg = $m.Avg; Jitter = $m.Jitter; Loss = $m.Loss; When = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
    try { $stamp | ConvertTo-Json -Depth 4 | Set-Content -Path $histFile -Encoding UTF8 } catch { }
    Add-Log ('latency test: ' + (($out | ForEach-Object { $_.Label + ' avg=' + $_.Avg + ' jitter=' + $_.Jitter + ' loss=' + $_.Loss }) -join ' | '))
}

# =============================================================================
#  MENU
# =============================================================================
#  MENU
# =============================================================================
$script:Menu = @(
    @{ Key = '1'; Id = 'start'; Title = 'START'; Desc = 'tune everything for FiveM + launch the booster' },
    @{ Key = '2'; Id = 'reset'; Title = 'RESET'; Desc = 'restore every change back to the baseline' },
    @{ Key = '3'; Id = 'test';  Title = 'TEST';  Desc = 'measure ping / jitter / loss + verify the tuning for real' }
)

function Show-Choice {
    param([string]$Title, [int]$Selected = 0)
    $items = $script:Menu
    $status = @(Get-StatusLines)
    $sel = $Selected
    while ($true) {
        Clear-Host
        Show-Banner
        Write-Host ''
        Write-Host ('  ' + $Title) -ForegroundColor Yellow
        Write-Host ('  ' + ('=' * 58)) -ForegroundColor DarkCyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $line = '  [{0}] {1}   {2}' -f $it.Key, $it.Title, $it.Desc
            if ($i -eq $sel) {
                Write-Host ('  ' + $line.TrimStart()) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ('   ' + $line.TrimStart()) -ForegroundColor Gray
            }
        }
        Write-Host ''
        Write-Host '  MACHINE STATUS' -ForegroundColor DarkCyan
        foreach ($l in $status) {
            Write-Host '   . ' -NoNewline -ForegroundColor DarkGray
            Write-Host $l.L.PadRight(14) -NoNewline -ForegroundColor Gray
            Write-Host $l.V -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Up / Down select   .   Enter confirm   .   press 1, 2 or 3   .   Esc quit' -ForegroundColor DarkYellow
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'UpArrow')   { $sel = ($sel - 1 + $items.Count) % $items.Count; continue }
        if ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $items.Count; continue }
        if ($k.Key -eq 'Escape')    { return $null }
        if ($k.Key -eq 'Enter')     { return $items[$sel] }
        $ch = [string]$k.KeyChar
        if ($ch -and $ch -ne [string][char]0) {
            foreach ($it in $items) { if ($it.Key -eq $ch) { return $it } }
        }
    }
}

# =============================================================================
#  APPLY SEQUENCES
# =============================================================================
function Invoke-ApplyAll {
    param([switch]$WithProgress)
    $steps = @(
        @{ N = 'Power plan, CPU boost, USB/PCIe/disk power'; A = { Invoke-PowerTweaks } },
        @{ N = 'Mouse and keyboard latency';                 A = { Invoke-InputTweaks -Queues } },
        @{ N = 'Game mode, DVR off, MMCSS priorities';       A = { Invoke-GameCoreTweaks } },
        @{ N = 'TCP stack: Nagle, RSC, ECN, auto-tuning';    A = { Invoke-TcpBaseTweaks } },
        @{ N = 'Latency: delayed ACK, heuristics, NIC buffers'; A = { Invoke-LatencyHardening } },
        @{ N = 'Network adapter tuning + DNS';               A = { Invoke-NicTweaks -Dns } },
        @{ N = 'Windows policies (gpedit equivalent)';       A = { Invoke-PolicyTweaks } },
        @{ N = 'Graphics: MPO, fullscreen opt, HAGS';        A = { Invoke-GraphicsTweaks -Full } },
        @{ N = 'Background services';                        A = { Invoke-ServiceTweaks } },
        @{ N = 'FiveM QoS / DSCP priority';                  A = { Invoke-FiveMQosTweaks } }
    )
    $i = 0
    foreach ($s in $steps) {
        $i++
        if ($WithProgress) { Show-ProgressBar -Index $i -Total $steps.Count -Label $s.N }
        & $s.A
    }
    Save-Backup
    if ($script:AppliedModules -notcontains 'High') { $script:AppliedModules += 'High' }
}

function Invoke-ApplyLight {
    Invoke-PowerTweaks
    Invoke-InputTweaks
    Invoke-GameCoreTweaks
    Invoke-TcpBaseTweaks
    if ($script:AppliedModules -notcontains 'Low') { $script:AppliedModules += 'Low' }
}

function Show-Result {
    param([string]$Level)
    $bullets = @()
    switch ($Level.ToLower()) {
        'high'   { $bullets = @('Power plan + CPU boost, no core parking, no power throttling', 'Mouse 1:1 and faster keyboard input', 'Game priority: MMCSS, Win32PrioritySeparation, Game DVR off', 'Network: Nagle + delayed ACK off, RSC/ECN off, NIC buffers maxed', 'Adapter tuned, DNS 1.1.1.1, Windows cannot power the NIC down', 'System policies (gpedit): QoS 0%, LLMNR off, NCSI off', 'Graphics: MPO off, fullscreen optimizations off, HAGS, TdrDelay', 'Background services disabled: Ndu / DiagTrack / SysMain / WSearch', 'FiveM QoS DSCP 46 for FiveM.exe, GTAProcess.exe and UDP 30120') }
        'low'    { $bullets = @('Power plan + CPU boost', 'Mouse 1:1 and faster keyboard input', 'Game mode on, Game DVR off', 'Nagle disabled (no packet waiting)') }
        default  { $bullets = @('Selected module finished') }
    }
    Write-Host ''
    Write-Host ('  [DONE] ' + $Level.ToUpper() + ' applied') -ForegroundColor Green
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    foreach ($b in $bullets) { Write-Host ('   . ' + $b) -ForegroundColor Gray }
    Write-Host ''
    Write-Host '  Reboot once so services, HAGS and NIC values fully apply.' -ForegroundColor Yellow
}

# =============================================================================
#  CLI DISPATCH
# =============================================================================
if ($Booster) {
    # booster mode: no menu, no backup work, just the runtime boost
    Start-BoosterSession -Priority $Priority -NoAffinity:$NoAffinity
    exit 0
}

Add-Log '================ START ================'
Load-Backup
Clear-Host

if ($Latency) {
    Show-Banner
    Show-LatencyReport
    exit 0
}

if ($Verify) {
    Show-Banner
    $null = Show-TuningReport
    exit 0
}

if ($Preview) {
    Show-Banner
    Write-Host ''
    Write-Host '  PROJECT X  .  START = tune / RESET = restore      (PREVIEW - nothing changes)' -ForegroundColor Yellow
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor DarkCyan
    foreach ($it in $script:Menu) {
        Write-Host ('  [{0}] {1}   {2}' -f $it.Key, $it.Title, $it.Desc) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Status
    Write-Host ''
    Write-Host '  Up / Down select   .   Enter confirm   .   press 1, 2 or 3   .   Esc quit' -ForegroundColor DarkYellow
    Write-Host ''
    exit 0
}

if ($ResetDefaults) {
    Show-Banner
    Reset-ToWindowsDefaults -PowerPlan $PowerPlan
    if (Test-Path $BackupFile) {
        $stale = Join-Path $BackupDir ('backup.before-reset.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        try { Move-Item -Path $BackupFile -Destination $stale -Force; Info ('old backup archived as: ' + $stale) } catch { }
    }
    exit 0
}

if ($Restore) {
    Show-Banner
    if ($Restore -eq 'strike' -or $Restore -eq 'all') {
        if (Test-Path $BackupFile) {
            $b = $null
            try { $b = Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $b = $null }
            if ($b) { Restore-Strike -b $b } else { Err 'could not read the backup file' }
        } else { Warn 'no backup file found (strike-backup.json)' }
    }
    if ($Restore -eq 'old' -or $Restore -eq 'all') {
        $oldRoot = $PSScriptRoot
        if (-not $oldRoot -and $script:SelfPath) { $oldRoot = Split-Path -Parent $script:SelfPath }
        $oldScript = ''
        if ($oldRoot) { $oldScript = Join-Path $oldRoot 'Gaming-Optimize.ps1' }
        if ($oldScript -and (Test-Path $oldScript) -and (Test-Path $OldBackupFile)) {
            try {
                Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $oldScript + '"'), '-Undo') -Wait
                Ok 'restored by the legacy script'
            } catch { Err 'legacy restore failed' }
        } else { Warn 'legacy script or its backup file not found' }
    }
    exit 0
}

if ($Apply) {
    Show-Banner
    Write-Host ''
    Write-Host ('  AUTOMATIC MODE: applying level ' + $Apply.ToUpper()) -ForegroundColor Yellow
    switch ($Apply.ToLower()) {
        'low'    { Invoke-ApplyLight }
        'medium' { Invoke-ApplyLight; Invoke-InputTweaks -Queues; Invoke-NicTweaks -Dns; Invoke-PolicyTweaks; Invoke-GraphicsTweaks }
        'high'   { Invoke-ApplyAll }
        'net'    { Invoke-TcpBaseTweaks; Invoke-NicTweaks -Dns; Invoke-PolicyTweaks }
        'input'  { Invoke-InputTweaks -Queues; Invoke-GraphicsTweaks }
        'gpedit' { Invoke-PolicyTweaks; Invoke-GameCoreTweaks }
        'fivem'  { Invoke-FiveMQosTweaks; Invoke-GraphicsTweaks -Full }
        'clean'  { Invoke-Clean }
    }
    Save-Backup
    Show-Result $Apply
    Write-Host ''
    Info ('backup file: ' + $BackupFile)
    Info 'to undo: run this script again and press RESET'
    exit 0
}

# =============================================================================
#  INTERACTIVE MENU
# =============================================================================
Set-WideConsole
if (-not $NoAnim) { try { Show-Intro } catch { Clear-Host; Show-Banner } } else { Clear-Host; Show-Banner }

$running = $true
while ($running) {
    $choice = Show-Choice -Title 'PROJECT X  .  START to tune  /  RESET to restore'
    if ($null -eq $choice) { break }

    Clear-Host
    Show-Banner
    switch ($choice.Id) {
        'start' {
            Head 'START - tuning everything for FiveM'
            Invoke-ApplyAll -WithProgress
            $launched = $true
            if (Test-BoosterRunning) { Info 'booster is already running - not starting a second one' }
            else { $launched = Start-BoosterWindow }
            Show-Result 'high'
            Show-Stamp -Text 'PROJECT X ONLINE' -Color 'Green' -Flash
            Write-Host ''
            Info 'first run: reboot once so every value is fully active'
            Info 'press 3 (TEST) at any time to measure the real effect'
            if ($launched) {
                Pause-Menu
            } else {
                Write-Host ''
                Write-Host '  >> BOOSTER - running in this window from now on' -ForegroundColor Yellow
                Write-Rule 58
                Write-Host '   leave this window open while you play   .   Ctrl+C to stop' -ForegroundColor Yellow
                Write-Host ''
                Start-BoosterSession -Priority $Priority -NoAffinity:$NoAffinity
            }
        }
        'reset' {
            Head 'RESET - restoring the baseline'
            if (Test-BoosterRunning) { Stop-Booster }
            if (-not $NoAnim) { Show-DrainBar -Label 'RESTORING' }
            if (Test-Path $BackupFile) {
                $b = $null
                try { $b = Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $b = $null }
                if ($b) { Restore-Strike -b $b } else { Err 'could not read the backup file' }
            } else {
                Warn 'no backup found - falling back to Windows defaults'
                Reset-ToWindowsDefaults
            }
            Write-Host ''
            Info 'reboot once after restoring'
            Pause-Menu
        }
        'test' {
            Head 'TEST - measure the real effect (nothing is changed)'
            Show-LatencyReport
            Write-Host ''
            $null = Show-TuningReport
            Pause-Menu
        }
    }
}

Clear-Host
Show-Banner
Write-Host ''
Write-Host '  Session closed. Thanks for using PROJECT X.' -ForegroundColor Green
Write-Host '  Reminder: run the booster while you play FiveM.' -ForegroundColor Yellow
Write-Host ''
Add-Log '================ END ================'
