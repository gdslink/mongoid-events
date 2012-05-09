require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe Mongoid::Event::Tracker do
  before :each do
    class MyTracker
      include Mongoid::Event::Tracker
    end
  end

  after :each do
    Mongoid::Event.tracker_class_name = nil
  end

  it "should set tracker_class_name when included" do
    Mongoid::Event.tracker_class_name.should == :my_tracker
  end
end
