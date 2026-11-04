// =============================================================================
// 文件名: poly32_fm_synth.v
// 模块功能: 64 声部 (64-Voice Polyphony) 6 拍流水线
//          【15-bit 线性插值 FM + 谐波声学物理建模 + 独立双包络 + 智能伴奏多声部合成引擎】
// 低底噪母带级增强:
//   1. 全链路向零对称舍入 (shr_z): 彻底消除 IIR 去直流与低通滤波器的 -1 极限环底噪;
//   2. 64 声部活跃检测 (any_voice_active): 当全部声部释音完毕进入静默时，滤波器状态与输出
//      平滑归零 (0 LSB 绝对静音)，配合 PAM8403 功放实现零数字底噪;
//   3. 针对 PAM8403 (24dB 固定增益 D 类功放) 优化的二阶温暖声学重构滤波与对数音量曲线，
//      彻底滤除高频与 D 类功放载波互调产生的沙沙声。
// =============================================================================

module poly32_fm_synth (
    input  wire               clk,           // 50MHz 系统时钟
    input  wire               rst_n,         // 低电平有效同步复位
    input  wire               sample_tick,   // 48.828kHz 采样率同步脉冲
    input  wire [17:0]        key_state,     // 18 个琴键当前状态 (C4~F5)
    input  wire [17:0]        key_press_evt, // 按键按下事件脉冲
    input  wire [17:0]        key_rel_evt,   // 按键释放事件脉冲
    input  wire [125:0]       key_vel_flat,  // 18 键独立 7-bit 力度向量 (11白键铜箔测速 36..127, 7黑键恒定100)
    input  wire [3:0]         volume,        // 主音量 (0~15)
    input  wire [3:0]         timbre_idx,    // 12 种商业级乐器音色 (0~11)
    input  wire               vibrato_en,    // 颤音开关
    input  wire               portamento_en,  // 滑音开关
    input  wire signed [5:0]  transpose_semi, // 蓝牙自定义移调半音偏移 (-24..+24, 默认 0)
    input  wire               test_cmd_vld,   // 64 路满负荷测试音指令脉冲 (蓝牙 X1/X0)
    input  wire               test_cmd_on,   // 1=开启 64 复音齐鸣测试, 0=关闭
    input  wire               acc_bass_stb,  // 智能伴奏: 低音触发脉冲
    input  wire [4:0]         acc_bass_note, // 智能伴奏: 低音音符编号 (0..11, 内部降八度为 C3~B3)
    input  wire               acc_bass_gate, // 智能伴奏: 低音门控保持
    input  wire               acc_arp_stb,   // 智能伴奏: 分解和弦主音触发脉冲
    input  wire [4:0]         acc_arp_note,  // 智能伴奏: 分解和弦主音编号 (0..24, C4~C6)
    input  wire               acc_arp2_stb,  // 智能伴奏: 分解和弦副音触发脉冲 (双音柱式伴奏)
    input  wire [4:0]         acc_arp2_note, // 智能伴奏: 分解和弦副音编号 (0..24, C4~C6)
    input  wire               acc_arp_gate,  // 智能伴奏: 分解和弦门控保持
    output reg  signed [23:0] pcm_out,       // 24-bit 高动态纯净音频输出
    output reg  signed [15:0] mono_sample,   // 16-bit 混音采样 (送往频谱与李萨如图模块)
    output reg                voices_active  // 64 声部中存在活跃发声声部标志
);

    // 向零对称舍入辅助函数: 彻底消除负数算术右移的 -1 极限环，确保静默时 100% 归零无底噪
    function signed [23:0] shr1_z24;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj      = x[23] ? (x + 24'sd1) : x;
            shr1_z24 = adj >>> 1;
        end
    endfunction

    function signed [23:0] shr2_z24;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj      = x[23] ? (x + 24'sd3) : x;
            shr2_z24 = adj >>> 2;
        end
    endfunction

    function signed [23:0] shr9_z24;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj      = x[23] ? (x + 24'sd511) : x;
            shr9_z24 = adj >>> 9;
        end
    endfunction

    // =========================================================================
    // 1. C4 ~ C6 (共 25 个半音, 0..24) 32-bit DDS 相位步进查找表 (fs = 48828.125 Hz)
    // =========================================================================
    function [31:0] note_step_lut;
        input [4:0] note;
        begin
            case (note)
                5'd0:  note_step_lut = 32'd23013441; // C4  (261.63 Hz)
                5'd1:  note_step_lut = 32'd24381891; // C#4 (277.18 Hz)
                5'd2:  note_step_lut = 32'd25831713; // D4  (293.66 Hz)
                5'd3:  note_step_lut = 32'd27367747; // D#4 (311.13 Hz)
                5'd4:  note_step_lut = 32'd28994966; // E4  (329.63 Hz)
                5'd5:  note_step_lut = 32'd30719098; // F4  (349.23 Hz)
                5'd6:  note_step_lut = 32'd32545750; // F#4 (369.99 Hz)
                5'd7:  note_step_lut = 32'd34480586; // G4  (392.00 Hz)
                5'd8:  note_step_lut = 32'd36531302; // G#4 (415.30 Hz)
                5'd9:  note_step_lut = 32'd38702699; // A4  (440.00 Hz)
                5'd10: note_step_lut = 32'd41004097; // A#4 (466.16 Hz)
                5'd11: note_step_lut = 32'd43442006; // B4  (493.88 Hz)
                5'd12: note_step_lut = 32'd46026882; // C5  (523.25 Hz)
                5'd13: note_step_lut = 32'd48763782; // C#5 (554.37 Hz)
                5'd14: note_step_lut = 32'd51663426; // D5  (587.33 Hz)
                5'd15: note_step_lut = 32'd54735494; // D#5 (622.25 Hz)
                5'd16: note_step_lut = 32'd57989932; // E5  (659.26 Hz)
                5'd17: note_step_lut = 32'd61438196; // F5  (698.46 Hz)
                5'd18: note_step_lut = 32'd65091500; // F#5 (739.99 Hz)
                5'd19: note_step_lut = 32'd68961172; // G5  (783.99 Hz)
                5'd20: note_step_lut = 32'd73062604; // G#5 (830.61 Hz)
                5'd21: note_step_lut = 32'd77405398; // A5  (880.00 Hz)
                5'd22: note_step_lut = 32'd82008194; // A#5 (932.33 Hz)
                5'd23: note_step_lut = 32'd86884012; // B5  (987.77 Hz)
                5'd24: note_step_lut = 32'd92053764; // C6  (1046.50 Hz)
                default: note_step_lut = 32'd38702699;
            endcase
        end
    endfunction

    // =========================================================================
    // 1b. 自定义移调 DDS 相位步进计算器 (支持 -24 ~ +24 半音无损移调, 覆盖 C2 ~ C8)
    // =========================================================================
    function [31:0] note_step_trans_lut;
        input [4:0]        note;
        input signed [5:0] trans;
        reg signed [6:0]   tnote;
        reg [6:0]          lut_idx_full;
        begin
            tnote = $signed({2'b00, note}) + $signed({trans[5], trans});
            if (tnote < -7'sd24)      tnote = -7'sd24;
            else if (tnote > 7'sd48)  tnote = 7'sd48;

            if (tnote < -7'sd12) begin
                lut_idx_full        = $unsigned(tnote + 7'sd24);
                note_step_trans_lut = note_step_lut(lut_idx_full[4:0]) >> 2;
            end else if (tnote < 7'sd0) begin
                lut_idx_full        = $unsigned(tnote + 7'sd12);
                note_step_trans_lut = note_step_lut(lut_idx_full[4:0]) >> 1;
            end else if (tnote <= 7'sd24) begin
                lut_idx_full        = $unsigned(tnote);
                note_step_trans_lut = note_step_lut(lut_idx_full[4:0]);
            end else if (tnote <= 7'sd36) begin
                lut_idx_full        = $unsigned(tnote - 7'sd12);
                note_step_trans_lut = note_step_lut(lut_idx_full[4:0]) << 1;
            end else begin
                lut_idx_full        = $unsigned(tnote - 7'sd24);
                note_step_trans_lut = note_step_lut(lut_idx_full[4:0]) << 2;
            end
        end
    endfunction

    // =========================================================================
    // 2. 针对 PCM5102A -> PAM8403 (24dB 功放) 甜区标定的 16 级对数音量表
    //    避免前级数字增益过高导致 PAM8403 输入过载与底噪放大
    // =========================================================================
    function signed [10:0] vol_gain_lut;
        input [3:0] vol;
        begin
            case (vol)
                4'd0:  vol_gain_lut = 11'sd0;
                4'd1:  vol_gain_lut = 11'sd8;
                4'd2:  vol_gain_lut = 11'sd15;
                4'd3:  vol_gain_lut = 11'sd24;
                4'd4:  vol_gain_lut = 11'sd34;
                4'd5:  vol_gain_lut = 11'sd46;
                4'd6:  vol_gain_lut = 11'sd60;
                4'd7:  vol_gain_lut = 11'sd76;
                4'd8:  vol_gain_lut = 11'sd96;  // 开机默认 8/15: 匹配 PAM8403 最佳输入动态甜区，声音洪亮且极低底噪
                4'd9:  vol_gain_lut = 11'sd118;
                4'd10: vol_gain_lut = 11'sd142;
                4'd11: vol_gain_lut = 11'sd168;
                4'd12: vol_gain_lut = 11'sd196;
                4'd13: vol_gain_lut = 11'sd228;
                4'd14: vol_gain_lut = 11'sd264;
                4'd15: vol_gain_lut = 11'sd304;
            endcase
        end
    endfunction

    // =========================================================================
    // 3. 512 点基础正弦表 + 15-bit 线性插值高精度正弦引擎 (等效 32768 点, SFDR > 92dB)
    // =========================================================================
    function signed [15:0] sine_lut;
        input [8:0] angle;
        reg [7:0] u, m;
        reg signed [15:0] amp;
        begin
            u = angle[7:0];
            m = u[7] ? (~u + 8'd1) : u;
            if (m == 8'd128) m = 8'd127;
            case (m[6:0])
                7'd0:  amp = 16'sd0;     7'd1:  amp = 16'sd402;   7'd2:  amp = 16'sd804;   7'd3:  amp = 16'sd1206;
                7'd4:  amp = 16'sd1608;  7'd5:  amp = 16'sd2009;  7'd6:  amp = 16'sd2410;  7'd7:  amp = 16'sd2811;
                7'd8:  amp = 16'sd3212;  7'd9:  amp = 16'sd3612;  7'd10: amp = 16'sd4011;  7'd11: amp = 16'sd4410;
                7'd12: amp = 16'sd4808;  7'd13: amp = 16'sd5205;  7'd14: amp = 16'sd5602;  7'd15: amp = 16'sd5998;
                7'd16: amp = 16'sd6393;  7'd17: amp = 16'sd6786;  7'd18: amp = 16'sd7179;  7'd19: amp = 16'sd7571;
                7'd20: amp = 16'sd7962;  7'd21: amp = 16'sd8351;  7'd22: amp = 16'sd8739;  7'd23: amp = 16'sd9126;
                7'd24: amp = 16'sd9512;  7'd25: amp = 16'sd9896;  7'd26: amp = 16'sd10278; 7'd27: amp = 16'sd10659;
                7'd28: amp = 16'sd11039; 7'd29: amp = 16'sd11417; 7'd30: amp = 16'sd11793; 7'd31: amp = 16'sd12167;
                7'd32: amp = 16'sd12539; 7'd33: amp = 16'sd12910; 7'd34: amp = 16'sd13279; 7'd35: amp = 16'sd13645;
                7'd36: amp = 16'sd14010; 7'd37: amp = 16'sd14372; 7'd38: amp = 16'sd14732; 7'd39: amp = 16'sd15090;
                7'd40: amp = 16'sd15446; 7'd41: amp = 16'sd15800; 7'd42: amp = 16'sd16151; 7'd43: amp = 16'sd16499;
                7'd44: amp = 16'sd16846; 7'd45: amp = 16'sd17189; 7'd46: amp = 16'sd17530; 7'd47: amp = 16'sd17869;
                7'd48: amp = 16'sd18204; 7'd49: amp = 16'sd18537; 7'd50: amp = 16'sd18868; 7'd51: amp = 16'sd19195;
                7'd52: amp = 16'sd19519; 7'd53: amp = 16'sd19841; 7'd54: amp = 16'sd20159; 7'd55: amp = 16'sd20475;
                7'd56: amp = 16'sd20787; 7'd57: amp = 16'sd21096; 7'd58: amp = 16'sd21403; 7'd59: amp = 16'sd21705;
                7'd60: amp = 16'sd22005; 7'd61: amp = 16'sd22301; 7'd62: amp = 16'sd22594; 7'd63: amp = 16'sd22884;
                7'd64: amp = 16'sd23170; 7'd65: amp = 16'sd23452; 7'd66: amp = 16'sd23731; 7'd67: amp = 16'sd24007;
                7'd68: amp = 16'sd24279; 7'd69: amp = 16'sd24547; 7'd70: amp = 16'sd24811; 7'd71: amp = 16'sd25072;
                7'd72: amp = 16'sd25329; 7'd73: amp = 16'sd25582; 7'd74: amp = 16'sd25832; 7'd75: amp = 16'sd26077;
                7'd76: amp = 16'sd26319; 7'd77: amp = 16'sd26556; 7'd78: amp = 16'sd26790; 7'd79: amp = 16'sd27019;
                7'd80: amp = 16'sd27245; 7'd81: amp = 16'sd27466; 7'd82: amp = 16'sd27683; 7'd83: amp = 16'sd27896;
                7'd84: amp = 16'sd28105; 7'd85: amp = 16'sd28310; 7'd86: amp = 16'sd28510; 7'd87: amp = 16'sd28706;
                7'd88: amp = 16'sd28898; 7'd89: amp = 16'sd29085; 7'd90: amp = 16'sd29268; 7'd91: amp = 16'sd29447;
                7'd92: amp = 16'sd29621; 7'd93: amp = 16'sd29791; 7'd94: amp = 16'sd29956; 7'd95: amp = 16'sd30117;
                7'd96: amp = 16'sd30273; 7'd97: amp = 16'sd30424; 7'd98: amp = 16'sd30571; 7'd99: amp = 16'sd30714;
                7'd100: amp = 16'sd30852; 7'd101: amp = 16'sd30985; 7'd102: amp = 16'sd31113; 7'd103: amp = 16'sd31237;
                7'd104: amp = 16'sd31356; 7'd105: amp = 16'sd31470; 7'd106: amp = 16'sd31580; 7'd107: amp = 16'sd31685;
                7'd108: amp = 16'sd31785; 7'd109: amp = 16'sd31880; 7'd110: amp = 16'sd31971; 7'd111: amp = 16'sd32057;
                7'd112: amp = 16'sd32137; 7'd113: amp = 16'sd32213; 7'd114: amp = 16'sd32285; 7'd115: amp = 16'sd32351;
                7'd116: amp = 16'sd32412; 7'd117: amp = 16'sd32469; 7'd118: amp = 16'sd32521; 7'd119: amp = 16'sd32567;
                7'd120: amp = 16'sd32609; 7'd121: amp = 16'sd32646; 7'd122: amp = 16'sd32678; 7'd123: amp = 16'sd32705;
                7'd124: amp = 16'sd32728; 7'd125: amp = 16'sd32745; 7'd126: amp = 16'sd32757; 7'd127: amp = 16'sd32765;
            endcase
            sine_lut = angle[8] ? -amp : amp;
        end
    endfunction

    // 15-bit 线性插值高精度正弦函数 (9-bit 整数查表 + 6-bit 小数线性内插)
    function signed [15:0] sine_interp;
        input [14:0] phase15;
        reg [8:0] idx0, idx1;
        reg [5:0] frac;
        reg signed [15:0] y0, y1;
        reg signed [16:0] diff;
        reg signed [23:0] prod;
        begin
            idx0 = phase15[14:6];
            idx1 = idx0 + 9'd1;
            frac = phase15[5:0];
            y0   = sine_lut(idx0);
            y1   = sine_lut(idx1);
            diff = $signed({y1[15], y1}) - $signed({y0[15], y0});
            prod = diff * $signed({1'b0, frac});
            sine_interp = y0 + $signed(prod[21:6]);
        end
    endfunction

    // =========================================================================
    // 4. 待分配按键挂起队列与 18-to-5 优先级编码器
    // =========================================================================
    reg  [17:0] pending_press;
    reg  [17:0] rel_evt_latch;
    wire        has_pending = (|pending_press);
    reg  [4:0]  req_note;

    always @(*) begin
        if      (pending_press[0])  req_note = 5'd0;
        else if (pending_press[1])  req_note = 5'd1;
        else if (pending_press[2])  req_note = 5'd2;
        else if (pending_press[3])  req_note = 5'd3;
        else if (pending_press[4])  req_note = 5'd4;
        else if (pending_press[5])  req_note = 5'd5;
        else if (pending_press[6])  req_note = 5'd6;
        else if (pending_press[7])  req_note = 5'd7;
        else if (pending_press[8])  req_note = 5'd8;
        else if (pending_press[9])  req_note = 5'd9;
        else if (pending_press[10]) req_note = 5'd10;
        else if (pending_press[11]) req_note = 5'd11;
        else if (pending_press[12]) req_note = 5'd12;
        else if (pending_press[13]) req_note = 5'd13;
        else if (pending_press[14]) req_note = 5'd14;
        else if (pending_press[15]) req_note = 5'd15;
        else if (pending_press[16]) req_note = 5'd16;
        else                        req_note = 5'd17;
    end

    // =========================================================================
    // 4b. 64 路满复音测试模式与智能伴奏专用声部挂起寄存器
    // =========================================================================
    reg        test_en;
    reg  [6:0] test_voices_on;
    reg        kill_alloc;
    reg  [31:0] alloc_commit_step;
    reg  [6:0]  alloc_commit_vel;
    wire [6:0]  req_note_vel = key_vel_flat[req_note * 7 +: 7];

    reg        bass_pend;
    reg  [4:0] bass_pend_note;
    reg        bass_v_sel; // 0 -> Voice 56, 1 -> Voice 57

    reg        arp1_pend;
    reg  [4:0] arp1_pend_note;
    reg        arp2_pend;
    reg  [4:0] arp2_pend_note;
    reg  [2:0] arp_v_ptr;  // 0..5 -> Voice 58..63 (6 路轮询)

    wire [5:0] arp_target_voice = 6'd58 + {3'd0, arp_v_ptr};

    wire [3:0] arp_timbre_sel = (timbre_idx == 4'd0) ? 4'd0 :
                                (timbre_idx == 4'd1 || timbre_idx == 4'd3 || timbre_idx == 4'd5 ||
                                 timbre_idx == 4'd8 || timbre_idx == 4'd11) ? 4'd1 : 4'd4;

    wire test_want = test_en && (test_voices_on < 7'd64);
    wire [6:0] test_sub18 = test_voices_on - 7'd18;
    wire [6:0] test_sub36 = test_voices_on - 7'd36;
    wire [6:0] test_sub54 = test_voices_on - 7'd54;
    reg  [4:0]  test_note;
    reg  [31:0] test_step;
    always @(*) begin
        if (test_voices_on < 7'd18) begin
            test_note = test_voices_on[4:0];
            test_step = note_step_lut(test_note);
        end else if (test_voices_on < 7'd36) begin
            test_note = test_sub18[4:0];
            test_step = note_step_lut(test_note) << 1;
        end else if (test_voices_on < 7'd54) begin
            test_note = test_sub36[4:0];
            test_step = note_step_lut(test_note) >> 1;
        end else begin
            test_note = test_sub54[4:0];
            test_step = note_step_lut(test_note) << 2;
        end
    end

    // =========================================================================
    // 5. TDM 6 拍流水线控制寄存器与 64 声部双包络存储器阵列
    // =========================================================================
    reg        tdm_busy;
    reg [2:0]  tdm_sub;
    reg [5:0]  tdm_idx;
    reg [2:0]  post_ph;
    reg signed [23:0] mix_acc;
    reg        sample_had_voice; // 当前采样周期是否有活跃声部发声
    reg [6:0]  env_div;
    wire       atk_tick = (env_div[1:0] == 2'd0); // 12.207 kHz 瞬态/起音时钟
    wire       env_tick = (env_div[2:0] == 3'd0); // 6.104 kHz 延音/释音时钟

    reg [2:0]  v_state      [0:63];
    reg [4:0]  v_note       [0:63];
    reg [3:0]  v_timbre     [0:63];
    reg [31:0] v_curr_step  [0:63];
    reg [31:0] v_targ_step  [0:63];
    reg [31:0] v_c_phase    [0:63];
    reg [15:0] v_env_level  [0:63]; // 声部主振幅包络
    reg [15:0] v_timbre_env [0:63]; // 声部独立瞬态音色/泛音包络
    reg [7:0]  v_vib_fade   [0:63]; // 声部颤音渐进淡入计数器
    reg [6:0]  v_vel        [0:63]; // 声部独立触键力度 (36..127)
    reg [63:0] v_sub_toggle;

    wire [2:0]  cur_v_state  = v_state[tdm_idx];
    wire [4:0]  cur_v_note   = v_note[tdm_idx];
    wire [3:0]  cur_v_timbre = v_timbre[tdm_idx];
    wire [15:0] cur_v_env    = v_env_level[tdm_idx];
    wire [15:0] cur_v_tenv   = v_timbre_env[tdm_idx];
    wire [7:0]  cur_v_vfade  = v_vib_fade[tdm_idx];
    wire [6:0]  cur_v_vel    = v_vel[tdm_idx];
    wire [31:0] cur_v_cstep  = v_curr_step[tdm_idx];
    wire [31:0] cur_v_tstep  = v_targ_step[tdm_idx];
    wire [31:0] cur_v_cphs   = v_c_phase[tdm_idx];
    wire        cur_v_sub    = v_sub_toggle[tdm_idx];

    wire        is_bass_voice = (!test_en) && (tdm_idx == 6'd56 || tdm_idx == 6'd57);
    wire        is_arp_voice  = (!test_en) && (tdm_idx >= 6'd58);

    // =========================================================================
    // 6. 12 款商业级混合 FM + 泛音物理建模音色表 (索引 0~11)
    // =========================================================================
    reg        t_h2_sel;       // 0=2f, 1=3f
    reg [1:0]  t_h3_sel;       // 0=3f, 1=4f, 2=5f, 3=0.5f
    reg [2:0]  t_recipe;       // 0..7 声学合成配方
    reg [1:0]  t_env_mode;     // 0=持续延音, 1=双段声板自然余音衰减, 2=短促木槌/八音盒衰减
    reg [7:0]  t_atk_rate;
    reg [2:0]  t_dec_shift;
    reg [15:0] t_sus_level;
    reg [2:0]  t_rel_shift;
    reg [1:0]  t_h4_sel;       // 0=0.5f, 1=4f, 2=5f, 3=3f
    reg [1:0]  t_h4_amp;       // 0=关, 1=/4, 2=/8, 3=/16
    reg [1:0]  t_ens_mode;     // 0=无, 1=柔和立体群感, 2=宽广交响群感
    reg [1:0]  t_fm_depth;     // 2-Op FM 相位调制深度 (1=温暖, 2=中度, 3=深度)
    reg        t_fm_dyn;       // 1=使用独立瞬态包络 v_timbre_env, 0=随主包络持续调制
    reg [2:0]  t_fm_dec_shift; // 瞬态音色包络衰减速率
    reg [15:0] t_fm_floor;     // 瞬态衰减后的温暖泛音保持底数

    always @(*) begin
        case (cur_v_timbre)
            // 00 三角钢琴 (Grand Piano)
            4'd0:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd0; t_env_mode=2'd1; t_atk_rate=8'd254; t_dec_shift=3'd6; t_sus_level=16'hD000; t_rel_shift=3'd5; t_h4_sel=2'd1; t_h4_amp=2'd2; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h9000; end
            // 01 经典电钢 (Rhodes EPiano)
            4'd1:  begin t_h2_sel=1'b0; t_h3_sel=2'd1; t_recipe=3'd0; t_env_mode=2'd1; t_atk_rate=8'd250; t_dec_shift=3'd6; t_sus_level=16'hD400; t_rel_shift=3'd5; t_h4_sel=2'd3; t_h4_amp=2'd2; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h8800; end
            // 02 水晶八音 (Music Box, +1 Oct)
            4'd2:  begin t_h2_sel=1'b1; t_h3_sel=2'd1; t_recipe=3'd1; t_env_mode=2'd2; t_atk_rate=8'd255; t_dec_shift=3'd6; t_sus_level=16'hB000; t_rel_shift=3'd5; t_h4_sel=2'd3; t_h4_amp=2'd2; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h7800; end
            // 03 教堂风琴 (Pipe Organ)
            4'd3:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd2; t_env_mode=2'd0; t_atk_rate=8'd128; t_dec_shift=3'd6; t_sus_level=16'hF000; t_rel_shift=3'd4; t_h4_sel=2'd1; t_h4_amp=2'd1; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b0; t_fm_dec_shift=3'd7; t_fm_floor=16'h9000; end
            // 04 古典吉他 (Acoustic Guitar)
            4'd4:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd3; t_env_mode=2'd1; t_atk_rate=8'd254; t_dec_shift=3'd5; t_sus_level=16'hB800; t_rel_shift=3'd5; t_h4_sel=2'd2; t_h4_amp=2'd2; t_ens_mode=2'd0; t_fm_depth=2'd2; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h9800; end
            // 05 交响弦乐 (Violin Strings)
            4'd5:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd4; t_env_mode=2'd0; t_atk_rate=8'd44;  t_dec_shift=3'd6; t_sus_level=16'hEC00; t_rel_shift=3'd5; t_h4_sel=2'd1; t_h4_amp=2'd1; t_ens_mode=2'd1; t_fm_depth=2'd1; t_fm_dyn=1'b0; t_fm_dec_shift=3'd7; t_fm_floor=16'hA000; end
            // 06 空灵长笛 (Concert Flute)
            4'd6:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd5; t_env_mode=2'd0; t_atk_rate=8'd64;  t_dec_shift=3'd6; t_sus_level=16'hEC00; t_rel_shift=3'd5; t_h4_sel=2'd3; t_h4_amp=2'd3; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h7000; end
            // 07 木管单簧 (Clarinet)
            4'd7:  begin t_h2_sel=1'b1; t_h3_sel=2'd2; t_recipe=3'd6; t_env_mode=2'd0; t_atk_rate=8'd88;  t_dec_shift=3'd6; t_sus_level=16'hEC00; t_rel_shift=3'd5; t_h4_sel=2'd3; t_h4_amp=2'd1; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b0; t_fm_dec_shift=3'd7; t_fm_floor=16'hB000; end
            // 08 辉煌铜管 (Symphonic Brass)
            4'd8:  begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd7; t_env_mode=2'd0; t_atk_rate=8'd56;  t_dec_shift=3'd6; t_sus_level=16'hF000; t_rel_shift=3'd5; t_h4_sel=2'd1; t_h4_amp=2'd1; t_ens_mode=2'd0; t_fm_depth=2'd2; t_fm_dyn=1'b0; t_fm_dec_shift=3'd7; t_fm_floor=16'hB800; end
            // 09 木琴马林 (Marimba)
            4'd9:  begin t_h2_sel=1'b0; t_h3_sel=2'd1; t_recipe=3'd1; t_env_mode=2'd2; t_atk_rate=8'd255; t_dec_shift=3'd4; t_sus_level=16'h7800; t_rel_shift=3'd4; t_h4_sel=2'd1; t_h4_amp=2'd1; t_ens_mode=2'd0; t_fm_depth=2'd1; t_fm_dyn=1'b1; t_fm_dec_shift=3'd4; t_fm_floor=16'h8000; end
            // 10 重低贝司 (Electric Bass, -1 Oct)
            4'd10: begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd7; t_env_mode=2'd1; t_atk_rate=8'd252; t_dec_shift=3'd5; t_sus_level=16'hB800; t_rel_shift=3'd4; t_h4_sel=2'd1; t_h4_amp=2'd1; t_ens_mode=2'd0; t_fm_depth=2'd2; t_fm_dyn=1'b1; t_fm_dec_shift=3'd5; t_fm_floor=16'h9000; end
            // 11 合成主音 (Synth Lead)
            default: begin t_h2_sel=1'b0; t_h3_sel=2'd0; t_recipe=3'd7; t_env_mode=2'd0; t_atk_rate=8'd120; t_dec_shift=3'd6; t_sus_level=16'hF000; t_rel_shift=3'd5; t_h4_sel=2'd2; t_h4_amp=2'd1; t_ens_mode=2'd1; t_fm_depth=2'd2; t_fm_dyn=1'b0; t_fm_dec_shift=3'd7; t_fm_floor=16'hB000; end
        endcase
    end

    wire [1:0] new_oct_mode = (timbre_idx == 4'd2)  ? 2'd2 :
                              (timbre_idx == 4'd10) ? 2'd1 : 2'd0;

    // =========================================================================
    // 7. 音乐厅级渐进式颤音与无爆音滑音
    // =========================================================================
    reg [15:0] lfo_phase;
    reg signed [15:0] lfo_val_r;
    reg signed [15:0] ens_val_r;

    wire signed [16:0] trem_mod = (lfo_val_r >>> 3);

    reg [31:0] last_active_step;
    reg [31:0] glide_anchor_step;
    reg [9:0]  glide_chord_timer;
    reg        has_last_note;

    reg [11:0] alt_ioi_cnt;
    reg [12:0] auto_expr_hold;
    wire [17:0] prev_held_keys   = key_state & ~key_press_evt;
    wire       prev_single_held  = (|prev_held_keys) && ((prev_held_keys & (prev_held_keys - 18'd1)) == 18'd0);
    wire       prev_none_held    = (prev_held_keys == 18'd0);
    wire       single_key_trig   = (|key_press_evt) && ((key_press_evt & (key_press_evt - 18'd1)) == 18'd0);
    wire       melody_context    = single_key_trig && (prev_single_held || prev_none_held);
    wire       legato_slur       = melody_context && prev_single_held && (alt_ioi_cnt >= 12'd275);
    wire       rapid_trill_trig  = melody_context && (alt_ioi_cnt >= 12'd275 && alt_ioi_cnt <= 12'd1150);
    wire       eff_portamento    = portamento_en;
    wire       eff_vibrato       = vibrato_en;

    // 后处理滤波器与去直流状态寄存器
    reg signed [23:0] dc_x1;
    reg signed [23:0] dc_y1;
    reg signed [23:0] lp_warm1;
    reg signed [23:0] lp_warm2;
    reg signed [10:0] vol_gain_slewed;

    reg [17:0] search_best_cost;
    reg [5:0]  search_best_voice;
    reg        alloc_commit_en;
    reg [5:0]  alloc_commit_v;
    reg [4:0]  alloc_commit_note;

    // 6 拍流水线级间寄存器
    reg        pipe_active;
    reg        pipe_is_bass;
    reg        pipe_is_arp;
    reg [2:0]  pipe_recipe;
    reg [1:0]  pipe_h4_amp;
    reg [1:0]  pipe_ens_mode;
    reg [1:0]  pipe_fm_depth;
    reg        pipe_fm_dyn;
    reg [4:0]  pipe_note;
    reg [7:0]  pipe_vfade;
    reg [6:0]  pipe_vel;
    reg [15:0] pipe_env;
    reg [15:0] pipe_tenv;
    reg [15:0] fm_raw_env_r;
    reg [31:0] harm_env_sq_r;
    reg [15:0] pipe_harm_env;
    reg [15:0] env_mod_val_r;
    reg [15:0] pipe_voice_env;
    reg [1:0]  pipe_hf_atten;
    reg [14:0] sel_ang2_15_r;
    reg [14:0] ang1_15_r;
    reg [14:0] carrier_ang15_r;
    reg [14:0] ang3_15_r;
    reg [8:0]  ang4_r;
    reg [31:0] alloc_lut_step_r;
    reg [31:0] voice_lut_step_r;
    reg [1:0]  voice_oct_mode_r;
    reg signed [31:0] vib_prod_r;
    reg signed [15:0] fm_mod_r;
    reg signed [15:0] pipe_s1, pipe_s2, pipe_s3, pipe_s4;
    reg signed [17:0] raw_wave_r;

    // 后处理 4 拍流水线寄存器
    reg signed [23:0] warm_r;
    reg signed [34:0] vol_prod_r;
    reg signed [25:0] scaled_bus_r;
    reg signed [23:0] lim_out_r;

    reg [17:0] cur_voice_cost;
    always @(*) begin
        if (cur_v_state == 3'd0)
            cur_voice_cost = {2'b00, 16'd0};
        else if (cur_v_state == 3'd4 && cur_v_note == req_note)
            cur_voice_cost = {2'b01, cur_v_env};
        else if (cur_v_state == 3'd4)
            cur_voice_cost = {2'b10, cur_v_env};
        else
            cur_voice_cost = {2'b11, cur_v_env};
    end

    wire [17:0] clear_req_mask = (tdm_busy && (tdm_sub == 3'd5) && (tdm_idx == 6'd63) && has_pending && !alloc_commit_en && !test_en) ? (18'd1 << req_note) : 18'd0;
    wire signed [10:0] cur_vol_gain = vol_gain_lut(volume);
    wire alloc_req_eff = test_want || (has_pending && !test_en);

    reg [31:0] base_note_step;
    reg [31:0] oct_adj_step;
    reg [31:0] scoop_step;
    reg [31:0] start_glide_step;
    reg [31:0] glide_diff;
    reg [4:0]  arp_launch_note;
    reg [31:0] arp_launch_step;
    reg signed [31:0] vib_raw;
    reg signed [31:0] vib_scaled;
    reg signed [31:0] vib_delta;
    reg signed [31:0] ens_delta;
    reg [31:0] step_with_vib;
    reg [31:0] next_cphs;
    reg [31:0] phs_x3;
    reg [31:0] phs_x5;
    reg [31:0] phs_x3_0;
    reg [8:0]  p05_angle, p3_angle, p4_angle, p5_angle;
    reg [14:0] p05_angle15, p1_angle15, p3_angle15, p4_angle15, p5_angle15;
    reg [15:0] exp_dec_step;
    reg [15:0] exp_rel_step;
    reg [15:0] timbre_dec_step;
    reg [15:0] eff_atk_step;
    reg        voice_rel_cond;
    reg [15:0] fm_env_scale;
    reg signed [31:0] fm_prod;
    reg signed [14:0] fm_phase_off15;
    reg signed [31:0] trem_prod;
    reg signed [17:0] env_trem_tmp;
    reg [15:0] env_mod_val;
    reg [7:0]  vel_gain8;
    reg [23:0] env_vel_prod;
    reg [15:0] env_vel_scaled;
    reg signed [31:0] s3_dyn_prod;
    reg signed [24:0] s2_dyn_prod;
    reg signed [15:0] s3_dyn;
    reg signed [15:0] s2_dyn;
    reg signed [17:0] raw_sum;
    reg signed [34:0] scaled_wave;
    reg signed [23:0] dc_out;
    reg signed [23:0] warm_diff1;
    reg signed [23:0] warm_diff2;
    reg signed [23:0] warm1_next;
    reg signed [23:0] warm2_next;
    reg signed [25:0] bus_abs;
    reg signed [25:0] bus_diff;
    reg signed [25:0] bus_shf;
    reg signed [23:0] lim_mag;
    reg signed [23:0] mono_scaled;
    integer vi;
    reg [6:0] init_v_cnt = 7'd0;
    wire      v_clr_busy = ~init_v_cnt[6];
    reg       rel_all_Scan = 1'b0;

    initial begin
        for (vi = 0; vi < 64; vi = vi + 1) begin
            v_state[vi]      = 3'd0;
            v_note[vi]       = 5'd0;
            v_timbre[vi]     = 4'd0;
            v_curr_step[vi]  = 32'd0;
            v_targ_step[vi]  = 32'd0;
            v_c_phase[vi]    = 32'd0;
            v_env_level[vi]  = 16'd0;
            v_timbre_env[vi] = 16'd0;
            v_vib_fade[vi]   = 8'd0;
            v_vel[vi]        = 7'd100;
        end
    end

    wire [8:0]         ens_angle9          = lfo_phase[15:7] + {tdm_idx, 3'b011};
    wire [4:0]         alloc_lut_note      = bass_pend ? bass_pend_note :
                                             arp1_pend ? arp1_pend_note :
                                             arp2_pend ? arp2_pend_note : alloc_commit_note;
    wire [14:0]        shared_interp_ang15 = (!tdm_busy)       ? lfo_phase[15:1] :
                                             (tdm_sub == 3'd1) ? sel_ang2_15_r   :
                                             (tdm_sub == 3'd2) ? ang3_15_r       : carrier_ang15_r;
    wire signed [15:0] shared_interp_val   = sine_interp(shared_interp_ang15);

    always @(posedge clk) begin
        if (!rst_n) begin
            pending_press        <= 18'd0;
            rel_evt_latch        <= 18'd0;
            bass_pend            <= 1'b0;
            bass_pend_note       <= 5'd0;
            bass_v_sel           <= 1'b0;
            arp1_pend            <= 1'b0;
            arp1_pend_note       <= 5'd0;
            arp2_pend            <= 1'b0;
            arp2_pend_note       <= 5'd0;
            arp_v_ptr            <= 3'd0;
            tdm_busy             <= 1'b0;
            tdm_sub              <= 3'd0;
            tdm_idx              <= 6'd0;
            post_ph              <= 3'd0;
            v_sub_toggle         <= 64'd0;
            lfo_phase            <= 16'd0;
            lfo_val_r            <= 16'sd0;
            ens_val_r            <= 16'sd0;
            env_div              <= 7'd0;
            last_active_step     <= 32'd0;
            glide_anchor_step    <= 32'd0;
            glide_chord_timer    <= 10'd0;
            has_last_note        <= 1'b0;
            alt_ioi_cnt          <= 12'd4095;
            auto_expr_hold       <= 13'd0;
            mix_acc              <= 24'sd0;
            sample_had_voice     <= 1'b0;
            dc_x1                <= 24'sd0;
            dc_y1                <= 24'sd0;
            lp_warm1             <= 24'sd0;
            lp_warm2             <= 24'sd0;
            vol_gain_slewed      <= 11'sd96;
            pcm_out              <= 24'sd0;
            mono_sample          <= 16'sd0;
            voices_active        <= 1'b0;
            alloc_commit_en      <= 1'b0;
            alloc_commit_v       <= 6'd0;
            alloc_commit_note    <= 5'd0;
            alloc_commit_step    <= 32'd0;
            alloc_commit_vel     <= 7'd100;
            pipe_vel             <= 7'd100;
            search_best_cost     <= 18'h3FFFF;
            search_best_voice    <= 6'd0;
            pipe_active          <= 1'b0;
            pipe_is_bass         <= 1'b0;
            pipe_is_arp          <= 1'b0;
            pipe_recipe          <= 3'd0;
            pipe_h4_amp          <= 2'd0;
            pipe_ens_mode        <= 2'd0;
            pipe_fm_depth        <= 2'd0;
            pipe_fm_dyn          <= 1'b0;
            pipe_note            <= 5'd0;
            pipe_vfade           <= 8'd0;
            pipe_env             <= 16'd0;
            pipe_tenv            <= 16'd0;
            fm_raw_env_r         <= 16'd0;
            harm_env_sq_r        <= 32'd0;
            pipe_harm_env        <= 16'd0;
            env_mod_val_r        <= 16'd0;
            pipe_voice_env       <= 16'd0;
            pipe_hf_atten        <= 2'd0;
            sel_ang2_15_r        <= 15'd0;
            ang1_15_r            <= 15'd0;
            carrier_ang15_r      <= 15'd0;
            ang3_15_r            <= 15'd0;
            ang4_r               <= 9'd0;
            alloc_lut_step_r     <= 32'd23013441;
            voice_lut_step_r     <= 32'd23013441;
            voice_oct_mode_r     <= 2'd0;
            vib_prod_r           <= 32'sd0;
            fm_mod_r             <= 16'sd0;
            pipe_s1              <= 16'sd0;
            pipe_s2              <= 16'sd0;
            pipe_s3              <= 16'sd0;
            pipe_s4              <= 16'sd0;
            raw_wave_r           <= 18'sd0;
            warm_r               <= 24'sd0;
            vol_prod_r           <= 35'sd0;
            scaled_bus_r         <= 26'sd0;
            lim_out_r            <= 24'sd0;
            test_en              <= 1'b0;
            test_voices_on       <= 7'd0;
            kill_alloc           <= 1'b0;
            init_v_cnt           <= 7'd0;
            rel_all_Scan         <= 1'b0;
        end else if (v_clr_busy) begin
            v_state[init_v_cnt[5:0]]      <= 3'd0;
            v_note[init_v_cnt[5:0]]       <= 5'd0;
            v_timbre[init_v_cnt[5:0]]     <= 4'd0;
            v_curr_step[init_v_cnt[5:0]]  <= 32'd0;
            v_targ_step[init_v_cnt[5:0]]  <= 32'd0;
            v_c_phase[init_v_cnt[5:0]]    <= 32'd0;
            v_env_level[init_v_cnt[5:0]]  <= 16'd0;
            v_timbre_env[init_v_cnt[5:0]] <= 16'd0;
            v_vib_fade[init_v_cnt[5:0]]   <= 8'd0;
            v_vel[init_v_cnt[5:0]]        <= 7'd100;
            init_v_cnt                    <= init_v_cnt + 7'd1;
        end else begin
            alloc_lut_step_r <= note_step_trans_lut(alloc_lut_note, transpose_semi);
            if (!tdm_busy)
                lfo_val_r <= shared_interp_val;
            pending_press <= (pending_press & ~clear_req_mask) | key_press_evt;
            if (|key_press_evt) begin
                if (rapid_trill_trig || legato_slur)
                    auto_expr_hold <= 13'd4500;
                alt_ioi_cnt <= 12'd0;
            end else if (sample_tick && env_tick) begin
                if (alt_ioi_cnt < 12'd4095)
                    alt_ioi_cnt <= alt_ioi_cnt + 12'd1;
                if (auto_expr_hold != 13'd0)
                    auto_expr_hold <= auto_expr_hold - 13'd1;
            end
            if (sample_tick) begin
                rel_evt_latch <= key_rel_evt;
                kill_alloc    <= 1'b0;
                if (glide_chord_timer != 10'd0)
                    glide_chord_timer <= glide_chord_timer - 10'd1;
            end else begin
                rel_evt_latch <= rel_evt_latch | key_rel_evt;
            end

            if (acc_bass_stb && !test_en) begin
                bass_pend      <= 1'b1;
                bass_pend_note <= acc_bass_note;
                bass_v_sel     <= ~bass_v_sel;
            end
            if (acc_arp_stb && !test_en) begin
                arp1_pend      <= 1'b1;
                arp1_pend_note <= acc_arp_note;
            end
            if (acc_arp2_stb && !test_en) begin
                arp2_pend      <= 1'b1;
                arp2_pend_note <= acc_arp2_note;
            end

            // =================================================================
            // 采样周期启动 (sample_tick)
            // =================================================================
            if (sample_tick) begin
                tdm_busy         <= 1'b1;
                tdm_sub          <= 3'd0;
                tdm_idx          <= 6'd0;
                post_ph          <= 3'd0;
                mix_acc          <= 24'sd0;
                sample_had_voice <= 1'b0;
                env_div          <= env_div + 7'd1;
                lfo_phase        <= lfo_phase + 16'd8;
                search_best_cost <= 18'h3FFFF;
                pipe_active      <= 1'b0;
            end else if (tdm_busy) begin
                case (tdm_sub)
                    // ---------------------------------------------------------
                    // 拍 0: 声部寻优、新音符分配、滑音步进更新与 LFO 预乘
                    // ---------------------------------------------------------
                    3'd0: begin
                        if (tdm_idx == 6'd0 || ((tdm_idx <= 6'd55) && (cur_voice_cost < search_best_cost))) begin
                            search_best_cost  <= cur_voice_cost;
                            search_best_voice <= tdm_idx;
                        end

                        if (!test_en && bass_pend && (tdm_idx == {5'b11100, bass_v_sel}) && !kill_alloc) begin
                            oct_adj_step          = alloc_lut_step_r >> 1;
                            v_note[tdm_idx]      <= bass_pend_note;
                            v_targ_step[tdm_idx] <= oct_adj_step;
                            v_curr_step[tdm_idx] <= oct_adj_step;
                            v_state[tdm_idx]     <= 3'd1;
                            v_timbre[tdm_idx]    <= 4'd10;
                            v_timbre_env[tdm_idx]<= 16'hFFFF;
                            v_vib_fade[tdm_idx]  <= 8'd0;
                            v_vel[tdm_idx]       <= 7'd112;
                            if (cur_v_state == 3'd0) begin
                                v_c_phase[tdm_idx]   <= 32'd0;
                                v_env_level[tdm_idx] <= 16'd64;
                            end else begin
                                v_env_level[tdm_idx] <= (cur_v_env < 16'd64) ? 16'd64 : cur_v_env;
                            end
                            bass_pend        <= 1'b0;
                            pipe_active      <= 1'b0;
                            sample_had_voice <= 1'b1;
                            tdm_sub          <= 3'd5;
                        end else if (!test_en && (arp1_pend || arp2_pend) && (tdm_idx == arp_target_voice) && !kill_alloc) begin
                            arp_launch_note       = arp1_pend ? arp1_pend_note : arp2_pend_note;
                            arp_launch_step       = alloc_lut_step_r;
                            v_note[tdm_idx]      <= arp_launch_note;
                            v_targ_step[tdm_idx] <= arp_launch_step;
                            v_curr_step[tdm_idx] <= arp_launch_step;
                            v_state[tdm_idx]     <= 3'd1;
                            v_timbre[tdm_idx]    <= arp_timbre_sel;
                            v_timbre_env[tdm_idx]<= 16'hE000;
                            v_vib_fade[tdm_idx]  <= 8'd0;
                            v_vel[tdm_idx]       <= 7'd104;
                            if (cur_v_state == 3'd0) begin
                                v_c_phase[tdm_idx]   <= 32'd0;
                                v_env_level[tdm_idx] <= 16'd64;
                            end else begin
                                v_env_level[tdm_idx] <= (cur_v_env < 16'd64) ? 16'd64 : cur_v_env;
                            end
                            if (arp1_pend)
                                arp1_pend <= 1'b0;
                            else
                                arp2_pend <= 1'b0;
                            arp_v_ptr        <= (arp_v_ptr >= 3'd5) ? 3'd0 : (arp_v_ptr + 3'd1);
                            pipe_active      <= 1'b0;
                            sample_had_voice <= 1'b1;
                            tdm_sub          <= 3'd5;
                        end else if (alloc_commit_en && (tdm_idx == alloc_commit_v) && !kill_alloc) begin
                            if (test_en) begin
                                v_note[tdm_idx]      <= alloc_commit_note;
                                v_targ_step[tdm_idx] <= alloc_commit_step;
                                v_curr_step[tdm_idx] <= alloc_commit_step;
                                test_voices_on       <= test_voices_on + 7'd1;
                                last_active_step     <= alloc_commit_step;
                            end else begin
                                base_note_step = alloc_lut_step_r;
                                if (new_oct_mode == 2'd1)
                                    oct_adj_step = base_note_step >> 1;
                                else if (new_oct_mode == 2'd2)
                                    oct_adj_step = base_note_step << 1;
                                else
                                    oct_adj_step = base_note_step;

                                scoop_step = oct_adj_step - (oct_adj_step >> 3);
                                if (!has_last_note) begin
                                    start_glide_step = scoop_step;
                                end else if (glide_chord_timer == 10'd0) begin
                                    start_glide_step = (last_active_step == oct_adj_step) ? scoop_step : last_active_step;
                                    glide_anchor_step <= last_active_step;
                                end else begin
                                    start_glide_step = (glide_anchor_step == oct_adj_step || glide_anchor_step == 32'd0)
                                                       ? scoop_step : glide_anchor_step;
                                end

                                v_note[tdm_idx]      <= alloc_commit_note;
                                v_targ_step[tdm_idx] <= oct_adj_step;
                                v_curr_step[tdm_idx] <= eff_portamento ? start_glide_step : oct_adj_step;
                                last_active_step     <= oct_adj_step;
                                glide_chord_timer    <= 10'd732;
                            end

                            v_state[tdm_idx]      <= 3'd1;
                            v_timbre[tdm_idx]     <= timbre_idx;
                            v_timbre_env[tdm_idx] <= {1'b1, alloc_commit_vel, 8'hFF};
                            v_vel[tdm_idx]        <= alloc_commit_vel;
                            v_vib_fade[tdm_idx]   <= (auto_expr_hold != 13'd0) ? 8'd192 : 8'd0;
                            if (cur_v_state == 3'd0) begin
                                v_c_phase[tdm_idx]   <= 32'd0;
                                v_env_level[tdm_idx] <= 16'd64;
                            end else begin
                                v_env_level[tdm_idx] <= (cur_v_env < 16'd64) ? 16'd64 : cur_v_env;
                            end
                            has_last_note    <= 1'b1;
                            alloc_commit_en  <= 1'b0;
                            pipe_active      <= 1'b0;
                            sample_had_voice <= 1'b1;
                            tdm_sub          <= 3'd5;
                        end else if (cur_v_state != 3'd0) begin
                            if (eff_portamento && !is_bass_voice && !is_arp_voice && !test_en) begin
                                if (atk_tick) begin
                                    if (cur_v_cstep < cur_v_tstep) begin
                                        glide_diff = cur_v_tstep - cur_v_cstep;
                                        v_curr_step[tdm_idx] <= cur_v_cstep + (glide_diff >> 8) - (glide_diff >> 10) + 32'd4;
                                    end else if (cur_v_cstep > cur_v_tstep) begin
                                        glide_diff = cur_v_cstep - cur_v_tstep;
                                        v_curr_step[tdm_idx] <= cur_v_cstep - (glide_diff >> 8) + (glide_diff >> 10) - 32'd4;
                                    end
                                end
                            end else begin
                                v_curr_step[tdm_idx] <= cur_v_tstep;
                            end

                            phs_x3_0          = cur_v_cphs + (cur_v_cphs << 1);
                            sel_ang2_15_r    <= t_h2_sel ? phs_x3_0[31:17] : cur_v_cphs[30:16];
                            voice_oct_mode_r <= (is_bass_voice || (!is_arp_voice && cur_v_timbre == 4'd10)) ? 2'd1 :
                                                (!is_arp_voice && cur_v_timbre == 4'd2) ? 2'd2 : 2'd0;
                            vib_prod_r       <= $signed({1'b0, cur_v_cstep[31:16]}) * lfo_val_r;
                            ens_val_r        <= sine_lut(ens_angle9);
                            pipe_active      <= 1'b1;
                            sample_had_voice <= 1'b1;
                            pipe_is_bass     <= is_bass_voice;
                            pipe_is_arp      <= is_arp_voice;
                            pipe_recipe      <= t_recipe;
                            pipe_h4_amp      <= (cur_v_cstep >= 32'd72_000_000) ? 2'd0 : t_h4_amp;
                            pipe_ens_mode    <= t_ens_mode;
                            pipe_fm_depth    <= t_fm_depth;
                            pipe_fm_dyn      <= t_fm_dyn;
                            pipe_note        <= cur_v_note;
                            pipe_hf_atten    <= (cur_v_cstep >= 32'd72_000_000) ? 2'd2 :
                                                (cur_v_cstep >= 32'd41_000_000) ? 2'd1 : 2'd0;
                            pipe_vfade       <= cur_v_vfade;
                            pipe_vel         <= cur_v_vel;
                            pipe_env         <= cur_v_env;
                            pipe_tenv        <= cur_v_tenv;
                            fm_raw_env_r     <= t_fm_dyn ? cur_v_tenv : cur_v_env;
                            tdm_sub          <= 3'd1;
                        end else begin
                            pipe_active <= 1'b0;
                            tdm_sub     <= 3'd5;
                        end
                    end

                    // ---------------------------------------------------------
                    // 拍 1: 相位累加、15-bit 插值预取 FM 调制波、包络更新
                    // ---------------------------------------------------------
                    3'd1: begin
                        vib_raw    = eff_vibrato ? (vib_prod_r >>> 5) : 32'sd0;
                        vib_scaled = (vib_raw * $signed({1'b0, pipe_vfade})) >>> 8;
                        vib_delta  = (!test_en && !pipe_is_bass && eff_vibrato) ? vib_scaled : 32'sd0;

                        if (test_en || pipe_ens_mode == 2'd0)
                            ens_delta = 32'sd0;
                        else
                            ens_delta = $signed(ens_val_r) <<< 1;

                        step_with_vib = cur_v_cstep + vib_delta + ens_delta;
                        next_cphs     = cur_v_cphs + step_with_vib;

                        v_c_phase[tdm_idx] <= next_cphs;
                        if (cur_v_cphs[31] && !next_cphs[31])
                            v_sub_toggle[tdm_idx] <= ~cur_v_sub;

                        phs_x3 = cur_v_cphs + (cur_v_cphs << 1);
                        phs_x5 = cur_v_cphs + (cur_v_cphs << 2);

                        p05_angle15 = {cur_v_sub, cur_v_cphs[31:18]};
                        p1_angle15  = cur_v_cphs[31:17];
                        p3_angle15  = phs_x3[31:17];
                        p4_angle15  = cur_v_cphs[29:15];
                        p5_angle15  = phs_x5[31:17];

                        p05_angle   = {cur_v_sub, cur_v_cphs[31:24]};
                        p3_angle    = phs_x3[31:23];
                        p4_angle    = cur_v_cphs[29:21];
                        p5_angle    = phs_x5[31:23];

                        ang1_15_r   <= p1_angle15;
                        case (t_h3_sel)
                            2'd0: ang3_15_r <= p3_angle15;
                            2'd1: ang3_15_r <= p4_angle15;
                            2'd2: ang3_15_r <= p5_angle15;
                            2'd3: ang3_15_r <= p05_angle15;
                        endcase
                        case (t_h4_sel)
                            2'd0: ang4_r <= p05_angle;
                            2'd1: ang4_r <= p4_angle;
                            2'd2: ang4_r <= p5_angle;
                            2'd3: ang4_r <= p3_angle;
                        endcase

                        voice_lut_step_r <= note_step_trans_lut(pipe_note, transpose_semi);
                        fm_mod_r         <= shared_interp_val;
                        harm_env_sq_r <= fm_raw_env_r * fm_raw_env_r;
                        pipe_harm_env <= fm_raw_env_r;

                        // 全采样率 (48.828kHz) 零阶跃音色泛音包络平滑更新
                        if (t_fm_dyn) begin
                            timbre_dec_step = (cur_v_tenv >> (t_fm_dec_shift + 4'd2)) + 16'd2;
                            if (cur_v_tenv > t_fm_floor + timbre_dec_step)
                                v_timbre_env[tdm_idx] <= cur_v_tenv - timbre_dec_step;
                            else
                                v_timbre_env[tdm_idx] <= t_fm_floor;
                        end else begin
                            v_timbre_env[tdm_idx] <= cur_v_env;
                        end

                        if (env_tick && cur_v_vfade < 8'd255) begin
                            v_vib_fade[tdm_idx] <= (cur_v_vfade > 8'd251) ? 8'd255 : (cur_v_vfade + 8'd4);
                        end

                        // 全采样率 (48.828kHz) 零阶跃振幅包络步进 (彻底消除 6.1kHz/12.2kHz 包络台阶底噪)
                        exp_dec_step = (cur_v_env >> (t_dec_shift + 4'd7)) + 16'd1;
                        exp_rel_step = (cur_v_env >> (t_rel_shift + 4'd7)) + 16'd1;
                        eff_atk_step = (eff_portamento && !is_bass_voice && !is_arp_voice && (cur_v_env < 16'h3000) && (t_atk_rate < 8'd80))
                                       ? {5'd0, t_atk_rate, 3'd0} : {6'd0, t_atk_rate, 2'd0};

                        if (is_bass_voice)
                            voice_rel_cond = (!acc_bass_gate) || (tdm_idx[0] != bass_v_sel);
                        else if (is_arp_voice)
                            voice_rel_cond = (!acc_arp_gate);
                        else
                            voice_rel_cond = (!key_state[cur_v_note]) || rel_evt_latch[cur_v_note];

                        if ((rel_all_Scan || (!test_en && voice_rel_cond)) &&
                            (cur_v_state == 3'd1 || cur_v_state == 3'd2 || cur_v_state == 3'd3)) begin
                            v_state[tdm_idx] <= 3'd4;
                        end else if (cur_v_state == 3'd1) begin
                            if ({1'b0, cur_v_env} + {1'b0, eff_atk_step} >= 17'h0FFFF) begin
                                v_env_level[tdm_idx] <= 16'hFFFF;
                                v_state[tdm_idx]     <= 3'd2;
                            end else begin
                                v_env_level[tdm_idx] <= cur_v_env + eff_atk_step;
                            end
                        end else if (test_en) begin
                            v_env_level[tdm_idx] <= 16'h0800;
                        end else begin
                            case (cur_v_state)
                                3'd2: begin
                                    if (cur_v_env <= t_sus_level + exp_dec_step) begin
                                        v_env_level[tdm_idx] <= t_sus_level;
                                        v_state[tdm_idx]     <= 3'd3;
                                    end else begin
                                        v_env_level[tdm_idx] <= cur_v_env - exp_dec_step;
                                    end
                                end
                                3'd3: begin
                                    if (t_env_mode == 2'd2) begin
                                        if (cur_v_env <= 16'd48) begin
                                            v_env_level[tdm_idx] <= 16'd0;
                                            v_state[tdm_idx]     <= 3'd0;
                                        end else if (atk_tick) begin
                                            v_env_level[tdm_idx] <= cur_v_env - ((cur_v_env >> 11) + 16'd1);
                                        end
                                    end else if (t_env_mode == 2'd1) begin
                                        if (cur_v_env <= 16'd32) begin
                                            v_env_level[tdm_idx] <= 16'd0;
                                            v_state[tdm_idx]     <= 3'd0;
                                        end else if (env_tick) begin
                                            v_env_level[tdm_idx] <= cur_v_env - ((cur_v_env >> 12) + 16'd1);
                                        end
                                    end else begin
                                        v_env_level[tdm_idx] <= t_sus_level;
                                    end
                                end
                                3'd4: begin
                                    if (cur_v_env <= exp_rel_step || cur_v_env <= 16'd24) begin
                                        v_env_level[tdm_idx] <= 16'd0;
                                        v_state[tdm_idx]     <= 3'd0;
                                    end else begin
                                        v_env_level[tdm_idx] <= cur_v_env - exp_rel_step;
                                    end
                                end
                                default: v_state[tdm_idx] <= 3'd0;
                            endcase
                        end

                        tdm_sub <= 3'd2;
                    end

                    // ---------------------------------------------------------
                    // 拍 2: FM 调制深度抗混叠缩放 + 载波相位寄存 + 15-bit 插值第 3 泛音
                    // ---------------------------------------------------------
                    3'd2: begin
                        if (pipe_hf_atten == 2'd2)
                            fm_env_scale = harm_env_sq_r[31:16] >> 2;
                        else if (pipe_hf_atten == 2'd1 || pipe_note >= 5'd11)
                            fm_env_scale = harm_env_sq_r[31:16] >> 1;
                        else
                            fm_env_scale = harm_env_sq_r[31:16];

                        fm_prod = fm_mod_r * $signed({1'b0, fm_env_scale});
                        if (test_en || pipe_fm_depth == 2'd0)
                            fm_phase_off15 = 15'sd0;
                        else if (pipe_fm_depth == 2'd1)
                            fm_phase_off15 = $signed(fm_prod[31:21]);
                        else
                            fm_phase_off15 = $signed(fm_prod[31:20]);

                        if (!test_en) begin
                            if (voice_oct_mode_r == 2'd1)
                                v_targ_step[tdm_idx] <= voice_lut_step_r >> 1;
                            else if (voice_oct_mode_r == 2'd2)
                                v_targ_step[tdm_idx] <= voice_lut_step_r << 1;
                            else
                                v_targ_step[tdm_idx] <= voice_lut_step_r;
                        end

                        carrier_ang15_r <= ang1_15_r + fm_phase_off15;
                        pipe_s2         <= fm_mod_r;
                        pipe_s3         <= shared_interp_val;
                        pipe_s4         <= sine_lut(ang4_r);

                        if (eff_vibrato && !test_en && !pipe_is_bass) begin
                            trem_prod    = $signed({2'b00, pipe_env[15:3]}) * trem_mod;
                            env_trem_tmp = $signed({2'b00, pipe_env}) + $signed(trem_prod[30:13]);
                            if (env_trem_tmp > 18'sd65535)
                                env_mod_val = 16'hFFFF;
                            else if (env_trem_tmp < 18'sd0)
                                env_mod_val = 16'd0;
                            else
                                env_mod_val = env_trem_tmp[15:0];
                        end else begin
                            env_mod_val = pipe_env;
                        end

                        env_mod_val_r <= env_mod_val;
                        tdm_sub       <= 3'd3;
                    end

                    // ---------------------------------------------------------
                    // 拍 3: 15-bit 线性插值 FM 载波查表 + 声部力度振幅配比
                    // ---------------------------------------------------------
                    3'd3: begin
                        pipe_s1 <= shared_interp_val;

                        vel_gain8      = {1'b0, pipe_vel} + 8'd1;
                        env_vel_prod   = env_mod_val_r * vel_gain8;
                        env_vel_scaled = env_vel_prod[22:7];

                        if (pipe_is_bass)
                            pipe_voice_env <= env_mod_val_r - (env_mod_val_r >> 2);
                        else if (pipe_is_arp)
                            pipe_voice_env <= (env_mod_val_r >> 1) + (env_mod_val_r >> 3);
                        else
                            pipe_voice_env <= env_vel_scaled;

                        tdm_sub <= 3'd4;
                    end

                    // ---------------------------------------------------------
                    // 拍 4: 动态泛音缩放 + 8 种声学物理合成配方
                    // ---------------------------------------------------------
                    3'd4: begin
                        s3_dyn_prod = pipe_s3 * $signed({1'b0, pipe_harm_env});
                        s3_dyn      = (pipe_hf_atten == 2'd2) ? ($signed(s3_dyn_prod[31:16]) >>> 1) : $signed(s3_dyn_prod[31:16]);
                        s2_dyn_prod = $signed(pipe_s2) * $signed({1'b0, pipe_harm_env[15:8]});
                        s2_dyn      = $signed(s2_dyn_prod[23:8]);

                        case (pipe_recipe)
                            3'd0: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s1) >>> 3) + ($signed(s2_dyn) >>> 2) + ($signed(s3_dyn) >>> 2);
                            3'd1: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s1) >>> 2) + ($signed(s3_dyn) >>> 2);
                            3'd2: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s2) >>> 2) + ($signed(pipe_s3) >>> 2);
                            3'd3: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s1) >>> 3) + ($signed(s2_dyn) >>> 2) + ($signed(s3_dyn) >>> 2);
                            3'd4: raw_sum = ($signed(pipe_s1) >>> 1) - ($signed(pipe_s2) >>> 2) + ($signed(pipe_s3) >>> 2);
                            3'd5: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s1) >>> 2) + ($signed(s2_dyn) >>> 3);
                            3'd6: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s1) >>> 3) + ($signed(s3_dyn) >>> 3) + ($signed(s3_dyn) >>> 4);
                            3'd7: raw_sum = ($signed(pipe_s1) >>> 1) + ($signed(pipe_s2) >>> 2) + ($signed(s3_dyn) >>> 2);
                        endcase

                        case (pipe_h4_amp)
                            2'd1: raw_sum = (pipe_recipe == 3'd4) ? (raw_sum - ($signed(pipe_s4) >>> 3))
                                                                  : (raw_sum + ($signed(pipe_s4) >>> 2));
                            2'd2: raw_sum = raw_sum + ($signed(pipe_s4) >>> 3);
                            2'd3: raw_sum = raw_sum + ($signed(pipe_s4) >>> 4);
                            default: ;
                        endcase

                        raw_wave_r <= raw_sum;
                        tdm_sub    <= 3'd5;
                    end

                    // ---------------------------------------------------------
                    // 拍 5: 声部包络乘法与混音累加 + 推进至下一声部 (0..63)
                    // ---------------------------------------------------------
                    3'd5: begin
                        if (pipe_active) begin
                            scaled_wave = raw_wave_r * $signed({1'b0, pipe_voice_env});
                            mix_acc     <= mix_acc + $signed(scaled_wave[34:14]);
                        end

                        tdm_sub <= 3'd0;
                        if (tdm_idx == 6'd63) begin
                            tdm_busy     <= 1'b0;
                            rel_all_Scan <= 1'b0;
                            post_ph      <= 3'd1;

                            if (alloc_req_eff && !alloc_commit_en) begin
                                alloc_commit_en   <= 1'b1;
                                alloc_commit_v    <= test_want ? test_voices_on[5:0] : search_best_voice;
                                alloc_commit_note <= test_want ? test_note : req_note;
                                alloc_commit_step <= test_step;
                                alloc_commit_vel  <= (test_want || req_note_vel < 7'd32) ? 7'd100 : req_note_vel;
                            end
                        end else begin
                            tdm_idx <= tdm_idx + 6'd1;
                        end
                    end

                    default: tdm_sub <= 3'd0;
                endcase
            end else if (post_ph != 3'd0) begin
                // =============================================================
                // 混音后 4 拍零底噪母带级流水线:
                //   - 向零对称舍入去直流 (shr9_z24) + 二阶温暖声学重构滤波 (fc ≈ 7.8kHz, 彻底滤除 PAM8403 互调底噪)
                //   - 静默态自动平滑归零 (0 LSB 绝对静音)
                // =============================================================
                case (post_ph)
                    3'd1: begin
                        voices_active <= sample_had_voice;
                        if (!sample_had_voice && (mix_acc == 24'sd0)) begin
                            dc_x1    <= 24'sd0;
                            dc_y1    <= dc_y1 - shr2_z24(dc_y1);
                            warm1_next = lp_warm1 - shr2_z24(lp_warm1);
                            warm2_next = lp_warm2 - shr2_z24(lp_warm2);
                            if (warm2_next >= -24'sd4 && warm2_next <= 24'sd4)
                                warm2_next = 24'sd0;
                        end else begin
                            dc_out     = mix_acc - dc_x1 + dc_y1 - shr9_z24(dc_y1);
                            dc_x1     <= mix_acc;
                            dc_y1     <= dc_out;

                            warm_diff1 = dc_out - lp_warm1;
                            warm1_next = lp_warm1 + shr1_z24(warm_diff1);
                            warm_diff2 = warm1_next - lp_warm2;
                            warm2_next = lp_warm2 + shr1_z24(warm_diff2);
                        end
                        lp_warm1 <= warm1_next;
                        lp_warm2 <= warm2_next;
                        warm_r   <= warm2_next;

                        mono_scaled = warm2_next >>> 2;
                        if (mono_scaled > 24'sd32767)
                            mono_sample <= 16'sd32767;
                        else if (mono_scaled < -24'sd32768)
                            mono_sample <= -16'sd32768;
                        else
                            mono_sample <= $signed(mono_scaled[15:0]);

                        if (vol_gain_slewed < cur_vol_gain)
                            vol_gain_slewed <= vol_gain_slewed + 11'sd1;
                        else if (vol_gain_slewed > cur_vol_gain)
                            vol_gain_slewed <= vol_gain_slewed - 11'sd1;

                        post_ph <= 3'd2;
                    end

                    3'd2: begin
                        vol_prod_r <= warm_r * vol_gain_slewed;
                        post_ph    <= 3'd3;
                    end

                    3'd3: begin
                        if (vol_prod_r > 35'sd33554431)
                            scaled_bus_r = 26'sd33554431;
                        else if (vol_prod_r < -35'sd33554432)
                            scaled_bus_r = -26'sd33554432;
                        else
                            scaled_bus_r = $signed(vol_prod_r[25:0]);

                        bus_abs = scaled_bus_r[25] ? -scaled_bus_r : scaled_bus_r;
                        if (!sample_had_voice && bus_abs <= 26'sd16) begin
                            bus_diff = 26'sd0;
                            bus_shf  = 26'sd0;
                            lim_mag  = 24'sd0; // 仅在无活跃声部静默期执行归零，彻底消除过零死区交越失真底噪
                        end else if (bus_abs < 26'sd6291456) begin
                            bus_diff = 26'sd0;
                            bus_shf  = 26'sd0;
                            lim_mag  = $signed(bus_abs[23:0]);
                        end else if (bus_abs < 26'sd7864320) begin
                            bus_diff = bus_abs - 26'sd6291456;
                            bus_shf  = bus_diff >>> 1;
                            lim_mag  = 24'sd6291456 + $signed(bus_shf[23:0]);
                        end else if (bus_abs < 26'sd11010048) begin
                            bus_diff = bus_abs - 26'sd7864320;
                            bus_shf  = bus_diff >>> 2;
                            lim_mag  = 24'sd7077888 + $signed(bus_shf[23:0]);
                        end else if (bus_abs < 26'sd15204352) begin
                            bus_diff = bus_abs - 26'sd11010048;
                            bus_shf  = bus_diff >>> 3;
                            lim_mag  = 24'sd7864320 + $signed(bus_shf[23:0]);
                        end else begin
                            bus_diff = 26'sd0;
                            bus_shf  = 26'sd0;
                            lim_mag  = 24'sd8388600;
                        end
                        lim_out_r <= scaled_bus_r[25] ? -lim_mag : lim_mag;
                        post_ph <= 3'd4;
                    end

                    3'd4: begin
                        pcm_out <= lim_out_r;
                        post_ph <= 3'd0;
                    end

                    default: post_ph <= 3'd0;
                endcase
            end

            if (test_cmd_vld) begin
                test_en         <= test_cmd_on;
                test_voices_on  <= 7'd0;
                pending_press   <= 18'd0;
                alloc_commit_en <= 1'b0;
                bass_pend       <= 1'b0;
                arp1_pend       <= 1'b0;
                arp2_pend       <= 1'b0;
                kill_alloc      <= 1'b1;
                rel_all_Scan    <= 1'b1;
            end
        end
    end

endmodule
