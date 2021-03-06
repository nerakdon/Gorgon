require "gorgon/job_definition"
require "gorgon/configuration"
require 'gorgon/source_tree_syncer'
require "gorgon/g_logger"
require "gorgon/callback_handler"
require "gorgon/version"
require "gorgon/worker_manager"
require "gorgon/crash_reporter"
require "gorgon/gem_command_handler"
require 'gorgon/originator_protocol'

require "yajl"
require "gorgon_bunny/lib/gorgon_bunny"
require "awesome_print"
require "open4"
require "tmpdir"
require "socket"

module Gorgon
  class Listener
    include Configuration
    include GLogger
    include CrashReporter

    def initialize
      @listener_config_filename = Dir.pwd + "/gorgon_listener.json"
      initialize_logger configuration[:log_file]

      log "Listener #{Gorgon::VERSION} initializing"
      connect
      initialize_personal_job_queue
      announce_readiness_to_originators
    end

    def listen
      at_exit_hook
      log "Waiting for jobs..."
      while true
        sleep 2 unless poll
      end
    end

    def connect
      @bunny = GorgonBunny.new(connection_information)
      @bunny.start
    end

    def initialize_personal_job_queue
      @job_queue = @bunny.queue("job_queue_" + UUIDTools::UUID.timestamp_create.to_s, :auto_delete => true)
      exchange = @bunny.exchange(job_exchange_name, :type => :fanout)
      @job_queue.bind(exchange)
    end

    def announce_readiness_to_originators
      exchange = @bunny.exchange(originator_exchange_name, :type => :fanout)
      data = {:listener_queue_name => @job_queue.name}
      exchange.publish(Yajl::Encoder.encode(data))
    end

    def poll
      message = @job_queue.pop
      return false if message == [nil, nil, nil]
      log "Received: #{message}"

      payload = message[2]

      handle_request payload

      log "Waiting for more jobs..."
      return true
    end

    def handle_request json_payload
      payload = Yajl::Parser.new(:symbolize_keys => true).parse(json_payload)

      case payload[:type]
      when "job_definition"
        run_job(payload)
      when "ping"
        respond_to_ping payload[:reply_exchange_name]
      when "gem_command"
        GemCommandHandler.new(@bunny).handle payload, configuration
      end
    end

    def run_job(payload)
      @job_definition = JobDefinition.new(payload)
      @reply_exchange = @bunny.exchange(@job_definition.reply_exchange_name, :auto_delete => true)

      syncer = SourceTreeSyncer.new(@job_definition.sync)
      syncer.pull do |execution_context|
        if execution_context.success
          log "Command '#{execution_context.command}' completed successfully."
          fork_worker_manager if run_after_sync?
        else

          log_and_send_crash_message(execution_context.command, execution_context.output, execution_context.errors)
        end
      end
    end

    def at_exit_hook
      at_exit { log "Listener will exit!"}
    end

    private

    def run_after_sync?
      log "Running after_sync callback..."
      begin
        callback_handler.after_sync
      rescue Exception => e
        log_error "Exception raised when running after_sync callback_handler. Please, check your script in #{@job_definition.callbacks[:after_sync]}:"
        log_error e.message
        log_error "\n" + e.backtrace.join("\n")

        reply = {:type => :exception,
                 :hostname => Socket.gethostname,
                 :message => "after_sync callback failed. Please, check your script in #{@job_definition.callbacks[:after_sync]}. Message: #{e.message}",
                 :backtrace => e.backtrace.join("\n")
        }
        @reply_exchange.publish(Yajl::Encoder.encode(reply))
        return false
      end
      true
    end

    def callback_handler
      @callback_handler ||= Gorgon::CallbackHandler.new(@job_definition.callbacks)
    end

    def log_and_send_crash_message(command, output, errors)
      send_crash_message @reply_exchange, output, errors
      log_error "Command '#{command}' failed!"
      log_error "Stdout:\n#{output}"
      log_error "Stderr:\n#{errors}"
    end

    ERROR_FOOTER_TEXT = "\n***** See #{WorkerManager::STDERR_FILE} and #{WorkerManager::STDOUT_FILE} at '#{Socket.gethostname}' for complete output *****\n"
    def fork_worker_manager
      log "Forking Worker Manager..."
      ENV["GORGON_CONFIG_PATH"] = @listener_config_filename

      pid, stdin = Open4::popen4 "gorgon manage_workers"
      stdin.write(@job_definition.to_json)
      stdin.close

      _, status = Process.waitpid2 pid
      log "Worker Manager #{pid} finished"

      if status.exitstatus != 0
        exitstatus = status.exitstatus
        log_error "Worker Manager #{pid} crashed with exit status #{exitstatus}!"

        msg = report_crash @reply_exchange, :out_file => WorkerManager::STDOUT_FILE,
          :err_file => WorkerManager::STDERR_FILE, :footer_text => ERROR_FOOTER_TEXT

        log_error "Process output:\n#{msg}"
      end
    end

    def respond_to_ping reply_exchange_name
      reply = {:type => "ping_response", :hostname => Socket.gethostname,
               :version => Gorgon::VERSION, :worker_slots => configuration[:worker_slots]}
      publish_to reply_exchange_name, reply
    end

    def publish_to reply_exchange_name, message
      reply_exchange = @bunny.exchange(reply_exchange_name, :auto_delete => true)

      log "Sending #{message}"
      reply_exchange.publish(Yajl::Encoder.encode(message))
    end

    def job_exchange_name
      OriginatorProtocol.job_exchange_name(configuration.fetch(:cluster_id, nil))
    end

    def originator_exchange_name
      OriginatorProtocol.originator_exchange_name(configuration.fetch(:cluster_id, nil))
    end

    def connection_information
      configuration[:connection]
    end

    def configuration
      @configuration ||= load_configuration_from_file("gorgon_listener.json")
    end
  end
end
