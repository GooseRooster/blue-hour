# blue-hour update helpers. Available via `ujust <recipe>`.
#
# These are phase-7 `ujust`-style commands (see docs/port-plan.md). The two
# update recipes exist so the notification/tray path can be exercised in the VM
# without waiting for the 15-minute timer.

# Refresh the blue-hour update status now (writes
# /run/blue-hour/update-status.json) and trigger the notification service.
blue-hour-update-status:
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/libexec/blue-hour-update-status
    systemctl --user start blue-hour-update-notify.service || true

# Simulate a staged update to preview the desktop notification and the Noctalia
# tray dot. Optional argument: a version string (default: test-1.0).
blue-hour-test-update version="test-1.0":
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/libexec/blue-hour-update-simulate "{{ version }}"
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/blue-hour/update-notify.staged"
    systemctl --user start blue-hour-update-notify.service || true

# Clear a simulated update and re-run the real status check.
blue-hour-clear-update:
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/libexec/blue-hour-update-status
