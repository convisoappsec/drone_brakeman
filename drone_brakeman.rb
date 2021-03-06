#!/usr/bin/ruby
require 'rubygems'
require 'yaml'
require 'fileutils'
require 'zip/zip'

PATH = File.dirname(__FILE__)
LIB_PATH = File.join(File.dirname(__FILE__), 'lib')
DEBUG = false
CONFIG_FILE = File.join(PATH, 'config.yml')

require File.join(LIB_PATH, 'parse/json/brakeman')
require File.join(LIB_PATH, 'parse/writer/conviso')
require File.join(LIB_PATH, 'communication/xmpp')
require File.join(LIB_PATH, 'output/debug')



# PARSING CONFIGURATION FILE
if !File.exists?(CONFIG_FILE)
  puts('Configuration file is missing.')
  exit
end

configuration = YAML.load_file(CONFIG_FILE)

# SETUPING LOG FILE
debug = Output::Debug.new(configuration)
Output::Debug::level = configuration['debug_level'].to_i || 0

# LOADING ANALYSIS MODULES
analysis_modules = []
Dir.glob(File.join(LIB_PATH, 'analysis/*_analysis.rb')).each do |a| 
  debug.info("Loading analysis module:  [#{a}]")
  begin 
    require a
    a =~ /analysis\/(\w+)_analysis.rb/
    am = eval("Analysis::#{$1.capitalize}.new()")
    am.config = configuration['analysis'][$1.downcase]
    am.debug = debug
    analysis_modules << am
  rescue Exception => e
    debug.error("Error loading analysis module:  [#{a}]")
  end
end

module Drone
  class Brakeman
    def initialize(config = '', debug = nil, analyses = [])
      @config, @debug, @analyses = config, debug, analyses
      
      # INITIALIZING A NEW XMPP COMMUNICATION CHANNEL 
      @comm = Communication::XMPP.new(@config, @debug)
      
      # PERFORMING MINNOR CHECKS BEFORE STARTS OPPERATING
      __validate_configuration
    end


    def run
      # VERIFY IF THE CONNECTION IS STILL ACTIVE
      if @comm.active?
        
        # SCAN ALL SOURCES SPECIFIED IN THE CONFIGURATION FILE
        @config['sources'].each do |s|

          # SETUP A COLLECTION OF ALL JSONs FOUND INSIDE THE CURRENT SOURCE INPUT DIRECTORY
	        json_files = __scan_input_directory(s)

          # FOR EACH JSON
	        json_files.each do |json_file|
            begin
              # PARSING THE CURRENT JSON USING THE SPECIFIC PARSER FOR THE TOOL OUTPUT FORMAT
	            structure = __parse_file(json_file)
            rescue Exception => e
              @debug.error("Error parsing JSON file: [#{json_file}]")
              next
            end

	          # Try to send all vulnerabilities then, if had success, compress and 
	          # archive the JSON file otherwise does not touch the original file
	          if __sent_structure(structure, s)
              compressed_file = __compress_file(json_file)
              __archive_file(compressed_file) unless @config['archive_directory'].to_s.empty?
	          end
	        end
        end
      end
    end
    
    private
    def __sent_structure(brakeman_structure, source)
      # EXECUTES ALL BULK ANALYSES
      @analyses.select {|a| a.class.superclass == Analysis::Interface::Bulk}.each {|a| brakeman_structure[:issues] = a._analyse(brakeman_structure[:issues])}
      
      # SEND EACH ISSUE INDIVIDUALLY TO THE SERVER
      # THE "source" STRUCTURE CONTAINS A TUPLE WITH (CLIENT_ID, PROJECT_ID)
      response = brakeman_structure[:issues].collect do |issue|
        # EXECUTES ALL INDIVIDUAL ANALYSES
        @analyses.select {|a| a.class.superclass == Analysis::Interface::Individual}.each {|a| issue = a._analyse(issue)}
        
        # SEND THE MSG WITH THE ISSUE
        source['tool_name'] = @config['tool_name']
        ret = @comm.send_msg(Parse::Writer::Conviso.build_xml(issue, source))
        
        if @config['xmpp']['importer_address'] =~ /validator/
          msg = @comm.receive_msg
          ret = false
          if msg =~ /\[OK\]/
            @debug.info('VALIDATOR - THIS MESSAGE IS VALID')
          else
            @debug.info('VALIDATOR - THIS MESSAGE IS INVALID')
          end
        end
        
        ret
      end
      
      # JUST IN CASE THE RESPONSE ARRAY COMES EMPTY
      response = response + [true]
      
      # IF ALL ISSUES WERE SUCCESSFULLY SENT TO THE SERVER RETURN TRUE
      response.inject{|a,b| a & b}
    end
    
    #TODO: Criar classes de excecões para todos esses erros
    def __validate_configuration
      
      # VALIDATES IF INPUT DIRECTORIES FOR ALL SOURCES
      @config['sources'].each do |s|
        if !Dir.exists?(s['input_directory'].to_s)
	        @debug.error("Input directory #{s['input_directory']}does not exist.")
	        exit
        end
      end
      
      # VALIDATES THE ARCHIVE DIRECTORY
      if !@config['archive_directory'].nil? && !Dir.exists?(@config['archive_directory'].to_s)
	      @debug.error('Archive directory does not exist.')
	      exit
      end
    end
    
    def __scan_input_directory(source)
      @debug.info("Pooling input directory ...")
      files = Dir.glob(File.join(source['input_directory'], '*.json'))
      @debug.info("##{files.size} files were found.")
      return files
    end

    def __parse_file (json_file = '')
      @debug.info("Parsing json file [#{json_file}].")
      parse = Parse::Json::Brakeman.new()
      parse.parse_file(json_file)
    end
    
    def __archive_file (zip_file = '')
      @debug.info("Archiving json file [#{zip_file}].")
      FileUtils.mv(zip_file, @config['archive_directory'])
    end
    
    def __compress_file (json_file = '')
      @debug.info("Compressing json file [#{json_file}].")
      zip_file_name = json_file + ".zip"
      File.unlink(zip_file_name) if File.exists?(zip_file_name)
      zip = Zip::ZipFile.new(zip_file_name, true)
      zip.add(File.basename(json_file), json_file)
      zip.close
      File.unlink(json_file)
      return zip_file_name
    end
    
  end
end

# Creating an instance of Drone::Brakeman Object
drone = Drone::Brakeman.new(configuration, debug, analysis_modules)
debug.info("Starting #{configuration['plugin_name']} Drone ...")
drone.run
