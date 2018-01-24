class AddLastActionAtIntoTopics < ActiveRecord::Migration[5.1]
  def change
    add_column :topics, :last_action_at, :integer
    add_index :topics, :last_action_at
  end
end
