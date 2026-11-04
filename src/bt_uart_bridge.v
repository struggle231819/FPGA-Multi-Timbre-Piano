// =============================================================================
// 文件名: bt_uart_bridge.v
// 模块功能: JDY-23 蓝牙双引脚全自动收发容错 (H5 & J5 正反接均可双向收发!) + 双波特率自适应
//          (9600/115200) + 256 步在线歌曲下载 + 80ms 高精度实弹录音/回放/回传 + 智能伴奏指令控制
//          (针对 Serial Bluetooth Terminal 手机端做了单/双位十进制与十六进制指令全兼容优化)
// =============================================================================
module bt_uart_bridge #(
    parameter [23:0] REC_BEAT = 24'd3_999_999    // 80ms 高精度录音网格 (50MHz * 0.08s - 1)
) (
    input  wire        clk,              // 50MHz 系统时钟
    input  wire        rst_n,            // 低有效同步复位
    input  wire        bt_rx_h5,         // H5 引脚输入回读
    input  wire        bt_rx_j5,         // J5 引脚输入回读
    output wire        bt_tx_bit,        // FPGA 发送数据位 (= 移位寄存器 LSB)
    output reg         bt_tx_en_h5,      // H5 发送驱动使能 (当 J5 为接收脚时驱动 H5)
    output reg         bt_tx_en_j5,      // J5 发送驱动使能 (当 H5 为接收脚时驱动 J5)
    output reg         cmd_play_user,    // 触发播放用户下载/录音曲目 (Song 4)
    output reg         cmd_stop,         // 触发停止自动演奏
    output reg         cmd_song_vld,     // 触发指定曲目切换
    output reg  [2:0]  cmd_song_idx,     // 0..3: 内置名曲, 4: 手机下载/录音曲目
    output reg         cmd_timbre_vld,   // 触发手机切换音色
    output reg  [3:0]  cmd_timbre,       // 0..15 音色编号
    output reg         cmd_vol_vld,      // 触发手机调节音量
    output reg  [3:0]  cmd_vol,          // 0..15 音量等级
    output reg         cmd_vol_step_vld, // V+/V- 音量步进增减脉冲
    output reg         cmd_vol_up,       // 1=音量+1, 0=音量-1
    output reg  [17:0] bt_live_keys,     // 手机触屏琴键/流式伴奏实时发声掩码
    output reg         cmd_fx_vld,       // 效果器选择/单路开关有效脉冲
    output reg  [3:0]  cmd_fx_sel,       // 0..7=效果搭配, 8=翻转合唱, 9=翻转延迟, 10=翻转混响, 11=循环
    output reg         cmd_test_vld,     // 测试音指令有效脉冲
    output reg         cmd_test_on,      // 1=开启 64 路满复音测试音, 0=关闭
    output reg         cmd_vib_vld,      // Y 指令: 颤音开关有效脉冲
    output reg  [3:0]  cmd_vib_depth,    // 非0=开, 0=关
    output reg         cmd_glide_vld,    // Z/O 指令: 滑音开关有效脉冲
    output reg  [3:0]  cmd_glide_lvl,    // 非0=开, 0=关
    output reg         cmd_fxlv_vld,     // F 指令: 湿声强度有效脉冲
    output reg  [3:0]  cmd_fx_level,     // 湿声强度 0~15
    output reg         cmd_scene_vld,    // A 指令: 场景预设有效脉冲
    output reg  [2:0]  cmd_scene,        // 场景编号 0~7
    output reg         cmd_disp_vld,     // C 指令: 显示模式切换脉冲 (C0~C3)
    output reg  [1:0]  cmd_disp_mode,    // 0=分屏频谱+李萨如 1=全屏李萨如 2=全宽频谱 3=循环
    output reg         cmd_acc_vld,      // B 指令: 智能伴奏节奏型切换脉冲 (B0~B5)
    output reg  [2:0]  cmd_acc_mode,     // 0..4=指定模式, 5=循环下一节奏型
    output reg         cmd_tempo_vld,    // B6~B9 指令: 伴奏速度预设脉冲
    output reg  [1:0]  cmd_tempo_idx,    // 0=90BPM, 1=110BPM, 2=130BPM, 3=150BPM
    output reg         rec_active,       // 录音进行中指示
    output reg         user_is_highres,  // 1=第5槽为80ms高精度实弹录音, 0=240ms简谱/W编曲
    input  wire [17:0] rec_keys,         // 玩家实时按键 (物理|手机), 高有效
    input  wire [7:0]  user_rd_addr,     // 当前拍地址 0..255
    input  wire [7:0]  user_next_addr,   // 下一拍地址 0..255
    output reg  [18:0] user_rd_word,     // 当前拍 {retrig, keys[17:0]}
    output reg  [18:0] user_next_word,   // 下一拍 {retrig, keys[17:0]}
    output reg  [7:0]  user_last_step,   // 下载/录音的最后一拍索引 (0..255)
    output reg  signed [5:0] transpose_semi // 蓝牙自定义移调半音偏移 (-24..+24, 默认 0)
);

    // =========================================================================
    // 1. H5 与 J5 双引脚同步、自动接收脚识别与自发自收隔离
    // =========================================================================
    reg [2:0] h5_sync; // H5
    reg [2:0] j5_sync; // J5
    always @(posedge clk) begin
        if (!rst_n) begin
            h5_sync <= 3'b111;
            j5_sync <= 3'b111;
        end else begin
            h5_sync <= {h5_sync[1:0], bt_rx_h5};
            j5_sync <= {j5_sync[1:0], bt_rx_j5};
        end
    end

    wire rx_en;
    wire h5_in  = bt_tx_en_h5 ? 1'b1 : h5_sync[2];
    wire j5_in  = bt_tx_en_j5 ? 1'b1 : j5_sync[2];
    wire rx_pin = rx_en ? (h5_in & j5_in) : 1'b1;

    reg  rx_pin_d;
    reg  rx_from_j5;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_pin_d   <= 1'b1;
            rx_from_j5 <= 1'b0;
        end else begin
            rx_pin_d <= rx_pin;
            if (rx_en && !rx_pin && rx_pin_d) begin
                if (!j5_in && h5_in)
                    rx_from_j5 <= 1'b1;
                else if (!h5_in && j5_in)
                    rx_from_j5 <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 2. 硬件脉冲宽度自适应波特率检测 (9600 vs 115200 bps, 发送期间冻结锁定)
    // =========================================================================
    reg        is_115200;
    reg        is_115200_d;
    reg [15:0] low_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            is_115200   <= 1'b0;
            is_115200_d <= 1'b0;
            low_cnt     <= 16'd0;
        end else if (rx_en) begin
            is_115200_d <= is_115200;
            if (!rx_pin) begin
                if (low_cnt != 16'hFFFF)
                    low_cnt <= low_cnt + 16'd1;
                if (low_cnt >= 16'd4500)
                    is_115200 <= 1'b0;
            end else begin
                if (!rx_pin_d) begin
                    if (low_cnt >= 16'd350 && low_cnt <= 16'd4100)
                        is_115200 <= 1'b1;
                end
                low_cnt <= 16'd0;
            end
        end else begin
            low_cnt <= 16'd0;
        end
    end

    wire [12:0] baud_div  = is_115200 ? 13'd433  : 13'd5207;
    wire [12:0] baud_half = is_115200 ? 13'd216  : 13'd2603;

    reg        rx_busy;
    reg [12:0] rx_cnt;
    reg [3:0]  rx_bit_idx;
    reg [7:0]  rx_shift;
    reg        rx_vld;
    reg [7:0]  rx_byte;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_busy    <= 1'b0;
            rx_cnt     <= 13'd0;
            rx_bit_idx <= 4'd0;
            rx_shift   <= 8'd0;
            rx_vld     <= 1'b0;
            rx_byte    <= 8'd0;
        end else begin
            rx_vld <= 1'b0;
            if (!rx_en) begin
                rx_busy <= 1'b0;
                rx_cnt  <= 13'd0;
            end else if (!rx_busy) begin
                if (!rx_pin && rx_pin_d) begin
                    rx_busy    <= 1'b1;
                    rx_cnt     <= 13'd0;
                    rx_bit_idx <= 4'd0;
                end
            end else begin
                if (rx_bit_idx == 4'd0) begin
                    if (rx_cnt >= baud_half) begin
                        if (!rx_pin) begin
                            rx_cnt     <= 13'd0;
                            rx_bit_idx <= 4'd1;
                        end else begin
                            rx_busy <= 1'b0;
                        end
                    end else begin
                        rx_cnt <= rx_cnt + 13'd1;
                    end
                end else if (rx_cnt >= baud_div) begin
                    rx_cnt <= 13'd0;
                    if (rx_bit_idx <= 4'd8) begin
                        rx_shift   <= {rx_pin, rx_shift[7:1]};
                        rx_bit_idx <= rx_bit_idx + 4'd1;
                    end else begin
                        rx_busy <= 1'b0;
                        if (rx_pin) begin
                            rx_vld  <= 1'b1;
                            rx_byte <= rx_shift;
                        end
                    end
                end else begin
                    rx_cnt <= rx_cnt + 13'd1;
                end
            end
        end
    end

    // =========================================================================
    // 3. 256 步用户歌曲同步 BSRAM
    // =========================================================================
    reg [18:0] user_ram [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) user_ram[i] = 19'h00000;
        user_ram[0]  = 19'h40001; user_ram[1]  = 19'h40001;
        user_ram[2]  = 19'h40081; user_ram[3]  = 19'h40081;
        user_ram[4]  = 19'h40220; user_ram[5]  = 19'h40220;
        user_ram[6]  = 19'h40081; user_ram[7]  = 19'h00081;
        user_ram[8]  = 19'h40021; user_ram[9]  = 19'h40021;
        user_ram[10] = 19'h40011; user_ram[11] = 19'h40011;
        user_ram[12] = 19'h40004; user_ram[13] = 19'h40004;
        user_ram[14] = 19'h40091; user_ram[15] = 19'h00091;
    end

    reg        ram_we;
    reg [7:0]  ram_waddr;
    reg [18:0] ram_wdata;

    reg [1:0]  rd_slot;
    reg [1:0]  rd_slot_d;
    reg [7:0]  ram_raddr;
    reg [18:0] ram_rdata;
    reg [18:0] dump_word;
    reg [7:0]  dump_idx;

    always @(*) begin
        case (rd_slot)
            2'd0:    ram_raddr = user_rd_addr;
            2'd1:    ram_raddr = user_next_addr;
            default: ram_raddr = dump_idx;
        endcase
    end

    always @(posedge clk) begin
        if (ram_we)
            user_ram[ram_waddr] <= ram_wdata;
        ram_rdata <= user_ram[ram_raddr];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_slot        <= 2'd0;
            rd_slot_d      <= 2'd0;
            user_rd_word   <= 19'h40001;
            user_next_word <= 19'h40001;
            dump_word      <= 19'h40001;
        end else begin
            rd_slot   <= (rd_slot == 2'd2) ? 2'd0 : (rd_slot + 2'd1);
            rd_slot_d <= rd_slot;
            case (rd_slot_d)
                2'd0: user_rd_word   <= ram_rdata;
                2'd1: user_next_word <= ram_rdata;
                2'd2: dump_word      <= ram_rdata;
                default: ;
            endcase
        end
    end

    function [4:0] hex_to_nib;
        input [7:0] ch;
        begin
            case (ch)
                8'h30: hex_to_nib = 5'b1_0000;
                8'h31: hex_to_nib = 5'b1_0001;
                8'h32: hex_to_nib = 5'b1_0010;
                8'h33: hex_to_nib = 5'b1_0011;
                8'h34: hex_to_nib = 5'b1_0100;
                8'h35: hex_to_nib = 5'b1_0101;
                8'h36: hex_to_nib = 5'b1_0110;
                8'h37: hex_to_nib = 5'b1_0111;
                8'h38: hex_to_nib = 5'b1_1000;
                8'h39: hex_to_nib = 5'b1_1001;
                8'h41, 8'h61: hex_to_nib = 5'b1_1010;
                8'h42, 8'h62: hex_to_nib = 5'b1_1011;
                8'h43, 8'h63: hex_to_nib = 5'b1_1100;
                8'h44, 8'h64: hex_to_nib = 5'b1_1101;
                8'h45, 8'h65: hex_to_nib = 5'b1_1110;
                8'h46, 8'h66: hex_to_nib = 5'b1_1111;
                default: hex_to_nib = 5'b0_0000;
            endcase
        end
    endfunction

    function [7:0] nib_ascii;
        input [3:0] n;
        nib_ascii = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    endfunction

    function [17:0] jianpu_to_mask;
        input [7:0] ch;
        begin
            case (ch)
                "1": jianpu_to_mask = 18'h00001;
                "!": jianpu_to_mask = 18'h00002;
                "2": jianpu_to_mask = 18'h00004;
                "@": jianpu_to_mask = 18'h00008;
                "3": jianpu_to_mask = 18'h00011;
                "4": jianpu_to_mask = 18'h00021;
                "$": jianpu_to_mask = 18'h00040;
                "5": jianpu_to_mask = 18'h00081;
                "%": jianpu_to_mask = 18'h00100;
                "6": jianpu_to_mask = 18'h00220;
                "^": jianpu_to_mask = 18'h00400;
                "7": jianpu_to_mask = 18'h00880;
                "h", "H", "8": jianpu_to_mask = 18'h01011;
                "#":           jianpu_to_mask = 18'h02000;
                "i", "I", "9": jianpu_to_mask = 18'h04080;
                "(":           jianpu_to_mask = 18'h08000;
                "j", "J":      jianpu_to_mask = 18'h10081;
                "l", "L":      jianpu_to_mask = 18'h20220;
                default:       jianpu_to_mask = 18'h00000;
            endcase
        end
    endfunction

    // =========================================================================
    // 4. 蓝牙指令状态机 + 80ms 高精度实弹录音引擎
    // =========================================================================
    localparam [4:0] ST_IDLE      = 5'd0;
    localparam [4:0] ST_CMD_M     = 5'd1;
    localparam [4:0] ST_CMD_T     = 5'd2;
    localparam [4:0] ST_CMD_V     = 5'd3;
    localparam [4:0] ST_W_ADDR    = 5'd4;
    localparam [4:0] ST_W_DATA    = 5'd5;
    localparam [4:0] ST_SKIP_LINE = 5'd6;
    localparam [4:0] ST_CMD_K     = 5'd7;
    localparam [4:0] ST_CMD_D     = 5'd8;
    localparam [4:0] ST_CMD_U     = 5'd9;
    localparam [4:0] ST_CMD_E     = 5'd10;
    localparam [4:0] ST_CMD_X     = 5'd11;
    localparam [4:0] ST_CMD_Y     = 5'd12;
    localparam [4:0] ST_CMD_Z     = 5'd13;
    localparam [4:0] ST_CMD_O     = 5'd14;
    localparam [4:0] ST_CMD_F     = 5'd15;
    localparam [4:0] ST_CMD_A     = 5'd16;
    localparam [4:0] ST_CMD_C     = 5'd17;
    localparam [4:0] ST_CMD_B     = 5'd18;
    localparam [4:0] ST_CMD_T2    = 5'd19;
    localparam [4:0] ST_CMD_V2    = 5'd20;
    localparam [4:0] ST_CMD_E2    = 5'd21;
    localparam [4:0] ST_CMD_F2    = 5'd22;
    localparam [4:0] ST_CMD_Q     = 5'd23;
    localparam [4:0] ST_CMD_Q_POS = 5'd24;
    localparam [4:0] ST_CMD_Q_NEG = 5'd25;
    localparam [4:0] ST_CMD_Q_D2  = 5'd26;
    localparam [4:0] ST_CMD_Q_KEY = 5'd27;

    reg [4:0]  parse_st;
    reg        q_neg;
    reg [1:0]  q_d1;
    reg [17:0] q_wait_cnt;
    reg [17:0] tr_echo_wait_cnt;
    reg        tr_echo_pending;
    wire       tr_echo_done;
    reg        prev_d1;
    reg        w_session_act;
    reg [7:0]  wr_ptr;
    reg [17:0] last_mask;
    reg [1:0]  w_addr_cnt;
    reg [2:0]  w_data_cnt;
    reg [7:0]  w_addr_reg;
    reg [19:0] w_data_reg;
    reg [5:0]  skip_cnt;

    reg [23:0] live_key_cnt;
    reg [17:0] held_keys;
    reg [17:0] pulse_keys;

    reg        rec_started;
    reg [23:0] rec_grid;
    reg [7:0]  rec_idx;
    reg [17:0] rec_prev;
    reg [17:0] rec_keys_d;
    reg [17:0] step_key_latch;
    reg        step_retrig_latch;

    reg        dump_pending;
    wire       dump_done;

    wire [4:0] nib = hex_to_nib(rx_byte);
    wire       is_dec_digit = (rx_byte >= 8'h30 && rx_byte <= 8'h39);
    wire [3:0] dec_2digit   = prev_d1 ? (4'd10 + nib[3:0]) : nib[3:0];
    wire       wr_full      = (wr_ptr == 8'd255);
    wire [3:0] tempo_sub    = nib[3:0] - 4'd6;

    // 自定义移调算术辅助信号 (-24 ~ +24 半音, 覆盖 ±2 个八度)
    wire signed [5:0] trans_inc1      = (transpose_semi < 6'sd24)  ? (transpose_semi + 6'sd1) : 6'sd24;
    wire signed [5:0] trans_dec1      = (transpose_semi > -6'sd24) ? (transpose_semi - 6'sd1) : -6'sd24;
    wire signed [6:0] trans_add12     = $signed({transpose_semi[5], transpose_semi}) + 7'sd12;
    wire signed [6:0] trans_sub12     = $signed({transpose_semi[5], transpose_semi}) - 7'sd12;
    wire signed [5:0] trans_inc12     = (trans_add12 > 7'sd24)  ? 6'sd24  : trans_add12[5:0];
    wire signed [5:0] trans_dec12     = (trans_sub12 < -7'sd24) ? -6'sd24 : trans_sub12[5:0];
    wire signed [5:0] q_1digit_pos    = $signed({2'b00, nib[3:0]});
    wire signed [5:0] q_1digit_neg    = -$signed({2'b00, nib[3:0]});
    wire [4:0]        q_2digit_raw    = (q_d1 == 2'd2) ? (5'd20 + {1'b0, nib[3:0]}) :
                                        (q_d1 == 2'd1) ? (5'd10 + {1'b0, nib[3:0]}) :
                                                         {1'b0, nib[3:0]};
    wire [4:0]        q_2digit_lim    = (q_2digit_raw > 5'd24) ? 5'd24 : q_2digit_raw;
    wire signed [5:0] q_2digit_signed = q_neg ? (-$signed({1'b0, q_2digit_lim})) : $signed({1'b0, q_2digit_lim});

    always @(*) begin
        bt_live_keys = held_keys | pulse_keys;
    end

    wire [17:0] new_key_edge  = rec_keys & ~rec_keys_d;
    wire [17:0] eff_step_keys = (|rec_keys) ? rec_keys : step_key_latch;
    wire        eff_retrig    = step_retrig_latch || ((|eff_step_keys) && (eff_step_keys != rec_prev) && ((eff_step_keys & ~rec_prev) != 18'd0));

    always @(posedge clk) begin
        if (!rst_n) begin
            parse_st          <= ST_IDLE;
            prev_d1           <= 1'b0;
            w_session_act     <= 1'b0;
            wr_ptr            <= 8'd0;
            user_last_step    <= 8'd15;
            user_is_highres   <= 1'b0;
            last_mask         <= 18'd0;
            w_addr_cnt        <= 2'd0;
            w_data_cnt        <= 3'd0;
            w_addr_reg        <= 8'd0;
            w_data_reg        <= 20'd0;
            skip_cnt          <= 6'd0;
            cmd_play_user     <= 1'b0;
            cmd_stop          <= 1'b0;
            cmd_song_vld      <= 1'b0;
            cmd_song_idx      <= 3'd0;
            cmd_timbre_vld    <= 1'b0;
            cmd_timbre        <= 4'd0;
            cmd_vol_vld       <= 1'b0;
            cmd_vol           <= 4'd8;
            cmd_vol_step_vld  <= 1'b0;
            cmd_vol_up        <= 1'b0;
            cmd_fx_vld        <= 1'b0;
            cmd_fx_sel        <= 4'd0;
            cmd_test_vld      <= 1'b0;
            cmd_test_on       <= 1'b0;
            cmd_vib_vld       <= 1'b0;
            cmd_vib_depth     <= 4'd0;
            cmd_glide_vld     <= 1'b0;
            cmd_glide_lvl     <= 4'd0;
            cmd_fxlv_vld      <= 1'b0;
            cmd_fx_level      <= 4'd8;
            cmd_scene_vld     <= 1'b0;
            cmd_scene         <= 3'd0;
            cmd_disp_vld      <= 1'b0;
            cmd_disp_mode     <= 2'd0;
            cmd_acc_vld       <= 1'b0;
            cmd_acc_mode      <= 3'd1;
            cmd_tempo_vld     <= 1'b0;
            cmd_tempo_idx     <= 2'd0;
            held_keys         <= 18'd0;
            pulse_keys        <= 18'd0;
            live_key_cnt      <= 24'd0;
            rec_active        <= 1'b0;
            rec_started       <= 1'b0;
            rec_grid          <= 24'd0;
            rec_idx           <= 8'd0;
            rec_prev          <= 18'd0;
            rec_keys_d        <= 18'd0;
            step_key_latch    <= 18'd0;
            step_retrig_latch <= 1'b0;
            dump_pending      <= 1'b0;
            ram_we            <= 1'b0;
            ram_waddr         <= 8'd0;
            ram_wdata         <= 19'd0;
            transpose_semi    <= 6'sd0;
            q_neg             <= 1'b0;
            q_d1              <= 2'd0;
            q_wait_cnt        <= 18'd0;
            tr_echo_wait_cnt  <= 18'd0;
            tr_echo_pending   <= 1'b0;
        end else begin
            cmd_play_user    <= 1'b0;
            cmd_stop         <= 1'b0;
            cmd_song_vld     <= 1'b0;
            cmd_timbre_vld   <= 1'b0;
            cmd_vol_vld      <= 1'b0;
            cmd_vol_step_vld <= 1'b0;
            cmd_fx_vld       <= 1'b0;
            cmd_test_vld     <= 1'b0;
            cmd_vib_vld      <= 1'b0;
            cmd_glide_vld    <= 1'b0;
            cmd_fxlv_vld     <= 1'b0;
            cmd_scene_vld    <= 1'b0;
            cmd_disp_vld     <= 1'b0;
            cmd_acc_vld      <= 1'b0;
            cmd_tempo_vld    <= 1'b0;
            ram_we           <= 1'b0;
            rec_keys_d       <= rec_keys;

            if (is_115200 != is_115200_d)
                parse_st <= ST_IDLE;

            if (live_key_cnt != 24'd0) begin
                live_key_cnt <= live_key_cnt - 24'd1;
                if (live_key_cnt == 24'd1) pulse_keys <= 18'd0;
            end

            if (dump_done)    dump_pending    <= 1'b0;
            if (tr_echo_done) tr_echo_pending <= 1'b0;

            if (tr_echo_wait_cnt != 18'd0) begin
                if (rx_vld && rx_en) begin
                    tr_echo_wait_cnt <= 18'd250_000;
                end else begin
                    tr_echo_wait_cnt <= tr_echo_wait_cnt - 18'd1;
                    if (tr_echo_wait_cnt == 18'd1)
                        tr_echo_pending <= 1'b1;
                end
            end

            if (q_wait_cnt != 18'd0) begin
                if (!(rx_vld && rx_en)) begin
                    q_wait_cnt <= q_wait_cnt - 18'd1;
                    if (q_wait_cnt == 18'd1) begin
                        if (parse_st == ST_CMD_Q_POS) begin
                            transpose_semi   <= trans_inc1;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (parse_st == ST_CMD_Q_NEG) begin
                            transpose_semi   <= trans_dec1;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (parse_st == ST_CMD_Q) begin
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (parse_st == ST_CMD_Q_D2 || parse_st == ST_CMD_Q_KEY) begin
                            parse_st         <= ST_IDLE;
                        end
                    end
                end
            end

            // ---------------- 80ms 高精度实弹录音引擎 ----------------
            if (rec_active) begin
                if (!rec_started) begin
                    if (|rec_keys) begin
                        rec_started       <= 1'b1;
                        rec_grid          <= 24'd0;
                        rec_idx           <= 8'd0;
                        step_key_latch    <= rec_keys;
                        step_retrig_latch <= 1'b1;
                    end
                end else begin
                    if (|new_key_edge) begin
                        step_key_latch    <= step_key_latch | rec_keys;
                        step_retrig_latch <= 1'b1;
                    end else if (|rec_keys) begin
                        step_key_latch    <= step_key_latch | rec_keys;
                    end

                    if (rec_grid >= REC_BEAT) begin
                        rec_grid          <= 24'd0;
                        ram_we            <= 1'b1;
                        ram_waddr         <= rec_idx;
                        ram_wdata         <= {eff_retrig, eff_step_keys};
                        rec_prev          <= eff_step_keys;
                        step_key_latch    <= rec_keys;
                        step_retrig_latch <= 1'b0;

                        if ((|eff_step_keys) || (|rec_prev) || (rec_idx == 8'd0))
                            user_last_step <= rec_idx;

                        if (rec_idx == 8'd255) begin
                            rec_active  <= 1'b0;
                            rec_started <= 1'b0;
                        end else begin
                            rec_idx <= rec_idx + 8'd1;
                        end
                    end else begin
                        rec_grid <= rec_grid + 24'd1;
                    end
                end
            end

            // ---------------- 指令解析 ----------------
            if (rx_vld && rx_en) begin
                case (parse_st)
                    ST_IDLE: begin
                        case (rx_byte)
                            "+": begin
                                parse_st <= ST_SKIP_LINE;
                                skip_cnt <= 6'd0;
                            end
                            "N", "n": begin
                                cmd_stop        <= 1'b1;
                                rec_active      <= 1'b0;
                                rec_started     <= 1'b0;
                                user_is_highres <= 1'b0;
                                w_session_act   <= 1'b0;
                                wr_ptr          <= 8'd0;
                                user_last_step  <= 8'd0;
                                last_mask       <= 18'd0;
                            end
                            "P", "p": begin
                                held_keys     <= 18'd0;
                                pulse_keys    <= 18'd0;
                                rec_active    <= 1'b0;
                                rec_started   <= 1'b0;
                                cmd_play_user <= 1'b1;
                            end
                            "S", "s": begin
                                cmd_stop    <= 1'b1;
                                rec_active  <= 1'b0;
                                rec_started <= 1'b0;
                                held_keys   <= 18'd0;
                                pulse_keys  <= 18'd0;
                            end
                            "G", "g": begin
                                rec_active        <= ~rec_active;
                                rec_started       <= 1'b0;
                                w_session_act     <= 1'b0;
                                cmd_stop          <= 1'b1;
                                rec_grid          <= 24'd0;
                                rec_idx           <= 8'd0;
                                rec_prev          <= 18'd0;
                                step_key_latch    <= 18'd0;
                                step_retrig_latch <= 1'b0;
                                if (!rec_active) begin
                                    user_is_highres <= 1'b1;
                                    user_last_step  <= 8'd0;
                                end
                            end
                            "R", "r": begin
                                rec_active   <= 1'b0;
                                rec_started  <= 1'b0;
                                if (!dump_pending)
                                    dump_pending <= 1'b1;
                            end
                            "K", "k": parse_st <= ST_CMD_K;
                            "D", "d": parse_st <= ST_CMD_D;
                            "U", "u": parse_st <= ST_CMD_U;
                            "E", "e": parse_st <= ST_CMD_E;
                            "X", "x": parse_st <= ST_CMD_X;
                            "Y", "y": parse_st <= ST_CMD_Y;
                            "Z", "z": parse_st <= ST_CMD_Z;
                            "O", "o": parse_st <= ST_CMD_O;
                            "F", "f": parse_st <= ST_CMD_F;
                            "A", "a": parse_st <= ST_CMD_A;
                            "C", "c": parse_st <= ST_CMD_C;
                            "B", "b": parse_st <= ST_CMD_B;
                            "M", "m": parse_st <= ST_CMD_M;
                            "T", "t": parse_st <= ST_CMD_T;
                            "V", "v": parse_st <= ST_CMD_V;
                            "Q", "q": begin
                                parse_st   <= ST_CMD_Q;
                                q_wait_cnt <= 18'd125_000;
                            end
                            "<": begin
                                transpose_semi   <= trans_dec1;
                                tr_echo_wait_cnt <= 18'd250_000;
                            end
                            ">": begin
                                transpose_semi   <= trans_inc1;
                                tr_echo_wait_cnt <= 18'd250_000;
                            end
                            "W", "w": begin
                                if (!rec_active) begin
                                    parse_st      <= ST_W_ADDR;
                                    w_addr_cnt    <= 2'd0;
                                    w_addr_reg    <= 8'd0;
                                end
                            end
                            "1", "!", "2", "@", "3", "4", "$", "5", "%", "6", "^", "7",
                            "8", "h", "H", "#", "9", "i", "I", "(", "j", "J", "l", "L": begin
                                if (!rec_active) begin
                                    ram_we          <= 1'b1;
                                    ram_waddr       <= wr_ptr;
                                    ram_wdata       <= {1'b1, jianpu_to_mask(rx_byte)};
                                    user_last_step  <= wr_ptr;
                                    user_is_highres <= 1'b0;
                                    w_session_act   <= 1'b0;
                                    last_mask       <= jianpu_to_mask(rx_byte);
                                    if (!wr_full) wr_ptr <= wr_ptr + 8'd1;
                                    pulse_keys      <= jianpu_to_mask(rx_byte);
                                    live_key_cnt    <= 24'd10_000_000;
                                end
                            end
                            "-": begin
                                if (!rec_active) begin
                                    ram_we         <= 1'b1;
                                    ram_waddr      <= wr_ptr;
                                    ram_wdata      <= {1'b0, last_mask};
                                    user_last_step <= wr_ptr;
                                    w_session_act  <= 1'b0;
                                    if (!wr_full) wr_ptr <= wr_ptr + 8'd1;
                                end
                            end
                            "0": begin
                                if (!rec_active) begin
                                    ram_we         <= 1'b1;
                                    ram_waddr      <= wr_ptr;
                                    ram_wdata      <= 19'h00000;
                                    user_last_step <= wr_ptr;
                                    w_session_act  <= 1'b0;
                                    last_mask      <= 18'd0;
                                    if (!wr_full) wr_ptr <= wr_ptr + 8'd1;
                                    pulse_keys     <= 18'd0;
                                end
                            end
                            default: ;
                        endcase
                    end

                    ST_CMD_M: begin
                        if (rx_byte >= 8'h30 && rx_byte <= 8'h35) begin
                            cmd_song_vld <= 1'b1;
                            cmd_song_idx <= rx_byte[2:0];
                            held_keys    <= 18'd0;
                            pulse_keys   <= 18'd0;
                        end else if (rx_byte == "+" || rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_song_vld <= 1'b1;
                            cmd_song_idx <= 3'd5;
                            held_keys    <= 18'd0;
                            pulse_keys   <= 18'd0;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_T: begin
                        if (nib[4]) begin
                            cmd_timbre_vld <= 1'b1;
                            cmd_timbre     <= nib[3:0];
                            if (nib[3:0] <= 4'd1) begin
                                prev_d1  <= nib[0];
                                parse_st <= ST_CMD_T2;
                            end else begin
                                parse_st <= ST_IDLE;
                            end
                        end else if (rx_byte == "+" || rx_byte == "=" || rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_timbre_vld <= 1'b1;
                            cmd_timbre     <= 4'd12; // 下一音色
                            parse_st       <= ST_IDLE;
                        end else if (rx_byte == "-") begin
                            cmd_timbre_vld <= 1'b1;
                            cmd_timbre     <= 4'd13; // 上一音色
                            parse_st       <= ST_IDLE;
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_CMD_T2: begin
                        if (is_dec_digit && dec_2digit <= 4'd11) begin
                            cmd_timbre_vld <= 1'b1;
                            cmd_timbre     <= dec_2digit;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_V: begin
                        if (nib[4]) begin
                            cmd_vol_vld <= 1'b1;
                            cmd_vol     <= nib[3:0];
                            if (nib[3:0] <= 4'd1) begin
                                prev_d1  <= nib[0];
                                parse_st <= ST_CMD_V2;
                            end else begin
                                parse_st <= ST_IDLE;
                            end
                        end else if (rx_byte == "+" || rx_byte == "=") begin
                            cmd_vol_step_vld <= 1'b1;
                            cmd_vol_up       <= 1'b1;
                            parse_st         <= ST_IDLE;
                        end else if (rx_byte == "-") begin
                            cmd_vol_step_vld <= 1'b1;
                            cmd_vol_up       <= 1'b0;
                            parse_st         <= ST_IDLE;
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_CMD_V2: begin
                        if (is_dec_digit) begin
                            cmd_vol_vld <= 1'b1;
                            cmd_vol     <= dec_2digit;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_E: begin
                        if (nib[4]) begin
                            cmd_fx_vld <= 1'b1;
                            cmd_fx_sel <= nib[3:0];
                            if (nib[3:0] <= 4'd1) begin
                                prev_d1  <= nib[0];
                                parse_st <= ST_CMD_E2;
                            end else begin
                                parse_st <= ST_IDLE;
                            end
                        end else if (rx_byte == "+" || rx_byte == "=" || rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_fx_vld <= 1'b1;
                            cmd_fx_sel <= 4'd11; // 循环切换当前音色的下一适配搭配
                            parse_st   <= ST_IDLE;
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_CMD_E2: begin
                        if (is_dec_digit && dec_2digit <= 4'd11) begin
                            cmd_fx_vld <= 1'b1;
                            cmd_fx_sel <= dec_2digit;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_X: begin
                        if (nib[4]) begin
                            cmd_test_vld <= 1'b1;
                            cmd_test_on  <= nib[0];
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_Y: begin
                        if (nib[4]) begin
                            cmd_vib_vld   <= 1'b1;
                            cmd_vib_depth <= nib[3:0];
                        end else if (rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_vib_vld   <= 1'b1;
                            cmd_vib_depth <= (cmd_vib_depth == 4'd0) ? 4'd1 : 4'd0;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_Z, ST_CMD_O: begin
                        if (nib[4]) begin
                            cmd_glide_vld <= 1'b1;
                            cmd_glide_lvl <= nib[3:0];
                        end else if (rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_glide_vld <= 1'b1;
                            cmd_glide_lvl <= (cmd_glide_lvl == 4'd0) ? 4'd1 : 4'd0;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_F: begin
                        if (nib[4]) begin
                            cmd_fxlv_vld <= 1'b1;
                            cmd_fx_level <= nib[3:0];
                            if (nib[3:0] <= 4'd1) begin
                                prev_d1  <= nib[0];
                                parse_st <= ST_CMD_F2;
                            end else begin
                                parse_st <= ST_IDLE;
                            end
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_CMD_F2: begin
                        if (is_dec_digit) begin
                            cmd_fxlv_vld <= 1'b1;
                            cmd_fx_level <= dec_2digit;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_A: begin
                        if (nib[4]) begin
                            cmd_scene_vld <= 1'b1;
                            cmd_scene     <= nib[2:0];
                        end else if (rx_byte == "+" || rx_byte == "=" || rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_scene_vld <= 1'b1;
                            cmd_scene     <= 3'd4; // 循环切换 4 大工作模式 (等效按 S1)
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_C: begin
                        if (nib[4]) begin
                            cmd_disp_vld  <= 1'b1;
                            cmd_disp_mode <= nib[1:0];
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_B: begin
                        if (nib[4]) begin
                            if (nib[3:0] <= 4'd5) begin
                                cmd_acc_vld  <= 1'b1;
                                cmd_acc_mode <= nib[2:0];
                            end else if (nib[3:0] <= 4'd9) begin
                                cmd_tempo_vld <= 1'b1;
                                cmd_tempo_idx <= tempo_sub[1:0];
                            end
                        end else if (rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            cmd_acc_vld  <= 1'b1;
                            cmd_acc_mode <= 3'd5; // 循环切换至下一伴奏节奏型
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_W_ADDR: begin
                        if (rx_byte == ":") begin
                            parse_st   <= ST_W_DATA;
                            w_data_cnt <= 3'd0;
                            w_data_reg <= 20'd0;
                        end else if (nib[4] && w_addr_cnt < 2'd2) begin
                            w_addr_reg <= {w_addr_reg[3:0], nib[3:0]};
                            w_addr_cnt <= w_addr_cnt + 2'd1;
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_W_DATA: begin
                        if (nib[4]) begin
                            if (w_data_cnt == 3'd4) begin
                                ram_we         <= 1'b1;
                                ram_waddr      <= w_addr_reg;
                                ram_wdata      <= {w_data_reg[14:0], nib[3:0]};
                                if (!w_session_act && w_addr_reg == 8'd0) begin
                                    user_last_step <= 8'd0;
                                    w_session_act  <= 1'b1;
                                end else if (w_addr_reg > user_last_step) begin
                                    user_last_step <= w_addr_reg;
                                    w_session_act  <= 1'b1;
                                end
                                pulse_keys     <= {w_data_reg[13:0], nib[3:0]};
                                live_key_cnt   <= 24'd6_000_000;
                                parse_st       <= ST_IDLE;
                            end else begin
                                w_data_reg <= {w_data_reg[15:0], nib[3:0]};
                                w_data_cnt <= w_data_cnt + 3'd1;
                            end
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_SKIP_LINE: begin
                        if (rx_byte == 8'h0A || rx_byte == 8'h0D)
                            parse_st <= ST_IDLE;
                        else if (skip_cnt >= 6'd62)
                            parse_st <= ST_IDLE;
                        else
                            skip_cnt <= skip_cnt + 6'd1;
                    end

                    ST_CMD_K: begin
                        if (rx_byte >= 8'h41 && rx_byte <= 8'h52) begin
                            pulse_keys   <= (18'd1 << (rx_byte - 8'h41));
                            live_key_cnt <= 24'd11_000_000;
                            parse_st     <= ST_IDLE;
                        end else if (rx_byte >= 8'h61 && rx_byte <= 8'h72) begin
                            pulse_keys   <= (18'd1 << (rx_byte - 8'h61));
                            live_key_cnt <= 24'd11_000_000;
                            parse_st     <= ST_IDLE;
                        end else if (rx_byte == "+" || rx_byte == "=") begin
                            parse_st   <= ST_CMD_Q_POS;
                            q_wait_cnt <= 18'd125_000;
                        end else if (rx_byte == "-") begin
                            parse_st   <= ST_CMD_Q_NEG;
                            q_wait_cnt <= 18'd125_000;
                        end else if (rx_byte == ">") begin
                            transpose_semi   <= trans_inc12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (rx_byte == "<") begin
                            transpose_semi   <= trans_dec12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (is_dec_digit) begin
                            transpose_semi   <= q_1digit_pos;
                            tr_echo_wait_cnt <= 18'd250_000;
                            if (nib[3:0] <= 4'd2) begin
                                q_neg      <= 1'b0;
                                q_d1       <= nib[1:0];
                                q_wait_cnt <= 18'd125_000;
                                parse_st   <= ST_CMD_Q_D2;
                            end else begin
                                parse_st   <= ST_IDLE;
                            end
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    // ---------------- 蓝牙自定义移调指令 (Q / K) ----------------
                    // 支持:
                    //   1. 直接指定半音偏移 (-24 ~ +24): Q+2, Q2, Q+12, Q-3, Q-12, Q0
                    //   2. 单步微调与八度移调: Q+ (升半音), Q- (降半音), Q++ / Q> (升八度+12), Q-- / Q< (降八度-12)
                    //   3. 调号直选 (1=C..B): QC(0), QC#/QDb(+1), QD(+2), QD#/QEb(+3), QE(+4), QF(+5),
                    //                        QF#/QGb(+6), QG(+7), QG#/QAb(-4), QA(-3), QA#/QBb(-2), QB(-1)
                    //   4. 状态查询: Q? 或单发 Q 回显当前移调状态 "TR:+02 (1=D )"
                    ST_CMD_Q: begin
                        q_wait_cnt <= 18'd0;
                        if (rx_byte == "+" || rx_byte == "=") begin
                            parse_st   <= ST_CMD_Q_POS;
                            q_wait_cnt <= 18'd125_000;
                        end else if (rx_byte == "-") begin
                            parse_st   <= ST_CMD_Q_NEG;
                            q_wait_cnt <= 18'd125_000;
                        end else if (rx_byte == ">") begin
                            transpose_semi   <= trans_inc12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (rx_byte == "<") begin
                            transpose_semi   <= trans_dec12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (is_dec_digit) begin
                            transpose_semi   <= q_1digit_pos;
                            tr_echo_wait_cnt <= 18'd250_000;
                            if (nib[3:0] <= 4'd2) begin
                                q_neg      <= 1'b0;
                                q_d1       <= nib[1:0];
                                q_wait_cnt <= 18'd125_000;
                                parse_st   <= ST_CMD_Q_D2;
                            end else begin
                                parse_st   <= ST_IDLE;
                            end
                        end else if (rx_byte == "C" || rx_byte == "c") begin
                            transpose_semi   <= 6'sd0;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "D" || rx_byte == "d") begin
                            transpose_semi   <= 6'sd2;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "E" || rx_byte == "e") begin
                            transpose_semi   <= 6'sd4;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "F" || rx_byte == "f") begin
                            transpose_semi   <= 6'sd5;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "G" || rx_byte == "g") begin
                            transpose_semi   <= 6'sd7;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "A" || rx_byte == "a") begin
                            transpose_semi   <= -6'sd3;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "B" || rx_byte == "b") begin
                            transpose_semi   <= -6'sd1;
                            tr_echo_wait_cnt <= 18'd250_000;
                            q_wait_cnt       <= 18'd125_000;
                            parse_st         <= ST_CMD_Q_KEY;
                        end else if (rx_byte == "R" || rx_byte == "r") begin
                            transpose_semi   <= 6'sd0;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else if (rx_byte == "?" || rx_byte == 8'h0A || rx_byte == 8'h0D || rx_byte == 8'h20) begin
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else begin
                            parse_st <= ST_IDLE;
                        end
                    end

                    ST_CMD_Q_POS: begin
                        q_wait_cnt <= 18'd0;
                        if (is_dec_digit) begin
                            transpose_semi   <= q_1digit_pos;
                            tr_echo_wait_cnt <= 18'd250_000;
                            if (nib[3:0] <= 4'd2) begin
                                q_neg      <= 1'b0;
                                q_d1       <= nib[1:0];
                                q_wait_cnt <= 18'd125_000;
                                parse_st   <= ST_CMD_Q_D2;
                            end else begin
                                parse_st   <= ST_IDLE;
                            end
                        end else if (rx_byte == "+" || rx_byte == "=" || rx_byte == ">") begin
                            transpose_semi   <= trans_inc12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else begin
                            transpose_semi   <= trans_inc1;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end
                    end

                    ST_CMD_Q_NEG: begin
                        q_wait_cnt <= 18'd0;
                        if (is_dec_digit) begin
                            transpose_semi   <= q_1digit_neg;
                            tr_echo_wait_cnt <= 18'd250_000;
                            if (nib[3:0] <= 4'd2) begin
                                q_neg      <= 1'b1;
                                q_d1       <= nib[1:0];
                                q_wait_cnt <= 18'd125_000;
                                parse_st   <= ST_CMD_Q_D2;
                            end else begin
                                parse_st   <= ST_IDLE;
                            end
                        end else if (rx_byte == "-" || rx_byte == "<") begin
                            transpose_semi   <= trans_dec12;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end else begin
                            transpose_semi   <= trans_dec1;
                            tr_echo_wait_cnt <= 18'd250_000;
                            parse_st         <= ST_IDLE;
                        end
                    end

                    ST_CMD_Q_D2: begin
                        q_wait_cnt <= 18'd0;
                        if (is_dec_digit) begin
                            transpose_semi   <= q_2digit_signed;
                            tr_echo_wait_cnt <= 18'd250_000;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_Q_KEY: begin
                        q_wait_cnt <= 18'd0;
                        if (rx_byte == "#") begin
                            transpose_semi   <= (transpose_semi == 6'sd7) ? -6'sd4 : trans_inc1;
                            tr_echo_wait_cnt <= 18'd250_000;
                        end else if (rx_byte == "b" || rx_byte == "B") begin
                            transpose_semi   <= (transpose_semi == 6'sd0) ? -6'sd1 : trans_dec1;
                            tr_echo_wait_cnt <= 18'd250_000;
                        end
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_D: begin
                        if (rx_byte >= 8'h41 && rx_byte <= 8'h52)
                            held_keys <= held_keys | (18'd1 << (rx_byte - 8'h41));
                        else if (rx_byte >= 8'h61 && rx_byte <= 8'h72)
                            held_keys <= held_keys | (18'd1 << (rx_byte - 8'h61));
                        parse_st <= ST_IDLE;
                    end

                    ST_CMD_U: begin
                        if (rx_byte >= 8'h41 && rx_byte <= 8'h52)
                            held_keys <= held_keys & ~(18'd1 << (rx_byte - 8'h41));
                        else if (rx_byte >= 8'h61 && rx_byte <= 8'h72)
                            held_keys <= held_keys & ~(18'd1 << (rx_byte - 8'h61));
                        parse_st <= ST_IDLE;
                    end

                    default: parse_st <= ST_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // 5. FPGA→手机 全自动引脚路由发送引擎 ("R" 触发录音回传 + "Q/K" 触发移调状态回显)
    // =========================================================================
    reg        dump_started;
    reg [3:0]  dump_ph;
    reg        tr_echo_started;
    reg [3:0]  tr_echo_ph;
    reg        tx_busy;
    reg [3:0]  tx_bitcnt;
    reg [12:0] tx_cnt;
    reg [9:0]  tx_shift;
    reg [16:0] line_gap_cnt;
    reg [15:0] rx_guard;
    reg        dump_done_r;
    reg        tr_echo_done_r;

    assign dump_done    = dump_done_r;
    assign tr_echo_done = tr_echo_done_r;

    wire [5:0] tr_abs  = transpose_semi[5] ? (-transpose_semi) : transpose_semi;
    wire [3:0] tr_tens = (tr_abs >= 6'd20) ? 4'd2 : (tr_abs >= 6'd10) ? 4'd1 : 4'd0;
    wire [5:0] tr_rem  = (tr_abs >= 6'd20) ? (tr_abs - 6'd20) :
                         (tr_abs >= 6'd10) ? (tr_abs - 6'd10) : tr_abs;
    wire [3:0] tr_ones = tr_rem[3:0];

    wire [6:0] tr_norm_full = $unsigned($signed({transpose_semi[5], transpose_semi}) + 7'sd24);
    wire [5:0] tr_norm      = tr_norm_full[5:0];
    wire [5:0] tr_pc_full   = (tr_norm >= 6'd48) ? 6'd0 :
                              (tr_norm >= 6'd36) ? (tr_norm - 6'd36) :
                              (tr_norm >= 6'd24) ? (tr_norm - 6'd24) :
                              (tr_norm >= 6'd12) ? (tr_norm - 6'd12) : tr_norm;
    wire [3:0] tr_pc        = tr_pc_full[3:0];

    reg [7:0] tr_key_c0, tr_key_c1;
    always @(*) begin
        case (tr_pc)
            4'd0:    begin tr_key_c0 = "C"; tr_key_c1 = " "; end
            4'd1:    begin tr_key_c0 = "C"; tr_key_c1 = "#"; end
            4'd2:    begin tr_key_c0 = "D"; tr_key_c1 = " "; end
            4'd3:    begin tr_key_c0 = "E"; tr_key_c1 = "b"; end
            4'd4:    begin tr_key_c0 = "E"; tr_key_c1 = " "; end
            4'd5:    begin tr_key_c0 = "F"; tr_key_c1 = " "; end
            4'd6:    begin tr_key_c0 = "F"; tr_key_c1 = "#"; end
            4'd7:    begin tr_key_c0 = "G"; tr_key_c1 = " "; end
            4'd8:    begin tr_key_c0 = "A"; tr_key_c1 = "b"; end
            4'd9:    begin tr_key_c0 = "A"; tr_key_c1 = " "; end
            4'd10:   begin tr_key_c0 = "B"; tr_key_c1 = "b"; end
            default: begin tr_key_c0 = "B"; tr_key_c1 = " "; end
        endcase
    end

    reg [7:0] tr_tx_next;
    always @(*) begin
        case (tr_echo_ph)
            4'd0:    tr_tx_next = "T";
            4'd1:    tr_tx_next = "R";
            4'd2:    tr_tx_next = ":";
            4'd3:    tr_tx_next = transpose_semi[5] ? "-" : "+";
            4'd4:    tr_tx_next = 8'h30 + {4'd0, tr_tens};
            4'd5:    tr_tx_next = 8'h30 + {4'd0, tr_ones};
            4'd6:    tr_tx_next = " ";
            4'd7:    tr_tx_next = "(";
            4'd8:    tr_tx_next = "1";
            4'd9:    tr_tx_next = "=";
            4'd10:   tr_tx_next = tr_key_c0;
            4'd11:   tr_tx_next = tr_key_c1;
            4'd12:   tr_tx_next = ")";
            4'd13:   tr_tx_next = 8'h0D;                                    // '\r'
            default: tr_tx_next = 8'h0A;                                    // '\n'
        endcase
    end

    reg [7:0] tx_next;
    always @(*) begin
        case (dump_ph)
            4'd0:    tx_next = 8'h57;                                       // 'W'
            4'd1:    tx_next = nib_ascii(dump_idx[7:4]);
            4'd2:    tx_next = nib_ascii(dump_idx[3:0]);
            4'd3:    tx_next = 8'h3A;                                       // ':'
            4'd4:    tx_next = nib_ascii({1'b0, dump_word[18:16]});
            4'd5:    tx_next = nib_ascii(dump_word[15:12]);
            4'd6:    tx_next = nib_ascii(dump_word[11:8]);
            4'd7:    tx_next = nib_ascii(dump_word[7:4]);
            4'd8:    tx_next = nib_ascii(dump_word[3:0]);
            4'd9:    tx_next = 8'h0D;                                       // '\r'
            default: tx_next = 8'h0A;                                       // '\n'
        endcase
    end

    assign bt_tx_bit = tx_shift[0];

    always @(posedge clk) begin
        if (!rst_n) begin
            dump_started    <= 1'b0;
            dump_idx        <= 8'd0;
            dump_ph         <= 4'd0;
            tr_echo_started <= 1'b0;
            tr_echo_ph      <= 4'd0;
            tx_busy         <= 1'b0;
            tx_bitcnt       <= 4'd0;
            tx_cnt          <= 13'd0;
            tx_shift        <= 10'h3FF;
            line_gap_cnt    <= 17'd0;
            bt_tx_en_h5     <= 1'b0;
            bt_tx_en_j5     <= 1'b0;
            rx_guard        <= 16'd0;
            dump_done_r     <= 1'b0;
            tr_echo_done_r  <= 1'b0;
        end else begin
            dump_done_r    <= 1'b0;
            tr_echo_done_r <= 1'b0;

            if (dump_started || tr_echo_started || tx_busy)
                rx_guard <= 16'd15000;
            else if (rx_guard != 16'd0)
                rx_guard <= rx_guard - 16'd1;

            if (!tx_busy) begin
                if (dump_pending && !dump_started && !tr_echo_started && !dump_done_r) begin
                    dump_started <= 1'b1;
                    dump_idx     <= 8'd0;
                    dump_ph      <= 4'd0;
                    tx_shift     <= 10'h3FF;
                    line_gap_cnt <= 17'd25000;
                    bt_tx_en_h5  <=  rx_from_j5;
                    bt_tx_en_j5  <= ~rx_from_j5;
                end else if (tr_echo_pending && !dump_started && !tr_echo_started && !tr_echo_done_r) begin
                    tr_echo_started <= 1'b1;
                    tr_echo_ph      <= 4'd0;
                    tx_shift        <= 10'h3FF;
                    bt_tx_en_h5     <=  rx_from_j5;
                    bt_tx_en_j5     <= ~rx_from_j5;
                end else if (dump_started) begin
                    bt_tx_en_h5 <=  rx_from_j5;
                    bt_tx_en_j5 <= ~rx_from_j5;
                    if (line_gap_cnt != 17'd0) begin
                        tx_shift     <= 10'h3FF;
                        line_gap_cnt <= line_gap_cnt - 17'd1;
                    end else if (rd_slot_d == 2'd2) begin
                        tx_shift  <= {1'b1, tx_next, 1'b0};
                        tx_busy   <= 1'b1;
                        tx_cnt    <= 13'd0;
                        tx_bitcnt <= 4'd0;
                    end
                end else if (tr_echo_started) begin
                    bt_tx_en_h5 <=  rx_from_j5;
                    bt_tx_en_j5 <= ~rx_from_j5;
                    tx_shift    <= {1'b1, tr_tx_next, 1'b0};
                    tx_busy     <= 1'b1;
                    tx_cnt      <= 13'd0;
                    tx_bitcnt   <= 4'd0;
                end else begin
                    bt_tx_en_h5 <= 1'b0;
                    bt_tx_en_j5 <= 1'b0;
                    tx_shift    <= 10'h3FF;
                end
            end else begin
                bt_tx_en_h5 <=  rx_from_j5;
                bt_tx_en_j5 <= ~rx_from_j5;
                if (tx_cnt >= baud_div) begin
                    tx_cnt <= 13'd0;
                    if (tx_bitcnt == 4'd9) begin
                        tx_busy  <= 1'b0;
                        tx_shift <= 10'h3FF;
                        if (tr_echo_started) begin
                            if (tr_echo_ph >= 4'd14) begin
                                tr_echo_started <= 1'b0;
                                tr_echo_done_r  <= 1'b1;
                            end else begin
                                tr_echo_ph <= tr_echo_ph + 4'd1;
                            end
                        end else if (dump_ph == 4'd10) begin
                            if (dump_idx >= user_last_step) begin
                                dump_started <= 1'b0;
                                dump_done_r  <= 1'b1;
                            end else begin
                                dump_idx     <= dump_idx + 8'd1;
                                dump_ph      <= 4'd0;
                                line_gap_cnt <= 17'd100000;
                            end
                        end else begin
                            dump_ph <= dump_ph + 4'd1;
                        end
                    end else begin
                        tx_shift  <= {1'b1, tx_shift[9:1]};
                        tx_bitcnt <= tx_bitcnt + 4'd1;
                    end
                end else begin
                    tx_cnt <= tx_cnt + 13'd1;
                end
            end
        end
    end

    assign rx_en = (!dump_started) && (!tr_echo_started) && (!tx_busy) && (rx_guard == 16'd0);

endmodule
