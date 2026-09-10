# frozen_string_literal: true

module AndOne
  # One process-lifetime subscription; scan cleanup only releases local state.
  module SqlSubscriber
    @mutex = Mutex.new

    def self.install!
      @mutex.synchronize do
        return @subscriber if @subscriber

        @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          detector = ExecutionContext.active_detector
          detector&.record(payload)
        end
      end
    end
  end
end
