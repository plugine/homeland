require 'httparty'
require 'json'

WEB_BASE = "https://ruby-china.org"
LIST_URL = "#{WEB_BASE}/topics/popular?page="

items = []

1.times do |i|
  list_content = HTTParty.get("#{LIST_URL}#{i + 1}").body
  result = list_content.scan /<div class="title media-heading">.*?title="(.*?)" href="(.*?)"/m
  result.each do |r|
    items << {
        title: r[0],
        url: r[1]
    }
  end
end

items.each do |item|
  t = Topic.new title: item[:title], node: Node.first, body: item[:title], user: User.first
  t.save
  ((rand * 23).to_i + 1).times do |num|
    r = Reply.new topic: t, body: "reply ##{num}", user: User.first
    r.save
  end
end