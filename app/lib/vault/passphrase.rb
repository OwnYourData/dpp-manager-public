module Vault
  # Judging a passphrase, for the strength indicator on the create screen.
  #
  # Deliberately not a dictionary check and not a rule set ("one capital, one
  # digit"). Rules of that kind push people towards short passwords that satisfy
  # the rules, and this passphrase is the only thing between an attacker with the
  # file and everything in it. Length is what matters, so length is what is
  # rewarded, and the wording tells the user why.
  module Passphrase
    MINIMUM_LENGTH = 12

    LEVELS = %i[too_short weak fair strong].freeze

    module_function

    def level(passphrase)
      value = passphrase.to_s
      return :too_short if value.length < MINIMUM_LENGTH

      case estimated_bits(value)
      when 0...60   then :weak
      when 60...90  then :fair
      else :strong
      end
    end

    # A rough entropy estimate, not a promise: character-class size times length,
    # with repeats discounted. It ranks passphrases against each other, which is
    # all a bar on a screen can honestly do.
    def estimated_bits(passphrase)
      value = passphrase.to_s
      return 0 if value.empty?

      pool = 0
      pool += 26 if value.match?(/[a-z]/)
      pool += 26 if value.match?(/[A-Z]/)
      pool += 10 if value.match?(/[0-9]/)
      pool += 33 if value.match?(/[^a-zA-Z0-9]/)
      pool = 26 if pool.zero?

      unique_ratio = value.chars.uniq.length.to_f / value.length
      (value.length * Math.log2(pool) * unique_ratio).floor
    end
  end
end
