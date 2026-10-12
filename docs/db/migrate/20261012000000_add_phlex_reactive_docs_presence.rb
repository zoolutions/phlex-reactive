# frozen_string_literal: true

# Presence (issue #358): pgbus's presence table, from pgbus 0.18's own
# `rails g pgbus:add_presence` template. Production only — the deployed site
# runs pgbus on Postgres; dev and test run SQLite without pgbus, where this
# migration does nothing (the presence demo stays behind Presence.capable?).
# Named for this app so it cannot collide with pgbus's own AddPgbusPresence.
# A FRESH production database is built by db:prepare from the SQLite-dumped
# schema.rb, which has no presence table, and this migration is then marked as
# run: there, run `rails g pgbus:add_presence` (or the demo stays hidden).
class AddPhlexReactiveDocsPresence < ActiveRecord::Migration[8.1]
  def up
    return unless connection.adapter_name.match?(/postg/i)
    return if table_exists?(:pgbus_presence_members)

    create_table :pgbus_presence_members, id: false do |t|
      t.string :stream_name, null: false
      t.string :member_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.string :connection_id
      t.string :seat
      t.jsonb :state, null: false, default: {}
      t.datetime :joined_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.datetime :last_seen_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
    end

    add_index :pgbus_presence_members, %i[stream_name member_id],
              unique: true, where: 'connection_id IS NULL', name: 'idx_pgbus_presence_members_member_key'
    add_index :pgbus_presence_members, %i[stream_name connection_id],
              unique: true, where: 'connection_id IS NOT NULL', name: 'idx_pgbus_presence_members_connection_key'
    add_index :pgbus_presence_members, %i[stream_name member_id], name: 'idx_pgbus_presence_members_member'
    add_index :pgbus_presence_members, %i[stream_name last_seen_at], name: 'idx_pgbus_presence_members_sweep'
    add_index :pgbus_presence_members, :last_seen_at,
              where: 'connection_id IS NOT NULL', name: 'idx_pgbus_presence_members_seat_expiry'
  end

  # The table may be pgbus's own (its AddPgbusPresence, or `up` found it
  # already there), so rolling this back never drops it: roll back pgbus's
  # migration for that.
  def down; end
end
