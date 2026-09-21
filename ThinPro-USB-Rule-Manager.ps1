[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Remote files managed by this tool.
$RulePath = '/etc/udev/rules.d/98-horizon-usb-managed.rules'
$VmwareConfig = '/etc/vmware/config'

function Pause-Console {
    Write-Host ''
    [void](Read-Host '按 Enter 返回主菜单')
}

function Show-Banner {
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = 'ThinPro Horizon USB 规则管理器' } catch {}
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '          ThinPro Horizon USB Rule Manager' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '          USB 重定向设备规则管理工具' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  github.com/tbc0309/ThinPro-Horizon-USB-Rule-Manager' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  功能：读取 USB 设备、添加或删除 Horizon 重定向规则、恢复原始配置' -ForegroundColor Gray
    Write-Host '  提示：绿色表示已加入，白色表示尚未加入' -ForegroundColor DarkGray
    Write-Host ''
}

function Initialize-Plink {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    # Remove password files left behind only if a previous run was interrupted.
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'thinpro-usb-*.pwd' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $script:PlinkPath = Join-Path $PSScriptRoot 'plink.exe'
    if (-not (Test-Path -LiteralPath $script:PlinkPath)) {
        throw "工具目录中缺少 plink.exe：$script:PlinkPath"
    }
    $expectedHash = '969f36879d5716aa1a9811f43a6a6510e8f08372dbeb9695b810b9c776f39c75'
    $stream = [IO.File]::OpenRead($script:PlinkPath)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $actualHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally { $stream.Dispose() }
    if ($actualHash -ne $expectedHash) {
        throw 'plink.exe 的 SHA-256 校验失败，文件可能损坏或被替换，已拒绝运行。'
    }
}

function New-PasswordFile([Security.SecureString]$Password) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    $path = Join-Path ([IO.Path]::GetTempPath()) ("thinpro-usb-{0}.pwd" -f [Guid]::NewGuid().ToString('N'))
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, $plain, $utf8NoBom)
    $plain = $null
    & icacls.exe $path /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
    return $path
}

function Invoke-Remote([string]$Command) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $plinkArgs = @('-ssh', '-batch', '-no-antispoof', '-pwfile', $script:PasswordFile)
        if ($script:HostKeyFingerprint) { $plinkArgs += @('-hostkey', $script:HostKeyFingerprint) }
        $plinkArgs += @("root@$script:TargetHost", $Command)
        $output = @('' | & $script:PlinkPath @plinkArgs 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) {
        $message = ($output -join "`n").Trim()
        throw "远程命令失败（退出码 $code）：`n$message"
    }
    return ($output -join "`n")
}

function Confirm-HostKey {
    if ($script:HostKeyFingerprint) {
        Invoke-Remote 'true' | Out-Null
        return
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $probe = @('' | & $script:PlinkPath -ssh -batch -no-antispoof -pwfile $script:PasswordFile "root@$script:TargetHost" 'true' 2>&1)
        $probeCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($probeCode -eq 0) { return }
    $text = $probe -join "`n"
    if ($text -match 'host key is not cached|host key does not match|key fingerprint') {
        $fingerprintMatch = [regex]::Match($text, 'SHA256:[A-Za-z0-9+/=]+')
        if (-not $fingerprintMatch.Success) {
            throw "无法从 Plink 输出中提取 SSH 主机指纹：`n$text"
        }
        $script:HostKeyFingerprint = $fingerprintMatch.Value
        Write-Host "`n首次连接，需要确认 ThinPro SSH 主机指纹：" -ForegroundColor Yellow
        Write-Host $text
        Write-Host "提取到的指纹：$script:HostKeyFingerprint" -ForegroundColor Cyan
        $answer = Read-Host '确认这是目标 ThinPro 并使用该指纹连接？[Y/N]'
        if ([string]$answer -notmatch '^(y|yes|是)$') { throw '用户取消了主机指纹确认。' }
        Invoke-Remote 'true' | Out-Null
    } else {
        throw "连接失败：`n$text"
    }
}

function Read-RemoteFile([string]$Path) {
    $quoted = "'$Path'"
    $encoded = Invoke-Remote "if [ -f $quoted ]; then base64 -w0 $quoted; fi"
    if ([string]::IsNullOrWhiteSpace($encoded)) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Trim()))
}

