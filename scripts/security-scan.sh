#!/bin/bash
# Security Scanning Script for ZTP Bootstrap Web UI
# This script runs various security scans and generates a report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="${PROJECT_ROOT}/security-reports"
TARGET_URL="${1:-http://127.0.0.1:8080/ui/}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ZTP Bootstrap Security Scan ===${NC}"
echo "Target URL: $TARGET_URL"
echo "Report directory: $REPORT_DIR"
echo ""

# Create report directory
mkdir -p "$REPORT_DIR"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Dependency Vulnerability Scan
echo -e "${YELLOW}[1/6] Scanning Python dependencies for vulnerabilities...${NC}"
if command_exists pip-audit; then
    pip-audit -r "${PROJECT_ROOT}/webui/requirements.txt" --format json > "${REPORT_DIR}/pip-audit.json" 2>&1 || true
    pip-audit -r "${PROJECT_ROOT}/webui/requirements.txt" > "${REPORT_DIR}/pip-audit.txt" 2>&1 || true
    echo -e "${GREEN}✓ pip-audit scan complete${NC}"
else
    echo -e "${RED}✗ pip-audit not installed. Install with: pip install pip-audit${NC}"
fi

# 2. Python Code Security Scan (Bandit)
echo -e "${YELLOW}[2/6] Scanning Python code with Bandit...${NC}"
if command_exists bandit; then
    bandit -r "${PROJECT_ROOT}/webui/" -f json -o "${REPORT_DIR}/bandit-report.json" 2>&1 || true
    bandit -r "${PROJECT_ROOT}/webui/" -f txt -o "${REPORT_DIR}/bandit-report.txt" 2>&1 || true
    echo -e "${GREEN}✓ Bandit scan complete${NC}"
else
    echo -e "${RED}✗ Bandit not installed. Install with: pip install bandit${NC}"
fi

# 3. Security Headers Check
echo -e "${YELLOW}[3/6] Checking security headers...${NC}"
curl -sI "$TARGET_URL" > "${REPORT_DIR}/security-headers.txt" 2>&1 || true
echo "Security Headers:" > "${REPORT_DIR}/security-headers-analysis.txt"
echo "=================" >> "${REPORT_DIR}/security-headers-analysis.txt"
echo "" >> "${REPORT_DIR}/security-headers-analysis.txt"

# Check for important headers
HEADERS=("Strict-Transport-Security" "Content-Security-Policy" "X-Frame-Options" "X-Content-Type-Options" "X-XSS-Protection" "Referrer-Policy")
for header in "${HEADERS[@]}"; do
    if grep -qi "$header" "${REPORT_DIR}/security-headers.txt"; then
        echo -e "${GREEN}✓ $header: Present${NC}" | tee -a "${REPORT_DIR}/security-headers-analysis.txt"
    else
        echo -e "${RED}✗ $header: Missing${NC}" | tee -a "${REPORT_DIR}/security-headers-analysis.txt"
    fi
done

# 4. OWASP ZAP Baseline Scan
echo -e "${YELLOW}[4/6] Running OWASP ZAP baseline scan...${NC}"
if command_exists zap.sh || command_exists zap-cli; then
    # Check if ZAP is already running
    if curl -s http://127.0.0.1:8080 >/dev/null 2>&1; then
        echo "ZAP appears to be running, using existing instance"
        ZAP_URL="http://127.0.0.1:8080"
    else
        echo "Starting ZAP daemon..."
        zap.sh -daemon -host 0.0.0.0 -port 8080 -config api.disablekey=true >/dev/null 2>&1 &
        ZAP_PID=$!
        sleep 10
        ZAP_URL="http://127.0.0.1:8080"
    fi
    
    if command_exists zap-cli; then
        zap-cli quick-scan --self-contained --start-options '-config api.disablekey=true' "$TARGET_URL" > "${REPORT_DIR}/zap-quick-scan.txt" 2>&1 || true
        zap-cli report -o "${REPORT_DIR}/zap-report.html" -f html 2>&1 || true
        echo -e "${GREEN}✓ OWASP ZAP scan complete${NC}"
    else
        echo -e "${RED}✗ zap-cli not installed. Install with: pip install zapcli${NC}"
    fi
    
    # Cleanup if we started ZAP
    if [ -n "${ZAP_PID:-}" ]; then
        kill "$ZAP_PID" 2>/dev/null || true
    fi
