open_checkpoint [lindex [glob ./build/sync/post_synth.dcp] 0]
delete_pblock pblock_hades
create_pblock pblock_hades
add_cells_to_pblock pblock_hades [get_cells u_hades]
resize_pblock pblock_hades -add {CLOCKREGION_X2Y10:CLOCKREGION_X3Y14}
puts "--- pblock with small SLR2 sub-rectangle; placing"
opt_design
place_design
puts "PLACE_OK"
exit
