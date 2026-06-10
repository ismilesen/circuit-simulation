v {xschem version=3.4.6 file_version=1.2}
G {}
K {}
V {}
S {}
E {}
N 0 -120 100 -120 {lab=VPWR}
N 0 -40 100 -40 {lab=OUT}
N 100 -40 220 -40 {lab=OUT}
N 40 -20 40 -40 {lab=OUT}
N 40 60 80 60 {lab=NINT}
N 40 140 40 170 {lab=VGND}
N -338 -80 -40 -80 {lab=A}
N -120 -80 -120 20 {lab=A}
N -120 20 0 20 {lab=A}
N -338 60 -260 60 {lab=B}
N -260 60 -260 190 {lab=B}
N -260 190 240 190 {lab=B}
N 240 190 240 -80 {lab=B}
N 240 -80 60 -80 {lab=B}
N 0 190 0 100 {lab=B}
C {pfet_01v8.sym} 0 -80 0 0 {name=MPA L=0.15 W=2 nf=1 mult=1 model=pfet_01v8 spiceprefix=X}
C {pfet_01v8.sym} 100 -80 0 0 {name=MPB L=0.15 W=2 nf=1 mult=1 model=pfet_01v8 spiceprefix=X}
C {nfet_01v8.sym} 40 20 0 0 {name=MNA L=0.15 W=1 nf=1 mult=1 model=nfet_01v8 spiceprefix=X}
C {nfet_01v8.sym} 40 100 0 0 {name=MNB L=0.15 W=1 nf=1 mult=1 model=nfet_01v8 spiceprefix=X}
C {button/button.sym} -420 -112 0 0 {name=VA}
C {button/button.sym} -420 28 0 0 {name=VB}
C {lab_pin.sym} -120 -80 0 0 {name=p1 lab=A}
C {lab_pin.sym} -260 60 0 0 {name=p2 lab=B}
C {lab_pin.sym} 220 -40 0 0 {name=p3 lab=OUT}
C {lab_pin.sym} 50 -120 0 0 {name=p4 lab=VPWR}
C {lab_pin.sym} 40 170 0 0 {name=p5 lab=VGND}
C {lab_pin.sym} 80 60 0 0 {name=p6 lab=NINT}
C {devices/title.sym} -180 230 0 0 {name=l1 author="Circuit Simulator Demo" title="Sky130 NAND2 With Live Inputs"}
