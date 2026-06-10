v {xschem version=3.4.6 file_version=1.2}
G {}
K {}
V {}
S {}
E {}
N -222 -18 -100 -18 {lab=IN}
N -100 -18 -100 -30 {lab=IN}
N -100 -18 -100 30 {lab=IN}
N -100 -30 -60 -30 {lab=IN}
N -100 30 -60 30 {lab=IN}
N -20 -100 -20 -70 {lab=VPWR}
N -20 -10 -20 10 {lab=OUT}
N -20 0 120 0 {lab=OUT}
N -20 70 -20 100 {lab=VGND}
C {button/button.sym} -304 -50 0 0 {name=VINBTN}
C {pfet_01v8.sym} -20 -30 0 0 {name=MP1 L=0.15 W=2 nf=1 mult=1 model=pfet_01v8 spiceprefix=X}
C {nfet_01v8.sym} -20 30 0 0 {name=MN1 L=0.15 W=1 nf=1 mult=1 model=nfet_01v8 spiceprefix=X}
C {lab_pin.sym} -120 -18 0 0 {name=p1 lab=IN}
C {lab_pin.sym} 120 0 0 0 {name=p2 lab=OUT}
C {lab_pin.sym} -20 -100 0 0 {name=p3 lab=VPWR}
C {lab_pin.sym} -20 100 0 0 {name=p4 lab=VGND}
C {devices/title.sym} -160 160 0 0 {name=l1 author="Circuit Simulator Demo" title="Sky130 Button-Controlled Inverter"}