function Test-RemoteFile([string]$Path) {
    return ((Invoke-Remote "if [ -f '$Path' ]; then echo 1; else echo 0; fi").Trim() -eq '1')
}

function Initialize-DeviceIdentity {
    $identityCommand = "if [ -s /etc/machine-id ]; then cat /etc/machine-id; elif [ -s /var/lib/dbus/machine-id ]; then cat /var/lib/dbus/machine-id; elif [ -s /sys/class/net/eth0/address ]; then tr -d ':' < /sys/class/net/eth0/address; fi"
    $identity = (Invoke-Remote $identityCommand).Trim().ToLowerInvariant()
    $identity = $identity -replace '[^a-z0-9._-]', ''
    if ([string]::IsNullOrWhiteSpace($identity)) { throw '无法读取 ThinPro 的稳定机器标识。' }
    $script:DeviceId = $identity
    $script:DeviceBackupName = "ThinPro_$identity"
}

function Initialize-PristineBackup {
    $root = Join-Path $env:LOCALAPPDATA 'ThinPro-USB-Rule-Manager\Backups'
    $script:PristineBackupDir = Join-Path $root $script:DeviceBackupName
    $manifestPath = Join-Path $script:PristineBackupDir 'original-backup.json'
    $remoteBackupCommand = @(
        'fsunlock >/dev/null 2>&1 || true',
        "if [ ! -e '$VmwareConfig.bak' ] && [ ! -e '$VmwareConfig.bak.absent' ]; then if [ -f '$VmwareConfig' ]; then cp -a '$VmwareConfig' '$VmwareConfig.bak'; else : > '$VmwareConfig.bak.absent'; fi; fi",
        "if [ ! -e '$RulePath.bak' ] && [ ! -e '$RulePath.bak.absent' ]; then if [ -f '$RulePath' ]; then cp -a '$RulePath' '$RulePath.bak'; else : > '$RulePath.bak.absent'; fi; fi",
        'sync',
        'fslock >/dev/null 2>&1 || true'
    ) -join '; '
    Invoke-Remote $remoteBackupCommand | Out-Null
    Write-Host "ThinPro 同级原始备份：$VmwareConfig.bak、$RulePath.bak" -ForegroundColor DarkGreen

    if (Test-Path -LiteralPath $manifestPath) {
        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not ($existingManifest.PSObject.Properties.Name -contains 'deviceId')) {
            $existingManifest | Add-Member -NotePropertyName deviceId -NotePropertyValue $script:DeviceId
            $existingManifest | Add-Member -NotePropertyName lastKnownIp -NotePropertyValue $script:TargetHost
            [IO.File]::WriteAllText($manifestPath, ($existingManifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        }
        Write-Host "已找到 Windows 端备份副本：$manifestPath" -ForegroundColor DarkGreen
        return
    }

    [IO.Directory]::CreateDirectory($script:PristineBackupDir) | Out-Null
    $configExists = Test-RemoteFile $VmwareConfig
    $rulesExist = Test-RemoteFile $RulePath
    $configText = if ($configExists) { Read-RemoteFile $VmwareConfig } else { '' }
    $rulesText = if ($rulesExist) { Read-RemoteFile $RulePath } else { '' }
    $manifest = [ordered]@{
        formatVersion = 1
        createdAt = (Get-Date).ToString('o')
        deviceId = $script:DeviceId
        lastKnownIp = $script:TargetHost
        files = @(
            [ordered]@{ path = $VmwareConfig; existed = $configExists; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($configText)) },
            [ordered]@{ path = $RulePath; existed = $rulesExist; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rulesText)) }
        )
    }
    $json = $manifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $script:PristineBackupDir 'README.txt'),
        "这是 $($script:TargetHost) 在首次运行 USB 规则管理器时保存的原始配置。`r`n请勿修改或删除 original-backup.json。`r`n可在管理器菜单中使用它恢复并清理本工具的修改。`r`n",
        (New-Object Text.UTF8Encoding($true)))
    Write-Host "首次原始备份已永久保存：$manifestPath" -ForegroundColor Green
}

