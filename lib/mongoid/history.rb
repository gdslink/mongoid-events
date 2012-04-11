module Mongoid
  module History
    mattr_accessor :tracker_class_name
    mattr_accessor :trackable_class_options
    mattr_accessor :modifier_class_name
    mattr_accessor :current_user_method
    mattr_accessor :current_user_field

    def self.tracker_class
      @tracker_class ||= tracker_class_name.to_s.classify.constantize
    end

  end
end
