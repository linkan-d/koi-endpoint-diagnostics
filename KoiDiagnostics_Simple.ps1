<#
.SYNOPSIS
    Koi Diagnostics Script - troubleshoot Koi agent connectivity and service health.

.DESCRIPTION
    Collects system, network, proxy, TLS/certificate, time-sync and Koi service
    health information and writes it to a single diagnostic report (.txt).

    *** READ-ONLY / TROUBLESHOOTING ONLY ***
    This script is built purely for troubleshooting purposes. It does NOT change
    anything in the server configuration: no registry keys, services, firewall
    rules, proxy settings, certificates, TLS settings or Koi files are created,
    modified, restarted or deleted. The only file it writes is the diagnostic
    report itself.

    Note: checks run as the user who launches the script, not as the Koi service
    account (normally LocalSystem). Proxy and certificate-trust behaviour can
    differ between the two, so LocalSystem proxy settings are reported separately.

.PARAMETER Mode
    Network, Agent or Comprehensive. If omitted, an interactive menu is shown;
    in non-interactive sessions Comprehensive is used.
.PARAMETER KoiApiHost
    Koi API hostname to test. Default: api.prod.koi.security
.PARAMETER ProxyHost
    Corporate proxy hostname. Pass an empty string ('') to skip proxy tests.
.PARAMETER ProxyPort
    Corporate proxy port. Default: 8080
.PARAMETER KoiRoot
    Koi installation/data folder. Default: C:\ProgramData\Koi
.PARAMETER OutputDirectory
    Folder for the report. Default: the script's folder (falls back to %TEMP%).
.PARAMETER LogLookbackDays
    Only scan Koi logs and event logs written within this many days. Default: 7
.PARAMETER MaxLogFileMB
    Skip Koi log files larger than this when searching for errors. Default: 50

.EXAMPLE
    .\KoiDiagnostics_Simple.ps1
.EXAMPLE
    .\KoiDiagnostics_Simple.ps1 -Mode Comprehensive -ProxyHost bcproxy -ProxyPort 8080
.EXAMPLE
    .\KoiDiagnostics_Simple.ps1 -Mode Network -ProxyHost ''

.NOTES
    Author   : Linkan Dash
    Version  : 1.1
    Purpose  : Built for troubleshooting purposes only. Read-only - it does not
               change anything in the server configuration.
    Requires : Windows PowerShell 5.1 or later, run as Administrator.
               curl.exe (built into Windows 10 1803+ / Server 2019+) for HTTPS tests.
#>

[CmdletBinding()]
param(
    [ValidateSet('Network', 'Agent', 'Comprehensive')]
    [string]$Mode,
    [string]$KoiApiHost = 'api.prod.koi.security',
    [string]$ProxyHost = 'bcproxy',
    [int]$ProxyPort = 8080,
    [string]$KoiRoot = 'C:\ProgramData\Koi',
    [string]$OutputDirectory,
    [int]$LogLookbackDays = 7,
    [int]$MaxLogFileMB = 50
)

$ScriptVersion = '1.1'
$ScriptAuthor  = 'Linkan Dash'

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: This script requires administrator privileges.'
    Write-Host 'Please run PowerShell as Administrator and try again.'
    exit 1
}

# When a proxy is in use, direct-path failures are often expected, so they are
# reported as WARN rather than FAIL.
$script:DirectFailStatus = if ($ProxyHost) { 'WARN' } else { 'FAIL' }
$script:DirectNote       = if ($ProxyHost) { ' (may be expected if all egress goes via the proxy)' } else { '' }
$script:Results          = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-Section {
    param([string]$Title)
    Write-Output ''
    Write-Output ('=' * 70)
    Write-Output $Title
    Write-Output ('=' * 70)
}

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [string]$Details = ''
    )
    $script:Results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Details = $Details })
    Write-Output ('{0,-38} {1,-6} {2}' -f $Name, $Status, $Details)
}

# Renders formatted objects as text so they appear in order in the transcript.
function Out-Block {
    param([Parameter(ValueFromPipeline = $true)] $InputObject)
    begin   { $items = New-Object System.Collections.Generic.List[object] }
    process { if ($null -ne $InputObject) { $items.Add($InputObject) } }
    end     { if ($items.Count -gt 0) { Write-Output (($items | Out-String -Width 250).TrimEnd()) } }
}

