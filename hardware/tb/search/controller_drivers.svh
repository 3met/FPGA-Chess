// Clock, request/response, setup, and common result-checking helpers.
// Included in tb_search_controller scope.

    task automatic do_clock(input int count = 1);
        for (int idx = 0; idx < count; idx++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask : do_clock

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    function automatic EngineControllerRequest zero_request();
        automatic EngineControllerRequest request;

        request = EngineControllerRequest'('0);
        request.operation = ENGINE_CTRL_IDLE;
        request.board_op = BOARD_IDLE_OP;
        return request;
    endfunction : zero_request

    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        automatic Move move;

        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction : make_move

    function automatic logic is_null_move(input Move move);
        return move.from_pos == Position'(0) && move.to_pos == Position'(0);
    endfunction : is_null_move

    function automatic ThreadID expected_next_thread(input int thread_idx);
        return (thread_idx >= THREAD_COUNT - 1) ? ThreadID'(0) : ThreadID'(thread_idx + 1);
    endfunction : expected_next_thread

    task automatic reset_dut();
        automatic int startup_cycles = 0;
        automatic bit startup_response_seen = 1'b0;
        req_valid = 1'b0;
        req = zero_request();
        rst_n = 1'b0;
        do_clock(3);
        rst_n = 1'b1;
        while (!req_ready && startup_cycles < 200000) begin
            startup_response_seen |= resp_valid;
            do_clock(1);
            startup_cycles++;
        end
        check(req_ready, "controller ready after reset initialization");
        check(!startup_response_seen && !resp_valid, "startup emits no unsolicited response");
    endtask : reset_dut

    task automatic check_search_stats(input string label);
        automatic logic [39:0] phase_total;

        debug_stat_address = ENGINE_STAT_ENABLED;
        #1;
        check(debug_stat_value == 40'd1, {label, " enabled"});
        debug_stat_address = ENGINE_STAT_THREAD_COUNT;
        #1;
        check(debug_stat_value == 40'(THREAD_COUNT), {label, " thread count"});
        debug_stat_address = ENGINE_STAT_PHASE_COUNT;
        #1;
        check(debug_stat_value == 40'(ENGINE_STAT_PHASE_COUNT_VALUE), {label, " phase count"});
        debug_stat_address = ENGINE_STAT_TT_LOOKUPS;
        #1;
        check(debug_stat_value != 40'd0, {label, " recorded TT lookups"});
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            phase_total = 40'd0;
            for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                debug_stat_address = ENGINE_STAT_PHASE_BASE
                    + 8'(tid * ENGINE_STAT_PHASE_COUNT_VALUE + phase);
                #1;
                phase_total += debug_stat_value;
            end
            check(phase_total == dut.stat_search_cycle,
                $sformatf("%s thread %0d phase total matches search cycles", label, tid));
        end
        $display("Search cycle profile %s: nodes=%0d total=%0d ready=%0d tt=%0d eval=%0d move=%0d board=%0d reverse=%0d repetition=%0d store=%0d terminal=%0d done=%0d",
            label, resp.nodes_count, dut.stat_search_cycle,
            dut.stat_phase_cycles[0][0], dut.stat_phase_cycles[0][1],
            dut.stat_phase_cycles[0][2], dut.stat_phase_cycles[0][3],
            dut.stat_phase_cycles[0][4], dut.stat_phase_cycles[0][5],
            dut.stat_phase_cycles[0][6], dut.stat_phase_cycles[0][7],
            dut.stat_phase_cycles[0][8], dut.stat_phase_cycles[0][9]);
    endtask : check_search_stats

    task automatic hold_request_until_ready(input EngineControllerRequest request, input string label);
        automatic int wait_cycles = 0;

        req = request;
        req_valid = 1'b1;
        while (!req_ready && wait_cycles < 5000) begin
            do_clock(1);
            wait_cycles += 1;
        end
        check(req_ready, {label, " accepted"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
        wait_response(label);
    endtask : hold_request_until_ready

    task automatic pulse_request(input EngineControllerRequest request, input string label);
        req = request;
        req_valid = 1'b1;
        #1;
        check(req_ready, {label, " accepted"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
    endtask : pulse_request

    task automatic wait_response(input string label, input int maximum_cycles = 200000);
        automatic int wait_cycles = 0;

        while (!resp_valid && wait_cycles < maximum_cycles) begin
            do_clock(1);
            wait_cycles += 1;
        end
        if (!resp_valid) begin
            $display("timeout %s state=%0d active=%0d", label, dut.state,
                dut.search_active_thread_count);
            for (int tid = 0; tid < THREAD_COUNT; tid++)
                $display("tid=%0d phase=%0d ply=%0d order=%0d gen=%0b cache_valid=%0b cache_ply=%0d mem_phase=%0d stage=%0b load=%0b",
                    tid, dut.search_thread_phase[tid], dut.search_ply[tid],
                    dut.search_stack_top[tid].move_order_state,
                    dut.search_generation_inflight[tid],
                    dut.move_generator.reader.cache_valid[tid],
                    dut.move_generator.reader.cache_ply[tid],
                    dut.move_generator.reader.cache_state[tid].phase,
                    dut.move_generator.reader.stage_valid[tid],
                    dut.move_generator.reader.pointer_load_pending[tid]);
        end
        check(resp_valid, {label, " response valid"});
        do_clock(1);
    endtask : wait_response

    task automatic new_game();
        automatic EngineControllerRequest request = zero_request();
        automatic logic nnue_metadata_clear = 1'b1;

        request.operation = ENGINE_CTRL_NEW_GAME;
        hold_request_until_ready(request, "new game");
        check(!resp.error, "new game response has no error");
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            nnue_metadata_clear &= !dut.nnue_plan_pending[tid];
            nnue_metadata_clear &= !dut.nnue_state_valid[tid];
        end
        check(nnue_metadata_clear, "new game invalidates queued NNUE plans and accumulator states");
        check(dut.nnue_update_idle && dut.nnue_eval_ready,
            "new game leaves the NNUE datapath idle and ready");
    endtask : new_game

    task automatic apply_game_move(input Move move, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_COMMIT_MOVE_OP;
        request.move = move;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " response has no error"});
    endtask : apply_game_move

    task automatic run_perft(input logic [7:0] depth, input NodeCountType expected_nodes, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic time start_time = $time;

        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count == expected_nodes,
            $sformatf("%s expected nodes=%0d found=%0d", label, expected_nodes, resp.nodes_count));
        check(resp.completed_depth == depth, {label, " completed depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        $display("Perft cycle profile %s: nodes=%0d cycles=%0d",
            label, resp.nodes_count, ($time - start_time) / 10);
    endtask : run_perft

    task automatic run_search_depth(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic logic [39:0] generation_cycles_before;
        automatic logic [39:0] destinations_before;
        automatic logic [39:0] candidates_before;

        repetition_root_request_seen = 1'b0;
        repetition_child_request_seen = 1'b0;
        generation_cycles_before = dut.move_stat_generation_cycles;
        destinations_before = dut.move_stat_destination_count;
        candidates_before = dut.move_stat_candidate_count;
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count != NodeCountType'(0), {label, " searches below root"});
        check(resp.completed_depth == depth, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        check(!(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0)), {label, " best move is non-null"});
        if (depth >= 8'd2)
            check(!is_null_move(resp.ponder_move), {label, " ponder move is non-null"});
        check(repetition_root_request_seen, {label, " checks root repetition"});
        check(repetition_child_request_seen, {label, " checks legal child repetition"});
        last_move_generation_cycles =
            dut.move_stat_generation_cycles - generation_cycles_before;
        last_move_destination_count =
            dut.move_stat_destination_count - destinations_before;
        last_move_candidate_count =
            dut.move_stat_candidate_count - candidates_before;
        $display("Move generation profile %s: active_cycles=%0d destinations=%0d candidates=%0d",
            label, last_move_generation_cycles,
            last_move_destination_count, last_move_candidate_count);
    endtask : run_search_depth

    task automatic run_search_depth_record(
        input logic [7:0] depth,
        input string label,
        output Move best_move,
        output EvalScore score,
        output NodeCountType nodes
    );
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.completed_depth == depth, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        best_move = resp.best_move;
        score = resp.score;
        nodes = resp.nodes_count;
    endtask : run_search_depth_record

    task automatic run_perft_error(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(resp.error, {label, " reports error"});
        check(resp.end_reason == ENGINE_END_ERROR, {label, " end reason"});
    endtask : run_perft_error

    task automatic run_search_depth_error(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(resp.error, {label, " reports error"});
        check(resp.end_reason == ENGINE_END_ERROR, {label, " end reason"});
    endtask : run_search_depth_error

    task automatic set_tile(input Tile tile, input Position pos, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic logic [3:0] tile_bits;

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_TILE_OP;
        request.move.to_pos = pos;
        tile_bits = (tile.piece_type == NULL_PIECE) ? 4'h0 : tile;
        request.board_wr_data = {3'b000, tile_bits};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_tile

    task automatic set_turn(input Color color, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_TURN_OP;
        request.board_wr_data = {6'b000000, color};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_turn

    task automatic set_castling_rights(input CastlingRights castling_rights, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_CASTLING_RIGHTS_OP;
        request.board_wr_data = {3'b000, castling_rights};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_castling_rights

    task automatic set_en_passant(input logic has_ep, input BoardFile ep_file, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_EN_PASSANT_OP;
        request.board_wr_data = {3'b000, ep_file, has_ep};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_en_passant

    task automatic set_halfmove_clock(input HalfmoveClock halfmove_clock, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
        request.board_wr_data = halfmove_clock;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_halfmove_clock

    // Position builders always follow New Game, so clear only occupied start
    // squares instead of issuing 64 mostly redundant board-update requests.
    task automatic clear_start_position(input string label);
        for (int pos = 0; pos < 16; pos++) begin
            set_tile(EMPTY_TILE, Position'(pos), $sformatf("%s clear square %0d", label, pos));
        end
        for (int pos = 48; pos < 64; pos++) begin
            set_tile(EMPTY_TILE, Position'(pos), $sformatf("%s clear square %0d", label, pos));
        end
        set_castling_rights(CastlingRights'(4'b0000), {label, " clear castling rights"});
    endtask : clear_start_position

    // The command layer needs multiple cycles to cache a response before acknowledging it.
    task automatic test_response_backpressure();
        automatic EngineControllerRequest request = zero_request();
        automatic EngineControllerResponse held;
        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = 8'd0;
        resp_ready = 1'b0;
        pulse_request(request, "held completion perft");
        while (!resp_valid) do_clock(1);
        held = resp;
        for (int idx = 0; idx < 17; idx++) begin
            do_clock(1);
            check(resp_valid && resp === held && !req_ready,
                "controller holds completion and blocks new requests under response backpressure");
        end
        req.operation = ENGINE_CTRL_KILL;
        req_valid = 1'b1;
        do_clock(2);
        check(resp_valid && resp === held && !req_ready, "late kill cannot overwrite a held completion");
        req_valid = 1'b0;
        req = zero_request();
        resp_ready = 1'b1;
        do_clock(1);
        check(!resp_valid && req_ready, "controller retires completion once accepted");
    endtask : test_response_backpressure
