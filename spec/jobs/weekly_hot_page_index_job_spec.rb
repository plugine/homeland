require 'rails_helper'

describe WeeklyHotPageIndexJob, type: :job do
  describe '.perform' do
    it 'should send weekly hot page cache message to topic' do
      expect(Topic).to receive(:precache_hot_page).once
      WeeklyHotPageIndexJob.perform_later
    end
  end
end
