#!/usr/bin/env ruby

require 'pdf/reader'
require 'pp'

class MyReceiver 
	def initialize
		@lines = []
		@texts = []
		@images = []
		@stack = []
		@rectangles = []
		@state = { :matrix => identity_matrix }
		@current_text = {}
	end

	def stats
		{ 
			:lines => @lines,
			:texts => @texts,
			:rectangles => @rectangles,
			:images => @images
		}
	end


	def page=(c)
		@page = c
		@page_height = @page.attributes[:MediaBox][3]
	end

	def set_line_cap_style(style)
		@current_line = {} unless @current_line
		@current_line[:style] = style
	end

	def set_line_width(width)
		@current_line = {} unless @current_line
		@current_line[:width] = width
	end
		
	def begin_text_object
		@current_text = {} if @current_text.nil?
	end

	def set_text_font_and_size(font_id, size)
		@current_text[:font] = font_id
		@current_text[:size] = size
	end
	def set_text_matrix_and_text_line_matrix(scale_x,shear_x,shear_y,scale_y,x,y)
		if scale_x == 1.0 and shear_x == 0 and shear_y == 0 and scale_y == 1
			@current_text[:rotate] = :rotate0
		elsif scale_x == 0 and shear_x == -1.0 and shear_y == 1.0 and scale_y == 0
			@current_text[:rotate] = :rotate90
		elsif scale_x == -1 and shear_x == 0 and shear_y == 0 and scale_y == -1
			@current_text[:rotate] = :rotate180
		elsif scale_x == 0 and shear_x == 1.0 and shear_y == -1.0 and scale_y == 0
			@current_text[:rotate] = :rotate270
		else
			raise RuntimeError,'EPL supports only (0,90,180,270) text rotation'
		end
		move_text_position(x,y)	
	end

	def move_text_position(x,y) 
		@current_text[:position] = [x, @page_height - y]
	end

	def show_text(text)
		@current_text[:text] = text
	end

	def set_horizontal_text_scaling(scale)
		@current_text[:hscale] = scale.to_f/100
	end

	def end_text_object
		@texts << make_text(@current_text.clone) if @current_text[:text] and @current_text[:text].length > 0
		@current_text[:text] = nil
		@current_text[:rotate] = :rotate0
	end

	def make_text(obj)
		font = PDF::Reader::Font.new(@page.objects, @page.fonts[obj[:font]])
		width = font.unpack(obj[:text]).map { |c|
			font.glyph_width(c)/1000*obj[:size]
		}.reduce(:+)
		obj[:text] = font.to_utf8(obj[:text])
		obj[:width] = width
		if obj[:rotate] == :rotate0
			obj[:end] = [ obj[:position][0] + obj[:width], obj[:position][1] + obj[:size] ]
		elsif obj[:rotate] == :rotate90
			obj[:end] = [ obj[:position][0] + obj[:size], obj[:position][1] + obj[:width] ]
		elsif obj[:rotate] == :rotate180
			obj[:end] = [ obj[:position][0] - obj[:width], obj[:position][1] - obj[:size] ]
		elsif obj[:rotate] == :rotate270
			obj[:end] = [ obj[:position][0] - obj[:size], obj[:position][1] - obj[:width] ]
		end

		obj
	end

	def begin_new_subpath(x, y)
		@position = [ x, @page_height - y ]
	end	

	def append_line(x, y)
		@lines << @current_line.merge({ :from => @position, :to => [ x, @page_height - y ] })
	end

	def stroke_path
		# WTF?
	end

	def save_graphics_state
		@stack.push({ :matrix => @state[:matrix].clone }) 
	end

	def restore_graphics_state
		@state = @stack.pop
	end

	def invoke_xobject(object_id)
		obj = @page.xobjects[object_id]
		raise RuntimeError, 'XObject not found: ' + object_id.to_s unless obj
		raise RuntimeError, 'Only image XObjects are supported: ' + obj.hash[:Subtype].to_s unless obj.hash[:Subtype] == :Image
		matrix = @state[:matrix].clone
		matrix = matrix.multiply!(*obj.hash[:Matrix].to_a) if obj.hash[:Matrix]
		@images << make_image({ :matrix => matrix.to_a, :image => obj })
	end

	def make_image(obj) 
		m = obj[:matrix]
		obj[:width] = m[0]
		obj[:height] = m[4]
		obj[:position] = [ m[6], @page_height - m[7] - obj[:height] ]
		raise RuntimeError, 'Only FlateDecode is currently supported' if obj[:image].hash[:Filter] != :FlateDecode
		cs = obj[:image].hash[:ColorSpace]
		# TODO: someone should make *real* image support, but i only need 1 bit bw images.
		raise RuntimeError, 'Only 1 bit indexed image is currently supported' unless cs[0] == :Indexed and cs[1] == :DeviceRGB and cs[2] == 1 and cs[3].unfiltered_data == "\x00\x00\x00\xFF\xFF\xFF".b
		bytes = Zlib::Inflate.new.inflate(obj[:image].data).b
		# img.hash[:Width] is few bits smaller then real image row ("scan line") in stream
		pixels_height = obj[:image].hash[:Height]	
		pixels_width = (bytes.length*8 / pixels_height).to_i
		raise RuntimeError, 'Image row bit count should be integer value' if pixels_width*pixels_height != bytes.length*8
		raise RuntimeError, 'Image row bit count should be rounded to 8 bits' if (pixels_width.to_f/8).to_i*8 != pixels_width
		obj[:data] = { 
			:bytes => bytes,
			:width => pixels_width,
			:height => pixels_height
		}
		obj
	end


	def identity_matrix
		PDF::Reader::TransformationMatrix.new(1,0,
   						      0,1,
						      0,0) 
	end
	def concatenate_matrix(a,b,c,d,e,f) 		
		@state[:matrix].multiply!(a,b,c,d,e,f)
	end

	def append_rectangle(x,y, width, height)
		@rectangles << { :pos => [x,@page_height - y], :size => [width,-height], :print => false }
	end

	def fill_path_with_nonzero
		@rectangles.last[:print] = true
	end

	def method_missing(method, *args, &block) 
		raise 'Unsupported pdf method: ' + [ method, *args ].inspect unless [ :r ].index(method)
	end

	def calculate_area
		minx = []
		maxx = []
		miny = []
		maxy = []

		minx << @lines.map { |line| [ line[:from][0], line[:to][0] ].min }.min
		maxx << @lines.map { |line| [ line[:from][0], line[:to][0] ].max }.max
		minx << @rectangles.map { |r| [ r[:pos][0], r[:pos][0] + r[:size][0] ].min }.min
		maxx << @rectangles.map { |r| [ r[:pos][0], r[:pos][0] + r[:size][0] ].max }.max
		minx << @texts.map { |text| [ text[:position][0], text[:end][0] ].min }.min
		maxx << @texts.map { |text| [ text[:position][0], text[:end][0] ].max }.max
		[ 'Lines', 'Rectangles', 'Texts' ].zip( minx.zip(maxx) ).each { |title, a|
			left, right = a
			STDERR.puts "#{title} from #{left} to #{right}"
		}
		
		miny << @lines.map { |line| [ line[:from][1], line[:to][1] ].min }.min
		maxy << @lines.map { |line| [ line[:from][1], line[:to][1] ].max }.max
		miny << @rectangles.map { |r| [ r[:pos][1], r[:pos][1] + r[:size][1] ].min }.min
		maxy << @rectangles.map { |r| [ r[:pos][1], r[:pos][1] + r[:size][1] ].max }.max
		miny << @texts.map { |text| [ text[:position][1], text[:end][1] ].min }.min
		maxy << @texts.map { |text| [ text[:position][1], text[:end][1] ].max }.max
		{ :top => miny.min, :bottom => maxy.max, :left => minx.min, :right => maxx.max, :width => maxx.max - minx.min, :height => maxy.max - miny.min }
	end
	
	def scale_to(width, height)
		area = calculate_area
		STDERR.puts("Scaling #{area[:width]}x#{area[:height]} to #{width}x#{height}")
		offset = { :x => area[:left], :y => area[:top] }
		scale = { :x => area[:width]/width, :y => area[:height]/height }
		@texts.map! { |text|
			text[:realpos] = {
				:position => [ (text[:position][0] - offset[:x])/scale[:x], (text[:position][1] - offset[:y])/scale[:y] ],
		   		:width => text[:width]/scale[:x],
				:size => text[:size]/scale[:y],
				:hscale => text[:hscale]
			}
			if text[:rotate] == nil or text[:rotate] == :rotate0
				text[:realpos][:position][1] -= text[:size]/scale[:y]
			elsif text[:rotate] == :rotate90
				text[:realpos][:position][0] -= text[:size]/scale[:x]
			end
			# TODO: elsifs
		   	text
		}	
		@rectangles.map! { |r|
			r[:realpos] = {
				:p0 => [ (r[:pos][0] - offset[:x])/scale[:x], (r[:pos][1] - offset[:y])/scale[:y] ],
				:p1 => [ (r[:pos][0] + r[:size][0] - offset[:x])/scale[:x], (r[:pos][1] + r[:size][1] - offset[:y])/scale[:y] ],
			}
			r[:realpos][:start] = [ 
				[ r[:realpos][:p0][0], r[:realpos][:p1][0] ].min,
				[ r[:realpos][:p0][1], r[:realpos][:p1][1] ].min
			]
			r[:realpos][:end] = [ 
				[ r[:realpos][:p0][0], r[:realpos][:p1][0] ].max,
				[ r[:realpos][:p0][1], r[:realpos][:p1][1] ].max
			]
			r[:realpos][:width] = r[:realpos][:end][0] - r[:realpos][:start][0]
			r[:realpos][:height] = r[:realpos][:end][1] - r[:realpos][:start][1]
			r
		}
		@lines.map! { |line|
			line[:realpos] = { 
				:from => [ (line[:from][0] - offset[:x])/scale[:x], (line[:from][1] - offset[:y])/scale[:y] ],
				:to => [ (line[:to][0] - offset[:x])/scale[:x], (line[:to][1] - offset[:y])/scale[:y] ],
			}
			line[:realpos][:start] = [
				[ line[:realpos][:from][0], line[:realpos][:to][0] ].min,
				[ line[:realpos][:from][1], line[:realpos][:to][1] ].min
			]
			line[:realpos][:width] = [ line[:realpos][:from][0], line[:realpos][:to][0] ].max - line[:realpos][:start][0]
			line[:realpos][:height] = [ line[:realpos][:from][1], line[:realpos][:to][1] ].max - line[:realpos][:start][1]
			if line[:realpos][:width] == 0.0
				line[:realpos][:width] = line[:width]/scale[:x] 
				line[:realpos][:start][0] -= line[:realpos][:width]
			end
			if line[:realpos][:height] == 0.0
				line[:realpos][:height] = line[:width]/scale[:y] 
				line[:realpos][:start][1] -= line[:realpos][:height]
			end
			line
		}		
		@images.map! { |image|
			image[:realpos] = {
				:position => [ (image[:position][0]-offset[:x])/scale[:x], (image[:position][1]-offset[:y])/scale[:y] ],
				:width => image[:width]/scale[:x],
				:height => image[:height]/scale[:y]			
			}
			image
		}
	end

	def select_best_font_for_text(text, startfrom = 5)
		expected_height = text[:realpos][:size]
		expected_text_width = text[:realpos][:width]
		fonts = [ 
			[ 1, 10, 12 ], # font id, width, height, in dots
			[ 2, 12, 16 ], 
			[ 3, 14, 20 ], 
			[ 4, 16, 24 ],
			[ 5, 36, 48 ]
		]		
		if startfrom <= 0
			STDERR.puts("No good candidate for #{text[:text]}/#{expected_height}/#{expected_text_width/text[:text].length}, choosing font 1 and upscaling")
			f = fonts.first
			fid, vscale, hscale = [ f[0], (expected_height/f[2]).round, (expected_text_width.to_f/text[:text].length/f[1]).round ] 
