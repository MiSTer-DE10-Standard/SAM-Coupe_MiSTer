//============================================================================
// 
//  SAM Coupe replica for MiSTer
//  Copyright (C) 2017,2018 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [44:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	input         TAPE_IN,

	// SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE
);

assign LED_USER  = ioctl_download | fdd2_io;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign CLK_VIDEO = clk_sys;

assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VIDEO_ARX = status[4:3] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[4:3] ? 8'd9  : 8'd3;


`include "build_id.v"
localparam CONF_STR = 
{
	"SAMCOUPE;;",
	"-;",
	"S0,DSKMGTIMG,Drive 1;",
	"S1,DSKMGTIMG,Drive 2;",
	"-;",
	"O34,Aspect ratio,Original,Wide,Zoom;",
	"O12,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"-;",
	"O67,Stereo mix,none,25%,50%,100%;",
	"-;",
	"O8A,CPU Speed,Normal,6MHz,9.6MHz,12MHz,24MHz;",
	"OBC,ZX Mode Speed,Emulated,Full,Real;",
	"O5,External RAM,on,off;",
	"J,Fire 1,Fire 2;",
	"V,v1.55.",`BUILD_DATE
};


////////////////////   CLOCKS   ///////////////////
wire clk_sys;
wire locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(SDRAM_CLK),
	.locked(locked)
);

reg  ce_1m;
reg  ce_psg;   //8MHz
reg  ce_6mp;
reg  ce_6mn;
reg  ce_24m;
reg  cpu_en;
reg  cpu_p;
reg  cpu_n;

wire ce_cpu_p = cpu_en & cpu_p;
wire ce_cpu_n = cpu_en & cpu_n;

reg [2:0] req_speed, cpu_speed = 0;
always_comb begin
	casex({turbo_boot, !video_mode && (status[12:11] == 2)})
		'b1X: req_speed = 5;
		'b01: req_speed = 0;
		'b00: req_speed = 3'd1 + status[10:8];
	default: req_speed = 1;
	endcase
end

reg turbo_boot = 0;
always @(posedge clk_sys) begin
	reg old_rd, skip;
	old_rd <= port_rd;

	if(reset) {skip,turbo_boot} <= 1;
	else if(~old_rd & port_rd & kbdr_sel) begin
		skip <= 1;
		if(skip) turbo_boot <= 0;
	end
end

wire [4:0] cpu_max[6] = '{26, 15, 15, 9, 7, 3};
wire [4:0] cpu_mid[6] = '{13,  8,  8, 5, 4, 2};

always @(negedge clk_sys) begin
	reg [3:0] counter = 0;
	reg [3:0] psg_div = 0;
	reg [4:0] cpu_div = 0;
	reg [6:0] meg_div = 0;
	reg       cnt_en  = 1;
	reg       skip;

	counter <=  counter + 1'd1;
	ce_24m  <= !counter[1:0];
	ce_6mp  <= !counter[3] & !counter[2:0];
	ce_6mn  <=  counter[3] & !counter[2:0];

	{cpu_p, cpu_n} <= 0;
	if(cnt_en & ~(ram_busy & (cpu_speed >= 3) & (cpu_div == (cpu_mid[cpu_speed])))) begin
		cpu_div <= cpu_div + 1'd1;
		if(cpu_div >= cpu_max[cpu_speed]) cpu_div <= 0;

		if(!cpu_div) cpu_en <= ~((cpu_speed == 1) & (ram_wait | io_wait));

		cpu_p <= (cpu_div == 0);
		cpu_n <= (cpu_div == cpu_mid[cpu_speed]);
	end

	if((cpu_speed != req_speed) & nWR & nRD & ce_cpu_p) begin
		cpu_div <= 1;
		cnt_en  <= 0;
		skip    <= 0;
	end

	if(~cnt_en & !counter) begin
		skip <= 1;
		if(skip) begin
			cpu_speed <= req_speed;
			cnt_en    <= 1;
		end
	end

	psg_div <= psg_div + 1'd1;
	if(psg_div == 11) psg_div <= 0;
	ce_psg  <= !psg_div;

	meg_div <= meg_div + 1'd1;
	if(meg_div == 95) meg_div <= 0;
	ce_1m  <= !meg_div;
end

// Contention model
wire ram_acc = ~nMREQ & nRFSH & ~rom0_sel & ~rom1_sel & ~ext_ram;
wire io_acc  = ~nIORQ & ~(nRD & nWR) & nM1 & &addr[7:3];
reg  ram_wait, io_wait;

