require "auto-space"

CORRECT_CHARS = [
  ["［", "["],
  ["］", "]"],
  ["【", "["],
  ["】", "]"],
  ["（", "("],
  ["）", ")"]
]

class Topic < ApplicationRecord
  include MarkdownBody
  include SoftDelete
  include Mentionable
  include Closeable
  include Searchable
  include MentionTopic
  include UserAvatarDelegate

  # 临时存储检测用户是否读过的结果
  attr_accessor :read_state, :admin_editing

  belongs_to :user, inverse_of: :topics, counter_cache: true
  belongs_to :team, counter_cache: true
  belongs_to :node, counter_cache: true
  belongs_to :last_reply_user, class_name: "User"
  belongs_to :last_reply, class_name: "Reply"
  has_many :replies, dependent: :destroy

  validates :user_id, :title, :body, :node_id, presence: true

  counter :hits, default: 0

  delegate :login, to: :user, prefix: true, allow_nil: true
  delegate :body, to: :last_reply, prefix: true, allow_nil: true

  # scopes
  scope :last_actived,       -> { order(last_active_mark: :desc) }
  scope :suggest,            -> { where("suggested_at IS NOT NULL").order(suggested_at: :desc) }
  scope :without_suggest,    -> { where(suggested_at: nil) }
  scope :high_likes,         -> { order(likes_count: :desc).order(id: :desc) }
  scope :high_replies,       -> { order(replies_count: :desc).order(id: :desc) }
  scope :no_reply,           -> { where(replies_count: 0) }
  scope :popular,            -> { where("likes_count > 5") }
  scope :excellent,          -> { where("excellent >= 1") }
  scope :without_hide_nodes, -> { exclude_column_ids("node_id", Topic.topic_index_hide_node_ids) }

  scope :without_node_ids,   ->(ids) { exclude_column_ids("node_id", ids) }
  scope :without_users,      ->(ids) { exclude_column_ids("user_id", ids) }
  scope :exclude_column_ids, ->(column, ids) { ids.empty? ? all : where.not(column => ids) }

  scope :week_actioned, lambda {
    now = Time.now
    current_day = Time.new now.year, now.month, now.day
    where("last_action_at > #{(current_day - 7.days).to_i}")
  }

  scope :day_actioned, lambda {
    now = Time.now
    current_hour = Time.new now.year, now.month, now.day, now.hour
    where("last_action_at > #{(current_hour - 1.days).to_i}")
  }

  scope :without_nodes, lambda { |node_ids|
    ids = node_ids + Topic.topic_index_hide_node_ids
    ids.uniq!
    exclude_column_ids("node_id", ids)
  }

  mapping do
    indexes :title, term_vector: :yes
    indexes :body, term_vector: :yes
  end

  def as_indexed_json(_options = {})
    {
      title: self.title,
      body: self.full_body
    }
  end

  def indexed_changed?
    saved_change_to_title? || saved_change_to_body?
  end

  def related_topics(size = 5)
    opts = {
      query: {
        more_like_this: {
          fields: [:title, :body],
          like: [
            {
              _index: self.class.index_name,
              _type: self.class.document_type,
              _id: id
            }
          ],
          min_term_freq: 2,
          min_doc_freq: 5
        }
      },
      size: size
    }
    self.class.__elasticsearch__.search(opts).records.to_a
  end

  def self.fields_for_list
    columns = %w(body who_deleted)
    select(column_names - columns.map(&:to_s))
  end

  def full_body
    ([self.body] + self.replies.pluck(:body)).join('\n\n')
  end

  def self.topic_index_hide_node_ids
    Setting.node_ids_hide_in_topics_index.to_s.split(",").collect(&:to_i)
  end

  before_save :store_cache_fields
  def store_cache_fields
    self.node_name = node.try(:name) || ""
  end

  before_save :auto_correct_title
  def auto_correct_title
    CORRECT_CHARS.each do |chars|
      title.gsub!(chars[0], chars[1])
    end
    title.auto_space!
  end
  before_save do
    if admin_editing == true && self.node_id_changed?
      Topic.notify_topic_node_changed(id, node_id)
    end
  end

  before_create :init_last_active_mark_on_create
  def init_last_active_mark_on_create
    self.last_active_mark = Time.now.to_i
  end

  after_commit :async_create_reply_notify, on: :create
  def async_create_reply_notify
    NotifyTopicJob.perform_later(id)
  end

  def update_last_reply(reply, opts = {})
    # replied_at 用于最新回复的排序，如果帖着创建时间在一个月以前，就不再往前面顶了
    return false if reply.blank? && !opts[:force]

    self.last_active_mark = Time.now.to_i if created_at > 1.month.ago
    self.replied_at = reply.try(:created_at)
    self.replies_count = replies.without_system.count
    self.last_reply_id = reply.try(:id)
    self.last_reply_user_id = reply.try(:user_id)
    self.last_reply_user_login = reply.try(:user_login)
    # Reindex Search document
    SearchIndexer.perform_later("update", "topic", self.id)
    save
  end

  # 更新最后更新人，当最后个回帖删除的时候
  def update_deleted_last_reply(deleted_reply)
    return false if deleted_reply.blank?
    return false if last_reply_user_id != deleted_reply.user_id

    previous_reply = replies.without_system.where.not(id: deleted_reply.id).recent.first
    update_last_reply(previous_reply, force: true)
  end

  # 删除并记录删除人
  def destroy_by(user)
    return false if user.blank?
    update_attribute(:who_deleted, user.login)
    destroy
  end

  def destroy
    super
    delete_notification_mentions
  end

  # 所有的回复编号
  def reply_ids
    Rails.cache.fetch([self, "reply_ids"]) do
      self.replies.order("id asc").pluck(:id)
    end
  end

  def excellent?
    excellent >= 1
  end

  def ban!(opts = {})
    transaction do
      update(lock_node: true, node_id: Node.no_point.id, admin_editing: true)
      if opts[:reason]
        Reply.create_system_event(action: "ban", topic_id: self.id, body: opts[:reason])
      end
    end
  end

  def excellent!
    transaction do
      Reply.create_system_event(action: "excellent", topic_id: self.id)
      update!(excellent: 1)
    end
  end

  def unexcellent!
    transaction do
      Reply.create_system_event(action: "unexcellent", topic_id: self.id)
      update!(excellent: 0)
    end
  end

  def floor_of_reply(reply)
    reply_index = reply_ids.index(reply.id)
    reply_index + 1
  end

  # 更新最后操作时间和帖子热门值分数，默认计算浏览事件，当is_comment_action为true时计算的、是评论事件
  def update_last_action_time(is_comment_action: false)
    now = Time.now
    update_attribute(:last_action_at, now.to_i)
    current_day = Time.new now.year, now.month, now.day

    weight = 1
    weight = 3 if is_comment_action

    week_cache_key = "action_weight_#{Rails.env}_week_#{self.id}_#{current_day.to_i}"
    $redis.set(week_cache_key, 0, expire: 7.days) unless $redis.exists(week_cache_key)
    $redis.incrby(week_cache_key, weight)

    current_hour = current_day + now.hour
    day_cache_key  = "action_weight_#{Rails.env}_day_#{self.id}_#{current_hour.to_i}"
    $redis.set(day_cache_key, 0, expire: 1.days) unless $redis.exists(day_cache_key)
    $redis.incrby(day_cache_key, weight)

  end

  # 计算当前帖子的热门值分数，默认计算当周排名，当 is_rank_day 为true计算当天排名
  def calc_hot_score(is_rank_day: true)
    cache_key_prefix = "action_weight_#{Rails.env}_week_#{self.id}*"
    cache_key_prefix = "action_weight_#{Rails.env}_day_#{self.id}*" if is_rank_day

    max_limit = 7
    max_limit = 24 if is_rank_day

    keys = $redis.keys(cache_key_prefix).to_a
    return 0 if keys == []

    ((($redis.mget(keys).sort do |v1, v2|
      v2[/\d+/].to_i <=> v1[/\d+/].to_i
    end).map &:to_i).each_with_index.map do |v, i|
      v * (max_limit - i)
    end).reduce &:+
  end

  def self.notify_topic_created(topic_id)
    topic = Topic.find_by_id(topic_id)
    return unless topic && topic.user

    follower_ids = topic.user.follow_by_user_ids
    return if follower_ids.empty?

    notified_user_ids = topic.mentioned_user_ids

    # 给关注者发通知
    default_note = { notify_type: "topic", target_type: "Topic", target_id: topic.id, actor_id: topic.user_id }
    Notification.bulk_insert(set_size: 100) do |worker|
      follower_ids.each do |uid|
        # 排除同一个回复过程中已经提醒过的人
        next if notified_user_ids.include?(uid)
        # 排除回帖人
        next if uid == topic.user_id
        note = default_note.merge(user_id: uid)
        worker.add(note)
      end
    end

    true
  end

  def self.notify_topic_node_changed(topic_id, node_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?
    node = Node.find_by_id(node_id)
    return if node.blank?

    Notification.create notify_type: "node_changed",
                        user_id: topic.user_id,
                        target: topic,
                        second_target: node
    true
  end

  def self.total_pages
    return @total_pages if defined? @total_pages

    total_count = Rails.cache.fetch("topics/total_count", expires_in: 1.week) do
      self.unscoped.count
    end
    if total_count >= 1500
      @total_pages = 60
    end
    @total_pages
  end

  # 获取100个指定时段的的热门话题，当is_rank_hour为true是返回24小时热门，否则返回一周热门
  def self.precache_hot_page(is_rank_day: true)
    prepare_pages = Topic.week_actioned
    prepare_pages = Topic.day_actioned if is_rank_day

    cache_key = "hot_page_week_ids_#{Rails.env}"
    cache_key = "hot_page_day_ids_#{Rails.env}" if is_rank_day

    hot_page_ids = (prepare_pages.all.sort do |t1, t2|
      t2.calc_hot_score(is_rank_day: is_rank_day) <=> t1.calc_hot_score(is_rank_day: is_rank_day)
    end).take(100).map(&:id)

    $redis.set cache_key, hot_page_ids.to_json
    hot_page_ids
  end

  def self.hot_page(is_rank_day: false)
    cache_key = "hot_page_week_ids_#{Rails.env}"
    cache_key = "hot_page_day_ids_#{Rails.env}" if is_rank_day

    cache_ids = $redis.get(cache_key).to_s
    if cache_ids == ''
      cache_ids = precache_hot_page is_rank_day: is_rank_day
    else
      cache_ids = JSON.parse cache_ids
    end
    Topic.find(cache_ids)
  end
end