#T			text[:realpos][:position][1] -= vscale*f[2]
			STDERR.puts("Expected: width = #{expected_text_width}; height = #{expected_height}")
			STDERR.puts("Actual: width = #{hscale*f[1]*text[:text].length}; height = #{vscale*f[2]}")
			STDERR.puts("Upscale results: hscale x vscale = #{hscale}x#{vscale}, height error #{expected_height - vscale*f[2]}, width error #{expected_text_width - text[:text].length*f[1]*hscale}}(#{(expected_text_width-f[1]*hscale*text[:text].length).to_f/text[:text].length} per char)")			
			error = text[:text].length*f[1]*hscale - expected_text_width
			if error > 0
#				puts "Moving text left because of error(#{error} dots, #{text[:rotate].to_s})"
				if (text[:rotate] == :rotate0 or text[:rotate] == nil) and text[:realpos][:position][0] > error.to_i/2
					text[:realpos][:position][0] -= error.to_i/2
				elsif text[:rotate] == :rotate90 and text[:realpos][:position][1] > error.to_i/2
					text[:realpos][:position][1] -= error.to_i/2
				end 
				# TODO: elsifs
			end
			return [ fid, vscale, hscale ]
		else
			diff, fid, vscale = (1..9).map { |i|
				fonts[0..startfrom].map { |fid, w, h|
					[ (h*i-expected_height).abs, fid, i ]
				}.min
			}.min
			diff, hscale = (1..6).map { |i|
				[ (fonts[fid-1][1]*text[:text].length*i - expected_text_width).abs, i ]
			}.min			
			if text[:text].match(/^\d+$/)
				current_width = fonts[fid-1][1]*text[:text].length		