always @(posedge clk_sys) begin
	reg old_ram, old_io, old_memcont, old_iocont;

	old_ram <= ram_acc;
	if(~old_ram & ram_acc & mem_contention) ram_wait <= 1;

	old_memcont <= mem_contention;
	if(~mem_contention & old_memcont) ram_wait <= 0;

	old_io  <= io_acc;
	if(~old_io & io_acc & io_contention) io_wait <= 1;

	old_iocont  <= io_contention;
	if(~io_contention & old_iocont) io_wait <= 0;
end


//////////////////   MIST ARM I/O   ///////////////////
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire [15:0] joystick_0;
wire [15:0] joystick_1;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire [31:0] status;

wire [31:0] sd_lba;
wire  [1:0] sd_rd;
wire  [1:0] sd_wr;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din;
wire        sd_buff_wr;
wire  [1:0] img_mounted;
wire [63:0] img_size;
wire        img_readonly;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;

hps_io #(.STRLEN($size(CONF_STR)>>3), .VDNUM(2)) hps_io
(
	.*,

	.conf_str(CONF_STR),
	.sd_conf(0),
	.sd_ack_conf(),
	.ps2_kbd_led_use(0),
	.ps2_kbd_led_status(0),

	// unused
	.new_vmode(0),
	.RTC(),
	.TIMESTAMP(),
	.ps2_kbd_clk_out(),
	.ps2_kbd_data_out(),
	.ps2_kbd_clk_in(0),
	.ps2_kbd_data_in(0),
	.ps2_mouse_clk_out(),
	.ps2_mouse_data_out(),
	.ps2_mouse_clk_in(0),
	.ps2_mouse_data_in(0),
	.ioctl_wait(0),
	.joystick_analog_0(),
	.joystick_analog_1()
);


///////////////////   CPU   ///////////////////
wire [15:0] addr;
wire  [7:0] cpu_din;
wire  [7:0] cpu_dout;
wire        nM1;
wire        nMREQ;
wire        nIORQ;
wire        nRD;
wire        nWR;
wire        nRFSH;
reg         nINT;
wire        reset  = buttons[1] | status[0] | cold_reset | warm_reset;
wire        cold_reset = (mod[1] & Fn[11]) | init_reset;
wire        warm_reset =  mod[2] & Fn[11];
wire        port_we    = ~nIORQ & ~nWR & nM1;
wire        port_rd    = ~nIORQ & ~nRD & nM1;

always @(posedge clk_sys) if(ce_cpu_p) nINT <= ~(INT_line | INT_frame | INT_midi);

T80pa cpu
(
	.RESET_n(~reset),
	.CLK(clk_sys),
	.CEN_p(ce_cpu_p),
	.CEN_n(ce_cpu_n),
	.WAIT_n(1),
	.INT_n(nINT),
	.NMI_n((mod[2:1]==0) & Fn[11]),
	.BUSRQ_n(1),
	.M1_n(nM1),
	.MREQ_n(nMREQ),
	.IORQ_n(nIORQ),
	.RD_n(nRD),
	.WR_n(nWR),
	.RFSH_n(nRFSH),
	.HALT_n(1),
	.A(addr),
	.DO(cpu_dout),
	.DI(cpu_din)
);

always_comb begin
	casex({nMREQ, rom0_sel | rom1_sel, ~nM1 | nIORQ | nRD})
	    'b011: cpu_din = bios_dout;
	    'b001: cpu_din = ext_ena ? ram_dout : 8'hFF;
	    'b1X0: cpu_din = asic_dout;
	  default: cpu_din = 8'hFF;
	endcase
end

reg init_reset = 1;
always @(posedge clk_sys) begin
	reg old_rst;
	old_rst <= status[0];
	if(old_rst & ~status[0]) init_reset <= 0;
end


//////////////////   MEMORY   //////////////////
reg  [24:0] ram_addr;
always_comb begin
	casex({rom0_sel | rom1_sel, ext_ram, addr[15:14]})
		'b1X_XX: ram_addr = {5'h10,addr[15], addr[13:0]};
		'b01_X0: ram_addr = {ext_c_off,      addr[13:0]};
		'b01_X1: ram_addr = {ext_d_off,      addr[13:0]};
		'b00_00: ram_addr = {page_ab,        addr[13:0]};
		'b00_01: ram_addr = {page_ab + 1'b1, addr[13:0]};
		'b00_10: ram_addr = {page_cd,        addr[13:0]};
		'b00_11: ram_addr = {page_cd + 1'b1, addr[13:0]};
	endcase
