vlib questa_lib/work
vlib questa_lib/msim

vlib questa_lib/msim/xpm
vlib questa_lib/msim/blk_mem_gen_v8_4_12
vlib questa_lib/msim/xil_defaultlib

vmap xpm questa_lib/msim/xpm
vmap blk_mem_gen_v8_4_12 questa_lib/msim/blk_mem_gen_v8_4_12
vmap xil_defaultlib questa_lib/msim/xil_defaultlib

vlog -work xpm -64 -incr -mfcu  -sv "+incdir+../../../../../../../../../run/media/luis/WNFN/fpga2/2025.2.1/data/rsb/busdef" \
"/run/media/luis/WNFN/fpga2/2025.2.1/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
"/run/media/luis/WNFN/fpga2/2025.2.1/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \

vcom -work xpm -64 -93  \
"/run/media/luis/WNFN/fpga2/2025.2.1/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work blk_mem_gen_v8_4_12 -64 -incr -mfcu  "+incdir+../../../../../../../../../run/media/luis/WNFN/fpga2/2025.2.1/data/rsb/busdef" \
"../../../ipstatic/simulation/blk_mem_gen_v8_4.v" \

vlog -work xil_defaultlib -64 -incr -mfcu  "+incdir+../../../../../../../../../run/media/luis/WNFN/fpga2/2025.2.1/data/rsb/busdef" \
"../../../../fase_12.gen/sources_1/ip/rom_diagrom/sim/rom_diagrom.v" \

vlog -work xil_defaultlib \
"glbl.v"