#T				text[:realpos][:position][1] -= vscale*fonts[fid-1][2]
				STDERR.puts([ 'selected ', fid, vscale, ' for ', expected_height, text[:text]].inspect)
				STDERR.puts([ 'widths expected', expected_text_width, 'actual', current_width, 'hscale', hscale ].inspect)
				vscale = hscale = [ vscale, hscale ].max
				[ fid, vscale, hscale ]
			elsif hscale * fonts[fid-1][1]*text[:text].length > 1.35 * expected_text_width
				return select_best_font_for_text(text, fid-2)
			else
				current_width = fonts[fid-1][1]*text[:text].length		
#T				text[:realpos][:position][1] -= vscale*fonts[fid-1][2]
				STDERR.puts([ 'selected ', fid, vscale, ' for ', expected_height, text[:text]].inspect)
				error = current_width - expected_text_width 
				if error > 0 
					if text[:rotate] == :rotate0 or text[:rotate] == nil and text[:realpos][:position][0] > error.to_i/2
						text[:realpos][:position][0] -= error.to_i/2 
					elsif text[:rotate] == :rotate90 
						text[:realpos][:position][1] -= error.to_i/2 and text[:realpos][:position][1] > error.to_i/2
					end 
					# TODO: elsifs
				end
				STDERR.puts([ 'widths expected', expected_text_width, 'actual', current_width, 'hscale', hscale ].inspect)
				[ fid, vscale, hscale ]
			end
		end
	end

	def fix_text_object_position(text, fid, vscale, hscale, boxwidth, boxheight, lastchance = false)
		fonts = [ 
			[ 1, 10, 12 ], # font id, width, height, in dots
			[ 2, 12, 16 ], 
			[ 3, 14, 20 ], 
			[ 4, 16, 24 ],
			[ 5, 36, 48 ]
		]
		font_width = fonts[fid-1][1]
		font_height = fonts[fid-1][2]
		l = text[:text].length
		# we do not want text objects to overflow
		# so move them left if they overflow