end

wire       ram_busy;
wire [7:0] ram_dout;
sdram ram
(
	.*,
	.init(~locked),
	.clk(clk_sys),
	.addr(ram_addr),
	.dout(ram_dout),
	.din(cpu_dout),
	.we(~(rom0_sel | rom1_sel | ram_wp) & ~nMREQ & ~nWR & ext_ena),
	.rd(~nMREQ & ~nRD),

	.vid_addr1(vram_addr1),
	.vid_addr2(vram_addr2),
	.vid_data1(vram_dout1),
	.vid_data2(vram_dout2),

	.misc_addr(ioctl_addr),
	.misc_din(ioctl_dout),
	.misc_dout(),
	.misc_rd(0),
	.misc_we(ioctl_wr && ioctl_index),
	.misc_busy()
);


wire [7:0] bios_dout;
bios bios
(
	.clock(clk_sys),
	.data(ioctl_dout),
	.wraddress(ioctl_addr[14:0]),
	.wren(ioctl_wr && ioctl_download && !ioctl_index),
	.rdaddress({addr[15], addr[13:0]}),
	.q(bios_dout)
);


//////////////////////  EXT.RAM  ////////////////////
reg  [7:0] ext_c;
reg  [7:0] ext_d;
wire [8:0] ext_c_off = 9'h40 + ext_c;
wire [8:0] ext_d_off = 9'h40 + ext_d;
reg        ext_dis;
wire       ext_ena   = ~(ext_ram & ext_dis);

wire       ext_c_sel = (addr[7:0] == 128);
wire       ext_d_sel = (addr[7:0] == 129);

always @(posedge clk_sys) begin
	reg old_we;
	old_we <= port_we;
	if(port_we & ~old_we) begin
		if(ext_c_sel) ext_c <= cpu_dout;
		if(ext_d_sel) ext_d <= cpu_dout;
	end

	if(reset) ext_dis <= status[5];
end


////////////////////  ASIC PORTS  ///////////////////
reg  [7:0] brdr;
wire [3:0] border_color = {brdr[5], brdr[2:0]};
wire       ear_out  = brdr[4];
wire       mic_out  = 0; // brdr[3]; it seems not used in SAM Coupe.

reg  [7:0] lmpr;
wire [4:0] page_ab  = lmpr[4:0];
wire       rom0_sel =~lmpr[5] & !addr[15:14];
wire       rom1_sel = lmpr[6] & &addr[15:14];
wire       ram_wp   = lmpr[7] & !addr[15:14];

reg  [7:0] hmpr;
wire [4:0] page_cd  = hmpr[4:0];
wire [1:0] mode3_hi = hmpr[6:5];
wire       ext_ram  = hmpr[7] &  addr[15];

wire       sid_sel  = (addr[7:0] == 212); // D4
wire       fdd_sel  = &addr[7:5] & ~addr[3]; // 224-231(E0-E7), 240-247(F0-F7)
wire       lptd_sel = (addr[7:0] == 232); // E8
wire       lpts_sel = (addr[7:0] == 233); // E9
//clut, hpen, lpen  = (addr[7:0] == 248); // F8
wire       stat_sel = (addr[7:0] == 249); // F9
wire       lmpr_sel = (addr[7:0] == 250); // FA
wire       hmpr_sel = (addr[7:0] == 251); // FB
//         vmpr_sel = (addr[7:0] == 252); // FC
wire       midi_sel = (addr[7:0] == 253); // FD
wire       kbdr_sel = (addr[7:0] == 254); // FE
wire       brdr_sel = (addr[7:0] == 254); // FE
//         attr_sel = (addr[7:0] == 255); // FF

always @(posedge clk_sys) begin
	reg old_we;
	
	if(reset) begin
		lmpr <= 0;
		hmpr <= 0;
		brdr <= 0;
	end else begin
		old_we <= port_we;
		if(port_we & ~old_we) begin
			if(brdr_sel) brdr <= cpu_dout;
			if(lmpr_sel) lmpr <= cpu_dout;
			if(hmpr_sel) hmpr <= cpu_dout;
		end
	end
