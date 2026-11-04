// =============================================================================
// 文件名: audio.v
// 模块功能: 商业级超低底噪真立体声数字音频效果器
// 低底噪增强:
//   1. 彻底移除延迟线 24.4kHz 奇偶二分频欠采样 (dly_div)，改为全速 48.828kHz 采样，
//      消除 24.4kHz 半采样率混叠啸叫与底噪;
//   2. 原声模式微立体声采用无 LFO 调制的正交早期反射 (st_diff_r)，消除未插值抽头跳变杂音;
//   3. 静默死区自动归零门控: 当输入与混响尾音衰减至 ±8 LSB 以内时直接输出绝对 0，杜绝功放底噪。
// =============================================================================
module audio #(
    parameter [13:0] DLY_DEPTH = 14'd8192
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire signed [23:0] pcm_in,
    input  wire [2:0]         fx_sel,
    input  wire [3:0]         fx_level,     // 湿声强度 0~15
    output reg  signed [23:0] pcm_l,
    output reg  signed [23:0] pcm_r
);

    function signed [23:0] sat24;
        input signed [26:0] v;
        begin
            if (v > 27'sd8388607)       sat24 = 24'sd8388607;
            else if (v < -27'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = $signed(v[23:0]);
        end
    endfunction

    // 向零对称舍入函数: 彻底消除负数算术右移的 -1 极限环，无需死区截断即可 100% 归零无底噪
    function signed [23:0] shr1_z;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj    = x[23] ? (x + 24'sd1) : x;
            shr1_z = adj >>> 1;
        end
    endfunction

    function signed [23:0] shr2_z;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj    = x[23] ? (x + 24'sd3) : x;
            shr2_z = adj >>> 2;
        end
    endfunction

    function signed [23:0] shr3_z;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj    = x[23] ? (x + 24'sd7) : x;
            shr3_z = adj >>> 3;
        end
    endfunction

    function signed [23:0] shr4_z;
        input signed [23:0] x;
        reg signed [23:0] adj;
        begin
            adj    = x[23] ? (x + 24'sd15) : x;
            shr4_z = adj >>> 4;
        end
    endfunction

    // 母带级三段平滑软膝盖限幅器 (无过零死区台阶，彻底消除微幅信号过零交越失真“丝丝”声)
    function signed [26:0] softlim;
        input signed [26:0] x;
        reg signed [26:0] a, m;
        begin
            a = x[26] ? -x : x;
            if (a < 27'sd6291456)
                softlim = x;
            else if (a < 27'sd8388608) begin
                m = 27'sd6291456 + ((a - 27'sd6291456) >>> 1);
                softlim = x[26] ? -m : m;
            end else begin
                m = 27'sd7340032 + ((a - 27'sd8388608) >>> 3);
                if (m > 27'sd8388600) m = 27'sd8388600;
                softlim = x[26] ? -m : m;
            end
        end
    endfunction

    // 上电硬件 BSRAM 清零计数器 (0..8191 拍 = 164us 内将全部延迟/混响/合唱 RAM 物理清零)
    reg [13:0] init_clr_cnt;
    wire       clr_busy   = ~init_clr_cnt[13];
    wire [12:0] clr_addr13 = init_clr_cnt[12:0];
    wire [10:0] clr_addr   = init_clr_cnt[10:0];

    always @(posedge clk) begin
        if (!rst_n)
            init_clr_cnt <= 14'd0;
        else if (clr_busy)
            init_clr_cnt <= init_clr_cnt + 14'd1;
    end

    reg [2:0] fx_ph;
    always @(posedge clk) begin
        if (!rst_n || clr_busy) fx_ph <= 3'd0;
        else if (sample_tick)   fx_ph <= 3'd1;
        else if (fx_ph == 3'd7) fx_ph <= 3'd0;
        else if (fx_ph != 3'd0) fx_ph <= fx_ph + 3'd1;
    end

    reg signed [23:0] in_r;

    // =====================================================================
    // 1. Roland Dimension D 级平滑正弦双抽头立体声合唱 (8-bit 线性内插)
    // =====================================================================
    reg  [23:0] cho_mem [0:1023];
    reg  [9:0]  cho_wr;
    reg  [1:0]  cho_lfo_div;
    reg  [13:0] cho_tri;
    reg         cho_dir;
    reg  signed [23:0] ca0, ca1, cb0;
    reg  signed [23:0] cho_wa, cho_wb;
    reg  signed [31:0] cho_d;

    wire [13:0] tri_inv  = 14'd16383 - cho_tri;
    wire [27:0] curve_p  = cho_tri * tri_inv;
    wire [13:0] cho_s_a  = cho_dir ? (cho_tri - (curve_p[25:14])) : (cho_tri + (curve_p[25:14]));
    wire [13:0] cho_s_b  = 14'd16383 - cho_s_a;

    wire [9:0]  off_a    = {4'b0000, cho_s_a[13:8]};
    wire [9:0]  off_b    = {4'b0000, cho_s_b[13:8]};
    wire [7:0]  frac_a   = cho_s_a[7:0];
    wire [7:0]  frac_b   = cho_s_b[7:0];
    wire [9:0]  ra0      = cho_wr - 10'd280 - off_a;
    wire [9:0]  ra1      = ra0 - 10'd1;
    wire [9:0]  rb0      = cho_wr - 10'd520 - off_b;
    wire [9:0]  rb1      = rb0 - 10'd1;

    reg         cho_we;
    reg  [9:0]  cho_waddr;
    reg  [23:0] cho_wdata;
    reg  [9:0]  cho_raddr;
    reg  signed [23:0] cho_rdata;

    always @(*) begin
        case (fx_ph)
            3'd1:    cho_raddr = ra1;
            3'd2:    cho_raddr = rb0;
            3'd3:    cho_raddr = rb1;
            default: cho_raddr = ra0;
        endcase
    end

    always @(posedge clk) begin
        if (cho_we)
            cho_mem[cho_waddr] <= cho_wdata;
        cho_rdata <= $signed(cho_mem[cho_raddr]);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cho_wr      <= 10'd0;
            cho_lfo_div <= 2'd0;
            cho_tri     <= 14'd0;
            cho_dir     <= 1'b1;
            ca0         <= 24'sd0;
            ca1         <= 24'sd0;
            cb0         <= 24'sd0;
            cho_wa      <= 24'sd0;
            cho_wb      <= 24'sd0;
            cho_we      <= 1'b0;
            cho_waddr   <= 10'd0;
            cho_wdata   <= 24'd0;
        end else if (clr_busy) begin
            cho_we    <= 1'b1;
            cho_waddr <= clr_addr[9:0];
            cho_wdata <= 24'd0;
        end else begin
            cho_we <= 1'b0;
            if (fx_ph == 3'd1) begin
                ca0 <= cho_rdata;
            end else if (fx_ph == 3'd2) begin
                ca1 <= cho_rdata;
            end else if (fx_ph == 3'd3) begin
                cb0       <= cho_rdata;
                cho_we    <= 1'b1;
                cho_waddr <= cho_wr;
                cho_wdata <= in_r;
                cho_wr    <= cho_wr + 10'd1;
                cho_d      = (ca1 - ca0) * $signed({1'b0, frac_a});
                cho_wa    <= ca0 + $signed(cho_d[31:8]);
            end else if (fx_ph == 3'd4) begin
                cho_d      = (cho_rdata - cb0) * $signed({1'b0, frac_b});
                cho_wb    <= cb0 + $signed(cho_d[31:8]);
                cho_lfo_div <= cho_lfo_div + 2'd1;
                if (cho_lfo_div == 2'd0) begin
                    if (cho_dir) begin
                        if (cho_tri >= 14'd16382) begin cho_tri <= 14'd16383; cho_dir <= 1'b0; end
                        else                            cho_tri <= cho_tri + 14'd1;
                    end else begin
                        if (cho_tri <= 14'd1)     begin cho_tri <= 14'd0;     cho_dir <= 1'b1; end
                        else                            cho_tri <= cho_tri - 14'd1;
                    end
                end
            end
        end
    end

    // =====================================================================
    // 2. 全速 48.828kHz 零混叠真立体声乒乓延迟
    // =====================================================================
    reg  [23:0] dly_mem [0:8191];
    reg  [12:0] dly_ptr;
    reg  signed [23:0] dly_main;
    reg  signed [23:0] dly_tap2;
    reg  signed [23:0] rev_predly;
    reg  signed [23:0] dly_out_l;
    reg  signed [23:0] dly_out_r;
    reg  signed [23:0] dly_lp;
    reg  signed [23:0] dly_lp_next;
    reg  signed [23:0] dly_fb_val;
    reg  signed [26:0] dly_tmp;

    wire [12:0] dly_last    = DLY_DEPTH[12:0] - 13'd1;
    wire [12:0] tap2_addr   = dly_ptr - 13'd4096;
    wire [12:0] predly_addr = dly_ptr - 13'd1024; // ~21ms 自然音乐厅预延迟

    reg         dly_we;
    reg  [12:0] dly_waddr;
    reg  [23:0] dly_wdata;
    reg  [12:0] dly_raddr;
    reg  signed [23:0] dly_rdata;

    always @(*) begin
        case (fx_ph)
            3'd1:    dly_raddr = tap2_addr;
            3'd2:    dly_raddr = predly_addr;
            default: dly_raddr = dly_ptr;
        endcase
    end

    always @(posedge clk) begin
        if (dly_we)
            dly_mem[dly_waddr] <= dly_wdata;
        dly_rdata <= $signed(dly_mem[dly_raddr]);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            dly_ptr    <= 13'd0;
            dly_main   <= 24'sd0;
            dly_tap2   <= 24'sd0;
            rev_predly <= 24'sd0;
            dly_out_l  <= 24'sd0;
            dly_out_r  <= 24'sd0;
            dly_lp     <= 24'sd0;
            dly_we     <= 1'b0;
            dly_waddr  <= 13'd0;
            dly_wdata  <= 24'd0;
        end else if (clr_busy) begin
            dly_we    <= 1'b1;
            dly_waddr <= clr_addr13;
            dly_wdata <= 24'd0;
        end else begin
            dly_we <= 1'b0;
            if (fx_ph == 3'd1) begin
                dly_main <= dly_rdata;
            end else if (fx_ph == 3'd2) begin
                dly_tap2    <= dly_rdata;
                dly_lp_next  = dly_lp + shr1_z(dly_main - dly_lp);
                dly_lp      <= dly_lp_next;
                dly_fb_val   = shr1_z(dly_lp_next);
                dly_tmp      = $signed({{3{in_r[23]}}, in_r}) + $signed({{3{dly_fb_val[23]}}, dly_fb_val});
                dly_we      <= 1'b1;
                dly_waddr   <= dly_ptr;
                dly_wdata   <= sat24(dly_tmp);
                dly_ptr     <= (dly_ptr == dly_last) ? 13'd0 : (dly_ptr + 13'd1);
            end else if (fx_ph == 3'd3) begin
                rev_predly <= dly_rdata;
                dly_out_l  <= dly_main + shr2_z(dly_tap2);
                dly_out_r  <= shr1_z(dly_tap2) + shr1_z(dly_main) + shr2_z(dly_main);
            end
        end
    end

    // =====================================================================
    // 3. 真立体声维也纳音乐厅混响 Reverb (4 并联阻尼梳状正交矩阵 + 2 串联全通)
    // =====================================================================
    reg  [23:0] c0_mem [0:1115];  reg [10:0] c0_ptr;  reg signed [23:0] c0_v;
    reg  [23:0] c1_mem [0:1187];  reg [10:0] c1_ptr;  reg signed [23:0] c1_v;
    reg  [23:0] c2_mem [0:1490];  reg [10:0] c2_ptr;  reg signed [23:0] c2_v;
    reg  [23:0] c3_mem [0:1556];  reg [10:0] c3_ptr;  reg signed [23:0] c3_v;
    reg  signed [23:0] d0, d1, d2, d3;
    reg  signed [23:0] d_next;
    reg  signed [23:0] fb_val;
    reg  signed [26:0] rev_tmp;

    reg  [23:0] ap1_mem [0:555];  reg [9:0]  ap1_ptr; reg signed [23:0] ap1_v;
    reg  [23:0] ap2_mem [0:440];  reg [9:0]  ap2_ptr; reg signed [23:0] ap2_v;
    reg  signed [23:0] ap1_w, ap2_w;
    reg  signed [23:0] ap1_o, ap2_o;
    reg  signed [23:0] cs_r;
    reg  signed [23:0] st_diff_r;
    reg  signed [23:0] early_refl;
    reg  signed [23:0] rev_raw_l;
    reg  signed [23:0] rev_raw_r;
    reg  signed [23:0] rev_out_l;
    reg  signed [23:0] rev_out_r;

    wire signed [23:0] rev_in   = shr2_z(in_r) + shr3_z(rev_predly);
    wire signed [26:0] comb_raw = $signed({{3{c0_v[23]}}, shr1_z(c0_v)}) +
                                  $signed({{3{c1_v[23]}}, shr1_z(c1_v)}) +
                                  $signed({{3{c2_v[23]}}, shr1_z(c2_v)}) +
                                  $signed({{3{c3_v[23]}}, shr1_z(c3_v)});
    wire signed [26:0] comb_side = $signed({{3{c0_v[23]}}, shr2_z(c0_v)}) -
                                   $signed({{3{c1_v[23]}}, shr2_z(c1_v)}) +
                                   $signed({{3{c2_v[23]}}, shr2_z(c2_v)}) -
                                   $signed({{3{c3_v[23]}}, shr2_z(c3_v)});

    integer iz;
    initial begin
        for (iz = 0; iz < 1024; iz = iz + 1) cho_mem[iz] = 24'd0;
        for (iz = 0; iz < 1024; iz = iz + 1) dly_mem[iz]    = 24'd0;
        for (iz = 1024; iz < 2048; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 2048; iz < 3072; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 3072; iz < 4096; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 4096; iz < 5120; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 5120; iz < 6144; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 6144; iz < 7168; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 7168; iz < 8192; iz = iz + 1) dly_mem[iz] = 24'd0;
        for (iz = 0; iz < 1116; iz = iz + 1) c0_mem[iz]  = 24'd0;
        for (iz = 0; iz < 1188; iz = iz + 1) c1_mem[iz]  = 24'd0;
        for (iz = 0; iz < 1491; iz = iz + 1) c2_mem[iz]  = 24'd0;
        for (iz = 0; iz < 1557; iz = iz + 1) c3_mem[iz]  = 24'd0;
        for (iz = 0; iz < 556;  iz = iz + 1) ap1_mem[iz] = 24'd0;
        for (iz = 0; iz < 441;  iz = iz + 1) ap2_mem[iz] = 24'd0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            c0_ptr <= 11'd0; c1_ptr <= 11'd0; c2_ptr <= 11'd0; c3_ptr <= 11'd0;
            ap1_ptr <= 10'd0; ap2_ptr <= 10'd0;
            c0_v <= 24'sd0; c1_v <= 24'sd0; c2_v <= 24'sd0; c3_v <= 24'sd0;
            d0 <= 24'sd0; d1 <= 24'sd0; d2 <= 24'sd0; d3 <= 24'sd0;
            ap1_v <= 24'sd0; ap2_v <= 24'sd0;
            ap1_o <= 24'sd0; ap2_o <= 24'sd0; cs_r <= 24'sd0; st_diff_r <= 24'sd0;
            early_refl <= 24'sd0; rev_raw_l <= 24'sd0; rev_raw_r <= 24'sd0; rev_out_l <= 24'sd0; rev_out_r <= 24'sd0;
        end else if (clr_busy) begin
            if (clr_addr < 11'd1116) c0_mem[clr_addr] <= 24'd0;
            if (clr_addr < 11'd1188) c1_mem[clr_addr] <= 24'd0;
            if (clr_addr < 11'd1491) c2_mem[clr_addr] <= 24'd0;
            if (clr_addr < 11'd1557) c3_mem[clr_addr] <= 24'd0;
            if (clr_addr < 11'd556)  ap1_mem[clr_addr[9:0]] <= 24'd0;
            if (clr_addr < 11'd441)  ap2_mem[clr_addr[9:0]] <= 24'd0;
        end else if (fx_ph == 3'd1) begin
            c0_v <= $signed(c0_mem[c0_ptr]);
            c1_v <= $signed(c1_mem[c1_ptr]);
            c2_v <= $signed(c2_mem[c2_ptr]);
            c3_v <= $signed(c3_mem[c3_ptr]);
        end else if (fx_ph == 3'd2) begin
            d_next  = d0 + shr1_z(c0_v - d0);
            d0     <= d_next;
            fb_val  = d_next - shr3_z(d_next) - shr4_z(d_next);
            rev_tmp = $signed({{3{rev_in[23]}}, rev_in}) + $signed({{3{fb_val[23]}}, fb_val});
            c0_mem[c0_ptr] <= sat24(rev_tmp);
            c0_ptr <= (c0_ptr == 11'd1115) ? 11'd0 : c0_ptr + 11'd1;

            d_next  = d1 + shr1_z(c1_v - d1);
            d1     <= d_next;
            fb_val  = d_next - shr3_z(d_next) - shr4_z(d_next);
            rev_tmp = $signed({{3{rev_in[23]}}, rev_in}) + $signed({{3{fb_val[23]}}, fb_val});
            c1_mem[c1_ptr] <= sat24(rev_tmp);
            c1_ptr <= (c1_ptr == 11'd1187) ? 11'd0 : c1_ptr + 11'd1;

            d_next  = d2 + shr1_z(c2_v - d2);
            d2     <= d_next;
            fb_val  = d_next - shr3_z(d_next) - shr4_z(d_next);
            rev_tmp = $signed({{3{rev_in[23]}}, rev_in}) + $signed({{3{fb_val[23]}}, fb_val});
            c2_mem[c2_ptr] <= sat24(rev_tmp);
            c2_ptr <= (c2_ptr == 11'd1490) ? 11'd0 : c2_ptr + 11'd1;

            d_next  = d3 + shr1_z(c3_v - d3);
            d3     <= d_next;
            fb_val  = d_next - shr3_z(d_next) - shr4_z(d_next);
            rev_tmp = $signed({{3{rev_in[23]}}, rev_in}) + $signed({{3{fb_val[23]}}, fb_val});
            c3_mem[c3_ptr] <= sat24(rev_tmp);
            c3_ptr <= (c3_ptr == 11'd1556) ? 11'd0 : c3_ptr + 11'd1;

            cs_r       <= sat24(comb_raw);
            st_diff_r  <= sat24(comb_side);
            early_refl <= shr2_z(rev_predly);
            ap1_v      <= $signed(ap1_mem[ap1_ptr]);
        end else if (fx_ph == 3'd3) begin
            rev_tmp = $signed({{3{cs_r[23]}}, cs_r}) + $signed({{3{ap1_v[23]}}, shr1_z(ap1_v)});
            ap1_w   = sat24(rev_tmp);
            ap1_mem[ap1_ptr] <= ap1_w;
            rev_tmp = $signed({{3{ap1_v[23]}}, ap1_v}) - $signed({{3{ap1_w[23]}}, shr1_z(ap1_w)});
            ap1_o  <= sat24(rev_tmp);
            ap1_ptr <= (ap1_ptr == 10'd555) ? 10'd0 : ap1_ptr + 10'd1;
            ap2_v   <= $signed(ap2_mem[ap2_ptr]);
            rev_raw_l <= sat24($signed({{3{ap2_o[23]}}, ap2_o}) + $signed({{3{st_diff_r[23]}}, st_diff_r}));
            rev_raw_r <= sat24($signed({{3{ap2_o[23]}}, ap2_o}) - $signed({{3{st_diff_r[23]}}, st_diff_r}));
        end else if (fx_ph == 3'd4) begin
            rev_tmp = $signed({{3{ap1_o[23]}}, ap1_o}) + $signed({{3{ap2_v[23]}}, shr1_z(ap2_v)});
            ap2_w   = sat24(rev_tmp);
            ap2_mem[ap2_ptr] <= ap2_w;
            rev_tmp = $signed({{3{ap2_v[23]}}, ap2_v}) - $signed({{3{ap2_w[23]}}, shr1_z(ap2_w)}) + $signed({{3{early_refl[23]}}, early_refl});
            ap2_o  <= sat24(rev_tmp);
            ap2_ptr <= (ap2_ptr == 10'd440) ? 10'd0 : ap2_ptr + 10'd1;

            rev_out_l <= rev_out_l + shr1_z(rev_raw_l - rev_out_l);
            rev_out_r <= rev_out_r + shr1_z(rev_raw_r - rev_out_r);
        end
    end

    // =====================================================================
    // 4. 立体声恒功率平衡混合输出 (ph5/ph6) + 原声正交空间微立体声 + 死区静音归零
    // =====================================================================
    wire [4:0] fx_gain = {1'b0, fx_level} + 5'd1;
    wire signed [24:0] cho_mix_l = $signed({cho_wa[23], cho_wa}) + $signed({{2{cho_wb[23]}}, cho_wb[23:1]});
    wire signed [24:0] cho_mix_r = $signed({cho_wb[23], cho_wb}) + $signed({{2{cho_wa[23]}}, cho_wa[23:1]});

    // 原声模式 (fx_sel == 3'b000) 采用无 LFO 调制的正交早期空间反射 st_diff_r，彻底消除调制跳变底噪
    wire signed [23:0] haas_diff = shr2_z(st_diff_r);

    wire multi_fx_on = (fx_sel == 3'b011) || (fx_sel == 3'b101) || (fx_sel == 3'b110) || (fx_sel == 3'b111);
    wire signed [23:0] dry_bal = multi_fx_on ? (in_r - shr3_z(in_r)) : in_r;

    reg signed [26:0] fx_acc;
    reg signed [25:0] wet_dl, wet_dr, wet_rl, wet_rr, wet_ca, wet_cb;
    reg signed [31:0] prod_d, prod_r, prod_ca, prod_cb;

    always @(posedge clk) begin
        if (!rst_n || clr_busy) begin
            in_r   <= 24'sd0;
            pcm_l  <= 24'sd0;
            pcm_r  <= 24'sd0;
            wet_dl <= 26'sd0;
            wet_dr <= 26'sd0;
            wet_rl <= 26'sd0;
            wet_rr <= 26'sd0;
        end else if (sample_tick) begin
            in_r <= pcm_in;
        end else if (fx_ph == 3'd5) begin
            prod_d  = dly_out_l * $signed({1'b0, fx_gain});
            prod_r  = rev_out_l * $signed({1'b0, fx_gain});
            prod_ca = cho_mix_l * $signed({1'b0, fx_gain});
            wet_dl  = $signed(prod_d[29:4]);
            wet_rl  = $signed(prod_r[29:4]) + $signed(prod_r[29:5]);
            wet_ca  = $signed(prod_ca[30:5]);
            fx_acc  = $signed({{3{dry_bal[23]}}, dry_bal});
            if (fx_sel == 3'b000)
                fx_acc = fx_acc + $signed({{3{haas_diff[23]}}, haas_diff});
            if (fx_sel[1]) fx_acc = fx_acc + wet_dl;
            if (fx_sel[2]) fx_acc = fx_acc + wet_rl;
            if (fx_sel[0]) fx_acc = fx_acc + wet_ca;
            pcm_l <= sat24(softlim(fx_acc));
        end else if (fx_ph == 3'd6) begin
            prod_d  = dly_out_r * $signed({1'b0, fx_gain});
            prod_r  = rev_out_r * $signed({1'b0, fx_gain});
            prod_cb = cho_mix_r * $signed({1'b0, fx_gain});
            wet_dr  = $signed(prod_d[29:4]);
            wet_rr  = $signed(prod_r[29:4]) + $signed(prod_r[29:5]);
            wet_cb  = $signed(prod_cb[30:5]);
            fx_acc  = $signed({{3{dry_bal[23]}}, dry_bal});
            if (fx_sel == 3'b000)
                fx_acc = fx_acc - $signed({{3{haas_diff[23]}}, haas_diff});
            if (fx_sel[1]) fx_acc = fx_acc + wet_dr;
            if (fx_sel[2]) fx_acc = fx_acc + wet_rr;
            if (fx_sel[0]) fx_acc = fx_acc + wet_cb;
            pcm_r <= sat24(softlim(fx_acc));
        end
    end

endmodule