#		p [ :fix, text[:realpos][:position][0], font_width*l*hscale, text[:realpos][:position][0] + font_width*l*hscale,  boxwidth ]
		if (text[:rotate] == :rotate0 or text[:rotate] == nil) and text[:realpos][:position][0] + font_width*l*hscale > boxwidth
			error = text[:realpos][:position][0] + font_width*l - boxwidth
			if text[:realpos][:position][0] - error <= 0
				raise RuntimeError, "I am sorry, this text if too long to fit on label: #{text[:text].inspect}" if lastchance
				really_fix_text_object(text)
				return fix_text_object_position(text, fid, vscale, hscale, boxwidth, boxheight, true)
			else
				STDERR.puts("Fixing text box, #{error} dots overflow")
				text[:realpos][:position][0] -= (error+20) # 20 dots for margin
			end
		end 
		# TODO elsifs for other rotates
	end

	def really_fix_text_object(text)
		STDERR.puts("Text too long, trying to fix by removing spaces")
		text[:text] = text[:text].gsub(/([.,]) /,'\1')
	end

	def generate_epl
		rotates = { nil => 0, :rotate0 => 0, :rotate90 => 1, :rotate180 => 2, :rotate270 => 3 }
		dpi = 203 # dots/inch
		labelheight = 150.0 # mm
		labelwidth = 100.0 # mm
		inch = 25.4 # mm
		labelheight_dots = labelheight/inch*dpi
		labelwidth_dots = labelwidth/inch*dpi

		scale_to(labelwidth_dots, labelheight_dots)
		header = []
		header << "N" # new label
		header << "S3" # speed 3
		header << "D11" # density 11 (0-15)
		
		header << "q#{labelwidth_dots.to_i}" # width in dots
		header << "Q#{labelheight_dots.to_i},26" # label height in dots
		header << "I8,B,001" # 8 bit character encoding (8), windows 1250 (B), 001 (country code)
		footer = []
		footer <<  "P1,1\n"
		(header + 
		@texts.map { |text|
			pos = text[:realpos]
			font, font_vscale, font_hscale = select_best_font_for_text(text)
			fix_text_object_position(text, font, font_vscale, font_hscale, labelwidth_dots, labelheight_dots)
			#font_hscale = font_vscale # 1-6, 8
			# font_vscale = 1 # 1-9
			escaped_text = text[:text].gsub(/\\/,'\\\\').gsub(/([^\\])"/,'\1\\"').encode('cp1250')
			sprintf 'A%d,%d,%d,%d,%d,%d,N,"%s"', pos[:position][0], pos[:position][1], rotates[text[:rotate]], font, font_hscale, font_vscale, escaped_text
		} + 
		@rectangles.map { |r|
			rp = r[:realpos]
			sprintf 'LO%d,%d,%d,%d', rp[:start][0], rp[:start][1], rp[:width], rp[:height]
		} + 
		@lines.map { |line| 
			rp = line[:realpos]
			sprintf 'LO%d,%d,%d,%d', rp[:start][0], rp[:start][1], rp[:width], rp[:height]
		} + footer).join("\n")
	end
end

#receiver = PDF::Reader::RegisterReceiver.new
receiver = MyReceiver.new
PDF::Reader.open(ARGV[0]) do |reader|
	reader.pages.each do |page|
		page.walk(receiver)
		puts(receiver.generate_epl)
		PP.pp(receiver.calculate_area, STDERR)
		PP.pp(receiver.stats, STDERR)
	end
end
