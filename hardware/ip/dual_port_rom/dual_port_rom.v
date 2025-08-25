

// synopsys translate_off
`timescale 1 ps / 1 ps
// synopsys translate_on
module dual_port_rom
	#(
		parameter NUM_WORDS,
		parameter WORD_SIZE,
		parameter MEM_INIT_FILE
	) (
		address_a,
		address_b,
		clock,
		rden_a,
		rden_b,
		q_a,
		q_b
	);

	input	[$clog2(NUM_WORDS)-1:0]  address_a;
	input	[$clog2(NUM_WORDS)-1:0]  address_b;
	input	  clock;
	input	  rden_a;
	input	  rden_b;
	output	[WORD_SIZE-1:0]  q_a;
	output	[WORD_SIZE-1:0]  q_b;
`ifndef ALTERA_RESERVED_QIS
// synopsys translate_off
`endif
	tri1	  clock;
	tri1	  rden_a;
	tri1	  rden_b;
`ifndef ALTERA_RESERVED_QIS
// synopsys translate_on
`endif

	wire [WORD_SIZE-1:0] sub_wire0 = 8'h0;
	wire  sub_wire1 = 1'h0;
	wire [WORD_SIZE-1:0] sub_wire2;
	wire [WORD_SIZE-1:0] sub_wire3;
	wire [WORD_SIZE-1:0] q_a = sub_wire2[WORD_SIZE-1:0];
	wire [WORD_SIZE-1:0] q_b = sub_wire3[WORD_SIZE-1:0];

	altsyncram	altsyncram_component (
				.address_a (address_a),
				.address_b (address_b),
				.clock0 (clock),
				.data_a (sub_wire0),
				.data_b (sub_wire0),
				.rden_a (rden_a),
				.rden_b (rden_b),
				.wren_a (sub_wire1),
				.wren_b (sub_wire1),
				.q_a (sub_wire2),
				.q_b (sub_wire3)
				// synopsys translate_off
				,
				.aclr0 (),
				.aclr1 (),
				.addressstall_a (),
				.addressstall_b (),
				.byteena_a (),
				.byteena_b (),
				.clock1 (),
				.clocken0 (),
				.clocken1 (),
				.clocken2 (),
				.clocken3 (),
				.eccstatus ()
				// synopsys translate_on
				);
	defparam
		altsyncram_component.address_reg_b = "CLOCK0",
		altsyncram_component.clock_enable_input_a = "BYPASS",
		altsyncram_component.clock_enable_input_b = "BYPASS",
		altsyncram_component.clock_enable_output_a = "BYPASS",
		altsyncram_component.clock_enable_output_b = "BYPASS",
		altsyncram_component.indata_reg_b = "CLOCK0",
		altsyncram_component.init_file = MEM_INIT_FILE,
		altsyncram_component.intended_device_family = "Cyclone V",
		altsyncram_component.lpm_type = "altsyncram",
		altsyncram_component.numwords_a = NUM_WORDS,
		altsyncram_component.numwords_b = NUM_WORDS,
		altsyncram_component.operation_mode = "BIDIR_DUAL_PORT",
		altsyncram_component.outdata_aclr_a = "NONE",
		altsyncram_component.outdata_aclr_b = "NONE",
		altsyncram_component.outdata_reg_a = "UNREGISTERED",
		altsyncram_component.outdata_reg_b = "UNREGISTERED",
		altsyncram_component.power_up_uninitialized = "FALSE",
		altsyncram_component.widthad_a = $clog2(NUM_WORDS),
		altsyncram_component.widthad_b = $clog2(NUM_WORDS),
		altsyncram_component.width_a = WORD_SIZE,
		altsyncram_component.width_b = WORD_SIZE,
		altsyncram_component.width_byteena_a = 1,
		altsyncram_component.width_byteena_b = 1,
		altsyncram_component.wrcontrol_wraddress_reg_b = "CLOCK0";

endmodule
