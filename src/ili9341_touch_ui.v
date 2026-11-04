// =============================================================================
// 文件名: ili9341_touch_ui.v 
// 适用平台: Sipeed Tang Primer 25K (GW5A-LV25MG121NC1/I0) + 25K Dock 底板
// 硬件接线 (严格对应 14P SPI 触摸屏接线表):
//   #1  T_IRQ  -> Pin J10 (触摸笔中断, 低电平有效, FPGA 内部上拉)
//   #2  T_DO   -> Pin F6  (触摸 SPI MISO 数据输入, FPGA 内部上拉)
//   #3  T_DIN  -> Pin K8  (触摸 SPI MOSI 控制字输出)
//   #4  T_CS   -> Pin K9  (触摸片选, 低电平有效)
//   #5  T_CLK  -> Pin K10 (触摸 SPI 时钟输出)
//   #6  MISO   -> 悬空不接
//   #7  LED    -> 3.3V
//   #8  SCK    -> Pin L8  (LCD SPI 时钟输出, 12.5MHz)
//   #9  MOSI   -> Pin J7  (LCD SPI MOSI 像素/指令输出)
//   #10 DC     -> Pin H2  (LCD 数据/命令选择: 0=命令, 1=数据)
//   #11 RESET  -> Pin G10 (LCD 硬件复位, 低电平有效)
//   #12 CS     -> Pin G11 (LCD 片选, 低电平有效)
//   #13 GND    -> GND
//   #14 VCC    -> 3.3V
// =============================================================================