function Restore-PristineBackup {
    $configBak = Test-RemoteFile "$VmwareConfig.bak"
    $configAbsent = Test-RemoteFile "$VmwareConfig.bak.absent"
    $rulesBak = Test-RemoteFile "$RulePath.bak"
    $rulesAbsent = Test-RemoteFile "$RulePath.bak.absent"
    if ((-not $configBak -and -not $configAbsent) -or (-not $rulesBak -and -not $rulesAbsent)) {
        throw 'ThinPro 同级目录中的首次 .bak 备份或 .bak.absent 标记不完整，已拒绝恢复。'
    }
    Write-Host '此操作会从 ThinPro 同级 .bak 恢复首次原件，并删除首次运行时不存在的托管规则文件。' -ForegroundColor Yellow
    $confirm = Read-Host "请输入 RESTORE 确认恢复 $($script:TargetHost)"
    if ($confirm -cne 'RESTORE') { Write-Host '恢复已取消。'; return }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Invoke-Remote "fsunlock >/dev/null 2>&1 || true; [ ! -f '$VmwareConfig' ] || cp -a '$VmwareConfig' '$VmwareConfig.before-restore-$stamp'; [ ! -f '$RulePath' ] || cp -a '$RulePath' '$RulePath.before-restore-$stamp'" | Out-Null
    try {
        if ($configBak) { Invoke-Remote "cp -a '$VmwareConfig.bak' '$VmwareConfig'" | Out-Null }
        else { Invoke-Remote "rm -f '$VmwareConfig'" | Out-Null }
        if ($rulesBak) { Invoke-Remote "cp -a '$RulePath.bak' '$RulePath'" | Out-Null }
        else { Invoke-Remote "rm -f '$RulePath'" | Out-Null }
        Invoke-Remote 'udevadm control --reload-rules; sync; fslock >/dev/null 2>&1 || true' | Out-Null
        Write-Host '已恢复首次原始状态，并清理本工具后来添加的规则。请拔插 USB 设备。' -ForegroundColor Green
    } catch {
        Invoke-Remote 'fslock >/dev/null 2>&1 || true' | Out-Null
        throw
    }
}

function Show-BackupStatus {
    Write-Host ''
    Write-Host '  实际备份状态' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray

    foreach ($item in @(
        [pscustomobject]@{ Name = 'Horizon 配置'; Path = $VmwareConfig },
        [pscustomobject]@{ Name = 'USB 规则'; Path = $RulePath }
    )) {
        if (Test-RemoteFile "$($item.Path).bak") {
            Write-Host "  $($item.Name)：原文件存在" -ForegroundColor Green
            Write-Host "    $($item.Path).bak" -ForegroundColor Gray
        } elseif (Test-RemoteFile "$($item.Path).bak.absent") {
            Write-Host "  $($item.Name)：首次运行时不存在" -ForegroundColor Yellow
            Write-Host "    $($item.Path).bak.absent" -ForegroundColor Gray
        } else {
            Write-Host "  $($item.Name)：未找到首次备份" -ForegroundColor Red
        }
        Write-Host ''
    }

    $localBackup = Join-Path $script:PristineBackupDir 'original-backup.json'
    if (Test-Path -LiteralPath $localBackup) {
        Write-Host '  Windows 备份副本：已保存' -ForegroundColor Green
        Write-Host "    $localBackup" -ForegroundColor Gray
    } else {
        Write-Host '  Windows 备份副本：未找到' -ForegroundColor Red
    }
}

function Write-RemoteFile([string]$Path, [string]$Content) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
    $quoted = "'$Path'"
    $temp = "$Path.codex-new"
    $qTemp = "'$temp'"
    Invoke-Remote "printf '%s' '$encoded' | base64 -d > $qTemp && chmod 0644 $qTemp && mv $qTemp $quoted" | Out-Null
}

function Get-ManagedEntries([string]$RuleText) {
    $entries = @()
    foreach ($line in ($RuleText -split "`r?`n")) {
        if ($line -match '^# managed vid=([0-9a-f]{4}) pid=([0-9a-f]{4}) name=(.*)$') {
            $entries += [pscustomobject]@{ Vid = $Matches[1]; Pid = $Matches[2]; Name = $Matches[3] }
        }
    }
    return $entries
}

