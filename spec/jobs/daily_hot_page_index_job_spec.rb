require 'rails_helper'

describe DailyHotPageIndexJob, type: :job do
  describe '.perform' do
    it 'should send daily hot page cache message to topic' do
      expect(Topic).to receive(:precache_hot_page).with({is_rank_day: true}).once
      DailyHotPageIndexJob.perform_later
    end
  end
end
