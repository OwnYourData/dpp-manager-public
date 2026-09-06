class SettingsController < ApplicationController
  def show
    @setting = settings
  end

  def update
    @setting = settings
    changed  = {}

    permitted.each do |key, value|
      next if @setting.public_send(key).to_s == value.to_s

      changed[key] = { from: @setting.public_send(key), to: value }
    end

    if @setting.update(permitted)
      changed.each { |key, change| Event.record!(:setting_changed, setting: key, from: change[:from], to: change[:to]) }
      redirect_to settings_path, notice: t("settings.saved")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def permitted
    params.require(:setting).permit(:locale, :help_mode, :idle_timeout_minutes)
  end
end
