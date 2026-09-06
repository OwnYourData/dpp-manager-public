class EventsController < ApplicationController
  PER_PAGE = 100

  def index
    scope = Event.all
    scope = scope.where(kind: params[:kind]) if Event::KINDS.include?(params[:kind])

    @kind         = params[:kind]
    @total        = scope.count
    @events       = scope.reorder(id: :desc).limit(PER_PAGE)
    @broken_at    = Event.verify_chain
  end
end