function Build-RuleText($Entries) {
    $lines = @(
        '# Managed by ThinPro Horizon USB Rule Manager',
        '# Leave matching devices available for the Horizon USB arbitrator.'
    )
    foreach ($entry in ($Entries | Sort-Object Vid, Pid)) {
        $safeName = ([string]$entry.Name) -replace '[\r\n]', ' '
        $lines += "# managed vid=$($entry.Vid) pid=$($entry.Pid) name=$safeName"
        $lines += "ACTION==`"add`", SUBSYSTEM==`"usb`", ENV{DEVTYPE}==`"usb_device`", ATTR{idVendor}==`"$($entry.Vid)`", ATTR{idProduct}==`"$($entry.Pid)`", RUN+=`"/bin/sh -c 'echo 0 > /sys%p/bConfigurationValue || true'`""
    }
    return (($lines -join "`n") + "`n")
}

function Update-IncludeVidPid([string]$Config, $Entries) {
    $managedTokens = @($Entries | ForEach-Object { "vid-$($_.Vid)_pid-$($_.Pid)" })
    $lines = @($Config -split "`r?`n")
    $index = -1
    $tokens = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*viewusb\.IncludeVidPid\s*=\s*"([^"]*)"') {
            $index = $i
            foreach ($token in ($Matches[1] -split ';')) {
                $t = $token.Trim().ToLowerInvariant()
                if ($t -match '^vid-[0-9a-f]{4}_pid-[0-9a-f]{4}$' -and -not $tokens.Contains($t)) {
                    $tokens.Add($t)
                }
            }
            break
        }
    }

    foreach ($token in $managedTokens) {
        if (-not $tokens.Contains($token)) { $tokens.Add($token) }
    }

    $newLine = 'viewusb.IncludeVidPid = "' + (($tokens | Sort-Object) -join ';') + ';"'
    if ($index -ge 0) { $lines[$index] = $newLine } else { $lines += $newLine }
    return (($lines -join "`n").TrimEnd() + "`n")
}

function Remove-IncludeToken([string]$Config, [string]$Vid, [string]$ProductId) {
    $remove = "vid-$Vid`_pid-$ProductId"
    $lines = @($Config -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*viewusb\.IncludeVidPid\s*=\s*"([^"]*)"') {
            $tokens = @($Matches[1] -split ';' | ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { $_ -match '^vid-[0-9a-f]{4}_pid-[0-9a-f]{4}$' -and $_ -ne $remove })
            $lines[$i] = 'viewusb.IncludeVidPid = "' + (($tokens | Sort-Object -Unique) -join ';') + ';"'
            break
        }
    }
    return (($lines -join "`n").TrimEnd() + "`n")
}

function Commit-Configuration($Entries, [string]$NewVmwareConfig) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $oldRules = Read-RemoteFile $RulePath
    $oldConfig = Read-RemoteFile $VmwareConfig
    try {
        Invoke-Remote "fsunlock >/dev/null 2>&1 || true; cp -a '$VmwareConfig' '$VmwareConfig.bak-$stamp'; if [ -f '$RulePath' ]; then cp -a '$RulePath' '$RulePath.bak-$stamp'; fi" | Out-Null
        Write-RemoteFile $RulePath (Build-RuleText $Entries)
        Write-RemoteFile $VmwareConfig $NewVmwareConfig
        Invoke-Remote "udevadm control --reload-rules && udevadm test /sys/bus/usb/devices/usb1 >/tmp/usb-rule-test.log 2>&1 || true; sync; fslock >/dev/null 2>&1 || true" | Out-Null
    }
    catch {
        Write-Host '写入失败，正在恢复原配置……' -ForegroundColor Red
        try {
            Invoke-Remote 'fsunlock >/dev/null 2>&1 || true' | Out-Null
            Write-RemoteFile $RulePath $oldRules
            Write-RemoteFile $VmwareConfig $oldConfig
            Invoke-Remote 'udevadm control --reload-rules; sync; fslock >/dev/null 2>&1 || true' | Out-Null
        } catch { Write-Warning "自动回滚也失败：$($_.Exception.Message)" }
        throw
    }
}

function Show-Entries {
    $entries = @(Get-ManagedEntries (Read-RemoteFile $RulePath))
    if ($entries.Count -eq 0) {
        Write-Host ''
        Write-Host '  当前没有由本工具管理的设备。' -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host '  已加入的设备' -ForegroundColor Green
        Write-Host ''
        Write-Host '  设备 ID          设备名称' -ForegroundColor Green
        Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGreen
        foreach ($entry in $entries) {
            Write-Host ("  {0}:{1}         {2}" -f $entry.Vid, $entry.Pid, $entry.Name) -ForegroundColor Green
            Write-Host ''
        }
    }
}