function Get-ErrorText {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

# Masks credentials embedded in proxy URLs (http://user:pass@host -> http://***@host).
function Hide-Credential {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ($Text -replace '(?<=://)[^/@\s]+@', '***@')
}

# Fast TCP test with timeout (Test-NetConnection falls back to a slow ICMP ping on failure).
function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [pscustomobject]@{ Success = $false; Remote = $null; Error = "Timed out after $($TimeoutMs / 1000)s" }
        }
        $client.EndConnect($iar)
        return [pscustomobject]@{ Success = $true; Remote = $client.Client.RemoteEndPoint.ToString(); Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Remote = $null; Error = (Get-ErrorText $_) }
    } finally {
        $client.Close()
    }
}

$script:CurlExitHints = @{
    5  = 'Could not resolve proxy'
    6  = 'Could not resolve host'
    7  = 'Failed to connect'
    28 = 'Operation timed out'
    35 = 'TLS/SSL handshake failed'
    56 = 'Failure receiving data (often a proxy reset or refused CONNECT)'
    60 = 'Server certificate not trusted'
    77 = 'Problem reading the CA certificate store'
}

function Invoke-CurlTest {
    param([string]$Name, [string[]]$ExtraArgs = @(), [string]$FailStatus = 'FAIL')

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Check $Name 'WARN' 'curl.exe not found - HTTPS test skipped'
        return
    }

    $curlArgs = @('-sS', '--tlsv1.2', '--connect-timeout', '10', '--max-time', '20', '-o', 'NUL',
                  '-w', 'HTTP_STATUS=%{http_code} PROXY_CONNECT=%{http_connect} REMOTE_IP=%{remote_ip} TCP=%{time_connect}s TLS=%{time_appconnect}s') +
                $ExtraArgs + @("https://$KoiApiHost/api")

    # try/catch does not catch native command failures, so use $LASTEXITCODE.
    $output = (& curl.exe @curlArgs 2>&1 | ForEach-Object { "$_" }) -join ' '
    $exit = $LASTEXITCODE
    Write-Output "  curl: $output"

    $httpCode = if ($output -match 'HTTP_STATUS=(\d{3})') { $Matches[1] } else { '000' }

    if ($exit -eq 0 -and $httpCode -ne '000') {
        Write-Check $Name 'PASS' "TLS OK, HTTP $httpCode (any HTTP status means the API was reached)"
        return
    }

    $hint = $script:CurlExitHints[[int]$exit]
    if ($output -match 'PROXY_CONNECT=407') { $hint = 'Proxy requires authentication (HTTP 407)' }
    elseif ($output -match 'PROXY_CONNECT=403') { $hint = 'Proxy denied the CONNECT (HTTP 403) - check proxy allow-list' }
    $revocation = $output -match 'revocation|CRYPT_E_NO_REVOCATION_CHECK|CRYPT_E_REVOCATION_OFFLINE'
    if ($revocation) { $hint = 'Certificate revocation check failed (CRL/OCSP endpoints not reachable)' }

    Write-Check $Name $FailStatus ("curl exit $exit" + $(if ($hint) { " - $hint" } else { '' }))

    # Confirm a revocation problem by repeating the request without the revocation check (read-only).
    if ($revocation -and ($ExtraArgs -notcontains '--ssl-no-revoke')) {
        Invoke-CurlTest -Name "$Name [no revocation check]" -ExtraArgs ($ExtraArgs + '--ssl-no-revoke') -FailStatus $FailStatus
    }
}