end

reg [7:0] asic_dout;
always_comb begin
	casex({kbdr_sel, stat_sel, lmpr_sel, hmpr_sel, vid_sel, fdd_sel, kjoy_sel, lptd_sel | lpts_sel})
		'b1XXXXXXX: asic_dout = {soff, ~tape_in, 1'b0, hid_data};
		'b01XXXXXX: asic_dout = {key_data[7:5], ~INT_midi, ~INT_frame, 2'b11, ~INT_line};
		'b001XXXXX: asic_dout = lmpr;
		'b0001XXXX: asic_dout = hmpr;
		'b00001XXX: asic_dout = vid_dout;
		'b000001XX: asic_dout = fdd1_io ? fdd1_dout : fdd2_dout;
		'b0000001X: asic_dout = {2'b00, joystick_0[5:0] | joystick_1[5:0]};
		'b00000001: asic_dout = 0; // fake LPT port.
		'b00000000: asic_dout = 8'hFF;
	endcase
end

reg        INT_midi;
reg        midi_tx;
always @(posedge clk_sys) begin
	reg       old_we;
	reg [8:0] tx_time;
	reg       available;
	
	if(reset) begin
		INT_midi <=0;
		tx_time <= 0;
		midi_tx <= 0;
		available <= 0;
	end else begin
		if(ce_1m) begin
			if(tx_time) begin
				tx_time <= tx_time - 1'd1;
				if(tx_time == 15) INT_midi <= 1;
			end else begin
				{INT_midi, midi_tx} <= 0;
				if(available) begin
					midi_tx   <= 1;
					tx_time   <= 319;
					available <= 0;
				end
			end
		end

		old_we <= port_we;
		if(port_we & ~old_we & midi_sel) available <= 1;
	end
end

////////////////////   AUDIO   ///////////////////
wire [7:0] psg_ch_l;
wire [7:0] psg_ch_r;
wire       tape_in = 0; //tape is not implemented (yet?)

saa1099 psg
(
	.clk_sys(clk_sys),
	.ce(ce_psg),
	.rst_n(~reset),
	.cs_n((addr[7:0] != 255) | nIORQ),
	.a0(addr[8]),
	.wr_n(nWR),
	.din(cpu_dout),
	.out_l(psg_ch_l),
	.out_r(psg_ch_r)
);

