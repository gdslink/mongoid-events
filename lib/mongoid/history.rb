module Mongoid
  module History
    mattr_accessor :tracker_class_name
    mattr_accessor :trackable_class_options
  end
end
