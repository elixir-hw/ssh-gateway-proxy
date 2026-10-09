# Windows PowerShell 5.1; runs the packaged proxy and an SSH reverse tunnel.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Run', 'Start', 'Stop', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configPath = Join-Path $root 'config.json'
$proxyExe = Join-Path $root 'bin\ssh-gateway-proxy.exe'
$remoteSetup = Join-Path $root 'remote-setup.sh'
$secretDir = Join-Path $root '.secrets'
$secretFile = Join-Path $secretDir 'proxy-password.txt'
$logDir = Join-Path $root '.logs'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Missing config.json: $configPath"
}
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$sshAlias = [string]$config.sshAlias
$localPort = [int]$config.localPort
$remotePort = [int]$config.remotePort
$privateHosts = @($config.allowedPrivateHosts)

if ($sshAlias -notmatch '^[A-Za-z0-9._-]+$' -or $sshAlias -eq 'CHANGE_ME') {
    throw 'Set sshAlias in config.json to a concrete alias from your ~/.ssh/config.'
}
if ($localPort -lt 1 -or $localPort -gt 65535 -or
    $remotePort -lt 1 -or $remotePort -gt 65535) {
    throw 'localPort and remotePort must be between 1 and 65535.'
}
foreach ($privateHost in $privateHosts) {
    if ($privateHost -notmatch '^[A-Za-z0-9.-]+$' -or
        $privateHost -eq 'gateway.example.internal') {
        throw 'Replace the sample allowedPrivateHosts entry with your gateway host, or use an empty array.'
    }
}

$taskName = "SshGatewayProxy-$sshAlias"
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "SSH 网关代理 ($sshAlias).lnk"
$forwardSpec = "127.0.0.1:${remotePort}:127.0.0.1:${localPort}"
$proxyLog = Join-Path $logDir 'proxy.log'
$sshLog = Join-Path $logDir 'ssh.log'

function Initialize-Secret {
    New-Item -ItemType Directory -Path $secretDir,$logDir -Force | Out-Null
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $secretDir '/inheritance:r' '/grant:r' "*${sid}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the secret directory.' }

    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
        $bytes = New-Object byte[] 24
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        [System.IO.File]::WriteAllText($secretFile,
            [BitConverter]::ToString($bytes).Replace('-', ''))
    }
    $password = [System.IO.File]::ReadAllText($secretFile).Trim()
    if ($password -notmatch '^[A-Fa-f0-9]{48}$') {
        throw 'The proxy password file is malformed.'
    }
    return $password
}

function Stop-ManagedProcesses {
    $proxyPath = $proxyExe.ToLowerInvariant()
    Get-CimInstance Win32_Process | ForEach-Object {
        $command = [string]$_.CommandLine
        if (-not $command) { return }
        $ownedProxy = $_.Name -ieq 'ssh-gateway-proxy.exe' -and
            $command.ToLowerInvariant().Contains($proxyPath) -and
            $command.Contains("--port $localPort")
        $ownedTunnel = $_.Name -ieq 'ssh.exe' -and
            $command.Contains("-R $forwardSpec") -and
            $command.Contains($sshAlias)
        if ($ownedProxy -or $ownedTunnel) {
            Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        }
    }
}

function Start-LocalProxy {
    $env:LOCAL_CONNECT_PROXY_PASSWORD = $password
    try {
        $arguments = @('--bind', '127.0.0.1', '--port', "$localPort", '--username', 'proxy')
        foreach ($privateHost in $privateHosts) {
            $arguments += @('--allow-private-host', [string]$privateHost)
        }
        return Start-Process -FilePath $proxyExe -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardError $proxyLog -PassThru
    }
    finally {
        Remove-Item Env:\LOCAL_CONNECT_PROXY_PASSWORD -ErrorAction SilentlyContinue
    }
}

