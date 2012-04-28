module Mongoid::History
  module Tracker
    extend ActiveSupport::Concern

    included do
      include Mongoid::Document
      include Mongoid::Timestamps
      attr_writer :trackable

      field       :association_chain,       :type => Array,     :default => []
      field       :data,                    :type => Hash
      field       :original,                :type => Hash
      field       :version,                 :type => Integer
      field       :action,                  :type => String
      field       :scope,                   :type => String
      field       :edited_by,               :type => String
      field       :record_id,               :type => String

    end

    def trackable_root
      @trackable_root ||= trackable_parents_and_trackable.first
    end

    def trackable
      @trackable ||= trackable_parents_and_trackable.last
    end

    def trackable_parents
      @trackable_parents ||= trackable_parents_and_trackable[0, -1]
    end

    def trackable_parent
      @trackable_parent ||= trackable_parents_and_trackable[-2]
    end

    def affected
      @affected ||= (data.keys | original.keys).inject({}){ |h,k| h[k] =
        trackable ? trackable.attributes[k] : data[k]; h}
    end

  end
end
