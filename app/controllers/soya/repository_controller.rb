module Soya
  # This application, pretending to be a SOyA repository.
  #
  # soya-web-cli resolves every structure by pulling it from the repository it
  # was configured with. Pointing that at the internet would mean the operator
  # needs a network to open a form they filled in yesterday, and that the
  # structure they validate against can change under them between two passports.
  # Pointing it here instead means both come out of the vault: the fetch is the
  # only moment a repository on the internet is involved, and after it the
  # application is self-contained.
  #
  # The endpoints are the three soya-js actually uses (confirmed in
  # lib2/src/services/repo.ts: pull is GET /{name}, nothing more elaborate).
  #
  # Not behind the passphrase, because soya-web-cli is a separate process with
  # no session — but bound to the loopback address, which it shares with nothing
  # else. A request published to the host arrives from the container gateway and
  # is refused.
  class RepositoryController < ActionController::Base
    LOOPBACK = %w[127.0.0.1 ::1].freeze

    before_action :require_loopback
    before_action :require_open_vault

    # GET /soya/:name — the structure, as soya-js expects to receive it.
    #
    # A type carries three: the one the form comes from, the transformation that
    # turns its answers into the element model, and the one that reads an
    # element model back. All are pulled by name through here, so which of them
    # was asked for is decided by the name.
    def show
      type, kind = ProductType.resolve_document(params[:name])
      document = case kind
      when :transformation         then type&.transformation_jsonld
      when :reverse_transformation then type&.reverse_transformation_jsonld
      else                              type&.jsonld
      end
      return head :not_found if document.blank?

      render json: document
    end

    # GET /soya/:name/yaml — the author's version. Optional everywhere it is
    # used, so a structure that was published without one answers 404 rather
    # than inventing something.
    def yaml
      type = ProductType.resolve(params[:name])
      return head :not_found if type.nil? || type.yaml.blank?

      render plain: type.yaml, content_type: "text/plain"
    end

    # GET /soya/api/soya/query?name= — searching the types that are here.
    def query
      term = params[:name].to_s
      rows = ProductType.fetched.select { |type| type.structure_name.downcase.include?(term.downcase) }

      render json: rows.map { |type| { name: type.resolvable_name, dri: type.dri } }
    end

    private

    def require_loopback
      head :forbidden unless LOOPBACK.include?(request.remote_ip)
    end

    # 503 rather than 404: the structure is not missing, it is unreadable until
    # someone types the passphrase. A form cannot be rendered before that
    # anyway, so this is a state nobody should reach.
    def require_open_vault
      head :service_unavailable unless Vault::Store.open?
    end
  end
end
