class WeeklyHotPageIndexJob < ApplicationJob
  queue_as :search_indexer

  def perform
    Topic.precache_hot_page
  end
end
