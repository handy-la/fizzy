class Account::ExportsController < ApplicationController
  before_action :ensure_admin_or_owner
  before_action :set_export, only: :show

  CURRENT_EXPORT_LIMIT = Export::CURRENT_LIMIT

  def show
    respond_to do |format|
      format.html
      format.json { @export ? render(:show) : head(:not_found) }
    end
  end

  def create
    @export = Account::Export.start_for(Current.account, user: Current.user)
    @export.build_later

    respond_to do |format|
      format.html { redirect_to account_settings_path, notice: "Export started. You'll receive an email when it's ready." }
      format.json { render :show, status: :created }
    end
  rescue Export::LimitExceeded
    head :too_many_requests
  end

  private
    def ensure_admin_or_owner
      head :forbidden unless Current.user.admin? || Current.user.owner?
    end

    def set_export
      scope = request.format.json? ? Current.account.exports : Current.account.exports.completed
      @export = scope.find_by(id: params[:id], user: Current.user)
    end
end
