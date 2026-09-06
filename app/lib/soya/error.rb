module Soya
  # Everything that can go wrong on the way to or from SOyA, under one name.
  #
  # In its own file rather than beside the client that raises it most: the
  # rescue in Soya::Import fires on paths where no client has been loaded yet,
  # and an autoloader that has not seen the constant defined turns a handled
  # failure into a NameError several frames away from the cause.
  class Error < StandardError; end
end