function Get-UsbDevices {
    $scanScript = @'
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [ -r "$d/idProduct" ] || continue
    v=$(cat "$d/idVendor")
    p=$(cat "$d/idProduct")
    [ "$v" = "1d6b" ] && continue
    n=$(cat "$d/product" 2>/dev/null)
    [ -n "$n" ] || n=$(cat "$d/manufacturer" 2>/dev/null)
    [ -n "$n" ] || n="Unknown USB device"
    n=$(printf "%s" "$n" | tr '\r\n\t' '   ')
    x=$(cat "$d/devnum" 2>/dev/null)
    printf "%s\t%s\t%s\t%s\n" "$v" "$p" "$n" "$x"
done
'@
    $scanScript = $scanScript.Replace("`r", '')
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scanScript))
    $encoded = (Invoke-Remote "echo $payload | base64 -d | sh | base64 -w0").Trim()
    if ([string]::IsNullOrWhiteSpace($encoded)) { return @() }
    try { $output = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) }
    catch { throw "USB 列表解码失败。远端返回：$encoded" }
    $devices = @()
    foreach ($line in ($output -split "`r?`n")) {
        $fields = @($line -split "`t", 4)
        if ($fields.Count -ne 4 -or $fields[0] -notmatch '^[0-9A-Fa-f]{4}$' -or $fields[1] -notmatch '^[0-9A-Fa-f]{4}$' -or $fields[3] -notmatch '^[0-9]+$') { continue }
        $devices += [pscustomobject]@{ Vid = $fields[0].ToLowerInvariant(); Pid = $fields[1].ToLowerInvariant(); Name = $fields[2].Trim(); Instance = $fields[3] }
    }
    return @($devices | Sort-Object Vid, Pid, Name, Instance -Unique)
}

function Show-UsbDeviceList($Devices, $Entries) {
    Write-Host ''
    Write-Host '  当前 USB 设备' -ForegroundColor Cyan
    Write-Host '  绿色 = 已加入    白色 = 未加入' -ForegroundColor DarkGray
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  编号  VID   PID   设备名称' -ForegroundColor Gray
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    if ($Devices.Count -eq 0) { Write-Host '  当前没有检测到外接 USB 设备。' -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $d = $Devices[$i]
        $added = [bool]($Entries | Where-Object { $_.Vid -eq $d.Vid -and $_.Pid -eq $d.Pid })
        $suffix = if ($added) { ' [已加入]' } else { '' }
        $color = if ($added) { 'Green' } else { 'White' }
        Write-Host ("  {0,2}.  {1}  {2}  {3}{4}" -f ($i + 1), $d.Vid, $d.Pid, $d.Name, $suffix) -ForegroundColor $color
    }
}

function Select-And-AddUsbDevice {
    $entries = @(Get-ManagedEntries (Read-RemoteFile $RulePath))
    $devices = @(Get-UsbDevices)
    Show-UsbDeviceList $devices $entries
    if ($devices.Count -eq 0) { Write-Host '当前列表为空。' -ForegroundColor Yellow; Pause-Console; return }
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '   0.  返回主菜单' -ForegroundColor Gray
    Write-Host ''
    $selection = Read-Host '  > 输入要添加的设备编号'
    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 0 -or $number -gt $devices.Count) {
        Write-Host '编号无效。' -ForegroundColor Red
        Pause-Console
        return
    }
    if ($number -eq 0) { return }
    $device = $devices[$number - 1]
    if ($entries | Where-Object { $_.Vid -eq $device.Vid -and $_.Pid -eq $device.Pid }) {
        Write-Host "$($device.Vid):$($device.Pid) 已经加入，无需重复操作。" -ForegroundColor Green
        Pause-Console
        return
    }
    Write-Host "即将加入：$($device.Vid):$($device.Pid)  $($device.Name)" -ForegroundColor Yellow
    Write-Host '加入后，该设备会等待 Horizon 接管，可能无法作为 ThinPro 本地设备使用。' -ForegroundColor Yellow
    $confirm = Read-Host '确认添加？[Y/N]'
    if ([string]$confirm -notmatch '^(y|yes|是)$') { return }
    $entries += [pscustomobject]@{ Vid = $device.Vid; Pid = $device.Pid; Name = $device.Name }
    $config = Update-IncludeVidPid (Read-RemoteFile $VmwareConfig) $entries
    Commit-Configuration $entries $config
    Write-Host '添加成功。请物理拔插设备，再从 Horizon 中连接。' -ForegroundColor Green
    Pause-Console
}

