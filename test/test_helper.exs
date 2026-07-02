ExUnit.start()

# `:live` tests shell out to a real git clone (see Syncordian.GitLog) and are excluded by
# default so `mix test` stays green without the clone. Run them with:
#   mix test --include live
ExUnit.configure(exclude: [live: true])
