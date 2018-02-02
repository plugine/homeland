class DailyHotPageIndexJob < ApplicationJob
  queue_as :search_indexer

  def perform
    Topic.merge_daily_hot_topic_score
  end
end
