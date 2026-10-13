# Koi Diagnostics Script

**Script:** `KoiDiagnostics_Simple.ps1` · **Version:** 1.1 · **Author:** Linkan Dash

> [!IMPORTANT]
> **Read-only, for troubleshooting only.** This script was built to help troubleshoot Koi agent connectivity and service health. It does **not** change anything in the server configuration. It does not create, modify, restart or delete registry keys, services, firewall rules, proxy settings, certificates, TLS settings or Koi files. The only thing it writes is its own report file.

## Contents

- [Files in this repository](#files-in-this-repository)
- [What the Script Captures](#what-the-script-captures)
- [How to Run](#how-to-run)
- [Viewing the Report](#viewing-the-report)
- [Output Example](#output-example)
- [Reading the Results](#reading-the-results)
- [Troubleshooting Guide](#troubleshooting-guide)
- [Common Error Messages in Koi Logs](#common-error-messages-in-koi-logs)
- [Sharing the Report](#sharing-the-report)
- [FAQ](#faq)

## Files in this repository

| File | Purpose |
|---|---|
| `KoiDiagnostics_Simple.ps1` | The diagnostic script. Run it on each endpoint. |
| `KoiReportAnalyser.html` | Offline report viewer. Open it in a browser and load a report. |
| `KOI_ARCHITECTURE.md` | Notes on how the Koi agent works, including open questions still marked `[?]`. |
| `README.md` | This file. |

## What the Script Captures

### System
- OS version, build, architecture, domain, last boot time and uptime
- PowerShell version
- Network adapter configuration and IPv4 DNS servers
- Windows Firewall profiles (enabled state and default outbound action)

### Network Connectivity
- DNS resolution of `api.prod.koi.security`, including any CNAME chain
- TCP 443 to the Koi API over the direct path (5-second timeout)
- HTTPS/TLS 1.2 request to the Koi API, direct and through the proxy, using `curl.exe`
- Proxy DNS resolution and TCP reachability, tested before the HTTPS-through-proxy check
- Automatic hints for proxy authentication (407), proxy denial (403), TLS handshake failure, untrusted certificate and certificate revocation-check failure
- If revocation checking fails, a confirmation retest with revocation checking disabled. This affects that single request only.

### TLS Certificate Inspection
- The certificate presented for the Koi API, retrieved both direct and through the proxy. This is a handshake only; no data is sent.
- Issuer, validity dates, thumbprint, negotiated protocol and cipher, and chain trust
- **TLS inspection detection:** a WARN if the proxy re-signs Koi traffic with a different issuer

### Time Synchronisation
- Local and UTC time, plus Windows Time service status (`w32tm /query /status`)
- Clock skew against the Koi API's `Date` header. Anything over ±5 minutes is a FAIL.

### Proxy Configuration
- WinHTTP proxy, the machine-wide setting used by many services
- WinINet proxy settings for three contexts:
  - the current user
  - **LocalSystem**, the context the Koi service normally runs in
  - machine policy
- Proxy-related environment variables at process and machine scope
- Any credentials embedded in proxy URLs are masked in the report.

### TLS / Schannel Configuration
- .NET Framework `SchUseStrongCrypto` and `SystemDefaultTlsVersions`, for both 64-bit and 32-bit (WOW6432Node) keys
- Schannel client settings for TLS 1.0, 1.1, 1.2 and 1.3
- Enabled cipher suites in priority order (Windows 10 / Server 2016 and later)
- Schannel events from the System log (last 7 days, maximum 20)

### Koi Agent Status
- Koi services: state, start mode, service account, process ID, binary path, and any service-specific environment variables
- Service Control Manager crash and start-failure events that mention Koi (last 7 days)
- Koi processes: path, start time, memory and CPU time
- Binary signature and file version. The binary path is taken from the service definition.
- The last 50 lines of `C:\ProgramData\Koi\KoiService\KoiService.log`
- Error and warning lines from `.log` and `.jsonl` files under `C:\ProgramData\Koi` modified in the last 7 days. The last 10 matching lines are shown per file, and files over 50 MB are skipped.
- `*.json` files are deliberately **not** searched, because they may be config files containing secrets.

### Summary
- A PASS / WARN / FAIL / INFO table at the end of the report, with totals

---

## How to Run

### Prerequisites

| Requirement | Detail |
|---|---|
| OS | Windows 10 / Windows Server 2016 or later recommended. Older versions (for example Server 2012 R2) lack `curl.exe` and `Get-TlsCipherSuite`, so the HTTPS and cipher-suite checks are skipped. |
| PowerShell | Windows PowerShell 5.1 or later |
| Privileges | **Administrator (required)** |
| curl.exe | Built into Windows 10 1803+ and Server 2019+ |

### Steps

1. **Open PowerShell as Administrator.** Right-click PowerShell and choose **Run as Administrator**.

2. **Go to the script folder.**
   ```powershell
   cd "C:\path\to\script"
   ```

3. **Run the script.**
   ```powershell
   .\KoiDiagnostics_Simple.ps1
   ```
   If script execution is blocked by policy, run it for this one invocation only. This does not change the machine's execution policy.
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\KoiDiagnostics_Simple.ps1
   ```

4. **Choose a diagnostic mode when prompted.** Press Enter for the default.
   - `N` – Network only
   - `A` – Agent only
   - `C` – Comprehensive (Network + Agent) — **default**

5. **Wait for it to finish.** It typically takes 1–2 minutes, and longer if the direct internet path is blocked, because each blocked test waits for its timeout.

6. **Find the report.**
   - File name: `KoiDiagnostics_<ComputerName>_<yyyyMMdd-HHmmss>.txt`
   - Saved in the script's folder. If that folder isn't writable, it falls back to `%TEMP%`.
   - The full path is printed at the end of the run.

### Parameters (Optional)

| Parameter | Default | Purpose |
|---|---|---|
| `-Mode` | *(menu)* | `Network`, `Agent` or `Comprehensive`. Skips the menu. |
| `-KoiApiHost` | `api.prod.koi.security` | Koi API host to test |
| `-ProxyHost` | `bcproxy` | Proxy host. Use `''` to skip proxy tests. |
| `-ProxyPort` | `8080` | Proxy port |
| `-KoiRoot` | `C:\ProgramData\Koi` | Koi data and log folder |
| `-OutputDirectory` | Script folder | Where to save the report |
| `-LogLookbackDays` | `7` | How far back to search logs and event logs |
| `-MaxLogFileMB` | `50` | Skip log files larger than this |

Examples:
```powershell
# Non-interactive, full run
.\KoiDiagnostics_Simple.ps1 -Mode Comprehensive

# Different proxy
.\KoiDiagnostics_Simple.ps1 -ProxyHost proxy.corp.local -ProxyPort 3128

# No proxy in this environment
.\KoiDiagnostics_Simple.ps1 -ProxyHost ''
```

> [!NOTE]
> The checks run as the user who launches the script, but the Koi service normally runs as **LocalSystem**. Proxy and certificate-trust behaviour can differ between the two. That is why the report shows the LocalSystem proxy settings separately.

---

## Viewing the Report

Open `KoiReportAnalyser.html` in any modern browser (Edge, Chrome or Firefox). It works offline.

1. Drop the `KoiDiagnostics_<ComputerName>_<timestamp>.txt` file onto the page, or choose it with **Choose report file**. You can also paste the text with **Paste text**.
2. Read the verdict and the health strip, then work through **Not working** and **Worth reviewing**. Each card explains the finding, gives the next step and, where relevant, a read-only command.
3. Use **Export findings** to:
   - **Copy summary for a ticket**
   - **Download** the findings as Markdown (`.md`), CSV (`.csv`) or JSON (`.json`)
   - **Download PDF**, which opens the print dialog. Choose *Save as PDF*.
4. Use **Reset** to clear the report and start again.

The report is read in the browser only. It is not uploaded or stored anywhere. The page loads its fonts from Google Fonts, which is the only external request.

## Output Example

Report excerpt (values are illustrative):
```
Koi Diagnostics Script v1.1
Author   : Linkan Dash
Purpose  : Troubleshooting only. READ-ONLY - no server configuration is changed.
Computer : WORKSTATION-001
Mode     : Comprehensive
Proxy    : bcproxy:8080

======================================================================
NETWORK CONNECTIVITY TESTS
======================================================================
Koi API DNS                            WARN   No such host is known (may be expected if all egress goes via the proxy)
Koi API TCP 443 (direct)               WARN   Timed out after 5s (may be expected if all egress goes via the proxy)
Proxy DNS                              PASS   Resolved to: 10.10.1.20
Proxy TCP                              PASS   Connected to 10.10.1.20:8080
Koi API HTTPS (via proxy)              PASS   TLS OK, HTTP 404 (any HTTP status means the API was reached)
...
======================================================================
SUMMARY
======================================================================
Result: 0 FAIL, 3 WARN, 14 PASS, 1 INFO
```

When a proxy is configured, failures on the **direct** path are reported as **WARN**, not FAIL, because blocked direct egress is normal in proxied networks. Any HTTP status code from the Koi API, including 404, means the API was reached and TLS succeeded.

---

## Reading the Results

| Status | Meaning |
|---|---|
| **PASS** | Check succeeded |
| **FAIL** | Check failed; likely contributes to the problem |
| **WARN** | Needs review. Often expected, such as a blocked direct path or Koi log lines matching error keywords. |
| **INFO** | Informational only |

Start with the **SUMMARY** section at the end of the report, then scroll up to the matching section for details.

---

## Troubleshooting Guide

> The script itself changes nothing. The commands below are **manual follow-up steps**. Read-only checks are marked; anything that changes the system should be done by an administrator, following your change process.

### DNS Resolution Fails
**Report:** `Koi API DNS  FAIL` (or `WARN` when a proxy is configured)

**Likely causes:** the internal DNS doesn't forward external names, the DNS server is unreachable, or all egress goes via the proxy. The last case is normal, and the proxy resolves the name.

**Check (read-only):**
```powershell
Resolve-DnsName api.prod.koi.security
Get-DnsClientServerAddress -AddressFamily IPv4
```
**Next step:** If a proxy is used and `Koi API HTTPS (via proxy)` passes, a direct DNS failure can be ignored. Otherwise, raise it with the DNS/network team.

---

### Direct TCP 443 Fails
**Report:** `Koi API TCP 443 (direct)  FAIL / WARN`

**Likely causes:** the perimeter firewall blocks direct egress (normal when a proxy is mandatory), or the host has no route to the internet.

**Check (read-only):**
```powershell
Test-NetConnection api.prod.koi.security -Port 443
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultOutboundAction
```
**Next step:** If the proxy path passes, no action is needed. If direct egress is meant to be allowed, ask the network team for a rule.

---

### Proxy DNS or TCP Fails
**Report:** `Proxy DNS  FAIL` or `Proxy TCP  FAIL`

**Likely causes:** wrong proxy name or port, the proxy is down, or a host firewall or network ACL is blocking it.

**Check (read-only):**
```powershell
netsh winhttp show proxy
Test-NetConnection bcproxy -Port 8080
```
**Next step:** Confirm the correct proxy host and port with IT, then re-run with `-ProxyHost` / `-ProxyPort`.

---

### HTTPS Through the Proxy Fails
**Report:** `Koi API HTTPS (via proxy)  FAIL – <hint>`

| Hint in report | Meaning | Next step |
|---|---|---|
| `Proxy requires authentication (HTTP 407)` | Proxy needs credentials. The Koi service, as LocalSystem, may not be able to supply them. | Ask the proxy team to exempt `api.prod.koi.security` from authentication |
| `Proxy denied the CONNECT (HTTP 403)` | Destination not on the proxy allow-list | Ask the proxy team to allow `api.prod.koi.security:443` |
| `TLS/SSL handshake failed` | TLS 1.2 disabled, cipher mismatch, or interference from inspection | Check the TLS section and the `TLS inspection by proxy` result |
| `Server certificate not trusted` | Certificate chain not trusted, often because of TLS inspection | See *TLS Inspection Detected* below |
| `Certificate revocation check failed` | CRL/OCSP endpoints not reachable through the proxy | Allow the CA's CRL/OCSP URLs through the proxy |
| `Operation timed out` / `Failed to connect` | Proxy not responding or path blocked | See *Proxy DNS or TCP Fails* |

**Manual test (read-only).** Use `curl.exe`, not `curl`. In Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`.
```powershell
curl.exe -v -x http://bcproxy:8080 https://api.prod.koi.security/api
```

---

### TLS Inspection Detected
**Report:** `TLS inspection by proxy  WARN`, or `Certificate trust (via proxy)  FAIL` with a corporate CA as issuer

**Meaning:** The proxy is decrypting and re-signing Koi traffic with its own CA. Agents frequently fail in this situation.

**Next step (preferred):** Ask the proxy/security team to **exclude `api.prod.koi.security` from SSL inspection**. If that isn't possible, confirm with Koi support whether the agent supports trusting the corporate CA.

---

### Clock Skew
**Report:** `Clock skew vs Koi API  FAIL`

**Meaning:** The system clock is more than 5 minutes out, which can break TLS and token validation.

**Check (read-only):**
```powershell
w32tm /query /status
w32tm /query /source
```
**Next step:** An administrator should fix the time source, for example the domain hierarchy or an NTP server.

---

### TLS 1.2 Disabled
**Report:** `TLS 1.2 client  FAIL`

**Meaning:** The Schannel registry explicitly disables the TLS 1.2 client. If the key is absent, the result is `Not configured (OS default)`. That is normal and means TLS 1.2 is enabled on all supported Windows versions.

**Check (read-only):**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" |
  Select-Object SchUseStrongCrypto, SystemDefaultTlsVersions
```
**Next step:** Re-enabling TLS 1.2 is a configuration change. Raise it with the server owner or through your hardening process.

---

### Koi Service Not Found or Not Running
**Report:** `Koi service installed  FAIL` or `Service <name>  FAIL`

**Check (read-only):**
```powershell
Get-Service | Where-Object { $_.Name -like '*Koi*' -or $_.DisplayName -like '*Koi*' }
Test-Path 'C:\ProgramData\Koi'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 200 |
  Where-Object { $_.Message -like '*Koi*' }
```
**Next step:** If it isn't installed, reinstall the agent. If it's installed but stopped, review the `Koi service crash/start errors` section before restarting. A restart is a change, so the service owner should approve it:
```powershell
Restart-Service -Name <KoiServiceName>   # changes system state - approval required
```

---

### Service Running but Agent Not Working
**Report:** `Service <name>  PASS`, with `Koi log errors  WARN`

**Check (read-only):** Review the *Recent service log* and *log search* sections of the report, and match them against the table below.

**Next step:** Share the report with Koi support. **Do not delete Koi log files.** They are the main evidence for support.

---

### Binary Signature Not Valid
**Report:** `Signature <file>.exe  FAIL`

**Meaning:** The Koi binary is unsigned, tampered with, or its signature can't be validated, for example because the root certificate isn't present.

**Next step:** Treat this as a potential security issue. Verify the file hash with Koi and reinstall from a trusted source.

---

## Common Error Messages in Koi Logs

| Log message | Meaning | Action |
|---|---|---|
| `Connection refused` | Destination or proxy rejected the connection | Check proxy/TCP results |
| `Timeout` / `timed out` | No response in time | Check proxy path and firewall |
| `SSL` / `certificate` errors | TLS validation failed | Check certificate trust and TLS inspection results |
| `407` / `Proxy Authentication Required` | Proxy needs credentials | Request an auth exemption for the Koi API host |
| `401 Unauthorized` | Agent credentials or token rejected | Check agent registration / tenant with Koi support |
| `403 Forbidden` | Access denied by proxy or API | Check proxy allow-list, then Koi tenant |
| `Could not resolve host` | DNS failure | Check DNS, or confirm proxy use |
| `Access denied` / `Permission denied` | Agent can't read or write a local path | Check folder permissions with Koi support |

---

## Sharing the Report

⚠️ The report may contain:
- Hostnames, IP addresses and DNS servers
- User and service account names, and the domain name
- Proxy hostnames (embedded credentials are masked automatically)
- TLS certificate details
- Koi log lines, which may include internal identifiers

**Before sharing:**
1. Review the report.
2. Redact anything your policy requires.
3. Share it only with authorised support contacts.

---

## Support Information

When contacting support, provide:
1. The full diagnostic report
2. The FAIL / WARN lines from the SUMMARY section
3. When the issue started, and any recent network, proxy or firewall changes

---

## Script Details

| Detail | Value |
|---|---|
| **Name** | `KoiDiagnostics_Simple.ps1` |
| **Version** | 1.1 |
| **Author** | Linkan Dash |
| **Language** | Windows PowerShell 5.1+ |
| **OS** | Windows 10 / Server 2016+ (Server 2012 R2 with reduced checks) |
| **Requirements** | Administrator, curl.exe |
| **Runtime** | Typically 1–2 minutes |
| **Output** | Text transcript: `KoiDiagnostics_<ComputerName>_<Timestamp>.txt` |
| **Safety** | Read-only. Makes no changes to server configuration. |

**Last updated:** 2026-10-09
