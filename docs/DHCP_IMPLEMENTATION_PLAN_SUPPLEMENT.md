# DHCP Implementation Plan - Supplement

## Overview

This document supplements the main `DHCP_IMPLEMENTATION_PLAN.md` with additional features and gap analysis based on the current implementation state. The main plan outlined the architecture and phases; this supplement focuses on **missing UI components**, **DHCP reservations management**, **OUI filtering UI**, and **live logging toggle**.

---

## Current Implementation Status

### ✅ Completed Components

| Component | Status | Notes |
|-----------|--------|-------|
| `dhcp_config.py` | ✅ Complete | Kea configuration generator with OUI filtering logic |
| `dhcp_utils.py` | ✅ Complete | Network detection, validation, port conflict checking |
| `dhcp_deploy.py` | ✅ Complete | Container deployment via quadlet/systemd |
| `kea_client.py` | ✅ Complete | Kea Control Agent client with lease/reservation APIs |
| `config.yaml.template` | ✅ Complete | DHCP section with OUI filtering, PXE, relay support |
| API Endpoints | ✅ Complete | All DHCP endpoints implemented in `app.py` |
| DHCP Tab (basic) | ✅ Complete | Configuration, Status, Logs tabs |
| Active Leases Table | ✅ Complete | Displays leases with delete action |
| Auto-refresh Logs | ✅ Complete | Toggle exists in UI |

### ❌ Missing/Incomplete Components

| Component | Status | Priority | Notes |
|-----------|--------|----------|-------|
| DHCP Reservations UI | ❌ Missing | **HIGH** | API exists, no UI to create/manage reservations |
| OUI Filtering UI | ❌ Missing | **HIGH** | Backend exists, no UI to configure OUI rules |
| Live Logging Toggle | ⚠️ Exists but subtle | **LOW** | Toggle exists but could be more prominent |
| PXE Configuration UI | ❌ Missing | Medium | Backend exists, no UI |
| Relay Configuration UI | ❌ Missing | Medium | Backend exists, no UI |
| Custom DHCP Options UI | ❌ Missing | Low | Backend exists, no UI |

---

## Phase S1: DHCP Reservations Management UI

### S1.1 Reservations Tab Addition

**File**: `webui/templates/index.html`

Add a "Reservations" tab to the DHCP Server Tabs section:

```html
<!-- Add to DHCP Server Tabs nav -->
<button @click="activeDhcpTab = 'reservations'"
        :class="activeDhcpTab === 'reservations' ? 'border-blue-500 text-blue-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'"
        class="px-6 py-4 border-b-2 font-medium text-sm">
    Reservations
</button>
```

### S1.2 Reservations Table and Form

**File**: `webui/templates/index.html`

Create Reservations tab content with:
- Table displaying current reservations (MAC, IP, Hostname, Actions)
- "Add Reservation" button that opens a modal/inline form
- Form fields: MAC Address, IP Address, Hostname (optional)
- Delete button per reservation

**UI Design**:
```
┌─────────────────────────────────────────────────────────────────────┐
│ DHCP Reservations                                    [+ Add New]    │
├─────────────────────────────────────────────────────────────────────┤
│ MAC Address        │ IP Address    │ Hostname    │ Actions         │
├────────────────────┼───────────────┼─────────────┼─────────────────┤
│ 00:1c:73:aa:bb:cc  │ 10.0.0.100    │ switch-1    │ [Delete]        │
│ 00:1c:73:dd:ee:ff  │ 10.0.0.101    │ switch-2    │ [Delete]        │
└─────────────────────────────────────────────────────────────────────┘

┌─ Add Reservation ───────────────────────────────────────────────────┐
│ MAC Address: [00:1c:73:__:__:__]  IP Address: [10.0.0.___]         │
│ Hostname (optional): [________________]                             │
│                                         [Cancel] [Add Reservation]  │
└─────────────────────────────────────────────────────────────────────┘
```

### S1.3 Alpine.js State and Functions

**File**: `webui/templates/index.html` (script section)

Add to Alpine.js data:
```javascript
// DHCP Reservations state
dhcpReservations: [],
showReservationForm: false,
newReservation: {
    mac: '',
    ip: '',
    hostname: ''
},
reservationError: '',
```

Add functions:
```javascript
async loadDhcpReservations() {
    // GET /api/dhcp/reservations
},

async addDhcpReservation() {
    // POST /api/dhcp/reservations with newReservation data
    // Validate MAC format (XX:XX:XX:XX:XX:XX)
    // Validate IP is within configured subnet
},

async deleteDhcpReservation(mac) {
    // DELETE /api/dhcp/reservations/{mac}
},

validateMacAddress(mac) {
    // Return true if valid MAC format
},

validateReservationIp(ip) {
    // Return true if IP is within configured subnet
}
```

