// =============================================================================
// 文件名: key_encoder_input.v
// 模块功能: 18 键消抖、双路 EC11 编码器旋转解码与按键消抖、四大切屏模式切换 + 子项切换 + 蓝牙/触控联动
// 操作逻辑说明:
//   - 旋转编码器 1 (A=F5, B=G7, SW=H8):
//       * 旋转: 专职调节 16 级主音量 (开机默认 8 档，针对 PAM8403 甜区优化，洪亮纯净无底噪)
//       * 按压 SW (Pin H8): 等效 S1 键功能! 循环切换 4 大切屏工作模式:
//         [0:手动演奏页] -> [1:曲目点播页] -> [2:智能伴奏页] -> [3:音色效果页]
//   - 旋转编码器 2 (A=G5, B=G8, SW=H7):
//       * 旋转: 专职切换 12 种乐器音色 (00~11 循环)
//       * 按压 SW (Pin H7): 等效 S2 键功能! 根据当前所在的切屏页面切换对应子项:
//         - 在 [0:手动演奏页]: 切换频谱/李萨如示波器显示布局
//         - 在 [1:曲目点播页]: 切换并播放第 01~05 首示范曲
//         - 在 [2:智能伴奏页]: 切换第 01~04 种伴奏节奏型
//         - 在 [3:音色效果页]: 切换当前音色的专属空间效果搭配
//   - 编码器 1 SW + 编码器 2 SW 同时按住 (或 S1 + S2 同时按住): 启动 3 点触摸屏校准向导
// =============================================================================

