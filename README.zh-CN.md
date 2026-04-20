# btresumed

> 事件驱动的 macOS 守护进程，自动修复睡眠唤醒后 BLE 鼠标/键盘不重连的问题。
>
> [English](README.md)

## 问题

在 macOS（Sonoma、Sequoia 以及真 Mac 上都存在）上，某些使用 **LE Privacy (RPA)** 的 BLE 外设——特别是 Microsoft Modern Mobile Mouse、Logitech MX Master、Logitech MX Keys、Framework 笔记本内置 BT 鼠标等——**从睡眠唤醒后无法自动重连**。

表现：

- 唤醒 Mac → 鼠标指针不动、键盘无响应
- System Settings 显示设备 "Not Connected"（未连接）
- 手动 **关掉再打开蓝牙** 设备立刻重连
- `bluetoothd` 日志里有 `reason 762`、`encryption STATUS 634` 或 `MIC failure (HCI 0x3D)`
- 同一设备在 Windows / Linux / ChromeOS 上完全正常

这是 macOS BLE 栈的已知 bug。Apple 没有修复第三方 BLE 外设的这个问题，社区唯一通用的 workaround 就是手动 toggle 蓝牙。

## btresumed 做什么

一个小型原生守护进程，自动化手动 toggle——但仅在真正需要时才动作。**双层检测**保证可靠：

1. **CoreBluetooth 事件层（正常路径）**：通过 CBCentralManager 监听已 adopt 的 BLE 外设。收到断开事件 → 等 5 秒（给 macOS 自愈机会）→ 仍断 & 是 HID & 用户没关蓝牙 → toggle。
2. **Log stream watchdog（异常路径）**：某些情况下 CoreBluetooth 对卡在 762 loop 的外设**不给我们派发事件**。子进程用 `/usr/bin/log stream` 直接看 `bluetoothd` 的 762 错误日志，一出现立即 toggle，**<1 秒反应**。空闲零耗能（管道阻塞）。

