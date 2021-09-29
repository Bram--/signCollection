#!/usr/bin/env ruby

require 'bundler/setup'
require 'dry/cli'
require 'down/http'
require 'fileutils'
require 'pathname'
require 'zip'

DOWNLOAD_LINK_FORMAT = "https://openclipart.org/download/%d"

FOLDER_DOWNLOADS = "tmp/svgs"
FOLDER_PNGS = "tmp/pngs"
FOLDER_OUTPUT = "output"

FULL_SIGN_SIZE_PX = 400
HALF_SIGN_SIZE_PX = 200
THUMBNAIL_SIZE_PX = 100

class LineWriter
  def initialize
    @last_line_length = 0
  end

  def write(line, &block)
    line_length_delta = @last_line_length - line.length

    print line
    line_length_delta.times { |i| print " " }
    print "\r"

    block.call

    @last_line_length = line.length
  end

  def flush
    @last_line_length.times { |i| print " " }
    print "\r"
    $stdout.flush
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
      width  = if ratio.between?(epsilon, 0.9)
                 HALF_SIGN_SIZE_PX
               else
                 FULL_SIGN_SIZE_PX
               end
      height = if ratio > 1.2
                 HALF_SIGN_SIZE_PX
               else
                 FULL_SIGN_SIZE_PX
               end

      # Crop to 1:1, 2:1 or 1:2
      @line_writer.write("Converting #{new_file} ") do
        `rsvg-convert -w #{width} -h #{height} -a \"#{svg}\" > \"#{png}\"`
      end

      @color_pairs.each do |name, hex|
        @line_writer.write("Colorizing #{new_file} #{name}") do
          color_destination = "#{FOLDER_OUTPUT}/#{name}"
          FileUtils.mkdir_p color_destination
          `convert "#{png}"\
            -fuzz 50% -background "#{hex}"\
            -gravity center -extent #{width}x#{height}\
            -quality 75 "#{color_destination}/#{new_file} #{name}.jpg"`
        end
      end
    end
  end
end

class Montager
  def	initialize(line_writer, input_file)
    @line_writer = line_writer
    @color_pairs = FileParser.new(input_file).parse_colors_and_names
  end

  def montage!
    color_folders = Pathname.new(FOLDER_OUTPUT).children.select(&:directory?)
    raise "No output folder detected (have you ran `colorize`?)" unless File.exists?(FOLDER_OUTPUT)
    raise "No color folders detected (have you ran `colorize` )" if color_folders.empty?

    color_folders.each do |folder|
      color_name = folder.to_s[/\A.+\/(.+\Z)/, 1]
      color = @color_pairs.find { |color| color[0].casecmp?(color_name) }

      @line_writer.write("Creating overview for #{color[0]}") do
        `montage #{folder}/*.jpg \
          -geometry #{THUMBNAIL_SIZE_PX}x#{THUMBNAIL_SIZE_PX}+2+2  \
           -pointsize #{THUMBNAIL_SIZE_PX / 3} -title '#{color_name}'\
         -background "#{color[1]}" -mattecolor "#{color[1]}"         \
          #{FOLDER_OUTPUT}/#{color_name}.jpg`
      end
    end
  end
end

class Publisher
  def	initialize(line_writer, input_file, remove_temp)
    @line_writer = line_writer
    parser = FileParser.new(input_file)
    @color_pairs = parser.parse_colors_and_names
    @download_pairs = FileParser.new(input_file).parse_download_link_and_names
    @remove_temp = remove_temp
  end

  def publish!
    color_folders = Pathname.new(FOLDER_OUTPUT).children.select(&:directory?)
    raise "No output folder detected (have you ran `colorize`?)" unless File.exists?(FOLDER_OUTPUT)
    raise "No color folders detected (have you ran `colorize` )" if color_folders.empty?

    color_folders.each do |folder|
      color_name = folder.to_s[/\A.+\/(.+\Z)/, 1]
      color = @color_pairs.find { |color| color[0].casecmp?(color_name) }

      @line_writer.write("Zipping #{color_name}") do
        create_readme(color_name)
        create_zip(color_name, folder)
      end
    end

    if (@remove_temp)
      Dir["#{FOLDER_OUTPUT}/*"].select do |file|
        unless file.match(/.+\.zip\Z/i)
          @line_writer.write("Removing #{file}") do
            FileUtils.rm_rf(file)
          end
        end
      end
    end
  end

  private
  def create_readme(color_name)
    readme = %{#{color_name.upcase} SIGN PACK.
Files generated with: https://github.com/Bram--/signCollection.
All files are downloaded from OpenClipart (see list below).

Files:

}
    readme += @download_pairs.map { |name, link| "#{name}\t\t#{link}" }.join("\n")
    File.new( "#{FOLDER_OUTPUT}/#{color_name}.README", "w").write(readme)
  end

  def create_zip(color_name, folder)
    zip_file = "#{FOLDER_OUTPUT}/#{color_name}.zip"
    FileUtils.rm zip_file if File.exists?(zip_file)
    Zip::File.open(zip_file, create: true) do |zip|
      zip.add("README", "#{FOLDER_OUTPUT}/#{color_name}.README")

      if File.exists?("#{FOLDER_OUTPUT}/#{color_name}.jpg")
        zip.add("overview.jpg", "#{FOLDER_OUTPUT}/#{color_name}.jpg")
      end

      zip.mkdir("signs")
      Dir[ "#{folder}/*.*" ].each do |sign|
        basename = File.basename(sign)
        zip.add("signs/#{basename}", "#{sign}")
      end
    end
  end


