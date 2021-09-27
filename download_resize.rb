#!/usr/bin/ruby

require 'fileutils'
require 'down/http'

OUT_FOLDER = "out"
DOWNLOAD_FOLDER = "svgs"
DOWNLOAD_LINK_FORMAT = "https://openclipart.org/download/%d"

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
    destination = "#{OUT_FOLDER}/#{DOWNLOAD_FOLDER}"
    FileUtils.mkdir_p destination

    @file_name_download_url_pairs.each do |name, url|
      file_name = "#{destination}/#{name}.svg"
      unless File.exists?(file_name)
        @line_writer.write("Downloading #{file_name}") do
          Down::Http.download(url, destination: file_name)
        end
      end
    end

    destination
  end

  def self.make_folder(color_name)
    folder
  end
end

# Needs ImageMagick and librsvg2-bin
class Colorizer
  def initialize(line_writer, color_pairs, svgs)
    @line_writer = line_writer
    @color_pairs = color_pairs
    @svgs = svgs
  end

  def colorize!
    @color_pairs.each do |name, hex|
      destination = "#{OUT_FOLDER}/#{name}"
      FileUtils.mkdir_p destination

      @svgs.each do |svg|
        new_file = File.basename(svg, ".svg")
        @line_writer.write("Colorizing #{destination}/#{new_file}") do

          # Convert svg to downsized PNG.
          `rsvg-convert -w 2000 \"#{svg}\" > \"#{destination}/#{new_file}.png\"`

          # Fill transparent background with specified color.
          `convert "#{destination}/#{new_file}.png"\
         -fuzz 25%\
         -fill none\
         -background "#{hex}"\
         -flatten\
         "#{destination}/#{new_file} - #{name}.jpg"`

          # Remove PNG
          `rm "#{destination}/#{new_file}.png"`
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

# Finally use all SVGs and colorize them according to the color pairs
colorizer = Colorizer.new(line_writer, color_pairs, Dir[ "#{download_folder}/*.svg" ])
colorizer.colorize!