### S1.4 Quick Reservation from Leases

**Enhancement**: Add "Create Reservation" action to the Active Leases table to quickly convert a dynamic lease to a static reservation.

```html
<!-- In leases table actions column -->
<button @click="createReservationFromLease(lease)"
        class="text-blue-600 hover:text-blue-800 mr-2">
    Reserve
</button>
```

---

## Phase S2: OUI Filtering UI

### S2.1 OUI Filtering Section in Configuration Tab

**File**: `webui/templates/index.html`

Add OUI Filtering section after DNS & Domain settings in the DHCP Configuration form:

```html
<!-- OUI Filtering Section -->
<div class="border-t border-gray-200 pt-4 mt-4">
    <h4 class="text-sm font-medium text-gray-700 mb-3">OUI Filtering</h4>

    <!-- Arista-Only Mode Toggle -->
    <div class="flex items-center justify-between mb-4">
        <div>
            <label class="text-sm font-medium text-gray-700">Arista-Only Mode</label>
            <p class="text-xs text-gray-500">Only serve DHCP to Arista devices (recommended for ZTP)</p>
        </div>
        <label class="inline-flex items-center cursor-pointer">
            <input type="checkbox" x-model="dhcpConfig.oui_filtering.arista_only_mode" class="sr-only peer">
            <div class="relative w-11 h-6 bg-gray-200 peer-focus:outline-none peer-focus:ring-4 peer-focus:ring-blue-300 rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600"></div>
        </label>
    </div>

    <!-- Allowed OUIs (only shown if Arista-only is off) -->
    <div x-show="!dhcpConfig.oui_filtering.arista_only_mode" class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Allowed OUIs</label>
        <p class="text-xs text-gray-500 mb-2">MAC prefixes to allow (e.g., 00:1C:73 for Arista). Leave empty to allow all.</p>
        <div class="flex flex-wrap gap-2 mb-2">
            <template x-for="(oui, index) in dhcpConfig.oui_filtering.allowed_ouis" :key="index">
                <span class="inline-flex items-center px-2 py-1 bg-green-100 text-green-800 rounded-md text-sm">
                    <span x-text="oui"></span>
                    <button @click="removeAllowedOui(index)" class="ml-1 text-green-600 hover:text-green-800">&times;</button>
                </span>
            </template>
        </div>
        <div class="flex gap-2">
            <input type="text" x-model="newAllowedOui" placeholder="00:1C:73"
                   class="flex-1 px-3 py-2 border border-gray-300 rounded-md text-sm"
                   @keyup.enter="addAllowedOui()">
            <button @click="addAllowedOui()" class="px-3 py-2 bg-green-600 text-white rounded-md text-sm hover:bg-green-700">Add</button>
        </div>
    </div>

    <!-- Blocked OUIs -->
    <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Blocked OUIs</label>
        <p class="text-xs text-gray-500 mb-2">MAC prefixes to block (never serve DHCP to these devices)</p>
        <div class="flex flex-wrap gap-2 mb-2">
            <template x-for="(oui, index) in dhcpConfig.oui_filtering.blocked_ouis" :key="index">
                <span class="inline-flex items-center px-2 py-1 bg-red-100 text-red-800 rounded-md text-sm">
                    <span x-text="oui"></span>
                    <button @click="removeBlockedOui(index)" class="ml-1 text-red-600 hover:text-red-800">&times;</button>
                </span>
            </template>
        </div>
        <div class="flex gap-2">
            <input type="text" x-model="newBlockedOui" placeholder="00:00:00"
                   class="flex-1 px-3 py-2 border border-gray-300 rounded-md text-sm"
                   @keyup.enter="addBlockedOui()">
            <button @click="addBlockedOui()" class="px-3 py-2 bg-red-600 text-white rounded-md text-sm hover:bg-red-700">Add</button>
        </div>
    </div>
</div>
```

### S2.2 OUI Filtering State and Functions

**File**: `webui/templates/index.html` (script section)

Extend dhcpConfig state:
```javascript
dhcpConfig: {
    // ... existing fields ...
    oui_filtering: {
        arista_only_mode: false,
        allowed_ouis: [],
        blocked_ouis: []
    }
},
newAllowedOui: '',
newBlockedOui: '',
```