module ili9341_touch_ui #(
    parameter [20:0] HW_RST_LOW_TICKS  = 21'd1_000_000, // 20ms 硬件低电平复位 (@50MHz)
    parameter [22:0] HW_RST_WAIT_TICKS = 23'd6_000_000  // 120ms 复位/退出休眠等待 (@50MHz)
) (
    input  wire               clk,              // 50MHz 系统主时钟
    input  wire               rst_n,            // 低电平有效同步复位
    input  wire               sample_tick,      // 48.828kHz 音频采样脉冲
    input  wire signed [15:0] mono_sample,      // 合成器单声道混音采样
    input  wire [17:0]        key_state,        // 18 个琴键当前状态
    input  wire [3:0]         volume,           // 主音量 0~15
    input  wire [3:0]         timbre_idx,       // 12 种精选音色编号 0~11
    input  wire               vibrato_en,       // 颤音生效状态
    input  wire               portamento_en,    // 滑音生效状态
    input  wire [17:0]        guide_keys,       // 下一拍跟弹指引掩码
    input  wire               guide_en,         // 跟弹指引有效
    input  wire               rec_active,       // 实弹录音进行中
    input  wire [1:0]         disp_mode,        // 0=同屏仪表盘, 1=全屏李萨如, 2=全宽频谱
    input  wire [17:0]        acc_vis_keys,     // 智能伴奏实时触发音符掩码
    input  wire               acc_beat_pulse,   // 智能伴奏节拍脉冲
    input  wire [1:0]         sys_mode,         // 系统四大模式: 0=手动, 1=曲目, 2=伴奏, 3=效果
    input  wire [1:0]         preset_idx,       // 当前音色效果搭配编号 0~2
    input  wire [3:0]         preset_code,      // 当前音色效果搭配名称编码 0~11
    input  wire [2:0]         fx_allow_mask,    // 当前音色允许的效果器掩码 {rev, dly, cho}
    input  wire               auto_play_en,     // 自动播放开启状态
    input  wire [2:0]         song_idx,         // 当前曲目编号 0~4
    input  wire [2:0]         fx_sel,           // 当前激活效果器 {rev, dly, cho}
    input  wire [2:0]         acc_mode,         // 当前伴奏模式 0=关, 1~4=四种节奏型
    input  wire               acc_active,       // 伴奏正在发声
    input  wire [3:0]         det_root,         // 识别到的和弦根音 0~11
    input  wire [2:0]         det_chord_type,   // 识别到的和弦类型 0~5
    input  wire [2:0]         rhythm_step,      // 伴奏当前步进 0~7
    input  wire               cal_trig_btn,     // S1+S2 同时按或长按触发 3 点触摸校准
    input  wire [6:0]         last_vel,         // 最新触发琴键的 7-bit 力度 (36..127)
    input  wire signed [5:0]  transpose_semi,   // 蓝牙自定义移调半音偏移 (-24..+24)
    // ---- 触摸控制输出脉冲 (与物理按键/编码器/蓝牙指令无缝并联) ----
    output reg                tp_timbre_vld,    // 触摸直接选音色脉冲
    output reg  [3:0]         tp_timbre,        // 触摸选中的音色编号 0~11 (12=音色+1, 13=音色-1)
    output reg                tp_vol_step_vld,  // 触摸调节音量步进脉冲
    output reg                tp_vol_up,        // 1=音量+1, 0=音量-1
    output reg                tp_acc_vld,       // 触摸切换智能伴奏模式脉冲
    output reg  [2:0]         tp_acc_mode,      // 0=关闭伴奏, 1~4=四种节奏型, 5=循环下一节奏型
    output reg                tp_tempo_vld,     // 触摸切换伴奏速度预设脉冲
    output reg  [1:0]         tp_tempo_idx,     // 0=90BPM, 1=110BPM, 2=130BPM, 3=150BPM
    output reg                tp_song_vld,      // 触摸点播曲目脉冲
    output reg  [2:0]         tp_song_idx,      // 点播的曲目编号 0~4 (5=切下一首)
    output reg                tp_stop,          // 触摸停止自动播放脉冲
    output reg                tp_scene_vld,     // 触摸切换四大系统模式脉冲
    output reg  [2:0]         tp_scene,         // 0~3=指定模式, 4=循环下一模式
    output reg                tp_fx_step_stb,   // 触摸循环切换当前音色最佳效果搭配脉冲
    output reg                tp_fx_vld,        // 触摸独立开关混响/合唱/延迟脉冲
    output reg  [3:0]         tp_fx_sel,        // 0=原声, 8=切换合唱, 9=切换延迟, 10=切换混响
    output reg                tp_disp_step_stb, // 触摸切换频谱/李萨如视图模式脉冲
    output reg  [17:0]        tp_live_keys,     // 触摸屏 18 键虚拟琴键实时弹奏输出
    output wire [1:0]         active_page,      // 当前切屏页面编号 (0=手动演奏, 1=曲目点播, 2=智能伴奏, 3=音色效果)
    // ---- ILI9341 SPI 显示接口 ----
    output reg                lcd_sck,          // Pin L8  (SCK)
    output reg                lcd_sdi,          // Pin J7  (MOSI / SDI)
    output reg                lcd_dc,           // Pin H2  (DC)
    output reg                lcd_reset,        // Pin G10 (RESET)
    output reg                lcd_cs,           // Pin G11 (CS)
    // ---- XPT2046 SPI 电阻触摸接口 ----
    output reg                tp_clk,           // Pin K10 (T_CLK)
    output reg                tp_cs,            // Pin K9  (T_CS)
    output reg                tp_din,           // Pin K8  (T_DIN)
    input  wire               tp_do,            // Pin F6  (T_DO)
    input  wire               tp_irq            // Pin J10 (T_IRQ, 按下为低电平)
);

    // =========================================================================
    // 1. 8 频段实时频谱能量提取器
    // =========================================================================
    reg signed [15:0] lp1;
    reg signed [15:0] lp2;
    reg signed [15:0] lp3;

    wire signed [15:0] bp_low  = lp2 - lp3;
    wire signed [15:0] bp_mid  = lp1 - lp2;
    wire signed [15:0] bp_high = mono_sample - lp1;

    wire [15:0] abs_total = mono_sample[15] ? (-mono_sample) : mono_sample;
    wire [15:0] abs_low   = bp_low[15]      ? (-bp_low)      : bp_low;
    wire [15:0] abs_mid   = bp_mid[15]      ? (-bp_mid)      : bp_mid;
    wire [15:0] abs_high  = bp_high[15]     ? (-bp_high)     : bp_high;

    wire [4:0] e_tot  = (abs_total[14:10] > 5'd31) ? 5'd31 : abs_total[14:10];
    wire [4:0] e_low  = (abs_low[13:9]    > 5'd31) ? 5'd31 : abs_low[13:9];
    wire [4:0] e_mid  = (abs_mid[13:9]    > 5'd31) ? 5'd31 : abs_mid[13:9];
    wire [4:0] e_high = (abs_high[13:9]   > 5'd31) ? 5'd31 : abs_high[13:9];

    reg [4:0]  band0, band1, band2, band3, band4, band5, band6, band7;
    reg [4:0]  peak_energy;
    reg [17:0] key_hold_mask;
    reg [10:0] decay_cnt;

    wire [5:0] sum_e6 = {1'b0, e_tot[4:1]} + {1'b0, e_high[4:1]};

    always @(posedge clk) begin
        if (!rst_n) begin
            band0 <= 5'd0; band1 <= 5'd0; band2 <= 5'd0; band3 <= 5'd0;
            band4 <= 5'd0; band5 <= 5'd0; band6 <= 5'd0; band7 <= 5'd0;
            peak_energy   <= 5'd0;
            key_hold_mask <= 18'd0;
            decay_cnt     <= 11'd0;
            lp1 <= 16'sd0; lp2 <= 16'sd0; lp3 <= 16'sd0;
        end else if (sample_tick) begin
            lp1 <= lp1 + ((mono_sample - lp1) >>> 3);
            lp2 <= lp2 + ((lp1 - lp2) >>> 4);
            lp3 <= lp3 + ((lp2 - lp3) >>> 5);

            if (|key_state)
                key_hold_mask <= key_state;
            else if (e_tot == 5'd0)
                key_hold_mask <= 18'd0;

            decay_cnt <= decay_cnt + 11'd1;

            if (e_tot > peak_energy)
                peak_energy <= e_tot;
            else if (decay_cnt == 11'd0 && peak_energy > 5'd0)
                peak_energy <= peak_energy - 5'd1;

            if (|key_hold_mask[2:0]   && e_low  > band0) band0 <= e_low;
            else if (decay_cnt == 11'd0 && band0 > 5'd0) band0 <= band0 - 5'd1;

            if (|key_hold_mask[4:2]   && e_tot  > band1) band1 <= e_tot;
            else if (decay_cnt == 11'd0 && band1 > 5'd0) band1 <= band1 - 5'd1;

            if (|key_hold_mask[6:4]   && e_mid  > band2) band2 <= e_mid;
            else if (decay_cnt == 11'd0 && band2 > 5'd0) band2 <= band2 - 5'd1;

            if (|key_hold_mask[9:6]   && e_tot  > band3) band3 <= e_tot;
            else if (decay_cnt == 11'd0 && band3 > 5'd0) band3 <= band3 - 5'd1;

            if (|key_hold_mask[12:9]  && e_mid  > band4) band4 <= e_mid;
            else if (decay_cnt == 11'd0 && band4 > 5'd0) band4 <= band4 - 5'd1;

            if (|key_hold_mask[15:12] && e_tot  > band5) band5 <= e_tot;
            else if (decay_cnt == 11'd0 && band5 > 5'd0) band5 <= band5 - 5'd1;

            if ((|key_hold_mask[17:15] || e_mid > 5'd2) && sum_e6[4:0] > band6)
                band6 <= sum_e6[4:0];
            else if (decay_cnt == 11'd0 && band6 > 5'd0)
                band6 <= band6 - 5'd1;

            if (e_high > band7) band7 <= e_high;
            else if (decay_cnt == 11'd0 && band7 > 5'd0) band7 <= band7 - 5'd1;
        end
    end

    // =========================================================================
    // 2. 256 点正弦查找表与音程频率比分析器 (用于硬件李萨如示波器)
    // =========================================================================
    function signed [6:0] sin8_lut;
        input [7:0] ang;
        reg [6:0] u, m;
        reg signed [6:0] v;
        begin
            u = ang[6:0];
            m = u[6] ? (~u) : u;
            case (m[5:2])
                4'd0:  v = 7'sd0;   4'd1:  v = 7'sd3;   4'd2:  v = 7'sd6;   4'd3:  v = 7'sd9;
                4'd4:  v = 7'sd12;  4'd5:  v = 7'sd15;  4'd6:  v = 7'sd18;  4'd7:  v = 7'sd21;
                4'd8:  v = 7'sd23;  4'd9:  v = 7'sd25;  4'd10: v = 7'sd27;  4'd11: v = 7'sd29;
                4'd12: v = 7'sd30;  4'd13: v = 7'sd31;  4'd14: v = 7'sd32;  default: v = 7'sd32;
            endcase
            sin8_lut = ang[7] ? (-v) : v;
        end
    endfunction

    reg [4:0] low_note, high_note;
    reg [4:0] active_cnt;
    integer ki;
    always @(*) begin
        low_note   = 5'd0;
        high_note  = 5'd0;
        active_cnt = 5'd0;
        for (ki = 0; ki < 18; ki = ki + 1) begin
            if (key_hold_mask[ki]) begin
                if (active_cnt == 5'd0)
                    low_note = ki[4:0];
                high_note  = ki[4:0];
                active_cnt = active_cnt + 5'd1;
            end
        end
    end

    wire [4:0] note_diff = high_note - low_note;
    reg  [2:0] target_fx, target_fy;

    always @(*) begin
        if (active_cnt >= 5'd2) begin
            case (note_diff)
                5'd12:             begin target_fx = 3'd1; target_fy = 3'd2; end
                5'd7, 5'd14:       begin target_fx = 3'd2; target_fy = 3'd3; end
                5'd5, 5'd17:       begin target_fx = 3'd3; target_fy = 3'd4; end
                5'd4, 5'd9, 5'd16: begin target_fx = 3'd3; target_fy = 3'd5; end
                5'd3, 5'd8, 5'd15: begin target_fx = 3'd4; target_fy = 3'd5; end
                default:           begin target_fx = 3'd2; target_fy = 3'd5; end
            endcase
        end else if (active_cnt == 5'd1 || peak_energy > 5'd1) begin
            case (timbre_idx)
                4'd0:    begin target_fx = 3'd1; target_fy = 3'd2; end
                4'd1:    begin target_fx = 3'd2; target_fy = 3'd3; end
                4'd2:    begin target_fx = 3'd1; target_fy = 3'd4; end
                4'd3:    begin target_fx = 3'd3; target_fy = 3'd4; end
                4'd4:    begin target_fx = 3'd2; target_fy = 3'd5; end
                4'd5:    begin target_fx = 3'd1; target_fy = 3'd3; end
                4'd6:    begin target_fx = 3'd1; target_fy = 3'd3; end
                4'd7:    begin target_fx = 3'd2; target_fy = 3'd3; end
                4'd8:    begin target_fx = 3'd1; target_fy = 3'd4; end
                4'd9:    begin target_fx = 3'd3; target_fy = 3'd4; end
                4'd10:   begin target_fx = 3'd3; target_fy = 3'd5; end
                default: begin target_fx = 3'd1; target_fy = 3'd1; end
            endcase
        end else begin
            target_fx = 3'd1;
            target_fy = 3'd1;
        end
    end

    // =========================================================================
    // 3. 内置 126 个 16x16 中文/数字/和弦字模 ROM (自动映射为 2 块 BSRAM)
    // =========================================================================
    function [7:0] glyph_rom_fn;
        input [11:0] addr;
        begin
            case (addr)
                12'd33: glyph_rom_fn = 8'h24; 12'd34: glyph_rom_fn = 8'h24; 12'd35: glyph_rom_fn = 8'hA4; 12'd36: glyph_rom_fn = 8'hBC; 12'd37: glyph_rom_fn = 8'hB4; 12'd38: glyph_rom_fn = 8'hA6; 12'd39: glyph_rom_fn = 8'hA6; 12'd40: glyph_rom_fn = 8'hA4; 12'd41: glyph_rom_fn = 8'hB4; 12'd42: glyph_rom_fn = 8'hBC; 12'd43: glyph_rom_fn = 8'hA4; 12'd44: glyph_rom_fn = 8'h24; 12'd45: glyph_rom_fn = 8'h24;
                12'd51: glyph_rom_fn = 8'h3F; 12'd52: glyph_rom_fn = 8'h35; 12'd53: glyph_rom_fn = 8'h35; 12'd54: glyph_rom_fn = 8'h35; 12'd55: glyph_rom_fn = 8'h35; 12'd56: glyph_rom_fn = 8'h35; 12'd57: glyph_rom_fn = 8'h35; 12'd58: glyph_rom_fn = 8'h35; 12'd59: glyph_rom_fn = 8'h3F;
                12'd65: glyph_rom_fn = 8'h20; 12'd66: glyph_rom_fn = 8'hF0; 12'd67: glyph_rom_fn = 8'hF8; 12'd68: glyph_rom_fn = 8'h2E; 12'd69: glyph_rom_fn = 8'h26; 12'd70: glyph_rom_fn = 8'h24; 12'd71: glyph_rom_fn = 8'hE4; 12'd72: glyph_rom_fn = 8'h34; 12'd73: glyph_rom_fn = 8'h3C; 12'd74: glyph_rom_fn = 8'h24; 12'd75: glyph_rom_fn = 8'h20; 12'd76: glyph_rom_fn = 8'hE0;
                12'd82: glyph_rom_fn = 8'h1F; 12'd83: glyph_rom_fn = 8'h3F; 12'd84: glyph_rom_fn = 8'h22; 12'd85: glyph_rom_fn = 8'h22; 12'd86: glyph_rom_fn = 8'h22; 12'd87: glyph_rom_fn = 8'h23; 12'd88: glyph_rom_fn = 8'h23; 12'd89: glyph_rom_fn = 8'h22; 12'd90: glyph_rom_fn = 8'h22; 12'd91: glyph_rom_fn = 8'h23; 12'd92: glyph_rom_fn = 8'h33; 12'd93: glyph_rom_fn = 8'h38;
                12'd98: glyph_rom_fn = 8'hF8; 12'd99: glyph_rom_fn = 8'h18; 12'd100: glyph_rom_fn = 8'h18; 12'd101: glyph_rom_fn = 8'hFE; 12'd102: glyph_rom_fn = 8'h18; 12'd103: glyph_rom_fn = 8'h18; 12'd104: glyph_rom_fn = 8'h98; 12'd105: glyph_rom_fn = 8'hFE; 12'd106: glyph_rom_fn = 8'h18; 12'd107: glyph_rom_fn = 8'h18; 12'd108: glyph_rom_fn = 8'hF8;
                12'd114: glyph_rom_fn = 8'h3F; 12'd115: glyph_rom_fn = 8'h31; 12'd116: glyph_rom_fn = 8'h31; 12'd117: glyph_rom_fn = 8'h3F; 12'd118: glyph_rom_fn = 8'h31; 12'd119: glyph_rom_fn = 8'h31; 12'd120: glyph_rom_fn = 8'h31; 12'd121: glyph_rom_fn = 8'h3F; 12'd122: glyph_rom_fn = 8'h31; 12'd123: glyph_rom_fn = 8'h31; 12'd124: glyph_rom_fn = 8'h3F;
                12'd130: glyph_rom_fn = 8'hFC; 12'd131: glyph_rom_fn = 8'hFE; 12'd132: glyph_rom_fn = 8'h26; 12'd133: glyph_rom_fn = 8'h26; 12'd134: glyph_rom_fn = 8'h26; 12'd135: glyph_rom_fn = 8'h26; 12'd136: glyph_rom_fn = 8'h26; 12'd137: glyph_rom_fn = 8'h26; 12'd138: glyph_rom_fn = 8'h26; 12'd139: glyph_rom_fn = 8'hFE;
                12'd146: glyph_rom_fn = 8'h3F; 12'd147: glyph_rom_fn = 8'h3F; 12'd148: glyph_rom_fn = 8'h13; 12'd149: glyph_rom_fn = 8'h13; 12'd150: glyph_rom_fn = 8'h13; 12'd151: glyph_rom_fn = 8'h13; 12'd152: glyph_rom_fn = 8'h13; 12'd153: glyph_rom_fn = 8'h13; 12'd154: glyph_rom_fn = 8'h13; 12'd155: glyph_rom_fn = 8'h3F;
                12'd161: glyph_rom_fn = 8'h20; 12'd162: glyph_rom_fn = 8'h66; 12'd163: glyph_rom_fn = 8'h04; 12'd165: glyph_rom_fn = 8'h7C; 12'd166: glyph_rom_fn = 8'h7E; 12'd167: glyph_rom_fn = 8'h56; 12'd168: glyph_rom_fn = 8'h56; 12'd169: glyph_rom_fn = 8'h56; 12'd170: glyph_rom_fn = 8'hD6; 12'd171: glyph_rom_fn = 8'h56; 12'd172: glyph_rom_fn = 8'h7E;
                12'd177: glyph_rom_fn = 8'h30; 12'd178: glyph_rom_fn = 8'h1C; 12'd179: glyph_rom_fn = 8'h0F; 12'd181: glyph_rom_fn = 8'h3F; 12'd182: glyph_rom_fn = 8'h3F; 12'd183: glyph_rom_fn = 8'h22; 12'd184: glyph_rom_fn = 8'h32; 12'd186: glyph_rom_fn = 8'h3F; 12'd187: glyph_rom_fn = 8'h22; 12'd188: glyph_rom_fn = 8'h22; 12'd189: glyph_rom_fn = 8'h39;
                12'd193: glyph_rom_fn = 8'hFC; 12'd194: glyph_rom_fn = 8'h0C; 12'd195: glyph_rom_fn = 8'h04; 12'd196: glyph_rom_fn = 8'hFC; 12'd198: glyph_rom_fn = 8'hF8; 12'd199: glyph_rom_fn = 8'h08; 12'd200: glyph_rom_fn = 8'hEC; 12'd201: glyph_rom_fn = 8'h6E; 12'd202: glyph_rom_fn = 8'h68; 12'd203: glyph_rom_fn = 8'hE8; 12'd204: glyph_rom_fn = 8'h08; 12'd205: glyph_rom_fn = 8'hF8;
                12'd209: glyph_rom_fn = 8'h0F; 12'd210: glyph_rom_fn = 8'h06; 12'd211: glyph_rom_fn = 8'h06; 12'd212: glyph_rom_fn = 8'h07; 12'd214: glyph_rom_fn = 8'h3F; 12'd216: glyph_rom_fn = 8'h0F; 12'd217: glyph_rom_fn = 8'h0C; 12'd218: glyph_rom_fn = 8'h0C; 12'd219: glyph_rom_fn = 8'h2F; 12'd220: glyph_rom_fn = 8'h20; 12'd221: glyph_rom_fn = 8'h3F;
                12'd225: glyph_rom_fn = 8'h20; 12'd226: glyph_rom_fn = 8'h30; 12'd227: glyph_rom_fn = 8'h70; 12'd228: glyph_rom_fn = 8'h58; 12'd229: glyph_rom_fn = 8'h4C; 12'd230: glyph_rom_fn = 8'h44; 12'd231: glyph_rom_fn = 8'h46; 12'd232: glyph_rom_fn = 8'h46; 12'd233: glyph_rom_fn = 8'h4C; 12'd234: glyph_rom_fn = 8'h58; 12'd235: glyph_rom_fn = 8'h70; 12'd236: glyph_rom_fn = 8'h30; 12'd237: glyph_rom_fn = 8'h20;
                12'd242: glyph_rom_fn = 8'h3E; 12'd243: glyph_rom_fn = 8'h3F; 12'd244: glyph_rom_fn = 8'h13; 12'd245: glyph_rom_fn = 8'h13; 12'd246: glyph_rom_fn = 8'h13; 12'd247: glyph_rom_fn = 8'h13; 12'd248: glyph_rom_fn = 8'h13; 12'd249: glyph_rom_fn = 8'h13; 12'd250: glyph_rom_fn = 8'h13; 12'd251: glyph_rom_fn = 8'h3F; 12'd252: glyph_rom_fn = 8'h3E;
                12'd257: glyph_rom_fn = 8'hFC; 12'd258: glyph_rom_fn = 8'h0C; 12'd259: glyph_rom_fn = 8'h0C; 12'd260: glyph_rom_fn = 8'hFC; 12'd262: glyph_rom_fn = 8'h7C; 12'd263: glyph_rom_fn = 8'h7E; 12'd264: glyph_rom_fn = 8'h56; 12'd265: glyph_rom_fn = 8'h56; 12'd266: glyph_rom_fn = 8'h56; 12'd267: glyph_rom_fn = 8'h56; 12'd268: glyph_rom_fn = 8'h7E;
                12'd273: glyph_rom_fn = 8'h0F; 12'd274: glyph_rom_fn = 8'h06; 12'd275: glyph_rom_fn = 8'h06; 12'd276: glyph_rom_fn = 8'h07; 12'd278: glyph_rom_fn = 8'h3F; 12'd279: glyph_rom_fn = 8'h35; 12'd280: glyph_rom_fn = 8'h35; 12'd281: glyph_rom_fn = 8'h35; 12'd282: glyph_rom_fn = 8'h35; 12'd283: glyph_rom_fn = 8'h35; 12'd284: glyph_rom_fn = 8'h3D; 12'd285: glyph_rom_fn = 8'h3F;
                12'd289: glyph_rom_fn = 8'h04; 12'd290: glyph_rom_fn = 8'h64; 12'd291: glyph_rom_fn = 8'h74; 12'd292: glyph_rom_fn = 8'hCC; 12'd293: glyph_rom_fn = 8'hC4; 12'd294: glyph_rom_fn = 8'h04; 12'd295: glyph_rom_fn = 8'hF4; 12'd296: glyph_rom_fn = 8'h04; 12'd297: glyph_rom_fn = 8'h04; 12'd298: glyph_rom_fn = 8'hFE; 12'd299: glyph_rom_fn = 8'h62; 12'd300: glyph_rom_fn = 8'h62; 12'd301: glyph_rom_fn = 8'h02;
                12'd305: glyph_rom_fn = 8'h20; 12'd306: glyph_rom_fn = 8'h3E; 12'd307: glyph_rom_fn = 8'h1C; 12'd308: glyph_rom_fn = 8'h1F; 12'd309: glyph_rom_fn = 8'h31; 12'd310: glyph_rom_fn = 8'h30; 12'd311: glyph_rom_fn = 8'h37; 12'd312: glyph_rom_fn = 8'h24; 12'd313: glyph_rom_fn = 8'h24; 12'd314: glyph_rom_fn = 8'h27; 12'd315: glyph_rom_fn = 8'h24; 12'd316: glyph_rom_fn = 8'h24; 12'd317: glyph_rom_fn = 8'h24;
                12'd321: glyph_rom_fn = 8'h46; 12'd322: glyph_rom_fn = 8'hCC; 12'd323: glyph_rom_fn = 8'hC8; 12'd326: glyph_rom_fn = 8'hFE; 12'd327: glyph_rom_fn = 8'h66; 12'd328: glyph_rom_fn = 8'h66; 12'd329: glyph_rom_fn = 8'h66; 12'd330: glyph_rom_fn = 8'h66; 12'd331: glyph_rom_fn = 8'h66; 12'd332: glyph_rom_fn = 8'hFE;
                12'd337: glyph_rom_fn = 8'h30; 12'd338: glyph_rom_fn = 8'h1F; 12'd339: glyph_rom_fn = 8'h1F; 12'd340: glyph_rom_fn = 8'h10; 12'd341: glyph_rom_fn = 8'h3E; 12'd342: glyph_rom_fn = 8'h23; 12'd343: glyph_rom_fn = 8'h20; 12'd344: glyph_rom_fn = 8'h20; 12'd345: glyph_rom_fn = 8'h21; 12'd346: glyph_rom_fn = 8'h23; 12'd347: glyph_rom_fn = 8'h26; 12'd348: glyph_rom_fn = 8'h2C; 12'd349: glyph_rom_fn = 8'h20;
                12'd353: glyph_rom_fn = 8'h80; 12'd354: glyph_rom_fn = 8'h86; 12'd355: glyph_rom_fn = 8'h86; 12'd356: glyph_rom_fn = 8'hC6; 12'd357: glyph_rom_fn = 8'hFE; 12'd358: glyph_rom_fn = 8'h86; 12'd359: glyph_rom_fn = 8'h86; 12'd360: glyph_rom_fn = 8'h86; 12'd361: glyph_rom_fn = 8'h86; 12'd362: glyph_rom_fn = 8'hFE; 12'd363: glyph_rom_fn = 8'h86; 12'd364: glyph_rom_fn = 8'h86; 12'd365: glyph_rom_fn = 8'h80;
                12'd369: glyph_rom_fn = 8'h20; 12'd370: glyph_rom_fn = 8'h30; 12'd371: glyph_rom_fn = 8'h18; 12'd372: glyph_rom_fn = 8'h0F; 12'd373: glyph_rom_fn = 8'h01; 12'd378: glyph_rom_fn = 8'h3F;
                12'd387: glyph_rom_fn = 8'hFC; 12'd388: glyph_rom_fn = 8'h4C; 12'd389: glyph_rom_fn = 8'h4C; 12'd390: glyph_rom_fn = 8'h4C; 12'd391: glyph_rom_fn = 8'h4E; 12'd392: glyph_rom_fn = 8'h4C; 12'd393: glyph_rom_fn = 8'h4C; 12'd394: glyph_rom_fn = 8'h4C; 12'd395: glyph_rom_fn = 8'h4C; 12'd396: glyph_rom_fn = 8'h7C;
                12'd401: glyph_rom_fn = 8'h30; 12'd402: glyph_rom_fn = 8'h1E; 12'd403: glyph_rom_fn = 8'h07; 12'd405: glyph_rom_fn = 8'h3E; 12'd406: glyph_rom_fn = 8'h12; 12'd407: glyph_rom_fn = 8'h12; 12'd408: glyph_rom_fn = 8'h12; 12'd409: glyph_rom_fn = 8'h12; 12'd410: glyph_rom_fn = 8'h12; 12'd411: glyph_rom_fn = 8'h12; 12'd412: glyph_rom_fn = 8'h3E; 12'd413: glyph_rom_fn = 8'h3E;
                12'd418: glyph_rom_fn = 8'h10; 12'd419: glyph_rom_fn = 8'h10; 12'd420: glyph_rom_fn = 8'h16; 12'd421: glyph_rom_fn = 8'h1C; 12'd422: glyph_rom_fn = 8'h90; 12'd423: glyph_rom_fn = 8'hF0; 12'd424: glyph_rom_fn = 8'h10; 12'd425: glyph_rom_fn = 8'h1C; 12'd426: glyph_rom_fn = 8'h16; 12'd427: glyph_rom_fn = 8'h10; 12'd428: glyph_rom_fn = 8'h10;
                12'd433: glyph_rom_fn = 8'h21; 12'd434: glyph_rom_fn = 8'h21; 12'd435: glyph_rom_fn = 8'h31; 12'd436: glyph_rom_fn = 8'h11; 12'd437: glyph_rom_fn = 8'h19; 12'd438: glyph_rom_fn = 8'h0F; 12'd439: glyph_rom_fn = 8'h03; 12'd440: glyph_rom_fn = 8'h07; 12'd441: glyph_rom_fn = 8'h0D; 12'd442: glyph_rom_fn = 8'h19; 12'd443: glyph_rom_fn = 8'h31; 12'd444: glyph_rom_fn = 8'h31; 12'd445: glyph_rom_fn = 8'h21;
                12'd449: glyph_rom_fn = 8'hF0; 12'd450: glyph_rom_fn = 8'hF0; 12'd451: glyph_rom_fn = 8'h06; 12'd452: glyph_rom_fn = 8'h64; 12'd453: glyph_rom_fn = 8'h60; 12'd454: glyph_rom_fn = 8'h62; 12'd455: glyph_rom_fn = 8'hE6; 12'd456: glyph_rom_fn = 8'hFE; 12'd457: glyph_rom_fn = 8'h66; 12'd458: glyph_rom_fn = 8'h66; 12'd459: glyph_rom_fn = 8'h06; 12'd460: glyph_rom_fn = 8'hFE; 12'd461: glyph_rom_fn = 8'hFC;
                12'd465: glyph_rom_fn = 8'h3F; 12'd466: glyph_rom_fn = 8'h3F; 12'd468: glyph_rom_fn = 8'h0C; 12'd469: glyph_rom_fn = 8'h06; 12'd470: glyph_rom_fn = 8'h03; 12'd471: glyph_rom_fn = 8'h31; 12'd472: glyph_rom_fn = 8'h1F; 12'd475: glyph_rom_fn = 8'h20; 12'd476: glyph_rom_fn = 8'h3F; 12'd477: glyph_rom_fn = 8'h1F;
                12'd481: glyph_rom_fn = 8'h04; 12'd482: glyph_rom_fn = 8'h24; 12'd483: glyph_rom_fn = 8'h24; 12'd484: glyph_rom_fn = 8'h24; 12'd485: glyph_rom_fn = 8'h24; 12'd486: glyph_rom_fn = 8'h24; 12'd487: glyph_rom_fn = 8'hFC; 12'd488: glyph_rom_fn = 8'h66; 12'd489: glyph_rom_fn = 8'h26; 12'd490: glyph_rom_fn = 8'h22; 12'd491: glyph_rom_fn = 8'h22; 12'd492: glyph_rom_fn = 8'h22;
                12'd497: glyph_rom_fn = 8'h03; 12'd498: glyph_rom_fn = 8'h03; 12'd499: glyph_rom_fn = 8'h03; 12'd500: glyph_rom_fn = 8'h03; 12'd501: glyph_rom_fn = 8'h23; 12'd502: glyph_rom_fn = 8'h23; 12'd503: glyph_rom_fn = 8'h3F; 12'd504: glyph_rom_fn = 8'h03; 12'd505: glyph_rom_fn = 8'h03; 12'd506: glyph_rom_fn = 8'h03; 12'd507: glyph_rom_fn = 8'h03; 12'd508: glyph_rom_fn = 8'h03; 12'd509: glyph_rom_fn = 8'h03;
                12'd513: glyph_rom_fn = 8'h64; 12'd514: glyph_rom_fn = 8'h64; 12'd515: glyph_rom_fn = 8'hE4; 12'd516: glyph_rom_fn = 8'h64; 12'd517: glyph_rom_fn = 8'h64; 12'd518: glyph_rom_fn = 8'h20; 12'd520: glyph_rom_fn = 8'h18; 12'd521: glyph_rom_fn = 8'hFE; 12'd522: glyph_rom_fn = 8'h1E; 12'd523: glyph_rom_fn = 8'h18; 12'd524: glyph_rom_fn = 8'h18; 12'd525: glyph_rom_fn = 8'hF8;
                12'd529: glyph_rom_fn = 8'h1C; 12'd530: glyph_rom_fn = 8'h0F; 12'd531: glyph_rom_fn = 8'h09; 12'd532: glyph_rom_fn = 8'h08; 12'd533: glyph_rom_fn = 8'h0F; 12'd534: glyph_rom_fn = 8'h2E; 12'd535: glyph_rom_fn = 8'h38; 12'd536: glyph_rom_fn = 8'h1C; 12'd537: glyph_rom_fn = 8'h07; 12'd538: glyph_rom_fn = 8'h20; 12'd539: glyph_rom_fn = 8'h20; 12'd540: glyph_rom_fn = 8'h3C; 12'd541: glyph_rom_fn = 8'h1F;
                12'd545: glyph_rom_fn = 8'h22; 12'd546: glyph_rom_fn = 8'h64; 12'd548: glyph_rom_fn = 8'h1C; 12'd549: glyph_rom_fn = 8'hC4; 12'd550: glyph_rom_fn = 8'h54; 12'd551: glyph_rom_fn = 8'h54; 12'd552: glyph_rom_fn = 8'hF6; 12'd553: glyph_rom_fn = 8'hF4; 12'd554: glyph_rom_fn = 8'h54; 12'd555: glyph_rom_fn = 8'h54; 12'd556: glyph_rom_fn = 8'hC4; 12'd557: glyph_rom_fn = 8'h1C;
                12'd561: glyph_rom_fn = 8'h30; 12'd562: glyph_rom_fn = 8'h1E; 12'd564: glyph_rom_fn = 8'h20; 12'd565: glyph_rom_fn = 8'h37; 12'd566: glyph_rom_fn = 8'h15; 12'd567: glyph_rom_fn = 8'h15; 12'd568: glyph_rom_fn = 8'h07; 12'd569: glyph_rom_fn = 8'h07; 12'd570: glyph_rom_fn = 8'h1D; 12'd571: glyph_rom_fn = 8'h15; 12'd572: glyph_rom_fn = 8'h37; 12'd573: glyph_rom_fn = 8'h20;
                12'd577: glyph_rom_fn = 8'h40; 12'd578: glyph_rom_fn = 8'h54; 12'd579: glyph_rom_fn = 8'hD4; 12'd580: glyph_rom_fn = 8'hD4; 12'd581: glyph_rom_fn = 8'h74; 12'd582: glyph_rom_fn = 8'h7C; 12'd583: glyph_rom_fn = 8'h5E; 12'd584: glyph_rom_fn = 8'h54; 12'd585: glyph_rom_fn = 8'h54; 12'd586: glyph_rom_fn = 8'hD4; 12'd587: glyph_rom_fn = 8'hD4; 12'd588: glyph_rom_fn = 8'h54; 12'd589: glyph_rom_fn = 8'h40;
                12'd593: glyph_rom_fn = 8'h03; 12'd594: glyph_rom_fn = 8'h25; 12'd595: glyph_rom_fn = 8'h25; 12'd596: glyph_rom_fn = 8'h35; 12'd597: glyph_rom_fn = 8'h15; 12'd598: glyph_rom_fn = 8'h1D; 12'd599: glyph_rom_fn = 8'h1F; 12'd600: glyph_rom_fn = 8'h15; 12'd601: glyph_rom_fn = 8'h15; 12'd602: glyph_rom_fn = 8'h35; 12'd603: glyph_rom_fn = 8'h25; 12'd604: glyph_rom_fn = 8'h25; 12'd605: glyph_rom_fn = 8'h03;
                12'd610: glyph_rom_fn = 8'h04; 12'd611: glyph_rom_fn = 8'hE4; 12'd612: glyph_rom_fn = 8'h04; 12'd613: glyph_rom_fn = 8'h04; 12'd614: glyph_rom_fn = 8'h04; 12'd615: glyph_rom_fn = 8'hFC; 12'd616: glyph_rom_fn = 8'hFC; 12'd617: glyph_rom_fn = 8'h84; 12'd618: glyph_rom_fn = 8'h84; 12'd619: glyph_rom_fn = 8'h84; 12'd620: glyph_rom_fn = 8'h84; 12'd621: glyph_rom_fn = 8'h04;
                12'd625: glyph_rom_fn = 8'h20; 12'd626: glyph_rom_fn = 8'h20; 12'd627: glyph_rom_fn = 8'h3F; 12'd628: glyph_rom_fn = 8'h20; 12'd629: glyph_rom_fn = 8'h20; 12'd630: glyph_rom_fn = 8'h20; 12'd631: glyph_rom_fn = 8'h3F; 12'd632: glyph_rom_fn = 8'h3F; 12'd633: glyph_rom_fn = 8'h20; 12'd634: glyph_rom_fn = 8'h20; 12'd635: glyph_rom_fn = 8'h20; 12'd636: glyph_rom_fn = 8'h20; 12'd637: glyph_rom_fn = 8'h20;
                12'd641: glyph_rom_fn = 8'h08; 12'd642: glyph_rom_fn = 8'h88; 12'd643: glyph_rom_fn = 8'hE8; 12'd644: glyph_rom_fn = 8'h38; 12'd645: glyph_rom_fn = 8'h9E; 12'd646: glyph_rom_fn = 8'h8E; 12'd647: glyph_rom_fn = 8'h88; 12'd648: glyph_rom_fn = 8'h88; 12'd649: glyph_rom_fn = 8'hE8; 12'd650: glyph_rom_fn = 8'h88; 12'd651: glyph_rom_fn = 8'h88; 12'd652: glyph_rom_fn = 8'h88; 12'd653: glyph_rom_fn = 8'h08;
                12'd657: glyph_rom_fn = 8'h03; 12'd658: glyph_rom_fn = 8'h03; 12'd659: glyph_rom_fn = 8'h3F; 12'd660: glyph_rom_fn = 8'h20; 12'd661: glyph_rom_fn = 8'h21; 12'd662: glyph_rom_fn = 8'h21; 12'd663: glyph_rom_fn = 8'h21; 12'd664: glyph_rom_fn = 8'h31; 12'd665: glyph_rom_fn = 8'h3F; 12'd666: glyph_rom_fn = 8'h21; 12'd667: glyph_rom_fn = 8'h21; 12'd668: glyph_rom_fn = 8'h21; 12'd669: glyph_rom_fn = 8'h20;
                12'd673: glyph_rom_fn = 8'h40; 12'd674: glyph_rom_fn = 8'h42; 12'd675: glyph_rom_fn = 8'h52; 12'd676: glyph_rom_fn = 8'h52; 12'd677: glyph_rom_fn = 8'h52; 12'd678: glyph_rom_fn = 8'hD2; 12'd679: glyph_rom_fn = 8'hD2; 12'd680: glyph_rom_fn = 8'hD2; 12'd681: glyph_rom_fn = 8'h52; 12'd682: glyph_rom_fn = 8'h7E; 12'd683: glyph_rom_fn = 8'h7E; 12'd684: glyph_rom_fn = 8'h40; 12'd685: glyph_rom_fn = 8'h40;
                12'd689: glyph_rom_fn = 8'h10; 12'd690: glyph_rom_fn = 8'h10; 12'd691: glyph_rom_fn = 8'h1B; 12'd692: glyph_rom_fn = 8'h0A; 12'd693: glyph_rom_fn = 8'h24; 12'd694: glyph_rom_fn = 8'h24; 12'd695: glyph_rom_fn = 8'h3F; 12'd696: glyph_rom_fn = 8'h03; 12'd697: glyph_rom_fn = 8'h06; 12'd698: glyph_rom_fn = 8'h0E; 12'd699: glyph_rom_fn = 8'h1B; 12'd700: glyph_rom_fn = 8'h11; 12'd701: glyph_rom_fn = 8'h30;
                12'd705: glyph_rom_fn = 8'h40; 12'd706: glyph_rom_fn = 8'h46; 12'd707: glyph_rom_fn = 8'h46; 12'd708: glyph_rom_fn = 8'h46; 12'd709: glyph_rom_fn = 8'h46; 12'd710: glyph_rom_fn = 8'hC6; 12'd711: glyph_rom_fn = 8'hFE; 12'd712: glyph_rom_fn = 8'h46; 12'd713: glyph_rom_fn = 8'h46; 12'd714: glyph_rom_fn = 8'h46; 12'd715: glyph_rom_fn = 8'h46; 12'd716: glyph_rom_fn = 8'h44; 12'd717: glyph_rom_fn = 8'h40;
                12'd721: glyph_rom_fn = 8'h20; 12'd722: glyph_rom_fn = 8'h30; 12'd723: glyph_rom_fn = 8'h30; 12'd724: glyph_rom_fn = 8'h18; 12'd725: glyph_rom_fn = 8'h0C; 12'd726: glyph_rom_fn = 8'h07; 12'd727: glyph_rom_fn = 8'h01; 12'd728: glyph_rom_fn = 8'h07; 12'd729: glyph_rom_fn = 8'h0C; 12'd730: glyph_rom_fn = 8'h18; 12'd731: glyph_rom_fn = 8'h10; 12'd732: glyph_rom_fn = 8'h30; 12'd733: glyph_rom_fn = 8'h20;
                12'd737: glyph_rom_fn = 8'h38; 12'd738: glyph_rom_fn = 8'h98; 12'd739: glyph_rom_fn = 8'h88; 12'd740: glyph_rom_fn = 8'hC8; 12'd741: glyph_rom_fn = 8'h68; 12'd742: glyph_rom_fn = 8'h08; 12'd743: glyph_rom_fn = 8'h0C; 12'd744: glyph_rom_fn = 8'h08; 12'd745: glyph_rom_fn = 8'h68; 12'd746: glyph_rom_fn = 8'h48; 12'd747: glyph_rom_fn = 8'hC8; 12'd748: glyph_rom_fn = 8'h98; 12'd749: glyph_rom_fn = 8'h38;
                12'd753: glyph_rom_fn = 8'h40; 12'd754: glyph_rom_fn = 8'h43; 12'd755: glyph_rom_fn = 8'h46; 12'd756: glyph_rom_fn = 8'h46; 12'd757: glyph_rom_fn = 8'h46; 12'd758: glyph_rom_fn = 8'h46; 12'd759: glyph_rom_fn = 8'h7E; 12'd760: glyph_rom_fn = 8'h46; 12'd761: glyph_rom_fn = 8'h46; 12'd762: glyph_rom_fn = 8'h46; 12'd763: glyph_rom_fn = 8'h46; 12'd764: glyph_rom_fn = 8'h47; 12'd765: glyph_rom_fn = 8'h40;
                12'd770: glyph_rom_fn = 8'h10; 12'd771: glyph_rom_fn = 8'h10; 12'd772: glyph_rom_fn = 8'h10; 12'd773: glyph_rom_fn = 8'h10; 12'd774: glyph_rom_fn = 8'h1E; 12'd775: glyph_rom_fn = 8'h1C; 12'd776: glyph_rom_fn = 8'h90; 12'd777: glyph_rom_fn = 8'hD0; 12'd778: glyph_rom_fn = 8'h70; 12'd779: glyph_rom_fn = 8'h30; 12'd780: glyph_rom_fn = 8'h10;
                12'd785: glyph_rom_fn = 8'h20; 12'd786: glyph_rom_fn = 8'h30; 12'd787: glyph_rom_fn = 8'h08; 12'd788: glyph_rom_fn = 8'h1C; 12'd789: glyph_rom_fn = 8'h1C; 12'd790: glyph_rom_fn = 8'h36; 12'd791: glyph_rom_fn = 8'h33; 12'd792: glyph_rom_fn = 8'h21; 12'd793: glyph_rom_fn = 8'h20; 12'd794: glyph_rom_fn = 8'h20; 12'd795: glyph_rom_fn = 8'h20; 12'd796: glyph_rom_fn = 8'h20; 12'd797: glyph_rom_fn = 8'h20;
                12'd801: glyph_rom_fn = 8'h30; 12'd802: glyph_rom_fn = 8'hFE; 12'd803: glyph_rom_fn = 8'h30; 12'd804: glyph_rom_fn = 8'h30; 12'd805: glyph_rom_fn = 8'hF0; 12'd806: glyph_rom_fn = 8'hF8; 12'd807: glyph_rom_fn = 8'h48; 12'd808: glyph_rom_fn = 8'hC8; 12'd809: glyph_rom_fn = 8'h08; 12'd810: glyph_rom_fn = 8'hFE; 12'd811: glyph_rom_fn = 8'h08; 12'd812: glyph_rom_fn = 8'hCE; 12'd813: glyph_rom_fn = 8'h48;
                12'd817: glyph_rom_fn = 8'h08; 12'd818: glyph_rom_fn = 8'h0F; 12'd819: glyph_rom_fn = 8'h06; 12'd820: glyph_rom_fn = 8'h34; 12'd821: glyph_rom_fn = 8'h1F; 12'd822: glyph_rom_fn = 8'h03; 12'd823: glyph_rom_fn = 8'h08; 12'd824: glyph_rom_fn = 8'h2F; 12'd825: glyph_rom_fn = 8'h30; 12'd826: glyph_rom_fn = 8'h1B; 12'd827: glyph_rom_fn = 8'h1E; 12'd828: glyph_rom_fn = 8'h33; 12'd829: glyph_rom_fn = 8'h38; 12'd830: glyph_rom_fn = 8'h08;
                12'd833: glyph_rom_fn = 8'h30; 12'd834: glyph_rom_fn = 8'hB8; 12'd835: glyph_rom_fn = 8'hE6; 12'd836: glyph_rom_fn = 8'h70; 12'd837: glyph_rom_fn = 8'h18; 12'd838: glyph_rom_fn = 8'h84; 12'd839: glyph_rom_fn = 8'hC4; 12'd840: glyph_rom_fn = 8'h44; 12'd841: glyph_rom_fn = 8'h64; 12'd842: glyph_rom_fn = 8'h74; 12'd843: glyph_rom_fn = 8'h5C; 12'd844: glyph_rom_fn = 8'hCC; 12'd845: glyph_rom_fn = 8'h80;
                12'd849: glyph_rom_fn = 8'h13; 12'd850: glyph_rom_fn = 8'h1B; 12'd851: glyph_rom_fn = 8'h1B; 12'd852: glyph_rom_fn = 8'h09; 12'd853: glyph_rom_fn = 8'h29; 12'd854: glyph_rom_fn = 8'h20; 12'd855: glyph_rom_fn = 8'h22; 12'd856: glyph_rom_fn = 8'h22; 12'd857: glyph_rom_fn = 8'h3E; 12'd858: glyph_rom_fn = 8'h3E; 12'd859: glyph_rom_fn = 8'h22; 12'd860: glyph_rom_fn = 8'h22; 12'd861: glyph_rom_fn = 8'h20;
                12'd866: glyph_rom_fn = 8'hFC; 12'd867: glyph_rom_fn = 8'hCC; 12'd868: glyph_rom_fn = 8'h4C; 12'd869: glyph_rom_fn = 8'hFE; 12'd870: glyph_rom_fn = 8'hFE; 12'd871: glyph_rom_fn = 8'h4C; 12'd872: glyph_rom_fn = 8'hFE; 12'd873: glyph_rom_fn = 8'hFE; 12'd874: glyph_rom_fn = 8'h4C; 12'd875: glyph_rom_fn = 8'hCC; 12'd876: glyph_rom_fn = 8'hFC;
                12'd880: glyph_rom_fn = 8'h04; 12'd881: glyph_rom_fn = 8'h24; 12'd882: glyph_rom_fn = 8'h27; 12'd883: glyph_rom_fn = 8'h34; 12'd884: glyph_rom_fn = 8'h14; 12'd885: glyph_rom_fn = 8'h1F; 12'd886: glyph_rom_fn = 8'h07; 12'd887: glyph_rom_fn = 8'h04; 12'd888: glyph_rom_fn = 8'h07; 12'd889: glyph_rom_fn = 8'h17; 12'd890: glyph_rom_fn = 8'h14; 12'd891: glyph_rom_fn = 8'h34; 12'd892: glyph_rom_fn = 8'h27; 12'd893: glyph_rom_fn = 8'h24; 12'd894: glyph_rom_fn = 8'h04;
                12'd897: glyph_rom_fn = 8'h40; 12'd898: glyph_rom_fn = 8'h40; 12'd899: glyph_rom_fn = 8'h40; 12'd900: glyph_rom_fn = 8'h40; 12'd901: glyph_rom_fn = 8'h40; 12'd902: glyph_rom_fn = 8'h60; 12'd903: glyph_rom_fn = 8'h7E; 12'd904: glyph_rom_fn = 8'h48; 12'd905: glyph_rom_fn = 8'h48; 12'd906: glyph_rom_fn = 8'h48; 12'd907: glyph_rom_fn = 8'h48; 12'd908: glyph_rom_fn = 8'h40; 12'd909: glyph_rom_fn = 8'h40;
                12'd919: glyph_rom_fn = 8'h3F; 12'd920: glyph_rom_fn = 8'h06; 12'd921: glyph_rom_fn = 8'h04; 12'd922: glyph_rom_fn = 8'h0C; 12'd923: glyph_rom_fn = 8'h08;
                12'd930: glyph_rom_fn = 8'h38; 12'd931: glyph_rom_fn = 8'h08; 12'd932: glyph_rom_fn = 8'h88; 12'd933: glyph_rom_fn = 8'hC8; 12'd934: glyph_rom_fn = 8'h78; 12'd935: glyph_rom_fn = 8'h7E; 12'd936: glyph_rom_fn = 8'hCE; 12'd937: glyph_rom_fn = 8'h08; 12'd938: glyph_rom_fn = 8'h08; 12'd939: glyph_rom_fn = 8'h88; 12'd940: glyph_rom_fn = 8'h38; 12'd941: glyph_rom_fn = 8'h38;
                12'd945: glyph_rom_fn = 8'h04; 12'd946: glyph_rom_fn = 8'h06; 12'd947: glyph_rom_fn = 8'h03; 12'd948: glyph_rom_fn = 8'h3F; 12'd949: glyph_rom_fn = 8'h3F; 12'd950: glyph_rom_fn = 8'h30; 12'd951: glyph_rom_fn = 8'h10; 12'd952: glyph_rom_fn = 8'h01; 12'd953: glyph_rom_fn = 8'h03; 12'd954: glyph_rom_fn = 8'h0F; 12'd955: glyph_rom_fn = 8'h18; 12'd956: glyph_rom_fn = 8'h18; 12'd957: glyph_rom_fn = 8'h30;
                12'd961: glyph_rom_fn = 8'h46; 12'd962: glyph_rom_fn = 8'h76; 12'd963: glyph_rom_fn = 8'h5E; 12'd964: glyph_rom_fn = 8'h46; 12'd965: glyph_rom_fn = 8'h7E; 12'd966: glyph_rom_fn = 8'h76; 12'd967: glyph_rom_fn = 8'hC0; 12'd968: glyph_rom_fn = 8'hF0; 12'd969: glyph_rom_fn = 8'hFE; 12'd970: glyph_rom_fn = 8'h18; 12'd971: glyph_rom_fn = 8'h98; 12'd972: glyph_rom_fn = 8'hF8; 12'd973: glyph_rom_fn = 8'h18;
                12'd977: glyph_rom_fn = 8'h20; 12'd978: glyph_rom_fn = 8'h36; 12'd979: glyph_rom_fn = 8'h3F; 12'd980: glyph_rom_fn = 8'h3F; 12'd981: glyph_rom_fn = 8'h16; 12'd982: glyph_rom_fn = 8'h16; 12'd983: glyph_rom_fn = 8'h20; 12'd984: glyph_rom_fn = 8'h30; 12'd985: glyph_rom_fn = 8'h19; 12'd986: glyph_rom_fn = 8'h0F; 12'd987: glyph_rom_fn = 8'h0F; 12'd988: glyph_rom_fn = 8'h31; 12'd989: glyph_rom_fn = 8'h30;
                12'd993: glyph_rom_fn = 8'h60; 12'd994: glyph_rom_fn = 8'hF6; 12'd995: glyph_rom_fn = 8'hBE; 12'd996: glyph_rom_fn = 8'hBE; 12'd997: glyph_rom_fn = 8'hF6; 12'd998: glyph_rom_fn = 8'hB6; 12'd999: glyph_rom_fn = 8'hBE; 12'd1000: glyph_rom_fn = 8'hB2; 12'd1001: glyph_rom_fn = 8'hB2; 12'd1002: glyph_rom_fn = 8'hBA; 12'd1003: glyph_rom_fn = 8'hBE; 12'd1004: glyph_rom_fn = 8'hF2; 12'd1005: glyph_rom_fn = 8'h20;
                12'd1009: glyph_rom_fn = 8'h18; 12'd1010: glyph_rom_fn = 8'h2D; 12'd1011: glyph_rom_fn = 8'h27; 12'd1012: glyph_rom_fn = 8'h27; 12'd1013: glyph_rom_fn = 8'h2F; 12'd1014: glyph_rom_fn = 8'h3F; 12'd1015: glyph_rom_fn = 8'h17; 12'd1016: glyph_rom_fn = 8'h37; 12'd1017: glyph_rom_fn = 8'h3F; 12'd1018: glyph_rom_fn = 8'h2F; 12'd1019: glyph_rom_fn = 8'h27; 12'd1020: glyph_rom_fn = 8'h21; 12'd1021: glyph_rom_fn = 8'h20;
                12'd1025: glyph_rom_fn = 8'h04; 12'd1026: glyph_rom_fn = 8'hF4; 12'd1027: glyph_rom_fn = 8'h94; 12'd1028: glyph_rom_fn = 8'h94; 12'd1029: glyph_rom_fn = 8'h14; 12'd1030: glyph_rom_fn = 8'hF4; 12'd1031: glyph_rom_fn = 8'h04; 12'd1032: glyph_rom_fn = 8'hF4; 12'd1033: glyph_rom_fn = 8'h14; 12'd1034: glyph_rom_fn = 8'h94; 12'd1035: glyph_rom_fn = 8'h14; 12'd1036: glyph_rom_fn = 8'hF4; 12'd1037: glyph_rom_fn = 8'h04;
                12'd1042: glyph_rom_fn = 8'h3F; 12'd1044: glyph_rom_fn = 8'h27; 12'd1045: glyph_rom_fn = 8'h20; 12'd1046: glyph_rom_fn = 8'h3F; 12'd1048: glyph_rom_fn = 8'h7F; 12'd1050: glyph_rom_fn = 8'h27; 12'd1051: glyph_rom_fn = 8'h20; 12'd1052: glyph_rom_fn = 8'h3F;
                12'd1057: glyph_rom_fn = 8'h80; 12'd1058: glyph_rom_fn = 8'hC0; 12'd1059: glyph_rom_fn = 8'hB0; 12'd1060: glyph_rom_fn = 8'h9C; 12'd1061: glyph_rom_fn = 8'hC0; 12'd1062: glyph_rom_fn = 8'h60; 12'd1063: glyph_rom_fn = 8'h80; 12'd1064: glyph_rom_fn = 8'hE0; 12'd1065: glyph_rom_fn = 8'hB0; 12'd1066: glyph_rom_fn = 8'h9C; 12'd1067: glyph_rom_fn = 8'hC4; 12'd1068: glyph_rom_fn = 8'h60;
                12'd1073: glyph_rom_fn = 8'h60; 12'd1074: glyph_rom_fn = 8'h6C; 12'd1075: glyph_rom_fn = 8'h6E; 12'd1076: glyph_rom_fn = 8'h6B; 12'd1077: glyph_rom_fn = 8'h6D; 12'd1078: glyph_rom_fn = 8'h64; 12'd1079: glyph_rom_fn = 8'h60; 12'd1080: glyph_rom_fn = 8'h6C; 12'd1081: glyph_rom_fn = 8'h6E; 12'd1082: glyph_rom_fn = 8'h6F; 12'd1083: glyph_rom_fn = 8'h65; 12'd1084: glyph_rom_fn = 8'h64; 12'd1085: glyph_rom_fn = 8'h64;
                12'd1089: glyph_rom_fn = 8'h36; 12'd1090: glyph_rom_fn = 8'h66; 12'd1091: glyph_rom_fn = 8'hC6; 12'd1092: glyph_rom_fn = 8'hFE; 12'd1093: glyph_rom_fn = 8'h1C; 12'd1094: glyph_rom_fn = 8'h60; 12'd1095: glyph_rom_fn = 8'h38; 12'd1096: glyph_rom_fn = 8'h1E; 12'd1097: glyph_rom_fn = 8'hE8; 12'd1098: glyph_rom_fn = 8'hE8; 12'd1099: glyph_rom_fn = 8'h08; 12'd1100: glyph_rom_fn = 8'h78; 12'd1101: glyph_rom_fn = 8'h18;
                12'd1105: glyph_rom_fn = 8'h30; 12'd1106: glyph_rom_fn = 8'h18; 12'd1107: glyph_rom_fn = 8'h0F; 12'd1108: glyph_rom_fn = 8'h07; 12'd1109: glyph_rom_fn = 8'h0C; 12'd1110: glyph_rom_fn = 8'h20; 12'd1111: glyph_rom_fn = 8'h30; 12'd1112: glyph_rom_fn = 8'h1C; 12'd1113: glyph_rom_fn = 8'h07; 12'd1114: glyph_rom_fn = 8'h03; 12'd1115: glyph_rom_fn = 8'h0C; 12'd1116: glyph_rom_fn = 8'h30; 12'd1117: glyph_rom_fn = 8'h20;
                12'd1122: glyph_rom_fn = 8'hFC; 12'd1123: glyph_rom_fn = 8'hDC; 12'd1124: glyph_rom_fn = 8'h84; 12'd1125: glyph_rom_fn = 8'h84; 12'd1126: glyph_rom_fn = 8'h84; 12'd1127: glyph_rom_fn = 8'hF4; 12'd1128: glyph_rom_fn = 8'hC6; 12'd1129: glyph_rom_fn = 8'h82; 12'd1130: glyph_rom_fn = 8'h82; 12'd1131: glyph_rom_fn = 8'h82; 12'd1132: glyph_rom_fn = 8'h80;
                12'd1137: glyph_rom_fn = 8'h10; 12'd1138: glyph_rom_fn = 8'h18; 12'd1139: glyph_rom_fn = 8'h0E; 12'd1140: glyph_rom_fn = 8'h02; 12'd1141: glyph_rom_fn = 8'h20; 12'd1142: glyph_rom_fn = 8'h20; 12'd1143: glyph_rom_fn = 8'h3F; 12'd1146: glyph_rom_fn = 8'h02; 12'd1147: glyph_rom_fn = 8'h0E; 12'd1148: glyph_rom_fn = 8'h18; 12'd1149: glyph_rom_fn = 8'h10;
                12'd1153: glyph_rom_fn = 8'h70; 12'd1154: glyph_rom_fn = 8'h1C; 12'd1155: glyph_rom_fn = 8'hC4; 12'd1157: glyph_rom_fn = 8'h1C; 12'd1158: glyph_rom_fn = 8'h30; 12'd1159: glyph_rom_fn = 8'h02; 12'd1160: glyph_rom_fn = 8'hFA; 12'd1161: glyph_rom_fn = 8'h1E; 12'd1162: glyph_rom_fn = 8'hDE; 12'd1163: glyph_rom_fn = 8'h1A; 12'd1164: glyph_rom_fn = 8'hFA; 12'd1165: glyph_rom_fn = 8'hF2;
                12'd1169: glyph_rom_fn = 8'h18; 12'd1170: glyph_rom_fn = 8'h1F; 12'd1171: glyph_rom_fn = 8'h11; 12'd1172: glyph_rom_fn = 8'h18; 12'd1173: glyph_rom_fn = 8'h1F; 12'd1174: glyph_rom_fn = 8'h1C; 12'd1175: glyph_rom_fn = 8'h20; 12'd1176: glyph_rom_fn = 8'h37; 12'd1177: glyph_rom_fn = 8'h18; 12'd1178: glyph_rom_fn = 8'h0F; 12'd1179: glyph_rom_fn = 8'h18; 12'd1180: glyph_rom_fn = 8'h17; 12'd1181: glyph_rom_fn = 8'h27;
                12'd1185: glyph_rom_fn = 8'h04; 12'd1186: glyph_rom_fn = 8'hE4; 12'd1187: glyph_rom_fn = 8'hE4; 12'd1188: glyph_rom_fn = 8'h0E; 12'd1189: glyph_rom_fn = 8'hFE; 12'd1190: glyph_rom_fn = 8'h04; 12'd1191: glyph_rom_fn = 8'h84; 12'd1192: glyph_rom_fn = 8'hE4; 12'd1193: glyph_rom_fn = 8'h7E; 12'd1194: glyph_rom_fn = 8'hCE; 12'd1195: glyph_rom_fn = 8'h44; 12'd1196: glyph_rom_fn = 8'h44; 12'd1197: glyph_rom_fn = 8'h04;
                12'd1201: glyph_rom_fn = 8'h20; 12'd1202: glyph_rom_fn = 8'h3D; 12'd1203: glyph_rom_fn = 8'h24; 12'd1204: glyph_rom_fn = 8'h24; 12'd1205: glyph_rom_fn = 8'h3F; 12'd1206: glyph_rom_fn = 8'h3C; 12'd1207: glyph_rom_fn = 8'h24; 12'd1208: glyph_rom_fn = 8'h3C; 12'd1209: glyph_rom_fn = 8'h3C; 12'd1210: glyph_rom_fn = 8'h25; 12'd1211: glyph_rom_fn = 8'h25; 12'd1212: glyph_rom_fn = 8'h3C; 12'd1213: glyph_rom_fn = 8'h20;
                12'd1218: glyph_rom_fn = 8'h66; 12'd1219: glyph_rom_fn = 8'h7E; 12'd1220: glyph_rom_fn = 8'h46; 12'd1221: glyph_rom_fn = 8'h46; 12'd1222: glyph_rom_fn = 8'h46; 12'd1223: glyph_rom_fn = 8'hC6; 12'd1224: glyph_rom_fn = 8'hC6; 12'd1225: glyph_rom_fn = 8'hC6; 12'd1226: glyph_rom_fn = 8'hFE; 12'd1227: glyph_rom_fn = 8'h46; 12'd1228: glyph_rom_fn = 8'h46; 12'd1229: glyph_rom_fn = 8'h46;
                12'd1233: glyph_rom_fn = 8'h10; 12'd1234: glyph_rom_fn = 8'h18; 12'd1235: glyph_rom_fn = 8'h08; 12'd1236: glyph_rom_fn = 8'h0C; 12'd1237: glyph_rom_fn = 8'h06; 12'd1238: glyph_rom_fn = 8'h02; 12'd1239: glyph_rom_fn = 8'h21; 12'd1240: glyph_rom_fn = 8'h20; 12'd1241: glyph_rom_fn = 8'h20; 12'd1242: glyph_rom_fn = 8'h3F;
                12'd1250: glyph_rom_fn = 8'h84; 12'd1251: glyph_rom_fn = 8'h84; 12'd1252: glyph_rom_fn = 8'h84; 12'd1253: glyph_rom_fn = 8'h84; 12'd1254: glyph_rom_fn = 8'h84; 12'd1255: glyph_rom_fn = 8'h84; 12'd1256: glyph_rom_fn = 8'h84; 12'd1257: glyph_rom_fn = 8'h84; 12'd1258: glyph_rom_fn = 8'h84; 12'd1259: glyph_rom_fn = 8'h84; 12'd1260: glyph_rom_fn = 8'h84;
                12'd1265: glyph_rom_fn = 8'h10; 12'd1266: glyph_rom_fn = 8'h10; 12'd1267: glyph_rom_fn = 8'h10; 12'd1268: glyph_rom_fn = 8'h10; 12'd1269: glyph_rom_fn = 8'h10; 12'd1270: glyph_rom_fn = 8'h10; 12'd1271: glyph_rom_fn = 8'h10; 12'd1272: glyph_rom_fn = 8'h10; 12'd1273: glyph_rom_fn = 8'h10; 12'd1274: glyph_rom_fn = 8'h10; 12'd1275: glyph_rom_fn = 8'h10; 12'd1276: glyph_rom_fn = 8'h10; 12'd1277: glyph_rom_fn = 8'h10;
                12'd1281: glyph_rom_fn = 8'h10; 12'd1282: glyph_rom_fn = 8'hF8; 12'd1283: glyph_rom_fn = 8'hFC; 12'd1284: glyph_rom_fn = 8'h96; 12'd1285: glyph_rom_fn = 8'h96; 12'd1286: glyph_rom_fn = 8'h94; 12'd1287: glyph_rom_fn = 8'hF4; 12'd1288: glyph_rom_fn = 8'hBC; 12'd1289: glyph_rom_fn = 8'h9C; 12'd1290: glyph_rom_fn = 8'h94; 12'd1291: glyph_rom_fn = 8'h90; 12'd1292: glyph_rom_fn = 8'hF0;
                12'd1297: glyph_rom_fn = 8'h30; 12'd1298: glyph_rom_fn = 8'h1F; 12'd1299: glyph_rom_fn = 8'h07; 12'd1300: glyph_rom_fn = 8'h04; 12'd1301: glyph_rom_fn = 8'h04; 12'd1302: glyph_rom_fn = 8'h04; 12'd1303: glyph_rom_fn = 8'h3F; 12'd1304: glyph_rom_fn = 8'h07; 12'd1305: glyph_rom_fn = 8'h04; 12'd1306: glyph_rom_fn = 8'h24; 12'd1307: glyph_rom_fn = 8'h24; 12'd1308: glyph_rom_fn = 8'h3F;
                12'd1313: glyph_rom_fn = 8'h18; 12'd1314: glyph_rom_fn = 8'h2E; 12'd1315: glyph_rom_fn = 8'hEE; 12'd1316: glyph_rom_fn = 8'h28; 12'd1317: glyph_rom_fn = 8'h28; 12'd1318: glyph_rom_fn = 8'hFC; 12'd1319: glyph_rom_fn = 8'hFE; 12'd1320: glyph_rom_fn = 8'h36; 12'd1321: glyph_rom_fn = 8'hE6; 12'd1322: glyph_rom_fn = 8'hE6; 12'd1323: glyph_rom_fn = 8'h36; 12'd1324: glyph_rom_fn = 8'h16; 12'd1325: glyph_rom_fn = 8'hFC;
                12'd1329: glyph_rom_fn = 8'h01; 12'd1330: glyph_rom_fn = 8'h01; 12'd1331: glyph_rom_fn = 8'h3F; 12'd1332: glyph_rom_fn = 8'h31; 12'd1333: glyph_rom_fn = 8'h11; 12'd1334: glyph_rom_fn = 8'h3F; 12'd1335: glyph_rom_fn = 8'h3F; 12'd1336: glyph_rom_fn = 8'h0C; 12'd1337: glyph_rom_fn = 8'h07; 12'd1338: glyph_rom_fn = 8'h03; 12'd1339: glyph_rom_fn = 8'h26; 12'd1340: glyph_rom_fn = 8'h34; 12'd1341: glyph_rom_fn = 8'h3F;
                12'd1345: glyph_rom_fn = 8'h22; 12'd1346: glyph_rom_fn = 8'h2A; 12'd1347: glyph_rom_fn = 8'h3E; 12'd1348: glyph_rom_fn = 8'h3E; 12'd1349: glyph_rom_fn = 8'hAA; 12'd1350: glyph_rom_fn = 8'hEA; 12'd1351: glyph_rom_fn = 8'hC0; 12'd1352: glyph_rom_fn = 8'hAA; 12'd1353: glyph_rom_fn = 8'hAA; 12'd1354: glyph_rom_fn = 8'h3E; 12'd1355: glyph_rom_fn = 8'h3E; 12'd1356: glyph_rom_fn = 8'h2A; 12'd1357: glyph_rom_fn = 8'h22;
                12'd1361: glyph_rom_fn = 8'h02; 12'd1362: glyph_rom_fn = 8'h06; 12'd1363: glyph_rom_fn = 8'h07; 12'd1364: glyph_rom_fn = 8'h05; 12'd1365: glyph_rom_fn = 8'h05; 12'd1366: glyph_rom_fn = 8'h04; 12'd1367: glyph_rom_fn = 8'h26; 12'd1368: glyph_rom_fn = 8'h24; 12'd1369: glyph_rom_fn = 8'h15; 12'd1370: glyph_rom_fn = 8'h1D; 12'd1371: glyph_rom_fn = 8'h0F; 12'd1372: glyph_rom_fn = 8'h07; 12'd1373: glyph_rom_fn = 8'h02;
                12'd1377: glyph_rom_fn = 8'hF8; 12'd1378: glyph_rom_fn = 8'hF8; 12'd1379: glyph_rom_fn = 8'h48; 12'd1380: glyph_rom_fn = 8'h48; 12'd1381: glyph_rom_fn = 8'h48; 12'd1382: glyph_rom_fn = 8'hFE; 12'd1383: glyph_rom_fn = 8'hFE; 12'd1384: glyph_rom_fn = 8'h48; 12'd1385: glyph_rom_fn = 8'h48; 12'd1386: glyph_rom_fn = 8'h48; 12'd1387: glyph_rom_fn = 8'hF8;
                12'd1393: glyph_rom_fn = 8'h07; 12'd1394: glyph_rom_fn = 8'h07; 12'd1395: glyph_rom_fn = 8'h06; 12'd1396: glyph_rom_fn = 8'h06; 12'd1397: glyph_rom_fn = 8'h06; 12'd1398: glyph_rom_fn = 8'h1F; 12'd1399: glyph_rom_fn = 8'h3F; 12'd1400: glyph_rom_fn = 8'h26; 12'd1401: glyph_rom_fn = 8'h26; 12'd1402: glyph_rom_fn = 8'h26; 12'd1403: glyph_rom_fn = 8'h27; 12'd1404: glyph_rom_fn = 8'h20; 12'd1405: glyph_rom_fn = 8'h38;
                12'd1409: glyph_rom_fn = 8'h10; 12'd1410: glyph_rom_fn = 8'h10; 12'd1411: glyph_rom_fn = 8'h10; 12'd1412: glyph_rom_fn = 8'hF0; 12'd1413: glyph_rom_fn = 8'h70; 12'd1415: glyph_rom_fn = 8'hFE; 12'd1416: glyph_rom_fn = 8'h70; 12'd1417: glyph_rom_fn = 8'hE0; 12'd1418: glyph_rom_fn = 8'h60; 12'd1419: glyph_rom_fn = 8'h30; 12'd1420: glyph_rom_fn = 8'h18; 12'd1421: glyph_rom_fn = 8'h08;
                12'd1425: glyph_rom_fn = 8'h18; 12'd1426: glyph_rom_fn = 8'h0C; 12'd1427: glyph_rom_fn = 8'h07; 12'd1428: glyph_rom_fn = 8'h21; 12'd1429: glyph_rom_fn = 8'h20; 12'd1430: glyph_rom_fn = 8'h20; 12'd1431: glyph_rom_fn = 8'h3F; 12'd1433: glyph_rom_fn = 8'h01; 12'd1434: glyph_rom_fn = 8'h03; 12'd1435: glyph_rom_fn = 8'h06; 12'd1436: glyph_rom_fn = 8'h0C; 12'd1437: glyph_rom_fn = 8'h18;
                12'd1442: glyph_rom_fn = 8'hBC; 12'd1443: glyph_rom_fn = 8'hFE; 12'd1444: glyph_rom_fn = 8'hDE; 12'd1445: glyph_rom_fn = 8'hDE; 12'd1446: glyph_rom_fn = 8'hDE; 12'd1447: glyph_rom_fn = 8'h5E; 12'd1448: glyph_rom_fn = 8'hDE; 12'd1449: glyph_rom_fn = 8'hDE; 12'd1450: glyph_rom_fn = 8'hDE; 12'd1451: glyph_rom_fn = 8'hFE; 12'd1452: glyph_rom_fn = 8'hBC;
                12'd1457: glyph_rom_fn = 8'h3F; 12'd1458: glyph_rom_fn = 8'h3D; 12'd1459: glyph_rom_fn = 8'h25; 12'd1460: glyph_rom_fn = 8'h25; 12'd1461: glyph_rom_fn = 8'h35; 12'd1462: glyph_rom_fn = 8'h3F; 12'd1464: glyph_rom_fn = 8'h3F; 12'd1465: glyph_rom_fn = 8'h35; 12'd1466: glyph_rom_fn = 8'h25; 12'd1467: glyph_rom_fn = 8'h25; 12'd1468: glyph_rom_fn = 8'h3D; 12'd1469: glyph_rom_fn = 8'h3F;
                12'd1476: glyph_rom_fn = 8'hE0; 12'd1477: glyph_rom_fn = 8'h7C; 12'd1481: glyph_rom_fn = 8'h7C; 12'd1482: glyph_rom_fn = 8'hE0;
                12'd1489: glyph_rom_fn = 8'h30; 12'd1490: glyph_rom_fn = 8'h18; 12'd1491: glyph_rom_fn = 8'h0E; 12'd1492: glyph_rom_fn = 8'h03; 12'd1498: glyph_rom_fn = 8'h03; 12'd1499: glyph_rom_fn = 8'h0F; 12'd1500: glyph_rom_fn = 8'h1C; 12'd1501: glyph_rom_fn = 8'h30;
                12'd1505: glyph_rom_fn = 8'h14; 12'd1506: glyph_rom_fn = 8'h94; 12'd1507: glyph_rom_fn = 8'hDE; 12'd1508: glyph_rom_fn = 8'hFE; 12'd1509: glyph_rom_fn = 8'hF4; 12'd1510: glyph_rom_fn = 8'h9C; 12'd1511: glyph_rom_fn = 8'h9C; 12'd1512: glyph_rom_fn = 8'hF0; 12'd1513: glyph_rom_fn = 8'hFE; 12'd1514: glyph_rom_fn = 8'h18; 12'd1515: glyph_rom_fn = 8'h98; 12'd1516: glyph_rom_fn = 8'hF8; 12'd1517: glyph_rom_fn = 8'h18;
                12'd1521: glyph_rom_fn = 8'h09; 12'd1522: glyph_rom_fn = 8'h2D; 12'd1523: glyph_rom_fn = 8'h2C; 12'd1524: glyph_rom_fn = 8'h3F; 12'd1525: glyph_rom_fn = 8'h05; 12'd1526: glyph_rom_fn = 8'h04; 12'd1527: glyph_rom_fn = 8'h24; 12'd1528: glyph_rom_fn = 8'h30; 12'd1529: glyph_rom_fn = 8'h19; 12'd1530: glyph_rom_fn = 8'h0F; 12'd1531: glyph_rom_fn = 8'h0F; 12'd1532: glyph_rom_fn = 8'h31; 12'd1533: glyph_rom_fn = 8'h30;
                12'd1537: glyph_rom_fn = 8'h70; 12'd1538: glyph_rom_fn = 8'h30; 12'd1539: glyph_rom_fn = 8'h9C; 12'd1540: glyph_rom_fn = 8'hD8; 12'd1541: glyph_rom_fn = 8'hD0; 12'd1542: glyph_rom_fn = 8'hD0; 12'd1543: glyph_rom_fn = 8'hDC; 12'd1544: glyph_rom_fn = 8'hD0; 12'd1545: glyph_rom_fn = 8'hD0; 12'd1546: glyph_rom_fn = 8'hDC; 12'd1547: glyph_rom_fn = 8'h94; 12'd1548: glyph_rom_fn = 8'h30; 12'd1549: glyph_rom_fn = 8'h70;
                12'd1553: glyph_rom_fn = 8'h40; 12'd1554: glyph_rom_fn = 8'h58; 12'd1555: glyph_rom_fn = 8'h5B; 12'd1556: glyph_rom_fn = 8'h5B; 12'd1557: glyph_rom_fn = 8'h5A; 12'd1558: glyph_rom_fn = 8'h5A; 12'd1559: glyph_rom_fn = 8'h7E; 12'd1560: glyph_rom_fn = 8'h5A; 12'd1561: glyph_rom_fn = 8'h5A; 12'd1562: glyph_rom_fn = 8'h5B; 12'd1563: glyph_rom_fn = 8'h5B; 12'd1564: glyph_rom_fn = 8'h58; 12'd1565: glyph_rom_fn = 8'h40;
                12'd1570: glyph_rom_fn = 8'hFC; 12'd1571: glyph_rom_fn = 8'hFE; 12'd1572: glyph_rom_fn = 8'h26; 12'd1573: glyph_rom_fn = 8'h66; 12'd1574: glyph_rom_fn = 8'hC6; 12'd1575: glyph_rom_fn = 8'h86; 12'd1576: glyph_rom_fn = 8'hE6; 12'd1577: glyph_rom_fn = 8'h36; 12'd1578: glyph_rom_fn = 8'h06; 12'd1579: glyph_rom_fn = 8'hFE;
                12'd1585: glyph_rom_fn = 8'h30; 12'd1586: glyph_rom_fn = 8'h1F; 12'd1587: glyph_rom_fn = 8'h03; 12'd1588: glyph_rom_fn = 8'h08; 12'd1589: glyph_rom_fn = 8'h04; 12'd1590: glyph_rom_fn = 8'h03; 12'd1591: glyph_rom_fn = 8'h03; 12'd1592: glyph_rom_fn = 8'h07; 12'd1593: glyph_rom_fn = 8'h0C; 12'd1595: glyph_rom_fn = 8'h1F; 12'd1596: glyph_rom_fn = 8'h38; 12'd1597: glyph_rom_fn = 8'h38; 12'd1598: glyph_rom_fn = 8'h08;
                12'd1601: glyph_rom_fn = 8'h10; 12'd1602: glyph_rom_fn = 8'h10; 12'd1603: glyph_rom_fn = 8'h10; 12'd1604: glyph_rom_fn = 8'h10; 12'd1605: glyph_rom_fn = 8'h10; 12'd1606: glyph_rom_fn = 8'h10; 12'd1607: glyph_rom_fn = 8'hFE; 12'd1608: glyph_rom_fn = 8'h10; 12'd1609: glyph_rom_fn = 8'h10; 12'd1610: glyph_rom_fn = 8'h10; 12'd1611: glyph_rom_fn = 8'h10; 12'd1612: glyph_rom_fn = 8'h10; 12'd1613: glyph_rom_fn = 8'h10;
                12'd1619: glyph_rom_fn = 8'h3F; 12'd1620: glyph_rom_fn = 8'h11; 12'd1621: glyph_rom_fn = 8'h11; 12'd1622: glyph_rom_fn = 8'h11; 12'd1623: glyph_rom_fn = 8'h11; 12'd1624: glyph_rom_fn = 8'h11; 12'd1625: glyph_rom_fn = 8'h11; 12'd1626: glyph_rom_fn = 8'h11; 12'd1627: glyph_rom_fn = 8'h3F; 12'd1628: glyph_rom_fn = 8'h3F;
                12'd1633: glyph_rom_fn = 8'h08; 12'd1634: glyph_rom_fn = 8'h48; 12'd1635: glyph_rom_fn = 8'h48; 12'd1636: glyph_rom_fn = 8'h48; 12'd1637: glyph_rom_fn = 8'h48; 12'd1638: glyph_rom_fn = 8'h48; 12'd1639: glyph_rom_fn = 8'h7E; 12'd1640: glyph_rom_fn = 8'h48; 12'd1641: glyph_rom_fn = 8'h48; 12'd1642: glyph_rom_fn = 8'h48; 12'd1643: glyph_rom_fn = 8'h48; 12'd1644: glyph_rom_fn = 8'h48; 12'd1645: glyph_rom_fn = 8'h08;
                12'd1650: glyph_rom_fn = 8'h3E; 12'd1651: glyph_rom_fn = 8'h3F; 12'd1652: glyph_rom_fn = 8'h13; 12'd1653: glyph_rom_fn = 8'h13; 12'd1654: glyph_rom_fn = 8'h13; 12'd1655: glyph_rom_fn = 8'h13; 12'd1656: glyph_rom_fn = 8'h13; 12'd1657: glyph_rom_fn = 8'h13; 12'd1658: glyph_rom_fn = 8'h13; 12'd1659: glyph_rom_fn = 8'h3F; 12'd1660: glyph_rom_fn = 8'h3E;
                12'd1665: glyph_rom_fn = 8'hE0; 12'd1666: glyph_rom_fn = 8'hF8; 12'd1667: glyph_rom_fn = 8'hFE; 12'd1668: glyph_rom_fn = 8'h42; 12'd1669: glyph_rom_fn = 8'hF8; 12'd1670: glyph_rom_fn = 8'hF8; 12'd1671: glyph_rom_fn = 8'h20; 12'd1672: glyph_rom_fn = 8'h20; 12'd1673: glyph_rom_fn = 8'hFE; 12'd1674: glyph_rom_fn = 8'h30; 12'd1675: glyph_rom_fn = 8'h10; 12'd1676: glyph_rom_fn = 8'hF0;
                12'd1682: glyph_rom_fn = 8'h3F; 12'd1683: glyph_rom_fn = 8'h3F; 12'd1685: glyph_rom_fn = 8'h1F; 12'd1686: glyph_rom_fn = 8'h3F; 12'd1687: glyph_rom_fn = 8'h20; 12'd1688: glyph_rom_fn = 8'h20; 12'd1689: glyph_rom_fn = 8'h27; 12'd1690: glyph_rom_fn = 8'h20; 12'd1691: glyph_rom_fn = 8'h26; 12'd1692: glyph_rom_fn = 8'h23; 12'd1693: glyph_rom_fn = 8'h38;
                12'd1697: glyph_rom_fn = 8'h88; 12'd1698: glyph_rom_fn = 8'hC8; 12'd1699: glyph_rom_fn = 8'h68; 12'd1700: glyph_rom_fn = 8'h28; 12'd1701: glyph_rom_fn = 8'h08; 12'd1702: glyph_rom_fn = 8'h0E; 12'd1703: glyph_rom_fn = 8'h0E; 12'd1704: glyph_rom_fn = 8'h08; 12'd1705: glyph_rom_fn = 8'h08; 12'd1706: glyph_rom_fn = 8'hA8; 12'd1707: glyph_rom_fn = 8'h68; 12'd1708: glyph_rom_fn = 8'hC8; 12'd1709: glyph_rom_fn = 8'h08;
                12'd1713: glyph_rom_fn = 8'h20; 12'd1714: glyph_rom_fn = 8'h20; 12'd1715: glyph_rom_fn = 8'h30; 12'd1716: glyph_rom_fn = 8'h11; 12'd1717: glyph_rom_fn = 8'h13; 12'd1718: glyph_rom_fn = 8'h0E; 12'd1719: glyph_rom_fn = 8'h0C; 12'd1720: glyph_rom_fn = 8'h0E; 12'd1721: glyph_rom_fn = 8'h1B; 12'd1722: glyph_rom_fn = 8'h11; 12'd1723: glyph_rom_fn = 8'h30; 12'd1724: glyph_rom_fn = 8'h20; 12'd1725: glyph_rom_fn = 8'h20;
                12'd1729: glyph_rom_fn = 8'hE6; 12'd1730: glyph_rom_fn = 8'h66; 12'd1731: glyph_rom_fn = 8'h26; 12'd1732: glyph_rom_fn = 8'h3E; 12'd1734: glyph_rom_fn = 8'h8C; 12'd1735: glyph_rom_fn = 8'hCC; 12'd1736: glyph_rom_fn = 8'h7C; 12'd1737: glyph_rom_fn = 8'h8E; 12'd1738: glyph_rom_fn = 8'h8C; 12'd1739: glyph_rom_fn = 8'hCC; 12'd1740: glyph_rom_fn = 8'h0C; 12'd1741: glyph_rom_fn = 8'h0C;
                12'd1745: glyph_rom_fn = 8'h01; 12'd1746: glyph_rom_fn = 8'h21; 12'd1747: glyph_rom_fn = 8'h21; 12'd1748: glyph_rom_fn = 8'h3F; 12'd1750: glyph_rom_fn = 8'h31; 12'd1751: glyph_rom_fn = 8'h39; 12'd1752: glyph_rom_fn = 8'h3D; 12'd1753: glyph_rom_fn = 8'h37; 12'd1754: glyph_rom_fn = 8'h13; 12'd1755: glyph_rom_fn = 8'h14; 12'd1756: glyph_rom_fn = 8'h1C; 12'd1757: glyph_rom_fn = 8'h30;
                12'd1762: glyph_rom_fn = 8'h42; 12'd1763: glyph_rom_fn = 8'h5A; 12'd1764: glyph_rom_fn = 8'h5A; 12'd1765: glyph_rom_fn = 8'h5A; 12'd1766: glyph_rom_fn = 8'h5A; 12'd1767: glyph_rom_fn = 8'hDA; 12'd1768: glyph_rom_fn = 8'h5A; 12'd1769: glyph_rom_fn = 8'h5A; 12'd1770: glyph_rom_fn = 8'h5A; 12'd1771: glyph_rom_fn = 8'h7E; 12'd1772: glyph_rom_fn = 8'h7E;
                12'd1777: glyph_rom_fn = 8'h20; 12'd1778: glyph_rom_fn = 8'h26; 12'd1779: glyph_rom_fn = 8'h33; 12'd1780: glyph_rom_fn = 8'h10; 12'd1781: glyph_rom_fn = 8'h18; 12'd1782: glyph_rom_fn = 8'h0E; 12'd1783: glyph_rom_fn = 8'h07; 12'd1784: glyph_rom_fn = 8'h06; 12'd1785: glyph_rom_fn = 8'h0C; 12'd1786: glyph_rom_fn = 8'h12; 12'd1787: glyph_rom_fn = 8'h33; 12'd1788: glyph_rom_fn = 8'h21; 12'd1789: glyph_rom_fn = 8'h20;
                12'd1793: glyph_rom_fn = 8'h40; 12'd1794: glyph_rom_fn = 8'h40; 12'd1795: glyph_rom_fn = 8'hC0; 12'd1796: glyph_rom_fn = 8'hFE; 12'd1797: glyph_rom_fn = 8'h40; 12'd1798: glyph_rom_fn = 8'h40; 12'd1799: glyph_rom_fn = 8'hF0; 12'd1800: glyph_rom_fn = 8'hD8; 12'd1801: glyph_rom_fn = 8'h4C; 12'd1802: glyph_rom_fn = 8'h46; 12'd1803: glyph_rom_fn = 8'h42; 12'd1804: glyph_rom_fn = 8'h40; 12'd1805: glyph_rom_fn = 8'h40;
                12'd1812: glyph_rom_fn = 8'h3F; 12'd1813: glyph_rom_fn = 8'h30; 12'd1814: glyph_rom_fn = 8'h10; 12'd1816: glyph_rom_fn = 8'h03; 12'd1817: glyph_rom_fn = 8'h06; 12'd1818: glyph_rom_fn = 8'h0C; 12'd1819: glyph_rom_fn = 8'h18; 12'd1820: glyph_rom_fn = 8'h30; 12'd1821: glyph_rom_fn = 8'h10;
                12'd1825: glyph_rom_fn = 8'h10; 12'd1826: glyph_rom_fn = 8'hDC; 12'd1827: glyph_rom_fn = 8'hC6; 12'd1828: glyph_rom_fn = 8'hCC; 12'd1829: glyph_rom_fn = 8'hDC; 12'd1830: glyph_rom_fn = 8'hC4; 12'd1831: glyph_rom_fn = 8'hE4; 12'd1832: glyph_rom_fn = 8'hDC; 12'd1833: glyph_rom_fn = 8'hCE; 12'd1834: glyph_rom_fn = 8'hCC; 12'd1835: glyph_rom_fn = 8'hDC; 12'd1836: glyph_rom_fn = 8'hC4; 12'd1837: glyph_rom_fn = 8'h04;
                12'd1842: glyph_rom_fn = 8'h3F; 12'd1843: glyph_rom_fn = 8'h36; 12'd1844: glyph_rom_fn = 8'h36; 12'd1845: glyph_rom_fn = 8'h36; 12'd1846: glyph_rom_fn = 8'h36; 12'd1847: glyph_rom_fn = 8'h3F; 12'd1848: glyph_rom_fn = 8'h36; 12'd1849: glyph_rom_fn = 8'h36; 12'd1850: glyph_rom_fn = 8'h36; 12'd1851: glyph_rom_fn = 8'h36; 12'd1852: glyph_rom_fn = 8'h3F;
                12'd1857: glyph_rom_fn = 8'h10; 12'd1858: glyph_rom_fn = 8'h10; 12'd1859: glyph_rom_fn = 8'h10; 12'd1860: glyph_rom_fn = 8'h10; 12'd1861: glyph_rom_fn = 8'h90; 12'd1862: glyph_rom_fn = 8'h70; 12'd1863: glyph_rom_fn = 8'hFE; 12'd1864: glyph_rom_fn = 8'h70; 12'd1865: glyph_rom_fn = 8'h90; 12'd1866: glyph_rom_fn = 8'h10; 12'd1867: glyph_rom_fn = 8'h10; 12'd1868: glyph_rom_fn = 8'h10; 12'd1869: glyph_rom_fn = 8'h10;
                12'd1873: glyph_rom_fn = 8'h18; 12'd1874: glyph_rom_fn = 8'h0C; 12'd1875: glyph_rom_fn = 8'h06; 12'd1876: glyph_rom_fn = 8'h03; 12'd1877: glyph_rom_fn = 8'h01; 12'd1879: glyph_rom_fn = 8'h3F; 12'd1881: glyph_rom_fn = 8'h01; 12'd1882: glyph_rom_fn = 8'h03; 12'd1883: glyph_rom_fn = 8'h06; 12'd1884: glyph_rom_fn = 8'h0C; 12'd1885: glyph_rom_fn = 8'h18;
                12'd1889: glyph_rom_fn = 8'h68; 12'd1890: glyph_rom_fn = 8'h24; 12'd1891: glyph_rom_fn = 8'hA6; 12'd1892: glyph_rom_fn = 8'hA4; 12'd1893: glyph_rom_fn = 8'hAC; 12'd1894: glyph_rom_fn = 8'hB4; 12'd1895: glyph_rom_fn = 8'hBC; 12'd1896: glyph_rom_fn = 8'hAC; 12'd1897: glyph_rom_fn = 8'hA6; 12'd1898: glyph_rom_fn = 8'hA4; 12'd1899: glyph_rom_fn = 8'hAC; 12'd1900: glyph_rom_fn = 8'h24; 12'd1901: glyph_rom_fn = 8'h64;
                12'd1907: glyph_rom_fn = 8'h3F; 12'd1908: glyph_rom_fn = 8'h2E; 12'd1909: glyph_rom_fn = 8'h2E; 12'd1910: glyph_rom_fn = 8'h2E; 12'd1911: glyph_rom_fn = 8'h2E; 12'd1912: glyph_rom_fn = 8'h2E; 12'd1913: glyph_rom_fn = 8'h2E; 12'd1914: glyph_rom_fn = 8'h2F; 12'd1915: glyph_rom_fn = 8'h3F; 12'd1916: glyph_rom_fn = 8'h3C;
                12'd1922: glyph_rom_fn = 8'hF8; 12'd1923: glyph_rom_fn = 8'hF8; 12'd1924: glyph_rom_fn = 8'h4A; 12'd1925: glyph_rom_fn = 8'h4E; 12'd1926: glyph_rom_fn = 8'h68; 12'd1927: glyph_rom_fn = 8'hF8; 12'd1928: glyph_rom_fn = 8'h68; 12'd1929: glyph_rom_fn = 8'h4C; 12'd1930: glyph_rom_fn = 8'h4E; 12'd1931: glyph_rom_fn = 8'hF8; 12'd1932: glyph_rom_fn = 8'hF8;
                12'd1937: glyph_rom_fn = 8'h08; 12'd1938: glyph_rom_fn = 8'h09; 12'd1939: glyph_rom_fn = 8'h09; 12'd1940: glyph_rom_fn = 8'h09; 12'd1941: glyph_rom_fn = 8'h09; 12'd1942: glyph_rom_fn = 8'h0B; 12'd1943: glyph_rom_fn = 8'h7F; 12'd1944: glyph_rom_fn = 8'h0B; 12'd1945: glyph_rom_fn = 8'h09; 12'd1946: glyph_rom_fn = 8'h09; 12'd1947: glyph_rom_fn = 8'h09; 12'd1948: glyph_rom_fn = 8'h09; 12'd1949: glyph_rom_fn = 8'h08;
                12'd1953: glyph_rom_fn = 8'hC8; 12'd1954: glyph_rom_fn = 8'hFE; 12'd1955: glyph_rom_fn = 8'hF6; 12'd1956: glyph_rom_fn = 8'hF4; 12'd1957: glyph_rom_fn = 8'hFC; 12'd1958: glyph_rom_fn = 8'hF4; 12'd1959: glyph_rom_fn = 8'hF4; 12'd1960: glyph_rom_fn = 8'hF6; 12'd1961: glyph_rom_fn = 8'hF6; 12'd1962: glyph_rom_fn = 8'hF4; 12'd1963: glyph_rom_fn = 8'hFC; 12'd1964: glyph_rom_fn = 8'hF4; 12'd1965: glyph_rom_fn = 8'hE4;
                12'd1969: glyph_rom_fn = 8'h20; 12'd1970: glyph_rom_fn = 8'h2F; 12'd1971: glyph_rom_fn = 8'h3F; 12'd1972: glyph_rom_fn = 8'h3D; 12'd1973: glyph_rom_fn = 8'h3D; 12'd1974: glyph_rom_fn = 8'h1D; 12'd1975: glyph_rom_fn = 8'h1F; 12'd1976: glyph_rom_fn = 8'h1D; 12'd1977: glyph_rom_fn = 8'h3D; 12'd1978: glyph_rom_fn = 8'h3D; 12'd1979: glyph_rom_fn = 8'h3D; 12'd1980: glyph_rom_fn = 8'h3F; 12'd1981: glyph_rom_fn = 8'h20;
                12'd1985: glyph_rom_fn = 8'h5C; 12'd1986: glyph_rom_fn = 8'hD0; 12'd1987: glyph_rom_fn = 8'h7E; 12'd1988: glyph_rom_fn = 8'hD0; 12'd1989: glyph_rom_fn = 8'h5C; 12'd1991: glyph_rom_fn = 8'hAE; 12'd1992: glyph_rom_fn = 8'hE2; 12'd1993: glyph_rom_fn = 8'h3A; 12'd1994: glyph_rom_fn = 8'hF2; 12'd1995: glyph_rom_fn = 8'h22; 12'd1996: glyph_rom_fn = 8'h22; 12'd1997: glyph_rom_fn = 8'h2E;
                12'd2001: glyph_rom_fn = 8'h30; 12'd2002: glyph_rom_fn = 8'h0F; 12'd2004: glyph_rom_fn = 8'h1F; 12'd2005: glyph_rom_fn = 8'h18; 12'd2007: glyph_rom_fn = 8'h0D; 12'd2008: glyph_rom_fn = 8'h0D; 12'd2009: glyph_rom_fn = 8'h0D; 12'd2010: glyph_rom_fn = 8'h3F; 12'd2011: glyph_rom_fn = 8'h0D; 12'd2012: glyph_rom_fn = 8'h0D; 12'd2013: glyph_rom_fn = 8'h0D;
                12'd2017: glyph_rom_fn = 8'hF0; 12'd2018: glyph_rom_fn = 8'h10; 12'd2019: glyph_rom_fn = 8'hFE; 12'd2020: glyph_rom_fn = 8'h18; 12'd2021: glyph_rom_fn = 8'h0C; 12'd2022: glyph_rom_fn = 8'h7C; 12'd2023: glyph_rom_fn = 8'hFC; 12'd2024: glyph_rom_fn = 8'hD4; 12'd2025: glyph_rom_fn = 8'hD6; 12'd2026: glyph_rom_fn = 8'hD4; 12'd2027: glyph_rom_fn = 8'hD4; 12'd2028: glyph_rom_fn = 8'hFC; 12'd2029: glyph_rom_fn = 8'h7C;
                12'd2033: glyph_rom_fn = 8'h30; 12'd2034: glyph_rom_fn = 8'h1E; 12'd2035: glyph_rom_fn = 8'h07; 12'd2036: glyph_rom_fn = 8'h0C; 12'd2037: glyph_rom_fn = 8'h28; 12'd2038: glyph_rom_fn = 8'h2B; 12'd2039: glyph_rom_fn = 8'h2B; 12'd2040: glyph_rom_fn = 8'h2B; 12'd2041: glyph_rom_fn = 8'h3F; 12'd2042: glyph_rom_fn = 8'h3F; 12'd2043: glyph_rom_fn = 8'h2B; 12'd2044: glyph_rom_fn = 8'h2B; 12'd2045: glyph_rom_fn = 8'h2B;
                12'd2049: glyph_rom_fn = 8'h18; 12'd2050: glyph_rom_fn = 8'h2E; 12'd2051: glyph_rom_fn = 8'hEE; 12'd2052: glyph_rom_fn = 8'h28; 12'd2053: glyph_rom_fn = 8'h28; 12'd2055: glyph_rom_fn = 8'hFE; 12'd2056: glyph_rom_fn = 8'h12; 12'd2057: glyph_rom_fn = 8'hD2; 12'd2058: glyph_rom_fn = 8'hD2; 12'd2059: glyph_rom_fn = 8'hD2; 12'd2060: glyph_rom_fn = 8'h06; 12'd2061: glyph_rom_fn = 8'hFE;
                12'd2065: glyph_rom_fn = 8'h01; 12'd2066: glyph_rom_fn = 8'h01; 12'd2067: glyph_rom_fn = 8'h3F; 12'd2068: glyph_rom_fn = 8'h31; 12'd2069: glyph_rom_fn = 8'h11; 12'd2071: glyph_rom_fn = 8'h3F; 12'd2073: glyph_rom_fn = 8'h0F; 12'd2074: glyph_rom_fn = 8'h0C; 12'd2075: glyph_rom_fn = 8'h2F; 12'd2076: glyph_rom_fn = 8'h20; 12'd2077: glyph_rom_fn = 8'h3F;
                12'd2083: glyph_rom_fn = 8'h02; 12'd2084: glyph_rom_fn = 8'hFA; 12'd2085: glyph_rom_fn = 8'h82; 12'd2086: glyph_rom_fn = 8'h82; 12'd2087: glyph_rom_fn = 8'h82; 12'd2088: glyph_rom_fn = 8'h82; 12'd2089: glyph_rom_fn = 8'h82; 12'd2090: glyph_rom_fn = 8'hFE; 12'd2091: glyph_rom_fn = 8'h9E; 12'd2092: glyph_rom_fn = 8'h80; 12'd2093: glyph_rom_fn = 8'h80;
                12'd2098: glyph_rom_fn = 8'h0C; 12'd2099: glyph_rom_fn = 8'h0C; 12'd2100: glyph_rom_fn = 8'h0D; 12'd2101: glyph_rom_fn = 8'h0D; 12'd2102: glyph_rom_fn = 8'h0D; 12'd2103: glyph_rom_fn = 8'h0D; 12'd2104: glyph_rom_fn = 8'h0D; 12'd2105: glyph_rom_fn = 8'h2D; 12'd2106: glyph_rom_fn = 8'h21; 12'd2107: glyph_rom_fn = 8'h21; 12'd2108: glyph_rom_fn = 8'h3F; 12'd2109: glyph_rom_fn = 8'h07;
                12'd2113: glyph_rom_fn = 8'h18; 12'd2114: glyph_rom_fn = 8'h98; 12'd2115: glyph_rom_fn = 8'hFE; 12'd2116: glyph_rom_fn = 8'hFE; 12'd2117: glyph_rom_fn = 8'hD8; 12'd2118: glyph_rom_fn = 8'h98; 12'd2120: glyph_rom_fn = 8'h98; 12'd2121: glyph_rom_fn = 8'hF8; 12'd2122: glyph_rom_fn = 8'hFE; 12'd2123: glyph_rom_fn = 8'hD8; 12'd2124: glyph_rom_fn = 8'h18;
                12'd2129: glyph_rom_fn = 8'h06; 12'd2130: glyph_rom_fn = 8'h03; 12'd2131: glyph_rom_fn = 8'h3F; 12'd2132: glyph_rom_fn = 8'h3F; 12'd2134: glyph_rom_fn = 8'h01; 12'd2135: glyph_rom_fn = 8'h0E; 12'd2136: glyph_rom_fn = 8'h03; 12'd2137: glyph_rom_fn = 8'h01; 12'd2138: glyph_rom_fn = 8'h3F; 12'd2139: glyph_rom_fn = 8'h01; 12'd2140: glyph_rom_fn = 8'h07; 12'd2141: glyph_rom_fn = 8'h0C;
                12'd2145: glyph_rom_fn = 8'h08; 12'd2146: glyph_rom_fn = 8'hEE; 12'd2147: glyph_rom_fn = 8'hAE; 12'd2148: glyph_rom_fn = 8'hAE; 12'd2149: glyph_rom_fn = 8'hAE; 12'd2150: glyph_rom_fn = 8'hBE; 12'd2151: glyph_rom_fn = 8'hFE; 12'd2152: glyph_rom_fn = 8'hAA; 12'd2153: glyph_rom_fn = 8'hAA; 12'd2154: glyph_rom_fn = 8'hAA; 12'd2155: glyph_rom_fn = 8'hAA; 12'd2156: glyph_rom_fn = 8'hEA; 12'd2157: glyph_rom_fn = 8'h08;
                12'd2161: glyph_rom_fn = 8'h28; 12'd2162: glyph_rom_fn = 8'h2B; 12'd2163: glyph_rom_fn = 8'h2A; 12'd2164: glyph_rom_fn = 8'h2A; 12'd2165: glyph_rom_fn = 8'h2A; 12'd2166: glyph_rom_fn = 8'h2A; 12'd2167: glyph_rom_fn = 8'h3F; 12'd2168: glyph_rom_fn = 8'h2A; 12'd2169: glyph_rom_fn = 8'h2A; 12'd2170: glyph_rom_fn = 8'h2A; 12'd2171: glyph_rom_fn = 8'h2A; 12'd2172: glyph_rom_fn = 8'h2B; 12'd2173: glyph_rom_fn = 8'h28;
                12'd2177: glyph_rom_fn = 8'hC0; 12'd2178: glyph_rom_fn = 8'h70; 12'd2179: glyph_rom_fn = 8'hFE; 12'd2180: glyph_rom_fn = 8'h02; 12'd2181: glyph_rom_fn = 8'hFC; 12'd2182: glyph_rom_fn = 8'hFC; 12'd2183: glyph_rom_fn = 8'h44; 12'd2184: glyph_rom_fn = 8'h46; 12'd2185: glyph_rom_fn = 8'h7E; 12'd2186: glyph_rom_fn = 8'hFE; 12'd2187: glyph_rom_fn = 8'h42; 12'd2188: glyph_rom_fn = 8'h42; 12'd2189: glyph_rom_fn = 8'h40;
                12'd2195: glyph_rom_fn = 8'h3F; 12'd2197: glyph_rom_fn = 8'h1F; 12'd2198: glyph_rom_fn = 8'h3F; 12'd2199: glyph_rom_fn = 8'h20; 12'd2201: glyph_rom_fn = 8'h30; 12'd2202: glyph_rom_fn = 8'h0F; 12'd2203: glyph_rom_fn = 8'h3C; 12'd2204: glyph_rom_fn = 8'h20; 12'd2205: glyph_rom_fn = 8'h38;
                12'd2211: glyph_rom_fn = 8'hFE; 12'd2212: glyph_rom_fn = 8'h06; 12'd2213: glyph_rom_fn = 8'h06; 12'd2214: glyph_rom_fn = 8'h06; 12'd2215: glyph_rom_fn = 8'hF6; 12'd2216: glyph_rom_fn = 8'h06; 12'd2217: glyph_rom_fn = 8'h06; 12'd2218: glyph_rom_fn = 8'h06; 12'd2219: glyph_rom_fn = 8'hFE;
                12'd2225: glyph_rom_fn = 8'h20; 12'd2226: glyph_rom_fn = 8'h20; 12'd2227: glyph_rom_fn = 8'h33; 12'd2228: glyph_rom_fn = 8'h10; 12'd2229: glyph_rom_fn = 8'h08; 12'd2230: glyph_rom_fn = 8'h0E; 12'd2231: glyph_rom_fn = 8'h03; 12'd2233: glyph_rom_fn = 8'h0C; 12'd2234: glyph_rom_fn = 8'h08; 12'd2235: glyph_rom_fn = 8'h13; 12'd2236: glyph_rom_fn = 8'h30; 12'd2237: glyph_rom_fn = 8'h20;
                12'd2242: glyph_rom_fn = 8'h16; 12'd2243: glyph_rom_fn = 8'h96; 12'd2244: glyph_rom_fn = 8'h96; 12'd2245: glyph_rom_fn = 8'h96; 12'd2246: glyph_rom_fn = 8'h96; 12'd2247: glyph_rom_fn = 8'h96; 12'd2248: glyph_rom_fn = 8'h96; 12'd2249: glyph_rom_fn = 8'h96; 12'd2250: glyph_rom_fn = 8'h06; 12'd2251: glyph_rom_fn = 8'h06; 12'd2252: glyph_rom_fn = 8'hFE;
                12'd2259: glyph_rom_fn = 8'h0F; 12'd2260: glyph_rom_fn = 8'h04; 12'd2261: glyph_rom_fn = 8'h04; 12'd2262: glyph_rom_fn = 8'h04; 12'd2263: glyph_rom_fn = 8'h04; 12'd2264: glyph_rom_fn = 8'h07; 12'd2265: glyph_rom_fn = 8'h07; 12'd2266: glyph_rom_fn = 8'h20; 12'd2267: glyph_rom_fn = 8'h20; 12'd2268: glyph_rom_fn = 8'h3F;
                12'd2274: glyph_rom_fn = 8'hF8; 12'd2275: glyph_rom_fn = 8'hC8; 12'd2276: glyph_rom_fn = 8'h88; 12'd2277: glyph_rom_fn = 8'h88; 12'd2278: glyph_rom_fn = 8'h88; 12'd2279: glyph_rom_fn = 8'h08; 12'd2280: glyph_rom_fn = 8'h7E; 12'd2281: glyph_rom_fn = 8'hFC; 12'd2282: glyph_rom_fn = 8'h08; 12'd2283: glyph_rom_fn = 8'hCE; 12'd2284: glyph_rom_fn = 8'hC8; 12'd2285: glyph_rom_fn = 8'h08;
                12'd2289: glyph_rom_fn = 8'h38; 12'd2290: glyph_rom_fn = 8'h0F; 12'd2292: glyph_rom_fn = 8'h10; 12'd2293: glyph_rom_fn = 8'h18; 12'd2294: glyph_rom_fn = 8'h0F; 12'd2295: glyph_rom_fn = 8'h20; 12'd2296: glyph_rom_fn = 8'h30; 12'd2297: glyph_rom_fn = 8'h1F; 12'd2298: glyph_rom_fn = 8'h1E; 12'd2299: glyph_rom_fn = 8'h33; 12'd2300: glyph_rom_fn = 8'h20; 12'd2301: glyph_rom_fn = 8'h30;
                12'd2305: glyph_rom_fn = 8'h10; 12'd2306: glyph_rom_fn = 8'h30; 12'd2307: glyph_rom_fn = 8'h30; 12'd2308: glyph_rom_fn = 8'h30; 12'd2309: glyph_rom_fn = 8'h30; 12'd2310: glyph_rom_fn = 8'h3C; 12'd2311: glyph_rom_fn = 8'hFC; 12'd2312: glyph_rom_fn = 8'h30; 12'd2313: glyph_rom_fn = 8'h30; 12'd2314: glyph_rom_fn = 8'h30; 12'd2315: glyph_rom_fn = 8'h30; 12'd2316: glyph_rom_fn = 8'h30; 12'd2317: glyph_rom_fn = 8'h10;
                12'd2321: glyph_rom_fn = 8'h40; 12'd2322: glyph_rom_fn = 8'h42; 12'd2323: glyph_rom_fn = 8'h42; 12'd2324: glyph_rom_fn = 8'h42; 12'd2325: glyph_rom_fn = 8'h42; 12'd2326: glyph_rom_fn = 8'h43; 12'd2327: glyph_rom_fn = 8'h7F; 12'd2328: glyph_rom_fn = 8'h42; 12'd2329: glyph_rom_fn = 8'h42; 12'd2330: glyph_rom_fn = 8'h42; 12'd2331: glyph_rom_fn = 8'h42; 12'd2332: glyph_rom_fn = 8'h42; 12'd2333: glyph_rom_fn = 8'h40;
                12'd2337: glyph_rom_fn = 8'hF0; 12'd2338: glyph_rom_fn = 8'hF8; 12'd2339: glyph_rom_fn = 8'h08; 12'd2340: glyph_rom_fn = 8'h08; 12'd2341: glyph_rom_fn = 8'hF8; 12'd2342: glyph_rom_fn = 8'hF0; 12'd2345: glyph_rom_fn = 8'hF0; 12'd2346: glyph_rom_fn = 8'hF8; 12'd2347: glyph_rom_fn = 8'h08; 12'd2348: glyph_rom_fn = 8'h08; 12'd2349: glyph_rom_fn = 8'hF8; 12'd2350: glyph_rom_fn = 8'hF0;
                12'd2353: glyph_rom_fn = 8'h0F; 12'd2354: glyph_rom_fn = 8'h1F; 12'd2355: glyph_rom_fn = 8'h10; 12'd2356: glyph_rom_fn = 8'h10; 12'd2357: glyph_rom_fn = 8'h1F; 12'd2358: glyph_rom_fn = 8'h0F; 12'd2361: glyph_rom_fn = 8'h0F; 12'd2362: glyph_rom_fn = 8'h1F; 12'd2363: glyph_rom_fn = 8'h10; 12'd2364: glyph_rom_fn = 8'h10; 12'd2365: glyph_rom_fn = 8'h1F; 12'd2366: glyph_rom_fn = 8'h0F;
                12'd2369: glyph_rom_fn = 8'hF0; 12'd2370: glyph_rom_fn = 8'hF8; 12'd2371: glyph_rom_fn = 8'h08; 12'd2372: glyph_rom_fn = 8'h08; 12'd2373: glyph_rom_fn = 8'hF8; 12'd2374: glyph_rom_fn = 8'hF0; 12'd2377: glyph_rom_fn = 8'h20; 12'd2378: glyph_rom_fn = 8'h30; 12'd2379: glyph_rom_fn = 8'hF8; 12'd2380: glyph_rom_fn = 8'hF8;
                12'd2385: glyph_rom_fn = 8'h0F; 12'd2386: glyph_rom_fn = 8'h1F; 12'd2387: glyph_rom_fn = 8'h10; 12'd2388: glyph_rom_fn = 8'h10; 12'd2389: glyph_rom_fn = 8'h1F; 12'd2390: glyph_rom_fn = 8'h0F; 12'd2393: glyph_rom_fn = 8'h10; 12'd2394: glyph_rom_fn = 8'h10; 12'd2395: glyph_rom_fn = 8'h1F; 12'd2396: glyph_rom_fn = 8'h1F; 12'd2397: glyph_rom_fn = 8'h10; 12'd2398: glyph_rom_fn = 8'h10;
                12'd2401: glyph_rom_fn = 8'hF0; 12'd2402: glyph_rom_fn = 8'hF8; 12'd2403: glyph_rom_fn = 8'h08; 12'd2404: glyph_rom_fn = 8'h08; 12'd2405: glyph_rom_fn = 8'hF8; 12'd2406: glyph_rom_fn = 8'hF0; 12'd2409: glyph_rom_fn = 8'h10; 12'd2410: glyph_rom_fn = 8'h18; 12'd2411: glyph_rom_fn = 8'h88; 12'd2412: glyph_rom_fn = 8'hC8; 12'd2413: glyph_rom_fn = 8'h78; 12'd2414: glyph_rom_fn = 8'h30;
                12'd2417: glyph_rom_fn = 8'h0F; 12'd2418: glyph_rom_fn = 8'h1F; 12'd2419: glyph_rom_fn = 8'h10; 12'd2420: glyph_rom_fn = 8'h10; 12'd2421: glyph_rom_fn = 8'h1F; 12'd2422: glyph_rom_fn = 8'h0F; 12'd2425: glyph_rom_fn = 8'h1E; 12'd2426: glyph_rom_fn = 8'h1F; 12'd2427: glyph_rom_fn = 8'h19; 12'd2428: glyph_rom_fn = 8'h18; 12'd2429: glyph_rom_fn = 8'h18; 12'd2430: glyph_rom_fn = 8'h18;
                12'd2433: glyph_rom_fn = 8'hF0; 12'd2434: glyph_rom_fn = 8'hF8; 12'd2435: glyph_rom_fn = 8'h08; 12'd2436: glyph_rom_fn = 8'h08; 12'd2437: glyph_rom_fn = 8'hF8; 12'd2438: glyph_rom_fn = 8'hF0; 12'd2441: glyph_rom_fn = 8'h10; 12'd2442: glyph_rom_fn = 8'h18; 12'd2443: glyph_rom_fn = 8'h88; 12'd2444: glyph_rom_fn = 8'h88; 12'd2445: glyph_rom_fn = 8'hF8; 12'd2446: glyph_rom_fn = 8'h70;
                12'd2449: glyph_rom_fn = 8'h0F; 12'd2450: glyph_rom_fn = 8'h1F; 12'd2451: glyph_rom_fn = 8'h10; 12'd2452: glyph_rom_fn = 8'h10; 12'd2453: glyph_rom_fn = 8'h1F; 12'd2454: glyph_rom_fn = 8'h0F; 12'd2457: glyph_rom_fn = 8'h08; 12'd2458: glyph_rom_fn = 8'h18; 12'd2459: glyph_rom_fn = 8'h10; 12'd2460: glyph_rom_fn = 8'h10; 12'd2461: glyph_rom_fn = 8'h1F; 12'd2462: glyph_rom_fn = 8'h0F;
                12'd2465: glyph_rom_fn = 8'hF0; 12'd2466: glyph_rom_fn = 8'hF8; 12'd2467: glyph_rom_fn = 8'h08; 12'd2468: glyph_rom_fn = 8'h08; 12'd2469: glyph_rom_fn = 8'hF8; 12'd2470: glyph_rom_fn = 8'hF0; 12'd2473: glyph_rom_fn = 8'hC0; 12'd2474: glyph_rom_fn = 8'hE0; 12'd2475: glyph_rom_fn = 8'h30; 12'd2476: glyph_rom_fn = 8'hF8; 12'd2477: glyph_rom_fn = 8'hF8;
                12'd2481: glyph_rom_fn = 8'h0F; 12'd2482: glyph_rom_fn = 8'h1F; 12'd2483: glyph_rom_fn = 8'h10; 12'd2484: glyph_rom_fn = 8'h10; 12'd2485: glyph_rom_fn = 8'h1F; 12'd2486: glyph_rom_fn = 8'h0F; 12'd2489: glyph_rom_fn = 8'h03; 12'd2490: glyph_rom_fn = 8'h03; 12'd2491: glyph_rom_fn = 8'h03; 12'd2492: glyph_rom_fn = 8'h1F; 12'd2493: glyph_rom_fn = 8'h1F; 12'd2494: glyph_rom_fn = 8'h03;
                12'd2497: glyph_rom_fn = 8'hF0; 12'd2498: glyph_rom_fn = 8'hF8; 12'd2499: glyph_rom_fn = 8'h08; 12'd2500: glyph_rom_fn = 8'h08; 12'd2501: glyph_rom_fn = 8'hF8; 12'd2502: glyph_rom_fn = 8'hF0; 12'd2505: glyph_rom_fn = 8'h78; 12'd2506: glyph_rom_fn = 8'h78; 12'd2507: glyph_rom_fn = 8'h48; 12'd2508: glyph_rom_fn = 8'h48; 12'd2509: glyph_rom_fn = 8'hC8; 12'd2510: glyph_rom_fn = 8'h88;
                12'd2513: glyph_rom_fn = 8'h0F; 12'd2514: glyph_rom_fn = 8'h1F; 12'd2515: glyph_rom_fn = 8'h10; 12'd2516: glyph_rom_fn = 8'h10; 12'd2517: glyph_rom_fn = 8'h1F; 12'd2518: glyph_rom_fn = 8'h0F; 12'd2521: glyph_rom_fn = 8'h08; 12'd2522: glyph_rom_fn = 8'h18; 12'd2523: glyph_rom_fn = 8'h10; 12'd2524: glyph_rom_fn = 8'h10; 12'd2525: glyph_rom_fn = 8'h1F; 12'd2526: glyph_rom_fn = 8'h0F;
                12'd2529: glyph_rom_fn = 8'hF0; 12'd2530: glyph_rom_fn = 8'hF8; 12'd2531: glyph_rom_fn = 8'h08; 12'd2532: glyph_rom_fn = 8'h08; 12'd2533: glyph_rom_fn = 8'hF8; 12'd2534: glyph_rom_fn = 8'hF0; 12'd2537: glyph_rom_fn = 8'hF0; 12'd2538: glyph_rom_fn = 8'hF8; 12'd2539: glyph_rom_fn = 8'h88; 12'd2540: glyph_rom_fn = 8'h88; 12'd2541: glyph_rom_fn = 8'h98; 12'd2542: glyph_rom_fn = 8'h10;
                12'd2545: glyph_rom_fn = 8'h0F; 12'd2546: glyph_rom_fn = 8'h1F; 12'd2547: glyph_rom_fn = 8'h10; 12'd2548: glyph_rom_fn = 8'h10; 12'd2549: glyph_rom_fn = 8'h1F; 12'd2550: glyph_rom_fn = 8'h0F; 12'd2553: glyph_rom_fn = 8'h0F; 12'd2554: glyph_rom_fn = 8'h1F; 12'd2555: glyph_rom_fn = 8'h10; 12'd2556: glyph_rom_fn = 8'h10; 12'd2557: glyph_rom_fn = 8'h1F; 12'd2558: glyph_rom_fn = 8'h0F;
                12'd2561: glyph_rom_fn = 8'hF0; 12'd2562: glyph_rom_fn = 8'hF8; 12'd2563: glyph_rom_fn = 8'h08; 12'd2564: glyph_rom_fn = 8'h08; 12'd2565: glyph_rom_fn = 8'hF8; 12'd2566: glyph_rom_fn = 8'hF0; 12'd2569: glyph_rom_fn = 8'h18; 12'd2570: glyph_rom_fn = 8'h18; 12'd2571: glyph_rom_fn = 8'h98; 12'd2572: glyph_rom_fn = 8'hD8; 12'd2573: glyph_rom_fn = 8'h78; 12'd2574: glyph_rom_fn = 8'h38;
                12'd2577: glyph_rom_fn = 8'h0F; 12'd2578: glyph_rom_fn = 8'h1F; 12'd2579: glyph_rom_fn = 8'h10; 12'd2580: glyph_rom_fn = 8'h10; 12'd2581: glyph_rom_fn = 8'h1F; 12'd2582: glyph_rom_fn = 8'h0F; 12'd2586: glyph_rom_fn = 8'h1E; 12'd2587: glyph_rom_fn = 8'h1F; 12'd2588: glyph_rom_fn = 8'h01;
                12'd2593: glyph_rom_fn = 8'hF0; 12'd2594: glyph_rom_fn = 8'hF8; 12'd2595: glyph_rom_fn = 8'h08; 12'd2596: glyph_rom_fn = 8'h08; 12'd2597: glyph_rom_fn = 8'hF8; 12'd2598: glyph_rom_fn = 8'hF0; 12'd2601: glyph_rom_fn = 8'h70; 12'd2602: glyph_rom_fn = 8'hF8; 12'd2603: glyph_rom_fn = 8'h88; 12'd2604: glyph_rom_fn = 8'h88; 12'd2605: glyph_rom_fn = 8'hF8; 12'd2606: glyph_rom_fn = 8'h70;
                12'd2609: glyph_rom_fn = 8'h0F; 12'd2610: glyph_rom_fn = 8'h1F; 12'd2611: glyph_rom_fn = 8'h10; 12'd2612: glyph_rom_fn = 8'h10; 12'd2613: glyph_rom_fn = 8'h1F; 12'd2614: glyph_rom_fn = 8'h0F; 12'd2617: glyph_rom_fn = 8'h0F; 12'd2618: glyph_rom_fn = 8'h1F; 12'd2619: glyph_rom_fn = 8'h10; 12'd2620: glyph_rom_fn = 8'h10; 12'd2621: glyph_rom_fn = 8'h1F; 12'd2622: glyph_rom_fn = 8'h0F;
                12'd2625: glyph_rom_fn = 8'hF0; 12'd2626: glyph_rom_fn = 8'hF8; 12'd2627: glyph_rom_fn = 8'h08; 12'd2628: glyph_rom_fn = 8'h08; 12'd2629: glyph_rom_fn = 8'hF8; 12'd2630: glyph_rom_fn = 8'hF0; 12'd2633: glyph_rom_fn = 8'h70; 12'd2634: glyph_rom_fn = 8'hF8; 12'd2635: glyph_rom_fn = 8'h88; 12'd2636: glyph_rom_fn = 8'h88; 12'd2637: glyph_rom_fn = 8'hF8; 12'd2638: glyph_rom_fn = 8'hF0;
                12'd2641: glyph_rom_fn = 8'h0F; 12'd2642: glyph_rom_fn = 8'h1F; 12'd2643: glyph_rom_fn = 8'h10; 12'd2644: glyph_rom_fn = 8'h10; 12'd2645: glyph_rom_fn = 8'h1F; 12'd2646: glyph_rom_fn = 8'h0F; 12'd2649: glyph_rom_fn = 8'h08; 12'd2650: glyph_rom_fn = 8'h18; 12'd2651: glyph_rom_fn = 8'h10; 12'd2652: glyph_rom_fn = 8'h10; 12'd2653: glyph_rom_fn = 8'h1F; 12'd2654: glyph_rom_fn = 8'h0F;
                12'd2657: glyph_rom_fn = 8'h20; 12'd2658: glyph_rom_fn = 8'h30; 12'd2659: glyph_rom_fn = 8'hF8; 12'd2660: glyph_rom_fn = 8'hF8; 12'd2665: glyph_rom_fn = 8'hF0; 12'd2666: glyph_rom_fn = 8'hF8; 12'd2667: glyph_rom_fn = 8'h08; 12'd2668: glyph_rom_fn = 8'h08; 12'd2669: glyph_rom_fn = 8'hF8; 12'd2670: glyph_rom_fn = 8'hF0;
                12'd2673: glyph_rom_fn = 8'h10; 12'd2674: glyph_rom_fn = 8'h10; 12'd2675: glyph_rom_fn = 8'h1F; 12'd2676: glyph_rom_fn = 8'h1F; 12'd2677: glyph_rom_fn = 8'h10; 12'd2678: glyph_rom_fn = 8'h10; 12'd2681: glyph_rom_fn = 8'h0F; 12'd2682: glyph_rom_fn = 8'h1F; 12'd2683: glyph_rom_fn = 8'h10; 12'd2684: glyph_rom_fn = 8'h10; 12'd2685: glyph_rom_fn = 8'h1F; 12'd2686: glyph_rom_fn = 8'h0F;
                12'd2689: glyph_rom_fn = 8'h20; 12'd2690: glyph_rom_fn = 8'h30; 12'd2691: glyph_rom_fn = 8'hF8; 12'd2692: glyph_rom_fn = 8'hF8; 12'd2697: glyph_rom_fn = 8'h20; 12'd2698: glyph_rom_fn = 8'h30; 12'd2699: glyph_rom_fn = 8'hF8; 12'd2700: glyph_rom_fn = 8'hF8;
                12'd2705: glyph_rom_fn = 8'h10; 12'd2706: glyph_rom_fn = 8'h10; 12'd2707: glyph_rom_fn = 8'h1F; 12'd2708: glyph_rom_fn = 8'h1F; 12'd2709: glyph_rom_fn = 8'h10; 12'd2710: glyph_rom_fn = 8'h10; 12'd2713: glyph_rom_fn = 8'h10; 12'd2714: glyph_rom_fn = 8'h10; 12'd2715: glyph_rom_fn = 8'h1F; 12'd2716: glyph_rom_fn = 8'h1F; 12'd2717: glyph_rom_fn = 8'h10; 12'd2718: glyph_rom_fn = 8'h10;
                12'd2721: glyph_rom_fn = 8'h80; 12'd2722: glyph_rom_fn = 8'h80; 12'd2723: glyph_rom_fn = 8'h80; 12'd2724: glyph_rom_fn = 8'h80; 12'd2725: glyph_rom_fn = 8'h80; 12'd2726: glyph_rom_fn = 8'h80; 12'd2729: glyph_rom_fn = 8'h80; 12'd2730: glyph_rom_fn = 8'h80; 12'd2731: glyph_rom_fn = 8'h80; 12'd2732: glyph_rom_fn = 8'h80; 12'd2733: glyph_rom_fn = 8'h80; 12'd2734: glyph_rom_fn = 8'h80;
                12'd2737: glyph_rom_fn = 8'h01; 12'd2738: glyph_rom_fn = 8'h01; 12'd2739: glyph_rom_fn = 8'h01; 12'd2740: glyph_rom_fn = 8'h01; 12'd2741: glyph_rom_fn = 8'h01; 12'd2742: glyph_rom_fn = 8'h01; 12'd2745: glyph_rom_fn = 8'h01; 12'd2746: glyph_rom_fn = 8'h01; 12'd2747: glyph_rom_fn = 8'h01; 12'd2748: glyph_rom_fn = 8'h01; 12'd2749: glyph_rom_fn = 8'h01; 12'd2750: glyph_rom_fn = 8'h01;
                12'd2758: glyph_rom_fn = 8'h30; 12'd2759: glyph_rom_fn = 8'h30;
                12'd2774: glyph_rom_fn = 8'h0C; 12'd2775: glyph_rom_fn = 8'h0C;
                12'd2791: glyph_rom_fn = 8'h54; 12'd2792: glyph_rom_fn = 8'h54;
                12'd2807: glyph_rom_fn = 8'h15; 12'd2808: glyph_rom_fn = 8'h15;
                12'd2817: glyph_rom_fn = 8'h40; 12'd2818: glyph_rom_fn = 8'h60; 12'd2819: glyph_rom_fn = 8'hF8; 12'd2820: glyph_rom_fn = 8'hFE; 12'd2821: glyph_rom_fn = 8'h04; 12'd2822: glyph_rom_fn = 8'h7C; 12'd2823: glyph_rom_fn = 8'h78; 12'd2824: glyph_rom_fn = 8'hFC; 12'd2825: glyph_rom_fn = 8'hFE; 12'd2826: glyph_rom_fn = 8'h60; 12'd2827: glyph_rom_fn = 8'h7C; 12'd2828: glyph_rom_fn = 8'h6C;
                12'd2835: glyph_rom_fn = 8'h3F; 12'd2836: glyph_rom_fn = 8'h3F; 12'd2837: glyph_rom_fn = 8'h02; 12'd2838: glyph_rom_fn = 8'h06; 12'd2839: glyph_rom_fn = 8'h06; 12'd2840: glyph_rom_fn = 8'h3F; 12'd2841: glyph_rom_fn = 8'h3F; 12'd2842: glyph_rom_fn = 8'h06; 12'd2843: glyph_rom_fn = 8'h06; 12'd2844: glyph_rom_fn = 8'h06; 12'd2845: glyph_rom_fn = 8'h02;
                12'd2849: glyph_rom_fn = 8'h40; 12'd2850: glyph_rom_fn = 8'h60; 12'd2851: glyph_rom_fn = 8'h70; 12'd2852: glyph_rom_fn = 8'hDC; 12'd2853: glyph_rom_fn = 8'hCE; 12'd2854: glyph_rom_fn = 8'hC0; 12'd2855: glyph_rom_fn = 8'hC0; 12'd2856: glyph_rom_fn = 8'hC0; 12'd2857: glyph_rom_fn = 8'hCE; 12'd2858: glyph_rom_fn = 8'hDC; 12'd2859: glyph_rom_fn = 8'hF8; 12'd2860: glyph_rom_fn = 8'h60;
                12'd2866: glyph_rom_fn = 8'h30; 12'd2867: glyph_rom_fn = 8'h30; 12'd2868: glyph_rom_fn = 8'h18; 12'd2869: glyph_rom_fn = 8'h0F; 12'd2870: glyph_rom_fn = 8'h07; 12'd2872: glyph_rom_fn = 8'h30; 12'd2873: glyph_rom_fn = 8'h30; 12'd2874: glyph_rom_fn = 8'h3F; 12'd2875: glyph_rom_fn = 8'h07;
                12'd2881: glyph_rom_fn = 8'h20; 12'd2882: glyph_rom_fn = 8'hF8; 12'd2883: glyph_rom_fn = 8'hFE; 12'd2884: glyph_rom_fn = 8'hF4; 12'd2885: glyph_rom_fn = 8'hBC; 12'd2886: glyph_rom_fn = 8'hE0; 12'd2887: glyph_rom_fn = 8'hE4; 12'd2888: glyph_rom_fn = 8'hF4; 12'd2889: glyph_rom_fn = 8'hBC; 12'd2890: glyph_rom_fn = 8'hA4; 12'd2891: glyph_rom_fn = 8'hA4; 12'd2892: glyph_rom_fn = 8'h3C;
                12'd2898: glyph_rom_fn = 8'h3F; 12'd2899: glyph_rom_fn = 8'h07; 12'd2900: glyph_rom_fn = 8'h03; 12'd2901: glyph_rom_fn = 8'h22; 12'd2902: glyph_rom_fn = 8'h3F; 12'd2903: glyph_rom_fn = 8'h0F; 12'd2904: glyph_rom_fn = 8'h07; 12'd2905: glyph_rom_fn = 8'h05; 12'd2906: glyph_rom_fn = 8'h3F; 12'd2907: glyph_rom_fn = 8'h0D; 12'd2908: glyph_rom_fn = 8'h05; 12'd2909: glyph_rom_fn = 8'h04;
                12'd2913: glyph_rom_fn = 8'h20; 12'd2914: glyph_rom_fn = 8'h6C; 12'd2915: glyph_rom_fn = 8'hEC; 12'd2916: glyph_rom_fn = 8'hFC; 12'd2917: glyph_rom_fn = 8'hFE; 12'd2918: glyph_rom_fn = 8'h62; 12'd2919: glyph_rom_fn = 8'h60; 12'd2920: glyph_rom_fn = 8'hFC; 12'd2921: glyph_rom_fn = 8'h0C; 12'd2922: glyph_rom_fn = 8'h0C; 12'd2923: glyph_rom_fn = 8'hFC; 12'd2924: glyph_rom_fn = 8'hFC;
                12'd2929: glyph_rom_fn = 8'h04; 12'd2930: glyph_rom_fn = 8'h0E; 12'd2931: glyph_rom_fn = 8'h03; 12'd2932: glyph_rom_fn = 8'h3F; 12'd2933: glyph_rom_fn = 8'h3F; 12'd2934: glyph_rom_fn = 8'h03; 12'd2935: glyph_rom_fn = 8'h02; 12'd2936: glyph_rom_fn = 8'h1F; 12'd2937: glyph_rom_fn = 8'h0C; 12'd2938: glyph_rom_fn = 8'h0C; 12'd2939: glyph_rom_fn = 8'h1F; 12'd2940: glyph_rom_fn = 8'h1F;
                12'd2946: glyph_rom_fn = 8'h60; 12'd2947: glyph_rom_fn = 8'h66; 12'd2948: glyph_rom_fn = 8'h04; 12'd2949: glyph_rom_fn = 8'h48; 12'd2950: glyph_rom_fn = 8'hC8; 12'd2951: glyph_rom_fn = 8'hF8; 12'd2952: glyph_rom_fn = 8'h7E; 12'd2953: glyph_rom_fn = 8'h4E; 12'd2954: glyph_rom_fn = 8'h68; 12'd2955: glyph_rom_fn = 8'h78; 12'd2956: glyph_rom_fn = 8'hE8; 12'd2957: glyph_rom_fn = 8'h08;
                12'd2962: glyph_rom_fn = 8'h30; 12'd2963: glyph_rom_fn = 8'h1C; 12'd2964: glyph_rom_fn = 8'h06; 12'd2965: glyph_rom_fn = 8'h30; 12'd2966: glyph_rom_fn = 8'h1F; 12'd2967: glyph_rom_fn = 8'h07; 12'd2968: glyph_rom_fn = 8'h1F; 12'd2969: glyph_rom_fn = 8'h3F; 12'd2971: glyph_rom_fn = 8'h3F; 12'd2972: glyph_rom_fn = 8'h30; 12'd2973: glyph_rom_fn = 8'h18;
                12'd2978: glyph_rom_fn = 8'h98; 12'd2979: glyph_rom_fn = 8'hCC; 12'd2980: glyph_rom_fn = 8'hF6; 12'd2981: glyph_rom_fn = 8'h30; 12'd2982: glyph_rom_fn = 8'h40; 12'd2983: glyph_rom_fn = 8'h6C; 12'd2984: glyph_rom_fn = 8'h6C; 12'd2985: glyph_rom_fn = 8'h6C; 12'd2986: glyph_rom_fn = 8'hEC; 12'd2987: glyph_rom_fn = 8'hEC; 12'd2988: glyph_rom_fn = 8'h6C; 12'd2989: glyph_rom_fn = 8'h40;
                12'd2993: glyph_rom_fn = 8'h01; 12'd2994: glyph_rom_fn = 8'h01; 12'd2995: glyph_rom_fn = 8'h3F; 12'd2996: glyph_rom_fn = 8'h3F; 12'd3000: glyph_rom_fn = 8'h30; 12'd3001: glyph_rom_fn = 8'h30; 12'd3002: glyph_rom_fn = 8'h3F; 12'd3003: glyph_rom_fn = 8'h1F;
                12'd3009: glyph_rom_fn = 8'h08; 12'd3010: glyph_rom_fn = 8'h9C; 12'd3011: glyph_rom_fn = 8'hEE; 12'd3012: glyph_rom_fn = 8'hF6; 12'd3013: glyph_rom_fn = 8'h20; 12'd3014: glyph_rom_fn = 8'hA4; 12'd3015: glyph_rom_fn = 8'hA4; 12'd3016: glyph_rom_fn = 8'hFE; 12'd3017: glyph_rom_fn = 8'hFE; 12'd3018: glyph_rom_fn = 8'hA4; 12'd3019: glyph_rom_fn = 8'hFC; 12'd3020: glyph_rom_fn = 8'hFC; 12'd3021: glyph_rom_fn = 8'h20;
                12'd3025: glyph_rom_fn = 8'h01; 12'd3026: glyph_rom_fn = 8'h01; 12'd3027: glyph_rom_fn = 8'h3F; 12'd3028: glyph_rom_fn = 8'h3F; 12'd3029: glyph_rom_fn = 8'h08; 12'd3030: glyph_rom_fn = 8'h0A; 12'd3031: glyph_rom_fn = 8'h0A; 12'd3032: glyph_rom_fn = 8'h3F; 12'd3033: glyph_rom_fn = 8'h3F; 12'd3034: glyph_rom_fn = 8'h0A; 12'd3035: glyph_rom_fn = 8'h0A; 12'd3036: glyph_rom_fn = 8'h0A; 12'd3037: glyph_rom_fn = 8'h08;
                12'd3042: glyph_rom_fn = 8'h30; 12'd3043: glyph_rom_fn = 8'h38; 12'd3044: glyph_rom_fn = 8'hFE; 12'd3045: glyph_rom_fn = 8'h06; 12'd3046: glyph_rom_fn = 8'h30; 12'd3047: glyph_rom_fn = 8'h30; 12'd3048: glyph_rom_fn = 8'hFE; 12'd3049: glyph_rom_fn = 8'hD8; 12'd3050: glyph_rom_fn = 8'h98; 12'd3051: glyph_rom_fn = 8'h8C; 12'd3052: glyph_rom_fn = 8'hE4;
                12'd3058: glyph_rom_fn = 8'h06; 12'd3059: glyph_rom_fn = 8'h06; 12'd3060: glyph_rom_fn = 8'h06; 12'd3061: glyph_rom_fn = 8'h06; 12'd3062: glyph_rom_fn = 8'h06; 12'd3063: glyph_rom_fn = 8'h3E; 12'd3064: glyph_rom_fn = 8'h06; 12'd3065: glyph_rom_fn = 8'h06; 12'd3066: glyph_rom_fn = 8'h06; 12'd3067: glyph_rom_fn = 8'h06; 12'd3068: glyph_rom_fn = 8'h06; 12'd3069: glyph_rom_fn = 8'h04;
                12'd3074: glyph_rom_fn = 8'hC0; 12'd3075: glyph_rom_fn = 8'hF0; 12'd3076: glyph_rom_fn = 8'h3C; 12'd3077: glyph_rom_fn = 8'h3C; 12'd3078: glyph_rom_fn = 8'h30; 12'd3079: glyph_rom_fn = 8'hF0; 12'd3080: glyph_rom_fn = 8'hF0; 12'd3081: glyph_rom_fn = 8'h30; 12'd3082: glyph_rom_fn = 8'h30; 12'd3083: glyph_rom_fn = 8'hF0; 12'd3084: glyph_rom_fn = 8'h70;
                12'd3090: glyph_rom_fn = 8'h18; 12'd3091: glyph_rom_fn = 8'h0E; 12'd3092: glyph_rom_fn = 8'h07; 12'd3093: glyph_rom_fn = 8'h60; 12'd3094: glyph_rom_fn = 8'h60; 12'd3095: glyph_rom_fn = 8'h7F; 12'd3096: glyph_rom_fn = 8'h1F; 12'd3098: glyph_rom_fn = 8'h07; 12'd3099: glyph_rom_fn = 8'h0E; 12'd3100: glyph_rom_fn = 8'h1C;
                12'd3106: glyph_rom_fn = 8'hD8; 12'd3107: glyph_rom_fn = 8'hF8; 12'd3108: glyph_rom_fn = 8'h7E; 12'd3109: glyph_rom_fn = 8'h9C; 12'd3110: glyph_rom_fn = 8'h98; 12'd3111: glyph_rom_fn = 8'h98; 12'd3112: glyph_rom_fn = 8'hD8; 12'd3113: glyph_rom_fn = 8'hFC; 12'd3114: glyph_rom_fn = 8'h3E; 12'd3115: glyph_rom_fn = 8'hD8; 12'd3116: glyph_rom_fn = 8'h98;
                12'd3121: glyph_rom_fn = 8'h10; 12'd3122: glyph_rom_fn = 8'h31; 12'd3123: glyph_rom_fn = 8'h1F; 12'd3124: glyph_rom_fn = 8'h17; 12'd3125: glyph_rom_fn = 8'h1F; 12'd3126: glyph_rom_fn = 8'h38; 12'd3127: glyph_rom_fn = 8'h30; 12'd3128: glyph_rom_fn = 8'h39; 12'd3129: glyph_rom_fn = 8'h1F; 12'd3130: glyph_rom_fn = 8'h17; 12'd3131: glyph_rom_fn = 8'h1D; 12'd3132: glyph_rom_fn = 8'h3C;
                12'd3137: glyph_rom_fn = 8'h10; 12'd3138: glyph_rom_fn = 8'h18; 12'd3139: glyph_rom_fn = 8'hFE; 12'd3140: glyph_rom_fn = 8'hFE; 12'd3141: glyph_rom_fn = 8'h90; 12'd3142: glyph_rom_fn = 8'hF0; 12'd3143: glyph_rom_fn = 8'hF8; 12'd3144: glyph_rom_fn = 8'h98; 12'd3145: glyph_rom_fn = 8'h9E; 12'd3146: glyph_rom_fn = 8'h9A; 12'd3147: glyph_rom_fn = 8'hF8; 12'd3148: glyph_rom_fn = 8'hF8;
                12'd3153: glyph_rom_fn = 8'h01; 12'd3154: glyph_rom_fn = 8'h33; 12'd3155: glyph_rom_fn = 8'h3F; 12'd3156: glyph_rom_fn = 8'h1F; 12'd3157: glyph_rom_fn = 8'h01; 12'd3158: glyph_rom_fn = 8'h3F; 12'd3159: glyph_rom_fn = 8'h3F; 12'd3160: glyph_rom_fn = 8'h19; 12'd3161: glyph_rom_fn = 8'h19; 12'd3162: glyph_rom_fn = 8'h19; 12'd3163: glyph_rom_fn = 8'h3F; 12'd3164: glyph_rom_fn = 8'h3F;
                12'd3170: glyph_rom_fn = 8'hF8; 12'd3171: glyph_rom_fn = 8'hF8; 12'd3172: glyph_rom_fn = 8'hA8; 12'd3173: glyph_rom_fn = 8'hA8; 12'd3174: glyph_rom_fn = 8'hA8; 12'd3175: glyph_rom_fn = 8'hA8; 12'd3176: glyph_rom_fn = 8'h3C; 12'd3177: glyph_rom_fn = 8'hFC; 12'd3178: glyph_rom_fn = 8'hCC; 12'd3179: glyph_rom_fn = 8'h7C; 12'd3180: glyph_rom_fn = 8'h08;
                12'd3185: glyph_rom_fn = 8'h02; 12'd3186: glyph_rom_fn = 8'h77; 12'd3187: glyph_rom_fn = 8'h39; 12'd3188: glyph_rom_fn = 8'h0B; 12'd3189: glyph_rom_fn = 8'h7B; 12'd3190: glyph_rom_fn = 8'h6E; 12'd3191: glyph_rom_fn = 8'h4F; 12'd3192: glyph_rom_fn = 8'h4A; 12'd3193: glyph_rom_fn = 8'h73; 12'd3194: glyph_rom_fn = 8'h3B; 12'd3195: glyph_rom_fn = 8'h3A; 12'd3196: glyph_rom_fn = 8'h73; 12'd3197: glyph_rom_fn = 8'h01;
                12'd3205: glyph_rom_fn = 8'hE0; 12'd3206: glyph_rom_fn = 8'hF0; 12'd3207: glyph_rom_fn = 8'h18; 12'd3208: glyph_rom_fn = 8'h18; 12'd3209: glyph_rom_fn = 8'h18; 12'd3210: glyph_rom_fn = 8'h18;
                12'd3221: glyph_rom_fn = 8'h03; 12'd3222: glyph_rom_fn = 8'h07; 12'd3223: glyph_rom_fn = 8'h0C; 12'd3224: glyph_rom_fn = 8'h0C; 12'd3225: glyph_rom_fn = 8'h0C; 12'd3226: glyph_rom_fn = 8'h0C;
                12'd3234: glyph_rom_fn = 8'hF0; 12'd3235: glyph_rom_fn = 8'h30; 12'd3236: glyph_rom_fn = 8'h18; 12'd3237: glyph_rom_fn = 8'h18; 12'd3238: glyph_rom_fn = 8'h18; 12'd3241: glyph_rom_fn = 8'h40; 12'd3242: glyph_rom_fn = 8'hF0; 12'd3243: glyph_rom_fn = 8'h40; 12'd3244: glyph_rom_fn = 8'hF0; 12'd3245: glyph_rom_fn = 8'h40;
                12'd3250: glyph_rom_fn = 8'h07; 12'd3251: glyph_rom_fn = 8'h0E; 12'd3252: glyph_rom_fn = 8'h0C; 12'd3253: glyph_rom_fn = 8'h0C; 12'd3254: glyph_rom_fn = 8'h0C; 12'd3255: glyph_rom_fn = 8'h04; 12'd3256: glyph_rom_fn = 8'h02; 12'd3257: glyph_rom_fn = 8'h0F; 12'd3258: glyph_rom_fn = 8'h03; 12'd3259: glyph_rom_fn = 8'h0A; 12'd3260: glyph_rom_fn = 8'h0F; 12'd3261: glyph_rom_fn = 8'h02;
                12'd3268: glyph_rom_fn = 8'hF8; 12'd3269: glyph_rom_fn = 8'hF8; 12'd3270: glyph_rom_fn = 8'h18; 12'd3271: glyph_rom_fn = 8'h18; 12'd3272: glyph_rom_fn = 8'h18; 12'd3273: glyph_rom_fn = 8'hF0; 12'd3274: glyph_rom_fn = 8'hE0;
                12'd3284: glyph_rom_fn = 8'h0F; 12'd3285: glyph_rom_fn = 8'h0F; 12'd3286: glyph_rom_fn = 8'h0C; 12'd3287: glyph_rom_fn = 8'h0C; 12'd3288: glyph_rom_fn = 8'h0E; 12'd3289: glyph_rom_fn = 8'h07; 12'd3290: glyph_rom_fn = 8'h03;
                12'd3297: glyph_rom_fn = 8'hF8; 12'd3298: glyph_rom_fn = 8'hF8; 12'd3299: glyph_rom_fn = 8'h08; 12'd3300: glyph_rom_fn = 8'h18; 12'd3301: glyph_rom_fn = 8'hF0; 12'd3302: glyph_rom_fn = 8'hE0; 12'd3305: glyph_rom_fn = 8'h40; 12'd3306: glyph_rom_fn = 8'hF0; 12'd3307: glyph_rom_fn = 8'h40; 12'd3308: glyph_rom_fn = 8'hF0; 12'd3309: glyph_rom_fn = 8'h40;
                12'd3313: glyph_rom_fn = 8'h0F; 12'd3314: glyph_rom_fn = 8'h0F; 12'd3315: glyph_rom_fn = 8'h08; 12'd3316: glyph_rom_fn = 8'h0C; 12'd3317: glyph_rom_fn = 8'h07; 12'd3318: glyph_rom_fn = 8'h03; 12'd3320: glyph_rom_fn = 8'h02; 12'd3321: glyph_rom_fn = 8'h0F; 12'd3322: glyph_rom_fn = 8'h03; 12'd3323: glyph_rom_fn = 8'h0A; 12'd3324: glyph_rom_fn = 8'h0F; 12'd3325: glyph_rom_fn = 8'h02;
                12'd3333: glyph_rom_fn = 8'hF8; 12'd3334: glyph_rom_fn = 8'hF8; 12'd3335: glyph_rom_fn = 8'hD8; 12'd3336: glyph_rom_fn = 8'hD8; 12'd3337: glyph_rom_fn = 8'hD8; 12'd3338: glyph_rom_fn = 8'h08;
                12'd3349: glyph_rom_fn = 8'h0F; 12'd3350: glyph_rom_fn = 8'h0F; 12'd3351: glyph_rom_fn = 8'h0C; 12'd3352: glyph_rom_fn = 8'h0C; 12'd3353: glyph_rom_fn = 8'h0C; 12'd3354: glyph_rom_fn = 8'h08;
                12'd3365: glyph_rom_fn = 8'hF8; 12'd3366: glyph_rom_fn = 8'hF8; 12'd3367: glyph_rom_fn = 8'h98; 12'd3368: glyph_rom_fn = 8'h98; 12'd3369: glyph_rom_fn = 8'h98; 12'd3370: glyph_rom_fn = 8'h08;
                12'd3381: glyph_rom_fn = 8'h0F; 12'd3382: glyph_rom_fn = 8'h0F; 12'd3383: glyph_rom_fn = 8'h01; 12'd3384: glyph_rom_fn = 8'h01; 12'd3385: glyph_rom_fn = 8'h01;
                12'd3394: glyph_rom_fn = 8'hF8; 12'd3395: glyph_rom_fn = 8'hF8; 12'd3396: glyph_rom_fn = 8'h88; 12'd3397: glyph_rom_fn = 8'h88; 12'd3398: glyph_rom_fn = 8'h88; 12'd3400: glyph_rom_fn = 8'h40; 12'd3401: glyph_rom_fn = 8'hF0; 12'd3402: glyph_rom_fn = 8'h40; 12'd3403: glyph_rom_fn = 8'hF0; 12'd3404: glyph_rom_fn = 8'h40;
                12'd3410: glyph_rom_fn = 8'h0F; 12'd3411: glyph_rom_fn = 8'h0F; 12'd3415: glyph_rom_fn = 8'h02; 12'd3416: glyph_rom_fn = 8'h0F; 12'd3417: glyph_rom_fn = 8'h03; 12'd3418: glyph_rom_fn = 8'h0A; 12'd3419: glyph_rom_fn = 8'h0F; 12'd3420: glyph_rom_fn = 8'h02;
                12'd3428: glyph_rom_fn = 8'hE0; 12'd3429: glyph_rom_fn = 8'hF0; 12'd3430: glyph_rom_fn = 8'h18; 12'd3431: glyph_rom_fn = 8'h18; 12'd3432: glyph_rom_fn = 8'h98; 12'd3433: glyph_rom_fn = 8'h98; 12'd3434: glyph_rom_fn = 8'h80;
                12'd3444: glyph_rom_fn = 8'h03; 12'd3445: glyph_rom_fn = 8'h07; 12'd3446: glyph_rom_fn = 8'h0C; 12'd3447: glyph_rom_fn = 8'h0C; 12'd3448: glyph_rom_fn = 8'h0D; 12'd3449: glyph_rom_fn = 8'h0F; 12'd3450: glyph_rom_fn = 8'h07;
                12'd3457: glyph_rom_fn = 8'hF0; 12'd3458: glyph_rom_fn = 8'h30; 12'd3459: glyph_rom_fn = 8'h18; 12'd3460: glyph_rom_fn = 8'h98; 12'd3461: glyph_rom_fn = 8'h98; 12'd3462: glyph_rom_fn = 8'h90; 12'd3465: glyph_rom_fn = 8'h40; 12'd3466: glyph_rom_fn = 8'hF0; 12'd3467: glyph_rom_fn = 8'h40; 12'd3468: glyph_rom_fn = 8'hF0; 12'd3469: glyph_rom_fn = 8'h40;
                12'd3473: glyph_rom_fn = 8'h07; 12'd3474: glyph_rom_fn = 8'h06; 12'd3475: glyph_rom_fn = 8'h0C; 12'd3476: glyph_rom_fn = 8'h0C; 12'd3477: glyph_rom_fn = 8'h0D; 12'd3478: glyph_rom_fn = 8'h07; 12'd3480: glyph_rom_fn = 8'h02; 12'd3481: glyph_rom_fn = 8'h0F; 12'd3482: glyph_rom_fn = 8'h03; 12'd3483: glyph_rom_fn = 8'h0A; 12'd3484: glyph_rom_fn = 8'h0F; 12'd3485: glyph_rom_fn = 8'h02;
                12'd3493: glyph_rom_fn = 8'h80; 12'd3494: glyph_rom_fn = 8'hF0; 12'd3495: glyph_rom_fn = 8'h38; 12'd3496: glyph_rom_fn = 8'h78; 12'd3497: glyph_rom_fn = 8'hE0;
                12'd3508: glyph_rom_fn = 8'h0C; 12'd3509: glyph_rom_fn = 8'h0F; 12'd3510: glyph_rom_fn = 8'h03; 12'd3511: glyph_rom_fn = 8'h01; 12'd3512: glyph_rom_fn = 8'h01; 12'd3513: glyph_rom_fn = 8'h07; 12'd3514: glyph_rom_fn = 8'h0F; 12'd3515: glyph_rom_fn = 8'h08;
                12'd3522: glyph_rom_fn = 8'hC0; 12'd3523: glyph_rom_fn = 8'hF8; 12'd3524: glyph_rom_fn = 8'h18; 12'd3525: glyph_rom_fn = 8'hF8; 12'd3526: glyph_rom_fn = 8'hC0; 12'd3529: glyph_rom_fn = 8'h40; 12'd3530: glyph_rom_fn = 8'hF0; 12'd3531: glyph_rom_fn = 8'h40; 12'd3532: glyph_rom_fn = 8'hF0; 12'd3533: glyph_rom_fn = 8'h40;
                12'd3537: glyph_rom_fn = 8'h0C; 12'd3538: glyph_rom_fn = 8'h0F; 12'd3539: glyph_rom_fn = 8'h01; 12'd3540: glyph_rom_fn = 8'h01; 12'd3541: glyph_rom_fn = 8'h01; 12'd3542: glyph_rom_fn = 8'h0F; 12'd3543: glyph_rom_fn = 8'h0C; 12'd3544: glyph_rom_fn = 8'h02; 12'd3545: glyph_rom_fn = 8'h0F; 12'd3546: glyph_rom_fn = 8'h03; 12'd3547: glyph_rom_fn = 8'h0A; 12'd3548: glyph_rom_fn = 8'h0F; 12'd3549: glyph_rom_fn = 8'h02;
                12'd3557: glyph_rom_fn = 8'hF8; 12'd3558: glyph_rom_fn = 8'hF8; 12'd3559: glyph_rom_fn = 8'h88; 12'd3560: glyph_rom_fn = 8'hD8; 12'd3561: glyph_rom_fn = 8'hF8; 12'd3562: glyph_rom_fn = 8'hF0;
                12'd3573: glyph_rom_fn = 8'h0F; 12'd3574: glyph_rom_fn = 8'h0F; 12'd3575: glyph_rom_fn = 8'h08; 12'd3576: glyph_rom_fn = 8'h0C; 12'd3577: glyph_rom_fn = 8'h0D; 12'd3578: glyph_rom_fn = 8'h07; 12'd3579: glyph_rom_fn = 8'h02;
                12'd3588: glyph_rom_fn = 8'hF8; 12'd3589: glyph_rom_fn = 8'hF8; 12'd3590: glyph_rom_fn = 8'hF0; 12'd3591: glyph_rom_fn = 8'h80; 12'd3593: glyph_rom_fn = 8'hE0; 12'd3594: glyph_rom_fn = 8'h78; 12'd3595: glyph_rom_fn = 8'hF8;
                12'd3604: glyph_rom_fn = 8'h0F; 12'd3605: glyph_rom_fn = 8'h0F; 12'd3607: glyph_rom_fn = 8'h07; 12'd3608: glyph_rom_fn = 8'h07; 12'd3609: glyph_rom_fn = 8'h01; 12'd3610: glyph_rom_fn = 8'h0F; 12'd3611: glyph_rom_fn = 8'h0F;
                12'd3619: glyph_rom_fn = 8'hF0; 12'd3620: glyph_rom_fn = 8'hF0; 12'd3621: glyph_rom_fn = 8'h30; 12'd3622: glyph_rom_fn = 8'h30; 12'd3623: glyph_rom_fn = 8'hF0; 12'd3624: glyph_rom_fn = 8'hE0; 12'd3625: glyph_rom_fn = 8'h30; 12'd3626: glyph_rom_fn = 8'h30; 12'd3627: glyph_rom_fn = 8'hF0; 12'd3628: glyph_rom_fn = 8'hE0;
                12'd3635: glyph_rom_fn = 8'h07; 12'd3636: glyph_rom_fn = 8'h07; 12'd3639: glyph_rom_fn = 8'h07; 12'd3640: glyph_rom_fn = 8'h07; 12'd3643: glyph_rom_fn = 8'h07; 12'd3644: glyph_rom_fn = 8'h07;
                12'd3653: glyph_rom_fn = 8'h18; 12'd3654: glyph_rom_fn = 8'h18; 12'd3655: glyph_rom_fn = 8'hD8; 12'd3656: glyph_rom_fn = 8'hF8; 12'd3657: glyph_rom_fn = 8'h38; 12'd3658: glyph_rom_fn = 8'h08;
                12'd3670: glyph_rom_fn = 8'h0E; 12'd3671: glyph_rom_fn = 8'h0F;
                12'd3680: glyph_rom_fn = 8'hE0; 12'd3681: glyph_rom_fn = 8'hE0; 12'd3682: glyph_rom_fn = 8'h60; 12'd3683: glyph_rom_fn = 8'hE0; 12'd3684: glyph_rom_fn = 8'hC0; 12'd3685: glyph_rom_fn = 8'h40; 12'd3686: glyph_rom_fn = 8'h60; 12'd3687: glyph_rom_fn = 8'hE0; 12'd3688: glyph_rom_fn = 8'hC0; 12'd3690: glyph_rom_fn = 8'h10; 12'd3691: glyph_rom_fn = 8'h10; 12'd3692: glyph_rom_fn = 8'h10; 12'd3693: glyph_rom_fn = 8'hD0; 12'd3694: glyph_rom_fn = 8'hF0; 12'd3695: glyph_rom_fn = 8'h30;
                12'd3696: glyph_rom_fn = 8'h0F; 12'd3697: glyph_rom_fn = 8'h0F; 12'd3699: glyph_rom_fn = 8'h0F; 12'd3700: glyph_rom_fn = 8'h0F; 12'd3703: glyph_rom_fn = 8'h0F; 12'd3704: glyph_rom_fn = 8'h0F; 12'd3708: glyph_rom_fn = 8'h0E; 12'd3709: glyph_rom_fn = 8'h0F;
                12'd3715: glyph_rom_fn = 8'hE0; 12'd3716: glyph_rom_fn = 8'hE0; 12'd3717: glyph_rom_fn = 8'h20; 12'd3718: glyph_rom_fn = 8'h20; 12'd3720: glyph_rom_fn = 8'h80; 12'd3721: glyph_rom_fn = 8'hE0; 12'd3722: glyph_rom_fn = 8'h70; 12'd3723: glyph_rom_fn = 8'hF0;
                12'd3731: glyph_rom_fn = 8'h0D; 12'd3732: glyph_rom_fn = 8'h09; 12'd3733: glyph_rom_fn = 8'h0F; 12'd3734: glyph_rom_fn = 8'h06; 12'd3735: glyph_rom_fn = 8'h03; 12'd3736: glyph_rom_fn = 8'h03; 12'd3737: glyph_rom_fn = 8'h02; 12'd3738: glyph_rom_fn = 8'h03; 12'd3739: glyph_rom_fn = 8'h0F; 12'd3740: glyph_rom_fn = 8'h02;
                12'd3744: glyph_rom_fn = 8'h80; 12'd3745: glyph_rom_fn = 8'hC0; 12'd3746: glyph_rom_fn = 8'h40; 12'd3747: glyph_rom_fn = 8'hC0; 12'd3748: glyph_rom_fn = 8'hF8; 12'd3751: glyph_rom_fn = 8'hC0; 12'd3752: glyph_rom_fn = 8'hC0; 12'd3753: glyph_rom_fn = 8'hC0; 12'd3754: glyph_rom_fn = 8'hC0; 12'd3755: glyph_rom_fn = 8'h80; 12'd3756: glyph_rom_fn = 8'h80; 12'd3757: glyph_rom_fn = 8'hC0; 12'd3758: glyph_rom_fn = 8'hC0; 12'd3759: glyph_rom_fn = 8'h80;
                12'd3760: glyph_rom_fn = 8'h0F; 12'd3761: glyph_rom_fn = 8'h18; 12'd3762: glyph_rom_fn = 8'h10; 12'd3763: glyph_rom_fn = 8'h18; 12'd3764: glyph_rom_fn = 8'h1F; 12'd3767: glyph_rom_fn = 8'h1F; 12'd3768: glyph_rom_fn = 8'h1F; 12'd3770: glyph_rom_fn = 8'h1F; 12'd3771: glyph_rom_fn = 8'h1F; 12'd3774: glyph_rom_fn = 8'h1F; 12'd3775: glyph_rom_fn = 8'h1F;
                12'd3777: glyph_rom_fn = 8'h48; 12'd3778: glyph_rom_fn = 8'h28; 12'd3779: glyph_rom_fn = 8'h9A; 12'd3780: glyph_rom_fn = 8'h4E; 12'd3781: glyph_rom_fn = 8'h08; 12'd3782: glyph_rom_fn = 8'h98; 12'd3783: glyph_rom_fn = 8'h68; 12'd3784: glyph_rom_fn = 8'h40; 12'd3785: glyph_rom_fn = 8'hB0; 12'd3786: glyph_rom_fn = 8'h1E; 12'd3787: glyph_rom_fn = 8'h1E; 12'd3788: glyph_rom_fn = 8'h90; 12'd3789: glyph_rom_fn = 8'h70;
                12'd3792: glyph_rom_fn = 8'h10; 12'd3793: glyph_rom_fn = 8'h08; 12'd3794: glyph_rom_fn = 8'h06; 12'd3795: glyph_rom_fn = 8'h03; 12'd3797: glyph_rom_fn = 8'h03; 12'd3798: glyph_rom_fn = 8'h2C; 12'd3799: glyph_rom_fn = 8'h30; 12'd3800: glyph_rom_fn = 8'h10; 12'd3801: glyph_rom_fn = 8'h08; 12'd3802: glyph_rom_fn = 8'h07; 12'd3803: glyph_rom_fn = 8'h07; 12'd3804: glyph_rom_fn = 8'h08; 12'd3805: glyph_rom_fn = 8'h10; 12'd3806: glyph_rom_fn = 8'h30;
                12'd3809: glyph_rom_fn = 8'h80; 12'd3810: glyph_rom_fn = 8'h80; 12'd3811: glyph_rom_fn = 8'hBE; 12'd3812: glyph_rom_fn = 8'hAA; 12'd3813: glyph_rom_fn = 8'hAA; 12'd3814: glyph_rom_fn = 8'hAA; 12'd3815: glyph_rom_fn = 8'hFE; 12'd3816: glyph_rom_fn = 8'hFE; 12'd3817: glyph_rom_fn = 8'hAA; 12'd3818: glyph_rom_fn = 8'hAA; 12'd3819: glyph_rom_fn = 8'hAA; 12'd3820: glyph_rom_fn = 8'hBE; 12'd3821: glyph_rom_fn = 8'h80; 12'd3822: glyph_rom_fn = 8'h80;
                12'd3825: glyph_rom_fn = 8'h10; 12'd3826: glyph_rom_fn = 8'h18; 12'd3827: glyph_rom_fn = 8'h0C; 12'd3828: glyph_rom_fn = 8'h06; 12'd3829: glyph_rom_fn = 8'h03; 12'd3830: glyph_rom_fn = 8'h01; 12'd3831: glyph_rom_fn = 8'h3F; 12'd3832: glyph_rom_fn = 8'h3F; 12'd3833: glyph_rom_fn = 8'h01; 12'd3834: glyph_rom_fn = 8'h03; 12'd3835: glyph_rom_fn = 8'h06; 12'd3836: glyph_rom_fn = 8'h0C; 12'd3837: glyph_rom_fn = 8'h18; 12'd3838: glyph_rom_fn = 8'h10;
                12'd3841: glyph_rom_fn = 8'h10; 12'd3842: glyph_rom_fn = 8'hD0; 12'd3843: glyph_rom_fn = 8'hFE; 12'd3844: glyph_rom_fn = 8'hD0; 12'd3845: glyph_rom_fn = 8'h10; 12'd3846: glyph_rom_fn = 8'h04; 12'd3847: glyph_rom_fn = 8'h04; 12'd3848: glyph_rom_fn = 8'hFE; 12'd3849: glyph_rom_fn = 8'h54; 12'd3850: glyph_rom_fn = 8'h54; 12'd3851: glyph_rom_fn = 8'h54; 12'd3852: glyph_rom_fn = 8'h5E; 12'd3853: glyph_rom_fn = 8'h54; 12'd3854: glyph_rom_fn = 8'hF4;
                12'd3857: glyph_rom_fn = 8'h03; 12'd3859: glyph_rom_fn = 8'h3F; 12'd3861: glyph_rom_fn = 8'h01; 12'd3862: glyph_rom_fn = 8'h24; 12'd3863: glyph_rom_fn = 8'h24; 12'd3864: glyph_rom_fn = 8'h17; 12'd3865: glyph_rom_fn = 8'h0D; 12'd3866: glyph_rom_fn = 8'h05; 12'd3867: glyph_rom_fn = 8'h0F; 12'd3868: glyph_rom_fn = 8'h15; 12'd3869: glyph_rom_fn = 8'h35; 12'd3870: glyph_rom_fn = 8'h25;
                12'd3873: glyph_rom_fn = 8'h10; 12'd3874: glyph_rom_fn = 8'h90; 12'd3875: glyph_rom_fn = 8'h90; 12'd3876: glyph_rom_fn = 8'h90; 12'd3877: glyph_rom_fn = 8'h90; 12'd3878: glyph_rom_fn = 8'h90; 12'd3879: glyph_rom_fn = 8'h90; 12'd3880: glyph_rom_fn = 8'h10; 12'd3881: glyph_rom_fn = 8'h10; 12'd3882: glyph_rom_fn = 8'hFE; 12'd3883: glyph_rom_fn = 8'h10; 12'd3884: glyph_rom_fn = 8'h10; 12'd3885: glyph_rom_fn = 8'h12; 12'd3886: glyph_rom_fn = 8'h14;
                12'd3890: glyph_rom_fn = 8'h30; 12'd3891: glyph_rom_fn = 8'h30; 12'd3892: glyph_rom_fn = 8'h1F; 12'd3893: glyph_rom_fn = 8'h10; 12'd3894: glyph_rom_fn = 8'h10; 12'd3895: glyph_rom_fn = 8'h08; 12'd3896: glyph_rom_fn = 8'h08; 12'd3898: glyph_rom_fn = 8'h03; 12'd3899: glyph_rom_fn = 8'h0C; 12'd3900: glyph_rom_fn = 8'h10; 12'd3901: glyph_rom_fn = 8'h30; 12'd3902: glyph_rom_fn = 8'h28;
                12'd3905: glyph_rom_fn = 8'h40; 12'd3906: glyph_rom_fn = 8'h40; 12'd3907: glyph_rom_fn = 8'hE0; 12'd3908: glyph_rom_fn = 8'hB0; 12'd3909: glyph_rom_fn = 8'h98; 12'd3910: glyph_rom_fn = 8'h8C; 12'd3911: glyph_rom_fn = 8'h86; 12'd3912: glyph_rom_fn = 8'h86; 12'd3913: glyph_rom_fn = 8'h8C; 12'd3914: glyph_rom_fn = 8'h98; 12'd3915: glyph_rom_fn = 8'hB0; 12'd3916: glyph_rom_fn = 8'hE0; 12'd3917: glyph_rom_fn = 8'h40; 12'd3918: glyph_rom_fn = 8'h40;
                12'd3921: glyph_rom_fn = 8'h20; 12'd3922: glyph_rom_fn = 8'h20; 12'd3923: glyph_rom_fn = 8'h24; 12'd3924: glyph_rom_fn = 8'h24; 12'd3925: glyph_rom_fn = 8'h24; 12'd3926: glyph_rom_fn = 8'h24; 12'd3927: glyph_rom_fn = 8'h3F; 12'd3928: glyph_rom_fn = 8'h3F; 12'd3929: glyph_rom_fn = 8'h24; 12'd3930: glyph_rom_fn = 8'h24; 12'd3931: glyph_rom_fn = 8'h24; 12'd3932: glyph_rom_fn = 8'h24; 12'd3933: glyph_rom_fn = 8'h20; 12'd3934: glyph_rom_fn = 8'h20;
                12'd3938: glyph_rom_fn = 8'hFE; 12'd3939: glyph_rom_fn = 8'h02; 12'd3940: glyph_rom_fn = 8'h02; 12'd3941: glyph_rom_fn = 8'hF2; 12'd3942: glyph_rom_fn = 8'h5A; 12'd3943: glyph_rom_fn = 8'h52; 12'd3944: glyph_rom_fn = 8'h52; 12'd3945: glyph_rom_fn = 8'h52; 12'd3946: glyph_rom_fn = 8'h52; 12'd3947: glyph_rom_fn = 8'h52; 12'd3948: glyph_rom_fn = 8'h52; 12'd3949: glyph_rom_fn = 8'hF2;
                12'd3953: glyph_rom_fn = 8'h30; 12'd3954: glyph_rom_fn = 8'h0F; 12'd3956: glyph_rom_fn = 8'h10; 12'd3957: glyph_rom_fn = 8'h09; 12'd3958: glyph_rom_fn = 8'h25; 12'd3959: glyph_rom_fn = 8'h31; 12'd3960: glyph_rom_fn = 8'h11; 12'd3961: glyph_rom_fn = 8'h1F; 12'd3962: glyph_rom_fn = 8'h01; 12'd3963: glyph_rom_fn = 8'h01; 12'd3964: glyph_rom_fn = 8'h05; 12'd3965: glyph_rom_fn = 8'h09; 12'd3966: glyph_rom_fn = 8'h10;
                12'd3969: glyph_rom_fn = 8'h04; 12'd3970: glyph_rom_fn = 8'hD4; 12'd3971: glyph_rom_fn = 8'h54; 12'd3972: glyph_rom_fn = 8'h54; 12'd3973: glyph_rom_fn = 8'h54; 12'd3974: glyph_rom_fn = 8'h54; 12'd3975: glyph_rom_fn = 8'hDE; 12'd3976: glyph_rom_fn = 8'hDE; 12'd3977: glyph_rom_fn = 8'h54; 12'd3978: glyph_rom_fn = 8'h54; 12'd3979: glyph_rom_fn = 8'h54; 12'd3980: glyph_rom_fn = 8'h54; 12'd3981: glyph_rom_fn = 8'hD4; 12'd3982: glyph_rom_fn = 8'h04;
                12'd3984: glyph_rom_fn = 8'h20; 12'd3985: glyph_rom_fn = 8'h10; 12'd3986: glyph_rom_fn = 8'h0F; 12'd3987: glyph_rom_fn = 8'h02; 12'd3988: glyph_rom_fn = 8'h02; 12'd3989: glyph_rom_fn = 8'h02; 12'd3990: glyph_rom_fn = 8'h02; 12'd3991: glyph_rom_fn = 8'h03; 12'd3992: glyph_rom_fn = 8'h03; 12'd3993: glyph_rom_fn = 8'h02; 12'd3994: glyph_rom_fn = 8'h02; 12'd3995: glyph_rom_fn = 8'h02; 12'd3996: glyph_rom_fn = 8'h02; 12'd3997: glyph_rom_fn = 8'h07;
                12'd4001: glyph_rom_fn = 8'h74; 12'd4002: glyph_rom_fn = 8'h54; 12'd4003: glyph_rom_fn = 8'h56; 12'd4004: glyph_rom_fn = 8'h54; 12'd4005: glyph_rom_fn = 8'h54; 12'd4006: glyph_rom_fn = 8'h74; 12'd4008: glyph_rom_fn = 8'hFA; 12'd4009: glyph_rom_fn = 8'h0A; 12'd4010: glyph_rom_fn = 8'hEA; 12'd4011: glyph_rom_fn = 8'hAE; 12'd4012: glyph_rom_fn = 8'hEA; 12'd4013: glyph_rom_fn = 8'h0A; 12'd4014: glyph_rom_fn = 8'hFA;
                12'd4016: glyph_rom_fn = 8'h10; 12'd4017: glyph_rom_fn = 8'h19; 12'd4018: glyph_rom_fn = 8'h17; 12'd4019: glyph_rom_fn = 8'h15; 12'd4020: glyph_rom_fn = 8'h15; 12'd4021: glyph_rom_fn = 8'h07; 12'd4022: glyph_rom_fn = 8'h01; 12'd4023: glyph_rom_fn = 8'h10; 12'd4024: glyph_rom_fn = 8'h09; 12'd4025: glyph_rom_fn = 8'h04; 12'd4026: glyph_rom_fn = 8'h02; 12'd4028: glyph_rom_fn = 8'h02; 12'd4029: glyph_rom_fn = 8'h04; 12'd4030: glyph_rom_fn = 8'h09; 12'd4031: glyph_rom_fn = 8'h10;
                12'd4033: glyph_rom_fn = 8'h12; 12'd4034: glyph_rom_fn = 8'hA4; 12'd4036: glyph_rom_fn = 8'h30; 12'd4037: glyph_rom_fn = 8'hDE; 12'd4038: glyph_rom_fn = 8'h52; 12'd4039: glyph_rom_fn = 8'h52; 12'd4040: glyph_rom_fn = 8'h5A; 12'd4041: glyph_rom_fn = 8'h5E; 12'd4042: glyph_rom_fn = 8'h5A; 12'd4043: glyph_rom_fn = 8'h52; 12'd4044: glyph_rom_fn = 8'h52; 12'd4045: glyph_rom_fn = 8'h5E; 12'd4046: glyph_rom_fn = 8'hD0; 12'd4047: glyph_rom_fn = 8'h30;
                12'd4048: glyph_rom_fn = 8'h04; 12'd4049: glyph_rom_fn = 8'h03; 12'd4053: glyph_rom_fn = 8'h3F; 12'd4054: glyph_rom_fn = 8'h05; 12'd4055: glyph_rom_fn = 8'h05; 12'd4056: glyph_rom_fn = 8'h05; 12'd4057: glyph_rom_fn = 8'h05; 12'd4058: glyph_rom_fn = 8'h05; 12'd4059: glyph_rom_fn = 8'h05; 12'd4060: glyph_rom_fn = 8'h25; 12'd4061: glyph_rom_fn = 8'h35; 12'd4062: glyph_rom_fn = 8'h1F;
                default: glyph_rom_fn = 8'h00;
            endcase
        end
    endfunction

    // =========================================================================
    // 4. 高灵敏度全天候连续轮询 XPT2046 / HR2046 三通道 (Z1=8'hB0, X=8'hD0, Y=8'h90) 触摸引擎
    //    - 采样等待周期缩短至 0.36ms (18,000 clocks)，轮询速率提升 2.8 倍!
    //    - Z1 触控压力阈值优化至 20，2 次一致性快速均值滤波 (<380 容差)，轻触即应!
    // =========================================================================
    reg [2:0] tp_irq_sync;
    reg [1:0] tp_do_sync;
    always @(posedge clk) begin
        if (!rst_n) begin
            tp_irq_sync <= 3'b111;
            tp_do_sync  <= 2'b11;
        end else begin
            tp_irq_sync <= {tp_irq_sync[1:0], tp_irq};
            tp_do_sync  <= {tp_do_sync[0],   tp_do};
        end
    end
    wire tp_irq_low = ~tp_irq_sync[2];
    wire tp_miso    = tp_do_sync[1];

    reg [4:0] tp_clk_div;
    wire      tp_tick = (tp_clk_div == 5'd15); // 50MHz / 32 = 1.5625MHz SPI 时钟
    always @(posedge clk) begin
        if (!rst_n)
            tp_clk_div <= 5'd0;
        else
            tp_clk_div <= tp_tick ? 5'd0 : (tp_clk_div + 5'd1);
    end

    reg [1:0]  tp_state;
    reg [15:0] tp_idle_cnt;
    reg [1:0]  tp_ch_idx;     // 0=Z1(8'hB0), 1=X(8'hD0), 2=Y(8'h90)
    reg        irq_at_start;  // 转换开始前静默期锁存的 T_IRQ 状态
    reg [4:0]  tp_bit_cnt;    // 0..23 (24 个标准 SPI 时钟周期)
    reg [7:0]  tp_cmd_sh;
    reg [15:0] tp_rx_sh16;
    reg [11:0] cur_z1, cur_d0, cur_90;
    reg [11:0] prev_d0, prev_90;
    reg [2:0]  down_cnt;
    reg [3:0]  up_cnt;
    reg        pen_armed;
    reg        touch_held;
    reg [11:0] raw_d0_avg, raw_90_avg;
    reg        raw_tap_stb;

    wire [11:0] rx_val12  = tp_rx_sh16[14:3];
    wire [11:0] d0_delta  = (cur_d0 >= prev_d0) ? (cur_d0 - prev_d0) : (prev_d0 - cur_d0);
    wire [11:0] d90_delta = (cur_90 >= prev_90) ? (cur_90 - prev_90) : (prev_90 - cur_90);

    // 高灵敏度有效触控判定: (静默期 T_IRQ 为低 或 Z1 压力 >= 20) 且 X/Y 坐标在有效范围内
    wire coords_valid = (cur_d0 >= 12'd40) && (cur_d0 <= 12'd4055) &&
                        (cur_90 >= 12'd40) && (cur_90 <= 12'd4055);
    wire press_active = coords_valid && (irq_at_start || tp_irq_low || (cur_z1 >= 12'd20));

    wire [12:0] avg2_d0 = {1'b0, prev_d0} + {1'b0, cur_d0};
    wire [12:0] avg2_90 = {1'b0, prev_90} + {1'b0, cur_90};

    always @(posedge clk) begin
        if (!rst_n) begin
            tp_state     <= 2'd0;
            tp_idle_cnt  <= 16'd0;
            tp_ch_idx    <= 2'd0;
            irq_at_start <= 1'b0;
            tp_bit_cnt   <= 5'd0;
            tp_cmd_sh    <= 8'h60;
            tp_rx_sh16   <= 16'd0;
            cur_z1       <= 12'd0;
            cur_d0       <= 12'd0;
            cur_90       <= 12'd0;
            prev_d0      <= 12'd2048;
            prev_90      <= 12'd2048;
            down_cnt     <= 3'd0;
            up_cnt       <= 4'd15;
            pen_armed    <= 1'b1;
            touch_held   <= 1'b0;
            raw_d0_avg   <= 12'd2048;
            raw_90_avg   <= 12'd2048;
            raw_tap_stb  <= 1'b0;
            tp_cs        <= 1'b1;
            tp_clk       <= 1'b0;
            tp_din       <= 1'b0;
        end else begin
            raw_tap_stb <= 1'b0;
            case (tp_state)
                // 状态 0: 0.36ms 高速静默间隔，锁存 T_IRQ 并启动三通道读取
                2'd0: begin
                    tp_cs  <= 1'b1;
                    tp_clk <= 1'b0;
                    tp_din <= 1'b0;
                    if (tp_idle_cnt >= 16'd18_000) begin
                        tp_idle_cnt  <= 16'd0;
                        irq_at_start <= tp_irq_low;
                        tp_ch_idx    <= 2'd0;
                        tp_state     <= 2'd1;
                    end else begin
                        tp_idle_cnt <= tp_idle_cnt + 16'd1;
                    end
                end

                // 状态 1: 拉低 T_CS 并装载当前通道 8-bit 控制字 (0:8'hB0 读Z1, 1:8'hD0 读X, 2:8'h90 读Y)
                2'd1: begin
                    if (tp_tick) begin
                        tp_cs      <= 1'b0;
                        tp_clk     <= 1'b0;
                        tp_din     <= 1'b1; // 控制字最高位 S=1
                        tp_cmd_sh  <= (tp_ch_idx == 2'd0) ? 8'h60 :
                                      (tp_ch_idx == 2'd1) ? 8'hA0 : 8'h20;
                        tp_rx_sh16 <= 16'd0;
                        tp_bit_cnt <= 5'd0;
                        tp_state   <= 2'd2;
                    end
                end

                // 状态 2: 24 个 SPI 时钟周期移位
                2'd2: begin
                    if (tp_tick) begin
                        if (!tp_clk) begin
                            tp_clk <= 1'b1;
                            if (tp_bit_cnt >= 5'd8) begin
                                tp_rx_sh16 <= {tp_rx_sh16[14:0], tp_miso};
                            end
                        end else begin
                            tp_clk <= 1'b0;
                            if (tp_bit_cnt < 5'd7) begin
                                tp_din     <= tp_cmd_sh[7];
                                tp_cmd_sh  <= {tp_cmd_sh[6:0], 1'b0};
                                tp_bit_cnt <= tp_bit_cnt + 5'd1;
                            end else if (tp_bit_cnt < 5'd23) begin
                                tp_din     <= 1'b0;
                                tp_bit_cnt <= tp_bit_cnt + 5'd1;
                            end else begin
                                tp_cs <= 1'b1;
                                if (tp_ch_idx == 2'd0) begin
                                    cur_z1    <= rx_val12;
                                    tp_ch_idx <= 2'd1;
                                    tp_state  <= 2'd1;
                                end else if (tp_ch_idx == 2'd1) begin
                                    cur_d0    <= rx_val12;
                                    tp_ch_idx <= 2'd2;
                                    tp_state  <= 2'd1;
                                end else begin
                                    cur_90    <= rx_val12;
                                    tp_state  <= 2'd3;
                                end
                            end
                        end
                    end
                end

                // 状态 3: 2次一致性高灵敏度滤波与触控点击脉冲生成 (~0.9ms 极速响应!)
                default: begin
                    tp_cs <= 1'b1;
                    if (!press_active) begin
                        down_cnt <= 3'd0;
                        if (up_cnt < 4'd3) begin
                            up_cnt <= up_cnt + 4'd1;
                        end else begin
                            pen_armed  <= 1'b1;
                            touch_held <= 1'b0;
                        end
                    end else begin
                        up_cnt  <= 4'd0;
                        prev_d0 <= cur_d0;
                        prev_90 <= cur_90;
                        if (down_cnt == 3'd0) begin
                            down_cnt <= 3'd1;
                        end else if (d0_delta < 12'd380 && d90_delta < 12'd380) begin
                            raw_d0_avg <= avg2_d0[12:1];
                            raw_90_avg <= avg2_90[12:1];
                            touch_held <= 1'b1;
                            if (pen_armed) begin
                                raw_tap_stb <= 1'b1;
                                pen_armed   <= 1'b0;
                            end
                        end else begin
                            down_cnt <= 3'd1;
                        end
                    end
                    tp_state <= 2'd0;
                end
            endcase
        end
    end

    // ---- 3 点触摸方向/偏移自动校准与屏幕像素坐标映射 (0..319, 0..239) ----
    reg        cal_swap_xy;
    reg        cal_inv_x;
    reg        cal_inv_y;
    reg [1:0]  cal_state;     // 0=正常使用, 1=点左上红框, 2=点右上黄框, 3=点右下绿框
    reg        cal_done_lock; // 校准完成抬笔锁
    reg [11:0] cal_p1_d0, cal_p1_90;
    reg [11:0] cal_p2_d0, cal_p2_90;
    reg [11:0] cal_off_x, cal_off_y;

    wire [11:0] src_x_raw = cal_swap_xy ? raw_90_avg : raw_d0_avg;
    wire [11:0] src_y_raw = cal_swap_xy ? raw_d0_avg : raw_90_avg;
    wire [11:0] pol_x_raw = cal_inv_x   ? (12'd4095 - src_x_raw) : src_x_raw;
    wire [11:0] pol_y_raw = cal_inv_y   ? (12'd4095 - src_y_raw) : src_y_raw;

    wire [11:0] adj_x = (pol_x_raw <= cal_off_x) ? 12'd0 : (pol_x_raw - cal_off_x);
    wire [11:0] adj_y = (pol_y_raw <= cal_off_y) ? 12'd0 : (pol_y_raw - cal_off_y);

    wire [17:0] prod_tx = ({6'd0, adj_x} << 5) + ({6'd0, adj_x} << 3) + ({6'd0, adj_x} << 2) + {6'd0, adj_x};
    wire [17:0] prod_ty = ({6'd0, adj_y} << 5) + ({6'd0, adj_y} << 1) + {6'd0, adj_y};

    wire [8:0]  touch_x = (prod_tx[17:9] > 9'd319) ? 9'd319 : prod_tx[17:9];
    wire [7:0]  touch_y = (prod_ty[17:9] > 9'd239) ? 8'd239 : prod_ty[16:9];

    wire [11:0] cal_dx_d0 = (raw_d0_avg >= cal_p1_d0) ? (raw_d0_avg - cal_p1_d0) : (cal_p1_d0 - raw_d0_avg);
    wire [11:0] cal_dx_90 = (raw_90_avg >= cal_p1_90) ? (raw_90_avg - cal_p1_90) : (cal_p1_90 - raw_90_avg);
    wire        new_swap  = (cal_dx_90 > cal_dx_d0);

    // =========================================================================
    // 4b. 四大独立切屏页面状态与全屏大按钮触控路由逻辑
    //     切屏 0 (2'd0): 【手动演奏页】 (快捷栏 + 大尺寸频谱/李萨如示波器 + 大号 18 键钢琴键盘)
    //     切屏 1 (2'd1): 【曲目点播页】 (5 首名曲/自录曲大按钮卡片 + 播放/停止 + 跟弹钢琴键盘)
    //     切屏 2 (2'd2): 【智能伴奏页】 (和弦识别状态横幅 + 4 种节奏型大卡 + 4 档速度 BPM 大卡)
    //     切屏 3 (2'd3): 【音色效果页】 (4x3 全景 12 音色直选大卡 + 底部 4 个立体声效果器开关大卡)
    // =========================================================================
    reg [1:0]  ui_page;
    assign     active_page = ui_page;

    reg [1:0]  sys_mode_d;
    reg [2:0]  tp_mode_mask;
    reg [1:0]  ui_tempo_idx;
    reg [8:0]  cursor_x;
    reg [7:0]  cursor_y;
    reg [25:0] cursor_hold;
    reg [25:0] cal_hold_cnt;

    reg [1:0] touch_col4;
    always @(*) begin
        if      (touch_x < 9'd80)  touch_col4 = 2'd0;
        else if (touch_x < 9'd160) touch_col4 = 2'd1;
        else if (touch_x < 9'd240) touch_col4 = 2'd2;
        else                       touch_col4 = 2'd3;
    end

    wire [8:0] touch_key_off = (touch_x >= 9'd16) ? (touch_x - 9'd16) : 9'd0;
    wire [4:0] touch_key_idx = (touch_key_off[8:4] > 5'd17) ? 5'd17 : touch_key_off[8:4];

    // 虚拟钢琴键盘仅出现在 切屏0(手动演奏页 Y>=168) 与 切屏1(曲目跟弹页 Y>=162)
    wire on_piano_page = (ui_page == 2'd0 && touch_y >= 8'd168) ||
                         (ui_page == 2'd1 && touch_y >= 8'd162);

    always @(posedge clk) begin
        if (!rst_n) begin
            cal_swap_xy      <= 1'b1;
            cal_inv_x        <= 1'b1;
            cal_inv_y        <= 1'b0;
            cal_state        <= 2'd0;
            cal_done_lock    <= 1'b0;
            cal_p1_d0        <= 12'd0;
            cal_p1_90        <= 12'd0;
            cal_p2_d0        <= 12'd0;
            cal_p2_90        <= 12'd0;
            cal_off_x        <= 12'd240;
            cal_off_y        <= 12'd260;
            ui_page          <= 2'd0;
            sys_mode_d       <= 2'd0;
            tp_mode_mask     <= 3'd0;
            ui_tempo_idx     <= 2'd1;
            cursor_x         <= 9'd160;
            cursor_y         <= 8'd120;
            cursor_hold      <= 26'd0;
            cal_hold_cnt     <= 26'd0;
            tp_timbre_vld    <= 1'b0;
            tp_timbre        <= 4'd0;
            tp_vol_step_vld  <= 1'b0;
            tp_vol_up        <= 1'b0;
            tp_acc_vld       <= 1'b0;
            tp_acc_mode      <= 3'd1;
            tp_tempo_vld     <= 1'b0;
            tp_tempo_idx     <= 2'd1;
            tp_song_vld      <= 1'b0;
            tp_song_idx      <= 3'd0;
            tp_stop          <= 1'b0;
            tp_scene_vld     <= 1'b0;
            tp_scene         <= 3'd0;
            tp_fx_step_stb   <= 1'b0;
            tp_fx_vld        <= 1'b0;
            tp_fx_sel        <= 4'd0;
            tp_disp_step_stb <= 1'b0;
            tp_live_keys     <= 18'd0;
        end else begin
            tp_timbre_vld    <= 1'b0;
            tp_vol_step_vld  <= 1'b0;
            tp_acc_vld       <= 1'b0;
            tp_tempo_vld     <= 1'b0;
            tp_song_vld      <= 1'b0;
            tp_stop          <= 1'b0;
            tp_scene_vld     <= 1'b0;
            tp_fx_step_stb   <= 1'b0;
            tp_fx_vld        <= 1'b0;
            tp_disp_step_stb <= 1'b0;

            sys_mode_d <= sys_mode;
            if (tp_mode_mask != 3'd0)
                tp_mode_mask <= tp_mode_mask - 3'd1;
            else if (sys_mode != sys_mode_d) begin
                // 当按下编码器1 SW / S1 或蓝牙切换模式时，自动同步切屏
                ui_page <= sys_mode;
            end

            if (cursor_hold != 26'd0)
                cursor_hold <= cursor_hold - 26'd1;

            if (cal_trig_btn) begin
                if (cal_hold_cnt >= 26'd20_000_000) begin
                    cal_state    <= 2'd1;
                    cal_hold_cnt <= 26'd0;
                end else begin
                    cal_hold_cnt <= cal_hold_cnt + 26'd1;
                end
            end else begin
                cal_hold_cnt <= 26'd0;
            end

            if (!touch_held)
                cal_done_lock <= 1'b0;

            if (touch_held) begin
                cursor_x    <= touch_x;
                cursor_y    <= touch_y;
                cursor_hold <= 26'd60_000_000;
            end

            // 18 键触摸钢琴键盘实时按压/滑音发声 (切屏0 与 切屏1 底部)
            if (touch_held && (cal_state == 2'd0) && !cal_done_lock &&
                on_piano_page && (touch_x >= 9'd16) && (touch_x < 9'd304)) begin
                tp_live_keys <= (18'd1 << touch_key_idx);
            end else begin
                tp_live_keys <= 18'd0;
            end

            // 单次触摸点击事件路由
            if (raw_tap_stb) begin
                tp_mode_mask <= 3'd7;
                if (cal_state != 2'd0) begin
                    case (cal_state)
                        2'd1: begin
                            cal_p1_d0 <= raw_d0_avg;
                            cal_p1_90 <= raw_90_avg;
                            cal_state <= 2'd2;
                        end
                        2'd2: begin
                            cal_p2_d0   <= raw_d0_avg;
                            cal_p2_90   <= raw_90_avg;
                            cal_swap_xy <= new_swap;
                            cal_inv_x   <= new_swap ? (raw_90_avg < cal_p1_90) : (raw_d0_avg < cal_p1_d0);
                            if (new_swap) begin
                                if (raw_90_avg < cal_p1_90)
                                    cal_off_x <= ((12'd4095 - cal_p1_90) > 12'd500 && (12'd4095 - cal_p1_90) < 12'd960) ? ((12'd4095 - cal_p1_90) - 12'd410) : 12'd240;
                                else
                                    cal_off_x <= (cal_p1_90 > 12'd500 && cal_p1_90 < 12'd960) ? (cal_p1_90 - 12'd410) : 12'd240;
                            end else begin
                                if (raw_d0_avg < cal_p1_d0)
                                    cal_off_x <= ((12'd4095 - cal_p1_d0) > 12'd500 && (12'd4095 - cal_p1_d0) < 12'd960) ? ((12'd4095 - cal_p1_d0) - 12'd410) : 12'd240;
                                else
                                    cal_off_x <= (cal_p1_d0 > 12'd500 && cal_p1_d0 < 12'd960) ? (cal_p1_d0 - 12'd410) : 12'd240;
                            end
                            cal_state   <= 2'd3;
                        end
                        default: begin
                            cal_inv_y     <= cal_swap_xy ? (raw_d0_avg < cal_p2_d0) : (raw_90_avg < cal_p2_90);
                            if (cal_swap_xy) begin
                                if (raw_d0_avg < cal_p2_d0)
                                    cal_off_y <= ((12'd4095 - cal_p2_d0) > 12'd600 && (12'd4095 - cal_p2_d0) < 12'd1060) ? ((12'd4095 - cal_p2_d0) - 12'd520) : 12'd260;
                                else
                                    cal_off_y <= (cal_p2_d0 > 12'd600 && cal_p2_d0 < 12'd1060) ? (cal_p2_d0 - 12'd520) : 12'd260;
                            end else begin
                                if (raw_90_avg < cal_p2_90)
                                    cal_off_y <= ((12'd4095 - cal_p2_90) > 12'd600 && (12'd4095 - cal_p2_90) < 12'd1060) ? ((12'd4095 - cal_p2_90) - 12'd520) : 12'd260;
                                else
                                    cal_off_y <= (cal_p2_90 > 12'd600 && cal_p2_90 < 12'd1060) ? (cal_p2_90 - 12'd520) : 12'd260;
                            end
                            cal_state     <= 2'd0;
                            cal_done_lock <= 1'b1;
                        end
                    endcase
                end else if (touch_y < 8'd16) begin
                    // 顶部状态栏 (Y = 0..15): 左侧跳至音色页，中间循环切屏，右侧调节音量
                    if (touch_x < 9'd128) begin
                        ui_page <= 2'd3;
                    end else if (touch_x < 9'd240) begin
                        ui_page <= ui_page + 2'd1;
                    end else if (touch_x < 9'd280) begin
                        tp_vol_step_vld <= 1'b1;
                        tp_vol_up       <= 1'b0;
                    end else begin
                        tp_vol_step_vld <= 1'b1;
                        tp_vol_up       <= 1'b1;
                    end
                end else if (touch_y < 8'd40) begin
                    // 顶部 4 大切屏导航栏 Tab (Y = 16..39): 一键切换 4 大独立全屏页面!
                    ui_page <= touch_col4;
                end else begin
                    // =========================================================
                    // 四大独立全屏切屏工作区触控路由 (Y = 40..239)
                    // =========================================================
                    case (ui_page)
                        // -----------------------------------------------------
                        // 切屏 0: 【手动演奏与频谱/李萨如页】
                        //   - Y = 40..75:  4 个快捷按钮 [0:视图切换] [1:音量--] [2:音量++] [3:伴奏开/关]
                        //   - Y = 76..167: 大尺寸频谱柱 + 李萨如示波器 (点击切换视图模式)
                        //   - Y = 168..239: 大尺寸 18 键虚拟钢琴键盘 (由 touch_held 实时发声)
                        // -----------------------------------------------------
                        2'd0: begin
                            if (touch_y < 8'd76) begin
                                case (touch_col4)
                                    2'd0: tp_disp_step_stb <= 1'b1;
                                    2'd1: begin tp_vol_step_vld <= 1'b1; tp_vol_up <= 1'b0; end
                                    2'd2: begin tp_vol_step_vld <= 1'b1; tp_vol_up <= 1'b1; end
                                    default: begin
                                        tp_acc_vld  <= 1'b1;
                                        tp_acc_mode <= (acc_mode == 3'd0) ? 3'd1 : 3'd0;
                                    end
                                endcase
                            end else if (touch_y < 8'd168) begin
                                tp_disp_step_stb <= 1'b1;
                            end
                        end

                        // -----------------------------------------------------
                        // 切屏 1: 【曲目点播与录音跟弹页】
                        //   - Row 0 (Y = 40..99):  [曲01:天空之城] [曲02:经典卡农] [曲03:致爱丽丝] [曲04:欢乐之颂]
                        //   - Row 1 (Y = 100..161): [曲05:蓝牙录音] [演奏:开启/停止] [音量 --]      [音量 ++]
                        //   - Row 2 (Y = 162..239): 18 键跟弹钢琴键盘
                        // -----------------------------------------------------
                        2'd1: begin
                            if (touch_y < 8'd100) begin
                                tp_song_vld <= 1'b1;
                                tp_song_idx <= {1'b0, touch_col4};
                            end else if (touch_y < 8'd162) begin
                                case (touch_col4)
                                    2'd0: begin
                                        tp_song_vld <= 1'b1;
                                        tp_song_idx <= 3'd4;
                                    end
                                    2'd1: begin
                                        if (auto_play_en)
                                            tp_stop <= 1'b1;
                                        else begin
                                            tp_song_vld <= 1'b1;
                                            tp_song_idx <= song_idx;
                                        end
                                    end
                                    2'd2: begin tp_vol_step_vld <= 1'b1; tp_vol_up <= 1'b0; end
                                    default: begin tp_vol_step_vld <= 1'b1; tp_vol_up <= 1'b1; end
                                endcase
                            end
                        end

                        // -----------------------------------------------------
                        // 切屏 2: 【智能伴奏与和弦/速度页】
                        //   - Row 0 (Y = 40..99):  [伴奏关闭] [和弦识别状态(点击开/关)] [节拍状态(点击开/关)] [节奏切换]
                        //   - Row 1 (Y = 100..169): [01:分解和弦] [02:流行律动] [03:华尔兹拍] [04:动感八拍]
                        //   - Row 2 (Y = 170..239): [速度01:90]   [速度02:110]  [速度03:130]  [速度04:150]
                        // -----------------------------------------------------
                        2'd2: begin
                            if (touch_y < 8'd100) begin
                                case (touch_col4)
                                    2'd0: begin tp_acc_vld <= 1'b1; tp_acc_mode <= 3'd0; end
                                    2'd3: begin tp_acc_vld <= 1'b1; tp_acc_mode <= 3'd5; end
                                    default: begin
                                        tp_acc_vld  <= 1'b1;
                                        tp_acc_mode <= (acc_mode == 3'd0) ? 3'd1 : 3'd0;
                                    end
                                endcase
                            end else if (touch_y < 8'd170) begin
                                tp_acc_vld  <= 1'b1;
                                tp_acc_mode <= {1'b0, touch_col4} + 3'd1;
                            end else begin
                                tp_tempo_vld <= 1'b1;
                                tp_tempo_idx <= touch_col4;
                                ui_tempo_idx <= touch_col4;
                            end
                        end

                        // -----------------------------------------------------
                        // 切屏 3: 【12 音色库与空间效果页】
                        //   - Row 0 (Y = 40..88):   音色 00 ~ 03
                        //   - Row 1 (Y = 89..137):  音色 04 ~ 07
                        //   - Row 2 (Y = 138..187): 音色 08 ~ 11
                        //   - Row 3 (Y = 188..239): [效果搭配切换] [混响开/关] [合唱开/关] [延迟开/关]
                        // -----------------------------------------------------
                        default: begin
                            if (touch_y < 8'd89) begin
                                tp_timbre_vld <= 1'b1;
                                tp_timbre     <= {2'b00, touch_col4};
                            end else if (touch_y < 8'd138) begin
                                tp_timbre_vld <= 1'b1;
                                tp_timbre     <= 4'd4 + {2'b00, touch_col4};
                            end else if (touch_y < 8'd188) begin
                                tp_timbre_vld <= 1'b1;
                                tp_timbre     <= 4'd8 + {2'b00, touch_col4};
                            end else begin
                                case (touch_col4)
                                    2'd0: tp_fx_step_stb <= 1'b1;
                                    2'd1: begin tp_fx_vld <= 1'b1; tp_fx_sel <= 4'd10; end // 切换混响
                                    2'd2: begin tp_fx_vld <= 1'b1; tp_fx_sel <= 4'd8;  end // 切换合唱
                                    default: begin tp_fx_vld <= 1'b1; tp_fx_sel <= 4'd9; end // 切换延迟
                                endcase
                            end
                        end
                    endcase
                end
            end
        end
    end

    // =========================================================================
    // 5. 硬件李萨如 128x64 位图缓存 (1 块 BSRAM)
    // =========================================================================
    reg        scope_ram [0:8191];
    reg [12:0] scope_wr_addr;
    reg        scope_wr_en;
    reg        scope_wr_data;
    reg [12:0] scope_rd_addr;
    reg        scope_rd_bit;

    always @(posedge clk) begin
        if (scope_wr_en)
            scope_ram[scope_wr_addr] <= scope_wr_data;
        scope_rd_bit <= scope_ram[scope_rd_addr];
    end

    reg [5:0]  blink_cnt;
    wire       blink_bit = blink_cnt[4];
    reg [17:0] d_keys;
    reg [17:0] d_acc_keys;
    reg        d_beat;
    reg [3:0]  d_vol;
    reg [3:0]  d_timbre;
    reg [1:0]  d_disp_mode;
    reg [4:0]  d_b0, d_b1, d_b2, d_b3, d_b4, d_b5, d_b6, d_b7;
    reg [2:0]  d_fx_freq, d_fy_freq;
    reg [7:0]  d_liss_phase;
    reg [4:0]  d_rad_x, d_rad_y;
    reg [1:0]  d_sys_mode;
    reg [1:0]  d_preset_idx;
    reg [3:0]  d_preset_code;
    reg [2:0]  d_fx_allow;
    reg        d_auto;
    reg [2:0]  d_song;
    reg        d_rec;
    reg [2:0]  d_fx_sel;
    reg [2:0]  d_acc_mode;
    reg        d_acc_act;
    reg [3:0]  d_root;
    reg [2:0]  d_ctype;
    reg [2:0]  d_rstep;
    reg [1:0]  d_page;
    reg [6:0]  d_vel;
    reg signed [5:0] d_transpose;
    reg [5:0]  d_tr_abs_r;
    reg [3:0]  d_tr_rem_r;
    reg [3:0]  d_tr_pc_r;

    reg [8:0]  liss_step;
    wire [7:0] liss_k    = liss_step[7:0];
    wire [10:0] prod_kx  = liss_k * d_fx_freq;
    wire [10:0] prod_ky  = liss_k * d_fy_freq;
    wire [7:0]  ang_x    = prod_kx[7:0] + d_liss_phase;
    wire [7:0]  ang_y    = prod_ky[7:0] + 8'd64;
    wire signed [6:0] sin_x = sin8_lut(ang_x);
    wire signed [6:0] sin_y = sin8_lut(ang_y);
    wire signed [12:0] l_px = sin_x * $signed({1'b0, d_rad_x});
    wire signed [12:0] l_py = sin_y * $signed({1'b0, d_rad_y});
    wire [6:0] pt_x = 7'd48 + $signed(l_px[11:5]);
    wire [5:0] pt_y = 6'd30 + $signed(l_py[10:5]);

    // =========================================================================
    // 6. 320x240 四大独立切屏全屏像素合成流水线
    // =========================================================================
    reg [8:0] scan_x; // 0..319
    reg [7:0] scan_y; // 0..239

    // 4 列 x 80px 统一网格坐标译码
    reg [1:0] col4_idx;
    reg [8:0] col4_base;
    always @(*) begin
        if      (scan_x < 9'd80)  begin col4_idx = 2'd0; col4_base = 9'd0;   end
        else if (scan_x < 9'd160) begin col4_idx = 2'd1; col4_base = 9'd80;  end
        else if (scan_x < 9'd240) begin col4_idx = 2'd2; col4_base = 9'd160; end
        else                      begin col4_idx = 2'd3; col4_base = 9'd240; end
    end
    wire [8:0] lx80_full = scan_x - col4_base;
    wire [6:0] lx80      = lx80_full[6:0]; // 0..79
    wire       in_card_x = (lx80 >= 7'd3) && (lx80 <= 7'd76);
    wire       on_card_x = (lx80 == 7'd3) || (lx80 == 7'd76);
    wire       in_txt4_x = (lx80 >= 7'd8) && (lx80 < 7'd72);
    wire [6:0] txt4_off  = in_txt4_x ? (lx80 - 7'd8) : 7'd0;
    wire [1:0] txt4_slot = txt4_off[5:4]; // 0..3
    wire [3:0] txt4_cx   = txt4_off[3:0]; // 0..15

    // 音色名称查表辅助函数 (输入 0..11 音色号，返回 {num_g, c0_g, c1_g, c2_g, c3_g})
    function [34:0] timbre_glyphs_lut;
        input [3:0] t;
        begin
            case (t)
                4'd0:    timbre_glyphs_lut = {7'd73, 7'd39, 7'd40, 7'd41, 7'd42}; // 00 三角钢琴
                4'd1:    timbre_glyphs_lut = {7'd74, 7'd26, 7'd27, 7'd43, 7'd41}; // 01 经典电钢
                4'd2:    timbre_glyphs_lut = {7'd75, 7'd44, 7'd45, 7'd46, 7'd1};  // 02 水晶八音
                4'd3:    timbre_glyphs_lut = {7'd76, 7'd47, 7'd48, 7'd49, 7'd42}; // 03 教堂风琴
                4'd4:    timbre_glyphs_lut = {7'd77, 7'd50, 7'd27, 7'd51, 7'd52}; // 04 古典吉他
                4'd5:    timbre_glyphs_lut = {7'd78, 7'd53, 7'd6,  7'd54, 7'd35}; // 05 交响弦乐
                4'd6:    timbre_glyphs_lut = {7'd79, 7'd23, 7'd55, 7'd56, 7'd57}; // 06 空灵长笛
                4'd7:    timbre_glyphs_lut = {7'd80, 7'd58, 7'd59, 7'd60, 7'd61}; // 07 木管单簧
                4'd8:    timbre_glyphs_lut = {7'd81, 7'd62, 7'd63, 7'd64, 7'd59}; // 08 辉煌铜管
                4'd9:    timbre_glyphs_lut = {7'd82, 7'd58, 7'd42, 7'd65, 7'd66}; // 09 木琴马林
                4'd10:   timbre_glyphs_lut = {7'd83, 7'd67, 7'd68, 7'd69, 7'd70}; // 10 重低贝司
                default: timbre_glyphs_lut = {7'd84, 7'd7,  7'd71, 7'd72, 7'd1};  // 11 合成主音
            endcase
        end
    endfunction

    // 曲目名称查表辅助函数 (输入 0..4 曲目号)
    function [34:0] song_glyphs_lut;
        input [2:0] s;
        begin
            case (s)
                3'd0:    song_glyphs_lut = {7'd74, 7'd22, 7'd23, 7'd24, 7'd25}; // 01 天空之城
                3'd1:    song_glyphs_lut = {7'd75, 7'd26, 7'd27, 7'd28, 7'd29}; // 02 经典卡农
                3'd2:    song_glyphs_lut = {7'd76, 7'd30, 7'd31, 7'd32, 7'd33}; // 03 致爱丽丝
                3'd3:    song_glyphs_lut = {7'd77, 7'd34, 7'd35, 7'd24, 7'd36}; // 04 欢乐之颂
                default: song_glyphs_lut = {7'd78, 7'd37, 7'd38, 7'd21, 7'd1};  // 05 蓝牙录音
            endcase
        end
    endfunction

    // 效果搭配名称查表辅助函数
    function [27:0] preset_glyphs_lut;
        input [3:0] c;
        begin
            case (c)
                4'd1:    preset_glyphs_lut = {7'd5,   7'd6,   7'd11,  7'd12};  // 混响开启
                4'd2:    preset_glyphs_lut = {7'd123, 7'd124, 7'd120, 7'd121}; // 原声模式
                4'd3:    preset_glyphs_lut = {7'd5,   7'd6,   7'd7,   7'd8};   // 混响合唱
                4'd4:    preset_glyphs_lut = {7'd7,   7'd8,   7'd11,  7'd12};  // 合唱开启
                4'd5:    preset_glyphs_lut = {7'd125, 7'd1,   7'd5,   7'd6};   // 颤音混响
                4'd6:    preset_glyphs_lut = {7'd5,   7'd6,   7'd9,   7'd10};  // 混响延迟
                4'd7:    preset_glyphs_lut = {7'd126, 7'd1,   7'd5,   7'd6};   // 滑音混响
                4'd8:    preset_glyphs_lut = {7'd125, 7'd1,   7'd5,   7'd8};   // 颤音混唱
                4'd9:    preset_glyphs_lut = {7'd126, 7'd1,   7'd125, 7'd1};   // 滑音颤音
                4'd10:   preset_glyphs_lut = {7'd126, 7'd1,   7'd9,   7'd10};  // 滑音延迟
                default: preset_glyphs_lut = {7'd118, 7'd119, 7'd122, 7'd11};  // 效果全开
            endcase
        end
    endfunction

    // 伴奏节奏名称查表辅助函数 (输入 0..4 伴奏模式)
    function [27:0] acc_glyphs_lut;
        input [2:0] m;
        begin
            case (m)
                3'd0:    acc_glyphs_lut = {7'd88, 7'd18, 7'd13, 7'd14}; // 伴奏关闭
                3'd1:    acc_glyphs_lut = {7'd89, 7'd90, 7'd91, 7'd54}; // 分解和弦
                3'd2:    acc_glyphs_lut = {7'd92, 7'd93, 7'd94, 7'd16}; // 流行律动
                3'd3:    acc_glyphs_lut = {7'd95, 7'd96, 7'd97, 7'd98}; // 华尔兹拍
                default: acc_glyphs_lut = {7'd16, 7'd99, 7'd46, 7'd98}; // 动感八拍
            endcase
        end
    endfunction

    wire [34:0] cur_timbre_g = timbre_glyphs_lut(d_timbre);
    wire [34:0] cur_song_g   = song_glyphs_lut(d_song);
    wire [27:0] cur_preset_g = preset_glyphs_lut(d_preset_code);
    wire [27:0] cur_acc_g    = acc_glyphs_lut(d_acc_mode);
    wire [5:0]  w_tr_abs     = transpose_semi[5] ? (-transpose_semi) : transpose_semi;
    wire [5:0]  w_tr_rem     = (w_tr_abs >= 6'd20) ? (w_tr_abs - 6'd20) :
                               (w_tr_abs >= 6'd10) ? (w_tr_abs - 6'd10) : w_tr_abs;
    wire [6:0]  w_tr_norm_w  = $unsigned($signed({transpose_semi[5], transpose_semi}) + 7'sd24);
    wire [5:0]  w_tr_norm    = w_tr_norm_w[5:0];
    wire [5:0]  w_tr_pc_w    = (w_tr_norm >= 6'd48) ? 6'd0 :
                               (w_tr_norm >= 6'd36) ? (w_tr_norm - 6'd36) :
                               (w_tr_norm >= 6'd24) ? (w_tr_norm - 6'd24) :
                               (w_tr_norm >= 6'd12) ? (w_tr_norm - 6'd12) : w_tr_norm;
    wire [3:0]  w_tr_pc      = w_tr_pc_w[3:0];
    wire [4:0]  d_root_sum   = {1'b0, d_root} + {1'b0, d_tr_pc_r};
    wire [3:0]  d_eff_root   = (d_root_sum >= 5'd12) ? (d_root_sum[3:0] - 4'd12) : d_root_sum[3:0];
    wire [6:0]  root_gid     = (d_eff_root <= 4'd11) ? (7'd100 + {3'd0, d_eff_root}) : 7'd100;
    wire [6:0]  tr_key_gid   = 7'd100 + {3'd0, d_tr_pc_r};
    wire [6:0]  tr_abs_gid   = (d_tr_abs_r <= 6'd11) ? (7'd73 + {3'd0, d_tr_abs_r[3:0]}) :
                               (d_tr_abs_r <  6'd20) ? ((scan_x[3:0] < 4'd8) ? 7'd83 : (7'd73 + {3'd0, d_tr_rem_r})) :
                                                       ((scan_x[3:0] < 4'd8) ? 7'd75 : (7'd73 + {3'd0, d_tr_rem_r}));
    wire [6:0]  ctype_gid    = (d_ctype <= 3'd5) ? (7'd112 + {4'd0, d_ctype}) : 7'd112;

    // 顶部第 0 行动态文字 (col 9..16)
    reg [6:0] s_hdr0_g, s_hdr1_g, s_num_g, s_sep_g, s_c0_g, s_c1_g, s_c2_g, s_c3_g;
    always @(*) begin
        s_hdr0_g = 7'd120; s_hdr1_g = 7'd121; s_sep_g = 7'd86;
        if (d_rec) begin
            s_hdr0_g = 7'd3;  s_hdr1_g = 7'd4;  s_num_g = 7'd21;
            s_c0_g   = 7'd19; s_c1_g   = 7'd20; s_c2_g  = 7'd21; s_c3_g = 7'd1;
        end else begin
            case (d_page)
                2'd0: begin
                    s_hdr0_g = 7'd120; s_hdr1_g = 7'd121; s_num_g = 7'd74 + {5'd0, d_disp_mode};
                    if (d_transpose != 6'sd0) begin
                        s_c0_g = tr_key_gid;
                        s_c1_g = d_transpose[5] ? 7'd85 : 7'd11;
                        s_c2_g = tr_abs_gid;
                        s_c3_g = 7'd1;
                    end else begin
                        s_c0_g = 7'd15; s_c1_g = 7'd16; s_c2_g = 7'd17; s_c3_g = 7'd18;
                    end
                end
                2'd1: begin
                    s_hdr0_g = 7'd3; s_hdr1_g = 7'd4; s_num_g = cur_song_g[34:28];
                    s_c0_g   = cur_song_g[27:21]; s_c1_g = cur_song_g[20:14];
                    s_c2_g   = cur_song_g[13:7];  s_c3_g = cur_song_g[6:0];
                end
                2'd2: begin
                    s_hdr0_g = 7'd88; s_hdr1_g = 7'd18;
                    if (d_acc_act) begin
                        s_num_g = root_gid;
                        s_sep_g = ctype_gid;
                    end else begin
                        s_num_g = 7'd73 + {4'd0, d_acc_mode};
                        s_sep_g = 7'd86;
                    end
                    s_c0_g = cur_acc_g[27:21]; s_c1_g = cur_acc_g[20:14];
                    s_c2_g = cur_acc_g[13:7];  s_c3_g = cur_acc_g[6:0];
                end
                default: begin
                    s_hdr0_g = 7'd118; s_hdr1_g = 7'd119;
                    s_num_g  = 7'd74 + {5'd0, d_preset_idx};
                    s_c0_g   = cur_preset_g[27:21]; s_c1_g = cur_preset_g[20:14];
                    s_c2_g   = cur_preset_g[13:7];  s_c3_g = cur_preset_g[6:0];
                end
            endcase
        end
    end

    // ---- 切屏 0 专用: 大尺寸 8 频段频谱柱 + 李萨如示波器坐标 (Y = 82..161, 高 80px) ----
    wire [8:0] spec_x_off = (scan_x >= 9'd8) ? (scan_x - 9'd8) : 9'd0;
    wire [2:0] spec_band  = (d_disp_mode == 2'd2) ? spec_x_off[7:5] : spec_x_off[6:4];
    wire [4:0] spec_in_x  = (d_disp_mode == 2'd2) ? spec_x_off[4:0] : {1'b0, spec_x_off[3:0]};
    wire [4:0] spec_bar_w = (d_disp_mode == 2'd2) ? 5'd26 : 5'd12;

    reg [4:0] spec_bval;
    always @(*) begin
        case (spec_band)
            3'd0: spec_bval = d_b0;
            3'd1: spec_bval = d_b1;
            3'd2: spec_bval = d_b2;
            3'd3: spec_bval = d_b3;
            3'd4: spec_bval = d_b4;
            3'd5: spec_bval = d_b5;
            3'd6: spec_bval = d_b6;
            3'd7: spec_bval = d_b7;
        endcase
    end

    // 频谱垂直高度 60px (Y = 92..151): 每 2px 一级 -> 0..29 级
    wire [7:0] spec_y_inv = (scan_y >= 8'd92 && scan_y < 8'd152) ? (8'd151 - scan_y) : 8'd0;
    wire [4:0] spec_level = spec_y_inv[5:1];

    // 李萨如示波器窗口读取坐标 (Y = 92..151, 60px 高):
    //   - 同屏模式 (disp_mode==0): X = 180..275 (96px 宽)
    //   - 全屏模式 (disp_mode==1): X = 64..255  (192px 宽, 2x 放大)
    wire       in_scope_split = (d_disp_mode == 2'd0) && (scan_x >= 9'd180) && (scan_x < 9'd276) && (scan_y >= 8'd92) && (scan_y < 8'd152);
    wire       in_scope_full  = (d_disp_mode == 2'd1) && (scan_x >= 9'd64)  && (scan_x < 9'd256) && (scan_y >= 8'd92) && (scan_y < 8'd152);
    wire [8:0] scope_dx_split = scan_x - 9'd180;
    wire [8:0] scope_dx_full  = scan_x - 9'd64;
    wire [6:0] scope_rx       = in_scope_full ? scope_dx_full[7:1] : scope_dx_split[6:0];
    wire [7:0] scope_dy       = scan_y - 8'd92;
    wire [5:0] scope_ry       = scope_dy[5:0];

    always @(*) begin
        scope_rd_addr = {scope_ry, scope_rx};
    end

    // 大尺寸 18 键钢琴键盘条坐标 (X = 16..303, 每键 16px 宽; 切屏0 Y=170..235, 切屏1 Y=166..235)
    wire       in_piano_x   = (scan_x >= 9'd16) && (scan_x < 9'd304);
    wire [8:0] piano_dx     = scan_x - 9'd16;
    wire [4:0] piano_kidx   = piano_dx[8:4];
    wire [3:0] piano_kx     = piano_dx[3:0];
    wire       is_black_key = (piano_kidx == 5'd1)  || (piano_kidx == 5'd3)  || (piano_kidx == 5'd6)  ||
                              (piano_kidx == 5'd8)  || (piano_kidx == 5'd10) || (piano_kidx == 5'd13) ||
                              (piano_kidx == 5'd15);

    // 切屏 3 (12 音色库) 3行x4列 音色编号映射
    wire [1:0] p3_t_row      = (scan_y < 8'd89) ? 2'd0 : ((scan_y < 8'd138) ? 2'd1 : 2'd2);
    wire [3:0] p3_timbre_id  = (p3_t_row == 2'd0) ? {2'b00, col4_idx} :
                               (p3_t_row == 2'd1) ? (4'd4 + {2'b00, col4_idx}) :
                                                    (4'd8 + {2'b00, col4_idx});
    wire [34:0] p3_t_glyphs  = timbre_glyphs_lut(p3_timbre_id);
    wire [27:0] p2_a_glyphs  = acc_glyphs_lut({1'b0, col4_idx} + 3'd1);
    wire [34:0] p1_s_glyphs  = song_glyphs_lut({1'b0, col4_idx});
    wire [34:0] p1_s4_glyphs = song_glyphs_lut(3'd4);

    reg [6:0]  req_glyph_id;
    reg [3:0]  req_char_x;
    reg [3:0]  req_char_y;
    reg        req_text_en;
    reg [15:0] req_fg_rgb;
    reg [15:0] req_bg_rgb;

    wire [4:0] top_col_slot = scan_x[8:4]; // 0..19
    wire [3:0] grid_cx      = scan_x[3:0];
    wire [3:0] grid_cy      = scan_y[3:0];

    always @(*) begin
        req_glyph_id = 7'd0;
        req_char_x   = grid_cx;
        req_char_y   = grid_cy;
        req_text_en  = 1'b0;
        req_fg_rgb   = 16'hFFFF;
        req_bg_rgb   = 16'h0842; // 深空蓝底色

        // =====================================================================
        // A. 顶部第 0 行全局状态栏 (Y = 0..15): 音色名 + 当前状态 + 音量数值
        // =====================================================================
        if (scan_y < 8'd16) begin
            req_bg_rgb  = (scan_x < 9'd128) ? 16'h10A6 : (scan_x < 9'd272 ? 16'h0864 : 16'h1926);
            req_text_en = 1'b1;
            req_fg_rgb  = (scan_x < 9'd128) ? 16'h07FF : (d_rec ? 16'hF800 : 16'hFFE0);
            case (top_col_slot)
                5'd0:  req_glyph_id = 7'd1;                   // '音'
                5'd1:  req_glyph_id = 7'd2;                   // '色'
                5'd2:  req_glyph_id = cur_timbre_g[34:28];    // '00'..'11'
                5'd3:  req_glyph_id = 7'd86;                  // ':'
                5'd4:  req_glyph_id = cur_timbre_g[27:21];
                5'd5:  req_glyph_id = cur_timbre_g[20:14];
                5'd6:  req_glyph_id = cur_timbre_g[13:7];
                5'd7:  req_glyph_id = cur_timbre_g[6:0];
                5'd8:  begin req_glyph_id = 7'd87; req_fg_rgb = 16'h7BEF; end
                5'd9:  req_glyph_id = s_hdr0_g;
                5'd10: req_glyph_id = s_hdr1_g;
                5'd11: req_glyph_id = s_num_g;
                5'd12: req_glyph_id = s_sep_g;
                5'd13: req_glyph_id = s_c0_g;
                5'd14: req_glyph_id = s_c1_g;
                5'd15: req_glyph_id = s_c2_g;
                5'd16: req_glyph_id = s_c3_g;
                5'd17: begin req_glyph_id = 7'd87; req_fg_rgb = 16'h7BEF; end
                5'd18: begin
                    req_glyph_id = (d_transpose != 6'sd0) ? tr_key_gid : 7'd1;
                    req_fg_rgb   = (d_transpose > 6'sd0)  ? 16'h07FF :
                                   (d_transpose < 6'sd0)  ? 16'hF81F :
                                   (d_beat ? (d_rstep == 3'd0 ? 16'hF81F : 16'hFFE0) : 16'h07E0);
                end
                default: begin
                    if (d_vol <= 4'd11)
                        req_glyph_id = 7'd73 + {3'd0, d_vol};
                    else if (grid_cx < 4'd8)
                        req_glyph_id = 7'd83;
                    else
                        req_glyph_id = 7'd63 + {3'd0, d_vol};
                    req_fg_rgb = 16'h07E0;
                end
            endcase

        // =====================================================================
        // B. 顶部第 1 行 4 大切屏导航栏 Tab (Y = 16..39):
        //    [0:手动演奏]  [1:曲目演奏]  [2:伴奏模式]  [3:音色效果]
        // =====================================================================
        end else if (scan_y < 8'd40) begin
            if (scan_y == 8'd39) begin
                req_bg_rgb = 16'h07FF;
            end else if (in_card_x && scan_y >= 8'd18 && scan_y <= 8'd37) begin
                if (on_card_x || scan_y == 8'd18 || scan_y == 8'd37)
                    req_bg_rgb = (d_page == col4_idx) ? 16'hFFE0 : 16'h39E7;
                else
                    req_bg_rgb = (d_page == col4_idx) ? 16'h0318 : 16'h1084;

                if (in_txt4_x && scan_y >= 8'd20 && scan_y < 8'd36) begin
                    req_text_en = 1'b1;
                    req_char_x  = txt4_cx;
                    req_char_y  = scan_y[3:0] - 4'd4;
                    req_fg_rgb  = (d_page == col4_idx) ? 16'hFFE0 : 16'hDF7B;
                    case (col4_idx)
                        2'd0: case (txt4_slot) 2'd0: req_glyph_id=7'd15; 2'd1: req_glyph_id=7'd16; 2'd2: req_glyph_id=7'd17;  2'd3: req_glyph_id=7'd18;  endcase // 手动演奏
                        2'd1: case (txt4_slot) 2'd0: req_glyph_id=7'd3;  2'd1: req_glyph_id=7'd4;  2'd2: req_glyph_id=7'd17;  2'd3: req_glyph_id=7'd18;  endcase // 曲目演奏
                        2'd2: case (txt4_slot) 2'd0: req_glyph_id=7'd88; 2'd1: req_glyph_id=7'd18; 2'd2: req_glyph_id=7'd120; 2'd3: req_glyph_id=7'd121; endcase // 伴奏模式
                        default: case (txt4_slot) 2'd0: req_glyph_id=7'd1; 2'd1: req_glyph_id=7'd2; 2'd2: req_glyph_id=7'd118; 2'd3: req_glyph_id=7'd119; endcase // 音色效果
                    endcase
                end
            end

        // =====================================================================
        // C. 四大独立全屏切屏主工作区 (Y = 40..239)
        // =====================================================================
        end else begin
            case (d_page)
                // -------------------------------------------------------------
                // 【切屏 0: 手动演奏与频谱/李萨如页】
                //   - Y = 42..73:  4 个快捷控制按钮 [视图模式] [音量--] [音量++] [伴奏开/关]
                //   - Y = 78..163: 宽幅频谱柱与李萨如示波器专享视窗
                //   - Y = 170..235: 66px 高大尺寸 18 键仿真钢琴键盘
                // -------------------------------------------------------------
                2'd0: begin
                    if (scan_y >= 8'd42 && scan_y <= 8'd73 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd42 || scan_y == 8'd73)
                            req_bg_rgb = 16'h07FF;
                        else if (col4_idx == 2'd3 && d_acc_mode != 3'd0)
                            req_bg_rgb = 16'h03A8;
                        else
                            req_bg_rgb = 16'h1928;

                        if (in_txt4_x && scan_y >= 8'd50 && scan_y < 8'd66) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd2;
                            req_fg_rgb  = 16'hFFE0;
                            case (col4_idx)
                                2'd0: case (txt4_slot) 2'd0: req_glyph_id=7'd120; 2'd1: req_glyph_id=7'd121; 2'd2: req_glyph_id=7'd86; 2'd3: req_glyph_id=7'd74+{5'd0,d_disp_mode}; endcase // 模式:01
                                2'd1: case (txt4_slot) 2'd0: req_glyph_id=7'd1;   2'd1: req_glyph_id=7'd86;  2'd2: req_glyph_id=7'd85; 2'd3: req_glyph_id=7'd85; endcase // 音:--
                                2'd2: case (txt4_slot) 2'd0: req_glyph_id=7'd1;   2'd1: req_glyph_id=7'd86;  2'd2: req_glyph_id=7'd11; 2'd3: req_glyph_id=7'd12; endcase // 音:开启(音量+)
                                default: case (txt4_slot)
                                    2'd0: req_glyph_id = 7'd88;
                                    2'd1: req_glyph_id = 7'd18;
                                    2'd2: req_glyph_id = (d_acc_mode != 3'd0) ? 7'd11 : 7'd13;
                                    2'd3: req_glyph_id = (d_acc_mode != 3'd0) ? 7'd12 : 7'd14;
                                endcase
                            endcase
                        end
                    end else if (scan_y >= 8'd78 && scan_y <= 8'd163) begin
                        if (scan_y == 8'd78 || scan_y == 8'd163 || scan_x == 9'd4 || scan_x == 9'd315) begin
                            req_bg_rgb = 16'h39E7;
                        end else if (scan_y >= 8'd92 && scan_y < 8'd152) begin
                            if (d_disp_mode == 2'd0) begin
                                if (scan_x >= 9'd8 && scan_x < 9'd136) begin
                                    if (spec_in_x < spec_bar_w && (spec_y_inv[0] != 1'b0)) begin
                                        if (spec_bval > spec_level) begin
                                            if (spec_level >= 5'd21)      req_bg_rgb = 16'hF800;
                                            else if (spec_level >= 5'd11) req_bg_rgb = 16'hFFE0;
                                            else                          req_bg_rgb = 16'h07E0;
                                        end else begin
                                            req_bg_rgb = 16'h1083;
                                        end
                                    end
                                end else if (in_scope_split) begin
                                    if (scan_x == 9'd180 || scan_x == 9'd275 || scan_y == 8'd92 || scan_y == 8'd151)
                                        req_bg_rgb = 16'h07FF;
                                    else if (scope_rd_bit)
                                        req_bg_rgb = 16'h07FF;
                                    else if (scan_x == 9'd228 || scan_y == 8'd122)
                                        req_bg_rgb = 16'h1926;
                                    else
                                        req_bg_rgb = 16'h0021;
                                end
                            end else if (d_disp_mode == 2'd1) begin
                                if (in_scope_full) begin
                                    if (scan_x == 9'd64 || scan_x == 9'd255 || scan_y == 8'd92 || scan_y == 8'd151)
                                        req_bg_rgb = 16'h07FF;
                                    else if (scope_rd_bit)
                                        req_bg_rgb = 16'h07E0;
                                    else if (scan_x == 9'd160 || scan_y == 8'd122)
                                        req_bg_rgb = 16'h1926;
                                    else
                                        req_bg_rgb = 16'h0021;
                                end
                            end else begin
                                if (scan_x >= 9'd8 && scan_x < 9'd264) begin
                                    if (spec_in_x < spec_bar_w && (spec_y_inv[0] != 1'b0)) begin
                                        if (spec_bval > spec_level) begin
                                            if (spec_level >= 5'd21)      req_bg_rgb = 16'hF81F;
                                            else if (spec_level >= 5'd11) req_bg_rgb = 16'h07FF;
                                            else                          req_bg_rgb = 16'h07E0;
                                        end else begin
                                            req_bg_rgb = 16'h1083;
                                        end
                                    end
                                end
                            end
                        end
                    end else if (scan_y >= 8'd170 && scan_y < 8'd236 && in_piano_x) begin
                        if (piano_kx == 4'd0 || piano_kx == 4'd15 || scan_y == 8'd170 || scan_y == 8'd235) begin
                            req_bg_rgb = 16'h1082;
                        end else if (guide_en && guide_keys[piano_kidx]) begin
                            req_bg_rgb = blink_bit ? 16'hF81F : 16'hFD20;
                        end else if (d_keys[piano_kidx]) begin
                            req_bg_rgb = (d_vel >= 7'd108) ? 16'hFD20 : ((d_vel >= 7'd72) ? 16'h07FF : 16'h5D9F);
                        end else if (d_acc_keys[piano_kidx]) begin
                            req_bg_rgb = 16'h07E0;
                        end else if (is_black_key) begin
                            req_bg_rgb = (scan_y < 8'd208) ? 16'h18C3 : 16'h4208;
                        end else begin
                            req_bg_rgb = 16'hEF7D;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 【切屏 1: 曲目点播与录音跟弹页】
                //   - Row 0 (Y = 44..95):  [曲01:天空之城] [曲02:经典卡农] [曲03:致爱丽丝] [曲04:欢乐之颂]
                //   - Row 1 (Y = 102..153): [曲05:蓝牙录音] [演奏:开启/关闭] [音量 --]      [音量 ++]
                //   - Row 2 (Y = 164..235): 72px 高大尺寸跟弹钢琴键盘
                // -------------------------------------------------------------
                2'd1: begin
                    if (scan_y >= 8'd44 && scan_y <= 8'd95 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd44 || scan_y == 8'd95)
                            req_bg_rgb = (d_auto && d_song == {1'b0, col4_idx}) ? 16'hFFE0 : 16'h39E7;
                        else
                            req_bg_rgb = (d_auto && d_song == {1'b0, col4_idx}) ? 16'h039A : 16'h10A5;

                        if (in_txt4_x && scan_y >= 8'd50 && scan_y < 8'd66 && (txt4_slot == 2'd1 || txt4_slot == 2'd2)) begin
                            req_text_en  = 1'b1;
                            req_char_x   = txt4_cx;
                            req_char_y   = scan_y[3:0] - 4'd2;
                            req_fg_rgb   = 16'h07FF;
                            req_glyph_id = (txt4_slot == 2'd1) ? 7'd3 : p1_s_glyphs[34:28];
                        end else if (in_txt4_x && scan_y >= 8'd72 && scan_y < 8'd88) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd8;
                            req_fg_rgb  = (d_auto && d_song == {1'b0, col4_idx}) ? 16'hFFE0 : 16'hFFFF;
                            case (txt4_slot)
                                2'd0: req_glyph_id = p1_s_glyphs[27:21];
                                2'd1: req_glyph_id = p1_s_glyphs[20:14];
                                2'd2: req_glyph_id = p1_s_glyphs[13:7];
                                2'd3: req_glyph_id = p1_s_glyphs[6:0];
                            endcase
                        end
                    end else if (scan_y >= 8'd102 && scan_y <= 8'd153 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd102 || scan_y == 8'd153)
                            req_bg_rgb = 16'h07FF;
                        else if (col4_idx == 2'd0 && d_auto && d_song == 3'd4)
                            req_bg_rgb = 16'h039A;
                        else if (col4_idx == 2'd1 && d_auto)
                            req_bg_rgb = 16'h03A8;
                        else if (col4_idx >= 2'd2)
                            req_bg_rgb = 16'h1928;
                        else
                            req_bg_rgb = 16'h10A5;

                        if (in_txt4_x && scan_y >= 8'd108 && scan_y < 8'd124 && (txt4_slot == 2'd1 || txt4_slot == 2'd2)) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd12;
                            req_fg_rgb  = 16'h07FF;
                            case (col4_idx)
                                2'd0: req_glyph_id = (txt4_slot == 2'd1) ? 7'd3  : 7'd78; // 曲05
                                2'd1: req_glyph_id = (txt4_slot == 2'd1) ? 7'd3  : 7'd4;  // 曲目
                                2'd2: req_glyph_id = (txt4_slot == 2'd1) ? 7'd1  : 7'd85; // 音--
                                default: req_glyph_id = (txt4_slot == 2'd1) ? 7'd1 : 7'd11; // 音开(+)
                            endcase
                        end else if (in_txt4_x && scan_y >= 8'd130 && scan_y < 8'd146) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd2;
                            req_fg_rgb  = 16'hFFE0;
                            case (col4_idx)
                                2'd0: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = p1_s4_glyphs[27:21];
                                        2'd1: req_glyph_id = p1_s4_glyphs[20:14];
                                        2'd2: req_glyph_id = p1_s4_glyphs[13:7];
                                        2'd3: req_glyph_id = p1_s4_glyphs[6:0];
                                    endcase
                                end
                                2'd1: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd17;
                                        2'd1: req_glyph_id = 7'd18;
                                        2'd2: req_glyph_id = d_auto ? 7'd11 : 7'd13;
                                        2'd3: req_glyph_id = d_auto ? 7'd12 : 7'd14;
                                    endcase
                                end
                                2'd2: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd1;
                                        2'd1: req_glyph_id = 7'd86;
                                        2'd2: req_glyph_id = 7'd85;
                                        2'd3: req_glyph_id = 7'd85;
                                    endcase
                                end
                                default: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd1;
                                        2'd1: req_glyph_id = 7'd86;
                                        2'd2: req_glyph_id = 7'd11;
                                        2'd3: req_glyph_id = 7'd12;
                                    endcase
                                end
                            endcase
                        end
                    end else if (scan_y >= 8'd164 && scan_y < 8'd236 && in_piano_x) begin
                        if (piano_kx == 4'd0 || piano_kx == 4'd15 || scan_y == 8'd164 || scan_y == 8'd235) begin
                            req_bg_rgb = 16'h1082;
                        end else if (guide_en && guide_keys[piano_kidx]) begin
                            req_bg_rgb = blink_bit ? 16'hF81F : 16'hFD20;
                        end else if (d_keys[piano_kidx]) begin
                            req_bg_rgb = 16'h07FF;
                        end else if (is_black_key) begin
                            req_bg_rgb = (scan_y < 8'd204) ? 16'h18C3 : 16'h4208;
                        end else begin
                            req_bg_rgb = 16'hEF7D;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 【切屏 2: 智能伴奏与和弦/速度页】
                //   - Row 0 (Y = 44..95):  [伴奏关闭] [当前识别和弦卡] [当前伴奏状态卡] [节奏切换]
                //   - Row 1 (Y = 104..165): [01:分解和弦] [02:流行律动] [03:华尔兹拍] [04:动感八拍]
                //   - Row 2 (Y = 174..235): [速度01:90]   [速度02:110]  [速度03:130]  [速度04:150]
                // -------------------------------------------------------------
                2'd2: begin
                    if (scan_y >= 8'd44 && scan_y <= 8'd95 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd44 || scan_y == 8'd95)
                            req_bg_rgb = 16'h07FF;
                        else if (col4_idx == 2'd0 && d_acc_mode == 3'd0)
                            req_bg_rgb = 16'h3A08;
                        else if ((col4_idx == 2'd1 || col4_idx == 2'd2) && d_acc_mode != 3'd0)
                            req_bg_rgb = 16'h03A8;
                        else
                            req_bg_rgb = 16'h1928;

                        if (in_txt4_x && scan_y >= 8'd62 && scan_y < 8'd78) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd14;
                            req_fg_rgb  = 16'hFFE0;
                            case (col4_idx)
                                2'd0: case (txt4_slot) 2'd0: req_glyph_id=7'd88; 2'd1: req_glyph_id=7'd18; 2'd2: req_glyph_id=7'd13; 2'd3: req_glyph_id=7'd14; endcase // 伴奏关闭
                                2'd1: case (txt4_slot) 2'd0: req_glyph_id=7'd88; 2'd1: req_glyph_id=7'd86; 2'd2: req_glyph_id=root_gid; 2'd3: req_glyph_id=ctype_gid; endcase // 伴:C Maj
                                2'd2: case (txt4_slot)
                                    2'd0: req_glyph_id = cur_acc_g[27:21];
                                    2'd1: req_glyph_id = cur_acc_g[20:14];
                                    2'd2: req_glyph_id = cur_acc_g[13:7];
                                    2'd3: req_glyph_id = cur_acc_g[6:0];
                                endcase
                                default: case (txt4_slot) 2'd0: req_glyph_id=7'd88; 2'd1: req_glyph_id=7'd18; 2'd2: req_glyph_id=7'd120; 2'd3: req_glyph_id=7'd121; endcase // 伴奏模式(切换)
                            endcase
                        end
                    end else if (scan_y >= 8'd104 && scan_y <= 8'd165 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd104 || scan_y == 8'd165)
                            req_bg_rgb = (d_acc_mode == ({1'b0, col4_idx} + 3'd1)) ? 16'hFFE0 : 16'h39E7;
                        else
                            req_bg_rgb = (d_acc_mode == ({1'b0, col4_idx} + 3'd1)) ? 16'h03A8 : 16'h10A5;

                        if (in_txt4_x && scan_y >= 8'd114 && scan_y < 8'd130 && (txt4_slot == 2'd1 || txt4_slot == 2'd2)) begin
                            req_text_en  = 1'b1;
                            req_char_x   = txt4_cx;
                            req_char_y   = scan_y[3:0] - 4'd2;
                            req_fg_rgb   = 16'h07FF;
                            req_glyph_id = (txt4_slot == 2'd1) ? 7'd88 : (7'd74 + {5'd0, col4_idx});
                        end else if (in_txt4_x && scan_y >= 8'd140 && scan_y < 8'd156) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd12;
                            req_fg_rgb  = (d_acc_mode == ({1'b0, col4_idx} + 3'd1)) ? 16'hFFE0 : 16'hFFFF;
                            case (txt4_slot)
                                2'd0: req_glyph_id = p2_a_glyphs[27:21];
                                2'd1: req_glyph_id = p2_a_glyphs[20:14];
                                2'd2: req_glyph_id = p2_a_glyphs[13:7];
                                2'd3: req_glyph_id = p2_a_glyphs[6:0];
                            endcase
                        end
                    end else if (scan_y >= 8'd174 && scan_y <= 8'd235 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd174 || scan_y == 8'd235)
                            req_bg_rgb = (ui_tempo_idx == col4_idx) ? 16'h07FF : 16'h39E7;
                        else
                            req_bg_rgb = (ui_tempo_idx == col4_idx) ? 16'h1928 : 16'h10A5;

                        if (in_txt4_x && scan_y >= 8'd196 && scan_y < 8'd212) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd4;
                            req_fg_rgb  = (ui_tempo_idx == col4_idx) ? 16'hFFE0 : 16'hDF7B;
                            case (txt4_slot)
                                2'd0: req_glyph_id = 7'd88;
                                2'd1: req_glyph_id = 7'd18;
                                2'd2: req_glyph_id = 7'd86;
                                2'd3: req_glyph_id = 7'd74 + {5'd0, col4_idx};
                            endcase
                        end
                    end
                end

                // -------------------------------------------------------------
                // 【切屏 3: 12 音色库与空间效果页】
                //   - Row 0 (Y = 42..85):   [00 三角钢琴] [01 经典电钢] [02 水晶八音] [03 教堂风琴]
                //   - Row 1 (Y = 91..134):  [04 古典吉他] [05 交响弦乐] [06 空灵长笛] [07 木管单簧]
                //   - Row 2 (Y = 140..183): [08 辉煌铜管] [09 木琴马林] [10 重低贝司] [11 合成主音]
                //   - Row 3 (Y = 190..235): [效果搭配切换] [混响开/关]   [合唱开/关]   [延迟开/关]
                // -------------------------------------------------------------
                default: begin
                    if (((scan_y >= 8'd42  && scan_y <= 8'd85)  ||
                         (scan_y >= 8'd91  && scan_y <= 8'd134) ||
                         (scan_y >= 8'd140 && scan_y <= 8'd183)) && in_card_x) begin
                        if (on_card_x || scan_y == 8'd42 || scan_y == 8'd85 ||
                            scan_y == 8'd91 || scan_y == 8'd134 || scan_y == 8'd140 || scan_y == 8'd183)
                            req_bg_rgb = (d_timbre == p3_timbre_id) ? 16'hFFE0 : 16'h39E7;
                        else
                            req_bg_rgb = (d_timbre == p3_timbre_id) ? 16'h039A : 16'h10A5;

                        if (in_txt4_x && (txt4_slot == 2'd1 || txt4_slot == 2'd2) &&
                            ((scan_y >= 8'd46  && scan_y < 8'd62)  ||
                             (scan_y >= 8'd95  && scan_y < 8'd111) ||
                             (scan_y >= 8'd144 && scan_y < 8'd160))) begin
                            req_text_en  = 1'b1;
                            req_char_x   = txt4_cx;
                            req_char_y   = (p3_t_row == 2'd0) ? (scan_y[3:0] - 4'd14) :
                                           (p3_t_row == 2'd1) ? (scan_y[3:0] - 4'd15) : scan_y[3:0];
                            req_fg_rgb   = (d_timbre == p3_timbre_id) ? 16'hFFE0 : 16'h07FF;
                            req_glyph_id = (txt4_slot == 2'd1) ? 7'd1 : p3_t_glyphs[34:28];
                        end else if (in_txt4_x &&
                                     ((scan_y >= 8'd66  && scan_y < 8'd82)  ||
                                      (scan_y >= 8'd115 && scan_y < 8'd131) ||
                                      (scan_y >= 8'd164 && scan_y < 8'd180))) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = (p3_t_row == 2'd0) ? (scan_y[3:0] - 4'd2) :
                                          (p3_t_row == 2'd1) ? (scan_y[3:0] - 4'd3) : (scan_y[3:0] - 4'd4);
                            req_fg_rgb  = (d_timbre == p3_timbre_id) ? 16'hFFFF : 16'hDF7B;
                            case (txt4_slot)
                                2'd0: req_glyph_id = p3_t_glyphs[27:21];
                                2'd1: req_glyph_id = p3_t_glyphs[20:14];
                                2'd2: req_glyph_id = p3_t_glyphs[13:7];
                                2'd3: req_glyph_id = p3_t_glyphs[6:0];
                            endcase
                        end
                    end else if (scan_y >= 8'd190 && scan_y <= 8'd235 && in_card_x) begin
                        if (on_card_x || scan_y == 8'd190 || scan_y == 8'd235)
                            req_bg_rgb = 16'h07FF;
                        else if (col4_idx == 2'd1 && d_fx_sel[2])
                            req_bg_rgb = 16'h03A8;
                        else if (col4_idx == 2'd2 && d_fx_sel[0])
                            req_bg_rgb = 16'h039A;
                        else if (col4_idx == 2'd3 && d_fx_sel[1])
                            req_bg_rgb = 16'h3A08;
                        else
                            req_bg_rgb = 16'h1928;

                        if (in_txt4_x && scan_y >= 8'd204 && scan_y < 8'd220) begin
                            req_text_en = 1'b1;
                            req_char_x  = txt4_cx;
                            req_char_y  = scan_y[3:0] - 4'd12;
                            req_fg_rgb  = 16'hFFE0;
                            case (col4_idx)
                                2'd0: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = cur_preset_g[27:21];
                                        2'd1: req_glyph_id = cur_preset_g[20:14];
                                        2'd2: req_glyph_id = cur_preset_g[13:7];
                                        2'd3: req_glyph_id = cur_preset_g[6:0];
                                    endcase
                                end
                                2'd1: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd5;
                                        2'd1: req_glyph_id = 7'd6;
                                        2'd2: req_glyph_id = d_fx_sel[2] ? 7'd11 : 7'd13;
                                        2'd3: req_glyph_id = d_fx_sel[2] ? 7'd12 : 7'd14;
                                    endcase
                                end
                                2'd2: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd7;
                                        2'd1: req_glyph_id = 7'd8;
                                        2'd2: req_glyph_id = d_fx_sel[0] ? 7'd11 : 7'd13;
                                        2'd3: req_glyph_id = d_fx_sel[0] ? 7'd12 : 7'd14;
                                    endcase
                                end
                                default: begin
                                    case (txt4_slot)
                                        2'd0: req_glyph_id = 7'd9;
                                        2'd1: req_glyph_id = 7'd10;
                                        2'd2: req_glyph_id = d_fx_sel[1] ? 7'd11 : 7'd13;
                                        2'd3: req_glyph_id = d_fx_sel[1] ? 7'd12 : 7'd14;
                                    endcase
                                end
                            endcase
                        end
                    end
                end
            endcase
        end

        // =====================================================================
        // D. 3点触摸校准向导靶心与实时触摸十字准星叠加层
        // =====================================================================
        if (cal_state == 2'd1 && scan_x >= 9'd24 && scan_x <= 9'd48 && scan_y >= 8'd24 && scan_y <= 8'd48) begin
            if (scan_x == 9'd36 || scan_y == 8'd36 || scan_x == 9'd24 || scan_x == 9'd48 || scan_y == 8'd24 || scan_y == 8'd48)
                req_bg_rgb = 16'hF800;
        end else if (cal_state == 2'd2 && scan_x >= 9'd272 && scan_x <= 9'd296 && scan_y >= 8'd24 && scan_y <= 8'd48) begin
            if (scan_x == 9'd284 || scan_y == 8'd36 || scan_x == 9'd272 || scan_x == 9'd296 || scan_y == 8'd24 || scan_y == 8'd48)
                req_bg_rgb = 16'hFFE0;
        end else if (cal_state == 2'd3 && scan_x >= 9'd272 && scan_x <= 9'd296 && scan_y >= 8'd172 && scan_y <= 8'd196) begin
            if (scan_x == 9'd284 || scan_y == 8'd184 || scan_x == 9'd272 || scan_x == 9'd296 || scan_y == 8'd172 || scan_y == 8'd196)
                req_bg_rgb = 16'h07E0;
        end else if (cursor_hold != 26'd0) begin
            if ((scan_x == cursor_x && scan_y + 8'd7 >= cursor_y && scan_y <= cursor_y + 8'd7) ||
                (scan_y == cursor_y && scan_x + 9'd7 >= cursor_x && scan_x <= cursor_x + 9'd7)) begin
                req_bg_rgb  = 16'hF800;
                req_text_en = 1'b0;
            end
        end
    end

    // 同步读取字模 ROM
    reg [7:0]  rom_raw_byte;
    reg [2:0]  dly_char_bit;
    reg        dly_text_en;
    reg [15:0] dly_fg_rgb;
    reg [15:0] dly_bg_rgb;

    always @(posedge clk) begin
        rom_raw_byte <= glyph_rom_fn({req_glyph_id, req_char_y[3], req_char_x});
        dly_char_bit <= req_char_y[2:0];
        dly_text_en  <= req_text_en && (req_glyph_id != 7'd0);
        dly_fg_rgb   <= req_fg_rgb;
        dly_bg_rgb   <= req_bg_rgb;
    end

    wire [15:0] pixel_rgb565 = (dly_text_en && rom_raw_byte[dly_char_bit]) ? dly_fg_rgb : dly_bg_rgb;

    // =========================================================================
    // 7. ILI9341 320x240 横屏初始化序列与 12.5MHz SPI 连续像素流引擎
    // =========================================================================
    function [8:0] ili_init_rom;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  ili_init_rom = {1'b0, 8'h01};
                6'd1:  ili_init_rom = {1'b0, 8'hCF};
                6'd2:  ili_init_rom = {1'b1, 8'h00};
                6'd3:  ili_init_rom = {1'b1, 8'hC1};
                6'd4:  ili_init_rom = {1'b1, 8'h30};
                6'd5:  ili_init_rom = {1'b0, 8'hED};
                6'd6:  ili_init_rom = {1'b1, 8'h64};
                6'd7:  ili_init_rom = {1'b1, 8'h03};
                6'd8:  ili_init_rom = {1'b1, 8'h12};
                6'd9:  ili_init_rom = {1'b1, 8'h81};
                6'd10: ili_init_rom = {1'b0, 8'hE8};
                6'd11: ili_init_rom = {1'b1, 8'h85};
                6'd12: ili_init_rom = {1'b1, 8'h00};
                6'd13: ili_init_rom = {1'b1, 8'h78};
                6'd14: ili_init_rom = {1'b0, 8'hCB};
                6'd15: ili_init_rom = {1'b1, 8'h39};
                6'd16: ili_init_rom = {1'b1, 8'h2C};
                6'd17: ili_init_rom = {1'b1, 8'h00};
                6'd18: ili_init_rom = {1'b1, 8'h34};
                6'd19: ili_init_rom = {1'b1, 8'h02};
                6'd20: ili_init_rom = {1'b0, 8'hF7};
                6'd21: ili_init_rom = {1'b1, 8'h20};
                6'd22: ili_init_rom = {1'b0, 8'hEA};
                6'd23: ili_init_rom = {1'b1, 8'h00};
                6'd24: ili_init_rom = {1'b1, 8'h00};
                6'd25: ili_init_rom = {1'b0, 8'hC0};
                6'd26: ili_init_rom = {1'b1, 8'h23};
                6'd27: ili_init_rom = {1'b0, 8'hC1};
                6'd28: ili_init_rom = {1'b1, 8'h10};
                6'd29: ili_init_rom = {1'b0, 8'hC5};
                6'd30: ili_init_rom = {1'b1, 8'h3E};
                6'd31: ili_init_rom = {1'b1, 8'h28};
                6'd32: ili_init_rom = {1'b0, 8'hC7};
                6'd33: ili_init_rom = {1'b1, 8'h86};
                6'd34: ili_init_rom = {1'b0, 8'h36};
                6'd35: ili_init_rom = {1'b1, 8'hE8};
                6'd36: ili_init_rom = {1'b0, 8'h3A};
                6'd37: ili_init_rom = {1'b1, 8'h55};
                6'd38: ili_init_rom = {1'b0, 8'hB1};
                6'd39: ili_init_rom = {1'b1, 8'h00};
                6'd40: ili_init_rom = {1'b1, 8'h18};
                6'd41: ili_init_rom = {1'b0, 8'hB6};
                6'd42: ili_init_rom = {1'b1, 8'h08};
                6'd43: ili_init_rom = {1'b1, 8'h82};
                6'd44: ili_init_rom = {1'b1, 8'h27};
                6'd45: ili_init_rom = {1'b0, 8'h11};
                default: ili_init_rom = {1'b0, 8'h29};
            endcase
        end
    endfunction

    function [8:0] win_hdr_rom;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  win_hdr_rom = {1'b0, 8'h2A};
                4'd1:  win_hdr_rom = {1'b1, 8'h00};
                4'd2:  win_hdr_rom = {1'b1, 8'h00};
                4'd3:  win_hdr_rom = {1'b1, 8'h01};
                4'd4:  win_hdr_rom = {1'b1, 8'h3F};
                4'd5:  win_hdr_rom = {1'b0, 8'h2B};
                4'd6:  win_hdr_rom = {1'b1, 8'h00};
                4'd7:  win_hdr_rom = {1'b1, 8'h00};
                4'd8:  win_hdr_rom = {1'b1, 8'h00};
                4'd9:  win_hdr_rom = {1'b1, 8'hEF};
                default: win_hdr_rom = {1'b0, 8'h2C};
            endcase
        end
    endfunction

    reg [3:0]  lcd_state;
    reg [22:0] lcd_timer;
    reg [5:0]  init_idx;
    reg [3:0]  win_idx;
    reg [15:0] spi_shift16;
    reg [4:0]  spi_bit_cnt;
    reg [2:0]  spi_clk_div;
    reg [12:0] clr_addr;
    reg [4:0]  calc_rad;
    reg        frame_last_pix;

    wire [8:0] cur_init_word = ili_init_rom(init_idx);
    wire [8:0] cur_win_word  = win_hdr_rom(win_idx);

    always @(posedge clk) begin
        if (!rst_n) begin
            lcd_state      <= 4'd0;
            lcd_timer      <= 23'd0;
            init_idx       <= 6'd0;
            win_idx        <= 4'd0;
            spi_shift16    <= 16'd0;
            spi_bit_cnt    <= 5'd0;
            spi_clk_div    <= 3'd0;
            clr_addr       <= 13'd0;
            frame_last_pix <= 1'b0;
            liss_step      <= 9'd0;
            scope_wr_addr  <= 13'd0;
            scope_wr_en    <= 1'b0;
            scope_wr_data  <= 1'b0;
            scan_x         <= 9'd0;
            scan_y         <= 8'd0;
            lcd_reset      <= 1'b0;
            lcd_cs         <= 1'b1;
            lcd_dc         <= 1'b0;
            lcd_sck        <= 1'b0;
            lcd_sdi        <= 1'b0;
            blink_cnt      <= 6'd0;
            d_keys         <= 18'd0;
            d_acc_keys     <= 18'd0;
            d_beat         <= 1'b0;
            d_vol          <= 4'd8;
            d_timbre       <= 4'd0;
            d_disp_mode    <= 2'd0;
            d_b0 <= 5'd0; d_b1 <= 5'd0; d_b2 <= 5'd0; d_b3 <= 5'd0;
            d_b4 <= 5'd0; d_b5 <= 5'd0; d_b6 <= 5'd0; d_b7 <= 5'd0;
            d_fx_freq      <= 3'd1;
            d_fy_freq      <= 3'd2;
            d_liss_phase   <= 8'd0;
            d_rad_x        <= 5'd16;
            d_rad_y        <= 5'd16;
            d_sys_mode     <= 2'd0;
            d_preset_idx   <= 2'd0;
            d_preset_code  <= 4'd1;
            d_fx_allow     <= 3'b100;
            d_auto         <= 1'b0;
            d_song         <= 3'd0;
            d_rec          <= 1'b0;
            d_fx_sel       <= 3'b100;
            d_acc_mode     <= 3'd0;
            d_acc_act      <= 1'b0;
            d_root         <= 4'd0;
            d_ctype        <= 3'd0;
            d_rstep        <= 3'd0;
            d_page         <= 2'd0;
            d_vel          <= 7'd100;
            d_transpose    <= 6'sd0;
            d_tr_abs_r     <= 6'd0;
            d_tr_rem_r     <= 4'd0;
            d_tr_pc_r      <= 4'd0;
        end else begin
            scope_wr_en <= 1'b0;

            case (lcd_state)
                4'd0: begin
                    lcd_cs  <= 1'b1;
                    lcd_sck <= 1'b0;
                    if (lcd_timer < {2'b00, HW_RST_LOW_TICKS}) begin
                        lcd_reset <= 1'b0;
                        lcd_timer <= lcd_timer + 23'd1;
                    end else if (lcd_timer < HW_RST_WAIT_TICKS) begin
                        lcd_reset <= 1'b1;
                        lcd_timer <= lcd_timer + 23'd1;
                    end else begin
                        lcd_reset <= 1'b1;
                        lcd_timer <= 23'd0;
                        init_idx  <= 6'd0;
                        lcd_state <= 4'd1;
                    end
                end

                4'd1: begin
                    lcd_cs      <= 1'b0;
                    lcd_dc      <= cur_init_word[8];
                    lcd_sck     <= 1'b0;
                    lcd_sdi     <= cur_init_word[7];
                    spi_shift16 <= {cur_init_word[6:0], 9'd0};
                    spi_bit_cnt <= 5'd0;
                    spi_clk_div <= 3'd0;
                    lcd_state   <= 4'd2;
                end

                4'd2: begin
                    spi_clk_div <= spi_clk_div + 3'd1;
                    if (spi_clk_div == 3'd3) begin
                        lcd_sck <= 1'b1;
                    end else if (spi_clk_div == 3'd7) begin
                        lcd_sck <= 1'b0;
                        if (spi_bit_cnt == 5'd7) begin
                            lcd_cs <= 1'b1;
                            if (init_idx == 6'd0 || init_idx == 6'd45 || init_idx == 6'd46) begin
                                lcd_timer <= 23'd0;
                                lcd_state <= 4'd3;
                            end else begin
                                init_idx  <= init_idx + 6'd1;
                                lcd_state <= 4'd1;
                            end
                        end else begin
                            lcd_sdi     <= spi_shift16[15];
                            spi_shift16 <= {spi_shift16[14:0], 1'b0};
                            spi_bit_cnt <= spi_bit_cnt + 5'd1;
                        end
                    end
                end

                4'd3: begin
                    if (lcd_timer < HW_RST_WAIT_TICKS) begin
                        lcd_timer <= lcd_timer + 23'd1;
                    end else begin
                        lcd_timer <= 23'd0;
                        if (init_idx == 6'd46) begin
                            lcd_state <= 4'd4;
                        end else begin
                            init_idx  <= init_idx + 6'd1;
                            lcd_state <= 4'd1;
                        end
                    end
                end

                4'd4: begin
                    blink_cnt     <= blink_cnt + 6'd1;
                    d_keys        <= key_state;
                    d_acc_keys    <= acc_vis_keys;
                    d_beat        <= acc_beat_pulse;
                    d_vol         <= volume;
                    d_timbre      <= (timbre_idx > 4'd11) ? 4'd0 : timbre_idx;
                    d_disp_mode   <= (disp_mode > 2'd2)   ? 2'd0 : disp_mode;
                    d_b0 <= band0; d_b1 <= band1; d_b2 <= band2; d_b3 <= band3;
                    d_b4 <= band4; d_b5 <= band5; d_b6 <= band6; d_b7 <= band7;
                    d_fx_freq     <= target_fx;
                    d_fy_freq     <= target_fy;
                    d_sys_mode    <= sys_mode;
                    d_preset_idx  <= preset_idx;
                    d_preset_code <= preset_code;
                    d_fx_allow    <= fx_allow_mask;
                    d_auto        <= auto_play_en;
                    d_song        <= song_idx;
                    d_rec         <= rec_active;
                    d_fx_sel      <= fx_sel;
                    d_acc_mode    <= (acc_mode > 3'd4) ? 3'd0 : acc_mode;
                    d_acc_act     <= acc_active;
                    d_root        <= det_root;
                    d_ctype       <= det_chord_type;
                    d_rstep       <= rhythm_step;
                    d_page        <= ui_page;
                    d_vel         <= last_vel;
                    d_transpose   <= transpose_semi;
                    d_tr_abs_r    <= w_tr_abs;
                    d_tr_rem_r    <= w_tr_rem[3:0];
                    d_tr_pc_r     <= w_tr_pc;

                    if (|key_state || peak_energy > 5'd2) begin
                        calc_rad = 5'd16 + {1'b0, peak_energy[4:1]};
                        if (calc_rad > 5'd26) calc_rad = 5'd26;
                    end else begin
                        calc_rad = 5'd10 + {4'd0, blink_cnt[4]};
                    end
                    d_rad_y <= calc_rad;
                    d_rad_x <= calc_rad + (calc_rad >> 1);

                    if (|key_state || peak_energy > 5'd1) begin
                        if (vibrato_en)
                            d_liss_phase <= d_liss_phase + (blink_cnt[3] ? 8'd6 : 8'd252);
                        else if (portamento_en)
                            d_liss_phase <= d_liss_phase + 8'd7 + {3'd0, low_note};
                        else
                            d_liss_phase <= d_liss_phase + 8'd3 + {4'd0, low_note[4:1]};
                    end else begin
                        d_liss_phase <= d_liss_phase + 8'd1;
                    end

                    clr_addr  <= 13'd0;
                    lcd_state <= 4'd5;
                end

                4'd5: begin
                    scope_wr_en   <= 1'b1;
                    scope_wr_addr <= clr_addr;
                    scope_wr_data <= 1'b0;
                    if (clr_addr == 13'd8191) begin
                        liss_step <= 9'd0;
                        lcd_state <= 4'd6;
                    end else begin
                        clr_addr <= clr_addr + 13'd1;
                    end
                end

                4'd6: begin
                    scope_wr_en   <= 1'b1;
                    scope_wr_data <= 1'b1;
                    if (!liss_step[0])
                        scope_wr_addr <= {pt_y, pt_x};
                    else
                        scope_wr_addr <= {(pt_y < 6'd59) ? (pt_y + 6'd1) : pt_y, pt_x};

                    if (liss_step == 9'd511) begin
                        win_idx   <= 4'd0;
                        lcd_state <= 4'd7;
                    end else begin
                        liss_step <= liss_step + 9'd1;
                    end
                end

                4'd7: begin
                    lcd_cs      <= 1'b0;
                    lcd_dc      <= cur_win_word[8];
                    lcd_sck     <= 1'b0;
                    lcd_sdi     <= cur_win_word[7];
                    spi_shift16 <= {cur_win_word[6:0], 9'd0};
                    spi_bit_cnt <= 5'd0;
                    spi_clk_div <= 3'd0;
                    lcd_state   <= 4'd8;
                end

                4'd8: begin
                    spi_clk_div <= spi_clk_div + 3'd1;
                    if (spi_clk_div[1:0] == 2'd1) begin
                        lcd_sck <= 1'b1;
                    end else if (spi_clk_div[1:0] == 2'd3) begin
                        lcd_sck <= 1'b0;
                        if (spi_bit_cnt == 5'd7) begin
                            if (win_idx == 4'd10) begin
                                scan_x      <= 9'd0;
                                scan_y      <= 8'd0;
                                spi_clk_div <= 3'd0;
                                lcd_state   <= 4'd9;
                            end else begin
                                lcd_cs    <= 1'b1;
                                win_idx   <= win_idx + 4'd1;
                                lcd_state <= 4'd7;
                            end
                        end else begin
                            lcd_sdi     <= spi_shift16[15];
                            spi_shift16 <= {spi_shift16[14:0], 1'b0};
                            spi_bit_cnt <= spi_bit_cnt + 5'd1;
                        end
                    end
                end

                4'd9: begin
                    spi_clk_div    <= spi_clk_div + 3'd1;
                    frame_last_pix <= 1'b0;
                    if (spi_clk_div == 3'd2) begin
                        lcd_cs      <= 1'b0;
                        lcd_dc      <= 1'b1;
                        lcd_sck     <= 1'b0;
                        lcd_sdi     <= pixel_rgb565[15];
                        spi_shift16 <= {pixel_rgb565[14:0], 1'b0};
                        spi_bit_cnt <= 5'd0;
                        spi_clk_div <= 3'd0;
                        lcd_state   <= 4'd10;
                    end
                end

                4'd10: begin
                    spi_clk_div <= spi_clk_div + 3'd1;
                    if (spi_clk_div[1:0] == 2'd1) begin
                        lcd_sck <= 1'b1;
                        if (spi_bit_cnt == 5'd14) begin
                            if (scan_x == 9'd319 && scan_y == 8'd239) begin
                                frame_last_pix <= 1'b1;
                            end else if (scan_x == 9'd319) begin
                                scan_x <= 9'd0;
                                scan_y <= scan_y + 8'd1;
                            end else begin
                                scan_x <= scan_x + 9'd1;
                            end
                        end
                    end else if (spi_clk_div[1:0] == 2'd3) begin
                        lcd_sck <= 1'b0;
                        if (spi_bit_cnt == 5'd15) begin
                            if (frame_last_pix) begin
                                frame_last_pix <= 1'b0;
                                lcd_cs         <= 1'b1;
                                lcd_state      <= 4'd4;
                            end else begin
                                lcd_sdi     <= pixel_rgb565[15];
                                spi_shift16 <= {pixel_rgb565[14:0], 1'b0};
                                spi_bit_cnt <= 5'd0;
                            end
                        end else begin
                            lcd_sdi     <= spi_shift16[15];
                            spi_shift16 <= {spi_shift16[14:0], 1'b0};
                            spi_bit_cnt <= spi_bit_cnt + 5'd1;
                        end
                    end
                end

                default: lcd_state <= 4'd0;
            endcase
        end
    end

endmodule
