set title "bloat_53"
set palette negative rgbformula 21,22,23
set cbrange [0:2]
set yrange [480:0]
set size ratio 1.57377
set view map
splot "bloat_53.dat" using 1:2:3 with image
pause -1
