transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

asim +access +r +m+rom_diagrom  -L xil_defaultlib -L xpm -L blk_mem_gen_v8_4_12 -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.rom_diagrom xil_defaultlib.glbl

do {rom_diagrom.udo}

run 1000ns

endsim

quit -force
