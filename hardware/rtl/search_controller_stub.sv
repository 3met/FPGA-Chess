// By Emet Behrendt

import general_chess_defs::*;
import engine_defs::*;

module search_controller_stub #(
    parameter int RESPONSE_LATENCY = 3
) (
    input wire clk,
    input wire rst_n,
    input logic req_valid,
    output logic req_ready,
    input EngineControllerRequest req,
    output logic resp_valid,
    output EngineControllerResponse resp
);

    localparam int TIMER_BITS = (RESPONSE_LATENCY <= 1) ? 1 : $clog2(RESPONSE_LATENCY + 1);

    EngineControllerOp active_operation;
    logic [TIMER_BITS-1:0] timer;
    EngineControllerResponse resp_reg;

    assign req_ready = 1'b1;
    assign resp = resp_reg;

    function automatic logic request_needs_response(input EngineControllerOp operation);
        case (operation)
            ENGINE_CTRL_SEARCH_DEPTH,
            ENGINE_CTRL_SEARCH_FIXED_TIME,
            ENGINE_CTRL_SEARCH_ON_CLOCK,
            ENGINE_CTRL_SEARCH_NODES,
            ENGINE_CTRL_PERFT: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction : request_needs_response

    function automatic EngineControllerResponse placeholder_response(input EngineControllerRequest request);
        automatic EngineControllerResponse response;

        response = EngineControllerResponse'('0);
        response.error = 1'b0;
        response.best_move.from_pos = Position'('d12);
        response.best_move.to_pos = Position'('d28);
        response.best_move.promo_piece = PROMO_QUEEN;
        response.score = EvalScore'(0);
        response.nodes_count = NodeCountType'(1);
        response.completed_depth = request.depth_limit;
        response.end_reason = (request.operation == ENGINE_CTRL_PERFT) ? ENGINE_END_DEPTH_LIMIT : ENGINE_END_NORMAL;
        response.board_rd_data = 4'h0;
        return response;
    endfunction : placeholder_response

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_operation <= ENGINE_CTRL_IDLE;
            timer <= '0;
            resp_valid <= 1'b0;
            resp_reg <= EngineControllerResponse'('0);
        end else begin
            resp_valid <= 1'b0;

            if (req_valid && request_needs_response(req.operation)) begin
                active_operation <= req.operation;
                resp_reg <= placeholder_response(req);
                timer <= TIMER_BITS'(RESPONSE_LATENCY);
            end else if (req_valid && req.operation == ENGINE_CTRL_KILL) begin
                active_operation <= ENGINE_CTRL_IDLE;
                resp_reg.error <= 1'b0;
                resp_reg.end_reason <= ENGINE_END_KILLED;
                timer <= '0;
            end else if (timer != '0) begin
                timer <= timer - TIMER_BITS'(1);
                if (timer == TIMER_BITS'(1)) begin
                    resp_valid <= 1'b1;
                    active_operation <= ENGINE_CTRL_IDLE;
                end
            end
        end
    end

endmodule : search_controller_stub