Toggle 本身是 `IOBluetoothPreferenceSetControllerPowerState(0) → (1)`——和系统设置里蓝牙开关走的同一个私有 SPI。但这个 SPI 是**异步**的：固定 sleep 会让 off/on 被 stack 合并为 no-op。实现用 [blueutil](https://github.com/toy/blueutil) 的 canonical 模式：轮询 getter、强制最小 off-phase 时长、settle、再上电。连续失败时 off-phase 递进变长（3 秒 → 5 秒 → 8 秒）；HID 重连时计数归零。

设计原则：

- **事件驱动为主，watchdog 兜底**：响应真实 BLE 断连/连接事件；当 CB 失聪时用 bluetoothd 日志签名兜底。频繁合盖/开盖、短时睡眠不会触发不必要的 toggle。
- **无 shell 脚本，无第三方依赖**：纯原生 Objective-C，只用 Apple 系统 framework（包括通过 NSTask 调用 `/usr/bin/log`）。
- **保留配对信息**：只调电源 toggle SPI。配对 key 不受影响——双系统/多系统共享配对 key 的场景完全安全。
- **尊重用户意图**：如果用户主动关了蓝牙，守护进程什么都不做。
- **和 Linux/Windows 的重连速度持平**：典型恢复 ≤ 5 秒，从鼠标不响应到重新可用。

## 适合你吗？

**适合**：

- 你有一个 BLE 鼠标/键盘/触控板，macOS 睡眠唤醒后不自动重连
- 你验证过手动 toggle 蓝牙能解决
- 你想要一个一劳永逸的方案

**不适合**：

- 你的设备睡眠唤醒工作正常
- 你用的 macOS 版本比 Big Sur 还老（CoreBluetooth API 可能不同）
- 你在被管理的企业环境下，不允许运行后台 LaunchAgent

## 兼容性

- **实测环境**：macOS 14 (Sonoma) — Intel Hackintosh（Comet Lake + Intel AX201 蓝牙）。任何 Sonoma 或更新版本的 Mac / Hackintosh 应该都能用。
- **实测设备**：Microsoft Modern Mobile Mouse
- **应该适用**：任何"手动 toggle 蓝牙可以恢复连接"的 BLE HID 设备

## 安装

### 前置条件

- macOS 14+（推荐 Sonoma 或 Sequoia）
- Xcode Command Line Tools（`xcode-select --install`）
- 管理员权限（安装 LaunchAgent 需要）

### 一键安装

```bash
git clone https://github.com/DexterSLamb/btresumed.git
cd btresumed
sudo ./install.sh
```

然后：
1. macOS 会弹窗："btresumed" wants to use Bluetooth → 点击 **允许**
2. 可能还会在 **System Settings → 通用 → 登录项与扩展** 的"在后台允许"里看到一项——打开开关

完成。下次从睡眠唤醒、鼠标卡住时，守护进程会在 5 秒后静默 toggle 蓝牙，你的鼠标会自动连回。

### 手动安装

```bash
make
sudo make install
```

### 验证

```bash
launchctl print gui/$(id -u)/com.user.btresumed
tail -f ~/Library/Logs/btresumed.log
```

启动正常的话 log 应该长这样：

```
btresumed starting (pid=...)
CBCentralManager created, waiting for state update...
CB state: PoweredOn
found 1 connected BLE peripheral(s)
adopt: ... (Modern Mobile Mouse) state=0
connect: ... (Modern Mobile Mouse)
classified HID-like: ... (Modern Mobile Mouse)
```

## 工作原理（架构）

```
┌─────────────────┐       ┌──────────────────┐      ┌─────────────────────────┐
│ CBCentralManager│──────▶│                  │─────▶│ IOBluetoothPreference   │
│  (BLE 事件)     │       │                  │      │ SetControllerPowerState │
├─────────────────┤       │  BTResumed       │      │  (Settings 的私有 SPI)  │
│ /usr/bin/log    │──────▶│                  │      └─────────────────────────┘
│  stream (762)   │       │  • HID 分类       │
└─────────────────┘       │  • 防抖           │
  watchdog NSTask         │  • poll + settle  │
                          │  • 渐进 off-phase │
                          └──────────────────┘
```

核心实现要点：

- **设备发现**：用 `retrieveConnectedPeripheralsWithServices:` + GAP (0x1800) 枚举当前已连接的所有 BLE 外设（GAP 是每个 BLE 设备的强制服务）。新配对的设备通过 60 秒定期 rescan 发现。
- **持久化追踪**：已分类为 HID 的 peripheral UUID 写入 `~/Library/Application Support/btresumed/hids.plist`。CB PoweredOn 时通过 `retrievePeripheralsWithIdentifiers:` 恢复追踪——**即使 peripheral 当前没连**也能拿回 CBPeripheral 对象。Apple 官方推荐的跨会话观察模式。
- **HID 识别**：Apple 的 CoreBluetooth **对第三方 CB 客户端隐藏了标准 HID 服务（0x1812）**，出于隐私考虑。所以守护进程退回到 **设备名关键字匹配**（`mouse`, `keyboard`, `trackpad`, `magic`, `mx`, `k380` 等）。如果你的设备名很特别，修改源码里的 `nameLooksLikeHID()` 加上对应关键字即可。
- **Log-stream watchdog**：子进程跑 `log stream --predicate 'process == "bluetoothd" AND eventMessage CONTAINS "reason 762"'`。一匹配到对应日志行就立即 toggle，毫秒级反应。子进程意外退出会自动重启。
- **Toggle（poll + 渐进 off-phase）**：`SetPowerState(0)` → 轮询 `GetPowerState()` 直到报 0 → **强制最小 off-phase 时长** → `SetPowerState(1)` → 轮询直到报 1。Off-phase 最小从 3 秒起，连续失败时递增到 5 秒、8 秒（HID 重连或 60 秒空闲时计数归零）。这是 [blueutil 的 canonical 模式](https://github.com/toy/blueutil)——固定 sleep 会让 SPI 的 off/on 被 stack 合并为 no-op。
- **断连处理**：`didDisconnectPeripheral:` 在 `_pending[peripheral.identifier]` 存一个时间戳 ticket。5 秒后 `dispatch_after` 检查 peripheral 是否已重连（重连时 `didConnectPeripheral:` 会清掉 ticket）——如果没重连就 evaluate → toggle。
- **防抖**：两次 toggle 之间至少 5 秒；60 秒空闲后重置连续失败计数。
- **尊重用户电源意图**：如果用户主动关了蓝牙（`IOBluetoothPreferenceGetControllerPowerState() == 0`），守护进程保持静默。
- **PoweredOff→PoweredOn 转换**：清除 stale pending 检查（它们是蓝牙被 toggle 关掉时产生的"假故障"，不是真问题）。

## 日志

所有活动都写到 `~/Library/Logs/btresumed.log`：

```
[时间戳] disconnect: <uuid> (Mouse) err=(no error), check in 5s
[时间戳+5s] check: ... still disconnected → toggle BT
[时间戳+5s] toggle complete
```

或者自愈场景：

```
[时间戳] disconnect: <uuid> (Mouse) ...
[时间戳+2s] connect: <uuid> (Mouse)
[时间戳+2s]   pending check canceled (natural recovery)
```

## 排错

**守护进程启动了，唤醒时没反应**

看 `~/Library/Logs/btresumed.log`。如果出现 `CB state: Unauthorized`——到 System Settings → 隐私与安全性 → 蓝牙 里允许 btresumed。

**设备被分类为 `non-HID`，但它其实是 HID 设备**

名字匹配没命中。编辑 `btresumed.m` 里的 `nameLooksLikeHID()`，加上你设备名的关键字或特征子串，然后重新编译。

**守护进程被 kill 了或者退出了**

`tail -n 50 ~/Library/Logs/btresumed.log` — 看错误行。`launchctl print gui/$(id -u)/com.user.btresumed` 看运行时状态。

**Toggle 发出了但鼠标还是不重连**

- 检查电池：没电的鼠标 toggle 多少次都连不上
- 重新配对（最后手段）。这会改变配对 key，多系统共享 key 的环境需要重新同步。

**重新编译二进制后 TCC 反复要求授权**

未签名的二进制每次重编 content hash 变，TCC 条目失效。要么不再重编，要么做 ad-hoc 签名固化 cdhash：`codesign --force --sign - --identifier com.user.btresumed btresumed`（注意：ad-hoc 签名**不会消除**"身份不明开发者"警告，但能稳定 cdhash 让 TCC 授权不再失效）。

## 局限

- **需要蓝牙权限 (TCC)**：LaunchAgent 跑在用户会话下，CoreBluetooth 需要标准的"隐私与安全性 → 蓝牙"权限。首次启动一键通过。
- **未做代码签名**：从源码编的，在"登录项"里会显示为"身份不明的开发者"。功能上无害。要消除这个标识，需要付费 Apple Developer ID。
- **HID 分类靠名字启发式**：覆盖了主流厂商（Microsoft、Apple、Logitech、Razer 等），但可能漏掉命名特别的设备。
- **CoreBluetooth 隐藏 HID 服务**：我们无法用 0x1812 服务 UUID 来做分类，因为 Apple 对第三方 CB 客户端限制了这个服务。
- **仅 macOS**：使用 Apple 专有 IOBluetooth SPI。

## 相关项目

- [Bluesnooze](https://github.com/odlp/bluesnooze) — 类似思路，但是**无条件** toggle（没有事件过滤和 HID 分类）
- [blueutil](https://github.com/toy/blueutil) — CLI 蓝牙工具，经常配合 SleepWatcher 脚本使用
- [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware) — Hackintosh 上给 Intel AX2xx 蓝牙用的 kext（btresumed 是用户空间补充，不是替代）

## License

MIT。见 [LICENSE](LICENSE)。

## 贡献

欢迎 PR，特别是：

- 为 HID 分类添加新的设备名关键字
- 在不同 macOS 版本上测试
- 在不同 BLE 外设上测试
