# One worker, a handful of threads. This serves exactly one person on their own
# machine, and the vault key lives in the memory of one process -- a second
# worker would have its own copy of nothing and would not be able to answer.
threads 1, Integer(ENV.fetch("RAILS_MAX_THREADS", 5))

bind "tcp://#{ENV.fetch('BIND', '0.0.0.0')}:#{ENV.fetch('PORT', 3000)}"

environment ENV.fetch("RAILS_ENV", "production")
workers 0

plugin :tmp_restart
