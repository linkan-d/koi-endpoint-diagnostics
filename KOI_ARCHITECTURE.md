# Koi Agent Architecture - Detailed Explanation

**Status:** Framework document - awaiting verification on items marked `[?]`  
**Purpose:** Complete reference for Koi agent lifecycle, data flow, and troubleshooting

---

## Table of Contents

1. [High-Level Architecture](#high-level-architecture)
2. [Agent Installation & Initialization](#agent-installation--initialization)
3. [Connection Establishment](#connection-establishment)
4. [Data Flow & Communication](#data-flow--communication)
5. [Reporting Mechanisms](#reporting-mechanisms)
6. [Authentication & Authorization](#authentication--authorization)
7. [Log Files & Activity Tracking](#log-files--activity-tracking)
8. [Troubleshooting Decision Tree](#troubleshooting-decision-tree)
9. [Open Questions for Clarification](#open-questions-for-clarification)

---

## High-Level Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLOUD (Koi)                              │
│                                                                   │
│  ┌──────────────────┐         ┌──────────────────┐               │
│  │  Koi API Server  │         │  Koi UI Server   │               │
│  │  api.prod.koi... │◄────────┤  (Dashboard)     │               │
│  └────────┬─────────┘         └────────┬─────────┘               │
│           │                            │                         │
│    HTTPS  │ TCP 443                    │ HTTPS                   │
│           │                            │ (via API)               │
└───────────┼────────────────────────────┼─────────────────────────┘
            │                            │
            │                            │
┌───────────┼────────────────────────────┼─────────────────────────┐
│           │                            │                         │
│   ENDPOINT (Windows Host)              │                         │
│   ════════════════════════════════════════════════════════════   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │         KoiService (C:\ProgramData\Koi)                │    │
│  │                                                          │    │
│  │  ├── KoiService.exe (main service)                     │    │
│  │  ├── KoiService.log (activity log)                     │    │
│  │  ├── agent_activity.jsonl (JSON log stream)            │    │
│  │  ├── agent_enforcement.log (enforcement actions)       │    │
│  │  ├── mdm.exe (policy enforcement engine)               │    │
│  │  └── config files (policies, settings)                 │    │
│  └─────────────────────────────────────────────────────────┘    │
│           │                                                      │
│           │ Communication via Cortex XDR Agent                  │
│           │                                                      │
│  ┌────────▼──────────────────────────────────────────────────┐  │
│  │       Cortex XDR Agent                                   │  │
│  │  (monitors endpoint, collects telemetry, relay Koi)      │  │
│  └────────┬──────────────────────────────────────────────────┘  │
│           │                                                      │
│           │                                                      │
└───────────┼──────────────────────────────────────────────────────┘
            │
     HTTPS  │ TCP 443
     (XDR   │
      API)  │
            │
    ┌───────▼────────────┐
    │  Cortex XDR Cloud  │
    │  (Management)      │
    └────────────────────┘
```

---

## Agent Installation & Initialization

### 1. Pre-Installation

**Installation Method:** [?] Please confirm:
- Downloaded from Koi portal?
- Deployed via Cortex XDR?
- Deployed via Group Policy (GPO)?
- Manual installation via MSI/EXE?

**Installation Package Contents:**
- KoiService.exe (main Windows service)
- mdm.exe (enforcement engine)
- Configuration file (e.g., config.yaml, settings.json) [?]
- Certificates/authentication material [?]

### 2. Installation Process

```
Step 1: Copy binaries
  └─→ C:\ProgramData\Koi\
      ├── KoiService\KoiService.exe
      ├── KoiService\mdm.exe
      └── config\ (configuration files)

Step 2: Register Windows Service
  └─→ Service name: "KoiService" [?]
      Display name: [?]
      Startup type: Automatic [?]
      Run as: LocalSystem [?]

Step 3: Initialize Configuration
  └─→ Load policies from:
      - Local config file [?]
      - Koi Cloud (first-time registration) [?]
      - Cortex XDR Agent [?]

Step 4: Start Service
  └─→ KoiService.exe starts
      ├── Initializes logging
      ├── Loads configuration
      └── Establishes cloud connection
```

### 3. First-Time Registration

When KoiService starts for the first time:

1. **Generates or retrieves identifier**
   - Machine GUID [?]
   - Device ID [?]
   - Authentication token [?]

2. **Contacts Koi Cloud**
   - Endpoint: `api.prod.koi.security` [?]
   - Path: `/api/devices/register` [?]
   - Method: POST [?]
   - Authentication: [?]

3. **Receives policies**
   - Default enforcement policies
   - Configuration parameters
   - Scheduling intervals

4. **Starts service loops**
   - Policy fetching loop (every X minutes) [?]
   - Activity reporting loop (every X minutes) [?]
   - Health check loop (every X minutes) [?]

---

## Connection Establishment

### 1. Initial Connection Sequence

```
Timeline:
├─ T+0s    KoiService.exe starts
│
├─ T+0.5s  Read local configuration
│          └─→ Check C:\ProgramData\Koi\config\*
│
├─ T+1s    DNS lookup: api.prod.koi.security
│          └─→ Resolve to IP address
│
├─ T+2s    TCP connection attempt
│          └─→ Connect to api.prod.koi.security:443
│
├─ T+3s    TLS handshake
│          └─→ Negotiate TLS 1.2+ [?]
│          └─→ Validate server certificate
│
├─ T+4s    HTTP/2 or HTTP/1.1 setup [?]
│
├─ T+5s    Authentication
│          └─→ Send device credentials
│          └─→ Receive authentication token (if needed)
│
├─ T+6s    Initial sync
│          └─→ Fetch latest policies
│          └─→ Sync configuration
│
└─ T+7s    Connected - service operational
           └─→ Begin periodic sync loops
```

### 2. Proxy Handling

KoiService runs as **LocalSystem**, which means it uses:

**Priority Order:**
1. WinHTTP proxy settings (netsh winhttp show proxy)
   - [?] Does KoiService specifically use WinHTTP?
2. Machine-wide proxy (HKLM Internet Settings)
3. Proxy auto-config (PAC) if configured [?]
4. Direct connection (no proxy)

**Proxy Detection:**
```
┌─ Is proxy bypass rule matching api.prod.koi.security?
│  ├─ YES → Connect directly (no proxy)
│  └─ NO  → Connect via proxy
│
└─ Proxy authentication [?]
   ├─ NTLM credentials (current process user) [?]
   ├─ Basic auth (stored credentials) [?]
   └─ Anonymous
```

### 3. Certificate Validation

```
Step 1: Receive server certificate
  └─→ CN: api.prod.koi.security [?]
      Issuer: [?]

Step 2: Validate certificate chain
  └─→ Check root CA in Windows certificate store
      ├─ If CA missing → Connection fails
      └─ If CA present → Continue

Step 3: Hostname verification
  └─→ Certificate CN matches: api.prod.koi.security [?]

Step 4: Check certificate expiration
  └─→ Current date must be within NotBefore...NotAfter
```

---

## Data Flow & Communication

### 1. Periodic Sync Loops

```
KoiService Operation:
═══════════════════════════════════════════════════════════════

Loop 1: Policy Update Loop (every X minutes [?])
────────────────────────────────────────────
GET /api/devices/{deviceId}/policies
  └─→ Response: JSON array of enforcement policies
      {
        "policies": [
          {
            "id": "policy-001",
            "type": "threat-detection",
            "config": {...}
          }
        ]
      }

Loop 2: Activity Reporting Loop (every X minutes [?])
────────────────────────────────────────────
POST /api/devices/{deviceId}/activity
  └─→ Body: JSON with endpoint activity
      {
        "device_id": "...",
        "timestamp": "2026-09-29T14:00:00Z",
        "events": [
          {
            "type": "process_execution",
            "process_name": "notepad.exe",
            "action": "allowed"
          }
        ]
      }

Loop 3: Health Check Loop (every X minutes [?])
────────────────────────────────────────────
GET /api/devices/{deviceId}/health
  └─→ Response: Server confirms agent is registered
```

### 2. Enforcement Action Flow

```
When a threat is detected:

1. mdm.exe identifies threat
   └─→ (Quarantine, block, notify, etc.)

2. Record action to agent_enforcement.log
   └─→ Timestamp, action type, target

3. Send to Koi Cloud
   └─→ POST /api/devices/{deviceId}/enforcement
       {
         "action": "quarantine",
         "target": "file_hash",
         "reason": "malware_detected"
       }

4. Also relay to Cortex XDR Agent [?]
   └─→ XDR forwards to cloud
   └─→ Appears in XDR console
```

---

## Reporting Mechanisms

### 1. Where Does Data Go?

```
Koi Agent Data Flow:
═══════════════════════════════════════════════════════════════

KoiService
  │
  ├─→ Koi Cloud (api.prod.koi.security)
  │   └─→ Used by: Koi UI dashboard
  │
  ├─→ Cortex XDR Agent [?]
  │   └─→ Used by: XDR console
  │       (Does Cortex relay Koi data back to cloud?)
  │
  └─→ Local logs
      ├─→ KoiService.log
      ├─→ agent_activity.jsonl
      └─→ agent_enforcement.log
```

### 2. Cortex XDR Integration

[?] **Need clarification:**

- Is KoiService **standalone**, sending data directly to Koi Cloud?
- Or does KoiService **relay through** Cortex XDR Agent?
- Does Cortex XDR Agent:
  - Collect Koi logs and forward them?
  - Monitor KoiService process health?
  - Act as proxy for Koi API calls?

### 3. Koi UI Dashboard

[?] **Need clarification:**

- Does Koi UI pull data directly from agent via API?
- Or does Koi Cloud aggregate and serve pre-computed view?
- What data is displayed?
  - Real-time threats?
  - Device status?
  - Policy compliance?

---

## Authentication & Authorization

### 1. Device Registration

**Initial Authentication:**

```
Endpoint: POST /api/devices/register
Body:
{
  "hostname": "WORKSTATION-01",
  "machine_guid": "...",
  "os_version": "Windows 10 21H2",
  "agent_version": "1.0.0",
  "registration_token": "..." [?]
}

Response:
{
  "device_id": "dev_abc123...",
  "auth_token": "...",
  "policies": [...],
  "config": {...}
}
```

### 2. Ongoing Authentication

[?] **Need clarification:**

- Is auth_token sent with every API call?
- Location: Header? Bearer token? API key?
- Expiration time?
- Refresh mechanism?

**Expected format:**
```
GET /api/devices/{deviceId}/policies
Authorization: Bearer <auth_token>
```

### 3. Authorization Levels

[?] **Assumptions:**

- All devices with valid registration token can report activity
- Enforcement policies are role-based (admin can configure, user cannot)
- Cross-device access (can agent X see data from agent Y)?

---

## Log Files & Activity Tracking

### 1. KoiService.log

**Location:** `C:\ProgramData\Koi\KoiService\KoiService.log`

**Format:** [?] (plain text, JSON, custom)

**Typical Content:**
```
[2026-09-29 14:00:00] Service started
[2026-09-29 14:00:05] Configuration loaded from disk
[2026-09-29 14:00:10] Attempting connection to api.prod.koi.security:443
[2026-09-29 14:00:12] TLS handshake successful
[2026-09-29 14:00:15] Authentication successful (token: dev_abc...)
[2026-09-29 14:00:20] Policy sync: 5 policies retrieved
[2026-09-29 14:05:00] Activity report sent (23 events)
[2026-09-29 14:10:00] Policy sync: 5 policies retrieved (no changes)
```

**Troubleshooting Signals:**
- "Connection refused" → Firewall/proxy issue
- "Certificate validation failed" → TLS/cert issue
- "Authentication failed" → Credential/token issue
- "Timeout" → Network latency or unreachable endpoint
- "Policy application failed" → Enforcement engine error

### 2. agent_activity.jsonl

**Location:** `C:\ProgramData\Koi\agent_activity.jsonl`

**Format:** JSON Lines (one JSON object per line)

**Example:**
```json
{"timestamp":"2026-09-29T14:00:15Z","type":"process_execution","process":"notepad.exe","user":"DOMAIN\\user","action":"allowed"}
{"timestamp":"2026-09-29T14:00:20Z","type":"file_access","file":"C:\\Users\\user\\Downloads\\suspicious.exe","user":"DOMAIN\\user","action":"blocked"}
```

**Purpose:**
- Record all endpoint activities
- Sent to Koi Cloud in batches
- Analyzed for threat detection

**When empty (0 bytes):**
- Agent not running
- No activities captured
- File not being written (permissions issue?)

### 3. agent_enforcement.log

**Location:** `C:\ProgramData\Koi\agent_enforcement.log`

**Format:** [?]

**Example Content:**
```
[2026-09-29 14:00:30] QUARANTINE: C:\Users\user\Downloads\malware.exe (Hash: abc123...)
[2026-09-29 14:05:15] BLOCK: Process terminated - suspicious behavior
[2026-09-29 14:10:00] NOTIFY: User alerted to threat
```

**Purpose:**
- Track enforcement actions taken
- Audit trail for security decisions

---

## Troubleshooting Decision Tree

```
START: Agent not reporting
│
├─ Is KoiService installed?
│  ├─ NO → Install agent
│  └─ YES
│
├─ Is KoiService running?
│  ├─ NO → Check service startup (Start-Service KoiService)
│  └─ YES
│
├─ Is KoiService.log being written?
│  ├─ NO → Permissions issue? Service not starting?
│  └─ YES
│
├─ Are there errors in KoiService.log?
│  ├─ "Connection refused" → DNS/TCP/Firewall issue (run NETWORK tests)
│  ├─ "Certificate validation failed" → TLS/Cert issue (run NETWORK tests)
│  ├─ "Authentication failed" → Device not registered / token invalid
│  ├─ "Timeout" → Endpoint unreachable (run NETWORK tests)
│  └─ Other → Analyze error message
│
├─ Can we reach api.prod.koi.security from this machine?
│  ├─ NO → Network path issue (firewall, proxy, DNS)
│  │   ├─ Check firewall rules
│  │   ├─ Check proxy configuration
│  │   └─ Check DNS resolution
│  └─ YES
│
├─ Is agent_activity.jsonl growing?
│  ├─ NO → No activities captured or file permission issue
│  └─ YES → Agent is collecting data
│
├─ Is agent reporting to Koi Cloud?
│  ├─ Check in Koi UI dashboard
│  ├─ Check in Cortex XDR console [?]
│  └─ Check for recent API calls in KoiService.log
│
└─ END: Issue identified
```

---

## Open Questions for Clarification

### Architecture & Design

- [?] Is KoiService independent, or does it depend on Cortex XDR Agent?
- [?] Does Cortex XDR Agent relay Koi data, or does it go direct?
- [?] How does policy sync work? Pull vs. push?
- [?] Can agent operate if Cortex XDR Agent is not installed?

### Authentication

- [?] How is device initially authenticated (registration token, pre-shared key)?
- [?] What is the lifetime of auth_token?
- [?] Can auth_token be refreshed, or does registration need to repeat?
- [?] Is device auth tied to machine GUID, or some other identifier?

### Communication

- [?] Does Koi use HTTP/2 or HTTP/1.1?
- [?] What is the timeout for API calls?
- [?] Does agent retry failed requests? (Backoff strategy?)
- [?] What ports besides 443 are used? (8443, others?)

### Configuration

- [?] Where is local configuration stored?
- [?] Can configuration be modified locally, or only via Koi Cloud?
- [?] What is the refresh interval for policies?
- [?] What is the report interval for activity?

### Service Details

- [?] What is the exact service name in Windows Services?
- [?] What user does service run as (LocalSystem, NetworkService)?
- [?] What are service dependencies (if any)?
- [?] What are typical startup times?

### Cortex XDR Integration

- [?] Does Cortex XDR forward Koi enforcement actions?
- [?] Does Cortex XDR provide MDM policies to Koi?
- [?] Are there shared log files or just separate ones?
- [?] Is there a fallback if Cortex XDR is not reachable?

### Logging & Monitoring

- [?] Log rotation policy (when logs are archived/deleted)?
- [?] Maximum log file sizes?
- [?] What verbosity levels exist (debug, info, warning, error)?
- [?] Can logging be configured to be more verbose?

### Troubleshooting

- [?] Are there known failure modes (network issue vs auth vs config)?
- [?] What are common timeout/reconnection patterns?
- [?] How does agent behave if Koi Cloud is temporarily unreachable?

---

## Next Steps

**To complete this document:**

1. Provide answers to all `[?]` questions above
2. Provide sample logs (sanitized) if available
3. Share configuration file structure (e.g., config.yaml)
4. Provide API endpoint reference if public
5. Clarify XDR integration model

**Once clarified**, this document will become:
- Complete training material for workshops
- Reference guide for troubleshooting
- Foundation for additional runbooks

---

**Document Status:** Awaiting input for 30+ clarification points

**Last Updated:** 2026-09-29
