# AMap Signal Countdown（自用 rootless tweak）

**当前版本 1.0.17 = 已验证可用的 1.0.10 行为的精确回滚。** 中间版本（1.0.11–1.0.16）尝试过的额外 hook（气泡数据 setter `0x1209DDC` 等）已全部撤除，只保留最初确认可用的三个 hook：信号状态序列化（`0x788410`）、汽车记录（`0x11FF8C0`）、骑行相位 wrapper（`0x840490`）。叶子函数 `0x840548` 保持不挂（闪退根因）。

适用环境：

- iOS 16.x / arm64
- Dopamine rootless + ElleKit
- 高德地图 `com.autonavi.amap` **16.11.1**
- 已验证汽车导航与自行车导航

> 本项目使用高德 `16.11.1` 主程序的版本专用本地偏移。升级或降级高德后不要继续使用，必须重新核对偏移并构建。

## 功能与边界

插件只读取高德进程中已经存在的原生红绿灯状态和相位时间表，HUD 为悬浮球形态：

- 启动后是一个可拖动的悬浮球（默认在右上角）；
- 导航中自动获取倒计时：球体颜色即灯色（绿/黄/红），球内显示剩余秒数；
- 无数据时球为灰色并显示 "-"；
- 单击悬浮球展开为全屏倒计时牌：数字充满屏幕、颜色即灯色，再次单击返回悬浮球；
- 没有倒计时数据时点击悬浮球不进入全屏（避免误触）；
- 全屏数字随高德 app 的屏幕方向自适应（横竖屏均铺满）。

自行车倒计时通过相位评估 wrapper（`0x840490`，标准函数序言与 ABI）读取同一份相位 vector。相位表的 start/end 是绝对纪元秒，与本机时钟同源，因此区间匹配使用本机时钟（wrapper 自身的时间参数是相对量，探针实测为 34）。wrapper 只在信号灯气泡激活期间刷新（实测约每 10 秒一次，骑过当前灯后停止，接近下一个灯时恢复）。每次推送会把整张相位表（约 6 分钟周期）存入 seqlock 快照，HUD 每秒在本地表中走格，连续跟随绿→黄→红→绿整个周期；黄灯按绿灯与红灯之间约 3 秒的间隔显示。灯与灯之间没有当前灯数据时显示等待，与高德自身气泡的消失一致。崩溃根因是叶子函数 `0x840548` 入口含早期条件跳转，ElleKit trampoline 重定位出错，因此该叶子本身保持不挂 hook。骑行倒计时没有 OC 属性/方法可用（相关键名是 AJX/JS 桥的 JSON 字段）。

### 关于距离

本版不显示“距该信号灯还有多少米”。对高德 16.11.1 自行车原生模型的核对结果是：`trafficLightInfo` 中能确认的是经纬度、`linkID`、灯态/相位；没有确认到实时距离标量。`trafficlight_display_distance` 是默认约 500 的显示/搜索阈值，不是当前距离。把路线进度、坐标或该阈值换算成米都会变成自行推算，因此没有接入。

插件明确**不做**以下事情：

- 不使用 OCR 或截图识别；
- 不调用、抓取或解密高德私有网络接口；
- 不读取 Core Location、骑行速度，也不自行推算或显示路口距离；
- 不提供加速、减速、抢灯或其他骑行建议；
- 不进行视图树扫描或全进程内存扫描。

HUD 仅供参考，不能代替现场交通信号灯。

## 构建

无需 Theos：

```sh
cd /private/var/root/Library/mydsh/amap-cycle-assist
make clean
make package
```

产物：

```text
build/com.dsh.amapcycleassist_1.0.17_iphoneos-arm64.deb
```

## 安装

```sh
dpkg -i /private/var/root/Library/mydsh/amap-cycle-assist/build/com.dsh.amapcycleassist_1.0.17_iphoneos-arm64.deb
killall -9 AMapiPhone 2>/dev/null || true
```

重新打开高德并开始汽车或自行车导航。高德自身提供该路口倒计时后，顶部 HUD 才会出现相应数据。请先在静止、安全环境中验证至少一个完整红绿灯周期。

## 日志

简要日志位于高德数据容器：

```text
tmp/amap-signal-countdown.log
```

可查找并查看：

```sh
log=$(ls -t /var/mobile/Containers/Data/Application/*/tmp/amap-signal-countdown.log 2>/dev/null | head -n1)
tail -n 50 "$log"
```

如果 HUD 一直显示“等待高德数据”，先确认高德当前界面本身已经显示该路口倒计时，并确认高德版本仍为 `16.11.1`。

## 卸载与故障恢复

```sh
dpkg -r com.dsh.amapcycleassist
killall -9 AMapiPhone 2>/dev/null || true
```

高德若无法启动，可在越狱安全模式下删除或改名：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.plist
```

## 安全提醒

倒计时可能因高德数据、本机调度或版本变化而延迟、缺失或错误。始终以现场信号灯、道路状况和交通规则为准；不要仅凭 HUD 通过路口。
