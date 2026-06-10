v {xschem version=3.4.6 file_version=1.2}
G {}
K {}
V {}
S {}
E {}

N -520 -160 520 -160 {lab=vdd}
N -520 80 520 80 {lab=0}
N -400 -160 -400 -120 {lab=vdd}
N -200 -160 -200 -120 {lab=vdd}
N 0 -160 0 -120 {lab=vdd}
N 200 -160 200 -120 {lab=vdd}
N 400 -160 400 -120 {lab=vdd}
N -400 40 -400 80 {lab=0}
N -200 40 -200 80 {lab=0}
N 0 40 0 80 {lab=0}
N 200 40 200 80 {lab=0}
N 400 40 400 80 {lab=0}

N -400 -80 -400 0 {lab=n0}
N -400 -40 -240 -40 {lab=n0}
N -240 -120 -240 40 {lab=n0}
N -200 -80 -200 0 {lab=n1}
N -200 -40 -40 -40 {lab=n1}
N -40 -120 -40 40 {lab=n1}
N 0 -80 0 0 {lab=n2}
N 0 -40 160 -40 {lab=n2}
N 160 -120 160 40 {lab=n2}
N 200 -80 200 0 {lab=n3}
N 200 -40 360 -40 {lab=n3}
N 360 -120 360 40 {lab=n3}
N 400 -80 400 0 {lab=n4}
N 400 -40 500 -40 {lab=n4}
N 500 -40 500 -240 {lab=n4}
N 500 -240 -440 -240 {lab=n4}
N -440 -240 -440 40 {lab=n4}

C {pfet.sym} -400 -120 0 0 {name=MP0}
C {nfet.sym} -400 40 0 0 {name=MN0}
C {pfet.sym} -200 -120 0 0 {name=MP1}
C {nfet.sym} -200 40 0 0 {name=MN1}
C {pfet.sym} 0 -120 0 0 {name=MP2}
C {nfet.sym} 0 40 0 0 {name=MN2}
C {pfet.sym} 200 -120 0 0 {name=MP3}
C {nfet.sym} 200 40 0 0 {name=MN3}
C {pfet.sym} 400 -120 0 0 {name=MP4}
C {nfet.sym} 400 40 0 0 {name=MN4}

C {lab_pin.sym} -520 -160 0 0 {name=pwr lab=vdd}
C {lab_pin.sym} -520 80 0 0 {name=gnd lab=0}
C {lab_pin.sym} -320 -40 0 0 {name=tap0 lab=n0}
C {lab_pin.sym} -120 -40 0 0 {name=tap1 lab=n1}
C {lab_pin.sym} 80 -40 0 0 {name=tap2 lab=n2}
C {lab_pin.sym} 280 -40 0 0 {name=tap3 lab=n3}
C {lab_pin.sym} 500 -140 0 0 {name=tap4 lab=n4}
C {devices/title.sym} -520 240 0 0 {name=l1 author="Codex"}
C {devices/code_shown.sym} 560 240 0 0 {name=NOTE only_toplevel=false value="
Animated ring oscillator demo.
Load animated_ring_demo.spice and run the transient simulation.
The five stage nets n0..n4 chase each other around the loop.
"}