# Performs a TLS handshake only (no application data sent) and returns certificate details.
function Get-RemoteCertificate {
    param([string]$TargetHost, [int]$Port = 443, [string]$ViaProxyHost, [int]$ViaProxyPort)

    $client = $null; $ssl = $null
    try {
        $connectHost = if ($ViaProxyHost) { $ViaProxyHost } else { $TargetHost }
        $connectPort = if ($ViaProxyHost) { $ViaProxyPort } else { $Port }

        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($connectHost, $connectPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(10000)) { throw "TCP connect to ${connectHost}:${connectPort} timed out" }
        $client.EndConnect($iar)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $stream.WriteTimeout = 10000

        if ($ViaProxyHost) {
            $request = "CONNECT ${TargetHost}:${Port} HTTP/1.1`r`nHost: ${TargetHost}:${Port}`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($request)
            $stream.Write($bytes, 0, $bytes.Length)

            $sb = New-Object Text.StringBuilder
            $buf = New-Object byte[] 1
            while (-not $sb.ToString().EndsWith("`r`n`r`n") -and $sb.Length -lt 8192) {
                if ($stream.Read($buf, 0, 1) -le 0) { break }
                [void]$sb.Append([char]$buf[0])
            }
            $statusLine = ($sb.ToString() -split "`r`n")[0]
            if ($statusLine -notmatch '^HTTP/\d(\.\d)? 200') { throw "Proxy CONNECT refused: $statusLine" }
        }

        # Accept any certificate so it can be inspected; trust is evaluated separately below.
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
        $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
        $ssl.AuthenticateAsClient($TargetHost,
            (New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection),
            [System.Security.Authentication.SslProtocols]::Tls12, $false)

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'   # revocation is covered by the curl tests
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(10)
        $trusted = $chain.Build($cert)

        [pscustomobject]@{
            Subject      = $cert.Subject
            Issuer       = $cert.Issuer
            ValidFrom    = $cert.NotBefore
            ValidTo      = $cert.NotAfter
            Thumbprint   = $cert.Thumbprint
            Protocol     = $ssl.SslProtocol
            Cipher       = "$($ssl.CipherAlgorithm) $($ssl.CipherStrength)-bit"
            ChainTrusted = $trusted
            ChainStatus  = if ($trusted) { 'OK' } else { (@($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', ') }
            ChainPath    = (@($chain.ChainElements | ForEach-Object { $_.Certificate.GetNameInfo('SimpleName', $false) }) -join ' -> ')
        }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($client) { $client.Close() }
    }
}

# ---------------------------------------------------------------------------
# Diagnostic sections
# ---------------------------------------------------------------------------
function Test-System {
    Write-Section 'SYSTEM INFORMATION'

    Write-Output ''
    Write-Output 'Operating System:'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Caption        = $os.Caption
            Version        = $os.Version
            BuildNumber    = $os.BuildNumber
            Architecture   = $os.OSArchitecture
            Domain         = $cs.Domain
            LastBootUpTime = $os.LastBootUpTime
            Uptime         = '{0:dd}d {0:hh}h {0:mm}m' -f ((Get-Date) - $os.LastBootUpTime)
        } | Format-List | Out-Block
    } catch {
        Write-Output "Could not read OS information: $(Get-ErrorText $_)"
    }

    Write-Output ''
    Write-Output "PowerShell Version: $($PSVersionTable.PSVersion)"

    Write-Output ''
    Write-Output 'Network Configuration:'
    try { Get-NetIPConfiguration -ErrorAction Stop | Format-List | Out-Block }
    catch { Write-Output 'Could not read network configuration' }

    Write-Output ''
    Write-Output 'DNS Servers:'
    try {
        Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses } |
            Format-Table InterfaceAlias, ServerAddresses -AutoSize | Out-Block
    } catch { Write-Output 'Could not read DNS servers' }

    Write-Output ''
    Write-Output 'Firewall Profiles:'
    try {
        Get-NetFirewallProfile -ErrorAction Stop |
            Format-Table Name, Enabled, DefaultOutboundAction -AutoSize | Out-Block
    } catch { Write-Output 'Could not read firewall status' }
}

