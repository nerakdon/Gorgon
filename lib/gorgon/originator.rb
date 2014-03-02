require 'gorgon/originator_protocol'
require 'gorgon/configuration'
require 'gorgon/job_state'
require 'gorgon/progress_bar_view'
require 'gorgon/originator_logger'
require 'gorgon/failures_printer'
require 'gorgon/rsync_daemon'
require 'gorgon/shutdown_manager.rb'

require 'awesome_print'
require 'etc'
require 'socket'

class Originator
  include Configuration

  def initialize
    @configuration = nil
    @rsync_daemon = RsyncDaemon.new
  end

  def originate
    begin
      Signal.trap("INT") { ctrl_c }
      Signal.trap("TERM") { ctrl_c }

      publish
      @logger.log "Originator finished successfully"
    rescue StandardError
      puts "Unhandled exception in originator:"
      puts $!.message
      puts $!.backtrace.join("\n")
      puts "----------------------------------"
      puts "Now attempting to cancel the job."
      @logger.log_error "Unhandled Exception!" if @logger
      cancel_job
    end
  end

  def cancel_job
    ShutdownManager.new(protocol: @protocol,
                        job_state: @job_state,
                        rsync_daemon: @rsync_daemon).cancel_job
  end

  def ctrl_c
    puts "\nCtrl-C received! Just wait a moment while I clean up..."
    cancel_job
  end

  def publish
    @logger = OriginatorLogger.new configuration[:originator_log_file]

    if files.empty?
      $stderr.puts "There are no files to test! Quitting."
      exit 2
    end

    if !@rsync_daemon.start
      @logger.log_error "rsync daemon didn't start!"
      exit 1
    end

    @protocol = OriginatorProtocol.new @logger

    EventMachine.run do
      @logger.log "Connecting..."
      @protocol.connect connection_information, :on_closed => method(:on_disconnect)

      @logger.log "Publishing files..."
      @protocol.publish_files files
      create_job_state_and_observers

      @logger.log "Publishing Job..."
      @protocol.publish_job job_definition
      @logger.log "Job Published"

      @protocol.receive_payloads do |payload|
        handle_reply(payload)
      end
    end
  end

  def cleanup_if_job_complete
    if @job_state.is_job_complete?
      @logger.log "Job is done"
      @protocol.disconnect
      @rsync_daemon.stop
    end
  end

  def handle_reply(payload)
    payload = Yajl::Parser.new(:symbolize_keys => true).parse(payload)

    # at some point this will probably need to be fancy polymorphic type based responses, or at least a nice switch statement
    if payload[:action] == "finish"
      @job_state.file_finished payload
    elsif payload[:action] == "start"
      @job_state.file_started payload
    elsif payload[:type] == "crash"
      @job_state.gorgon_crash_message payload
    elsif payload[:type] == "exception"
      # TODO
      ap payload
    else
      ap payload
    end

    @logger.log_message payload
    # Uncomment this to see each message received by originator
    # ap payload

    cleanup_if_job_complete
  end

  def create_job_state_and_observers
    @job_state = JobState.new files.count
    @progress_bar_view = ProgressBarView.new @job_state
    @progress_bar_view.show
    failures_printer = FailuresPrinter.new @job_state
  end

  def on_disconnect
    EventMachine.stop
  end

  def connection_information
    configuration[:connection]
  end

  def files
    @files ||= configuration[:files].reduce([]) do |memo, obj|
      memo.concat(Dir[obj])
    end.uniq
  end

  def job_definition
    job_config = configuration[:job]
    if !job_config.has_key?(:source_tree_path)
      job_config[:source_tree_path] = "rsync://#{local_ip_addr}:43434/src"
    end
    JobDefinition.new(configuration[:job])
  end

  private

  def local_ip_addr
    orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  # turn off reverse DNS resolution temporarily

    UDPSocket.open do |s|
      s.connect '64.59.144.16', 1
      s.addr.last
    end
  ensure
    Socket.do_not_reverse_lookup = orig
  end

  def configuration
    @configuration ||= load_configuration_from_file("gorgon.json")
  end
end
