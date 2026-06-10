# frozen_string_literal: true

module Her
  # Wrapper marking a string as already-rendered, trusted HTML (§5).
  #
  # `Her.safe` passes Safe values through untouched and escapes everything
  # else — that single rule is what lets components nest without
  # double-escaping: an inner component's markup survives because the
  # component returned Safe, while a user-supplied "<script>" string gets
  # neutralized.
  class Safe
    def initialize(str)
      @str = str.to_s
    end

    def to_s
      @str
    end
    alias to_str to_s

    def ==(other)
      other.is_a?(Safe) && to_s == other.to_s
    end
    alias eql? ==

    def hash
      [Safe, @str].hash
    end

    def inspect
      "#<Her::Safe #{@str.inspect}>"
    end

    # Concatenating onto trusted HTML escapes the other side unless it is
    # itself trusted, and stays trusted.
    def +(other)
      Safe.new(@str + Her.safe(other))
    end
  end
end
