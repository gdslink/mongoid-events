module Mongoid::Events
  module Trackable
    extend ActiveSupport::Concern

    module ClassMethods
      def track_events(options={})
        model_name = self.name.tableize.singularize.to_sym
        default_options = {
            :on                   =>  :all,
            :except               =>  [:created_at, :updated_at],
            :modifier_field       =>  [:edited_by],
            :modifier_src_table   =>  :system,
            :scope                =>  model_name,
            :track_create         =>  false,
            :track_update         =>  true,
            :track_destroy        =>  false,
            :periodic_pruning     =>  false,
        }

        options = default_options.merge(options)

        # normalize except fields
        # manually ensure _id, id, version will not be tracked in event
        options[:except] = [options[:except]] unless options[:except].is_a? Array
        #options[:except] += options[:modifier_field]
        options[:except] += [:_id, :id]
        options[:except] = options[:except].map(&:to_s).flatten.compact.uniq
        options[:except].map(&:to_s)

        # normalize fields to track to either :all or an array of strings
        if options[:on] != :all
          options[:on] = [options[:on]] unless options[:on].is_a? Array
          options[:on] = options[:on].map(&:to_s).flatten.uniq
        end


        # options[:modifier_field].each do |field|
        #   field field
        # end


        tracker_class_name = options[:tracker_class_name].to_s.classify + "Events"
        tracker_collection_name = options[:tracker_class_name].to_s.underscore + "_events"

        metric_class_name = options[:tracker_class_name].to_s.classify + "Metrics"
        metric_collection_name = options[:tracker_class_name].to_s.underscore + "_metrics"

        create_tracker_class(tracker_class_name, tracker_collection_name, options[:modifier_field])
        create_metric_class(metric_class_name, metric_collection_name)

        options[:tracker_class] = tracker_class_name.constantize

        options[:metric_class] = metric_class_name.constantize

        include MyInstanceMethods
        extend SingletonMethods

        delegate :events_trackable_options, :to => 'self.class'
        delegate :track_events?, :to => 'self.class'


        after_destroy :destroy_events if options[:destroy_events]

        Mongoid::Events.trackable_class_options ||= {}
        Mongoid::Events.trackable_class_options[model_name] = options


        @indexes = options[:tracker_class].collection.indexes.map { |k, v| k } rescue []

        options[:tracker_class].collection.indexes.create_one({ :'d.record_id' => 1 }, {:background => true, :name => "record_id" }) if not indexes_include?("record_id")
        options[:tracker_class].collection.indexes.create_one({ :'d.association_path' => 1 }, {:background => true, :name  => "association_path" }) if not indexes_include?("association_path")
        options[:tracker_class].collection.indexes.create_one({ :'d.invalidate' => 1 }, {:background => true, :name => "invalidate" }) if not indexes_include?("invalidate")
        options[:tracker_class].collection.indexes.create_one({ :'d.scope' => 1 }, {:background => true, :name => "scope" }) if not indexes_include?("scope")
        options[:tracker_class].collection.indexes.create_one({ :'d.association_chain.name' => 1 }, {:background => true, :name => "association_chain_name" }) if not indexes_include?("association_chain_name")
        options[:tracker_class].collection.indexes.create_one({ :'d.association_chain.id' => 1 }, {:background => true, :name => "association_chain_id" }) if not indexes_include?("association_chain_id")


        start_pruning_thread(options[:tracker_class]) if options[:periodic_pruning]
      end

      def indexes_include?(name)
        @indexes.map { |i| i['name'] }.include?(name)
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
          store_in collection: collection_name, database: self.database_name
        }

      end

      def create_tracker_class(class_name, collection_name, modifier_fields)
        klass = find_class(class_name)

        return klass if klass

        events_tracker_class = find_class("EventsTracker")

        if !events_tracker_class
          events_tracker_klass = Object.const_set("EventsTracker", Class.new)

          events_tracker_klass.instance_eval{
            include Mongoid::Events::Tracker


            modifier_fields.each do |f|
              field f
            end

          }
        end

        klass = Object.const_set(class_name.gsub(" ",""), Class.new)

        klass.instance_eval{
          include Mongoid::Document
          store_in collection: collection_name, database: self.database_name

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
              records = tracker_class.only(:_id).where('d.invalidate' => {'$lt' => 1.hour.to_i * 1000}, :t => {'$lt' => Time.now - 1.day})
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
        @events_tracks ||= events_trackable_options[:tracker_class].where('d.scope' => events_trackable_options[:scope], 'd.association_chain.name' => association_hash['name'], :'d.association_chain.id' => association_hash['id'])
      end

      def tracked_changes(action = :update)
        events_tracker_attributes(action).merge(:action => action.to_s, :trackable => self, :association_path => association_path, :record_id => @events_tracker_attributes[:association_chain][0]['id'].to_s)
      end

      def track_update(data = nil)
        begin
          return unless should_track_update?
          record = data || tracked_changes(:update)
          invalidate_old_records
          events_trackable_options[:metric_class].delete_all
          events_trackable_options[:tracker_class].create!(:d => record) if record[:modified].size > 0
        ensure
          clear_memoization
        end
      end

      def track_create
        begin
          return unless should_track_create?
          record = tracked_changes(:create)
          events_trackable_options[:metric_class].delete_all
          events_trackable_options[:tracker_class].create!(:d => record)
        ensure
          clear_memoization
        end
      end

      private

      def should_track_create?
        track_events? && events_trackable_options[:scope] == self.class.to_s
      end

      def should_track_update?
        track_events? && !modified_attributes_for_update.blank? && events_trackable_options[:scope] == self.class.to_s
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
        name = node.collection_name

        #get index if it's an array
        index = node._parent.send(node.collection_name).size if node.respond_to? :_parent and node._parent and node._parent.send(node.collection_name).respond_to? :size

        { 'name' => name, 'id' => node.id, 'index' => index}
      end

      def modified_attributes_for_update
        @modified_attributes_for_update ||= if events_trackable_options[:on] == :all
                                              changes_with_relations.reject do |k, v|
                                                events_trackable_options[:except].include?(k) or v[1].kind_of? Mongoid::EncryptedField
                                              end
                                            else
                                              changes_with_relations.reject do |k, v|
                                                !events_trackable_options[:on].include?(k) or v[1].kind_of? Mongoid::EncryptedField
                                              end

                                            end
      end

      def modified_attributes_for_create
        @modified_attributes_for_create ||= attributes.inject({}) do |h, pair|
          k,v =  pair
          h[k] = [nil, v]
          h
        end.reject do |k, v|
          events_trackable_options[:except].include?(k) or v[1].kind_of? Mongoid::EncryptedField
        end
      end

      def modified_attributes_for_destroy
        @modified_attributes_for_destroy ||= attributes.inject({}) do |h, pair|
          k,v =  pair
          h[k] = [nil, v]
          h
        end
      end

      def get_modifier_src(doc = self)
        return doc if not doc.respond_to?(:_parent)
        until doc._parent == nil
          return get_modifier_src(doc._parent)
        end
        doc
      end


      def events_tracker_attributes(method)
        return @events_tracker_attributes if @events_tracker_attributes

        @events_tracker_attributes = {
            :association_chain  => traverse_association_chain,
            :scope              => events_trackable_options[:scope],
        }

        d = get_modifier_src(self)

        events_trackable_options[:modifier_field].each do |field|
          @events_tracker_attributes.merge!(field => d.instance_eval("#{events_trackable_options[:modifier_src_table].to_s}.#{field}"))
        end

        original, modified = transform_changes(case method
                                                 when :destroy then modified_attributes_for_destroy
                                                 when :create then modified_attributes_for_create
                                                 else modified_attributes_for_update
                                               end)

        @events_tracker_attributes[:original] = original
        @events_tracker_attributes[:modified] = modified
        @events_tracker_attributes[:data] = attributes
        @events_tracker_attributes
      end

      def association_path
        path = ''
        @events_tracker_attributes[:association_chain][1..-1].each do |a|
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

      def destroy_events
        return unless should_track_destroy?
        events_trackable_options[:metric_class].delete_all
        records = events_trackable_options[:tracker_class].only(:_id).where('d.record_id' => self._id)
        records.delete_all
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

          modified[k] = m unless o.nil? && m.nil?
        end

        [original, modified]
      end
    end

    module SingletonMethods
      def events_trackable_options
        @events_trackable_options ||= Mongoid::Events.trackable_class_options[self.name.tableize.singularize.to_sym]
      end
    end

  end
end
