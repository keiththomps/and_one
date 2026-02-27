# frozen_string_literal: true

module AndOne
  # Auto-scans for N+1 queries during `rails console` sessions.
  # Each console command is wrapped in an N+1 scan, and warnings
  # are printed inline after the result.
  #
  # Activated automatically by the Railtie in development, or manually:
  #
  #   AndOne::Console.activate!
  #
  # To deactivate:
  #   AndOne::Console.deactivate!
  #
  module Console
    class << self
      def activate!
        return if active?

        @active = true
        @previous_raise = AndOne.raise_on_detect
        # Never raise in console — always warn inline
        AndOne.raise_on_detect = false

        start_scan
        install_hook
      end

      def deactivate!
        return unless active?

        finish_scan
        remove_hook
        AndOne.raise_on_detect = @previous_raise
        @active = false
      end

      def active?
        @active == true
      end

      private

      def start_scan
        return if AndOne.scanning?

        AndOne.scan # Start without a block — manual finish later
      end

      def finish_scan
        AndOne.finish if AndOne.scanning?
      rescue StandardError
        # Don't let cleanup errors interrupt the console
        nil
      end

      # Install an IRB/Pry hook that finishes the current scan after each
      # command and starts a fresh one.
      def install_hook
        if defined?(::IRB)
          install_irb_hook
        elsif defined?(::Pry)
          install_pry_hook
        end
      end

      def remove_hook
        if defined?(::IRB) && @irb_hook_installed
          remove_irb_hook
        elsif defined?(::Pry) && @pry_hook_installed
          remove_pry_hook
        end
      end

      def install_irb_hook
        return if @irb_hook_installed

        @irb_hook_installed = true

        # IRB in Rails 7.1+ uses IRB::Context#evaluate with hooks
        # We hook into the SIGINT-safe eval output via an around_eval approach
        return unless defined?(::IRB::Context)

        ::IRB::Context.prepend(IrbContextPatch)
      end

      def remove_irb_hook
        @irb_hook_installed = false
        # The prepend can't be removed, but IrbContextPatch checks active?
      end

      def install_pry_hook
        return if @pry_hook_installed

        @pry_hook_installed = true

        ::Pry.hooks.add_hook(:after_eval, :and_one_console) do |_result, _pry|
          AndOne::Console.send(:cycle_scan) if AndOne::Console.active?
        end
      end

      def remove_pry_hook
        ::Pry.hooks.delete_hook(:after_eval, :and_one_console) if defined?(::Pry) && ::Pry.hooks
        @pry_hook_installed = false
      end

      # Finish the current scan (reporting any N+1s), then start a fresh one.
      def cycle_scan
        finish_scan
        start_scan
      end
    end

    # Prepended into IRB::Context to hook after each evaluation.
    module IrbContextPatch
      def evaluate(...)
        result = super
        AndOne::Console.send(:cycle_scan) if AndOne::Console.active?
        result
      rescue StandardError
        AndOne::Console.send(:cycle_scan) if AndOne::Console.active?
        raise
      end
    end
  end
end
