class WeeklyHotPageIndexJob < ApplicationJob
  queue_as :search_indexer

  def perform
    Topic.merge_weekly_hot_topic_score
  end
end
