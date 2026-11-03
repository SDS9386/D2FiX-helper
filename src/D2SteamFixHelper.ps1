#Requires -Version 5.1
<#
    D2SteamFix 한국어 설치 도우미

    steamfix.exe 자체는 포함하지 않습니다. GitHub 공식 릴리스에서 받은
    공식 바이너리를 그대로 사용하고, 이 도구는 아래 작업만 대신합니다.

      - Steam / Destiny 2 설치 경로 자동 탐지
      - steamfix.exe 가 올바른 위치에 있는지 확인
      - Steam 실행 옵션 문자열 생성 및 자동 기록(localconfig.vdf)
      - 설정 되돌리기

    원본 프로젝트: https://github.com/d2checkpoint-com/D2SteamFix (GPL-2.0)
    이 도우미는 원본 코드를 포함하지 않는 별개의 보조 도구입니다.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$script:AppId       = '1085660'
$script:GameName    = 'Destiny 2'
$script:ExeName     = 'steamfix.exe'
$script:RepoUrl     = 'https://github.com/d2checkpoint-com/D2SteamFix'
# 공식 최신 릴리스 페이지에서 사용자가 직접 받는다.
$script:GuideUrl    = 'https://github.com/d2checkpoint-com/D2SteamFix#installation'
$script:DownloadUrl = 'https://github.com/d2checkpoint-com/D2SteamFix/releases/latest'
# 백업은 %LOCALAPPDATA% 에 둔다. 도우미 폴더 옆에 두면 찾기는 쉽지만,
# 권한 없는 위치에 넣거나 압축을 풀지 않고 실행하면 백업이 실패하거나 사라진다.
# 위치는 3단계 아래에 그대로 표시하고 눌러서 열 수 있게 해 두었다.
$script:StateDir     = Join-Path $env:LOCALAPPDATA 'D2SteamFixHelper'
$script:SettingsPath = Join-Path $script:StateDir 'settings.json'
$script:BackupKeep   = 20   # 보관할 백업 개수 (1개당 약 250KB)
$script:WindowTitle  = 'D2SteamFix 한국어 설치 도우미'
$script:MutexName    = 'Local\D2SteamFixHelperKR-SingleInstance'

# ---------------------------------------------------------------------------
# VDF 파서
#
# localconfig.vdf 안에는 앱 ID와 같은 문자열이 실행 옵션과 무관한 위치에도
# 등장한다. 단순 문자열 검색으로는 엉뚱한 곳을 고치게 되므로 블록 구조를
# 실제로 따라 내려간다.
# ---------------------------------------------------------------------------

function Skip-VdfWhitespace {
    param([string]$Text, [hashtable]$Cur, [int]$End)
    while ($Cur.i -lt $End) {
        $c = $Text[$Cur.i]
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n") { $Cur.i++; continue }
        if ($c -eq '/' -and ($Cur.i + 1) -lt $End -and $Text[$Cur.i + 1] -eq '/') {
            while ($Cur.i -lt $End -and $Text[$Cur.i] -ne "`n") { $Cur.i++ }
            continue
        }
        break
    }
}

function Read-VdfToken {
    param([string]$Text, [hashtable]$Cur, [int]$End)

    Skip-VdfWhitespace -Text $Text -Cur $Cur -End $End
    if ($Cur.i -ge $End) { return $null }

    $start = $Cur.i
    $c = $Text[$Cur.i]

    if ($c -eq '{' -or $c -eq '}') {
        $Cur.i++
        return @{ Type = [string]$c; Value = [string]$c; Start = $start; End = $Cur.i }
    }

    if ($c -eq '"') {
        $Cur.i++
        $sb = New-Object System.Text.StringBuilder
        while ($Cur.i -lt $End) {
            $ch = $Text[$Cur.i]
            if ($ch -eq '\') {
                $Cur.i++
                if ($Cur.i -lt $End) { [void]$sb.Append($Text[$Cur.i]); $Cur.i++ }
                continue
            }
            if ($ch -eq '"') { $Cur.i++; break }
            [void]$sb.Append($ch)
            $Cur.i++
        }
        return @{ Type = 'str'; Value = $sb.ToString(); Start = $start; End = $Cur.i }
    }

    while ($Cur.i -lt $End -and $Text[$Cur.i] -notmatch '[\s{}"]') { $Cur.i++ }
    return @{ Type = 'str'; Value = $Text.Substring($start, $Cur.i - $start); Start = $start; End = $Cur.i }
}

# 하위 블록의 끝(짝이 맞는 '}')만 찾는다. 안쪽 내용을 토큰으로 만들지 않기
# 때문에 250KB짜리 localconfig.vdf 에서도 충분히 빠르다.
function Find-VdfBlockEnd {
    param([string]$Text, [int]$Start, [int]$End)

    $i = $Start
    $depth = 1
    while ($i -lt $End) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $i++
            while ($i -lt $End) {
                $ch = $Text[$i]
                if ($ch -eq '\') { $i += 2; continue }
                $i++
                if ($ch -eq '"') { break }
            }
            continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $End -and $Text[$i + 1] -eq '/') {
            while ($i -lt $End -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        $i++
        if ($c -eq '{') { $depth++; continue }
        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return ($i - 1) }
        }
    }
    return $End
}

function Get-VdfEntries {
    param([string]$Text, [int]$Start, [int]$End)

    $entries = @()
    $cur = @{ i = $Start }

    while ($cur.i -lt $End) {
        $keyTok = Read-VdfToken -Text $Text -Cur $cur -End $End
        if ($null -eq $keyTok -or $keyTok.Type -eq '}') { break }
        if ($keyTok.Type -ne 'str') { continue }

        $valTok = Read-VdfToken -Text $Text -Cur $cur -End $End
        if ($null -eq $valTok) { break }

        if ($valTok.Type -eq '{') {
            $contentStart = $valTok.End
            $contentEnd   = Find-VdfBlockEnd -Text $Text -Start $contentStart -End $End
            $entryEnd     = [Math]::Min($contentEnd + 1, $End)
            $cur.i        = $entryEnd
            $entries += @{
                Key          = $keyTok.Value
                Kind         = 'block'
                EntryStart   = $keyTok.Start
                EntryEnd     = $entryEnd
                ContentStart = $contentStart
                ContentEnd   = $contentEnd
            }
        }
        else {
            $entries += @{
                Key        = $keyTok.Value
                Kind       = 'value'
                Value      = $valTok.Value
                EntryStart = $keyTok.Start
                EntryEnd   = $valTok.End
                ValueStart = $valTok.Start
                ValueEnd   = $valTok.End
            }
        }
    }

    return $entries
}

function Find-VdfBlock {
    param([string]$Text, [string[]]$Path)

    $start = 0
    $end   = $Text.Length

    foreach ($key in $Path) {
        $found = $null
        foreach ($e in (Get-VdfEntries -Text $Text -Start $start -End $end)) {
            if ($e.Kind -eq 'block' -and [string]::Equals($e.Key, $key, 'OrdinalIgnoreCase')) { $found = $e; break }
        }
        if ($null -eq $found) { return $null }
        $start = $found.ContentStart
        $end   = $found.ContentEnd
    }

    return @{ ContentStart = $start; ContentEnd = $end }
}

function ConvertTo-VdfString {
    param([string]$Value)
    '"' + (($Value -replace '\\', '\\') -replace '"', '\"') + '"'
}

# ---------------------------------------------------------------------------
# Steam / 게임 경로 탐지
# ---------------------------------------------------------------------------

# 레지스트리의 SteamPath 는 전부 소문자로 들어 있다. 동작에는 문제가 없지만
# 화면과 실행 옵션에 그대로 노출되므로 디스크의 실제 표기로 맞춘다.
function Get-CanonicalPath {
    param([string]$Path)
    try {
        $dir   = New-Object System.IO.DirectoryInfo((Get-Item -LiteralPath $Path -ErrorAction Stop).FullName)
        $parts = @()
        while ($dir.Parent) {
            $real = @($dir.Parent.GetFileSystemInfos($dir.Name)) | Select-Object -First 1
            if ($real) { $parts = @($real.Name) + $parts } else { $parts = @($dir.Name) + $parts }
            $dir = $dir.Parent
        }
        return ($dir.Name.ToUpper() + ($parts -join '\'))
    }
    catch { return $Path }
}

function Get-SteamPath {
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $props = $null
        try { $props = Get-ItemProperty -Path $key -ErrorAction Stop } catch { continue }
        foreach ($name in @('SteamPath', 'InstallPath')) {
            if (-not $props.PSObject.Properties[$name]) { continue }
            $value = [string]$props.$name
            if (-not $value) { continue }
            $value = $value -replace '/', '\'
            if (Test-Path $value) { return (Get-CanonicalPath -Path $value) }
        }
    }
    return $null
}

function Get-SteamLibraries {
    param([string]$SteamPath)

    $libs = New-Object System.Collections.Generic.List[string]
    $libs.Add($SteamPath)

    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $text = [System.IO.File]::ReadAllText($vdf)
        $root = Find-VdfBlock -Text $text -Path @('libraryfolders')
        if ($root) {
            foreach ($entry in (Get-VdfEntries -Text $text -Start $root.ContentStart -End $root.ContentEnd)) {
                if ($entry.Kind -ne 'block') { continue }
                foreach ($child in (Get-VdfEntries -Text $text -Start $entry.ContentStart -End $entry.ContentEnd)) {
                    if ($child.Kind -eq 'value' -and [string]::Equals($child.Key, 'path', 'OrdinalIgnoreCase')) {
                        if ($child.Value -and (Test-Path $child.Value)) { $libs.Add((Get-CanonicalPath -Path $child.Value)) }
                    }
                }
            }
        }
    }

    return ($libs | Select-Object -Unique)
}

# 게임을 다른 라이브러리로 옮기면 예전 자리에 빈 "Destiny 2" 폴더나 매니페스트가
# 남아 있는 경우가 있다. 폴더가 있다는 것만으로 게임이 거기 있다고 단정하면 엉뚱한
# 경로를 잡고, 그 경로로 실행 옵션을 기록하면 Steam 이 없는 파일을 실행하려다 실패한다.
# (그 경우 steamfix 는 시작조차 못 하므로 로그도 남지 않는다)
# 그래서 destiny2.exe 가 실제로 들어 있는 폴더를 우선한다.
function Get-Destiny2Path {
    param([string]$SteamPath)

    $withGame    = @()
    $folderOnly  = @()

    foreach ($lib in (Get-SteamLibraries -SteamPath $SteamPath)) {
        $installDir = $null

        $acf = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f $script:AppId)
        if (Test-Path $acf) {
            $text  = [System.IO.File]::ReadAllText($acf)
            $state = Find-VdfBlock -Text $text -Path @('AppState')
            if ($state) {
                foreach ($e in (Get-VdfEntries -Text $text -Start $state.ContentStart -End $state.ContentEnd)) {
                    if ($e.Kind -eq 'value' -and [string]::Equals($e.Key, 'installdir', 'OrdinalIgnoreCase')) { $installDir = $e.Value }
                }
            }
        }
        # 매니페스트가 없어도 기본 폴더명으로 한 번 더 확인한다.
        if (-not $installDir) { $installDir = $script:GameName }

        $full = Join-Path $lib ('steamapps\common\{0}' -f $installDir)
        if (-not (Test-Path $full)) { continue }

        if (Test-Path (Join-Path $full 'destiny2.exe')) { $withGame += $full }
        else { $folderOnly += $full }
    }

    if ($withGame.Count   -gt 0) { return (Get-CanonicalPath -Path $withGame[0]) }
    if ($folderOnly.Count -gt 0) { return (Get-CanonicalPath -Path $folderOnly[0]) }
    return $null
}

# 잡아낸 폴더에 게임 본체가 없으면 사용자에게 알려야 한다. 그대로 설정하면
# 게임이 실행되지 않는다.
function Test-GameFilesPresent {
    param([string]$GameDir)
    if (-not $GameDir) { return $false }
    return (Test-Path (Join-Path $GameDir 'destiny2.exe'))
}