function Test-Network {
    Write-Section 'NETWORK CONNECTIVITY TESTS'

    # --- Direct path ---
    Write-Output ''
    Write-Output 'DNS resolution:'
    try {
        $dns   = Resolve-DnsName -Name $KoiApiHost -ErrorAction Stop
        $ips   = @($dns | Where-Object { $_.Type -in 'A', 'AAAA' } | ForEach-Object { $_.IPAddress })
        $cname = @($dns | Where-Object { $_.Type -eq 'CNAME' } | ForEach-Object { $_.NameHost })
        if ($ips.Count -gt 0) {
            $detail = "Resolved to: $($ips -join ', ')"
            if ($cname.Count -gt 0) { $detail += " (via $($cname -join ' -> '))" }
            Write-Check 'Koi API DNS' 'PASS' $detail
        } else {
            Write-Check 'Koi API DNS' $script:DirectFailStatus "No A/AAAA records returned$($script:DirectNote)"
        }
    } catch {
        Write-Check 'Koi API DNS' $script:DirectFailStatus "$(Get-ErrorText $_)$($script:DirectNote)"
    }

    Write-Output ''
    Write-Output 'TCP connectivity (direct):'
    $tcp = Test-TcpPort -TargetHost $KoiApiHost -Port 443
    if ($tcp.Success) { Write-Check 'Koi API TCP 443 (direct)' 'PASS' "Connected to $($tcp.Remote)" }
    else { Write-Check 'Koi API TCP 443 (direct)' $script:DirectFailStatus "$($tcp.Error)$($script:DirectNote)" }

    Write-Output ''
    Write-Output 'HTTPS/TLS (direct):'
    Invoke-CurlTest -Name 'Koi API HTTPS (direct)' -ExtraArgs @('--noproxy', '*') -FailStatus $script:DirectFailStatus

    # --- Proxy path (proxy checked first, then HTTPS through it) ---
    Write-Output ''
    if (-not $ProxyHost) {
        Write-Output 'Proxy tests skipped (no -ProxyHost specified).'
        return
    }

    Write-Output "Proxy ${ProxyHost}:${ProxyPort}:"
    try {
        $proxyIps = [System.Net.Dns]::GetHostAddresses($ProxyHost) | ForEach-Object { $_.IPAddressToString }
        Write-Check 'Proxy DNS' 'PASS' "Resolved to: $($proxyIps -join ', ')"
    } catch {
        Write-Check 'Proxy DNS' 'FAIL' (Get-ErrorText $_)
    }

    $ptcp = Test-TcpPort -TargetHost $ProxyHost -Port $ProxyPort
    if ($ptcp.Success) { Write-Check 'Proxy TCP' 'PASS' "Connected to $($ptcp.Remote)" }
    else { Write-Check 'Proxy TCP' 'FAIL' $ptcp.Error }

    Write-Output ''
    Write-Output 'HTTPS/TLS (via proxy):'
    Invoke-CurlTest -Name 'Koi API HTTPS (via proxy)' -ExtraArgs @('-x', "http://${ProxyHost}:${ProxyPort}")
}

function Test-Certificate {
    Write-Section 'TLS CERTIFICATE INSPECTION'
    Write-Output 'Retrieves the certificate presented for the Koi API (TLS handshake only - no data is sent).'

    $direct = $null; $viaProxy = $null

    Write-Output ''
    Write-Output 'Direct:'
    try {
        $direct = Get-RemoteCertificate -TargetHost $KoiApiHost
        $direct | Format-List | Out-Block
    } catch {
        Write-Check 'Certificate (direct)' $script:DirectFailStatus "$(Get-ErrorText $_)$($script:DirectNote)"
    }

    if ($ProxyHost) {
        Write-Output ''
        Write-Output "Via proxy ${ProxyHost}:${ProxyPort}:"
        try {
            $viaProxy = Get-RemoteCertificate -TargetHost $KoiApiHost -ViaProxyHost $ProxyHost -ViaProxyPort $ProxyPort
            $viaProxy | Format-List | Out-Block
        } catch {
            Write-Check 'Certificate (via proxy)' 'FAIL' (Get-ErrorText $_)
        }
    }

    Write-Output ''
    foreach ($item in @(@{ Label = 'direct'; Cert = $direct }, @{ Label = 'via proxy'; Cert = $viaProxy })) {
        $c = $item.Cert
        if (-not $c) { continue }
        if ($c.ValidTo -lt (Get-Date)) {
            Write-Check "Certificate expiry ($($item.Label))" 'FAIL' "Expired on $($c.ValidTo)"
        }
        if ($c.ChainTrusted) {
            Write-Check "Certificate trust ($($item.Label))" 'PASS' "Issuer: $($c.Issuer)"
        } else {
            Write-Check "Certificate trust ($($item.Label))" 'FAIL' "Not trusted ($($c.ChainStatus)) - Issuer: $($c.Issuer)"
        }
    }

    if ($direct -and $viaProxy -and $direct.Issuer -ne $viaProxy.Issuer) {
        Write-Check 'TLS inspection by proxy' 'WARN' 'Proxy re-signs the Koi API certificate. Exclude the Koi API host from SSL inspection, or confirm the agent trusts the proxy CA.'
    } elseif ($viaProxy -and -not $direct) {
        Write-Output 'Tip: if the issuer shown via the proxy is an internal/corporate CA rather than a public CA,'
        Write-Output '     the proxy is performing TLS inspection on Koi traffic.'
    }
}

