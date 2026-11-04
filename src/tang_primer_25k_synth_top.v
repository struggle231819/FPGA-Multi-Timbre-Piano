// =============================================================================
// 文件名: tang_primer_25k_synth_top.v
// 适用平台: Sipeed Tang Primer 25K (GW5A-LV25MG121NC1/I0) + 25K Dock 底板
// 模块功能: 全功能 64 复音 (64-Voice Polyphony) 12 商业级音色智能电子琴顶层模块 
// =============================================================================

module tang_primer_25k_synth_top #(
    parameter [23:0] REC_BEAT_P     = 24'd3_999_999,   // 80ms 高精度实弹录音网格 (12.5Hz)
    parameter [13:0] DLY_DEPTH_P    = 14'd8192,        // 延迟线深度 8192 (仿真可改小)
    parameter [24:0] ACC_STEP_DEF_P = 25'd12_499_999,  // 智能伴奏默认八分音符步长 (250ms = 120BPM)
    parameter [24:0] ACC_STEP_MIN_P = 25'd7_499_999,   // 智能伴奏最快步长 (150ms = 200BPM)
    parameter [24:0] ACC_STEP_MAX_P = 25'd22_499_999   // 智能伴奏最慢步长 (450ms = 66BPM)
) (
    input  wire        clk,        // 板载 50MHz 晶振 (Pin E2)
    input  wire        s1_key,     // Dock 板载按键 S1 (Pin H11, 单击开启/停止脱机自动演奏)
    input  wire        s2_key,     // Dock 板载按键 S2 (Pin H10, 演奏时切歌 0~4 / 手动短按切音色 / 长按切伴奏节奏型)
    input  wire [17:0] keys_raw_n, // 18 个独立轻触琴键 C4~F5 (按下接地=0, 内部上拉)
    input  wire        enc1_a,     // 旋转编码器 1 A 相 (Pin F5, 旋转调节音量)
    input  wire        enc1_b,     // 旋转编码器 1 B 相 (Pin G7)
    input  wire        enc1_sw_n,  // 旋转编码器 1 SW 脚 (Pin H8, 替换为 S1 功能: 循环切屏/切换四大模式)
    input  wire        enc2_a,     // 旋转编码器 2 A 相 (Pin G5, 旋转切换 12 种精选音色)
    input  wire        enc2_b,     // 旋转编码器 2 B 相 (Pin G8)
    input  wire        enc2_sw_n,  // 旋转编码器 2 SW 脚 (Pin H7, 替换为 S2 功能: 切换当前切屏子项)
    inout  wire        bt_rx,      // 蓝牙 JDY-23 TXD (Pin H5, 双向自适应容错收发)
    inout  wire        bt_tx,      // 蓝牙 JDY-23 RXD (Pin J5)
    output wire        pcm_bck,    // PCM5102A BCK  (Pin L5,  3.125MHz I2S 位时钟)
    output wire        pcm_lck,    // PCM5102A LCK  (Pin E10, 48.828kHz 左右声道时钟)
    output wire        pcm_din,    // PCM5102A DIN  (Pin A10, 24-bit 真立体声 Hi-Fi I2S)
    output wire        pcm_flt,    // PCM5102A FLT  (Pin A11, 固定低=FIR 正常延迟滤波)
    output wire        pcm_dmp,    // PCM5102A DMP  (Pin E11, 固定低=无去加重)
    output wire        pcm_scl,    // PCM5102A SCL  (Pin K11, 固定低=启用内部锁相环振荡器)
    output wire        pcm_fmt,    // PCM5102A FMT  (Pin L11, 固定低=标准 I2S 格式)
    output wire        pcm_xmt,    // PCM5102A XMT  (Pin K5,  高电平=解除静音正常播放)
    output wire        lcd_sck,    // ILI9341 SCK   (Pin L8,  LCD SPI 时钟)
    output wire        lcd_sdi,    // ILI9341 MOSI  (Pin J7,  LCD SPI MOSI)
    output wire        lcd_dc,     // ILI9341 DC    (Pin H2,  LCD 数据/命令)
    output wire        lcd_reset,  // ILI9341 RESET (Pin G10, LCD 复位)
    output wire        lcd_cs,     // ILI9341 CS    (Pin G11, LCD 片选)
    output wire        tp_clk,     // XPT2046 T_CLK (Pin K10, 触摸时钟)
    output wire        tp_cs,      // XPT2046 T_CS  (Pin K9,  触摸片选)
    output wire        tp_din,     // XPT2046 T_DIN (Pin K8,  触摸 MOSI)
    input  wire        tp_do,      // XPT2046 T_DO  (Pin F6,  触摸 MISO, 内部上拉)
    input  wire        tp_irq,     // XPT2046 T_IRQ (Pin J10, 触摸中断, 内部上拉)
    inout  wire [10:0] vel_io,     // 11 个白键铜箔电容测速引脚 (H4,J2,D1,A1,F1,C2,L3,G1,K4,L1,K2)
    output wire        led         // 核心板状态指示灯 (Pin E8)
);

    reg [10:0] por_cnt = 11'd0;
    wire       rst_n   = por_cnt[10];
    always @(posedge clk) begin
        if (!por_cnt[10])
            por_cnt <= por_cnt + 11'd1;
    end

    reg [9:0] clk_div;
    always @(posedge clk) begin
        if (!rst_n)
            clk_div <= 10'd0;
        else
            clk_div <= clk_div + 10'd1;
    end

    wire sample_tick    = (clk_div == 10'd0);
    wire bck_falling_en = (clk_div[3:0] == 4'b1111);
    wire [5:0] bit_idx  = clk_div[9:4];

    // =========================================================================
    // 1. 内置 4 首经典名曲 ROM (64 步/首) + 第 5 首用户 RAM (256 步, 下载/录音共用)
    // =========================================================================
    function [18:0] song_rom;
        input [7:0] addr;
        begin
            case (addr)
                8'd  0: song_rom = 19'h40020;
                8'd  1: song_rom = 19'h40080;
                8'd  2: song_rom = 19'h40121;
                8'd  3: song_rom = 19'h00121;
                8'd  4: song_rom = 19'h00121;
                8'd  5: song_rom = 19'h40081;
                8'd  6: song_rom = 19'h40120;
                8'd  7: song_rom = 19'h00120;
                8'd  8: song_rom = 19'h41020;
                8'd  9: song_rom = 19'h01020;
                8'd 10: song_rom = 19'h40088;
                8'd 11: song_rom = 19'h00088;
                8'd 12: song_rom = 19'h40488;
                8'd 13: song_rom = 19'h00488;
                8'd 14: song_rom = 19'h40001;
                8'd 15: song_rom = 19'h00001;
                8'd 16: song_rom = 19'h40022;
                8'd 17: song_rom = 19'h00022;
                8'd 18: song_rom = 19'h00022;
                8'd 19: song_rom = 19'h40008;
                8'd 20: song_rom = 19'h40022;
                8'd 21: song_rom = 19'h00022;
                8'd 22: song_rom = 19'h40120;
                8'd 23: song_rom = 19'h00120;
                8'd 24: song_rom = 19'h40009;
                8'd 25: song_rom = 19'h00009;
                8'd 26: song_rom = 19'h40089;
                8'd 27: song_rom = 19'h00089;
                8'd 28: song_rom = 19'h40001;
                8'd 29: song_rom = 19'h00001;
                8'd 30: song_rom = 19'h40002;
                8'd 31: song_rom = 19'h00002;
                8'd 32: song_rom = 19'h40001;
                8'd 33: song_rom = 19'h40022;
                8'd 34: song_rom = 19'h00022;
                8'd 35: song_rom = 19'h40120;
                8'd 36: song_rom = 19'h00120;
                8'd 37: song_rom = 19'h40009;
                8'd 38: song_rom = 19'h00009;
                8'd 39: song_rom = 19'h40100;
                8'd 40: song_rom = 19'h40084;
                8'd 41: song_rom = 19'h00084;
                8'd 42: song_rom = 19'h40004;
                8'd 43: song_rom = 19'h40084;
                8'd 44: song_rom = 19'h00084;
                8'd 45: song_rom = 19'h40090;
                8'd 46: song_rom = 19'h40100;
                8'd 47: song_rom = 19'h40400;
                8'd 48: song_rom = 19'h41108;
                8'd 49: song_rom = 19'h01108;
                8'd 50: song_rom = 19'h40408;
                8'd 51: song_rom = 19'h41100;
                8'd 52: song_rom = 19'h48088;
                8'd 53: song_rom = 19'h08088;
                8'd 54: song_rom = 19'h40488;
                8'd 55: song_rom = 19'h00488;
                8'd 56: song_rom = 19'h41120;
                8'd 57: song_rom = 19'h42020;
                8'd 58: song_rom = 19'h60120;
                8'd 59: song_rom = 19'h48088;
                8'd 60: song_rom = 19'h08088;
                8'd 61: song_rom = 19'h41100;
                8'd 62: song_rom = 19'h40490;
                8'd 63: song_rom = 19'h40121;
                8'd 64: song_rom = 19'h50081;
                8'd 65: song_rom = 19'h41010;
                8'd 66: song_rom = 19'h44084;
                8'd 67: song_rom = 19'h40880;
                8'd 68: song_rom = 19'h41011;
                8'd 69: song_rom = 19'h40210;
                8'd 70: song_rom = 19'h40890;
                8'd 71: song_rom = 19'h40090;
                8'd 72: song_rom = 19'h40221;
                8'd 73: song_rom = 19'h41020;
                8'd 74: song_rom = 19'h40091;
                8'd 75: song_rom = 19'h41010;
                8'd 76: song_rom = 19'h40221;
                8'd 77: song_rom = 19'h44020;
                8'd 78: song_rom = 19'h40884;
                8'd 79: song_rom = 19'h44080;
                8'd 80: song_rom = 19'h50081;
                8'd 81: song_rom = 19'h41010;
                8'd 82: song_rom = 19'h44080;
                8'd 83: song_rom = 19'h50001;
                8'd 84: song_rom = 19'h44084;
                8'd 85: song_rom = 19'h40880;
                8'd 86: song_rom = 19'h41004;
                8'd 87: song_rom = 19'h44080;
                8'd 88: song_rom = 19'h41011;
                8'd 89: song_rom = 19'h40210;
                8'd 90: song_rom = 19'h40A00;
                8'd 91: song_rom = 19'h41010;
                8'd 92: song_rom = 19'h40890;
                8'd 93: song_rom = 19'h40090;
                8'd 94: song_rom = 19'h40280;
                8'd 95: song_rom = 19'h40810;
                8'd 96: song_rom = 19'h40221;
                8'd 97: song_rom = 19'h40021;
                8'd 98: song_rom = 19'h400A0;
                8'd 99: song_rom = 19'h40201;
                8'd100: song_rom = 19'h40091;
                8'd101: song_rom = 19'h40011;
                8'd102: song_rom = 19'h40030;
                8'd103: song_rom = 19'h40081;
                8'd104: song_rom = 19'h40221;
                8'd105: song_rom = 19'h40220;
                8'd106: song_rom = 19'h40081;
                8'd107: song_rom = 19'h40021;
                8'd108: song_rom = 19'h40884;
                8'd109: song_rom = 19'h40880;
                8'd110: song_rom = 19'h40204;
                8'd111: song_rom = 19'h40880;
                8'd112: song_rom = 19'h41011;
                8'd113: song_rom = 19'h40880;
                8'd114: song_rom = 19'h41010;
                8'd115: song_rom = 19'h40011;
                8'd116: song_rom = 19'h40084;
                8'd117: song_rom = 19'h40880;
                8'd118: song_rom = 19'h40204;
                8'd119: song_rom = 19'h40080;
                8'd120: song_rom = 19'h40221;
                8'd121: song_rom = 19'h41020;
                8'd122: song_rom = 19'h60200;
                8'd123: song_rom = 19'h50011;
                8'd124: song_rom = 19'h44084;
                8'd125: song_rom = 19'h40880;
                8'd126: song_rom = 19'h41091;
                8'd127: song_rom = 19'h01091;
                8'd128: song_rom = 19'h50000;
                8'd129: song_rom = 19'h48000;
                8'd130: song_rom = 19'h50000;
                8'd131: song_rom = 19'h48000;
                8'd132: song_rom = 19'h50000;
                8'd133: song_rom = 19'h40800;
                8'd134: song_rom = 19'h44000;
                8'd135: song_rom = 19'h41000;
                8'd136: song_rom = 19'h40211;
                8'd137: song_rom = 19'h00211;
                8'd138: song_rom = 19'h40001;
                8'd139: song_rom = 19'h40010;
                8'd140: song_rom = 19'h40200;
                8'd141: song_rom = 19'h40910;
                8'd142: song_rom = 19'h00910;
                8'd143: song_rom = 19'h40010;
                8'd144: song_rom = 19'h40100;
                8'd145: song_rom = 19'h40800;
                8'd146: song_rom = 19'h41211;
                8'd147: song_rom = 19'h01211;
                8'd148: song_rom = 19'h40010;
                8'd149: song_rom = 19'h50000;
                8'd150: song_rom = 19'h48000;
                8'd151: song_rom = 19'h50000;
                8'd152: song_rom = 19'h48000;
                8'd153: song_rom = 19'h50000;
                8'd154: song_rom = 19'h40800;
                8'd155: song_rom = 19'h44000;
                8'd156: song_rom = 19'h41000;
                8'd157: song_rom = 19'h40211;
                8'd158: song_rom = 19'h00211;
                8'd159: song_rom = 19'h40001;
                8'd160: song_rom = 19'h40010;
                8'd161: song_rom = 19'h40200;
                8'd162: song_rom = 19'h40910;
                8'd163: song_rom = 19'h40010;
                8'd164: song_rom = 19'h41000;
                8'd165: song_rom = 19'h40800;
                8'd166: song_rom = 19'h40211;
                8'd167: song_rom = 19'h00211;
                8'd168: song_rom = 19'h40800;
                8'd169: song_rom = 19'h41000;
                8'd170: song_rom = 19'h44000;
                8'd171: song_rom = 19'h50081;
                8'd172: song_rom = 19'h10081;
                8'd173: song_rom = 19'h40080;
                8'd174: song_rom = 19'h60000;
                8'd175: song_rom = 19'h50000;
                8'd176: song_rom = 19'h44884;
                8'd177: song_rom = 19'h04884;
                8'd178: song_rom = 19'h40020;
                8'd179: song_rom = 19'h50000;
                8'd180: song_rom = 19'h44000;
                8'd181: song_rom = 19'h41211;
                8'd182: song_rom = 19'h01211;
                8'd183: song_rom = 19'h40010;
                8'd184: song_rom = 19'h44000;
                8'd185: song_rom = 19'h41000;
                8'd186: song_rom = 19'h40910;
                8'd187: song_rom = 19'h00910;
                8'd188: song_rom = 19'h40010;
                8'd189: song_rom = 19'h50000;
                8'd190: song_rom = 19'h48000;
                8'd191: song_rom = 19'h40810;
                8'd192: song_rom = 19'h40221;
                8'd193: song_rom = 19'h40220;
                8'd194: song_rom = 19'h40420;
                8'd195: song_rom = 19'h41220;
                8'd196: song_rom = 19'h41081;
                8'd197: song_rom = 19'h40480;
                8'd198: song_rom = 19'h40220;
                8'd199: song_rom = 19'h40091;
                8'd200: song_rom = 19'h40021;
                8'd201: song_rom = 19'h40021;
                8'd202: song_rom = 19'h40081;
                8'd203: song_rom = 19'h40221;
                8'd204: song_rom = 19'h40221;
                8'd205: song_rom = 19'h40091;
                8'd206: song_rom = 19'h40091;
                8'd207: song_rom = 19'h00091;
                8'd208: song_rom = 19'h40221;
                8'd209: song_rom = 19'h40220;
                8'd210: song_rom = 19'h40420;
                8'd211: song_rom = 19'h41220;
                8'd212: song_rom = 19'h41081;
                8'd213: song_rom = 19'h40480;
                8'd214: song_rom = 19'h40220;
                8'd215: song_rom = 19'h40091;
                8'd216: song_rom = 19'h40021;
                8'd217: song_rom = 19'h40021;
                8'd218: song_rom = 19'h40091;
                8'd219: song_rom = 19'h40221;
                8'd220: song_rom = 19'h40091;
                8'd221: song_rom = 19'h40021;
                8'd222: song_rom = 19'h40221;
                8'd223: song_rom = 19'h00221;
                8'd224: song_rom = 19'h40091;
                8'd225: song_rom = 19'h40091;
                8'd226: song_rom = 19'h40221;
                8'd227: song_rom = 19'h40021;
                8'd228: song_rom = 19'h40091;
                8'd229: song_rom = 19'h40424;
                8'd230: song_rom = 19'h40221;
                8'd231: song_rom = 19'h40021;
                8'd232: song_rom = 19'h40084;
                8'd233: song_rom = 19'h40424;
                8'd234: song_rom = 19'h40224;
                8'd235: song_rom = 19'h40084;
                8'd236: song_rom = 19'h40021;
                8'd237: song_rom = 19'h40090;
                8'd238: song_rom = 19'h40091;
                8'd239: song_rom = 19'h00091;
                8'd240: song_rom = 19'h40221;
                8'd241: song_rom = 19'h40221;
                8'd242: song_rom = 19'h40424;
                8'd243: song_rom = 19'h41220;
                8'd244: song_rom = 19'h41090;
                8'd245: song_rom = 19'h40420;
                8'd246: song_rom = 19'h40221;
                8'd247: song_rom = 19'h40091;
                8'd248: song_rom = 19'h40024;
                8'd249: song_rom = 19'h40021;
                8'd250: song_rom = 19'h40091;
                8'd251: song_rom = 19'h40221;
                8'd252: song_rom = 19'h40091;
                8'd253: song_rom = 19'h40021;
                8'd254: song_rom = 19'h41221;
                8'd255: song_rom = 19'h01221;
                default: song_rom = 19'h00000;
            endcase
        end
    endfunction

    wire        auto_play_en;
    wire [2:0]  song_idx;
    wire        song_restart_stb;
    wire [7:0]  user_last_step;
    wire        user_is_highres;

    reg  [7:0]  step_idx;
    reg  [23:0] beat_cnt;
    reg  [26:0] loop_gap_cnt;

    wire [7:0]  max_step = (song_idx == 3'd4) ? user_last_step : 8'd63;

    reg  [23:0] beat_limit;
    always @(*) begin
        case (song_idx)
            3'd0: beat_limit = 24'd11_999_999; // 《天空之城》 240ms
            3'd1: beat_limit = 24'd12_999_999; // 《卡农》     260ms
            3'd2: beat_limit = 24'd9_499_999;  // 《致爱丽丝》 190ms
            3'd3: beat_limit = 24'd13_499_999; // 《欢乐颂》   270ms
            default: beat_limit = user_is_highres ? REC_BEAT_P : 24'd11_999_999;
        endcase
    end

    wire song_auto_next = auto_play_en && !song_restart_stb &&
                          (beat_cnt >= beat_limit) && (step_idx >= max_step) && (song_idx != 3'd4);

    always @(posedge clk) begin
        if (!rst_n) begin
            step_idx     <= 8'd0;
            beat_cnt     <= 24'd0;
            loop_gap_cnt <= 27'd0;
        end else if (!auto_play_en || song_restart_stb) begin
            step_idx     <= 8'd0;
            beat_cnt     <= 24'd0;
            loop_gap_cnt <= 27'd0;
        end else if (loop_gap_cnt != 27'd0) begin
            loop_gap_cnt <= loop_gap_cnt - 27'd1;
        end else begin
            if (beat_cnt >= beat_limit) begin
                beat_cnt <= 24'd0;
                if (step_idx >= max_step) begin
                    step_idx <= 8'd0;
                    if (song_idx == 3'd4)
                        loop_gap_cnt <= 27'd99_999_999; // 50MHz * 2.0s = 2秒静音间隔
                end else begin
                    step_idx <= step_idx + 8'd1;
                end
            end else begin
                beat_cnt <= beat_cnt + 24'd1;
            end
        end
    end

    wire [7:0]  next_step_idx = (step_idx >= max_step) ? 8'd0 : (step_idx + 8'd1);
    wire [18:0] user_rd_word;
    wire [18:0] user_next_word;
    wire [18:0] curr_rom_word = (song_idx == 3'd4) ? user_rd_word   : song_rom({song_idx[1:0], step_idx[5:0]});
    wire [18:0] next_rom_word = (song_idx == 3'd4) ? user_next_word : song_rom({song_idx[1:0], next_step_idx[5:0]});

    wire [17:0] curr_keys   = curr_rom_word[17:0];
    wire        next_retrig = next_rom_word[18];
    wire [17:0] next_keys   = next_rom_word[17:0];

    wire [23:0] gate_gap_len    = (song_idx == 3'd4 && user_is_highres) ? 24'd250_000 : 24'd320_000;
    wire        in_gate_gap     = (beat_cnt >= (beat_limit - gate_gap_len));
    wire [17:0] retrig_cut_mask = (in_gate_gap && next_retrig) ? (curr_keys & next_keys) : 18'd0;
    wire [17:0] auto_keys       = (!auto_play_en || (loop_gap_cnt != 27'd0)) ? 18'd0 :
                                  (curr_keys & ~retrig_cut_mask);

    wire beat_cue  = (beat_cnt >= (beat_limit >> 1));
    wire guide_cue = auto_play_en && beat_cue && (|next_keys);

    // =========================================================================
    // 2. 蓝牙双脚容错接收 + 全双工发送 + 录音回传 + 在线歌曲下载 + 智能伴奏指令
    // =========================================================================
    wire [17:0] key_state;
    wire [17:0] key_press_evt;
    wire [17:0] key_rel_evt;
    wire [3:0]  volume;
    wire [3:0]  timbre_idx;
    wire        vibrato_en;
    wire        portamento_en;
    wire [2:0]  acc_mode;

    wire        cmd_play_user;
    wire        cmd_stop;
    wire        cmd_song_vld;
    wire [2:0]  cmd_song_idx;
    wire        cmd_timbre_vld;
    wire [3:0]  cmd_timbre;
    wire        cmd_vol_vld;
    wire [3:0]  cmd_vol;
    wire        cmd_vol_step_vld;
    wire        cmd_vol_up;
    wire [17:0] bt_live_keys;
    wire        cmd_fx_vld;
    wire [3:0]  cmd_fx_sel;
    wire        cmd_test_vld;
    wire        cmd_test_on;
    wire        cmd_vib_vld;
    wire [3:0]  cmd_vib_depth;
    wire        cmd_glide_vld;
    wire [3:0]  cmd_glide_lvl;
    wire        cmd_fxlv_vld;
    wire [3:0]  cmd_fx_level;
    wire        cmd_scene_vld;
    wire [2:0]  cmd_scene;
    wire        cmd_disp_vld;
    wire [1:0]  cmd_disp_mode;
    wire        cmd_acc_vld;
    wire [2:0]  cmd_acc_mode;
    wire        cmd_tempo_vld;
    wire [1:0]  cmd_tempo_idx;
    wire signed [5:0] transpose_semi;
    wire        rec_active;
    wire        bt_tx_bit;
    wire        bt_tx_en_h5;
    wire        bt_tx_en_j5;

    // 智能伴奏输出信号
    wire        acc_active;
    wire [3:0]  det_root;
    wire [2:0]  det_chord_type;
    wire [2:0]  rhythm_step;
    wire        acc_beat_pulse;
    wire        acc_bass_stb;
    wire [4:0]  acc_bass_note;
    wire        acc_bass_gate;
    wire        acc_arp_stb;
    wire [4:0]  acc_arp_note;
    wire        acc_arp2_stb;
    wire [4:0]  acc_arp2_note;
    wire        acc_arp_gate;
    wire [17:0] acc_vis_keys;
    wire [17:0] acc_rec_keys;

    assign bt_rx = bt_tx_en_h5 ? bt_tx_bit : 1'bz;
    assign bt_tx = bt_tx_en_j5 ? bt_tx_bit : 1'bz;
    wire bt_rx_pin = bt_rx;
    wire bt_tx_pin = bt_tx;

    // 触摸屏 UI 输出控制脉冲与虚拟键盘信号
    wire        tp_timbre_vld;
    wire [3:0]  tp_timbre;
    wire        tp_vol_step_vld;
    wire        tp_vol_up;
    wire        tp_acc_vld;
    wire [2:0]  tp_acc_mode;
    wire        tp_tempo_vld;
    wire [1:0]  tp_tempo_idx;
    wire        tp_song_vld;
    wire [2:0]  tp_song_idx;
    wire        tp_stop;
    wire        tp_scene_vld;
    wire [2:0]  tp_scene;
    wire        tp_fx_step_stb;
    wire        tp_fx_vld;
    wire [3:0]  tp_fx_sel;
    wire        tp_disp_step_stb;
    wire [17:0] tp_live_keys;

    wire [17:0] player_keys = (~keys_raw_n) | bt_live_keys | tp_live_keys;

    bt_uart_bridge #(
        .REC_BEAT (REC_BEAT_P)
    ) u_bt (
        .clk               (clk),
        .rst_n             (rst_n),
        .bt_rx_h5          (bt_rx_pin),
        .bt_rx_j5          (bt_tx_pin),
        .bt_tx_bit         (bt_tx_bit),
        .bt_tx_en_h5       (bt_tx_en_h5),
        .bt_tx_en_j5       (bt_tx_en_j5),
        .cmd_play_user     (cmd_play_user),
        .cmd_stop          (cmd_stop),
        .cmd_song_vld      (cmd_song_vld),
        .cmd_song_idx      (cmd_song_idx),
        .cmd_timbre_vld    (cmd_timbre_vld),
        .cmd_timbre        (cmd_timbre),
        .cmd_vol_vld       (cmd_vol_vld),
        .cmd_vol           (cmd_vol),
        .cmd_vol_step_vld  (cmd_vol_step_vld),
        .cmd_vol_up        (cmd_vol_up),
        .bt_live_keys      (bt_live_keys),
        .cmd_fx_vld        (cmd_fx_vld),
        .cmd_fx_sel        (cmd_fx_sel),
        .cmd_test_vld      (cmd_test_vld),
        .cmd_test_on       (cmd_test_on),
        .cmd_vib_vld       (cmd_vib_vld),
        .cmd_vib_depth     (cmd_vib_depth),
        .cmd_glide_vld     (cmd_glide_vld),
        .cmd_glide_lvl     (cmd_glide_lvl),
        .cmd_fxlv_vld      (cmd_fxlv_vld),
        .cmd_fx_level      (cmd_fx_level),
        .cmd_scene_vld     (cmd_scene_vld),
        .cmd_scene         (cmd_scene),
        .cmd_disp_vld      (cmd_disp_vld),
        .cmd_disp_mode     (cmd_disp_mode),
        .cmd_acc_vld       (cmd_acc_vld),
        .cmd_acc_mode      (cmd_acc_mode),
        .cmd_tempo_vld     (cmd_tempo_vld),
        .cmd_tempo_idx     (cmd_tempo_idx),
        .rec_active        (rec_active),
        .user_is_highres   (user_is_highres),
        .rec_keys          (player_keys | acc_rec_keys),
        .user_rd_addr      (step_idx),
        .user_next_addr    (next_step_idx),
        .user_rd_word      (user_rd_word),
        .user_next_word    (user_next_word),
        .user_last_step    (user_last_step),
        .transpose_semi    (transpose_semi)
    );

    wire [1:0] sys_mode;
    wire [1:0] active_page;
    wire       s2_fx_step_stb;
    wire       s2_disp_step_stb;

    // =========================================================================
    // 12 种音色专属精选效果搭配表 (每个音色仅保留 2~3 个最优搭配；09木琴与10贝司无需效果器则不显示、不切换)
    // 返回 18-bit 向量:
    //   [17:16] num_presets   (1=无可选效果器/S2不切换, 2=2个最优搭配, 3=3个最优搭配)
    //   [15:13] fx_allow_mask ({allow_rev, allow_dly, allow_cho}: 控制彩屏状态栏高亮显示适配的效果器)
    //   [12:10] p_fx_sel      ({rev, dly, cho})
    //   [9:6]   p_fx_level    (当前搭配最佳湿声浓度 0..15)
    //   [5]     p_vib_en      (当前搭配是否启用揉弦颤音)
    //   [4]     p_glide_en    (当前搭配是否启用连奏滑音)
    //   [3:0]   p_code        (彩屏效果搭配名称编码: 0=不显示, 1=混响开启, 2=原声模式, 3=混响合唱, 4=合唱开启,
    //                          5=颤音混响, 6=混响延迟, 7=滑音混响, 8=颤音混唱, 9=滑音颤音, 10=滑音延迟, 11=效果全开)
    // =========================================================================
    function [17:0] timbre_preset_lut;
        input [3:0] t;
        input [1:0] p;
        begin
            case (t)
                // 00 三角钢琴 (仅适配【混响】，不显示合唱与延迟；2 个搭配: 01混响开启 / 02原声模式)
                4'd0: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b100, 3'b100, 4'd7,  1'b0, 1'b0, 4'd1}; // 01: 混响开启 (默认最优)
                        default: timbre_preset_lut = {2'd2, 3'b100, 3'b000, 4'd7,  1'b0, 1'b0, 4'd2}; // 02: 原声模式
                    endcase
                end
                // 01 经典电钢 (适配【混响、合唱】，不显示延迟；3 个搭配: 01混响合唱 / 02合唱开启 / 03颤音混响)
                4'd1: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd3, 3'b101, 3'b101, 4'd8,  1'b0, 1'b0, 4'd3}; // 01: 混响合唱 (默认最优)
                        2'd1:    timbre_preset_lut = {2'd3, 3'b101, 3'b001, 4'd9,  1'b0, 1'b0, 4'd4}; // 02: 合唱开启
                        default: timbre_preset_lut = {2'd3, 3'b101, 3'b100, 4'd7,  1'b1, 1'b0, 4'd5}; // 03: 颤音混响
                    endcase
                end
                // 02 水晶八音 (适配【混响、延迟】，不显示合唱；2 个搭配: 01混响开启 / 02混响延迟)
                4'd2: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b110, 3'b100, 4'd9,  1'b0, 1'b0, 4'd1}; // 01: 混响开启 (默认最优)
                        default: timbre_preset_lut = {2'd2, 3'b110, 3'b110, 4'd8,  1'b0, 1'b0, 4'd6}; // 02: 混响延迟
                    endcase
                end
                // 03 教堂风琴 (适配【混响、合唱】，不显示延迟；2 个搭配: 01混响合唱 / 02混响开启)
                4'd3: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b101, 3'b101, 4'd10, 1'b0, 1'b0, 4'd3}; // 01: 混响合唱 (默认最优)
                        default: timbre_preset_lut = {2'd2, 3'b101, 3'b100, 4'd11, 1'b0, 1'b0, 4'd1}; // 02: 混响开启
                    endcase
                end
                // 04 古典吉他 (仅适配【混响】与指板滑音，不显示合唱与延迟；3 个搭配: 01混响开启 / 02滑音混响 / 03原声模式)
                4'd4: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd3, 3'b100, 3'b100, 4'd7,  1'b0, 1'b0, 4'd1}; // 01: 混响开启 (默认最优)
                        2'd1:    timbre_preset_lut = {2'd3, 3'b100, 3'b100, 4'd7,  1'b0, 1'b1, 4'd7}; // 02: 滑音混响
                        default: timbre_preset_lut = {2'd3, 3'b100, 3'b000, 4'd7,  1'b0, 1'b0, 4'd2}; // 03: 原声模式
                    endcase
                end
                // 05 交响弦乐 (适配【混响、合唱】与提琴揉弦颤音，不显示延迟；3 个搭配: 01颤音混唱 / 02混响合唱 / 03混响开启)
                4'd5: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd3, 3'b101, 3'b101, 4'd9,  1'b1, 1'b0, 4'd8}; // 01: 颤音混唱 (默认最优)
                        2'd1:    timbre_preset_lut = {2'd3, 3'b101, 3'b101, 4'd9,  1'b0, 1'b0, 4'd3}; // 02: 混响合唱
                        default: timbre_preset_lut = {2'd3, 3'b101, 3'b100, 4'd8,  1'b1, 1'b0, 4'd1}; // 03: 混响开启
                    endcase
                end
                // 06 空灵长笛 (适配【混响、延迟】与气息颤音/滑音，不显示合唱；3 个搭配: 01颤音混响 / 02混响延迟 / 03滑音颤音)
                4'd6: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd3, 3'b110, 3'b100, 4'd8,  1'b1, 1'b0, 4'd5}; // 01: 颤音混响 (默认最优)
                        2'd1:    timbre_preset_lut = {2'd3, 3'b110, 3'b110, 4'd8,  1'b1, 1'b0, 4'd6}; // 02: 混响延迟
                        default: timbre_preset_lut = {2'd3, 3'b110, 3'b100, 4'd8,  1'b1, 1'b1, 4'd9}; // 03: 滑音颤音
                    endcase
                end
                // 07 木管单簧 (仅适配【混响】与柔和颤音，不显示合唱与延迟；2 个搭配: 01颤音混响 / 02原声模式)
                4'd7: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b100, 3'b100, 4'd7,  1'b1, 1'b0, 4'd5}; // 01: 颤音混响 (默认最优)
                        default: timbre_preset_lut = {2'd2, 3'b100, 3'b000, 4'd7,  1'b0, 1'b0, 4'd2}; // 02: 原声模式
                    endcase
                end
                // 08 辉煌铜管 (适配【混响、合唱】，不显示延迟；2 个搭配: 01混响开启 / 02混响合唱)
                4'd8: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b101, 3'b100, 4'd8,  1'b0, 1'b0, 4'd1}; // 01: 混响开启 (默认最优)
                        default: timbre_preset_lut = {2'd2, 3'b101, 3'b101, 4'd8,  1'b1, 1'b0, 4'd3}; // 02: 混响合唱
                    endcase
                end
                // 09 木琴马林 (适配温暖木质空间【混响】与哈斯立体声原声；2 个搭配: 01混响开启 / 02原声模式)
                4'd9: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b100, 3'b100, 4'd5,  1'b0, 1'b0, 4'd1}; // 01: 混响开启 (清透木琴空间共鸣)
                        default: timbre_preset_lut = {2'd2, 3'b100, 3'b000, 4'd5,  1'b0, 1'b0, 4'd2}; // 02: 原声模式 (哈斯微立体声)
                    endcase
                end
                // 10 重低贝司 (适配哈斯立体声原声与立体声贝司【合唱】；2 个搭配: 01原声模式 / 02合唱开启)
                4'd10: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd2, 3'b001, 3'b000, 4'd5,  1'b0, 1'b0, 4'd2}; // 01: 原声模式 (扎实立体声低音)
                        default: timbre_preset_lut = {2'd2, 3'b001, 3'b001, 4'd5,  1'b0, 1'b0, 4'd4}; // 02: 合唱开启 (宽广立体声电贝司)
                    endcase
                end
                // 11 合成主音 (全效果适配；3 个搭配: 01混响合唱 / 02滑音延迟 / 03效果全开)
                default: begin
                    case (p)
                        2'd0:    timbre_preset_lut = {2'd3, 3'b111, 3'b101, 4'd9,  1'b0, 1'b0, 4'd3};  // 01: 混响合唱 (默认最优)
                        2'd1:    timbre_preset_lut = {2'd3, 3'b111, 3'b110, 4'd9,  1'b1, 1'b1, 4'd10}; // 02: 滑音延迟
                        default: timbre_preset_lut = {2'd3, 3'b111, 3'b111, 4'd9,  1'b1, 1'b1, 4'd11}; // 03: 效果全开
                    endcase
                end
            endcase
        end
    endfunction

    reg [3:0] timbre_idx_d;
    reg [1:0] preset_idx;
    reg [2:0] fx_sel;
    reg [3:0] fx_level;
    reg       preset_vib_en;
    reg       preset_glide_en;
    reg       bt_vib_ovr;
    reg       bt_glide_ovr;
    reg       test_en;
    reg [1:0] disp_mode;

    wire [17:0] cur_preset_info = timbre_preset_lut(timbre_idx, preset_idx);
    wire [1:0]  num_presets     = cur_preset_info[17:16];
    wire [2:0]  fx_allow_mask   = cur_preset_info[15:13];
    wire [3:0]  preset_code     = cur_preset_info[3:0];

    wire [1:0]  next_preset_idx = (num_presets <= 2'd1) ? 2'd0 :
                                  (num_presets == 2'd2) ? ((preset_idx >= 2'd1) ? 2'd0 : (preset_idx + 2'd1)) :
                                                          ((preset_idx >= 2'd2) ? 2'd0 : (preset_idx + 2'd1));
    wire [17:0] next_preset_info = timbre_preset_lut(timbre_idx, next_preset_idx);
    wire [17:0] def_preset_info  = timbre_preset_lut(timbre_idx, 2'd0);
    wire [17:0] p1_info          = timbre_preset_lut(timbre_idx, 2'd1);
    wire [17:0] p2_info          = timbre_preset_lut(timbre_idx, 2'd2);

    wire cmd_vib_on   = (cmd_vib_depth != 4'd0);
    wire cmd_glide_on = (cmd_glide_lvl != 4'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            timbre_idx_d    <= 4'd0;
            preset_idx      <= 2'd0;
            fx_sel          <= 3'b100; // 开机 00 三角钢琴默认搭配 01: 适度音乐厅混响
            fx_level        <= 4'd7;
            preset_vib_en   <= 1'b0;
            preset_glide_en <= 1'b0;
            bt_vib_ovr      <= 1'b0;
            bt_glide_ovr    <= 1'b0;
            test_en         <= 1'b0;
            disp_mode       <= 2'd0;
        end else begin
            timbre_idx_d <= timbre_idx;

            if (s2_disp_step_stb || tp_disp_step_stb) begin
                disp_mode <= (disp_mode >= 2'd2) ? 2'd0 : (disp_mode + 2'd1);
            end else if (cmd_disp_vld) begin
                if (cmd_disp_mode == 2'd3)
                    disp_mode <= (disp_mode >= 2'd2) ? 2'd0 : (disp_mode + 2'd1);
                else
                    disp_mode <= cmd_disp_mode;
            end

            // 1. 切换音色时：自动加载该音色的【搭配 01 (首选最优效果搭配)】
            if (timbre_idx != timbre_idx_d) begin
                preset_idx      <= 2'd0;
                fx_sel          <= def_preset_info[12:10];
                fx_level        <= def_preset_info[9:6];
                preset_vib_en   <= def_preset_info[5];
                preset_glide_en <= def_preset_info[4];
                bt_vib_ovr      <= 1'b0;
                bt_glide_ovr    <= 1'b0;
            // 2. 在效果器选择模式下按 S2 或触摸效果搭配卡：在该音色适配的 2~3 个搭配间循环切换
            end else if (s2_fx_step_stb || tp_fx_step_stb) begin
                if (num_presets > 2'd1) begin
                    preset_idx      <= next_preset_idx;
                    fx_sel          <= next_preset_info[12:10];
                    fx_level        <= next_preset_info[9:6];
                    preset_vib_en   <= next_preset_info[5];
                    preset_glide_en <= next_preset_info[4];
                    bt_vib_ovr      <= 1'b0;
                    bt_glide_ovr    <= 1'b0;
                end
            // 3. 蓝牙 E 指令或触摸独立效果按钮：严格受限于当前音色适配的效果器范围!
            end else if ((cmd_fx_vld || tp_fx_vld) && (num_presets > 2'd1)) begin
                case (tp_fx_vld ? tp_fx_sel : cmd_fx_sel)
                    4'd0: begin // E0: 关闭当前音色空间效果
                        fx_sel <= 3'b000;
                    end
                    4'd1: begin // E1: 切换到当前音色【搭配 01】
                        preset_idx      <= 2'd0;
                        fx_sel          <= def_preset_info[12:10];
                        fx_level        <= def_preset_info[9:6];
                        preset_vib_en   <= def_preset_info[5];
                        preset_glide_en <= def_preset_info[4];
                        bt_vib_ovr      <= 1'b0;
                        bt_glide_ovr    <= 1'b0;
                    end
                    4'd2: begin // E2: 切换到当前音色【搭配 02】
                        preset_idx      <= 2'd1;
                        fx_sel          <= p1_info[12:10];
                        fx_level        <= p1_info[9:6];
                        preset_vib_en   <= p1_info[5];
                        preset_glide_en <= p1_info[4];
                        bt_vib_ovr      <= 1'b0;
                        bt_glide_ovr    <= 1'b0;
                    end
                    4'd3: begin // E3: 切换到当前音色【搭配 03】(仅当该音色有 3 个搭配时生效)
                        if (num_presets == 2'd3) begin
                            preset_idx      <= 2'd2;
                            fx_sel          <= p2_info[12:10];
                            fx_level        <= p2_info[9:6];
                            preset_vib_en   <= p2_info[5];
                            preset_glide_en <= p2_info[4];
                            bt_vib_ovr      <= 1'b0;
                            bt_glide_ovr    <= 1'b0;
                        end
                    end
                    4'd8: begin // E8: 仅在该音色支持合唱时切换合唱开关
                        if (fx_allow_mask[0]) fx_sel[0] <= ~fx_sel[0];
                    end
                    4'd9: begin // E9: 仅在该音色支持延迟时切换延迟开关
                        if (fx_allow_mask[1]) fx_sel[1] <= ~fx_sel[1];
                    end
                    4'd10: begin // EA: 仅在该音色支持混响时切换混响开关
                        if (fx_allow_mask[2]) fx_sel[2] <= ~fx_sel[2];
                    end
                    default: begin // EB / E+: 循环切换当前音色的下一个适配搭配 (等效按 S2)
                        preset_idx      <= next_preset_idx;
                        fx_sel          <= next_preset_info[12:10];
                        fx_level        <= next_preset_info[9:6];
                        preset_vib_en   <= next_preset_info[5];
                        preset_glide_en <= next_preset_info[4];
                        bt_vib_ovr      <= 1'b0;
                        bt_glide_ovr    <= 1'b0;
                    end
                endcase
            end

            if (cmd_vib_vld && (num_presets > 2'd1))   bt_vib_ovr   <= 1'b1;
            if (cmd_glide_vld && (num_presets > 2'd1)) bt_glide_ovr <= 1'b1;
            if (cmd_test_vld) test_en <= cmd_test_on;
            if (cmd_fxlv_vld && (num_presets > 2'd1))  fx_level     <= cmd_fx_level;
        end
    end

    wire vibrato_eff    = (num_presets <= 2'd1) ? 1'b0 : (bt_vib_ovr   ? vibrato_en    : preset_vib_en);
    wire portamento_eff = (num_presets <= 2'd1) ? 1'b0 : (bt_glide_ovr ? portamento_en : preset_glide_en);

    wire [17:0] combined_keys_n = keys_raw_n & ~(auto_keys | bt_live_keys | tp_live_keys);

    key_encoder_input u_input (
        .clk              (clk),
        .rst_n            (rst_n),
        .s1_autoplay_btn  (s1_key),
        .s2_song_btn      (s2_key),
        .active_page      (active_page),
        .song_auto_next   (song_auto_next),
        .cmd_play_user    (cmd_play_user),
        .cmd_stop         (cmd_stop | tp_stop),
        .cmd_song_vld     (cmd_song_vld | tp_song_vld),
        .cmd_song_idx     (tp_song_vld ? tp_song_idx : cmd_song_idx),
        .cmd_timbre_vld   (cmd_timbre_vld | tp_timbre_vld),
        .cmd_timbre       (tp_timbre_vld ? tp_timbre : cmd_timbre),
        .cmd_vol_vld      (cmd_vol_vld),
        .cmd_vol          (cmd_vol),
        .cmd_vol_step_vld (cmd_vol_step_vld | tp_vol_step_vld),
        .cmd_vol_up       (tp_vol_step_vld ? tp_vol_up : cmd_vol_up),
        .cmd_vib_vld      (cmd_vib_vld),
        .cmd_vib_on       (cmd_vib_on),
        .cmd_glide_vld    (cmd_glide_vld),
        .cmd_glide_on     (cmd_glide_on),
        .cmd_acc_vld      (cmd_acc_vld | tp_acc_vld),
        .cmd_acc_mode     (tp_acc_vld ? tp_acc_mode : cmd_acc_mode),
        .cmd_scene_vld    (cmd_scene_vld | tp_scene_vld),
        .cmd_scene        (tp_scene_vld ? tp_scene : cmd_scene),
        .keys_raw_n       (combined_keys_n),
        .enc1_a           (enc1_a),
        .enc1_b           (enc1_b),
        .enc1_sw_n        (enc1_sw_n),
        .enc2_a           (enc2_a),
        .enc2_b           (enc2_b),
        .enc2_sw_n        (enc2_sw_n),
        .key_state        (key_state),
        .key_press_evt    (key_press_evt),
        .key_rel_evt      (key_rel_evt),
        .volume           (volume),
        .timbre_idx       (timbre_idx),
        .vibrato_en       (vibrato_en),
        .portamento_en    (portamento_en),
        .sys_mode         (sys_mode),
        .auto_play_en     (auto_play_en),
        .song_idx         (song_idx),
        .song_restart_stb (song_restart_stb),
        .acc_mode         (acc_mode),
        .s2_fx_step_stb   (s2_fx_step_stb),
        .s2_disp_step_stb (s2_disp_step_stb)
    );

    // =========================================================================
    // 2b. 轻量级智能伴奏引擎 (主音/和弦识别 + 自动分解和弦 + 自动低音 + 速度跟随 + 节奏切换)
    // =========================================================================
    smart_accompaniment #(
        .STEP_DEFAULT_P (ACC_STEP_DEF_P),
        .STEP_MIN_P     (ACC_STEP_MIN_P),
        .STEP_MAX_P     (ACC_STEP_MAX_P)
    ) u_acc (
        .clk              (clk),
        .rst_n            (rst_n),
        .key_state        (key_state),
        .key_press_evt    (key_press_evt),
        .key_rel_evt      (key_rel_evt),
        .auto_play_en     (auto_play_en),
        .acc_mode         (acc_mode),
        .tempo_preset_vld (cmd_tempo_vld | tp_tempo_vld),
        .tempo_preset_idx (tp_tempo_vld ? tp_tempo_idx : cmd_tempo_idx),
        .acc_active       (acc_active),
        .det_root         (det_root),
        .det_chord_type   (det_chord_type),
        .rhythm_step      (rhythm_step),
        .beat_pulse       (acc_beat_pulse),
        .acc_bass_stb     (acc_bass_stb),
        .acc_bass_note    (acc_bass_note),
        .acc_bass_gate    (acc_bass_gate),
        .acc_arp_stb      (acc_arp_stb),
        .acc_arp_note     (acc_arp_note),
        .acc_arp2_stb     (acc_arp2_stb),
        .acc_arp2_note    (acc_arp2_note),
        .acc_arp_gate     (acc_arp_gate),
        .acc_vis_keys     (acc_vis_keys),
        .acc_rec_keys     (acc_rec_keys)
    );

    // =========================================================================
    // 2c. 11 白键铜箔电容隔空接近 (t1) + 机械开关触底 (t2) 双时间戳力度检测引擎
    // =========================================================================
    wire [125:0] key_vel_flat;
    wire [6:0]   last_vel;

    white_key_cap_velocity u_vel (
        .clk           (clk),
        .rst_n         (rst_n),
        .key_state     (key_state),
        .key_press_evt (key_press_evt),
        .remote_keys   (bt_live_keys | tp_live_keys),
        .auto_play_en  (auto_play_en),
        .vel_io        (vel_io),
        .key_vel_flat  (key_vel_flat),
        .last_vel      (last_vel)
    );

    wire signed [23:0] pcm_sample;
    wire signed [15:0] mono_sample;
    wire               voices_active;

    poly32_fm_synth u_synth (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_tick   (sample_tick),
        .key_state     (key_state),
        .key_press_evt (key_press_evt),
        .key_rel_evt   (key_rel_evt),
        .key_vel_flat  (key_vel_flat),
        .volume        (volume),
        .timbre_idx    (timbre_idx),
        .vibrato_en     (vibrato_eff),
        .portamento_en  (portamento_eff),
        .transpose_semi (transpose_semi),
        .test_cmd_vld   (cmd_test_vld),
        .test_cmd_on   (cmd_test_on),
        .acc_bass_stb  (acc_bass_stb),
        .acc_bass_note (acc_bass_note),
        .acc_bass_gate (acc_bass_gate),
        .acc_arp_stb   (acc_arp_stb),
        .acc_arp_note  (acc_arp_note),
        .acc_arp2_stb  (acc_arp2_stb),
        .acc_arp2_note (acc_arp2_note),
        .acc_arp_gate  (acc_arp_gate),
        .pcm_out       (pcm_sample),
        .mono_sample   (mono_sample),
        .voices_active (voices_active)
    );

    wire signed [23:0] pcm_l, pcm_r;
    audio#(
        .DLY_DEPTH (DLY_DEPTH_P)
    ) u_fx (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .pcm_in      (pcm_sample),
        .fx_sel      (fx_sel),
        .fx_level    (fx_level),
        .pcm_l       (pcm_l),
        .pcm_r       (pcm_r)
    );

    // =========================================================================
    // 3. PCM5102A 24-bit 真立体声 Hi-Fi I2S 母带输出引擎:
    //    - 2x 动态母带增益 + 平滑软膝盖限幅，兼顾低电位器档位高响度与高电位器档位零破音!
    //    - 标准 Philips I2S 64-BCK 帧格式 (BCK=L5, LCK=E10, DIN=A10, FLT=A11, DMP=E11, SCL=K11, FMT=L11, XMT=K5)
    // =========================================================================
    reg signed [23:0] gain_l1, gain_r1;
    reg signed [23:0] gain_l,  gain_r;
    reg signed [23:0] i2s_word_l, i2s_word_r;
    reg               pcm_bck_r;
    reg               pcm_lck_r;
    reg               pcm_din_reg;
    reg [24:0]        dac_active_hold;

    wire audio_playing = voices_active ||
                         ((pcm_l > 24'sd24) || (pcm_l < -24'sd24)) ||
                         ((pcm_r > 24'sd24) || (pcm_r < -24'sd24)) ||
                         (|key_state) || auto_play_en || acc_active || test_en;

    wire signed [23:0] diff_l1 = pcm_l   - gain_l1;
    wire signed [23:0] diff_r1 = pcm_r   - gain_r1;
    wire signed [23:0] step_l1 = (diff_l1[23] ? (diff_l1 + 24'sd1) : diff_l1) >>> 1;
    wire signed [23:0] step_r1 = (diff_r1[23] ? (diff_r1 + 24'sd1) : diff_r1) >>> 1;

    wire signed [23:0] next_l1 = gain_l1 + step_l1;
    wire signed [23:0] next_r1 = gain_r1 + step_r1;
    wire signed [23:0] diff_l2 = gain_l1 - gain_l;
    wire signed [23:0] diff_r2 = gain_r1 - gain_r;
    wire signed [23:0] step_l2 = (diff_l2[23] ? (diff_l2 + 24'sd1) : diff_l2) >>> 1;
    wire signed [23:0] step_r2 = (diff_r2[23] ? (diff_r2 + 24'sd1) : diff_r2) >>> 1;

    wire [9:0] next_clk_div = clk_div + 10'd1;

    always @(posedge clk) begin
        if (!rst_n) begin
            gain_l1         <= 24'sd0;
            gain_r1         <= 24'sd0;
            gain_l          <= 24'sd0;
            gain_r          <= 24'sd0;
            i2s_word_l      <= 24'sd0;
            i2s_word_r      <= 24'sd0;
            pcm_bck_r       <= 1'b0;
            pcm_lck_r       <= 1'b0;
            pcm_din_reg     <= 1'b0;
            dac_active_hold <= 25'd0;
        end else begin
            pcm_bck_r <= next_clk_div[3];
            pcm_lck_r <= next_clk_div[9];

            if (audio_playing)
                dac_active_hold <= 25'd24_999_999; // 发声期间立即开启 DAC，完全静默 0.5 秒后平滑进入硬件零底噪静音
            else if (dac_active_hold != 25'd0)
                dac_active_hold <= dac_active_hold - 25'd1;

            if (sample_tick) begin
                if (!audio_playing && (gain_l >= -24'sd8 && gain_l <= 24'sd8) && (gain_r >= -24'sd8 && gain_r <= 24'sd8)) begin
                    gain_l1 <= 24'sd0;
                    gain_r1 <= 24'sd0;
                    gain_l  <= 24'sd0;
                    gain_r  <= 24'sd0;
                end else begin
                    gain_l1 <= next_l1;
                    gain_r1 <= next_r1;
                    gain_l  <= gain_l + step_l2; // 双级联向零舍入重构低通滤波，彻底滤除 PAM8403 D类高频互调底噪
                    gain_r  <= gain_r + step_r2;
                end
            end

            if (bck_falling_en) begin
                if (bit_idx == 6'd63) begin
                    i2s_word_l  <= gain_l;
                    pcm_din_reg <= 1'b0;
                end else if (bit_idx == 6'd31) begin
                    i2s_word_r  <= gain_r;
                end
                if (bit_idx <= 6'd23) begin
                    pcm_din_reg <= i2s_word_l[6'd23 - bit_idx];
                end else if (bit_idx >= 6'd32 && bit_idx <= 6'd55) begin
                    pcm_din_reg <= i2s_word_r[6'd55 - bit_idx];
                end else begin
                    pcm_din_reg <= 1'b0;
                end
            end
        end
    end

    assign pcm_bck  = pcm_bck_r;                              // Pin L5  -> PCM5102A BCK (同步寄存器直出，零组合毛刺/低时钟抖动)
    assign pcm_lck  = pcm_lck_r;                              // Pin E10 -> PCM5102A LCK (同步寄存器直出)
    assign pcm_din  = pcm_din_reg;                            // Pin A10 -> PCM5102A DIN
    assign pcm_flt  = 1'b0;                                   // Pin A11 -> PCM5102A FLT
    assign pcm_dmp  = 1'b1;                                   // Pin E11 -> PCM5102A DMP (开启硬件高频去加重滤波，抑制功放高频沙沙底噪)
    assign pcm_scl  = 1'b0;                                   // Pin K11 -> PCM5102A SCL
    assign pcm_fmt  = 1'b0;                                   // Pin L11 -> PCM5102A FMT
    assign pcm_xmt  = rst_n & (dac_active_hold != 25'd0);     // Pin K5  -> PCM5102A XMT (发声及余音期高电平，静默0.5s后硬件零底噪静音)

    // 2.4寸 ILI9341 (320x240 RGB565 SPI) 彩屏 + XPT2046 电阻触摸屏多页面交互引擎
    ili9341_touch_ui u_touch_ui (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_tick      (sample_tick),
        .mono_sample      (mono_sample),
        .key_state        (key_state),
        .volume           (volume),
        .timbre_idx       (timbre_idx),
        .vibrato_en       (vibrato_eff),
        .portamento_en    (portamento_eff),
        .guide_keys       (next_keys),
        .guide_en         (guide_cue),
        .rec_active       (rec_active),
        .disp_mode        (disp_mode),
        .acc_vis_keys     (acc_vis_keys),
        .acc_beat_pulse   (acc_beat_pulse),
        .sys_mode         (sys_mode),
        .preset_idx       (preset_idx),
        .preset_code      (preset_code),
        .fx_allow_mask    (fx_allow_mask),
        .auto_play_en     (auto_play_en),
        .song_idx         (song_idx),
        .fx_sel           (fx_sel),
        .acc_mode         (acc_mode),
        .acc_active       (acc_active),
        .det_root         (det_root),
        .det_chord_type   (det_chord_type),
        .rhythm_step      (rhythm_step),
        .cal_trig_btn     ((s1_key & s2_key) | (~enc1_sw_n & ~enc2_sw_n)),
        .last_vel         (last_vel),
        .transpose_semi   (transpose_semi),
        .tp_timbre_vld    (tp_timbre_vld),
        .tp_timbre        (tp_timbre),
        .tp_vol_step_vld  (tp_vol_step_vld),
        .tp_vol_up        (tp_vol_up),
        .tp_acc_vld       (tp_acc_vld),
        .tp_acc_mode      (tp_acc_mode),
        .tp_tempo_vld     (tp_tempo_vld),
        .tp_tempo_idx     (tp_tempo_idx),
        .tp_song_vld      (tp_song_vld),
        .tp_song_idx      (tp_song_idx),
        .tp_stop          (tp_stop),
        .tp_scene_vld     (tp_scene_vld),
        .tp_scene         (tp_scene),
        .tp_fx_step_stb   (tp_fx_step_stb),
        .tp_fx_vld        (tp_fx_vld),
        .tp_fx_sel        (tp_fx_sel),
        .tp_disp_step_stb (tp_disp_step_stb),
        .tp_live_keys     (tp_live_keys),
        .active_page      (active_page),
        .lcd_sck          (lcd_sck),
        .lcd_sdi          (lcd_sdi),
        .lcd_dc           (lcd_dc),
        .lcd_reset        (lcd_reset),
        .lcd_cs           (lcd_cs),
        .tp_clk           (tp_clk),
        .tp_cs            (tp_cs),
        .tp_din           (tp_din),
        .tp_do            (tp_do),
        .tp_irq           (tp_irq)
    );

    reg [1:0]  sw_keep;
    reg [24:0] hb_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            sw_keep <= 2'b11;
            hb_cnt  <= 25'd0;
        end else begin
            sw_keep <= {sw_keep[0], enc1_sw_n ^ enc2_sw_n ^ rhythm_step[0]};
            if (hb_cnt == 25'h1FFFFFF)
                hb_cnt <= {24'd0, ~sw_keep[1]};
            else
                hb_cnt <= hb_cnt + 25'd1;
        end
    end

    assign led = rec_active              ? 1'b1 :
                 test_en                 ? hb_cnt[21] :
                 guide_cue               ? 1'b1 :
                 acc_active              ? acc_beat_pulse :
                 auto_play_en            ? 1'b0 :
                 (|key_state)            ? 1'b1 : hb_cnt[24];

endmodule
// =============================================================================
// 文件名: smart_accompaniment.v
// 适用平台: Sipeed Tang Primer 25K (GW5A-LV25MG121NC1/I0)
// 模块功能: 轻量级硬件智能伴奏引擎 
// 核心特性:
//   1.【实时主音与多维和弦识别 (Root & Inversion-Aware Chord Detection)】
//      - 将 18 键状态折叠为 12 平均律音级向量 (Chroma Vector)，支持：
//        * 多指原位/转位和弦自动识别：大三和弦 (Maj)、小三和弦 (Min)、属七和弦 (Dom7)、
//          小七和弦 (Min7)、挂四和弦 (Sus4)、减三和弦 (Dim)；
//        * 双音音程智能推断：大三度/小三度/纯五度/纯四度/大小六度转位自动定根音；
//        * 单指智能调内配和弦：低音区或单指弹奏自动匹配自然大调/小调三和弦；
//        * 抬键防抖锁存与高音旋律分离：仅在触键窗口更新和弦，松手抬指绝不误跳和弦；
//          锁定多指和弦后，高八度 (C5~F5) 单音旋律演奏不会打乱当前伴奏和弦。
//   2.【自动分解和弦发生器 (2-Octave True Ascending Arpeggiator)】
//      - 根据识别出的根音与和弦性质，实时计算跨两个八度 (C4~C6, 音符编号 0..24) 的
//        四个和弦音级 (根音 tone0、三音/挂四音 tone1、五音 tone2、高八度/七音 tone3)，
//        通过独立声部通道自动输出单音流水分解或双音柱式伴奏。
//   3.【自动低音伴奏发生器 (Sub-Octave Bass Accompaniment)】
//      - 自动生成根音 (Root)、三音 (Third)、五音 (Fifth) 低音伴奏序列，驱动合成器
//        专用低音声部以 -1 八度 (C3~B3) 重低贝司音色独立发声。
//   4.【自适应演奏速度跟随 (IOI Performance Tempo Tracker)】
//      - 实时测量玩家触键间隔 (Inter-Onset Interval, IOI)：自动滤除 <75ms 的和弦同时按下的
//        多指微时间差，智能识别八分音符/四分音符弹奏速率，经一阶 IIR 平滑滤波动态调整
//        伴奏步进周期 (支持 ~66 BPM 至 ~200 BPM 无缝变速跟随)，并在起拍瞬间零延迟对齐强拍。
//   5.【五态简单节奏型切换 (5-Mode Rhythm Pattern Switcher)】
//      - 0: 关闭伴奏 (OFF)
//      - 1: 抒情分解 (4/4 Ballad Arpeggio: 1-5-8-3-5-8-5-3 流水分解 + 根五持续低音, 默认开启)
//      - 2: 流行律动 (4/4 Pop Bounce: 1-5-1-5 跳跃低音 + 2/4 拍双音后拍切分伴奏)
//      - 3: 华尔兹拍 (3/4 Waltz: 6 步三拍子 "强-弱-弱" 根五五低音 + 双音柱式伴奏)
//      - 4: 动感八拍 (4/4 Driving 8-Beat: 1-1-3-3-5-5-6-5 行走贝司 + 波浪分解和弦)
// =============================================================================

module smart_accompaniment #(
    parameter [24:0] STEP_DEFAULT_P = 25'd12_499_999, // 默认 120 BPM 八分音符步长 (250ms @ 50MHz)
    parameter [24:0] STEP_MIN_P     = 25'd7_499_999,  // 最快步长 150ms (~200 BPM)
    parameter [24:0] STEP_MAX_P     = 25'd22_499_999  // 最慢步长 450ms (~66 BPM)
) (
    input  wire        clk,              // 50MHz 系统时钟
    input  wire        rst_n,            // 低有效同步复位
    input  wire [17:0] key_state,        // 消抖后按键状态 (C4~F5, 高有效)
    input  wire [17:0] key_press_evt,    // 单周期按键按下触发脉冲
    input  wire [17:0] key_rel_evt,      // 单周期按键释放触发脉冲
    input  wire        auto_play_en,     // 自动演奏状态 (开启内置示范曲时自动静音伴奏)
    input  wire [2:0]  acc_mode,         // 节奏型模式: 0=关, 1=抒情分解, 2=流行律动, 3=华尔兹3/4, 4=动感八拍
    input  wire        tempo_preset_vld, // 蓝牙速度预设脉冲 (B6~B9)
    input  wire [1:0]  tempo_preset_idx, // 0:90BPM, 1:110BPM, 2:130BPM, 3:150BPM
    output reg         acc_active,       // 智能伴奏当前正在发声标志
    output reg  [3:0]  det_root,         // 识别出的当前主音/根音 (0=C .. 11=B)
    output reg  [2:0]  det_chord_type,   // 识别出的和弦性质 (0=Maj,1=Min,2=Dom7,3=Min7,4=Sus4,5=Dim)
    output reg  [2:0]  rhythm_step,      // 当前小节步进索引 (4/4拍为0..7, 3/4华尔兹为0..5)
    output wire        beat_pulse,       // 节拍同步脉冲 (送往彩屏仪表盘与状态指示灯)
    output reg         acc_bass_stb,     // 自动低音伴奏触发单拍脉冲
    output reg  [4:0]  acc_bass_note,    // 自动低音伴奏音符 (0..11, 合成器内部降八度以贝司音色发声)
    output reg         acc_bass_gate,    // 自动低音门控信号
    output reg         acc_arp_stb,      // 自动分解和弦主音触发单拍脉冲
    output reg  [4:0]  acc_arp_note,     // 自动分解和弦主音编号 (0..24, C4~C6)
    output reg         acc_arp2_stb,     // 自动分解和弦副音触发单拍脉冲 (柱式双音伴奏)
    output reg  [4:0]  acc_arp2_note,    // 自动分解和弦副音编号 (0..24, C4~C6)
    output reg         acc_arp_gate,     // 自动分解和弦门控信号
    output wire [17:0] acc_vis_keys,     // 折叠至 18 键的彩屏伴奏可视化键位掩码
    output wire [17:0] acc_rec_keys      // 折叠至 18 键的伴奏实弹录音键位掩码 (不含降八度低音)
);

    localparam [2:0] CHORD_MAJ  = 3'd0;
    localparam [2:0] CHORD_MIN  = 3'd1;
    localparam [2:0] CHORD_DOM7 = 3'd2;
    localparam [2:0] CHORD_MIN7 = 3'd3;
    localparam [2:0] CHORD_SUS4 = 3'd4;
    localparam [2:0] CHORD_DIM  = 3'd5;

    // =========================================================================
    // 1. 18 键转 12 音级向量 (Chroma Vector) 与最低音提取
    // =========================================================================
    wire [11:0] chroma;
    assign chroma[0]  = key_state[0]  | key_state[12]; // C
    assign chroma[1]  = key_state[1]  | key_state[13]; // C#
    assign chroma[2]  = key_state[2]  | key_state[14]; // D
    assign chroma[3]  = key_state[3]  | key_state[15]; // D#
    assign chroma[4]  = key_state[4]  | key_state[16]; // E
    assign chroma[5]  = key_state[5]  | key_state[17]; // F
    assign chroma[6]  = key_state[6];                  // F#
    assign chroma[7]  = key_state[7];                  // G
    assign chroma[8]  = key_state[8];                  // G#
    assign chroma[9]  = key_state[9];                  // A
    assign chroma[10] = key_state[10];                 // A#
    assign chroma[11] = key_state[11];                 // B

    reg [4:0] key_cnt;
    reg [3:0] chroma_cnt;
    reg [4:0] lowest_key;
    reg       found_low;
    integer   ki, ci;

    always @(*) begin
        key_cnt    = 5'd0;
        lowest_key = 5'd0;
        found_low  = 1'b0;
        for (ki = 0; ki < 18; ki = ki + 1) begin
            if (key_state[ki]) begin
                key_cnt = key_cnt + 5'd1;
                if (!found_low) begin
                    lowest_key = ki[4:0];
                    found_low  = 1'b1;
                end
            end
        end

        chroma_cnt = 4'd0;
        for (ci = 0; ci < 12; ci = ci + 1) begin
            if (chroma[ci])
                chroma_cnt = chroma_cnt + 4'd1;
        end
    end

    wire [4:0] lowest_pc_full = (lowest_key >= 5'd12) ? (lowest_key - 5'd12) : lowest_key;
    wire [3:0] lowest_pc      = lowest_pc_full[3:0];

    function [11:0] rot12;
        input [11:0] c;
        input [3:0]  r;
        reg   [23:0] dbl;
        begin
            dbl   = {c, c} >> r;
            rot12 = dbl[11:0];
        end
    endfunction

    function [3:0] add_mod12;
        input [3:0] a;
        input [3:0] b;
        reg   [4:0] sum;
        begin
            sum       = {1'b0, a} + {1'b0, b};
            add_mod12 = (sum >= 5'd12) ? (sum[3:0] - 4'd12) : sum[3:0];
        end
    endfunction

    function [2:0] diatonic_type;
        input [3:0] pc;
        begin
            case (pc)
                4'd2, 4'd4, 4'd9, 4'd11, 4'd1, 4'd6: diatonic_type = CHORD_MIN;
                default:                             diatonic_type = CHORD_MAJ;
            endcase
        end
    endfunction

    // =========================================================================
    // 2. 组合逻辑和弦识别器 (支持原位、第一/第二转位、七和弦、挂留和弦与双音音程)
    // =========================================================================
    wire [11:0] r_low = rot12(chroma, lowest_pc);
    reg  [3:0]  comb_root;
    reg  [2:0]  comb_type;
    reg         inv_matched;
    reg  [11:0] r_scan;
    integer     ri;

    always @(*) begin
        comb_root   = lowest_pc;
        comb_type   = diatonic_type(lowest_pc);
        inv_matched = 1'b0;
        r_scan      = 12'd0;

        if (chroma_cnt >= 4'd3) begin
            if (r_low[0] && r_low[4] && r_low[10]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_DOM7;
            end else if (r_low[0] && r_low[3] && r_low[10]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_MIN7;
            end else if (r_low[0] && r_low[4] && r_low[7]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_MAJ;
            end else if (r_low[0] && r_low[3] && r_low[7]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_MIN;
            end else if (r_low[0] && r_low[5] && r_low[7]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_SUS4;
            end else if (r_low[0] && r_low[3] && r_low[6]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_DIM;
            end else begin
                for (ri = 0; ri < 12; ri = ri + 1) begin
                    r_scan = rot12(chroma, ri[3:0]);
                    if (!inv_matched) begin
                        if (r_scan[0] && r_scan[4] && r_scan[7] && r_scan[10]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_DOM7;
                            inv_matched = 1'b1;
                        end else if (r_scan[0] && r_scan[3] && r_scan[7] && r_scan[10]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_MIN7;
                            inv_matched = 1'b1;
                        end else if (r_scan[0] && r_scan[4] && r_scan[7]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_MAJ;
                            inv_matched = 1'b1;
                        end else if (r_scan[0] && r_scan[3] && r_scan[7]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_MIN;
                            inv_matched = 1'b1;
                        end else if (r_scan[0] && r_scan[5] && r_scan[7]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_SUS4;
                            inv_matched = 1'b1;
                        end else if (r_scan[0] && r_scan[3] && r_scan[6]) begin
                            comb_root   = ri[3:0];
                            comb_type   = CHORD_DIM;
                            inv_matched = 1'b1;
                        end
                    end
                end
            end
        end else if (chroma_cnt == 4'd2) begin
            if (r_low[4]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_MAJ;
            end else if (r_low[3]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_MIN;
            end else if (r_low[7]) begin
                comb_root = lowest_pc;
                comb_type = diatonic_type(lowest_pc);
            end else if (r_low[8]) begin
                comb_root = add_mod12(lowest_pc, 4'd8);
                comb_type = CHORD_MAJ;
            end else if (r_low[9]) begin
                comb_root = add_mod12(lowest_pc, 4'd9);
                comb_type = CHORD_MIN;
            end else if (r_low[5]) begin
                comb_root = add_mod12(lowest_pc, 4'd5);
                comb_type = diatonic_type(add_mod12(lowest_pc, 4'd5));
            end else if (r_low[10]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_DOM7;
            end else if (r_low[6]) begin
                comb_root = lowest_pc;
                comb_type = CHORD_DIM;
            end else begin
                comb_root = lowest_pc;
                comb_type = diatonic_type(lowest_pc);
            end
        end else begin
            comb_root = lowest_pc;
            comb_type = diatonic_type(lowest_pc);
        end
    end

    wire [11:0] locked_chord_mask;
    wire [3:0]  locked_3rd_pc = add_mod12(det_root,
                    (det_chord_type == CHORD_MIN || det_chord_type == CHORD_MIN7 || det_chord_type == CHORD_DIM) ? 4'd3 :
                    (det_chord_type == CHORD_SUS4) ? 4'd5 : 4'd4);
    wire [3:0]  locked_5th_pc = add_mod12(det_root, (det_chord_type == CHORD_DIM) ? 4'd6 : 4'd7);
    assign locked_chord_mask  = (12'd1 << det_root) | (12'd1 << locked_3rd_pc) | (12'd1 << locked_5th_pc);

    reg  [21:0] recog_win_cnt;
    reg  [3:0]  max_chroma_in_win;
    reg         multi_chord_locked;

    wire        any_key_press = (|key_press_evt);
    wire        any_key_held  = (|key_state);
    wire        unused_rel    = (|key_rel_evt);

    wire        chord_update_cond = any_key_held && (any_key_press || (recog_win_cnt != 22'd0)) &&
                                    ((chroma_cnt >= 4'd2) ||
                                     ((chroma_cnt == 4'd1) && (max_chroma_in_win <= 4'd1) &&
                                      (!multi_chord_locked || (lowest_key <= 5'd11) || !locked_chord_mask[lowest_pc])));

    wire [3:0]  eff_root = chord_update_cond ? comb_root : det_root;
    wire [2:0]  eff_type = chord_update_cond ? comb_type : det_chord_type;

    // =========================================================================
    // 3. 和弦音级映射器: 生成分解和弦四音 (tone0..tone3, 0..24) 与低音三音 (0..11)
    // =========================================================================
    reg [4:0] int_3rd;
    reg [4:0] int_5th;
    reg [4:0] int_top;
    always @(*) begin
        case (eff_type)
            CHORD_MIN:  begin int_3rd = 5'd3; int_5th = 5'd7; int_top = 5'd12; end
            CHORD_DOM7: begin int_3rd = 5'd4; int_5th = 5'd7; int_top = 5'd10; end
            CHORD_MIN7: begin int_3rd = 5'd3; int_5th = 5'd7; int_top = 5'd10; end
            CHORD_SUS4: begin int_3rd = 5'd5; int_5th = 5'd7; int_top = 5'd12; end
            CHORD_DIM:  begin int_3rd = 5'd3; int_5th = 5'd6; int_top = 5'd12; end
            default:    begin int_3rd = 5'd4; int_5th = 5'd7; int_top = 5'd12; end
        endcase
    end

    wire [4:0] tone0 = {1'b0, eff_root};
    wire [4:0] tone1 = {1'b0, eff_root} + int_3rd;
    wire [4:0] tone2 = {1'b0, eff_root} + int_5th;
    wire [4:0] tone3 = {1'b0, eff_root} + int_top;

    wire [4:0] bass_root  = {1'b0, eff_root};
    wire [4:0] bass_third = {1'b0, add_mod12(eff_root, int_3rd[3:0])};
    wire [4:0] bass_fifth = {1'b0, add_mod12(eff_root, int_5th[3:0])};
    wire [4:0] bass_sixth = {1'b0, add_mod12(eff_root, 4'd9)};

    // =========================================================================
    // 4. 节奏型步进序列表 (支持 4 种音乐风格: 抒情分解 / 流行律动 / 华尔兹3/4 / 动感八拍)
    // =========================================================================
    wire [2:0] max_rhythm_step = (acc_mode == 3'd3) ? 3'd5 : 3'd7;

    reg        pat_bass_trig;
    reg [4:0]  pat_bass_note;
    reg        pat_arp1_trig;
    reg [4:0]  pat_arp1_note;
    reg        pat_arp2_trig;
    reg [4:0]  pat_arp2_note;

    reg [2:0]  lookup_step;
    always @(*) begin
        pat_bass_trig = 1'b0;
        pat_bass_note = bass_root;
        pat_arp1_trig = 1'b0;
        pat_arp1_note = tone0;
        pat_arp2_trig = 1'b0;
        pat_arp2_note = tone2;

        case (acc_mode)
            3'd1: begin
                pat_arp1_trig = 1'b1;
                case (lookup_step)
                    3'd0: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone0; end
                    3'd1: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone2; end
                    3'd2: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone3; end
                    3'd3: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone1; end
                    3'd4: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone2; end
                    3'd5: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone3; end
                    3'd6: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone2; end
                    default: begin pat_bass_trig = 1'b0;                          pat_arp1_note = tone1; end
                endcase
            end

            3'd2: begin
                pat_arp1_trig = 1'b1;
                case (lookup_step)
                    3'd0: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone0; end
                    3'd1: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone2; end
                    3'd2: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone1; pat_arp2_trig = 1'b1; pat_arp2_note = tone3; end
                    3'd3: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone2; end
                    3'd4: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone0; end
                    3'd5: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone2; end
                    3'd6: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone1; pat_arp2_trig = 1'b1; pat_arp2_note = tone3; end
                    default: begin pat_bass_trig = 1'b0;                          pat_arp1_note = tone1; end
                endcase
            end

            3'd3: begin
                pat_arp1_trig = 1'b1;
                case (lookup_step)
                    3'd0: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone0; end
                    3'd1: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone1; end
                    3'd2: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone1; pat_arp2_trig = 1'b1; pat_arp2_note = tone2; end
                    3'd3: begin pat_bass_trig = 1'b0;                             pat_arp1_note = tone3; end
                    3'd4: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone2; pat_arp2_trig = 1'b1; pat_arp2_note = tone3; end
                    default: begin pat_bass_trig = 1'b0;                          pat_arp1_note = tone1; end
                endcase
            end

            3'd4: begin
                pat_arp1_trig = 1'b1;
                case (lookup_step)
                    3'd0: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone0; end
                    3'd1: begin pat_bass_trig = 1'b1; pat_bass_note = bass_root;  pat_arp1_note = tone1; end
                    3'd2: begin pat_bass_trig = 1'b1; pat_bass_note = bass_third; pat_arp1_note = tone2; end
                    3'd3: begin pat_bass_trig = 1'b1; pat_bass_note = bass_third; pat_arp1_note = tone3; end
                    3'd4: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone3; pat_arp2_trig = 1'b1; pat_arp2_note = tone1; end
                    3'd5: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone2; end
                    3'd6: begin pat_bass_trig = 1'b1; pat_bass_note = bass_sixth; pat_arp1_note = tone1; end
                    default: begin pat_bass_trig = 1'b1; pat_bass_note = bass_fifth; pat_arp1_note = tone2; end
                endcase
            end

            default: begin
                pat_bass_trig = 1'b0;
                pat_arp1_trig = 1'b0;
                pat_arp2_trig = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // 5. 演奏速度跟随器 (IOI Tempo Tracker) + 节拍状态机
    // =========================================================================
    wire [24:0] decluster_ticks = (STEP_MIN_P >> 1);
    wire [26:0] quarter_max_ioi = {1'b0, STEP_MAX_P, 1'b0};

    reg  [24:0] step_period;
    reg  [24:0] step_cnt;
    reg  [26:0] ioi_cnt;
    reg         ioi_armed;
    reg  [26:0] phrase_hold_cnt;

    wire        mode_en = (acc_mode != 3'd0) && (!auto_play_en);
    wire [2:0]  next_rhythm_step = (rhythm_step >= max_rhythm_step) ? 3'd0 : (rhythm_step + 3'd1);

    always @(*) begin
        if (!acc_active)
            lookup_step = 3'd0;
        else
            lookup_step = next_rhythm_step;
    end

    wire [24:0] arp_gate_len  = (acc_mode == 3'd1) ? (step_period - (step_period >> 3))
                                                   : (step_period - (step_period >> 2));
    wire [24:0] bass_gate_len = (acc_mode == 3'd4) ? (step_period - (step_period >> 2))
                                                   : (step_period - (step_period >> 3));

    reg [24:0] meas_step;
    always @(*) begin
        if (ioi_cnt <= {2'b00, STEP_MAX_P})
            meas_step = ioi_cnt[24:0];
        else
            meas_step = ioi_cnt[25:1];
    end

    wire [24:0] win_ticks_full = (STEP_MIN_P > 25'd2_250_000) ? 25'd2_250_000 : (STEP_MIN_P >> 1);
    reg         acc_arp2_act;

    always @(posedge clk) begin
        if (!rst_n) begin
            acc_active         <= 1'b0;
            det_root           <= 4'd0;
            det_chord_type     <= CHORD_MAJ;
            rhythm_step        <= 3'd0;
            step_period        <= STEP_DEFAULT_P;
            step_cnt           <= 25'd0;
            ioi_cnt            <= 27'd0;
            ioi_armed          <= 1'b0;
            recog_win_cnt      <= 22'd0;
            max_chroma_in_win  <= 4'd0;
            multi_chord_locked <= 1'b0;
            phrase_hold_cnt    <= 27'd0;
            acc_bass_stb       <= 1'b0;
            acc_bass_note      <= 5'd0;
            acc_bass_gate      <= 1'b0;
            acc_arp_stb        <= 1'b0;
            acc_arp_note       <= 5'd0;
            acc_arp2_stb       <= 1'b0;
            acc_arp2_note      <= 5'd4;
            acc_arp_gate       <= 1'b0;
            acc_arp2_act       <= 1'b0;
        end else begin
            acc_bass_stb <= 1'b0;
            acc_arp_stb  <= 1'b0;
            acc_arp2_stb <= 1'b0;

            if (tempo_preset_vld) begin
                case (tempo_preset_idx)
                    2'd0: step_period <= 25'd16_666_666; // 90 BPM
                    2'd1: step_period <= 25'd13_636_363; // 110 BPM
                    2'd2: step_period <= 25'd11_538_461; // 130 BPM
                    2'd3: step_period <= 25'd9_999_999;  // 150 BPM
                endcase
            end

            if (!mode_en) begin
                ioi_cnt   <= 27'd0;
                ioi_armed <= 1'b0;
            end else if (any_key_press) begin
                if (!ioi_armed) begin
                    ioi_armed <= 1'b1;
                    ioi_cnt   <= 27'd0;
                end else if (ioi_cnt >= {2'b00, decluster_ticks}) begin
                    if (ioi_cnt >= {2'b00, STEP_MIN_P} && ioi_cnt <= quarter_max_ioi) begin
                        if (meas_step < STEP_MIN_P)
                            step_period <= STEP_MIN_P;
                        else if (meas_step > STEP_MAX_P)
                            step_period <= STEP_MAX_P;
                        else
                            step_period <= step_period - (step_period >> 2) + (meas_step >> 2);
                    end
                    ioi_cnt <= 27'd0;
                end
            end else if (ioi_armed) begin
                if (ioi_cnt < quarter_max_ioi + {2'b00, STEP_MAX_P})
                    ioi_cnt <= ioi_cnt + 27'd1;
                else
                    ioi_armed <= 1'b0;
            end

            if (any_key_press) begin
                recog_win_cnt <= win_ticks_full[21:0];
                if (recog_win_cnt == 22'd0)
                    max_chroma_in_win <= chroma_cnt;
                else if (chroma_cnt > max_chroma_in_win)
                    max_chroma_in_win <= chroma_cnt;
            end else if (recog_win_cnt != 22'd0) begin
                recog_win_cnt <= recog_win_cnt - 22'd1;
                if (chroma_cnt > max_chroma_in_win)
                    max_chroma_in_win <= chroma_cnt;
            end else if (!any_key_held && !unused_rel) begin
                max_chroma_in_win <= 4'd0;
            end

            if (chord_update_cond) begin
                det_root       <= comb_root;
                det_chord_type <= comb_type;
                if (chroma_cnt >= 4'd2)
                    multi_chord_locked <= 1'b1;
            end

            if (!mode_en) begin
                acc_active         <= 1'b0;
                rhythm_step        <= 3'd0;
                step_cnt           <= 25'd0;
                phrase_hold_cnt    <= 27'd0;
                multi_chord_locked <= 1'b0;
                acc_bass_gate      <= 1'b0;
                acc_arp_gate       <= 1'b0;
                acc_arp2_act       <= 1'b0;
            end else begin
                if (any_key_held) begin
                    phrase_hold_cnt <= {step_period, 2'b00};
                end else if (phrase_hold_cnt != 27'd0) begin
                    phrase_hold_cnt <= phrase_hold_cnt - 27'd1;
                end

                if (!acc_active) begin
                    if (any_key_press || any_key_held) begin
                        acc_active    <= 1'b1;
                        rhythm_step   <= 3'd0;
                        step_cnt      <= 25'd0;
                        acc_bass_stb  <= pat_bass_trig;
                        acc_bass_note <= pat_bass_note;
                        acc_bass_gate <= pat_bass_trig;
                        acc_arp_stb   <= pat_arp1_trig;
                        acc_arp_note  <= pat_arp1_note;
                        acc_arp2_stb  <= pat_arp2_trig;
                        acc_arp2_note <= pat_arp2_note;
                        acc_arp_gate  <= pat_arp1_trig;
                        acc_arp2_act  <= pat_arp2_trig;
                    end
                end else if (!any_key_held && (phrase_hold_cnt == 27'd0)) begin
                    acc_active         <= 1'b0;
                    multi_chord_locked <= 1'b0;
                    acc_bass_gate      <= 1'b0;
                    acc_arp_gate       <= 1'b0;
                    acc_arp2_act       <= 1'b0;
                end else begin
                    if (any_key_press && (chroma_cnt >= 4'd2) && (comb_root != det_root) &&
                        (rhythm_step == 3'd0) && (step_cnt < (step_period >> 2))) begin
                        acc_bass_stb  <= 1'b1;
                        acc_bass_note <= bass_root;
                        acc_bass_gate <= 1'b1;
                        acc_arp_stb   <= 1'b1;
                        acc_arp_note  <= tone0;
                        acc_arp_gate  <= 1'b1;
                        acc_arp2_act  <= 1'b0;
                    end

                    if (step_cnt >= step_period) begin
                        step_cnt     <= 25'd0;
                        rhythm_step  <= next_rhythm_step;
                        acc_arp2_act <= pat_arp2_trig;

                        if (pat_bass_trig) begin
                            acc_bass_stb  <= 1'b1;
                            acc_bass_note <= pat_bass_note;
                            acc_bass_gate <= 1'b1;
                        end
                        if (pat_arp1_trig) begin
                            acc_arp_stb   <= 1'b1;
                            acc_arp_note  <= pat_arp1_note;
                            acc_arp_gate  <= 1'b1;
                        end
                        if (pat_arp2_trig) begin
                            acc_arp2_stb  <= 1'b1;
                            acc_arp2_note <= pat_arp2_note;
                        end
                    end else begin
                        step_cnt <= step_cnt + 25'd1;

                        if (step_cnt == arp_gate_len) begin
                            acc_arp_gate <= 1'b0;
                            acc_arp2_act <= 1'b0;
                        end
                        if (step_cnt == bass_gate_len) begin
                            if (acc_mode != 3'd1 || rhythm_step == 3'd3 || rhythm_step == 3'd7)
                                acc_bass_gate <= 1'b0;
                        end
                    end
                end
            end
        end
    end

    assign beat_pulse = acc_active && (step_cnt < (step_period >> 1));

    wire [4:0] arp1_vis_idx = (acc_arp_note  > 5'd17) ? (acc_arp_note  - 5'd12) : acc_arp_note;
    wire [4:0] arp2_vis_idx = (acc_arp2_note > 5'd17) ? (acc_arp2_note - 5'd12) : acc_arp2_note;
    wire [17:0] bass_vis_mask = acc_bass_gate ? (18'd1 << acc_bass_note[3:0]) : 18'd0;
    wire [17:0] arp1_vis_mask = acc_arp_gate  ? (18'd1 << arp1_vis_idx)       : 18'd0;
    wire [17:0] arp2_vis_mask = (acc_arp_gate && acc_arp2_act) ? (18'd1 << arp2_vis_idx) : 18'd0;

    assign acc_vis_keys = acc_active ? (bass_vis_mask | arp1_vis_mask | arp2_vis_mask) : 18'd0;
    assign acc_rec_keys = acc_active ? (arp1_vis_mask | arp2_vis_mask) : 18'd0;

endmodule

// =============================================================================
// 模块名: white_key_cap_velocity
// 适用平台: Sipeed Tang Primer 25K (GW5A-LV25MG121NC1/I0)
// 硬件拓扑:
//   - 11 个白键 (C4, D4, E4, F4, G4, A4, B4, C5, D5, E5, F5 -> K0,K2,K4,K5,K7,K9,K11,K12,K14,K16,K17)
//     内壁顶面贴有导电铜箔，引出至铜箔节点;
//   - 铜箔节点一端接 1MΩ 电阻到 GND (放电回路)，另一端经 1kΩ 电阻接 FPGA 引脚 vel_io[10:0]:
//     vel_io[0..10] 依次对应 H4, J2, D1, A1, F1, C2, L3, G1, K4, L1, K2。
// 测速原理 (电容隔空接近 t1 + 机械开关触底 t2 双时间戳测速):
//   1. 每 250us (12,500 clocks @50MHz) 执行一次充放电测量循环:
//      - 前 10us (500 clocks): FPGA 输出高电平 (3.3V) 经 1kΩ 电阻将铜箔电容充满;
//      - 后 240us (12,000 clocks): FPGA 切换为高阻输入 (1'bz)，电容经 1MΩ 电阻向 GND 放电，
//        以 50MHz 时钟精确计数引脚电平从 1 跌落到 V_TH (~1.5V) 所需的时钟周期数。
//   2. 连续 4 次放电计数累加为 1ms 采样值 meas_4x (等效 200MHz / 5ns 时间分辨率):
//      - 自动跟踪每个白键的静态寄生电容基线 base_4x[i];
//      - 当手指下落进入距离琴键表面 3~5mm 耦合区时，耦合电容增加约 0.5~2pF，
//        meas_4x[i] 超过动态阈值 th_prox，触发 t1 接近事件并启动毫秒计时器 flight_ms[i];
//      - 当手指继续下压将机械轻触开关按到底 (key_press_evt 触发 t2) 时，读取时间差
//        Δt = t2 - t1: 重敲时 Δt 短 (3~10ms) 映射为高力度 (103~127)；轻按时 Δt 长
//        (40~85ms) 映射为低力度 (36~78)。
//   3. 双轨物理隔离与容错:
//      - 发声触发 100% 由机械开关决定，铜箔仅决定触键力度，绝不误触发鬼音;
//      - 若某键未接铜箔/电阻，自动识别并回退至标准饱满力度 (100);
//      - 7 个黑键完全独立于白键铜箔测速（黑键不受影响），始终以标准饱满力度 (100) 纯净发声。
// =============================================================================
module white_key_cap_velocity (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [17:0]  key_state,
    input  wire [17:0]  key_press_evt,
    input  wire [17:0]  remote_keys,
    input  wire         auto_play_en,
    inout  wire [10:0]  vel_io,
    output wire [125:0] key_vel_flat,
    output reg  [6:0]   last_vel
);

    // 11 个白键对应的 18 键索引:
    // ch0->K0(C4), ch1->K2(D4), ch2->K4(E4), ch3->K5(F4), ch4->K7(G4), ch5->A4(K9),
    // ch6->K11(B4), ch7->K12(C5), ch8->K14(D5), ch9->K16(E5), ch10->K17(F5)
    wire [10:0] wkey_held = {
        key_state[17], key_state[16], key_state[14], key_state[12],
        key_state[11], key_state[9],  key_state[7],  key_state[5],
        key_state[4],  key_state[2],  key_state[0]
    };

    wire [10:0] wkey_press = {
        key_press_evt[17], key_press_evt[16], key_press_evt[14], key_press_evt[12],
        key_press_evt[11], key_press_evt[9],  key_press_evt[7],  key_press_evt[5],
        key_press_evt[4],  key_press_evt[2],  key_press_evt[0]
    };

    wire [10:0] wkey_remote = {
        remote_keys[17], remote_keys[16], remote_keys[14], remote_keys[12],
        remote_keys[11], remote_keys[9],  remote_keys[7],  remote_keys[5],
        remote_keys[4],  remote_keys[2],  remote_keys[0]
    };

    // 250us 充放电周期计数器 (0..12499 @50MHz)
    reg [13:0] cyc_cnt;
    reg [1:0]  sub_cnt;
    reg [3:0]  drift_div;
    wire       chg_phase = (cyc_cnt < 14'd500); // 前 10us 充电，后 240us 高阻放电测量
    wire       cyc_end   = (cyc_cnt == 14'd12499);

    reg [10:0] rc_valid_ch;

    // 三态驱动: 仅在未按下、非自动播放且检测到有效RC通路时输出充电脉冲，彻底阻断 4kHz 充放电脉冲对音频的串扰
    genvar gi;
    generate
        for (gi = 0; gi < 11; gi = gi + 1) begin : gen_vel_io
            assign vel_io[gi] = (chg_phase && !auto_play_en && !wkey_held[gi] && (!base_init[gi] || rc_valid_ch[gi])) ? 1'b1 : 1'bz;
        end
    endgenerate

    // 两级同步器消除充放电阈值跨越亚稳态
    reg [10:0] pin_s1, pin_s2;
    always @(posedge clk) begin
        if (!rst_n) begin
            pin_s1 <= 11'd0;
            pin_s2 <= 11'd0;
        end else begin
            pin_s1 <= vel_io;
            pin_s2 <= pin_s1;
        end
    end

    reg [11:0] rc_cnt    [0:10];
    reg [13:0] acc_4x    [0:10];
    reg [13:0] base_4x   [0:10];
    reg [10:0] base_init;
    reg [10:0] prox_on;
    reg [7:0]  flight_ms [0:10];
    reg [7:0]  close_ms  [0:10];
    reg [6:0]  wkey_vel  [0:10];
    reg [6:0]  key_vel   [0:17];

    // 充电期前 11 个时钟周期 (cyc_cnt = 1..11) 串行分时复用处理 11 个白键通道，节省约 2500 个 LUT!
    wire       seq_en = (cyc_cnt >= 14'd1) && (cyc_cnt <= 14'd11);
    wire [3:0] seq_ch = cyc_cnt[3:0] - 4'd1;

    wire [13:0] ch_acc   = acc_4x[seq_ch];
    wire [11:0] ch_rc    = rc_cnt[seq_ch];
    wire [13:0] cur_meas = ch_acc + {2'b00, ch_rc};
    wire [13:0] cur_base = base_4x[seq_ch];
    wire [13:0] th_prox  = (cur_base >> 5) + 14'd14;
    wire [13:0] th_close = (cur_base >> 4) + 14'd32;
    wire [13:0] delta_c  = (cur_meas > cur_base) ? (cur_meas - cur_base) : 14'd0;

    wire        ch_init   = base_init[seq_ch];
    wire        ch_prox   = prox_on[seq_ch];
    wire [7:0]  ch_flight = flight_ms[seq_ch];
    wire [7:0]  ch_close  = close_ms[seq_ch];

    wire        next_prox   = (delta_c >= th_prox) ? 1'b1 : ((delta_c < (th_prox >> 1)) ? 1'b0 : ch_prox);
    wire [7:0]  next_flight = (delta_c >= th_prox) ? ((ch_flight < 8'd255) ? (ch_flight + 8'd1) : 8'd255) :
                              ((delta_c < (th_prox >> 1)) ? 8'd0 : ch_flight);
    wire [7:0]  next_close  = (delta_c >= th_prox) ? ((delta_c >= th_close) ? ((ch_close < 8'd255) ? (ch_close + 8'd1) : 8'd255) : 8'd0) :
                              ((delta_c < (th_prox >> 1)) ? 8'd0 : ch_close);

    wire        rc_ok  = ch_init && (cur_base >= 14'd32) && (cur_base <= 14'd15500);
    wire [7:0]  eff_dt = (next_flight > 8'd90 && next_close > 8'd0 && next_close <= 8'd65)
                         ? next_close : next_flight;

    reg [6:0] calc_vel;
    always @(*) begin
        if (auto_play_en || !rc_ok || !next_prox) begin
            calc_vel = 7'd100;
        end else if (eff_dt <= 8'd6) begin
            calc_vel = 7'd127; // Δt <= 6ms: 极强重击 (127)
        end else if (eff_dt <= 8'd18) begin
            calc_vel = 7'd127 - ((eff_dt[6:0] - 7'd6) << 1); // 7..18ms -> 103..125
        end else if (eff_dt <= 8'd42) begin
            calc_vel = 7'd103 - (eff_dt[6:0] - 7'd18);        // 19..42ms -> 79..102
        end else if (eff_dt <= 8'd85) begin
            calc_vel = 7'd79  - (eff_dt[6:0] - 7'd42);        // 43..85ms -> 36..78
        end else begin
            calc_vel = 7'd36;  // Δt > 85ms: 极弱轻按 (36)
        end
    end

    integer ci;

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc_cnt   <= 14'd0;
            sub_cnt   <= 2'd0;
            drift_div <= 4'd0;
            base_init   <= 11'd0;
            rc_valid_ch <= 11'h7FF;
            prox_on     <= 11'd0;
            last_vel  <= 7'd100;
            for (ci = 0; ci < 11; ci = ci + 1) begin
                rc_cnt[ci]    <= 12'd0;
                acc_4x[ci]    <= 14'd0;
                base_4x[ci]   <= 14'd1024;
                flight_ms[ci] <= 8'd0;
                close_ms[ci]  <= 8'd0;
                wkey_vel[ci]  <= 7'd100;
            end
            for (ci = 0; ci < 18; ci = ci + 1) begin
                key_vel[ci] <= 7'd100;
            end
        end else begin
            // 1. 250us 充放电计时循环
            if (cyc_end) begin
                cyc_cnt <= 14'd0;
                sub_cnt <= sub_cnt + 2'd1;
                if (sub_cnt == 2'd3)
                    drift_div <= drift_div + 4'd1;
            end else begin
                cyc_cnt <= cyc_cnt + 14'd1;
            end

            // 2. 放电期 11 通道并行计数，充电期第 16 拍统一清零
            if (cyc_cnt == 14'd16) begin
                for (ci = 0; ci < 11; ci = ci + 1)
                    rc_cnt[ci] <= 12'd0;
            end else if (!chg_phase && cyc_cnt >= 14'd502 && !cyc_end) begin
                for (ci = 0; ci < 11; ci = ci + 1) begin
                    if (pin_s2[ci] && (rc_cnt[ci] < 12'd4095))
                        rc_cnt[ci] <= rc_cnt[ci] + 12'd1;
                end
            end

            // 3. 充电期前 11 拍 (cyc_cnt = 1..11) 单算术流水线串行更新 11 个通道
            if (seq_en) begin
                if (sub_cnt != 2'd0) begin
                    if (sub_cnt == 2'd1)
                        acc_4x[seq_ch] <= {2'b00, ch_rc};
                    else
                        acc_4x[seq_ch] <= cur_meas;
                end else begin
                    acc_4x[seq_ch] <= 14'd0;
                    if (!ch_init) begin
                        base_4x[seq_ch]     <= cur_meas;
                        base_init[seq_ch]   <= 1'b1;
                        rc_valid_ch[seq_ch] <= (cur_meas >= 14'd32) && (cur_meas <= 14'd15500);
                        wkey_vel[seq_ch]    <= 7'd100;
                    end else begin
                        if (!wkey_held[seq_ch]) begin
                            if (cur_meas < cur_base)
                                base_4x[seq_ch] <= cur_base - ((cur_base - cur_meas) >> 2) - 14'd1;
                            else if (delta_c < th_prox && drift_div == 4'd15)
                                base_4x[seq_ch] <= cur_base + 14'd1;
                        end
                        if (!wkey_press[seq_ch]) begin
                            prox_on[seq_ch]   <= next_prox;
                            flight_ms[seq_ch] <= next_flight;
                            close_ms[seq_ch]  <= next_close;
                            wkey_vel[seq_ch]  <= calc_vel;
                        end
                    end
                end
            end

            // 4. t2 机械开关或远程虚拟按键触发瞬间: 锁存各键力度并清零该键飞行计时器
            if (key_press_evt[0])  begin key_vel[0]  <= (auto_play_en || wkey_remote[0])  ? 7'd100 : wkey_vel[0];  last_vel <= (auto_play_en || wkey_remote[0])  ? 7'd100 : wkey_vel[0];  flight_ms[0]  <= 8'd0; close_ms[0]  <= 8'd0; wkey_vel[0]  <= 7'd100; end
            if (key_press_evt[2])  begin key_vel[2]  <= (auto_play_en || wkey_remote[1])  ? 7'd100 : wkey_vel[1];  last_vel <= (auto_play_en || wkey_remote[1])  ? 7'd100 : wkey_vel[1];  flight_ms[1]  <= 8'd0; close_ms[1]  <= 8'd0; wkey_vel[1]  <= 7'd100; end
            if (key_press_evt[4])  begin key_vel[4]  <= (auto_play_en || wkey_remote[2])  ? 7'd100 : wkey_vel[2];  last_vel <= (auto_play_en || wkey_remote[2])  ? 7'd100 : wkey_vel[2];  flight_ms[2]  <= 8'd0; close_ms[2]  <= 8'd0; wkey_vel[2]  <= 7'd100; end
            if (key_press_evt[5])  begin key_vel[5]  <= (auto_play_en || wkey_remote[3])  ? 7'd100 : wkey_vel[3];  last_vel <= (auto_play_en || wkey_remote[3])  ? 7'd100 : wkey_vel[3];  flight_ms[3]  <= 8'd0; close_ms[3]  <= 8'd0; wkey_vel[3]  <= 7'd100; end
            if (key_press_evt[7])  begin key_vel[7]  <= (auto_play_en || wkey_remote[4])  ? 7'd100 : wkey_vel[4];  last_vel <= (auto_play_en || wkey_remote[4])  ? 7'd100 : wkey_vel[4];  flight_ms[4]  <= 8'd0; close_ms[4]  <= 8'd0; wkey_vel[4]  <= 7'd100; end
            if (key_press_evt[9])  begin key_vel[9]  <= (auto_play_en || wkey_remote[5])  ? 7'd100 : wkey_vel[5];  last_vel <= (auto_play_en || wkey_remote[5])  ? 7'd100 : wkey_vel[5];  flight_ms[5]  <= 8'd0; close_ms[5]  <= 8'd0; wkey_vel[5]  <= 7'd100; end
            if (key_press_evt[11]) begin key_vel[11] <= (auto_play_en || wkey_remote[6])  ? 7'd100 : wkey_vel[6];  last_vel <= (auto_play_en || wkey_remote[6])  ? 7'd100 : wkey_vel[6];  flight_ms[6]  <= 8'd0; close_ms[6]  <= 8'd0; wkey_vel[6]  <= 7'd100; end
            if (key_press_evt[12]) begin key_vel[12] <= (auto_play_en || wkey_remote[7])  ? 7'd100 : wkey_vel[7];  last_vel <= (auto_play_en || wkey_remote[7])  ? 7'd100 : wkey_vel[7];  flight_ms[7]  <= 8'd0; close_ms[7]  <= 8'd0; wkey_vel[7]  <= 7'd100; end
            if (key_press_evt[14]) begin key_vel[14] <= (auto_play_en || wkey_remote[8])  ? 7'd100 : wkey_vel[8];  last_vel <= (auto_play_en || wkey_remote[8])  ? 7'd100 : wkey_vel[8];  flight_ms[8]  <= 8'd0; close_ms[8]  <= 8'd0; wkey_vel[8]  <= 7'd100; end
            if (key_press_evt[16]) begin key_vel[16] <= (auto_play_en || wkey_remote[9])  ? 7'd100 : wkey_vel[9];  last_vel <= (auto_play_en || wkey_remote[9])  ? 7'd100 : wkey_vel[9];  flight_ms[9]  <= 8'd0; close_ms[9]  <= 8'd0; wkey_vel[9]  <= 7'd100; end
            if (key_press_evt[17]) begin key_vel[17] <= (auto_play_en || wkey_remote[10]) ? 7'd100 : wkey_vel[10]; last_vel <= (auto_play_en || wkey_remote[10]) ? 7'd100 : wkey_vel[10]; flight_ms[10] <= 8'd0; close_ms[10] <= 8'd0; wkey_vel[10] <= 7'd100; end

            // 7 个黑键独立触发: 固定使用标准饱满力度 (100)，完全不受白键铜箔测速影响
            if (key_press_evt[1])  key_vel[1]  <= 7'd100;
            if (key_press_evt[3])  key_vel[3]  <= 7'd100;
            if (key_press_evt[6])  key_vel[6]  <= 7'd100;
            if (key_press_evt[8])  key_vel[8]  <= 7'd100;
            if (key_press_evt[10]) key_vel[10] <= 7'd100;
            if (key_press_evt[13]) key_vel[13] <= 7'd100;
            if (key_press_evt[15]) key_vel[15] <= 7'd100;
        end
    end

    assign key_vel_flat = {
        key_vel[17], key_vel[16], key_vel[15], key_vel[14], key_vel[13], key_vel[12],
        key_vel[11], key_vel[10], key_vel[9],  key_vel[8],  key_vel[7],  key_vel[6],
        key_vel[5],  key_vel[4],  key_vel[3],  key_vel[2],  key_vel[1],  key_vel[0]
    };

endmodule
