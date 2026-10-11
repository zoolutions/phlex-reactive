# frozen_string_literal: true

# A card on the Project board demo (issue #216). Lives in exactly one of the
# three fixed lanes; position orders it within its lane (moves append at the
# bottom). One shared public board — every visitor plays on the same cards,
# which is what makes the cross-tab story visible between strangers.
class Card < ApplicationRecord
  LANES = %w[todo doing done].freeze

  validates :title, presence: true
  validates :lane, inclusion: { in: LANES }

  scope :by_lane, ->(lane) { where(lane:).order(:position, :id) }

  # The board's broadcast topic — the SAME splat feeds turbo_stream_from
  # (subscribe) and broadcast_to (publish), so the key can never drift.
  def self.stream_key = %w[project-board all]

  # New cards land at the bottom of their lane.
  def self.next_position(lane)
    (by_lane(lane).maximum(:position) || 0) + 1
  end

  # A drop (issue #350): into `lane` at the 0-based `index` among its other
  # cards, renumbering the lane 1..n so positions stay dense.
  def move_to!(lane, index)
    transaction do
      cards = Card.by_lane(lane).where.not(id:).to_a
      cards.insert(index.clamp(0, cards.size), self)
      update!(lane:)
      cards.each.with_index(1) { |card, position| card.update!(position:) }
    end
  end
end
