# 原生界面性能记录

测量日期：2026-10-10。Apple M5 Pro、15 个逻辑核心、48 GiB RAM、macOS 26.6、arm64，release 原生进程。主面板和设置页均已使用，真实 MP4 与 LRF 已核验，自动导入和登录启动开启。收起面板后，对同一 PID 每秒采样，连续 120 秒。

| 指标 | 实测 |
|---|---:|
| 物理 footprint 范围 | 33.77–33.83 MiB |
| 平均 CPU / 单核心 | 0.015535% |
| 1 秒间隔最高 CPU | 0.217970% |
| 累计 CPU 时间 | 18.643 ms |
| 内核生命周期 footprint 峰值 | 130.05 MiB |

[JSON 汇总](native-ui-idle.json)、[完整 CSV](native-ui-idle.csv)。内存以 MiB（1,048,576 字节）表示；CPU 100% 为一个逻辑核心。生命周期峰值包含采样前的启动、素材核验和 UI 操作，未定位到具体阶段，不能用空闲窗口证明导入过程始终低于 40 MiB。

监测器在应用外按需运行，不增加应用常驻定时器。复制及哈希按块释放临时缓冲；后台空闲预算为 footprint ≤40 MiB、平均 CPU ≤0.1% / 单核心，此次均通过。

## 复测

先从活动监视器获取 ActionImport 的 PID，在项目目录运行：

```sh
# 将 12345 换成实际 PID；使用新的输出文件名。
(set -o noclobber; zsh scripts/performance/monitor.sh 12345 120 1 idle.csv > idle.json)
```

CSV 和 JSON 都不会覆盖已有文件。监测器需用 Command Line Tools 编译，读取 macOS 的进程 CPU、RSS、footprint 和 wakeups。应用中的文件操作独立于 UI 线程。

这些数据来自单台机器、单次空闲窗口，不代表所有设备、完整 GUI 大文件导入峰值、数千素材批量、真实 USB 吞吐、功耗或长期无泄漏。
