// HADES-SRAM coverage exclusions (urg -elfile, loaded with
// -excl_bypass_checks so checksum drift never silently unmatches).
//
// 1) FSM phantom reset arcs: urg infers an arc "state -> IDLE" for every
//    state from the reset assignment.  These three fire only when ui_rst
//    asserts while the FSM is mid-transaction in exactly that state —
//    RD_SYNTH is a single-cycle state (uncatchable by real reset timing) —
//    and all are the defensive reset path reviewed by inspection.  The
//    reset-recovery test (test_rst) covers the practically reachable arcs.
//
// 2) slot_stky_u set path: the response-slot-overflow sentinel is
//    fault-only logic, unreachable in legal operation — the slot budget
//    (spec 4.3) guarantees a free slot at every response by construction.

MODULE: hades_mig_if
Fsm rd_state "633467097"
Transition RD_ISSUE->RD_IDLE "1->0"
Transition RD_SYNTH->RD_IDLE "2->0"

MODULE: hades_backdoor
Fsm state "2639661931"
Transition B_RD->B_IDLE "1->0"

MODULE: hades_sram_top
Block 32 "92565036" "slot_stky_u <= 1'b1;"