module key_encoder_input (
    input  wire        clk,              // 50MHz 系统时钟 (Pin E2)
    input  wire        rst_n,            // 低电平有效同步复位
    input  wire        s1_autoplay_btn,  // Dock 底板 S1 键 (Pin H11, 切换 4 大切屏模式)
    input  wire        s2_song_btn,      // Dock 底板 S2 键 (Pin H10, 切换当前切屏下的子项)
    input  wire [1:0]  active_page,      // 当前触摸屏所在切屏页码 (0=演奏, 1=曲目, 2=伴奏, 3=音色效果)
    input  wire        song_auto_next,   // 曲目演完自动切下一首脉冲
    input  wire        cmd_play_user,    // 蓝牙指令 'P': 立即进入曲目模式并播放用户曲目 (Song 4)
    input  wire        cmd_stop,         // 蓝牙指令 'S': 停止自动演奏并回到手动演奏模式
    input  wire        cmd_song_vld,     // 蓝牙指令 "M0"~"M5": 进入曲目模式并切换到指定曲目
    input  wire [2:0]  cmd_song_idx,
    input  wire        cmd_timbre_vld,   // 蓝牙指令 "T0"~"TD"/"T+"/"T-": 切换音色
    input  wire [3:0]  cmd_timbre,
    input  wire        cmd_vol_vld,      // 蓝牙指令 "V0"~"VF": 调节 16 级音量
    input  wire [3:0]  cmd_vol,
    input  wire        cmd_vol_step_vld, // 蓝牙指令 "V+"/"V-": 音量步进增减脉冲
    input  wire        cmd_vol_up,       // 1=音量+1, 0=音量-1
    input  wire        cmd_vib_vld,      // 蓝牙指令 Y: 颤音控制
    input  wire        cmd_vib_on,
    input  wire        cmd_glide_vld,    // 蓝牙指令 Z: 滑音控制
    input  wire        cmd_glide_on,
    input  wire        cmd_acc_vld,      // 蓝牙指令 B0~B5: 智能伴奏模式切换脉冲
    input  wire [2:0]  cmd_acc_mode,     // 0=关(回手动模式), 1..4=指定伴奏模式, 5=循环下一节奏型
    input  wire        cmd_scene_vld,    // 蓝牙指令 A0~A4 / 触屏顶栏切屏脉冲
    input  wire [2:0]  cmd_scene,
    input  wire [17:0] keys_raw_n,       // 18 个琴键输入 (含自动演奏叠加信号, 低有效)
    input  wire        enc1_a,           // 编码器 1 A 相 (Pin F5, 旋转调节音量)
    input  wire        enc1_b,           // 编码器 1 B 相 (Pin G7)
    input  wire        enc1_sw_n,        // 编码器 1 SW 按键 (Pin H8, 低有效, 替换为 S1 功能: 切屏/切模式)
    input  wire        enc2_a,           // 编码器 2 A 相 (Pin G5, 旋转切换音色 0~11)
    input  wire        enc2_b,           // 编码器 2 B 相 (Pin G8)
    input  wire        enc2_sw_n,        // 编码器 2 SW 按键 (Pin H7, 低有效, 替换为 S2 功能: 切换当前页子项)
    output reg  [17:0] key_state,        // 消抖后按键状态 (高有效: 1=按下)
    output reg  [17:0] key_press_evt,    // 单周期按键按下触发脉冲
    output reg  [17:0] key_rel_evt,      // 单周期按键释放触发脉冲
    output reg  [3:0]  volume,           // 音量等级 0~15 (开机默认 8)
    output reg  [3:0]  timbre_idx,       // 音色编号 0~11 (默认 0)
    output reg         vibrato_en,       // 蓝牙颤音开关状态
    output reg         portamento_en,    // 蓝牙滑音开关状态
    output reg  [1:0]  sys_mode,         // 当前系统模式: 0=手动演奏, 1=曲目点播, 2=伴奏模式, 3=音色效果
    output reg         auto_play_en,     // 自动演奏开关状态
    output reg  [2:0]  song_idx,         // 当前曲目编号 0~4
    output reg         song_restart_stb, // 切歌或重新开始演奏脉冲
    output reg  [2:0]  acc_mode,         // 实际生效的智能伴奏模式: 0=关, 1=抒情分解, 2=流行律动, 3=华尔兹3/4, 4=动感八拍
    output reg         s2_fx_step_stb,   // 在音色效果页按 S2/编码器2SW 触发的效果搭配切换脉冲
    output reg         s2_disp_step_stb  // 在手动演奏页按 S2/编码器2SW 触发的示波器视图切换脉冲
);

    reg [17:0] keys_sync0;
    reg [17:0] keys_sync1;
    reg [2:0]  e1_a_sync;
    reg [2:0]  e1_b_sync;
    reg [2:0]  e1_sw_sync;
    reg [2:0]  e2_a_sync;
    reg [2:0]  e2_b_sync;
    reg [2:0]  e2_sw_sync;
    reg [2:0]  s1_sync;
    reg [2:0]  s2_sync;

    // 将编码器 1 SW (~enc1_sw_n) 与 S1 (s1_autoplay_btn) 硬件并联，编码器 2 SW (~enc2_sw_n) 与 S2 (s2_song_btn) 硬件并联
    always @(posedge clk) begin
        if (!rst_n) begin
            keys_sync0 <= 18'h3FFFF;
            keys_sync1 <= 18'h3FFFF;
            e1_a_sync  <= 3'b111;
            e1_b_sync  <= 3'b111;
            e1_sw_sync <= 3'b111;
            e2_a_sync  <= 3'b111;
            e2_b_sync  <= 3'b111;
            e2_sw_sync <= 3'b111;
            s1_sync    <= 3'b000;
            s2_sync    <= 3'b000;
        end else begin
            keys_sync0 <= keys_raw_n;
            keys_sync1 <= keys_sync0;
            e1_a_sync  <= {e1_a_sync[1:0],  enc1_a};
            e1_b_sync  <= {e1_b_sync[1:0],  enc1_b};
            e1_sw_sync <= {e1_sw_sync[1:0], enc1_sw_n};
            e2_a_sync  <= {e2_a_sync[1:0],  enc2_a};
            e2_b_sync  <= {e2_b_sync[1:0],  enc2_b};
            e2_sw_sync <= {e2_sw_sync[1:0], enc2_sw_n};
            s1_sync    <= {s1_sync[1:0],    s1_autoplay_btn};
            s2_sync    <= {s2_sync[1:0],    s2_song_btn};
        end
    end

    wire btn1_raw = s1_sync[2] | (~e1_sw_sync[2]); // S1 或 编码器1按下
    wire btn2_raw = s2_sync[2] | (~e2_sw_sync[2]); // S2 或 编码器2按下

    reg [12:0] tick_150us;
    wire       sample_150us = (tick_150us == 13'd7499);
    reg [14:0] tick_500us;
    wire       sample_500us = (tick_500us == 15'd24999);

    always @(posedge clk) begin
        if (!rst_n) begin
            tick_150us <= 13'd0;
            tick_500us <= 15'd0;
        end else begin
            tick_150us <= sample_150us ? 13'd0 : (tick_150us + 13'd1);
            tick_500us <= sample_500us ? 15'd0 : (tick_500us + 15'd1);
        end
    end

    reg [17:0] k_s0;
    reg [17:0] k_s1;
    reg [17:0] k_s2;
    reg [17:0] k_s3;
    reg [17:0] key_state_d;
    wire [17:0] keys_active = ~keys_sync1;
    wire [17:0] stable_high = k_s0 & k_s1 & k_s2 & k_s3;
    wire [17:0] stable_low  = ~(k_s0 | k_s1 | k_s2 | k_s3);

    always @(posedge clk) begin
        if (!rst_n) begin
            k_s0          <= 18'd0;
            k_s1          <= 18'd0;
            k_s2          <= 18'd0;
            k_s3          <= 18'd0;
            key_state     <= 18'd0;
            key_state_d   <= 18'd0;
            key_press_evt <= 18'd0;
            key_rel_evt   <= 18'd0;
        end else begin
            if (sample_500us) begin
                k_s0 <= keys_active;
                k_s1 <= k_s0;
                k_s2 <= k_s1;
                k_s3 <= k_s2;
            end
            key_state     <= (key_state & ~stable_low) | stable_high;
            key_state_d   <= key_state;
            key_press_evt <=  key_state & ~key_state_d;
            key_rel_evt   <= ~key_state &  key_state_d;
        end
    end

    reg [3:0] e1a_sh, e1b_sh;
    reg [3:0] e2a_sh, e2b_sh;
    reg       e1a_clean, e1b_clean, e1a_clean_d;
    reg       e2a_clean, e2b_clean, e2a_clean_d;

    reg [6:0] s1_cnt, s2_cnt;
    reg       s1_clean, s1_clean_d;
    reg       s2_clean, s2_clean_d;
    reg       s1_pend,  s2_pend;
    reg [7:0] s1_guard, s2_guard;
    reg       s12_combo;

    reg [2:0] acc_sub_mode;

    wire [3:0] timbre_inc  = (timbre_idx >= 4'd11) ? 4'd0  : (timbre_idx + 4'd1);
    wire [3:0] timbre_dec  = (timbre_idx == 4'd0 || timbre_idx > 4'd11) ? 4'd11 : (timbre_idx - 4'd1);
    wire [2:0] acc_sub_inc = (acc_sub_mode >= 3'd4 || acc_sub_mode == 3'd0) ? 3'd1 : (acc_sub_mode + 3'd1);
    wire [2:0] song_inc    = (song_idx >= 3'd4) ? 3'd0 : (song_idx + 3'd1);
    wire [1:0] next_mode   = active_page + 2'd1;

    wire       both_pressed = (btn1_raw & btn2_raw) | (s1_clean & s2_clean);
    wire       s1_fire      = s1_pend && !both_pressed && !s12_combo && ((s1_guard >= 8'd160) || (!s1_clean && s1_clean_d));
    wire       s2_fire      = s2_pend && !both_pressed && !s12_combo && ((s2_guard >= 8'd160) || (!s2_clean && s2_clean_d));

    always @(posedge clk) begin
        if (!rst_n) begin
            volume           <= 4'd8;  // 开机默认中档位置 (8/15)，针对 PAM8403 增益甜区优化，纯净无底噪
            timbre_idx       <= 4'd0;  // 默认 00 三角钢琴
            vibrato_en       <= 1'b0;
            portamento_en    <= 1'b0;
            sys_mode         <= 2'd0;  // 开机默认切屏 0: 手动演奏页
            auto_play_en     <= 1'b0;
            song_idx         <= 3'd0;
            song_restart_stb <= 1'b0;
            acc_sub_mode     <= 3'd1;  // 伴奏模式默认子项: 01 抒情分解和弦
            acc_mode         <= 3'd0;  // 手动演奏模式下伴奏默认关闭
            s2_fx_step_stb   <= 1'b0;
            s2_disp_step_stb <= 1'b0;
            e1a_sh           <= 4'hF;
            e1b_sh           <= 4'hF;
            e2a_sh           <= 4'hF;
            e2b_sh           <= 4'hF;
            e1a_clean        <= 1'b1;
            e1b_clean        <= 1'b1;
            e1a_clean_d      <= 1'b1;
            e2a_clean        <= 1'b1;
            e2b_clean        <= 1'b1;
            e2a_clean_d      <= 1'b1;
            s1_cnt           <= 7'd0;
            s2_cnt           <= 7'd0;
            s1_clean         <= 1'b0;
            s1_clean_d       <= 1'b0;
            s2_clean         <= 1'b0;
            s2_clean_d       <= 1'b0;
            s1_pend          <= 1'b0;
            s2_pend          <= 1'b0;
            s1_guard         <= 8'd0;
            s2_guard         <= 8'd0;
            s12_combo        <= 1'b0;
        end else begin
            song_restart_stb <= 1'b0;
            s2_fx_step_stb   <= 1'b0;
            s2_disp_step_stb <= 1'b0;

            // 1. 蓝牙/触屏曲目与伴奏指令联动
            if (cmd_play_user) begin
                sys_mode         <= 2'd1;
                auto_play_en     <= 1'b1;
                acc_mode         <= 3'd0;
                song_idx         <= 3'd4;
                song_restart_stb <= 1'b1;
            end else if (cmd_stop) begin
                auto_play_en     <= 1'b0;
                song_restart_stb <= 1'b1;
            end else if (cmd_song_vld) begin
                sys_mode         <= 2'd1;
                auto_play_en     <= 1'b1;
                acc_mode         <= 3'd0;
                song_idx         <= (cmd_song_idx <= 3'd4) ? cmd_song_idx : song_inc;
                song_restart_stb <= 1'b1;
            end else if (song_auto_next && auto_play_en) begin
                song_idx <= song_inc;
            end

            if (cmd_acc_vld) begin
                if (cmd_acc_mode == 3'd0) begin
                    acc_mode     <= 3'd0;
                end else if (cmd_acc_mode <= 3'd4) begin
                    auto_play_en <= 1'b0;
                    acc_sub_mode <= cmd_acc_mode;
                    acc_mode     <= cmd_acc_mode;
                end else begin
                    auto_play_en <= 1'b0;
                    acc_sub_mode <= acc_sub_inc;
                    acc_mode     <= acc_sub_inc;
                end
            end else if (cmd_scene_vld) begin
                case (cmd_scene)
                    3'd0: begin sys_mode <= 2'd0; auto_play_en <= 1'b0; song_restart_stb <= 1'b1; end
                    3'd1: begin sys_mode <= 2'd1; auto_play_en <= 1'b1; acc_mode <= 3'd0; song_restart_stb <= 1'b1; end
                    3'd2: begin sys_mode <= 2'd2; auto_play_en <= 1'b0; acc_mode <= acc_sub_mode; song_restart_stb <= 1'b1; end
                    3'd3: begin sys_mode <= 2'd3; auto_play_en <= 1'b0; song_restart_stb <= 1'b1; end
                    default: begin
                        sys_mode <= next_mode;
                        case (next_mode)
                            2'd0: begin auto_play_en <= 1'b0; song_restart_stb <= 1'b1; end
                            2'd1: begin auto_play_en <= 1'b1; acc_mode <= 3'd0; song_restart_stb <= 1'b1; end
                            2'd2: begin auto_play_en <= 1'b0; acc_mode <= acc_sub_mode; song_restart_stb <= 1'b1; end
                            default: begin auto_play_en <= 1'b0; song_restart_stb <= 1'b1; end
                        endcase
                    end
                endcase
            end

            // 2. 音色/音量/表现力指令
            if (cmd_timbre_vld) begin
                if (cmd_timbre <= 4'd11)
                    timbre_idx <= cmd_timbre;
                else if (cmd_timbre == 4'd12)
                    timbre_idx <= timbre_inc;
                else if (cmd_timbre == 4'd13)
                    timbre_idx <= timbre_dec;
                else
                    timbre_idx <= cmd_timbre - 4'd12;
            end

            if (cmd_vol_vld) begin
                volume <= cmd_vol;
            end else if (cmd_vol_step_vld) begin
                if (cmd_vol_up) begin
                    if (volume < 4'd15) volume <= volume + 4'd1;
                end else begin
                    if (volume > 4'd0)  volume <= volume - 4'd1;
                end
            end

            if (cmd_vib_vld)   vibrato_en    <= cmd_vib_on;
            if (cmd_glide_vld) portamento_en <= cmd_glide_on;

            // 3. 150us 编码器与按键消抖状态机
            if (sample_150us) begin
                e1a_sh <= {e1a_sh[2:0], e1_a_sync[2]};
                e1b_sh <= {e1b_sh[2:0], e1_b_sync[2]};
                e2a_sh <= {e2a_sh[2:0], e2_a_sync[2]};
                e2b_sh <= {e2b_sh[2:0], e2_b_sync[2]};

                if (e1a_sh == 4'hF) e1a_clean <= 1'b1;
                else if (e1a_sh == 4'h0) e1a_clean <= 1'b0;
                if (e1b_sh == 4'hF) e1b_clean <= 1'b1;
                else if (e1b_sh == 4'h0) e1b_clean <= 1'b0;

                if (e2a_sh == 4'hF) e2a_clean <= 1'b1;
                else if (e2a_sh == 4'h0) e2a_clean <= 1'b0;
                if (e2b_sh == 4'hF) e2b_clean <= 1'b1;
                else if (e2b_sh == 4'h0) e2b_clean <= 1'b0;

                e1a_clean_d <= e1a_clean;
                e2a_clean_d <= e2a_clean;

                // 旋转编码器 1 (F5/G7): 专职调节 16 级音量 (0~15)
                if (!e1a_clean && e1a_clean_d) begin
                    if (e1b_clean) begin
                        if (volume < 4'd15) volume <= volume + 4'd1;
                    end else begin
                        if (volume > 4'd0)  volume <= volume - 4'd1;
                    end
                end else if (e1a_clean && !e1a_clean_d) begin
                    if (!e1b_clean) begin
                        if (volume < 4'd15) volume <= volume + 4'd1;
                    end else begin
                        if (volume > 4'd0)  volume <= volume - 4'd1;
                    end
                end

                // 旋转编码器 2 (G5/G8): 专职切换 12 种音色 (00~11)
                if (!e2a_clean && e2a_clean_d) begin
                    if (e2b_clean)
                        timbre_idx <= timbre_inc;
                    else
                        timbre_idx <= timbre_dec;
                end else if (e2a_clean && !e2a_clean_d) begin
                    if (!e2b_clean)
                        timbre_idx <= timbre_inc;
                    else
                        timbre_idx <= timbre_dec;
                end

                // 按键 1 (S1 或 编码器 1 SW 按下) 与 按键 2 (S2 或 编码器 2 SW 按下) 消抖
                if (btn1_raw != s1_clean) begin
                    if (s1_cnt == 7'd50) begin s1_clean <= btn1_raw; s1_cnt <= 7'd0; end
                    else s1_cnt <= s1_cnt + 7'd1;
                end else s1_cnt <= 7'd0;

                if (btn2_raw != s2_clean) begin
                    if (s2_cnt == 7'd50) begin s2_clean <= btn2_raw; s2_cnt <= 7'd0; end
                    else s2_cnt <= s2_cnt + 7'd1;
                end else s2_cnt <= 7'd0;

                s1_clean_d <= s1_clean;
                s2_clean_d <= s2_clean;

                // 双键同按校准防误触保护 (24ms 组合检测窗)
                if (both_pressed) begin
                    s12_combo <= 1'b1;
                    s1_pend   <= 1'b0;
                    s2_pend   <= 1'b0;
                    s1_guard  <= 8'd0;
                    s2_guard  <= 8'd0;
                end else if (!s1_clean && !s2_clean && !btn1_raw && !btn2_raw) begin
                    s12_combo <= 1'b0;
                end

                if (s1_clean && !s1_clean_d && !both_pressed && !s12_combo) begin
                    s1_pend  <= 1'b1;
                    s1_guard <= 8'd0;
                end else if (s1_pend && s1_clean && !both_pressed && !s12_combo) begin
                    s1_guard <= s1_guard + 8'd1;
                end

                if (s2_clean && !s2_clean_d && !both_pressed && !s12_combo) begin
                    s2_pend  <= 1'b1;
                    s2_guard <= 8'd0;
                end else if (s2_pend && s2_clean && !both_pressed && !s12_combo) begin
                    s2_guard <= s2_guard + 8'd1;
                end

                // =============================================================
                // 编码器 1 按下 (H8) 或 S1 (H11): 循环切换 4 大切屏工作模式
                //   0: 手动演奏页 -> 1: 曲目点播页 -> 2: 智能伴奏页 -> 3: 音色效果页
                // =============================================================
                if (s1_fire) begin
                    s1_pend  <= 1'b0;
                    s1_guard <= 8'd0;
                    sys_mode <= next_mode;
                    case (next_mode)
                        2'd0: begin // 切入【0: 手动演奏页】
                            auto_play_en     <= 1'b0;
                            song_restart_stb <= 1'b1;
                        end
                        2'd1: begin // 切入【1: 曲目点播页】
                            auto_play_en     <= 1'b1;
                            acc_mode         <= 3'd0;
                            song_restart_stb <= 1'b1;
                        end
                        2'd2: begin // 切入【2: 智能伴奏页】
                            auto_play_en     <= 1'b0;
                            acc_mode         <= acc_sub_mode;
                            song_restart_stb <= 1'b1;
                        end
                        default: begin // 切入【3: 音色效果页】
                            auto_play_en     <= 1'b0;
                            song_restart_stb <= 1'b1;
                        end
                    endcase
                end else if (!s1_clean) begin
                    s1_pend  <= 1'b0;
                    s1_guard <= 8'd0;
                end

                // =============================================================
                // 编码器 2 按下 (H7) 或 S2 (H10): 切换当前所在切屏页面 (active_page) 的子项!
                // =============================================================
                if (s2_fire) begin
                    s2_pend  <= 1'b0;
                    s2_guard <= 8'd0;
                    case (active_page)
                        2'd0: begin // 【0: 手动演奏页】按编码器2/S2: 切换频谱/李萨如视图模式
                            s2_disp_step_stb <= 1'b1;
                        end
                        2'd1: begin // 【1: 曲目点播页】按编码器2/S2: 切换曲目 (01~05) 并播放
                            sys_mode         <= 2'd1;
                            auto_play_en     <= 1'b1;
                            acc_mode         <= 3'd0;
                            song_idx         <= song_inc;
                            song_restart_stb <= 1'b1;
                        end
                        2'd2: begin // 【2: 智能伴奏页】按编码器2/S2: 切换 4 种伴奏节奏型 (01~04)
                            sys_mode     <= 2'd2;
                            auto_play_en <= 1'b0;
                            acc_sub_mode <= acc_sub_inc;
                            acc_mode     <= acc_sub_inc;
                        end
                        default: begin // 【3: 音色效果页】按编码器2/S2: 切换当前音色的效果器搭配
                            s2_fx_step_stb <= 1'b1;
                        end
                    endcase
                end else if (!s2_clean) begin
                    s2_pend  <= 1'b0;
                    s2_guard <= 8'd0;
                end
            end
        end
    end

endmodule