function Test-TimeSync {
    Write-Section 'TIME SYNCHRONISATION'
    Write-Output 'TLS handshakes fail if the system clock is significantly wrong.'
    Write-Output ''
    Write-Output "Local time : $(Get-Date -Format 'o')"
    Write-Output "UTC time   : $((Get-Date).ToUniversalTime().ToString('o'))"

    Write-Output ''
    Write-Output 'Windows Time service status (w32tm /query /status):'
    & w32tm.exe /query /status 2>&1 | ForEach-Object { "  $_" }

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return }

    $attempts = @(@{ Label = 'direct'; Args = @('--noproxy', '*') })
    if ($ProxyHost) { $attempts += @{ Label = 'via proxy'; Args = @('-x', "http://${ProxyHost}:${ProxyPort}") } }

    foreach ($a in $attempts) {
        $routeArgs = $a.Args
        $headers = & curl.exe -sSI --connect-timeout 10 --max-time 20 @routeArgs "https://$KoiApiHost/" 2>$null
        $dateLine = $headers | Where-Object { $_ -match '^Date:\s*(.+)$' } | Select-Object -First 1
        if ($dateLine -and $dateLine -match '^Date:\s*(.+)$') {
            try {
                $serverUtc = [DateTime]::Parse($Matches[1].Trim(), [Globalization.CultureInfo]::InvariantCulture,
                                               [Globalization.DateTimeStyles]::AdjustToUniversal)
                $skew = [math]::Round(((Get-Date).ToUniversalTime() - $serverUtc).TotalSeconds)
                $status = if ([math]::Abs($skew) -le 300) { 'PASS' } else { 'FAIL' }
                Write-Output ''
                Write-Check 'Clock skew vs Koi API' $status "$skew s ($($a.Label); tolerance +/-300 s)"
                return
            } catch { }
        }
    }
    Write-Output ''
    Write-Check 'Clock skew vs Koi API' 'INFO' 'Could not read the server Date header'
}

function Test-Proxy {
    Write-Section 'PROXY CONFIGURATION'

    Write-Output ''
    Write-Output 'WinHTTP proxy (machine-wide, used by many services):'
    & netsh.exe winhttp show proxy 2>&1 | ForEach-Object { "  $_" }

    $ieKey = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $sources = [ordered]@{
        "Current user ($env:USERNAME)"     = "HKCU:\$ieKey"
        'LocalSystem (Koi service context)' = "Registry::HKEY_USERS\S-1-5-18\$ieKey"
        'Machine policy'                    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings"
    }
    foreach ($label in $sources.Keys) {
        Write-Output ''
        Write-Output "WinINet proxy settings - ${label}:"
        try {
            $p = Get-ItemProperty -Path $sources[$label] -ErrorAction Stop
            [pscustomobject]@{
                ProxyEnable          = $p.ProxyEnable
                ProxyServer          = Hide-Credential $p.ProxyServer
                ProxyOverride        = $p.ProxyOverride
                AutoConfigURL        = $p.AutoConfigURL
                ProxySettingsPerUser = $p.ProxySettingsPerUser
            } | Format-List | Out-Block
        } catch {
            Write-Output '  Not configured / not readable'
        }
    }

    foreach ($scope in 'Process', 'Machine') {
        Write-Output ''
        Write-Output "Proxy-related environment variables ($scope scope):"
        $vars = @([Environment]::GetEnvironmentVariables($scope).GetEnumerator() | Where-Object { $_.Key -match 'PROXY' })
        if ($vars.Count -gt 0) {
            $vars | ForEach-Object { '  {0} = {1}' -f $_.Key, (Hide-Credential "$($_.Value)") }
        } else {
            Write-Output '  None set'
        }
    }
}