function Select-And-RemoveEntry {
    $entries = @(Get-ManagedEntries (Read-RemoteFile $RulePath))
    if ($entries.Count -eq 0) { Write-Host '当前没有可删除的条目。'; Pause-Console; return }
    Write-Host ''
    Write-Host '  选择要删除的设备' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        Write-Host ("  {0,2}.  {1}  {2}  {3}" -f ($i + 1), $e.Vid, $e.Pid, $e.Name) -ForegroundColor Green
    }
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '   0.  返回主菜单' -ForegroundColor Gray
    Write-Host ''
    $selection = Read-Host '  > 输入要删除的设备编号'
    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 0 -or $number -gt $entries.Count) {
        Write-Host '编号无效。' -ForegroundColor Red; Pause-Console; return
    }
    if ($number -eq 0) { return }
    $entry = $entries[$number - 1]
    $confirm = Read-Host "确认删除 $($entry.Vid):$($entry.Pid) $($entry.Name)？[Y/N]"
    if ([string]$confirm -notmatch '^(y|yes|是)$') { return }
    $newEntries = @($entries | Where-Object { $_.Vid -ne $entry.Vid -or $_.Pid -ne $entry.Pid })
    $config = Remove-IncludeToken (Read-RemoteFile $VmwareConfig) $entry.Vid $entry.Pid
    Commit-Configuration $newEntries $config
    Write-Host '删除成功。请物理拔插设备使变化生效。' -ForegroundColor Green
    Pause-Console
}

try {
    Show-Banner
    Initialize-Plink
    Write-Host '  连接信息' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
    $ip = (Read-Host '  > ThinPro IP 地址').Trim()
    if ($ip -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw 'IP 或主机名格式无效。' }
    $password = Read-Host '  > 管理员密码' -AsSecureString
    $script:PasswordFile = New-PasswordFile $password
    $password.Dispose()
    $script:TargetHost = $ip
    Write-Host ''
    Write-Host "  正在连接 $ip ……" -ForegroundColor Cyan
    Confirm-HostKey
    Invoke-Remote 'true' | Out-Null
    Write-Host '  连接成功。' -ForegroundColor Green
    Initialize-DeviceIdentity
    Write-Host "ThinPro 稳定机器标识：$script:DeviceId" -ForegroundColor DarkGreen
    Initialize-PristineBackup

    do {
        Clear-Host
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '          ThinPro USB 规则管理' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host ("  已连接：{0}" -f $script:TargetHost) -ForegroundColor Green
        Write-Host ''
        Write-Host '  USB 设备规则' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '      [1]  扫描设备并添加规则'
        Write-Host ''
        Write-Host '      [2]  查看已加入设备'
        Write-Host ''
        Write-Host '      [3]  删除设备规则'
        Write-Host ''
        Write-Host '  备份与维护' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '      [4]  恢复首次原始状态'
        Write-Host ''
        Write-Host '      [5]  查看备份位置'
        Write-Host ''
        Write-Host '      [6]  退出工具' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  --------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ''
        $choice = Read-Host '  请输入编号'
        switch ($choice) {
            '1' { Select-And-AddUsbDevice }
            '2' { Show-Entries; Pause-Console }
            '3' { Select-And-RemoveEntry }
            '4' { try { Restore-PristineBackup } catch { Write-Host $_.Exception.Message -ForegroundColor Red }; Pause-Console }
            '5' {
                Show-BackupStatus
                Pause-Console
            }
            '6' { break }
            default { Write-Host '无效选择。' -ForegroundColor Yellow }
        }
    } while ($choice -ne '6')
}
catch {
    Write-Host "错误：$($_.Exception.Message)" -ForegroundColor Red
    Pause-Console
}
finally {
    if ($script:PasswordFile -and (Test-Path -LiteralPath $script:PasswordFile)) {
        Remove-Item -LiteralPath $script:PasswordFile -Force -ErrorAction SilentlyContinue
    }
}
