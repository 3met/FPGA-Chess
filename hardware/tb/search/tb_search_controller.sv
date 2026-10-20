`timescale 1ns/1ns

import chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
import search_defs::*;
import move_generator_defs::*;
import nnue_defs::*;
import tt_defs::*;

module tb_search_controller #(
    parameter int THREAD_COUNT = 1,
    parameter bit EARLY_ONLY = 0,
    parameter bit MATE_ONLY = 0
);

    `include "hardware/tb/search/controller_fixture.svh"
    `include "hardware/tb/search/controller_drivers.svh"
    `include "hardware/tb/search/controller_positions.svh"
    `include "hardware/tb/search/controller_scenarios.svh"
    `include "hardware/tb/search/controller_sequence.svh"
    `include "hardware/tb/search/controller_monitors.svh"

endmodule : tb_search_controller

// Exercise response arbitration and shared pipelines with a helper thread.
module tb_search_controller_multithread;
    tb_search_controller #(.THREAD_COUNT(2)) bench();
endmodule : tb_search_controller_multithread

// Exercise arbitration wraparound with a non-power-of-two thread count.
module tb_search_controller_three_threads;
    tb_search_controller #(.THREAD_COUNT(3)) bench();
endmodule : tb_search_controller_three_threads

// Verify exact mate distance with both serial and shared-table search.
module tb_search_controller_fifty_move_mate;
    tb_search_controller #(.MATE_ONLY(1)) bench();
endmodule : tb_search_controller_fifty_move_mate

module tb_search_controller_fifty_move_mate_multithread;
    tb_search_controller #(.THREAD_COUNT(2), .MATE_ONLY(1)) bench();
endmodule : tb_search_controller_fifty_move_mate_multithread

// Force only the ordering thresholds, retaining real generation and search.
module tb_search_controller_early_reads;
    tb_search_controller #(.THREAD_COUNT(2), .EARLY_ONLY(1)) bench();
endmodule : tb_search_controller_early_reads
