require 'sinatra/base'
require 'erb'
require 'thin'
require 'webhooker/version'
require 'webhooker/command_runner'
require 'webhooker/logging'
require 'webhooker/configuration'

module Webhooker
  class App < Sinatra::Base
    configuration_file = ENV["CONFIG_FILE"] || 'etc/example.yml'
    Configuration.load!(configuration_file)
    include Logging

    # Sinatra configuration
    set :show_exceptions, false
    set server: 'thin', connections: [], history_file: 'history.yml'

    # helpers
    helpers do
      def protected!
        return if authorized?
        headers['WWW-Authenticate'] = 'Basic realm="Webhooker authentication"'
        halt 401, "Not authorized\n"
      end

      def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        user = Configuration.settings[:global][:username]
        password = Configuration.settings[:global][:password]
        @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == [user,password]
      end
    end

    # error handling
    not_found do
      'Route not found. Do you know what you want to do?'
    end

    error do |err|
      "I'm so sorry, there was an application error: #{err}"
    end

    ### Sinatra routes
    # we don't have anything to show
    get '/' do
      protected!
      logger.info "incoming request from #{request.ip} for GET /"
      "I'm running. Nice, isn't it?"
    end

    post '/payload/:payloadtype' do
      protected!
      logger.info "incoming request from #{request.ip} for payload type #{params[:payloadtype]}"

      begin
        logger.debug "try to load webhooker/payloadtype/#{params[:payloadtype]}.rb"
        load "webhooker/payloadtype/#{params[:payloadtype]}.rb"
      rescue LoadError
        logger.error "file not found: webhooker/payloadtype/#{params[:payloadtype]}.rb"
        halt 400, "Payload type unknown\n"
      end

      parser = ParsePayload.new(request.body.read)
      parsed_data = parser.parse

      # see if the payloadtype is known
      if Configuration.settings.has_key?(parsed_data[:type].to_sym)
        case parsed_data[:type]
          when 'vcs'
            # reload configuration
            Configuration.load!(configuration_file)
            command = nil
            # is the repo name configured?
            if Configuration.settings[:vcs].has_key?(parsed_data[:repo_name].to_sym)
              repo_config = Configuration.settings[:vcs][parsed_data[:repo_name].to_sym]
              # is the branch configured?
              if repo_config.has_key?(parsed_data[:branch_name].to_sym)
                logger.debug "branch is explicitely configured"
                branch_config = repo_config[parsed_data[:branch_name].to_sym]
                begin
                  command = branch_config[:command]
                rescue
                  logger.error "no command configured"
                  halt 500, "no command configured\n"
                end
              # is there a catch all rule?
              elsif repo_config.has_key?(:_all)
                logger.debug "branch is not not explicitely configured, but there is a '_all' rule"
                branch_config = repo_config[:_all]
                command = branch_config[:command]
              # don't know what to do
              else
                error_msg = "no configuration for branch '#{parsed_data[:branch_name]}' found"
                logger.error error_msg
                halt 500, "#{error_msg}\n"
              end
              if command
                # vars for ERB binding
                branch_name = parsed_data[:branch_name]
                parsed_command = ERB.new(command).result(binding)
                command_runner = Commandrunner.new(parsed_command)
                command_runner.run
              end
            # is there a catch all rule?
            elsif Configuration.settings[:vcs].has_key?(:_all)
              logger.info "repository not explicitely configured, but there is a '_all' rule"
            else
              error_msg = "the repository '#{parsed_data[:repo_name]}' is not configured"
              logger.error error_msg
              halt 500, "#{error_msg}\n"
            end
          else
            error_msg = "webhook payload type #{parsed_data[:type]} unknown"
            logger.fatal error_msg
            halt 500, "#{error_msg}\n"
        end
      else
        error_msg = "webhook payload of type #{parsed_data[:type]} not configured"
        logger.info error_msg
        halt 500, "#{error_msg}\n"
      end

      # output to the requester
      logger.debug "using configuration file #{configuration_file}"
      "it's coming from #{parsed_data[:source]}"
    end
  end
end
