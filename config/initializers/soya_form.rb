# The soya-form single-page app, served from this application.
#
# It is built into the image as static files and mounted here rather than run
# behind its own little Node server. Two reasons, both practical: one HTTP
# surface instead of two, and — the one that matters — same origin. The page
# that embeds it listens to its postMessage, and a form on a different origin
# would put a cross-origin boundary between the operator's typing and the place
# it is stored.
#
# Nothing here is secret: it is the same JavaScript everyone using SOyA gets.
# The data it renders comes from routes that are behind the passphrase.
root = ENV["SOYA_FORM_ROOT"].presence

if root && File.directory?(root)
  Rails.application.config.middleware.insert_before(
    0, Rack::Static,
    urls: [ "/soya-form" ],
    root: File.dirname(root),
    index: "index.html",
    header_rules: [
      # Vite fingerprints every asset, so they can be cached hard; index.html
      # must not be, or an image upgrade leaves the browser holding a page that
      # points at assets which are no longer there.
      [ %r{/assets/}, { "cache-control" => "public, max-age=31536000, immutable" } ],
      [ :all,         { "cache-control" => "no-cache" } ]
    ]
  )
end
