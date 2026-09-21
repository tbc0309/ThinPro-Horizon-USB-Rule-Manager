# 技术原理

## 为什么 USB 管理器勾选后仍可能无效

ThinPro USB 管理器中的设备状态主要表达重定向意图：

```text
root/USB/Devices/<UUID>/State = 2
```

设备仍需经过 Horizon 的设备过滤和 Linux 本地驱动分配。Horizon 默认保护键盘、鼠标等 HID 输入设备，视频和音频设备则通常优先使用高级重定向。

因此 `State=2` 并不等于 Horizon 一定接管成功。

## Horizon 过滤规则

工具在 `/etc/vmware/config` 中维护：

```text
viewusb.IncludeVidPid = "vid-6603_pid-1002;"
```

它按具体 VID/PID 为设备建立例外，不会允许所有 HID 设备。

## udev 规则

工具管理：

```text
/etc/udev/rules.d/98-horizon-usb-managed.rules
```

规则只匹配用户选择的 USB 设备，并在设备插入时取消当前配置，让 Horizon USB 仲裁器有机会接管完整设备。

## 复合设备

摄像头可能同时包含 Video、Audio Control 和 Audio Streaming 等多个接口。只要其中一部分被本地驱动占用，完整 USBR 就可能失败。

对于普通视频会议，优先使用 Horizon RTAV。对于必须识别原生 USB 设备的管理软件，才使用本工具进行完整 USB 重定向。

## 为什么不允许全部 HID

若将唯一键盘或鼠标完整重定向到虚拟机，ThinPro 本地可能立即失去输入能力，远程会话断开后也可能无法恢复操作。因此工具坚持使用精确 VID/PID，不提供“允许全部 HID”选项。