function Test-TLS {
    Write-Section 'TLS / SCHANNEL CONFIGURATION'

    Write-Output ''
    Write-Output '.NET Framework strong-crypto settings (blank = not set):'
    $netKeys = @(
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727'
    )
    $netKeys | ForEach-Object {
        $p = Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Key                      = $_ -replace '^HKLM:\\SOFTWARE\\', ''
            SchUseStrongCrypto       = $p.SchUseStrongCrypto
            SystemDefaultTlsVersions = $p.SystemDefaultTlsVersions
        }
    } | Format-Table -AutoSize | Out-Block

    Write-Output ''
    Write-Output 'Schannel client protocol settings:'
    $protoRows = foreach ($proto in 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3') {
        $p = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\Client" -ErrorAction SilentlyContinue
        $effective = if (-not $p) { 'Not configured (OS default)' }
                     elseif ($p.Enabled -eq 0 -or $p.DisabledByDefault -eq 1) { 'Disabled' }
                     else { 'Enabled (explicit)' }
        [pscustomobject]@{ Protocol = $proto; Enabled = $p.Enabled; DisabledByDefault = $p.DisabledByDefault; Effective = $effective }
    }
    $protoRows | Format-Table -AutoSize | Out-Block

    $tls12 = $protoRows | Where-Object { $_.Protocol -eq 'TLS 1.2' }
    if ($tls12.Effective -eq 'Disabled') { Write-Check 'TLS 1.2 client' 'FAIL' 'Disabled in Schannel registry' }
    else { Write-Check 'TLS 1.2 client' 'PASS' $tls12.Effective }

    if (Get-Command Get-TlsCipherSuite -ErrorAction SilentlyContinue) {
        $suites = @(Get-TlsCipherSuite -ErrorAction SilentlyContinue)
        Write-Output ''
        Write-Output "Enabled TLS cipher suites ($($suites.Count), in priority order):"
        $suites | ForEach-Object { "  $($_.Name)" }
    }

    Write-Output ''
    Write-Output "Schannel events (last $LogLookbackDays day(s), max 20):"
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Schannel'; StartTime = (Get-Date).AddDays(-$LogLookbackDays) } -MaxEvents 20 -ErrorAction Stop)
        $ev | Select-Object TimeCreated, Id, LevelDisplayName, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
            Format-Table -AutoSize -Wrap | Out-Block
        Write-Check 'Schannel events' 'INFO' "$($ev.Count) event(s) - review above (inbound-client errors are common noise)"
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { Write-Check 'Schannel events' 'PASS' "None in last $LogLookbackDays day(s)" }
        else { Write-Output "  Unable to read System log: $(Get-ErrorText $_)" }
    }
}

