require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe Mongoid::Events::Trackable do
  before :each do
    class MyModel
      include Mongoid::Document
      include Mongoid::Events::Trackable
    end
  end

  after :each do
    Mongoid::Events.trackable_class_options = nil
  end

  it "should have #track_events" do
    MyModel.should respond_to :track_events
  end

  it "should append trackable_class_options ONLY when #track_events is called" do
    Mongoid::Events.trackable_class_options.should be_blank
    MyModel.track_events
    Mongoid::Events.trackable_class_options.keys.should == [:my_model]
  end

  describe "#track_events" do
    before :each do
      class MyModel
        include Mongoid::Document
        include Mongoid::Events::Trackable
        track_events
      end

      @expected_option = {
        :on             =>  :all,
        :modifier_field =>  :modifier,
        :version_field  =>  :version,
        :scope          =>  :my_model,
        :except         =>  ["created_at", "updated_at", "version", "modifier_id", "_id", "id"],
        :track_create   =>  false,
        :track_update   =>  true,
        :track_destroy  =>  false,
      }
    end

    after :each do
      Mongoid::Events.trackable_class_options = nil
    end

    it "should have default options" do
      Mongoid::Events.trackable_class_options[:my_model].should == @expected_option
    end

    it "should define callback function #track_update" do
      MyModel.new.private_methods.collect(&:to_sym).should include(:track_update)
    end

    it "should define callback function #track_create" do
      MyModel.new.private_methods.collect(&:to_sym).should include(:track_create)
    end

    it "should define callback function #track_destroy" do
      MyModel.new.private_methods.collect(&:to_sym).should include(:track_destroy)
    end

    it "should define #events_trackable_options" do
      MyModel.events_trackable_options.should == @expected_option
    end

    context "track_events" do

      it "should be enabled on the current thread" do
        MyModel.new.track_events?.should == true
      end

      it "should be disabled within disable_tracking" do
        MyModel.disable_tracking do
          MyModel.new.track_events?.should == false
        end
      end

      it "should be rescued if an exception occurs" do
        begin
          MyModel.disable_tracking do
            raise "exception"
          end
        rescue
        end
        MyModel.new.track_events?.should == true
      end

      it "should be disabled only for the class that calls disable_tracking" do
        class MyModel2
          include Mongoid::Document
          include Mongoid::Events::Trackable
          track_events
        end

        MyModel.disable_tracking do
          MyModel2.new.track_events?.should == true
        end
      end

    end

  end
end
