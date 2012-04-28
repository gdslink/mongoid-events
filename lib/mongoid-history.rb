require 'easy_diff'

require File.expand_path(File.dirname(__FILE__) + '/mongoid/history')
require File.expand_path(File.dirname(__FILE__) + '/mongoid/history/tracker')
require File.expand_path(File.dirname(__FILE__) + '/mongoid/history/trackable')
require File.expand_path(File.dirname(__FILE__) + '/mongoid/history/user_lookup')

Mongoid::History.modifier_class_name = "User"
Mongoid::History.trackable_class_options = {}
Mongoid::History.current_user_method ||= :current_user
Mongoid::History.current_user_field ||= :email
