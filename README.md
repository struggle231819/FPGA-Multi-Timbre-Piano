# 🎹 FPGA 多音色智能电子琴 (FPGA-Multi-Timbre-Piano)

**基于 Sipeed Tang Primer 25K (GW5A-25) 的 64 复音 12 音色全硬件 FM 与物理建模智能合成器**  
*A 64-Voice Polyphonic, 12-Timbre FM & Physical-Modeling Smart Electronic Piano Synthesizer in Pure Verilog HDL*

[![FPGA](https://img.shields.io/badge/FPGA-Gowin%20GW5A--LV25MG121NC1%2FI0-0066cc)](https://wiki.sipeed.com/hardware/zh/tang/tang-primer-25k/primer-25k.html)
[![Board](https://img.shields.io/badge/Board-Sipeed%20Tang%20Primer%2025K%20%2B%20Dock-ff6600)](https://wiki.sipeed.com/hardware/zh/tang/tang-primer-25k/primer-25k.html)
[![Toolchain](https://img.shields.io/badge/EDA-Gowin%20V1.9.12.04-2ea44f)](https://www.gowinsemi.com.cn/)
![Audio](https://img.shields.io/badge/Audio-48.828kHz%2024--bit%20True%20Stereo%20I2S-blueviolet)
![Author](https://img.shields.io/badge/Author-ges280388--hub-informational)
![License](https://img.shields.io/badge/License-MIT-brightgreen)

## 项目简介 (Overview)

**FPGA-Multi-Timbre-Piano（FPGA 多音色智能电子琴）** 是由 **ges280388-hub** 基于 **Sipeed Tang Primer 25K (`GW5A-LV25MG121NC1/I0`) + 25K Dock 底板** 纯 Verilog HDL 全硬件设计与实现的数字音乐合成工作站。

与传统依赖软核 MCU 或单音方波分频的简易 FPGA 电子琴不同，本项目采用 **6 级深度时分复用流水线 (6-Stage TDM Pipeline)**，在单颗高云 25K FPGA 上实现了 **64 复音齐鸣 (64-Voice Polyphony)**、**15-bit 线性插值高精度正弦合成 (SFDR > 92 dB)**、**12 种商业级乐器声学建模音色**、**11 白键铜箔电容隔空触键测速**、**实时多维和弦识别与自动伴奏引擎**、**24-bit 零底噪真立体声 DSP 空间效果器**、**2.4 寸彩屏实时频谱/李萨如示波器与触控 UI**，以及 **JDY-23 蓝牙盲插自适应串口编曲录音系统**。

## 核心技术亮点 (Key Highlights)

* **64 复音 6 拍流水线混合合成引擎 (`poly32_fm_synth.v`)**
  * **15-bit 线性插值正弦查找表**：采用 512 点基础正弦 ROM 配合 6-bit 小数线性内插（等效 32,768 点采样精度，无杂散动态范围 SFDR > 92 dB）。
  * **FM 调频 + 谐波声学物理建模**：内置 12 种乐器音色、独立双包络（载波/调制器 ADSR）、揉弦颤音 (Vibrato) 与连奏滑音 (Portamento)，支持 `-24 ~ +24` 半音（覆盖 C2 ~ C8）无损移调与 64 声部满负荷压力测试。
  * **母带级零数字底噪架构**：全链路采用向零对称舍入 (`shr_z`) 彻底消除 IIR 去直流与重构低通滤波器的 `-1` 极限环底噪；64 声部静默检测 (`voices_active`) 配合 PCM5102A 硬件静音门控及 PAM8403 24 dB 功放甜区对数音量曲线，在静默期达到 `0 LSB` 绝对静音。
* **超低底噪 24-bit 真立体声 DSP 空间效果器 (`audio.v`)**
  * 全速 `48.828 kHz / 24-bit` 采样处理（8192 深度 BSRAM 延迟线），彻底消除半采样率混叠啸叫。
  * 内置 **音乐厅混响 (Hall Reverb)**、**立体声乒乓延迟 (Stereo Delay)**、**宽广立体声合唱 (Stereo Chorus)** 与 **无 LFO 正交早期反射哈斯微立体声 (Haas Micro-Stereo)**。
  * 针对 12 种音色定制 2~3 套最佳空间效果搭配，切换音色时自动挂载最优声场参数。
* **独创 11 白键铜箔电容隔空测速 + 18 键独立轻触琴键 (`tang_primer_25k_synth_top.v`)**
  * 采用 **铜箔电容接近 (`t1`) + 机械开关触底 (`t2`) 双时间戳渡越时间测量法**，仅用单根 I/O 引脚配合 1MΩ 接地电阻与 1kΩ 串联电阻，即可为 11 个白键提供 `36 ~ 127` 连续 7-bit 触键力度感应（7 个黑键恒定力度 100）。
* **硬件级智能伴奏与速度跟随引擎 (`smart_accompaniment`)**
  * **实时多维和弦识别**：将 18 键状态折叠为 12 平均律音级向量 (Chroma Vector)，支持原位/转位大三 (Maj)、小三 (Min)、属七 (Dom7)、小七 (Min7)、挂四 (Sus4)、减三 (Dim) 和弦识别与单指智能配和弦，具备高八度旋律分离与抬键防抖锁存。
  * **自动低音 + 双八度分解和弦 + IOI 速度跟随**：实时测量演奏触键时间间隔 (Inter-Onset Interval, IOI)，经一阶 IIR 平滑滤波在 `66 ~ 200 BPM` 范围内无缝跟随演奏速度，起拍零延迟对齐强拍。
* **2.4 寸 ILI9341 彩屏实时示波器 + XPT2046 触控多页面工作站 (`ili9341_touch_ui.v`)**
  * 硬件 SPI (12.5 MHz) 驱动 `320×240 RGB565` 彩屏，提供 **手动演奏页、曲目点播页、智能伴奏页、音色效果页** 四大交互页面。
  * 内置 **实时频谱分析仪 (Spectrum)**、**立体声李萨如相位示波器 (Lissajous)**、跟弹键位高亮指引、触屏虚拟琴键及 **3 点十字准星触摸校准向导**。
* **JDY-23 蓝牙双引脚盲插容错与 80ms 实弹录音系统 (`bt_uart_bridge.v`)**
  * **TX/RX 正反接全自动识别**：`H5` 与 `J5` 双引脚自动侦测接收端并隔离发送驱动，硬件脉冲宽度自适应锁定 `9600 / 115200 bps` 波特率。
  * **内置名曲 ROM + 256 步 BSRAM 实弹录音**：内置 4 首经典示范曲（《天空之城》《卡农》《致爱丽丝》《欢乐颂》）+ 第 5 槽用户自定义曲目（支持 80ms 网格高精度实弹录音、录音蓝牙回传与手机端在线编曲下载）。

## 系统硬件架构图 (System Architecture)

```text
+---------------------------------------------------------------------------------------------------+
|                        Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)                        |
|                                                                                                   |
|  +-----------------------+     +----------------------------+     +----------------------------+  |
|  | 18x Tactile Keys      |---->|   key_encoder_input.v      |     |   smart_accompaniment.v    |  |
|  | 2x EC11 Encoders      |     | - 18-Key Debounce          |---->| - 12-Tone Chroma Folding   |  |
|  | Dock S1 / S2 Buttons  |     | - Dual EC11 Quadrature     |     | - Maj/Min/Dom7/Min7/Sus4   |  |
|  +-----------------------+     | - 4-Page UI State Machine  |     | - 2-Octave Arpeggiator     |  |
|                                +-------------+--------------+     | - Sub-Octave Bass Engine   |  |
|  +-----------------------+                   |                    | - IOI Tempo Tracker        |  |
|  | 11x White-Key Copper  |     +-------------v--------------+     +-------------+--------------+  |
|  | Foil Capacitive Pads  |---->|  Capacitive Velocity (t1/t2)|                  |                 |
|  +-----------------------+     |  7-bit Velocity (36..127)  |                  |                 |
|                                +-------------+--------------+                  |                 |
|  +-----------------------+                   |                                 |                 |
|  | JDY-23 BLE Module     |<--->|      bt_uart_bridge.v      |                  |                 |
|  | (H5/J5 Auto-Polarity) |     | - Auto-Baud (9600/115200)  |                  |                 |
|  +-----------------------+     | - 80ms Live Recorder BSRAM |                  |                 |
|                                +-------------+--------------+                  |                 |
|                                              |                                 |                 |
|                                              v                                 v                 |
|                           +-------------------------------------------------------+              |
|                           |                  poly32_fm_synth.v                    |              |
|                           |  - 64-Voice 6-Stage TDM Pipeline (@ 48.828 kHz)       |              |
|                           |  - 15-bit Linear Interpolated Sine LUT (SFDR > 92 dB) |              |
|                           |  - 12 Acoustic/FM Timbres + Dual ADSR + Vib/Glide     |              |
|                           |  - Round-Toward-Zero (shr_z) Zero-Noise Filter Chain  |              |
|                           +------------------+------------------------------------+              |
|                                              | 24-bit Mono Synth Stream                          |
|                                              v                                                   |
|  +-----------------------+     +--------------------------------------------------+              |
|  | 2.4" ILI9341 320x240  |<----|                  audio.v                         |              |
|  | SPI LCD + XPT2046 TP  |     |  - 48.828 kHz 24-bit True Stereo DSP Engine      |              |
|  | (ili9341_touch_ui.v)  |<--->|  - 8192-Sample BSRAM Delay Line                  |              |
|  | - Spectrum & Lissajous|     |  - Hall Reverb / Stereo Delay / Chorus / Haas    |              |
|  | - 3-Point Calibration |     +---------------------+----------------------------+              |
|  +-----------------------+                           | 24-bit Stereo L/R                         |
|                                                      v                                           |
|                                +--------------------------------------------------+              |
|                                |   PCM5102A Hi-Fi I2S Mastering Engine (Top)      |              |
|                                |  - 2x Soft-Knee Limiter + Auto-Zero Hardware Mute|              |
|                                +---------------------+----------------------------+              |
+------------------------------------------------------|--------------------------------------------+
                                                       v
                                     +----------------------------------+
                                     | PCM5102A 24-bit DAC -> PAM8403   |
                                     +----------------------------------+
```

## 仓库目录结构与模块说明 (Repository Structure)

```text
FPGA-Multi-Timbre-Piano/
├── README.md                          # 项目说明文档 (含架构图、引脚表、音色表与蓝牙协议)
├── LICENSE                            # MIT 开源许可证 (Copyright (c) 2026 ges280388-hub)
├── .gitignore                         # Gowin EDA 工程 Git 忽略规则
├── tang_primer_25k_synth.gprj         # Gowin EDA 标准工程文件
├── push_to_github.bat                 # Windows 一键 Git 初始化与推送脚本
├── push_to_github.sh                  # Linux / macOS 一键 Git 初始化与推送脚本
├── src/                               # Verilog RTL 核心源码与约束文件
│   ├── tang_primer_25k_synth_top.v    # 顶层模块 + 智能伴奏引擎 + 电容测速 + I2S 母带输出
│   ├── poly32_fm_synth.v              # 64 声部 6 级流水线 15-bit 插值 FM 与物理建模合成引擎
│   ├── audio.v                        # 24-bit 真立体声低底噪数字效果器 (混响/延迟/合唱/哈斯立体声)
│   ├── ili9341_touch_ui.v             # 2.4 寸 ILI9341 彩屏渲染引擎 + XPT2046 触控与 3 点校准
│   ├── bt_uart_bridge.v               # JDY-23 蓝牙双脚盲插自适应 + 80ms 实弹录音 + 指令解析器
│   ├── key_encoder_input.v            # 18 键消抖 + 双 EC11 编码器解码 + 四大模式状态机
│   ├── tang_primer_25k_full_synth.cst # 物理引脚约束文件 (Sipeed Tang Primer 25K + Dock)
│   └── tang_primer_25k_synth.sdc      # 50MHz 系统时钟时序约束文件
├── firmware/                          # 预编译固件 (可直接用 Gowin Programmer 烧录体验)
│   ├── tang_primer_25k_synth.fs       # Gowin 标准比特流文件 (.fs)
│   └── tang_primer_25k_synth.bin      # 二进制固件镜像 (.bin)
└── docs/
    └── pnr_resource_report.txt        # Gowin EDA 布局布线资源与时序分析报告
```

| RTL 源码文件 | 代码规模 | 核心职责与关键算法 |
| :--- | :---: | :--- |
| `src/tang_primer_25k_synth_top.v` | ~97 KB | 顶层时钟分发 (`48.828 kHz` 采样脉冲)、4 首内置名曲 ROM、12 音色专属效果预设表、11 白键铜箔电容 `t1/t2` 力度检测、硬件智能伴奏模块 (`smart_accompaniment`)、PCM5102A 软膝盖限幅与自动静音 I2S 输出 |
| `src/poly32_fm_synth.v` | ~69 KB | 64 声部 6 拍时分复用流水线、32-bit DDS 相位累加器 (`-24~+24` 半音无损移调)、512×15-bit 线性内插正弦引擎、12 音色谐波/FM 调制矩阵、向零舍入无极限环滤波器与 PAM8403 甜区对数音量表 |
| `src/ili9341_touch_ui.v` | ~196 KB | 2.4 寸 `320×240` RGB565 SPI 彩屏硬件图形加速渲染、四大交互页面、实时音频频谱柱状图与李萨如立体声相位轨迹、18 键触屏虚拟琴键、XPT2046 3 点仿射校准状态机 |
| `src/bt_uart_bridge.v` | ~63 KB | `H5/J5` 双引脚正反接自适应检测、脉冲宽度 `9600/115200 bps` 波特率自适应、256 步 BSRAM 曲库、80ms 网格实弹录音与蓝牙回传、全功能 ASCII 串口指令解析 |
| `src/key_encoder_input.v` | ~22 KB | 18 路轻触琴键独立硬件消抖、双路 EC11 正交旋转编码器四倍频鉴相与按键消抖、四大工作模式与子项切换控制 |
| `src/audio.v` | ~20 KB | 8192 深度 24-bit 全速立体声延迟线、音乐厅混响反馈网络、立体声合唱调制、哈斯微立体声正交早期反射与静默死区自动归零门控 |

## 硬件物料清单与引脚分配 (Hardware BOM & Pinout)

### 硬件组成清单 (BOM)

* **FPGA 核心板与底板**：Sipeed Tang Primer 25K 核心板 (`GW5A-LV25MG121NC1/I0`) + 25K Dock 底板
* **显示与触控模块**：2.4 寸 14P SPI 彩屏模块（驱动芯片 `ILI9341` 分辨率 `320×240`，电阻触摸芯片 `XPT2046`）
* **数字音频与功放**：`PCM5102A` 24-bit 立体声 I2S DAC 模块 + `PAM8403` 双声道立体声 D 类功放 + 立体声扬声器
* **无线通信模块**：`JDY-23` 蓝牙 BLE 串口透传模块（支持手机端 *Serial Bluetooth Terminal* 控制）
* **交互输入外设**：18 个独立轻触按键（对应 `C4 ~ F5`）、11 片白键铜箔感应贴片（各经 `1MΩ` 电阻接地、串 `1kΩ` 电阻接 FPGA）、2 个 `EC11` 带按键旋转编码器

### 完整引脚分配表 (59 I/O Pins, `LVCMOS33`)

| 外设模块 | 信号名称 | FPGA 引脚 | 方向 / 上下拉 | 功能说明 |
| :--- | :--- | :--- | :--- | :--- |
| **系统时钟与状态灯** | `clk` | `E2` | Input (NONE) | 板载 50 MHz 有源晶振输入 |
| | `led` | `E8` | Output (DRIVE=8) | 核心板状态与节拍脉冲指示灯 |
| **Dock 板载按键** | `s1_key` | `H11` | Input (PULL_DOWN) | S1 键：循环切换四大工作模式；与 S2 同按进入触屏校准 |
| | `s2_key` | `H10` | Input (PULL_DOWN) | S2 键：切换当前页面子项（显示布局/曲目/伴奏节奏/效果搭配） |
| **2.4" ILI9341 彩屏** | `lcd_sck` | `L8` | Output (DRIVE=8) | LCD SPI 时钟 (12.5 MHz) |
| **(320×240 RGB565)** | `lcd_sdi` | `J7` | Output (DRIVE=8) | LCD SPI MOSI 数据输出 |
| | `lcd_dc` | `H2` | Output (DRIVE=8) | LCD 数据/命令选择 (`0`=命令, `1`=数据) |
| | `lcd_reset` | `G10` | Output (DRIVE=8) | LCD 硬件低电平复位 |
| | `lcd_cs` | `G11` | Output (DRIVE=8) | LCD 片选（低有效） |
| **XPT2046 电阻触摸** | `tp_irq` | `J10` | Input (PULL_UP) | 触摸笔中断（低有效） |
| | `tp_do` | `F6` | Input (PULL_UP) | 触摸 SPI MISO 数据输入 |
| | `tp_din` | `K8` | Output (DRIVE=8) | 触摸 SPI MOSI 控制字输出 |
| | `tp_cs` | `K9` | Output (DRIVE=8) | 触摸片选（低有效） |
| | `tp_clk` | `K10` | Output (DRIVE=8) | 触摸 SPI 时钟输出 |
| **PCM5102A 立体声 DAC** | `pcm_bck` | `L5` | Output (DRIVE=4) | I2S 位时钟 (3.125 MHz) |
| **(后级接 PAM8403)** | `pcm_lck` | `E10` | Output (DRIVE=4) | I2S 左右声道时钟 (48.828 kHz) |
| | `pcm_din` | `A10` | Output (DRIVE=4) | 24-bit 立体声 I2S 串行数据 |
| | `pcm_flt` | `A11` | Output (DRIVE=4) | 固定 `0`（FIR 正常延迟滤波） |
| | `pcm_dmp` | `E11` | Output (DRIVE=4) | 固定 `1`（开启高频去加重，抑制 D 类功放高频底噪） |
| | `pcm_scl` | `K11` | Output (DRIVE=4) | 固定 `0`（启用 PCM5102A 内部锁相环生钟） |
| | `pcm_fmt` | `L11` | Output (DRIVE=4) | 固定 `0`（标准 Philips I2S 格式） |
| | `pcm_xmt` | `K5` | Output (DRIVE=4) | 硬件静音控制（发声高电平，静默 0.5s 后置低进入零底噪静音） |
| **JDY-23 蓝牙 BLE** | `bt_rx` / `bt_tx` | `H5`, `J5` | Inout (PULL_UP) | 双脚正反接自适应双向收发，自动兼容 9600 / 115200 波特率 |
| **双路 EC11 编码器** | `enc1_a`, `enc1_b`, `enc1_sw_n` | `F5`, `G7`, `H8` | Input (PULL_UP) | 编码器 1：旋转调节 16 级主音量（默认 8 档）；按压等效 S1 切屏 |
| | `enc2_a`, `enc2_b`, `enc2_sw_n` | `G5`, `G8`, `H7` | Input (PULL_UP) | 编码器 2：旋转切换 12 种乐器音色；按压等效 S2 切换页面子项 |
| **18 键轻触琴键** | `keys_raw_n[17:0]` | `J11, F7, J8, L9, L10, L7, K7, H1, G4, J1, E3, E1, F2, L4, G2, J4, L2, K1` | Input (PULL_UP) | 对应 `C4 ~ F5` 共 18 个半音（按下接地低有效） |
| **11 白键铜箔测速** | `vel_io[10:0]` | `H4, J2, D1, A1, F1, C2, L3, G1, K4, L1, K2` | Inout (DRIVE=4) | 对应 `C4, D4, E4, F4, G4, A4, B4, C5, D5, E5, F5`（各串 1kΩ 接铜箔，铜箔经 1MΩ 接地） |

## 12 种精选音色与专属空间效果搭配 (12 Timbres & DSP Presets)

系统为每种乐器音色定制了声学物理参数与 2~3 套最佳效果器组合（可在【音色效果页】按 `S2` / 编码器 2 按键 / 触屏卡片 / 蓝牙 `E` 指令切换）：

| 编号 | 音色名称 | 适配空间效果模块 | 预设搭配 01 (默认最优) | 预设搭配 02 | 预设搭配 03 |
| :---: | :--- | :--- | :--- | :--- | :--- |
| `00` | **三角钢琴 (Grand Piano)** | 混响 | 混响开启 (Lv.7) | 原声模式 (哈斯立体声) | — |
| `01` | **经典电钢 (Electric Piano)** | 混响 + 合唱 | 混响合唱 (Lv.8) | 合唱开启 (Lv.9) | 颤音混响 (Lv.7 + Vib) |
| `02` | **水晶八音 (Crystal Music Box)** | 混响 + 延迟 | 混响开启 (Lv.9) | 混响延迟 (Lv.8) | — |
| `03` | **教堂风琴 (Church Organ)** | 混响 + 合唱 | 混响合唱 (Lv.10) | 混响开启 (Lv.11) | — |
| `04` | **古典吉他 (Classical Guitar)** | 混响 + 指板滑音 | 混响开启 (Lv.7) | 滑音混响 (Lv.7 + Glide) | 原声模式 |
| `05` | **交响弦乐 (Symphonic Strings)** | 混响 + 合唱 + 揉弦颤音 | 颤音混唱 (Lv.9 + Vib) | 混响合唱 (Lv.9) | 混响开启 (Lv.8 + Vib) |
| `06` | **空灵长笛 (Ethereal Flute)** | 混响 + 延迟 + 气息颤/滑音 | 颤音混响 (Lv.8 + Vib) | 混响延迟 (Lv.8 + Vib) | 滑音颤音 (Lv.8 + Vib + Glide) |
| `07` | **木管单簧 (Clarinet)** | 混响 + 柔和颤音 | 颤音混响 (Lv.7 + Vib) | 原声模式 | — |
| `08` | **辉煌铜管 (Warm Brass)** | 混响 + 合唱 | 混响开启 (Lv.8) | 混响合唱 (Lv.8 + Vib) | — |
| `09` | **木琴马林 (Marimba)** | 混响 + 哈斯立体声 | 混响开启 (Lv.5) | 原声模式 (哈斯微立体声) | — |
| `10` | **重低贝司 (Electric Bass)** | 合唱 + 哈斯立体声 | 原声模式 (扎实低音) | 合唱开启 (宽广电贝司) | — |
| `11` | **合成主音 (Synth Lead)** | 混响 + 延迟 + 合唱 + 滑/颤音 | 混响合唱 (Lv.9) | 滑音延迟 (Lv.9 + Vib + Glide) | 效果全开 (Rev+Dly+Cho+Vib+Glide) |

## 四大工作模式与内置曲目 / 智能伴奏 (Operating Modes)

1. **`[0] 手动演奏页`**：支持 18 键物理键盘（含 11 白键电容测速）、触屏虚拟键盘与蓝牙实时弹奏；按 `S2` 切换 **分屏频谱+李萨如 / 全屏李萨如 / 全宽频谱** 三种可视化仪表盘。
2. **`[1] 曲目点播页`**：内置 4 首 64 步经典名曲 ROM + 1 首 256 步用户曲目 RAM，支持跟弹键位高亮指引：
   * `Song 0`：《天空之城》(240 ms/拍)
   * `Song 1`：《卡农》(260 ms/拍)
   * `Song 2`：《致爱丽丝》(190 ms/拍)
   * `Song 3`：《欢乐颂》(270 ms/拍)
   * `Song 4`：用户自定义曲目（80 ms 高精度实弹录音 / 蓝牙下载曲目）
3. **`[2] 智能伴奏页`**：支持多指原位/转位和弦识别、单指智能配和弦与 `66 ~ 200 BPM` 触键速度自适应跟随，按 `S2` 切换节奏型：
   * `Mode 0`：关闭伴奏 (`OFF`)
   * `Mode 1`：**抒情分解** (4/4 Ballad Arpeggio，`1-5-8-3-5-8-5-3` 流水分解 + 根五持续低音)
   * `Mode 2`：**流行律动** (4/4 Pop Bounce，`1-5-1-5` 跳跃低音 + 后拍双音切分伴奏)
   * `Mode 3`：**华尔兹拍** (3/4 Waltz，三拍子“强-弱-弱”根五五低音 + 双音柱式伴奏)
   * `Mode 4`：**动感八拍** (4/4 Driving 8-Beat，`1-1-3-3-5-5-6-5` 行走贝司 + 波浪分解和弦)
4. **`[3] 音色效果页`**：直观查看当前音色与空间效果器状态，一键切换该音色专属的 2~3 套最佳效果预设。

## 蓝牙串口指令速查表 (Bluetooth UART Protocol)

通过手机 APP（如 *Serial Bluetooth Terminal*）连接 `JDY-23` 蓝牙模块即可发送 ASCII 指令控制（兼容十进制/十六进制与换行符）：

| 指令分类 | 指令格式 | 功能说明与示例 |
| :--- | :--- | :--- |
| **模式与场景** | `A0` ~ `A3` / `A+` | 切换四大页面：`A0`=手动演奏, `A1`=曲目点播, `A2`=智能伴奏, `A3`=音色效果, `A+`=循环下一模式 |
| **曲目点播** | `M0` ~ `M4`, `P`, `S` | `M0`~`M3` 播放内置名曲 1~4；`M4` 或 `P` 播放用户录音/下载曲目；`S` 停止自动演奏 |
| **音色切换** | `T0` ~ `T11` (`TB`), `T+`, `T-` | 直接指定 `00~11` 号音色（如 `T0`=三角钢琴, `T5`=交响弦乐），或 `T+`/`T-` 前后切换 |
| **音量控制** | `V0` ~ `V15` (`VF`), `V+`, `V-` | 直接设置 `0~15` 级音量（开机默认 `V8`），或 `V+`/`V-` 步进增减 |
| **空间效果** | `E0` ~ `E3`, `E8`~`EA`, `EB` | `E0`=关效果, `E1`~`E3`=切换预设搭配 1~3, `E8`=合唱开关, `E9`=延迟开关, `EA`=混响开关, `EB`=下一搭配 |
| **湿声与表现力** | `F0`~`FF`, `Y1`/`Y0`, `Z1`/`Z0` | `F0`~`F15` 调节效果器湿声浓度；`Y1`/`Y0` 开关揉弦颤音；`Z1`/`Z0` 开关连奏滑音 |
| **智能伴奏** | `B0` ~ `B5`, `B6` ~ `B9` | `B0`=关闭, `B1`=抒情分解, `B2`=流行律动, `B3`=华尔兹, `B4`=动感八拍, `B5`=下一节奏；`B6`~`B9`=90/110/130/150 BPM |
| **移调控制** | `Q+n`, `Q-n`, `Q+`, `Q-`, `QC`~`QB` | 支持 `-24 ~ +24` 半音移调（如 `Q+2`, `Q-12`, `Q0` 复位）及调号直选（`QC`, `QD`, `QF#`, `QBb` 等） |
| **示波器布局** | `C0` ~ `C3` | `C0`=分屏频谱+李萨如, `C1`=全屏李萨如, `C2`=全宽频谱, `C3`=循环切换 |
| **实弹录音/下载** | `R`, `D` / `W...` | 支持 80ms 网格高精度实弹录音、录音数据蓝牙回传以及手机端 256 步曲谱下载 |
| **满复音测试** | `X1`, `X0` | `X1` 开启 64 声部齐鸣压力测试音，`X0` 关闭测试音 |

## FPGA 资源占用 (Resource Utilization)

综合与布局布线基于 **Gowin EDA V1.9.12.04 (64-bit)**，目标器件 `GW5A-LV25MG121NC1/I0`：

| 资源类型 (Resource) | 使用量 / 总量 (Usage) | 占用率 (Utilization) | 备注 |
| :--- | :---: | :---: | :--- |
| **Logic (LUT / ALU)** | `17,905 / 23,040` | **78%** | 13,950 LUT + 3,955 ALU |
| **Register (FF)** | `5,167 / 23,280` | **23%** | 5,133 Logic FF + 34 I/O FF（0 Latch） |
| **CLS (Configurable Logic Slice)** | `9,983 / 11,520` | **87%** | 高密度流水线复用 |
| **BSRAM (Block SRAM)** | `47 / 56` | **84%** | 41 SDPB + 5 pROM + 1 pROMX9（含 8192 深度立体声延迟线与曲库） |
| **DSP Slices** | `22 / 28` | **79%** | 4 × MULT12X12 + 20 × MULTALU27X18 |
| **I/O Ports** | `59 / 86` | **69%** | 29 Input + 17 Output + 13 Inout |

## 快速开始：编译与烧录 (Build & Flash)

### 方式一：直接烧录预编译固件（最快体验）

1. 将 **Tang Primer 25K** 核心板安装至 Dock 底板，连接 USB 调试/烧录接口。
2. 打开 **Gowin Programmer (云源烧录工具)**。
3. 选择本仓库 `firmware/tang_primer_25k_synth.fs` 比特流文件，烧录至 SRAM 或外部 Flash 即可运行。

### 方式二：从源码重新综合编译

1. 使用 **Gowin EDA V1.9.12.04**（或兼容版本）打开根目录下的 `tang_primer_25k_synth.gprj`。
2. 在左侧 Design 窗口确认 `src/` 下 6 个 `.v` 源码文件、`tang_primer_25k_full_synth.cst` 与 `tang_primer_25k_synth.sdc` 已加载。
3. 依次双击运行 **Synthesize (综合)** 与 **Place & Route (布局布线)**，生成新的 `.fs` 固件。

## 触摸屏 3 点校准说明 (Touch Calibration)

首次上电或更换屏幕后，同时按住 **Dock 底板 `S1 + S2` 按键**（或同时按住 **两个旋转编码器按键 `ENC1_SW + ENC2_SW`**），彩屏将进入 **3 点十字准星校准向导**。依次点击左上、右下、中心三个校准靶心即可完成高精度仿射坐标标定。

## 开源协议与作者 (Author & License)

* **作者 (Author)**：[ges280388-hub](https://github.com/ges280388-hub)
* **开源协议 (License)**：本项目基于 MIT License 开源，版权所有 `Copyright (c) 2026 ges280388-hub`，欢迎 Star、Fork 与二次开发交流。

