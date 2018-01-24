class DailyHotPageIndexJob < ApplicationJob
  queue_as :search_indexer

  def perform
    Topic.precache_hot_page is_rank_day: true
  end
end
