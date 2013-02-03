require 'easy_diff'

require File.expand_path(File.dirname(__FILE__) + '/mongoid/events')
require File.expand_path(File.dirname(__FILE__) + '/mongoid/events/tracker')
require File.expand_path(File.dirname(__FILE__) + '/mongoid/events/trackable')

Mongoid::Events.trackable_class_options = {}