# steamfix 는 자기 옆에 steamfix.log 와 steamfix.dat 를 만든다. 그 폴더에 쓰기 권한이
# 없으면 로그 초기화 단계에서 바로 죽는다(원본 종료 코드 11). 로그를 못 만든 상태라
# 원인을 알려줄 로그도 남지 않아 "프로세스 실패"만 보인다.
# 다른 드라이브에 직접 만든 Steam 라이브러리는 권한이 다를 수 있어 미리 확인한다.
function Test-FolderWritable {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    $probe = Join-Path $Path ('.d2sfh-write-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-SteamAccounts {
    param([string]$SteamPath)

    $accounts = @()
    $userdata = Join-Path $SteamPath 'userdata'
    if (-not (Test-Path $userdata)) { return $accounts }

    $names      = @{}
    $mostRecent = $null

    $loginUsers = Join-Path $SteamPath 'config\loginusers.vdf'
    if (Test-Path $loginUsers) {
        $text  = [System.IO.File]::ReadAllText($loginUsers)
        $users = Find-VdfBlock -Text $text -Path @('users')
        if ($users) {
            foreach ($entry in (Get-VdfEntries -Text $text -Start $users.ContentStart -End $users.ContentEnd)) {
                if ($entry.Kind -ne 'block') { continue }
                [long]$sid64 = 0
                if (-not [long]::TryParse($entry.Key, [ref]$sid64)) { continue }
                $accountId = [string]($sid64 - 76561197960265728)

                # Steam 버전에 따라 MostRecent 를 아예 쓰지 않는다. 실제로 확인한 최신
                # 클라이언트의 loginusers.vdf 에는 AutoLogin 만 있었다. 둘 다 받아준다.
                $persona = $null; $account = $null; $recent = $false
                foreach ($child in (Get-VdfEntries -Text $text -Start $entry.ContentStart -End $entry.ContentEnd)) {
                    if ($child.Kind -ne 'value') { continue }
                    if ([string]::Equals($child.Key, 'PersonaName', 'OrdinalIgnoreCase')) { $persona = $child.Value }
                    if ([string]::Equals($child.Key, 'AccountName', 'OrdinalIgnoreCase')) { $account = $child.Value }
                    if ([string]::Equals($child.Key, 'MostRecent', 'OrdinalIgnoreCase') -and $child.Value -eq '1') { $recent = $true }
                    if ([string]::Equals($child.Key, 'AutoLogin', 'OrdinalIgnoreCase') -and $child.Value -eq '1') { $recent = $true }
                }

                $label = $persona
                if (-not $label) { $label = $account }
                if ($label) { $names[$accountId] = $label }
                if ($recent) { $mostRecent = $accountId }
            }
        }
    }

    foreach ($dir in (Get-ChildItem -Path $userdata -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq '0' -or $dir.Name -eq 'ac') { continue }
        $localConfig = Join-Path $dir.FullName 'config\localconfig.vdf'
        if (-not (Test-Path $localConfig)) { continue }

        $label = $names[$dir.Name]
        if (-not $label) { $label = "계정 $($dir.Name)" }

        $accounts += [pscustomobject]@{
            AccountId    = $dir.Name
            Label        = $label
            LocalConfig  = $localConfig
            IsMostRecent = ($dir.Name -eq $mostRecent)
            LastWrite    = (Get-Item $localConfig).LastWriteTime
        }
    }

    return ($accounts | Sort-Object -Property @{ Expression = 'IsMostRecent'; Descending = $true }, @{ Expression = 'LastWrite'; Descending = $true })
}

# ---------------------------------------------------------------------------
# 실행 옵션 읽기 / 쓰기
# ---------------------------------------------------------------------------

function New-LaunchString {
    param([string]$GameDir)
    '"' + (Join-Path $GameDir $script:ExeName) + '" %command%'
}

# 실행 옵션에 적힌 실행 파일 경로만 뽑아낸다.
# 따옴표가 빠진 채 저장돼 있으면 공백 앞까지만 잡히는데, 그게 바로 스팀이
# 실행하려다 실패하는 경로다. 따라서 "잘못 뽑히는 것"이 아니라 실제 동작을 재현하는 것이다.
function Get-LaunchOptionExePath {
    param([string]$Options)

    if (-not $Options) { return $null }

    $quoted = [regex]::Match($Options, '^\s*"([^"]+)"')
    if ($quoted.Success) { return $quoted.Groups[1].Value }

    $bare = [regex]::Match($Options, '^\s*(\S+)')
    if ($bare.Success) { return $bare.Groups[1].Value }

    return $null
}

function Get-LaunchOptions {
    param([string]$LocalConfigPath)

    $text = [System.IO.File]::ReadAllText($LocalConfigPath)
    $apps = Find-VdfBlock -Text $text -Path @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps')
    if (-not $apps) { return $null }

    foreach ($entry in (Get-VdfEntries -Text $text -Start $apps.ContentStart -End $apps.ContentEnd)) {
        if ($entry.Kind -ne 'block' -or $entry.Key -ne $script:AppId) { continue }
        foreach ($child in (Get-VdfEntries -Text $text -Start $entry.ContentStart -End $entry.ContentEnd)) {
            if ($child.Kind -eq 'value' -and [string]::Equals($child.Key, 'LaunchOptions', 'OrdinalIgnoreCase')) { return $child.Value }
        }
        return ''
    }

    return ''
}

function Set-LaunchOptionsText {
    param([string]$Text, [string]$NewValue)

    $apps = Find-VdfBlock -Text $Text -Path @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps')
    if (-not $apps) { throw 'localconfig.vdf 안에서 apps 섹션을 찾지 못했습니다. Steam을 한 번 실행한 뒤 다시 시도해 주세요.' }

    $appBlock = $null
    foreach ($entry in (Get-VdfEntries -Text $Text -Start $apps.ContentStart -End $apps.ContentEnd)) {
        if ($entry.Kind -eq 'block' -and $entry.Key -eq $script:AppId) { $appBlock = $entry; break }
    }

    $encoded = ConvertTo-VdfString -Value $NewValue

    if ($null -eq $appBlock) {
        $insert = "`r`n" + ("`t" * 5) + '"' + $script:AppId + '"' +
                  "`r`n" + ("`t" * 5) + '{' +
                  "`r`n" + ("`t" * 6) + '"LaunchOptions"' + "`t`t" + $encoded +
                  "`r`n" + ("`t" * 5) + '}'
        return $Text.Insert($apps.ContentStart, $insert)
    }

    $launchEntry = $null
    foreach ($child in (Get-VdfEntries -Text $Text -Start $appBlock.ContentStart -End $appBlock.ContentEnd)) {
        if ($child.Kind -eq 'value' -and [string]::Equals($child.Key, 'LaunchOptions', 'OrdinalIgnoreCase')) { $launchEntry = $child; break }
    }

    if ($launchEntry) {
        return $Text.Substring(0, $launchEntry.ValueStart) + $encoded + $Text.Substring($launchEntry.ValueEnd)
    }

    $insert = "`r`n" + ("`t" * 6) + '"LaunchOptions"' + "`t`t" + $encoded
    return $Text.Insert($appBlock.ContentStart, $insert)
}

function Merge-LaunchOptions {
    param([string]$Existing, [string]$SteamFixPart)

    $rest = [regex]::Replace($Existing, '"[^"]*steamfix\.exe"\s*', '', 'IgnoreCase')
    $rest = [regex]::Replace($rest, '(?<!\S)\S*steamfix\.exe(?!\S)\s*', '', 'IgnoreCase')
    $rest = [regex]::Replace($rest, '%command%\s*', '', 'IgnoreCase')
    $rest = $rest.Trim()

    if ($rest) { return $SteamFixPart + ' ' + $rest }
    return $SteamFixPart
}

function Remove-SteamFixFromOptions {
    param([string]$Existing)

    $rest = [regex]::Replace($Existing, '"[^"]*steamfix\.exe"\s*', '', 'IgnoreCase')
    $rest = [regex]::Replace($rest, '(?<!\S)\S*steamfix\.exe(?!\S)\s*', '', 'IgnoreCase')
    if ($rest -eq $Existing) { return $Existing }

    $rest = [regex]::Replace($rest, '^\s*%command%\s*', '', 'IgnoreCase')
    return $rest.Trim()
}

# 백업은 그냥 두면 한없이 쌓인다. 한 개가 250KB 쯤 되므로 최근 것만 남긴다.
function Remove-OldBackup {
    param([string]$Dir, [int]$Keep = 20)

    if (-not (Test-Path $Dir)) { return 0 }
    $files = @(Get-ChildItem -Path $Dir -Filter 'localconfig-*.vdf.bak' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    $old = @($files | Select-Object -Skip $Keep)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    return $old.Count
}

function Save-LocalConfig {
    param([string]$Path, [string]$Text, [string]$AccountId)

    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tag   = $AccountId
    if (-not $tag) { $tag = 'unknown' }
    $backup = Join-Path $script:StateDir ('localconfig-{0}-{1}.vdf.bak' -f $tag, $stamp)

    Copy-Item -Path $Path -Destination $backup -Force
    # Copy-Item 은 원본의 수정 시각까지 복사한다. 그대로 두면 백업을 만든 순서와
    # 파일 시각이 어긋나서 오래된 것부터 지우는 정리가 엉뚱하게 동작한다.
    (Get-Item -LiteralPath $backup).LastWriteTime = Get-Date

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))

    $removed = Remove-OldBackup -Dir $script:StateDir -Keep $script:BackupKeep
    return [pscustomobject]@{ Path = $backup; Removed = $removed }
}

# 브라우저가 오류 페이지를 steamfix.exe 라는 이름으로 저장해 버리는 경우가 있다.
# PE 실행 파일은 반드시 'MZ' 로 시작하므로 그것만 확인한다.
function Test-IsExecutable {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 2
            $read = $stream.Read($head, 0, 2)
            return ($read -eq 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A)
        }
        finally { $stream.Dispose() }
    }
    catch { return $false }
}

# 문제가 생긴 PC 를 직접 볼 수 없을 때, 원인을 가르는 항목을 한 번에 모아준다.
# 화면 캡처보다 정확하고, 주고받는 횟수를 줄인다.
function Get-DiagnosticReport {
    param([string]$SteamPath, [string]$GameDir, $Accounts)

    $out = New-Object System.Collections.Generic.List[string]
    $add = { param([string]$line) $out.Add($line) }

    & $add '=== D2SteamFix 설치 도우미 진단 정보 ==='
    & $add ('작성 시각 : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    & $add ('Windows   : {0}' -f [System.Environment]::OSVersion.Version)
    & $add ('PowerShell: {0}' -f $PSVersionTable.PSVersion)
    & $add ''

    & $add '[백신]'
    $avList = Get-InstalledAntivirus
    if ($avList.Count -gt 0) {
        foreach ($av in $avList) { & $add ('  {0} (실시간 감시 {1})' -f $av.Name, $(if ($av.RealTime) { '켜짐' } else { '꺼짐' })) }
    }
    else { & $add '  조회하지 못함' }
    & $add ''

    & $add '[Steam]'
    if ($SteamPath) {
        & $add ('설치 폴더 : {0}' -f $SteamPath)
        & $add '라이브러리:'
        foreach ($lib in (Get-SteamLibraries -SteamPath $SteamPath)) { & $add ('  - {0}' -f $lib) }
    }
    else { & $add '설치 폴더 : 찾지 못함' }
    & $add ''

    & $add '[게임 폴더]'
    if ($GameDir) {
        & $add ('경로          : {0}' -f $GameDir)
        & $add ('destiny2.exe  : {0}' -f $(if (Test-GameFilesPresent -GameDir $GameDir) { '있음' } else { '없음  <-- 빈 폴더를 잡았을 수 있음' }))
        & $add ('쓰기 권한     : {0}' -f $(if (Test-FolderWritable -Path $GameDir) { '있음' } else { '없음  <-- steamfix 가 로그를 못 만들어 즉시 종료됨' }))

        $exe = Join-Path $GameDir $script:ExeName
        if (Test-Path -LiteralPath $exe) {
            $fi = Get-Item -LiteralPath $exe
            & $add ('steamfix.exe  : 있음 ({0:N0} bytes, {1}, 실행파일={2})' -f $fi.Length, $fi.LastWriteTime, (Test-IsExecutable -Path $exe))
            & $add ('  차단 여부   : {0}' -f $(if (Test-FileBlocked -Path $exe) { '차단됨  <-- 윈도우가 실행을 막습니다. 차단 해제 필요' } else { '정상' }))
        }
        else { & $add 'steamfix.exe  : 없음  <-- 게임 폴더에 넣어야 함' }

        $log = Join-Path $GameDir 'steamfix.log'
        if (Test-Path -LiteralPath $log) {
            $lf = Get-Item -LiteralPath $log
            & $add ('steamfix.log  : 있음 ({0:N0} bytes, {1})' -f $lf.Length, $lf.LastWriteTime)
        }
        else { & $add 'steamfix.log  : 없음  <-- steamfix 가 시작조차 못 했다는 뜻' }

        $dat = Join-Path $GameDir 'steamfix.dat'
        & $add ('steamfix.dat  : {0}' -f $(if (Test-Path -LiteralPath $dat) { '있음  <-- 실행 중이거나 권한 복구가 남아 있음 (삭제 금지)' } else { '없음 (정상)' }))
    }
    else { & $add '경로          : 찾지 못함' }
    & $add ''

    & $add '[실행 옵션]'
    foreach ($acc in @($Accounts)) {
        if (-not $acc) { continue }
        $opt = $null
        try { $opt = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig } catch { $opt = $null }
        & $add ('계정 {0} ({1})' -f $acc.AccountId, $acc.Label)
        if ($null -eq $opt)      { & $add '  읽기 실패' }
        elseif ($opt -eq '')     { & $add '  (비어 있음)' }
        else {
            & $add ('  원문        : {0}' -f $opt)
            $exePath = Get-LaunchOptionExePath -Options $opt
            & $add ('  실행 파일   : {0}' -f $exePath)
            if ($exePath) {
                $exists = Test-Path -LiteralPath $exePath
                & $add ('  그 경로 존재: {0}' -f $(if ($exists) { '예' } else { '아니오  <-- 스팀이 여기서 실패함' }))
                if ($opt -match 'steamfix\.exe' -and $opt -notmatch '^\s*"') {
                    & $add '  주의        : 따옴표가 없습니다. 공백에서 잘려 실행에 실패합니다.'
                }
            }
        }
    }
    & $add ''

    # 로그가 있으면 마지막 부분이 가장 중요한 단서다.
    if ($GameDir) {
        $log = Join-Path $GameDir 'steamfix.log'
        if (Test-Path -LiteralPath $log) {
            & $add '[steamfix.log 마지막 10줄]'
            try {
                foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8 -Tail 10)) { & $add $line }
            }
            catch { & $add '(읽기 실패)' }
        }
    }

    return ($out -join [Environment]::NewLine)
}

# 인터넷에서 받은 파일에는 Zone.Identifier 라는 표시가 붙는다. 이게 붙어 있으면
# 윈도우나 백신이 실행을 막을 수 있는데, 파일은 그대로 있어서 눈에 띄지 않는다.
# 스팀이 실행에 실패하고 steamfix 는 시작조차 못 하므로 로그도 남지 않는다.
function Test-FileBlocked {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $zone = Get-Item -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction Stop
        return ($null -ne $zone)
    }
    catch { return $false }
}