wire [18:0] aud_l = {1'b0, psg_ch_l, psg_ch_l, 2'd0} + {1'b0, ear_out, mic_out, tape_in, 15'd0} + {vox_l,vox_l,2'd0} + sid_out;
wire [18:0] aud_r = {1'b0, psg_ch_r, psg_ch_r, 2'd0} + {1'b0, ear_out, mic_out, tape_in, 15'd0} + {vox_r,vox_r,2'd0} + sid_out;

assign AUDIO_L = aud_l[18:3];
assign AUDIO_R = aud_r[18:3];
assign AUDIO_S = 0;
assign AUDIO_MIX = status[7:6];


reg [7:0] vox_l, vox_r;
always @(posedge clk_sys) begin
	reg old_we, old_stb;
	reg [7:0] data;

	if(reset) {vox_l, vox_r, old_stb, data} <= 0;
	else begin
		old_we <= port_we;
		if(port_we & ~old_we) begin
			if(lptd_sel) data <= cpu_dout;
			if(lpts_sel) begin
				if(~old_stb & cpu_dout[0]) vox_l <= data;
				if(old_stb & ~cpu_dout[0]) vox_r <= data;
				old_stb <= cpu_dout[0];
			end
		end
	end
end

// SID uses signed samples and requires special handling
softmuter sid_muter
(
	.clk_sys(clk_sys),
	.ce(ce_1m),

	.enable(sid_act),
	.vol_in({~sid_outraw[17], sid_outraw[16:0]}),
	.vol_out(sid_out)
);

wire [17:0] sid_out;
wire [17:0] sid_outraw;
wire        sid_act;
sid_top sid
(
	.clock(clk_sys),
	.reset(reset),
	.addr(addr[12:8]),
	.wren(port_we && sid_sel && video_mode), // disable in ZX mode
	.wdata(cpu_dout),

	.comb_wave_l(0),
	.comb_wave_r(0),
	.extfilter_en(1),

	.active(sid_act),
	.start_iter(ce_1m),
	.sample_left(sid_outraw)
);


////////////////////   VIDEO   ///////////////////
wire [18:0] vram_addr1;
wire [18:0] vram_addr2;
wire        vram_rd1;
wire        vram_rd2;
wire [15:0] vram_dout1;
wire [15:0] vram_dout2;
wire  [7:0] vid_dout;
wire        vid_sel;
wire        soff = (brdr[7] & video_mode[1]) | turbo_boot;
wire        INT_line;
wire        INT_frame;
wire        mem_contention;
wire        io_contention;
wire  [1:0] video_mode;

video video
(
	.*,
	.ce_pix(CE_PIXEL),
	.full_zx(status[12:11] == 1),
	.scale(status[2:1]),
	.wide(status[4]),
	.din(cpu_dout),
	.dout(vid_dout),
	.dout_en(vid_sel)
);


////////////////////   HID   /////////////////////
wire [11:1] Fn;
wire  [2:0] mod;
wire  [7:0] key_data;
reg         autostart;
keyboard kbd( .*, .restart(rom0_sel & (addr == 0) & ~nMREQ & ~nRD));

wire        kjoy_sel = (addr[7:0] == 'h1F);
wire  [4:0] hid_data = key_data[4:0] & mouse_data
	& (addr[12] ? 5'b11111 : ~{joystick_0[1],  joystick_0[0], joystick_0[2], joystick_0[3], joystick_0[4] | joystick_0[5]})
	& (addr[11] ? 5'b11111 : ~{joystick_1[4] | joystick_1[5], joystick_1[3], joystick_1[2], joystick_1[0],  joystick_1[1]});

wire  [4:0] mouse_data;
mouse mouse( .*, .dout(mouse_data), .rd(kbdr_sel & &addr[15:8] & nM1 & ~nIORQ & ~nRD));


///////////////////   FDC   ///////////////////

reg fdd_num = 0;
always @(posedge clk_sys) begin
	if(sd_rd[1]|sd_wr[1]) fdd_num <= 1;
	if(sd_rd[0]|sd_wr[0]) fdd_num <= 0;
end

assign sd_buff_din = fdd_num ? fdd2_buf_dout : fdd1_buf_dout;
assign sd_lba      = fdd_num ? fdd2_lba      : fdd1_lba;



// FDD1
wire        fdd1_busy;
reg         fdd1_ready;
reg         fdd1_side;
wire        fdd1_io   = fdd_sel & ~addr[4] & ~nIORQ & nM1;
wire  [7:0] fdd1_dout;
wire  [7:0] fdd1_buf_dout;
wire [31:0] fdd1_lba;
reg         fdd1_wp;

always @(posedge clk_sys) begin
	reg old_wr;
	reg old_mounted;

	old_wr <= nWR;
	if(old_wr & ~nWR & fdd1_io) fdd1_side <= addr[2];

	old_mounted <= img_mounted[0];
	if(cold_reset) fdd1_ready <= 0;
		else if(~old_mounted & img_mounted[0]) {fdd1_ready, fdd1_wp} <= {1'b1, img_readonly};
end


wd1793 #(1) fdd1
(
	.clk_sys(clk_sys),
	.ce(cpu_n),
	.reset(reset),
	.io_en(fdd1_io & fdd1_ready),
	.rd(~nRD),
	.wr(~nWR),
	.addr(addr[1:0]),
	.din(cpu_dout),
	.dout(fdd1_dout),

	.img_mounted(img_mounted[0]),
	.img_size(img_size[19:0]),
	.sd_lba(fdd1_lba),
	.sd_rd(sd_rd[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(fdd1_buf_dout),
	.sd_buff_wr(sd_buff_wr),

	.wp(fdd1_wp),

	.size_code(4),
	.layout(ioctl_index[7:6] == 2),
	.side(fdd1_side),
	.ready(fdd1_ready),
	.prepare(fdd1_busy),

	.input_active(0),
	.input_addr(0),
	.input_data(0),
	.input_wr(0),
	.buff_din(0)
);

always @(posedge clk_sys) begin
	reg old_busy;
	integer counter;

	if(reset) begin
		autostart <= 0;
		counter   <= 0;
	end else begin
		old_busy <= fdd1_busy;
		if(old_busy & ~fdd1_busy & fdd1_ready) begin
			autostart <= 1;
			counter   <= 1000000;
		end else if(ce_6mp && counter) begin
			counter   <= counter - 1;
			if(counter == 1) autostart <= 0;
		end
	end
end



// FDD2
reg         fdd2_ready;
reg         fdd2_side;
wire        fdd2_io   = fdd_sel & addr[4] & ~nIORQ & nM1;
wire  [7:0] fdd2_dout;
wire  [7:0] fdd2_buf_dout;
wire [31:0] fdd2_lba;
reg         fdd2_wp;

always @(posedge clk_sys) begin
	reg old_wr;
	reg old_mounted;

	old_wr <= nWR;
	if(old_wr & ~nWR & fdd2_io) fdd2_side <= addr[2];

	old_mounted <= img_mounted[1];
	if(cold_reset) fdd2_ready <= 0;
		else if(~old_mounted & img_mounted[1]) {fdd2_ready, fdd2_wp} <= {1'b1, img_readonly};
end

wd1793 #(1) fdd2
(
	.clk_sys(clk_sys),
	.ce(cpu_n),
	.reset(reset),
	.io_en(fdd2_io & fdd2_ready),
	.rd(~nRD),
	.wr(~nWR),
	.addr(addr[1:0]),
	.din(cpu_dout),
	.dout(fdd2_dout),

	.img_mounted(img_mounted[1]),
	.img_size(img_size[19:0]),
	.sd_lba(fdd2_lba),
	.sd_rd(sd_rd[1]),
	.sd_wr(sd_wr[1]),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(fdd2_buf_dout),
	.sd_buff_wr(sd_buff_wr),

	.wp(fdd2_wp),

	.size_code(4),
	.layout(ioctl_index[7:6] == 2),
	.side(fdd2_side),
	.ready(fdd2_ready),

	.input_active(0),
	.input_addr(0),
	.input_data(0),
	.input_wr(0),
	.buff_din(0)
);

endmodule

module softmuter
(
	input         clk_sys,
	input         ce,
	
	input         enable,
	input  [17:0] vol_in,
	output [17:0] vol_out
);

reg [17:0] att = '1;
assign vol_out = (vol_in > att) ? vol_in - att : 18'd0;

always @(posedge clk_sys) begin
	if(ce) begin
		if( enable &&   att) att <= att - 1'd1;
		if(~enable && ~&att) att <= att + 1'd1;
	end
end

endmodule

module bios
(
	input	       clock,
	input	 [7:0] data,
	input	[14:0] rdaddress,
	input	[14:0] wraddress,
	input	       wren,
	output [7:0] q
);

altsyncram	altsyncram_component (
			.address_a (wraddress),
			.address_b (rdaddress),
			.clock0 (clock),
			.data_a (data),
			.wren_a (wren),
			.q_b (q),
			.aclr0 (1'b0),
			.aclr1 (1'b0),
			.addressstall_a (1'b0),
			.addressstall_b (1'b0),
			.byteena_a (1'b1),
			.byteena_b (1'b1),
			.clock1 (1'b1),
			.clocken0 (1'b1),
			.clocken1 (1'b1),
			.clocken2 (1'b1),
			.clocken3 (1'b1),
			.data_b ({8{1'b1}}),
			.eccstatus (),
			.q_a (),
			.rden_a (1'b1),
			.rden_b (1'b1),
			.wren_b (1'b0));
defparam
	altsyncram_component.address_aclr_b = "NONE",
	altsyncram_component.address_reg_b = "CLOCK0",
	altsyncram_component.clock_enable_input_a = "BYPASS",
	altsyncram_component.clock_enable_input_b = "BYPASS",
	altsyncram_component.clock_enable_output_b = "BYPASS",
	altsyncram_component.init_file = "bios.mif",
	altsyncram_component.intended_device_family = "Cyclone V",
	altsyncram_component.lpm_type = "altsyncram",
	altsyncram_component.numwords_a = 32768,
	altsyncram_component.numwords_b = 32768,
	altsyncram_component.operation_mode = "DUAL_PORT",
	altsyncram_component.outdata_aclr_b = "NONE",
	altsyncram_component.outdata_reg_b = "UNREGISTERED",
	altsyncram_component.power_up_uninitialized = "FALSE",
	altsyncram_component.read_during_write_mode_mixed_ports = "DONT_CARE",
	altsyncram_component.widthad_a = 15,
	altsyncram_component.widthad_b = 15,
	altsyncram_component.width_a = 8,
	altsyncram_component.width_b = 8,
	altsyncram_component.width_byteena_a = 1;


endmodule
