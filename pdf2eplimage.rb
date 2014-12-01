#!/usr/bin/env ruby

paper = [ 100, 150 ]
inch = 25.4
dpi = 203
dots = paper.map { |i| (i*dpi/inch).to_i }

IO.popen("convert -density 400 -size #{dots.join('x')} '#{ARGV[0]}' -layers merge -trim -resize #{dots.join('x')} -negate pbm:-", 'r') do |f|
       raise RuntimeError, 'Expected P4 format' unless f.readline.chop == 'P4'
       width, height = f.readline.chop.split(/\s+/).map(&:to_i)
       bytes = f.read.b
       raise RuntimeError, "Expected #{width*height/8} bytes, but read only #{bytes.length}" if bytes.length*8 != width*height
       raise RuntimeError, "Expected scan line bit count to be divisible by 8" if ((width.to_f/8)*8) != width
       margins = [ width, height ].zip(dots).map { |a,b| (b-a)/2 }
       header = [ 'N', 'S2', 'D14', "q#{dots[0]}", "Q#{dots[1]}" ]
       footer = [ 'P1,1' ]
       cmd = sprintf('GW%d,%d,%d,%d,', margins[0], margins[1], width/8, height) + bytes
       
       puts (header + [cmd] + footer).join("\n")
end
