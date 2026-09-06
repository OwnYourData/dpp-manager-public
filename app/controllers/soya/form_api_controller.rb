module Soya
  # What the soya-form page asks for while it renders.
  #
  # These four paths are not this application's choice: they are hard-coded in
  # the SPA's own source (src/config.ts and src/services/soyaRepo.ts), which is
  # served unmodified. Implementing them here rather than running the little
  # Node server that normally answers them means the answers come out of the
  # vault — so a form renders with the wifi off, and nothing about the
  # operator's structures leaves this machine.
  #
  # Note what is *not* here: soya-web-cli. The form was generated when the type
  # was fetched and stored with it, so rendering costs a database read. The Node
  # process is needed at import and at validation, not while somebody types.
  class FormApiController < ApplicationController
    # GET /api/runtime-config
    def runtime_config
      render json: { repoBaseUrl: soya_root_url, repoMode: "public" }
    end

    # GET /api/repo/query?name=
    def query
      term = params[:name].to_s
      rows = ProductType.fetched.select { |type| type.structure_name.downcase.include?(term.downcase) }

      render json: rows.map { |type| { name: type.resolvable_name, dri: type.dri } }
    end

    # GET /api/repo/:name/yaml
    #
    # The SPA prefers the author's YAML, because that is where a form overlay
    # lives, and falls back to the generated form when it is not there. A 404 is
    # therefore an ordinary answer and not a failure.
    def yaml
      type = ProductType.resolve(params[:name])
      return head :not_found if type.nil? || type.yaml.blank?

      render plain: type.yaml, content_type: "text/plain"
    end

    # GET /api/form/:name?language=&tag=
    def form
      type = ProductType.resolve(params[:name])
      return head :not_found if type.nil?

      form = type.form_for(params[:language].presence || I18n.locale)
      return head :not_found if form.nil?

      render json: form
    end

    private

    def soya_root_url
      "#{request.base_url}/soya"
    end
  end
end