else
    echo -e "${RED}✗ OWASP ZAP not installed. Install from: https://www.zaproxy.org/download/${NC}"
fi

# 5. SSL/TLS Configuration Check (if HTTPS)
echo -e "${YELLOW}[5/6] Checking SSL/TLS configuration...${NC}"
if [[ "$TARGET_URL" == https://* ]]; then
    if command_exists openssl; then
        DOMAIN=$(echo "$TARGET_URL" | sed -E 's|https?://([^/]+).*|\1|')
        echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>&1 > "${REPORT_DIR}/ssl-info.txt" || true
        echo -e "${GREEN}✓ SSL/TLS check complete${NC}"
    else
        echo -e "${RED}✗ openssl not available${NC}"
    fi
else
    echo "Skipping SSL check (HTTP only)"
fi

# 6. Generate Summary Report
echo -e "${YELLOW}[6/6] Generating summary report...${NC}"

# Build list of available reports
AVAILABLE_REPORTS=()
NEXT_STEPS=()

if [ -f "${REPORT_DIR}/pip-audit.txt" ]; then
    AVAILABLE_REPORTS+=("pip-audit.txt")
    NEXT_STEPS+=("- Review \`pip-audit.txt\` for dependency vulnerabilities")
fi

if [ -f "${REPORT_DIR}/bandit-report.txt" ]; then
    AVAILABLE_REPORTS+=("bandit-report.txt")
    NEXT_STEPS+=("- Review \`bandit-report.txt\` for code security issues")
fi

if [ -f "${REPORT_DIR}/security-headers-analysis.txt" ]; then
    AVAILABLE_REPORTS+=("security-headers-analysis.txt")
    NEXT_STEPS+=("- Check \`security-headers-analysis.txt\` for missing headers")
fi

if [ -f "${REPORT_DIR}/zap-report.html" ]; then
    AVAILABLE_REPORTS+=("zap-report.html")
    NEXT_STEPS+=("- Review \`zap-report.html\` for web application vulnerabilities")
fi

if [ -f "${REPORT_DIR}/zap-quick-scan.txt" ]; then
    AVAILABLE_REPORTS+=("zap-quick-scan.txt")
fi

if [ -f "${REPORT_DIR}/ssl-info.txt" ]; then
    AVAILABLE_REPORTS+=("ssl-info.txt")
    NEXT_STEPS+=("- Review \`ssl-info.txt\` for SSL/TLS configuration issues")
fi

cat > "${REPORT_DIR}/SECURITY-SCAN-SUMMARY.md" <<EOF
# Security Scan Summary

**Date:** $(date)
**Target URL:** $TARGET_URL

## Scan Results

### 1. Dependency Vulnerabilities
- **Report:** \`pip-audit.txt\`
- **Status:** $(if [ -f "${REPORT_DIR}/pip-audit.txt" ]; then echo "✅ Complete"; else echo "❌ Not run (pip-audit not installed)"; fi)
$(if [ -f "${REPORT_DIR}/pip-audit.txt" ]; then
    echo ""
    echo "**Results:**"
    echo "\`\`\`"
    # Show first 50 lines or full file if smaller
    head -n 50 "${REPORT_DIR}/pip-audit.txt"
    if [ $(wc -l < "${REPORT_DIR}/pip-audit.txt") -gt 50 ]; then
        echo "... (truncated, see full report in \`pip-audit.txt\`)"
    fi
    echo "\`\`\`"
fi)

### 2. Code Security (Bandit)
- **Report:** \`bandit-report.txt\`
- **Status:** $(if [ -f "${REPORT_DIR}/bandit-report.txt" ]; then echo "✅ Complete"; else echo "❌ Not run (bandit not installed)"; fi)
$(if [ -f "${REPORT_DIR}/bandit-report.txt" ]; then
    echo ""
    echo "**Results:**"
    echo "\`\`\`"
    # Show first 100 lines or full file if smaller
    head -n 100 "${REPORT_DIR}/bandit-report.txt"
    if [ $(wc -l < "${REPORT_DIR}/bandit-report.txt") -gt 100 ]; then
        echo "... (truncated, see full report in \`bandit-report.txt\`)"
    fi
    echo "\`\`\`"
fi)

### 3. Security Headers
- **Report:** \`security-headers-analysis.txt\`
- **Status:** $(if [ -f "${REPORT_DIR}/security-headers-analysis.txt" ]; then echo "✅ Complete"; else echo "❌ Failed"; fi)
$(if [ -f "${REPORT_DIR}/security-headers-analysis.txt" ]; then
    echo ""
    echo "**Results:**"
    echo "\`\`\`"
    # Strip ANSI color codes and show content
    sed 's/\x1b\[[0-9;]*m//g' "${REPORT_DIR}/security-headers-analysis.txt" | tail -n +4
    echo "\`\`\`"
fi)

### 4. OWASP ZAP Scan
- **Report:** \`zap-report.html\`
- **Status:** $(if [ -f "${REPORT_DIR}/zap-report.html" ]; then echo "✅ Complete"; else echo "❌ Not run (OWASP ZAP not installed)"; fi)
$(if [ -f "${REPORT_DIR}/zap-quick-scan.txt" ]; then
    echo ""
    echo "**Quick Scan Results:**"
    echo "\`\`\`"
    # Show quick scan results
    head -n 100 "${REPORT_DIR}/zap-quick-scan.txt"
    if [ $(wc -l < "${REPORT_DIR}/zap-quick-scan.txt") -gt 100 ]; then
        echo "... (truncated, see full report in \`zap-quick-scan.txt\`)"
    fi
    echo "\`\`\`"
    echo "- **Full HTML Report:** \`zap-report.html\`"
elif [ -f "${REPORT_DIR}/zap-report.html" ]; then
    echo "- **Full HTML Report:** \`zap-report.html\`"
fi)

### 5. SSL/TLS Configuration
- **Report:** \`ssl-info.txt\`
- **Status:** $(if [ -f "${REPORT_DIR}/ssl-info.txt" ]; then echo "✅ Complete"; elif [[ "$TARGET_URL" == https://* ]]; then echo "❌ Not run"; else echo "⏭️  Not applicable (HTTP only)"; fi)
$(if [ -f "${REPORT_DIR}/ssl-info.txt" ]; then
    echo ""
    echo "**Results:**"
    echo "\`\`\`"
    # Show SSL info (certificate details, cipher info, etc.)
    grep -E "(subject=|issuer=|Protocol|Cipher|Verify return code)" "${REPORT_DIR}/ssl-info.txt" | head -n 20
    echo "\`\`\`"
    echo "- **Full Report:** \`ssl-info.txt\`"
fi)

## Available Reports

$(if [ ${#AVAILABLE_REPORTS[@]} -eq 0 ]; then
    echo "No reports were generated. Install the required tools to generate reports:"
    echo ""
    echo "- \`pip install pip-audit\` - for dependency scanning"
    echo "- \`pip install bandit\` - for code security scanning"
    echo "- Install OWASP ZAP from https://www.zaproxy.org/download/"
else
    echo "The following reports are available in \`${REPORT_DIR}\`:"
    echo ""
    for report in "${AVAILABLE_REPORTS[@]}"; do
        echo "- \`${report}\`"
    done
fi)

## Recommendations

1. Review all available scan reports for vulnerabilities
2. Address high and medium severity issues immediately
3. Schedule regular security scans (weekly/monthly)
4. Keep dependencies up to date
5. Monitor security advisories for Flask, Werkzeug, and PyYAML

## Next Steps

$(if [ ${#NEXT_STEPS[@]} -eq 0 ]; then
    echo "Install security scanning tools to generate reports:"
    echo ""
    echo "- Install \`pip-audit\`: \`pip install pip-audit\`"
    echo "- Install \`bandit\`: \`pip install bandit\`"
    echo "- Install OWASP ZAP: https://www.zaproxy.org/download/"
    echo "- Install \`zap-cli\`: \`pip install zapcli\`"
else
    for step in "${NEXT_STEPS[@]}"; do
        echo "$step"
    done
fi)

EOF

echo ""
echo -e "${GREEN}=== Security Scan Complete ===${NC}"
echo "Reports saved to: $REPORT_DIR"
echo ""
echo "View summary: cat ${REPORT_DIR}/SECURITY-SCAN-SUMMARY.md"
echo "View HTML report: open ${REPORT_DIR}/zap-report.html"
