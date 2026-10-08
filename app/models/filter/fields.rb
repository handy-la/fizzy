module Filter::Fields
  extend ActiveSupport::Concern

  INDEXES = %w[ all closed not_now stalled postponing_soon golden ]
  SORTED_BY = %w[ newest oldest latest ]

  # Each term adds one full-text predicate to the cards query, so a filter
  # carries few short terms.
  MAX_TERMS = 10
  MAX_TERM_LENGTH = 100
  MAX_TERMS_LENGTH = 300

  delegate :default_value?, to: :class

  class_methods do
    def default_values
      { indexed_by: "all", sorted_by: "latest" }
    end

    def default_value?(key, value)
      default_values[key.to_sym].eql?(value)
    end

    def normalize_terms(terms)
      Array(terms).collect { it.to_s.squish }.compact_blank.uniq
    end

    def terms_within_limits?(terms)
      terms.size <= MAX_TERMS &&
        terms.all? { it.length <= MAX_TERM_LENGTH } &&
        terms.sum(&:length) <= MAX_TERMS_LENGTH
    end

    def indexed_by_human_name(index)
      case index
      when "postponing_soon"
        "Closing soon"
      when "closed"
        "Done"
      when "all"
        "Open"
      else
        index.humanize
      end
    end
  end

  included do
    store_accessor :fields, :assignment_status, :indexed_by, :sorted_by, :terms,
      :card_ids, :creation, :closure, :column_ids

    def assignment_status
      super.to_s.inquiry
    end

    def indexed_by
      (super || default_indexed_by).inquiry
    end

    def sorted_by
      (super || default_sorted_by).inquiry
    end

    def creation_window
      TimeWindowParser.parse(creation)
    end

    def closure_window
      TimeWindowParser.parse(closure)
    end

    def terms
      self.class.normalize_terms(super)
    end

    def terms=(value)
      super(self.class.normalize_terms(value))
    end

    def terms_within_limits?
      self.class.terms_within_limits?(terms)
    end

    def column_ids
      Array(super).filter(&:present?).uniq
    end

    def column_ids=(value)
      super(Array(value).filter(&:present?).uniq)
    end
  end

  def with(**fields)
    creator.filters.from_params(as_params).tap do |filter|
      fields.each do |key, value|
        filter.public_send("#{key}=", value)
      end
    end
  end

  def default_indexed_by
    self.class.default_values[:indexed_by]
  end

  def default_indexed_by?
    default_value?(:indexed_by, indexed_by)
  end

  def default_sorted_by
    self.class.default_values[:sorted_by]
  end

  def default_sorted_by?
    default_value?(:sorted_by, sorted_by)
  end
end
