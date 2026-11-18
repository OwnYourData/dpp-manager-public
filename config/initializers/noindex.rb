# DPP_NOINDEX: an X-Robots-Tag header on every response, including the static
# files and the health check, which never pass through a controller. The
# variable is read per request (Deployment.noindex?), so the middleware is always
# in place and does nothing unless it is set.
class NoindexHeader
  VALUE = "noindex, nofollow".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    headers["x-robots-tag"] = VALUE if Deployment.noindex?
    [ status, headers, body ]
  end
end

Rails.application.config.middleware.insert_before 0, NoindexHeader