function Test-Agent {
    Write-Section 'KOI SERVICE STATUS'

    # --- Services ---
    Write-Output ''
    Write-Output 'Koi services:'
    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Koi' -or $_.DisplayName -match 'Koi' })

    if ($services.Count -eq 0) {
        Write-Check 'Koi service installed' 'FAIL' 'No service with "Koi" in its name or display name'
    } else {
        $services | Select-Object Name, DisplayName, State, StartMode, StartName, ProcessId, PathName | Format-List | Out-Block
        foreach ($svc in $services) {
            $st = if ($svc.State -eq 'Running') { 'PASS' } else { 'FAIL' }
            Write-Check "Service $($svc.Name)" $st "State=$($svc.State), StartMode=$($svc.StartMode), RunAs=$($svc.StartName)"

            $svcEnv = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)" -Name Environment -ErrorAction SilentlyContinue).Environment
            if ($svcEnv) {
                Write-Output "  Service-specific environment for $($svc.Name):"
                $svcEnv | ForEach-Object { "    $(Hide-Credential $_)" }
            }
        }
    }

    # --- Service crashes / start failures ---
    Write-Output ''
    Write-Output "Service Control Manager errors mentioning Koi (last $LogLookbackDays day(s)):"
    try {
        $scm = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'System'; ProviderName = 'Service Control Manager'
                    Id = 7000, 7001, 7009, 7011, 7022, 7023, 7024, 7031, 7032, 7034
                    StartTime = (Get-Date).AddDays(-$LogLookbackDays) } -ErrorAction Stop |
                 Where-Object { $_.Message -match 'Koi' } | Select-Object -First 25)
        if ($scm.Count -gt 0) {
            $scm | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
                Format-Table -AutoSize -Wrap | Out-Block
            Write-Check 'Koi service crash/start errors' 'WARN' "$($scm.Count) event(s) - review above"
        } else {
            Write-Check 'Koi service crash/start errors' 'PASS' 'None found'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { Write-Check 'Koi service crash/start errors' 'PASS' 'None found' }
        else { Write-Output "  Unable to read System log: $(Get-ErrorText $_)" }
    }

    # --- Processes ---
    Write-Output ''
    Write-Output 'Koi processes:'
    $processes = @(Get-Process -Name '*Koi*' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Write-Check 'Koi processes' 'FAIL' 'No Koi processes running'
    } else {
        foreach ($proc in $processes) {
            $start = try { $proc.StartTime } catch { 'n/a' }
            Write-Output "Process: $($proc.Name) (PID: $($proc.Id))"
            Write-Output "  Path     : $($proc.Path)"
            Write-Output "  Started  : $start"
            Write-Output "  Memory   : $([math]::Round($proc.WorkingSet64 / 1MB, 2)) MB"
            Write-Output "  CPU Time : $($proc.TotalProcessorTime)"
        }
    }

    # --- Binary signature & version (path taken from the service definition) ---
    Write-Output ''
    Write-Output 'Koi binary verification:'
    $binaries = New-Object System.Collections.Generic.List[string]
    foreach ($svc in $services) {
        if ($svc.PathName -match '^\s*"?([^"]+?\.exe)') { $binaries.Add($Matches[1]) }
    }
    if ($binaries.Count -eq 0) { $binaries.Add((Join-Path $KoiRoot 'KoiService\KoiService.exe')) }

    foreach ($bin in $binaries) {
        if (-not (Test-Path -LiteralPath $bin)) {
            Write-Check "Binary $(Split-Path $bin -Leaf)" 'FAIL' "Not found at $bin"
            continue
        }
        try {
            $sig = Get-AuthenticodeSignature -FilePath $bin
            $ver = (Get-Item -LiteralPath $bin).VersionInfo
            Write-Output "  File      : $bin"
            Write-Output "  Version   : $($ver.FileVersion)"
            Write-Output "  Signature : $($sig.Status)"
            Write-Output "  Signer    : $($sig.SignerCertificate.Subject)"
            Write-Output "  Timestamp : $(if ($sig.TimeStamperCertificate) { 'Present' } else { 'None' })"
            $st = if ($sig.Status -eq 'Valid') { 'PASS' } else { 'FAIL' }
            Write-Check "Signature $(Split-Path $bin -Leaf)" $st "$($sig.Status)"
        } catch {
            Write-Output "  Could not verify $bin : $(Get-ErrorText $_)"
        }
    }

    # --- Service log tail ---
    Write-Output ''
    Write-Output 'Recent service log (last 50 lines):'
    $serviceLog = Join-Path $KoiRoot 'KoiService\KoiService.log'
    if (Test-Path -LiteralPath $serviceLog) {
        $f = Get-Item -LiteralPath $serviceLog
        Write-Output "Log file: $($f.FullName) (Size: $([math]::Round($f.Length / 1KB, 2)) KB, Modified: $($f.LastWriteTime))"
        Write-Output ''
        Get-Content -LiteralPath $serviceLog -Tail 50 -ErrorAction SilentlyContinue
    } else {
        Write-Output "Service log not found at $serviceLog"
    }

    # --- Error search across recent logs ---
    Write-Output ''
    Write-Output "Searching Koi logs modified in the last $LogLookbackDays day(s) for errors/warnings..."
    Write-Output '(*.json files are deliberately skipped - they may be config files containing secrets)'

    if (-not (Test-Path -LiteralPath $KoiRoot)) {
        Write-Check 'Koi folder' 'FAIL' "$KoiRoot not found"
        return
    }

    $cutoff = (Get-Date).AddDays(-$LogLookbackDays)
    $logFiles = @(Get-ChildItem -LiteralPath $KoiRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.jsonl' -and $_.LastWriteTime -ge $cutoff })

    $errorPattern = '\b(error|exception|fatal|timeout|timed out|failed|failure|refused|unreachable|tls|ssl|certificate|proxy)\b'
    $totalHits = 0

    foreach ($log in $logFiles) {
        if ($log.Length -gt ($MaxLogFileMB * 1MB)) {
            Write-Output "Skipped (larger than $MaxLogFileMB MB): $($log.FullName)"
            continue
        }
        # $logHits rather than $matches - $Matches is a PowerShell automatic variable.
        $logHits = @(Select-String -LiteralPath $log.FullName -Pattern $errorPattern -ErrorAction SilentlyContinue | Select-Object -Last 10)
        if ($logHits.Count -gt 0) {
            Write-Output ''
            Write-Output "File: $($log.FullName)  (last $($logHits.Count) matching lines)"
            foreach ($h in $logHits) {
                $line = $h.Line.Trim()
                if ($line.Length -gt 400) { $line = $line.Substring(0, 400) + ' ...' }
                Write-Output "  Line $($h.LineNumber): $line"
            }
            $totalHits += $logHits.Count
        }
    }

    if ($totalHits -gt 0) { Write-Check 'Koi log errors' 'WARN' "$totalHits matching line(s) across $($logFiles.Count) recent file(s) - review above" }
    else { Write-Check 'Koi log errors' 'PASS' "No matches in $($logFiles.Count) recent log file(s)" }
}

