class Account::ImportsController < ApplicationController
  layout "public"

  disallow_account_scope only: %i[ new create ]
  allow_unauthorized_access only: :show
  before_action :set_import, only: %i[ show ]
  before_action :ensure_accessed_by_owner, only: %i[ show ]

  def new
  end

  def create
    if import = Account::Import.start(identity: Current.identity, file: params[:file])
      redirect_to account_import_path(import, script_name: import.account.slug)
    else
      render :new, alert: "Couldn't create account.", status: :unprocessable_entity
    end
  rescue Account::Import::AlreadyInProgressError
    head :too_many_requests
  end

  def show
  end

  private
    def set_import
      @import = Current.account.imports.find(params[:id])
    end

    def ensure_accessed_by_owner
      head :forbidden unless @import.identity == Current.identity
    end
end