end

class ParkitectSigner
  def initialize(line_writer)
    @line_writer = line_writer
  end

  ## Parse signs file and create Color and Download pairs
  def parse!(file)
    parser = FileParser.new(file)
    parser.parse_download_link_and_names

    @color_pairs = parser.parse_colors_and_names
    @download_pairs = parser.parse_download_link_and_names
  end

  # Download all
  def download!
    raise "#parse needs to be called first" unless defined?(@color_pairs)

    downloader = ImageDownloader.new(@line_writer, @download_pairs)
    @download_folder = downloader.download!
  end

  def colorize!
    raise "#download needs to be called first" unless defined?(@download_folder)

    converter = ImageConverter.new(@line_writer, Dir[ "#{@download_folder}/*.svg" ], @color_pairs)
    converter.pad_and_colorize!
  end

  def publish!(montage, file, remove_temp)
    if (montage)
      montager = Montager.new(@line_writer, file)
      montager.montage!
    end

    publisher = Publisher.new(@line_writer, file, remove_temp)
    publisher.publish!
  end

  def run_all(montage, file, remove_temp)
    parse!(file)
    download!
    colorize!
    publish!(montage, file, remove_temp)
  end
end

module Parkitect
  module CLI
    module Commands
      extend Dry::CLI::Registry

      class Download < Dry::CLI::Command
        desc "Redownloads all files"

        option :input, type: :string, default: "signs.txt", desc: "Input file containing colors and OpenClipart links"
        example [
          "path/to/file.txt # Reads path/to/file.txt"
        ]

        def call(**options)
          line_writer = LineWriter.new
          signer = ParkitectSigner.new(line_writer)
          signer.parse!(options.fetch(:input))

          line_writer.write("Removing downloads, continue? [y/N]") do
            if $stdin.gets.chomp =~ /y(|es)/i
              FileUtils.remove_dir(FOLDER_DOWNLOADS)
            end
          end
          signer.download!
          line_writer.flush
          puts "All done!"
        end
      end

      class Colorize < Dry::CLI::Command
        desc "Downloads all files if not already present and colorizes them"

        option :input, type: :string, default: "signs.txt", desc: "Input file containing colors and OpenClipart links"
        example [
          "--input=signs.txt"
        ]

        def call(**options)
          line_writer = LineWriter.new
          signer = ParkitectSigner.new(line_writer)
          signer.parse!(options.fetch(:input))
          signer.download!
          signer.colorize!

          line_writer.flush
          puts "All done!"
        end
      end

      class Publish < Dry::CLI::Command
        desc "Creates a montage for all images and zips them"

        option :montage, type: :boolean, default: true,
          desc: "Wether to create a montage for each color or not"
        option :input, type: :string, default: "signs.txt", desc: "Input file containing colors and OpenClipart links"
        option :remove_temp, type: :boolean, default: false, desc: "Remove temp files after zipping them"
        example [
          "--montage --input=signs.txt --no-remove-temp"
        ]

        def call(**options)
          line_writer = LineWriter.new
          signer = ParkitectSigner.new(line_writer)
          signer.publish!(
            options.fetch(:montage),
            options.fetch(:input),
            options.fetch(:remove_temp))

          line_writer.flush
          puts "All done!"
        end
      end

      class All < Dry::CLI::Command
        desc "Runs Colorize and Publish"

        option :montage, type: :boolean, default: true,
          desc: "Wether to create a montage for each color or not"
        option :input, type: :string, default: "signs.txt", desc: "Input file containing colors and OpenClipart links"
        option :remove_temp, type: :boolean, default: true, desc: "Remove temp files after zipping them"
        example [
          "--montage --input=signs.txt --no-remove-temp"
        ]

        def call(**options)
          line_writer = LineWriter.new
          signer = ParkitectSigner.new(line_writer)
          signer.run_all(
            options.fetch(:montage),
            options.fetch(:input),
            options.fetch(:remove_temp))

          line_writer.flush
          puts "All done!"
        end
      end

      register "download", Download, aliases: ["d", "-d"]
      register "colorize", Colorize, aliases: ["c", "-c"]
      register "publish", Publish, aliases: ["p", "-p"]
      register "all", All, aliases: ["a", "cp", "pc"]
    end
  end
end

Dry::CLI.new(Parkitect::CLI::Commands).call
