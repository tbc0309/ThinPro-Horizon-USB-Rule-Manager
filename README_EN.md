# ThinPro Horizon USB Rule Manager

[简体中文](README.md) | [English](README_EN.md)

A Windows management tool that adds or removes VMware Horizon USB redirection exception rules for selected USB devices on HP ThinPro.

Project: <https://github.com/tbc0309/ThinPro-Horizon-USB-Rule-Manager>

## Preview

![USB device scan and rule status](docs/images/thinpro-usb-rule-manager-preview.png)

## What It Solves

HP ThinPro USB Manager can mark a device as `Redirect - USBR`, but that setting alone does not guarantee that Horizon will claim the device.

Horizon excludes keyboards, mice, and other HID devices by default so users do not accidentally redirect their only input device and lose local control. Composite devices such as cameras and microphones may also be affected by video or audio class filtering and by local Linux drivers.

This can cause symptoms such as:

- The device is selected in ThinPro USB Manager, but is not visible in the Windows virtual machine.
- Clicking **Connect** in Horizon hangs, and the device later disappears.
- HID devices, keyboards with extra control keys, special controllers, or composite cameras cannot be redirected completely.

For each VID/PID explicitly selected by the user, this tool performs two configuration changes:

1. Maintains `viewusb.IncludeVidPid` in `/etc/vmware/config` to create an exception to Horizon's default device-class exclusions.
2. Creates an exact VID/PID udev rule so the device can be claimed by the Horizon USB arbitrator.

The tool does not enable all HID devices and does not modify USB devices that the user has not selected.

## Tested Environments

- HP ThinPro 7.2
- HP ThinPro 8.1.3
- VMware Horizon Client 8.0 and 8.8
- HP t630 and HP t430
- Windows PowerShell 5.1

## Quick Start

> **Important: Before running this tool, open “Control Panel → Management → SSHD Manager” in ThinPro, select “Enable incoming Secure Shell access,” and click “Apply.” The tool cannot connect to ThinPro through SSH until this setting is enabled.**

1. Download the complete project and keep all four runtime files in the same directory.
2. Double-click `Start-ThinPro-USB-Rule-Manager.cmd`.
3. Enter the ThinPro IP address and administrator password.
4. Verify the SSH host fingerprint shown on the first connection.
5. Select the option to scan devices and add a rule.
6. Select the target device and confirm.
7. Physically unplug and reconnect the device, then connect it again from Horizon.

Green devices already have a rule; white devices do not.

## Features

- Reads connected ThinPro USB devices, including their names, VIDs, and PIDs.
- Adds exact redirection rules for selected devices.
- Displays or removes devices managed by this tool.
- Preserves the original configuration and provides a recovery function.
- Associates backups with the ThinPro `machine-id`, not its dynamic IP address.
- Verifies the fixed SHA-256 digest of the bundled `plink.exe`.
- Does not save IP addresses, administrator passwords, or login records.

## Security Design

- SSH always uses `root`; the interface calls its password the administrator password.
- Password input is hidden and is passed to Plink only for the current run through a restricted temporary file, which is deleted on exit.
- The tool removes any temporary password files left by an interrupted previous run.
- The user must manually verify the SSH SHA-256 host fingerprint on the first connection or after reinstalling ThinPro.
- Do not add the only keyboard or mouse currently used to control ThinPro.

## Backup and Recovery

On the first connection, the tool preserves the state before any changes:

```text
/etc/vmware/config.bak
/etc/udev/rules.d/98-horizon-usb-managed.rules.bak
```

If an original file does not exist, an `.bak.absent` marker is created instead. An additional original-state copy, organized by `machine-id`, is stored on Windows at:

```text
%LOCALAPPDATA%\ThinPro-USB-Rule-Manager\Backups\ThinPro_<machine-id>\original-backup.json
```

Restoring the initial state requires entering uppercase `RESTORE` to prevent accidental recovery.

## Notes

- `State=2` in USB Manager expresses a redirection preference; it does not override Horizon HID, video, or audio exclusion rules by itself.
- Prefer Horizon RTAV for ordinary webcam use. Use full USBR only when an application requires the native USB device.
- Physically unplug and reconnect the device after adding or deleting a rule. If necessary, completely exit and reconnect the Horizon session.
- If Windows detects the device but the application does not, check the Windows driver and application compatibility.

## Project Files

```text
Start-ThinPro-USB-Rule-Manager.cmd  Launcher
ThinPro-USB-Rule-Manager.ps1        Main program
plink.exe                           PuTTY 0.85 Plink
README.md                           Default Simplified Chinese documentation
README_EN.md                        English documentation
使用说明.txt                         Concise Chinese instructions
docs/technical-background.md        Technical background (Chinese)
docs/troubleshooting.md             Troubleshooting (Chinese)
THIRD_PARTY_NOTICES.md              Third-party notices
```

## Disclaimer

This tool modifies the Horizon and udev configuration on ThinPro. Test it on a non-production device first and ensure that a working keyboard, mouse, or remote-management method remains available on site.