function Start-SshTunnel {
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    return Start-Process -FilePath $ssh -ArgumentList @(
        '-N', '-T', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ForwardX11=no', '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3', '-R', $forwardSpec, $sshAlias
    ) -WindowStyle Hidden -RedirectStandardError $sshLog -PassThru
}

function Start-InstalledTask {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { throw "Task $taskName is missing. Run -Action Install first." }
    Start-ScheduledTask -TaskName $taskName
    Write-Output "Started $taskName."
}

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $proxyExe -PathType Leaf)) {
            throw "Missing packaged executable: $proxyExe"
        }
        if (-not (Test-Path -LiteralPath $remoteSetup -PathType Leaf)) {
            throw "Missing remote-setup.sh: $remoteSetup"
        }
        & ssh.exe -o BatchMode=yes $sshAlias true
        if ($LASTEXITCODE -ne 0) { throw "SSH key login to $sshAlias failed." }
        $password = Initialize-Secret

        $proxyUrl = "http://proxy:$password@127.0.0.1:$remotePort"
        $remoteEnv = @"
export HTTPS_PROXY='$proxyUrl'
export https_proxy=`$HTTPS_PROXY
export HTTP_PROXY=`$HTTPS_PROXY
export http_proxy=`$HTTPS_PROXY
export NO_PROXY=127.0.0.1,localhost
export no_proxy=`$NO_PROXY
"@
        $remoteEnv | & ssh.exe -T -o BatchMode=yes $sshAlias 'umask 077; mkdir -p "$HOME/.config/ssh-gateway-proxy"; cat > "$HOME/.config/ssh-gateway-proxy/proxy.env"; chmod 600 "$HOME/.config/ssh-gateway-proxy/proxy.env"'
        if ($LASTEXITCODE -ne 0) { throw 'Could not install the remote proxy environment.' }
        $remoteSetupBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($remoteSetup))
        & ssh.exe -T -o BatchMode=yes $sshAlias "printf '%s' '$remoteSetupBase64' | base64 -d | bash -s"
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the remote shell.' }

        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Stop-ManagedProcesses
        }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Run' -f $PSCommandPath
        $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
        $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Start' -f $PSCommandPath
        $shortcut.WorkingDirectory = $root
        $shortcut.IconLocation = "$proxyExe,0"
        $shortcut.Description = "Start the SSH gateway proxy for $sshAlias"
        $shortcut.Save()

        Start-InstalledTask
        Write-Output "Desktop shortcut: $shortcutPath"
        break
    }
    'Run' {
        if (-not (Test-Path -LiteralPath $proxyExe -PathType Leaf)) {
            throw "Missing packaged executable: $proxyExe"
        }
        $password = Initialize-Secret
        Stop-ManagedProcesses
        $proxyProcess = $null
        $tunnelProcess = $null
        try {
            while ($true) {
                if ($null -eq $proxyProcess -or $proxyProcess.HasExited) {
                    $proxyProcess = Start-LocalProxy
                }
                if ($null -eq $tunnelProcess -or $tunnelProcess.HasExited) {
                    $tunnelProcess = Start-SshTunnel
                }
                Start-Sleep -Seconds 5
            }
        }
        finally {
            foreach ($child in @($tunnelProcess, $proxyProcess)) {
                if ($null -ne $child -and -not $child.HasExited) {
                    Stop-Process -Id $child.Id -ErrorAction SilentlyContinue
                }
            }
        }
        break
    }
    'Start' {
        Start-InstalledTask
        break
    }
    'Stop' {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Stop-ManagedProcesses
        Write-Output "Stopped $taskName."
        break
    }
    'Status' {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { Write-Output "Task: $taskName ($($task.State))" }
        else { Write-Output "Task: $taskName (not installed)" }
        $listener = Get-NetTCPConnection -LocalPort $localPort -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -First 1
        if ($listener) { Write-Output "Local proxy: 127.0.0.1:$localPort (listening)" }
        else { Write-Output "Local proxy: 127.0.0.1:$localPort (not listening)" }
        break
    }
}
