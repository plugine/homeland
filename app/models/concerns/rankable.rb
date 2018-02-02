# Attention: All Rankable Model should have integer filed 'last_action_at'.
module Rankable
  extend ActiveSupport::Concern

  included do
    scope :week_actioned, -> { where("last_action_at > #{(Time.now.beginning_of_day - 7.days).to_i}") }
    scope :day_actioned,  -> { where("last_action_at > #{(Time.now.beginning_of_hour - 1.day).to_i}") }
    scope :hour_actioned, -> { where("last_action_at > #{(Time.now.beginning_of_hour - 1.hour).to_i}") }

    before_destroy do
      $redis.zrem(Rankable.hot_page_day_rank_cache_key, self.id)
      $redis.zrem(Rankable.hot_page_week_rank_cache_key, self.id)
    end


    # 将上一小时的分数根据求权方程加入到总分中（由定时任务每小时整点调用）
    def self.merge_daily_hot_topic_score
      score_ex = 345 / 321.to_f
      self.day_actioned.each do |topic|
        last_score = $redis.get(Rankable.hour_score_cache_key(topic.id)).to_i
        hour_score = $redis.get(Rankable.prev_hour_score_cache_key(topic.id)).to_i

        $redis.set(Rankable.hour_score_cache_key(topic.id), (last_score / score_ex) + hour_score, ex: 2.day)
        topic.calc_hour_hot_score
      end
    end

    # 将上天的分数根据求权方程加入到总分中（由定时任务每天0点调用）
    def self.merge_weekly_hot_topic_score
      score_ex = 28 / 21.to_f
      self.week_actioned.each do |topic|
        last_score = $redis.get(Rankable.day_score_cache_key(topic.id)).to_i
        day_score = $redis.get(Rankable.prev_day_score_cache_key(topic.id)).to_i

        $redis.set(Rankable.day_score_cache_key(topic.id), (last_score / score_ex) + day_score, ex: 1.week)
        topic.calc_day_hot_score
      end
    end

    # 取得100条每日热帖
    def self.daily_hot
      ids = $redis.zrevrange(Rankable.hot_page_day_rank_cache_key, 0, 100)
      return self.find(ids) if ids.size > 1
      [self.find(ids.first)]
    end

    # 取得100条每周热帖
    def self.weekly_hot
      ids = $redis.zrevrange(Rankable.hot_page_week_rank_cache_key, 0, 100)
      return self.find(ids) if ids.size > 1
      [self.find(ids.first)]
    end

    # for test environment only
    def self.clear_cache
      keys = $redis.keys("action_weight_#{Rails.env}_*")
      $redis.pipelined do
        keys.each {|k| $redis.del k}
      end
    end
  end

  def view_action
    update_last_action_time
  end

  def comment_action
    update_last_action_time(is_comment_action: true)
  end

  # 更新最后操作时间和帖子热门值分数，默认计算浏览事件，当is_comment_action为true时计算的是评论事件
  # 当用户发表评论和浏览帖子时会触发这次操作
  def update_last_action_time(is_comment_action: false)
    weight = 1
    weight = 3 if is_comment_action

    update_attribute(:last_action_at, Time.now.to_i)

    $redis.pipelined do
      $redis.set(Rankable.current_hour_score_cache_key(self.id), 0, expire: 2.5.hours) unless $redis.exists(Rankable.current_hour_score_cache_key(self.id))
      $redis.incrby(Rankable.current_hour_score_cache_key(self.id), weight)

      $redis.set(Rankable.current_day_score_cache_key(self.id), 0, expire: 2.1.days) unless $redis.exists(Rankable.current_day_score_cache_key(self.id))
      $redis.incrby(Rankable.current_day_score_cache_key(self.id), weight)
    end

    calc_day_hot_score
    calc_hour_hot_score
  end

  # 实时将周排行的每日分数算入排行榜中
  def calc_day_hot_score
      last_score = $redis.get(Rankable.day_score_cache_key(self.id)).to_i
      current_day_score = $redis.get(Rankable.current_day_score_cache_key(self.id)).to_i
      score = current_day_score * 7 + last_score

      # zadd key score member
      $redis.zadd(Rankable.hot_page_week_rank_cache_key, score, self.id)
  end

  # 实时将日排行的每小时分数算入排行榜中
  def calc_hour_hot_score
      last_score = $redis.get(Rankable.hour_score_cache_key(self.id)).to_i
      current_hour_score = $redis.get(Rankable.current_hour_score_cache_key(self.id)).to_i
      score = current_hour_score * 24 + last_score

      # zadd key score member
      $redis.zadd(Rankable.hot_page_day_rank_cache_key, score, self.id)
  end

  def hot_day_score
    $redis.zscore(Rankable.hot_page_day_rank_cache_key, self.id)
  end

  def hot_week_score
    $redis.zscore(Rankable.hot_page_week_rank_cache_key, self.id)
  end

  def self.hot_page_day_rank_cache_key
    "action_weight_#{Rails.env}_rank_day"
  end

  def self.hot_page_week_rank_cache_key
    "action_weight_#{Rails.env}_rank_week"
  end

  def self.hour_score_cache_key(tid)
    "action_weight_#{Rails.env}_score_daily_#{tid}"
  end

  def self.day_score_cache_key(tid)
    "action_weight_#{Rails.env}_score_weekly_#{tid}"
  end

  def self.prev_hour_score_cache_key(tid)
    "action_weight_#{Rails.env}_hour_#{tid}_#{(Time.now.beginning_of_hour - 1.hour).to_i}"
  end

  def self.current_hour_score_cache_key(tid)
    "action_weight_#{Rails.env}_hour_#{tid}_#{Time.now.beginning_of_hour.to_i}"
  end

  def self.prev_day_score_cache_key(tid)
    "action_weight_#{Rails.env}_day_#{tid}_#{(Time.now.beginning_of_day - 1.day).to_i}"
  end

  def self.current_day_score_cache_key(tid)
    "action_weight_#{Rails.env}_day_#{tid}_#{Time.now.beginning_of_day.to_i}"
  end
end