Add functions:
```javascript
addAllowedOui() {
    const oui = this.normalizeOui(this.newAllowedOui);
    if (oui && !this.dhcpConfig.oui_filtering.allowed_ouis.includes(oui)) {
        this.dhcpConfig.oui_filtering.allowed_ouis.push(oui);
        this.newAllowedOui = '';
    }
},

removeAllowedOui(index) {
    this.dhcpConfig.oui_filtering.allowed_ouis.splice(index, 1);
},

addBlockedOui() {
    const oui = this.normalizeOui(this.newBlockedOui);
    if (oui && !this.dhcpConfig.oui_filtering.blocked_ouis.includes(oui)) {
        this.dhcpConfig.oui_filtering.blocked_ouis.push(oui);
        this.newBlockedOui = '';
    }
},

removeBlockedOui(index) {
    this.dhcpConfig.oui_filtering.blocked_ouis.splice(index, 1);
},

normalizeOui(oui) {
    // Normalize OUI to XX:XX:XX format
    if (!oui) return null;
    const cleaned = oui.replace(/[^0-9a-fA-F]/g, '').toUpperCase();
    if (cleaned.length !== 6) return null;
    return `${cleaned.slice(0,2)}:${cleaned.slice(2,4)}:${cleaned.slice(4,6)}`;
}
```

### S2.3 Known Arista OUIs Reference

Add a helper tooltip or expandable section showing known Arista OUIs:

```
Known Arista OUIs:
- 00:1C:73 - Arista Networks (most common)
- 00:1E:0D through 00:1E:1F - Arista Networks
- 28:99:3A - Arista Networks
- 44:4C:A8 - Arista Networks
```

### S2.4 Backend Integration

The backend (`dhcp_config.py`) already handles OUI filtering. Ensure the API endpoints save/load the `oui_filtering` section:

**File**: `webui/app.py`

Verify `update_dhcp_config()` properly handles:
```python
oui_filtering = data.get("oui_filtering", {})
config["dhcp"]["oui_filtering"] = {
    "arista_only_mode": oui_filtering.get("arista_only_mode", False),
    "allowed_ouis": oui_filtering.get("allowed_ouis", []),
    "blocked_ouis": oui_filtering.get("blocked_ouis", [])
}
```

---

## Phase S3: Live Logging Toggle Enhancement

### S3.1 Current State

The auto-refresh toggle exists but is:
- Small and easy to miss
- Located in the log controls area
- Uses the same styling as other controls

### S3.2 Enhancement: More Prominent Toggle

**Option A**: Add a visual indicator showing live status

```html
<!-- Enhanced Live Logging Toggle -->
<div class="flex items-center gap-2">
    <label class="inline-flex items-center cursor-pointer" title="Live log updates">
        <input type="checkbox" x-model="autoRefreshEnabled" @change="toggleAutoRefresh()" class="sr-only peer">
        <div class="relative w-11 h-6 bg-gray-200 peer-focus:outline-none peer-focus:ring-4 peer-focus:ring-blue-300 rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-green-600"></div>
    </label>
    <span class="text-sm" :class="autoRefreshEnabled ? 'text-green-600 font-medium' : 'text-gray-500'">
        <span x-show="autoRefreshEnabled" class="flex items-center">
            <span class="relative flex h-2 w-2 mr-1">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75"></span>
                <span class="relative inline-flex rounded-full h-2 w-2 bg-green-500"></span>
            </span>
            Live
        </span>
        <span x-show="!autoRefreshEnabled">Paused</span>
    </span>
</div>
```

**Option B**: Add keyboard shortcut

```javascript
// Add to init() or document ready
document.addEventListener('keydown', (e) => {
    // Press 'L' to toggle live logging when on logs tab
    if (e.key === 'l' && !e.ctrlKey && !e.metaKey && !e.altKey) {
        if (this.activeTab === 'logs' || (this.activeApplication === 'dhcp' && this.activeDhcpTab === 'logs')) {
            this.autoRefreshEnabled = !this.autoRefreshEnabled;
            this.toggleAutoRefresh();
        }
    }
});
```

### S3.3 Persist Toggle State

The toggle state should persist across page reloads:

```javascript
// In init()
this.autoRefreshEnabled = localStorage.getItem('ztpbootstrap-autoRefreshEnabled') !== 'false';

// In toggleAutoRefresh()
localStorage.setItem('ztpbootstrap-autoRefreshEnabled', this.autoRefreshEnabled);
```

---

## Phase S4: API Enhancements

### S4.1 Reservation Validation Endpoint

**File**: `webui/app.py`

Add validation endpoint for reservations:

