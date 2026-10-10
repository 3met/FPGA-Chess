// Shared repetition initialization states for RTL and verification.
package repetition_defs;
    typedef enum logic [2:0] {
        REP_INIT_IDLE, REP_INIT_CLEAR, REP_INIT_HISTORY_READ, REP_INIT_STATIC_READ,
        REP_INIT_STATIC_CHECK, REP_INIT_RETRY, REP_INIT_READY, REP_INIT_FAIL
    } RepetitionInitState;
endpackage : repetition_defs
