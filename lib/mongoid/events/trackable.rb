module Mongoid::Events
  module Trackable
    extend ActiveSupport::Concern

    module ClassMethods
      def track_events(options={})
        model_name = self.name.tableize.singularize.to_sym
        default_options = {
          :on                 =>  :all,
          :except             =>  [:created_at, :updated_at],
          :modifier_field     =>  :modifier,
          :version_field      =>  :version,
          :scope              =>  model_name,
          :track_create       =>  false,
          :track_update       =>  true,
          :track_destroy      =>  false,
          :periodic_pruning   =>  false,
        }

        options = default_options.merge(options)

        # normalize except fields
        # manually ensure _id, id, version will not be tracked in event
        options[:except] = [options[:except]] unless options[:except].is_a? Array
        options[:except] << options[:version_field]
        options[:except] << "#{options[:modifier_field]}".to_sym
        options[:except] += [:_id, :id, :transaction_id]
        options[:except] = options[:except].map(&:to_s).flatten.compact.uniq
        options[:except].map(&:to_s)

        # normalize fields to track to either :all or an array of strings
        if options[:on] != :all
          options[:on] = [options[:on]] unless options[:on].is_a? Array
          options[:on] = options[:on].map(&:to_s).flatten.uniq
        end

        field options[:version_field].to_sym, :type => Integer
        field :edited_by, :type => String


        tracker_class_name = options[:tracker_class_name].to_s.classify + "Events"
        tracker_collection_name = options[:tracker_class_name].to_s.underscore + "_events"
        
        metric_class_name = options[:tracker_class_name].to_s.classify + "Metrics"
        metric_collection_name = options[:tracker_class_name].to_s.underscore + "_metrics"

        create_tracker_class(tracker_class_name, tracker_collection_name)
        create_metric_class(metric_class_name, metric_collection_name)
        
        options[:tracker_class] = tracker_class_name.constantize

        options[:metric_class] = metric_class_name.constantize
        
        field :transaction_id, :type => String

        #add a transaction id to the scoped document
        if options[:scope] == self.name          
          set_callback :save, :before, :update_transaction_id
        end

        include MyInstanceMethods
        extend SingletonMethods

        delegate :events_trackable_options, :to => 'self.class'
        delegate :track_events?, :to => 'self.class'

        before_update :track_update if options[:track_update]
        before_create :track_create if options[:track_create]
        before_destroy :destroy_events if options[:destroy_events]          
        
        Mongoid::Events.trackable_class_options ||= {}
        Mongoid::Events.trackable_class_options[model_name] = options

        start_pruning_thread(options[:tracker_class]) if options[:periodic_pruning]
      end

      # validates that a class exists in the program namespace
      # returne false if not class with the specified name could
      # be found.
      def find_class(class_name)
        begin
          klass = Module.const_get(class_name)
          return (klass.is_a?(Class) ? klass : nil)
        rescue NameError
          return nil
        end
      end


      def create_metric_class(class_name, collection_name)
        klass = find_class(class_name)

        return klass if klass

        klass = Object.const_set(class_name.gsub(" ",""), Class.new)

        klass.instance_eval{
          include Mongoid::Document
          self.collection_name = collection_name
        }

      end

      def create_tracker_class(class_name, collection_name)
        klass = find_class(class_name)

        return klass if klass

        events_tracker_class = find_class("EventsTracker")

        if !events_tracker_class
          events_tracker_klass = Object.const_set("EventsTracker", Class.new)

          events_tracker_klass.instance_eval{
            include Mongoid::Events::Tracker          
          }
        end

        klass = Object.const_set(class_name.gsub(" ",""), Class.new)

        klass.instance_eval{
          include Mongoid::Document
          self.collection_name = collection_name

          field :t, :type => DateTime

          embeds_one :d, :class_name => "EventsTracker"

          before_create :update_time 
        }

        klass.class_eval{
          def update_time
            self.t = Time.now
          end     
        }        
      end


      def start_pruning_thread(tracker_class)
        Thread.new(tracker_class){
          begin        
            while(1) do
              records = tracker_class.where('d.invalidate_time' => {'$lt' => 1.hour.to_i * 1000}, :t => {'$lt' => Time.now - 1.day})
              records.destroy_all
              sleep(1.day.to_i)
            end
          rescue Exception => e
            puts e
          end
        }        
      end

      def track_events?
        enabled = Thread.current[track_events_flag]
        enabled.nil? ? true : enabled
      end

      def disable_tracking(&block)
        begin
          Thread.current[track_events_flag] = false
          yield
        ensure
          Thread.current[track_events_flag] = true
        end
      end

      def track_events_flag
        "mongoid_events_#{self.name.underscore}_trackable_enabled".to_sym
      end      
    end

    module MyInstanceMethods
      def events_tracks
        @events_tracks ||= events_trackable_options[:tracker_class].where(:scope => events_trackable_options[:scope], :'association_chain.name' => association_hash['name'], :'association_chain.id' => association_hash['id'])
      end
      
      def update_transaction_id
        Thread.current[:current_transaction_id] = self.transaction_id = SecureRandom.uuid
      end

    private
      def get_versions_criteria(options_or_version)
        if options_or_version.is_a? Hash
          options = options_or_version
          if options[:from] && options[:to]
            lower = options[:from] >= options[:to] ? options[:to] : options[:from]
            upper = options[:from] <  options[:to] ? options[:to] : options[:from]
            versions = events_tracks.where( :version.in => (lower .. upper).to_a )
          elsif options[:last]
            versions = events_tracks.limit( options[:last] )
          else
            raise "Invalid options, please specify (:from / :to) keys or :last key."
          end
        else
          options_or_version = options_or_version.to_a if options_or_version.is_a?(Range)
          version_field_name = events_trackable_options[:version_field]
          version = options_or_version || self.attributes[version_field_name] || self.attributes[version_field_name.to_s]
          version = [ version ].flatten
          versions = events_tracks.where(:version.in => version)
        end
        versions.desc(:version)
      end

      def should_track_create?
        track_events? && (Thread.current[:current_transaction_id] != self.send(:transaction_id) or events_trackable_options[:scope] == self.class.to_s)
      end

      def should_track_update?
        track_events? && !modified_attributes_for_update.blank? && (Thread.current[:current_transaction_id] != self.send(:transaction_id) or events_trackable_options[:scope] == self.class.to_s)
      end

      def should_track_destroy?
        track_events? && self._parent == nil
      end

      def traverse_association_chain(node=self)
        list = node._parent ? traverse_association_chain(node._parent) : []
        list << association_hash(node)
        list
      end

      def association_hash(node=self)
        name = node.class.name

        #get index if it's an array
        index = node._parent.send(node.collection_name).size if node.respond_to? :_parent and node._parent and node._parent.send(node.collection_name).respond_to? :size
        transaction_id = node.send(:transaction_id) if node.respond_to? :transaction_id

        { 'name' => name, 'id' => node.id, 'transaction_id' => transaction_id, 'index' => index}
      end

      def modified_attributes_for_update
        @modified_attributes_for_update ||= if events_trackable_options[:on] == :all
          changes.reject do |k, v|
            events_trackable_options[:except].include?(k)
          end
        else
          changes.reject do |k, v|
            !events_trackable_options[:on].include?(k)
          end

        end
      end

      def modified_attributes_for_create
        @modified_attributes_for_create ||= attributes.inject({}) do |h, pair|
          k,v =  pair
          h[k] = [nil, v]
          h
        end.reject do |k, v|
          events_trackable_options[:except].include?(k)
        end
      end

      def modified_attributes_for_destroy
        @modified_attributes_for_destroy ||= attributes.inject({}) do |h, pair|
          k,v =  pair
          h[k] = [nil, v]
          h
        end
      end

      
      def events_tracker_attributes(method)
        return @events_tracker_attributes if @events_tracker_attributes

        @events_tracker_attributes = {
          :association_chain  => traverse_association_chain,
          :scope              => events_trackable_options[:scope],
          :edited_by          => send(events_trackable_options[:modifier_field])

        }

        original, modified = transform_changes(case method
          when :destroy then modified_attributes_for_destroy
          when :create then modified_attributes_for_create
          else modified_attributes_for_update
        end)

        @events_tracker_attributes[:original] = original
        @events_tracker_attributes[:modified] = modified
        @events_tracker_attributes[:data] = attributes.reject{ |k, v| v.is_a?(Hash)}
        @events_tracker_attributes
      end

      def association_path
        path = ''
        @events_tracker_attributes[:association_chain].each do |a|
          path += '.' if not path.empty?
          path += "#{a['name']}"
        end
        path
      end

      def invalidate_old_records
        records = events_trackable_options[:tracker_class].where('d.record_id' =>  @events_tracker_attributes[:association_chain][0]['id'].to_s).and('d.association_path' => association_path)
        records.each do |r|
          invalidate_time = (Time.now.to_i - r.t.to_i) * 1000
          r.update_attribute('d.invalidate', invalidate_time)
        end
      end

      def track_update
        return unless should_track_update?
        current_version = (self.send(events_trackable_options[:version_field]) || 0 ) + 1
        self.send("#{events_trackable_options[:version_field]}=", current_version)
        self.send(:transaction_id=, Thread.current[:current_transaction_id])
        record = events_tracker_attributes(:update).merge(:version => current_version, :action => "update", :trackable => self, :association_path => association_path, :record_id => @events_tracker_attributes[:association_chain][0]['id'].to_s)
        invalidate_old_records
        events_trackable_options[:metric_class].destroy_all
        events_trackable_options[:tracker_class].create!(:d => record)        
        clear_memoization
      end

      def track_create                
        return unless should_track_create?
        current_version = (self.send(events_trackable_options[:version_field]) || 0 ) + 1
        self.send("#{events_trackable_options[:version_field]}=", current_version)
        self.send(:transaction_id=, Thread.current[:current_transaction_id])
        record = events_tracker_attributes(:create).merge(:version => current_version, :action => "create", :trackable => self, :association_path => association_path, :record_id =>  @events_tracker_attributes[:association_chain][0]['id'].to_s)
        events_trackable_options[:metric_class].destroy_all
        events_trackable_options[:tracker_class].create!(:d => record) if record[:modified].size > 0
        clear_memoization
      end

      def destroy_events
        return unless should_track_destroy?
        events_trackable_options[:metric_class].destroy_all
        records = events_trackable_options[:tracker_class].where('d.record_id' => self._id)
        records.destroy_all
        clear_memoization
      end

      def clear_memoization
        @events_tracker_attributes =  nil
        @modified_attributes_for_create = nil
        @modified_attributes_for_update = nil
        @events_tracks = nil
      end

      def transform_changes(changes)
        original = {}
        modified = {}
        changes.each_pair do |k, v|
          o, m = v
          original[k] = o unless o.nil?
          modified[k] = m unless m.nil?
        end

        return original.easy_diff modified
      end

    end

    module SingletonMethods
      def events_trackable_options
        @events_trackable_options ||= Mongoid::Events.trackable_class_options[self.name.tableize.singularize.to_sym]
      end
    end

  end
end