```python
@app.route("/api/dhcp/reservations/validate", methods=["POST"])
@require_auth
def validate_dhcp_reservation():
    """Validate reservation before adding"""
    data = request.get_json()
    mac = data.get("mac", "")
    ip = data.get("ip", "")

    errors = []
    warnings = []

    # Validate MAC format
    if not re.match(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$', mac):
        errors.append("Invalid MAC address format. Use XX:XX:XX:XX:XX:XX")

    # Validate IP is within configured subnet
    config = load_config()
    subnet = config.get("dhcp", {}).get("ipv4", {}).get("subnet", "")
    if subnet:
        try:
            network = ipaddress.ip_network(subnet, strict=False)
            ip_addr = ipaddress.ip_address(ip)
            if ip_addr not in network:
                errors.append(f"IP {ip} is not within subnet {subnet}")
        except ValueError as e:
            errors.append(f"Invalid IP address: {e}")

    # Check for duplicate MAC
    existing = config.get("dhcp", {}).get("reservations", [])
    if any(r.get("hw-address") == mac for r in existing):
        errors.append(f"Reservation for MAC {mac} already exists")

    # Check for duplicate IP
    if any(r.get("ip-address") == ip for r in existing):
        warnings.append(f"IP {ip} is already reserved for another device")

    return jsonify({
        "valid": len(errors) == 0,
        "errors": errors,
        "warnings": warnings
    })
```

### S4.2 OUI Lookup Endpoint

**File**: `webui/app.py`

Add OUI lookup for displaying vendor names:

```python
# Known OUI prefixes (subset for common vendors)
KNOWN_OUIS = {
    "00:1C:73": "Arista Networks",
    "00:1E:0D": "Arista Networks",
    "28:99:3A": "Arista Networks",
    "44:4C:A8": "Arista Networks",
    "00:50:56": "VMware",
    "00:0C:29": "VMware",
    "52:54:00": "QEMU/KVM",
    "08:00:27": "VirtualBox",
    # Add more as needed
}

@app.route("/api/dhcp/oui/<oui>", methods=["GET"])
def lookup_oui(oui):
    """Lookup OUI vendor name"""
    normalized = oui.upper().replace("-", ":").replace(".", ":")[:8]
    vendor = KNOWN_OUIS.get(normalized, "Unknown")
    return jsonify({"oui": normalized, "vendor": vendor})
```

---

## Phase S5: Testing

### S5.1 Unit Tests for New Features

**File**: `tests/unit/test_dhcp_reservations.py`

```python
def test_reservation_validation():
    """Test reservation MAC/IP validation"""

def test_oui_normalization():
    """Test OUI format normalization"""

def test_oui_filtering_config_generation():
    """Test Kea config generation with OUI filtering"""
```

### S5.2 Integration Tests

**File**: `tests/integration/test_dhcp_reservations.bats`

```bash
@test "Add DHCP reservation via API" {
    # POST /api/dhcp/reservations
}

@test "Delete DHCP reservation via API" {
    # DELETE /api/dhcp/reservations/{mac}
}

@test "OUI filtering configuration persists" {
    # PUT /api/dhcp/config with oui_filtering
    # GET /api/dhcp/config and verify
}
```

---

## Implementation Order

1. **Phase S1**: DHCP Reservations UI (HIGH priority)
   - Add Reservations tab
   - Create reservation form
   - Implement Alpine.js functions
   - Add "Reserve" action to leases table

2. **Phase S2**: OUI Filtering UI (HIGH priority)
   - Add OUI filtering section to config form
   - Implement OUI add/remove functions
   - Add Arista-only mode toggle
   - Verify backend integration

3. **Phase S3**: Live Logging Toggle Enhancement (LOW priority)
   - Add visual indicator for live status
   - Persist toggle state
   - Optional: Add keyboard shortcut

4. **Phase S4**: API Enhancements (as needed)
   - Reservation validation endpoint
   - OUI lookup endpoint

5. **Phase S5**: Testing (throughout)

---

## Files to Modify

| File | Changes |
|------|---------|
| `webui/templates/index.html` | Reservations tab, OUI filtering UI, enhanced live toggle |
| `webui/app.py` | Validation endpoint, OUI lookup, verify OUI config handling |
| `tests/unit/test_dhcp_reservations.py` | New test file |
| `tests/integration/test_dhcp_reservations.bats` | New test file |

---

## Notes

- The backend infrastructure is largely complete; this supplement focuses on UI gaps
- OUI filtering logic in `dhcp_config.py` is already implemented and generates correct Kea client classifications
- Reservations API endpoints exist in `app.py` but have no UI
- The live logging toggle exists but could benefit from better visibility
- All changes should maintain the existing UI aesthetic and use Tailwind CSS classes
