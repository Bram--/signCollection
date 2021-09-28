#!/usr/bin/ruby

require 'fileutils'
require 'down/http'

DOWNLOAD_LINK_FORMAT = "https://openclipart.org/download/%d"

FOLDER_DOWNLOADS = "tmp/svgs"
FOLDER_PNGS = "tmp/pngs"
FOLDER_OUTPUT = "output"

class LineWriter
  def initialize
    @last_line_length = 0
  end

  def write(line, &block)
    line_length_delta = @last_line_length - line.length

    print line
    line_length_delta.times { |i| print " " }
    print "\r"

    yield

    $stdout.flush
    @last_line_length = line.length
  end

end

class FileParser
  def initialize(file_path)
    @lines = File.open(file_path).readlines.map(&:chomp).uniq
  end


  ## Build a list of File names and download Ids.
  def parse_download_link_and_names
    download_id_name_pairs = @lines.collect do |line|
      line.scan(/([^\t]+).+openclipart.org\/detail\/(\d+).+/).flatten
    end
    download_id_name_pairs
      .reject! { |pair| pair.empty? }
      .each { |pair| pair[1] = DOWNLOAD_LINK_FORMAT % pair[1] }
  end

  def parse_colors_and_names
    color_name_pairs = @lines.collect do |line|
      line.scan(/([^:]+):\s+(#[a-zA-Z0-9]+)/).flatten
    end
    color_name_pairs
      .reject { |pair| pair.empty? }
      .each { |pair| pair[0] = pair[0].split(/[\s\-\_]/).collect(&:capitalize).join }
  end
end

class ImageDownloader
  def initialize(line_writer, file_name_download_url_pairs)
    @line_writer = line_writer
    @file_name_download_url_pairs = file_name_download_url_pairs
  end

  def download!
    FileUtils.mkdir_p FOLDER_DOWNLOADS

    @file_name_download_url_pairs.each do |name, url|
      file_name = "#{FOLDER_DOWNLOADS}/#{name}.svg"
      unless File.exists?(file_name)
        @line_writer.write("Downloading #{file_name}") do
          Down::Http.download(url, destination: file_name)
        end
      end
    end

    FOLDER_DOWNLOADS
  end

  def self.make_folder(color_name)
    folder
  end
end


# Needs ImageMagick
class ImageConverter
  def initialize(line_writer, svgs, color_pairs)
    @line_writer = line_writer
    @svgs = svgs
    @color_pairs = color_pairs
  end

  def pad_and_colorize!
    FileUtils.mkdir_p FOLDER_PNGS

    @svgs.each do |svg|
      new_file = File.basename(svg, ".svg")
      ratio = `(identify -format "%[fx:w/h]" "#{svg}") 2>/dev/null`.to_f
      epsilon = 0.1

      # Convert svg to downsized PNG.
      png = "#{FOLDER_PNGS}/#{new_file}.png"
      width  = if ratio.between?(epsilon, 0.9) then 1000 else 2000 end
      height = if ratio > 1.2 then 1000 else 2000 end

      # Crop to 1:1, 2:1 or 1:2
      @line_writer.write("Converting #{new_file} ") do
        `rsvg-convert -w #{width} -h #{height} -a \"#{svg}\" > \"#{png}\"`
      end

      @color_pairs.each do |name, hex|
        @line_writer.write("Colorizing #{new_file} #{name}") do
          color_destination = "#{FOLDER_OUTPUT}/#{name}"
          FileUtils.mkdir_p color_destination
          `convert "#{png}"\
                         -fuzz 25 -background "#{hex}"\
                         -gravity center -extent #{width}x#{height}\
                         "#{color_destination}/#{new_file}.png"`
        end
      end
    end
  end
end



## Parse signs file and create Color and Download pairs
parser = FileParser.new("signs.txt")
parser.parse_download_link_and_names
color_pairs = parser.parse_colors_and_names
download_pairs = parser.parse_download_link_and_names

line_writer = LineWriter.new

# Download all
downloader = ImageDownloader.new(line_writer, download_pairs)
download_folder = downloader.download!

# Reencode and crop images
converter = ImageConverter.new(line_writer, Dir[ "#{download_folder}/*.svg" ], color_pairs)
converter.pad_and_colorize!

puts ""
puts "All Done! #{FOLDER_OUTPUT}"

