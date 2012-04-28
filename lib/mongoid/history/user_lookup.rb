module Mongoid::History
  class UserLookup < Mongoid::Observer
    def controller
      Thread.current[:mongoid_history_user_lookup_controller]
    end

    def controller=(value)
      Thread.current[:mongoid_history_user_lookup_controller] = value
    end

    # Hook to ActionController::Base#around_filter.
    # Runs before a controller action is run.
    # It should always return true so controller actions
    # can continue.
    def before(controller)
      self.controller = controller
      true
    end

    # Hook to ActionController::Base#around_filter.
    # Runs after a controller action is run.
    # Clean up so that the controller can
    # be collected after this request
    def after(controller)
      self.controller = nil
    end
  end
end