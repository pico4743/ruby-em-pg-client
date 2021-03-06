require 'pg/em'

module PG
  module EM

    # Connection pool for PG::EM::Client
    #
    # Author:: Rafal Michalski
    #
    # The ConnectionPool allocates new connections asynchronously when
    # there are no free connections left up to the {#max_size} number.
    #
    # If {Client#async_autoreconnect} option is not set or the re-connect fails
    # the failed connection is dropped from the pool.
    #
    # @example Basic usage
    #   pg = PG::EM::ConnectionPool.new size: 10, dbname: 'foo'
    #   res = pg.query 'select * from bar'
    #
    # The list of {Client} command methods that are available in {ConnectionPool}:
    #
    # Fiber synchronized methods:
    #
    # * {Client#exec}
    # * {Client#query}
    # * {Client#async_exec}
    # * {Client#async_query}
    # * {Client#exec_params}
    # * {Client#exec_prepared}
    # * {Client#prepare}
    # * {Client#describe_prepared}
    # * {Client#describe_portal}
    #
    # The asynchronous command methods:
    #
    # * {Client#exec_defer}
    # * {Client#query_defer}
    # * {Client#async_exec_defer}
    # * {Client#async_query_defer}
    # * {Client#exec_params_defer}
    # * {Client#exec_prepared_defer}
    # * {Client#prepare_defer}
    # * {Client#describe_prepared_defer}
    # * {Client#describe_portal_defer}
    #
    # The pool will only allow for {#max_size} commands (both deferred and
    # fiber synchronized) to be performed concurrently. The pending requests
    # will be queued and executed when connections become available.
    #
    # Please keep in mind, that the above methods may send commands to
    # different clients from the pool each time they are called. You can't
    # assume anything about which connection is acquired even if the
    # {#max_size} of the pool is set to one. This is because no connection
    # will be shared between two concurrent requests and the connections
    # maight occasionally fail and they will be dropped from the pool.
    #
    # This prevents the `*_defer` commands to execute transactions.
    #
    # For transactions use {#transaction} and fiber synchronized methods.
    class ConnectionPool

      DEFAULT_SIZE = 4

      # Maximum number of connections in the connection pool
      # @return [Integer]
      attr_reader :max_size

      attr_reader :available, :allocated

      # Creates and initializes a new connection pool.
      #
      # The connection pool allocates its first connection upon initialization
      # unless +lazy: true+ option is given.
      #
      # Pass PG::EM::Client +options+ together with ConnectionPool +options+:
      #
      # - +:size+ = +4+ - the maximum number of concurrent connections
      # - +:lazy+ = false - should lazy allocate first connection
      # - +:connection_class+ = {PG::EM::Client}
      #
      # For convenience the given block will be set as the +on_connect+ option.
      #
      # @yieldparam pg [Client] connected client instance on each newly
      #                         created connection
      # @yieldparam is_async [Boolean] always +true+ in a connection pool
      #                      context
      # @yieldparam is_reset [Boolean] always +false+ unless
      #                      +async_autoreconnect+ options is +true+ and
      #                      was actually re-connecting
      #
      # @raise [PG::Error]
      # @raise [ArgumentError]
      # @see Client#on_connect
      def initialize(options = {}, &on_connect)
        @available = []
        @pending = []
        @allocated = {}
        @max_size = DEFAULT_SIZE
        @connection_class = Client

        if block_given?
          options = {on_connect: on_connect}.merge(options)
        end

        lazy = false
        @options = options.reject do |key, value|
          case key.to_sym
          when :size, :max_size
            @max_size = value.to_i
            true
          when :connection_class
            @connection_class = value
            true
          when :lazy
            lazy = value
            true
          end
        end

        raise ArgumentError, "#{self.class}.new: pool size must be >= 1" if @max_size < 1

        # allocate first connection, unless we are lazy
        hold unless lazy
      end

      # Creates and initializes new connection pool.
      #
      # Attempts to establish the first connection asynchronously.
      #
      # @return [FeaturedDeferrable]
      # @yieldparam pg [Client|PG::Error] new and connected client instance
      #             on success or a raised PG::Error
      #
      # Use the returned deferrable's +callback+ hook to obtain newly created
      # {ConnectionPool}.
      # In case of a connection error +errback+ hook is called with
      # a raised error object as its argument.
      #
      # If the block is provided it's bound to both +callback+ and +errback+
      # hooks of the returned deferrable.
      #
      # Pass PG::EM::Client +options+ together with ConnectionPool +options+:
      #
      # - +:size+ = +4+ - the maximum number of concurrent connections
      # - +:connection_class+ = {PG::EM::Client}
      #
      # @raise [ArgumentError]
      def self.connect_defer(options = {}, &blk)
        pool = new options.merge(lazy: true)
        pool.__send__(:hold_deferred, blk) do
          ::EM::DefaultDeferrable.new.tap { |df| df.succeed pool }
        end
      end

      class << self
        alias_method :connect, :new
        alias_method :async_connect, :connect_defer
      end

      # Current number of connections in the connection pool
      #
      # @return [Integer]
      def size
        @available.length + @allocated.length
      end

      # Finishes all available connections and clears the available pool.
      #
      # After call to this method the pool is still usable and will try to
      # allocate new client connections on subsequent query commands.
      def finish
        @available.each { |c| c.finish }
        @available.clear
        self
      end

      alias_method :close, :finish

      class DeferredOptions < Hash
        def apply(conn)
          each_pair { |n,v| conn.__send__(n, v) }
        end
      end
      # @!attribute [rw] connect_timeout
      #   @return [Float] connection timeout in seconds
      #   Set {Client#connect_timeout} on all present and future connections
      #   in this pool or read value from options
      # @!attribute [rw] query_timeout
      #   @return [Float] query timeout in seconds
      #   Set {Client#query_timeout}  on all present and future connections
      #   in this pool or read value from options
      # @!attribute [rw] async_autoreconnect
      #   @return [Boolean] asynchronous auto re-connect status
      #   Set {Client#async_autoreconnect}  on all present and future connections
      #   in this pool or read value from options
      # @!attribute [rw] on_connect
      #   @return [Proc<Client,is_async,is_reset>] connect hook
      #   Set {Client#on_connect} on all present and future connections
      #   in this pool or read value from options
      # @!attribute [rw] on_autoreconnect
      #   @return [Proc<Client, Error>] auto re-connect hook
      #   Set {Client#on_autoreconnect} on all present and future connections
      #   in this pool or read value from options
      %w[connect_timeout
         query_timeout
         async_autoreconnect
         on_connect
         on_autoreconnect].each do |name|
        class_eval <<-EOD, __FILE__, __LINE__
          def #{name}=(value)
            @options[:#{name}] = value
            b = proc { |c| c.#{name} = value }
            @available.each(&b)
            @allocated.each_value(&b)
          end
        EOD
        if name.start_with?('on_')
          class_eval <<-EOD, __FILE__, __LINE__
            def #{name}(&hook)
              if block_given?
                self.#{name} = hook
              else
                @options[:#{name}] || @options['#{name}']
              end
            end
          EOD
        else
          class_eval <<-EOD, __FILE__, __LINE__
            def #{name}
              @options[:#{name}] || @options['#{name}']
            end
          EOD
        end
        DeferredOptions.class_eval <<-EOD, __FILE__, __LINE__
          def #{name}=(value)
            self[:#{name}=] = value
          end
        EOD
      end

      %w(
        exec
        query
        async_exec
        async_query
        exec_params
        exec_prepared
        prepare
        describe_prepared
        describe_portal
          ).each do |name|

        class_eval <<-EOD, __FILE__, __LINE__
          def #{name}(*args, &blk)
            hold { |c| c.#{name}(*args, &blk) }
          end
        EOD
      end

      %w(
        exec_defer
        query_defer
        async_query_defer
        async_exec_defer
        exec_params_defer
        exec_prepared_defer
        prepare_defer
        describe_prepared_defer
        describe_portal_defer
          ).each do |name|

        class_eval <<-EOD, __FILE__, __LINE__
          def #{name}(*args, &blk)
            hold_deferred(blk) { |c| c.#{name}(*args) }
          end
        EOD
      end

      # Executes a BEGIN at the start of the block
      # and a COMMIT at the end of the block
      # or ROLLBACK if any exception occurs.
      # Calls to transaction may be nested,
      # however without sub-transactions (save points).
      #
      # @example Transactions
      #   pg = PG::EM::ConnectionPool.new size: 10
      #   pg.transaction do
      #     pg.exec('insert into animals (family, species) values ($1,$2)',
      #             [family, species])
      #     num = pg.query('select count(*) from people where family=$1',
      #             [family]).get_value(0,0)
      #     pg.exec('update stats set count = $1 where family=$2',
      #             [num, family])
      #   end
      #
      # @see Client#transaction
      # @see #hold
      def transaction(&blk)
        hold do |pg|
          pg.transaction(&blk)
        end
      end

      # Acquires {Client} connection and passes it to the given block.
      #
      # The connection is allocated to the current fiber and ensures that
      # any subsequent query from the same fiber will be performed on
      # the connection.
      #
      # It is possible to nest hold calls from the same fiber,
      # so each time the block will be given the same {Client} instance.
      # This feature is needed e.g. for nesting transaction calls.
      # @yieldparam [Client] pg
      def hold
        fiber = Fiber.current
        id = fiber.object_id

        if conn = @allocated[id]
          skip_release = true
        else
          conn = acquire(fiber) until conn
        end

        begin
          yield conn if block_given?

        rescue PG::Error
          if conn.status != PG::CONNECTION_OK
            conn.finish unless conn.finished?
            drop_failed(id)
            skip_release = true
          end
          raise
        ensure
          release(id) unless skip_release
        end
      end

      alias_method :execute, :hold

      def method_missing(*a, &b)
        hold { |c| c.__send__(*a, &b) }
      end

      def respond_to_missing?(m, priv = false)
        hold { |c| c.respond_to?(m, priv) }
      end

      private

      # Get available connection or create a new one, or put on hold
      # @return [Client] on success
      # @return [nil] when dropped connection creates a free slot
      def acquire(fiber)
        if conn = @available.pop
          @allocated[fiber.object_id] = conn
        else
          if size < max_size
            begin
              id = fiber.object_id
              # mark allocated pool for proper #size value
              # the connection is made asynchronously
              @allocated[id] = opts = DeferredOptions.new
              conn = @connection_class.new(@options)
            ensure
              if conn
                opts.apply conn
                @allocated[id] = conn
              else
                drop_failed(id)
              end
            end
          else
            @pending << fiber
            Fiber.yield
          end
        end
      end

      # Asynchronously acquires {Client} connection and passes it to the
      # given block on success.
      #
      # The block will receive the acquired connection as its argument and
      # should return a deferrable object which is either returned from
      # this method or is being status-bound to another deferrable returned
      # from this method.
      #
      # @param blk [Proc] optional block passed to +callback+ and +errback+
      #               of the returned deferrable object
      # @yieldparam pg [Client] a connected client instance
      # @yieldreturn [EM::Deferrable]
      # @return [EM::Deferrable]
      def hold_deferred(blk = nil)
        if conn = @available.pop
          id = conn.object_id
          @allocated[id] = conn
          df = yield conn
        else
          df = FeaturedDeferrable.new
          id = df.object_id
          acquire_deferred(df) do |nc|
            @allocated[id] = conn = nc
            df.bind_status yield conn
          end
        end
        df.callback { release(id) }
        df.errback do |err|
          if conn
            if err.is_a?(PG::Error) &&
                conn.status != PG::CONNECTION_OK
              conn.finish unless conn.finished?
              drop_failed(id)
            else
              release(id)
            end
          end
        end
        df.completion(&blk) if blk
        df
      end

      # Asynchronously create a new connection or get the released one
      #
      # @param df [EM::Deferrable] - the acquiring object and the one to fail
      #                         when establishing connection fails
      # @return [EM::Deferrable] the deferrable that will succeed with either
      #                          new or released connection
      def acquire_deferred(df, &blk)
        id = df.object_id
        if size < max_size
          # mark allocated pool for proper #size value
          # the connection is made asynchronously
          @allocated[id] = opts = DeferredOptions.new
          @connection_class.connect_defer(@options).callback {|conn|
            opts.apply conn
          }.errback do |err|
            drop_failed(id)
            df.fail(err)
          end
        else
          @pending << (conn_df = ::EM::DefaultDeferrable.new)
          conn_df.errback do
            # a dropped connection made a free slot
            acquire_deferred(df, &blk)
          end
        end.callback(&blk)
      end

      # drop a failed connection (or a mark) from the pool and
      # ensure that the pending requests won't starve
      def drop_failed(id)
        @allocated.delete(id)
        if pending = @pending.shift
          if pending.is_a?(Fiber)
            pending.resume
          else
            pending.fail
          end
        end
      end

      # release connection and pass it to the next pending
      # request or back to the free pool
      def release(id)
        conn = @allocated.delete(id)
        if pending = @pending.shift
          if pending.is_a?(Fiber)
            @allocated[pending.object_id] = conn
            pending.resume conn
          else
            pending.succeed conn
          end
        else
          @available << conn
        end
      end

    end
  end
end
