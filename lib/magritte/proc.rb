module Magritte
  class Proc
    class Interrupt < RuntimeError
      attr_reader :status

      def initialize(status)
        @status = status
      end
    end

    def self.current
      Thread.current[:magritte_proc] or raise 'no proc'
    end

    def self.current?
      !!Thread.current[:magritte_proc]
    end

    def self.with_channels(in_ch, out_ch, &b)
      current.send(:with_channels, in_ch, out_ch, &b)
    end

    def self.with_env(env, &b)
      current.send(:with_env, env, &b)
    end

    def self.spawn(code, env)
      start_mutex = Mutex.new
      start_mutex.lock

      t = Thread.new do
        begin
          # wait for Proc#start
          start_mutex.lock
          Thread.current[:status] = Status[:incomplete]

          Thread.current[:status] = code.run
          Proc.current.checkpoint
        rescue Interrupt => e
          Proc.current.compensate
          Thread.current[:status] = e.status
        rescue Exception => e
          PRINTER.p :exception
          PRINTER.p e
          PRINTER.puts e.backtrace
          Proc.current.compensate
          Thread.current[:status] = Status[:crash, :bug, msg: e.to_s]
          raise
        ensure
          @alive = false
          Proc.current.cleanup!
          PRINTER.puts('exiting')
        end
      end

      p = Proc.new(t, code, env)

      # will be unlocked in Proc#start
      t[:magritte_start_mutex] = start_mutex

      # provides Proc.current
      t[:magritte_proc] = p

      p
    end

    def inspect
      "#<Proc #{@code.loc}>"
    end

    def wait
      PRINTER.p waiting: self
      start
      @thread.join
      @thread[:status]
    end

    def join
      alive? && @thread.join
    end

    attr_reader :thread, :env
    def initialize(thread, code, env)
      @alive = false
      @thread = thread
      @code = code
      @env = env
      @compensation_stack = [[]]

      @interrupt_mutex = LogMutex.new :interrupt
    end

    def start
      @alive = true
      open_channels
      @thread[:magritte_start_mutex].unlock
      self
    end

    def alive?
      @alive && @thread.alive?
    end

    def interrupt!(status)
      @interrupt_mutex.synchronize do
        return unless alive?

        # will run cleanup in the thread via the ensure block
        @thread.raise(Interrupt.new(status))
      end
    end

    def crash!(msg=nil)
      interrupt!(Status[:crash, msg: msg])
    end

    def sleep
      @thread.stop
    end

    def wakeup
      @thread.run
    end

    def cleanup!
      PRINTER.p :cleanup => self
      @env.each_input { |c| c.remove_reader(self) }
      @env.each_output { |c| c.remove_writer(self) }
    end

    def open_channels
      @env.each_input { |c| c.add_reader(self) }
      @env.each_output { |c| c.add_writer(self) }
    end

    def stdout
      @env.stdout || Channel::Null.new
    end

    def stdin
      @env.stdin || Channel::Null.new
    end

    def add_compensation(comp)
      @compensation_stack[-1] << comp
    end

    def compensate
      comps = @compensation_stack.pop
      comps.each(&:run)
    end

    def checkpoint
      comps = @compensation_stack.pop
      comps.each(&:run_checkpoint)
    end

  protected
    def with_channels(new_in, new_out, &b)
      with_env(@env.extend(new_in, new_out), &b)
    end

    def with_env(new_env, &b)
      PRINTER.p :with_env => new_env.repr
      old_env = nil

      @interrupt_mutex.synchronize do
        old_env = @env
        @env = new_env
      end

      open_channels

      @compensation_stack << []
      yield
    rescue Interrupt => e
      PRINTER.puts('virtual proc interrupted')
      compensate

      if e.status.property?(:crash)
        interrupt!(e.status)
      end

      e.status
    else
      checkpoint
    ensure
      @interrupt_mutex.synchronize do
        @env = old_env
      end

      new_env.own_inputs.each { |c| c.remove_reader(self) }
      new_env.own_outputs.each { |c| c.remove_writer(self) }
    end
  end
end