function Unblock-DownloadedFile {
    param([string]$Path)
    try {
        Unblock-File -LiteralPath $Path -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# 어떤 백신이 깔려 있는지 알면 안내를 그 백신에 맞출 수 있다.
# 국내 백신은 윈도우 자체 백신과 대응 방법이 완전히 다르다.
function Get-InstalledAntivirus {
    $list = @()
    try {
        foreach ($av in (Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $realtime = (($av.productState -band 0x1000) -ne 0)
            $list += [pscustomobject]@{ Name = $av.displayName; RealTime = $realtime }
        }
    }
    catch { }
    # 항목이 하나면 PowerShell 이 배열을 풀어버려서 호출부가 헷갈린다. 배열로 고정한다.
    return ,@($list)
}

# 원본 docs/EXIT_CODES.md 에 적힌 종료 코드의 뜻(2026-08-18 확인).
# 숫자만 보여 주면 백신이 막은 것인지, 게임이 이미 켜져 있는 것인지 구분할 수 없다.
$script:ExitCodeNotes = @{
    '0'  = '정상 종료'
    '10' = '올바르지 않은 실행 인자'
    '11' = '기록 파일을 만들지 못함'
    '12' = 'Destiny 2 · 스팀 앱 ID · 권한 확인 실패'
    '13' = '다른 SteamFix 나 Destiny 2 가 이미 실행 중'
    '14' = '스팀 설치나 렌더러 DLL 을 찾지 못함'
    '15' = '오버레이 렌더러가 이미 로드되어 있음'
    '16' = '렌더러 권한 보호 · 복구 실패'
    '17' = '데스티니 런처를 시작하지 못함'
    '19' = '예기치 않은 내부 오류'
}

# 사용자가 바로 손쓸 수 있는 코드에만 다음에 할 일을 붙인다.
$script:ExitCodeHints = @{
    '13' = '게임과 다른 SteamFix 를 모두 끄고 다시 눌러 주세요.'
    '14' = '스팀이 제대로 설치되어 있는지, 게임 폴더가 맞는지 확인해 주세요.'
    '16' = '스팀을 완전히 종료한 뒤 다시 시도해 주세요.'
    '17' = '스팀을 다시 실행한 뒤 시도해 주세요.'
}

function Get-ExitCodeNote {
    param($Code)
    if ($null -eq $Code) { return '종료 코드 없음' }
    $key  = [string][int]$Code
    $note = $script:ExitCodeNotes[$key]
    if (-not $note) { $note = '원본 문서에 적혀 있지 않은 코드' }
    return ('종료 코드 {0} — {1}' -f $key, $note)
}

function Get-ExitCodeHint {
    param($Code)
    if ($null -eq $Code) { return $null }
    return $script:ExitCodeHints[([string][int]$Code)]
}

# 백신이 막고 있는지 가리는 가장 확실한 방법.
# v1.1.0부터 직접 실행은 복구 모드다. 진단에서 실행하거나 강제 종료하지 않는다.
function Test-SteamFixFile {
    param([string]$GameDir)
    $result = [pscustomobject]@{ Checked = $false; Blocked = $null; Note = $null }
    if (-not $GameDir) { return $result }
    $result.Checked = $true
    $exe = Join-Path $GameDir $script:ExeName
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $result.Blocked = 'steamfix.exe 가 없습니다. 최신 공식 릴리스에서 받아 주세요.'
    }
    elseif (-not (Test-IsExecutable -Path $exe)) {
        $result.Blocked = '실행 파일 헤더를 읽을 수 없거나 MZ 형식이 아닙니다. 파일을 다시 확인해 주세요.'
    }
    else {
        $result.Note = '파일 헤더 확인 완료. 실행 가능 여부와 백신 차단 여부는 확인하지 않았습니다.'
    }
    return $result
}

# 설정 경로와 현재 탐지 경로를 모두 확인한다. 백업은 직접 삭제하지 않는다.
function Get-RecoveryFiles {
    param([string]$GameDir, [string]$Options)
    $dirs = @()
    if ($GameDir) { $dirs += $GameDir }
    $exe = Get-LaunchOptionExePath -Options $Options
    if ($exe -and [IO.Path]::IsPathRooted($exe) -and
        [IO.Path]::GetFileName($exe) -ieq 'steamfix.exe') {
        $dirs += [IO.Path]::GetDirectoryName($exe)
    }
    foreach ($dir in ($dirs | Select-Object -Unique)) {
        foreach ($name in @('steamfix.dat', 'steamfix.dat.tmp', 'steamfix.dat.old')) {
            $path = Join-Path $dir $name
            if (Test-Path -LiteralPath $path) { $path }
        }
    }
}

function Test-SteamRunning {
    return (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count -gt 0)
}

function Stop-SteamClient {
    param([string]$SteamPath)

    $exe = Join-Path $SteamPath 'steam.exe'
    if (Test-Path $exe) { Start-Process -FilePath $exe -ArgumentList '-shutdown' | Out-Null }
    for ($n = 0; $n -lt 40; $n++) {
        if (-not (Test-SteamRunning)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Test-SteamRunning))
}

function Get-Settings {
    if (Test-Path $script:SettingsPath) {
        try { return (Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-Settings {
    param($Settings)
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    $Settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 자체 검사
# ---------------------------------------------------------------------------

function Invoke-SelfTest {
    function Assert-Equal {
        param($Expected, $Actual, [string]$Name)
        if ([string]$Expected -eq [string]$Actual) {
            Write-Host ("  [OK]   {0}" -f $Name) -ForegroundColor Green
            $script:tPass++
        }
        else {
            Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
            Write-Host ("         기대: <{0}>" -f $Expected)
            Write-Host ("         실제: <{0}>" -f $Actual)
            $script:tFail++
        }
    }

    # Assert-Equal 은 문자열로 견주므로 $null 과 빈 문자열을 갈라내지 못한다.
    # 이 둘의 차이가 실제로 동작을 갈라놓는 곳이 있어 전용 단정문을 따로 둔다.
    function Assert-Null {
        param($Actual, [string]$Name)
        if ($null -eq $Actual) {
            Write-Host ("  [OK]   {0}" -f $Name) -ForegroundColor Green
            $script:tPass++
        }
        else {
            Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
            Write-Host  "         기대: <null>"
            Write-Host ("         실제: <{0}>" -f $Actual)
            $script:tFail++
        }
    }

    $script:tPass = 0
    $script:tFail = 0

    Write-Host "`n== VDF 문자열 이스케이프 ==" -ForegroundColor Cyan
    Assert-Equal '"\"C:\\Games\\steamfix.exe\" %command%"' `
        (ConvertTo-VdfString -Value '"C:\Games\steamfix.exe" %command%') '경로와 따옴표 이스케이프'

    Write-Host "`n== 구조 파서 (미끼 앱 ID 포함) ==" -ForegroundColor Cyan
    # 실제 localconfig.vdf 와 동일하게, apps 섹션보다 앞에 같은 앱 ID가
    # 스칼라 값으로 등장하는 상황을 재현한다.
    $sample = @"
"UserLocalConfigStore"
{
	"Stats"
	{
		"1085660"		"deadbeef1085660"
	}
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"1623730"
					{
						"LaunchOptions"		"-DX12"
					}
					"1085660"
					{
						"Playtime"		"31"
					}
				}
			}
		}
	}
}
"@

    $apps = Find-VdfBlock -Text $sample -Path @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps')
    Assert-Equal $true ($null -ne $apps) 'apps 섹션 탐색'

    $appKeys = @()
    foreach ($e in (Get-VdfEntries -Text $sample -Start $apps.ContentStart -End $apps.ContentEnd)) {
        if ($e.Kind -eq 'block') { $appKeys += $e.Key }
    }
    Assert-Equal '1623730,1085660' ($appKeys -join ',') 'apps 하위 블록만 열거'

    Write-Host "`n== 실행 옵션 기록 ==" -ForegroundColor Cyan
    $launch = New-LaunchString -GameDir 'C:\Program Files (x86)\Steam\steamapps\common\Destiny 2'
    Assert-Equal '"C:\Program Files (x86)\Steam\steamapps\common\Destiny 2\steamfix.exe" %command%' $launch '실행 옵션 문자열 생성'

    $updated = Set-LaunchOptionsText -Text $sample -NewValue $launch
    Assert-Equal $true ($updated -match '"LaunchOptions"\s+"\\"C:\\\\Program Files') '신규 LaunchOptions 삽입'
    Assert-Equal $true ($updated -match '"deadbeef1085660"') '미끼 스칼라 값 보존'
    Assert-Equal $true ($updated -match '"LaunchOptions"\s+"-DX12"') '다른 게임 실행 옵션 보존'

    # 삽입한 결과를 다시 파싱해서 왕복 검증
    $tmp = Join-Path $env:TEMP ('d2sfh-selftest-{0}.vdf' -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($tmp, $updated, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Equal $launch (Get-LaunchOptions -LocalConfigPath $tmp) '기록 후 다시 읽기(왕복)'

    # 같은 파일에 두 번 적용해도 중복되지 않아야 한다
    $twice = Set-LaunchOptionsText -Text $updated -NewValue $launch
    [System.IO.File]::WriteAllText($tmp, $twice, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Equal $launch (Get-LaunchOptions -LocalConfigPath $tmp) '두 번 적용해도 값 유지'
    Assert-Equal 2 ([regex]::Matches($twice, '"LaunchOptions"').Count) 'LaunchOptions 키 중복 없음'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    Write-Host "`n== 기존 옵션 병합 / 제거 ==" -ForegroundColor Cyan
    Assert-Equal '"C:\D2\steamfix.exe" %command% -windowed' `
        (Merge-LaunchOptions -Existing '-windowed' -SteamFixPart '"C:\D2\steamfix.exe" %command%') '기존 옵션 뒤에 유지'
    Assert-Equal '"C:\New\steamfix.exe" %command%' `
        (Merge-LaunchOptions -Existing '"C:\Old\steamfix.exe" %command%' -SteamFixPart '"C:\New\steamfix.exe" %command%') '이전 경로 교체'
    Assert-Equal '-windowed' `
        (Remove-SteamFixFromOptions -Existing '"C:\D2\steamfix.exe" %command% -windowed') '제거 후 사용자 옵션 유지'
    Assert-Equal '' `
        (Remove-SteamFixFromOptions -Existing '"C:\D2\steamfix.exe" %command%') '전체 제거'
    Assert-Equal '-DX12' `
        (Remove-SteamFixFromOptions -Existing '-DX12') 'steamfix 없으면 그대로 둠'

    Write-Host "`n== 게임 폴더 탐지 (라이브러리를 옮긴 경우) ==" -ForegroundColor Cyan
    # 게임을 다른 라이브러리로 옮기면 예전 자리에 빈 폴더와 매니페스트가 남을 수 있다.
    # 폴더 존재만 보면 그 빈 폴더를 잡아 실행 옵션이 엉뚱한 곳을 가리키게 된다.
    $fakeRoot = Join-Path $env:TEMP ('d2sfh-move-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $oldLib   = Join-Path $fakeRoot 'Steam'
    $newLib   = Join-Path $fakeRoot 'NewDrive'
    New-Item -ItemType Directory -Path (Join-Path $oldLib 'steamapps\common\Destiny 2') -Force | Out-Null   # 빈 껍데기
    New-Item -ItemType Directory -Path (Join-Path $newLib 'steamapps\common\Destiny 2') -Force | Out-Null
    Set-Content -Path (Join-Path $newLib 'steamapps\common\Destiny 2\destiny2.exe') -Value 'MZ' -Encoding Ascii

    $escOld = $oldLib -replace '\\', '\\'
    $escNew = $newLib -replace '\\', '\\'
    $lf = '"libraryfolders"' + "`r`n{`r`n" +
          "`t`"0`"`r`n`t{`r`n`t`t`"path`"`t`t`"$escOld`"`r`n`t}`r`n" +
          "`t`"1`"`r`n`t{`r`n`t`t`"path`"`t`t`"$escNew`"`r`n`t}`r`n}"
    [System.IO.File]::WriteAllText((Join-Path $oldLib 'steamapps\libraryfolders.vdf'), $lf, (New-Object System.Text.UTF8Encoding($false)))
    # 옛 라이브러리에만 매니페스트가 남아 있는 상황
    $acfText = '"AppState"' + "`r`n{`r`n`t`"installdir`"`t`t`"Destiny 2`"`r`n}"
    [System.IO.File]::WriteAllText((Join-Path $oldLib 'steamapps\appmanifest_1085660.acf'), $acfText, (New-Object System.Text.UTF8Encoding($false)))

    $detected = Get-Destiny2Path -SteamPath $oldLib
    Assert-Equal (Join-Path $newLib 'steamapps\common\Destiny 2') $detected '빈 껍데기 대신 게임이 실제로 있는 폴더를 고름'
    Assert-Equal $true  (Test-GameFilesPresent -GameDir (Join-Path $newLib 'steamapps\common\Destiny 2')) '게임 있는 폴더는 present'
    Assert-Equal $false (Test-GameFilesPresent -GameDir (Join-Path $oldLib 'steamapps\common\Destiny 2')) '빈 껍데기는 absent'
    Assert-Equal $false (Test-GameFilesPresent -GameDir '') '경로가 없으면 absent'

    # steamfix 는 자기 옆에 로그를 만들지 못하면 시작하자마자 죽는다(종료 코드 11).
    Assert-Equal $true  (Test-FolderWritable -Path (Join-Path $newLib 'steamapps\common\Destiny 2')) '쓸 수 있는 폴더는 writable'
    Assert-Equal $false (Test-FolderWritable -Path 'Z:\없는드라이브\게임') '없는 경로는 not writable'
    Assert-Equal $false (Test-FolderWritable -Path '') '빈 경로는 not writable'
    Assert-Equal 0 (@(Get-ChildItem -Path (Join-Path $newLib 'steamapps\common\Destiny 2') -Force -Filter '.d2sfh-write-*').Count) '쓰기 검사 파일을 남기지 않음'

    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n== 실행 옵션에서 실행 파일 경로 뽑기 ==" -ForegroundColor Cyan
    Assert-Equal 'C:\Games\Destiny 2\steamfix.exe' `
        (Get-LaunchOptionExePath -Options '"C:\Games\Destiny 2\steamfix.exe" %command%') '따옴표로 감싼 경로'
    # 따옴표가 빠지면 스팀은 공백 앞까지를 실행 파일로 본다. 그래서 실패한다.
    Assert-Equal 'C:\Games\Destiny' `
        (Get-LaunchOptionExePath -Options 'C:\Games\Destiny 2\steamfix.exe %command%') '따옴표 없으면 공백에서 잘림(실제 실패 재현)'
    Assert-Equal 'D:\D2\steamfix.exe' `
        (Get-LaunchOptionExePath -Options '   "D:\D2\steamfix.exe"  %command% -DX12') '앞쪽 공백과 뒤 인자 무시'
    Assert-Null (Get-LaunchOptionExePath -Options '') '빈 옵션은 null'
    Assert-Null (Get-LaunchOptionExePath -Options $null) 'null 옵션은 null'

    Write-Host "`n== 진단 정보 생성 ==" -ForegroundColor Cyan
    $diagRoot = Join-Path $env:TEMP ('d2sfh-diag-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $diagGame = Join-Path $diagRoot 'steamapps\common\Destiny 2'
    New-Item -ItemType Directory -Path (Join-Path $diagRoot 'steamapps') -Force | Out-Null
    New-Item -ItemType Directory -Path $diagGame -Force | Out-Null
    Set-Content -Path (Join-Path $diagGame 'destiny2.exe') -Value 'MZ' -Encoding Ascii

    $report = Get-DiagnosticReport -SteamPath $diagRoot -GameDir $diagGame -Accounts @()
    Assert-Equal $true ($report -match '진단 정보')            '머리말 포함'
    Assert-Equal $true ($report -match 'destiny2\.exe\s*:\s*있음') '게임 파일 있음으로 보고'
    Assert-Equal $true ($report -match '쓰기 권한\s*:\s*있음')  '쓰기 권한 있음으로 보고'
    Assert-Equal $true ($report -match 'steamfix\.exe\s*:\s*없음') 'steamfix 없음으로 보고'
    Assert-Equal $true ($report -match 'steamfix\.log\s*:\s*없음') '로그 없음으로 보고'
    Assert-Equal $false ($report -match '비밀번호|password')     '민감한 항목 없음'

    # 인터넷에서 받은 파일 표시(Zone.Identifier) 감지와 해제
    $blockTarget = Join-Path $diagGame 'steamfix.exe'
    Set-Content -Path $blockTarget -Value 'MZ' -Encoding Ascii
    Assert-Equal $false (Test-FileBlocked -Path $blockTarget) '표시 없으면 차단 아님'
    Set-Content -Path $blockTarget -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding Ascii
    Assert-Equal $true  (Test-FileBlocked -Path $blockTarget) '표시 있으면 차단으로 판정'
    Assert-Equal $true  (Unblock-DownloadedFile -Path $blockTarget) '차단 해제 성공'
    Assert-Equal $false (Test-FileBlocked -Path $blockTarget) '해제 후 정상으로 판정'
    Assert-Equal $false (Test-FileBlocked -Path (Join-Path $diagGame '없는파일.exe')) '없는 파일은 차단 아님'

    $avOk = $true
    $avResult = $null
    try { $avResult = Get-InstalledAntivirus } catch { $avOk = $false }
    Assert-Equal $true  $avOk                    '백신 조회가 예외 없이 끝남'
    Assert-Equal $true  ($avResult -is [array])  '항목이 하나여도 배열로 반환'

    Remove-Item -LiteralPath $diagRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n== 백업 정리 ==" -ForegroundColor Cyan
    $bakDir = Join-Path $env:TEMP ('d2sfh-bak-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    # 오래된 것부터 25개를 만든다. 시각을 직접 지정해 순서를 확실히 한다.
    for ($n = 1; $n -le 25; $n++) {
        $f = Join-Path $bakDir ('localconfig-123456789-{0:D2}.vdf.bak' -f $n)
        Set-Content -Path $f -Value "backup $n" -Encoding UTF8
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddMinutes(-100 + $n)
    }
    # 정리 대상이 아닌 파일도 하나 섞어둔다
    Set-Content -Path (Join-Path $bakDir 'settings.json') -Value '{}' -Encoding UTF8

    $removed = Remove-OldBackup -Dir $bakDir -Keep 20
    $left    = @(Get-ChildItem -Path $bakDir -Filter 'localconfig-*.vdf.bak' -File)
    Assert-Equal 5  $removed      '25개 중 5개 삭제'
    Assert-Equal 20 $left.Count   '20개 보관'
    Assert-Equal $true ($left.Name -contains 'localconfig-123456789-25.vdf.bak') '가장 최근 백업 보존'
    Assert-Equal $false ($left.Name -contains 'localconfig-123456789-01.vdf.bak') '가장 오래된 백업 삭제'
    Assert-Equal $true (Test-Path (Join-Path $bakDir 'settings.json')) '백업이 아닌 파일은 건드리지 않음'
    Assert-Equal 0 (Remove-OldBackup -Dir $bakDir -Keep 20) '이미 정리된 폴더는 변화 없음'
    Remove-Item -LiteralPath $bakDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n== 내려받은 파일 형식 검사 ==" -ForegroundColor Cyan
    Assert-Equal $true (Test-IsExecutable -Path (Join-Path $env:WINDIR 'notepad.exe')) '실행 파일을 실행 파일로 판정'
    $notExe = Join-Path $env:TEMP ('d2sfh-notexe-{0}.exe' -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $notExe -Value '<html>404 Not Found</html>' -Encoding UTF8
    Assert-Equal $false (Test-IsExecutable -Path $notExe) 'HTML 오류 페이지를 걸러냄'
    Remove-Item $notExe -Force -ErrorAction SilentlyContinue
    Assert-Equal $false (Test-IsExecutable -Path 'C:\존재하지\않는\경로.exe') '없는 파일은 false'

    Write-Host "`n== 파서 경계 ==" -ForegroundColor Cyan
    Assert-Null (Find-VdfBlock -Text $sample -Path @('UserLocalConfigStore', 'Software', '없는키')) '없는 경로는 null'
    Assert-Null (Find-VdfBlock -Text '' -Path @('UserLocalConfigStore')) '빈 텍스트는 null'
    Assert-Equal '"\\"' (ConvertTo-VdfString -Value '\') '역슬래시 한 개'
    Assert-Equal '"\""' (ConvertTo-VdfString -Value '"') '따옴표 한 개'
    Assert-Equal '""'   (ConvertTo-VdfString -Value '') '빈 값'

    # 하위 블록을 토큰 단위로 훑으면 손자 키를 형제로 착각한다. 짝이 맞는 닫는 괄호까지
    # 건너뛰어야 한다(속도 때문에 고친 적이 있는 부분이라 검사로 못 박아 둔다).
    $nested = @"
"root"
{
    "a"
    {
        "inner"
        {
            "deep"      "1"
        }
        "x"     "2"
    }
    "b"     "3"
    "c"
    {
    }
}
"@
    $rootBlk = Find-VdfBlock -Text $nested -Path @('root')
    $kinds = @()
    foreach ($e in (Get-VdfEntries -Text $nested -Start $rootBlk.ContentStart -End $rootBlk.ContentEnd)) {
        $kinds += ('{0}:{1}' -f $e.Key, $e.Kind)
    }
    Assert-Equal 'a:block,b:value,c:block' ($kinds -join ',') '손자 키를 형제로 세지 않음'
    $innerBlk = Find-VdfBlock -Text $nested -Path @('root', 'a', 'inner')
    Assert-Equal '1' (@(Get-VdfEntries -Text $nested -Start $innerBlk.ContentStart -End $innerBlk.ContentEnd)[0].Value) '세 단계 아래 값 읽기'
    $emptyBlk = Find-VdfBlock -Text $nested -Path @('root', 'c')
    Assert-Equal 0 (@(Get-VdfEntries -Text $nested -Start $emptyBlk.ContentStart -End $emptyBlk.ContentEnd).Count) '빈 블록은 항목 없음'

    Write-Host "`n== 실행 옵션 읽기: 빈 값과 읽기 실패를 구분 ==" -ForegroundColor Cyan
    # 호출부는 $null 을 '구조를 읽지 못했다'는 오류로 다루고 '' 는 정상으로 본다.
    # 이 둘이 섞이면 정상 파일을 오류로 알리거나 그 반대가 된다.
    $writeTmp = {
        param([string]$Content)
        $p = Join-Path $env:TEMP ('d2sfh-t-{0}.vdf' -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($p, $Content, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }
    $emptyApps = @"
"UserLocalConfigStore"
{
    "Software"
    {
        "Valve"
        {
            "Steam"
            {
                "apps"
                {
                }
            }
        }
    }
}
"@
    $tEmpty  = & $writeTmp $emptyApps
    $tNoKey  = & $writeTmp $sample
    $tBroken = & $writeTmp '"UserLocalConfigStore"'
    Assert-Equal '' (Get-LaunchOptions -LocalConfigPath $tEmpty) '앱 블록이 없으면 빈 문자열'
    Assert-Equal '' (Get-LaunchOptions -LocalConfigPath $tNoKey) 'LaunchOptions 키가 없으면 빈 문자열'
    Assert-Null     (Get-LaunchOptions -LocalConfigPath $tBroken) '구조를 못 읽으면 null'

    Write-Host "`n== 실행 옵션 쓰기: 앱 블록 신설과 줄바꿈 ==" -ForegroundColor Cyan
    $probeOpt = '"D:\D2\steamfix.exe" %command%'
    $newBlock = Set-LaunchOptionsText -Text $emptyApps -NewValue $probeOpt
    $tNew     = & $writeTmp $newBlock
    Assert-Equal $probeOpt (Get-LaunchOptions -LocalConfigPath $tNew) '앱 블록을 새로 만들어 기록'
    Assert-Equal 1 ([regex]::Matches($newBlock, '"1085660"').Count) '앱 블록을 한 번만 만듦'

    # 실제 파일은 CRLF 다. 오프셋 계산이 줄바꿈 길이에 흔들리지 않아야 한다.
    $crlfText = Set-LaunchOptionsText -Text ($sample -replace "`n", "`r`n") -NewValue $probeOpt
    $tCrlf    = & $writeTmp $crlfText
    Assert-Equal $probeOpt (Get-LaunchOptions -LocalConfigPath $tCrlf) 'CRLF 파일에서도 왕복'

    $threwNoApps = $false
    try { [void](Set-LaunchOptionsText -Text "`"UserLocalConfigStore`"`n{`n}" -NewValue $probeOpt) }
    catch { $threwNoApps = $true }
    Assert-Equal $true $threwNoApps 'apps 섹션이 없으면 예외로 알림'

    foreach ($p in @($tEmpty, $tNoKey, $tBroken, $tNew, $tCrlf)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }

    Write-Host "`n== 병합 / 제거 추가 경우 ==" -ForegroundColor Cyan
    Assert-Equal '"C:\New\steamfix.exe" %command% -windowed' `
        (Merge-LaunchOptions -Existing '"C:\Old\steamfix.exe" %command% -windowed' `
                             -SteamFixPart '"C:\New\steamfix.exe" %command%') '경로는 교체하고 사용자 옵션은 유지'
    Assert-Equal '"C:\New\steamfix.exe" %command%' `
        (Merge-LaunchOptions -Existing 'C:\Old\steamfix.exe %command%' `
                             -SteamFixPart '"C:\New\steamfix.exe" %command%') '따옴표 없이 저장된 옛 설정도 교체'
    Assert-Equal '"C:\New\steamfix.exe" %command%' `
        (Merge-LaunchOptions -Existing '' -SteamFixPart '"C:\New\steamfix.exe" %command%') '기존이 비어 있으면 그대로'
    Assert-Equal '-DX12' (Remove-SteamFixFromOptions -Existing 'C:\D2\steamfix.exe %command% -DX12') '따옴표 없는 설정도 제거'
    Assert-Equal ''      (Remove-SteamFixFromOptions -Existing '') '빈 값은 빈 값'

    Write-Host "`n== 계정 목록 (가짜 userdata) ==" -ForegroundColor Cyan
    # MostRecent 키가 없는 Steam 버전이 있어 AutoLogin 도 함께 본다. 그 분기를 못 박는다.
    $accRoot = Join-Path $env:TEMP ('d2sfh-acc-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    foreach ($id in @('11111111', '22222222', '44444444', '0')) {
        New-Item -ItemType Directory -Path (Join-Path $accRoot "userdata\$id\config") -Force | Out-Null
        Set-Content -Path (Join-Path $accRoot "userdata\$id\config\localconfig.vdf") -Value '"UserLocalConfigStore"' -Encoding UTF8
    }
    New-Item -ItemType Directory -Path (Join-Path $accRoot 'userdata\33333333') -Force | Out-Null   # config 폴더 없음
    New-Item -ItemType Directory -Path (Join-Path $accRoot 'config') -Force | Out-Null
    $loginUsers = @"
"users"
{
    "76561197971376839"
    {
        "AccountName"       "old_account"
    }
    "76561197982487950"
    {
        "PersonaName"       "가디언"
        "AutoLogin"     "1"
    }
}
"@
    [System.IO.File]::WriteAllText((Join-Path $accRoot 'config\loginusers.vdf'), $loginUsers,
                                   (New-Object System.Text.UTF8Encoding($false)))

    $accList = @(Get-SteamAccounts -SteamPath $accRoot)
    Assert-Equal 3 $accList.Count '계정 0 번과 config 없는 폴더는 제외'
    Assert-Equal '22222222' $accList[0].AccountId 'AutoLogin 계정을 맨 앞에'
    Assert-Equal '가디언'   $accList[0].Label     'PersonaName 을 이름으로'
    Assert-Equal 'old_account' (($accList | Where-Object { $_.AccountId -eq '11111111' }).Label) `
        'PersonaName 이 없으면 AccountName'
    Assert-Equal '계정 44444444' (($accList | Where-Object { $_.AccountId -eq '44444444' }).Label) `
        'loginusers 에 없으면 계정 번호로 표시'
    Assert-Equal 0 (@(Get-SteamAccounts -SteamPath (Join-Path $accRoot 'userdata\33333333')).Count) `
        'userdata 가 없는 경로는 빈 목록'
    Remove-Item -LiteralPath $accRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n== 경로 표기 복원 ==" -ForegroundColor Cyan
    $caseRoot = Join-Path $env:TEMP ('d2sfh-case-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path (Join-Path $caseRoot 'MiXeDcAsE') -Force | Out-Null
    Assert-Equal 'MiXeDcAsE' `
        (Split-Path (Get-CanonicalPath -Path (Join-Path $caseRoot 'MiXeDcAsE').ToLower()) -Leaf) `
        '소문자로 들어온 경로를 디스크 표기로'
    Assert-Equal 'Z:\없는\경로' (Get-CanonicalPath -Path 'Z:\없는\경로') '없는 경로는 준 대로 돌려줌'
    Assert-Equal 1 (@(Get-SteamLibraries -SteamPath $caseRoot).Count) 'libraryfolders.vdf 가 없으면 Steam 경로만'
    Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction SilentlyContinue

    Assert-Equal $true ((Test-SteamRunning) -is [bool]) 'Steam 실행 여부는 참/거짓으로 반환'

    Write-Host "`n== 백업 만들기와 설정 저장 ==" -ForegroundColor Cyan
    # 실제 백업 폴더를 건드리지 않도록 저장 위치만 임시로 갈아 끼운다.
    $savedStateDir     = $script:StateDir
    $savedSettingsPath = $script:SettingsPath
    $stateRoot = Join-Path $env:TEMP ('d2sfh-state-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $script:StateDir     = $stateRoot
    $script:SettingsPath = Join-Path $stateRoot 'settings.json'
    try {
        $srcVdf = Join-Path $env:TEMP ('d2sfh-src-{0}.vdf' -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($srcVdf, '옛 내용', (New-Object System.Text.UTF8Encoding($false)))
        (Get-Item -LiteralPath $srcVdf).LastWriteTime = (Get-Date).AddDays(-10)

        $saved = Save-LocalConfig -Path $srcVdf -Text '새 내용' -AccountId '12345678'
        Assert-Equal $true ((Split-Path $saved.Path -Leaf) -match '^localconfig-12345678-\d{8}-\d{6}\.vdf\.bak$') `
            '백업 이름에 계정과 날짜·시각'
        Assert-Equal '옛 내용' ([System.IO.File]::ReadAllText($saved.Path)) '백업에는 바뀌기 전 내용'
        Assert-Equal '새 내용' ([System.IO.File]::ReadAllText($srcVdf)) '원본에는 새 내용'
        # Copy-Item 은 원본의 옛 시각까지 복사한다. 그대로 두면 정리가 새 백업을 먼저 지운다.
        Assert-Equal $true ((Get-Item -LiteralPath $saved.Path).LastWriteTime -gt (Get-Date).AddMinutes(-5)) `
            '백업 시각을 지금으로 다시 찍음'
        $head = [System.IO.File]::ReadAllBytes($srcVdf)[0..2]
        Assert-Equal $false (($head[0] -eq 0xEF) -and ($head[1] -eq 0xBB) -and ($head[2] -eq 0xBF)) `
            '기록한 파일에 BOM 을 붙이지 않음'
        Assert-Equal 0 $saved.Removed '백업이 적으면 지우지 않음'
        Remove-Item $srcVdf -Force -ErrorAction SilentlyContinue

        Save-Settings ([pscustomobject]@{ GameDir = 'D:\내 게임\Destiny 2' })
        Assert-Equal 'D:\내 게임\Destiny 2' (Get-Settings).GameDir '설정 저장 후 다시 읽기'
        Set-Content -Path $script:SettingsPath -Value '{ 망가진' -Encoding UTF8
        Assert-Null (Get-Settings) '깨진 설정 파일은 null (예외 아님)'
        Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction SilentlyContinue
        Assert-Null (Get-Settings) '설정 파일이 없으면 null'
    }
    finally {
        $script:StateDir     = $savedStateDir
        $script:SettingsPath = $savedSettingsPath
        Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n== 종료 코드 해설 ==" -ForegroundColor Cyan
    Assert-Equal '종료 코드 10 — 올바르지 않은 실행 인자' (Get-ExitCodeNote -Code 10) '코드 10 (잘못된 실행 인자)'
    Assert-Equal '종료 코드 13 — 다른 SteamFix 나 Destiny 2 가 이미 실행 중' (Get-ExitCodeNote -Code 13) '코드 13'
    Assert-Equal '종료 코드 없음' (Get-ExitCodeNote -Code $null) '코드가 없을 때'
    Assert-Equal $true ((Get-ExitCodeNote -Code 99) -match '적혀 있지 않은') '문서에 없는 코드도 문장으로'
    Assert-Null (Get-ExitCodeHint -Code 10) '정상 코드에는 조치 안내 없음'
    Assert-Equal $true ((Get-ExitCodeHint -Code 13) -match '끄고') '코드 13 에는 조치 안내'
    # 원본 docs/EXIT_CODES.md 의 9개(18 은 문서에 없음)가 빠지지 않았는지 본다.
    foreach ($code in @(10, 11, 12, 13, 14, 15, 16, 17, 19)) {
        Assert-Equal $false ((Get-ExitCodeNote -Code $code) -match '적혀 있지 않은') ('코드 {0} 해설 있음' -f $code)
    }

    Write-Host "`n== 실행하지 않는 파일 확인 및 복구 상태 ==" -ForegroundColor Cyan
    $applyRoot = Join-Path $env:TEMP ('d2sfh-apply-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $applyRoot -Force | Out-Null
    try {
        Assert-Equal $false (Test-SteamFixFile -GameDir '').Checked '경로가 없으면 확인하지 않음'
        Assert-Equal $true ((Test-SteamFixFile -GameDir $applyRoot).Blocked -match '없습니다') '파일 누락 안내'
        # MZ뿐인 파일도 실행하지 않고 헤더만 검사한다. 실행 검증으로 오인하지 않는다.
        $testExe = Join-Path $applyRoot 'steamfix.exe'
        [IO.File]::WriteAllText($testExe, 'MZ')
        Assert-Null (Test-SteamFixFile -GameDir $applyRoot).Blocked '헤더 검사 중 파일을 실행하지 않음'
        Assert-Equal $true ((Test-SteamFixFile -GameDir $applyRoot).Note -match '확인하지 않았습니다') '검사 한계 안내'
        [IO.File]::WriteAllText($testExe, 'invalid')
        Assert-Equal $true ((Test-SteamFixFile -GameDir $applyRoot).Blocked -match 'MZ') '잘못된 헤더 안내'
        Assert-Equal 0 @(Get-RecoveryFiles -GameDir $applyRoot).Count '복구 파일 없음'
        foreach ($name in @('steamfix.dat', 'steamfix.dat.tmp', 'steamfix.dat.old')) {
            [IO.File]::WriteAllText((Join-Path $applyRoot $name), 'backup')
        }
        $options = '"' + $testExe + '" %command%'
        Assert-Equal 3 @(Get-RecoveryFiles -Options $options).Count '실행 옵션의 실제 폴더 확인'
        Assert-Equal 3 @(Get-RecoveryFiles -GameDir $applyRoot -Options $options).Count '같은 폴더는 중복하지 않음'
        Assert-Equal 3 @(Get-RecoveryFiles -GameDir $applyRoot -Options 'other.exe').Count '탐지 폴더도 확인'
        Assert-Equal 'backup' ([IO.File]::ReadAllText((Join-Path $applyRoot 'steamfix.dat'))) '복구 파일 보존'
    }
    finally { Remove-Item -LiteralPath $applyRoot -Recurse -Force }

    Write-Host "`n== 실제 설치 환경 (읽기 전용) ==" -ForegroundColor Cyan
    $steam = Get-SteamPath
    if ($steam) {
        Write-Host ("  Steam 경로     : {0}" -f $steam)
        $game = Get-Destiny2Path -SteamPath $steam
        if ($game) { Write-Host ("  Destiny 2 경로 : {0}" -f $game) }
        else { Write-Host "  Destiny 2 미설치 (도우미는 수동 지정으로 대응)" -ForegroundColor Yellow }
        $accounts = @(Get-SteamAccounts -SteamPath $steam)
        foreach ($acc in $accounts) {
            $current = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig
            Write-Host ("  계정 {0,-12} {1,-20} 현재 실행 옵션: <{2}>" -f $acc.AccountId, $acc.Label, $current)
        }

        if ($accounts.Count -gt 0) {
            Write-Host "`n== 실제 localconfig.vdf 사본으로 쓰기 검증 ==" -ForegroundColor Cyan
            # 원본은 절대 건드리지 않는다. 임시 사본에만 기록해 본다.
            $source = $accounts[0].LocalConfig
            $orig   = [System.IO.File]::ReadAllText($source)
            $probe  = '"D:\게임 폴더\Destiny 2\steamfix.exe" %command%'
            $mod    = Set-LaunchOptionsText -Text $orig -NewValue $probe

            # 앞뒤로 동일한 구간을 걷어내서, 바뀐 부분이 정말 한 군데뿐인지 본다.
            $p = 0
            while ($p -lt $orig.Length -and $p -lt $mod.Length -and $orig[$p] -eq $mod[$p]) { $p++ }
            $s = 0
            while ($s -lt ($orig.Length - $p) -and $s -lt ($mod.Length - $p) -and
                   $orig[$orig.Length - 1 - $s] -eq $mod[$mod.Length - 1 - $s]) { $s++ }

            $touchedInOriginal = $orig.Length - $p - $s
            $newRegion         = $mod.Substring($p, $mod.Length - $p - $s)

            Write-Host ("  원본 {0:N0}자 중 {1}자 교체, 새 구간 {2}자" -f $orig.Length, $touchedInOriginal, $newRegion.Length)
            Assert-Equal $true ($touchedInOriginal -lt 200) '원본에서 건드린 구간이 한 군데뿐'

            # 이미 실행 옵션이 있으면 값만 교체하고, 없으면 키를 새로 넣는다.
            # 두 경로는 결과가 다르므로 각각에 맞게 검사한다.
            $hadKey  = $false
            $appsBlk = Find-VdfBlock -Text $orig -Path @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps')
            if ($appsBlk) {
                foreach ($e in (Get-VdfEntries -Text $orig -Start $appsBlk.ContentStart -End $appsBlk.ContentEnd)) {
                    if ($e.Kind -ne 'block' -or $e.Key -ne $script:AppId) { continue }
                    foreach ($c in (Get-VdfEntries -Text $orig -Start $e.ContentStart -End $e.ContentEnd)) {
                        if ($c.Kind -eq 'value' -and [string]::Equals($c.Key, 'LaunchOptions', 'OrdinalIgnoreCase')) { $hadKey = $true }
                    }
                }
            }

            $origKeys = [regex]::Matches($orig, '"LaunchOptions"').Count
            $modKeys  = [regex]::Matches($mod,  '"LaunchOptions"').Count

            if ($hadKey) {
                Write-Host '  (이 계정에는 실행 옵션이 이미 있어 값 교체 경로를 검사합니다)'
                Assert-Equal $origKeys $modKeys 'LaunchOptions 키 개수 유지(값만 교체)'
            }
            else {
                Write-Host '  (이 계정에는 실행 옵션이 없어 키 삽입 경로를 검사합니다)'
                Assert-Equal ($origKeys + 1) $modKeys 'LaunchOptions 키 1개만 추가'
                Assert-Equal $true ($newRegion -match 'LaunchOptions') '삽입 구간이 LaunchOptions'
            }

            $tmpReal = Join-Path $env:TEMP ('d2sfh-real-{0}.vdf' -f ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($tmpReal, $mod, (New-Object System.Text.UTF8Encoding($false)))
            Assert-Equal $probe (Get-LaunchOptions -LocalConfigPath $tmpReal) '한글 경로 포함 값 왕복'

            # 되돌리기까지 하면 원문과 완전히 같아져야 한다
            $back = Set-LaunchOptionsText -Text $mod -NewValue (Remove-SteamFixFromOptions -Existing $probe)
            [System.IO.File]::WriteAllText($tmpReal, $back, (New-Object System.Text.UTF8Encoding($false)))
            $backOptions = Get-LaunchOptions -LocalConfigPath $tmpReal
            Assert-Equal '' $backOptions '되돌리면 실행 옵션이 비워짐'
            Remove-Item $tmpReal -Force -ErrorAction SilentlyContinue

            # Steam 이 켜져 있으면 검사 도중에도 이 파일을 다시 쓴다. 내용만 견주면
            # Steam 이 쓴 것까지 우리 잘못으로 잡히므로(실제로 그렇게 실패한 적이 있다),
            # 파일이 바뀐 경우에는 '우리 검사용 값이 들어가지 않았는지'로 확인한다.
            $sourceNow = [System.IO.File]::ReadAllText($source)
            if ($sourceNow -eq $orig) {
                Assert-Equal $orig $sourceNow '원본 파일은 그대로 유지'
            }
            else {
                Write-Host '  (검사 중 Steam 이 localconfig.vdf 를 다시 썼습니다. 내용 비교 대신 값 확인으로 넘어갑니다)' -ForegroundColor Yellow
                Assert-Equal $false ($sourceNow -match [regex]::Escape($probe)) '원본에 검사용 값이 들어가지 않음'
            }
        }
    }
    else {
        Write-Host "  Steam 미설치 환경" -ForegroundColor Yellow
    }

    Write-Host ("`n결과: 성공 {0} / 실패 {1}`n" -f $script:tPass, $script:tFail) -ForegroundColor Cyan
    if ($script:tFail -gt 0) { exit 1 }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

# 배치 파일이 powershell 을 띄우면 콘솔 창이 같이 뜬다. GUI 도구에서는 눈에
# 거슬리므로 창을 만들자마자 숨긴다. 배치 쪽에서 -WindowStyle Hidden 도 주지만
# 환경에 따라 먹지 않는 경우가 있어 여기서 한 번 더 확실히 처리한다.
function Hide-ConsoleWindow {
    try {
        if (-not ('Native.ConsoleWindow' -as [type])) {
            Add-Type -Namespace Native -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $handle = [Native.ConsoleWindow]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) { [void][Native.ConsoleWindow]::ShowWindow($handle, 0) }  # SW_HIDE
    }
    catch { }   # 숨기지 못해도 도구 자체는 정상 동작한다
}

# 두 번째 실행이 들어오면 새 창을 띄우지 않고 이미 떠 있는 창을 앞으로 가져온다.
# 창이 두 개 뜨면 양쪽이 같은 localconfig.vdf 를 건드릴 수 있어 위험하다.
function Show-ExistingWindow {
    param([string]$Title)

    try {
        if (-not ('Native.WindowFinder' -as [type])) {
            Add-Type -Namespace Native -Name WindowFinder -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
'@ -ErrorAction Stop
        }

        $script:FoundWindow = [IntPtr]::Zero
        $callback = [Native.WindowFinder+EnumWindowsProc] {
            param($handle, $lparam)
            if ([Native.WindowFinder]::IsWindowVisible($handle)) {
                $len = [Native.WindowFinder]::GetWindowTextLength($handle)
                if ($len -gt 0) {
                    $sb = New-Object System.Text.StringBuilder ($len + 1)
                    [void][Native.WindowFinder]::GetWindowText($handle, $sb, $sb.Capacity)
                    if ($sb.ToString() -eq $Title) { $script:FoundWindow = $handle }
                }
            }
            return $true
        }
        [void][Native.WindowFinder]::EnumWindows($callback, [IntPtr]::Zero)

        if ($script:FoundWindow -ne [IntPtr]::Zero) {
            if ([Native.WindowFinder]::IsIconic($script:FoundWindow)) {
                [void][Native.WindowFinder]::ShowWindow($script:FoundWindow, 9)   # SW_RESTORE
            }
            [void][Native.WindowFinder]::SetForegroundWindow($script:FoundWindow)
            return $true
        }
    }
    catch { }

    return $false
}

# ---------------------------------------------------------------------------
# WinForms 컨트롤 만들기
#
# 컨트롤 하나마다 생성 · 문구 · 위치 · 크기 · 부모 등록이 네다섯 줄씩 붙는다.
# 창 하나에 서른 개가 넘어가면 배치를 눈으로 좇을 수 없어지므로 한 줄로 만든다.
# 좌표는 원래대로 절대 픽셀이다(고해상도 대응은 Form 의 AutoScaleMode 가 맡는다).
# ---------------------------------------------------------------------------

function New-UiFont {
    param([double]$Size, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return (New-Object System.Drawing.Font('맑은 고딕', [single]$Size, $style))
}

# 컨트롤 종류와 무관한 속성만 처리한다. 아래 팩터리들이 공통으로 쓴다.
function Set-UiCommon {
    param(
        $Control, $Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [double]$FontSize, [switch]$Bold, $ForeColor, [string]$Anchor
    )
    $Control.Text     = $Text
    $Control.Location = New-Object System.Drawing.Point($X, $Y)
    $Control.Size     = New-Object System.Drawing.Size($W, $H)
    # 글꼴은 지정한 것만 바꾼다. 건드리지 않으면 Form 에 준 기본 글꼴을 물려받는다.
    if ($FontSize -gt 0 -or $Bold) {
        $size = if ($FontSize -gt 0) { $FontSize } else { 9 }
        $Control.Font = New-UiFont -Size $size -Bold:$Bold
    }
    if ($ForeColor) { $Control.ForeColor = $ForeColor }
    if ($Anchor)    { $Control.Anchor    = $Anchor }
    $Parent.Controls.Add($Control)
}

function New-UiLabel {
    param(
        $Parent, [string]$Text = '', [int]$X, [int]$Y, [int]$W, [int]$H = 20,
        [double]$FontSize = 0, [switch]$Bold, $ForeColor, [string]$Anchor = '', [string]$TextAlign = ''
    )
    $c = New-Object System.Windows.Forms.Label
    Set-UiCommon -Control $c -Parent $Parent -Text $Text -X $X -Y $Y -W $W -H $H `
                 -FontSize $FontSize -Bold:$Bold -ForeColor $ForeColor -Anchor $Anchor | Out-Null
    if ($TextAlign) { $c.TextAlign = $TextAlign }
    return $c
}

function New-UiButton {
    param(
        $Parent, [string]$Text = '', [int]$X, [int]$Y, [int]$W, [int]$H = 26,
        [double]$FontSize = 0, [switch]$Bold, $ForeColor, [string]$Anchor = ''
    )
    $c = New-Object System.Windows.Forms.Button
    Set-UiCommon -Control $c -Parent $Parent -Text $Text -X $X -Y $Y -W $W -H $H `
                 -FontSize $FontSize -Bold:$Bold -ForeColor $ForeColor -Anchor $Anchor | Out-Null
    return $c
}

function New-UiGroup {
    param($Parent, [string]$Text = '', [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Anchor = '')
    $c = New-Object System.Windows.Forms.GroupBox
    Set-UiCommon -Control $c -Parent $Parent -Text $Text -X $X -Y $Y -W $W -H $H -Anchor $Anchor | Out-Null
    return $c
}

# 누를 수 있는 링크. 밑줄이 늘 그려져 있으면 문단이 시끄러워서, 필요하면
# -HoverUnderline 으로 마우스를 올릴 때만 밑줄이 보이게 한다.
function New-UiLink {
    param(
        $Parent, [string]$Text = '', [int]$X, [int]$Y, [int]$W, [int]$H = 20,
        [double]$FontSize = 0, $LinkColor, [switch]$HoverUnderline, [string]$Anchor = ''
    )
    $c = New-Object System.Windows.Forms.LinkLabel
    Set-UiCommon -Control $c -Parent $Parent -Text $Text -X $X -Y $Y -W $W -H $H `
                 -FontSize $FontSize -Anchor $Anchor | Out-Null
    if ($LinkColor)      { $c.LinkColor    = $LinkColor }
    if ($HoverUnderline) { $c.LinkBehavior = 'HoverUnderline' }
    return $c
}

# ---------------------------------------------------------------------------
# 알림 창
#
# MessageBox 호출이 스무 군데를 넘는다. 제목 · 버튼 · 아이콘 · Out-Null 이 매번
# 따라붙어 정작 중요한 문구가 묻히므로 세 가지 형태로 줄인다.
# ---------------------------------------------------------------------------

function Show-Note {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = '알림',
        [ValidateSet('Information', 'Warning', 'Question')][string]$Icon = 'Information'
    )
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

# 예외 메시지는 붙여 주기만 하고 창 종류는 하나로 통일한다.
function Show-Failure {
    param([Parameter(Mandatory)][string]$Text, [string]$Detail = '', [string]$Title = '오류')
    $body = $Text
    if ($Detail) { $body = $Text + [Environment]::NewLine + [Environment]::NewLine + $Detail }
    [void][System.Windows.Forms.MessageBox]::Show($body, $Title, 'OK', 'Error')
}

# [예] 를 눌렀을 때만 $true. 호출부에서 DialogResult 를 비교하지 않아도 되게 한다.
function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('Warning', 'Question')][string]$Icon = 'Question'
    )
    return ([System.Windows.Forms.MessageBox]::Show($Text, $Title, 'YesNo', $Icon) -eq
            [System.Windows.Forms.DialogResult]::Yes)
}

# 진단 정보를 창으로 보여준다. 무엇이 담기는지 눈으로 확인한 뒤 복사할 수 있어야
# 안심하고 남에게 보낼 수 있다.
function Show-DiagnosticWindow {
    param([string]$Report, $Owner, [string]$GameDir)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = '작동 안 될 때 — 진단 정보'
    $dlg.Size            = New-Object System.Drawing.Size(760, 580)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.MinimizeBox     = $false
    $dlg.Font            = New-UiFont -Size 9
    $dlg.MinimumSize     = New-Object System.Drawing.Size(520, 360)

    $lblHead = New-UiLabel -Parent $dlg -Text '게임이 작동하지 않을 때, 아래 내용을 도와주는 사람에게 보내면 원인을 빨리 찾을 수 있습니다.' `
        -X 14 -Y 14 -W 720 -Anchor 'Top,Left,Right'

    $lblSub = New-UiLabel -Parent $dlg -Text '문제가 있는 줄에는 <-- 표시가 붙습니다. 비밀번호 같은 개인 정보는 들어가지 않습니다.' `
        -X 14 -Y 34 -W 720 -ForeColor ([System.Drawing.Color]::FromArgb(95, 99, 104)) -Anchor 'Top,Left,Right'

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location   = New-Object System.Drawing.Point(14, 60)
    $txt.Size       = New-Object System.Drawing.Size(722, 440)
    $txt.Anchor     = 'Top,Left,Right,Bottom'
    $txt.Multiline  = $true
    $txt.ReadOnly   = $true
    $txt.ScrollBars = 'Both'
    $txt.WordWrap   = $false
    $txt.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $txt.BackColor  = [System.Drawing.Color]::White
    $txt.Text       = $Report
    $dlg.Controls.Add($txt)

    $lblDone = New-UiLabel -Parent $dlg -X 14 -Y 512 -W 340 `
        -ForeColor ([System.Drawing.Color]::FromArgb(0, 120, 40)) -Anchor 'Bottom,Left'

    $btnRun = New-UiButton -Parent $dlg -Text '파일 확인' -X 384 -Y 508 -W 120 -H 30 -Anchor 'Bottom,Right'
    $btnCopy = New-UiButton -Parent $dlg -Text '복사하기' -X 516 -Y 508 -W 110 -H 30 -Anchor 'Bottom,Right'
    $btnRun.Add_Click({
        try {
            $res = Test-SteamFixFile -GameDir $GameDir
            $note = if ($res.Blocked) { $res.Blocked } elseif ($res.Checked) { $res.Note } else { '게임 폴더를 먼저 지정해 주세요.' }
            $txt.AppendText([Environment]::NewLine + '[파일 확인] ' + $note)
            $lblDone.Text = '파일 확인 완료 (프로그램은 실행하지 않음)'
        }
        catch { $lblDone.Text = ('확인 실패: {0}' -f $_.Exception.Message) }
    })

    $btnClose = New-UiButton -Parent $dlg -Text '닫기' -X 634 -Y 508 -W 102 -H 30 -Anchor 'Bottom,Right'

    $btnCopy.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($txt.Text)
            $lblDone.Text = '복사되었습니다. 아무 데나 Ctrl+V 로 붙여넣으세요.'
        }
        catch { $lblDone.Text = '복사에 실패했습니다. 글자를 직접 선택해 복사해 주세요.' }
    })
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.CancelButton = $btnClose

    # 텍스트 상자가 포커스를 가지면 전체가 파랗게 선택된 채로 떠서 보기 나쁘다.
    $dlg.Add_Shown({
        $txt.SelectionStart  = 0
        $txt.SelectionLength = 0
        [void]$btnCopy.Focus()
    })

    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $uiFont   = New-UiFont -Size 9
    $monoFont = New-Object System.Drawing.Font('Consolas', 9)
    $okColor  = [System.Drawing.Color]::FromArgb(0, 120, 40)
    $badColor = [System.Drawing.Color]::FromArgb(180, 30, 30)
    $okBack   = [System.Drawing.Color]::FromArgb(232, 245, 233)
    $badBack  = [System.Drawing.Color]::FromArgb(253, 236, 234)
    $offFore  = [System.Drawing.Color]::FromArgb(95, 99, 104)
    $offBack  = [System.Drawing.Color]::FromArgb(241, 243, 244)

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $script:WindowTitle
    $form.Size            = New-Object System.Drawing.Size(720, 758)
    # CenterScreen 은 '커서가 있는 모니터'를 기준으로 삼는다. 모니터가 여러 대면
    # 창이 엉뚱한 화면에 떠서 안 뜬 것처럼 보이므로, 주 모니터에 직접 배치한다.
    $form.StartPosition   = 'Manual'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.Font            = $uiFont
    $form.AutoScaleMode   = 'Font'

    $header = New-UiLabel -Parent $form -Text 'Destiny 2 프레임 끊김 완화 도구(D2SteamFix)의 실행 옵션 설정을 대신해 줍니다.' -X 14 -Y 12 -W 680

    # --- 1단계 -------------------------------------------------------------
    $g1 = New-UiGroup -Parent $form -Text ' 1단계 · 설치 상태 확인 ' -X 14 -Y 38 -W 676 -H 156

    $lblSteam = New-UiLabel -Parent $g1 -X 14 -Y 26 -W 648

    $lblGame = New-UiLabel -Parent $g1 -X 14 -Y 50 -W 648

    $lblExe = New-UiLabel -Parent $g1 -X 14 -Y 74 -W 648

    $btnRefresh = New-UiButton -Parent $g1 -Text '다시 검사' -X 14 -Y 98 -W 110

    $btnPick = New-UiButton -Parent $g1 -Text '게임 폴더 직접 지정' -X 132 -Y 98 -W 150

    # 평소엔 쓸 일이 없는 버튼이라 오른쪽 끝으로 밀어 둔다.
    $btnDiag = New-UiButton -Parent $g1 -Text '작동 안 될 때' -X 512 -Y 98 -W 150

    # 평소엔 비어 있고, 찾은 폴더에 게임 본체가 없을 때만 문구가 채워진다.
    $lblWarn = New-UiLabel -Parent $g1 -X 14 -Y 128 -W 648 `
        -FontSize 8.5 -ForeColor ([System.Drawing.Color]::FromArgb(176, 92, 0))

    # --- 2단계 -------------------------------------------------------------
    $g2 = New-UiGroup -Parent $form -Text ' 2단계 · steamfix.exe 준비 ' -X 14 -Y 202 -W 676 -H 92

    $lblGuide = New-UiLabel -Parent $g2 -Text 'GitHub 최신 릴리스의 Assets에서 steamfix.exe 를 받아 게임 폴더에 넣어 주세요.' `
        -X 14 -Y 24 -W 648

    $btnDownload = New-UiButton -Parent $g2 -Text '다운로드 안내 열기' -X 14 -Y 52 -W 150

    $btnCopyUrl = New-UiButton -Parent $g2 -Text '다운로드 주소 복사' -X 172 -Y 52 -W 150

    $btnOpenFolder = New-UiButton -Parent $g2 -Text '게임 폴더 열기' -X 330 -Y 52 -W 130

    $btnDefender = New-UiButton -Parent $g2 -Text '백신에 잡힐 때' -X 468 -Y 52 -W 130

    # --- 3단계 -------------------------------------------------------------
    $g3 = New-UiGroup -Parent $form -Text ' 3단계 · Steam 실행 옵션 설정 ' -X 14 -Y 302 -W 676 -H 222

    $lblAccount = New-UiLabel -Parent $g3 -Text 'Steam 계정' -X 14 -Y 28 -W 80

    $cmbAccount = New-Object System.Windows.Forms.ComboBox
    $cmbAccount.Location      = New-Object System.Drawing.Point(96, 24)
    $cmbAccount.Size          = New-Object System.Drawing.Size(566, 24)
    $cmbAccount.DropDownStyle = 'DropDownList'
    $g3.Controls.Add($cmbAccount)

    # 실행 옵션 문자열만 보여주면 켜진 건지 꺼진 건지 알기 어렵다.
    # 색으로 구분되는 상태 배너를 따로 둔다.
    $pnlStatus = New-Object System.Windows.Forms.Panel
    $pnlStatus.Location    = New-Object System.Drawing.Point(14, 52)
    $pnlStatus.Size        = New-Object System.Drawing.Size(648, 44)
    $pnlStatus.BorderStyle = 'FixedSingle'
    $g3.Controls.Add($pnlStatus)

    $lblStatus = New-UiLabel -Parent $pnlStatus -X 10 -Y 5 -W 626 -H 17 -FontSize 9 -Bold

    $lblStatusSub = New-UiLabel -Parent $pnlStatus -X 10 -Y 23 -W 626 -H 17 -FontSize 8.5

    $lblWillSet = New-UiLabel -Parent $g3 -Text '설정될 실행 옵션' -X 14 -Y 104 -W 648 -H 18

    $txtLaunch = New-Object System.Windows.Forms.TextBox
    $txtLaunch.Location   = New-Object System.Drawing.Point(14, 122)
    $txtLaunch.Size       = New-Object System.Drawing.Size(648, 24)
    $txtLaunch.ReadOnly   = $true
    $txtLaunch.Font       = $monoFont
    $txtLaunch.BackColor  = [System.Drawing.Color]::White
    $g3.Controls.Add($txtLaunch)

    $btnApply = New-UiButton -Parent $g3 -Text '자동으로 설정하기' -X 14 -Y 156 -W 160 -H 32

    $btnCopy = New-UiButton -Parent $g3 -Text '복사해서 직접 넣기' -X 182 -Y 156 -W 150 -H 32

    $btnRemove = New-UiButton -Parent $g3 -Text '설정 되돌리기' -X 340 -Y 156 -W 130 -H 32

    $btnBackupDir = New-UiButton -Parent $g3 -Text '백업 폴더 열기' -X 478 -Y 156 -W 130 -H 32

    # 백업이 어디에 쌓이는지 알 수 없으면 불안하다. 경로를 그대로 보여주고
    # 눌러서 바로 열 수 있게 한다.
    $lblBackupPath = New-UiLink -Parent $g3 -Text ('백업 위치: {0}   ·   최근 {1}개 보관' -f $script:StateDir, $script:BackupKeep) `
        -X 14 -Y 196 -W 648 -H 18 -FontSize 8.5 -LinkColor ([System.Drawing.Color]::FromArgb(95, 99, 104)) -HoverUnderline

    # --- 로그 ---------------------------------------------------------------
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location   = New-Object System.Drawing.Point(14, 538)
    $txtLog.Size       = New-Object System.Drawing.Size(676, 140)
    $txtLog.Multiline  = $true
    $txtLog.ReadOnly   = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.BackColor  = [System.Drawing.Color]::FromArgb(248, 248, 248)
    $form.Controls.Add($txtLog)

    $lblFooter = New-UiLink -Parent $form -Text '원본: github.com/d2checkpoint-com/D2SteamFix (GPL-2.0) · 별개의 보조 도구' `
        -X 14 -Y 684 -W 520

    $lblCredit = New-UiLabel -Parent $form -Text '만든이 · SDS' `
        -X 538 -Y 684 -W 152 -FontSize 8 -ForeColor ([System.Drawing.Color]::FromArgb(130, 130, 130)) -TextAlign 'MiddleRight'

    # --- 동작 ---------------------------------------------------------------

    $writeLog = {
        param([string]$Message)
        $txtLog.AppendText(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $Message, [Environment]::NewLine))
    }

    $getSelectedAccount = {
        if ($cmbAccount.SelectedIndex -lt 0) { return $null }
        if (-not $script:Accounts) { return $null }
        return @($script:Accounts)[$cmbAccount.SelectedIndex]
    }

    $setStatus = {
        param([string]$Title, [string]$Sub, $Fore, $Back)
        $pnlStatus.BackColor    = $Back
        $lblStatus.Text         = $Title
        $lblStatus.ForeColor    = $Fore
        $lblStatusSub.Text      = $Sub
        $lblStatusSub.ForeColor = $Fore
    }

    # 설정을 쓰기 전에 Steam 을 반드시 닫아야 한다. 켜져 있으면 Steam 이 종료할 때
    # localconfig.vdf 를 자기 기억대로 다시 써서 방금 넣은 값이 사라진다.
    # 계속 진행해도 되면 $true, 사용자가 취소했거나 종료에 실패하면 $false.
    $ensureSteamClosed = {
        if (-not (Test-SteamRunning)) { return $true }

        $ask = "Steam이 실행 중입니다.`n`n" +
               "Steam이 켜져 있으면 종료할 때 설정 파일을 다시 덮어써서 변경이 사라집니다.`n" +
               "지금 Steam을 종료할까요?"
        if (-not (Confirm-Action -Text $ask -Title 'Steam 종료 필요')) {
            & $writeLog '취소했습니다. Steam을 직접 종료한 뒤 다시 시도해 주세요.'
            return $false
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $stopped = Stop-SteamClient -SteamPath $script:SteamPath
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        if (-not $stopped) {
            Show-Note 'Steam이 종료되지 않았습니다. 직접 종료한 뒤 다시 시도해 주세요.' -Icon 'Warning'
            return $false
        }
        & $writeLog 'Steam을 종료했습니다.'
        return $true
    }

    $refreshCurrent = {
        $acc = & $getSelectedAccount
        if (-not $acc) {
            & $setStatus '○ 확인 불가 — 스팀 계정을 찾지 못했습니다' `
                         '스팀이 설치되어 있는지 확인한 뒤 [다시 검사]를 눌러 주세요.' $offFore $offBack
            return
        }

        $current = $null
        try { $current = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig } catch { $current = $null }

        if ($null -eq $current) {
            & $setStatus '○ 확인 불가 — 스팀 설정을 읽지 못했습니다' `
                         '스팀을 한 번 실행한 뒤 [다시 검사]를 눌러 주세요.' $offFore $offBack
            return
        }

        # 설정만 되어 있고 실제 파일이 없으면 게임이 아예 실행되지 않는다.
        # 켜짐/꺼짐과 구분해서 따로 알려준다.
        $hasFix   = ($current -match 'steamfix\.exe')
        $exeReady = $false
        if ($script:GameDir) {
            $exePath  = Join-Path $script:GameDir $script:ExeName
            $exeReady = (Test-Path $exePath) -and (Test-IsExecutable -Path $exePath)
        }

        # 도우미가 찾은 폴더가 아니라, 실행 옵션에 실제로 적힌 경로를 확인해야 한다.
        # 스팀은 이 경로로 프로세스를 만들기 때문에, 여기가 어긋나면 게임이 시작되지 않는다.
        $optionExe = Get-LaunchOptionExePath -Options $current
        $optionExeOk = $true
        if ($hasFix -and $optionExe) { $optionExeOk = (Test-Path -LiteralPath $optionExe) }

        if ($hasFix -and -not $optionExeOk) {
            & $setStatus '● 실행 불가 — 실행 옵션이 가리키는 파일이 없습니다' `
                         ("스팀이 이 경로를 실행하려다 실패합니다: {0}" -f $optionExe) $badColor $badBack
        }
        elseif ($hasFix -and $exeReady) {
            # 설정이 되어 있는데 기록 파일이 한 번도 안 생겼다면, 게임을 실행했는데도
            # steamfix 가 돌지 못했다는 뜻일 수 있다. 백신이 조용히 막는 경우가 이렇다.
            $logPath = Join-Path $script:GameDir 'steamfix.log'
            if (Test-Path -LiteralPath $logPath) {
                & $setStatus '● 설정됨 — 실행 기록이 있습니다' `
                             '게임을 실행하면 D2SteamFix 를 거쳐 시작됩니다. 스팀 오버레이 기능은 꺼집니다.' $okColor $okBack
            }
            else {
                & $setStatus '● 설정됨 — 아직 한 번도 실행된 적이 없습니다' `
                             '게임 실행 후에도 로그가 없으면 [작동 안 될 때]에서 경로와 백신 차단 기록을 확인하세요.' $okColor $okBack
            }
        }
        elseif ($hasFix) {
            & $setStatus '● 실행 불가 — 설정은 되어 있는데 steamfix.exe 가 없습니다' `
                         '이대로면 게임이 시작되지 않습니다. 2단계에서 파일을 넣거나 [설정 되돌리기]를 누르세요.' $badColor $badBack
        }
        elseif ($current -eq '') {
            & $setStatus '○ 꺼짐 — 평소대로 실행됩니다' `
                         'D2SteamFix 가 적용되어 있지 않습니다. 스팀 오버레이는 정상 동작합니다.' $offFore $offBack
        }
        else {
            & $setStatus '○ 꺼짐 — 평소대로 실행됩니다' `
                         ('D2SteamFix 는 적용되어 있지 않습니다. 현재 실행 옵션: {0}' -f $current) $offFore $offBack
        }
    }

    $detect = {
        $script:SteamPath = $null
        $script:GameDir   = $null
        $script:Accounts  = @()

        $script:SteamPath = Get-SteamPath
        if ($script:SteamPath) {
            $lblSteam.Text = ('Steam 설치 폴더 : {0}' -f $script:SteamPath)
            $lblSteam.ForeColor = $okColor
        }
        else {
            $lblSteam.Text = 'Steam 설치 폴더 : 찾지 못했습니다. Steam이 설치되어 있는지 확인해 주세요.'
            $lblSteam.ForeColor = $badColor
        }

        $settings = Get-Settings
        if ($settings -and $settings.PSObject.Properties['GameDir'] -and $settings.GameDir -and (Test-Path $settings.GameDir)) {
            $script:GameDir = $settings.GameDir
        }
        elseif ($script:SteamPath) {
            $script:GameDir = Get-Destiny2Path -SteamPath $script:SteamPath
        }

        if ($script:GameDir) {
            $lblGame.Text = ('Destiny 2 폴더  : {0}' -f $script:GameDir)
            $lblGame.ForeColor = $okColor
        }
        else {
            $lblGame.Text = 'Destiny 2 폴더  : 찾지 못했습니다. 아래 [게임 폴더 직접 지정]을 눌러 주세요.'
            $lblGame.ForeColor = $badColor
        }

        if ($script:GameDir) {
            $exePath = Join-Path $script:GameDir $script:ExeName
            if (Test-Path $exePath) {
                $size = [math]::Round((Get-Item $exePath).Length / 1KB, 1)
                if (Test-IsExecutable -Path $exePath) {
                    # 차단된 파일은 스팀이 실행하지 못한다. 파일은 멀쩡히 있어서
                    # 눈으로는 구분이 안 되므로 여기서 잡아준다.
                    if (Test-FileBlocked -Path $exePath) {
                        $lblExe.Text = ('steamfix.exe    : 차단된 파일입니다 ({0} KB)' -f $size)
                        $lblExe.ForeColor = $badColor
                        & $writeLog 'steamfix.exe 가 차단된 상태입니다. 이대로면 게임 실행에 실패합니다.'
                        $ask = "steamfix.exe 가 차단된 상태입니다.`n`n" +
                               "인터넷에서 받은 파일에 윈도우가 붙이는 표시 때문입니다.`n" +
                               "이 상태면 스팀이 실행하지 못해서 게임이 켜지지 않습니다.`n`n" +
                               "지금 차단을 해제할까요?"
                        if (Confirm-Action -Text $ask -Title '차단된 파일' -Icon 'Warning') {
                            if (Unblock-DownloadedFile -Path $exePath) {
                                & $writeLog '차단을 해제했습니다.'
                                $lblExe.Text = ('steamfix.exe    : 준비 완료 ({0} KB, 차단 해제됨)' -f $size)
                                $lblExe.ForeColor = $okColor
                            }
                            else {
                                & $writeLog '차단 해제에 실패했습니다. 파일 우클릭 - 속성 - 차단 해제를 직접 해 주세요.'
                            }
                        }
                    }
                    else {
                        $lblExe.Text = ('steamfix.exe    : 준비 완료 ({0} KB)' -f $size)
                        $lblExe.ForeColor = $okColor
                    }
                }
                else {
                    $lblExe.Text = ('steamfix.exe    : 실행 파일이 아닙니다 ({0} KB). 내려받다 실패한 것 같으니 다시 받아 주세요.' -f $size)
                    $lblExe.ForeColor = $badColor
                }
            }
            else {
                $lblExe.Text = 'steamfix.exe    : 게임 폴더에 없습니다. 2단계를 먼저 진행해 주세요.'
                $lblExe.ForeColor = $badColor
            }
            $txtLaunch.Text = New-LaunchString -GameDir $script:GameDir
        }
        else {
            $lblExe.Text = 'steamfix.exe    : 게임 폴더를 먼저 확인해 주세요.'
            $lblExe.ForeColor = $badColor
            $txtLaunch.Text = ''
        }

        # 게임이 실행되지 않는 두 가지 원인을 미리 잡아낸다.
        $lblWarn.Text = ''
        if ($script:GameDir -and -not (Test-GameFilesPresent -GameDir $script:GameDir)) {
            $lblWarn.Text = '※ 이 폴더에 destiny2.exe 가 없습니다. 게임이 다른 곳에 설치된 것 같습니다. [게임 폴더 직접 지정]을 눌러 주세요.'
            & $writeLog '주의: 찾은 폴더에 destiny2.exe 가 없습니다. 게임을 다른 라이브러리로 옮긴 흔적일 수 있습니다.'
            & $writeLog '이 상태로 설정하면 게임이 실행되지 않습니다. [게임 폴더 직접 지정]으로 실제 위치를 알려주세요.'
        }
        elseif ($script:GameDir -and -not (Test-FolderWritable -Path $script:GameDir)) {
            $lblWarn.Text = '※ 이 폴더에 쓰기 권한이 없습니다. steamfix 가 기록 파일을 만들지 못해 게임이 실행되지 않습니다.'
            & $writeLog '주의: 게임 폴더에 쓰기 권한이 없습니다.'
            & $writeLog 'steamfix 는 자기 옆에 steamfix.log 를 만들어야 하는데, 실패하면 시작하자마자 종료됩니다.'
            & $writeLog '폴더 속성 - 보안에서 사용자 계정에 "쓰기" 권한을 주면 해결됩니다.'
        }

        $cmbAccount.Items.Clear()
        if ($script:SteamPath) {
            $script:Accounts = @(Get-SteamAccounts -SteamPath $script:SteamPath)
            # Destiny 2 는 무료라 어느 계정에나 블록이 있어 구분에 쓸 수 없다.
            # 마지막 사용 날짜가 실제로 쓰는 계정을 가장 잘 알려준다.
            foreach ($acc in $script:Accounts) {
                $suffix = ''
                if ($acc.IsMostRecent) { $suffix = '  ← 자동 로그인 계정' }
                [void]$cmbAccount.Items.Add(('{0}  ·  최근 사용 {1}  (ID {2}){3}' -f $acc.Label, $acc.LastWrite.ToString('yyyy-MM-dd'), $acc.AccountId, $suffix))
            }
            if ($cmbAccount.Items.Count -gt 0) { $cmbAccount.SelectedIndex = 0 }
        }

        & $refreshCurrent
        & $writeLog '검사를 마쳤습니다.'
    }

    $btnRefresh.Add_Click({ & $detect })

    $cmbAccount.Add_SelectedIndexChanged({ & $refreshCurrent })

    $btnDiag.Add_Click({
        try {
            $report = Get-DiagnosticReport -SteamPath $script:SteamPath -GameDir $script:GameDir -Accounts $script:Accounts
            & $writeLog ('진단 정보를 만들었습니다. ({0}자)' -f $report.Length)
            Show-DiagnosticWindow -Report $report -Owner $form -GameDir $script:GameDir
        }
        catch {
            & $writeLog ('진단 정보 생성 실패: {0}' -f $_.Exception.Message)
            Show-Failure -Text '진단 정보를 만들지 못했습니다.' -Detail $_.Exception.Message
        }
    })

    $btnPick.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Destiny 2 가 설치된 폴더를 선택해 주세요 (destiny2.exe 가 있는 폴더)'
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $chosen = $dlg.SelectedPath
        if (-not (Test-Path (Join-Path $chosen 'destiny2.exe'))) {
            $ask = "선택한 폴더에 destiny2.exe 가 없습니다.`n`n$chosen`n`n그래도 이 폴더를 사용할까요?"
            if (-not (Confirm-Action -Text $ask -Title '폴더 확인' -Icon 'Warning')) { return }
        }

        $settings = Get-Settings
        if (-not $settings) { $settings = [pscustomobject]@{ GameDir = $chosen } }
        else { $settings | Add-Member -NotePropertyName GameDir -NotePropertyValue $chosen -Force }
        Save-Settings -Settings $settings

        & $writeLog ('게임 폴더를 직접 지정했습니다: {0}' -f $chosen)
        & $detect
    })

    $btnDownload.Add_Click({
        Start-Process $script:GuideUrl
        & $writeLog '브라우저에서 설치 안내(README)를 열었습니다.'
        & $writeLog ('배포 주소: {0}' -f $script:DownloadUrl)
        Show-Note ("열린 설치 안내의 최신 릴리스 링크를 누르세요.`n" +
            "릴리스 페이지의 Assets에서 steamfix.exe 를 받으세요.`n`n" +
            "최신 릴리스:`n$($script:DownloadUrl)`n`n" +
            "받은 파일은 [게임 폴더 열기]로 열리는 폴더에 넣어 주세요.") -Title '내려받는 방법'
    })

    $btnCopyUrl.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($script:DownloadUrl)
        & $writeLog ('최신 릴리스 주소 복사: {0}' -f $script:DownloadUrl)
        Show-Note "주소를 복사했습니다.`n브라우저에서 열고 Assets의 steamfix.exe 를 받으세요.`n`n$($script:DownloadUrl)" -Title '주소 복사됨'
    })

    # 원본 저장소 docs/WINDOWS_DEFENDER.md 의 절차를 한국어로 옮긴 것.
    # 보안 설정을 건드리는 명령이라 도우미가 대신 실행하지는 않는다.
    $btnDefender.Add_Click({
        $cmds = 'cd /d "C:\Program Files\Windows Defender"' + "`r`n" +
                'MpCmdRun.exe -removedefinitions -dynamicsignatures' + "`r`n" +
                'MpCmdRun.exe -SignatureUpdate'
        try { [System.Windows.Forms.Clipboard]::SetText($cmds) } catch { }
        & $writeLog '백신 대처 명령을 클립보드에 복사했습니다.'
        Show-Note ("steamfix.exe 가 백신에 잡히는 경우입니다.`n`n" +
            "[ 먼저 알아두실 것 ]`n`n" +
            "경고창이 뜨는 경우보다 아무 말 없이 막는 경우가 더 골치입니다.`n" +
            "실제 사례에서 윈도우 보안은 경고만 하고 실행은 됐고,`n" +
            "국내 백신은 아무 알림 없이 조용히 실행만 막았습니다.`n" +
            "게임이 안 켜지는데 백신 경고도 없다면 이쪽을 의심하세요.`n`n" +
            "확인 방법: [작동 안 될 때]에서 진단 정보를 확인하고`n" +
            "백신의 차단 기록과 steamfix.log 를 함께 확인하세요.`n`n" +
            "─────────────────────────────`n`n" +
            "[ 윈도우 보안(Defender)이 잡는 경우 ]`n`n" +
            "만든 사람이 마이크로소프트에 신고해서 오진으로 확인받았고,`n" +
            "마이크로소프트도 해당 탐지를 이미 지웠습니다.`n" +
            "그런데 내 PC의 백신 정의 파일이 오래됐으면 예전 탐지가 계속 뜹니다.`n`n" +
            "이럴 때는 정의 파일을 갱신하면 됩니다.`n`n" +
            "1. 시작 메뉴에서 '명령 프롬프트'를 찾아`n" +
            "   우클릭 - [관리자 권한으로 실행]`n`n" +
            "2. 아래 세 줄을 차례로 붙여넣고 각각 엔터`n" +
            "   (방금 클립보드에 복사해 두었습니다)`n`n" +
            "$cmds`n`n" +
            "3. 끝나면 steamfix.exe 를 다시 받아 주세요.`n`n" +
            "─────────────────────────────`n`n" +
            "[ V3, 알약 등 국내 백신을 쓰신다면 ]`n`n" +
            "위 명령은 윈도우 자체 백신용이라 도움이 되지 않습니다.`n" +
            "국내 백신은 마이크로소프트의 오탐 해제와 무관하게`n" +
            "자체 판단으로 차단하므로, 그 백신에서 직접 풀어야 합니다.`n`n" +
            "  1. 백신의 차단/격리 기록에서 steamfix.exe 를 찾아 복원`n" +
            "  2. 설정에서 검사 예외(제외) 목록에 아래를 추가`n" +
            "     게임 폴더 또는 steamfix.exe 파일`n" +
            "  3. 그래도 막히면 백신 제조사에 오탐 신고`n`n" +
            "※ 예외 등록은 그 파일을 검사 대상에서 빼는 것이라,`n" +
            "   출처를 믿을 수 있을 때만 하시는 게 맞습니다.`n" +
            "※ 이 도우미가 대신 실행하지는 않습니다.`n" +
            "   보안 설정을 바꾸는 명령이라 직접 확인하고 실행하시는 게 맞습니다.`n" +
            "※ 그래도 계속 잡히거나 찜찜하면 설치하지 않으셔도 됩니다.") -Title '백신에 잡힐 때'
    })

    $btnOpenFolder.Add_Click({
        if (-not $script:GameDir) {
            Show-Note '게임 폴더를 먼저 확인해 주세요.'
            return
        }
        Start-Process explorer.exe $script:GameDir
        & $writeLog '게임 폴더를 열었습니다. 받은 steamfix.exe 를 이 폴더에 넣어 주세요.'
    })

    $openBackupDir = {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        $count = @(Get-ChildItem -Path $script:StateDir -Filter 'localconfig-*.vdf.bak' -File -ErrorAction SilentlyContinue).Count
        & $writeLog ('백업 폴더: {0} (현재 {1}개)' -f $script:StateDir, $count)
        Start-Process explorer.exe $script:StateDir
    }

    $btnBackupDir.Add_Click({ & $openBackupDir })
    $lblBackupPath.Add_LinkClicked({ & $openBackupDir })

    $btnCopy.Add_Click({
        if (-not $txtLaunch.Text) {
            Show-Note '먼저 게임 폴더를 확인해 주세요.'
            return
        }
        [System.Windows.Forms.Clipboard]::SetText($txtLaunch.Text)
        & $writeLog '실행 옵션을 클립보드에 복사했습니다.'
        Show-Note ("복사했습니다. 아래 순서로 붙여넣어 주세요.`n`n" +
            "1. Steam 라이브러리에서 Destiny 2 를 우클릭`n" +
            "2. [속성] → [일반] 탭`n" +
            "3. [실행 옵션] 칸에 Ctrl+V 로 붙여넣기`n" +
            "4. 창을 닫으면 저장됩니다") -Title '붙여넣는 방법'
    })

    $btnApply.Add_Click({
        $acc = & $getSelectedAccount
        if (-not $acc) {
            Show-Note '설정할 Steam 계정을 찾지 못했습니다.' -Icon 'Warning'
            return
        }
        if (-not $script:GameDir) {
            Show-Note '게임 폴더를 먼저 확인해 주세요.' -Icon 'Warning'
            return
        }

        $exePath = Join-Path $script:GameDir $script:ExeName
        if (-not (Test-Path $exePath)) {
            $ask = "게임 폴더에 steamfix.exe 가 아직 없습니다.`n실행 옵션만 먼저 설정할까요?`n`n(나중에 파일을 넣으면 그대로 동작합니다)"
            if (-not (Confirm-Action -Text $ask -Title '확인' -Icon 'Warning')) { return }
        }

        if (-not (& $ensureSteamClosed)) { return }

        try {
            $existing = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig
            if ($null -eq $existing) { throw 'localconfig.vdf 구조를 읽지 못했습니다.' }

            $newValue = Merge-LaunchOptions -Existing $existing -SteamFixPart $txtLaunch.Text

            if ($existing -and ($existing -notmatch 'steamfix\.exe')) {
                $ask = "이미 실행 옵션이 설정되어 있습니다.`n`n변경 전:`n$existing`n`n변경 후:`n$newValue`n`n이대로 진행할까요?"
                if (-not (Confirm-Action -Text $ask -Title '기존 실행 옵션 확인')) { & $writeLog '취소했습니다.'; return }
            }

            $text    = [System.IO.File]::ReadAllText($acc.LocalConfig)
            $updated = Set-LaunchOptionsText -Text $text -NewValue $newValue
            $saved   = Save-LocalConfig -Path $acc.LocalConfig -Text $updated -AccountId $acc.AccountId

            & $writeLog ('설정 완료: {0}' -f $newValue)
            & $writeLog ('백업 저장: {0}' -f $saved.Path)
            if ($saved.Removed -gt 0) { & $writeLog ('오래된 백업 {0}개 정리 (최근 {1}개 보관)' -f $saved.Removed, $script:BackupKeep) }
            & $refreshCurrent

            $probe = Test-SteamFixFile -GameDir $script:GameDir
            if ($probe.Blocked) {
                & $writeLog ('파일 확인: {0}' -f $probe.Blocked)
                Show-Note ("실행 옵션은 저장했습니다.`n`n" + $probe.Blocked) -Title '파일 확인 필요' -Icon 'Warning'
            }
            else {
                Show-Note "설정이 끝났습니다.`n`nSteam을 다시 실행하고 Destiny 2 를 시작하세요.`n실행 가능 여부와 백신 차단 여부는 검사하지 않았습니다.`n`n※ Steam 오버레이 관련 기능(Steam Input, 알림, 게임 녹화, 원격 플레이)은 동작하지 않게 됩니다." -Title '완료'
            }
        }
        catch {
            & $writeLog ('오류: {0}' -f $_.Exception.Message)
            Show-Failure -Text '설정에 실패했습니다.' -Detail $_.Exception.Message
        }
    })

    $btnRemove.Add_Click({
        $acc = & $getSelectedAccount
        if (-not $acc) {
            Show-Note '되돌릴 Steam 계정을 찾지 못했습니다.' -Icon 'Warning'
            return
        }

        # 되돌릴 것이 없으면 Steam을 끄기 전에 먼저 알려준다.
        # 괜히 Steam부터 종료시켜 놓고 "바꿀 게 없다"고 하면 헛수고가 된다.
        try {
            $existing = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig
        }
        catch {
            & $writeLog ('오류: {0}' -f $_.Exception.Message)
            Show-Failure -Text '설정을 읽지 못했습니다.' -Detail $_.Exception.Message
            return
        }

        if (-not $existing) {
            & $writeLog '되돌릴 설정이 없습니다.'
            Show-Note "이 계정에는 실행 옵션이 설정되어 있지 않습니다.`n되돌릴 것이 없습니다." -Title '변경 없음'
            return
        }

        $newValue = Remove-SteamFixFromOptions -Existing $existing
        if ($newValue -eq $existing) {
            & $writeLog 'steamfix 설정이 없어 변경하지 않았습니다.'
            Show-Note "이 계정의 실행 옵션에는 D2SteamFix 설정이 없습니다.`n아무것도 바꾸지 않았습니다.`n`n현재 실행 옵션:`n$existing" -Title '변경 없음'
            return
        }

        $recovery = @(Get-RecoveryFiles -GameDir $script:GameDir -Options $existing)
        if ($recovery.Count -gt 0) {
            Show-Note ("권한 복구 파일이 남아 있어 설정 제거를 멈췄습니다.`n`n" +
                ($recovery -join "`n") + "`n`n게임을 정상 종료한 뒤 다시 시도하세요. 파일이 남으면 최신 steamfix.exe 를 직접 열어 복구를 진행하세요.`n복구는 Steam과 게임을 종료하고 오버레이 파일을 다시 받습니다. 창 내용을 확인한 뒤 진행하세요.`n복구 파일을 직접 삭제하지 마세요.") -Title '권한 복구 먼저 필요' -Icon 'Warning'
            return
        }

        if (-not (& $ensureSteamClosed)) { return }

        try {
            # Steam 은 종료하면서 localconfig.vdf 를 다시 쓴다. 위에서 읽어둔 값은
            # 이미 낡았을 수 있으므로, 실제로 고치기 직전에 다시 읽는다.
            $existing = Get-LaunchOptions -LocalConfigPath $acc.LocalConfig
            $recovery = @(Get-RecoveryFiles -GameDir $script:GameDir -Options $existing)
            if ($recovery.Count -gt 0) {
                Show-Note ("권한 복구 파일이 남아 있어 설정 제거를 멈췄습니다.`n`n" +
                    ($recovery -join "`n") + "`n`n게임을 정상 종료한 뒤 다시 시도하세요. 파일이 남으면 최신 steamfix.exe 를 직접 열어 복구를 진행하세요.`n복구는 Steam과 게임을 종료하고 오버레이 파일을 다시 받습니다. 창 내용을 확인한 뒤 진행하세요.`n복구 파일을 직접 삭제하지 마세요.") -Title '권한 복구 먼저 필요' -Icon 'Warning'
                return
            }

            $newValue = Remove-SteamFixFromOptions -Existing $existing
            if ($newValue -eq $existing) {
                & $writeLog 'steamfix 설정이 없어 변경하지 않았습니다.'
                Show-Note "되돌릴 D2SteamFix 설정이 없습니다.`n아무것도 바꾸지 않았습니다." -Title '변경 없음'
                return
            }

            $text    = [System.IO.File]::ReadAllText($acc.LocalConfig)
            $updated = Set-LaunchOptionsText -Text $text -NewValue $newValue
            $saved   = Save-LocalConfig -Path $acc.LocalConfig -Text $updated -AccountId $acc.AccountId

            & $writeLog ('되돌리기 완료. 남은 실행 옵션: <{0}>' -f $newValue)
            & $writeLog ('백업 저장: {0}' -f $saved.Path)
            if ($saved.Removed -gt 0) { & $writeLog ('오래된 백업 {0}개 정리 (최근 {1}개 보관)' -f $saved.Removed, $script:BackupKeep) }
            & $refreshCurrent

            $remain = "남은 실행 옵션 없이 깨끗하게 비웠습니다."
            if ($newValue) { $remain = "원래 쓰시던 실행 옵션은 그대로 두었습니다:`n$newValue" }

            Show-Note ("되돌리기가 끝났습니다.`n`n$remain`n`n" +
                "Steam을 다시 실행하면 Destiny 2 는 D2SteamFix 없이 시작됩니다.`n" +
                "Steam 오버레이 기능(Steam Input, 알림, 게임 녹화, 원격 플레이)도 다시 동작합니다.") -Title '완료'
        }
        catch {
            & $writeLog ('오류: {0}' -f $_.Exception.Message)
            Show-Failure -Text '되돌리기에 실패했습니다.' -Detail $_.Exception.Message
        }
    })

    $lblFooter.Add_LinkClicked({ Start-Process $script:RepoUrl })

    # 검사를 Shown 안에서 바로 돌리면 창이 다 그려지기 전에 UI 스레드가 막힌다.
    # 한 박자 늦춰서 창이 먼저 뜨게 한다.
    $startupTimer = New-Object System.Windows.Forms.Timer
    $startupTimer.Interval = 120
    $startupTimer.Add_Tick({ $startupTimer.Stop(); & $detect })

    # 화면에 그려지기 전(Load)에 위치를 잡아야 창이 튀지 않는다. DPI 배율이 적용된
    # 뒤의 실제 크기를 써야 하므로 $form.Size 가 아니라 Width/Height 를 읽는다.
    $form.Add_Load({
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $area.X + [int](($area.Width  - $form.Width)  / 2)
        $y = $area.Y + [int](($area.Height - $form.Height) / 2)
        # 주 모니터보다 창이 큰 경우까지 감안해 화면 밖으로 밀리지 않게 한다.
        if ($x -lt $area.X) { $x = $area.X }
        if ($y -lt $area.Y) { $y = $area.Y }
        $form.Location = New-Object System.Drawing.Point($x, $y)
    })

    $form.Add_Shown({
        $lblSteam.Text = 'Steam 설치 폴더 : 확인 중...'
        $lblGame.Text  = 'Destiny 2 폴더  : 확인 중...'
        $lblExe.Text   = 'steamfix.exe    : 확인 중...'
        & $writeLog 'Steam과 Destiny 2 설치 상태를 확인합니다...'
        $form.Refresh()
        $startupTimer.Start()
    })

    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------

if ($SelfTest) { Invoke-SelfTest; return }   # 자체 검사는 콘솔 출력이 필요하므로 숨기지 않는다

# 중복 실행 방지. 이름 있는 뮤텍스를 먼저 잡아 보고, 이미 잡혀 있으면 두 번째 인스턴스다.
$createdNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$createdNew)

if (-not $createdNew) {
    Hide-ConsoleWindow
    if (-not (Show-ExistingWindow -Title $script:WindowTitle)) {
        # 창을 찾지 못한 경우에만 알린다. 찾았으면 앞으로 띄우는 것으로 충분하다.
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Show-Note '도우미가 이미 실행 중입니다.' -Title '중복 실행'
        }
        catch { }
    }
    return
}

try {
    Hide-ConsoleWindow
    Show-MainWindow
}
catch {
    # 콘솔을 숨긴 뒤라 오류 메시지가 갈 곳이 없다. 창으로 띄운다.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Show-Failure -Text '도우미를 시작하지 못했습니다.' -Detail $_.Exception.Message
    }
    catch { Write-Error $_ }
    exit 1
}
finally {
    if ($script:InstanceMutex) {
        try { [void]$script:InstanceMutex.ReleaseMutex() } catch { }
        $script:InstanceMutex.Dispose()
    }
}