function Write-Summary {
    Write-Section 'SUMMARY'
    $script:Results | Format-Table Check, Status, Details -AutoSize -Wrap | Out-Block
    $count = { param($s) @($script:Results | Where-Object { $_.Status -eq $s }).Count }
    Write-Output ''
    Write-Output ('Result: {0} FAIL, {1} WARN, {2} PASS, {3} INFO' -f (& $count 'FAIL'), (& $count 'WARN'), (& $count 'PASS'), (& $count 'INFO'))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Choose mode before the transcript starts so the menu is not captured.
if (-not $Mode) {
    $nonInteractive = [Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' }
    if ([Environment]::UserInteractive -and -not $nonInteractive) {
        try {
            $options = [System.Management.Automation.Host.ChoiceDescription[]]@(
                '&Network only', '&Agent only', '&Comprehensive (Network + Agent)')
            $choice = $Host.UI.PromptForChoice('Select Diagnostic Mode', 'Choose which diagnostics to run:', $options, 2)
            $Mode = @('Network', 'Agent', 'Comprehensive')[$choice]
        } catch {
            $Mode = 'Comprehensive'
        }
    } else {
        $Mode = 'Comprehensive'
    }
}

# Report location: script folder by default, falling back to %TEMP% if it is not writable.
$Timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$ComputerName = $env:COMPUTERNAME
if (-not $OutputDirectory) {
    $OutputDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
$OutputFile = Join-Path $OutputDirectory "KoiDiagnostics_${ComputerName}_${Timestamp}.txt"
try {
    Start-Transcript -Path $OutputFile -Force -ErrorAction Stop | Out-Null
} catch {
    $OutputFile = Join-Path $env:TEMP (Split-Path $OutputFile -Leaf)
    Start-Transcript -Path $OutputFile -Force | Out-Null
}

try {
    Write-Output "Koi Diagnostics Script v$ScriptVersion"
    Write-Output "Author   : $ScriptAuthor"
    Write-Output 'Purpose  : Troubleshooting only. READ-ONLY - no server configuration is changed.'
    Write-Output "Started  : $(Get-Date -Format 'o')"
    Write-Output "Computer : $ComputerName"
    Write-Output "User     : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Output "Mode     : $Mode"
    Write-Output "Koi API  : $KoiApiHost"
    Write-Output "Proxy    : $(if ($ProxyHost) { "${ProxyHost}:${ProxyPort}" } else { '(none)' })"

    Test-System

    if ($Mode -in 'Network', 'Comprehensive') {
        Test-Network
        Test-Certificate
        Test-TimeSync
        Test-Proxy
        Test-TLS
    }

    if ($Mode -in 'Agent', 'Comprehensive') {
        Test-Agent
    }

    Write-Summary

    Write-Section 'DIAGNOSTIC COMPLETE'
    Write-Output "Completed: $(Get-Date -Format 'o')"
    Write-Output "Report saved to: $OutputFile"
    Write-Output ''
    Write-Output 'No configuration changes were made by this script.'
    Write-Output 'Review the SUMMARY section for FAIL / WARN items.'
    Write-Output 'If issues are found, refer to the README.md troubleshooting section.'
}
catch {
    Write-Output "UNEXPECTED ERROR: $(Get-ErrorText $_)"
}
finally {
    Stop-Transcript | Out-Null
}

Write-Host ''
Write-Host 'Diagnostic complete!'
Write-Host "Report: $OutputFile"
Write-Host ''
Write-Host 'Before sharing this report, review it for sensitive information'
Write-Host '(hostnames, IP addresses, usernames and log content).'
